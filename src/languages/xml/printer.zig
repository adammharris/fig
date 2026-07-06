//! XML printer: renders a fig AST as XML — the documented inverse of the reader
//! (`parser.zig`). Read that file's header first; this one mirrors its data
//! model exactly, in reverse:
//!
//!   * The AST root must be a one-entry mapping `{ name: value }` (what the
//!     reader always produces by wrapping the document's single root element).
//!     Anything else — zero or 2+ root keys, a non-mapping root — has no XML
//!     spelling and is `error.RootNotSingleElement`.
//!   * A mapping value's entries split three ways by key, independent of
//!     order: an `@`-prefixed key is an attribute on the start tag; the key
//!     `#text` is text content; everything else is a child element (its name
//!     is the key).
//!   * A child entry whose value is a `sequence` expands to that many sibling
//!     elements of the same name (the inverse of the reader collapsing
//!     repeated children into one). A `sequence` reached anywhere else — the
//!     root's own value, or an item that is itself a sequence — has no element
//!     name to expand under and is `error.NestedSequenceUnsupported`.
//!   * `null` is an empty-element tag; a bare scalar (string/number/boolean/an
//!     `extended` literal) is text-only content, written as-is (numbers keep
//!     their source lexeme, booleans print `true`/`false`, an `extended`
//!     scalar prints its intrinsic text) — XML has no distinct number/boolean
//!     type, so these already collapse to text the moment they leave the AST.
//!   * A mapping key must be a string (`error.NonStringKey`) and, once an `@`
//!     prefix or `#text` is stripped, a valid XML `Name` (`error.
//!     InvalidElementName`) — reusing the reader's own `isNameStart`/
//!     `isNameChar` grammar (`tokenizer.zig`) so the two can never drift apart.
//!   * An `@`/`#text` value must itself be a scalar; a mapping/sequence there
//!     is `error.NonScalarValue`.
//!
//! Whitespace: this fig reader (like the parser) does not perform XML's
//! attribute-value whitespace normalization, so a literal tab/newline inside an
//! attribute value round-trips as-is with no need for numeric-reference
//! escaping. Indentation is only ever inserted BETWEEN sibling child elements
//! of an element-only body — exactly the whitespace the reader already
//! discards (see parser.zig's `assemble`) — never inside a `#text`-bearing
//! (mixed-content) body or a text-only element, where any inserted byte would
//! become part of the round-tripped string.
//!
//! Comments are not part of this model: the XML reader has no comment syntax,
//! so no `node_comments` ever populate for an XML-sourced AST, and this
//! printer never emits any.

const Printer = @This();
const std = @import("std");
const AST = @import("../../ast/ast.zig");
const Tokenizer = @import("tokenizer.zig");
const Writer = std.Io.Writer;

pub const Error = Writer.Error || error{
    /// A YAML `*alias` reached the printer (materialize first).
    UnresolvedAlias,
    /// A mapping key was not a string.
    NonStringKey,
    /// The AST root was not a one-entry mapping — XML has exactly one root
    /// element, no more, no fewer.
    RootNotSingleElement,
    /// A `sequence` was reached with no element name to expand it under (a
    /// bare root value, or an array item that is itself an array).
    NestedSequenceUnsupported,
    /// A mapping key — an element name, or an attribute name after its `@` —
    /// is not a valid XML `Name`.
    InvalidElementName,
    /// An `@`-attribute or `#text` entry's value was a mapping/sequence
    /// (attributes and text content must be scalar).
    NonScalarValue,
};

writer: *Writer,
ast: *const AST,
options: AST.SerializeOptions,

/// Prints the whole document: an XML declaration, then the single root
/// element derived from `ast.root`'s one mapping entry.
pub fn print(writer: *Writer, ast: *const AST, options: AST.SerializeOptions) Error!void {
    var p: Printer = .{ .writer = writer, .ast = ast, .options = options };
    try writer.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");

    const first = switch (ast.nodes[ast.root].kind) {
        .mapping => |f| f,
        else => return error.RootNotSingleElement,
    } orelse return error.RootNotSingleElement;
    if (ast.nodes[first].next_sibling != null) return error.RootNotSingleElement;

    const kv = ast.nodes[first].kind.keyvalue;
    const name = try p.keyString(kv.key);
    try p.element(name, kv.value, 0);
    try writer.writeByte('\n');
    try writer.flush();
}

