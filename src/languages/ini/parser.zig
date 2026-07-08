//! The parser turns an INI-formatted []const u8 into an AST.
//!
//! Shape: the root mapping holds any keys that appear before the first
//! `[section]`, plus one child mapping per section (keyed by section name).
//! INI has no dotted keys, arrays, or inline tables, and — unlike TOML —
//! no typed scalars: every value is a `.string` node (INI's real-world
//! semantics never coerce a value's type at the format layer; that's a
//! consumer concern). A value that is wholly wrapped in matching `"`/`'`
//! quotes has them stripped verbatim (no escape decoding — see the
//! tokenizer's module doc for why).
//!
//! A repeated `[section]` header reopens (merges into) the existing section
//! rather than erroring — the common lenient behavior (git-config, many INI
//! libraries). A repeated key anywhere silently keeps the LAST value at the
//! FIRST-seen position (see `shared/flat_map.zig`'s `putEntry`) and raises a
//! `duplicate_key`/`duplicate_section` warning — real, parseable content, but
//! likely an authoring mistake, so it's a lint rather than a parse error.

const Parser = @This();

const std = @import("std");
const testing = std.testing;
const AST = @import("../../ast/ast.zig");
const Document = @import("../../document.zig");
const Type = @import("ini.zig").Type;
const Span = @import("../../util/span.zig");
const flat_map = @import("../shared/flat_map.zig");
const Tokenizer = @import("tokenizer.zig");
const Token = Tokenizer.Token;

allocator: std.mem.Allocator,
version: Type = .INI,
source: []const u8 = "",
tokens: []const Token = &.{},
pos: usize = 0,
arena: flat_map.NodeArena = undefined,
root_id: AST.Node.Id = 0,
/// The mapping new keys attach to: the root until the first `[section]`,
/// then whichever section is currently open.
current_table: AST.Node.Id = 0,
// Comment layer: INI comments are full-line only (see the tokenizer), so
// there is no trailing-comment window to track like TOML's `last_value_id` —
// every captured comment is simply buffered as `pending_leading` until the
// next key/section-header claims it (or it dangles at EOF).
pending_leading: std.ArrayList(AST.Comment) = .empty,
comments_seen: bool = false,

recover: bool = false,
diagnostics: std.ArrayList(Diagnostic) = .empty,
warnings: std.ArrayList(Warning) = .empty,
/// Overrides the next diagnostic's offset/end when the cursor has already
/// scanned past the offending span — mirrors TOML's `Parser.failAt`/`failSpan`.
fail_offset: ?usize = null,
fail_end: ?usize = null,

pub const ParseError = error{
    UnexpectedToken,
    InvalidKey,
    DuplicateKey,
    InvalidUtf8,
};
pub const ParserError = ParseError || Tokenizer.TokenizeError || std.mem.Allocator.Error;
pub const Error = ParserError;

pub fn describe(code: Error) []const u8 {
    return switch (code) {
        error.UnexpectedToken => "unexpected content here; expected a `[section]` header or a `key = value` line",
        error.InvalidKey => "a key/section name cannot be empty",
        error.DuplicateKey => "this section conflicts with a key of the same name already defined at this level",
        error.InvalidUtf8 => "this file is not valid UTF-8; INI documents must be UTF-8 encoded",
        error.UnexpectedCarriageReturn => "a bare `\\r` must be followed by `\\n`; line endings must be `\\n` or `\\r\\n`",
        error.UnclosedSection => "unclosed `[section]` header; expected a `]` before the end of the line",
        error.MissingEquals => "expected `=` after this key; every INI line is `key = value`",
        error.TrailingContent => "unexpected content after `]`; a section header must be alone on its line",
        error.OutOfMemory => "out of memory",
    };
}

pub fn shortLabel(code: Error) []const u8 {
    return switch (code) {
        error.UnexpectedToken => "unexpected content",
        error.InvalidKey => "empty key",
        error.DuplicateKey => "section/key conflict",
        error.InvalidUtf8 => "invalid UTF-8",
        error.UnexpectedCarriageReturn => "bare CR",
        error.UnclosedSection => "unclosed section",
        error.MissingEquals => "missing `=`",
        error.TrailingContent => "trailing content",
        error.OutOfMemory => "out of memory",
    };
}

