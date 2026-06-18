const Printer = @This();
const std = @import("std");
const AST = @import("../ast.zig");
const Writer = std.Io.Writer;

/// JSON cannot represent a YAML alias. A materialized AST contains none (aliases
/// are expanded to copied subtrees by `yaml.materialize`), so reaching one here
/// means an unmaterialized YAML AST was handed to the JSON printer.
pub const Error = Writer.Error || error{UnresolvedAlias};

writer: *Writer,
ast: *const AST,
options: AST.SerializeOptions,
/// Which dialect to emit. JSON5 differs from JSON in exactly two places:
/// object keys print unquoted when they are bare identifiers, and the
/// non-finite `number_special` scalars (`Infinity`/`NaN`) print verbatim
/// rather than degrading to quoted strings. Everything else is identical.
dialect: Dialect = .json,

pub const Dialect = enum { json, json5 };

/// Prints a given document in JSON format.
pub fn print(writer: *Writer, ast: *const AST, options: AST.SerializeOptions) Error!void {
    var p: Printer = .{ .writer = writer, .ast = ast, .options = options };
    try p.node(ast.root, 0);
    try writer.writeByte('\n');
    try writer.flush();
}

/// Prints the subtree rooted at `id`. Used for partial renders; unlike `print`
/// it adds no trailing newline and does not flush.
pub fn printNode(writer: *Writer, ast: *const AST, id: AST.Node.Id, depth: usize, options: AST.SerializeOptions) Error!void {
    var p: Printer = .{ .writer = writer, .ast = ast, .options = options };
    try p.node(id, depth);
}

/// `print`, emitting JSON5: unquoted bare-identifier keys and verbatim
/// `Infinity`/`NaN`.
pub fn print5(writer: *Writer, ast: *const AST, options: AST.SerializeOptions) Error!void {
    var p: Printer = .{ .writer = writer, .ast = ast, .options = options, .dialect = .json5 };
    try p.node(ast.root, 0);
    try writer.writeByte('\n');
    try writer.flush();
}

/// `printNode`, emitting JSON5.
pub fn printNode5(writer: *Writer, ast: *const AST, id: AST.Node.Id, depth: usize, options: AST.SerializeOptions) Error!void {
    var p: Printer = .{ .writer = writer, .ast = ast, .options = options, .dialect = .json5 };
    try p.node(id, depth);
}

fn node(self: *Printer, id: AST.Node.Id, depth: usize) Error!void {
    const n = self.ast.nodes[id];
    switch (n.kind) {
        .null_ => try self.writer.writeAll("null"),
        .boolean => |value| try self.writer.writeAll(if (value) "true" else "false"),
        .number => |value| try self.number(value.raw),
        // JSON has none of these types. Datetimes and enum literals render as
        // strings (the timestamp / the bare name); a char literal renders as its
        // codepoint number.
        .extended => |value| switch (value.kind) {
            .char_literal => try self.writer.writeAll(value.text),
            // JSON5 has native non-finite floats; JSON must degrade to a string.
            .number_special => if (self.dialect == .json5)
                try self.writer.writeAll(value.text)
            else
                try writeJsonString(self.writer, value.text),
            else => try writeJsonString(self.writer, value.text),
        },
        .string => |value| try writeJsonString(self.writer, value),
        .sequence => |first_child| try self.sequence(first_child, depth),
        .mapping => |first_child| try self.mapping(first_child, depth),
        .keyvalue => |kv| {
            try self.key(kv.key, depth);
            // Compact output omits the space after the colon.
            try self.writer.writeAll(if (self.options.pretty) ": " else ":");
            try self.node(kv.value, depth);
        },
        .alias => return error.UnresolvedAlias,
    }
}

/// Render an object key. In JSON5 a string key that is a bare ECMAScript
/// identifier prints unquoted (`foo: 1`); otherwise it falls back to a normal
/// quoted string. JSON always quotes.
fn key(self: *Printer, id: AST.Node.Id, depth: usize) Error!void {
    const k = self.ast.nodes[id].kind;
    if (self.dialect == .json5 and k == .string and isBareIdentifier(k.string)) {
        try self.writer.writeAll(k.string);
        return;
    }
    try self.node(id, depth);
}

/// The ASCII subset of an ECMAScript IdentifierName, matching what the JSON5
/// tokenizer accepts unquoted. Reserved words are intentionally allowed (JSON5
/// permits `while: 1`); only the lexical shape matters.
fn isBareIdentifier(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name, 0..) |c, i| {
        const start_ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$';
        const part_ok = start_ok or (c >= '0' and c <= '9');
        if (!(if (i == 0) start_ok else part_ok)) return false;
    }
    return true;
}