/// Prints the subtree rooted at `id` as a single element. Unlike `print`,
/// `id` need not be a root-shaped one-entry mapping — a `--path` query result
/// has no source key to name itself after — so it is wrapped under the fixed
/// placeholder name `root`. Adds no trailing newline and does not flush.
pub fn printNode(writer: *Writer, ast: *const AST, id: AST.Node.Id, depth: usize, options: AST.SerializeOptions) Error!void {
    var p: Printer = .{ .writer = writer, .ast = ast, .options = options };
    try p.element("root", id, depth);
}

/// Print one element named `name` whose content is `id`.
fn element(self: *Printer, name: []const u8, id: AST.Node.Id, depth: usize) Error!void {
    try validateName(name);
    switch (self.ast.nodes[id].kind) {
        .null_ => try self.writer.print("<{s}/>", .{name}),
        .mapping => |first| try self.mappingBody(name, first, depth),
        .sequence => return error.NestedSequenceUnsupported,
        .keyvalue => unreachable, // never a value position
        .alias => return error.UnresolvedAlias,
        .string, .number, .boolean, .extended => {
            try self.writer.print("<{s}>", .{name});
            try self.writeScalarValue(id, false);
            try self.writer.print("</{s}>", .{name});
        },
    }
}

/// Print `name`'s start tag (with attributes), body (child elements / text),
/// and end tag from a mapping's linked entries.
fn mappingBody(self: *Printer, name: []const u8, first_entry: ?AST.Node.Id, depth: usize) Error!void {
    try self.writer.print("<{s}", .{name});

    // Pass 1: every entry's key must be a string (whether attribute, text, or
    // child) — checked here, up front, for all of them. `@`-prefixed ones
    // render as attributes on the start tag now, before anything else can
    // write past it.
    var cur = first_entry;
    while (cur) |eid| : (cur = self.ast.nodes[eid].next_sibling) {
        const kv = self.ast.nodes[eid].kind.keyvalue;
        const key = try self.keyString(kv.key);
        if (!isAttrKey(key)) continue;
        const attr_name = key[1..];
        try validateName(attr_name);
        try self.writer.print(" {s}=\"", .{attr_name});
        try self.writeScalarValue(kv.value, true);
        try self.writer.writeByte('"');
    }

    if (!self.hasBody(first_entry)) {
        try self.writer.writeAll("/>");
        return;
    }
    try self.writer.writeByte('>');

    // An element-only body is safe to pretty-print (inserted whitespace only
    // ever sits between sibling elements, which the reader already discards);
    // one carrying `#text` is not (see the file header) and prints compact.
    const pretty = self.options.pretty and !self.hasText(first_entry);
    if (pretty) try self.writer.writeByte('\n');

    cur = first_entry;
    while (cur) |eid| : (cur = self.ast.nodes[eid].next_sibling) {
        const kv = self.ast.nodes[eid].kind.keyvalue;
        const key = try self.keyString(kv.key);
        if (isAttrKey(key)) continue;
        if (std.mem.eql(u8, key, "#text")) {
            try self.writeScalarValue(kv.value, false);
            continue;
        }
        // A sequence value is the inverse of the reader collapsing repeated
        // same-named children: expand back into that many sibling elements.
        switch (self.ast.nodes[kv.value].kind) {
            .sequence => |first_item| {
                var item = first_item;
                while (item) |iid| : (item = self.ast.nodes[iid].next_sibling) {
                    if (pretty) try self.writeIndent(depth + 1);
                    try self.element(key, iid, depth + 1);
                    if (pretty) try self.writer.writeByte('\n');
                }
            },
            else => {
                if (pretty) try self.writeIndent(depth + 1);
                try self.element(key, kv.value, depth + 1);
                if (pretty) try self.writer.writeByte('\n');
            },
        }
    }

    if (pretty) try self.writeIndent(depth);
    try self.writer.print("</{s}>", .{name});
}