const parse_diagnostic = @import("../../parse_diagnostic.zig");

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

/// An authoring-time lint: valid, parseable INI, but a shape a reader wouldn't
/// expect — currently only "this key/section was defined more than once, and
/// the later one silently won."
pub const Warning = struct {
    code: Code,
    offset: usize,
    end: ?usize = null,

    pub const Code = enum { duplicate_key, duplicate_section };

    pub fn describeWarning(code: Code) []const u8 {
        return switch (code) {
            .duplicate_key => "this key is defined more than once; the last value wins and earlier ones are silently discarded",
            .duplicate_section => "this section is defined more than once; entries merge into the first occurrence",
        };
    }
    pub fn shortLabel(code: Code) []const u8 {
        return switch (code) {
            .duplicate_key => "duplicate key",
            .duplicate_section => "duplicate section",
        };
    }
    pub fn locate(self: Warning, source: []const u8) parse_diagnostic.Location {
        return parse_diagnostic.locateOffset(source, self.offset);
    }
    pub fn renderAlloc(self: Warning, allocator: std.mem.Allocator, source: []const u8, file: []const u8) std.mem.Allocator.Error![]u8 {
        return parse_diagnostic.renderReportAlloc(allocator, source, self.offset, file, "warning", describeWarning(self.code));
    }
};

pub const Report = struct {
    diag: ?Diagnostic = null,
    errors: []const Diagnostic = &.{},
    warnings: []const Warning = &.{},
};

pub fn parse(allocator: std.mem.Allocator, input: []const u8, format: Type) ParserError!Document {
    return parseImpl(allocator, input, format, null, false);
}

pub fn parseWithReport(allocator: std.mem.Allocator, input: []const u8, format: Type, out: *Report) ParserError!Document {
    return parseImpl(allocator, input, format, out, false);
}

pub fn parseCollecting(allocator: std.mem.Allocator, input: []const u8, format: Type, out: *Report) ParserError!Document {
    return parseImpl(allocator, input, format, out, true);
}

fn parseImpl(allocator: std.mem.Allocator, input: []const u8, format: Type, out: ?*Report, recover: bool) ParserError!Document {
    var parser: Parser = .{ .allocator = allocator, .arena = .{ .allocator = allocator }, .recover = recover };
    defer parser.diagnostics.deinit(allocator);
    defer parser.warnings.deinit(allocator);
    const result = parser.parseOnce(input, format);
    if (out) |o| o.warnings = allocator.dupe(Warning, parser.warnings.items) catch &.{};
    return result catch |err| {
        if (out) |o| {
            if (parser.diagnostics.items.len > 0) {
                o.diag = parser.diagnostics.items[0];
                if (recover) o.errors = allocator.dupe(Diagnostic, parser.diagnostics.items) catch &.{};
            }
        }
        // `node_comments` is already fully cleaned up (inner slices freed, list
        // deinited) by `parseOnce`'s own `defer` on every path, once tokenizing
        // succeeds — freeing it again here would double-free. `nodes`/`spans`
        // are NOT covered by any defer (only `toOwnedSlice`d on success), so
        // they're the only two this path needs to release, mirroring TOML's
        // `parseImpl`.
        parser.arena.nodes.deinit(allocator);
        parser.arena.spans.deinit(allocator);
        return err;
    };
}

pub fn parseAbstract(allocator: std.mem.Allocator, input: []const u8, format: Type) ParserError!AST {
    const doc = try parse(allocator, input, format);
    allocator.free(doc.node_spans);
    return doc.ast;
}

fn dispatchStatement(self: *Parser) ParserError!void {
    switch (self.peek().kind) {
        .open_bracket => try self.parseSectionHeader(),
        .text => try self.parseKeyValue(),
        else => return error.UnexpectedToken,
    }
}

