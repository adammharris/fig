//! The parser turns a JSON-formatted []const u8 into an AST.
//! It uses the Tokenizer to tokenize the string, and then converts
//! the token slice into an AST incrementally.
//!
//! This parser temporarily allocates and frees memory for the tokenizer
//! and for the in-progress containers, including three ArrayLists
//! for `node`s, `Span`s, and `OpenContainer`s.
//!
//! Decoded string escape allocations are transferred into the returned AST's
//! `owned_strings` slice and must be freed with `ast.deinit();`

const Parser = @This();

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const log = std.log.scoped(.parser);
const Unicode = @import("../util/util.zig").Unicode;
const AST = @import("../ast.zig");
const Document = @import("../document.zig");
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const Token = @import("../token.zig").Token(Tokenizer.Kind);
const Type = @import("json.zig").Type;
const Span = @import("../util/span.zig");

const ContainerKind = enum { array, object };
/// Either an array or object in the process of being parsed.
const OpenContainer = struct {
    id: AST.Node.Id,
    kind: ContainerKind,
    first_child: ?AST.Node.Id = null,
    last_child: ?AST.Node.Id = null,
    pending_key: ?AST.Node.Id = null,
};

// State
state: State = .ExpectValue,
nodes: std.ArrayList(AST.Node) = .empty,
node_spans: std.ArrayList(Span) = .empty,
container_stack: std.ArrayList(OpenContainer) = .empty,
owned_strings: std.ArrayList([]const u8) = .empty,

root: ?AST.Node.Id = null,

// Initial fields
allocator: std.mem.Allocator,
/// Which JSON dialect is being parsed. Gates the JSON5-only grammar
/// (unquoted keys, trailing commas, `Infinity`/`NaN`, single-quoted strings).
format: Type = .JSON,

const ParseError = error{ UnclosedObject, UnclosedArray, UnclosedString, InvalidBool, InvalidNumber, UnexpectedToken, InvalidUnicodeEscape };
const ParserError = ParseError || std.mem.Allocator.Error;

const State = enum {
    ExpectValue,

    ExpectArrayValueOrEnd,
    ExpectArrayCommaOrEnd,

    ExpectObjectKeyOrEnd,
    ExpectObjectKey,
    ExpectObjectColon,
    ExpectObjectValue,
    ExpectObjectCommaOrEnd,

    ExpectEndOfFile,
};

/// Expects "true" or "false", translates to boolean
pub fn getBool(slice: []const u8) ParseError!bool {
    if (std.mem.eql(u8, slice, "true")) return true;
    if (std.mem.eql(u8, slice, "false")) return false;
    return error.InvalidBool;
}

