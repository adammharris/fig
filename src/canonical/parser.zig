//! The canonical-form parser: text → AST, the exact inverse of
//! `canonical/printer.zig`. (This "canonical form" was formerly called "native";
//! the human-facing `fig` authoring dialect is a separate surface — see src/languages/fig/DESIGN.md.)
//!
//! Recursive-descent over the byte stream (the grammar is small enough that the
//! token framework the format parsers share would be overkill). It reconstructs
//! every `Node.Kind` arm and the YAML reference layer (anchors `&name`, tags
//! `!tag`, aliases `*name`) into the same side-tables the format parsers
//! populate, so `print` ∘ `parse` is the identity on any AST.
//!
//! Strings, numbers, anchor names and tag text borrow `input` where possible
//! (only escaped strings allocate, landing in the AST's `owned_strings`), so the
//! returned AST is valid only while `input` outlives it — same contract as the
//! JSON parser.

const Parser = @This();

const std = @import("std");
const AST = @import("../ast/ast.zig");
const Document = @import("../document.zig");
const Span = @import("../util/span.zig");
const Printer = @import("printer.zig");

const ExtKind = AST.Node.Kind.Extended.ExtKind;

allocator: std.mem.Allocator,
src: []const u8,
pos: usize = 0,
/// Current container-nesting depth, bounded by `Printer.max_depth` so a
/// pathologically nested input can't overflow the recursive descent's stack.
depth: usize = 0,

nodes: std.ArrayList(AST.Node) = .empty,
spans: std.ArrayList(Span) = .empty,
owned_strings: std.ArrayList([]const u8) = .empty,
// Reference layer, grown in lockstep with `nodes` (a null per node) and patched
// when a prefix is seen. Only materialized into the AST when `ref_seen`.
node_anchors: std.ArrayList(?[]const u8) = .empty,
node_tags: std.ArrayList(?[]const u8) = .empty,
anchors: std.ArrayList(AST.Anchor) = .empty,
ref_seen: bool = false,
// Comment layer, also grown in lockstep with `nodes`. `pending_leading` buffers
// own-line comments seen while skipping trivia until the next node claims them;
// trailing comments are set directly. Materialized only when `comments_seen`.
// Comment text borrows `src` (comments never contain escapes), so nothing here
// is owned except the per-node `leading` slices handed off at `claimLeading`.
node_comments: std.ArrayList(AST.NodeComments) = .empty,
pending_leading: std.ArrayList(AST.Comment) = .empty,
comments_seen: bool = false,

pub const ParseError = error{
    UnexpectedToken,
    UnexpectedEnd,
    UnclosedString,
    UnclosedArray,
    UnclosedObject,
    UnterminatedComment,
    ExpectedColon,
    InvalidExtended,
    InvalidEscape,
    InvalidUnicodeEscape,
    EmptyName,
    TrailingGarbage,
    NestingTooDeep,
};
pub const ParserError = ParseError || std.mem.Allocator.Error;

/// Parse `input` into an owned `AST`. Free with `ast.deinit()`.
pub fn parseAbstract(allocator: std.mem.Allocator, input: []const u8) ParserError!AST {
    const doc = try parse(allocator, input);
    allocator.free(doc.node_spans);
    return doc.ast;
}

/// Parse `input` into a `Document` (AST + source spans). Free with
/// `doc.deinit(allocator)`.
pub fn parse(allocator: std.mem.Allocator, input: []const u8) ParserError!Document {
    var parser: Parser = .{ .allocator = allocator, .src = input };
    defer parser.deinit();
    return parser.parseOnce();
}

pub fn deinit(self: *Parser) void {
    self.nodes.deinit(self.allocator);
    self.spans.deinit(self.allocator);
    for (self.owned_strings.items) |s| self.allocator.free(s);
    self.owned_strings.deinit(self.allocator);
    self.node_anchors.deinit(self.allocator);
    self.node_tags.deinit(self.allocator);
    self.anchors.deinit(self.allocator);
    // Free any `leading` slices still owned here. After a successful
    // `parseOnce` these moved to the AST and the list is empty; on an error
    // path they are freed here. Comment text borrows `src`, so it is not freed.
    for (self.node_comments.items) |nc| self.allocator.free(nc.leading);
    self.node_comments.deinit(self.allocator);
    self.pending_leading.deinit(self.allocator);
}

