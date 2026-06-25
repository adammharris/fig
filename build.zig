const std = @import("std");

/// The canonical package version, parsed once from `build.zig.zon`'s `.version`
/// so the C ABI's `fig_version*` accessors and the version-drift check both read
/// from a single source instead of a hand-synced trio of integers.
const version = std.SemanticVersion.parse(@import("build.zig.zon").version) catch
    @compileError("invalid `.version` in build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug information") orelse (optimize == .ReleaseSmall);
    const resolved_target = target.result;
    const run_conformance = b.option(bool, "json-conformance", "Run JSON conformance tests") orelse false;
    const run_json5_conformance = b.option(bool, "json5-conformance", "Run JSON5 conformance tests") orelse false;
    const run_yaml_conformance = b.option(bool, "yaml-conformance", "Run YAML conformance tests") orelse false;
    const run_toml_conformance = b.option(bool, "toml-conformance", "Run TOML conformance tests") orelse false;
    const run_xml_conformance = b.option(bool, "xml-conformance", "Run XML conformance tests") orelse false;

    // Per-language feature gates. Any format can be compiled out to shrink the
    // binary and drop its parser/printer — including JSON, now that the native
    // `.fig` format exists and `Language.detect()` sniffs every compiled-in
    // language rather than assuming a JSON base. A build with no language at all
    // is rejected at the call sites that need one (e.g. the C ABI editor union).
    // Default: everything on.
    const enable_json = b.option(bool, "json", "Include JSON/JSONC/JSON5 support") orelse true;
    const enable_yaml = b.option(bool, "yaml", "Include YAML support") orelse true;
    const enable_toml = b.option(bool, "toml", "Include TOML support") orelse true;
    const enable_zon = b.option(bool, "zon", "Include ZON support") orelse true;
    const enable_xml = b.option(bool, "xml", "Include XML support") orelse true;

    const options = b.addOptions();
    options.addOption(bool, "json_conformance", run_conformance);
    options.addOption(bool, "json5_conformance", run_json5_conformance);
    options.addOption(bool, "yaml_conformance", run_yaml_conformance);
    options.addOption(bool, "toml_conformance", run_toml_conformance);
    options.addOption(bool, "xml_conformance", run_xml_conformance);
    // Language gates, consumed across the codebase as `build_options.lang_*`.
    options.addOption(bool, "lang_json", enable_json);
    options.addOption(bool, "lang_yaml", enable_yaml);
    options.addOption(bool, "lang_toml", enable_toml);
    options.addOption(bool, "lang_zon", enable_zon);
    options.addOption(bool, "lang_xml", enable_xml);
    // Library version surfaced through the C ABI (`fig_version` /
    // `fig_version_string`). Parsed from `.version` in `build.zig.zon` — the one
    // canonical package version — and split into the components the ABI's
    // packed-integer/string accessors need. `zig build abi-check` separately
    // asserts that include/fig.h's FIG_VERSION_* macros match this same source.
    options.addOption(u8, "version_major", @intCast(version.major));
    options.addOption(u8, "version_minor", @intCast(version.minor));
    options.addOption(u8, "version_patch", @intCast(version.patch));

    // Build the options module once and share the single instance across every
    // target. Calling `addOptions` per-module would generate a fresh module from
    // the same generated file, which Zig rejects ("file belongs to two modules").
    const options_mod = options.createModule();


    const mod = b.addModule("fig", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    mod.addImport("build_options", options_mod);
    // `root.zig`'s `test {}` block pulls in `c_api.zig`, which uses
    // `std.heap.c_allocator` on non-wasm targets — that allocator is only
    // available when linking libc. macOS links libc implicitly, so the test
    // suite builds there regardless, but Linux requires it to be explicit or the
    // module-test compile fails. WebAssembly uses `wasm_allocator` and must not
    // link libc, so gate on the architecture.
    mod.link_libc = !resolved_target.cpu.arch.isWasm();

    const exe = b.addExecutable(.{
        .name = "fig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .imports = &.{
                .{ .name = "fig", .module = mod },
            },
        }),
    });
    exe.root_module.addImport("build_options", options_mod);

    b.installArtifact(exe);

    const c_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "fig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_api.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .link_libc = !resolved_target.cpu.arch.isWasm(),
        }),
    });
    c_lib.root_module.addImport("build_options", options_mod);
    const install_c_lib = b.addInstallArtifact(c_lib, .{});
    b.getInstallStep().dependOn(&install_c_lib.step);

    const install_c_lib_step = b.step("install-c-lib", "Install the C ABI static library");
    install_c_lib_step.dependOn(&install_c_lib.step);

    // Vendor this Zig source into the Rust crate (bindings/rust/fig/zig) so the
    // published crate is self-contained — build.rs compiles the core from there
    // when there is no repo above it. A small Zig program rather than a shell
    // script, so it runs anywhere the crate's own `zig build` already does.
    const vendor_rust = b.addExecutable(.{
        .name = "vendor_rust",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/vendor-rust.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const vendor_rust_run = b.addRunArtifact(vendor_rust);
    vendor_rust_run.addArg(b.pathFromRoot("."));
    vendor_rust_run.addArg(b.pathFromRoot("bindings/rust/fig/zig"));
    const vendor_rust_step = b.step("vendor-rust", "Vendor the Zig source into the Rust crate for publishing");
    vendor_rust_step.dependOn(&vendor_rust_run.step);

    // WebAssembly build for the TypeScript bindings: compile the same C ABI to a
    // freestanding `reactor` module (no `_start`; `rdynamic` keeps every
    // exported `fig_*` symbol). `c_api.zig` already selects `wasm_allocator` and
    // drops logging on wasm, so no libc is needed. `zig build wasm` writes
    // `fig.wasm` into the install prefix's `bin/`.
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const wasm = b.addExecutable(.{
        .name = "fig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_api.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
            .strip = true,
        }),
    });
    wasm.root_module.addImport("build_options", options_mod);
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    const install_wasm = b.addInstallArtifact(wasm, .{});
    const wasm_step = b.step("wasm", "Build the WebAssembly module for the TypeScript bindings");
    wasm_step.dependOn(&install_wasm.step);

    // WASI build of the *CLI* (`main.zig`), distinct from the freestanding
    // `fig.wasm` above. This is a real `_start` command module: run it with a
    // WASI runtime, e.g. `wasmtime run --dir=.::. zig-out/bin/fig-wasi.wasm get foo.yaml`.
    // File access is capability-gated, so map a dir onto the guest cwd (`--dir`).
    const wasi_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi });
    const wasi_mod = b.addModule("fig-wasi", .{
        .root_source_file = b.path("src/root.zig"),
        .target = wasi_target,
    });
    wasi_mod.addImport("build_options", options_mod);
    const wasi_cli = b.addExecutable(.{
        .name = "fig-wasi",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = wasi_target,
            .optimize = .ReleaseSmall,
            .strip = true,
            .imports = &.{
                .{ .name = "fig", .module = wasi_mod },
            },
        }),
    });
    wasi_cli.root_module.addImport("build_options", options_mod);
    const install_wasi = b.addInstallArtifact(wasi_cli, .{});
    const wasi_step = b.step("wasi", "Build the fig CLI as a WASI module (fig-wasi.wasm)");
    wasi_step.dependOn(&install_wasi.step);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Dev tool: regenerate the YAML conformance corpus from the yaml-test-suite,
    // parsing the suite meta-files with fig itself (no third-party YAML library).
    //   zig build gen-yaml-conformance -- <path-to-yaml-test-suite> [<fig-root>]
    const gen_yaml = b.addExecutable(.{
        .name = "gen_yaml_conformance",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_yaml_conformance.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "fig", .module = mod }},
        }),
    });
    const gen_yaml_run = b.addRunArtifact(gen_yaml);
    if (b.args) |args| gen_yaml_run.addArgs(args);
    const gen_yaml_step = b.step("gen-yaml-conformance", "Regenerate the YAML conformance corpus");
    gen_yaml_step.dependOn(&gen_yaml_run.step);

    // Dev tool: STRUCTURAL conformance — compare the shape of fig's parse against
    // the suite's canonical `tree:` event stream (the pass/fail scoreboard can't
    // see a wrong-shape accept). zig build check-yaml-trees -- <suite> [<fig-root>]
    const check_trees = b.addExecutable(.{
        .name = "check_yaml_trees",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/check_yaml_trees.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "fig", .module = mod }},
        }),
    });
    const check_trees_run = b.addRunArtifact(check_trees);
    if (b.args) |args| check_trees_run.addArgs(args);
    const check_trees_step = b.step("check-yaml-trees", "Structural-diff fig's parse vs the suite tree");
    check_trees_step.dependOn(&check_trees_run.step);

    // Dev tool: vendor the toml-lang/toml-test corpus into testdata/toml/.
    //   zig build gen-toml-conformance -- <path-to-toml-test> [<version>] [<fig-root>]
    const gen_toml = b.addExecutable(.{
        .name = "gen_toml_conformance",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_toml_conformance.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "fig", .module = mod }},
        }),
    });
    const gen_toml_run = b.addRunArtifact(gen_toml);
    if (b.args) |args| gen_toml_run.addArgs(args);
    const gen_toml_step = b.step("gen-toml-conformance", "Vendor the toml-test corpus");
    gen_toml_step.dependOn(&gen_toml_run.step);

    // Dev tool: vendor the json5/json5-tests corpus into testdata/json5/.
    //   zig build gen-json5-conformance -- <path-to-json5-tests> [<fig-root>]
    const gen_json5 = b.addExecutable(.{
        .name = "gen_json5_conformance",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_json5_conformance.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "fig", .module = mod }},
        }),
    });
    const gen_json5_run = b.addRunArtifact(gen_json5);
    if (b.args) |args| gen_json5_run.addArgs(args);
    const gen_json5_step = b.step("gen-json5-conformance", "Vendor the json5-tests corpus");
    gen_json5_step.dependOn(&gen_json5_run.step);

    // ABI surface check: keep the C ABI implementation (src/c_api.zig), the
    // public header (include/fig.h), and the built library in agreement.
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
    abi_check_run.addFileArg(b.path("include/fig.h"));
    abi_check_run.addFileArg(b.path("src/c_api.zig"));
    // The canonical version (from build.zig.zon) so the tool can assert that
    // fig.h's FIG_VERSION_* macros have not drifted from it.
    abi_check_run.addArg(b.fmt("{d}.{d}.{d}", .{ version.major, version.minor, version.patch }));

    const abi_probe_c = b.addExecutable(.{
        .name = "abi_probe_c",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    abi_probe_c.root_module.addCSourceFile(.{ .file = b.path("tools/abi_probe.c") });
    abi_probe_c.root_module.addIncludePath(b.path("include"));
    abi_probe_c.root_module.linkLibrary(c_lib);

    const abi_probe_cpp = b.addExecutable(.{
        .name = "abi_probe_cpp",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true, .link_libcpp = true }),
    });
    abi_probe_cpp.root_module.addCSourceFile(.{ .file = b.path("tools/abi_probe.cpp") });
    abi_probe_cpp.root_module.addIncludePath(b.path("include"));
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
    semver_check_run.addFileArg(b.path("include/fig.h"));
    semver_check_run.addArg(b.fmt("{d}.{d}.{d}", .{ version.major, version.minor, version.patch }));
    semver_check_run.addArg(b.pathFromRoot("."));
    // git state isn't a declared input, so never serve this from cache.
    semver_check_run.has_side_effects = true;
    const semver_check_step = b.step("semver-check", "Diff the C ABI vs the last release tag and verify the version bump");
    semver_check_step.dependOn(&semver_check_run.step);

    const test_filters =
        b.option([]const []const u8, "test-filter", "Only run tests matching this filter")
        orelse &.{};

    const mod_tests = b.addTest(.{
        .root_module = mod,
        .filters = test_filters,
    });
    // `mod` already carries `build_options` (added above); the test artifact
    // reuses that module, so no second `addOptions` is needed here.

    const install_mod_tests = b.addInstallArtifact(mod_tests, .{
        .dest_sub_path = "fig-tests",
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
        .filters = test_filters,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    const install_tests_step = b.step("install-tests", "Install test executables for debugging");
    install_tests_step.dependOn(&install_mod_tests.step);
}