/// Removes double quotes. If the string contains escape codes,
/// decodes and stores the allocated string in the AST's `owned_strings`.
pub fn getString(self: *Parser, slice: []const u8) ParserError![]const u8 {
    const json5 = self.format == .JSON5;
    // JSON5 strings may also be single-quoted; the closing quote must match.
    const quote: u8 = if (slice.len >= 1) slice[0] else 0;
    const valid_quote = quote == '"' or (json5 and quote == '\'');
    if (slice.len < 2 or !valid_quote or slice[slice.len - 1] != quote) {
        return ParseError.UnclosedString;
    }
    const inner = slice[1 .. slice.len - 1];

    // Fast path: no escapes, can safely point into source.
    if (std.mem.indexOfScalar(u8, inner, '\\') == null) return inner;

    // String contains escapes, so we need to allocate a new decoded string.
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
        if (i >= inner.len) return ParseError.UnclosedString;

        switch (inner[i]) {
            '"' => try decoded.append(self.allocator, '"'), // double quote
            '\\' => try decoded.append(self.allocator, '\\'), // backslash
            '/' => try decoded.append(self.allocator, '/'), // slash
            'b' => try decoded.append(self.allocator, 0x08), // backspace
            'f' => try decoded.append(self.allocator, 0x0c), // formfeed
            'n' => try decoded.append(self.allocator, '\n'), // newline
            'r' => try decoded.append(self.allocator, '\r'), // return
            't' => try decoded.append(self.allocator, '\t'), // tab
            // JSON5-only escapes.
            '\'' => if (json5) try decoded.append(self.allocator, '\'') else return ParseError.UnexpectedToken,
            'v' => if (json5) try decoded.append(self.allocator, 0x0b) else return ParseError.UnexpectedToken,
            '0' => if (json5) try decoded.append(self.allocator, 0x00) else return ParseError.UnexpectedToken,
            'x' => { // \xHH hex escape (one code point U+00HH)
                if (!json5) return ParseError.UnexpectedToken;
                if (i + 2 >= inner.len) return ParseError.UnclosedString;
                const byte = std.fmt.parseInt(u8, inner[i + 1 .. i + 3], 16) catch return ParseError.InvalidUnicodeEscape;
                var xbuf: [4]u8 = undefined;
                const xwritten = std.unicode.utf8Encode(byte, &xbuf) catch return ParseError.InvalidUnicodeEscape;
                try decoded.appendSlice(self.allocator, xbuf[0..xwritten]);
                i += 2;
            },
            // Line continuations: a backslash before a line terminator emits
            // nothing (the source line wraps). CRLF counts as one terminator.
            '\n' => {
                if (!json5) return ParseError.UnexpectedToken;
            },
            '\r' => {
                if (!json5) return ParseError.UnexpectedToken;
                if (i + 1 < inner.len and inner[i + 1] == '\n') i += 1;
            },
            'u' => { // unicode
                // JSON \u escapes encode one UTF-16 code unit in 4 hex chars.
                if (i + 4 >= inner.len) return ParseError.UnclosedString;
                const bytes = inner[i + 1 .. i + 5];
                const first_unit = std.fmt.parseInt(u16, bytes, 16) catch return ParseError.InvalidUnicodeEscape;
                var codepoint: u21 = first_unit;
                i += 4;

                // If the escape contains an unpaired surrogate, preserve the
                // raw source representation rather than failing. JSONTestSuite
                // treats these as implementation-defined `i_` cases, and the
                // AST cannot losslessly normalize them into UTF-8.
                if (Unicode.isHighSurrogate(codepoint)) {
                    if (i + 6 >= inner.len) {
                        decoded.deinit(self.allocator);
                        return inner;
                    }
                    if (inner[i + 1] != '\\' or inner[i + 2] != 'u') {
                        decoded.deinit(self.allocator);
                        return inner;
                    }
                    const nextBytes = inner[i + 3 .. i + 7];
                    const low_unit = std.fmt.parseInt(u16, nextBytes, 16) catch return ParseError.InvalidUnicodeEscape;
                    if (!Unicode.isLowSurrogate(low_unit)) {
                        decoded.deinit(self.allocator);
                        return inner;
                    }
                    codepoint = 0x10000 + ((@as(u21, first_unit) - 0xD800) << 10) + (@as(u21, low_unit) - 0xDC00);
                    i += 6;
                } else if (Unicode.isLowSurrogate(codepoint)) {
                    decoded.deinit(self.allocator);
                    return inner;
                }

                var buf: [4]u8 = undefined;
                const written = std.unicode.utf8Encode(codepoint, &buf) catch return ParseError.InvalidUnicodeEscape;
                try decoded.appendSlice(self.allocator, buf[0..written]);
            },
            // JSON5 NonEscapeCharacter: any other escaped char is itself
            // (`\q` -> `q`). Strict JSON rejects unknown escapes.
            else => if (json5) try decoded.append(self.allocator, inner[i]) else return ParseError.UnexpectedToken,
        }
        i += 1;
    }
    const owned = try decoded.toOwnedSlice(self.allocator);
    errdefer self.allocator.free(owned);

    try self.owned_strings.append(self.allocator, owned);
    return owned;
}

/// Returns lossless struct representation of a number
pub fn getNumber(slice: []const u8) ParseError!AST.Node.Kind.Number {
    // JSON5 hexadecimal integers (`0xC8`, optionally signed) carry no dot and
    // no exponent; their `e`/`E` digits are part of the radix, not a float
    // exponent, so classify them before the dot/exponent heuristic.
    const body = if (slice.len > 0 and (slice[0] == '+' or slice[0] == '-')) slice[1..] else slice;
    if (body.len >= 2 and body[0] == '0' and (body[1] == 'x' or body[1] == 'X'))
        return .{ .raw = slice, .kind = .integer };

    var numDots: usize = 0;
    for (slice) |char| {
        if (char == '.') numDots += 1;
    }
    return .{ .raw = slice, .kind = switch (numDots) {
        0 => if (std.mem.indexOfAny(u8, slice, "eE") == null) .integer else .float,
        1 => .float,
        else => return error.InvalidNumber,
    } };
}