fn parseOnce(self: *Parser) ParserError!Document {
    const root = try self.parseNode();
    try self.claimLeading(root);
    // A trailing comment on the same line as the root, then the document's final
    // trivia; any end-of-file orphan comments become the root's dangling run.
    self.skipInline();
    if (try self.tryComment()) |c| self.setTrailing(root, c);
    try self.collectLeading();
    try self.claimDangling(root);
    if (self.peek() != null) return error.TrailingGarbage;

    const nodes = try self.nodes.toOwnedSlice(self.allocator);
    self.nodes = .empty;
    errdefer self.allocator.free(nodes);

    const spans = try self.spans.toOwnedSlice(self.allocator);
    self.spans = .empty;
    errdefer self.allocator.free(spans);

    const owned_strings = try self.owned_strings.toOwnedSlice(self.allocator);
    self.owned_strings = .empty;
    errdefer self.allocator.free(owned_strings);

    var ast: AST = .{
        .allocator = self.allocator,
        .owned_strings = owned_strings,
        .root = root,
        .nodes = nodes,
    };

    // Only documents that actually used the reference layer carry the
    // side-tables; everything else leaves the AST's `&.{}` defaults.
    if (self.ref_seen) {
        ast.node_anchors = try self.node_anchors.toOwnedSlice(self.allocator);
        self.node_anchors = .empty;
        ast.node_tags = try self.node_tags.toOwnedSlice(self.allocator);
        self.node_tags = .empty;
    }
    if (self.anchors.items.len > 0) {
        // `resolveAlias` requires anchors sorted by node id (it walks until it
        // passes the alias). Inner anchors finish before outer ones, so sort.
        std.mem.sort(AST.Anchor, self.anchors.items, {}, anchorLess);
        ast.anchors = try self.anchors.toOwnedSlice(self.allocator);
        self.anchors = .empty;
    }
    // Materialized last so no fallible step follows it: hands the owned `leading`
    // slices to the AST in one move. Done only when comments were actually seen,
    // leaving the AST's `&.{}` default otherwise.
    if (self.comments_seen) {
        ast.node_comments = try self.node_comments.toOwnedSlice(self.allocator);
        self.node_comments = .empty;
    }

    return .{ .source = self.src, .ast = ast, .node_spans = spans };
}

fn anchorLess(_: void, a: AST.Anchor, b: AST.Anchor) bool {
    return a.node < b.node;
}

// ── node construction ───────────────────────────────────────────────────────

fn addNode(self: *Parser, kind: AST.Node.Kind, start: usize) ParserError!AST.Node.Id {
    const id: AST.Node.Id = @intCast(self.nodes.items.len);
    try self.nodes.append(self.allocator, .{ .id = id, .kind = kind, .next_sibling = null });
    try self.spans.append(self.allocator, .{ .start = start, .end = self.pos });
    try self.node_anchors.append(self.allocator, null);
    try self.node_tags.append(self.allocator, null);
    try self.node_comments.append(self.allocator, .{});
    return id;
}

// ── grammar ─────────────────────────────────────────────────────────────────

/// A node is any reference-layer prefixes (`&anchor`, `!tag`) followed by a
/// value. Leading comments encountered here accumulate in `pending_leading`;
/// the enclosing container (or the document root) claims them onto the right
/// node via `claimLeading` once it knows which node they belong to.
fn parseNode(self: *Parser) ParserError!AST.Node.Id {
    try self.collectLeading();
    var anchor: ?[]const u8 = null;
    var tag: ?[]const u8 = null;
    while (true) {
        switch (self.peek() orelse return error.UnexpectedEnd) {
            '&' => {
                if (anchor != null) return error.UnexpectedToken;
                anchor = try self.parseAnchorName();
                self.skipWs();
            },
            '!' => {
                if (tag != null) return error.UnexpectedToken;
                tag = self.parseTag();
                self.skipWs();
            },
            else => break,
        }
    }

    const id = try self.parseValue();

    if (anchor) |name| {
        self.ref_seen = true;
        self.node_anchors.items[id] = name;
        try self.anchors.append(self.allocator, .{ .name = name, .node = id });
    }
    if (tag) |text| {
        self.ref_seen = true;
        self.node_tags.items[id] = text;
    }
    return id;
}

