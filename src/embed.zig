//! Embedded config extraction: pull a config document out of a host file
//! (e.g. YAML frontmatter inside markdown) and parse it correctly.
const std = @import("std");
const Allocator = std.mem.Allocator;

const Language = @import("languages/language.zig");
const Document = @import("document.zig");
const Span = @import("util/span.zig");
const build_options = @import("build_options");

const Embed = @This();

const Delimiter = struct {
    /// The strings this delimiter matches against. Their meaning depends on
    /// `match`: for `whole_line`/`line_trimmed` each is an exact line body; for
    /// `prefix` each is a line prefix; for `script_open` there is exactly one —
    /// the required `type` attribute value (a MIME string), not literal tag text.
    tokens: []const []const u8,
    match: enum {
        /// The line, trimmed of trailing space/tab, equals a token exactly.
        /// Leading whitespace is significant (a markdown fence must sit at
        /// column 0), so an indented line never matches.
        whole_line,
        /// The line (untrimmed) starts with a token.
        prefix,
        /// The line, trimmed of leading AND trailing whitespace, equals a token
        /// exactly — the indentation-tolerant `whole_line`, for delimiters that
        /// may sit indented inside a host (e.g. a `</script>` close tag nested in
        /// an HTML `<head>`).
        line_trimmed,
        /// The line, trimmed both sides, is an HTML `<script …>` open tag (on its
        /// own line) whose `type` attribute equals `tokens[0]`. Attribute order,
        /// quoting, and surrounding whitespace are tolerated; a same-line block
        /// (`<script …>body</script>`) is deliberately not matched.
        script_open,
    },
    /// The exact text emitted for this delimiter when *synthesizing* a region
    /// (`initRegion`/`retype`), when it differs from `tokens[0]`. Needed for
    /// `script_open`, whose match token is a MIME value but whose literal fence
    /// is the full `<script type="…">` tag. Null ⇒ emit `tokens[0]` verbatim.
    literal: ?[]const u8 = null,
};

/// The format an archetype's content is written in — `---`/`;;;`/`+++` fences
/// imply YAML/JSON/TOML by convention; a fenced ```` ```lang ```` block implies
/// that `lang`. Named (not an inline anon enum) so callers outside this file can
/// name it too — see `innerFormat`.
pub const InnerFormat = enum { yaml, json, fig, toml };

const Archetype = struct {
    open: Delimiter,
    close: Delimiter,
    location: enum { start, end, middle },
    inner: InnerFormat,
};

fn archetypeOf(t: Type) Archetype {
    return switch (t) {
        .FrontmatterYaml => .{
            .open = .{ .tokens = &.{"---"}, .match = .whole_line },
            .close = .{ .tokens = &.{ "---", "..." }, .match = .whole_line },
            .location = .start,
            .inner = .yaml,
        },
        .FrontmatterJson => .{
            .open = .{ .tokens = &.{";;;"}, .match = .whole_line },
            .close = .{ .tokens = &.{";;;"}, .match = .whole_line },
            .location = .start,
            .inner = .json,
        },
        .EndmatterYaml => .{
            .open = .{ .tokens = &.{"```endmatter"}, .match = .whole_line },
            .close = .{ .tokens = &.{"```"}, .match = .whole_line },
            .location = .end,
            .inner = .yaml,
        },
        .FrontmatterFig => .{
            .open = .{ .tokens = &.{"```fig"}, .match = .whole_line },
            .close = .{ .tokens = &.{"```"}, .match = .whole_line },
            .location = .start,
            .inner = .fig,
        },
        .FrontmatterToml => .{
            .open = .{ .tokens = &.{"+++"}, .match = .whole_line },
            .close = .{ .tokens = &.{"+++"}, .match = .whole_line },
            .location = .start,
            .inner = .toml,
        },
        .FrontmatterYamlFenced => .{
            .open = .{ .tokens = &.{"```yaml"}, .match = .whole_line },
            .close = .{ .tokens = &.{"```"}, .match = .whole_line },
            .location = .start,
            .inner = .yaml,
        },
        .FrontmatterJsonFenced => .{
            .open = .{ .tokens = &.{"```json"}, .match = .whole_line },
            .close = .{ .tokens = &.{"```"}, .match = .whole_line },
            .location = .start,
            .inner = .json,
        },
        .FrontmatterTomlFenced => .{
            .open = .{ .tokens = &.{"```toml"}, .match = .whole_line },
            .close = .{ .tokens = &.{"```"}, .match = .whole_line },
            .location = .start,
            .inner = .toml,
        },
        .HtmlScriptFig => .{
            // Matched by the `type` MIME value; emitted as the full open tag.
            .open = .{
                .tokens = &.{"application/figl"},
                .match = .script_open,
                .literal = "<script type=\"application/figl\">",
            },
            .close = .{ .tokens = &.{"</script>"}, .match = .line_trimmed },
            // A data island lives mid-document (typically in `<head>`), so it is
            // located by scanning, not anchored at byte 0.
            .location = .middle,
            .inner = .fig,
        },
    };
}

/// An archetypal "config embedded in a host file" pattern. Each variant fixes
/// both *where* the config lives (the host's delimiter convention) and *what*
/// inner format it is — `---` fences imply YAML, by convention. This coupling
/// is deliberate: each named archetype is a blessed (delimiter, format) preset,
/// which keeps invalid combinations unspellable and gives `detect` a small,
/// unambiguous set to sniff. New conventions are added here as presets rather
/// than by exposing a free (delimiter × format) product.
pub const Type = enum {
    /// `---` … `---`/`...` YAML frontmatter at the top of a markdown file.
    FrontmatterYaml,
    /// `;;;` … `;;;` JSON frontmatter at the top of a markdown file.
    FrontmatterJson,
    /// For Stephen Deken. YAML in an ending codeblock.
    EndmatterYaml,
    /// A "fig" fenced code block … a bare "```" close, at the top of a
    /// markdown file — a fenced code block rather than a bare `---`/`;;;`
    /// delimiter, so it renders as a labeled code block (with fig syntax
    /// highlighting) on any markdown viewer instead of looking like a
    /// broken/empty rule.
    FrontmatterFig,
    /// `+++` … `+++` TOML frontmatter at the top of a markdown file — the
    /// Hugo/Zola convention, the TOML analogue of `---` YAML / `;;;` JSON.
    FrontmatterToml,
    /// A ```` ```yaml ```` fenced code block … bare ```` ``` ```` close, at the
    /// top of a markdown file: YAML content that still renders as a labeled code
    /// block on any markdown viewer (see `FrontmatterFig` for the fenced-vs-bare
    /// rationale) rather than as a `---` horizontal rule.
    FrontmatterYamlFenced,
    /// A ```` ```json ```` fenced frontmatter block — JSON content shown as a
    /// labeled code block rather than hidden behind `;;;` fences.
    FrontmatterJsonFenced,
    /// A ```` ```toml ```` fenced frontmatter block — TOML content shown as a
    /// labeled code block rather than behind bare `+++` fences.
    FrontmatterTomlFenced,
    /// An HTML `<script type="application/figl">` … `</script>` data island:
    /// figl config carried inside an HTML document (typically in `<head>`),
    /// invisible when the page renders and read by a program — the web's typed
    /// "data block" convention (cf. JSON-LD's `application/ld+json`). Unlike the
    /// markdown archetypes it sits MID-document and is located by scanning, and
    /// its `<script …>` open tag is matched attribute-tolerantly (see
    /// `matchScriptOpen`) rather than as a fixed line.
    HtmlScriptFig,
};

