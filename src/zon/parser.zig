//! ZON (Zig Object Notation) parser.
//!
//! Unlike the JSON/YAML parsers, this one hand-rolls NO tokenizer. ZON is a
//! subset of Zig source, so we lean on the Zig standard library's own parser:
//! `std.zig.Ast.parse(.zon)` produces a lossless syntax tree — token spans and
//! raw source bytes preserved — which we walk into fig's AST. This is the one
//! format where the stdlib carries the lexing/parsing for us, precisely because
//! `std.zig.Ast` is a formatter-grade *concrete* syntax tree (it backs `zig
//! fmt`), so it keeps the source fidelity fig's Document/span model needs.
//!
//! Enum and char literals — types the abstract model has no plain variant for —
//! are preserved as `extended` nodes (`ExtKind.enum_literal` / `.char_literal`),
//! so they round-trip through ZON losslessly. A non-ZON printer renders them
//! best-effort: an enum literal as a string (`"foo"`), a char as its codepoint.
//!
//! Remaining best-effort, niche behavior:
//!   * `inf` / `nan` become float numbers with verbatim raw text; a JSON printer
//!     will then emit non-conformant `inf`/`nan` tokens.
//!   * Non-decimal / underscored numbers (`0x1F`, `1_000`) keep their raw text,
//!     which is valid ZON but NOT valid JSON when converted.
//!
//! This parser is coupled to the Zig compiler's internal `std.zig.Ast` API,
//! which shifts between releases — the deliberate trade for the cheap impl.

const Parser = @This();

const std = @import("std");
const testing = std.testing;
const Ast = std.zig.Ast;
const AST = @import("../ast.zig");
const Document = @import("../document.zig");
const Type = @import("zon.zig").Type;
const Span = @import("../util/span.zig");

allocator: std.mem.Allocator,
/// Borrowed: the original (non-sentinel) input. AST string/number payloads that
/// point into source MUST slice this — never the sentinel dup `Ast` tokenizes,
/// which is freed before `parse` returns. Byte offsets are identical between the
/// two, so spans from the tree index this slice unchanged.
source: []const u8 = "",
tree: *const Ast = undefined,
nodes: std.ArrayList(AST.Node) = .empty,
node_spans: std.ArrayList(Span) = .empty,
owned_strings: std.ArrayList([]const u8) = .empty,

pub const Error = error{ InvalidZon, UnsupportedZon } || std.mem.Allocator.Error;

/// Parse `input` into an `AST` only, discarding source spans. Mirrors the other
/// languages' `parseAbstract` so tests can compare abstract shape.
pub fn parseAbstract(allocator: std.mem.Allocator, input: []const u8, format: Type) !AST {
    const parsed = try parse(allocator, input, format);
    allocator.free(parsed.node_spans);
    return parsed.ast;
}

pub fn parse(allocator: std.mem.Allocator, input: []const u8, format: Type) Error!Document {
    _ = format;

    // `std.zig.Ast.parse` requires a null-terminated source. The dup is byte
    // identical to `input`, so all token offsets line up with `input`.
    const sentinel = try allocator.dupeZ(u8, input);
    defer allocator.free(sentinel);

    var tree = try Ast.parse(allocator, sentinel, .zon);
    defer tree.deinit(allocator);
    if (tree.errors.len > 0) return error.InvalidZon;

    const root_decls = tree.rootDecls();
    if (root_decls.len == 0) return error.InvalidZon;

    var self: Parser = .{ .allocator = allocator, .source = input, .tree = &tree };
    errdefer self.deinit();

    const root = try self.walk(root_decls[0]);

    const nodes = try self.nodes.toOwnedSlice(allocator);
    errdefer allocator.free(nodes);
    self.nodes = .empty;

    const node_spans = try self.node_spans.toOwnedSlice(allocator);
    errdefer allocator.free(node_spans);
    self.node_spans = .empty;

    const owned_strings = try self.owned_strings.toOwnedSlice(allocator);
    self.owned_strings = .empty;

    return .{
        .source = input,
        .ast = .{
            .allocator = allocator,
            .owned_strings = owned_strings,
            .root = root,
            .nodes = nodes,
        },
        .node_spans = node_spans,
    };
}

