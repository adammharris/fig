//! The parser turns a dotenv-formatted []const u8 into an AST.
//!
//! Shape: a single flat root mapping, `KEY = value` per entry — dotenv has no
//! sections (unlike INI) and no dotted/nested keys. Every value is a
//! `.string` node: dotenv has no typed scalars either, and — deliberately —
//! no `$VAR`/`${VAR}` interpolation is performed; a value is stored exactly as
//! written (fig is a reader, not a shell). An optional leading `export `
//! (bash-export style) is recognized and discarded: see `parseKeyValue`.
//!
//! A repeated key silently keeps the LAST value at the FIRST-seen position
//! (see `shared/flat_map.zig`'s `putEntry`, `.overwrite`) and raises a
//! `duplicate_key` warning, exactly like INI/`.properties` — real,
//! parseable content, but likely an authoring mistake.

const Parser = @This();

const std = @import("std");
const testing = std.testing;
const AST = @import("../../ast/ast.zig");
const Document = @import("../../document.zig");
const Type = @import("dotenv.zig").Type;
const Span = @import("../../util/span.zig");
const flat_map = @import("../shared/flat_map.zig");
const Tokenizer = @import("tokenizer.zig");
const Token = Tokenizer.Token;

allocator: std.mem.Allocator,
version: Type = .DOTENV,
source: []const u8 = "",
tokens: []const Token = &.{},
pos: usize = 0,
arena: flat_map.NodeArena = undefined,
root_id: AST.Node.Id = 0,
owned_strings: std.ArrayList([]const u8) = .empty,
// Comment layer. Unlike INI (full-line comments only), dotenv's grammar has a
// real trailing comment (see the tokenizer): `last_value_id` tracks the most
// recently parsed value so `captureComment` can tell "a `#` right after that
// value, same line" (trailing) from "a `#` on its own line" (leading, buffered
// until the next key claims it) — mirrors TOML's identical `last_value_id`
// window exactly.
pending_leading: std.ArrayList(AST.Comment) = .empty,
last_value_id: ?AST.Node.Id = null,
comments_seen: bool = false,

recover: bool = false,
diagnostics: std.ArrayList(Diagnostic) = .empty,
warnings: std.ArrayList(Warning) = .empty,
fail_offset: ?usize = null,
fail_end: ?usize = null,

pub const ParseError = error{
    UnexpectedToken,
    MissingEquals,
    BadEscape,
    DuplicateKey,
    InvalidUtf8,
};
pub const ParserError = ParseError || Tokenizer.TokenizeError || std.mem.Allocator.Error;
pub const Error = ParserError;

pub fn describe(code: Error) []const u8 {
    return switch (code) {
        error.UnexpectedToken => "unexpected content here; expected `KEY=value` (optionally `export KEY=value`)",
        error.MissingEquals => "expected `=` after this key; every dotenv line is `KEY=value`",
        error.BadEscape => "invalid escape in a double-quoted value; supported: \\n \\t \\r \\\\ \\\" — use a single-quoted value for raw text with backslashes",
        error.DuplicateKey => "this key conflicts with one already defined",
        error.InvalidUtf8 => "this file is not valid UTF-8; dotenv documents must be UTF-8 encoded",
        error.UnexpectedCarriageReturn => "a bare `\\r` must be followed by `\\n`; line endings must be `\\n` or `\\r\\n`",
        error.UnclosedString => "unclosed quoted value; expected a matching `\"`/`'` before the end of the file",
        error.UnexpectedChar => "not a valid key here; a dotenv key is a bash identifier (`[A-Za-z_][A-Za-z0-9_]*`)",
        error.TrailingContent => "unexpected content after this quoted value; only a `#` comment may follow it on the same line",
        error.OutOfMemory => "out of memory",
    };
}

