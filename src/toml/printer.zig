//! TOML printer: renders a fig AST as canonical TOML.
//!
//! This is a *canonical* serializer, not a format-preserving round-tripper — the
//! editor (`editor.zig`) handles in-place, comment-preserving edits via source
//! spans. The printer takes a bare `*const AST` (no spans) and emits clean TOML.
//!
//! Structure mapping (the inverse of the parser):
//!   * the root mapping's scalar/array entries print as bare `key = value` lines;
//!   * a mapping value prints as a `[header.path]` section (so an inline-table
//!     value `p = {x=1}` canonicalizes to a `[p]` section — same AST);
//!   * a non-empty all-mapping sequence prints as `[[header.path]]` array-of-
//!     tables elements;
//!   * every other value (scalars, scalar/mixed arrays, empty arrays) prints
//!     inline, with nested mappings becoming inline tables `{ ... }`.
//!
//! A table's own header is suppressed when it has no direct inline entries but
//! does have sub-tables/AoTs (their headers imply it); an otherwise-empty table
//! still emits its `[header]` so its existence round-trips.
//!
//! TOML has no null, so a `null` value is `error.NullUnsupported` (e.g. a JSON
//! `null` cannot convert to TOML). `enum_literal`/`char_literal` extended scalars
//! (only minted by ZON) degrade to a string / integer; datetimes print verbatim.

const Printer = @This();
const std = @import("std");
const AST = @import("../ast.zig");
const Writer = std.Io.Writer;

/// TOML cannot represent a YAML alias (materialize expands them first), a null,
/// or a non-string table key.
pub const Error = Writer.Error || error{ NullUnsupported, NonStringKey, UnresolvedAlias };

/// A header path built on the call stack (one link per nesting level), rendered
/// parent-first so no allocation is needed to accumulate `a.b.c`.
const Path = struct {
    key: []const u8,
    parent: ?*const Path,
};

/// How a value renders inside its parent table body.
const Class = enum {
    /// `key = value` on one line (scalars, arrays, inline tables).
    inline_,
    /// `[header]` section (any mapping value).
    section,
    /// `[[header]]` array-of-tables (non-empty, all-mapping sequence).
    aot,
};

/// Document-emit state: `wrote` gates the blank line printed before each
/// section/AoT header (suppressed at the very start of the output).
const Ctx = struct {
    w: *Writer,
    wrote: bool = false,

    /// Emit a table's body: first every inline entry as `key = value`, then —
    /// after all of them, as TOML requires — each sub-table and array-of-tables
    /// with its own header. `path` is this table's header path (null at root).
    fn body(ctx: *Ctx, ast: *const AST, first_child: ?AST.Node.Id, path: ?*const Path) Error!void {
        var cur = first_child;
        while (cur) |id| : (cur = ast.nodes[id].next_sibling) {
            const kv = ast.nodes[id].kind.keyvalue;
            if (classify(ast, kv.value) != .inline_) continue;
            try ctx.kvLine(ast, kv.key, kv.value);
        }
        cur = first_child;
        while (cur) |id| : (cur = ast.nodes[id].next_sibling) {
            const kv = ast.nodes[id].kind.keyvalue;
            switch (classify(ast, kv.value)) {
                .inline_ => {},
                .section => try ctx.section(ast, kv.key, kv.value, path),
                .aot => try ctx.aot(ast, kv.key, kv.value, path),
            }
        }
    }

    fn kvLine(ctx: *Ctx, ast: *const AST, key_id: AST.Node.Id, value_id: AST.Node.Id) Error!void {
        try writeKey(ctx.w, ast, key_id);
        try ctx.w.writeAll(" = ");
        try writeInline(ctx.w, ast, value_id);
        try ctx.w.writeByte('\n');
        ctx.wrote = true;
    }

    fn section(ctx: *Ctx, ast: *const AST, key_id: AST.Node.Id, value_id: AST.Node.Id, parent: ?*const Path) Error!void {
        const seg = Path{ .key = try keyText(ast, key_id), .parent = parent };
        const first = ast.nodes[value_id].kind.mapping;
        if (needsHeader(ast, first)) {
            if (ctx.wrote) try ctx.w.writeByte('\n');
            try ctx.w.writeByte('[');
            try writePath(ctx.w, &seg);
            try ctx.w.writeAll("]\n");
            ctx.wrote = true;
        }
        try ctx.body(ast, first, &seg);
    }

    fn aot(ctx: *Ctx, ast: *const AST, key_id: AST.Node.Id, value_id: AST.Node.Id, parent: ?*const Path) Error!void {
        const seg = Path{ .key = try keyText(ast, key_id), .parent = parent };
        var elem = ast.nodes[value_id].kind.sequence;
        while (elem) |eid| : (elem = ast.nodes[eid].next_sibling) {
            if (ctx.wrote) try ctx.w.writeByte('\n');
            try ctx.w.writeAll("[[");
            try writePath(ctx.w, &seg);
            try ctx.w.writeAll("]]\n");
            ctx.wrote = true;
            try ctx.body(ast, ast.nodes[eid].kind.mapping, &seg);
        }
    }
};