fn parseValue(self: *Parser) ParserError!AST.Node.Id {
    const start = self.pos;
    switch (self.peek() orelse return error.UnexpectedEnd) {
        '{' => return self.parseMapping(),
        '[' => return self.parseSequence(),
        '"' => {
            const s = try self.parseStringValue();
            return self.addNode(.{ .string = s }, start);
        },
        '@' => return self.parseExtended(),
        '*' => return self.parseAlias(),
        '0'...'9', '+', '-', '.', '~' => return self.parseNumber(),
        'a'...'z', 'A'...'Z', '_' => return self.parseBareword(),
        else => return error.UnexpectedToken,
    }
}

fn parseBareword(self: *Parser) ParserError!AST.Node.Id {
    const start = self.pos;
    while (self.peek()) |c| : (self.pos += 1) {
        if (!isNameChar(c)) break;
    }
    const word = self.src[start..self.pos];
    const kind: AST.Node.Kind = if (std.mem.eql(u8, word, "null"))
        .null_
    else if (std.mem.eql(u8, word, "true"))
        .{ .boolean = true }
    else if (std.mem.eql(u8, word, "false"))
        .{ .boolean = false }
    else
        return error.UnexpectedToken;
    return self.addNode(kind, start);
}

fn parseNumber(self: *Parser) ParserError!AST.Node.Id {
    const start = self.pos;
    // Optional `~i`/`~f` kind override for the rare lexeme/kind mismatch.
    var override: ?bool = null;
    if (self.peek() == '~') {
        self.pos += 1;
        switch (self.peek() orelse return error.UnexpectedEnd) {
            'f' => override = true,
            'i' => override = false,
            else => return error.UnexpectedToken,
        }
        self.pos += 1;
    }
    const raw_start = self.pos;
    while (self.peek()) |c| : (self.pos += 1) {
        if (!isNumberChar(c)) break;
    }
    const raw = self.src[raw_start..self.pos];
    if (raw.len == 0) return error.UnexpectedToken;
    const NumberKind = @TypeOf(Printer.impliedNumberKind(raw));
    const kind: NumberKind = if (override) |is_float|
        (if (is_float) .float else .integer)
    else
        Printer.impliedNumberKind(raw);
    return self.addNode(.{ .number = .{ .raw = raw, .kind = kind } }, start);
}

fn parseExtended(self: *Parser) ParserError!AST.Node.Id {
    const start = self.pos;
    self.pos += 1; // '@'
    const kind_start = self.pos;
    while (self.peek()) |c| : (self.pos += 1) {
        if (!((c >= 'a' and c <= 'z') or c == '_')) break;
    }
    const kind_name = self.src[kind_start..self.pos];
    const kind = std.meta.stringToEnum(ExtKind, kind_name) orelse return error.InvalidExtended;
    self.skipWs();
    if (self.peek() != '"') return error.InvalidExtended;
    const text = try self.parseStringValue();
    return self.addNode(.{ .extended = .{ .kind = kind, .text = text } }, start);
}

fn parseAlias(self: *Parser) ParserError!AST.Node.Id {
    const start = self.pos;
    self.pos += 1; // '*'
    const name_start = self.pos;
    while (self.peek()) |c| : (self.pos += 1) {
        if (!isNameChar(c)) break;
    }
    const name = self.src[name_start..self.pos];
    if (name.len == 0) return error.EmptyName;
    return self.addNode(.{ .alias = name }, start);
}

