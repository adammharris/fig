//! The parser turns a TOML-formatted []const u8 into an AST.
//!
//! Phase 1: root-level `key = value` statements with scalar values (strings,
//! integers, floats, booleans, datetimes). Dotted keys and `[table]` headers
//! (Phase 2) and arrays / inline tables (Phase 3) are not assembled yet — a
//! statement that needs them returns error.NotImplemented.
//!
//! Scalars keep their source text verbatim (numbers/datetimes store `raw`;
//! decoded strings live in `owned_strings`). Number/datetime *normalization*
//! (e.g. 0xFF → 255 for JSON) is a print/convert concern, not done here.

const Parser = @This();

const std = @import("std");
const testing = std.testing;
const AST = @import("../ast.zig");
const Document = @import("../document.zig");
const Type = @import("toml.zig").Type;
const Span = @import("../util/span.zig");
const Tokenizer = @import("tokenizer.zig");
const Token = Tokenizer.Token;

allocator: std.mem.Allocator,
version: Type = .TOML_1_0,
source: []const u8 = "",
tokens: []const Token = &.{},
pos: usize = 0,
nodes: std.ArrayList(AST.Node) = .empty,
spans: std.ArrayList(Span) = .empty,
owned_strings: std.ArrayList([]const u8) = .empty,
// Comment layer. Comments are captured in `skipInline`/`skipBlank` (the trivia
// skippers): a comment on the same line as a just-parsed value (`last_value_id`
// set) trails it; one on its own line buffers as `pending_leading`, claimed onto
// the next entry's key in `appendKeyValue`. A newline resets the trailing
// window. Text borrows `source`. `pending_leading` is reserved to `tokens.len`
// once so capture cannot fail. Materialized only when `comments_seen`.
node_comments: std.ArrayList(AST.NodeComments) = .empty,
pending_leading: std.ArrayList(AST.Comment) = .empty,
last_value_id: ?AST.Node.Id = null,
comments_seen: bool = false,
/// The mapping that bare/dotted `key = value` lines attach to. Starts at root,
/// repointed by each `[table]` header.
current_table: AST.Node.Id = 0,
/// Per-mapping provenance, used to enforce TOML's table/key conflict rules.
/// Absent ⇒ a value node or the root.
table_meta: std.AutoHashMapUnmanaged(AST.Node.Id, TableMeta) = .empty,

/// How a table (mapping) node came to exist — determines whether a later header
/// or dotted key may target/extend it.
const TableMeta = struct {
    /// Defined by its own `[header]` (or `[[array]]` element). Cannot be
    /// redefined by a header, nor extended by dotted keys from another line.
    explicit: bool = false,
    /// Created as the value of a dotted-key segment (`a.b = 1` makes `a`).
    dotted: bool = false,
    /// Created only as an intermediate on a header path (`[a.b.c]` makes
    /// `a`, `a.b`). May still be promoted to `explicit` by its own header.
    implicit: bool = false,
    /// A sequence node created by `[[array.of.tables]]`. Only such sequences
    /// may be navigated into (last element) or extended; a static `= [...]`
    /// array has no meta and is therefore closed.
    aot: bool = false,
    /// A mapping from an inline `{ ... }` table — fully defined and closed; no
    /// header or dotted key may extend it.
    inline_table: bool = false,
};

const KeySeg = struct { str: []const u8, span: Span };

pub const ParseError = error{
    NotImplemented,
    UnexpectedToken,
    UnclosedString,
    BadEscape,
    InvalidUnicode,
    InvalidNumber,
    InvalidDatetime,
    InvalidKey,
    DuplicateKey,
    TrailingContent,
    InvalidUtf8,
};
pub const ParserError = ParseError || Tokenizer.TokenizeError || std.mem.Allocator.Error;

pub fn parse(allocator: std.mem.Allocator, input: []const u8, format: Type) ParserError!Document {
    var parser: Parser = .{ .allocator = allocator };
    return parser.parseOnce(input, format) catch |err| {
        parser.nodes.deinit(allocator);
        parser.spans.deinit(allocator);
        for (parser.owned_strings.items) |s| allocator.free(s);
        parser.owned_strings.deinit(allocator);
        return err;
    };
}

pub fn parseAbstract(allocator: std.mem.Allocator, input: []const u8, format: Type) ParserError!AST {
    const doc = try parse(allocator, input, format);
    allocator.free(doc.node_spans);
    return doc.ast;
}

fn parseOnce(self: *Parser, input: []const u8, format: Type) ParserError!Document {
    self.version = format;
    self.source = input;

    // A TOML file must be valid UTF-8 (catches all bad-utf8 fixtures at once).
    if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidUtf8;

    var tokenizer: Tokenizer = .{ .allocator = self.allocator, .str = input, .version = format };
    self.tokens = try tokenizer.tokenize();
    defer self.allocator.free(self.tokens);
    defer self.table_meta.deinit(self.allocator);
    // Reserve so trivia-skipping can buffer leading comments without failing.
    try self.pending_leading.ensureTotalCapacity(self.allocator, self.tokens.len);
    defer self.pending_leading.deinit(self.allocator);
    // On success the table is moved into the AST and this list emptied; on any
    // error path it (and any owned `leading` slices) are freed here.
    defer {
        for (self.node_comments.items) |nc| self.allocator.free(nc.leading);
        self.node_comments.deinit(self.allocator);
    }

    // Root mapping is node 0.
    const root_id = try self.addNode(.{ .mapping = null }, Span.init(0, input.len));
    self.current_table = root_id;

    self.skipBlank();
    while (!self.atEnd()) {
        switch (self.peek().kind) {
            .key => try self.parseKeyValue(),
            .open_bracket => try self.parseTableHeader(),
            .double_open_bracket => try self.parseArrayTable(),
            else => return error.UnexpectedToken,
        }
        try self.requireLineEnd();
        self.skipBlank();
    }

    const nodes = try self.nodes.toOwnedSlice(self.allocator);
    errdefer self.allocator.free(nodes);
    const spans = try self.spans.toOwnedSlice(self.allocator);
    errdefer self.allocator.free(spans);
    const owned = try self.owned_strings.toOwnedSlice(self.allocator);

    var ast: AST = .{
        .allocator = self.allocator,
        .root = root_id,
        .nodes = nodes,
        .owned_strings = owned,
    };
    if (self.comments_seen) {
        ast.node_comments = try self.node_comments.toOwnedSlice(self.allocator);
        self.node_comments = .empty;
    }

    return .{
        .source = input,
        .ast = ast,
        .node_spans = spans,
    };
}