/// Whether a section emits its own `[header]`: yes when empty (records its
/// existence) or when it has at least one direct inline entry; no when it has
/// only sub-tables/AoTs (whose own headers imply this table).
fn needsHeader(ast: *const AST, first_child: ?AST.Node.Id) bool {
    var cur = first_child orelse return true; // empty table
    while (true) {
        const kv = ast.nodes[cur].kind.keyvalue;
        if (classify(ast, kv.value) == .inline_) return true;
        cur = ast.nodes[cur].next_sibling orelse return false;
    }
}

fn classify(ast: *const AST, value_id: AST.Node.Id) Class {
    return switch (ast.nodes[value_id].kind) {
        .mapping => .section,
        .sequence => |first| if (allMappings(ast, first)) .aot else .inline_,
        else => .inline_,
    };
}

/// True for a non-empty sequence whose every element is a mapping — the shape
/// TOML writes as `[[array.of.tables]]`.
fn allMappings(ast: *const AST, first: ?AST.Node.Id) bool {
    var cur = first orelse return false;
    while (true) {
        if (ast.nodes[cur].kind != .mapping) return false;
        cur = ast.nodes[cur].next_sibling orelse return true;
    }
}

// ── Inline value rendering ──────────────────────────────────────────────────

fn writeInline(w: *Writer, ast: *const AST, id: AST.Node.Id) Error!void {
    switch (ast.nodes[id].kind) {
        .null_ => return error.NullUnsupported,
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .number => |n| try w.writeAll(n.raw),
        .string => |s| try writeBasicString(w, s),
        .extended => |ext| try writeExtended(w, ext),
        .sequence => |first| try writeInlineArray(w, ast, first),
        .mapping => |first| try writeInlineTable(w, ast, first),
        .keyvalue => unreachable, // a keyvalue is never a value position
        .alias => return error.UnresolvedAlias,
    }
}

fn writeInlineArray(w: *Writer, ast: *const AST, first: ?AST.Node.Id) Error!void {
    if (first == null) {
        try w.writeAll("[]");
        return;
    }
    try w.writeByte('[');
    var cur = first;
    while (cur) |id| {
        try writeInline(w, ast, id);
        cur = ast.nodes[id].next_sibling;
        if (cur != null) try w.writeAll(", ");
    }
    try w.writeByte(']');
}

fn writeInlineTable(w: *Writer, ast: *const AST, first: ?AST.Node.Id) Error!void {
    if (first == null) {
        try w.writeAll("{}");
        return;
    }
    try w.writeAll("{ ");
    var cur = first;
    while (cur) |id| {
        const kv = ast.nodes[id].kind.keyvalue;
        try writeKey(w, ast, kv.key);
        try w.writeAll(" = ");
        try writeInline(w, ast, kv.value);
        cur = ast.nodes[id].next_sibling;
        if (cur != null) try w.writeAll(", ");
    }
    try w.writeAll(" }");
}

/// Render an `extended` scalar. Datetimes print verbatim (their text is already
/// valid TOML). An `enum_literal` (ZON-only) has no TOML form, so it degrades to
/// a string; a `char_literal`'s text is a decimal codepoint, valid as an integer.
fn writeExtended(w: *Writer, ext: AST.Node.Kind.Extended) Error!void {
    switch (ext.kind) {
        .offset_datetime, .local_datetime, .local_date, .local_time => try w.writeAll(ext.text),
        .enum_literal => try writeBasicString(w, ext.text),
        .char_literal => try w.writeAll(ext.text),
    }
}