fn parseSequence(self: *Parser) ParserError!AST.Node.Id {
    const start = self.pos;
    self.pos += 1; // '['
    self.depth += 1;
    if (self.depth > Printer.max_depth) return error.NestingTooDeep;
    defer self.depth -= 1;
    const id = try self.addNode(.{ .sequence = null }, start);
    try self.captureOpenTrailing(id);
    try self.collectLeading();
    if (self.peek() == ']') {
        self.pos += 1;
        try self.claimDangling(id); // orphan comments inside an empty `[ … ]`
        self.spans.items[id].end = self.pos;
        return id;
    }
    var first: ?AST.Node.Id = null;
    var prev: ?AST.Node.Id = null;
    while (true) {
        const child = try self.parseNode();
        // A sequence element is its own value node: leading and trailing
        // comments both bind directly to it.
        try self.claimLeading(child);
        if (prev) |p| self.nodes.items[p].next_sibling = child else first = child;
        prev = child;
        if (try self.finishElement(']', error.UnclosedArray, child)) {
            try self.claimDangling(id); // orphan comments before the `]`
            break;
        }
    }
    self.nodes.items[id].kind = .{ .sequence = first };
    self.spans.items[id].end = self.pos;
    return id;
}

fn parseMapping(self: *Parser) ParserError!AST.Node.Id {
    const start = self.pos;
    self.pos += 1; // '{'
    self.depth += 1;
    if (self.depth > Printer.max_depth) return error.NestingTooDeep;
    defer self.depth -= 1;
    const id = try self.addNode(.{ .mapping = null }, start);
    try self.captureOpenTrailing(id);
    try self.collectLeading();
    if (self.peek() == '}') {
        self.pos += 1;
        try self.claimDangling(id); // orphan comments inside an empty `{ … }`
        self.spans.items[id].end = self.pos;
        return id;
    }
    var first: ?AST.Node.Id = null;
    var prev: ?AST.Node.Id = null;
    while (true) {
        const key = try self.parseNode();
        // An entry's leading comment sits above the key; its trailing comment
        // follows the value. This mirrors the canonical printer's anchors.
        try self.claimLeading(key);
        self.skipWs();
        if (self.peek() != ':') return error.ExpectedColon;
        self.pos += 1;
        const value = try self.parseNode();
        // Normally empty; claims any (non-canonical) comment between `:` and the
        // value so it can't leak onto the next entry's key.
        try self.claimLeading(value);
        const kv = try self.addNode(.{ .keyvalue = .{ .key = key, .value = value } }, self.spans.items[key].start);
        if (prev) |p| self.nodes.items[p].next_sibling = kv else first = kv;
        prev = kv;
        if (try self.finishElement('}', error.UnclosedObject, value)) {
            try self.claimDangling(id); // orphan comments before the `}`
            break;
        }
    }
    self.nodes.items[id].kind = .{ .mapping = first };
    self.spans.items[id].end = self.pos;
    return id;
}

// ── lexical helpers ─────────────────────────────────────────────────────────

fn parseAnchorName(self: *Parser) ParserError![]const u8 {
    self.pos += 1; // '&'
    const start = self.pos;
    while (self.peek()) |c| : (self.pos += 1) {
        if (!isNameChar(c)) break;
    }
    const name = self.src[start..self.pos];
    if (name.len == 0) return error.EmptyName;
    return name;
}

/// A tag is the verbatim `!`-led token (e.g. `!!str`, `!foo`), stored leading
/// `!` included to match how the format parsers fill `node_tags`. It runs to the
/// next whitespace or structural delimiter.
fn parseTag(self: *Parser) []const u8 {
    const start = self.pos;
    while (self.peek()) |c| : (self.pos += 1) {
        if (!isTagChar(c)) break;
    }
    return self.src[start..self.pos];
}

fn parseStringValue(self: *Parser) ParserError![]const u8 {
    // self.peek() == '"'
    self.pos += 1; // opening quote
    const inner_start = self.pos;
    var i = self.pos;
    var has_escape = false;
    while (i < self.src.len) {
        const ch = self.src[i];
        if (ch == '"') break;
        if (ch == '\\') {
            has_escape = true;
            i += 2; // skip the escaped char; the bounds check re-runs next loop
            continue;
        }
        i += 1;
    }
    if (i >= self.src.len) return error.UnclosedString;
    const inner = self.src[inner_start..i];
    self.pos = i + 1; // past closing quote

    if (!has_escape) return inner; // fast path: borrow from source
    return self.decodeEscapes(inner);
}