fn addNode(self: *Parser, kind: AST.Node.Kind, span: Span) ParserError!AST.Node.Id {
    const id: AST.Node.Id = @intCast(self.nodes.items.len);
    try self.nodes.append(self.allocator, .{ .id = id, .kind = kind });
    try self.spans.append(self.allocator, span);
    try self.node_comments.append(self.allocator, .{});
    return id;
}

// ── Token cursor ────────────────────────────────────────────────────────────

fn peek(self: *Parser) Token {
    return self.tokens[self.pos];
}

fn advance(self: *Parser) Token {
    const t = self.tokens[self.pos];
    if (self.pos + 1 < self.tokens.len) self.pos += 1;
    return t;
}

fn atEnd(self: *Parser) bool {
    return self.peek().kind == .end_of_file;
}

/// Skip whitespace and comments (but not newlines). A comment here is on the
/// current line, so it can trail a just-parsed value.
fn skipInline(self: *Parser) void {
    while (true) switch (self.peek().kind) {
        .whitespace => self.pos += 1,
        .comment => {
            self.captureComment(self.peek());
            self.pos += 1;
        },
        else => return,
    };
}

/// Skip whitespace, comments, and blank lines (newlines). A newline closes the
/// trailing-comment window, so comments past it lead the next entry.
fn skipBlank(self: *Parser) void {
    while (true) switch (self.peek().kind) {
        .whitespace => self.pos += 1,
        .comment => {
            self.captureComment(self.peek());
            self.pos += 1;
        },
        .newline => {
            self.last_value_id = null;
            self.pos += 1;
        },
        else => return,
    };
}

// ── Comments ─────────────────────────────────────────────────────────────────

/// Classify a comment token: trailing the most recent value when its window is
/// open (`last_value_id` set, no newline since), else buffered as leading.
fn captureComment(self: *Parser, tok: Token) void {
    const c: AST.Comment = .{ .text = commentText(self.tokenText(tok)), .style = .line };
    if (self.last_value_id) |id| {
        self.node_comments.items[id].trailing = c;
        self.comments_seen = true;
        self.last_value_id = null; // one trailing per value
    } else {
        self.pending_leading.appendAssumeCapacity(c); // capacity reserved in parseOnce
    }
}

/// Strip the leading `#` and surrounding spaces from a comment token's bytes
/// (which borrow `source`).
fn commentText(raw: []const u8) []const u8 {
    const body = if (raw.len > 0 and raw[0] == '#') raw[1..] else raw;
    return std.mem.trim(u8, body, " \t\r");
}

/// Hand the buffered leading comments to node `id` as an owned slice, then clear
/// the buffer (retaining its reserved capacity). No-op when nothing is buffered.
fn claimLeading(self: *Parser, id: AST.Node.Id) ParserError!void {
    if (self.pending_leading.items.len == 0) return;
    const owned = try self.allocator.dupe(AST.Comment, self.pending_leading.items);
    self.pending_leading.clearRetainingCapacity();
    self.node_comments.items[id].leading = owned;
    self.comments_seen = true;
}

/// After a statement, only trivia then a newline or EOF may follow.
fn requireLineEnd(self: *Parser) ParserError!void {
    self.skipInline();
    switch (self.peek().kind) {
        .newline, .end_of_file => {},
        else => return error.TrailingContent,
    }
}

fn tokenText(self: *Parser, tok: Token) []const u8 {
    return self.source[tok.span.start..tok.span.end];
}

// ── Statements ──────────────────────────────────────────────────────────────

/// Parse `[table.path]` and repoint `current_table`. The path is resolved from
/// the root; intermediates may pass through any existing table, the final must
/// be new (→ explicit) or an implicit path-table (→ promoted to explicit).
fn parseTableHeader(self: *Parser) ParserError!void {
    _ = self.advance(); // '['
    self.skipInline();

    var segs: std.ArrayList(KeySeg) = .empty;
    defer segs.deinit(self.allocator);
    try self.parseKeyPath(&segs);
    self.skipInline();
    if (self.peek().kind != .close_bracket) return error.UnexpectedToken;
    _ = self.advance();
    if (segs.items.len == 0) return error.InvalidKey;

    const cur = try self.navigateHeaderPath(0, segs.items[0 .. segs.items.len - 1]);
    const final = segs.items[segs.items.len - 1];
    if (self.lookupChild(cur, final.str)) |child| {
        if (self.nodes.items[child].kind != .mapping) return error.DuplicateKey;
        const m = self.table_meta.get(child) orelse TableMeta{};
        if (m.explicit or m.dotted or m.inline_table) return error.DuplicateKey;
        try self.table_meta.put(self.allocator, child, .{ .explicit = true });
        self.current_table = child;
    } else {
        self.current_table = try self.createTable(cur, final, .{ .explicit = true });
    }
}

/// Parse `[[array.of.tables]]`: navigate the path from root (intermediates like
/// a header), then create-or-extend the final array-of-tables, appending a fresh
/// element table that becomes `current_table`.
fn parseArrayTable(self: *Parser) ParserError!void {
    _ = self.advance(); // '[['
    self.skipInline();
    var segs: std.ArrayList(KeySeg) = .empty;
    defer segs.deinit(self.allocator);
    try self.parseKeyPath(&segs);
    self.skipInline();
    if (self.peek().kind != .double_close_bracket) return error.UnexpectedToken;
    _ = self.advance();
    if (segs.items.len == 0) return error.InvalidKey;

    const cur = try self.navigateHeaderPath(0, segs.items[0 .. segs.items.len - 1]);
    const final = segs.items[segs.items.len - 1];
    if (self.lookupChild(cur, final.str)) |child| {
        const m = self.table_meta.get(child) orelse TableMeta{};
        if (self.nodes.items[child].kind != .sequence or !m.aot) return error.DuplicateKey;
        self.current_table = try self.appendArrayElement(child);
    } else {
        const seq_id = try self.addNode(.{ .sequence = null }, final.span);
        try self.appendKeyValue(cur, final, seq_id);
        try self.table_meta.put(self.allocator, seq_id, .{ .aot = true });
        self.current_table = try self.appendArrayElement(seq_id);
    }
}

