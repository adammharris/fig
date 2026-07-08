//! plist printer: renders a fig AST as an XML property list — the documented
//! inverse of the reader (`parser.zig`). Read that file's header first; this
//! one mirrors its data model exactly, in reverse:
//!
//!   * `mapping` → `<dict>` of alternating `<key>`/value pairs (a mapping key
//!     must be a string — `error.NonStringKey` otherwise).
//!   * `sequence` → `<array>` of the same items, in order.
//!   * `string`/`number`(integer|float)/`boolean` → `<string>`/`<integer>`/
//!     `<real>`/`<true/>`/`<false/>`.
//!   * `extended` → `<date>`/`<data>` for plist's own two kinds
//!     (`ExtKind.plist_date`/`.plist_data`); any OTHER extended kind reaching
//!     here from a foreign AST (a TOML datetime, a ZON enum/char literal, a
//!     JSON5 non-finite float) has no dedicated plist primitive and degrades
//!     to a plain `<string>` of its text — the same blanket treatment XML's
//!     printer gives every scalar type it has no primitive for.
//!   * `null` has no plist type at all — `error.NullUnsupported` (same
//!     convention as TOML).
//!   * A YAML `*alias` reaching here is `error.UnresolvedAlias` (materialize
//!     first).
//!
//! The whole document is wrapped in the standard `<?xml ...?>` declaration,
//! `<!DOCTYPE plist ...>`, and a `<plist version="1.0">` root element — unlike
//! the reader (which also accepts a bare, unwrapped root object), the writer
//! always emits the full canonical wrapper.

const Printer = @This();
const std = @import("std");
const AST = @import("../../ast/ast.zig");
const Writer = std.Io.Writer;

pub const Error = Writer.Error || error{
    /// A YAML `*alias` reached the printer (materialize first).
    UnresolvedAlias,
    /// `null` has no representation in a plist.
    NullUnsupported,
    /// A `dict` mapping key was not a string.
    NonStringKey,
};

writer: *Writer,
ast: *const AST,
options: AST.SerializeOptions,

const header =
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" ++
    "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n" ++
    "<plist version=\"1.0\">";

/// Prints the whole document: the standard plist wrapper around `ast.root`.
pub fn print(writer: *Writer, ast: *const AST, options: AST.SerializeOptions) Error!void {
    var p: Printer = .{ .writer = writer, .ast = ast, .options = options };
    try writer.writeAll(header);
    try p.nl();
    try p.value(ast.root, 1);
    try p.nl();
    try writer.writeAll("</plist>\n");
    try writer.flush();
}

/// Prints the subtree rooted at `id` as a bare plistObject — no `<plist>`
/// wrapper, no trailing newline, no flush (used for partial/`--path` renders,
/// mirroring every other printer's `printNode`).
pub fn printNode(writer: *Writer, ast: *const AST, id: AST.Node.Id, depth: usize, options: AST.SerializeOptions) Error!void {
    var p: Printer = .{ .writer = writer, .ast = ast, .options = options };
    try p.value(id, depth);
}

fn value(self: *Printer, id: AST.Node.Id, depth: usize) Error!void {
    const n = self.ast.nodes[id];
    switch (n.kind) {
        .null_ => return error.NullUnsupported,
        .boolean => |b| try self.writer.writeAll(if (b) "<true/>" else "<false/>"),
        .number => |num| switch (num.kind) {
            .integer => try self.writer.print("<integer>{s}</integer>", .{num.raw}),
            .float => try self.writer.print("<real>{s}</real>", .{num.raw}),
        },
        .string => |s| try self.textElement("string", s),
        .extended => |e| switch (e.kind) {
            .plist_date => try self.textElement("date", e.text),
            .plist_data => try self.textElement("data", e.text),
            else => try self.textElement("string", e.text),
        },
        .sequence => |first| try self.array(first, depth),
        .mapping => |first| try self.dict(first, depth),
        .keyvalue => unreachable, // never a value position
        .alias => return error.UnresolvedAlias,
    }
}