fn decodeEscapes(self: *Parser, inner: []const u8) ParserError![]const u8 {
    var decoded: std.ArrayList(u8) = .empty;
    errdefer decoded.deinit(self.allocator);
    var i: usize = 0;
    while (i < inner.len) {
        const c = inner[i];
        if (c != '\\') {
            try decoded.append(self.allocator, c);
            i += 1;
            continue;
        }
        i += 1;
        if (i >= inner.len) return error.UnclosedString;
        switch (inner[i]) {
            '"' => try decoded.append(self.allocator, '"'),
            '\\' => try decoded.append(self.allocator, '\\'),
            '/' => try decoded.append(self.allocator, '/'),
            'b' => try decoded.append(self.allocator, 0x08),
            'f' => try decoded.append(self.allocator, 0x0c),
            'n' => try decoded.append(self.allocator, '\n'),
            'r' => try decoded.append(self.allocator, '\r'),
            't' => try decoded.append(self.allocator, '\t'),
            'u' => {
                if (i + 4 >= inner.len) return error.InvalidUnicodeEscape;
                const unit = std.fmt.parseInt(u21, inner[i + 1 .. i + 5], 16) catch return error.InvalidUnicodeEscape;
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(unit, &buf) catch return error.InvalidUnicodeEscape;
                try decoded.appendSlice(self.allocator, buf[0..n]);
                i += 4;
            },
            else => return error.InvalidEscape,
        }
        i += 1;
    }
    const owned = try decoded.toOwnedSlice(self.allocator);
    errdefer self.allocator.free(owned);
    try self.owned_strings.append(self.allocator, owned);
    return owned;
}

fn skipWs(self: *Parser) void {
    while (self.peek()) |c| {
        switch (c) {
            ' ', '\t', '\n', '\r' => self.pos += 1,
            else => break,
        }
    }
}

/// Skip spaces and tabs only — never a newline, never a comment. Used to reach a
/// same-line trailing comment or a separator without crossing into the next
/// line's leading trivia.
fn skipInline(self: *Parser) void {
    while (self.peek()) |c| {
        if (c == ' ' or c == '\t') self.pos += 1 else break;
    }
}

/// Skip whitespace (newlines included) and comments, buffering each comment in
/// `pending_leading` for the next node to claim. Returns at the next value byte.
fn collectLeading(self: *Parser) ParserError!void {
    while (true) {
        self.skipWs();
        const c = try self.tryComment() orelse return;
        try self.pending_leading.append(self.allocator, c);
        // `comments_seen` is set only once a comment actually binds to a node
        // (in `claimLeading`/`setTrailing`), so a buffered-then-dropped orphan
        // leaves the document comment-free.
    }
}

/// If positioned at a comment marker, consume the whole comment and return it;
/// otherwise leave `pos` unchanged and return null. The returned text borrows
/// `src` (marker stripped, surrounding whitespace trimmed) — comments never
/// contain escapes, so nothing is allocated.
fn tryComment(self: *Parser) ParserError!?AST.Comment {
    if (self.peek() != '/' or self.pos + 1 >= self.src.len) return null;
    switch (self.src[self.pos + 1]) {
        '/' => {
            self.pos += 2;
            const s = self.pos;
            while (self.peek()) |c| : (self.pos += 1) {
                if (c == '\n') break;
            }
            return .{ .text = std.mem.trim(u8, self.src[s..self.pos], " \t\r"), .style = .line };
        },
        '*' => {
            self.pos += 2;
            const s = self.pos;
            const len = std.mem.indexOf(u8, self.src[self.pos..], "*/") orelse return error.UnterminatedComment;
            self.pos += len + 2; // past the closing `*/`
            return .{ .text = std.mem.trim(u8, self.src[s .. s + len], " \t\r\n"), .style = .block };
        },
        else => return null,
    }
}