/// Walk a header/array-of-tables path of intermediate segments from `start`,
/// creating missing tables (implicit) and descending into existing ones. An
/// array-of-tables intermediate descends into its last element.
fn navigateHeaderPath(self: *Parser, start: AST.Node.Id, intermediates: []const KeySeg) ParserError!AST.Node.Id {
    var cur = start;
    for (intermediates) |seg| {
        if (self.lookupChild(cur, seg.str)) |child| {
            cur = try self.descend(child);
        } else {
            cur = try self.createTable(cur, seg, .{ .implicit = true });
        }
    }
    return cur;
}

/// Resolve an existing path node to the mapping to continue from: a plain table
/// directly, an array-of-tables to its last element. A non-table value, a
/// static array, or a closed inline table is an error.
fn descend(self: *Parser, child: AST.Node.Id) ParserError!AST.Node.Id {
    return switch (self.nodes.items[child].kind) {
        .mapping => blk: {
            const m = self.table_meta.get(child) orelse TableMeta{};
            if (m.inline_table) return error.DuplicateKey;
            break :blk child;
        },
        .sequence => blk: {
            const m = self.table_meta.get(child) orelse TableMeta{};
            if (!m.aot) return error.DuplicateKey;
            break :blk try self.lastElement(child);
        },
        else => error.DuplicateKey,
    };
}

fn lastElement(self: *Parser, seq_id: AST.Node.Id) ParserError!AST.Node.Id {
    var last = self.nodes.items[seq_id].kind.sequence orelse return error.DuplicateKey;
    while (self.nodes.items[last].next_sibling) |n| last = n;
    return last;
}

fn appendArrayElement(self: *Parser, seq_id: AST.Node.Id) ParserError!AST.Node.Id {
    const elem = try self.addNode(.{ .mapping = null }, self.spans.items[seq_id]);
    if (self.nodes.items[seq_id].kind.sequence) |first| {
        var last = first;
        while (self.nodes.items[last].next_sibling) |n| last = n;
        self.nodes.items[last].next_sibling = elem;
    } else {
        self.nodes.items[seq_id].kind = .{ .sequence = elem };
    }
    return elem;
}

/// Parse a `key = value` line (the key possibly dotted), attaching to
/// `current_table`. Dotted intermediates create/extend dotted tables but may
/// not descend into an explicitly-defined table (TOML forbids using dotted keys
/// to append to a `[table]`) nor through a non-table value.
fn parseKeyValue(self: *Parser) ParserError!void {
    var segs: std.ArrayList(KeySeg) = .empty;
    defer segs.deinit(self.allocator);
    try self.parseKeyPath(&segs);
    self.skipInline();
    if (self.peek().kind != .equals) return error.UnexpectedToken;
    _ = self.advance(); // '='
    self.skipInline();

    const cur = try self.navigateDottedPath(self.current_table, segs.items[0 .. segs.items.len - 1]);
    const final = segs.items[segs.items.len - 1];
    if (self.lookupChild(cur, final.str) != null) return error.DuplicateKey;
    const value_id = try self.parseValue();
    // The value is now the trailing-comment candidate for the rest of this line
    // (a `# comment` after it, captured by the upcoming `requireLineEnd`).
    self.last_value_id = value_id;
    try self.appendKeyValue(cur, final, value_id);
}

/// Walk dotted-key intermediates from `start`, creating missing tables (dotted)
/// and descending into dotted/implicit ones. Descending into an explicitly
/// defined table, a closed inline table, or a non-table value is an error —
/// dotted keys may not append to a `[table]`.
fn navigateDottedPath(self: *Parser, start: AST.Node.Id, intermediates: []const KeySeg) ParserError!AST.Node.Id {
    var cur = start;
    for (intermediates) |seg| {
        if (self.lookupChild(cur, seg.str)) |child| {
            if (self.nodes.items[child].kind != .mapping) return error.DuplicateKey;
            const m = self.table_meta.get(child) orelse TableMeta{};
            if (m.explicit or m.inline_table) return error.DuplicateKey;
            cur = child;
        } else {
            cur = try self.createTable(cur, seg, .{ .dotted = true });
        }
    }
    return cur;
}

/// Parse a dotted key path (`a.b.c`); cursor must be at the first `.key`. Stops
/// when the next significant token is not a dot.
fn parseKeyPath(self: *Parser, segs: *std.ArrayList(KeySeg)) ParserError!void {
    while (true) {
        const tok = self.peek();
        if (tok.kind != .key) return error.UnexpectedToken;
        _ = self.advance();
        try segs.append(self.allocator, .{ .str = try self.decodeKey(tok), .span = tok.span });
        self.skipInline();
        if (self.peek().kind != .dot) return;
        _ = self.advance();
        self.skipInline();
    }
}

/// Value node id of a child of `map_id` keyed `key`, or null.
fn lookupChild(self: *Parser, map_id: AST.Node.Id, key: []const u8) ?AST.Node.Id {
    var cur = self.nodes.items[map_id].kind.mapping;
    while (cur) |id| : (cur = self.nodes.items[id].next_sibling) {
        const kv = self.nodes.items[id].kind.keyvalue;
        if (std.mem.eql(u8, self.nodes.items[kv.key].kind.string, key)) return kv.value;
    }
    return null;
}