/// A located region, in *outer-source* byte coordinates. The fence spans are
/// retained so an editor can splice a replacement into `content` while leaving
/// everything else byte-identical. `body` is the host text OUTSIDE the region —
/// the markdown the config is embedded in — computed archetype-aware: the suffix
/// after the close fence for a `.start` (frontmatter) region, the prefix before
/// the open fence for an `.end` (endmatter) region. It is the read-side twin of
/// the `content` slice (frontmatter vs. body) and the target of `replace_body`.
pub const Region = struct {
    open_fence: Span,
    content: Span,
    close_fence: Span,
    body: Span,
};

/// Extraction result. `source` is the borrowed *outer* file; `region` indexes
/// into it. `document`'s node spans are relative to `region.content` — call
/// `outerSpan` to lift them back into outer-file coordinates.
pub const Embedded = struct {
    source: []const u8,
    type: Type,
    region: Region,
    document: Document,

    pub fn deinit(self: Embedded, allocator: Allocator) void {
        self.document.deinit(allocator);
    }

    pub fn outerSpan(self: Embedded, s: Span) Span {
        const base = self.region.content.start;
        return Span.init(s.start + base, s.end + base);
    }
};

/// One document within a multi-document YAML stream, located in *outer-source*
/// byte coordinates. `content` is the exact slice handed to the single-document
/// parser: it INCLUDES a leading `---` marker line (which the parser consumes)
/// but excludes a trailing `...`. `explicit` records whether the document opened
/// with a `---` marker (vs. a bare document at stream start or after `...`).
pub const StreamDoc = struct {
    content: Span,
    explicit: bool,
    document: Document,

    /// Lift a node span (relative to this document's content) into outer-file
    /// coordinates — mirrors `Embedded.outerSpan`.
    pub fn outerSpan(self: StreamDoc, s: Span) Span {
        const base = self.content.start;
        return Span.init(s.start + base, s.end + base);
    }
};

/// A parsed multi-document YAML stream. `source` is the borrowed outer file;
/// each document's `content` indexes into it. The single-document parser only
/// ever sees one document at a time, so this never trips its multi-document
/// guard — the stream concept lives here, in the splitter, not in the parser.
pub const Stream = struct {
    source: []const u8,
    documents: []const StreamDoc,

    pub fn deinit(self: Stream, allocator: Allocator) void {
        for (self.documents) |d| d.document.deinit(allocator);
        allocator.free(self.documents);
    }
};

pub const Error = error{
    /// No region of this archetype exists (plain markdown, no frontmatter).
    /// Distinct from a region that exists but is malformed.
    NotFound,
    /// An opening delimiter with no matching close.
    Unterminated,
};

/// Locate + parse the embedded document of type `t` in `source`.
pub fn extract(allocator: Allocator, source: []const u8, t: Type) !Embedded {
    const region = try locate(source, archetypeOf(t));
    const document = try parseSpan(allocator, source, region.content, t);
    return .{ .source = source, .type = t, .region = region, .document = document };
}

/// Locate the region of type `t` in `source` without parsing its content.
/// Useful when a caller only needs the fence/content spans (e.g. to splice).
pub fn locateRegion(source: []const u8, t: Type) Error!Region {
    return locate(source, archetypeOf(t));
}

/// The archetypes `detect` tries, in order. Earlier entries are the
/// position-anchored (`.start`) conventions, checked at the very top of the
/// file where each one's open token is unambiguous: every open delimiter is
/// matched whole-line-exact, and the tokens are mutually distinct (`---`,
/// `;;;`, `+++`, and the ```` ```lang ```` fences can't be confused with one
/// another), so order among the `.start` archetypes doesn't affect which one
/// wins — only that the fenced group is grouped first for readability.
/// `EndmatterYaml` and `HtmlScriptFig` are last because locating them requires
/// scanning the whole document (for the ```` ```endmatter ```` fence, or the
/// `<script type="application/figl">` tag) rather than just checking position
/// zero; their open tokens are distinct from every other archetype's, so being
/// last never costs a real match.
const detect_order = [_]Type{
    .FrontmatterFig,
    .FrontmatterYamlFenced,
    .FrontmatterJsonFenced,
    .FrontmatterTomlFenced,
    .FrontmatterJson,
    .FrontmatterToml,
    .FrontmatterYaml,
    .EndmatterYaml,
    .HtmlScriptFig,
};

/// Best-effort content sniffing for which embed archetype `source` uses, the
/// `Embed` counterpart to `Language.detect`: try each known archetype's OPEN
/// delimiter (not a full `locate`, which also demands a matching close — an
/// unterminated block should still be *recognized* as that archetype so the
/// caller's subsequent `extract`/`locateRegion` call surfaces the real
/// `error.Unterminated` instead of a misleading "nothing found") and return the
/// first that matches, or null if `source` opens none of them. Order matters
/// the same way `Language.detect`'s does — see `detect_order`.
pub fn detect(source: []const u8) ?Type {
    for (detect_order) |t| {
        if (matchesOpen(source, archetypeOf(t))) return t;
    }
    return null;
}

/// Whether `source` opens archetype `a` — anchored at byte 0 (after an
/// optional UTF-8 BOM) for a `.start` archetype, or anywhere in the document
/// for an `.end` one (mirrors `locate`'s own open-delimiter search).
fn matchesOpen(source: []const u8, a: Archetype) bool {
    var i: usize = 0;
    if (std.mem.startsWith(u8, source, "\xEF\xBB\xBF")) i += 3; // UTF-8 BOM
    return if (a.location == .start)
        matchDelim(source, i, a.open) != null
    else
        scanForDelim(source, i, a.open) != null;
}

