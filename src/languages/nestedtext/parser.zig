//! The parser turns a NestedText-formatted `[]const u8` into an AST.
//!
//! Every scalar is an untyped `.string` — NestedText, like INI, never
//! coerces a value's type at the format layer (see `nestedtext.org`'s design
//! philosophy: "strings all the way down"). Containers nest to arbitrary
//! depth via indentation (`mapping`/`sequence`), same as YAML/TOML, but with
//! none of their lexical complexity: rest-of-line values are 100% literal
//! (no escapes, no quoting, no reinterpretation — confirmed by the official
//! conformance suite: a value starting with `[` after `key: ` stays the
//! literal string, never an inline list).
//!
//! ── Algorithm sketch ─────────────────────────────────────────────────────
//! `parseRegion(parent_indent)` parses "the value that belongs here" — either
//! the whole top-level document (`parent_indent == null`, value indent must
//! be exactly 0) or the nested block under an item whose same-line value was
//! left empty (`parent_indent = Some(item's own indent)`, value indent must
//! be greater). Two cases:
//!   1. The region's first line is `.other`-kind and starts with `{`/`[`
//!      (never a valid dict-item key — NestedText forbids a key from
//!      starting with those chars) → parse it as a single-line inline
//!      value (`parseInlineLine`), then require nothing else follows in
//!      this region (else `error.ExtraContent`).
//!   2. Otherwise → `parseContainerAt`, a normal block dispatch to a list
//!      (`.dash` siblings), dict (`.colon` multiline-key runs and/or
//!      `.other` `key: value` siblings, freely intermixed), or string
//!      (`.gt` siblings) block.
//! Partial-dedent detection needs no explicit indent stack: each block's
//! sibling loop only continues while `line.indent == indent`, breaks
//! (returns to its caller) when `line.indent < indent`, and errors when
//! `line.indent > indent` (a line that skipped past this level without
//! landing on it) — recursion through the call stack does the rest, exactly
//! as it would for hand-nested parens.
//!
//! Inline `{...}`/`[...]` forms get their own tiny scanner
//! (`parseInline*`/`scanInlineValue`) operating on absolute byte offsets
//! into `source`; see its section below for the delimiter-error rules
//! reverse-engineered from the official conformance suite (`{a:0,}` and
//! friends).

const Parser = @This();

const std = @import("std");
const testing = std.testing;
const AST = @import("../../ast/ast.zig");
const Document = @import("../../document.zig");
const Type = @import("nestedtext.zig").Type;
const Span = @import("../../util/span.zig");
const flat_map = @import("../shared/flat_map.zig");
const Tokenizer = @import("tokenizer.zig");
const Line = Tokenizer.Line;
const parse_diagnostic = @import("../../parse_diagnostic.zig");

allocator: std.mem.Allocator,
version: Type = .NESTEDTEXT,
source: []const u8 = "",
lines: []const Line = &.{},
pos: usize = 0,
arena: flat_map.NodeArena = undefined,
owned_strings: std.ArrayList([]const u8) = .empty,
pending_leading: std.ArrayList(AST.Comment) = .empty,
comments_seen: bool = false,

/// Absolute cursor into `source` used only while scanning an inline
/// `{...}`/`[...]` line (see the "Inline values" section). `iend` is the
/// exclusive end of that line's content span.
ipos: usize = 0,
iend: usize = 0,

fail_offset: usize = 0,
fail_end: ?usize = null,

pub const ParseError = error{
    InvalidUtf8,
    TopLevelIndent,
    InvalidIndentation,
    ExpectedDictItem,
    ExpectedListItem,
    UnrecognizedLine,
    MissingValue,
    MultilineKeyNoValue,
    MultilineKeyBadValue,
    DuplicateKey,
    ExtraContent,
    ExtraCharsAfterDelim,
    UnclosedDelim,
    ExpectedColon,
    ExpectedCommaOrClose,
};
pub const ParserError = ParseError || Tokenizer.TokenizeError || std.mem.Allocator.Error;
pub const Error = ParserError;

pub fn describe(code: Error) []const u8 {
    return switch (code) {
        error.InvalidUtf8 => "this file is not valid UTF-8; NestedText documents must be UTF-8 encoded",
        error.InvalidIndentChar => "indentation must use plain spaces; a tab or other whitespace character is not allowed here",
        error.TopLevelIndent => "top-level content must start in column 1",
        error.InvalidIndentation => "this line's indentation does not match any enclosing block (partial dedent)",
        error.ExpectedDictItem => "expected a dictionary item (`key: value` or a `: multiline key` line) here",
        error.ExpectedListItem => "expected a list item (`- value`) here",
        error.UnrecognizedLine => "this line is not a valid dictionary item, list item, string item, or comment",
        error.MissingValue => "expected a value here",
        error.MultilineKeyNoValue => "a multiline key requires a value on a more-indented line",
        error.MultilineKeyBadValue => "the value of a multiline key must be on a more-indented line",
        error.DuplicateKey => "this key is already defined in this mapping",
        error.ExtraContent => "unexpected content after the document's value",
        error.ExtraCharsAfterDelim => "unexpected content after the closing `}`/`]`",
        error.UnclosedDelim => "this line ended without a closing `}`/`]`",
        error.ExpectedColon => "expected `:` after this inline dictionary key",
        error.ExpectedCommaOrClose => "expected `,` or a closing `}`/`]` here",
        error.OutOfMemory => "out of memory",
    };
}

