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
    tokens: []const []const u8,
    match: enum { whole_line, prefix },
};

const Archetype = struct {
    open: Delimiter,
    close: Delimiter,
    location: enum { start, end, middle },
    inner: enum { yaml, json },
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
    };
}

/// An archetypal "config embedded in a host file" pattern. Each variant fixes
/// both *where* the config lives (the host's delimiter convention) and *what*
/// inner format it is — `---` fences imply YAML, by convention. This coupling
/// is deliberate: it keeps invalid (delimiter, format) combinations unspellable.
pub const Type = enum {
    /// `---` … `---`/`...` YAML frontmatter at the top of a markdown file.
    FrontmatterYaml,
    /// `;;;` … `;;;` JSON frontmatter at the top of a markdown file.
    FrontmatterJson,
    /// For Stephen Deken. YAML in an ending codeblock.
    EndmatterYaml,
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

/// Whether `t`'s body (the host prose) sits BEFORE the open fence (endmatter)
/// rather than after the close fence (frontmatter). Lets a host-coordinate
/// editor pick the side to splice when replacing the body.
pub fn bodyIsBefore(t: Type) bool {
    return archetypeOf(t).location == .end;
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
pub fn initRegion(allocator: Allocator, source: []const u8, t: Type) !Initialized {
    const a = archetypeOf(t);
    const open_tok = a.open.tokens[0];
    const close_tok = a.close.tokens[0];
    // The empty inner document seeded between the fences. JSON gets a trailing
    // newline so the close fence stays on its own line after the flow-mapping
    // insert (which preserves it); YAML's block insert emits its own newline, so
    // its empty content needs none.
    const seed: []const u8 = switch (a.inner) {
        .yaml => "",
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
            // The body is the host text outside the fences: the suffix after the
            // close fence for frontmatter, the prefix before the open fence for
            // endmatter (where the config trails the prose).
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
    const trimmed = std.mem.trimEnd(u8, line, " \t");
    for (d.tokens) |tok| {
        const ok = switch (d.match) {
            .whole_line => std.mem.eql(u8, trimmed, tok),
            .prefix => std.mem.startsWith(u8, line, tok),
        };
        if (ok) return Span.init(start, eol);
    }
    return null;
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