/// Whether `t`'s body (the host prose) sits BEFORE the open fence (endmatter)
/// rather than after the close fence (frontmatter). Lets a host-coordinate
/// editor pick the side to splice when replacing the body.
pub fn bodyIsBefore(t: Type) bool {
    return archetypeOf(t).location == .end;
}

/// The format `t`'s content is written in. Lets a caller resolve the parser/
/// printer to use for an embed's content — e.g. a `get`-style command that
/// picked an archetype via `--embed` and needs to know what format that
/// implies, rather than trusting a possibly-unrelated file-extension guess.
pub fn innerFormat(t: Type) InnerFormat {
    return archetypeOf(t).inner;
}

/// The exact text to emit for delimiter `d` when synthesizing a region — its
/// `literal` override, or `tokens[0]` when there is none. (`script_open`'s match
/// token is a MIME value, not the `<script …>` tag it must emit.)
fn delimLiteral(d: Delimiter) []const u8 {
    return d.literal orelse d.tokens[0];
}

/// Built host for a source that has no region of type `t` — the create half of
/// "open or create".
pub const Initialized = struct { host: []u8, region: Region };

/// Synthesize a host containing an EMPTY region of type `t` around `source`,
/// which is assumed to have none. The fresh block is placed where the archetype
/// dictates — prepended for a `.start` (frontmatter) region, appended for an
/// `.end` (endmatter) region — with the original `source` becoming the region's
/// body. Its content is seeded with an empty inner document (nothing for YAML, an
/// empty object for JSON) so a subsequent insert/set lands the first key. No
/// blank line is inserted between fence and body, so the output matches the
/// hand-rolled `---\n…\n---\n{body}` shape. The returned `host` is caller-owned.
///
pub fn initRegion(allocator: Allocator, source: []const u8, t: Type) !Initialized {
    const a = archetypeOf(t);
    const open_tok = delimLiteral(a.open);
    const close_tok = delimLiteral(a.close);
    // The empty inner document seeded between the fences. JSON gets a trailing
    // newline so the close fence stays on its own line after the flow-mapping
    // insert (which preserves it); YAML's, fig's, and TOML's block inserts emit
    // their own newline, so their empty content needs none. Those three all seed
    // empty because an empty document is a valid empty map / empty root table
    // (see `fig/parser.zig`'s `buildRoot`), so a subsequent set/insert lands the
    // first key into it.
    const seed: []const u8 = switch (a.inner) {
        .yaml, .fig, .toml => "",
        .json => "{}\n",
    };

    var host: std.ArrayList(u8) = .empty;
    errdefer host.deinit(allocator);

    if (a.location == .end) {
        // [ body ][ \n? ][ open\n ][ seed ][ close\n ]
        try host.appendSlice(allocator, source);
        // The open fence must start its own line; add a separating newline when
        // the body doesn't already end in one.
        if (source.len > 0 and source[source.len - 1] != '\n') try host.append(allocator, '\n');
        const open_start = host.items.len;
        try host.appendSlice(allocator, open_tok);
        try host.append(allocator, '\n');
        const content_start = host.items.len;
        try host.appendSlice(allocator, seed);
        const content_end = host.items.len;
        try host.appendSlice(allocator, close_tok);
        try host.append(allocator, '\n');
        const close_end = host.items.len;
        return .{ .host = try host.toOwnedSlice(allocator), .region = .{
            .open_fence = Span.init(open_start, content_start),
            .content = Span.init(content_start, content_end),
            .close_fence = Span.init(content_end, close_end),
            .body = Span.init(0, source.len),
        } };
    }
    // .start: [ open\n ][ seed ][ close\n ][ body ]
    try host.appendSlice(allocator, open_tok);
    try host.append(allocator, '\n');
    const content_start = host.items.len;
    try host.appendSlice(allocator, seed);
    const content_end = host.items.len;
    try host.appendSlice(allocator, close_tok);
    try host.append(allocator, '\n');
    const close_end = host.items.len;
    const body_start = host.items.len;
    try host.appendSlice(allocator, source);
    return .{ .host = try host.toOwnedSlice(allocator), .region = .{
        .open_fence = Span.init(0, content_start),
        .content = Span.init(content_start, content_end),
        .close_fence = Span.init(content_end, close_end),
        .body = Span.init(body_start, body_start + source.len),
    } };
}

/// Rebuild `source`'s embedded region as a DIFFERENT archetype: keep the host
/// prose (`region.body`, byte-identical) but replace the old fences and
/// content with `to`'s convention wrapped around `new_content` — the already
/// re-serialized inner document (e.g. YAML frontmatter content re-printed as
/// JSON, for `fig convert --to-embed`). `region` must be `source`'s existing
/// region of whatever archetype it was located as (`locateRegion`/`extract`);
/// this function doesn't care what that was, only where the body is. Mirrors
/// `initRegion`'s `.start`/`.end` placement, but re-housing real content
/// rather than seeding an empty document. The returned buffer is caller-owned.
pub fn retype(allocator: Allocator, source: []const u8, region: Region, to: Type, new_content: []const u8) ![]u8 {
    const a = archetypeOf(to);
    const open_tok = delimLiteral(a.open);
    const close_tok = delimLiteral(a.close);
    const body = Span.of(u8, region.body, source);

    var host: std.ArrayList(u8) = .empty;
    errdefer host.deinit(allocator);

    if (a.location == .end) {
        // [ body ][ \n? ][ open\n ][ content ][ close\n ]
        try host.appendSlice(allocator, body);
        if (body.len > 0 and body[body.len - 1] != '\n') try host.append(allocator, '\n');
        try host.appendSlice(allocator, open_tok);
        try host.append(allocator, '\n');
        try host.appendSlice(allocator, new_content);
        try host.appendSlice(allocator, close_tok);
        try host.append(allocator, '\n');
        return host.toOwnedSlice(allocator);
    }
    // .start: [ open\n ][ content ][ close\n ][ body ]
    try host.appendSlice(allocator, open_tok);
    try host.append(allocator, '\n');
    try host.appendSlice(allocator, new_content);
    try host.appendSlice(allocator, close_tok);
    try host.append(allocator, '\n');
    try host.appendSlice(allocator, body);
    return host.toOwnedSlice(allocator);
}

