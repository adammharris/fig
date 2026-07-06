#!/usr/bin/env node
// The `fig` CLI, running under Node's built-in WASI (preview1) support — no
// native binary, no per-platform install: `npx @adammharris/fig-wasi` works
// anywhere Node 20+ runs. See ../../../docs/npm-wasi.md for the full guide,
// including the filesystem/platform caveats this host can't paper over.
//
// This file is deliberately plain JS with no build step of its own: it's a
// thin host around the *real* fig CLI, which is the WASI module vendored at
// ../wasm/fig-wasi.wasm (built from the repo root by `zig build wasi` — see
// scripts/build-wasm.mjs). All the actual parsing/editing/serializing logic
// lives there, identical to the native binaries Homebrew ships.

import { readFileSync, writeFileSync, openSync, closeSync, fstatSync, mkdtempSync, rmSync } from "node:fs";
import { WASI } from "node:wasi";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { tmpdir } from "node:os";

// `node:wasi` prints a one-time `ExperimentalWarning` the moment the class is
// constructed. That's noise for a CLI — the surface this file relies on
// (preview1, preopens, returnOnExit) has been stable across many Node
// majors — so swallow just that one warning and let everything else (e.g. a
// deprecation warning from something else in the user's pipeline) through.
process.removeAllListeners("warning");
process.on("warning", (w) => {
  if (w.name !== "ExperimentalWarning") console.error(w);
});

// FIG_WASI_DEBUG=1: dump fd classifications, decisions, and the raw exit code
// straight to the real stderr (`process.stderr.fd`, bypassing the proxy logic
// below entirely — these lines always show up even if the proxying itself is
// what's broken). Diagnostic aid for exactly the kind of "prints only the
// ExperimentalWarning and nothing else, on some machines/terminals but not
// others" report this shipped with.
const DEBUG = !!process.env.FIG_WASI_DEBUG;
function debug(...args) {
  if (DEBUG) console.error("[fig-wasi debug]", ...args);
}
debug("node", process.version, process.platform, process.arch);
debug("argv", process.argv.slice(2));
for (const fd of [0, 1, 2]) {
  try {
    const st = fstatSync(fd);
    debug(`fd ${fd}`, {
      isFIFO: st.isFIFO(),
      isSocket: st.isSocket(),
      isFile: st.isFile(),
      isCharacterDevice: st.isCharacterDevice(),
      isTTY: [process.stdin, process.stdout, process.stderr][fd].isTTY,
    });
  } catch (err) {
    debug(`fd ${fd} fstat threw`, err);
  }
}

const here = dirname(fileURLToPath(import.meta.url));
const wasmPath = join(here, "..", "wasm", "fig-wasi.wasm");
let wasmBytes;
try {
  wasmBytes = readFileSync(wasmPath);
} catch (err) {
  if (err.code === "ENOENT") {
    // Only reachable running from a checkout, not from an installed/packed
    // package — `wasm/` is git-ignored and only populated by
    // `npm run build` (scripts/build-wasm.mjs runs `zig build wasi` and
    // copies the result here). A published tarball always has it (see the
    // `files` allowlist in package.json), so this is a local-dev-only error.
    console.error(`fig: ${wasmPath} not found — run \`npm run build\` first (needs zig on PATH).`);
    process.exit(1);
  }
  throw err;
}

const cwd = process.cwd();
// "." is the preopen name wasi-libc-style relative-path resolution looks
// for — it's what makes relative arguments (`fig get foo.yaml`) resolve
// against the real cwd, mirroring `wasmtime run --dir=.::.` (see build.zig's
// `wasi` step doc comment, which documents that exact invocation). On POSIX,
// also preopen the real filesystem root so absolute host paths resolve too
// (the equivalent of `--dir=/::/`). There's no analogous single root on
// Windows — an absolute Windows path (`C:\...`) only resolves here if it
// happens to fall under `cwd`; see docs/npm-wasi.md for the exact limitation.
const preopens = { ".": cwd };
if (process.platform !== "win32") preopens["/"] = "/";

