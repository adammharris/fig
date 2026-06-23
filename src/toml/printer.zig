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
const AST = @import("../ast/ast.zig");
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
/// section/AoT header (suppressed at the very start of the output); `opts`
/// carries the width budget / indent / pretty knobs that drive the
/// inline-vs-expanded layout decisions below.
const Ctx = struct {
    w: *Writer,
    opts: AST.SerializeOptions,
    wrote: bool = false,

    /// Emit a table's body: first every inline entry as `key = value`, then —
    /// after all of them, as TOML requires — each sub-table and array-of-tables
    /// with its own header. `path` is this table's header path (null at root).
    fn body(ctx: *Ctx, ast: *const AST, node_id: AST.Node.Id, first_child: ?AST.Node.Id, path: ?*const Path) Error!void {
        var cur = first_child;
        while (cur) |id| : (cur = ast.nodes[id].next_sibling) {
            if (classify(ctx, ast, id) != .inline_) continue;
            const kv = ast.nodes[id].kind.keyvalue;
            try ctx.kvLine(ast, kv.key, kv.value);
        }
        // Comments dangling at the end of this table's own lines (after its
        // inline entries, before any sub-tables).
        for (ast.comments(node_id).dangling) |c| {
            var it = std.mem.splitScalar(u8, c.text, '\n');
            while (it.next()) |line| {
                try writeHashLine(ctx.w, std.mem.trim(u8, line, " \t"));
                try ctx.w.writeByte('\n');
            }
            ctx.wrote = true;
        }
        cur = first_child;
        while (cur) |id| : (cur = ast.nodes[id].next_sibling) {
            const kv = ast.nodes[id].kind.keyvalue;
            switch (classify(ctx, ast, id)) {
                .inline_ => {},
                .section => try ctx.section(ast, kv.key, kv.value, path),
                .aot => try ctx.aot(ast, kv.key, kv.value, path),
            }
        }
    }

    fn kvLine(ctx: *Ctx, ast: *const AST, key_id: AST.Node.Id, value_id: AST.Node.Id) Error!void {
        try ctx.leading(ast, key_id);
        try writeKey(ctx.w, ast, key_id);
        try ctx.w.writeAll(" = ");
        const col = (keyByteLen(ast, key_id) orelse 0) + 3; // `key` + ` = `
        try ctx.writeValue(ast, value_id, col);
        try ctx.trailing(ast, value_id);
        try ctx.w.writeByte('\n');
        ctx.wrote = true;
    }

    /// Render a `key = value` right-hand side. A scalar/mixed array that would
    /// overflow `opts.width` (and `pretty` is set) wraps one element per line;
    /// everything else renders inline. (Mappings and array-of-tables that reach
    /// here already fit by construction — see `classify`.)
    fn writeValue(ctx: *Ctx, ast: *const AST, value_id: AST.Node.Id, col: usize) Error!void {
        switch (ast.nodes[value_id].kind) {
            .sequence => |first| {
                if (ctx.opts.pretty and first != null) {
                    // A null/alias inside makes the array un-measurable; fall
                    // through so `writeInline` surfaces the proper error.
                    if (inlineByteLen(ast, value_id)) |len| {
                        if (col + len > ctx.opts.width) return ctx.writeArrayMultiline(ast, first);
                    }
                }
                try writeInline(ctx.w, ast, value_id);
            },
            else => try writeInline(ctx.w, ast, value_id),
        }
    }

    /// Wrap an array across lines: `[`, then each element indented one level with
    /// a trailing comma, then `]` at column 0. Elements themselves render inline.
    fn writeArrayMultiline(ctx: *Ctx, ast: *const AST, first: ?AST.Node.Id) Error!void {
        const w = ctx.w;
        try w.writeAll("[\n");
        var cur = first;
        while (cur) |id| : (cur = ast.nodes[id].next_sibling) {
            try w.splatByteAll(' ', ctx.opts.indent);
            try writeInline(w, ast, id);
            try w.writeAll(",\n");
        }
        try w.writeByte(']');
    }

    fn section(ctx: *Ctx, ast: *const AST, key_id: AST.Node.Id, value_id: AST.Node.Id, parent: ?*const Path) Error!void {
        const seg = Path{ .key = try keyText(ast, key_id), .parent = parent };
        const first = ast.nodes[value_id].kind.mapping;
        if (needsHeader(ctx, ast, first)) {
            if (ctx.wrote) try ctx.w.writeByte('\n');
            try ctx.leading(ast, key_id); // comments above the `[header]` line
            try ctx.w.writeByte('[');
            try writePath(ctx.w, &seg);
            try ctx.w.writeAll("]\n");
            ctx.wrote = true;
        }
        try ctx.body(ast, value_id, first, &seg);
    }

    // ── Comments ──────────────────────────────────────────────────────────
    // TOML has only `#` line comments. A block comment carried from another
    // format degrades to a run of `#` lines (one per content line).

    /// Emit a key's leading comments above its line, at column 0.
    fn leading(ctx: *Ctx, ast: *const AST, key_id: AST.Node.Id) Error!void {
        for (ast.comments(key_id).leading) |c| {
            var it = std.mem.splitScalar(u8, c.text, '\n');
            while (it.next()) |line| {
                try writeHashLine(ctx.w, std.mem.trim(u8, line, " \t"));
                try ctx.w.writeByte('\n');
            }
            ctx.wrote = true;
        }
    }

    /// Emit a value's trailing comment after its line (` # …`). A multi-line
    /// block flattens to one line (newlines → spaces).
    fn trailing(ctx: *Ctx, ast: *const AST, value_id: AST.Node.Id) Error!void {
        const c = ast.comments(value_id).trailing orelse return;
        try ctx.w.writeAll(" #");
        if (c.text.len != 0) {
            try ctx.w.writeByte(' ');
            for (c.text) |ch| try ctx.w.writeByte(if (ch == '\n') ' ' else ch);
        }
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
            try ctx.body(ast, eid, ast.nodes[eid].kind.mapping, &seg);
        }
    }
};