pub fn shortLabel(code: Error) []const u8 {
    return switch (code) {
        error.InvalidUtf8 => "invalid UTF-8",
        error.InvalidIndentChar => "invalid indentation",
        error.TopLevelIndent => "bad top-level indent",
        error.InvalidIndentation => "bad indentation",
        error.ExpectedDictItem => "expected dictionary item",
        error.ExpectedListItem => "expected list item",
        error.UnrecognizedLine => "unrecognized line",
        error.MissingValue => "expected value",
        error.MultilineKeyNoValue => "missing value",
        error.MultilineKeyBadValue => "missing value",
        error.DuplicateKey => "duplicate key",
        error.ExtraContent => "extra content",
        error.ExtraCharsAfterDelim => "extra characters",
        error.UnclosedDelim => "unclosed delimiter",
        error.ExpectedColon => "expected `:`",
        error.ExpectedCommaOrClose => "expected `,` or close",
        error.OutOfMemory => "out of memory",
    };
}

pub const Diagnostic = struct {
    code: Error,
    offset: usize,
    end: ?usize = null,

    pub fn locate(self: Diagnostic, source: []const u8) parse_diagnostic.Location {
        return parse_diagnostic.locateOffset(source, self.offset);
    }
    pub fn renderAlloc(self: Diagnostic, allocator: std.mem.Allocator, source: []const u8, file: []const u8) std.mem.Allocator.Error![]u8 {
        return parse_diagnostic.renderReportAlloc(allocator, source, self.offset, file, "error", describe(self.code));
    }
};

pub const Report = struct { diag: ?Diagnostic = null };

pub fn parse(allocator: std.mem.Allocator, input: []const u8, format: Type) ParserError!Document {
    return parseImpl(allocator, input, format, null);
}

pub fn parseWithReport(allocator: std.mem.Allocator, input: []const u8, format: Type, out: *Report) ParserError!Document {
    return parseImpl(allocator, input, format, out);
}

pub fn parseAbstract(allocator: std.mem.Allocator, input: []const u8, format: Type) ParserError!AST {
    const doc = try parse(allocator, input, format);
    allocator.free(doc.node_spans);
    return doc.ast;
}

fn parseImpl(allocator: std.mem.Allocator, input: []const u8, format: Type, out: ?*Report) ParserError!Document {
    var parser: Parser = .{ .allocator = allocator, .arena = .{ .allocator = allocator } };
    const result = parser.parseOnce(input, format);
    return result catch |err| {
        if (out) |o| o.diag = .{ .code = err, .offset = parser.fail_offset, .end = parser.fail_end };
        for (parser.owned_strings.items) |s| allocator.free(s);
        parser.owned_strings.deinit(allocator);
        parser.arena.nodes.deinit(allocator);
        parser.arena.spans.deinit(allocator);
        return err;
    };
}

fn parseOnce(self: *Parser, input: []const u8, format: Type) ParserError!Document {
    self.version = format;
    self.source = input;

    if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidUtf8;

    var tokenizer: Tokenizer = .{ .allocator = self.allocator, .str = input };
    self.lines = tokenizer.tokenize() catch |err| {
        self.fail_offset = tokenizer.i;
        return err;
    };
    defer self.allocator.free(self.lines);
    try self.pending_leading.ensureTotalCapacity(self.allocator, self.lines.len);
    defer self.pending_leading.deinit(self.allocator);
    defer {
        for (self.arena.node_comments.items) |nc| {
            self.allocator.free(nc.leading);
            self.allocator.free(nc.dangling);
        }
        self.arena.node_comments.deinit(self.allocator);
    }

    const root_id = try self.parseRegion(null, .null_document);
    self.skipBlank();
    if (!self.atEnd()) return self.failAtLine(self.peek(), error.ExtraContent);
    try self.claimDangling(root_id);

    const nodes = try self.arena.nodes.toOwnedSlice(self.allocator);
    errdefer self.allocator.free(nodes);
    const spans = try self.arena.spans.toOwnedSlice(self.allocator);
    errdefer self.allocator.free(spans);
    const owned = try self.owned_strings.toOwnedSlice(self.allocator);

    var ast: AST = .{ .allocator = self.allocator, .root = root_id, .nodes = nodes, .owned_strings = owned };
    if (self.comments_seen) {
        ast.node_comments = try self.arena.node_comments.toOwnedSlice(self.allocator);
        self.arena.node_comments = .empty;
    }

    return .{ .source = input, .ast = ast, .node_spans = spans };
}

// ── Line cursor ─────────────────────────────────────────────────────────────