// ── Keys and strings ────────────────────────────────────────────────────────

fn keyText(ast: *const AST, key_id: AST.Node.Id) Error![]const u8 {
    return switch (ast.nodes[key_id].kind) {
        .string => |s| s,
        else => error.NonStringKey,
    };
}

/// A key prints bare when non-empty and all of `[A-Za-z0-9_-]`, else quoted.
fn writeKey(w: *Writer, ast: *const AST, key_id: AST.Node.Id) Error!void {
    const name = try keyText(ast, key_id);
    if (isBareKey(name)) {
        try w.writeAll(name);
    } else {
        try writeBasicString(w, name);
    }
}

fn isBareKey(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        const ok = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

/// Render a header path (`a.b.c`), parent segment first.
fn writePath(w: *Writer, path: *const Path) Error!void {
    if (path.parent) |par| {
        try writePath(w, par);
        try w.writeByte('.');
    }
    if (isBareKey(path.key)) {
        try w.writeAll(path.key);
    } else {
        try writeBasicString(w, path.key);
    }
}

/// Emit a TOML basic string: double-quoted, with `"`, `\`, and control bytes
/// escaped (TOML keeps other Unicode literal).
fn writeBasicString(w: *Writer, value: []const u8) Writer.Error!void {
    try w.writeByte('"');
    for (value) |char| {
        switch (char) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            0x08 => try w.writeAll("\\b"),
            '\t' => try w.writeAll("\\t"),
            '\n' => try w.writeAll("\\n"),
            0x0c => try w.writeAll("\\f"),
            '\r' => try w.writeAll("\\r"),
            0x00...0x07, 0x0b, 0x0e...0x1f, 0x7f => try writeUnicodeEscape(w, char),
            else => try w.writeByte(char),
        }
    }
    try w.writeByte('"');
}

fn writeUnicodeEscape(w: *Writer, char: u8) Writer.Error!void {
    const hex = "0123456789ABCDEF";
    try w.writeAll("\\u00");
    try w.writeByte(hex[char >> 4]);
    try w.writeByte(hex[char & 0x0f]);
}

// ── Public entry points ─────────────────────────────────────────────────────

pub fn print(writer: *Writer, ast: *const AST) Error!void {
    var ctx = Ctx{ .w = writer };
    switch (ast.nodes[ast.root].kind) {
        .mapping => |first| try ctx.body(ast, first, null),
        // A non-table root (e.g. converting a JSON array) has no valid TOML
        // document form; emit the inline value as a best-effort fragment.
        else => {
            try writeInline(writer, ast, ast.root);
            try writer.writeByte('\n');
        },
    }
    try writer.flush();
}