fn textElement(self: *Printer, tag: []const u8, text: []const u8) Error!void {
    try self.writer.print("<{s}>", .{tag});
    try writeEscaped(self.writer, text);
    try self.writer.print("</{s}>", .{tag});
}

fn dict(self: *Printer, first_entry: ?AST.Node.Id, depth: usize) Error!void {
    if (first_entry == null) {
        try self.writer.writeAll("<dict/>");
        return;
    }
    try self.writer.writeAll("<dict>");
    try self.nl();
    var cur = first_entry;
    while (cur) |eid| : (cur = self.ast.nodes[eid].next_sibling) {
        const kv = self.ast.nodes[eid].kind.keyvalue;
        const key = switch (self.ast.nodes[kv.key].kind) {
            .string => |s| s,
            else => return error.NonStringKey,
        };
        try self.indent(depth);
        try self.textElement("key", key);
        try self.nl();
        try self.indent(depth);
        try self.value(kv.value, depth + 1);
        try self.nl();
    }
    try self.indent(depth - 1);
    try self.writer.writeAll("</dict>");
}

fn array(self: *Printer, first_item: ?AST.Node.Id, depth: usize) Error!void {
    if (first_item == null) {
        try self.writer.writeAll("<array/>");
        return;
    }
    try self.writer.writeAll("<array>");
    try self.nl();
    var cur = first_item;
    while (cur) |iid| : (cur = self.ast.nodes[iid].next_sibling) {
        try self.indent(depth);
        try self.value(iid, depth + 1);
        try self.nl();
    }
    try self.indent(depth - 1);
    try self.writer.writeAll("</array>");
}

/// Escape `&`/`<`/`>` while copying `s` to `writer` (plist text content is
/// never inside an attribute value in this printer's own output, so `"` never
/// needs escaping here).
fn writeEscaped(writer: *Writer, s: []const u8) Writer.Error!void {
    for (s) |c| switch (c) {
        '&' => try writer.writeAll("&amp;"),
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        else => try writer.writeByte(c),
    };
}

fn nl(self: *Printer) Writer.Error!void {
    if (self.options.pretty) try self.writer.writeByte('\n');
}