/// Hand the buffered leading comments to node `id`, transferring ownership of
/// the slice to the comment table. No-op when nothing is buffered.
fn claimLeading(self: *Parser, id: AST.Node.Id) ParserError!void {
    if (self.pending_leading.items.len == 0) return;
    const owned = try self.pending_leading.toOwnedSlice(self.allocator);
    self.pending_leading = .empty;
    self.node_comments.items[id].leading = owned;
    self.comments_seen = true;
}

/// Bind a same-line trailing comment to node `id`.
fn setTrailing(self: *Parser, id: AST.Node.Id, c: AST.Comment) void {
    self.node_comments.items[id].trailing = c;
    self.comments_seen = true;
}

/// Capture a line comment immediately after an opening delimiter that ends its
/// line (`[ // c`) as container `id`'s own trailing (the head comment). A block
/// comment is left for `collectLeading` — it may lead the first child.
fn captureOpenTrailing(self: *Parser, id: AST.Node.Id) ParserError!void {
    self.skipInline();
    if (self.peek() == '/' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '/') {
        if (try self.tryComment()) |c| self.setTrailing(id, c);
    }
}

/// Whether `id` is a container whose opening delimiter precedes `cpos` on an
/// earlier line — a multi-line `[ … ]`/`{ … }` whose close is on `cpos`'s line.
fn multilineContainer(self: *Parser, id: AST.Node.Id, cpos: usize) bool {
    switch (self.nodes.items[id].kind) {
        .sequence, .mapping => {},
        else => return false,
    }
    const open = self.spans.items[id].start;
    if (cpos <= open) return false;
    return std.mem.indexOfScalar(u8, self.src[open..cpos], '\n') != null;
}

/// Append one comment to `id`'s `dangling` run (reallocating onto any orphans
/// already claimed at the close).
fn appendDangling(self: *Parser, id: AST.Node.Id, c: AST.Comment) ParserError!void {
    const old = self.node_comments.items[id].dangling;
    const grown = try self.allocator.alloc(AST.Comment, old.len + 1);
    @memcpy(grown[0..old.len], old);
    grown[old.len] = c;
    self.allocator.free(old);
    self.node_comments.items[id].dangling = grown;
    self.comments_seen = true;
}

/// Hand buffered orphan comments (no node followed them) to container `id` as its
/// `dangling` run — they sit at the end of its body. No-op when nothing buffered.
fn claimDangling(self: *Parser, id: AST.Node.Id) ParserError!void {
    if (self.pending_leading.items.len == 0) return;
    const owned = try self.pending_leading.toOwnedSlice(self.allocator);
    self.pending_leading = .empty;
    self.node_comments.items[id].dangling = owned;
    self.comments_seen = true;
}

/// After an element's value is parsed (and its leading claimed), consume an
/// optional same-line trailing comment plus the separator. Binds the trailing
/// comment to `trailing_target`. Returns true when the container closed (`close`
/// consumed), false when another element follows. The canonical native form
/// puts a trailing comment after the comma (`v, // c`); a last element carries
/// it directly (`v // c`).
fn finishElement(self: *Parser, close: u8, unclosed: ParseError, trailing_target: AST.Node.Id) ParserError!bool {
    self.skipInline();
    var had_comma = false;
    if (self.peek() == ',') {
        self.pos += 1;
        had_comma = true;
        self.skipInline();
    }
    const cpos = self.pos;
    if (try self.tryComment()) |c| {
        // A comment after a multi-line container's close is a bottom comment →
        // its `dangling` run; a scalar or inline container keeps the trailing.
        if (self.multilineContainer(trailing_target, cpos)) {
            try self.appendDangling(trailing_target, c);
        } else {
            self.setTrailing(trailing_target, c);
        }
    }
    try self.collectLeading();
    const c = self.peek() orelse return unclosed;
    if (c == close) {
        self.pos += 1;
        // Any orphan comments before the close stay buffered; the caller claims
        // them as the container's `dangling` run.
        return true;
    }
    // More content is only legal across a comma separator.
    if (had_comma) return false;
    return error.UnexpectedToken;
}

