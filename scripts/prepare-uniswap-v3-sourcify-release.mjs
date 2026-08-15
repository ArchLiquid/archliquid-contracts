#!/usr/bin/env node

import { createHash } from "node:crypto";
import { createRequire } from "node:module";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";

const DEFAULT_RPC = "https://rpc.testnet.chain.robinhood.com";
const RELEASE_FILE = "deployments/robinhood-testnet-uniswap-v3-release.json";
const OPENZEPPELIN_SOURCES = [
  "proxy/Proxy.sol",
  "utils/Address.sol",
  "utils/Context.sol",
  "access/Ownable.sol",
  "proxy/ProxyAdmin.sol",
  "proxy/UpgradeableProxy.sol",
  "proxy/TransparentUpgradeableProxy.sol",
];

const CONTRACTS = [
  {
    id: "factory",
    referenceFile: "factory.json",
    artifact: "node_modules/@uniswap/v3-core/artifacts/contracts/UniswapV3Factory.sol/UniswapV3Factory.json",
    trimSources: true,
  },
  {
    id: "multicall2",
    referenceFile: "multicall2.json",
    artifact: "node_modules/@uniswap/v3-periphery/artifacts/contracts/lens/UniswapInterfaceMulticall.sol/UniswapInterfaceMulticall.json",
  },
  {
    id: "proxyAdmin",
    referenceFile: "proxyAdmin.json",
    artifact: "node_modules/@openzeppelin/contracts/build/contracts/ProxyAdmin.json",
    openzeppelinTarget: "contracts/proxy/ProxyAdmin.sol",
  },
  {
    id: "tickLens",
    referenceFile: "tickLens.json",
    artifact: "node_modules/@uniswap/v3-periphery/artifacts/contracts/lens/TickLens.sol/TickLens.json",
  },
  {
    id: "nftDescriptorLibrary",
    referenceFile: "nftDescriptorLibrary.json",
    artifact: "node_modules/v3-periphery-1_3_0/artifacts/contracts/libraries/NFTDescriptor.sol/NFTDescriptor.json",
    runtimeSelfAddress: true,
  },
  {
    id: "positionDescriptorImplementation",
    referenceFile: "positionDescriptorImplementation.json",
    artifact: "node_modules/v3-periphery-1_3_0/artifacts/contracts/NonfungibleTokenPositionDescriptor.sol/NonfungibleTokenPositionDescriptor.json",
    library: {
      source: "contracts/libraries/NFTDescriptor.sol",
      name: "NFTDescriptor",
      releaseKey: "nftDescriptorLibrary",
    },
  },
  {
    id: "positionDescriptorProxy",
    referenceFile: "positionDescriptorProxy.json",
    artifact: "node_modules/@openzeppelin/contracts/build/contracts/TransparentUpgradeableProxy.json",
    openzeppelinTarget: "contracts/proxy/TransparentUpgradeableProxy.sol",
  },
  {
    id: "positionManager",
    referenceFile: "positionManager.json",
    artifact: "node_modules/v3-periphery-1_3_0/artifacts/contracts/NonfungiblePositionManager.sol/NonfungiblePositionManager.json",
  },
  {
    id: "v3Migrator",
    referenceFile: "v3Migrator.json",
    artifact: "node_modules/v3-periphery-1_3_0/artifacts/contracts/V3Migrator.sol/V3Migrator.json",
  },
  {
    id: "v3Staker",
    referenceFile: "v3Staker.json",
    artifact: "node_modules/@uniswap/v3-staker/artifacts/contracts/UniswapV3Staker.sol/UniswapV3Staker.json",
  },
  {
    id: "quoterV2",
    referenceFile: "quoterV2.json",
    artifact: "node_modules/@uniswap/swap-router-contracts/artifacts/contracts/lens/QuoterV2.sol/QuoterV2.json",
  },
  {
    id: "swapRouter02",
    referenceFile: "swapRouter02.json",
    artifact: "node_modules/@uniswap/swap-router-contracts/artifacts/contracts/SwapRouter02.sol/SwapRouter02.json",
  },
];

