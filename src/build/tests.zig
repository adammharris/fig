//! The test surface: the unit-test suite (`test`), the conformance run against
//! the vendored corpora (`conformance`), coverage-guided fuzzing (`fuzz`), and
//! installing the test binaries for debugging (`install-tests`). Returns the two
//! step handles the `check` gate folds in.

const std = @import("std");
const Context = @import("Context.zig");
const Options = @import("Options.zig");
const artifacts = @import("artifacts.zig");

/// The step handles `checks` wires into the `check` gate.
pub const Result = struct {
    test_step: *std.Build.Step,
    conformance_step: *std.Build.Step,
};

pub fn add(ctx: Context, arts: artifacts.Result) Result {
    const b = ctx.b;
    const target = ctx.target;
    const resolved_target = target.result;
    const mod = arts.fig_mod;
    const exe = arts.exe;

    const test_filters =
        b.option([]const []const u8, "test-filter", "Only run tests matching this filter") orelse &.{};

    const mod_tests = b.addTest(.{
        .root_module = mod,
        .filters = test_filters,
    });
    // `mod` already carries `build_options` (added in artifacts.zig); the test
    // artifact reuses that module, so no second `addOptions` is needed here.

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

    // The conformance corpora vendored into `testdata/` (~2.7k cases: the
    // upstream yaml-test-suite, toml-test, json5-tests, JSONTestSuite, the
    // NestedText suite, and the plist fixtures) sit behind the six
    // `-D*-conformance` flags, which default off so that a routine `zig build
    // test` stays fast. The cost of that default was that nothing ever passed the
    // flags — CI included — so the whole corpus sat dormant. This step exists so
    // that running them is automatic in the one place it has to be: the gate.
    //
    // The suites live in `mod`'s test block (see the `build_options.*_conformance`
    // branches at the bottom of src/root.zig), and options are baked into a module
    // at configure time — so scoring them needs a *variant* of `mod` carrying
    // different options, not a flag on `mod_tests`. Hence the second module and
    // the second `addOptions` instance (a second instance is also what keeps Zig
    // from rejecting one generated file shared by two modules — see `options_mod`
    // in artifacts.zig). Corpus paths are relative to the repo root, which is
    // where `zig build` always runs.
    const conformance_options_mod = Options.addFigOptions(b, Options.BuildOptions.all_on, ctx.ver).createModule();
    const conformance_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    conformance_mod.addImport("build_options", conformance_options_mod);
    // Same libc reasoning as `mod` in artifacts.zig: root.zig's test block pulls
    // in c_api.zig, which reaches for `std.heap.c_allocator` on every non-wasm
    // target.
    conformance_mod.link_libc = !resolved_target.cpu.arch.isWasm();

    const conformance_tests = b.addTest(.{
        .root_module = conformance_mod,
        .filters = test_filters,
    });
    const run_conformance_tests = b.addRunArtifact(conformance_tests);

    const conformance_step = b.step("conformance", "Score every format against its vendored conformance corpus in testdata/");
    conformance_step.dependOn(&run_conformance_tests.step);

    // Coverage-guided fuzzing for the hand-written tokenizers/parsers — the
    // targets themselves live in src/fuzz.zig. Conformance proves fig handles the
    // inputs somebody thought to write down; this is what goes looking for the
    // ones nobody did.
    //
    // Two things about `--fuzz` are worth knowing before touching this:
    //
    //   1. It is a build-RUNNER flag, not something build.zig can turn on. So the
    //      step alone does not fuzz — `zig build fuzz` just runs the targets once.
    //      To actually fuzz: `zig build fuzz --fuzz=1M`.
    //   2. Its argument is an ITERATION CAP, not a time budget, and omitting it
    //      implies `--webui` — a web server that runs until interrupted. That is
    //      lovely locally (live coverage view) and a hang in CI, which is why
    //      .github/workflows/fuzz.yml always passes an explicit `=<n>`.
    //
    // The vendored `.test_runner` is a temporary workaround for an upstream Zig
    // 0.16.0 bug that makes `--fuzz` fail to compile; tools/fuzz_test_runner.zig
    // explains it in full and says how to delete it. Scoping it to this one
    // artifact is deliberate: `test`, `conformance` and `check` all keep the
    // stock runner, so a stale vendored copy can never silently compromise the
    // release gate — the worst it can do is break `zig build fuzz`.
    // `.mode` must be `.server`: the build system drives fuzzing over
    // `std.zig.Server`, and a `.simple` runner reports "no fuzz tests found".
    const fuzz_tests = b.addTest(.{
        .root_module = mod,
        // Default to the src/fuzz.zig targets rather than the whole suite — under
        // `--fuzz` every non-fuzz test would otherwise be rebuilt with coverage
        // instrumentation for nothing. An explicit `-Dtest-filter` still wins, so
        // a single target can be driven on its own while working on a parser.
        .filters = if (test_filters.len > 0) test_filters else &.{"fuzz"},
        .test_runner = .{ .path = b.path("tools/fuzz_test_runner.zig"), .mode = .server },
    });
    const run_fuzz_tests = b.addRunArtifact(fuzz_tests);

    const fuzz_step = b.step("fuzz", "Fuzz the hand-written parsers — needs the runner flag too, e.g. `zig build fuzz --fuzz=1M`");
    fuzz_step.dependOn(&run_fuzz_tests.step);

    // Deliberately NOT wired into `check`. Fuzzing has no natural stopping point,
    // so it has no business on a release gate or the PR critical path; the nightly
    // workflow is where it runs for real. The targets still get smoke-tested on
    // every `zig build test` — src/root.zig imports src/fuzz.zig unconditionally,
    // so a target that stops compiling, leaks, or has its property broken fails
    // CI the normal way, and they cannot rot unnoticed between nightly runs.

    const install_tests_step = b.step("install-tests", "Install test executables for debugging");
    install_tests_step.dependOn(&install_mod_tests.step);

    return .{ .test_step = test_step, .conformance_step = conformance_step };
}