fn peek(self: *Parser) Line {
    return self.lines[self.pos];
}
fn atEnd(self: *Parser) bool {
    return self.peek().kind == .end_of_file;
}

fn skipBlank(self: *Parser) void {
    while (true) switch (self.peek().kind) {
        .comment => {
            self.captureComment(self.peek());
            self.pos += 1;
        },
        .blank => self.pos += 1,
        else => return,
    };
}

fn captureComment(self: *Parser, l: Line) void {
    self.pending_leading.appendAssumeCapacity(.{ .text = self.source[l.content.start..l.content.end], .style = .line });
}

fn claimLeading(self: *Parser, id: AST.Node.Id) ParserError!void {
    self.attachLeading(id, try self.takeLeading());
}

/// Snapshot-and-clear the currently pending leading comments, WITHOUT
/// attaching them to a node yet. Split out of `claimLeading` for
/// `parseListBlock`: a list item has no node of its own to claim onto until
/// AFTER `parseItemValue` returns (unlike a dict item, which creates its key
/// node — and calls `claimLeading` on it — before parsing its value), and if
/// that value is itself a nested container, its own first entry would
/// otherwise call `claimLeading` FIRST and steal the comment meant for the
/// outer list item. Callers on this path snapshot before recursing into
/// `parseItemValue`, then `attachLeading` once the item's real node id is
/// known.
fn takeLeading(self: *Parser) ParserError!?[]AST.Comment {
    if (self.pending_leading.items.len == 0) return null;
    const owned = try self.allocator.dupe(AST.Comment, self.pending_leading.items);
    self.pending_leading.clearRetainingCapacity();
    return owned;
}

fn attachLeading(self: *Parser, id: AST.Node.Id, leading: ?[]AST.Comment) void {
    const owned = leading orelse return;
    self.arena.node_comments.items[id].leading = owned;
    self.comments_seen = true;
}

fn claimDangling(self: *Parser, id: AST.Node.Id) ParserError!void {
    if (self.pending_leading.items.len == 0) return;
    const owned = try self.allocator.dupe(AST.Comment, self.pending_leading.items);
    self.pending_leading.clearRetainingCapacity();
    self.arena.node_comments.items[id].dangling = owned;
    self.comments_seen = true;
}

fn failAtLine(self: *Parser, l: Line, err: Error) Error {
    self.fail_offset = l.line_start;
    self.fail_end = l.content.end;
    return err;
}
fn failHere(self: *Parser, err: Error) Error {
    self.fail_offset = self.peek().line_start;
    return err;
}

fn intern(self: *Parser, owned: []const u8) ParserError![]const u8 {
    try self.owned_strings.append(self.allocator, owned);
    return owned;
}

fn appendSeqItem(self: *Parser, seq_id: AST.Node.Id, value_id: AST.Node.Id) void {
    if (self.arena.nodes.items[seq_id].kind.sequence) |first| {
        var last = first;
        while (self.arena.nodes.items[last].next_sibling) |n| last = n;
        self.arena.nodes.items[last].next_sibling = value_id;
    } else {
        self.arena.nodes.items[seq_id].kind = .{ .sequence = value_id };
    }
}

// ── Regions and blocks ───────────────────────────────────────────────────────

/// What a region with no deeper content resolves to: the whole document
/// (empty file → `.null_`), a plain item's value (empty rest-of-line AND no
/// nested block → the empty STRING, per the official conformance suite —
/// `key:`/`-` alone is not an error, only a *multiline* key strictly
/// requires a value; see `MissingBehavior.err` below), or a multiline key's
/// value (which DOES strictly require one — the caller pre-checks and picks
/// the right of the two dedicated error codes, so `.err` here is only ever a
/// defensive fallback, never actually reached).
const MissingBehavior = enum { null_document, empty_string, err };

/// Parse the value belonging at this position: the whole document
/// (`parent_indent == null`) or a nested value-region under an item whose
/// same-line value was empty (`parent_indent = Some(item indent)`). See the
/// module doc comment for the algorithm.
fn parseRegion(self: *Parser, parent_indent: ?usize, on_missing: MissingBehavior) ParserError!AST.Node.Id {
    self.skipBlank();
    const no_content = self.atEnd() or (parent_indent != null and self.peek().indent <= parent_indent.?);
    if (no_content) {
        return switch (on_missing) {
            .null_document => self.arena.addNode(.{ .null_ = {} }, Span.init(self.source.len, self.source.len)),
            .empty_string => blk: {
                const at = if (self.atEnd()) self.source.len else self.peek().line_start;
                break :blk self.arena.addNode(.{ .string = "" }, Span.init(at, at));
            },
            .err => self.failHere(error.MissingValue),
        };
    }

    const first = self.peek();
    const region_indent = first.indent;
    if (parent_indent == null and region_indent != 0) return self.failAtLine(first, error.TopLevelIndent);

    if (first.kind == .other and self.startsWithBracket(first)) {
        const node = try self.parseInlineLine(first);
        self.pos += 1;
        self.skipBlank();
        const still_in_region = !self.atEnd() and (parent_indent == null or self.peek().indent > parent_indent.?);
        if (still_in_region) return self.failAtLine(self.peek(), error.ExtraContent);
        return node;
    }

    return self.parseContainerAt(region_indent);
}