pub fn deinit(self: *Parser) void {
    self.nodes.deinit(self.allocator);
    self.node_spans.deinit(self.allocator);
    for (self.owned_strings.items) |s| self.allocator.free(s);
    self.owned_strings.deinit(self.allocator);
}

// =========
// THE WALK
// =========

fn walk(self: *Parser, node: Ast.Node.Index) Error!AST.Node.Id {
    const tree = self.tree;
    switch (tree.nodeTag(node)) {
        .number_literal => return self.number(node),
        .char_literal => return self.charLiteral(node),
        .identifier => return self.identifier(node),
        .enum_literal => return self.enumLiteral(node),
        .string_literal, .multiline_string_literal => return self.stringLiteral(node),
        .negation => return self.negation(node),
        // ZON forbids parenthesized grouping, but the parser still builds the
        // node; transparently descend (best-effort).
        .grouped_expression => return self.walk(tree.nodeData(node).node_and_token[0]),
        .array_init_one,
        .array_init_one_comma,
        .array_init_dot_two,
        .array_init_dot_two_comma,
        .array_init_dot,
        .array_init_dot_comma,
        .array_init,
        .array_init_comma,
        .struct_init_one,
        .struct_init_one_comma,
        .struct_init_dot_two,
        .struct_init_dot_two_comma,
        .struct_init_dot,
        .struct_init_dot_comma,
        .struct_init,
        .struct_init_comma,
        => return self.container(node),
        else => return error.UnsupportedZon,
    }
}

/// Dispatch an init node to a sequence (array literal) or mapping (struct
/// literal). An empty `.{}` parses as an empty struct init → empty mapping.
fn container(self: *Parser, node: Ast.Node.Index) Error!AST.Node.Id {
    var buf: [2]Ast.Node.Index = undefined;
    if (self.tree.fullArrayInit(&buf, node)) |full| {
        if (full.ast.type_expr != .none) return error.UnsupportedZon; // `T{...}` typed init
        return self.sequence(node, full.ast.elements);
    }
    if (self.tree.fullStructInit(&buf, node)) |full| {
        if (full.ast.type_expr != .none) return error.UnsupportedZon;
        return self.mapping(node, full.ast.fields);
    }
    return error.UnsupportedZon;
}

fn sequence(self: *Parser, node: Ast.Node.Index, elements: []const Ast.Node.Index) Error!AST.Node.Id {
    const seq_id = try self.addNode(.{ .sequence = null }, self.nodeSpan(node));
    var first: ?AST.Node.Id = null;
    var prev: ?AST.Node.Id = null;
    for (elements) |elem| {
        const child_id = try self.walk(elem);
        if (prev) |p| self.nodes.items[p].next_sibling = child_id else first = child_id;
        prev = child_id;
    }
    self.nodes.items[seq_id].kind = .{ .sequence = first };
    return seq_id;
}

fn mapping(self: *Parser, node: Ast.Node.Index, fields: []const Ast.Node.Index) Error!AST.Node.Id {
    const tree = self.tree;
    const map_id = try self.addNode(.{ .mapping = null }, self.nodeSpan(node));
    var first: ?AST.Node.Id = null;
    var prev: ?AST.Node.Id = null;
    for (fields) |field| {
        // `.name = value`: the value's first token is `value`; stepping back two
        // tokens lands on the `name` identifier (skipping the `=`).
        const name_token = tree.firstToken(field) - 2;
        const key_id = try self.fieldName(name_token);
        const value_id = try self.walk(field);
        const key_span = self.node_spans.items[key_id];
        const value_span = self.node_spans.items[value_id];
        const kv_id = try self.addNode(
            .{ .keyvalue = .{ .key = key_id, .value = value_id } },
            .{ .start = key_span.start, .end = value_span.end },
        );
        if (prev) |p| self.nodes.items[p].next_sibling = kv_id else first = kv_id;
        prev = kv_id;
    }
    self.nodes.items[map_id].kind = .{ .mapping = first };
    return map_id;
}

// =========
// SCALARS
// =========

fn number(self: *Parser, node: Ast.Node.Index) Error!AST.Node.Id {
    const span = self.nodeSpan(node);
    const raw = self.sourceSlice(span);
    return self.addNode(.{ .number = .{ .raw = raw, .kind = classifyNumber(raw) } }, span);
}

