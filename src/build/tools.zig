//! Developer/maintenance tooling: vendoring the Zig source into the Rust crate,
//! regenerating the conformance corpora, the figl → generated-file sync, and the
//! version bumper. None of these run on a normal build; they are explicit steps
//! a maintainer invokes (a few are wired into the `check` gate via the handles
//! returned in `Result`).

const std = @import("std");
const Context = @import("Context.zig");
const artifacts = @import("artifacts.zig");

/// Handles the `checks` gate needs to depend on.
pub const Result = struct {
    /// The generated-file staleness guard (`build.zig.zon` + the workflows),
    /// which `zig build check` runs.
    check_figl_step: *std.Build.Step,
};

pub fn add(ctx: Context, arts: artifacts.Result) Result {
    const b = ctx.b;
    const target = ctx.target;
    const optimize = ctx.optimize;
    const mod = arts.fig_mod;
    const exe = arts.exe;

    // Vendor this Zig source into fig-sys (bindings/rust/fig-sys/zig) so the
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
    vendor_rust_run.addArg(b.pathFromRoot("bindings/rust/fig-sys/zig"));
    const vendor_rust_step = b.step("vendor-rust", "Vendor the Zig source into the Rust crate for publishing");
    vendor_rust_step.dependOn(&vendor_rust_run.step);

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

    // The writer counterpart of version-floor: set/bump one artifact's version
    // and keep every coupled field valid in one shot (the fig-wasi==cli pin, the
    // fig-macros pin, the artifact>=core floor, and fig.md's frontmatter version
    // — see docs/VERSIONING.md). It rewrites the real manifests (not addFileArg
    // cache copies), so it takes the repo root like sync-figl and is marked
    // has_side_effects. Not part of `check` — it mutates the tree rather than
    // guarding it. The `--` args (<artifact> <version|major|minor|patch>
    // [--dry-run]) are forwarded through. It also takes the just-built `fig`
    // binary itself (same self-hosting pattern as sync-figl below) so it can
    // sync fig.md's frontmatter with `fig set` instead of hand-parsing markdown.
    const version_set = b.addExecutable(.{
        .name = "version_set",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/version-set.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const version_set_run = b.addRunArtifact(version_set);
    version_set_run.addArtifactArg(exe);
    version_set_run.addArg(b.pathFromRoot("."));
    if (b.args) |args| version_set_run.addArgs(args);
    version_set_run.has_side_effects = true;
    const version_set_step = b.step("version-set", "Set/bump an artifact's version (core|cli|rust|npm) and keep the pins/floor valid");
    version_set_step.dependOn(&version_set_run.step);

    // The `.figl` files under figl/ (build.zig.figl, ci.figl, fuzz.figl,
    // homebrew.figl, release-binaries.figl, release.figl, release-npm.figl,
    // release-npm-wasi.figl) are the source of truth for their generated
    // counterparts (build.zig.zon, the six .github/workflows/*.yml files) —
    // the inverse of the usual setup,
    // dogfooding fig's own cross-format conversion for fig's own release
    // infra. This tool shells out to the just-built `fig` binary (`fig get -o
    // <format>`) to regenerate them; it never re-implements parsing/printing
    // itself. `sync-figl` writes; `check-figl` (used by CI and the pre-commit
    // hook, via `zig build check`) fails if a destination is stale, without
    // writing. Git state (the destination files) isn't a declared input, so
    // neither run may be served from cache.
    const sync_figl = b.addExecutable(.{
        .name = "sync_figl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/sync-figl.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const sync_figl_run = b.addRunArtifact(sync_figl);
    sync_figl_run.addArtifactArg(exe);
    sync_figl_run.addArg(b.pathFromRoot("."));
    sync_figl_run.has_side_effects = true;
    const sync_figl_step = b.step("sync-figl", "Regenerate build.zig.zon + the .github/workflows/*.yml files from their .figl sources");
    sync_figl_step.dependOn(&sync_figl_run.step);

    const check_figl_run = b.addRunArtifact(sync_figl);
    check_figl_run.addArtifactArg(exe);
    check_figl_run.addArg(b.pathFromRoot("."));
    check_figl_run.addArg("--check");
    check_figl_run.has_side_effects = true;
    const check_figl_step = b.step("check-figl", "Fail if build.zig.zon / .github/workflows/*.yml are stale relative to their .figl sources");
    check_figl_step.dependOn(&check_figl_run.step);

    return .{ .check_figl_step = check_figl_step };
}