fn startsWithBracket(self: *Parser, l: Line) bool {
    if (l.content.len() == 0) return false;
    const c = self.source[l.content.start];
    return c == '{' or c == '[';
}

/// First occurrence of `: ` or a trailing `:` at end-of-line within an
/// `.other` line's content — the dict-item key/value split point. Never
/// matches at offset 0 (an `.other` line never starts with `:`; that's the
/// dedicated `.colon` tag kind instead).
fn splitDictItem(self: *Parser, l: Line) ?struct { key_end: usize, val_start: usize } {
    var i = l.content.start;
    while (i < l.content.end) : (i += 1) {
        if (self.source[i] != ':') continue;
        if (i + 1 == l.content.end) return .{ .key_end = i, .val_start = l.content.end };
        if (self.source[i + 1] == ' ') return .{ .key_end = i, .val_start = i + 2 };
    }
    return null;
}

fn isDictItemLine(self: *Parser, l: Line) bool {
    if (self.startsWithBracket(l)) return false; // a key can never start with `{`/`[`
    return self.splitDictItem(l) != null;
}

fn parseContainerAt(self: *Parser, indent: usize) ParserError!AST.Node.Id {
    const first = self.peek();
    return switch (first.kind) {
        .dash => self.parseListBlock(indent),
        .gt => self.parseStringBlock(indent),
        .colon => self.parseDictBlock(indent),
        .other => if (self.isDictItemLine(first)) self.parseDictBlock(indent) else self.failAtLine(first, error.UnrecognizedLine),
        .blank, .comment, .end_of_file => unreachable, // skipBlank already advanced past these
    };
}

/// The value of a dash/dict-item whose rest-of-line content is `content`:
/// literal same-line text if non-empty; else the nested value-region at
/// `container_indent` if one follows (deeper indent); else the empty
/// STRING — a bare `key:`/`-` with nothing more indented after it is NOT an
/// error (confirmed by the official conformance suite, e.g. `key2:` at
/// end-of-file loads as `""`); only a *multiline* key strictly requires a
/// value (see `parseDictBlock`'s `.colon` branch).
fn parseItemValue(self: *Parser, content: Span, container_indent: usize) ParserError!AST.Node.Id {
    if (content.len() != 0) {
        return self.arena.addNode(.{ .string = self.source[content.start..content.end] }, content);
    }
    return self.parseRegion(container_indent, .empty_string);
}

fn parseListBlock(self: *Parser, indent: usize) ParserError!AST.Node.Id {
    const start = self.peek().line_start;
    const seq_id = try self.arena.addNode(.{ .sequence = null }, Span.init(start, start));
    var end = start;
    while (true) {
        self.skipBlank();
        if (self.atEnd()) break;
        const l = self.peek();
        if (l.indent < indent) break;
        if (l.indent > indent) return self.failAtLine(l, error.InvalidIndentation);
        if (l.kind != .dash) return self.failAtLine(l, error.ExpectedListItem);
        self.pos += 1;
        // Snapshot the item's own leading comment BEFORE recursing into its
        // value: a list item has no node of its own until `parseItemValue`
        // returns, and if the value is itself a nested container, its first
        // entry would otherwise claim this comment first (see `takeLeading`'s
        // doc comment).
        const leading = try self.takeLeading();
        const value_id = try self.parseItemValue(l.content, indent);
        self.attachLeading(value_id, leading);
        self.appendSeqItem(seq_id, value_id);
        end = self.arena.spans.items[value_id].end;
    }
    self.arena.spans.items[seq_id].end = end;
    return seq_id;
}

fn parseDictBlock(self: *Parser, indent: usize) ParserError!AST.Node.Id {
    const start = self.peek().line_start;
    const map_id = try self.arena.addNode(.{ .mapping = null }, Span.init(start, start));
    var end = start;
    while (true) {
        self.skipBlank();
        if (self.atEnd()) break;
        const l = self.peek();
        if (l.indent < indent) break;
        if (l.indent > indent) return self.failAtLine(l, error.InvalidIndentation);

        if (l.kind == .colon) {
            const mk = try self.collectMultilineKey(indent);
            const key_id = try self.arena.addNode(.{ .string = mk.text }, mk.span);
            try self.claimLeading(key_id);
            if (self.atEnd()) return self.failHere(error.MultilineKeyNoValue);
            if (self.peek().indent <= indent) return self.failAtLine(self.peek(), error.MultilineKeyBadValue);
            const value_id = try self.parseRegion(indent, .err); // unreachable fallback: already validated deeper content exists
            _ = try flat_map.putEntry(&self.arena, map_id, key_id, value_id, .err);
            end = self.arena.spans.items[value_id].end;
        } else if (l.kind == .other and self.isDictItemLine(l)) {
            const split = self.splitDictItem(l).?;
            self.pos += 1;
            // "Spaces between key and tag are ignored" — trim trailing
            // whitespace (space, tab, AND a trailing U+00A0 NO-BREAK SPACE —
            // the official suite exercises a tab and an NBSP right before
            // the `:`, e.g. `k4\t: v4`/`key 3\xc2\xa0: value 3`) the raw
            // key/tag scan left in (leading is already impossible:
            // `l.content.start` is the line's first non-space byte). The
            // VALUE is never trimmed — rest-of-line text is always 100%
            // literal, tabs included.
            const key_text = std.mem.trimEnd(u8, self.source[l.content.start..split.key_end], " \t\xC2\xA0");
            const key_id = try self.arena.addNode(.{ .string = key_text }, Span.init(l.content.start, l.content.start + key_text.len));
            try self.claimLeading(key_id);
            const value_id = try self.parseItemValue(Span.init(split.val_start, l.content.end), indent);
            _ = try flat_map.putEntry(&self.arena, map_id, key_id, value_id, .err);
            end = self.arena.spans.items[value_id].end;
        } else {
            return self.failAtLine(l, error.ExpectedDictItem);
        }
    }
    self.arena.spans.items[map_id].end = end;
    return map_id;
}

