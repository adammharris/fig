// Build the fig CLI as a WASI module and vendor it into this package.
//
// Runs `zig build wasi` at the repository root — the same command
// release-binaries.yml uses to build the CLI's WASI artifact for GitHub
// Releases (full format parity with the native binaries; its
// optimize/strip settings are hardcoded in build.zig, so no -D flags are
// needed here) — then copies the result into wasm/fig-wasi.wasm.
//
// Unlike the sibling `@diaryx/fig` library package, this ships the
// module as a real file rather than inlining it as base64: there's no
// bundler to appease here, just a plain `fs.readFileSync` from bin/fig.mjs.
//
// Builds into its own `--prefix` (rather than the default zig-out/) so this
// doesn't collide with `bindings/typescript`'s `zig build wasm` output, or
// with `zig build wasi`'s own default output, when both are built from the
// same checkout.
import { execFileSync } from "node:child_process";
import { copyFileSync, mkdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, "..", "..", "..");
const pkgDir = resolve(here, "..");
const prefix = join(repoRoot, "zig-out", "wasi-npm");

console.error("· zig build wasi");
execFileSync("zig", ["build", "wasi", "--prefix", prefix], {
  cwd: repoRoot,
  stdio: "inherit",
});

const wasmSrc = join(prefix, "bin", "fig-wasi.wasm");
const wasmDestDir = join(pkgDir, "wasm");
mkdirSync(wasmDestDir, { recursive: true });
copyFileSync(wasmSrc, join(wasmDestDir, "fig-wasi.wasm"));
console.error("· wrote wasm/fig-wasi.wasm");