/// Print the subtree at `id` as a standalone fragment (used by `get <path>`): a
/// mapping prints as a document body rooted there; any other node prints inline.
pub fn printNode(writer: *Writer, ast: *const AST, id: AST.Node.Id, depth: usize) Error!void {
    _ = depth;
    var ctx = Ctx{ .w = writer };
    switch (ast.nodes[id].kind) {
        .mapping => |first| try ctx.body(ast, first, null),
        else => {
            try writeInline(writer, ast, id);
            try writer.writeByte('\n');
        },
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────

const Parser = @import("parser.zig");

fn expectPrint(input: []const u8, expected: []const u8) !void {
    var ast = try Parser.parseAbstract(std.testing.allocator, input, .TOML_1_1);
    defer ast.deinit();
    var output: Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try print(&output.writer, &ast);
    try std.testing.expectEqualStrings(expected, output.written());
}

/// Round-trip: the printed TOML must reparse to an AST equal to the original.
fn expectRoundTrip(input: []const u8) !void {
    var ast = try Parser.parseAbstract(std.testing.allocator, input, .TOML_1_1);
    defer ast.deinit();
    var output: Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try print(&output.writer, &ast);

    var reparsed = try Parser.parseAbstract(std.testing.allocator, output.written(), .TOML_1_1);
    defer reparsed.deinit();
    errdefer std.log.err("printed:\n{s}", .{output.written()});
    try std.testing.expect(ast.eql(reparsed));
}

test "prints root scalars" {
    try expectPrint(
        \\name = "Tom"
        \\count = 42
        \\pi = 3.14
        \\flag = true
        \\
    ,
        \\name = "Tom"
        \\count = 42
        \\pi = 3.14
        \\flag = true
        \\
    );
}

test "canonicalizes numbers" {
    try expectPrint("hex = 0xDEAD_beef\noct = 0o17\nneg = -0\n", "hex = 3735928559\noct = 15\nneg = 0\n");
}

test "datetimes print verbatim" {
    try expectPrint("when = 1979-05-27T07:32:00Z\nd = 1979-05-27\nt = 07:32:00\n", "when = 1979-05-27T07:32:00Z\nd = 1979-05-27\nt = 07:32:00\n");
}

test "nested table becomes a header section" {
    try expectPrint(
        \\[server]
        \\host = "a"
        \\port = 80
        \\
    ,
        \\[server]
        \\host = "a"
        \\port = 80
        \\
    );
}

test "scalars precede sub-tables and blank-line separates" {
    try expectPrint(
        \\[a]
        \\x = 1
        \\[a.b]
        \\y = 2
        \\
    ,
        \\[a]
        \\x = 1
        \\
        \\[a.b]
        \\y = 2
        \\
    );
}

test "supertable header is suppressed when it has only sub-tables" {
    try expectPrint(
        \\[a.b]
        \\y = 2
        \\
    ,
        \\[a.b]
        \\y = 2
        \\
    );
}

test "empty table still emits its header" {
    try expectPrint("[a]\n", "[a]\n");
}

test "inline table canonicalizes to a section" {
    try expectPrint("point = { x = 1, y = 2 }\n", "[point]\nx = 1\ny = 2\n");
}

test "arrays of scalars print inline" {
    try expectPrint("nums = [1, 2, 3]\nnested = [[1, 2], [\"a\", \"b\"]]\n", "nums = [1, 2, 3]\nnested = [[1, 2], [\"a\", \"b\"]]\n");
}

test "array of tables prints as double-bracket sections" {
    try expectPrint(
        \\[[fruit]]
        \\name = "apple"
        \\
        \\[[fruit]]
        \\name = "pear"
        \\
    ,
        \\[[fruit]]
        \\name = "apple"
        \\
        \\[[fruit]]
        \\name = "pear"
        \\
    );
}

test "quotes non-bare keys" {
    try expectPrint("\"a.b\" = 1\n\"\" = 2\n", "\"a.b\" = 1\n\"\" = 2\n");
}

test "escapes control characters in strings" {
    try expectPrint("s = \"a\\tb\\nc\"\n", "s = \"a\\tb\\nc\"\n");
}

test "null value is unsupported" {
    // Build an AST with a null by hand (TOML never parses one).
    var nodes = [_]AST.Node{
        .{ .id = 0, .kind = .{ .mapping = 1 } },
        .{ .id = 1, .kind = .{ .keyvalue = .{ .key = 2, .value = 3 } } },
        .{ .id = 2, .kind = .{ .string = "k" } },
        .{ .id = 3, .kind = .null_ },
    };
    const ast = AST{ .allocator = std.testing.allocator, .root = 0, .nodes = &nodes };
    var output: Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try std.testing.expectError(error.NullUnsupported, print(&output.writer, &ast));
}

// Round-trips across the structural features.
test "round-trips a mixed document" {
    try expectRoundTrip(
        \\title = "demo"
        \\ports = [8000, 8001]
        \\
        \\[owner]
        \\name = "Tom"
        \\dob = 1979-05-27T07:32:00Z
        \\
        \\[servers.alpha]
        \\ip = "10.0.0.1"
        \\
        \\[servers.beta]
        \\ip = "10.0.0.2"
        \\
        \\[[products]]
        \\name = "Hammer"
        \\sku = 738594937
        \\
        \\[[products]]
        \\name = "Nail"
        \\color = "gray"
        \\
    );
}

test "round-trips nested arrays of tables" {
    try expectRoundTrip(
        \\[[a]]
        \\x = 1
        \\
        \\[[a.b]]
        \\y = 2
        \\
        \\[[a.b]]
        \\y = 3
        \\
    );
}

test "round-trips deeply nested empty and dotted tables" {
    try expectRoundTrip(
        \\a.b.c = 1
        \\
        \\[x]
        \\
        \\[x.y.z]
        \\w = "deep"
        \\
    );
}
