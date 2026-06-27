---
title: VERSIONING
description: Versioning policy for `fig`
author: adammharris
date: 2026-06-27
part_of: "[fig](/fig.md)"
---

# VERSIONING

fig ships three artifacts. Each is versioned **independently**, on its own
[SemVer](https://semver.org/) track:

| Artifact | Version lives in | Public surface it governs |
| --- | --- | --- |
| Zig core + C ABI | `build.zig.zon` `.version` (mirrored to `include/fig.h` `FIG_VERSION_*`) | the exported `fig_*` C symbols, struct layouts, enum values |
| Rust crate (`fig`) | `bindings/rust/Cargo.toml` `[workspace.package] version` | the native Rust API: `Value`, `Document`, the editor, `#[derive(ToValue/FromValue)]`, serde impls, cargo features |
| npm package (`@adammharris/fig`) | `bindings/typescript/package.json` `version` | the TypeScript/JS API exported from `dist/` |

They are **not** kept in lockstep. A change that touches only one surface bumps only
that artifact: a Rust convenience method bumps the crate, a TS typing fix bumps the npm
package, a new C function bumps the core — without dragging the others along.

## The one cross-artifact rule: the embedded-core floor

Both bindings compile/bundle the core from this same source tree, so the core they embed
is exactly `build.zig.zon`'s `.version`. The invariant that ties the tracks together:

> **A binding's version must be ≥ the core version it embeds.**

This guarantees:

- a **breaking core bump** (major) pulls every binding's major up with it — a binding can
  never keep an older-looking number while shipping a newer, possibly-incompatible core;
- reading a binding's version is never an underestimate of the core inside it.

Equality is **not** required — a binding may run ahead of the core for binding-only
releases. Enforced by `zig build version-floor` (`tools/version-floor.zig`), in CI.

## The C ABI contract version

`include/fig.h` also defines `FIG_ABI_VERSION` — a monotonic integer, distinct from the
marketing version, that identifies the *binary shape* of the C ABI the way an ELF SONAME
does. It is bumped **only on a breaking ABI change**. fig's forward-compat design
(size-gated structs, decode-unknown enums, add-never-remove functions) makes additions
non-breaking, so this number stays put across feature releases and moves only on a true
break. The library reports it at runtime via `fig_abi_version()`, so a host that
dynamically loads `libfig` can compare it against the `FIG_ABI_VERSION` it compiled with.

Source of truth: `abi_version` in `build.zig`. `zig build abi-check` pins the `fig.h`
macro to it; `zig build semver-check` requires it to increment whenever the C ABI diff
against the last release tag is breaking.

## The guard tools

| Tool | Guards | How |
| --- | --- | --- |
| `zig build abi-check` | core C ABI self-consistency | every `fig_*` export has a header prototype and vice versa; `fig.h` `FIG_VERSION_*`/`FIG_ABI_VERSION` match `build.zig` |
| `zig build semver-check` | core C ABI vs. last release | diffs functions + struct/enum layout against the last `v*` tag, turns it into a SemVer verdict, requires `.version` (and `FIG_ABI_VERSION` on a break) to cover it |
| `cargo-semver-checks` (CI `rust-semver`) | native Rust API | diffs the crate's rustdoc against the last `v*` tag; fails if the delta exceeds the crate's version bump |
| `zig build version-floor` | the cross-artifact floor + the `fig-macros` pin | each binding version ≥ core version; `fig-macros` pin == Rust workspace version |

These are the source of truth for the policy — this document only describes them. Run
the test suite and all four guards at once with **`zig build check`** — the single
pre-release gate (it depends on `test` plus the three Zig steps and shells out to
`cargo-semver-checks`, which skips with a note if the tool isn't installed or there's no
`v*` tag yet); the individual steps remain available for running one in isolation. The
`.githooks/pre-commit` hook runs `abi-check` (when an ABI file is staged)
and `version-floor` (when a manifest is staged) locally, and CI runs all four as separate
jobs (kept split for parallelism and the Rust job's pinned-nightly toolchain); bypass a
local run with `git commit --no-verify`. Enable the hooks once per clone:
`git config core.hooksPath .githooks`.

## Releasing

1. Bump only the artifact(s) whose surface changed, by the amount its SemVer tool demands.
2. If the core had a **breaking** ABI change, also bump `FIG_ABI_VERSION` (`abi_version` in
   `build.zig`) and pull each binding's major up to satisfy the floor.
3. Run `zig build check` (test + abi-check + semver-check + version-floor +
   cargo-semver-checks) — all green.
4. Tag the release `v<core-version>`; the SemVer tools baseline against the most recent
   `v*` tag.

## Known gaps

- **No automated TypeScript API guard.** There is no turnkey `cargo-semver-checks`
  equivalent for the TS public surface, and the C-ABI integer has no TS analog (npm
  exposes no C ABI). The TS package is on the independent track + floor; an automated
  TS API-diff (e.g. an `api-extractor` report committed to git) is an optional follow-up.