function parseArgs(argv) {
  const options = {
    upstreamRoot: null,
    referenceDir: null,
    outputDir: null,
    parityReport: null,
    rpcUrl: DEFAULT_RPC,
    solc074Root: null,
  };
  const fields = new Map([
    ["--upstream-root", "upstreamRoot"],
    ["--reference-dir", "referenceDir"],
    ["--output-dir", "outputDir"],
    ["--parity-report", "parityReport"],
    ["--rpc-url", "rpcUrl"],
    ["--solc-074-root", "solc074Root"],
  ]);
  for (let index = 0; index < argv.length; index += 1) {
    const field = fields.get(argv[index]);
    if (!field) throw new Error(`Unknown argument: ${argv[index]}`);
    const value = argv[++index];
    if (!value || value.startsWith("--")) throw new Error(`${argv[index - 1]} requires a value`);
    options[field] = value;
  }
  for (const field of ["upstreamRoot", "referenceDir", "outputDir", "parityReport", "solc074Root"]) {
    if (!options[field]) throw new Error(`--${field.replace(/[A-Z]/g, (letter) => `-${letter.toLowerCase()}`)} is required`);
  }
  return options;
}

function normalizeHex(value, label) {
  if (typeof value !== "string") throw new Error(`${label} is not bytecode`);
  const prefixed = value.startsWith("0x") ? value : `0x${value}`;
  if ((prefixed.length - 2) % 2 !== 0) throw new Error(`${label} has an odd number of hexadecimal characters`);
  return prefixed.toLowerCase();
}

function flattenReferences(references) {
  if (!references || typeof references !== "object") return [];
  const result = [];
  for (const value of Object.values(references)) {
    if (Array.isArray(value)) result.push(...value);
    else result.push(...flattenReferences(value));
  }
  return result;
}

function replaceRanges(bytecode, ranges, replacement, label) {
  let hex = normalizeHex(bytecode, label).slice(2);
  for (const range of [...ranges].sort((left, right) => right.start - left.start)) {
    const start = Number(range.start) * 2;
    const length = Number(range.length) * 2;
    if (!Number.isSafeInteger(start) || !Number.isSafeInteger(length) || start < 0 || length < 2 || start + length > hex.length) {
      throw new Error(`${label} has an invalid reference range`);
    }
    const value = replacement(range);
    if (value.length !== length) throw new Error(`${label} replacement length does not match reference length`);
    hex = `${hex.slice(0, start)}${value}${hex.slice(start + length)}`;
  }
  return `0x${hex}`;
}

function maskReferences(bytecode, references, label) {
  return replaceRanges(bytecode, flattenReferences(references), (range) => "0".repeat(Number(range.length) * 2), label);
}

function linkArtifact(bytecode, references, address, label) {
  const ranges = flattenReferences(references);
  if (ranges.length === 0) return normalizeHex(bytecode, label);
  const value = address.toLowerCase().replace(/^0x/, "");
  return replaceRanges(bytecode, ranges, (range) => {
    if (Number(range.length) !== 20) throw new Error(`${label} contains a non-address link reference`);
    return value;
  }, label);
}

function targetOutput(reference) {
  const [sourcePath, contractName] = reference.compilation.fullyQualifiedName.split(":");
  const output = reference.stdJsonOutput?.contracts?.[sourcePath]?.[contractName];
  if (!output?.evm?.bytecode?.object || !output?.evm?.deployedBytecode?.object) {
    throw new Error(`${reference.compilation.fullyQualifiedName} has no complete compiler output`);
  }
  return { sourcePath, contractName, output };
}

async function openzeppelinCompilation(definition, upstreamRoot, solc074Root) {
  const sources = {};
  for (const source of OPENZEPPELIN_SOURCES) {
    sources[`contracts/${source}`] = {
      content: await readFile(path.join(
        upstreamRoot,
        "node_modules/@openzeppelin/contracts",
        source,
      ), "utf8"),
    };
  }
  const contractName = path.basename(definition.openzeppelinTarget, ".sol");
  const standardInput = {
    language: "Solidity",
    sources,
    settings: {
      metadata: { bytecodeHash: "ipfs" },
      libraries: {},
      optimizer: { runs: 200, enabled: false },
      evmVersion: "istanbul",
      remappings: [],
      outputSelection: {
        [definition.openzeppelinTarget]: {
          [contractName]: ["abi", "metadata", "evm.bytecode", "evm.deployedBytecode"],
        },
      },
    },
  };
  const require = createRequire(import.meta.url);
  const solc = require(path.join(path.resolve(solc074Root), "node_modules/solc"));
  if (!solc.version().startsWith("0.7.4+commit.3f05b770")) {
    throw new Error("--solc-074-root does not contain the required solc 0.7.4 compiler");
  }
  const compilation = JSON.parse(solc.compile(JSON.stringify(standardInput)));
  const errors = (compilation.errors ?? []).filter((entry) => entry.severity === "error");
  if (errors.length > 0) throw new Error(errors.map((entry) => entry.formattedMessage).join("\n"));
  const output = compilation.contracts?.[definition.openzeppelinTarget]?.[contractName];
  if (!output) throw new Error(`${definition.id} exact OpenZeppelin compilation target is missing`);
  return {
    sourcePath: definition.openzeppelinTarget,
    contractName,
    output,
    standardInput,
    compilerVersion: "0.7.4+commit.3f05b770",
  };
}