/// Append a `key = value` entry to mapping `map_id`.
fn appendKeyValue(self: *Parser, map_id: AST.Node.Id, key: KeySeg, value_id: AST.Node.Id) ParserError!void {
    const key_id = try self.addNode(.{ .string = key.str }, key.span);
    // A leading comment block above this line (or above a `[header]`, since
    // headers also route through here) binds to the key node.
    try self.claimLeading(key_id);
    const value_end = self.spans.items[value_id].end;
    const kv_id = try self.addNode(
        .{ .keyvalue = .{ .key = key_id, .value = value_id } },
        Span.init(key.span.start, value_end),
    );
    if (self.nodes.items[map_id].kind.mapping) |first| {
        var last = first;
        while (self.nodes.items[last].next_sibling) |n| last = n;
        self.nodes.items[last].next_sibling = kv_id;
    } else {
        self.nodes.items[map_id].kind = .{ .mapping = kv_id };
    }
}

/// Create an empty child table under `parent` keyed `key`, record its origin,
/// and return the new mapping node id.
fn createTable(self: *Parser, parent: AST.Node.Id, key: KeySeg, meta: TableMeta) ParserError!AST.Node.Id {
    const map_id = try self.addNode(.{ .mapping = null }, key.span);
    try self.appendKeyValue(parent, key, map_id);
    try self.table_meta.put(self.allocator, map_id, meta);
    return map_id;
}

fn parseValue(self: *Parser) ParserError!AST.Node.Id {
    const tok = self.peek();
    switch (tok.kind) {
        .string => {
            _ = self.advance();
            const decoded = try self.decodeString(self.tokenText(tok));
            return self.addNode(.{ .string = decoded }, tok.span);
        },
        .number => {
            _ = self.advance();
            const raw = self.tokenText(tok);
            const kind = try classifyNumber(raw);
            // Store the value in canonical, format-independent form (decimal,
            // no underscores) so TOML→JSON/YAML conversion is direct. The
            // original source text is still recoverable via node_spans, so a
            // future round-trip editor loses nothing.
            const canon = switch (kind) {
                .integer => try self.canonicalInt(raw),
                .float => try self.canonicalFloat(raw),
            };
            return self.addNode(.{ .number = .{ .raw = canon, .kind = kind } }, tok.span);
        },
        .datetime => {
            _ = self.advance();
            const raw = self.tokenText(tok);
            const shape = try self.classifyDatetime(raw);
            return self.addNode(.{ .extended = .{ .text = raw, .kind = shape } }, tok.span);
        },
        .boolean => {
            _ = self.advance();
            return self.addNode(.{ .boolean = self.tokenText(tok)[0] == 't' }, tok.span);
        },
        .open_bracket => return self.parseArray(),
        .open_brace => return self.parseInlineTable(),
        else => return error.UnexpectedToken,
    }
}

/// Parse a `[ value, value, ... ]` array. Arrays may span lines and carry a
/// trailing comma; elements are heterogeneous.
fn parseArray(self: *Parser) ParserError!AST.Node.Id {
    const start = self.peek().span.start;
    _ = self.advance(); // '['
    const seq_id = try self.addNode(.{ .sequence = null }, Span.init(start, start + 1));
    var last: ?AST.Node.Id = null;

    while (true) {
        self.skipBlankFlow();
        if (self.peek().kind == .close_bracket) break;
        const elem = try self.parseValue();
        if (last) |l| {
            self.nodes.items[l].next_sibling = elem;
        } else {
            self.nodes.items[seq_id].kind = .{ .sequence = elem };
        }
        last = elem;
        self.skipBlankFlow();
        switch (self.peek().kind) {
            .comma => _ = self.advance(),
            .close_bracket => break,
            else => return error.UnexpectedToken,
        }
    }
    const end = self.peek().span.end;
    _ = self.advance(); // ']'
    self.spans.items[seq_id] = Span.init(start, end);
    return seq_id;
}

/// Parse a `{ key = value, ... }` inline table. TOML 1.0 inline tables are
/// single-line (no newlines inside) and have no trailing comma.
fn parseInlineTable(self: *Parser) ParserError!AST.Node.Id {
    // TOML 1.1 permits newlines and a trailing comma inside inline tables; 1.0
    // requires everything on one line with no trailing comma.
    const allow_nl = self.version == .TOML_1_1;
    const start = self.peek().span.start;
    _ = self.advance(); // '{'
    const map_id = try self.addNode(.{ .mapping = null }, Span.init(start, start + 1));
    try self.table_meta.put(self.allocator, map_id, .{ .inline_table = true });

    self.skipFlowWs(allow_nl);
    if (self.peek().kind != .close_brace) {
        while (true) {
            try self.parseInlineEntry(map_id);
            self.skipFlowWs(allow_nl);
            switch (self.peek().kind) {
                .comma => {
                    _ = self.advance();
                    self.skipFlowWs(allow_nl);
                    if (self.peek().kind == .close_brace) {
                        if (!allow_nl) return error.UnexpectedToken; // trailing comma (1.0)
                        break;
                    }
                },
                .close_brace => break,
                else => return error.UnexpectedToken,
            }
        }
    }
    const end = self.peek().span.end;
    if (self.peek().kind != .close_brace) return error.UnexpectedToken;
    _ = self.advance(); // '}'
    self.spans.items[map_id] = Span.init(start, end);
    return map_id;
}

/// One `key = value` (key possibly dotted) inside an inline table.
fn parseInlineEntry(self: *Parser, table_id: AST.Node.Id) ParserError!void {
    const allow_nl = self.version == .TOML_1_1;
    var segs: std.ArrayList(KeySeg) = .empty;
    defer segs.deinit(self.allocator);
    // Inline-table keys are lexed in value mode, so a bare key arrives as a
    // .number/.boolean/.datetime token; reinterpret it by position.
    while (true) {
        const tok = self.peek();
        const key = try self.decodeInlineKey(tok);
        _ = self.advance();
        try segs.append(self.allocator, .{ .str = key, .span = tok.span });
        self.skipFlowWs(allow_nl);
        if (self.peek().kind != .dot) break;
        _ = self.advance();
        self.skipFlowWs(allow_nl);
    }
    if (self.peek().kind != .equals) return error.UnexpectedToken;
    _ = self.advance();
    self.skipFlowWs(allow_nl);

    const cur = try self.navigateDottedPath(table_id, segs.items[0 .. segs.items.len - 1]);
    const final = segs.items[segs.items.len - 1];
    if (self.lookupChild(cur, final.str) != null) return error.DuplicateKey;
    const value_id = try self.parseValue();
    try self.appendKeyValue(cur, final, value_id);
}

