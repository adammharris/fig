#!/usr/bin/env bash
#
# Generate the per-target `fig-sys-<key>` payload crates from
# prebuilt-targets.tsv. Each payload crate carries a prebuilt `lib/libfig.a`
# (produced separately by build-payload-lib.sh / CI, git-ignored) built with
# fig's DEFAULT language set, and a tiny build script that hands its location to
# `fig-sys` via `links` metadata.
#
# Idempotent: safe to re-run after editing the table. Does NOT touch lib/.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)" # bindings/rust
table="$root/prebuilt-targets.tsv"

while IFS=$'\t' read -r rust_target zig_target key cfg; do
    [[ "$rust_target" =~ ^#|^$ ]] && continue
    dir="$root/fig-sys-$key"
    underscored="${key//-/_}"
    links="fig_prebuilt_$underscored"
    libname="fig_sys_$underscored"
    # Zig names the static library `fig.lib` on Windows and `libfig.a` elsewhere.
    # rustc's `-l static=fig` resolves either name from the search dir.
    if [[ "$rust_target" == *windows* ]]; then archive="fig.lib"; else archive="libfig.a"; fi
    mkdir -p "$dir/src"

    cat >"$dir/Cargo.toml" <<EOF
[package]
name = "fig-sys-$key"
version.workspace = true
edition.workspace = true
license.workspace = true
description = "Prebuilt libfig.a (default features) for $rust_target. Support crate for fig-sys; not for direct use."
repository = "https://github.com/diaryx-org/fig"
# The build script hands \`lib/$archive\`'s location to \`fig-sys\` via this
# \`links\` key (as \`DEP_${links^^}_LIBDIR\`). Unique per payload crate.
links = "$links"
# Allowlist: the prebuilt archive plus the trivial crate skeleton. \`lib/\` is
# git-ignored and populated by scripts/build-payload-lib.sh (or CI) before publish.
include = ["build.rs", "src/lib.rs", "lib/$archive", "README.md"]

[lib]
name = "$libname"
path = "src/lib.rs"
EOF

    cat >"$dir/build.rs" <<'EOF'
// Hand the prebuilt archive's directory to `fig-sys`'s build script. Because
// this crate sets `links`, the `cargo:libdir=…` line below reaches dependents
// as `DEP_<LINKS>_LIBDIR`. This crate emits no link directives itself —
// `fig-sys` is the single place that decides to link the static library.
use std::env;
use std::path::Path;

fn main() {
    let manifest = env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR");
    let libdir = Path::new(&manifest).join("lib");
    println!("cargo:libdir={}", libdir.display());
    println!("cargo:rerun-if-changed={}", libdir.display());
}
EOF

    cat >"$dir/src/lib.rs" <<EOF
//! Prebuilt \`libfig.a\` (default language features) for \`$rust_target\`.
//!
//! Support crate for [\`fig-sys\`](https://docs.rs/fig-sys); do not depend on it
//! directly. The archive is delivered to \`fig-sys\`'s build script through this
//! crate's \`links\` metadata (see \`build.rs\`); there is no Rust API here.
EOF

    cat >"$dir/README.md" <<EOF
# fig-sys-$key

Prebuilt \`libfig.a\` (fig's default language set) for \`$rust_target\`, letting
\`fig-sys\` link fig's native library on this target **without a Zig toolchain**.

This is an implementation detail of [\`fig-sys\`](https://crates.io/crates/fig-sys)
and [\`fig\`](https://crates.io/crates/fig). You should not depend on it directly;
\`fig-sys\` pulls in the right payload crate automatically for your target. A
non-default language feature set builds from source instead.

## License

MIT OR Apache-2.0
EOF

    echo "gen-payloads: wrote fig-sys-$key ($rust_target)"
done <"$table"
