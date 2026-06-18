const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug information") orelse (optimize == .ReleaseSmall);
    const resolved_target = target.result;
    const run_conformance = b.option(bool, "json-conformance", "Run JSON conformance tests") orelse false;
    const run_yaml_conformance = b.option(bool, "yaml-conformance", "Run YAML conformance tests") orelse false;
    const run_toml_conformance = b.option(bool, "toml-conformance", "Run TOML conformance tests") orelse false;

    const options = b.addOptions();
    options.addOption(bool, "json_conformance", run_conformance);
    options.addOption(bool, "yaml_conformance", run_yaml_conformance);
    options.addOption(bool, "toml_conformance", run_toml_conformance);


    const mod = b.addModule("fig", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

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
    const install_c_lib = b.addInstallArtifact(c_lib, .{});
    b.getInstallStep().dependOn(&install_c_lib.step);

    const install_c_lib_step = b.step("install-c-lib", "Install the C ABI static library");
    install_c_lib_step.dependOn(&install_c_lib.step);

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

    const test_filters =
        b.option([]const []const u8, "test-filter", "Only run tests matching this filter")
        orelse &.{};

    const mod_tests = b.addTest(.{
        .root_module = mod,
        .filters = test_filters,
    });

    mod_tests.root_module.addOptions("build_options", options);

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
