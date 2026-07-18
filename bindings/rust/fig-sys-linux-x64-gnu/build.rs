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