fn negation(self: *Parser, node: Ast.Node.Index) Error!AST.Node.Id {
    const tree = self.tree;
    const child = tree.nodeData(node).node;
    const span = self.nodeSpan(node); // covers the `-` through the operand
    switch (tree.nodeTag(child)) {
        // `-123`, `-0x1.5p3`: raw text (incl. the sign) is preserved verbatim.
        .number_literal => {
            const raw = self.sourceSlice(span);
            return self.addNode(.{ .number = .{ .raw = raw, .kind = classifyNumber(raw) } }, span);
        },
        // `-inf` is the only other legal negation in ZON.
        .identifier => {
            const ident = tree.tokenSlice(tree.nodeMainToken(child));
            if (std.mem.eql(u8, ident, "inf"))
                return self.addNode(.{ .number = .{ .raw = "-inf", .kind = .float } }, span);
            return error.UnsupportedZon;
        },
        else => return error.UnsupportedZon,
    }
}

fn identifier(self: *Parser, node: Ast.Node.Index) Error!AST.Node.Id {
    const span = self.nodeSpan(node);
    const ident = self.tree.tokenSlice(self.tree.nodeMainToken(node));
    if (std.mem.eql(u8, ident, "true")) return self.addNode(.{ .boolean = true }, span);
    if (std.mem.eql(u8, ident, "false")) return self.addNode(.{ .boolean = false }, span);
    if (std.mem.eql(u8, ident, "null")) return self.addNode(.null_, span);
    if (std.mem.eql(u8, ident, "inf")) return self.addNode(.{ .number = .{ .raw = "inf", .kind = .float } }, span);
    if (std.mem.eql(u8, ident, "nan")) return self.addNode(.{ .number = .{ .raw = "nan", .kind = .float } }, span);
    return error.UnsupportedZon; // ZON allows no other bare identifiers
}

/// `.foo` enum literal → `extended` enum_literal whose text is the bare name (no
/// leading `.`). The name is a valid identifier in the common case (slice
/// straight from source); the rare `.@"quoted"` form is decoded into an owned
/// string.
fn enumLiteral(self: *Parser, node: Ast.Node.Index) Error!AST.Node.Id {
    const tree = self.tree;
    const token = tree.nodeMainToken(node);
    const span = self.tokenSpan(token);
    const slice = tree.tokenSlice(token);
    if (std.mem.startsWith(u8, slice, "@\"")) {
        const decoded = std.zig.string_literal.parseAlloc(self.allocator, slice[1..]) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidLiteral => return error.InvalidZon,
        };
        errdefer self.allocator.free(decoded);
        try self.owned_strings.append(self.allocator, decoded);
        return self.addNode(.{ .extended = .{ .kind = .enum_literal, .text = decoded } }, span);
    }
    return self.addNode(.{ .extended = .{ .kind = .enum_literal, .text = self.sourceSlice(span) } }, span);
}

fn stringLiteral(self: *Parser, node: Ast.Node.Index) Error!AST.Node.Id {
    const span = self.nodeSpan(node);

    // Let stdlib decode escapes and join multiline `\\` lines for us.
    var aw: std.Io.Writer.Allocating = .init(self.allocator);
    errdefer aw.deinit();
    const result = std.zig.ZonGen.parseStrLit(self.tree.*, node, &aw.writer) catch
        return error.OutOfMemory;
    switch (result) {
        .success => {},
        // `Ast.parse` already validated syntax, so a decode failure here is not
        // expected; treat defensively as malformed input.
        .failure => return error.InvalidZon,
    }

    const owned = try aw.toOwnedSlice();
    errdefer self.allocator.free(owned);
    try self.owned_strings.append(self.allocator, owned);
    return self.addNode(.{ .string = owned }, span);
}

/// `'a'` char literal → `extended` char_literal whose text is the decimal
/// Unicode codepoint. Storing the codepoint (not the raw `'a'`) keeps the
/// Zig-specific char codec confined to this parser and the ZON printer: other
/// formats treat the text as a plain number. The ZON printer re-encodes `'a'`.
fn charLiteral(self: *Parser, node: Ast.Node.Index) Error!AST.Node.Id {
    const span = self.nodeSpan(node);
    const slice = self.tree.tokenSlice(self.tree.nodeMainToken(node));
    const codepoint: u21 = switch (std.zig.string_literal.parseCharLiteral(slice)) {
        .success => |c| c,
        .failure => return error.InvalidZon,
    };
    const raw = try std.fmt.allocPrint(self.allocator, "{d}", .{codepoint});
    errdefer self.allocator.free(raw);
    try self.owned_strings.append(self.allocator, raw);
    return self.addNode(.{ .extended = .{ .kind = .char_literal, .text = raw } }, span);
}