/// Parse an explicit content span as `t`'s inner format, no host scanning.
pub fn parseSpan(allocator: Allocator, source: []const u8, content: Span, t: Type) !Document {
    const slice = Span.of(u8, content, source);
    return switch (archetypeOf(t).inner) {
        .yaml => if (comptime build_options.lang_yaml) blk: {
            var parser = Language.YAML.Parser{ .allocator = allocator };
            break :blk Language.YAML.parse(&parser, slice, Language.YAML.default_type);
        } else error.FormatDisabled,
        .json => if (comptime build_options.lang_json) blk: {
            var parser = Language.JSON.Parser{ .allocator = allocator };
            break :blk Language.JSON.parse(&parser, slice, Language.JSON.default_type);
        } else error.FormatDisabled,
        .fig => if (comptime build_options.lang_fig) blk: {
            var parser = Language.FIG.Parser{ .allocator = allocator };
            break :blk Language.FIG.parse(&parser, slice, Language.FIG.default_type);
        } else error.FormatDisabled,
        .toml => if (comptime build_options.lang_toml) blk: {
            var parser = Language.TOML.Parser{ .allocator = allocator };
            break :blk Language.TOML.parse(&parser, slice, Language.TOML.default_type);
        } else error.FormatDisabled,
    };
}

// --- multi-document YAML stream splitter ---------------------------------

/// Split a YAML stream into its constituent documents and parse each one
/// independently with the single-document parser.
///
/// A stream is a sequence of documents delimited by `---` (start) and `...`
/// (end) markers at column 0. Rather than teach the core parser to span
/// documents — which would complicate in-place editing and round-tripping — we
/// locate each document's byte range here (the same "locate region, then parse
/// it" shape as `extract`) and hand the slices to the parser one at a time.
///
/// Always returns at least one document: an empty or comment-only stream yields
/// a single `null` document. A parse error in any document propagates (and any
/// already-parsed documents are freed).
pub fn extractStream(allocator: Allocator, source: []const u8) !Stream {
    var docs: std.ArrayList(StreamDoc) = .empty;
    errdefer {
        for (docs.items) |d| d.document.deinit(allocator);
        docs.deinit(allocator);
    }

    var start: usize = 0;
    if (std.mem.startsWith(u8, source, "\xEF\xBB\xBF")) start += 3; // UTF-8 BOM

    var seg_start: usize = start;
    var seg_explicit = false;

    var line = start;
    while (line < source.len) {
        const next = lineEnd(source, line);
        switch (markerKind(source, line)) {
            .start => {
                // A `---` ends the current segment and opens a new explicit
                // document *at* this line — the marker stays in the slice so
                // inline content (`--- foo`) is preserved and the parser eats
                // the marker token.
                //
                // Directives (`%YAML`/`%TAG`) preceding the `---` belong to the
                // document it introduces. If the pending segment is just those
                // directives (and trivia), don't close it here — let the explicit
                // document include them, so the parser sees `%YAML\n---\n…` as one
                // document and validates the directive against its marker.
                if (!segmentIsDirectives(source[seg_start..line])) {
                    try pushSegment(allocator, source, &docs, seg_start, line, seg_explicit);
                    seg_start = line;
                }
                seg_explicit = true;
            },
            .end => {
                // A `...` ends the current document; the marker itself is left
                // out of the slice. What follows is a fresh bare document.
                try pushSegment(allocator, source, &docs, seg_start, line, seg_explicit);
                seg_start = next;
                seg_explicit = false;
            },
            .none => {},
        }
        line = next;
    }
    try pushSegment(allocator, source, &docs, seg_start, source.len, seg_explicit);

    if (docs.items.len == 0) {
        // An empty / trivia-only stream is one null document.
        const doc = try parseYamlSlice(allocator, source[start..]);
        try docs.append(allocator, .{ .content = Span.init(start, source.len), .explicit = false, .document = doc });
    }

    return .{ .source = source, .documents = try docs.toOwnedSlice(allocator) };
}

/// Parse `source[seg_start..seg_end]` and append it as a document, unless it is
/// a bare segment with no real content (blank/comment-only) — such a segment is
/// not a document (e.g. a leading comment before the first `---`). An explicit
/// segment (opened by `---`) is always a document, even when its body is empty.
fn pushSegment(
    allocator: Allocator,
    source: []const u8,
    docs: *std.ArrayList(StreamDoc),
    seg_start: usize,
    seg_end: usize,
    explicit: bool,
) !void {
    const slice = source[seg_start..seg_end];
    if (!explicit and !hasContent(slice)) return;
    const doc = try parseYamlSlice(allocator, slice);
    try docs.append(allocator, .{
        .content = Span.init(seg_start, seg_end),
        .explicit = explicit,
        .document = doc,
    });
}

fn parseYamlSlice(allocator: Allocator, slice: []const u8) !Document {
    if (comptime build_options.lang_yaml) {
        var parser = Language.YAML.Parser{ .allocator = allocator };
        return Language.YAML.parse(&parser, slice, Language.YAML.default_type);
    } else return error.FormatDisabled;
}

const MarkerKind = enum { start, end, none };

/// Classify the column-0 line at `at` as a document `---`/`...` marker. A `---`
/// marker is the bare token or a `--- `/`---\t` prefix (inline content allowed);
/// `---foo` is a plain scalar, not a marker. A `...` marker must occupy the
/// whole line. Indented lines never match (callers only pass line starts).
fn markerKind(source: []const u8, at: usize) MarkerKind {
    const eol = lineEnd(source, at);
    const line = std.mem.trimEnd(u8, source[at..eol], "\r\n");
    if (std.mem.eql(u8, line, "---")) return .start;
    if (std.mem.startsWith(u8, line, "--- ") or std.mem.startsWith(u8, line, "---\t")) return .start;
    if (std.mem.eql(u8, std.mem.trimEnd(u8, line, " \t"), "...")) return .end;
    return .none;
}

/// True if every content line of `slice` (ignoring blanks and comments) is a
/// column-0 directive (`%…`), and there is at least one. Such a pre-`---`
/// segment is a directives prefix that belongs to the following document, not a
/// document of its own.
fn segmentIsDirectives(slice: []const u8) bool {
    var any = false;
    var i: usize = 0;
    while (i < slice.len) {
        const eol = lineEnd(slice, i);
        const line = std.mem.trimEnd(u8, slice[i..eol], "\r\n");
        i = eol;
        if (line.len == 0) continue;
        if (line[0] == '%') {
            any = true; // a directive sits at column 0
            continue;
        }
        const body = std.mem.trim(u8, line, " \t");
        if (body.len == 0 or body[0] == '#') continue; // blank or comment
        return false; // some other content — not a pure directives prefix
    }
    return any;
}

/// True if `slice` has any line that is neither blank nor a comment.
fn hasContent(slice: []const u8) bool {
    var i: usize = 0;
    while (i < slice.len) {
        const eol = lineEnd(slice, i);
        const trimmed = std.mem.trim(u8, slice[i..eol], " \t\r\n");
        if (trimmed.len != 0 and trimmed[0] != '#') return true;
        i = eol;
    }
    return false;
}

