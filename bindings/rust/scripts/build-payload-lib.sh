#!/usr/bin/env bash
#
# Build the prebuilt `libfig.a` for one tier-1 target (by `key`, or `all`) and
# drop it into the matching `fig-sys-<key>/lib/` payload crate. Uses Zig's
# cross-compiler, so every target builds from a single host. Run before
# `cargo package`/publish of the payload crates (this is what CI does).
#
#   scripts/build-payload-lib.sh macos-arm64
#   scripts/build-payload-lib.sh all
#
# The library is built with fig's DEFAULT language set — json, yaml, toml, fig
# ON; zon, xml OFF — matching `fig`'s `default` features. `fig-sys`'s build
# script only links a prebuilt archive when the active feature set matches this;
# any other combination compiles the core from source.
#
# Env: FIG_ZIG_ROOT overrides the Zig source root (defaults to the repo root).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"                 # bindings/rust
repo_root="$(cd "$root/../.." && pwd)"
zig_root="${FIG_ZIG_ROOT:-$repo_root}"
table="$root/prebuilt-targets.tsv"
want="${1:-all}"

build_one() {
    local rust_target="$1" zig_target="$2" key="$3"
    local dir="$root/fig-sys-$key"
    local prefix
    prefix="$(mktemp -d)"

    echo "build-payload-lib: $key ($rust_target -> zig $zig_target)"
    # Default language set: zon and xml are off in fig's `default`, everything
    # else on. Keep in sync with fig-sys's `features_match_prebuilt()`.
    zig build install-c-lib \
        -Doptimize=ReleaseFast \
        -Dstrip=true \
        -Dcpu=baseline \
        -Dzon=false \
        -Dxml=false \
        -Dtarget="$zig_target" \
        --prefix "$prefix" \
        --build-file "$zig_root/build.zig"

    # Zig names the static library `fig.lib` on Windows, `libfig.a` elsewhere.
    local name="libfig.a"
    [[ "$rust_target" == *windows* ]] && name="fig.lib"
    local archive="$prefix/lib/$name"
    [ -f "$archive" ] || { echo "  ERROR: $archive not produced" >&2; exit 1; }

    # Apple's ld rejects static-archive members that aren't 8-byte aligned, and
    # Zig 0.16's archiver can emit an unaligned member. Repack apple archives
    # with `ar` (writes aligned members) at build time so the shipped archive
    # links cleanly with no repack on the consumer side. `ar` (unlike macOS-only
    # `libtool`) is available on the Linux CI runner that cross-builds these.
    if [[ "$rust_target" == *apple* ]]; then
        local work; work="$(mktemp -d)"
        ( cd "$work" && ar x "$archive" && chmod u+rw ./*.o \
            && ar crs "$name" ./*.o )
        archive="$work/$name"
    fi

    mkdir -p "$dir/lib"
    cp "$archive" "$dir/lib/$name"
    echo "  -> $dir/lib/$name ($(du -h "$dir/lib/$name" | cut -f1))"
}

matched=0
while IFS=$'\t' read -r rust_target zig_target key cfg; do
    [[ "$rust_target" =~ ^#|^$ ]] && continue
    if [ "$want" = "all" ] || [ "$want" = "$key" ]; then
        build_one "$rust_target" "$zig_target" "$key"
        matched=1
    fi
done <"$table"

[ "$matched" = 1 ] || { echo "build-payload-lib: no target matched '$want'" >&2; exit 1; }
