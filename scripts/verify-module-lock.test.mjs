import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import test from "node:test";

import { verifyModuleLock } from "./verify-module-lock.mjs";

function git(root, ...args) {
  return execFileSync("git", ["-C", root, ...args], {
    encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], windowsHide: true,
  }).trim();
}

function commit(root, message) {
  git(root, "-c", "user.name=Module lock fixture", "-c", "user.email=fixture@example.invalid",
    "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", message);
  return git(root, "rev-parse", "HEAD");
}

function createRepository(root, label) {
  mkdirSync(root, { recursive: true });
  git(root, "init", "--quiet");
  git(root, "config", "core.longpaths", "true");
  writeFileSync(join(root, "fixture.txt"), `${label}\n`);
  git(root, "add", "fixture.txt");
  return commit(root, label);
}

function fixture(t) {
  const temporaryRoot = realpathSync(tmpdir());
  const root = mkdtempSync(join(temporaryRoot, "archliquid-module-lock-"));
  t.after(() => {
    assert.equal(dirname(realpathSync(root)), temporaryRoot, "Fixture cleanup must stay in the temporary directory");
    rmSync(root, { recursive: true, force: true });
  });
  createRepository(root, "workspace");
  const modules = ["core", "lockers", "token", "launchpad", "vesting", "staking", "lending"].map((name) => ({
    name, path: `lib/${name}`, repository: `https://github.com/ArchLiquid/archliquid-${name}.git`,
    commit: createRepository(join(root, "lib", name), name),
  }));
  const dependencies = ["forge-std", "openzeppelin-contracts"].map((name) => ({
    name, path: `lib/${name}`, repository: `https://example.invalid/${name}.git`,
    commit: createRepository(join(root, "lib", name), name),
  }));
  const compound = {
    name: "compound-protocol", path: "lib/lending/lib/compound-protocol",
    repository: "https://example.invalid/compound-protocol.git",
    commit: createRepository(join(root, "lib", "lending", "lib", "compound-protocol"), "compound"),
  };
  const lending = modules.find(({ name }) => name === "lending");
  git(join(root, lending.path), "update-index", "--add", "--cacheinfo", `160000,${compound.commit},lib/compound-protocol`);
  lending.commit = commit(join(root, lending.path), "Pin nested Compound");
  for (const entry of [...modules, ...dependencies]) {
    git(root, "update-index", "--add", "--cacheinfo", `160000,${entry.commit},${entry.path}`);
  }
  dependencies.push(compound);
  const lock = { schemaVersion: 1, modules, dependencies };
  const save = () => writeFileSync(join(root, "modules.lock.json"), `${JSON.stringify(lock, null, 2)}\n`);
  save();
  return { root, lock, save };
}

test("accepts all seven modules and three dependencies, including nested Compound", (t) => {
  const { root } = fixture(t);
  assert.deepEqual(verifyModuleLock(root), { modules: 7, dependencies: 3 });
});

test("rejects lock drift in every first-party module", (t) => {
  const { root, lock, save } = fixture(t);
  for (const entry of lock.modules) {
    const original = entry.commit;
    entry.commit = "0".repeat(40);
    save();
    assert.throws(() => verifyModuleLock(root), new RegExp(`${entry.name}: gitlink does not match`));
    entry.commit = original;
  }
  save();
  assert.doesNotThrow(() => verifyModuleLock(root));
});

test("rejects lock drift in both shared dependencies and nested Compound", (t) => {
  const { root, lock, save } = fixture(t);
  for (const entry of lock.dependencies) {
    const original = entry.commit;
    entry.commit = "0".repeat(40);
    save();
    assert.throws(() => verifyModuleLock(root), new RegExp(`${entry.name}: gitlink does not match`));
    entry.commit = original;
  }
});

test("rejects checkout drift even when the lock and gitlink agree", (t) => {
  const { root, lock } = fixture(t);
  for (const entry of [lock.modules.find(({ name }) => name === "staking"), lock.dependencies.at(-1)]) {
    const checkout = join(root, entry.path);
    writeFileSync(join(checkout, "fixture.txt"), "unexpected checkout\n");
    git(checkout, "add", "fixture.txt");
    commit(checkout, "Move checkout without changing the parent gitlink");
    assert.throws(() => verifyModuleLock(root), new RegExp(`${entry.name}: checkout does not match`));
    git(checkout, "checkout", "--quiet", entry.commit);
  }
});

test("rejects gitlink drift even when the lock and checkout agree", (t) => {
  const { root, lock } = fixture(t);
  const staking = lock.modules.find(({ name }) => name === "staking");
  git(root, "update-index", "--cacheinfo", `160000,${lock.modules[0].commit},${staking.path}`);
  assert.throws(() => verifyModuleLock(root), /staking: gitlink does not match/);
});

test("rejects an omitted direct module or shared dependency", (t) => {
  const { root, lock, save } = fixture(t);
  for (const entries of [lock.modules, lock.dependencies]) {
    const removed = entries.shift();
    save();
    assert.throws(() => verifyModuleLock(root), /gitlink is missing from modules.lock.json/);
    entries.unshift(removed);
  }
});

test("rejects duplicate entries, unsafe paths and abbreviated commits", (t) => {
  const { root, lock, save } = fixture(t);
  lock.modules.push({ ...lock.modules[0] });
  save();
  assert.throws(() => verifyModuleLock(root), /duplicate lock entry/);
  lock.modules.pop();
  const entry = lock.modules[0];
  const originalPath = entry.path;
  for (const path of ["../outside", "lib/../outside", "lib/core/", "C:/outside"]) {
    entry.path = path;
    save();
    assert.throws(() => verifyModuleLock(root), /invalid submodule path/);
  }
  entry.path = originalPath;
  entry.commit = entry.commit.slice(0, 7);
  save();
  assert.throws(() => verifyModuleLock(root), /expected a full commit SHA/);
});

test("rejects an uninitialized submodule instead of reading the parent HEAD", (t) => {
  const { root, lock, save } = fixture(t);
  mkdirSync(join(root, "lib", "uninitialized"));
  const entry = { name: "uninitialized", path: "lib/uninitialized", commit: git(root, "rev-parse", "HEAD") };
  git(root, "update-index", "--add", "--cacheinfo", `160000,${entry.commit},${entry.path}`);
  lock.modules.push(entry);
  save();
  assert.throws(() => verifyModuleLock(root), /uninitialized: submodule is not initialized/);
});
