// End-to-end tests: spawn the packaged bin/fig.mjs exactly as npx would, and
// drive it against real temp files. This is what actually exercises the WASI
// rights-compatibility shim in bin/fig.mjs — a unit test that mocked
// node:wasi would miss the real bug (ENOTCAPABLE on every file open) that
// shim works around.
//
// Requires wasm/fig-wasi.wasm to already exist — run `npm run build` first
// (release.yml and prepublishOnly both do this before `npm test`).
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const bin = join(here, "..", "bin", "fig.mjs");

function run(args, opts = {}) {
  return execFileSync(process.execPath, [bin, ...args], { encoding: "utf8", ...opts });
}

function withTempDir(fn) {
  const dir = mkdtempSync(join(tmpdir(), "fig-wasi-"));
  try {
    fn(dir);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

test("version prints the core version", () => {
  const out = run(["version"]);
  assert.match(out.trim(), /^\d+\.\d+\.\d+$/);
});

test("get converts YAML to JSON", () => {
  withTempDir((dir) => {
    const file = join(dir, "test.yaml");
    writeFileSync(file, "name: fig\nport: 8080\n");
    const out = run(["get", "-o", "json", "test.yaml"], { cwd: dir });
    assert.deepEqual(JSON.parse(out), { name: "fig", port: 8080 });
  });
});

test("set edits a file in place, preserving the rest byte-for-byte", () => {
  withTempDir((dir) => {
    const file = join(dir, "test.yaml");
    writeFileSync(file, "# keep me\nname: fig\n");
    run(["set", "test.yaml", "port", "9090"], { cwd: dir });
    const contents = readFileSync(file, "utf8");
    assert.match(contents, /# keep me/);
    assert.match(contents, /port: 9090/);
  });
});

test("relative paths resolve from a subdirectory (the '.' preopen)", () => {
  withTempDir((dir) => {
    mkdirSync(join(dir, "sub"));
    writeFileSync(join(dir, "sub", "x.json"), '{"a":1}');
    const out = run(["get", "sub/x.json"], { cwd: dir });
    assert.deepEqual(JSON.parse(out), { a: 1 });
  });
});

test("check validates a file and exits 0", () => {
  withTempDir((dir) => {
    writeFileSync(join(dir, "ok.json"), "{}");
    assert.doesNotThrow(() => run(["check", "ok.json"], { cwd: dir }));
  });
});

test("a missing file exits non-zero with fig's own clean error, not a JS stack trace", () => {
  withTempDir((dir) => {
    try {
      run(["get", "nope.yaml"], { cwd: dir });
      assert.fail("expected a non-zero exit");
    } catch (err) {
      assert.equal(err.status, 1);
      assert.match(err.stderr.toString(), /error: FileNotFound/);
      assert.doesNotMatch(err.stderr.toString(), /at file:\/\//); // no raw JS stack trace
    }
  });
});

// Regression test: a command that never touches stdin (`version`) must not
// hang when stdin happens to be a pipe that's never written to or closed —
// e.g. an interactive shell whose own stdin is presented as a pipe rather
// than a raw TTY (common inside another program, an IDE-integrated
// terminal, tmux, ...). bin/fig.mjs used to eagerly drain any pipe-like
// stdin before starting the guest (to work around node:wasi's ESPIPE bug on
// non-seekable fds — see the "stdio compatibility shim" comment there), which
// hung forever whenever nothing ever closed that pipe. The fix gates the
// eager read on whether `-` was actually passed. `execFileSync` can't express
// this (it can't leave stdin open-but-unwritten while asserting on a
// timeout), hence the manual `spawn` + race here.
test("does not hang when stdin is an open pipe that is never closed and never needed", async () => {
  const child = spawn(process.execPath, [bin, "version"], { stdio: ["pipe", "pipe", "pipe"] });
  // Deliberately never write to or close child.stdin.
  let out = "";
  child.stdout.on("data", (d) => (out += d));
  try {
    const result = await Promise.race([
      new Promise((resolve) => child.on("exit", (code) => resolve({ code }))),
      new Promise((_, reject) => setTimeout(() => reject(new Error("timed out: hung waiting on unrelated stdin")), 5000)),
    ]);
    assert.equal(result.code, 0);
    assert.match(out.trim(), /^\d+\.\d+\.\d+$/);
  } finally {
    child.kill();
  }
});
