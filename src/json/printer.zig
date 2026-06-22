const Printer = @This();
const std = @import("std");
const AST = @import("../ast.zig");
const json_string = @import("../util/json_string.zig");
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
/// rather than degrading to quoted strings. JSONC is plain JSON syntax (quoted
/// keys, normalized numbers) but, like JSON5, carries `//` and `/* */` comments.
dialect: Dialect = .json,

pub const Dialect = enum { json, jsonc, json5 };

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
    try p.leadingComments(ast.leadingCommentAnchor(ast.root), 0);
    try p.node(ast.root, 0);
    try p.rootTrailing();
    try writer.writeByte('\n');
    try writer.flush();
}

/// `printNode`, emitting JSON5.
pub fn printNode5(writer: *Writer, ast: *const AST, id: AST.Node.Id, depth: usize, options: AST.SerializeOptions) Error!void {
    var p: Printer = .{ .writer = writer, .ast = ast, .options = options, .dialect = .json5 };
    try p.node(id, depth);
}

/// `print`, emitting JSONC: plain-JSON syntax with `//`/`/* */` comments.
pub fn printc(writer: *Writer, ast: *const AST, options: AST.SerializeOptions) Error!void {
    var p: Printer = .{ .writer = writer, .ast = ast, .options = options, .dialect = .jsonc };
    try p.leadingComments(ast.leadingCommentAnchor(ast.root), 0);
    try p.node(ast.root, 0);
    try p.rootTrailing();
    try writer.writeByte('\n');
    try writer.flush();
}

/// Emit the root's trailing comment — but only when the root is a scalar. A
/// container root already emitted its own trailing beside its opening delimiter.
fn rootTrailing(self: *Printer) Error!void {
    const anchor = self.ast.trailingCommentAnchor(self.ast.root);
    if (!self.isContainer(anchor)) try self.trailingComment(anchor);
}

/// `printNode`, emitting JSONC.
pub fn printNodec(writer: *Writer, ast: *const AST, id: AST.Node.Id, depth: usize, options: AST.SerializeOptions) Error!void {
    var p: Printer = .{ .writer = writer, .ast = ast, .options = options, .dialect = .jsonc };
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
                try json_string.writeQuoted(self.writer, value.text),
            else => try json_string.writeQuoted(self.writer, value.text),
        },
        .string => |value| try json_string.writeQuoted(self.writer, value),
        .sequence => |first_child| try self.sequence(id, first_child, depth),
        .mapping => |first_child| try self.mapping(id, first_child, depth),
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

fn sequence(self: *Printer, node_id: AST.Node.Id, first_child: ?AST.Node.Id, depth: usize) Error!void {
    try self.container(node_id, '[', ']', first_child, depth);
}

fn mapping(self: *Printer, node_id: AST.Node.Id, first_child: ?AST.Node.Id, depth: usize) Error!void {
    try self.container(node_id, '{', '}', first_child, depth);
}

/// Sequences and mappings differ only in their delimiters and in how each child
/// renders (a bare node vs. a `key: value`), the latter dispatched by `node`.
fn container(self: *Printer, node_id: AST.Node.Id, open: u8, close: u8, first_child: ?AST.Node.Id, depth: usize) Error!void {
    // Dangling comments (orphans at the end of the body) force the block form so
    // they have somewhere to print; only an empty-and-comment-free container is
    // inline. Comments only print in pretty JSON5/JSONC, so an empty container
    // with dangling comments in a comment-less mode still prints inline.
    const dangling = if (self.commentsOn()) self.ast.comments(node_id).dangling else &.{};
    if (first_child == null and dangling.len == 0) {
        try self.writer.writeByte(open);
        try self.writer.writeByte(close);
        try self.trailingComment(node_id); // empty inline container: `[] // c`
        return;
    }

    const pretty = self.options.pretty;
    try self.writer.writeByte(open);
    // A container's own trailing comment rides the line it opened on, so it sits
    // beside the `[`/`{` (next to its key), not after the distant close.
    try self.trailingComment(node_id);
    if (pretty) try self.writer.writeByte('\n');

    var current_id = first_child;
    while (current_id) |id| {
        try self.leadingComments(self.ast.leadingCommentAnchor(id), depth + 1);
        if (pretty) try self.writeIndent(depth + 1);
        try self.node(id, depth + 1);
        current_id = self.ast.nodes[id].next_sibling;
        if (current_id != null) try self.writer.writeByte(',');
        // A scalar child's trailing prints here; a container child emits its own
        // (beside its opener, above), so skip it to avoid a double / misplacement.
        const anchor = self.ast.trailingCommentAnchor(id);
        if (!self.isContainer(anchor)) try self.trailingComment(anchor);
        if (pretty) try self.writer.writeByte('\n');
    }
    try self.danglingComments(dangling, depth + 1);

    if (pretty) try self.writeIndent(depth);
    try self.writer.writeByte(close);
}

