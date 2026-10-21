import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync, realpathSync } from "node:fs";
import { dirname, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const repositoryRoot = fileURLToPath(new URL("../", import.meta.url));

function git(root, args) {
  return execFileSync("git", ["-C", root, ...args], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    windowsHide: true,
  }).trim();
}

function gitlinks(root) {
  return new Map(git(root, ["ls-files", "--stage", "-z"]).split("\0").flatMap((entry) => {
    const match = /^160000 ([0-9a-f]{40}) 0\t(.+)$/.exec(entry);
    return match ? [[match[2], match[1]]] : [];
  }));
}

/** Check every locked module/dependency against both its gitlink and checkout. */
export function verifyModuleLock(root = repositoryRoot) {
  const lock = JSON.parse(readFileSync(resolve(root, "modules.lock.json"), "utf8"));
  assert.equal(lock.schemaVersion, 1, "Unsupported module lock schema");
  assert.ok(Array.isArray(lock.modules) && Array.isArray(lock.dependencies), "Missing module/dependency lists");
  const entries = [...lock.modules, ...lock.dependencies];
  const paths = new Set();
  const names = new Set();
  for (const entry of entries) {
    assert.ok(typeof entry.name === "string" && entry.name.length > 0, "Missing module/dependency name");
    assert.ok(typeof entry.path === "string" && /^lib\/(?:[A-Za-z0-9_-]+\/)*[A-Za-z0-9_-]+$/.test(entry.path),
      `${entry.name}: invalid submodule path`);
    assert.ok(typeof entry.commit === "string" && /^[0-9a-f]{40}$/.test(entry.commit),
      `${entry.name}: expected a full commit SHA`);
    assert.ok(!paths.has(entry.path) && !names.has(entry.name), `${entry.name}: duplicate lock entry`);
    paths.add(entry.path);
    names.add(entry.name);
  }
  for (const path of gitlinks(root).keys()) {
    assert.ok(paths.has(path), `${path}: gitlink is missing from modules.lock.json`);
  }
  for (const entry of entries) {
    const checkout = resolve(root, entry.path);
    const actualRoot = git(checkout, ["rev-parse", "--show-toplevel"]);
    assert.equal(realpathSync(actualRoot), realpathSync(checkout),
      `${entry.name}: submodule is not initialized`);
    const parentRoot = git(dirname(checkout), ["rev-parse", "--show-toplevel"]);
    const pathInParent = relative(parentRoot, checkout).split(sep).join("/");
    assert.equal(gitlinks(parentRoot).get(pathInParent), entry.commit,
      `${entry.name}: gitlink does not match modules.lock.json`);
    assert.equal(git(checkout, ["rev-parse", "HEAD"]), entry.commit,
      `${entry.name}: checkout does not match modules.lock.json`);
  }
  return { modules: lock.modules.length, dependencies: lock.dependencies.length };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const result = verifyModuleLock();
    console.log(`Module lock verified: ${result.modules} modules and ${result.dependencies} dependencies.`);
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