/// Main entry function
pub fn parseAbstract(allocator: std.mem.Allocator, input: []const u8, format: Type) !AST {
    const parsed = try parse(allocator, input, format);
    allocator.free(parsed.node_spans);
    return parsed.ast;
}

pub fn parse(allocator: std.mem.Allocator, input: []const u8, format: Type) !Document {
    var parser: Parser = .{ .allocator = allocator };
    defer parser.deinit();
    return parser.parse_once(input, format);
}

fn parse_once(self: *Parser, input: []const u8, kind: Type) !Document {
    self.format = kind;
    var tokenizer: Tokenizer = .{
        .allocator = self.allocator,
        .str = input,
        .kind = kind,
    };

    const tokens = try tokenizer.tokenize();
    defer self.allocator.free(tokens);

    // Each Document.Node has an id, a kind, and a next_sibling ID.
    // We produce them from the tokens.

    for (tokens) |token| {
        if (token.kind == .whitespace) continue;
        if (token.kind == .comment) continue;

        switch (self.state) {
            .ExpectValue => {
                switch (token.kind) {
                    .open_brace => {
                        const id = try self.addNode(.{ .mapping = null }, token.span);
                        try self.openContainer(.object, id);
                        self.state = .ExpectObjectKeyOrEnd;
                    },
                    .open_bracket => {
                        const id = try self.addNode(.{ .sequence = null }, token.span);
                        try self.openContainer(.array, id);
                        self.state = .ExpectArrayValueOrEnd;
                    },
                    .null_ => {
                        const id = try self.addTokenNode(input, token);
                        try self.finishValue(id);
                    },
                    .true_, .false_ => {
                        const id = try self.addTokenNode(input, token);
                        try self.finishValue(id);
                    },
                    .string => {
                        const id = try self.addTokenNode(input, token);
                        try self.finishValue(id);
                    },
                    .number, .identifier => {
                        const id = try self.addTokenNode(input, token);
                        try self.finishValue(id);
                    },
                    else => return ParseError.UnexpectedToken,
                }
            },

            .ExpectArrayValueOrEnd => {
                switch (token.kind) {
                    .open_bracket => {
                        const id = try self.addNode(.{ .sequence = null }, token.span);
                        try self.openContainer(.array, id);
                        self.state = .ExpectArrayValueOrEnd;
                    },
                    .open_brace => {
                        const id = try self.addNode(.{ .mapping = null }, token.span);
                        try self.openContainer(.object, id);
                        self.state = .ExpectObjectKeyOrEnd;
                    },
                    .null_ => {
                        const id = try self.addTokenNode(input, token);
                        try self.finishValue(id);
                    },
                    .true_, .false_ => {
                        const id = try self.addTokenNode(input, token);
                        try self.finishValue(id);
                    },
                    .string => {
                        const id = try self.addTokenNode(input, token);
                        try self.finishValue(id);
                    },
                    .number, .identifier => {
                        const id = try self.addTokenNode(input, token);
                        try self.finishValue(id);
                    },
                    .close_bracket => {
                        const id = try self.closeContainer(token.span.end);
                        try self.finishValue(id);
                    },
                    else => return ParseError.UnexpectedToken,
                }
            },
            .ExpectArrayCommaOrEnd => {
                switch (token.kind) {
                    .close_bracket => {
                        const id = try self.closeContainer(token.span.end);
                        try self.finishValue(id);
                    },
                    .comma => {
                        // JSON5 permits a trailing comma: route to the state
                        // that also accepts `]`. Strict JSON must then see a
                        // value, so `[1,]` stays an error.
                        self.state = if (self.format == .JSON5) .ExpectArrayValueOrEnd else .ExpectValue;
                    },
                    else => return ParseError.UnexpectedToken,
                }
            },

            .ExpectObjectKeyOrEnd => {
                switch (token.kind) {
                    .string, .identifier, .true_, .false_, .null_ => {
                        try self.beginKey(input, token);
                    },
                    .close_brace => {
                        const id = try self.closeContainer(token.span.end);
                        try self.finishValue(id);
                    },
                    else => return ParseError.UnexpectedToken,
                }
            },
            .ExpectObjectKey => {
                switch (token.kind) {
                    .string, .identifier, .true_, .false_, .null_ => {
                        try self.beginKey(input, token);
                    },
                    else => return ParseError.UnexpectedToken,
                }
            },
            .ExpectObjectColon => {
                switch (token.kind) {
                    .colon => {
                        self.state = .ExpectObjectValue;
                    },
                    else => return ParseError.UnexpectedToken,
                }
            },
            .ExpectObjectValue => {
                switch (token.kind) {
                    .open_brace => {
                        const id = try self.addNode(.{ .mapping = null }, token.span);
                        try self.openContainer(.object, id);
                        self.state = .ExpectObjectKeyOrEnd;
                    },
                    .open_bracket => {
                        const id = try self.addNode(.{ .sequence = null }, token.span);
                        try self.openContainer(.array, id);
                        self.state = .ExpectArrayValueOrEnd;
                    },
                    .null_ => {
                        const id = try self.addTokenNode(input, token);
                        try self.finishValue(id);
                    },
                    .true_, .false_ => {
                        const id = try self.addTokenNode(input, token);
                        try self.finishValue(id);
                    },
                    .string => {
                        const id = try self.addTokenNode(input, token);
                        try self.finishValue(id);
                    },
                    .number, .identifier => {
                        const id = try self.addTokenNode(input, token);
                        try self.finishValue(id);
                    },
                    else => return ParseError.UnexpectedToken,
                }
            },
            .ExpectObjectCommaOrEnd => {
                switch (token.kind) {
                    .close_brace => {
                        const id = try self.closeContainer(token.span.end);
                        try self.finishValue(id);
                    },
                    // JSON5 permits a trailing comma before `}`.
                    .comma => self.state = if (self.format == .JSON5) .ExpectObjectKeyOrEnd else .ExpectObjectKey,
                    else => return ParseError.UnexpectedToken,
                }
            },

            .ExpectEndOfFile => {
                switch (token.kind) {
                    .end_of_file => continue,
                    else => return ParseError.UnexpectedToken,
                }
            },
        }
    }

    // while loop completed.
    // Ready to return a Document!
    const root = self.root orelse return ParseError.UnexpectedToken;

    const nodes = try self.nodes.toOwnedSlice(self.allocator);
    errdefer self.allocator.free(nodes);
    self.nodes = .empty;

    const node_spans = try self.node_spans.toOwnedSlice(self.allocator);
    errdefer self.allocator.free(node_spans);
    self.node_spans = .empty;

    const owned_strings = try self.owned_strings.toOwnedSlice(self.allocator);
    self.owned_strings = .empty;

    return .{
        .source = input,
        .ast = .{
            .allocator = self.allocator,
            .owned_strings = owned_strings,
            .root = root,
            .nodes = nodes,
        },
        .node_spans = node_spans,
    };
}