// --- markdown frontmatter locator ---------------------------------------

fn locate(source: []const u8, a: Archetype) Error!Region {
    var i: usize = 0;
    if (std.mem.startsWith(u8, source, "\xEF\xBB\xBF")) i += 3; // UTF-8 BOM

    const open = if (a.location == .start)
        matchDelim(source, i, a.open) orelse return Error.NotFound
    else
        scanForDelim(source, i, a.open) orelse return Error.NotFound;

    var line = open.end;
    while (line < source.len) {
        if (matchDelim(source, line, a.close)) |close| {
            // The body is the host text outside the fences: the prefix before the
            // open fence for endmatter (where the config trails the prose), else
            // the suffix after the close fence — for frontmatter (`.start`) AND
            // for a mid-document block (`.middle`, e.g. an HTML `<script>` data
            // island). A `.middle` block also has host text BEFORE it, which this
            // single-span body doesn't capture; in-place edits splice via the
            // content spans and stay byte-identical on both sides regardless, so
            // only `replace_body` is one-sided (it swaps the suffix).
            const body = if (a.location == .end)
                Span.init(0, open.start)
            else
                Span.init(close.end, source.len);
            return .{ .open_fence = open, .content = Span.init(open.end, close.start), .close_fence = close, .body = body };
        }
        line = lineEnd(source, line);
    }
    return Error.Unterminated;
}

fn lineEnd(source: []const u8, from: usize) usize {
    return if (std.mem.findScalarPos(u8, source, from, '\n')) |nl| nl + 1 else source.len;
}

/// One line vs a Delimiter; returns the line's span (incl. newline) or null.
fn matchDelim(source: []const u8, start: usize, d: Delimiter) ?Span {
    const eol = lineEnd(source, start);
    const line = std.mem.trimEnd(u8, source[start..eol], "\r\n");
    const matched = switch (d.match) {
        .whole_line => blk: {
            const trimmed = std.mem.trimEnd(u8, line, " \t");
            for (d.tokens) |tok| if (std.mem.eql(u8, trimmed, tok)) break :blk true;
            break :blk false;
        },
        .prefix => blk: {
            for (d.tokens) |tok| if (std.mem.startsWith(u8, line, tok)) break :blk true;
            break :blk false;
        },
        .line_trimmed => blk: {
            const trimmed = std.mem.trim(u8, line, " \t");
            for (d.tokens) |tok| if (std.mem.eql(u8, trimmed, tok)) break :blk true;
            break :blk false;
        },
        .script_open => matchScriptOpen(std.mem.trim(u8, line, " \t"), d.tokens[0]),
    };
    return if (matched) Span.init(start, eol) else null;
}

fn isHspace(c: u8) bool {
    return c == ' ' or c == '\t';
}

/// Whether the already-both-sides-trimmed line `t` is an HTML `<script …>` open
/// tag, standing on its own line, whose `type` attribute equals `mime`. The `>`
/// must close the line: a same-line block (`<script …>body</script>`, whose
/// trimmed line also ends in `>`) is rejected so it isn't mis-located with an
/// empty content span.
fn matchScriptOpen(t: []const u8, mime: []const u8) bool {
    const tag = "<script";
    if (!std.ascii.startsWithIgnoreCase(t, tag)) return false; // HTML folds tag-name case
    const rest = t[tag.len..];
    // The char after `<script` must be whitespace or `>` — never a name char, so
    // `<scripts …>` (a different element) is not mistaken for `<script …>`.
    if (rest.len == 0 or (!isHspace(rest[0]) and rest[0] != '>')) return false;
    const gt = std.mem.indexOfScalar(u8, rest, '>') orelse return false;
    if (gt != rest.len - 1) return false; // `>` must end the line
    return scriptTypeEquals(rest[0..gt], mime);
}

/// Scan an HTML open tag's attribute region (`<script` and the closing `>`
/// stripped) for a `type` attribute whose value equals `mime`. Tolerant of
/// attribute order, extra attributes, single/double/unquoted values, and
/// whitespace around `=`. Attribute names compare case-insensitively (HTML
/// folds them); the value too, since MIME types are case-insensitive.
fn scriptTypeEquals(attrs: []const u8, mime: []const u8) bool {
    var i: usize = 0;
    while (i < attrs.len) {
        while (i < attrs.len and isHspace(attrs[i])) i += 1;
        if (i >= attrs.len) break;
        const name_start = i;
        while (i < attrs.len and attrs[i] != '=' and !isHspace(attrs[i])) i += 1;
        const name = attrs[name_start..i];
        while (i < attrs.len and isHspace(attrs[i])) i += 1;
        var value: []const u8 = "";
        if (i < attrs.len and attrs[i] == '=') {
            i += 1;
            while (i < attrs.len and isHspace(attrs[i])) i += 1;
            if (i < attrs.len and (attrs[i] == '"' or attrs[i] == '\'')) {
                const q = attrs[i];
                i += 1;
                const v_start = i;
                while (i < attrs.len and attrs[i] != q) i += 1;
                value = attrs[v_start..i];
                if (i < attrs.len) i += 1; // consume closing quote
            } else {
                const v_start = i;
                while (i < attrs.len and !isHspace(attrs[i])) i += 1;
                value = attrs[v_start..i];
            }
        }
        if (std.ascii.eqlIgnoreCase(name, "type") and std.ascii.eqlIgnoreCase(value, mime))
            return true;
    }
    return false;
}

/// Scan forward line-by-line for the first line matching `d`; null at EOF.
fn scanForDelim(source: []const u8, start: usize, d: Delimiter) ?Span {
    var line = start;
    while (line < source.len) {
        if (matchDelim(source, line, d)) |span| return span;
        line = lineEnd(source, line);
    }
    return null;
}
// --- tests ---------------------------------------------------------------

const testing = std.testing;
const AST = @import("ast/ast.zig");

fn rootKind(doc: Document) AST.Node.Kind {
    return doc.ast.nodes[doc.ast.root].kind;
}

test "extract: YAML frontmatter comments survive into the parsed AST" {
    if (comptime !build_options.lang_yaml) return error.SkipZigTest;
    // The embed layer slices the source and hands it to the real YAML parser
    // (no AST rebuild), so captured comments must ride through on `node_comments`.
    const src =
        \\---
        \\# the title
        \\title: hi # inline
        \\---
        \\# body
        \\
    ;
    const embedded = try extract(testing.allocator, src, .FrontmatterYaml);
    defer embedded.deinit(testing.allocator);
    const ast = embedded.document.ast;
    try testing.expect(ast.node_comments.len > 0);
    const kv = ast.nodes[ast.nodes[ast.root].kind.mapping.?].kind.keyvalue;
    try testing.expectEqualStrings("the title", ast.comments(kv.key).leading[0].text);
    try testing.expectEqualStrings("inline", ast.comments(kv.value).trailing.?.text);
}