/// The next line INDEX at exactly `indent` with kind `kind`, skipping over
/// any number of intervening blank/comment lines (which are transparent
/// inside a `>`/`: ` multiline run — confirmed by the official conformance
/// suite: a `#`-comment or blank line strictly between two `>` lines
/// contributes nothing to the joined value, not even an extra blank line).
/// Returns `null`, WITHOUT moving `self.pos`, when no such line follows
/// (the run has genuinely ended — the skipped blank/comment lines are left
/// for the enclosing container's own `skipBlank` to claim).
fn probeNext(self: *Parser, kind: Tokenizer.Kind, indent: usize) ?usize {
    var i = self.pos;
    while (i < self.lines.len and (self.lines[i].kind == .blank or self.lines[i].kind == .comment)) i += 1;
    if (i >= self.lines.len) return null;
    const l = self.lines[i];
    if (l.kind != kind or l.indent != indent) return null;
    return i;
}

fn parseStringBlock(self: *Parser, indent: usize) ParserError!AST.Node.Id {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(self.allocator);
    const start = self.peek().line_start;
    var end = start;
    var first = true;
    while (self.probeNext(.gt, indent)) |i| {
        self.pos = i;
        const l = self.lines[self.pos];
        if (!first) try buf.append(self.allocator, '\n');
        first = false;
        try buf.appendSlice(self.allocator, self.source[l.content.start..l.content.end]);
        end = l.content.end;
        self.pos += 1;
    }
    const owned = try self.intern(try buf.toOwnedSlice(self.allocator));
    return self.arena.addNode(.{ .string = owned }, Span.init(start, end));
}

/// Consecutive `.colon`-tagged lines at `indent` — see `probeNext` for how
/// intervening blank/comment lines are skipped transparently.
fn collectMultilineKey(self: *Parser, indent: usize) ParserError!struct { text: []const u8, span: Span } {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(self.allocator);
    const start = self.peek().line_start;
    var end = start;
    var first = true;
    while (self.probeNext(.colon, indent)) |i| {
        self.pos = i;
        const l = self.lines[self.pos];
        if (!first) try buf.append(self.allocator, '\n');
        first = false;
        try buf.appendSlice(self.allocator, self.source[l.content.start..l.content.end]);
        end = l.content.end;
        self.pos += 1;
    }
    const owned = try self.intern(try buf.toOwnedSlice(self.allocator));
    return .{ .text = owned, .span = Span.init(start, end) };
}

// ── Inline values (`{...}`/`[...]`) ─────────────────────────────────────────
// Only ever reached as the ENTIRE content of one line: a top-level document
// that's a single `{...}`/`[...]` line, or the sole line of a nested
// value-region under an item that left its same-line value empty. Never
// recognized after `key: ` on the same line (rest-of-line values are always
// literal — see the module doc comment). Delimiter-error rules below are
// reverse-engineered from the official conformance suite (see
// `testdata/nestedtext/tests.json`, cases `emanate`/`conclude`/`baptism`/
// `protrude`/`collate` etc.): a trailing comma before a closing delimiter is
// `error.MissingValue` ("expected a value here"), a value/key that runs off
// the end of the line without a delimiter is `error.UnclosedDelim`, a raw
// string value/key that hits a stray bracket/brace mid-scan (not at its very
// start, where it would instead recurse into a nested container) is
// `error.ExpectedCommaOrClose`/`error.ExpectedColon`.

const Close = enum { brace, bracket, none };
fn closeChar(ctx: Close) u8 {
    return switch (ctx) {
        .brace => '}',
        .bracket => ']',
        .none => 0,
    };
}
fn isInlineStop(c: u8) bool {
    return c == ',' or c == '{' or c == '}' or c == '[' or c == ']';
}