/// Build a string key node from a struct-field name token.
fn fieldName(self: *Parser, token: Ast.TokenIndex) Error!AST.Node.Id {
    const slice = self.tree.tokenSlice(token);
    const span = self.tokenSpan(token);
    if (std.mem.startsWith(u8, slice, "@\"")) {
        const decoded = std.zig.string_literal.parseAlloc(self.allocator, slice[1..]) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidLiteral => return error.InvalidZon,
        };
        errdefer self.allocator.free(decoded);
        try self.owned_strings.append(self.allocator, decoded);
        return self.addNode(.{ .string = decoded }, span);
    }
    return self.addNode(.{ .string = self.sourceSlice(span) }, span);
}

// =========
// HELPERS
// =========

fn addNode(self: *Parser, kind: AST.Node.Kind, span: Span) Error!AST.Node.Id {
    const id: AST.Node.Id = @intCast(self.nodes.items.len);
    try self.nodes.append(self.allocator, .{ .id = id, .kind = kind, .next_sibling = null });
    try self.node_spans.append(self.allocator, span);
    return id;
}

fn nodeSpan(self: *Parser, node: Ast.Node.Index) Span {
    const tree = self.tree;
    const first = tree.firstToken(node);
    const last = tree.lastToken(node);
    return .{
        .start = tree.tokenStart(first),
        .end = tree.tokenStart(last) + tree.tokenSlice(last).len,
    };
}

fn tokenSpan(self: *Parser, token: Ast.TokenIndex) Span {
    const start = self.tree.tokenStart(token);
    return .{ .start = start, .end = start + self.tree.tokenSlice(token).len };
}

fn sourceSlice(self: *Parser, span: Span) []const u8 {
    return self.source[span.start..span.end];
}

/// fig's `Number.kind` is just a hint (the raw text is authoritative). Classify
/// by inspecting the verbatim ZON literal: anything with a fractional point, a
/// hex `p`-exponent, or a decimal `e`-exponent is a float; everything else
/// (incl. `0x`/`0o`/`0b` integers and `_`-separated digits) is an integer.
fn classifyNumber(raw: []const u8) @FieldType(AST.Node.Kind.Number, "kind") {
    if (std.mem.indexOfScalar(u8, raw, '.') != null) return .float;
    const body = if (std.mem.startsWith(u8, raw, "-")) raw[1..] else raw;
    const is_hex = body.len >= 2 and body[0] == '0' and (body[1] == 'x' or body[1] == 'X');
    if (is_hex) {
        // In hex, `e`/`E` are digits; only `p`/`P` introduces an exponent.
        return if (std.mem.indexOfAny(u8, body, "pP") != null) .float else .integer;
    }
    return if (std.mem.indexOfAny(u8, raw, "eE") != null) .float else .integer;
}

// =========
// TESTS
// =========

fn expectParse(input: []const u8, expected: AST) !void {
    var ast = try parseAbstract(testing.allocator, input, .ZON);
    defer ast.deinit();
    try testing.expect(expected.eql(ast));
}

test "scalar literals" {
    try expectParse("true", .{ .allocator = testing.allocator, .root = 0, .nodes = &.{
        .{ .id = 0, .kind = .{ .boolean = true } },
    } });
    try expectParse("null", .{ .allocator = testing.allocator, .root = 0, .nodes = &.{
        .{ .id = 0, .kind = .null_ },
    } });
    try expectParse("42", .{ .allocator = testing.allocator, .root = 0, .nodes = &.{
        .{ .id = 0, .kind = .{ .number = .{ .raw = "42", .kind = .integer } } },
    } });
    try expectParse("-3.5", .{ .allocator = testing.allocator, .root = 0, .nodes = &.{
        .{ .id = 0, .kind = .{ .number = .{ .raw = "-3.5", .kind = .float } } },
    } });
}