fn peek(self: *const Parser) ?u8 {
    return if (self.pos < self.src.len) self.src[self.pos] else null;
}

fn isNameChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '-';
}

fn isNumberChar(c: u8) bool {
    return (c >= '0' and c <= '9') or
        (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F') or
        c == 'x' or c == 'X' or c == 'o' or c == 'O' or c == 'b' or c == 'B' or
        c == '.' or c == '_' or c == '+' or c == '-';
}

fn isTagChar(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\n', '\r', ',', ':', '{', '}', '[', ']', '"' => false,
        else => true,
    };
}

// =======
// Testing
// =======

const testing = std.testing;

/// Assert that `input` round-trips: parse → print → parse yields an equal AST,
/// and the re-printed text is byte-identical to the first print.
fn expectRoundTrip(input: []const u8) !void {
    var ast = try parseAbstract(testing.allocator, input);
    defer ast.deinit();

    var out1: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out1.deinit();
    try Printer.print(&out1.writer, &ast);

    var reparsed = try parseAbstract(testing.allocator, out1.written());
    defer reparsed.deinit();
    try testing.expect(ast.eql(reparsed));
    // Comments are excluded from `eql`, so assert them separately.
    try testing.expect(ast.commentsEql(reparsed));

    var out2: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out2.deinit();
    try Printer.print(&out2.writer, &reparsed);
    try testing.expectEqualStrings(out1.written(), out2.written());
}

test "round-trips comments: leading, trailing, line, block" {
    // Canonical form (what the printer emits), so the byte-identical reprint
    // check applies in full.
    try expectRoundTrip(
        \\{
        \\  // leading on first entry
        \\  "name": "fig", // trailing on a value
        \\  /* a block comment */
        \\  "port": 8080,
        \\  "nums": [
        \\    // leading on a sequence element
        \\    1,
        \\    2 // trailing on the last element
        \\  ]
        \\}
    );
}

test "captures comment attachment onto the right nodes" {
    var ast = try parseAbstract(testing.allocator,
        \\{
        \\  // c1
        \\  "a": 1, // c2
        \\  "b": [2 /* c3 */]
        \\}
    );
    defer ast.deinit();

    const root = ast.nodes[ast.root];
    const kv_a = ast.nodes[root.kind.mapping.?].kind.keyvalue;
    // Leading binds to the key node, trailing to the value node.
    try testing.expectEqualStrings("c1", ast.comments(kv_a.key).leading[0].text);
    try testing.expect(ast.comments(kv_a.key).leading[0].style == .line);
    try testing.expectEqualStrings("c2", ast.comments(kv_a.value).trailing.?.text);

    const kv_b = ast.nodes[ast.nodes[root.kind.mapping.?].next_sibling.?].kind.keyvalue;
    const elem = ast.nodes[ast.nodes[kv_b.value].kind.sequence.?];
    try testing.expectEqualStrings("c3", ast.comments(elem.id).trailing.?.text);
    try testing.expect(ast.comments(elem.id).trailing.?.style == .block);
}

test "comment-free document carries no comment table" {
    var ast = try parseAbstract(testing.allocator, "[1, 2, 3]");
    defer ast.deinit();
    try testing.expectEqual(@as(usize, 0), ast.node_comments.len);
}

test "orphan comments are captured as the container's dangling run" {
    try expectRoundTrip("[]"); // sanity: empty container still round-trips
    // An own-line comment at the bottom of a container binds as `dangling`.
    var ast = try parseAbstract(testing.allocator, "[\n  // orphan\n]");
    defer ast.deinit();
    try testing.expectEqualStrings("orphan", ast.comments(ast.root).dangling[0].text);
    // And it round-trips (printed inside the block-form container).
    try expectRoundTrip(
        \\{
        \\  "a": 1
        \\  // dangling at end
        \\}
    );
}

test "container comment: opening line is head (trailing), closing line is bottom (dangling)" {
    // `[ // head` rides the open line; `] // tail` normalizes to a bottom comment.
    try expectRoundTrip(
        \\{
        \\  "a": [ // head
        \\    1
        \\  ],
        \\  "b": [
        \\    2
        \\    // tail
        \\  ]
        \\}
    );
}