/// Whether a section emits its own `[header]`: yes when empty (records its
/// existence) or when it has at least one direct inline entry; no when it has
/// only sub-tables/AoTs (whose own headers imply this table). Note an inline
/// table counts as a direct inline entry, so a table whose sub-mappings all
/// collapse to inline tables does regain its header.
fn needsHeader(ctx: *Ctx, ast: *const AST, first_child: ?AST.Node.Id) bool {
    var cur = first_child orelse return true; // empty table
    while (true) {
        if (classify(ctx, ast, cur) == .inline_) return true;
        cur = ast.nodes[cur].next_sibling orelse return false;
    }
}

/// Decide how a key/value entry renders. A mapping collapses to an inline table
/// (`{ ... }`) when `fitsInline` allows it, otherwise it expands to a
/// `[section]`. A non-empty all-mapping sequence is always an `[[array.of.tables]]`
/// (the block form reads better and is the conventional shape — we don't collapse
/// it even when it would fit). Scalars and scalar/mixed arrays are always
/// `inline_` (the array may still *wrap*, but it stays in place).
fn classify(ctx: *Ctx, ast: *const AST, kv_id: AST.Node.Id) Class {
    const kv = ast.nodes[kv_id].kind.keyvalue;
    return switch (ast.nodes[kv.value].kind) {
        .mapping => if (fitsInline(ctx, ast, kv_id)) .inline_ else .section,
        .sequence => |first| if (allMappings(ast, first)) .aot else .inline_,
        else => .inline_,
    };
}

/// Whether a mapping value should render inline (`k = { ... }`) rather than as a
/// `[section]`. Inlining is allowed only when the whole `key = value` line fits in
/// `opts.width`, the subtree carries no comments (the inline form can't emit them
/// — they'd be silently dropped), and the value isn't an empty mapping (kept as
/// `[header]` so the table's existence round-trips).
fn fitsInline(ctx: *Ctx, ast: *const AST, kv_id: AST.Node.Id) bool {
    const kv = ast.nodes[kv_id].kind.keyvalue;
    const value_id = kv.value;
    switch (ast.nodes[value_id].kind) {
        .mapping => |first| if (first == null) return false,
        else => {},
    }
    if (nodeHasComments(ast, kv_id)) return false;
    if (subtreeHasComments(ast, kv.key)) return false;
    if (subtreeHasComments(ast, value_id)) return false;
    const klen = keyByteLen(ast, kv.key) orelse return false;
    const vlen = inlineByteLen(ast, value_id) orelse return false;
    return klen + 3 + vlen <= ctx.opts.width; // `key` + ` = ` + value
}

// ── Width / comment measurement ─────────────────────────────────────────────
// The inline-layout decision measures a value's rendered width by printing it to
// a discarding writer with the very functions that emit the real output, so the
// estimate can never drift from what's actually written.

/// Rendered byte width of a value's inline form, or null if it can't be inlined
/// (a `null`/alias inside makes `writeInline` error).
fn inlineByteLen(ast: *const AST, id: AST.Node.Id) ?usize {
    var buf: [256]u8 = undefined;
    var disc = std.Io.Writer.Discarding.init(&buf);
    writeInline(&disc.writer, ast, id) catch return null;
    return @intCast(disc.fullCount());
}

