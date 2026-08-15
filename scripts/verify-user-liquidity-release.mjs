import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

const releases = [
  {
    id: "robinhood-testnet-v4-user-liquidity-2026-08-15-r1",
    manifest: "deployments/robinhood-testnet-v4-user-liquidity.json",
    approval: "deployments/robinhood-testnet-v4-user-liquidity.approval.json",
    parity: "docs/audit-evidence/robinhood-testnet-v4-user-liquidity-r1-bytecode.json",
    sourcify: "docs/audit-evidence/robinhood-testnet-v4-user-liquidity-r1-sourcify.json",
    module: "v4",
  },
];

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

function canonicalSourcePath(source) {
  if (/^lib\/(core|lockers|token)\/src\//.test(source)) return source;
  if (!source.startsWith("src/")) return null;
  const relative = source.slice("src/".length);
  if (relative === "ArchToken.sol") return "lib/token/src/ArchToken.sol";
  if (relative === "ArchLiquidityLocker.sol") return "lib/lockers/src/ArchLiquidityLocker.sol";
  if (relative === "ArchStockRegistry.sol") return "lib/core/src/ArchStockRegistry.sol";
  if (["interfaces/IArchStockSwapExecutor.sol", "interfaces/IUniswapV3.sol"].includes(relative)) {
    return join("lib/core/src", relative);
  }
  return join("lib/launchpad/src", relative);
}

// Published standard inputs may use relative imports while canonical modules
// use remappings for the same dependencies. Imports affect metadata, so the
// immutable inputs remain the exact publication evidence and this comparison
// proves the executable first-party source text is identical.
function withoutImports(source) {
  return source.split("\n").filter((line) => !line.trim().startsWith("import ")).join("\n");
}

function verifyApprovalSignature(manifest, approval) {
  const message = [
    "ArchLiquid user-liquidity manifest approval",
    `releaseId=${manifest.release.id}`,
    `chainId=${manifest.chainId}`,
    `manifestSha256=${approval.manifestSha256}`,
  ].join("\n");
  execFileSync(
    "cast",
    ["wallet", "verify", "--address", approval.signer, message, approval.signature],
    { stdio: "pipe" },
  );
}

function verifyPinnedModules() {
  const moduleLock = readJson("modules.lock.json");
  for (const moduleName of ["core", "lockers", "token", "launchpad"]) {
    const locked = moduleLock.modules.find(({ name }) => name === moduleName)?.commit;
    const checkedOut = execFileSync("git", ["-C", `lib/${moduleName}`, "rev-parse", "HEAD"], {
      encoding: "utf8",
    }).trim();
    assert(locked === checkedOut, `${moduleName} gitlink does not match modules.lock.json`);
  }
}

function verifyRelease(release) {
  const releaseDir = join("contract-verification", "releases", release.id);
  const manifest = readJson(release.manifest);
  const approval = readJson(release.approval);
  const index = readJson(join(releaseDir, "index.json"));
  const parity = readJson(release.parity);
  const sourcify = readJson(release.sourcify);

  assert(manifest.release.id === release.id, `${release.id}: manifest release ID mismatch`);
  assert(manifest.chainId === 46630, `${release.id}: manifest chain ID must be 46630`);
  assert(manifest.modules?.[release.module]?.status === "live", `${release.id}: module is not live`);
  assert(manifest.sourcePublication?.provider === "sourcify", `${release.id}: source provider mismatch`);
  assert(manifest.sourcePublication?.permanent === true, `${release.id}: source publication is not permanent`);
  assert(manifest.sourcePublication?.exactContracts === 7, `${release.id}: source publication is not exact 7/7`);
  assert(manifest.canary?.residueChecksPassed === true, `${release.id}: canary residue checks did not pass`);
  assert(manifest.verificationContracts.length === 7, `${release.id}: manifest must contain seven contracts`);
  assert(
    new Set(manifest.verificationContracts.map(({ id }) => id)).size === 7,
    `${release.id}: contract IDs must be unique`,
  );
  assert(
    new Set(manifest.verificationContracts.map(({ address }) => address.toLowerCase())).size === 7,
    `${release.id}: contract addresses must be unique`,
  );

  assert(approval.releaseId === release.id, `${release.id}: approval release ID mismatch`);
  assert(approval.manifestSha256 === canonicalDigest(manifest), `${release.id}: approval digest mismatch`);
  assert(sameAddress(approval.signer, manifest.release.releaseApprover), `${release.id}: signer mismatch`);
  assert(/^0x[0-9a-f]{130}$/i.test(approval.signature), `${release.id}: signature is malformed`);
  verifyApprovalSignature(manifest, approval);

  assert(index.releaseId === release.id, `${release.id}: source index release ID mismatch`);
  assert(index.submissionAuthorized === true, `${release.id}: source publication lacks authorization`);
  assert(index.payloadCount === 7 && index.payloads.length === 7, `${release.id}: source index must have seven payloads`);
  assert(parity.releaseId === release.id && parity.passed === true, `${release.id}: bytecode parity did not pass`);
  assert(parity.summary.passed === 7, `${release.id}: bytecode parity must pass 7/7`);
  assert(sourcify.releaseId === release.id && sourcify.passed === true, `${release.id}: Sourcify did not pass`);
  assert(sourcify.chainId === "46630" && sourcify.summary.exact === 7, `${release.id}: Sourcify must be exact 7/7`);

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

    const standardInputPath = join(releaseDir, payload.standardInput);
    const standardInputText = readFileSync(standardInputPath, "utf8");
    assert(sha256(standardInputText) === payload.standardInputSha256, `${contract.id}: payload digest mismatch`);
    const standardInput = JSON.parse(standardInputText);
    for (const [source, record] of Object.entries(standardInput.sources)) {
      const canonicalPath = canonicalSourcePath(source);
      if (!canonicalPath) continue;
      assert(existsSync(canonicalPath), `${contract.id}: canonical source missing at ${canonicalPath}`);
      assert(
        withoutImports(readFileSync(canonicalPath, "utf8")) === withoutImports(record.content),
        `${contract.id}: deployed source differs from canonical ${canonicalPath}`,
      );
      comparedSources += 1;
    }
  }

  console.log(
    `${release.id}: 7/7 bytecode, 7/7 Sourcify, valid signer, ${comparedSources} source comparisons.`,
  );
}

verifyPinnedModules();
for (const release of releases) verifyRelease(release);