/// Render a number. JSON5 keeps the source lexeme verbatim (hex, leading/
/// trailing `.`, leading `+` are all valid JSON5). Plain JSON has none of those,
/// so a non-JSON lexeme — whether from a JSON5 source (`0xFF`, `.5`, `+15`) or a
/// TOML one (`0xFF`, `0o17`, `1_000`) — is normalized to a valid JSON number.
fn number(self: *Printer, raw: []const u8) Error!void {
    if (self.dialect == .json5) {
        try self.writer.writeAll(raw);
        return;
    }
    try writeJsonNumber(self.writer, raw);
}

fn writeJsonNumber(writer: *Writer, raw: []const u8) Writer.Error!void {
    // Leading sign: JSON keeps `-`, drops `+`.
    var s = raw;
    if (s.len > 0 and s[0] == '-') {
        try writer.writeByte('-');
        s = s[1..];
    } else if (s.len > 0 and s[0] == '+') {
        s = s[1..];
    }

    // Radix-prefixed integers (`0x`/`0o`/`0b`) convert to decimal. Plain decimal
    // integers are passed through (arbitrary precision; never reformatted).
    if (s.len >= 2 and s[0] == '0' and (s[1] | 0x20 == 'x' or s[1] | 0x20 == 'o' or s[1] | 0x20 == 'b')) {
        const base: u8 = switch (s[1] | 0x20) {
            'x' => 16,
            'o' => 8,
            else => 2,
        };
        var buf: [128]u8 = undefined;
        if (stripUnderscores(s[2..], &buf)) |digits| {
            if (std.fmt.parseInt(u128, digits, base)) |v| {
                try writer.print("{d}", .{v});
                return;
            } else |_| {}
        }
        // Fallback: emit the (sign-stripped) lexeme rather than nothing.
        try writer.writeAll(s);
        return;
    }

    // Decimal/float: drop digit-group underscores and pad a bare `.`
    // (`.5` -> `0.5`, `5.` -> `5.0`) so the result is a valid JSON number.
    const e_idx = std.mem.indexOfAny(u8, s, "eE");
    const mantissa = if (e_idx) |i| s[0..i] else s;
    const exponent = if (e_idx) |i| s[i..] else "";

    if (mantissa.len > 0 and mantissa[0] == '.') try writer.writeByte('0');
    for (mantissa) |c| {
        if (c != '_') try writer.writeByte(c);
    }
    if (mantissa.len > 0 and mantissa[mantissa.len - 1] == '.') try writer.writeByte('0');

    for (exponent) |c| {
        if (c != '_') try writer.writeByte(c);
    }
}

/// Copy `s` into `buf` without `_` digit separators; null if it would overflow.
fn stripUnderscores(s: []const u8, buf: []u8) ?[]const u8 {
    var n: usize = 0;
    for (s) |c| {
        if (c == '_') continue;
        if (n >= buf.len) return null;
        buf[n] = c;
        n += 1;
    }
    return buf[0..n];
}

fn sequence(self: *Printer, first_child: ?AST.Node.Id, depth: usize) Error!void {
    try self.container('[', ']', first_child, depth);
}

fn mapping(self: *Printer, first_child: ?AST.Node.Id, depth: usize) Error!void {
    try self.container('{', '}', first_child, depth);
}

/// Sequences and mappings differ only in their delimiters and in how each child
/// renders (a bare node vs. a `key: value`), the latter dispatched by `node`.
fn container(self: *Printer, open: u8, close: u8, first_child: ?AST.Node.Id, depth: usize) Error!void {
    if (first_child == null) {
        try self.writer.writeByte(open);
        try self.writer.writeByte(close);
        return;
    }

    const pretty = self.options.pretty;
    try self.writer.writeByte(open);
    if (pretty) try self.writer.writeByte('\n');

    var current_id = first_child;
    while (current_id) |id| {
        if (pretty) try self.writeIndent(depth + 1);
        try self.node(id, depth + 1);
        current_id = self.ast.nodes[id].next_sibling;
        if (current_id != null) try self.writer.writeByte(',');
        if (pretty) try self.writer.writeByte('\n');
    }

    if (pretty) try self.writeIndent(depth);
    try self.writer.writeByte(close);
}

fn writeIndent(self: *Printer, depth: usize) Writer.Error!void {
    for (0..depth * self.options.indent) |_| try self.writer.writeByte(' ');
}

fn writeJsonString(writer: *Writer, value: []const u8) Writer.Error!void {
    try writer.writeByte('"');
    for (value) |char| {
        switch (char) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            0x08 => try writer.writeAll("\\b"),
            0x0c => try writer.writeAll("\\f"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x00...0x07, 0x0b, 0x0e...0x1f => try writeControlEscape(writer, char),
            else => try writer.writeByte(char),
        }
    }
    try writer.writeByte('"');
}