fn decodeInlineKey(self: *Parser, tok: Token) ParserError![]const u8 {
    return switch (tok.kind) {
        .string => self.decodeString(self.tokenText(tok)), // quoted key
        .key => self.tokenText(tok),
        .number, .boolean, .datetime => blk: {
            const text = self.tokenText(tok);
            if (text.len == 0) return error.InvalidKey;
            for (text) |c| if (!Tokenizer.isBareKeyChar(c)) return error.InvalidKey;
            break :blk text;
        },
        else => error.UnexpectedToken,
    };
}

/// Skip whitespace, comments, and newlines — for inside a multi-line array.
fn skipBlankFlow(self: *Parser) void {
    self.skipBlank();
}

/// Skip inline-table separators: whitespace + comments, plus newlines when the
/// version permits them inside inline tables (1.1).
fn skipFlowWs(self: *Parser, allow_nl: bool) void {
    if (allow_nl) self.skipBlank() else self.skipInline();
}

// ── Key / string decoding ───────────────────────────────────────────────────

fn decodeKey(self: *Parser, tok: Token) ParserError![]const u8 {
    const raw = self.tokenText(tok);
    if (raw.len == 0) return error.InvalidKey;
    return switch (raw[0]) {
        '"', '\'' => self.decodeString(raw),
        else => raw, // bare key
    };
}

/// Decode any of the four TOML string forms to its byte value. Returns a slice
/// of `source` when no transformation is needed, else an owned (freed via the
/// AST) allocation.
fn decodeString(self: *Parser, raw: []const u8) ParserError![]const u8 {
    if (raw.len < 2) return error.UnclosedString;
    const q = raw[0];
    const triple = raw.len >= 6 and raw[1] == q and raw[2] == q;
    if (q == '\'') {
        // Literal: no escapes.
        if (triple) {
            var inner = raw[3 .. raw.len - 3];
            inner = trimLeadingNewline(inner);
            return inner;
        }
        return raw[1 .. raw.len - 1];
    }
    // Basic (q == '"').
    if (triple) {
        const inner = trimLeadingNewline(raw[3 .. raw.len - 3]);
        return self.decodeBasic(inner, true);
    }
    const inner = raw[1 .. raw.len - 1];
    if (std.mem.indexOfScalar(u8, inner, '\\') == null) return inner;
    return self.decodeBasic(inner, false);
}

/// A multi-line string with a newline immediately after the opening delimiter
/// drops that first newline.
fn trimLeadingNewline(inner: []const u8) []const u8 {
    if (inner.len >= 1 and inner[0] == '\n') return inner[1..];
    if (inner.len >= 2 and inner[0] == '\r' and inner[1] == '\n') return inner[2..];
    return inner;
}

fn decodeBasic(self: *Parser, inner: []const u8, multiline: bool) ParserError![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(self.allocator);

    var i: usize = 0;
    while (i < inner.len) {
        const c = inner[i];
        if (c != '\\') {
            try out.append(self.allocator, c);
            i += 1;
            continue;
        }
        if (i + 1 >= inner.len) return error.BadEscape;
        const n = inner[i + 1];
        switch (n) {
            'b' => try out.append(self.allocator, 0x08),
            't' => try out.append(self.allocator, '\t'),
            'n' => try out.append(self.allocator, '\n'),
            'f' => try out.append(self.allocator, 0x0c),
            'r' => try out.append(self.allocator, '\r'),
            '"' => try out.append(self.allocator, '"'),
            '\\' => try out.append(self.allocator, '\\'),
            'u' => i = try self.appendUnicode(&out, inner, i + 2, 4) - 2,
            'U' => i = try self.appendUnicode(&out, inner, i + 2, 8) - 2,
            // TOML 1.1: \e is ESC (U+001B); \xHH is shorthand for \u00HH.
            'e' => {
                if (self.version == .TOML_1_0) return error.BadEscape;
                try out.append(self.allocator, 0x1b);
            },
            'x' => {
                if (self.version == .TOML_1_0) return error.BadEscape;
                i = try self.appendUnicode(&out, inner, i + 2, 2) - 2;
            },
            ' ', '\t', '\n', '\r' => {
                if (!multiline) return error.BadEscape;
                // Line-ending backslash: `\` + optional whitespace + newline
                // trims all following whitespace up to the next content.
                var j = i + 1;
                while (j < inner.len and (inner[j] == ' ' or inner[j] == '\t')) j += 1;
                if (j >= inner.len or (inner[j] != '\n' and inner[j] != '\r')) return error.BadEscape;
                while (j < inner.len and (inner[j] == ' ' or inner[j] == '\t' or inner[j] == '\n' or inner[j] == '\r')) j += 1;
                i = j;
                continue;
            },
            else => return error.BadEscape,
        }
        i += 2;
    }

    const slice = try out.toOwnedSlice(self.allocator);
    errdefer self.allocator.free(slice);
    try self.owned_strings.append(self.allocator, slice);
    return slice;
}

/// Decode `n` hex digits at `inner[at..]` into a UTF-8 codepoint appended to
/// `out`; returns the index just past the digits.
fn appendUnicode(self: *Parser, out: *std.ArrayList(u8), inner: []const u8, at: usize, n: usize) ParserError!usize {
    if (at + n > inner.len) return error.BadEscape;
    const cp = std.fmt.parseInt(u21, inner[at .. at + n], 16) catch return error.InvalidUnicode;
    if (cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF)) return error.InvalidUnicode;
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &buf) catch return error.InvalidUnicode;
    try out.appendSlice(self.allocator, buf[0..len]);
    return at + n;
}

// ── Number validation / classification ──────────────────────────────────────

const NumberKind = @FieldType(AST.Node.Kind.Number, "kind");