async function rpc(url, method, params) {
  const response = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
    signal: AbortSignal.timeout(30_000),
  });
  if (!response.ok) throw new Error(`${method} returned HTTP ${response.status}`);
  const payload = await response.json();
  if (payload.error) throw new Error(`${method} failed with code ${payload.error.code}`);
  return payload.result;
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function fileName(id) {
  return `${id}.standard-input.json`;
}

function importedSourceClosure(sources, entrypoint) {
  const selected = {};
  const pending = [entrypoint];
  const imports = /import\s+(?:(?:[^"']+)\s+from\s+)?["']([^"']+)["']\s*;/g;
  while (pending.length > 0) {
    const sourcePath = pending.pop();
    if (selected[sourcePath]) continue;
    const source = sources[sourcePath];
    if (!source) throw new Error(`missing imported source ${sourcePath}`);
    selected[sourcePath] = source;
    for (const match of source.content.matchAll(imports)) {
      const imported = match[1].startsWith(".")
        ? path.posix.normalize(path.posix.join(path.posix.dirname(sourcePath), match[1]))
        : match[1];
      pending.push(imported);
    }
  }
  return selected;
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const repositoryRoot = path.resolve(import.meta.dirname, "..");
  const release = JSON.parse(await readFile(path.join(repositoryRoot, RELEASE_FILE), "utf8"));
  const upstreamRoot = path.resolve(options.upstreamRoot);
  const referenceDir = path.resolve(options.referenceDir);
  const outputDir = path.resolve(options.outputDir);
  await mkdir(outputDir, { recursive: true });

  const payloads = [];
  const checks = [];
  for (const definition of CONTRACTS) {
    const artifactPath = path.join(upstreamRoot, definition.artifact);
    const artifact = JSON.parse(await readFile(artifactPath, "utf8"));
    const reference = JSON.parse(await readFile(path.join(referenceDir, definition.referenceFile), "utf8"));
    const exactCompilation = definition.openzeppelinTarget
      ? await openzeppelinCompilation(definition, upstreamRoot, options.solc074Root)
      : { ...targetOutput(reference), standardInput: reference.stdJsonInput, compilerVersion: reference.compilation.compilerVersion };
    const { sourcePath, contractName, output } = exactCompilation;
    if (artifact.contractName !== contractName || (artifact.sourceName && artifact.sourceName !== sourcePath)) {
      throw new Error(`${definition.id} reference target does not match the pinned package artifact`);
    }

    const artifactCreation = maskReferences(artifact.bytecode, artifact.linkReferences, `${definition.id} package creation`);
    const referenceCreation = maskReferences(output.evm.bytecode.object, output.evm.bytecode.linkReferences, `${definition.id} reference creation`);
    const artifactRuntime = maskReferences(artifact.deployedBytecode, artifact.deployedLinkReferences, `${definition.id} package runtime`);
    const referenceRuntime = maskReferences(output.evm.deployedBytecode.object, output.evm.deployedBytecode.linkReferences, `${definition.id} reference runtime`);
    if (artifactCreation !== referenceCreation || artifactRuntime !== referenceRuntime) {
      throw new Error(`${definition.id} public compilation input does not reproduce the pinned package artifact`);
    }

    const address = release.contracts[definition.id];
    const transactionHash = release.deploymentTransactions[definition.id];
    if (!address || !transactionHash) throw new Error(`${definition.id} is missing release deployment evidence`);
    const libraryAddress = definition.library ? release.contracts[definition.library.releaseKey] : null;
    const linkedCreation = linkArtifact(artifact.bytecode, artifact.linkReferences, libraryAddress, `${definition.id} creation`);
    const linkedRuntime = linkArtifact(artifact.deployedBytecode, artifact.deployedLinkReferences, libraryAddress, `${definition.id} runtime`);
    const [transaction, liveRuntime] = await Promise.all([
      rpc(options.rpcUrl, "eth_getTransactionByHash", [transactionHash]),
      rpc(options.rpcUrl, "eth_getCode", [address, "latest"]),
    ]);
    if (!transaction?.input || transaction.to !== null) throw new Error(`${definition.id} transaction is not a direct creation`);
    if (!transaction.input.toLowerCase().startsWith(linkedCreation)) {
      throw new Error(`${definition.id} creation transaction does not contain the pinned creation bytecode`);
    }
    const constructorArguments = `0x${transaction.input.slice(linkedCreation.length)}`.toLowerCase();
    const immutableReferences = output.evm.deployedBytecode.immutableReferences ?? {};
    const runtimeTransformations = [
      ...flattenReferences(immutableReferences),
      ...(definition.runtimeSelfAddress ? [{ start: 1, length: 20 }] : []),
    ];
    const maskedCompiledRuntime = replaceRanges(
      linkedRuntime,
      runtimeTransformations,
      (range) => "0".repeat(Number(range.length) * 2),
      `${definition.id} compiled runtime`,
    );
    const maskedLiveRuntime = replaceRanges(
      liveRuntime,
      runtimeTransformations,
      (range) => "0".repeat(Number(range.length) * 2),
      `${definition.id} live runtime`,
    );
    if (maskedCompiledRuntime !== maskedLiveRuntime) {
      throw new Error(`${definition.id} live runtime does not exactly match the pinned package outside compiler-declared immutables`);
    }

    const standardInput = structuredClone(exactCompilation.standardInput);
    if (definition.trimSources) {
      standardInput.sources = importedSourceClosure(standardInput.sources, sourcePath);
    }
    if (definition.library) {
      standardInput.settings.libraries ??= {};
      standardInput.settings.libraries[definition.library.source] ??= {};
      standardInput.settings.libraries[definition.library.source][definition.library.name] = libraryAddress;
    }
    const serialized = `${JSON.stringify(standardInput, null, 2)}\n`;
    const standardInputFile = fileName(definition.id);
    await writeFile(path.join(outputDir, standardInputFile), serialized, "utf8");

    payloads.push({
      id: definition.id,
      address,
      contractName,
      sourcePath,
      compilerVersion: exactCompilation.compilerVersion,
      encodedConstructorArguments: constructorArguments,
      standardInput: standardInputFile,
      standardInputSha256: sha256(serialized),
      sourceCount: Object.keys(standardInput.sources ?? {}).length,
    });
    checks.push({
      id: definition.id,
      address,
      contractName,
      artifactPath: definition.artifact,
      source: {
        compilerVersion: exactCompilation.compilerVersion,
        sourcePath,
        upstreamRepository: release.release.upstreamRepository,
        upstreamCommit: release.release.upstreamCommit,
        upstreamPackageVersion: release.release.upstreamPackageVersion,
      },
      packageCompilationParity: true,
      runtime: {
        match: true,
        metadataMatch: true,
        immutableReferenceCount: flattenReferences(immutableReferences).length,
        librarySelfAddressGuard: definition.runtimeSelfAddress === true,
        liveSha256: sha256(normalizeHex(liveRuntime, `${definition.id} live runtime`)),
      },
      creation: {
        match: true,
        metadataMatch: true,
        transactionHash,
        encodedConstructorArguments: constructorArguments,
        transactionInputSha256: sha256(normalizeHex(transaction.input, `${definition.id} transaction input`)),
      },
      parityPassed: true,
    });
    console.log(`PASS ${definition.id}: package, creation, and runtime parity`);
  }

  const index = {
    schemaVersion: 1,
    releaseId: release.release.id,
    generatedAt: new Date().toISOString(),
    submissionAuthorized: true,
    authorizationBasis: "Owner approved permanent public Sourcify publication in the release conversation on 2026-08-15.",
    payloadCount: payloads.length,
    payloads,
  };
  await writeFile(path.join(outputDir, "index.json"), `${JSON.stringify(index, null, 2)}\n`, "utf8");

  const report = {
    schemaVersion: 1,
    releaseId: release.release.id,
    checkedAt: new Date().toISOString(),
    rpc: "redacted-read-only-endpoint",
    passed: true,
    summary: { total: checks.length, passed: checks.length, blocked: 0 },
    checks,
  };
  await writeFile(path.resolve(options.parityReport), `${JSON.stringify(report, null, 2)}\n`, "utf8");
  console.log(`PASS canonical Uniswap V3 exact-bytecode parity: ${checks.length}/${checks.length}`);
}

await main();
