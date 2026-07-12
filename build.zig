const std = @import("std");

/// The canonical package version, parsed once from `build.zig.zon`'s `.version`
/// so the C ABI's `fig_version*` accessors and the version-drift check both read
/// from a single source instead of a hand-synced trio of integers.
const version = std.SemanticVersion.parse(@import("build.zig.zon").version) catch
    @compileError("invalid `.version` in build.zig.zon");

/// The binary C ABI contract version (see `FIG_ABI_VERSION` in bindings/c/include/fig.h).
/// Canonical source of truth — surfaced to the C ABI as `fig_abi_version()` and
/// pinned to the header macro by `zig build abi-check`. A monotonic counter,
/// bumped ONLY on a breaking ABI change (which fig's forward-compat policy makes
/// rare); decoupled from the marketing `.version` above so a feature release does
/// not move it. `zig build semver-check` requires it to increment whenever the C
/// ABI diff against the last release tag is breaking.
const abi_version: u8 = 1;

/// The `fig` CLI binary's OWN SemVer track — independent of `.version` above,
/// the same way the Rust crate and npm package are independent of it (see
/// "Independent versioning" in docs/VERSIONING.md). The CLI's compatibility
/// contract is its flags/defaults/exit codes, not the library API or the C
/// ABI, so a CLI-only breaking change (e.g. flipping a flag's default) bumps
/// this without forcing a core/ABI release, and vice versa — a core-only
/// change doesn't force a CLI bump. The one invariant tying it to core: it
/// must stay >= `version` above (enforced by `zig build version-floor`,
/// alongside the Rust/npm floor checks), since the CLI always embeds
/// whatever core it's built against. Surfaced via `fig version`, which prints
/// both numbers.
const cli_version = std.SemanticVersion.parse("3.5.0") catch
    @compileError("invalid cli_version");

