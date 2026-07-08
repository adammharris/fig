const std = @import("std");
const Allocator = std.mem.Allocator;
const build_options = @import("build_options");

pub const Language = @This();

// Per-language gates: a compiled-out format resolves to `void`, so its module is
// never referenced and never built. Every call site that touches a gated
// `Language.*` must guard the access behind the same `build_options.lang_*`
// flag (a `comptime` check), or it will fail to compile against `void`. JSON is
// gateable like the rest now that `detect` no longer assumes it as a base.
pub const JSON = if (build_options.lang_json) @import("json/json.zig").Language else void;
pub const YAML = if (build_options.lang_yaml) @import("yaml/yaml.zig").Language else void;
pub const TOML = if (build_options.lang_toml) @import("toml/toml.zig").Language else void;
pub const ZON = if (build_options.lang_zon) @import("zon/zon.zig").Language else void;
pub const XML = if (build_options.lang_xml) @import("xml/xml.zig").Language else void;
pub const FIG = if (build_options.lang_fig) @import("fig/fig.zig").Language else void;
pub const INI = if (build_options.lang_ini) @import("ini/ini.zig").Language else void;
pub const DOTENV = if (build_options.lang_dotenv) @import("dotenv/dotenv.zig").Language else void;
pub const PROPERTIES = if (build_options.lang_properties) @import("properties/properties.zig").Language else void;
pub const PLIST = if (build_options.lang_plist) @import("plist/plist.zig").Language else void;
pub const NESTEDTEXT = if (build_options.lang_nestedtext) @import("nestedtext/nestedtext.zig").Language else void;

/// A format `detect` can recognize. The `jsonc` dialect and `canonical` are
/// deliberately excluded: jsonc overlaps json/json5 on most input, and
/// canonical is an explicit selection rather than something to sniff. `fig`
/// IS included, but slotted just ahead of YAML (see the ordering note on
/// `detect`) since its grammar overlaps TOML/YAML on plain `key = value`
/// content — it only wins detection on input that is either invalid for
/// every stricter format, or uses fig-only structural syntax (`>` section
/// depth, `*` elements, `+` continuations, `[]` group headers).
pub const Detected = enum { json, json5, yaml, toml, zon, xml, fig, ini, dotenv, properties, plist, nestedtext };