pub fn shortLabel(code: Error) []const u8 {
    return switch (code) {
        error.UnexpectedToken => "unexpected content",
        error.MissingEquals => "missing `=`",
        error.BadEscape => "invalid escape",
        error.DuplicateKey => "duplicate key",
        error.InvalidUtf8 => "invalid UTF-8",
        error.UnexpectedCarriageReturn => "bare CR",
        error.UnclosedString => "unclosed string",
        error.UnexpectedChar => "invalid key",
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

pub const Warning = struct {
    code: Code,
    offset: usize,
    end: ?usize = null,

    pub const Code = enum { duplicate_key };

    pub fn describeWarning(code: Code) []const u8 {
        return switch (code) {
            .duplicate_key => "this key is defined more than once; the last value wins and earlier ones are silently discarded",
        };
    }
    pub fn shortLabel(code: Code) []const u8 {
        return switch (code) {
            .duplicate_key => "duplicate key",
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
        // `node_comments` is already fully cleaned up by `parseOnce`'s own
        // `defer` on every path once tokenizing succeeds; freeing it again
        // here would double-free (see that defer's comment). `nodes`/`spans`
        // are not, so they're the only two this path releases.
        parser.arena.nodes.deinit(allocator);
        parser.arena.spans.deinit(allocator);
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

fn dispatchStatement(self: *Parser) ParserError!void {
    switch (self.peek().kind) {
        .key => try self.parseKeyValue(),
        else => return error.UnexpectedToken,
    }
}

/// The next `.newline`/`.end_of_file` token from `start` — always safe here:
/// a multi-line quoted value is one token regardless of the newlines it
/// embeds (see the tokenizer's module doc), so this can never land "inside"
/// one, and (like INI, unlike TOML) no lexical state persists across a real
/// newline, so the pre-computed token stream never needs re-tokenizing.
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
    try self.claimDangling(self.root_id);

    if (self.diagnostics.items.len > 0) return self.diagnostics.items[0].code;

    const nodes = try self.arena.nodes.toOwnedSlice(self.allocator);
    errdefer self.allocator.free(nodes);
    const spans = try self.arena.spans.toOwnedSlice(self.allocator);
    errdefer self.allocator.free(spans);
    const owned = try self.owned_strings.toOwnedSlice(self.allocator);

    var ast: AST = .{ .allocator = self.allocator, .root = self.root_id, .nodes = nodes, .owned_strings = owned };
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
        .newline => {
            self.last_value_id = null;
            self.pos += 1;
        },
        else => return,
    };
}

// ── Comments ─────────────────────────────────────────────────────────────────

/// A comment right after a just-parsed value (`last_value_id` set, no newline
/// since — the tokenizer only ever emits a comment token adjacent to a value
/// like this when it scanned a real trailing `#`) binds to it as trailing;
/// otherwise it's a leading comment buffered for the next key.
fn captureComment(self: *Parser, tok: Token) void {
    const text = std.mem.trim(u8, self.tokenText(tok), " \t\r");
    const c: AST.Comment = .{ .text = text, .style = .line };
    if (self.last_value_id) |id| {
        self.arena.node_comments.items[id].trailing = c;
        self.comments_seen = true;
        self.last_value_id = null;
    } else {
        self.pending_leading.appendAssumeCapacity(c);
    }
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

/// `[export] KEY = value`. An `export` prefix is recognized only when the
/// FIRST key-shaped token is literally that word AND a second key-shaped
/// token follows it (so a variable genuinely named `export` — `export=1` —
/// is unaffected: there, `=` immediately follows and no second key token
/// exists to trigger this).
fn parseKeyValue(self: *Parser) ParserError!void {
    var key_tok = self.peek();
    _ = self.advance();
    if (std.mem.eql(u8, self.tokenText(key_tok), "export") and self.peek().kind == .key) {
        key_tok = self.peek();
        _ = self.advance();
    }
    if (self.peek().kind != .equals) return error.MissingEquals;
    _ = self.advance();

    var value_text: []const u8 = "";
    var value_span = Span.init(self.peek().span.start, self.peek().span.start);
    var kind: ?Tokenizer.Kind = null;
    switch (self.peek().kind) {
        .double_quoted, .single_quoted, .unquoted => {
            const tok = self.peek();
            _ = self.advance();
            value_text = self.tokenText(tok);
            value_span = tok.span;
            kind = tok.kind;
        },
        else => {}, // `KEY=` at end of line: empty value
    }
    const decoded = if (kind) |k| try self.decodeValue(value_text, k) else "";

    const key_id = try self.arena.addNode(.{ .string = self.tokenText(key_tok) }, key_tok.span);
    try self.claimLeading(key_id);
    const value_id = try self.arena.addNode(.{ .string = decoded }, value_span);
    // Opens the trailing-comment window for a `#` immediately following on
    // this same line (see `captureComment`); `skipBlank`'s next real newline
    // closes it.
    self.last_value_id = value_id;
    const result = try flat_map.putEntry(&self.arena, self.root_id, key_id, value_id, .overwrite);
    if (result == .overwrote) try self.addWarning(.duplicate_key, key_tok.span);
}

fn decodeValue(self: *Parser, raw: []const u8, kind: Tokenizer.Kind) ParserError![]const u8 {
    return switch (kind) {
        .unquoted => raw, // never contains a literal newline; nothing to decode
        .single_quoted => self.decodeSingleQuoted(raw),
        .double_quoted => self.decodeDoubleQuoted(raw),
        else => unreachable,
    };
}

/// Fully raw between the quotes — no escapes — except a `\r\n` embedded in a
/// multi-line value normalizes to `\n` (fig's cross-platform line-ending
/// convention; see the YAML scanner's equivalent rule).
fn decodeSingleQuoted(self: *Parser, raw: []const u8) ParserError![]const u8 {
    const inner = raw[1 .. raw.len - 1];
    if (std.mem.indexOfScalar(u8, inner, '\r') == null) return inner;
    return self.normalizeCrlf(inner);
}

/// Decodes `\n \t \r \\ \"` and normalizes an embedded `\r\n` to `\n`,
/// matching a widely-used, minimal, unambiguous dotenv escape set — NOT
/// shell/JSON's fuller sets, and no `$VAR`/`${VAR}` interpolation (see the
/// module doc: fig is a reader, not a shell).
fn decodeDoubleQuoted(self: *Parser, raw: []const u8) ParserError![]const u8 {
    const inner = raw[1 .. raw.len - 1];
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(self.allocator);
    var i: usize = 0;
    while (i < inner.len) {
        const c = inner[i];
        if (c == '\r' and i + 1 < inner.len and inner[i + 1] == '\n') {
            try out.append(self.allocator, '\n');
            i += 2;
            continue;
        }
        if (c == '\\') {
            if (i + 1 >= inner.len) return error.BadEscape; // tokenizer guarantees this can't happen
            switch (inner[i + 1]) {
                'n' => try out.append(self.allocator, '\n'),
                't' => try out.append(self.allocator, '\t'),
                'r' => try out.append(self.allocator, '\r'),
                '\\' => try out.append(self.allocator, '\\'),
                '"' => try out.append(self.allocator, '"'),
                else => return error.BadEscape,
            }
            i += 2;
            continue;
        }
        try out.append(self.allocator, c);
        i += 1;
    }
    const slice = try out.toOwnedSlice(self.allocator);
    errdefer self.allocator.free(slice);
    try self.owned_strings.append(self.allocator, slice);
    return slice;
}

fn normalizeCrlf(self: *Parser, s: []const u8) ParserError![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(self.allocator);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\r' and i + 1 < s.len and s[i + 1] == '\n') {
            try out.append(self.allocator, '\n');
            i += 2;
            continue;
        }
        try out.append(self.allocator, s[i]);
        i += 1;
    }
    const slice = try out.toOwnedSlice(self.allocator);
    errdefer self.allocator.free(slice);
    try self.owned_strings.append(self.allocator, slice);
    return slice;
}

// ── Tests ───────────────────────────────────────────────────────────────────

fn expectRoot(input: []const u8, key: []const u8, value: []const u8) !void {
    var ast = try parseAbstract(testing.allocator, input, .DOTENV);
    defer ast.deinit();
    const v = AST.getValByPath(&ast, &.{.{ .key = key }}) catch |err| {
        std.debug.print("path lookup failed: {}\n", .{err});
        return err;
    };
    try testing.expectEqualStrings(value, v.kind.string);
}

test "unquoted value, trimmed" {
    try expectRoot("NAME = fig \n", "NAME", "fig");
}

test "export prefix is recognized and discarded" {
    try expectRoot("export NAME=fig\n", "NAME", "fig");
}

test "a variable actually named `export` is unaffected" {
    try expectRoot("export=1\n", "export", "1");
}

test "single-quoted value is fully raw (no escapes)" {
    try expectRoot("PATH = 'C:\\Users\\bob'\n", "PATH", "C:\\Users\\bob");
}

test "double-quoted value decodes escapes" {
    try expectRoot("MSG=\"line1\\nline2\\t!\"\n", "MSG", "line1\nline2\t!");
}

test "double-quoted value may embed a literal newline" {
    try expectRoot("MSG=\"line1\nline2\"\n", "MSG", "line1\nline2");
}

test "single-quoted value may also embed a literal newline" {
    try expectRoot("MSG='line1\nline2'\n", "MSG", "line1\nline2");
}

test "unquoted trailing comment requires preceding whitespace" {
    try expectRoot("A=bar #note\n", "A", "bar");
    try expectRoot("A=bar#not-a-comment\n", "A", "bar#not-a-comment");
}

test "a comment may follow a closing quote with no space" {
    try expectRoot("A=\"bar\"#note\n", "A", "bar");
}

test "empty value" {
    try expectRoot("A=\n", "A", "");
}

test "full-line comment leads the next key" {
    var ast = try parseAbstract(testing.allocator, "# a header\nNAME=fig\n", .DOTENV);
    defer ast.deinit();
    const key_node = (try AST.firstChildKey(&ast, &ast.nodes[ast.root])).?;
    const cs = ast.comments(key_node.id);
    try testing.expectEqual(@as(usize, 1), cs.leading.len);
    try testing.expectEqualStrings("a header", cs.leading[0].text);
}

test "repeated key keeps first position, last value, and warns" {
    var report: Report = .{};
    const doc = try parseWithReport(testing.allocator, "A=1\nB=2\nA=3\n", .DOTENV, &report);
    defer doc.deinit(testing.allocator);
    const a = try AST.getValByPath(&doc.ast, &.{.{ .key = "A" }});
    try testing.expectEqualStrings("3", a.kind.string);
    try testing.expectEqual(@as(usize, 1), report.warnings.len);
    try testing.expectEqual(Warning.Code.duplicate_key, report.warnings[0].code);
    testing.allocator.free(report.warnings);
}

test "an invalid key character is a tokenizer error" {
    try testing.expectError(error.UnexpectedChar, parseAbstract(testing.allocator, "1BAD=1\n", .DOTENV));
}

test "missing `=` is a recoverable parser error" {
    var report: Report = .{};
    const result = parseCollecting(testing.allocator, "good=1\nbadline\nfine=2\n", .DOTENV, &report);
    try testing.expectError(error.MissingEquals, result);
    try testing.expectEqual(@as(usize, 1), report.errors.len);
    testing.allocator.free(report.errors);
    testing.allocator.free(report.warnings);
}

test "unclosed quoted value is an error" {
    try testing.expectError(error.UnclosedString, parseAbstract(testing.allocator, "A=\"oops\n", .DOTENV));
}

test "trailing content after a quoted value is an error" {
    try testing.expectError(error.TrailingContent, parseAbstract(testing.allocator, "A=\"ok\" junk\n", .DOTENV));
}

test "invalid escape in a double-quoted value is an error" {
    try testing.expectError(error.BadEscape, parseAbstract(testing.allocator, "A=\"\\q\"\n", .DOTENV));
}
