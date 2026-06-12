use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

fn main() {
    let cargo_target = env::var("TARGET").expect("Cargo should set TARGET");
    let cargo_host = env::var("HOST").expect("Cargo should set HOST");
    let manifest_dir = PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").unwrap());
    let repo_root = manifest_dir
        .ancestors()
        .nth(2)
        .expect("bindings/rust should be two levels below the repository root");
    let out_dir = PathBuf::from(env::var_os("OUT_DIR").unwrap());
    let prefix = out_dir.join("zig-prefix");

    let mut command = Command::new("zig");
    command
        .arg("build")
        .arg("install-c-lib")
        .arg("-Doptimize=ReleaseFast")
        .arg("-Dstrip=true")
        // Pin the CPU to the portable baseline. Without this, `zig build` for a
        // host target (no `-Dtarget`) compiles for the *build machine's* native
        // CPU, baking in whatever vector ISA it happens to have (AVX2/AVX-512:
        // `ymm`/`zmm`/`kmov`). The resulting `libfig.a` gets cached (e.g. by
        // Swatinem/rust-cache) and later restored onto a different, older CPU —
        // GitHub's x86_64 Linux runner fleet is heterogeneous — where the first
        // wide-vector instruction faults with SIGILL. Baseline codegen runs
        // everywhere; the parser is not vector-bound, so the cost is negligible.
        .arg("-Dcpu=baseline");

    if let Some(zig_target) = zig_target_for_cargo_target(&cargo_target, &cargo_host) {
        command.arg(format!("-Dtarget={zig_target}"));
    }

    let status = command
        .arg("--prefix")
        .arg(&prefix)
        .current_dir(repo_root)
        .status()
        .expect("failed to run `zig build`");

    if !status.success() {
        panic!("`zig build` failed with status {status}");
    }

    // Apple's `ld` rejects Zig's static archive ("not 8-byte aligned"); repack
    // it with the system tools so it links.
    if cargo_target.contains("apple-darwin") {
        repack_archive_for_apple_ld(&prefix.join("lib").join("libfig.a"));
    }

    println!(
        "cargo:rustc-link-search=native={}",
        prefix.join("lib").display()
    );
    println!("cargo:rustc-link-lib=static=fig");

    println!(
        "cargo:rerun-if-changed={}",
        repo_root.join("build.zig").display()
    );
    println!("cargo:rerun-if-changed={}", repo_root.join("src").display());
    println!(
        "cargo:rerun-if-changed={}",
        repo_root.join("include/fig.h").display()
    );
}

/// Repackage a Zig-produced static archive so Apple's `ld` accepts it.
///
/// Zig's archiver writes members with a zero file mode and without 8-byte
/// alignment. LLD tolerates this, but ld64 errors with "not 8-byte aligned".
/// Extract the members, restore read permissions (so `libtool` can open them),
/// and rebuild the archive with `libtool`, whose output ld64 accepts.
fn repack_archive_for_apple_ld(lib_path: &Path) {
    let work = lib_path
        .parent()
        .expect("library path has a parent")
        .join("repack");
    let _ = fs::remove_dir_all(&work);
    fs::create_dir_all(&work).expect("create repack work dir");

    run(Command::new("ar").arg("x").arg(lib_path).current_dir(&work));

    // Collect the extracted object files, fixing their permissions.
    let mut objects = Vec::new();
    for entry in fs::read_dir(&work).expect("read repack work dir") {
        let path = entry.expect("dir entry").path();
        if path.extension().is_some_and(|ext| ext == "o") {
            run(Command::new("chmod").arg("u+rw").arg(&path));
            objects.push(path);
        }
    }
    assert!(
        !objects.is_empty(),
        "no object files extracted from {}",
        lib_path.display()
    );

    let mut libtool = Command::new("libtool");
    libtool.arg("-static").arg("-o").arg(lib_path).args(&objects);
    run(&mut libtool);

    let _ = fs::remove_dir_all(&work);
}

fn run(command: &mut Command) {
    let status = command
        .status()
        .unwrap_or_else(|e| panic!("failed to run {command:?}: {e}"));
    if !status.success() {
        panic!("{command:?} failed with status {status}");
    }
}

fn zig_target_for_cargo_target(target: &str, host: &str) -> Option<&'static str> {
    // Windows MSVC must be handled before the `target == host` shortcut: Zig's
    // native default Windows ABI is GNU-style and emits `__chkstk_ms`, a
    // compiler-rt stack-probe symbol that Zig does not bundle into a static
    // lib, so the MSVC linker can't resolve it. Forcing the msvc ABI makes Zig
    // emit `__chkstk` (provided by the MSVC runtime) and keeps the static lib
    // ABI-compatible with the windows-msvc Rust binary it links into.
    match target {
        "x86_64-pc-windows-msvc" => return Some("x86_64-windows-msvc"),
        "aarch64-pc-windows-msvc" => return Some("aarch64-windows-msvc"),
        _ => {}
    }

    if target == host {
        return None;
    }

    match target {
        "aarch64-apple-darwin" => Some("aarch64-macos"),
        "x86_64-apple-darwin" => Some("x86_64-macos"),
        "aarch64-pc-windows-gnu" => Some("aarch64-windows-gnu"),
        "x86_64-pc-windows-gnu" => Some("x86_64-windows-gnu"),
        "i686-pc-windows-gnu" => Some("x86-windows-gnu"),
        "aarch64-unknown-linux-gnu" => Some("aarch64-linux-gnu"),
        "aarch64-unknown-linux-musl" => Some("aarch64-linux-musl"),
        "arm-unknown-linux-gnueabi" => Some("arm-linux-gnueabi"),
        "arm-unknown-linux-gnueabihf" => Some("arm-linux-gnueabihf"),
        "arm-unknown-linux-musleabi" => Some("arm-linux-musleabi"),
        "arm-unknown-linux-musleabihf" => Some("arm-linux-musleabihf"),
        "i686-unknown-linux-gnu" => Some("x86-linux-gnu"),
        "i686-unknown-linux-musl" => Some("x86-linux-musl"),
        "powerpc64le-unknown-linux-gnu" => Some("powerpc64le-linux-gnu"),
        "powerpc64le-unknown-linux-musl" => Some("powerpc64le-linux-musl"),
        "riscv64gc-unknown-linux-gnu" => Some("riscv64-linux-gnu"),
        "riscv64gc-unknown-linux-musl" => Some("riscv64-linux-musl"),
        "wasm32-unknown-unknown" => Some("wasm32-freestanding"),
        "x86_64-unknown-linux-gnu" => Some("x86_64-linux-gnu"),
        "x86_64-unknown-linux-musl" => Some("x86_64-linux-musl"),
        _ => panic!(
            "unsupported Rust target `{target}` for fig's bundled Zig static library; \
             add a Cargo-to-Zig target mapping in bindings/rust/build.rs"
        ),
    }
}