test "extract: fig frontmatter (```fig fenced block) locates and parses" {
    if (comptime !build_options.lang_fig) return error.SkipZigTest;
    const src =
        \\```fig
        \\# the title
        \\title = hi # inline
        \\tags = [a, b]
        \\```
        \\# body
        \\
    ;
    const embedded = try extract(testing.allocator, src, .FrontmatterFig);
    defer embedded.deinit(testing.allocator);
    // Fences excluded from content; body is everything after the close fence.
    try testing.expectEqualStrings("```fig\n", src[embedded.region.open_fence.start..embedded.region.open_fence.end]);
    try testing.expectEqualStrings("```\n", src[embedded.region.close_fence.start..embedded.region.close_fence.end]);
    try testing.expectEqualStrings("# body\n", src[embedded.region.body.start..embedded.region.body.end]);

    const ast = embedded.document.ast;
    try testing.expect(ast.node_comments.len > 0);
    const kv = ast.nodes[ast.nodes[ast.root].kind.mapping.?].kind.keyvalue;
    try testing.expectEqualStrings("the title", ast.comments(kv.key).leading[0].text);
    try testing.expectEqualStrings("inline", ast.comments(kv.value).trailing.?.text);
    try testing.expectEqualSlices(u8, "hi", (try embedded.document.ast.getValByPath(&.{.{ .key = "title" }})).kind.string);
}

test "extract: a generic ```something fence is not mistaken for ```fig" {
    if (comptime !build_options.lang_fig) return error.SkipZigTest;
    // The open token match is whole-line-exact (`.whole_line`), not a prefix
    // match, so a same-family fenced code block with a different/longer info
    // string (an ordinary markdown code fence, not this archetype) must not
    // be located as fig frontmatter.
    const src =
        \\```figure
        \\not fig frontmatter
        \\```
        \\
    ;
    try testing.expectError(Error.NotFound, locateRegion(src, .FrontmatterFig));
}

test "innerFormat reports each archetype's content format" {
    try testing.expectEqual(InnerFormat.yaml, innerFormat(.FrontmatterYaml));
    try testing.expectEqual(InnerFormat.yaml, innerFormat(.EndmatterYaml));
    try testing.expectEqual(InnerFormat.json, innerFormat(.FrontmatterJson));
    try testing.expectEqual(InnerFormat.fig, innerFormat(.FrontmatterFig));
    try testing.expectEqual(InnerFormat.toml, innerFormat(.FrontmatterToml));
    try testing.expectEqual(InnerFormat.yaml, innerFormat(.FrontmatterYamlFenced));
    try testing.expectEqual(InnerFormat.json, innerFormat(.FrontmatterJsonFenced));
    try testing.expectEqual(InnerFormat.toml, innerFormat(.FrontmatterTomlFenced));
}

test "extract: TOML frontmatter (+++ fences) locates and parses" {
    if (comptime !build_options.lang_toml) return error.SkipZigTest;
    const src =
        \\+++
        \\title = "hi"
        \\tags = ["a", "b"]
        \\+++
        \\# body
        \\
    ;
    const embedded = try extract(testing.allocator, src, .FrontmatterToml);
    defer embedded.deinit(testing.allocator);
    try testing.expectEqualStrings("+++\n", src[embedded.region.open_fence.start..embedded.region.open_fence.end]);
    try testing.expectEqualStrings("+++\n", src[embedded.region.close_fence.start..embedded.region.close_fence.end]);
    try testing.expectEqualStrings("# body\n", src[embedded.region.body.start..embedded.region.body.end]);
    try testing.expectEqualSlices(u8, "hi", (try embedded.document.ast.getValByPath(&.{.{ .key = "title" }})).kind.string);
}

test "extract: fenced ```toml / ```yaml / ```json frontmatter locate and parse" {
    if (comptime !build_options.lang_toml or !build_options.lang_yaml or !build_options.lang_json)
        return error.SkipZigTest;

    const toml_src =
        \\```toml
        \\title = "hi"
        \\```
        \\body
        \\
    ;
    const t = try extract(testing.allocator, toml_src, .FrontmatterTomlFenced);
    defer t.deinit(testing.allocator);
    try testing.expectEqualStrings("```toml\n", toml_src[t.region.open_fence.start..t.region.open_fence.end]);
    try testing.expectEqualSlices(u8, "hi", (try t.document.ast.getValByPath(&.{.{ .key = "title" }})).kind.string);

    const yaml_src =
        \\```yaml
        \\title: hi
        \\```
        \\body
        \\
    ;
    const y = try extract(testing.allocator, yaml_src, .FrontmatterYamlFenced);
    defer y.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "hi", (try y.document.ast.getValByPath(&.{.{ .key = "title" }})).kind.string);

    const json_src =
        \\```json
        \\{"title": "hi"}
        \\```
        \\body
        \\
    ;
    const j = try extract(testing.allocator, json_src, .FrontmatterJsonFenced);
    defer j.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "hi", (try j.document.ast.getValByPath(&.{.{ .key = "title" }})).kind.string);
}

test "extract: HTML <script type=\"application/figl\"> data island locates and parses" {
    if (comptime !build_options.lang_fig) return error.SkipZigTest;
    // A realistic page: doctype + head, the island indented inside <head>, prose
    // both BEFORE and AFTER the block (the mid-document case).
    const src =
        \\<!doctype html>
        \\<html>
        \\  <head>
        \\    <script type="application/figl">
        \\title = hi
        \\tags = [a, b]
        \\    </script>
        \\  </head>
        \\  <body>page</body>
        \\</html>
        \\
    ;
    const embedded = try extract(testing.allocator, src, .HtmlScriptFig);
    defer embedded.deinit(testing.allocator);
    // The open/close fence spans cover their whole (indented) lines; content is
    // exactly what sits between them, spliced back byte-for-byte on edit.
    try testing.expectEqualStrings("    <script type=\"application/figl\">\n", src[embedded.region.open_fence.start..embedded.region.open_fence.end]);
    try testing.expectEqualStrings("    </script>\n", src[embedded.region.close_fence.start..embedded.region.close_fence.end]);
    try testing.expectEqualStrings("title = hi\ntags = [a, b]\n", src[embedded.region.content.start..embedded.region.content.end]);
    try testing.expectEqualSlices(u8, "hi", (try embedded.document.ast.getValByPath(&.{.{ .key = "title" }})).kind.string);
}