/// From `start`, the next `.newline`/`.end_of_file` token — always safe for
/// INI (unlike TOML, no lexical state persists across a newline, so the
/// pre-computed token stream never needs re-tokenizing after a parser-level
/// error; see the tokenizer's module doc).
fn resync(self: *Parser, start: usize) usize {
    var j = start;
    while (j < self.tokens.len) : (j += 1) {
        switch (self.tokens[j].kind) {
            .newline, .end_of_file => return j,
            else => {},
        }
    }
    return self.tokens.len - 1;
}

fn failAt(self: *Parser, offset: usize, err: Error) Error {
    self.fail_offset = offset;
    return err;
}
fn failSpan(self: *Parser, start: usize, end: usize, err: Error) Error {
    self.fail_offset = start;
    self.fail_end = end;
    return err;
}

fn parseOnce(self: *Parser, input: []const u8, format: Type) ParserError!Document {
    self.version = format;
    self.source = input;

    if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidUtf8;

    var tokenizer: Tokenizer = .{ .allocator = self.allocator, .str = input, .version = format };
    self.tokens = tokenizer.tokenize() catch |err| {
        try self.diagnostics.append(self.allocator, .{ .code = err, .offset = tokenizer.i });
        return err;
    };
    defer self.allocator.free(self.tokens);
    try self.pending_leading.ensureTotalCapacity(self.allocator, self.tokens.len);
    defer self.pending_leading.deinit(self.allocator);
    defer {
        for (self.arena.node_comments.items) |nc| {
            self.allocator.free(nc.leading);
            self.allocator.free(nc.dangling);
        }
        self.arena.node_comments.deinit(self.allocator);
    }

    self.root_id = try self.arena.addNode(.{ .mapping = null }, Span.init(0, input.len));
    self.current_table = self.root_id;

    self.skipBlank();
    while (!self.atEnd()) {
        self.dispatchStatement() catch |err| {
            if (err == error.OutOfMemory) return err;
            const offset = self.fail_offset orelse self.peek().span.start;
            const end = self.fail_end;
            self.fail_offset = null;
            self.fail_end = null;
            try self.diagnostics.append(self.allocator, .{ .code = err, .offset = offset, .end = end });
            if (!self.recover) return err;
            self.pos = self.resync(self.pos);
        };
        self.skipBlank();
    }
    try self.claimDangling(self.current_table);

    if (self.diagnostics.items.len > 0) return self.diagnostics.items[0].code;

    const nodes = try self.arena.nodes.toOwnedSlice(self.allocator);
    errdefer self.allocator.free(nodes);
    const spans = try self.arena.spans.toOwnedSlice(self.allocator);
    errdefer self.allocator.free(spans);

    var ast: AST = .{ .allocator = self.allocator, .root = self.root_id, .nodes = nodes };
    if (self.comments_seen) {
        ast.node_comments = try self.arena.node_comments.toOwnedSlice(self.allocator);
        self.arena.node_comments = .empty;
    }

    return .{ .source = input, .ast = ast, .node_spans = spans };
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
fn tokenText(self: *Parser, tok: Token) []const u8 {
    return self.source[tok.span.start..tok.span.end];
}

fn skipBlank(self: *Parser) void {
    while (true) switch (self.peek().kind) {
        .comment => {
            self.captureComment(self.peek());
            self.pos += 1;
        },
        .newline => self.pos += 1,
        else => return,
    };
}

// ── Comments ─────────────────────────────────────────────────────────────────

fn captureComment(self: *Parser, tok: Token) void {
    const text = std.mem.trim(u8, self.tokenText(tok), " \t\r");
    self.pending_leading.appendAssumeCapacity(.{ .text = text, .style = .line });
}

fn claimLeading(self: *Parser, id: AST.Node.Id) ParserError!void {
    if (self.pending_leading.items.len == 0) return;
    const owned = try self.allocator.dupe(AST.Comment, self.pending_leading.items);
    self.pending_leading.clearRetainingCapacity();
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

fn addWarning(self: *Parser, code: Warning.Code, span: Span) ParserError!void {
    try self.warnings.append(self.allocator, .{ .code = code, .offset = span.start, .end = span.end });
}

// ── Statements ──────────────────────────────────────────────────────────────

/// `[name]` — reopen the existing section mapping if `name` was seen before
/// (merge), else create a fresh child mapping under root.
fn parseSectionHeader(self: *Parser) ParserError!void {
    _ = self.advance(); // '['
    const name_tok = self.peek();
    if (name_tok.kind != .text) return error.UnexpectedToken;
    _ = self.advance();
    const name = self.tokenText(name_tok);
    if (self.peek().kind != .close_bracket) return error.UnexpectedToken;
    _ = self.advance();
    if (name.len == 0) return self.failSpan(name_tok.span.start, name_tok.span.end, error.InvalidKey);

    if (flat_map.lookupChild(self.arena.nodes.items, self.root_id, name)) |existing_kv| {
        const kv = self.arena.nodes.items[existing_kv].kind.keyvalue;
        if (self.arena.nodes.items[kv.value].kind != .mapping)
            return self.failSpan(name_tok.span.start, name_tok.span.end, error.DuplicateKey);
        self.current_table = kv.value;
        try self.addWarning(.duplicate_section, name_tok.span);
    } else {
        const key_id = try self.arena.addNode(.{ .string = name }, name_tok.span);
        try self.claimLeading(key_id);
        const map_id = try self.arena.addNode(.{ .mapping = null }, name_tok.span);
        _ = try flat_map.putEntry(&self.arena, self.root_id, key_id, map_id, .overwrite);
        self.current_table = map_id;
    }
}

/// `key = value`, attaching to `current_table`.
fn parseKeyValue(self: *Parser) ParserError!void {
    const key_tok = self.peek();
    _ = self.advance();
    const key_str = self.tokenText(key_tok);
    if (key_str.len == 0) return self.failSpan(key_tok.span.start, key_tok.span.end, error.InvalidKey);
    if (self.peek().kind != .equals) return error.UnexpectedToken;
    _ = self.advance();

    // A value token is absent for `key=` at end of line (empty value).
    var value_text: []const u8 = "";
    var value_span = Span.init(self.peek().span.start, self.peek().span.start);
    if (self.peek().kind == .text) {
        const value_tok = self.peek();
        _ = self.advance();
        value_text = self.tokenText(value_tok);
        value_span = value_tok.span;
    }

    const key_id = try self.arena.addNode(.{ .string = key_str }, key_tok.span);
    try self.claimLeading(key_id);
    const value_id = try self.arena.addNode(.{ .string = decodeValue(value_text) }, value_span);
    const result = try flat_map.putEntry(&self.arena, self.current_table, key_id, value_id, .overwrite);
    if (result == .overwrote) try self.addWarning(.duplicate_key, key_tok.span);
}

/// Strip one layer of matching `"..."`/`'...'` quotes spanning the whole
/// (already-trimmed) value. No escape decoding — see the tokenizer's doc.
fn decodeValue(raw: []const u8) []const u8 {
    if (raw.len >= 2) {
        const q = raw[0];
        if ((q == '"' or q == '\'') and raw[raw.len - 1] == q) return raw[1 .. raw.len - 1];
    }
    return raw;
}

// ── Tests ───────────────────────────────────────────────────────────────────

fn expectRoot(input: []const u8, key: []const u8, value: []const u8) !void {
    var ast = try parseAbstract(testing.allocator, input, .INI);
    defer ast.deinit();
    const v = AST.getValByPath(&ast, &.{.{ .key = key }}) catch |err| {
        std.debug.print("path lookup failed: {}\n", .{err});
        return err;
    };
    try testing.expectEqualStrings(value, v.kind.string);
}

test "root-level key before any section" {
    try expectRoot("name = fig\n", "name", "fig");
}

test "value runs to end of line, untouched, whitespace trimmed" {
    try expectRoot("path = C:\\Users\\bob;keep\n", "path", "C:\\Users\\bob;keep");
}

test "quoted value has its outer quotes stripped" {
    try expectRoot("name = \"fig lang\"\n", "name", "fig lang");
    try expectRoot("name = 'fig lang'\n", "name", "fig lang");
}

test "section nesting" {
    var ast = try parseAbstract(testing.allocator, "[server]\nhost = localhost\nport = 80\n", .INI);
    defer ast.deinit();
    const v = try AST.getValByPath(&ast, &.{ .{ .key = "server" }, .{ .key = "host" } });
    try testing.expectEqualStrings("localhost", v.kind.string);
}

test "repeated section merges entries and warns" {
    var report: Report = .{};
    const doc = try parseWithReport(testing.allocator, "[a]\nx = 1\n[a]\ny = 2\n", .INI, &report);
    defer doc.deinit(testing.allocator);
    const x = try AST.getValByPath(&doc.ast, &.{ .{ .key = "a" }, .{ .key = "x" } });
    const y = try AST.getValByPath(&doc.ast, &.{ .{ .key = "a" }, .{ .key = "y" } });
    try testing.expectEqualStrings("1", x.kind.string);
    try testing.expectEqualStrings("2", y.kind.string);
    try testing.expectEqual(@as(usize, 1), report.warnings.len);
    try testing.expectEqual(Warning.Code.duplicate_section, report.warnings[0].code);
    testing.allocator.free(report.warnings);
}

test "repeated key keeps first position, last value, and warns" {
    var report: Report = .{};
    const doc = try parseWithReport(testing.allocator, "a = 1\nb = 2\na = 3\n", .INI, &report);
    defer doc.deinit(testing.allocator);
    const a = try AST.getValByPath(&doc.ast, &.{.{ .key = "a" }});
    try testing.expectEqualStrings("3", a.kind.string);
    try testing.expectEqual(@as(usize, 1), report.warnings.len);
    try testing.expectEqual(Warning.Code.duplicate_key, report.warnings[0].code);
    testing.allocator.free(report.warnings);
}

test "comments: full-line only, leading run attaches to the next key" {
    var ast = try parseAbstract(testing.allocator,
        \\; a header comment
        \\# another style
        \\name = fig
        \\
    , .INI);
    defer ast.deinit();
    const key_node = (try AST.firstChildKey(&ast, &ast.nodes[ast.root])).?;
    const cs = ast.comments(key_node.id);
    try testing.expectEqual(@as(usize, 2), cs.leading.len);
    try testing.expectEqualStrings("a header comment", cs.leading[0].text);
    try testing.expectEqualStrings("another style", cs.leading[1].text);
}

test "a `;`/`#` inside a value is literal, not a comment" {
    try expectRoot("greeting = hi ; not a comment #still not\n", "greeting", "hi ; not a comment #still not");
}

test "empty value" {
    try expectRoot("flag = \n", "flag", "");
}

test "missing `=` is an error" {
    try testing.expectError(error.MissingEquals, parseAbstract(testing.allocator, "not-a-kv-line\n", .INI));
}

test "unclosed section is an error" {
    try testing.expectError(error.UnclosedSection, parseAbstract(testing.allocator, "[oops\n", .INI));
}

test "trailing content after a section header is an error" {
    try testing.expectError(error.TrailingContent, parseAbstract(testing.allocator, "[a] junk\n", .INI));
}

test "a section colliding with an existing plain key is a DuplicateKey error" {
    try testing.expectError(error.DuplicateKey, parseAbstract(testing.allocator, "a = 1\n[a]\nx = 2\n", .INI));
}

test "parseCollecting recovers across multiple parser-level errors" {
    // `MissingEquals`/`UnclosedSection` are TOKENIZER errors — like TOML, those
    // abort the whole lexical pass before the parser's statement loop (and its
    // recovery) ever starts, so they can't be collected one-per-line. This
    // exercises recovery over genuine PARSER-level errors instead: two
    // section/key name collisions in one file.
    var report: Report = .{};
    const result = parseCollecting(testing.allocator, "a = 1\n[a]\nx = 1\nb = 2\n[b]\ny = 2\n", .INI, &report);
    try testing.expectError(error.DuplicateKey, result);
    try testing.expectEqual(@as(usize, 2), report.errors.len);
    testing.allocator.free(report.errors);
    testing.allocator.free(report.warnings);
}
