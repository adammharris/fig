//! Build-time configuration: the `-D` feature knobs that get baked into the
//! `build_options` module every artifact imports.
//!
//! The package-identity constants (`version`, `abi_version`, `cli_version`,
//! `epoch`) deliberately live in `build.zig`, NOT here — external tooling
//! treats `build.zig` as their canonical home (e.g. `tools/version-floor.zig`
//! parses `cli_version` out of it), so they are passed in via `Versions` rather
//! than owned here.

const std = @import("std");

/// The package-identity numbers `addFigOptions` bakes into `build_options`.
/// Passed in from `build.zig` (their canonical home) so this module owns only
/// the knob machinery, not the identity.
pub const Versions = struct {
    /// The canonical package version (`build.zig.zon`'s `.version`, parsed in
    /// build.zig where that import path is shallow).
    core: std.SemanticVersion,
    /// The binary C ABI contract version.
    abi: u8,
    /// The `fig` CLI binary's own SemVer track.
    cli: std.SemanticVersion,
    /// The current marketing epoch.
    epoch: []const u8,
};

/// Every build-time knob baked into the `build_options` module.
///
/// This exists as a struct + `addFigOptions` rather than an inline block because
/// the option set is now constructed TWICE: once from the user's `-D` flags —
/// shared by the library, CLI, wasm and `zig build test` — and once with
/// everything forced on for `zig build conformance` (see that step below).
/// Options are baked into a module at configure time, so a step that needs
/// different values has no choice but to build its own `addOptions` instance;
/// funnelling both through one function is what keeps the two from drifting
/// apart as knobs get added.
pub const BuildOptions = struct {
    json_conformance: bool,
    json5_conformance: bool,
    yaml_conformance: bool,
    toml_conformance: bool,
    plist_conformance: bool,
    nestedtext_conformance: bool,
    lang_json: bool,
    lang_yaml: bool,
    lang_toml: bool,
    lang_zon: bool,
    lang_xml: bool,
    lang_fig: bool,
    lang_ini: bool,
    lang_dotenv: bool,
    lang_properties: bool,
    lang_plist: bool,
    lang_canonical: bool,
    lang_nestedtext: bool,

    /// The configuration `zig build conformance` builds: every suite and every
    /// language on, independent of whatever `-D` flags the caller passed, so the
    /// gate means the same thing on every machine.
    ///
    /// Forcing the six suites on is the point of the step. Forcing all twelve
    /// languages on is a deliberate second win: xml, plist and canonical are all
    /// off by default, so nothing else in CI ever compiles them together — this
    /// is the only build that proves the everything-on configuration still
    /// builds at all.
    pub const all_on: BuildOptions = .{
        .json_conformance = true,
        .json5_conformance = true,
        .yaml_conformance = true,
        .toml_conformance = true,
        .plist_conformance = true,
        .nestedtext_conformance = true,
        .lang_json = true,
        .lang_yaml = true,
        .lang_toml = true,
        .lang_zon = true,
        .lang_xml = true,
        .lang_fig = true,
        .lang_ini = true,
        .lang_dotenv = true,
        .lang_properties = true,
        .lang_plist = true,
        .lang_canonical = true,
        .lang_nestedtext = true,
    };
};

/// Read every `-D` flag into a `BuildOptions`. Called once from `build.zig` for
/// the user-facing configuration; `zig build conformance` uses
/// `BuildOptions.all_on` instead of calling this.
pub fn resolve(b: *std.Build) BuildOptions {
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

    return .{
        .json_conformance = run_conformance,
        .json5_conformance = run_json5_conformance,
        .yaml_conformance = run_yaml_conformance,
        .toml_conformance = run_toml_conformance,
        .plist_conformance = run_plist_conformance,
        .nestedtext_conformance = run_nestedtext_conformance,
        .lang_json = enable_json,
        .lang_yaml = enable_yaml,
        .lang_toml = enable_toml,
        .lang_zon = enable_zon,
        .lang_xml = enable_xml,
        .lang_fig = enable_fig,
        .lang_ini = enable_ini,
        .lang_dotenv = enable_dotenv,
        .lang_properties = enable_properties,
        .lang_plist = enable_plist,
        .lang_canonical = enable_canonical,
        .lang_nestedtext = enable_nestedtext,
    };
}

/// Build one `build_options` instance from `cfg` and `ver`. The version/ABI
/// values come in via `ver` rather than being owned here because they are
/// canonical facts about the package (their home is `build.zig`) rather than
/// knobs — every build gets the same ones.
pub fn addFigOptions(b: *std.Build, cfg: BuildOptions, ver: Versions) *std.Build.Step.Options {
    const options = b.addOptions();
    options.addOption(bool, "json_conformance", cfg.json_conformance);
    options.addOption(bool, "json5_conformance", cfg.json5_conformance);
    options.addOption(bool, "yaml_conformance", cfg.yaml_conformance);
    options.addOption(bool, "toml_conformance", cfg.toml_conformance);
    options.addOption(bool, "plist_conformance", cfg.plist_conformance);
    options.addOption(bool, "nestedtext_conformance", cfg.nestedtext_conformance);
    // Language gates, consumed across the codebase as `build_options.lang_*`.
    options.addOption(bool, "lang_json", cfg.lang_json);
    options.addOption(bool, "lang_yaml", cfg.lang_yaml);
    options.addOption(bool, "lang_toml", cfg.lang_toml);
    options.addOption(bool, "lang_zon", cfg.lang_zon);
    options.addOption(bool, "lang_xml", cfg.lang_xml);
    options.addOption(bool, "lang_fig", cfg.lang_fig);
    options.addOption(bool, "lang_ini", cfg.lang_ini);
    options.addOption(bool, "lang_dotenv", cfg.lang_dotenv);
    options.addOption(bool, "lang_properties", cfg.lang_properties);
    options.addOption(bool, "lang_plist", cfg.lang_plist);
    options.addOption(bool, "lang_canonical", cfg.lang_canonical);
    options.addOption(bool, "lang_nestedtext", cfg.lang_nestedtext);
    // Library version surfaced through the C ABI (`fig_version` /
    // `fig_version_string`). Parsed from `.version` in `build.zig.zon` — the one
    // canonical package version — and split into the components the ABI's
    // packed-integer/string accessors need. `zig build abi-check` separately
    // asserts that bindings/c/include/fig.h's FIG_VERSION_* macros match this same source.
    options.addOption(u8, "version_major", @intCast(ver.core.major));
    options.addOption(u8, "version_minor", @intCast(ver.core.minor));
    options.addOption(u8, "version_patch", @intCast(ver.core.patch));
    // The binary C ABI contract version, surfaced through `fig_abi_version()`.
    // `zig build abi-check` asserts bindings/c/include/fig.h's FIG_ABI_VERSION matches this.
    options.addOption(u8, "abi_version", ver.abi);
    // The CLI's own version (see `cli_version`'s doc comment in build.zig),
    // surfaced by `fig version` alongside the embedded core version.
    options.addOption(u8, "cli_version_major", @intCast(ver.cli.major));
    options.addOption(u8, "cli_version_minor", @intCast(ver.cli.minor));
    options.addOption(u8, "cli_version_patch", @intCast(ver.cli.patch));
    // The current marketing epoch (see `epoch`'s doc comment in build.zig),
    // surfaced only by `fig version` — no ABI/library counterpart.
    options.addOption([]const u8, "epoch", ver.epoch);
    return options;
}
