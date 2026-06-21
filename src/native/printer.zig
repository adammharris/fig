//! The native "fig" printer: a total, 1:1 text encoding of the AST.
//!
//! Unlike the format printers (JSON/YAML/TOML/ZON), this one is a *bijection*
//! with the AST — every `Node.Kind` arm and the YAML reference layer (anchors,
//! tags, aliases) has an unambiguous surface form, so any AST round-trips
//! through it unchanged. It is the default/debug representation and the
//! comparison oracle: canonicalize two documents to native text and `strcmp`.
//!
//! Grammar (informal):
//!   node      ::= prefix* value
//!   prefix    ::= '&' name  |  '!' tagtext        (anchor / tag, space-separated)
//!   value     ::= 'null' | 'true' | 'false'
//!               | string                          ("…", JSON escapes)
//!               | number                          (raw lexeme, see `number`)
//!               | '@' extkind ' ' string          (extended scalar)
//!               | '[' (node (',' node)*)? ']'     (sequence)
//!               | '{' (node ':' node (',' …)*)? '}'  (mapping; keys are nodes)
//!               | '*' name                        (alias)
//!
//! A `number`'s `kind` (integer vs float) is normally implied by its lexeme. On
//! the rare node whose stored kind disagrees with the lexeme (constructible via
//! `AST.Builder.addNumberRaw`), a `~i`/`~f` sigil pins it. Common data never
//! triggers it.

const Printer = @This();
const std = @import("std");
const AST = @import("../ast.zig");
const json_string = @import("../util/json_string.zig");
const Writer = std.Io.Writer;

/// The native encoding is total over every AST *node kind* — it rejects no
/// variant. The only failures are the underlying writer's and `NestingTooDeep`,
/// a recursion guard: a pathologically nested AST (e.g. a fuzzer feeding the
/// oracle, or a hand-built `Builder` tree) would otherwise overflow the stack.
/// `max_depth` matches the native parser's guard, so any AST the parser accepts
/// prints without hitting it.
pub const Error = Writer.Error || error{NestingTooDeep};

/// Maximum container-nesting depth, shared with `native/parser.zig`. Bounds the
/// recursion in both directions of the bijection.
pub const max_depth = 512;

writer: *Writer,
ast: *const AST,

/// Spaces per indentation level. The native encoding is a canonical oracle —
/// one document has exactly one spelling — so this is a fixed constant, not a
/// knob: a configurable canonical form would defeat the comparison oracle.
const indent_width = 2;

/// Print the whole AST to `writer`, with a trailing newline, and flush.
pub fn print(writer: *Writer, ast: *const AST) Error!void {
    var p: Printer = .{ .writer = writer, .ast = ast };
    try p.node(ast.root, 0);
    try writer.writeByte('\n');
    try writer.flush();
}

/// Print the subtree rooted at `id`. Adds no trailing newline and does not
/// flush (used for partial renders and by `print`).
pub fn printNode(writer: *Writer, ast: *const AST, id: AST.Node.Id, depth: usize) Error!void {
    var p: Printer = .{ .writer = writer, .ast = ast };
    try p.node(id, depth);
}

fn node(self: *Printer, id: AST.Node.Id, depth: usize) Error!void {
    try self.prefixes(id);
    const n = self.ast.nodes[id];
    switch (n.kind) {
        .null_ => try self.writer.writeAll("null"),
        .boolean => |value| try self.writer.writeAll(if (value) "true" else "false"),
        .number => |value| try self.number(value),
        .string => |value| try json_string.writeQuoted(self.writer, value),
        .extended => |value| {
            try self.writer.writeByte('@');
            try self.writer.writeAll(@tagName(value.kind));
            try self.writer.writeByte(' ');
            try json_string.writeQuoted(self.writer, value.text);
        },
        .alias => |name| {
            try self.writer.writeByte('*');
            try self.writer.writeAll(name);
        },
        .sequence => |first_child| try self.container('[', ']', first_child, depth),
        .mapping => |first_child| try self.container('{', '}', first_child, depth),
        .keyvalue => |kv| {
            try self.node(kv.key, depth);
            try self.writer.writeAll(": ");
            try self.node(kv.value, depth);
        },
    }
}

/// Emit the YAML reference-layer prefixes attached to this node id: an anchor
/// (`&name `) and/or a tag (`!!str `). Both are stored in side-tables that are
/// empty for non-YAML documents, so the length guard short-circuits there.
fn prefixes(self: *Printer, id: AST.Node.Id) Error!void {
    const a = self.ast;
    if (id < a.node_anchors.len) if (a.node_anchors[id]) |name| {
        try self.writer.writeByte('&');
        try self.writer.writeAll(name);
        try self.writer.writeByte(' ');
    };
    // `node_tags` stores the tag verbatim, leading `!` included (e.g. `!!str`).
    if (id < a.node_tags.len) if (a.node_tags[id]) |tag| {
        try self.writer.writeAll(tag);
        try self.writer.writeByte(' ');
    };
}