test "struct literal becomes a mapping" {
    try expectParse(
        \\.{ .name = "Ada", .age = 36 }
    , .{ .allocator = testing.allocator, .root = 0, .nodes = &.{
        .{ .id = 0, .kind = .{ .mapping = 3 } },
        .{ .id = 1, .kind = .{ .string = "name" } },
        .{ .id = 2, .kind = .{ .string = "Ada" } },
        .{ .id = 3, .kind = .{ .keyvalue = .{ .key = 1, .value = 2 } }, .next_sibling = 6 },
        .{ .id = 4, .kind = .{ .string = "age" } },
        .{ .id = 5, .kind = .{ .number = .{ .raw = "36", .kind = .integer } } },
        .{ .id = 6, .kind = .{ .keyvalue = .{ .key = 4, .value = 5 } } },
    } });
}

test "array literal becomes a sequence" {
    try expectParse(".{ 1, 2, 3 }", .{ .allocator = testing.allocator, .root = 0, .nodes = &.{
        .{ .id = 0, .kind = .{ .sequence = 1 } },
        .{ .id = 1, .kind = .{ .number = .{ .raw = "1", .kind = .integer } }, .next_sibling = 2 },
        .{ .id = 2, .kind = .{ .number = .{ .raw = "2", .kind = .integer } }, .next_sibling = 3 },
        .{ .id = 3, .kind = .{ .number = .{ .raw = "3", .kind = .integer } } },
    } });
}

test "empty .{} is an empty mapping" {
    try expectParse(".{}", .{ .allocator = testing.allocator, .root = 0, .nodes = &.{
        .{ .id = 0, .kind = .{ .mapping = null } },
    } });
}

test "string escapes are decoded" {
    var ast = try parseAbstract(testing.allocator, "\"tab:\\tnl:\\n\"", .ZON);
    defer ast.deinit();
    try testing.expectEqualStrings("tab:\tnl:\n", ast.nodes[ast.root].kind.string);
}

test "multiline string literal is joined" {
    var ast = try parseAbstract(testing.allocator,
        \\.{
        \\    .body =
        \\        \\line one
        \\        \\line two
        \\    ,
        \\}
    , .ZON);
    defer ast.deinit();
    const value = try ast.getValByPath(&.{.{ .key = "body" }});
    try testing.expectEqualStrings("line one\nline two", value.kind.string);
}

test "enum literal preserved as extended" {
    var ast = try parseAbstract(testing.allocator, ".{ .mode = .fast }", .ZON);
    defer ast.deinit();
    const value = try ast.getValByPath(&.{.{ .key = "mode" }});
    try testing.expect(value.kind.extended.kind == .enum_literal);
    try testing.expectEqualStrings("fast", value.kind.extended.text);
}

test "char literal preserved as extended codepoint" {
    var ast = try parseAbstract(testing.allocator, ".{ .c = 'A' }", .ZON);
    defer ast.deinit();
    const value = try ast.getValByPath(&.{.{ .key = "c" }});
    try testing.expect(value.kind.extended.kind == .char_literal);
    try testing.expectEqualStrings("65", value.kind.extended.text);
}

test "nested containers" {
    var ast = try parseAbstract(testing.allocator,
        \\.{ .items = .{ .{ .id = 1 }, .{ .id = 2 } } }
    , .ZON);
    defer ast.deinit();
    const second = try ast.getValByPath(&.{ .{ .key = "items" }, .{ .index = 1 }, .{ .key = "id" } });
    try testing.expectEqualStrings("2", second.kind.number.raw);
}

test "hex and underscored numbers keep raw text" {
    var ast = try parseAbstract(testing.allocator, ".{ .a = 0xFF, .b = 1_000, .c = 0x1.5p3 }", .ZON);
    defer ast.deinit();
    try testing.expectEqualStrings("0xFF", (try ast.getValByPath(&.{.{ .key = "a" }})).kind.number.raw);
    try testing.expect((try ast.getValByPath(&.{.{ .key = "a" }})).kind.number.kind == .integer);
    try testing.expectEqualStrings("1_000", (try ast.getValByPath(&.{.{ .key = "b" }})).kind.number.raw);
    try testing.expect((try ast.getValByPath(&.{.{ .key = "c" }})).kind.number.kind == .float);
}

test "syntax errors are rejected" {
    try testing.expectError(error.InvalidZon, parseAbstract(testing.allocator, ".{ .a = }", .ZON));
    try testing.expectError(error.InvalidZon, parseAbstract(testing.allocator, "", .ZON));
}