pub fn deinit(self: *Parser) void {
    self.container_stack.deinit(self.allocator);
    self.nodes.deinit(self.allocator);
    self.node_spans.deinit(self.allocator);
    for (self.owned_strings.items) |string| {
        self.allocator.free(string);
    }
    self.owned_strings.deinit(self.allocator);
}

// ===============
// PARSING HELPERS
// ===============

/// Add an incomplete node to self.nodes. Called as soon as `[` or `{` is found.
fn addNode(self: *Parser, kind: AST.Node.Kind, span: Span) !AST.Node.Id {
    const id: AST.Node.Id = @intCast(self.nodes.items.len);
    try self.nodes.append(self.allocator, .{
        .id = id,
        .kind = kind,
        .next_sibling = null, // Update if there is a next sibling
    });
    try self.node_spans.append(self.allocator, span);
    return id;
}

fn addTokenNode(self: *Parser, input: []const u8, token: Token) !AST.Node.Id {
    return self.addNode(try self.tokenKind(input, token), token.span);
}

fn tokenKind(self: *Parser, input: []const u8, token: Token) ParserError!AST.Node.Kind {
    const raw = token.source(input);
    return switch (token.kind) {
        .null_ => .null_,
        .true_, .false_ => .{ .boolean = try getBool(raw) },
        .string => .{ .string = try self.getString(raw) },
        .number => specialNumber(raw) orelse .{ .number = try getNumber(raw) },
        // A bare identifier is only a value when it spells `Infinity`/`NaN`.
        .identifier => specialNumber(raw) orelse return ParseError.UnexpectedToken,
        else => ParseError.UnexpectedToken,
    };
}

