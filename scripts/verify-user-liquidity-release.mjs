import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

const RELEASE_ID = "robinhood-testnet-user-liquidity-2026-08-14-r1";
const RELEASE_DIR = join("contract-verification", "releases", RELEASE_ID);

const readJson = (path) => JSON.parse(readFileSync(path, "utf8"));
const sha256 = (value) => createHash("sha256").update(value).digest("hex");
const sameAddress = (left, right) =>
  typeof left === "string"
  && typeof right === "string"
  && left.toLowerCase() === right.toLowerCase();

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function canonicalize(value) {
  if (Array.isArray(value)) return value.map(canonicalize);
  if (value !== null && typeof value === "object") {
    return Object.fromEntries(
      Object.keys(value).sort().map((key) => [key, canonicalize(value[key])]),
    );
  }
  return value;
}

function canonicalDigest(value) {
  return sha256(JSON.stringify(canonicalize(value)));
}

function sourcePath(source) {
  const relative = source.slice("src/".length);
  if (relative === "ArchToken.sol") return "lib/token/src/ArchToken.sol";
  if (relative === "ArchLiquidityLocker.sol") return "lib/lockers/src/ArchLiquidityLocker.sol";
  if (relative === "ArchStockRegistry.sol") return "lib/core/src/ArchStockRegistry.sol";
  if (["interfaces/IArchStockSwapExecutor.sol", "interfaces/IUniswapV3.sol"].includes(relative)) {
    return join("lib/core/src", relative);
  }
  return join("lib/launchpad/src", relative);
}

// The mined monorepo build used relative imports. Canonical module repositories
// use remapped imports for the same dependencies. Imports affect Solidity
// metadata, so the exact mined standard inputs remain immutable publication
// evidence while this comparison proves all executable source text is identical.
function withoutImports(source) {
  return source.split("\n").filter((line) => !line.trim().startsWith("import ")).join("\n");
}

const manifest = readJson("deployments/robinhood-testnet-user-liquidity.json");
const approval = readJson("deployments/robinhood-testnet-user-liquidity.approval.json");
const moduleLock = readJson("modules.lock.json");
const index = readJson(join(RELEASE_DIR, "index.json"));
const parity = readJson("docs/audit-evidence/robinhood-testnet-user-liquidity-r1-bytecode.json");
const sourcify = readJson("docs/audit-evidence/robinhood-testnet-user-liquidity-r1-sourcify.json");

assert(manifest.release.id === RELEASE_ID, "manifest release ID mismatch");
assert(manifest.chainId === 46630, "manifest chain ID must be 46630");
assert(manifest.verificationContracts.length === 7, "manifest must contain exactly seven contracts");
assert(new Set(manifest.verificationContracts.map(({ id }) => id)).size === 7, "contract IDs must be unique");
assert(
  new Set(manifest.verificationContracts.map(({ address }) => address.toLowerCase())).size === 7,
  "contract addresses must be unique",
);
assert(approval.releaseId === RELEASE_ID, "approval release ID mismatch");
assert(approval.manifestSha256 === canonicalDigest(manifest), "approval manifest digest mismatch");
assert(sameAddress(approval.signer, manifest.release.releaseApprover), "approval signer mismatch");
assert(/^0x[0-9a-f]{130}$/i.test(approval.signature), "approval signature is malformed");

for (const moduleName of ["token", "launchpad"]) {
  const locked = moduleLock.modules.find(({ name }) => name === moduleName)?.commit;
  const checkedOut = execFileSync("git", ["-C", `lib/${moduleName}`, "rev-parse", "HEAD"], {
    encoding: "utf8",
  }).trim();
  assert(locked === checkedOut, `${moduleName} gitlink does not match modules.lock.json`);
}

assert(index.releaseId === RELEASE_ID, "source index release ID mismatch");
assert(index.submissionAuthorized === true, "source publication lacks explicit authorization");
assert(index.payloadCount === 7 && index.payloads.length === 7, "source index must contain seven payloads");
assert(parity.releaseId === RELEASE_ID && parity.passed === true, "bytecode parity report did not pass");
assert(parity.summary.passed === 7, "bytecode parity report must pass 7/7");
assert(sourcify.releaseId === RELEASE_ID && sourcify.passed === true, "Sourcify report did not pass");
assert(sourcify.chainId === "46630" && sourcify.summary.exact === 7, "Sourcify report must be exact 7/7");

const parityById = new Map(parity.checks.map((entry) => [entry.id, entry]));
const sourcifyById = new Map(sourcify.results.map((entry) => [entry.id, entry]));
const payloadById = new Map(index.payloads.map((entry) => [entry.id, entry]));
let comparedSources = 0;

for (const contract of manifest.verificationContracts) {
  const parityEntry = parityById.get(contract.id);
  const sourcifyEntry = sourcifyById.get(contract.id);
  const payload = payloadById.get(contract.id);
  assert(sameAddress(parityEntry?.address, contract.address), `${contract.id}: parity address mismatch`);
  assert(parityEntry?.parityPassed === true, `${contract.id}: creation/runtime bytecode did not match`);
  assert(sameAddress(sourcifyEntry?.address, contract.address), `${contract.id}: Sourcify address mismatch`);
  assert(sourcifyEntry?.after?.contract?.creationMatch === "exact_match", `${contract.id}: creation match not exact`);
  assert(sourcifyEntry?.after?.contract?.runtimeMatch === "exact_match", `${contract.id}: runtime match not exact`);
  assert(sameAddress(payload?.address, contract.address), `${contract.id}: source payload address mismatch`);

  const standardInputPath = join(RELEASE_DIR, payload.standardInput);
  const standardInputText = readFileSync(standardInputPath, "utf8");
  assert(sha256(standardInputText) === payload.standardInputSha256, `${contract.id}: source payload digest mismatch`);
  const standardInput = JSON.parse(standardInputText);
  for (const [source, record] of Object.entries(standardInput.sources)) {
    if (!source.startsWith("src/")) continue;
    const canonicalPath = sourcePath(source);
    assert(existsSync(canonicalPath), `${contract.id}: canonical source missing at ${canonicalPath}`);
    assert(
      withoutImports(readFileSync(canonicalPath, "utf8")) === withoutImports(record.content),
      `${contract.id}: deployed source differs from canonical ${canonicalPath}`,
    );
    comparedSources += 1;
  }
}

console.log(
  `User-liquidity release gate passed: 7/7 bytecode, 7/7 Sourcify, ${comparedSources} canonical source comparisons.`,
);