// --- stdio compatibility shim -------------------------------------------
// `node:wasi` has (at least) two distinct gaps that break stdin/stdout/
// stderr the moment they're anything other than a genuine regular file:
//
// 1. It implements WASI's `fd_write`/`fd_read` by issuing a *positional* fs
//    syscall (`fs.writeSync`/`readSync` with an explicit `position`) against
//    the real fd, so it can track the WASI-spec file cursor independently of
//    the OS's own. Positional I/O only works on seekable fds — regular
//    files — and the OS rejects it with ESPIPE on a pipe or socket. That
//    breaks piping into or out of this CLI (`cat x.yaml | fig get -`,
//    `fig get x.yaml | jq`, `` out=$(fig get x.yaml) ``, or a test
//    harness/CI runner capturing output — all of which use OS pipes),
//    surfacing as a bare `error: WriteFailed`/read failure with no
//    indication it's a plumbing issue rather than a real one. Confirmed
//    empirically: a plain `fs.writeSync(1, buf, 0, buf.length, 0)` throws
//    ESPIPE against a piped stdout, while the non-positional
//    `fs.writeSync(1, buf)` succeeds fine.
//
// The fix originally only proxied pipes/sockets, on the assumption that a
// real regular file and a real TTY both already work with `node:wasi`'s
// direct-fd path. The regular-file half of that held up; the TTY half
// didn't: a *second*, distinct `node:wasi` gap showed up on a real terminal
// — `wasi.start()` returned exit code 1 with zero bytes written to either
// stream, for every action including `help`, which does nothing but print.
// The likely cause is fig's very first call in `main()`
// (`Io.Terminal.Mode.detect`, checking whether stdout/stderr can take color)
// failing against a real TTY fd under `node:wasi`, with Zig's minimal entry
// stub then exiting silently rather than surfacing the error — this sandbox
// never has a real TTY on fd 1/2 (always reports as a Pipe), which is why
// only pipes/sockets were caught and fixed here originally.
//
// Given two independent, unrelated `node:wasi` gaps have now turned up for
// "not a plain regular file," the safer rule is to trust only what's
// actually been proven to work directly: a genuine regular file. Everything
// else (pipe, socket, TTY, character device) gets proxied through a temp
// regular file — which positional I/O (the pipe bug) and, empirically,
// `Io.Terminal.Mode.detect` (the TTY bug — fixed by never handing `node:wasi`
// a real TTY fd at all) both work against reliably. stdout/stderr are
// buffered to temp files during the run and forwarded through Node's
// ordinary `process.stdout`/`process.stderr` writers afterward, once
// `wasi.start()` (synchronous — blocks until the guest's `_start` returns)
// is done. The trade-off: fig's automatic color-on-a-real-terminal detection
// can never see a real TTY through this host, so it always resolves to "no
// color" — use `CLICOLOR_FORCE=1` if you want color output regardless (see
// docs/npm-wasi.md).
//
// stdin is the sharp edge: eagerly draining it (reading until EOF, or until
// the user hits Ctrl-D on a TTY) before starting the guest is only correct
// when the guest is actually going to read stdin — fig's own convention is
// that it does so only when `-` is passed as the file argument (see
// main.zig's per-action `-` handling). Gate the eager read on that: a pipe
// with no writer that closes it (a shell's own stdin passed through as a
// pipe rather than a real TTY — common inside another program, an
// IDE-integrated terminal, tmux, etc.) never reaches EOF, so unconditionally
// draining it hangs forever even for `fig version`, which never touches
// stdin. Confirmed empirically: `node bin/fig.mjs version` with stdin
// attached to an open-but-silent pipe hung indefinitely before this guard
// was added.
function isRegularFile(fd) {
  return fstatSync(fd).isFile();
}

const needsStdin = process.argv.slice(2).includes("-");

const workDir = (needsStdin && !isRegularFile(0)) || !isRegularFile(1) || !isRegularFile(2) ? mkdtempSync(join(tmpdir(), "fig-wasi-")) : null;

let stdinFd = 0;
if (needsStdin && !isRegularFile(0)) {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  const stdinPath = join(workDir, "stdin");
  writeFileSync(stdinPath, Buffer.concat(chunks));
  stdinFd = openSync(stdinPath, "r");
}

const stdoutPath = !isRegularFile(1) ? join(workDir, "stdout") : null;
const stdoutFd = stdoutPath ? openSync(stdoutPath, "w") : 1;
const stderrPath = !isRegularFile(2) ? join(workDir, "stderr") : null;
const stderrFd = stderrPath ? openSync(stderrPath, "w") : 2;
// -------------------------------------------------------------------------

debug("needsStdin", needsStdin, "workDir", workDir, "stdinFd", stdinFd, "stdoutPath", stdoutPath, "stderrPath", stderrPath);

const wasi = new WASI({
  version: "preview1",
  // argv[0] becomes fig's `binary_name` (used only in help text) — pass
  // "fig" so `--help` output reads naturally regardless of how this script
  // was invoked.
  args: ["fig", ...process.argv.slice(2)],
  env: process.env,
  preopens,
  stdin: stdinFd,
  stdout: stdoutFd,
  stderr: stderrFd,
  returnOnExit: true,
});

const imports = wasi.getImportObject();