fn parseInlineLine(self: *Parser, l: Line) ParserError!AST.Node.Id {
    self.ipos = l.content.start;
    self.iend = l.content.end;
    const node = try self.parseInlineValue(.none);
    self.skipInlineWs();
    if (self.ipos < self.iend) {
        self.fail_offset = self.ipos;
        return error.ExtraCharsAfterDelim;
    }
    return node;
}

fn skipInlineWs(self: *Parser) void {
    // Space AND tab — the official suite exercises tabs as free-form
    // whitespace around every inline delimiter (`,`/`:`/`{`/`[`/`}`/`]`).
    while (self.ipos < self.iend and (self.source[self.ipos] == ' ' or self.source[self.ipos] == '\t')) self.ipos += 1;
}

fn parseInlineValue(self: *Parser, ctx: Close) ParserError!AST.Node.Id {
    self.skipInlineWs();
    if (self.ipos >= self.iend) {
        self.fail_offset = self.ipos;
        return error.UnclosedDelim;
    }
    return switch (self.source[self.ipos]) {
        '{' => self.parseInlineDict(),
        '[' => self.parseInlineList(),
        else => self.scanInlineValue(ctx),
    };
}

fn scanInlineValue(self: *Parser, ctx: Close) ParserError!AST.Node.Id {
    const start = self.ipos;
    while (self.ipos < self.iend and !isInlineStop(self.source[self.ipos])) self.ipos += 1;
    const raw_end = self.ipos;
    if (self.ipos < self.iend) {
        const stop = self.source[self.ipos];
        if (stop != ',' and stop != closeChar(ctx)) {
            self.fail_offset = self.ipos;
            return error.ExpectedCommaOrClose;
        }
    }
    const text = std.mem.trimEnd(u8, self.source[start..raw_end], " \t");
    return self.arena.addNode(.{ .string = text }, Span.init(start, raw_end));
}

fn parseInlineEntry(self: *Parser, map_id: AST.Node.Id) ParserError!void {
    self.skipInlineWs();
    const key_start = self.ipos;
    while (self.ipos < self.iend and self.source[self.ipos] != ':' and !isInlineStop(self.source[self.ipos])) self.ipos += 1;
    if (self.ipos >= self.iend) {
        self.fail_offset = self.ipos;
        return error.UnclosedDelim;
    }
    if (self.source[self.ipos] != ':') {
        self.fail_offset = self.ipos;
        return error.ExpectedColon;
    }
    const key_text = std.mem.trimEnd(u8, self.source[key_start..self.ipos], " \t");
    const key_id = try self.arena.addNode(.{ .string = key_text }, Span.init(key_start, self.ipos));
    self.ipos += 1; // consume ':'
    const value_id = try self.parseInlineValue(.brace);
    _ = try flat_map.putEntry(&self.arena, map_id, key_id, value_id, .err);
}

fn parseInlineDict(self: *Parser) ParserError!AST.Node.Id {
    const start = self.ipos;
    self.ipos += 1; // consume '{'
    const map_id = try self.arena.addNode(.{ .mapping = null }, Span.init(start, start));
    if (self.ipos < self.iend and self.source[self.ipos] == '}') {
        self.ipos += 1;
        self.arena.spans.items[map_id].end = self.ipos;
        return map_id;
    }
    var first = true;
    while (true) {
        if (!first) {
            self.skipInlineWs();
            if (self.ipos < self.iend and self.source[self.ipos] == '}') {
                self.fail_offset = self.ipos;
                return error.MissingValue;
            }
        }
        first = false;
        try self.parseInlineEntry(map_id);
        self.skipInlineWs();
        if (self.ipos >= self.iend) {
            self.fail_offset = self.ipos;
            return error.UnclosedDelim;
        }
        const d = self.source[self.ipos];
        if (d == ',') {
            self.ipos += 1;
            continue;
        }
        if (d == '}') {
            self.ipos += 1;
            break;
        }
        self.fail_offset = self.ipos;
        return error.ExpectedCommaOrClose;
    }
    self.arena.spans.items[map_id].end = self.ipos;
    return map_id;
}

fn parseInlineList(self: *Parser) ParserError!AST.Node.Id {
    const start = self.ipos;
    self.ipos += 1; // consume '['
    const seq_id = try self.arena.addNode(.{ .sequence = null }, Span.init(start, start));
    if (self.ipos < self.iend and self.source[self.ipos] == ']') {
        self.ipos += 1;
        self.arena.spans.items[seq_id].end = self.ipos;
        return seq_id;
    }
    // Unlike a dict entry (which needs at least a key), a list element has
    // no minimum content — a comma boundary, including one immediately
    // before `]`, is simply an empty-string element. So (unlike
    // `parseInlineDict`) there is no "trailing comma" pre-check here: `[,]`
    // is `["", ""]` and `[a,]` is `["a", ""]`, confirmed by the official
    // conformance suite (`epoch`/`geyser`).
    while (true) {
        const value_id = try self.parseInlineValue(.bracket);
        self.appendSeqItem(seq_id, value_id);
        self.skipInlineWs();
        if (self.ipos >= self.iend) {
            self.fail_offset = self.ipos;
            return error.UnclosedDelim;
        }
        const d = self.source[self.ipos];
        if (d == ',') {
            self.ipos += 1;
            continue;
        }
        if (d == ']') {
            self.ipos += 1;
            break;
        }
        self.fail_offset = self.ipos;
        return error.ExpectedCommaOrClose;
    }
    self.arena.spans.items[seq_id].end = self.ipos;
    return seq_id;
}