fn writeControlEscape(writer: *Writer, char: u8) Writer.Error!void {
    const hex = "0123456789abcdef";
    try writer.writeAll("\\u00");
    try writer.writeByte(hex[char >> 4]);
    try writer.writeByte(hex[char & 0x0f]);
}

test "prints JSON document" {
    const Parser = @import("parser.zig");
    const input = "{\"name\":\"Ada\",\"tags\":[\"zig\",true,null]}";
    var doc = try Parser.parseAbstract(std.testing.allocator, input, .JSON);
    defer doc.deinit();

    var output: Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try print(&output.writer, &doc, .{});
    try std.testing.expectEqualSlices(u8,
        \\{
        \\  "name": "Ada",
        \\  "tags": [
        \\    "zig",
        \\    true,
        \\    null
        \\  ]
        \\}
        \\
    , output.written());
}

test "prints compact JSON document" {
    const Parser = @import("parser.zig");
    const input = "{\"name\":\"Ada\",\"tags\":[\"zig\",true,null],\"empty\":{}}";
    var doc = try Parser.parseAbstract(std.testing.allocator, input, .JSON);
    defer doc.deinit();

    var output: Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try print(&output.writer, &doc, .{ .pretty = false });
    try std.testing.expectEqualSlices(u8,
        \\{"name":"Ada","tags":["zig",true,null],"empty":{}}
        \\
    , output.written());
}

test "json5: unquoted keys, Infinity/NaN, pretty" {
    const Parser = @import("parser.zig");
    const input = "{ a: 1, 'b c': 2, while: true, n: NaN, inf: -Infinity }";
    var doc = try Parser.parseAbstract(std.testing.allocator, input, .JSON5);
    defer doc.deinit();

    var output: Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try print5(&output.writer, &doc, .{});
    try std.testing.expectEqualSlices(u8,
        \\{
        \\  a: 1,
        \\  "b c": 2,
        \\  while: true,
        \\  n: NaN,
        \\  inf: -Infinity
        \\}
        \\
    , output.written());
}

test "json5: compact output" {
    const Parser = @import("parser.zig");
    const input = "{a:1,b:[2,Infinity,'x'],$_:3}";
    var doc = try Parser.parseAbstract(std.testing.allocator, input, .JSON5);
    defer doc.deinit();

    var output: Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try print5(&output.writer, &doc, .{ .pretty = false });
    try std.testing.expectEqualSlices(u8,
        \\{a:1,b:[2,Infinity,"x"],$_:3}
        \\
    , output.written());
}

test "json5: round-trips through serialize and reparse" {
    const Parser = @import("parser.zig");
    const input = "{ a: .5, b: 0xC8, c: [+1, -Infinity, NaN], 'has space': null, while: 'kw' }";
    var doc = try Parser.parseAbstract(std.testing.allocator, input, .JSON5);
    defer doc.deinit();

    var output: Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try print5(&output.writer, &doc, .{ .pretty = false });

    var reparsed = try Parser.parseAbstract(std.testing.allocator, output.written(), .JSON5);
    defer reparsed.deinit();
    try std.testing.expect(doc.eql(reparsed));
}

test "json dialect normalizes JSON5 number lexemes to valid JSON" {
    const Parser = @import("parser.zig");
    var doc = try Parser.parseAbstract(std.testing.allocator, "[0xFF, -0xa, .5, 5., +15, 1.5e3, -.25]", .JSON5);
    defer doc.deinit();

    var output: Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try print(&output.writer, &doc, .{ .pretty = false });
    try std.testing.expectEqualSlices(u8,
        \\[255,-10,0.5,5.0,15,1.5e3,-0.25]
        \\
    , output.written());
}

test "json dialect degrades Infinity to a quoted string" {
    const Parser = @import("parser.zig");
    var doc = try Parser.parseAbstract(std.testing.allocator, "Infinity", .JSON5);
    defer doc.deinit();

    var output: Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    // The same extended node, rendered by the plain-JSON dialect.
    try print(&output.writer, &doc, .{ .pretty = false });
    try std.testing.expectEqualSlices(u8, "\"Infinity\"\n", output.written());
}

test "honors custom indent width" {
    const Parser = @import("parser.zig");
    const input = "{\"a\":[1]}";
    var doc = try Parser.parseAbstract(std.testing.allocator, input, .JSON);
    defer doc.deinit();

    var output: Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try print(&output.writer, &doc, .{ .indent = 4 });
    try std.testing.expectEqualSlices(u8,
        \\{
        \\    "a": [
        \\        1
        \\    ]
        \\}
        \\
    , output.written());
}