test "matchScriptOpen: tolerates quoting, attribute order, and extra attributes; rejects near-misses" {
    // Accepted variants.
    try testing.expect(matchScriptOpen("<script type=\"application/figl\">", "application/figl"));
    try testing.expect(matchScriptOpen("<script type='application/figl'>", "application/figl"));
    try testing.expect(matchScriptOpen("<script id=\"cfg\" type=\"application/figl\">", "application/figl"));
    try testing.expect(matchScriptOpen("<script type = \"application/figl\" defer>", "application/figl"));
    try testing.expect(matchScriptOpen("<SCRIPT TYPE=\"application/figl\">", "application/figl")); // HTML folds names/mime case
    // Rejected: wrong element, wrong/absent type, a same-line block.
    try testing.expect(!matchScriptOpen("<scripts type=\"application/figl\">", "application/figl"));
    try testing.expect(!matchScriptOpen("<script type=\"application/json\">", "application/figl"));
    try testing.expect(!matchScriptOpen("<script>", "application/figl"));
    try testing.expect(!matchScriptOpen("<script type=\"application/figl\">k = 1</script>", "application/figl"));
}

test "initRegion: an HTML-script archetype seeds an empty <script> island" {
    if (comptime !build_options.lang_fig) return error.SkipZigTest;
    const init = try initRegion(testing.allocator, "<html></html>\n", .HtmlScriptFig);
    defer testing.allocator.free(init.host);
    try testing.expectEqualStrings("<script type=\"application/figl\">\n</script>\n<html></html>\n", init.host);
    try testing.expectEqual(init.region.content.start, init.region.content.end);
}

test "detect: recognizes an HTML <script> data island (scanned mid-document)" {
    if (comptime !build_options.lang_fig) return error.SkipZigTest;
    const src = "<html><head>\n<script type=\"application/figl\">\nk = v\n</script>\n</head></html>\n";
    try testing.expectEqual(@as(?Type, .HtmlScriptFig), detect(src));
}

test "detect: recognizes TOML and fenced-label frontmatter" {
    // Content-only sniff (no parser needed): the open delimiters are distinct.
    try testing.expectEqual(@as(?Type, .FrontmatterToml), detect("+++\ntitle = \"hi\"\n+++\nbody\n"));
    try testing.expectEqual(@as(?Type, .FrontmatterTomlFenced), detect("```toml\ntitle = \"hi\"\n```\nbody\n"));
    try testing.expectEqual(@as(?Type, .FrontmatterYamlFenced), detect("```yaml\ntitle: hi\n```\nbody\n"));
    try testing.expectEqual(@as(?Type, .FrontmatterJsonFenced), detect("```json\n{\"t\":1}\n```\nbody\n"));
    // A ```fig fence still wins its own detection, not the new fenced labels.
    try testing.expectEqual(@as(?Type, .FrontmatterFig), detect("```fig\nt = 1\n```\nbody\n"));
}

test "initRegion: a TOML-inner archetype seeds an empty +++ block" {
    const init = try initRegion(testing.allocator, "body text\n", .FrontmatterToml);
    defer testing.allocator.free(init.host);
    try testing.expectEqualStrings("+++\n+++\nbody text\n", init.host);
    try testing.expectEqual(init.region.content.start, init.region.content.end);
    try testing.expectEqualStrings("body text\n", init.host[init.region.body.start..init.region.body.end]);
}

test "initRegion: a fig-inner archetype seeds an empty block from nothing" {
    // An empty fig document is a valid empty map (see `fig/parser.zig`), so a
    // brand-new ```fig``` frontmatter block seeds empty (like YAML) and a
    // subsequent set/insert lands its first key.
    const init = try initRegion(testing.allocator, "body text\n", .FrontmatterFig);
    defer testing.allocator.free(init.host);
    try testing.expectEqualStrings("```fig\n```\nbody text\n", init.host);
    // The seeded content is an empty span between the fences.
    try testing.expectEqual(init.region.content.start, init.region.content.end);
    try testing.expectEqualStrings("body text\n", init.host[init.region.body.start..init.region.body.end]);
}

test "extract: fig frontmatter with no host body" {
    if (comptime !build_options.lang_fig) return error.SkipZigTest;
    const src =
        \\```fig
        \\title = hi
        \\```
        \\
    ;
    const embedded = try extract(testing.allocator, src, .FrontmatterFig);
    defer embedded.deinit(testing.allocator);
    try testing.expectEqualStrings("", src[embedded.region.body.start..embedded.region.body.end]);
}

test "extractStream: two explicit documents in a stream (JHB9)" {
    if (comptime !build_options.lang_yaml) return error.SkipZigTest;
    const src =
        \\# Ranking of 1998 home runs
        \\---
        \\- Mark McGwire
        \\- Sammy Sosa
        \\
        \\# Team ranking
        \\---
        \\- Chicago Cubs
        \\- St Louis Cardinals
        \\
    ;
    const stream = try extractStream(testing.allocator, src);
    defer stream.deinit(testing.allocator);

    // The leading comment-only segment is not a document.
    try testing.expectEqual(@as(usize, 2), stream.documents.len);
    try testing.expect(stream.documents[0].explicit);
    try testing.expect(stream.documents[1].explicit);
    try testing.expectEqualSlices(u8, "Mark McGwire", (try stream.documents[0].document.ast.getValByPath(&.{.{ .index = 0 }})).kind.string);
    try testing.expectEqualSlices(u8, "St Louis Cardinals", (try stream.documents[1].document.ast.getValByPath(&.{.{ .index = 1 }})).kind.string);
}

test "extractStream: directives fold into the following document (6ZKB-shaped)" {
    if (comptime !build_options.lang_yaml) return error.SkipZigTest;
    // Each `%…` prefix belongs to the `---` it introduces, not a document of its
    // own: `Document` is doc 1, the empty `---` is doc 2, and `%YAML 1.2\n---\n…`
    // is doc 3.
    const src =
        \\Document
        \\---
        \\# Empty
        \\...
        \\%YAML 1.2
        \\---
        \\matches %: 20
        \\
    ;
    const stream = try extractStream(testing.allocator, src);
    defer stream.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), stream.documents.len);
    try testing.expectEqualSlices(u8, "Document", rootKind(stream.documents[0].document).string);
    try testing.expect(rootKind(stream.documents[1].document) == .null_);
    try testing.expectEqualSlices(u8, "20", (try stream.documents[2].document.ast.getValByPath(&.{.{ .key = "matches %" }})).kind.number.raw);
}

