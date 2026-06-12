const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug information") orelse (optimize == .ReleaseSmall);
    const resolved_target = target.result;
    const run_conformance = b.option(bool, "json-conformance", "Run JSON conformance tests") orelse false;
    const run_yaml_conformance = b.option(bool, "yaml-conformance", "Run YAML conformance tests") orelse false;

    const options = b.addOptions();
    options.addOption(bool, "json_conformance", run_conformance);
    options.addOption(bool, "yaml_conformance", run_yaml_conformance);


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
