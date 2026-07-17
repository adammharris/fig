//! The correctness/release guards and the one-stop `check` gate that folds them
//! all together: the C ABI surface check, the SemVer diff, the cross-artifact
//! version floor, the cargo-semver-checks pass, and the Rust/TypeScript binding
//! test suites. `check` additionally depends on the `check-figl` step (from
//! `tools`) and the `test`/`conformance` steps (from `tests`), passed in via
//! `Deps` so this module doesn't reach back into the others.

const std = @import("std");
const Context = @import("Context.zig");
const artifacts = @import("artifacts.zig");

/// Step handles produced by other stages that the `check` gate must depend on.
pub const Deps = struct {
    /// From `tools`: generated-file staleness guard.
    check_figl_step: *std.Build.Step,
    /// From `tests`: the unit-test suite.
    test_step: *std.Build.Step,
    /// From `tests`: the conformance run.
    conformance_step: *std.Build.Step,
};

pub fn add(ctx: Context, arts: artifacts.Result, deps: Deps) void {
    const b = ctx.b;
    const target = ctx.target;
    const optimize = ctx.optimize;
    const ver = ctx.ver;
    const c_lib = arts.c_lib;

    // ABI surface check: keep the C ABI implementation (src/c_api.zig), the
    // public header (bindings/c/include/fig.h), and the built library in agreement.
    //   * tools/abi-check.zig diffs the exported `fig_*` symbols against the
    //     header prototypes (both directions), failing on any mismatch — this is
    //     what catches a symbol exported without a header declaration.
    //   * abi_probe.{c,cpp} are compiled against fig.h, as C and as C++, and
    //     linked against the C ABI static library, proving the header parses and
    //     links in both languages.
    // Signatures are not compared (C has no name mangling). Run: zig build abi-check.
    // The pre-commit hook in .githooks/ runs this when an ABI file is staged.
    const abi_check = b.addExecutable(.{
        .name = "abi_check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/abi-check.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const abi_check_run = b.addRunArtifact(abi_check);
    // Passed as file args so the run is cache-keyed on the files it inspects.
    abi_check_run.addFileArg(b.path("bindings/c/include/fig.h"));
    abi_check_run.addFileArg(b.path("src/c_api.zig"));
    // The canonical version (from build.zig.zon) so the tool can assert that
    // fig.h's FIG_VERSION_* macros have not drifted from it.
    abi_check_run.addArg(b.fmt("{d}.{d}.{d}", .{ ver.core.major, ver.core.minor, ver.core.patch }));
    // The canonical ABI version so the tool can assert fig.h's FIG_ABI_VERSION
    // macro matches the value compiled into `fig_abi_version()`.
    abi_check_run.addArg(b.fmt("{d}", .{ver.abi}));

    const abi_probe_c = b.addExecutable(.{
        .name = "abi_probe_c",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    abi_probe_c.root_module.addCSourceFile(.{ .file = b.path("tools/abi_probe.c") });
    abi_probe_c.root_module.addIncludePath(b.path("bindings/c/include"));
    abi_probe_c.root_module.linkLibrary(c_lib);

    const abi_probe_cpp = b.addExecutable(.{
        .name = "abi_probe_cpp",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true, .link_libcpp = true }),
    });
    abi_probe_cpp.root_module.addCSourceFile(.{ .file = b.path("tools/abi_probe.cpp") });
    abi_probe_cpp.root_module.addIncludePath(b.path("bindings/c/include"));
    abi_probe_cpp.root_module.linkLibrary(c_lib);

    const abi_check_step = b.step("abi-check", "Check the C ABI surface: symbol diff + C/C++ header probe");
    abi_check_step.dependOn(&abi_check_run.step);
    abi_check_step.dependOn(&abi_probe_c.step);
    abi_check_step.dependOn(&abi_probe_cpp.step);

    // SemVer gate: diff the current C ABI against the most recent `v*` git tag
    // and turn the delta into a version verdict (removed/changed symbol -> major,
    // added-only -> minor, none -> patch), then assert build.zig.zon's version is
    // high enough to cover it. Discovers the baseline itself via `git describe` +
    // `git show`, so it needs the repo root and the canonical version. With no git
    // history / no tags it prints a note and passes. Run: zig build semver-check.
    const semver_check = b.addExecutable(.{
        .name = "semver_check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/semver-check.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const semver_check_run = b.addRunArtifact(semver_check);
    // Cache-key on the header it inspects; the baseline comes from git at run time.
    semver_check_run.addFileArg(b.path("bindings/c/include/fig.h"));
    semver_check_run.addArg(b.fmt("{d}.{d}.{d}", .{ ver.core.major, ver.core.minor, ver.core.patch }));
    semver_check_run.addArg(b.pathFromRoot("."));
    // git state isn't a declared input, so never serve this from cache.
    semver_check_run.has_side_effects = true;
    const semver_check_step = b.step("semver-check", "Diff the C ABI vs the last release tag and verify the version bump");
    semver_check_step.dependOn(&semver_check_run.step);

    // Cross-artifact version floor. fig versions each artifact independently —
    // the Zig core (build.zig.zon), the CLI binary (`cli_version` in build.zig),
    // the Rust crate (bindings/rust/Cargo.toml), the npm package
    // (bindings/typescript/package.json), and the fig-wasi npm package
    // (bindings/wasi/package.json) move on their own SemVer tracks so a
    // binding-only (or CLI-only) change need not bump the core. The one
    // invariant: every artifact's version must be >= the core version it
    // embeds, so a breaking core bump always pulls the others' major up and
    // none can silently ship a newer core behind an older-looking number
    // (fig-wasi additionally must equal `cli_version` exactly, since it's a
    // repackaging of the CLI, not an independent binding). This tool
    // enforces both. Run: zig build version-floor.
    const version_floor = b.addExecutable(.{
        .name = "version_floor",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/version-floor.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const version_floor_run = b.addRunArtifact(version_floor);
    // Cache-keyed on the five manifests it compares (build.zig carries the
    // CLI's own version — see `cli_version` in build.zig).
    version_floor_run.addFileArg(b.path("build.zig.zon"));
    version_floor_run.addFileArg(b.path("build.zig"));
    version_floor_run.addFileArg(b.path("bindings/rust/Cargo.toml"));
    version_floor_run.addFileArg(b.path("bindings/typescript/package.json"));
    version_floor_run.addFileArg(b.path("bindings/wasi/package.json"));
    const version_floor_step = b.step("version-floor", "Check each binding's version is >= the core version it embeds");
    version_floor_step.dependOn(&version_floor_run.step);

    // One-stop release gate: every version/ABI guard behind a single command, so
    // "did I bump correctly?" is `zig build check` instead of remembering four
    // separate invocations across two build systems. It depends on the three Zig
    // guards above and additionally shells out to cargo-semver-checks — the only
    // guard that lives in cargo's world rather than zig's (it diffs the native
    // Rust API, which never crosses the C ABI the Zig tools inspect). A
    // TypeScript API guard can hang off this same step later the same way.
    const check_step = b.step("check", "Pre-release gate: zig test + conformance suites + abi/semver/floor/figl guards + cargo-semver-checks + rust & typescript tests (binding suites skip with a note if their toolchain is missing)");
    check_step.dependOn(abi_check_step);
    check_step.dependOn(semver_check_step);
    check_step.dependOn(version_floor_step);
    check_step.dependOn(deps.check_figl_step);

    // cargo-semver-checks guards the native Rust public surface. Mirror CI: pick
    // the most recent `rust/v*` tag as the baseline — the Rust crate's own
    // release line, distinct from `semver-check`'s `core/v*` baseline, since the
    // crate versions independently of the core (see "Independent versioning" in
    // docs/VERSIONING.md) — and skip cleanly when there is none yet (a fresh
    // repo, or one that hasn't cut a Rust release yet, has nothing to diff
    // against). Runs in bindings/rust; requires a nightly toolchain
    // (cargo-semver-checks reads rustdoc JSON) and the cargo-semver-checks
    // subcommand installed. git state is not a declared input, so it must never
    // be served from cache.
    const cargo_semver_script =
        \\set -eu
        \\if ! command -v cargo-semver-checks >/dev/null 2>&1; then
        \\  echo "cargo-semver-checks: not installed — skipping (install: cargo install cargo-semver-checks)."
        \\  exit 0
        \\fi
        \\tag="$(git describe --tags --abbrev=0 --match 'rust/v*' 2>/dev/null || true)"
        \\if [ -z "$tag" ]; then
        \\  echo "cargo-semver-checks: no rust/v* tag found — skipping (nothing to diff against)."
        \\  exit 0
        \\fi
        \\echo "cargo-semver-checks: baseline $tag"
        \\cargo semver-checks --package fig --baseline-rev "$tag"
    ;
    const cargo_semver = b.addSystemCommand(&.{ "sh", "-c", cargo_semver_script });
    cargo_semver.setCwd(b.path("bindings/rust"));
    cargo_semver.has_side_effects = true;
    check_step.dependOn(&cargo_semver.step);

    // Rust binding test suite, gated on a local cargo toolchain. A contributor
    // who only touches the Zig core (and has no Rust installed) still gets a
    // useful `check`; the step warns and skips rather than failing. CI installs
    // cargo, so there the suite runs for real.
    const rust_test_script =
        \\set -eu
        \\if ! command -v cargo >/dev/null 2>&1; then
        \\  echo "rust tests: cargo not found — skipping (install Rust to run them)."
        \\  exit 0
        \\fi
        \\cargo test --workspace
    ;
    const rust_test = b.addSystemCommand(&.{ "sh", "-c", rust_test_script });
    rust_test.setCwd(b.path("bindings/rust"));
    rust_test.has_side_effects = true;
    check_step.dependOn(&rust_test.step);

    // TypeScript binding test suite, gated on a local npm toolchain AND installed
    // deps. The tests import the built wasm module, so build first. Skips (with a
    // note) when npm is absent or `node_modules` hasn't been populated, so the
    // gate degrades gracefully on a partial checkout; CI runs `npm ci` first.
    const ts_test_script =
        \\set -eu
        \\if ! command -v npm >/dev/null 2>&1; then
        \\  echo "typescript tests: npm not found — skipping (install Node.js to run them)."
        \\  exit 0
        \\fi
        \\if [ ! -d node_modules ]; then
        \\  echo "typescript tests: node_modules missing — skipping (run 'npm ci' in bindings/typescript first)."
        \\  exit 0
        \\fi
        \\npm run build
        \\npm test
    ;
    const ts_test = b.addSystemCommand(&.{ "sh", "-c", ts_test_script });
    ts_test.setCwd(b.path("bindings/typescript"));
    ts_test.has_side_effects = true;
    check_step.dependOn(&ts_test.step);

    // The release gate runs the test suite too, so `zig build check` is the single
    // pre-release command: tests pass AND every version/ABI guard is satisfied.
    check_step.dependOn(deps.test_step);
    // Conformance rides the same gate (~13s on top). Because ci.yml already runs
    // `zig build check`, wiring it here — rather than as its own CI step — is what
    // keeps the corpus from going stale again: a new format's suite is scored by
    // CI the moment it is added to root.zig, with no workflow edit to forget.
    check_step.dependOn(deps.conformance_step);
}