fn classifyNumber(raw: []const u8) ParserError!NumberKind {
    if (raw.len == 0) return error.InvalidNumber;

    // Special floats.
    if (eqAny(raw, &.{ "inf", "+inf", "-inf", "nan", "+nan", "-nan" })) return .float;

    // Radix-prefixed integers (no sign permitted).
    if (raw.len >= 2 and raw[0] == '0') switch (raw[1]) {
        'x' => return if (validUnderscored(raw[2..], isHex)) .integer else error.InvalidNumber,
        'o' => return if (validUnderscored(raw[2..], isOctal)) .integer else error.InvalidNumber,
        'b' => return if (validUnderscored(raw[2..], isBinary)) .integer else error.InvalidNumber,
        else => {},
    };

    var body = raw;
    if (body[0] == '+' or body[0] == '-') body = body[1..];
    if (body.len == 0) return error.InvalidNumber;

    // Split mantissa / exponent.
    var mantissa = body;
    var exponent: ?[]const u8 = null;
    if (std.mem.indexOfAny(u8, body, "eE")) |e| {
        mantissa = body[0..e];
        exponent = body[e + 1 ..];
    }

    // Mantissa: int part, optional `.fraction`.
    var int_part = mantissa;
    var frac_part: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, mantissa, '.')) |d| {
        int_part = mantissa[0..d];
        frac_part = mantissa[d + 1 ..];
    }

    if (!validDecimalInt(int_part)) return error.InvalidNumber;
    var is_float = false;
    if (frac_part) |f| {
        if (!validUnderscored(f, isDecimal)) return error.InvalidNumber;
        is_float = true;
    }
    if (exponent) |e| {
        var exp = e;
        if (exp.len > 0 and (exp[0] == '+' or exp[0] == '-')) exp = exp[1..];
        if (!validUnderscored(exp, isDecimal)) return error.InvalidNumber;
        is_float = true;
    }
    return if (is_float) .float else .integer;
}

/// A decimal integer literal: `0`, or a non-zero-leading run of digits. Used for
/// the standalone integer and for a float's integer part (leading zeros banned
/// in both: `01` and `03.14` are invalid).
fn validDecimalInt(s: []const u8) bool {
    if (!validUnderscored(s, isDecimal)) return false;
    if (s.len > 1 and s[0] == '0') return false; // no leading zeros
    return true;
}

/// Non-empty, all chars satisfy `pred` or are `_`, and every `_` sits between
/// two `pred` digits (no leading/trailing/doubled underscore).
fn validUnderscored(s: []const u8, comptime pred: fn (u8) bool) bool {
    if (s.len == 0) return false;
    if (s[0] == '_' or s[s.len - 1] == '_') return false;
    var prev_us = false;
    for (s) |c| {
        if (c == '_') {
            if (prev_us) return false;
            prev_us = true;
        } else if (pred(c)) {
            prev_us = false;
        } else return false;
    }
    return true;
}

fn isDecimal(c: u8) bool {
    return c >= '0' and c <= '9';
}
fn isHex(c: u8) bool {
    return isDecimal(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}
fn isOctal(c: u8) bool {
    return c >= '0' and c <= '7';
}
fn isBinary(c: u8) bool {
    return c == '0' or c == '1';
}

fn eqAny(s: []const u8, options: []const []const u8) bool {
    for (options) |o| if (std.mem.eql(u8, s, o)) return true;
    return false;
}

/// Canonicalize an integer literal (any radix, underscores, sign) to a decimal
/// string. Returns `raw` unchanged when already canonical, else an owned copy.
fn canonicalInt(self: *Parser, raw: []const u8) ParserError![]const u8 {
    var buf: [80]u8 = undefined;
    var n: usize = 0;
    for (raw) |c| {
        if (c == '_') continue;
        if (n >= buf.len) return error.InvalidNumber;
        buf[n] = c;
        n += 1;
    }
    const v = std.fmt.parseInt(i64, buf[0..n], 0) catch return error.InvalidNumber;
    var out: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&out, "{d}", .{v}) catch return error.InvalidNumber;
    if (std.mem.eql(u8, s, raw)) return raw;
    return self.intern(s);
}

/// Canonicalize a float literal: special values to `inf`/`-inf`/`nan`, and strip
/// digit-group underscores (the remaining decimal/exponent form is valid JSON).
fn canonicalFloat(self: *Parser, raw: []const u8) ParserError![]const u8 {
    if (eqAny(raw, &.{ "inf", "+inf" })) return "inf";
    if (std.mem.eql(u8, raw, "-inf")) return "-inf";
    if (eqAny(raw, &.{ "nan", "+nan", "-nan" })) return "nan";
    if (std.mem.indexOfScalar(u8, raw, '_') == null) return raw;
    var buf: [80]u8 = undefined;
    var n: usize = 0;
    for (raw) |c| {
        if (c == '_') continue;
        if (n >= buf.len) return error.InvalidNumber;
        buf[n] = c;
        n += 1;
    }
    return self.intern(buf[0..n]);
}

/// Copy `s` into an AST-owned allocation.
fn intern(self: *Parser, s: []const u8) ParserError![]const u8 {
    const owned = try self.allocator.dupe(u8, s);
    errdefer self.allocator.free(owned);
    try self.owned_strings.append(self.allocator, owned);
    return owned;
}

// ── Datetime validation / classification ────────────────────────────────────

// The datetime subset of ExtKind; `classifyDatetime` only ever returns these
// four. (TOML never produces the enum/char-literal ExtKinds — those are ZON.)
const Shape = AST.Node.Kind.Extended.ExtKind;