/// Rendered byte width of a key (bare or quoted), or null for a non-string key.
fn keyByteLen(ast: *const AST, key_id: AST.Node.Id) ?usize {
    var buf: [128]u8 = undefined;
    var disc = std.Io.Writer.Discarding.init(&buf);
    writeKey(&disc.writer, ast, key_id) catch return null;
    return @intCast(disc.fullCount());
}

fn nodeHasComments(ast: *const AST, id: AST.Node.Id) bool {
    const c = ast.comments(id);
    return c.leading.len != 0 or c.trailing != null or c.dangling.len != 0;
}

/// Whether any node in the subtree rooted at `id` carries a comment. Used to keep
/// a commented mapping/array as an expanded section, where the printer can still
/// emit the comments (the inline `{ ... }` / `[ ... ]` forms cannot).
fn subtreeHasComments(ast: *const AST, id: AST.Node.Id) bool {
    if (nodeHasComments(ast, id)) return true;
    switch (ast.nodes[id].kind) {
        .sequence => |first| {
            var cur = first;
            while (cur) |e| : (cur = ast.nodes[e].next_sibling)
                if (subtreeHasComments(ast, e)) return true;
        },
        .mapping => |first| {
            var cur = first;
            while (cur) |kvid| : (cur = ast.nodes[kvid].next_sibling) {
                if (nodeHasComments(ast, kvid)) return true;
                const kv = ast.nodes[kvid].kind.keyvalue;
                if (subtreeHasComments(ast, kv.key)) return true;
                if (subtreeHasComments(ast, kv.value)) return true;
            }
        },
        else => {},
    }
    return false;
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
        // JSON5 `Infinity`/`NaN` map onto TOML's native lowercase float forms.
        .number_special => try w.writeAll(tomlSpecial(ext.text)),
    }
}

