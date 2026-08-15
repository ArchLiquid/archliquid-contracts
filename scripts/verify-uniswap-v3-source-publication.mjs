#!/usr/bin/env node

import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";

const SOURCIFY = "https://sourcify.dev/server";
const BLOCKSCOUT = "https://explorer.testnet.chain.robinhood.com";
const CHAIN_ID = "46630";

function parseArgs(argv) {
  const options = { inputDir: null, parityReport: null, report: null };
  const fields = new Map([
    ["--input-dir", "inputDir"],
    ["--parity-report", "parityReport"],
    ["--report", "report"],
  ]);
  for (let index = 0; index < argv.length; index += 1) {
    const field = fields.get(argv[index]);
    if (!field) throw new Error(`Unknown argument: ${argv[index]}`);
    const value = argv[++index];
    if (!value || value.startsWith("--")) throw new Error(`${argv[index - 1]} requires a value`);
    options[field] = value;
  }
  for (const [field, value] of Object.entries(options)) {
    if (!value) throw new Error(`--${field.replace(/[A-Z]/g, (letter) => `-${letter.toLowerCase()}`)} is required`);
  }
  return options;
}

async function json(url) {
  const response = await fetch(url, {
    headers: { accept: "application/json" },
    signal: AbortSignal.timeout(30_000),
  });
  const body = await response.json().catch(() => null);
  return { status: response.status, body };
}

function sourceIsPresent(contract, sourcePath) {
  const paths = [contract?.file_path, ...(contract?.additional_sources ?? []).map((source) => source.file_path)];
  return paths.some((candidate) => candidate === sourcePath
    || path.posix.basename(candidate ?? "") === path.posix.basename(sourcePath));
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const inputDir = path.resolve(options.inputDir);
  const index = JSON.parse(await readFile(path.join(inputDir, "index.json"), "utf8"));
  const parity = JSON.parse(await readFile(path.resolve(options.parityReport), "utf8"));
  if (!parity.passed || parity.summary?.passed !== parity.summary?.total) {
    throw new Error("exact bytecode parity must pass before publication verification");
  }
  const parityById = new Map(parity.checks.map((check) => [check.id, check]));
  const checks = [];
  for (const payload of index.payloads) {
    const parityCheck = parityById.get(payload.id);
    if (!parityCheck?.parityPassed || parityCheck.address !== payload.address) {
      throw new Error(`${payload.id} has no matching exact-bytecode evidence`);
    }
    const [sourcify, blockscout] = await Promise.all([
      json(`${SOURCIFY}/v2/contract/${CHAIN_ID}/${payload.address}`),
      json(`${BLOCKSCOUT}/api/v2/smart-contracts/${payload.address}`),
    ]);
    const sourcifyClassification = sourcify.body?.match;
    const sourcifyVerified = sourcify.status === 200
      && ["match", "exact_match"].includes(sourcifyClassification)
      && sourcify.body?.creationMatch === sourcifyClassification
      && sourcify.body?.runtimeMatch === sourcifyClassification;
    const blockscoutVerified = blockscout.status === 200
      && blockscout.body?.is_verified === true
      && blockscout.body?.is_changed_bytecode === false
      && sourceIsPresent(blockscout.body, payload.sourcePath);
    const passed = sourcifyVerified && blockscoutVerified;
    checks.push({
      id: payload.id,
      address: payload.address,
      contractName: payload.contractName,
      sourcePath: payload.sourcePath,
      exactBytecodeParity: true,
      sourcify: {
        verified: sourcifyVerified,
        classification: sourcifyClassification ?? null,
        matchId: sourcify.body?.matchId ?? null,
        verifiedAt: sourcify.body?.verifiedAt ?? null,
      },
      blockscout: {
        verified: blockscoutVerified,
        fullyVerified: blockscout.body?.is_fully_verified === true,
        partiallyVerified: blockscout.body?.is_partially_verified === true,
        displayedName: blockscout.body?.name ?? null,
        sourcePathPresent: sourceIsPresent(blockscout.body, payload.sourcePath),
        changedBytecode: blockscout.body?.is_changed_bytecode ?? null,
      },
      passed,
    });
    console.log(`${passed ? "PASS" : "BLOCKED"} ${payload.id}: Sourcify ${sourcifyClassification ?? sourcify.status}, Blockscout ${blockscout.status}`);
  }
  const verified = checks.filter((check) => check.passed).length;
  const exact = checks.filter((check) => check.sourcify.classification === "exact_match").length;
  const match = checks.filter((check) => check.sourcify.classification === "match").length;
  const report = {
    schemaVersion: 1,
    releaseId: index.releaseId,
    checkedAt: new Date().toISOString(),
    passed: verified === checks.length,
    summary: {
      total: checks.length,
      verified,
      sourcifyExactMatch: exact,
      sourcifyMatch: match,
      blocked: checks.length - verified,
    },
    interpretation: {
      exactBytecodeParity: "Independent release evidence proves the live creation and runtime bytecode match the pinned deployment artifacts for every address.",
      sourcifyExactMatch: "Sourcify reproduced executable bytecode and compiler auxdata exactly.",
      sourcifyMatch: "Sourcify verified the source and executable bytecode after permitted compiler-auxdata transformations.",
    },
    checks,
  };
  await writeFile(path.resolve(options.report), `${JSON.stringify(report, null, 2)}\n`, "utf8");
  console.log(`${report.passed ? "PASS" : "BLOCKED"} V3 source publication: ${verified}/${checks.length}`);
  if (!report.passed) process.exitCode = 1;
}

await main();