fn indent(self: *Printer, depth: usize) Writer.Error!void {
    if (!self.options.pretty) return;
    for (0..depth * self.options.indent) |_| try self.writer.writeByte(' ');
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;
const Parser = @import("parser.zig");

fn expectPrint(src: []const u8, expected: []const u8) !void {
    var doc = try Parser.parse(testing.allocator, src, .XML);
    defer doc.deinit(testing.allocator);
    var output: Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try print(&output.writer, &doc.ast, .{});
    try testing.expectEqualStrings(expected, output.written());
}

/// Parse `src`, print it, reparse the printed bytes, and assert the two ASTs
/// are equal — the round-trip property this design exists for.
fn expectRoundTrip(src: []const u8) !void {
    var doc = try Parser.parse(testing.allocator, src, .XML);
    defer doc.deinit(testing.allocator);
    var output: Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try print(&output.writer, &doc.ast, .{});

    var reparsed = try Parser.parse(testing.allocator, output.written(), .XML);
    defer reparsed.deinit(testing.allocator);
    try testing.expect(doc.ast.eql(reparsed.ast));
}

const wrapper_open =
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" ++
    "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n" ++
    "<plist version=\"1.0\">\n";
const wrapper_close = "\n</plist>\n";

test "empty dict" {
    try expectPrint("<dict/>", wrapper_open ++ "<dict/>" ++ wrapper_close);
}

test "scalars" {
    try expectPrint(
        "<dict><key>s</key><string>hi</string><key>i</key><integer>-42</integer>" ++
            "<key>r</key><real>3.14</real><key>t</key><true/><key>f</key><false/></dict>",
        wrapper_open ++
            \\<dict>
            \\  <key>s</key>
            \\  <string>hi</string>
            \\  <key>i</key>
            \\  <integer>-42</integer>
            \\  <key>r</key>
            \\  <real>3.14</real>
            \\  <key>t</key>
            \\  <true/>
            \\  <key>f</key>
            \\  <false/>
            \\</dict>
        ++ wrapper_close,
    );
}

test "date and data" {
    try expectPrint(
        "<dict><key>d</key><date>2011-11-01T12:00:00Z</date><key>b</key><data>SGVsbG8=</data></dict>",
        wrapper_open ++
            \\<dict>
            \\  <key>d</key>
            \\  <date>2011-11-01T12:00:00Z</date>
            \\  <key>b</key>
            \\  <data>SGVsbG8=</data>
            \\</dict>
        ++ wrapper_close,
    );
}

test "nested array and dict" {
    try expectPrint(
        "<array><string>one</string><dict><key>k</key><string>v</string></dict></array>",
        wrapper_open ++
            \\<array>
            \\  <string>one</string>
            \\  <dict>
            \\    <key>k</key>
            \\    <string>v</string>
            \\  </dict>
            \\</array>
        ++ wrapper_close,
    );
}

test "escapes & < > in text" {
    try expectPrint("<string>x &amp; y &lt;z&gt;</string>", wrapper_open ++ "<string>x &amp; y &lt;z&gt;</string>" ++ wrapper_close);
}

test "compact (non-pretty) output has no inserted whitespace" {
    var doc = try Parser.parse(testing.allocator, "<dict><key>a</key><integer>1</integer></dict>", .XML);
    defer doc.deinit(testing.allocator);
    var output: Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try print(&output.writer, &doc.ast, .{ .pretty = false });
    try testing.expectEqualStrings(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" ++
            "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n" ++
            "<plist version=\"1.0\"><dict><key>a</key><integer>1</integer></dict></plist>\n",
        output.written(),
    );
}

test "round-trip through parse -> print -> parse for every reader fixture shape" {
    const cases = [_][]const u8{
        "<dict/>",
        "<array/>",
        "<string>hi</string>",
        "<integer>-42</integer>",
        "<real>3.14</real>",
        "<true/>",
        "<false/>",
        "<date>2011-11-01T12:00:00Z</date>",
        "<data>SGVsbG8=</data>",
        "<dict><key>a</key><string>1</string><key>b</key><array><integer>1</integer><integer>2</integer></array></dict>",
    };
    for (cases) |src| try expectRoundTrip(src);
}

test "error: null is unsupported" {
    var nodes = [_]AST.Node{.{ .id = 0, .kind = .null_ }};
    const ast = AST{ .allocator = testing.allocator, .root = 0, .nodes = &nodes };
    var output: Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try testing.expectError(error.NullUnsupported, print(&output.writer, &ast, .{}));
}

test "error: non-string key" {
    var nodes = [_]AST.Node{
        .{ .id = 0, .kind = .{ .mapping = 1 } },
        .{ .id = 1, .kind = .{ .keyvalue = .{ .key = 2, .value = 3 } } },
        .{ .id = 2, .kind = .{ .number = .{ .raw = "1", .kind = .integer } } },
        .{ .id = 3, .kind = .{ .string = "x" } },
    };
    const ast = AST{ .allocator = testing.allocator, .root = 0, .nodes = &nodes };
    var output: Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try testing.expectError(error.NonStringKey, print(&output.writer, &ast, .{}));
}

test "error: unresolved alias" {
    var nodes = [_]AST.Node{.{ .id = 0, .kind = .{ .alias = "anchor" } }};
    const ast = AST{ .allocator = testing.allocator, .root = 0, .nodes = &nodes };
    var output: Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try testing.expectError(error.UnresolvedAlias, print(&output.writer, &ast, .{}));
}

test "foreign extended kind degrades to <string>" {
    var nodes = [_]AST.Node{.{ .id = 0, .kind = .{ .extended = .{ .kind = .enum_literal, .text = "fast" } } }};
    const ast = AST{ .allocator = testing.allocator, .root = 0, .nodes = &nodes };
    var output: Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try print(&output.writer, &ast, .{});
    try testing.expect(std.mem.indexOf(u8, output.written(), "<string>fast</string>") != null);
}