/// Map a JSON5 non-finite lexeme (`Infinity`, `-Infinity`, `+Infinity`, `NaN`,
/// `-NaN`, `+NaN`) to its TOML float spelling (`inf`/`-inf`/`+inf`/`nan`).
fn tomlSpecial(text: []const u8) []const u8 {
    if (std.mem.endsWith(u8, text, "NaN")) {
        return if (text.len > 0 and text[0] == '-') "-nan" else if (text.len > 0 and text[0] == '+') "+nan" else "nan";
    }
    if (std.mem.startsWith(u8, text, "-")) return "-inf";
    if (std.mem.startsWith(u8, text, "+")) return "+inf";
    return "inf";
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

/// Write `# text` (or a bare `#` for an empty comment).
fn writeHashLine(w: *Writer, text: []const u8) Writer.Error!void {
    try w.writeByte('#');
    if (text.len != 0) {
        try w.writeByte(' ');
        try w.writeAll(text);
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

pub fn print(writer: *Writer, ast: *const AST, options: AST.SerializeOptions) Error!void {
    var ctx = Ctx{ .w = writer, .opts = options };
    switch (ast.nodes[ast.root].kind) {
        .mapping => |first| try ctx.body(ast, ast.root, first, null),
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
pub fn printNode(writer: *Writer, ast: *const AST, id: AST.Node.Id, depth: usize, options: AST.SerializeOptions) Error!void {
    _ = depth;
    var ctx = Ctx{ .w = writer, .opts = options };
    switch (ast.nodes[id].kind) {
        .mapping => |first| try ctx.body(ast, id, first, null),
        else => {
            try writeInline(writer, ast, id);
            try writer.writeByte('\n');
        },
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────

const Parser = @import("parser.zig");

fn expectPrint(input: []const u8, expected: []const u8) !void {
    try expectPrintWith(input, expected, .{});
}

fn expectPrintWith(input: []const u8, expected: []const u8, options: AST.SerializeOptions) !void {
    var ast = try Parser.parseAbstract(std.testing.allocator, input, .TOML_1_1);
    defer ast.deinit();
    var output: Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try print(&output.writer, &ast, options);
    try std.testing.expectEqualStrings(expected, output.written());
}

/// Round-trip: the printed TOML must reparse without error, and the canonical
/// form must be a fixed point — re-printing the reparse yields identical bytes.
/// (We can't compare ASTs directly: `AST.eql` is structural-identity on node ids,
/// which canonicalization to inline tables intentionally changes even though the
/// data is preserved. Idempotency is the right invariant for a canonical printer.)
fn expectRoundTrip(input: []const u8) !void {
    var ast = try Parser.parseAbstract(std.testing.allocator, input, .TOML_1_1);
    defer ast.deinit();
    var out1: Writer.Allocating = .init(std.testing.allocator);
    defer out1.deinit();
    try print(&out1.writer, &ast, .{});

    var reparsed = try Parser.parseAbstract(std.testing.allocator, out1.written(), .TOML_1_1);
    defer reparsed.deinit();
    var out2: Writer.Allocating = .init(std.testing.allocator);
    defer out2.deinit();
    errdefer std.log.err("printed:\n{s}", .{out1.written()});
    try print(&out2.writer, &reparsed, .{});
    try std.testing.expectEqualStrings(out1.written(), out2.written());
}

test "captures and re-emits comments (leading, trailing, table header)" {
    try expectPrint(
        \\# document header
        \\name = "Tom" # the name
        \\count = 42
        \\
        \\# the server section
        \\[server]
        \\host = "a" # primary host
        \\
    ,
        \\# document header
        \\name = "Tom" # the name
        \\count = 42
        \\
        \\# the server section
        \\[server]
        \\host = "a" # primary host
        \\
    );
}

test "block comment carried in degrades to a # run" {
    const a = std.testing.allocator;
    var b = AST.Builder.init(a);
    defer b.deinit();
    const v = try b.addInt(1);
    const k = try b.addString("x");
    try b.setComments(k, .{ .leading = &.{.{ .text = "line one\nline two", .style = .block }} });
    const root = try b.addMapping(&.{.{ .key = k, .value = v }});
    var ast = try b.finish(root);
    defer ast.deinit();
    var out: Writer.Allocating = .init(a);
    defer out.deinit();
    try print(&out.writer, &ast, .{});
    try std.testing.expectEqualStrings("# line one\n# line two\nx = 1\n", out.written());
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

test "a small table collapses to an inline table" {
    try expectPrint(
        \\[server]
        \\host = "a"
        \\port = 80
        \\
    ,
        \\server = { host = "a", port = 80 }
        \\
    );
}

test "a table too wide for the budget stays a [section]" {
    // The same table forced to expand by a tight width budget.
    try expectPrintWith(
        \\[server]
        \\host = "a"
        \\port = 80
        \\
    ,
        \\[server]
        \\host = "a"
        \\port = 80
        \\
    , .{ .width = 20 });
}

test "a table carrying a comment stays a [section]" {
    // Inlining would drop the comment, so the table keeps its header form.
    try expectPrint(
        \\[server]
        \\host = "a" # primary
        \\port = 80
        \\
    ,
        \\[server]
        \\host = "a" # primary
        \\port = 80
        \\
    );
}

test "scalars precede sub-tables and blank-line separates (when expanded)" {
    // A tight budget keeps `[a]` and `[a.b]` from collapsing inline, exercising
    // the scalars-before-subtables ordering and the blank-line separator.
    try expectPrintWith(
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
    , .{ .width = 8 });
}

test "supertable header is suppressed when it has only sub-tables" {
    // A tight budget keeps `b` expanded, so `a` has only the sub-table `b` and
    // its own header is implied (suppressed) — printing `[a.b]` directly.
    try expectPrintWith(
        \\[a.b]
        \\y = 2
        \\
    ,
        \\[a.b]
        \\y = 2
        \\
    , .{ .width = 8 });
}

test "empty table still emits its header" {
    try expectPrint("[a]\n", "[a]\n");
}

test "a small inline table stays inline (within the budget)" {
    try expectPrint("point = { x = 1, y = 2 }\n", "point = { x = 1, y = 2 }\n");
}

test "a wide inline table expands to a section" {
    try expectPrintWith(
        "point = { x = 1, y = 2 }\n",
        "[point]\nx = 1\ny = 2\n",
        .{ .width = 10 },
    );
}

test "arrays of scalars print inline" {
    try expectPrint("nums = [1, 2, 3]\nnested = [[1, 2], [\"a\", \"b\"]]\n", "nums = [1, 2, 3]\nnested = [[1, 2], [\"a\", \"b\"]]\n");
}

test "a wide array wraps one element per line with a trailing comma" {
    try expectPrintWith(
        "members = [\"alpha\", \"beta\", \"gamma\"]\n",
        \\members = [
        \\  "alpha",
        \\  "beta",
        \\  "gamma",
        \\]
        \\
    ,
        .{ .width = 20 },
    );
}

test "pretty=false keeps a wide array on one line" {
    try expectPrintWith(
        "members = [\"alpha\", \"beta\", \"gamma\"]\n",
        "members = [\"alpha\", \"beta\", \"gamma\"]\n",
        .{ .width = 20, .pretty = false },
    );
}

test "wrapped-array indent honors the indent option" {
    try expectPrintWith(
        "xs = [1, 2]\n",
        "xs = [\n  1,\n  2,\n]\n",
        .{ .width = 4, .indent = 2 },
    );
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
    try std.testing.expectError(error.NullUnsupported, print(&output.writer, &ast, .{}));
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