/// `Infinity`/`NaN` (optionally signed) lift to an extended `number_special`
/// node — no JSON number can hold a non-finite value. Returns null otherwise.
fn specialNumber(raw: []const u8) ?AST.Node.Kind {
    const body = if (raw.len > 0 and (raw[0] == '+' or raw[0] == '-')) raw[1..] else raw;
    if (std.mem.eql(u8, body, "Infinity") or std.mem.eql(u8, body, "NaN"))
        return .{ .extended = .{ .kind = .number_special, .text = raw } };
    return null;
}

/// Record the pending object key from a `.string` (quoted), `.identifier`
/// (unquoted), or bare keyword (`true`/`false`/`null`) token, then expect `:`.
fn beginKey(self: *Parser, input: []const u8, token: Token) ParserError!void {
    // Only quoted strings are legal keys in strict JSON; the rest are JSON5.
    if (token.kind != .string and self.format != .JSON5) return ParseError.UnexpectedToken;
    const key_id = try self.addKeyNode(input, token);
    const parent = &self.container_stack.items[self.container_stack.items.len - 1];
    parent.pending_key = key_id;
    self.state = .ExpectObjectColon;
}

/// Build a string-valued key node. A quoted string is decoded; an identifier or
/// keyword key is its verbatim source text.
fn addKeyNode(self: *Parser, input: []const u8, token: Token) ParserError!AST.Node.Id {
    const kind: AST.Node.Kind = switch (token.kind) {
        .string => .{ .string = try self.getString(token.source(input)) },
        .identifier, .true_, .false_, .null_ => .{ .string = token.source(input) },
        else => return ParseError.UnexpectedToken,
    };
    return self.addNode(kind, token.span);
}

/// Attaches a completed child to the current open container.
fn attachChild(self: *Parser, parent: *OpenContainer, child_id: AST.Node.Id) void {
    if (parent.first_child != null) {
        self.nodes.items[parent.last_child.?].next_sibling = child_id;
    } else {
        parent.first_child = child_id;
        switch (parent.kind) {
            .array => self.nodes.items[parent.id].kind = .{ .sequence = child_id },
            .object => self.nodes.items[parent.id].kind = .{ .mapping = child_id },
        }
    }
    parent.last_child = child_id;
}

fn finishValue(self: *Parser, value_id: AST.Node.Id) !void {
    // If there is no parent, the parsing is complete
    if (self.container_stack.items.len == 0) {
        self.root = value_id;
        self.state = .ExpectEndOfFile;
        return;
    }

    const parent = &self.container_stack.items[self.container_stack.items.len - 1];

    switch (parent.kind) {
        .array => {
            self.attachChild(parent, value_id);
            self.state = .ExpectArrayCommaOrEnd;
        },
        .object => {
            const key_id = parent.pending_key orelse return ParseError.UnexpectedToken;
            parent.pending_key = null;

            const key_span = self.node_spans.items[key_id];
            const value_span = self.node_spans.items[value_id];
            const pair_id = try self.addNode(.{ .keyvalue = .{
                .key = key_id,
                .value = value_id,
            } }, .{
                .start = key_span.start,
                .end = value_span.end,
            });

            self.attachChild(parent, pair_id);
            self.state = .ExpectObjectCommaOrEnd;
        },
    }
}

/// Pushes stack metadata for a container node that already exists in self.nodes
fn openContainer(self: *Parser, kind: ContainerKind, node_id: AST.Node.Id) !void {
    try self.container_stack.append(self.allocator, .{
        .id = node_id,
        .kind = kind,
    });
}

/// Pops the current container, patches its span end, and returns the node ID.
fn closeContainer(self: *Parser, span_end: usize) !AST.Node.Id {
    if (self.container_stack.items.len == 0) return ParseError.UnexpectedToken;
    const container = self.container_stack.pop().?;
    self.node_spans.items[container.id].end = span_end;
    return container.id;
}