/// Render a number's raw lexeme verbatim. If the lexeme's implied kind disagrees
/// with the stored kind, prefix `~i`/`~f` so the parser can restore it exactly.
fn number(self: *Printer, value: AST.Node.Kind.Number) Error!void {
    if (impliedNumberKind(value.raw) != value.kind) {
        try self.writer.writeAll(if (value.kind == .float) "~f" else "~i");
    }
    try self.writer.writeAll(value.raw);
}

/// Classify a numeric lexeme the same way the JSON parser's `getNumber` does, so
/// a bare number round-trips to the same `kind`. Hex (`0x…`) is an integer; a
/// dot or an `e`/`E` exponent makes it a float; otherwise integer. Total (never
/// errors): a malformed lexeme that can't come from a printer is treated as the
/// nearest of the two.
pub fn impliedNumberKind(raw: []const u8) @TypeOf(@as(AST.Node.Kind.Number, undefined).kind) {
    const body = if (raw.len > 0 and (raw[0] == '+' or raw[0] == '-')) raw[1..] else raw;
    if (body.len >= 2 and body[0] == '0' and (body[1] == 'x' or body[1] == 'X')) return .integer;
    if (std.mem.indexOfScalar(u8, raw, '.') != null) return .float;
    if (std.mem.indexOfAny(u8, raw, "eE") != null) return .float;
    return .integer;
}

/// Sequences and mappings differ only in delimiters and in how each child
/// renders (a bare node vs. a `key: value`), the latter handled by `node`.
fn container(self: *Printer, open: u8, close: u8, first_child: ?AST.Node.Id, depth: usize) Error!void {
    if (first_child == null) {
        try self.writer.writeByte(open);
        try self.writer.writeByte(close);
        return;
    }
    // Guard the recursion below; an empty container (above) never descends.
    if (depth >= max_depth) return error.NestingTooDeep;
    try self.writer.writeByte(open);
    try self.writer.writeByte('\n');
    var current_id = first_child;
    while (current_id) |id| {
        try self.writeIndent(depth + 1);
        try self.node(id, depth + 1);
        current_id = self.ast.nodes[id].next_sibling;
        if (current_id != null) try self.writer.writeByte(',');
        try self.writer.writeByte('\n');
    }
    try self.writeIndent(depth);
    try self.writer.writeByte(close);
}

fn writeIndent(self: *Printer, depth: usize) Error!void {
    try self.writer.splatByteAll(' ', depth * indent_width);
}

// Strings are quoted/escaped by the shared `json_string.writeQuoted` (the native
// parser's escape decoder accepts exactly that set).

// =======
// Testing
// =======

test "prints scalars, sequences, and mappings 1:1" {
    const Parser = @import("parser.zig");
    var ast = try Parser.parseAbstract(std.testing.allocator,
        \\{ "name": "fig", "port": 8080, "ratio": 1.0, "tags": ["a", true, null] }
    );
    defer ast.deinit();

    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try print(&out.writer, &ast);
    try std.testing.expectEqualStrings(
        \\{
        \\  "name": "fig",
        \\  "port": 8080,
        \\  "ratio": 1.0,
        \\  "tags": [
        \\    "a",
        \\    true,
        \\    null
        \\  ]
        \\}
        \\
    , out.written());
}

test "prints empty containers inline" {
    const Parser = @import("parser.zig");
    var ast = try Parser.parseAbstract(std.testing.allocator, "{ \"a\": [], \"b\": {} }");
    defer ast.deinit();

    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try print(&out.writer, &ast);
    try std.testing.expectEqualStrings(
        \\{
        \\  "a": [],
        \\  "b": {}
        \\}
        \\
    , out.written());
}

test "bounds nesting depth" {
    const a = std.testing.allocator;
    // Build `levels` nested one-element sequences around an empty innermost seq.
    const nest = struct {
        fn build(alloc: std.mem.Allocator, levels: usize) !AST {
            var b = AST.Builder.init(alloc);
            errdefer b.deinit();
            // Innermost holds a scalar so it isn't the empty-container fast path
            // (which prints inline and never recurses, escaping the guard).
            var id = try b.addSequence(&.{try b.addNull()}); // 1 level
            for (1..levels) |_| id = try b.addSequence(&.{id});
            const ast = try b.finish(id);
            b.deinit();
            return ast;
        }
    }.build;

    var out: Writer.Allocating = .init(a);
    defer out.deinit();

    // Exactly `max_depth` levels prints; one deeper is rejected, not a crash.
    var ok = try nest(a, max_depth);
    defer ok.deinit();
    try print(&out.writer, &ok);

    var too_deep = try nest(a, max_depth + 1);
    defer too_deep.deinit();
    try std.testing.expectError(error.NestingTooDeep, print(&out.writer, &too_deep));
}