fn classifyDatetime(self: *Parser, raw: []const u8) ParserError!Shape {
    // Time-only: HH:MM...
    if (raw.len >= 3 and raw[2] == ':') {
        try self.validateTime(raw);
        return .local_time;
    }
    // Date present: YYYY-MM-DD.
    if (raw.len < 10) return error.InvalidDatetime;
    try validateDate(raw[0..10]);
    if (raw.len == 10) return .local_date;

    // Separator then time (+ optional offset).
    const sep = raw[10];
    if (sep != 'T' and sep != 't' and sep != ' ') return error.InvalidDatetime;
    const rest = raw[11..];

    // Offset: trailing Z/z, or ±HH:MM at the end.
    var time_str = rest;
    var has_offset = false;
    if (rest.len > 0 and (rest[rest.len - 1] == 'Z' or rest[rest.len - 1] == 'z')) {
        time_str = rest[0 .. rest.len - 1];
        has_offset = true;
    } else if (rest.len >= 6 and (rest[rest.len - 6] == '+' or rest[rest.len - 6] == '-') and rest[rest.len - 3] == ':') {
        try validateOffset(rest[rest.len - 6 ..]);
        time_str = rest[0 .. rest.len - 6];
        has_offset = true;
    }
    try self.validateTime(time_str);
    return if (has_offset) .offset_datetime else .local_datetime;
}

fn twoDigit(s: []const u8, at: usize) u8 {
    return (s[at] - '0') * 10 + (s[at + 1] - '0');
}

fn validateDate(s: []const u8) ParserError!void {
    if (s.len != 10 or s[4] != '-' or s[7] != '-') return error.InvalidDatetime;
    const year = @as(u16, twoDigit(s, 0)) * 100 + twoDigit(s, 2);
    const month = twoDigit(s, 5);
    const day = twoDigit(s, 8);
    if (month < 1 or month > 12) return error.InvalidDatetime;
    if (day < 1 or day > daysInMonth(year, month)) return error.InvalidDatetime;
}

fn daysInMonth(year: u16, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) @as(u8, 29) else 28,
        else => 0,
    };
}

fn isLeapYear(year: u16) bool {
    return (year % 4 == 0 and year % 100 != 0) or year % 400 == 0;
}

/// HH:MM[:SS[.fraction]]; seconds 00-60 (leap second allowed). Seconds are
/// required in TOML 1.0 but optional in 1.1.
fn validateTime(self: *Parser, s: []const u8) ParserError!void {
    if (s.len < 5 or s[2] != ':') return error.InvalidDatetime;
    const hour = twoDigit(s, 0);
    const minute = twoDigit(s, 3);
    if (hour > 23 or minute > 59) return error.InvalidDatetime;
    if (s.len == 5) {
        if (self.version == .TOML_1_0) return error.InvalidDatetime; // seconds required
        return;
    }
    if (s[5] != ':') return error.InvalidDatetime;
    if (s.len < 8) return error.InvalidDatetime;
    if (twoDigit(s, 6) > 60) return error.InvalidDatetime;
    if (s.len == 8) return;
    if (s[8] != '.' or s.len < 10) return error.InvalidDatetime;
    for (s[9..]) |c| if (!isDecimal(c)) return error.InvalidDatetime;
}