// =======
// Testing
// =======

fn testParser(input: []const u8, expected: AST) !void {
    var ast = try Parser.parseAbstract(testing.allocator, input, .JSON);
    defer ast.deinit();
    try testing.expect(expected.eql(ast));
}

fn testParserError(input: []const u8, expected_error: anyerror) !void {
    if (Parser.parseAbstract(testing.allocator, input, .JSON)) |ast| {
        var parsed = ast;
        defer parsed.deinit();
        try testing.expect(false);
    } else |err| {
        try testing.expectEqual(expected_error, err);
    }
}

test "simple JSON document" {
    try testParser(
        \\[{"hello":"world"}]
    , .{ .allocator = testing.allocator, .root = 0, .nodes = &[_]AST.Node{
        .{ .id = 0, .kind = .{ .sequence = 1 }, .next_sibling = null },
        .{
            .id = 1,
            .kind = .{ .mapping = 4 },
            .next_sibling = null,
        },
        .{
            .id = 2,
            .kind = .{ .string = "hello" },
            .next_sibling = null,
        },
        .{
            .id = 3,
            .kind = .{ .string = "world" },
            .next_sibling = null,
        },
        .{
            .id = 4,
            .kind = .{ .keyvalue = .{ .key = 2, .value = 3 } },
            .next_sibling = null,
        },
    } });
}

test "decodes JSON string escapes" {
    var ast = try Parser.parseAbstract(testing.allocator, "\"quote: \\\" slash: \\\\ newline: \\n tab: \\t backspace: \\b formfeed: \\f slash: \\/\"", .JSON);
    defer ast.deinit();

    const value = switch (ast.nodes[ast.root].kind) {
        .string => |string| string,
        else => return error.TestUnexpectedResult,
    };

    try testing.expectEqualSlices(u8, "quote: \" slash: \\ newline: \n tab: \t backspace: \x08 formfeed: \x0c slash: /", value);
}

test "decodes JSON unicode escapes" {
    var ast = try Parser.parseAbstract(testing.allocator, "\"A: \\u0041 latin: \\u00E9 clef: \\uD834\\uDD1E\"", .JSON);
    defer ast.deinit();

    const value = switch (ast.nodes[ast.root].kind) {
        .string => |string| string,
        else => return error.TestUnexpectedResult,
    };

    try testing.expectEqualSlices(u8, "A: A latin: é clef: 𝄞", value);
}

test "decodes escaped object keys" {
    var ast = try Parser.parseAbstract(testing.allocator, "{\"he\\u006clo\":1}", .JSON);
    defer ast.deinit();

    const value = try ast.getValByPath(&.{.{ .key = "hello" }});
    const number = switch (value.kind) {
        .number => |number| number,
        else => return error.TestUnexpectedResult,
    };

    try testing.expectEqualSlices(u8, "1", number.raw);
}

test "preserves unpaired unicode surrogate escapes as raw strings" {
    try testParser(
        "\"\\uD800\"",
        .{ .allocator = testing.allocator, .root = 0, .nodes = &[_]AST.Node{
            .{ .id = 0, .kind = .{ .string = "\\uD800" }, .next_sibling = null },
        } },
    );
    try testParser(
        "\"\\uDC00\"",
        .{ .allocator = testing.allocator, .root = 0, .nodes = &[_]AST.Node{
            .{ .id = 0, .kind = .{ .string = "\\uDC00" }, .next_sibling = null },
        } },
    );
    try testParser(
        "\"\\uD800x\"",
        .{ .allocator = testing.allocator, .root = 0, .nodes = &[_]AST.Node{
            .{ .id = 0, .kind = .{ .string = "\\uD800x" }, .next_sibling = null },
        } },
    );
    try testParser(
        "\"\\uD800\\u0041\"",
        .{ .allocator = testing.allocator, .root = 0, .nodes = &[_]AST.Node{
            .{ .id = 0, .kind = .{ .string = "\\uD800\\u0041" }, .next_sibling = null },
        } },
    );
}

test "UTF-8 BOM before document is ignored" {
    try testParser(
        "\xEF\xBB\xBF{}",
        .{ .allocator = testing.allocator, .root = 0, .nodes = &[_]AST.Node{
            .{ .id = 0, .kind = .{ .mapping = null }, .next_sibling = null },
        } },
    );
}

