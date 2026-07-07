```fig
title = VERSIONING
description = Versioning policy for `fig`
author = adammharris
created = 2026-06-27
updated = 2026-07-06
part_of = [docs](docs.md)
```

# VERSIONING

`fig` follows SemVer strictly. This means, in practice, that **major releases are not sacred** and will be bumped even on small-size releases if it is functionally a major breaking change according to SemVer.

Therefore, starting with version v2.0.0, the `fig` project now has what some call an "epoch"—a "marketing" version that changes less often than major releases. For v2.0.0, this is "Sierra," a kind of fig fruit.


## Independent versioning

`fig`'s artifacts are versioned independently, each on its own [SemVer](https://semver.org/) track, but **an artifact's version must be ≥ the core version it embeds.** The tracked artifacts:

- the Zig core + C ABI — `.version` in `build.zig.zon`
- the CLI binary — `cli_version` in `build.zig`
- the Rust crate — `[workspace.package] version` in `bindings/rust/Cargo.toml`
- the npm package — `"version"` in `bindings/typescript/package.json`

This guarantees:
- an artifact can never keep an older-looking number while shipping a newer, possibly-incompatible core;
- reading an artifact's version is never an underestimate of the core inside it.

Equality is **not** required — an artifact may run ahead of the core for artifact-only releases. Enforced by `zig build version-floor` (`tools/version-floor.zig`) in CI (via `zig build check`).

The CLI is on this list because its compatibility contract is its own — flags, defaults, exit codes — and is orthogonal to the library API and the C ABI. A CLI-only breaking change (e.g. flipping a flag's default, removing a flag) bumps `cli_version`'s major without forcing a core/ABI release; a core-only change doesn't force a CLI bump either. `fig version` prints both numbers, e.g. `fig 3.0.0 (core 2.0.0)`.

## The C ABI contract version

`bindings/c/include/fig.h` also defines `FIG_ABI_VERSION` — a monotonic integer, distinct from the marketing version, that identifies the *binary shape* of the C ABI the way an ELF SONAME does. It is bumped **only on a breaking ABI change**. fig's forward-compat design (size-gated structs, decode-unknown enums, add-never-remove functions) makes additions non-breaking, so this number stays put across feature releases and moves only on a true break. The library reports it at runtime via `fig_abi_version()`, so a host that dynamically loads `libfig` can compare it against the `FIG_ABI_VERSION` it compiled with.

Source of truth: `abi_version` in `build.zig`. `zig build abi-check` pins the `fig.h` macro to it; `zig build semver-check` requires it to increment whenever the C ABI diff against the last release tag is breaking.

## Releasing

1. Bump only the artifact(s) whose surface changed, by the amount its SemVer tool demands.
2. If the core had a **breaking** ABI change, also bump `FIG_ABI_VERSION` (`abi_version` in `build.zig`) and pull every other artifact's major up to satisfy the floor.
3. Run `zig build check` (test + abi-check + semver-check + version-floor + cargo-semver-checks) — all green.
4. Tag the release `v<core-version>`; the SemVer tools baseline against the most recent `v*` tag. (See the tagging gap below when only the CLI moved.)

## Known gaps

- **No automated TypeScript API guard.** There is no turnkey `cargo-semver-checks` equivalent for the TS public surface, and the C-ABI integer has no TS analog (npm exposes no C ABI). The TS package is on the independent track + floor; an automated TS API-diff (e.g. an `api-extractor` report committed to git) is an optional follow-up.
- **CLI releases aren't decoupled from the release tag yet.** The tag scheme (`v<core-version>`, one tag driving `release.yml`/`release-binaries.yml`/`homebrew.yml`) and `release.yml`'s "tag matches build.zig.zon version" check both assume core moves on every release. A CLI-only bump (`cli_version` ahead of an unchanged core) still needs *some* new `v*.*.*` tag to trigger a release build, which today means an administrative core patch bump just to mint one — even though nothing in the library changed. Splitting the tag scheme (e.g. a separate `cli-v<cli-version>` tag driving only the CLI binary builds) is an optional follow-up; until then, cutting a CLI-only release still rides along with a core patch bump.
