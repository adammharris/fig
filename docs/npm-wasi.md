```fig
title = fig CLI via npm/npx
author = adammharris
created = 2026-07-06
updated = 2026-07-06
part_of = [docs](docs.md)
```

# `fig` CLI via npm / npx (experimental)

> **Experimental.** This package is new, its underlying approach (running a
> WASI module through Node's own — separately, officially experimental —
> `node:wasi` support) has needed several non-obvious compatibility shims to
> work at all (see [Known limitations](#known-limitations)), and its
> interface may still change. For anything beyond a quick one-off or CI use,
> prefer a native install (Homebrew, a downloaded release binary, `cargo
> install`) — see [the main CLI docs](/fig.md#command-line-interface).

`@adammharris/fig-wasi` runs the real `fig` command-line tool — the same
`get`/`set`/`edit`/`insert`/`delete`/`comment`/`check`/`fmt`/`convert` actions
the native binary has — with **no install step, no per-platform binary, and no
native build**. It ships a single WASI (WebAssembly System Interface) module
and runs it under Node's built-in WASI support, so `npx` works anywhere Node
20+ does: Linux, macOS, Windows, CI containers, wherever.

If you already have `fig` installed natively (Homebrew, a downloaded release
binary, `cargo install`, ...), you don't need this package — use the real
binary. This exists for the zero-install case: a one-off in a shell script, a
CI pipeline that already has Node but not `fig`, or trying it out without
committing to an install.

## Install

Nothing to install — just run it:

```sh
npx @adammharris/fig-wasi get config.yaml
```

`npx` fetches the package, and because it declares a single `bin` (`fig`),
runs that command directly — you don't need `npx --package=... fig`. If you'd
rather have `fig` on your `PATH` permanently:

```sh
npm install -g @adammharris/fig-wasi
fig get config.yaml
```

Requires Node 20+.

## Usage

Same CLI, same actions, same flags as the native binary — see `fig help` and
`fig <action> --help` for the full reference:

```sh
npx @adammharris/fig-wasi get config.yaml
npx @adammharris/fig-wasi get -o json config.toml
npx @adammharris/fig-wasi set config.yaml server.port 9090
npx @adammharris/fig-wasi check config.yaml
npx @adammharris/fig-wasi fmt --dry-run config.yaml
```

Set `FIG_WASI_DEBUG=1` to print diagnostics (fd classifications, internal
decisions, exit code) to stderr — useful if something behaves differently on
your machine than expected; see
[bin/fig.mjs](/bindings/wasi/bin/fig.mjs).

## How it works

`zig build wasi` compiles the exact same `fig` CLI source to a WASI preview1
module (a real `_start` command, not a library) — the same artifact
attached to GitHub Releases for use with `wasmtime`/`wasmer`. This package
vendors that module and runs it with Node's built-in `node:wasi`, wiring
`argv`, `env`, and stdio straight through so piping and redirection behave
exactly like the native binary.

## Known limitations

Running a real filesystem CLI inside a WASI sandbox hosted by Node has some
real sharp edges — several of them not merely theoretical, but bugs that took
real debugging to find:

- **Absolute paths on Windows** are not resolved. WASI paths are POSIX-style;
  there's no single filesystem root to preopen the way POSIX gets `/`. Only
  paths under the current working directory are guaranteed to work on
  Windows. On macOS/Linux, both relative and absolute paths work.
- **No TTY detection — output is always treated as "not a terminal."** This
  is deliberate, not just a missing feature: handing `node:wasi` a real TTY
  fd directly causes `fig`'s own terminal/color detection to fail outright
  (confirmed empirically — every action exited non-zero with zero output when
  run directly in a real terminal, before this was worked around), so this
  package always proxies stdin/stdout/stderr through temp regular files
  unless they're already a plain regular file — which as a side effect means
  `fig` can never see a real TTY through this host. Use `CLICOLOR_FORCE=1` if
  you want color output regardless; `NO_COLOR=1` is a no-op either way since
  color is already off by default here.
- **Piping was broken without a second workaround.** `node:wasi` implements
  reads/writes via a positional fs syscall, which the OS rejects on a pipe or
  socket — so piping into or out of this CLI, or a test harness/CI runner
  capturing output, failed outright until this package started proxying
  those through temp files too.
- **Node's WASI support is officially "Experimental"** (Node's own stability
  index, independent of this package's own experimental status). The surface
  this package relies on — `preview1`, `preopens`, `returnOnExit` — has been
  stable across many Node majors; this package suppresses the one-time
  `ExperimentalWarning` Node prints so it doesn't clutter normal use.
- **Slower cold start than the native binary.** Every invocation compiles the
  WASI module fresh (no persistent process) — fine for occasional/CI use,
  not a reason to replace a natively-installed `fig` for heavy scripting.
- Not a security sandbox: don't rely on this to run untrusted config files
  from an untrusted source and expect isolation guarantees beyond "no
  network/thread/socket access" — Node's own WASI documentation is explicit
  that its filesystem sandboxing is not a hard security boundary.

Given how many of the above turned out to be real, previously-undocumented
`node:wasi` gaps rather than things this package could simply configure
around, treat this package itself as experimental too, not just its
dependencies — future Node versions, or WASI programs with different I/O
patterns than fig's, may surface more.

## See also

- [The Zig CLI / library](/fig.md) — install via Homebrew or a release binary.
- [fig in TypeScript](typescript.md) — the `@adammharris/fig` *library*
  package (parse/edit/serialize as a JS API), not a CLI.