test "object trailing comma is rejected" {
    try testParserError("{\"a\":1,}", error.UnexpectedToken);
}

// ── JSON5 ────────────────────────────────────────────────────────────────────

fn parseJson5(input: []const u8) !AST {
    return Parser.parseAbstract(testing.allocator, input, .JSON5);
}

test "json5: trailing commas accepted (and still rejected in strict JSON)" {
    var arr = try parseJson5("[1,2,]");
    defer arr.deinit();
    try testing.expectEqual(@as(usize, 2), countItems(arr, arr.root));

    var obj = try parseJson5("{a:1,}");
    defer obj.deinit();
    try testing.expectEqual(@as(usize, 1), countItems(obj, obj.root));

    // Strict JSON keeps rejecting both.
    try testParserError("[1,2,]", error.UnexpectedToken);
    try testParserError("{\"a\":1,}", error.UnexpectedToken);
}

test "json5: leading comma is still rejected" {
    try testJson5Error("[,1]", error.UnexpectedToken);
    try testJson5Error("[,]", error.UnexpectedToken);
}

test "json5: unquoted and keyword object keys" {
    var ast = try parseJson5("{ hello: 1, $_$9: 2, while: 3, null: 4 }");
    defer ast.deinit();
    inline for (.{ "hello", "$_$9", "while", "null" }) |k| {
        const v = try ast.getValByPath(&.{.{ .key = k }});
        try testing.expect(v.kind == .number);
    }
}

test "json5: single-quoted strings, escapes, and line continuation" {
    var a = try parseJson5("'I can\\'t'");
    defer a.deinit();
    try testing.expectEqualSlices(u8, "I can't", a.nodes[a.root].kind.string);

    var b = try parseJson5("'line 1 \\\nline 2'");
    defer b.deinit();
    try testing.expectEqualSlices(u8, "line 1 line 2", b.nodes[b.root].kind.string);
}

test "json5: Infinity and NaN become extended number_special" {
    inline for (.{ "Infinity", "-Infinity", "+Infinity", "NaN" }) |lit| {
        var ast = try parseJson5(lit);
        defer ast.deinit();
        const k = ast.nodes[ast.root].kind;
        try testing.expect(k == .extended and k.extended.kind == .number_special);
        try testing.expectEqualSlices(u8, lit, k.extended.text);
    }
}

test "json5: hexadecimal, leading/trailing point, and signed numbers" {
    const cases = .{
        .{ "0xC8", AST.Node.Kind.Number{ .raw = "0xC8", .kind = .integer } },
        .{ "0xc8e4", AST.Node.Kind.Number{ .raw = "0xc8e4", .kind = .integer } },
        .{ "+15", AST.Node.Kind.Number{ .raw = "+15", .kind = .integer } },
        .{ ".5", AST.Node.Kind.Number{ .raw = ".5", .kind = .float } },
        .{ "5.", AST.Node.Kind.Number{ .raw = "5.", .kind = .float } },
    };
    inline for (cases) |c| {
        var ast = try parseJson5(c[0]);
        defer ast.deinit();
        const n = ast.nodes[ast.root].kind.number;
        try testing.expectEqual(c[1].kind, n.kind);
        try testing.expectEqualSlices(u8, c[1].raw, n.raw);
    }
}

test "json5: octal and lone-decimal forms are rejected" {
    try testJson5Error("010", error.LeadingZero);
    try testJson5Error("0x", error.UnexpectedToken);
    try testJson5Error(".", error.UnexpectedToken);
    try testJson5Error("+098", error.LeadingZero);
}

fn testJson5Error(input: []const u8, expected_error: anyerror) !void {
    if (Parser.parseAbstract(testing.allocator, input, .JSON5)) |ast| {
        var parsed = ast;
        defer parsed.deinit();
        try testing.expect(false);
    } else |err| {
        try testing.expectEqual(expected_error, err);
    }
}

fn countItems(ast: AST, container: AST.Node.Id) usize {
    var n: usize = 0;
    var cur = switch (ast.nodes[container].kind) {
        .sequence, .mapping => |first| first,
        else => return 0,
    };
    while (cur) |id| : (cur = ast.nodes[id].next_sibling) n += 1;
    return n;
}