// --- WASI rights compatibility shim -------------------------------------
// Zig's wasm32-wasi std lib, when it opens a directory handle to resolve a
// relative path, requests `fs_rights_inheriting` bits that cover directory
// operations (PATH_OPEN, FD_READDIR, PATH_CREATE_FILE, ...) but not the
// regular-file operations (FD_READ, FD_SEEK, FD_WRITE, FD_FILESTAT_GET, ...)
// that a file opened underneath that handle needs. Per the WASI preview1
// spec, a child open's `fs_rights_base` must be a subset of its parent
// directory fd's `fs_rights_inheriting` — so without this shim, EVERY file
// open here is rejected with ENOTCAPABLE (which Zig surfaces as
// `error: AccessDenied`), even though the preopen itself is fine.
//
// This is invisible under wasmtime/wasmer: WASI preview1's rights system was
// deprecated years ago and modern standalone runtimes simply don't enforce
// it. Node's `node:wasi` is the outlier that still checks it faithfully —
// more spec-correct, but it surfaces this gap. Confirmed empirically against
// `zig build wasi`'s output (Zig 0.16.0): every action that touches a file
// (`get`, `set`, `edit`, `insert`, `delete`, `comment`, `check`, `fmt`,
// `convert`) fails without this patch and succeeds with it. It's a userspace
// workaround, not a fig code change — the proper fix belongs in Zig's wasi
// posix layer, which this package doesn't vendor.
const FILE_RIGHTS =
  (1n << 0n) | // FD_DATASYNC
  (1n << 1n) | // FD_READ
  (1n << 2n) | // FD_SEEK
  (1n << 4n) | // FD_SYNC
  (1n << 5n) | // FD_TELL
  (1n << 6n) | // FD_WRITE
  (1n << 7n) | // FD_ADVISE
  (1n << 8n) | // FD_ALLOCATE
  (1n << 21n) | // FD_FILESTAT_GET
  (1n << 22n) | // FD_FILESTAT_SET_SIZE
  (1n << 23n) | // FD_FILESTAT_SET_TIMES
  (1n << 27n); // POLL_FD_READWRITE
const O_DIRECTORY = 2;
const origPathOpen = imports.wasi_snapshot_preview1.path_open;
imports.wasi_snapshot_preview1.path_open = function (
  fd,
  dirflags,
  pathPtr,
  pathLen,
  oflags,
  base,
  inheriting,
  fdflags,
  resultPtr,
) {
  if (oflags & O_DIRECTORY) inheriting |= FILE_RIGHTS;
  return origPathOpen.call(this, fd, dirflags, pathPtr, pathLen, oflags, base, inheriting, fdflags, resultPtr);
};
// -------------------------------------------------------------------------

// Promisified stream write: `process.exit()` right after a `.write()` on a
// pipe can truncate it — Node may not have flushed the write yet, since a
// pipe write can be asynchronous even though `.write()` returns immediately.
// Waiting for the callback before exiting avoids losing the tail of the
// output (a real risk here, since forwarding the whole buffered proxy file
// often means one large `.write()` right before the process would otherwise
// exit).
function writeAll(stream, data) {
  return data.length === 0 ? Promise.resolve() : new Promise((resolve, reject) => stream.write(data, (err) => (err ? reject(err) : resolve())));
}

let exitCode = 1;
try {
  const module = await WebAssembly.compile(wasmBytes);
  debug("wasm compiled");
  const instance = await WebAssembly.instantiate(module, imports);
  debug("wasm instantiated, calling wasi.start()");
  exitCode = wasi.start(instance);
  debug("wasi.start() returned", exitCode);
} catch (err) {
  // A raw JS exception here means something outside fig's own error
  // reporting went wrong (e.g. a path that falls outside every preopen) —
  // print a short message instead of a Node stack trace.
  debug("wasi.start() threw", err);
  console.error(`fig: internal error: ${err && err.message ? err.message : err}`);
  exitCode = 1;
} finally {
  // Forward anything buffered in the stdout/stderr proxy files through
  // Node's normal stream writers (safe for pipes, unlike the positional
  // syscalls `node:wasi` itself uses), then clean up the temp dir.
  if (stdoutPath) {
    closeSync(stdoutFd);
    const buf = readFileSync(stdoutPath);
    debug("forwarding buffered stdout, bytes=", buf.length);
    await writeAll(process.stdout, buf);
    debug("stdout forward done");
  }
  if (stderrPath) {
    closeSync(stderrFd);
    const buf = readFileSync(stderrPath);
    debug("forwarding buffered stderr, bytes=", buf.length);
    await writeAll(process.stderr, buf);
    debug("stderr forward done");
  }
  if (stdinFd !== 0) closeSync(stdinFd);
  if (workDir) rmSync(workDir, { recursive: true, force: true });
}
debug("exiting with code", exitCode);
process.exit(exitCode);