test "extractStream: a tag handle scoped to the first document fails later use (QLJ7)" {
    if (comptime !build_options.lang_yaml) return error.SkipZigTest;
    // `!prefix!` is declared only for the first document; documents 2 and 3 use
    // it undeclared, so the splitter must reject the stream.
    const src =
        \\%TAG !prefix! tag:example.com,2011:
        \\--- !prefix!A
        \\a: b
        \\--- !prefix!B
        \\c: d
        \\
    ;
    try testing.expectError(error.UndefinedTagHandle, extractStream(testing.allocator, src));
}

test "extractStream: two document start markers yields two null docs (6XDY)" {
    if (comptime !build_options.lang_yaml) return error.SkipZigTest;
    const stream = try extractStream(testing.allocator, "---\n---\n");
    defer stream.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), stream.documents.len);
    try testing.expect(rootKind(stream.documents[0].document) == .null_);
    try testing.expect(rootKind(stream.documents[1].document) == .null_);
}

test "extractStream: document start on last line (PUW8)" {
    if (comptime !build_options.lang_yaml) return error.SkipZigTest;
    const stream = try extractStream(testing.allocator, "---\na: b\n---\n");
    defer stream.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), stream.documents.len);
    try testing.expectEqualSlices(u8, "b", (try stream.documents[0].document.ast.getValByPath(&.{.{ .key = "a" }})).kind.string);
    try testing.expect(rootKind(stream.documents[1].document) == .null_);
}

test "extractStream: bare docs separated by ... with a comment-only segment (M7A3)" {
    if (comptime !build_options.lang_yaml) return error.SkipZigTest;
    const src = "Bare\ndocument\n...\n# No document\n...\n|\n  %!PS-Adobe-2.0 # Not the first line\n";
    const stream = try extractStream(testing.allocator, src);
    defer stream.deinit(testing.allocator);
    // The `# No document` segment is comment-only and produces no document.
    try testing.expectEqual(@as(usize, 2), stream.documents.len);
    try testing.expect(!stream.documents[0].explicit);
    try testing.expectEqualSlices(u8, "Bare document", rootKind(stream.documents[0].document).string);
}

test "extractStream: inline content on the marker line (L383)" {
    if (comptime !build_options.lang_yaml) return error.SkipZigTest;
    const stream = try extractStream(testing.allocator, "--- foo  # comment\n--- foo  # comment\n");
    defer stream.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), stream.documents.len);
    try testing.expectEqualSlices(u8, "foo", rootKind(stream.documents[0].document).string);
    try testing.expectEqualSlices(u8, "foo", rootKind(stream.documents[1].document).string);
}

test "extractStream: explicit doc then bare doc after ... (7Z25)" {
    if (comptime !build_options.lang_yaml) return error.SkipZigTest;
    const stream = try extractStream(testing.allocator, "---\nscalar1\n...\nkey: value\n");
    defer stream.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), stream.documents.len);
    try testing.expect(stream.documents[0].explicit);
    try testing.expectEqualSlices(u8, "scalar1", rootKind(stream.documents[0].document).string);
    try testing.expect(!stream.documents[1].explicit);
    try testing.expectEqualSlices(u8, "value", (try stream.documents[1].document.ast.getValByPath(&.{.{ .key = "key" }})).kind.string);
}

test "extractStream: single bare document" {
    if (comptime !build_options.lang_yaml) return error.SkipZigTest;
    const stream = try extractStream(testing.allocator, "key: value\n");
    defer stream.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), stream.documents.len);
    try testing.expect(!stream.documents[0].explicit);
}

test "extractStream: empty stream is one null document" {
    if (comptime !build_options.lang_yaml) return error.SkipZigTest;
    const stream = try extractStream(testing.allocator, "");
    defer stream.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), stream.documents.len);
    try testing.expect(rootKind(stream.documents[0].document) == .null_);
}

test "extractStream: outerSpan lifts node spans into outer coordinates" {
    if (comptime !build_options.lang_yaml) return error.SkipZigTest;
    const src = "---\nfoo\n---\nbar\n";
    const stream = try extractStream(testing.allocator, src);
    defer stream.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), stream.documents.len);
    const d1 = stream.documents[1];
    const node = d1.document.ast.nodes[d1.document.ast.root];
    const outer = d1.outerSpan(d1.document.span(node));
    try testing.expectEqualSlices(u8, "bar", src[outer.start..outer.end]);
}

// --- Embed.detect / Embed.retype ------------------------------------------

test "detect: recognizes YAML frontmatter" {
    const src = "---\ntitle: hi\n---\nbody\n";
    try testing.expectEqual(@as(?Type, .FrontmatterYaml), detect(src));
}

test "detect: recognizes JSON frontmatter" {
    const src = ";;;\n{\"title\":\"hi\"}\n;;;\nbody\n";
    try testing.expectEqual(@as(?Type, .FrontmatterJson), detect(src));
}

test "detect: recognizes fig frontmatter" {
    if (comptime !build_options.lang_fig) return error.SkipZigTest;
    const src = "```fig\ntitle = hi\n```\nbody\n";
    try testing.expectEqual(@as(?Type, .FrontmatterFig), detect(src));
}

test "detect: recognizes YAML endmatter" {
    const src = "body prose\n```endmatter\ntitle: hi\n```\n";
    try testing.expectEqual(@as(?Type, .EndmatterYaml), detect(src));
}

test "detect: an unterminated block is still recognized (caller sees Unterminated, not NotFound)" {
    const src = "---\ntitle: hi\n";
    try testing.expectEqual(@as(?Type, .FrontmatterYaml), detect(src));
    try testing.expectError(Error.Unterminated, locateRegion(src, detect(src).?));
}

test "detect: plain prose with no fences at all detects nothing" {
    try testing.expectEqual(@as(?Type, null), detect("just some markdown\n\nno frontmatter here\n"));
}

test "retype: YAML frontmatter -> JSON frontmatter, body preserved byte-identical" {
    const src = "---\ntitle: hi\n---\n# body\n";
    const region = try locateRegion(src, .FrontmatterYaml);
    const out = try retype(testing.allocator, src, region, .FrontmatterJson, "{\"title\":\"hi\"}\n");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(";;;\n{\"title\":\"hi\"}\n;;;\n# body\n", out);
}

test "retype: frontmatter -> endmatter moves the fences to the end, body first" {
    const src = "---\ntitle: hi\n---\n# body\n";
    const region = try locateRegion(src, .FrontmatterYaml);
    const out = try retype(testing.allocator, src, region, .EndmatterYaml, "title: hi\n");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("# body\n```endmatter\ntitle: hi\n```\n", out);
}
