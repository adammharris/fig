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
- the `fig-wasi` npm package — `"version"` in `bindings/wasi/package.json` (a special case: see below)

This guarantees:
- an artifact can never keep an older-looking number while shipping a newer, possibly-incompatible core;
- reading an artifact's version is never an underestimate of the core inside it.

Equality is **not** required — an artifact may run ahead of the core for artifact-only releases. Enforced by `zig build version-floor` (`tools/version-floor.zig`) in CI (via `zig build check`).

The CLI is on this list because its compatibility contract is its own — flags, defaults, exit codes — and is orthogonal to the library API and the C ABI. A CLI-only breaking change (e.g. flipping a flag's default, removing a flag) bumps `cli_version`'s major without forcing a core/ABI release; a core-only change doesn't force a CLI bump either. `fig version` prints both numbers, e.g. `fig 3.0.0 (core 2.0.0 "Sierra")`.

`fig-wasi` (`bindings/wasi/package.json`, the npx-able CLI-over-WASI package) is the one exception to "independent": it's a repackaging of the CLI binary itself — same actions, same compatibility contract — not a separate binding, so its version must equal `cli_version` **exactly** (a pin, not a floor), checked by `version-floor` alongside the `fig-macros` pin (see below).

## The C ABI contract version

`bindings/c/include/fig.h` also defines `FIG_ABI_VERSION` — a monotonic integer, distinct from the marketing version, that identifies the *binary shape* of the C ABI the way an ELF SONAME does. It is bumped **only on a breaking ABI change**. fig's forward-compat design (size-gated structs, decode-unknown enums, add-never-remove functions) makes additions non-breaking, so this number stays put across feature releases and moves only on a true break. The library reports it at runtime via `fig_abi_version()`, so a host that dynamically loads `libfig` can compare it against the `FIG_ABI_VERSION` it compiled with.

Source of truth: `abi_version` in `build.zig`. `zig build abi-check` pins the `fig.h` macro to it; `zig build semver-check` requires it to increment whenever the C ABI diff against the last release tag is breaking. (`semver-check` uses the most recent `core/v*` tag — the core's own release line, see "Release tagging" below — purely as a git revision to diff *against* via `git show <tag>:...`, so it doesn't care what the tag's number itself represents; only `abi_version`/`.version` in the current tree matter to it.)

## Release tagging

Since each artifact versions independently, no single tag number could honestly describe all of them. Instead, each track gets its **own** tag prefix, and a release pushes only the tags for whichever artifact(s) actually moved:

| Tag | Drives | Why it exists |
|---|---|---|
| `cli/v<cli-version>` | `release-binaries.yml` + `homebrew.yml` (build/attach the CLI binaries, create the GitHub Release) and `release-npm-wasi.yml` | the CLI's own compatibility contract; this is the tag end users actually see and fetch (Homebrew, npx, direct download) |
| `core/v<core-version>` | nothing — no workflow triggers on it | the core has no package registry of its own — `zig fetch`'s "pushing the tag *is* the Zig release" needs a tag that means *core*, and `zig build semver-check`'s ABI diff needs a baseline on the core's own line, so it gets a plain (no CI, no GitHub Release) tag purely as that anchor |
| `rust/v<rust-version>` | `release.yml`'s `crate` job (crates.io: `fig` + `fig-macros`) | also the `cargo-semver-checks` baseline, so the Rust API diff compares against the Rust crate's own release history, not core's or the CLI's |
| `npm/v<npm-version>` | `release-npm.yml` (`@diaryx/fig`, the TS library) | independent track, same reasoning |

`fig-wasi` doesn't get its own prefix — it's pinned exactly to `cli_version` (see above), so it rides the `cli/` tag; its job keeps an explicit "tag matches package version" check (in addition to the floor) to enforce that pin.

Only `cli/*` tags get prebuilt binaries and a GitHub Release object (via `softprops/action-gh-release`) attached — that's the human-facing release. `core/*`, `rust/*`, and `npm/*` are plain git tags (visible under the repo's Tags list, not the Releases page): real, `git describe`-able and `zig fetch`-able anchors for their own consumers, without cluttering the Releases page with entries nobody downloads binaries from.

A release that bumps several artifacts at once just pushes several tags at the same commit — e.g. a release that bumps both the CLI and the core pushes `cli/v3.1.0` and `core/v2.1.0` together; a Rust-only bump pushes only `rust/v1.5.0` and needs no CLI or core tag at all.

## Releasing

1. Bump only the artifact(s) whose surface changed, by the amount its SemVer tool demands, with `zig build version-set -- <artifact> <version|major|minor|patch>` (`artifact` = `core`|`cli`|`rust`|`npm`). It edits the right manifest(s) and keeps the coupled fields consistent for you: the `fig-wasi` == `cli_version` pin (so a `cli` bump carries `fig-wasi`), the `fig-macros` pin == the Rust workspace version, and the `artifact >= core` floor (a `core` bump auto-raises any lagging cli/rust/npm), then refreshes the lockfiles. A `core` bump also syncs `fig.md`'s frontmatter `version` field (the number shown at the top of the README) to match, by shelling out to `fig set` itself rather than hand-editing the markdown. Add `--dry-run` to preview the edits without writing. (`version-set` is the writer counterpart of the read-only `version-floor` checker; it does **not** touch `abi_version` — see step 2.)
2. If the core had a **breaking** ABI change, also bump `FIG_ABI_VERSION` (`abi_version` in `build.zig`) by hand — it's a deliberate ABI-contract decision `semver-check` guards, not a marketing version, so `version-set` leaves it alone — and pull every other artifact's major up to satisfy the floor (`zig build version-set -- core <major>.0.0` does the pull for you).
3. Run `zig build check` (test + abi-check + semver-check + version-floor + cargo-semver-checks) — all green.
4. Push one tag per artifact that changed this release (see "Release tagging" above): `cli/v<cli-version>` if the CLI (or `fig-wasi`) moved, `core/v<core-version>` if the core moved, `rust/v<rust-version>` / `npm/v<npm-version>` for those tracks. The SemVer tools each baseline against their own track's most recent tag (`core/v*` for `semver-check`, `rust/v*` for `cargo-semver-checks`).

## Known gaps

- **No automated TypeScript API guard.** There is no turnkey `cargo-semver-checks` equivalent for the TS public surface, and the C-ABI integer has no TS analog (npm exposes no C ABI). The TS package is on the independent track + floor; an automated TS API-diff (e.g. an `api-extractor` report committed to git) is an optional follow-up.
- **No `npm/*` tag baseline guard yet.** Unlike the C ABI (`semver-check` vs `core/v*`) and the Rust crate (`cargo-semver-checks` vs `rust/v*`), the TS package has no equivalent baseline diff to run against `npm/v*` — see the TypeScript API guard gap above; once that lands, it should baseline the same way.