test "round-trips scalars, containers, and node keys" {
    try expectRoundTrip(
        \\{
        \\  "name": "fig",
        \\  "port": 8080,
        \\  "ratio": 1.0,
        \\  "hex": 0xFF,
        \\  "grouped": 1_000,
        \\  "signed": +42,
        \\  "nums": [1, 2.5, .5, 5., 1e9],
        \\  "missing": null,
        \\  "flag": true,
        \\  "nested": { "a": [true, false] }
        \\}
    );
}

test "round-trips extended scalars" {
    try expectRoundTrip(
        \\{
        \\  "dt": @offset_datetime "1979-05-27T07:32:00Z",
        \\  "d": @local_date "1979-05-27",
        \\  "mode": @enum_literal "fast",
        \\  "ch": @char_literal "65",
        \\  "inf": @number_special "Infinity"
        \\}
    );
}

test "round-trips anchors, aliases, and tags" {
    try expectRoundTrip(
        \\[&base { "retries": 3 }, *base, !!str "tagged"]
    );
}

test "string escapes decode and re-encode" {
    var ast = try parseAbstract(testing.allocator, "\"tab:\\t quote:\\\" backslash:\\\\ ctrl:\\u0007\"");
    defer ast.deinit();
    try testing.expectEqualStrings("tab:\t quote:\" backslash:\\ ctrl:\x07", ast.nodes[ast.root].kind.string);
}

test "non-string mapping keys" {
    var ast = try parseAbstract(testing.allocator, "{ [1, 2]: \"tuple\" }");
    defer ast.deinit();
    const root = ast.nodes[ast.root];
    const kv = ast.nodes[root.kind.mapping.?].kind.keyvalue;
    try testing.expect(ast.nodes[kv.key].kind == .sequence);
}

test "kind override survives a lexeme/kind mismatch" {
    // A float whose lexeme reads as an integer: only `~f` preserves it.
    var b = AST.Builder.init(testing.allocator);
    defer b.deinit();
    const root = try b.addNumberRaw("1", true); // raw "1", but kind=float
    var ast = try b.finish(root);
    defer ast.deinit();

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try Printer.print(&out.writer, &ast);
    try testing.expectEqualStrings("~f1\n", out.written());

    var reparsed = try parseAbstract(testing.allocator, out.written());
    defer reparsed.deinit();
    try testing.expect(reparsed.nodes[reparsed.root].kind.number.kind == .float);
}

test "alias resolves to its anchor" {
    var ast = try parseAbstract(testing.allocator, "[&a 1, *a]");
    defer ast.deinit();
    const seq = ast.nodes[ast.root];
    const alias_node = ast.nodes[ast.nodes[seq.kind.sequence.?].next_sibling.?];
    try testing.expect(alias_node.kind == .alias);
    const target = try ast.resolveAlias(alias_node);
    try testing.expectEqualStrings("1", ast.nodes[target].kind.number.raw);
}

test "rejects trailing garbage" {
    try testing.expectError(error.TrailingGarbage, parseAbstract(testing.allocator, "1 2"));
}

test "bounds nesting depth" {
    const a = testing.allocator;
    // `n` nested sequences: `[`×n then `]`×n (innermost is an empty `[]`).
    const nest = struct {
        fn build(alloc: std.mem.Allocator, n: usize) ![]u8 {
            const buf = try alloc.alloc(u8, n * 2);
            @memset(buf[0..n], '[');
            @memset(buf[n..], ']');
            return buf;
        }
    }.build;

    // At the limit it parses; one level past it is rejected (not a stack crash).
    const ok = try nest(a, Printer.max_depth);
    defer a.free(ok);
    var ast = try parseAbstract(a, ok);
    ast.deinit();

    const too_deep = try nest(a, Printer.max_depth + 1);
    defer a.free(too_deep);
    try testing.expectError(error.NestingTooDeep, parseAbstract(a, too_deep));
}