/// ±HH:MM offset; hour 00-23, minute 00-59.
fn validateOffset(s: []const u8) ParserError!void {
    if (s.len != 6 or s[3] != ':') return error.InvalidDatetime;
    if (twoDigit(s, 1) > 23 or twoDigit(s, 4) > 59) return error.InvalidDatetime;
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "parses empty / comment-only documents" {
    const inputs = [_][]const u8{ "", "# c\n", "\n\n  \n" };
    for (inputs) |input| {
        var doc = try parse(testing.allocator, input, .TOML_1_0);
        defer doc.deinit(testing.allocator);
        try testing.expect(doc.ast.nodes[doc.ast.root].kind == .mapping);
    }
}

test "parses scalar key/value pairs" {
    var doc = try parse(testing.allocator,
        \\name = "Tom"
        \\count = 42
        \\pi = 3.14
        \\hex = 0xDEAD_beef
        \\flag = true
        \\when = 1979-05-27T07:32:00Z
        \\
    , .TOML_1_0);
    defer doc.deinit(testing.allocator);
    const ast = &doc.ast;
    const name = try ast.getValByPath(&.{.{ .key = "name" }});
    try testing.expectEqualStrings("Tom", name.kind.string);
    const count = try ast.getValByPath(&.{.{ .key = "count" }});
    try testing.expect(count.kind.number.kind == .integer);
    const pi = try ast.getValByPath(&.{.{ .key = "pi" }});
    try testing.expect(pi.kind.number.kind == .float);
    const when = try ast.getValByPath(&.{.{ .key = "when" }});
    try testing.expect(when.kind.extended.kind == .offset_datetime);
}

test "datetime shapes" {
    const cases = [_]struct { src: []const u8, shape: Shape }{
        .{ .src = "1979-05-27T07:32:00Z", .shape = .offset_datetime },
        .{ .src = "1979-05-27T07:32:00", .shape = .local_datetime },
        .{ .src = "1979-05-27 07:32:00", .shape = .local_datetime },
        .{ .src = "1979-05-27", .shape = .local_date },
        .{ .src = "07:32:00", .shape = .local_time },
        .{ .src = "00:32:00.999999", .shape = .local_time },
    };
    for (cases) |c| {
        const src = try std.fmt.allocPrint(testing.allocator, "d = {s}\n", .{c.src});
        defer testing.allocator.free(src);
        var doc = try parse(testing.allocator, src, .TOML_1_0);
        defer doc.deinit(testing.allocator);
        const d = try doc.ast.getValByPath(&.{.{ .key = "d" }});
        try testing.expectEqual(c.shape, d.kind.extended.kind);
    }
}

test "rejects bad scalars" {
    const bad = [_][]const u8{
        "x = 01\n", // leading zero
        "x = 1__2\n", // doubled underscore
        "x = 0x\n", // empty hex
        "x = 1979-13-01\n", // month over
        "x = 2021-02-29\n", // not a leap year
        "x = 00:00:61\n", // second over
        "x = \"a\nb\"\n", // newline in single-line string
        "x = \"\\q\"\n", // bad escape
        "a = 1 b = 2\n", // trailing content
    };
    for (bad) |input| {
        if (parse(testing.allocator, input, .TOML_1_0)) |doc| {
            var d = doc;
            d.deinit(testing.allocator);
            std.debug.print("expected rejection: {s}\n", .{input});
            return error.ExpectedParseFailure;
        } else |_| {}
    }
}

test "rejects duplicate root keys" {
    try testing.expectError(error.DuplicateKey, parse(testing.allocator, "a = 1\na = 2\n", .TOML_1_0));
}

test "tables and dotted keys build nested mappings" {
    var doc = try parse(testing.allocator,
        \\[server.tcp]
        \\port = 80
        \\opts.timeout = 30
        \\
        \\[server]
        \\name = "main"
        \\
    , .TOML_1_0);
    defer doc.deinit(testing.allocator);
    const ast = &doc.ast;
    const port = try ast.getValByPath(&.{ .{ .key = "server" }, .{ .key = "tcp" }, .{ .key = "port" } });
    try testing.expect(port.kind.number.kind == .integer);
    const timeout = try ast.getValByPath(&.{ .{ .key = "server" }, .{ .key = "tcp" }, .{ .key = "opts" }, .{ .key = "timeout" } });
    try testing.expectEqualStrings("30", timeout.kind.number.raw);
    const name = try ast.getValByPath(&.{ .{ .key = "server" }, .{ .key = "name" } });
    try testing.expectEqualStrings("main", name.kind.string);
}

test "implicit table promoted to explicit is allowed" {
    var doc = try parse(testing.allocator, "[a.b.c]\nx = 1\n\n[a]\ny = 2\n", .TOML_1_0);
    defer doc.deinit(testing.allocator);
}

test "arrays, inline tables, and arrays-of-tables" {
    var doc = try parse(testing.allocator,
        \\nums = [1, 2, 3]
        \\nested = [[1, 2], ["a", "b"]]
        \\point = { x = 1, y = 2 }
        \\
        \\[[fruit]]
        \\name = "apple"
        \\
        \\[[fruit]]
        \\name = "pear"
        \\
    , .TOML_1_0);
    defer doc.deinit(testing.allocator);
    const ast = &doc.ast;

    const n1 = try ast.getValByPath(&.{ .{ .key = "nums" }, .{ .index = 1 } });
    try testing.expectEqualStrings("2", n1.kind.number.raw);
    const inner = try ast.getValByPath(&.{ .{ .key = "nested" }, .{ .index = 1 }, .{ .index = 0 } });
    try testing.expectEqualStrings("a", inner.kind.string);
    const y = try ast.getValByPath(&.{ .{ .key = "point" }, .{ .key = "y" } });
    try testing.expectEqualStrings("2", y.kind.number.raw);
    const pear = try ast.getValByPath(&.{ .{ .key = "fruit" }, .{ .index = 1 }, .{ .key = "name" } });
    try testing.expectEqualStrings("pear", pear.kind.string);
}

test "inline-table dotted keys" {
    var doc = try parse(testing.allocator, "a = { b.c = 1, b.d = 2 }\n", .TOML_1_0);
    defer doc.deinit(testing.allocator);
    const c = try doc.ast.getValByPath(&.{ .{ .key = "a" }, .{ .key = "b" }, .{ .key = "c" } });
    try testing.expectEqualStrings("1", c.kind.number.raw);
}

test "rejects inline-table and array errors" {
    const bad = [_][]const u8{
        "a = { b = 1, }\n", // trailing comma (1.0)
        "a = { b = 1\n c = 2 }\n", // newline inside inline table (1.0)
        "a = {b=1}\n[a.c]\nx=1\n", // extend a closed inline table
        "a = [1, 2\n", // unclosed array
        "a = { b = 1, b = 2 }\n", // duplicate inline key
    };
    for (bad) |input| {
        if (parse(testing.allocator, input, .TOML_1_0)) |doc| {
            var d = doc;
            d.deinit(testing.allocator);
            std.debug.print("expected rejection: {s}\n", .{input});
            return error.ExpectedParseFailure;
        } else |_| {}
    }
}

test "TOML 1.1 features: optional seconds, \\e/\\x escapes, inline-table newlines" {
    var doc = try parse(testing.allocator,
        \\t = 13:37
        \\esc = "\e\x41"
        \\tbl = {
        \\  a = 1,
        \\  b = 2,
        \\}
        \\
    , .TOML_1_1);
    defer doc.deinit(testing.allocator);
    const ast = &doc.ast;
    const t = try ast.getValByPath(&.{.{ .key = "t" }});
    try testing.expect(t.kind.extended.kind == .local_time);
    const esc = try ast.getValByPath(&.{.{ .key = "esc" }});
    try testing.expectEqualStrings("\x1bA", esc.kind.string);
    const b = try ast.getValByPath(&.{ .{ .key = "tbl" }, .{ .key = "b" } });
    try testing.expectEqualStrings("2", b.kind.number.raw);
}

test "1.1-only constructs are rejected under 1.0" {
    const only_1_1 = [_][]const u8{
        "t = 13:37\n", // optional seconds
        "s = \"\\e\"\n", // \e escape
        "s = \"\\x41\"\n", // \x escape
        "t = { a = 1,\n b = 2 }\n", // newline in inline table
        "t = { a = 1, }\n", // trailing comma
    };
    for (only_1_1) |input| {
        // Valid under 1.1 …
        var ok = try parse(testing.allocator, input, .TOML_1_1);
        ok.deinit(testing.allocator);
        // … but rejected under 1.0.
        if (parse(testing.allocator, input, .TOML_1_0)) |doc| {
            var d = doc;
            d.deinit(testing.allocator);
            std.debug.print("expected 1.0 rejection: {s}\n", .{input});
            return error.ExpectedParseFailure;
        } else |_| {}
    }
}

test "rejects table/key conflicts" {
    const bad = [_][]const u8{
        "[a]\nb = 1\n\n[a.b]\nc = 2\n", // value used as table
        "[a]\n\n[a]\n", // duplicate table
        "a.b = 1\na.b.c = 2\n", // dotted key through a value
        "[a.b.c]\nz = 9\n\n[a]\nb.c.t = 1\n", // dotted-append to explicit table
    };
    for (bad) |input| {
        if (parse(testing.allocator, input, .TOML_1_0)) |doc| {
            var d = doc;
            d.deinit(testing.allocator);
            std.debug.print("expected rejection: {s}\n", .{input});
            return error.ExpectedParseFailure;
        } else |_| {}
    }
}