/// Whether `id` is a container node (whose own trailing comment is emitted beside
/// its opening delimiter, not by its parent).
fn isContainer(self: *const Printer, id: AST.Node.Id) bool {
    return switch (self.ast.nodes[id].kind) {
        .sequence, .mapping => true,
        else => false,
    };
}

// ── comments (JSON5 only) ───────────────────────────────────────────────────
// Plain JSON has no comment syntax, so comments are emitted only in the JSON5
// dialect and only when pretty-printing (a `//` line comment can't survive on a
// minified single line). Both predicates are checked in the helpers, so callers
// can invoke them unconditionally.

/// True when comments may be emitted: a comment-bearing dialect (JSON5 or JSONC)
/// and multi-line output (a `//` can't survive on a minified single line).
fn commentsOn(self: *const Printer) bool {
    return (self.dialect == .json5 or self.dialect == .jsonc) and self.options.pretty;
}

/// Emit a node's leading comments, one per line at `depth`.
fn leadingComments(self: *Printer, id: AST.Node.Id, depth: usize) Error!void {
    if (!self.commentsOn()) return;
    for (self.ast.comments(id).leading) |c| {
        try self.writeIndent(depth);
        try self.writeComment(c);
        try self.writer.writeByte('\n');
    }
}

/// Emit a node's trailing comment (if any) after a leading space, no newline.
fn trailingComment(self: *Printer, id: AST.Node.Id) Error!void {
    if (!self.commentsOn()) return;
    if (self.ast.comments(id).trailing) |c| {
        try self.writer.writeByte(' ');
        try self.writeComment(c);
    }
}

/// Emit a container's dangling comments (end of body), one per line at `depth`.
/// The caller has already gated on `commentsOn` via the passed slice.
fn danglingComments(self: *Printer, dangling: []const AST.Comment, depth: usize) Error!void {
    for (dangling) |c| {
        try self.writeIndent(depth);
        try self.writeComment(c);
        try self.writer.writeByte('\n');
    }
}

/// Render one comment in JSON5 syntax. JSON5 has both forms, so the stored
/// `style` is honored directly with no degradation.
fn writeComment(self: *Printer, c: AST.Comment) Error!void {
    switch (c.style) {
        .line => {
            try self.writer.writeAll("//");
            if (c.text.len != 0) {
                try self.writer.writeByte(' ');
                try self.writer.writeAll(c.text);
            }
        },
        .block => {
            try self.writer.writeAll("/*");
            if (c.text.len != 0) {
                try self.writer.writeByte(' ');
                try self.writer.writeAll(c.text);
                try self.writer.writeByte(' ');
            }
            try self.writer.writeAll("*/");
        },
    }
}