/// Whether this mapping has anything besides attributes in its body (a
/// non-`@` key — `#text` or a child element) — an element with none
/// self-closes. Safe to assume every key is a string: pass 1 (the caller's
/// first loop over these same entries) already surfaced `NonStringKey`
/// otherwise.
fn hasBody(self: *const Printer, first_entry: ?AST.Node.Id) bool {
    var cur = first_entry;
    while (cur) |eid| : (cur = self.ast.nodes[eid].next_sibling) {
        const key = self.ast.nodes[self.ast.nodes[eid].kind.keyvalue.key].kind.string;
        if (!isAttrKey(key)) return true;
    }
    return false;
}

/// Whether this mapping carries a `#text` entry (mixed content). Same
/// string-key assumption as `hasBody`.
fn hasText(self: *const Printer, first_entry: ?AST.Node.Id) bool {
    var cur = first_entry;
    while (cur) |eid| : (cur = self.ast.nodes[eid].next_sibling) {
        const key = self.ast.nodes[self.ast.nodes[eid].kind.keyvalue.key].kind.string;
        if (std.mem.eql(u8, key, "#text")) return true;
    }
    return false;
}

fn isAttrKey(key: []const u8) bool {
    return key.len >= 2 and key[0] == '@';
}

fn keyString(self: *const Printer, key_id: AST.Node.Id) Error![]const u8 {
    return switch (self.ast.nodes[key_id].kind) {
        .string => |s| s,
        else => error.NonStringKey,
    };
}

/// Write an attribute's or `#text`'s value as escaped text. `null` writes
/// nothing (an empty attribute / no text); a container is
/// `error.NonScalarValue`. Numbers/booleans/`extended` scalars have no XML
/// primitive of their own and print as plain text, same as a string.
fn writeScalarValue(self: *Printer, id: AST.Node.Id, escape_quotes: bool) Error!void {
    switch (self.ast.nodes[id].kind) {
        .null_ => {},
        .string => |s| try writeEscaped(self.writer, s, escape_quotes),
        .number => |n| try writeEscaped(self.writer, n.raw, escape_quotes),
        .boolean => |b| try self.writer.writeAll(if (b) "true" else "false"),
        .extended => |e| try writeEscaped(self.writer, e.text, escape_quotes),
        .alias => return error.UnresolvedAlias,
        .mapping, .sequence, .keyvalue => return error.NonScalarValue,
    }
}

/// Escape `&`/`<`/`>` (always) and `"` (only in an attribute value) while
/// copying `s` to `writer`.
fn writeEscaped(writer: *Writer, s: []const u8, escape_quotes: bool) Writer.Error!void {
    for (s) |c| switch (c) {
        '&' => try writer.writeAll("&amp;"),
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        '"' => if (escape_quotes) try writer.writeAll("&quot;") else try writer.writeByte('"'),
        else => try writer.writeByte(c),
    };
}

/// A valid XML `Name`: reuses the reader's own grammar (`tokenizer.zig`) so
/// what the writer accepts and what the reader accepts can never drift apart.
fn validateName(name: []const u8) error{InvalidElementName}!void {
    if (name.len == 0 or !Tokenizer.isNameStart(name[0])) return error.InvalidElementName;
    for (name[1..]) |c| if (!Tokenizer.isNameChar(c)) return error.InvalidElementName;
}