/// Best-effort content sniffing: try each COMPILED-IN parser and return the
/// first that accepts `input`, or null if none do (also what an
/// all-languages-disabled build returns). Order matters because the grammars
/// overlap — from most to least strict: JSON/JSON5, ZON, XML, TOML, then fig,
/// then INI, then YAML. fig sits just before INI/YAML, not after: YAML is so
/// permissive (a bare line is a valid plain scalar) that almost anything falls
/// through to it, which would starve fig (and INI) of a turn if it went last.
/// fig itself overlaps TOML heavily (both accept plain `key = value`), so it is
/// tried only after TOML has had first claim — a plain TOML-shaped document
/// still resolves to `.toml`, and fig only wins on content TOML can't parse
/// (its `>`/`*`/`+`/`[]` structural markers) or that is otherwise TOML-invalid.
/// INI overlaps TOML/fig too (same `[section]`/`key = value` shape) but accepts
/// strictly more — any raw, unquoted value text — so it sits right after fig
/// and wins only what both of those reject. dotenv sits last of the four
/// key/value-shaped formats since INI's grammar shadows almost all of it too
/// (see the `dotenv` branch below for the one thing that doesn't). This is a
/// heuristic, not a proof: input valid as more than one format resolves to
/// the earliest candidate in this order.
pub fn detect(allocator: Allocator, input: []const u8) ?Detected {
    if (comptime build_options.lang_json) {
        if (tryParse(JSON, allocator, input, .JSON)) return .json;
        if (tryParse(JSON, allocator, input, .JSON5)) return .json5;
    }
    if (comptime build_options.lang_zon) {
        if (tryParse(ZON, allocator, input, ZON.default_type)) return .zon;
    }
    if (comptime build_options.lang_plist) {
        // plist's DTD vocabulary (`<dict>`/`<array>`/`<key>`/...) is a STRICT
        // SUBSET of well-formed XML: the generic XML reader below would also
        // happily accept any real plist document, just folding it into a
        // differently-shaped AST (attribute/`#text` folding, no typed
        // scalars). So plist must get first claim, or a compiled-in XML
        // reader would starve it completely — the reverse isn't a problem:
        // plist's own grammar rejects anything outside its fixed element
        // vocabulary (`error.UnknownElement`), so ordinary XML falls through
        // to the `.xml` branch below untouched.
        if (tryParse(PLIST, allocator, input, PLIST.default_type)) return .plist;
    }
    if (comptime build_options.lang_xml) {
        if (tryParse(XML, allocator, input, XML.default_type)) return .xml;
    }
    if (comptime build_options.lang_toml) {
        if (tryParse(TOML, allocator, input, TOML.default_type)) return .toml;
    }
    if (comptime build_options.lang_fig) {
        if (tryParse(FIG, allocator, input, FIG.default_type)) return .fig;
    }
    if (comptime build_options.lang_ini) {
        // INI's grammar is also permissive (a bare `key = value` line, or an
        // empty file, both parse), so it's tried only after everything
        // stricter above has had first claim — it wins only on content those
        // reject, e.g. a `[section]` header or an unquoted value with
        // characters no TOML/fig scalar allows (`path = C:\a\b`).
        if (tryParse(INI, allocator, input, INI.default_type)) return .ini;
    }
    if (comptime build_options.lang_dotenv) {
        // dotenv is almost entirely shadowed by INI above: INI's key scanner
        // accepts any non-`=`/newline run (so even `export FOO=bar` parses as
        // one weird INI key) and its value decoding is quote-agnostic, so
        // nearly anything dotenv accepts, INI already claimed first. The one
        // thing only dotenv parses — a `"`/`'`-quoted value spanning a literal
        // embedded newline (INI's value never crosses a physical line) — is
        // this branch's actual reason to exist; `.env`'s real path to
        // selection is its extension (`detectLanguageFromFileEnding`
        // special-cases the `env` extension), not this content sniff.
        if (tryParse(DOTENV, allocator, input, DOTENV.default_type)) return .dotenv;
    }
    if (comptime build_options.lang_yaml) {
        if (tryParse(YAML, allocator, input, YAML.default_type)) return .yaml;
    }
    if (comptime build_options.lang_properties) {
        // `.properties` is even more permissive than YAML: a line with no
        // separator at all is still legal (a bare key, empty value — see
        // `properties/tokenizer.zig`), so nearly any UTF-8 text parses. It
        // therefore sits LAST, after YAML — the one thing this format
        // accepts that YAML rejects outright is a malformed-YAML shape
        // (see the test below); `.properties`'s real path to selection is
        // its extension, same as `.env`.
        if (tryParse(PROPERTIES, allocator, input, PROPERTIES.default_type)) return .properties;
    }
    if (comptime build_options.lang_nestedtext) {
        // NestedText goes LAST, after even `.properties` — not because its
        // own grammar is unusually permissive (it isn't: keys/values have
        // real restrictions, unlike `.properties`'s "nearly any text"), but
        // because a huge, ordinary swath of it — plain `key: value` lines
        // and `- item` lists — is ALSO valid YAML, and parses to a MEANINGFULLY
        // DIFFERENT tree there (YAML types `port: 80` as an integer;
        // NestedText's `port` is the untyped string `"80"`). Trying this
        // before YAML would silently change what today's `detect()` returns
        // for ordinary plain-YAML content already relied upon elsewhere in
        // this codebase — a real regression, not just an academic ambiguity
        // — so NestedText only gets a turn once every stricter-or-equally-
        // plausible format (including YAML) has already rejected the input.
        // Its real path to selection is the `.nt` extension (see
        // `cli/args.zig`), exactly like dotenv/`.properties` above.
        if (tryParse(NESTEDTEXT, allocator, input, NESTEDTEXT.default_type)) return .nestedtext;
    }
    return null;
}

/// Parse with `Lang` and report only whether it succeeded, releasing the document
/// either way. The detection probe — content is parsed, never retained.
fn tryParse(comptime Lang: type, allocator: Allocator, input: []const u8, t: Lang.Type) bool {
    const doc = Lang.Parser.parse(allocator, input, t) catch return false;
    doc.deinit(allocator);
    return true;
}