/// The current "epoch" — a marketing name that changes far less often than
/// `version`'s major (see docs/VERSIONING.md: "major releases are not
/// sacred," so this exists precisely to give users a stable, human-facing
/// handle across a run of otherwise-eager SemVer bumps). Purely cosmetic —
/// no compatibility contract, so it lives here as a bare constant (like
/// `abi_version`/`cli_version`) rather than in build.zig.zon (a
/// toolchain-parsed package manifest with its own schema) or the C ABI (which
/// only ever exposes things a consumer might actually branch on). Surfaced
/// only by the CLI's `fig version`.
const epoch = "Sierra";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug information") orelse (optimize == .ReleaseSmall);
    const resolved_target = target.result;
    const run_conformance = b.option(bool, "json-conformance", "Run JSON conformance tests") orelse false;
    const run_json5_conformance = b.option(bool, "json5-conformance", "Run JSON5 conformance tests") orelse false;
    const run_yaml_conformance = b.option(bool, "yaml-conformance", "Run YAML conformance tests") orelse false;
    const run_toml_conformance = b.option(bool, "toml-conformance", "Run TOML conformance tests") orelse false;
    const run_plist_conformance = b.option(bool, "plist-conformance", "Run plist conformance tests") orelse false;
    const run_nestedtext_conformance = b.option(bool, "nestedtext-conformance", "Run NestedText conformance tests") orelse false;

    // Per-language feature gates. Any format can be compiled out to shrink the
    // binary and drop its parser/printer — including JSON, now that the native
    // `.fig` format exists and `Language.detect()` sniffs every compiled-in
    // language rather than assuming a JSON base. A build with no language at all
    // is rejected at the call sites that need one (e.g. the C ABI editor union).
    // Default: everything on, EXCEPT xml — it stays opt-in (`-Dxml=true`) even
    // in a full build. Generic XML is a demoted, best-effort *fold* (attributes/
    // `#text` collapse, no typed scalars, single-root-key output), NOT a
    // first-class config format, and it is slated for removal as a selectable
    // format in a future major (see `docs/BREAKING-CHANGES.md`). What survives
    // that removal is the shared XML *lexing substrate* — `xml/tokenizer.zig` —
    // that typed flavors (plist, and future `.csproj`/manifest readers) sit on
    // top of; that layer is always compiled when any XML-family flavor is, so it
    // does not ride on this gate. The gate here controls only the generic
    // reader/printer, which is why non-users shouldn't pay for it by default.
    const enable_json = b.option(bool, "json", "Include JSON/JSONC/JSON5 support") orelse true;
    const enable_yaml = b.option(bool, "yaml", "Include YAML support") orelse true;
    const enable_toml = b.option(bool, "toml", "Include TOML support") orelse true;
    const enable_zon = b.option(bool, "zon", "Include ZON support") orelse true;
    const enable_xml = b.option(bool, "xml", "Include XML support (opt-in; default off)") orelse false;
    const enable_fig = b.option(bool, "fig", "Include the fig authoring dialect support") orelse true;
    const enable_ini = b.option(bool, "ini", "Include INI support") orelse true;
    const enable_dotenv = b.option(bool, "dotenv", "Include dotenv (.env) support") orelse true;
    const enable_properties = b.option(bool, "properties", "Include Java .properties support") orelse true;
    // plist (XML variant only so far): the newest, least battle-tested format
    // (no conformance harness wired up yet — see
    // `src/languages/plist/conformance.zig`), opt-in via `-Dplist=true`. Unlike
    // generic xml above, plist is a first-class typed flavor (typed scalars,
    // round-trips, in-place editor) and is the intended long-term home for
    // structured XML config — it is not slated for removal.
    const enable_plist = b.option(bool, "plist", "Include Apple XML property list support (opt-in; default off)") orelse false;
    // The canonical form is the AST's own 1:1 oracle encoding — invaluable in
    // tests but not exposed through the C ABI or any binding, so shipping it in
    // the default library/CLI/wasm is dead weight for everyone but the test
    // suite. Opt-in like xml (`-Dcanonical=true`); the code still compiles for
    // ANY test build regardless, gated as `lang_canonical or @import("builtin").is_test`.
    const enable_canonical = b.option(bool, "canonical", "Include the canonical oracle format (opt-in; default off — used mainly by the test suite)") orelse false;
    // NestedText (nestedtext.org): reader + printer + editor, untyped-string
    // scalars like INI. No conformance harness caveat like plist — the
    // official test suite (vendored to `testdata/nestedtext/tests.json`) is
    // wired up from the start. On by default like TOML/ZON/INI.
    const enable_nestedtext = b.option(bool, "nestedtext", "Include NestedText support") orelse true;

    const options = b.addOptions();
    options.addOption(bool, "json_conformance", run_conformance);
    options.addOption(bool, "json5_conformance", run_json5_conformance);
    options.addOption(bool, "yaml_conformance", run_yaml_conformance);
    options.addOption(bool, "toml_conformance", run_toml_conformance);
    options.addOption(bool, "plist_conformance", run_plist_conformance);
    options.addOption(bool, "nestedtext_conformance", run_nestedtext_conformance);
    // Language gates, consumed across the codebase as `build_options.lang_*`.
    options.addOption(bool, "lang_json", enable_json);
    options.addOption(bool, "lang_yaml", enable_yaml);
    options.addOption(bool, "lang_toml", enable_toml);
    options.addOption(bool, "lang_zon", enable_zon);
    options.addOption(bool, "lang_xml", enable_xml);
    options.addOption(bool, "lang_fig", enable_fig);
    options.addOption(bool, "lang_ini", enable_ini);
    options.addOption(bool, "lang_dotenv", enable_dotenv);
    options.addOption(bool, "lang_properties", enable_properties);
    options.addOption(bool, "lang_plist", enable_plist);
    options.addOption(bool, "lang_canonical", enable_canonical);
    options.addOption(bool, "lang_nestedtext", enable_nestedtext);
    // Library version surfaced through the C ABI (`fig_version` /
    // `fig_version_string`). Parsed from `.version` in `build.zig.zon` — the one
    // canonical package version — and split into the components the ABI's
    // packed-integer/string accessors need. `zig build abi-check` separately
    // asserts that bindings/c/include/fig.h's FIG_VERSION_* macros match this same source.
    options.addOption(u8, "version_major", @intCast(version.major));
    options.addOption(u8, "version_minor", @intCast(version.minor));
    options.addOption(u8, "version_patch", @intCast(version.patch));
    // The binary C ABI contract version, surfaced through `fig_abi_version()`.
    // `zig build abi-check` asserts bindings/c/include/fig.h's FIG_ABI_VERSION matches this.
    options.addOption(u8, "abi_version", abi_version);
    // The CLI's own version (see `cli_version`'s doc comment above), surfaced
    // by `fig version` alongside the embedded core version.
    options.addOption(u8, "cli_version_major", @intCast(cli_version.major));
    options.addOption(u8, "cli_version_minor", @intCast(cli_version.minor));
    options.addOption(u8, "cli_version_patch", @intCast(cli_version.patch));
    // The current marketing epoch (see `epoch`'s doc comment above),
    // surfaced only by `fig version` — no ABI/library counterpart.
    options.addOption([]const u8, "epoch", epoch);

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
            .root_source_file = b.path("src/cli/main.zig"),
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

    // fig-lsp: a Language Server (LSP over stdio) that wraps the fig parser to
    // publish its teaching diagnostics to editors. Thin shell over `mod`.
    const lsp_exe = b.addExecutable(.{
        .name = "fig-lsp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lsp/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .imports = &.{
                .{ .name = "fig", .module = mod },
            },
        }),
    });
    lsp_exe.root_module.addImport("build_options", options_mod);
    b.installArtifact(lsp_exe);

    const lsp_run = b.addRunArtifact(lsp_exe);
    const lsp_run_step = b.step("run-lsp", "Run the fig language server (LSP over stdio)");
    lsp_run_step.dependOn(&lsp_run.step);

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
            .root_source_file = b.path("src/cli/main.zig"),
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
    abi_check_run.addArg(b.fmt("{d}.{d}.{d}", .{ version.major, version.minor, version.patch }));
    // The canonical ABI version so the tool can assert fig.h's FIG_ABI_VERSION
    // macro matches the value compiled into `fig_abi_version()`.
    abi_check_run.addArg(b.fmt("{d}", .{abi_version}));

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
    semver_check_run.addArg(b.fmt("{d}.{d}.{d}", .{ version.major, version.minor, version.patch }));
    semver_check_run.addArg(b.pathFromRoot("."));
    // git state isn't a declared input, so never serve this from cache.
    semver_check_run.has_side_effects = true;
    const semver_check_step = b.step("semver-check", "Diff the C ABI vs the last release tag and verify the version bump");
    semver_check_step.dependOn(&semver_check_run.step);

    // Cross-artifact version floor. fig versions each artifact independently —
    // the Zig core (build.zig.zon), the CLI binary (`cli_version` above, in
    // this file), the Rust crate (bindings/rust/Cargo.toml), the npm package
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
    // CLI's own version — see `cli_version` above).
    version_floor_run.addFileArg(b.path("build.zig.zon"));
    version_floor_run.addFileArg(b.path("build.zig"));
    version_floor_run.addFileArg(b.path("bindings/rust/Cargo.toml"));
    version_floor_run.addFileArg(b.path("bindings/typescript/package.json"));
    version_floor_run.addFileArg(b.path("bindings/wasi/package.json"));
    const version_floor_step = b.step("version-floor", "Check each binding's version is >= the core version it embeds");
    version_floor_step.dependOn(&version_floor_run.step);

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

    // The `.figl` files under figl/ (build.zig.figl, ci.figl, ci-rust.figl,
    // ci-npm.figl, homebrew.figl, release-binaries.figl, release.figl,
    // release-npm.figl, release-npm-wasi.figl) are the source of truth for
    // their generated counterparts (build.zig.zon, the eight
    // .github/workflows/*.yml files) — the inverse of the usual setup,
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

    // One-stop release gate: every version/ABI guard behind a single command, so
    // "did I bump correctly?" is `zig build check` instead of remembering four
    // separate invocations across two build systems. It depends on the three Zig
    // guards above and additionally shells out to cargo-semver-checks — the only
    // guard that lives in cargo's world rather than zig's (it diffs the native
    // Rust API, which never crosses the C ABI the Zig tools inspect). A
    // TypeScript API guard can hang off this same step later the same way.
    const check_step = b.step("check", "Pre-release gate: zig test + abi/semver/floor/figl guards + cargo-semver-checks + rust & typescript tests (binding suites skip with a note if their toolchain is missing)");
    check_step.dependOn(abi_check_step);
    check_step.dependOn(semver_check_step);
    check_step.dependOn(version_floor_step);
    check_step.dependOn(check_figl_step);

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

    const test_filters =
        b.option([]const []const u8, "test-filter", "Only run tests matching this filter") orelse &.{};

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

    // The release gate runs the test suite too, so `zig build check` is the single
    // pre-release command: tests pass AND every version/ABI guard is satisfied.
    check_step.dependOn(test_step);

    const install_tests_step = b.step("install-tests", "Install test executables for debugging");
    install_tests_step.dependOn(&install_mod_tests.step);
}