// ── Tests ───────────────────────────────────────────────────────────────────

fn expectRoot(input: []const u8, key: []const u8, value: []const u8) !void {
    var ast = try parseAbstract(testing.allocator, input, .NESTEDTEXT);
    defer ast.deinit();
    const v = AST.getValByPath(&ast, &.{.{ .key = key }}) catch |err| {
        std.debug.print("path lookup failed: {}\n", .{err});
        return err;
    };
    try testing.expectEqualStrings(value, v.kind.string);
}

test "root-level key: value" {
    try expectRoot("name: fig\n", "name", "fig");
}

test "rest-of-line value is 100% literal, even one that looks like an inline list" {
    try expectRoot("regex  : [+-]?([0-9]*[.])?[0-9]+\n", "regex", "[+-]?([0-9]*[.])?[0-9]+");
}

test "empty document is null" {
    var ast = try parseAbstract(testing.allocator, "", .NESTEDTEXT);
    defer ast.deinit();
    try testing.expectEqual(AST.Node.Kind.null_, ast.nodes[ast.root].kind);

    var ast2 = try parseAbstract(testing.allocator, "# just a comment\n\n", .NESTEDTEXT);
    defer ast2.deinit();
    try testing.expectEqual(AST.Node.Kind.null_, ast2.nodes[ast2.root].kind);
}

test "single string item" {
    var ast = try parseAbstract(testing.allocator, "> hello\n", .NESTEDTEXT);
    defer ast.deinit();
    try testing.expectEqualStrings("hello", ast.nodes[ast.root].kind.string);
}

test "two blank string items join with a newline" {
    var ast = try parseAbstract(testing.allocator, ">\n>\n", .NESTEDTEXT);
    defer ast.deinit();
    try testing.expectEqualStrings("\n", ast.nodes[ast.root].kind.string);
}

test "list of scalars" {
    var ast = try parseAbstract(testing.allocator, "- a\n- b\n- c\n", .NESTEDTEXT);
    defer ast.deinit();
    const v = try AST.getValByPath(&ast, &.{.{ .index = 1 }});
    try testing.expectEqualStrings("b", v.kind.string);
}

test "nested block under an empty-content dict item" {
    var ast = try parseAbstract(testing.allocator, "server:\n    host: localhost\n    port: 80\n", .NESTEDTEXT);
    defer ast.deinit();
    const v = try AST.getValByPath(&ast, &.{ .{ .key = "server" }, .{ .key = "host" } });
    try testing.expectEqualStrings("localhost", v.kind.string);
}

test "multiline key" {
    var ast = try parseAbstract(testing.allocator, ": key 1\n: spread over 2 lines\n    > value 1\n", .NESTEDTEXT);
    defer ast.deinit();
    const v = try AST.getValByPath(&ast, &.{.{ .key = "key 1\nspread over 2 lines" }});
    try testing.expectEqualStrings("value 1", v.kind.string);
}

test "empty key via bare multiline-key form" {
    var ast = try parseAbstract(testing.allocator, ":\n  >\n", .NESTEDTEXT);
    defer ast.deinit();
    const v = try AST.getValByPath(&ast, &.{.{ .key = "" }});
    try testing.expectEqualStrings("", v.kind.string);
}

test "simple key and multiline key can be siblings in the same dict" {
    var ast = try parseAbstract(testing.allocator,
        \\here is a simple key: with a simple value
        \\: Here is a multiline key
        \\: with a list value.
        \\    - 0
        \\    - 1
        \\
    , .NESTEDTEXT);
    defer ast.deinit();
    const simple = try AST.getValByPath(&ast, &.{.{ .key = "here is a simple key" }});
    try testing.expectEqualStrings("with a simple value", simple.kind.string);
    const list = try AST.getValByPath(&ast, &.{ .{ .key = "Here is a multiline key\nwith a list value." }, .{ .index = 1 } });
    try testing.expectEqualStrings("1", list.kind.string);
}

test "top-level inline dict/list" {
    var ast = try parseAbstract(testing.allocator, "{key 1: value 1, key 2: [value 2a, value 2b]}", .NESTEDTEXT);
    defer ast.deinit();
    const v = try AST.getValByPath(&ast, &.{ .{ .key = "key 2" }, .{ .index = 1 } });
    try testing.expectEqualStrings("value 2b", v.kind.string);
}