pub fn validate(comptime Lang: type) void {
    comptime {
        if (!@hasDecl(Lang, "Type"))
            @compileError("Language must define Type");

        if (!@hasDecl(Lang, "default_type"))
            @compileError("Language must define default_type");

        if (!@hasDecl(Lang, "parse"))
            @compileError("Language must define parse");
        if (!@hasDecl(Lang, "print"))
            @compileError("Language must define print");
    }
}

test "detect identifies each compiled-in format by content" {
    const a = std.testing.allocator;
    if (comptime build_options.lang_json) {
        try std.testing.expectEqual(Detected.json, detect(a, "{\"x\":1}").?);
    }
    if (comptime build_options.lang_zon) {
        try std.testing.expectEqual(Detected.zon, detect(a, ".{ .x = 1 }").?);
    }
    if (comptime build_options.lang_plist) {
        try std.testing.expectEqual(Detected.plist, detect(a, "<dict><key>a</key><string>b</string></dict>").?);
    }
    if (comptime build_options.lang_xml) {
        try std.testing.expectEqual(Detected.xml, detect(a, "<r/>").?);
    }
    if (comptime build_options.lang_toml) {
        try std.testing.expectEqual(Detected.toml, detect(a, "x = 1\n").?);
    }
    if (comptime build_options.lang_fig) {
        // A bare container header line (no `=`, no `:`, no brackets) followed
        // by a `>`-depth child isn't valid JSON/ZON/XML/TOML, so this resolves
        // to fig even though it's tried before YAML.
        try std.testing.expectEqual(Detected.fig, detect(a, "database\n> host = localhost\n").?);
    }
    if (comptime build_options.lang_ini) {
        // A `;`-led comment line is invalid JSON/ZON/XML/TOML (TOML has no `;`
        // comment leader — its bare-key scanner rejects `;` outright) and not
        // fig syntax either, so this resolves to INI even though it's tried
        // right before YAML.
        try std.testing.expectEqual(Detected.ini, detect(a, "; header\nname = fig\n").?);
    }
    if (comptime build_options.lang_dotenv) {
        // A double-quoted value spanning a literal embedded newline is the one
        // shape only dotenv parses: INI's value never crosses a physical line
        // (it hits the line's `\n` first), so `[a]` on its own next line is a
        // bad INI statement — this falls all the way through INI to dotenv.
        try std.testing.expectEqual(Detected.dotenv, detect(a, "A=\"line1\nline2\"\n").?);
    }
    if (comptime build_options.lang_yaml) {
        // A plain mapping that is not valid JSON/TOML/fig/INI/etc. falls
        // through to YAML, the most permissive grammar and therefore tried
        // second-to-last.
        try std.testing.expectEqual(Detected.yaml, detect(a, "key: value\n").?);
    }
    if (comptime build_options.lang_properties) {
        // Malformed YAML (a scalar followed by unexpectedly-indented content)
        // still parses as `.properties`: worst case, each line is just a bare
        // key with an empty value (see `properties/tokenizer.zig`) — the most
        // permissive grammar of all, so it's tried dead last.
        try std.testing.expectEqual(Detected.properties, detect(a, "a: 1\n b: 2\n").?);
    }
}

test "detect: plain `key = value` prefers TOML over fig despite fig accepting it too" {
    const a = std.testing.allocator;
    if (comptime !build_options.lang_toml or !build_options.lang_fig) return error.SkipZigTest;
    // fig's root-level dotted assignment accepts the exact same shape TOML
    // does; TOML is tried first, so it wins the tie.
    try std.testing.expectEqual(Detected.toml, detect(a, "x = 1\n").?);
}

test "detect: a plist document prefers plist over generic xml despite xml accepting it too" {
    const a = std.testing.allocator;
    if (comptime !build_options.lang_plist or !build_options.lang_xml) return error.SkipZigTest;
    // Any well-formed plist is also well-formed generic XML; plist is tried
    // first, so it wins. Ordinary XML that isn't plist-shaped still falls
    // through to `.xml`.
    try std.testing.expectEqual(Detected.plist, detect(a, "<dict><key>a</key><string>b</string></dict>").?);
    try std.testing.expectEqual(Detected.xml, detect(a, "<r/>").?);
}