fn writeIndent(self: *Printer, depth: usize) Writer.Error!void {
    for (0..depth * self.options.indent) |_| try self.writer.writeByte(' ');
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;
const Parser = @import("parser.zig");

fn expectPrint(src: []const u8, expected: []const u8) !void {
    var doc = try Parser.parse(testing.allocator, src, .XML_1_0);
    defer doc.deinit(testing.allocator);
    var output: Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try print(&output.writer, &doc.ast, .{});
    try testing.expectEqualStrings(expected, output.written());
}

/// Parse `src`, print it, reparse the printed bytes, and assert the two ASTs
/// are equal — the round-trip property this whole design exists for.
fn expectRoundTrip(src: []const u8) !void {
    var doc = try Parser.parse(testing.allocator, src, .XML_1_0);
    defer doc.deinit(testing.allocator);
    var output: Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try print(&output.writer, &doc.ast, .{});

    var reparsed = try Parser.parse(testing.allocator, output.written(), .XML_1_0);
    defer reparsed.deinit(testing.allocator);
    try testing.expect(doc.ast.eql(reparsed.ast));
}

test "text-only element" {
    try expectPrint("<a>hi</a>", "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<a>hi</a>\n");
}

test "empty element self-closes" {
    try expectPrint("<a/>", "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<a/>\n");
}

test "attribute folds from @key" {
    try expectPrint("<a x=\"1\"/>", "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<a x=\"1\"/>\n");
}

test "attributes plus text use #text" {
    try expectPrint(
        \\<a x="1">hi</a>
    , "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<a x=\"1\">hi</a>\n");
}

test "nested elements pretty-print with indentation" {
    try expectPrint("<r><a>1</a><b>2</b></r>",
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<r>
        \\  <a>1</a>
        \\  <b>2</b>
        \\</r>
        \\
    );
}

test "repeated elements collapse and re-expand" {
    try expectPrint("<r><i>a</i><i>b</i></r>",
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<r>
        \\  <i>a</i>
        \\  <i>b</i>
        \\</r>
        \\
    );
}

test "mixed content (text + attrs) prints compact, not pretty" {
    // A #text-bearing body never gets inserted whitespace: it would become
    // part of the round-tripped string.
    try expectPrint(
        \\<a x="1">hi</a>
    , "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<a x=\"1\">hi</a>\n");
}

test "escapes & < > in text and additionally \" in attributes" {
    try expectPrint("<a x=\"&quot;q&quot;\">x &amp; y &lt;z&gt;</a>", "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<a x=\"&quot;q&quot;\">x &amp; y &lt;z&gt;</a>\n");
}

test "round-trips: nested, attributes, text, repeats, entities" {
    try expectRoundTrip("<r><a x=\"1\" y=\"2\">hello &amp; goodbye</a><i>1</i><i>2</i><i>3</i><empty/></r>");
}

test "round-trip through parse -> print -> parse for every reader fixture shape" {
    const cases = [_][]const u8{
        "<a>hi</a>",
        "<a/>",
        "<a></a>",
        "<r><a>1</a><b>2</b></r>",
        "<a x=\"1\"/>",
        "<r><i>a</i><i>b</i></r>",
        "<a x=\"1\">hi</a>",
        "<x id=\"1\"><id>2</id></x>",
        "<a>x &amp; y A B</a>",
    };
    for (cases) |src| try expectRoundTrip(src);
}

test "error: root must be exactly one element" {
    var nodes = [_]AST.Node{
        .{ .id = 0, .kind = .{ .mapping = null } },
    };
    const ast = AST{ .allocator = testing.allocator, .root = 0, .nodes = &nodes };
    var output: Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try testing.expectError(error.RootNotSingleElement, print(&output.writer, &ast, .{}));
}

test "error: root scalar is not a single element" {
    var nodes = [_]AST.Node{
        .{ .id = 0, .kind = .{ .string = "hi" } },
    };
    const ast = AST{ .allocator = testing.allocator, .root = 0, .nodes = &nodes };
    var output: Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try testing.expectError(error.RootNotSingleElement, print(&output.writer, &ast, .{}));
}

test "error: non-string key" {
    // { 1: "x" } wrapped as the lone root entry — the key is a number, not a string.
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

test "error: invalid element name" {
    var nodes = [_]AST.Node{
        .{ .id = 0, .kind = .{ .mapping = 1 } },
        .{ .id = 1, .kind = .{ .keyvalue = .{ .key = 2, .value = 3 } } },
        .{ .id = 2, .kind = .{ .string = "1bad" } }, // Names can't start with a digit.
        .{ .id = 3, .kind = .null_ },
    };
    const ast = AST{ .allocator = testing.allocator, .root = 0, .nodes = &nodes };
    var output: Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try testing.expectError(error.InvalidElementName, print(&output.writer, &ast, .{}));
}

test "error: a bare sequence has no element name to expand under" {
    // root = { r: [1, 2] } — a sequence sitting directly as the root's value.
    var nodes = [_]AST.Node{
        .{ .id = 0, .kind = .{ .mapping = 1 } },
        .{ .id = 1, .kind = .{ .keyvalue = .{ .key = 2, .value = 3 } } },
        .{ .id = 2, .kind = .{ .string = "r" } },
        .{ .id = 3, .kind = .{ .sequence = 4 }, .next_sibling = null },
        .{ .id = 4, .kind = .{ .number = .{ .raw = "1", .kind = .integer } }, .next_sibling = 5 },
        .{ .id = 5, .kind = .{ .number = .{ .raw = "2", .kind = .integer } } },
    };
    const ast = AST{ .allocator = testing.allocator, .root = 0, .nodes = &nodes };
    var output: Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try testing.expectError(error.NestedSequenceUnsupported, print(&output.writer, &ast, .{}));
}

test "error: an array-of-arrays item has no element name either" {
    // root = { outer: { r: [ [1], [2] ] } } — unlike a bare sequence sitting
    // directly as a mapping-entry value (which the reader's own repeated-
    // children convention *does* give a meaning to), a sequence found as an
    // ITEM of another sequence has no such convention: nothing named it.
    var nodes = [_]AST.Node{
        .{ .id = 0, .kind = .{ .mapping = 1 } },
        .{ .id = 1, .kind = .{ .keyvalue = .{ .key = 2, .value = 3 } } },
        .{ .id = 2, .kind = .{ .string = "outer" } },
        .{ .id = 3, .kind = .{ .mapping = 4 } },
        .{ .id = 4, .kind = .{ .keyvalue = .{ .key = 5, .value = 6 } } },
        .{ .id = 5, .kind = .{ .string = "r" } },
        .{ .id = 6, .kind = .{ .sequence = 7 } },
        .{ .id = 7, .kind = .{ .sequence = 9 }, .next_sibling = 8 },
        .{ .id = 8, .kind = .{ .sequence = 10 } },
        .{ .id = 9, .kind = .{ .number = .{ .raw = "1", .kind = .integer } } },
        .{ .id = 10, .kind = .{ .number = .{ .raw = "2", .kind = .integer } } },
    };
    const ast = AST{ .allocator = testing.allocator, .root = 0, .nodes = &nodes };
    var output: Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try testing.expectError(error.NestedSequenceUnsupported, print(&output.writer, &ast, .{}));
}

test "error: attribute value must be scalar" {
    // root = { r: { @x: {} } } — an attribute whose value is a mapping.
    var nodes = [_]AST.Node{
        .{ .id = 0, .kind = .{ .mapping = 1 } },
        .{ .id = 1, .kind = .{ .keyvalue = .{ .key = 2, .value = 3 } } },
        .{ .id = 2, .kind = .{ .string = "r" } },
        .{ .id = 3, .kind = .{ .mapping = 4 } },
        .{ .id = 4, .kind = .{ .keyvalue = .{ .key = 5, .value = 6 } } },
        .{ .id = 5, .kind = .{ .string = "@x" } },
        .{ .id = 6, .kind = .{ .mapping = null } },
    };
    const ast = AST{ .allocator = testing.allocator, .root = 0, .nodes = &nodes };
    var output: Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try testing.expectError(error.NonScalarValue, print(&output.writer, &ast, .{}));
}

test "error: unresolved alias" {
    var nodes = [_]AST.Node{
        .{ .id = 0, .kind = .{ .mapping = 1 } },
        .{ .id = 1, .kind = .{ .keyvalue = .{ .key = 2, .value = 3 } } },
        .{ .id = 2, .kind = .{ .string = "r" } },
        .{ .id = 3, .kind = .{ .alias = "anchor" } },
    };
    const ast = AST{ .allocator = testing.allocator, .root = 0, .nodes = &nodes };
    var output: Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try testing.expectError(error.UnresolvedAlias, print(&output.writer, &ast, .{}));
}

test "honors custom indent width" {
    var doc = try Parser.parse(testing.allocator, "<r><a>1</a></r>", .XML_1_0);
    defer doc.deinit(testing.allocator);
    var output: Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try print(&output.writer, &doc.ast, .{ .indent = 4 });
    try testing.expectEqualStrings(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<r>
        \\    <a>1</a>
        \\</r>
        \\
    , output.written());
}