test "empty inline dict and list" {
    var ast = try parseAbstract(testing.allocator, "{}", .NESTEDTEXT);
    defer ast.deinit();
    try testing.expectEqual(@as(?AST.Node.Id, null), ast.nodes[ast.root].kind.mapping);

    var ast2 = try parseAbstract(testing.allocator, "[]", .NESTEDTEXT);
    defer ast2.deinit();
    try testing.expectEqual(@as(?AST.Node.Id, null), ast2.nodes[ast2.root].kind.sequence);
}

test "`[ ]` (space inside) is a single-element list containing one empty string" {
    var ast = try parseAbstract(testing.allocator, "[ ]", .NESTEDTEXT);
    defer ast.deinit();
    const v = try AST.getValByPath(&ast, &.{.{ .index = 0 }});
    try testing.expectEqualStrings("", v.kind.string);
    try testing.expectEqual(@as(?AST.Node.Id, null), ast.nodes[ast.nodes[ast.root].kind.sequence.?].next_sibling);
}

test "`{:}` is a single entry with an empty key and empty value" {
    var ast = try parseAbstract(testing.allocator, "{:}", .NESTEDTEXT);
    defer ast.deinit();
    const v = try AST.getValByPath(&ast, &.{.{ .key = "" }});
    try testing.expectEqualStrings("", v.kind.string);
}

test "inline value nested under an empty-content list item" {
    var ast = try parseAbstract(testing.allocator, "-\n    {a:0}\n", .NESTEDTEXT);
    defer ast.deinit();
    const v = try AST.getValByPath(&ast, &.{ .{ .index = 0 }, .{ .key = "a" } });
    try testing.expectEqualStrings("0", v.kind.string);
}

test "duplicate key is an error" {
    try testing.expectError(error.DuplicateKey, parseAbstract(testing.allocator, "key: value 1\nkey: value 2\n", .NESTEDTEXT));
}

test "tab in indentation is an error" {
    try testing.expectError(error.InvalidIndentChar, parseAbstract(testing.allocator, "ingredients:\n\t> green chilies\n", .NESTEDTEXT));
}

test "top-level content must start in column 1" {
    try testing.expectError(error.TopLevelIndent, parseAbstract(testing.allocator, "  key: value\n", .NESTEDTEXT));
}

test "mixing list and dict siblings at the same indentation is an error" {
    try testing.expectError(error.ExpectedDictItem, parseAbstract(testing.allocator, "ingredients:\n- green chilies\n", .NESTEDTEXT));
    try testing.expectError(error.ExpectedListItem, parseAbstract(testing.allocator,
        \\ingredients:
        \\  - green chilies
        \\  cannot mix list with: dictionary
        \\
    , .NESTEDTEXT));
}

test "partial dedent to an indentation that matches no open block is an error" {
    try testing.expectError(error.InvalidIndentation, parseAbstract(testing.allocator,
        \\a:
        \\    b:
        \\        c: 1
        \\  d: 2
        \\
    , .NESTEDTEXT));
}

test "inline: trailing comma before a closing delimiter is `expected value`" {
    try testing.expectError(error.MissingValue, parseAbstract(testing.allocator, "{a:0,}", .NESTEDTEXT));
}

test "inline: mismatched bracket/brace inside a value is a delimiter error" {
    try testing.expectError(error.ExpectedColon, parseAbstract(testing.allocator, "-\n    {a}\n", .NESTEDTEXT));
    try testing.expectError(error.UnclosedDelim, parseAbstract(testing.allocator, "-\n    {\n", .NESTEDTEXT));
}

test "top-level singleton bracket line followed by more content is extra content" {
    try testing.expectError(error.ExtraContent, parseAbstract(testing.allocator, "[]\nnutz: truck\n", .NESTEDTEXT));
}

test "leading comment attaches to the following key" {
    var ast = try parseAbstract(testing.allocator, "# a header comment\nname: fig\n", .NESTEDTEXT);
    defer ast.deinit();
    const key_node = (try AST.firstChildKey(&ast, &ast.nodes[ast.root])).?;
    const cs = ast.comments(key_node.id);
    try testing.expectEqual(@as(usize, 1), cs.leading.len);
    try testing.expectEqualStrings(" a header comment", cs.leading[0].text);
}

test "leading comment above a list item attaches to the ITEM, not a descendant of its nested value" {
    // Regression: a list item has no node of its own until its value is
    // fully parsed, so a comment captured just above it must be snapshotted
    // BEFORE recursing into a nested value — otherwise that value's own
    // first entry (here, the `nested` key) claims it first. See
    // `takeLeading`'s doc comment.
    var ast = try parseAbstract(testing.allocator, "- a\n# middle item note\n-\n    nested: 1\n- c\n", .NESTEDTEXT);
    defer ast.deinit();
    const item = try AST.getValByPath(&ast, &.{.{ .index = 1 }});
    const cs = ast.comments(item.id);
    try testing.expectEqual(@as(usize, 1), cs.leading.len);
    try testing.expectEqualStrings(" middle item note", cs.leading[0].text);

    const nested_key = (try AST.firstChildKey(&ast, &item)).?;
    try testing.expectEqual(@as(usize, 0), ast.comments(nested_key.id).leading.len);
}