fn writeIndent(self: *Printer, depth: usize) Writer.Error!void {
    for (0..depth * self.options.indent) |_| try self.writer.writeByte(' ');
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

test "json5 emits leading and trailing comments; plain json drops them" {
    const a = std.testing.allocator;
    var b = AST.Builder.init(a);
    defer b.deinit();

    // { name: "fig" } with a leading line comment on the entry, a trailing line
    // comment on the value, and a leading block comment on the document.
    const v = try b.addString("fig");
    try b.setComments(v, .{ .trailing = .{ .text = "inline", .style = .line } });
    const k = try b.addString("name");
    try b.setComments(k, .{ .leading = &.{.{ .text = "greeting", .style = .line }} });
    const root = try b.addMapping(&.{.{ .key = k, .value = v }});
    try b.setComments(root, .{ .leading = &.{.{ .text = "doc", .style = .block }} });

    var ast = try b.finish(root);
    defer ast.deinit();

    var j5: Writer.Allocating = .init(a);
    defer j5.deinit();
    try print5(&j5.writer, &ast, .{});
    try std.testing.expectEqualStrings(
        \\/* doc */
        \\{
        \\  // greeting
        \\  name: "fig" // inline
        \\}
        \\
    , j5.written());

    // Plain JSON has no comment syntax: same AST emits clean JSON.
    var j: Writer.Allocating = .init(a);
    defer j.deinit();
    try print(&j.writer, &ast, .{});
    try std.testing.expectEqualStrings(
        \\{
        \\  "name": "fig"
        \\}
        \\
    , j.written());

    // Compact JSON5 also drops comments (a `//` can't survive one line).
    var c: Writer.Allocating = .init(a);
    defer c.deinit();
    try print5(&c.writer, &ast, .{ .pretty = false });
    try std.testing.expectEqualStrings("{name:\"fig\"}\n", c.written());
}

test "json5: a container value's trailing comment rides its opening bracket" {
    const Parser = @import("parser.zig");
    // `key: [ // note` round-trips: the comment stays beside the `[` (next to its
    // key), not after the distant `]`.
    const input =
        \\{
        \\  contents: [ // the note
        \\    "a",
        \\    "b"
        \\  ]
        \\}
    ;
    var doc = try Parser.parseAbstract(std.testing.allocator, input, .JSON5);
    defer doc.deinit();
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try print5(&out.writer, &doc, .{});
    try std.testing.expectEqualStrings(input ++ "\n", out.written());
}

test "json5: opening-line comment stays at top, closing-line at bottom" {
    const Parser = @import("parser.zig");
    // A comment on the `]` line is a bottom comment: it normalizes to the last
    // line of the body (before the close), distinct from the opening-line one.
    var doc = try Parser.parseAbstract(std.testing.allocator,
        \\{
        \\  a: [ // top
        \\    1
        \\  ],
        \\  b: [
        \\    2
        \\  ] // bottom
        \\}
    , .JSON5);
    defer doc.deinit();
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try print5(&out.writer, &doc, .{});
    try std.testing.expectEqualStrings(
        \\{
        \\  a: [ // top
        \\    1
        \\  ],
        \\  b: [
        \\    2
        \\    // bottom
        \\  ]
        \\}
        \\
    , out.written());
}

test "jsonc emits comments with quoted keys (unlike json5)" {
    const a = std.testing.allocator;
    var b = AST.Builder.init(a);
    defer b.deinit();

    const v = try b.addString("fig");
    try b.setComments(v, .{ .trailing = .{ .text = "inline", .style = .line } });
    const k = try b.addString("name");
    try b.setComments(k, .{ .leading = &.{.{ .text = "greeting", .style = .block }} });
    const root = try b.addMapping(&.{.{ .key = k, .value = v }});

    var ast = try b.finish(root);
    defer ast.deinit();

    var out: Writer.Allocating = .init(a);
    defer out.deinit();
    try printc(&out.writer, &ast, .{});
    // JSON syntax (quoted key) + JSON5-style comments.
    try std.testing.expectEqualStrings(
        \\{
        \\  /* greeting */
        \\  "name": "fig" // inline
        \\}
        \\
    , out.written());
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
