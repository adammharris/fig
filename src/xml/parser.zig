//! XML reader: parses XML into the shared fig AST.
//!
//! Data model (config-oriented, reader-only):
//!   * An element becomes a `mapping`; a text-only element with no attributes
//!     becomes a bare `string`; an empty element becomes `null`.
//!   * Attributes are folded into the element's mapping under `@`-prefixed keys,
//!     and mixed/sibling text under `#text`. This is collision-proof: `@` and `#`
//!     are illegal as the first character of an XML name, so these synthetic keys
//!     can never clash with a real element/attribute name.
//!   * Repeated child elements of the same name collapse into a `sequence`
//!     (first-appearance order). Interleaving of differently-named repeats is not
//!     preserved — that is the deferred mixed-content side-table.
//!   * The document's single root element yields a one-entry root mapping
//!     `{ rootName: ... }`.
//!   * Values stay raw strings — no type inference. Predefined and numeric
//!     entities are decoded; CDATA is literal text. Whitespace-only text between
//!     element siblings is dropped; text inside a text-only element is verbatim.
//!
//! Entry order within an element mapping: attributes (source order), then child
//! elements (first-appearance order), then `#text` (if any).

const Parser = @This();

const std = @import("std");
const build_options = @import("build_options");
const AST = @import("../ast/ast.zig");
const Document = @import("../document.zig");
const Type = @import("xml.zig").Type;
const Span = @import("../util/span.zig");
const Tokenizer = @import("tokenizer.zig");

const Id = AST.Node.Id;

allocator: std.mem.Allocator,
version: Type = .XML_1_0,
source: []const u8 = "",
tokens: []const Tokenizer.Token = &.{},
pos: usize = 0,
nodes: std.ArrayList(AST.Node) = .empty,
spans: std.ArrayList(Span) = .empty,
owned_strings: std.ArrayList([]const u8) = .empty,

pub const ParseError = error{
    MissingRootElement,
    MultipleRootElements,
    ContentOutsideRoot,
    MismatchedTag,
    DuplicateAttribute,
    UnsupportedEntity,
    UnexpectedToken,
} || Tokenizer.TokenizeError;

/// One parsed child element: its name (a borrowed source slice) and the AST node
/// id of its value.
const Child = struct { name: []const u8, value: Id };

/// One run of character data; `literal` marks CDATA (no entity decoding, never
/// dropped as insignificant whitespace).
const TextRun = struct { raw: []const u8, literal: bool };

pub fn parse(allocator: std.mem.Allocator, input: []const u8, format: Type) ParseError!Document {
    var self: Parser = .{ .allocator = allocator, .version = format, .source = input };
    errdefer {
        for (self.owned_strings.items) |s| allocator.free(s);
        self.owned_strings.deinit(allocator);
        self.nodes.deinit(allocator);
        self.spans.deinit(allocator);
    }

    var tokenizer: Tokenizer = .{ .allocator = allocator, .str = input };
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);
    self.tokens = tokens;

    // Prolog: only insignificant whitespace may precede the root element.
    try self.skipWhitespaceText();
    if (self.curKind() != .lt) return error.MissingRootElement;
    const root_el = try self.parseElement();

    // Epilog: only insignificant whitespace may follow it.
    try self.skipWhitespaceText();
    switch (self.curKind()) {
        .eof => {},
        .lt, .lt_slash => return error.MultipleRootElements,
        else => return error.UnexpectedToken,
    }

    // Wrap the root element in the one-entry root mapping `{ name: value }`.
    const whole = Span.init(0, input.len);
    const key_id = try self.stringNode(try self.dupe(root_el.name), whole);
    const kv = try self.addNode(.{ .keyvalue = .{ .key = key_id, .value = root_el.value } }, whole);
    const root_id = try self.buildMapping(&.{kv}, whole);

    const nodes = try self.nodes.toOwnedSlice(allocator);
    const spans = try self.spans.toOwnedSlice(allocator);
    const owned = try self.owned_strings.toOwnedSlice(allocator);
    return .{
        .source = input,
        .ast = .{ .allocator = allocator, .owned_strings = owned, .root = root_id, .nodes = nodes },
        .node_spans = spans,
    };
}

/// Parse one element (positioned at its opening `lt`) through its end tag,
/// returning its name and the AST node id representing its value.
fn parseElement(self: *Parser) ParseError!Child {
    const sp = self.cur().span; // start-tag span; reused for this element's nodes
    self.advance(); // lt
    if (self.curKind() != .name) return error.UnexpectedToken;
    const el_name = self.curText();
    self.advance();

    // Attributes → `@name` keyvalue entries.
    var attrs: std.ArrayList(Id) = .empty;
    defer attrs.deinit(self.allocator);
    var attr_names: std.ArrayList([]const u8) = .empty;
    defer attr_names.deinit(self.allocator);
    while (self.curKind() == .name) {
        const aname = self.curText();
        self.advance();
        for (attr_names.items) |n| if (std.mem.eql(u8, n, aname)) return error.DuplicateAttribute;
        try attr_names.append(self.allocator, aname);

        if (self.curKind() != .eq) return error.UnexpectedToken;
        self.advance();
        if (self.curKind() != .attr_value) return error.UnexpectedToken;
        const raw = self.curText();
        self.advance();

        const key_id = try self.prefixedStringNode('@', aname, sp);
        const val_id = try self.decodedStringNode(raw, sp);
        try attrs.append(self.allocator, try self.addNode(.{ .keyvalue = .{ .key = key_id, .value = val_id } }, sp));
    }

    // Empty-element tag `<.../>`: no content.
    if (self.curKind() == .slash_gt) {
        self.advance();
        return .{ .name = el_name, .value = try self.containerOrEmpty(attrs.items, sp) };
    }
    if (self.curKind() != .gt) return error.UnexpectedToken;
    self.advance();

    // Content until the end tag.
    var children: std.ArrayList(Child) = .empty;
    defer children.deinit(self.allocator);
    var runs: std.ArrayList(TextRun) = .empty;
    defer runs.deinit(self.allocator);
    content: while (true) {
        switch (self.curKind()) {
            .char_data => {
                try runs.append(self.allocator, .{ .raw = self.curText(), .literal = false });
                self.advance();
            },
            .cdata => {
                try runs.append(self.allocator, .{ .raw = self.curText(), .literal = true });
                self.advance();
            },
            .lt => try children.append(self.allocator, try self.parseElement()),
            .lt_slash => break :content,
            .eof => return error.UnclosedTag,
            else => return error.UnexpectedToken,
        }
    }

    // End tag: `</name>` whose name must match.
    self.advance(); // lt_slash
    if (self.curKind() != .name) return error.UnexpectedToken;
    if (!std.mem.eql(u8, self.curText(), el_name)) return error.MismatchedTag;
    self.advance();
    if (self.curKind() != .gt) return error.UnexpectedToken;
    self.advance();

    return .{ .name = el_name, .value = try self.assemble(attrs.items, children.items, runs.items, sp) };
}

/// Build an element's value from its attributes, child elements, and text runs.
fn assemble(self: *Parser, attrs: []const Id, children: []const Child, runs: []const TextRun, sp: Span) ParseError!Id {
    const has_attrs = attrs.len > 0;
    const has_elems = children.len > 0;

    // Concatenate significant text. In element/attribute context, whitespace-only
    // char_data is dropped; CDATA and non-whitespace char_data are kept. In a
    // pure text-only element, all text is kept verbatim.
    var textbuf: std.ArrayList(u8) = .empty;
    defer textbuf.deinit(self.allocator);
    for (runs) |r| {
        if (r.literal) {
            try textbuf.appendSlice(self.allocator, r.raw);
        } else if ((!has_attrs and !has_elems) or !isWhitespaceOnly(r.raw)) {
            try self.decodeInto(&textbuf, r.raw);
        }
    }

    if (!has_attrs and !has_elems) {
        if (textbuf.items.len == 0) return self.addNode(.null_, sp);
        return self.stringNode(try self.dupe(textbuf.items), sp);
    }

    var entries: std.ArrayList(Id) = .empty;
    defer entries.deinit(self.allocator);
    try entries.appendSlice(self.allocator, attrs);
    try self.buildChildEntries(children, &entries, sp);
    if (textbuf.items.len > 0) {
        const key_id = try self.prefixedStringNode('#', "text", sp);
        const val_id = try self.stringNode(try self.dupe(textbuf.items), sp);
        try entries.append(self.allocator, try self.addNode(.{ .keyvalue = .{ .key = key_id, .value = val_id } }, sp));
    }
    return self.buildMapping(entries.items, sp);
}

/// Value for an element with no content: a mapping of its attributes, or `null`
/// when it has none.
fn containerOrEmpty(self: *Parser, attrs: []const Id, sp: Span) ParseError!Id {
    if (attrs.len == 0) return self.addNode(.null_, sp);
    return self.buildMapping(attrs, sp);
}

/// Group children by name into mapping entries: a name seen once becomes a plain
/// `name: value` entry; a repeated name becomes `name: [values…]`.
fn buildChildEntries(self: *Parser, children: []const Child, entries: *std.ArrayList(Id), sp: Span) ParseError!void {
    for (children, 0..) |child, i| {
        // Skip names already emitted at an earlier occurrence.
        var seen = false;
        for (children[0..i]) |prev| {
            if (std.mem.eql(u8, prev.name, child.name)) {
                seen = true;
                break;
            }
        }
        if (seen) continue;

        var vals: std.ArrayList(Id) = .empty;
        defer vals.deinit(self.allocator);
        for (children[i..]) |c| {
            if (std.mem.eql(u8, c.name, child.name)) try vals.append(self.allocator, c.value);
        }
        const value_id = if (vals.items.len == 1)
            vals.items[0]
        else
            try self.buildSequence(vals.items, sp);

        const key_id = try self.stringNode(try self.dupe(child.name), sp);
        try entries.append(self.allocator, try self.addNode(.{ .keyvalue = .{ .key = key_id, .value = value_id } }, sp));
    }
}

// ── entity decoding ──────────────────────────────────────────────────────────

/// Decode XML entity references in `raw` (predefined `&amp; &lt; &gt; &quot;
/// &apos;` and numeric `&#dd; / &#xhh;`) into `buf`. Any other named reference
/// is rejected — DTD-defined entities are out of scope.
fn decodeInto(self: *Parser, buf: *std.ArrayList(u8), raw: []const u8) ParseError!void {
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] != '&') {
            try buf.append(self.allocator, raw[i]);
            i += 1;
            continue;
        }
        const semi = std.mem.indexOfScalarPos(u8, raw, i + 1, ';') orelse return error.UnsupportedEntity;
        const ent = raw[i + 1 .. semi];
        if (ent.len == 0) return error.UnsupportedEntity;
        if (ent[0] == '#') {
            const cp = parseCharRef(ent) orelse return error.UnsupportedEntity;
            var utf8: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &utf8) catch return error.UnsupportedEntity;
            try buf.appendSlice(self.allocator, utf8[0..n]);
        } else {
            const repl: u8 = if (std.mem.eql(u8, ent, "amp"))
                '&'
            else if (std.mem.eql(u8, ent, "lt"))
                '<'
            else if (std.mem.eql(u8, ent, "gt"))
                '>'
            else if (std.mem.eql(u8, ent, "quot"))
                '"'
            else if (std.mem.eql(u8, ent, "apos"))
                '\''
            else
                return error.UnsupportedEntity;
            try buf.append(self.allocator, repl);
        }
        i = semi + 1;
    }
}

/// Parse a numeric character reference body (`#1234` or `#x1F600`) to a codepoint.
fn parseCharRef(ent: []const u8) ?u21 {
    if (ent.len < 2) return null;
    const hex = ent[1] == 'x' or ent[1] == 'X';
    const digits = if (hex) ent[2..] else ent[1..];
    if (digits.len == 0) return null;
    return std.fmt.parseInt(u21, digits, if (hex) 16 else 10) catch null;
}

// ── node construction ────────────────────────────────────────────────────────

fn addNode(self: *Parser, kind: AST.Node.Kind, span: Span) ParseError!Id {
    const id: Id = @intCast(self.nodes.items.len);
    try self.nodes.append(self.allocator, .{ .id = id, .kind = kind, .next_sibling = null });
    try self.spans.append(self.allocator, span);
    return id;
}

fn stringNode(self: *Parser, owned: []const u8, span: Span) ParseError!Id {
    return self.addNode(.{ .string = owned }, span);
}

/// A string node whose value is `prefix ++ name`, owned by the AST.
fn prefixedStringNode(self: *Parser, prefix: u8, name: []const u8, span: Span) ParseError!Id {
    const buf = try self.allocator.alloc(u8, name.len + 1);
    buf[0] = prefix;
    @memcpy(buf[1..], name);
    return self.stringNode(try self.intern(buf), span);
}

/// A string node whose value is `raw` with entities decoded, owned by the AST.
fn decodedStringNode(self: *Parser, raw: []const u8, span: Span) ParseError!Id {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(self.allocator);
    try self.decodeInto(&buf, raw);
    return self.stringNode(try self.dupe(buf.items), span);
}

fn buildSequence(self: *Parser, items: []const Id, span: Span) ParseError!Id {
    self.link(items);
    return self.addNode(.{ .sequence = if (items.len == 0) null else items[0] }, span);
}

fn buildMapping(self: *Parser, entries: []const Id, span: Span) ParseError!Id {
    self.link(entries);
    return self.addNode(.{ .mapping = if (entries.len == 0) null else entries[0] }, span);
}

/// Chain `ids` as siblings; terminate the last.
fn link(self: *Parser, ids: []const Id) void {
    if (ids.len == 0) return;
    for (ids[0 .. ids.len - 1], ids[1..]) |cur_id, next_id| {
        self.nodes.items[cur_id].next_sibling = next_id;
    }
    self.nodes.items[ids[ids.len - 1]].next_sibling = null;
}

/// Register an already-allocated buffer with the AST's owned strings.
fn intern(self: *Parser, owned: []u8) ParseError![]const u8 {
    errdefer self.allocator.free(owned);
    try self.owned_strings.append(self.allocator, owned);
    return owned;
}

/// Copy `bytes` into AST-owned storage.
fn dupe(self: *Parser, bytes: []const u8) ParseError![]const u8 {
    return self.intern(try self.allocator.dupe(u8, bytes));
}

// ── cursor + helpers ─────────────────────────────────────────────────────────

fn cur(self: *const Parser) Tokenizer.Token {
    return self.tokens[self.pos];
}

fn curKind(self: *const Parser) Tokenizer.Kind {
    return self.tokens[self.pos].kind;
}

fn curText(self: *const Parser) []const u8 {
    return self.tokens[self.pos].source(self.source);
}

fn advance(self: *Parser) void {
    self.pos += 1;
}

/// Consume insignificant (whitespace-only) char_data; a non-whitespace run
/// outside the root element is an error.
fn skipWhitespaceText(self: *Parser) ParseError!void {
    while (self.curKind() == .char_data) {
        if (!isWhitespaceOnly(self.curText())) return error.ContentOutsideRoot;
        self.advance();
    }
}

fn isWhitespaceOnly(s: []const u8) bool {
    for (s) |c| {
        if (c != ' ' and c != '\t' and c != '\r' and c != '\n') return false;
    }
    return true;
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Parse `src` and assert its JSON serialization equals `expected`.
fn expectJson(src: []const u8, expected: []const u8) !void {
    // These reader tests verify the parsed shape by serializing to JSON; skip
    // them when JSON is gated out of the build (the parser itself is unaffected).
    if (comptime !build_options.lang_json) return error.SkipZigTest;
    var doc = try parse(testing.allocator, src, .XML_1_0);
    defer doc.deinit(testing.allocator);
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try doc.ast.serialize(&w, .json);
    try testing.expectEqualStrings(expected, w.buffered());
}

test "text-only element" {
    try expectJson("<a>hi</a>",
        \\{
        \\  "a": "hi"
        \\}
        \\
    );
}

test "empty element is null" {
    try expectJson("<a/>",
        \\{
        \\  "a": null
        \\}
        \\
    );
    try expectJson("<a></a>",
        \\{
        \\  "a": null
        \\}
        \\
    );
}

test "nested elements" {
    try expectJson("<r><a>1</a><b>2</b></r>",
        \\{
        \\  "r": {
        \\    "a": "1",
        \\    "b": "2"
        \\  }
        \\}
        \\
    );
}

test "attribute folds to @key" {
    try expectJson(
        \\<a x="1"/>
    ,
        \\{
        \\  "a": {
        \\    "@x": "1"
        \\  }
        \\}
        \\
    );
}

test "repeated elements collapse to a sequence" {
    try expectJson("<r><i>a</i><i>b</i></r>",
        \\{
        \\  "r": {
        \\    "i": [
        \\      "a",
        \\      "b"
        \\    ]
        \\  }
        \\}
        \\
    );
}

test "attributes plus text use #text" {
    try expectJson(
        \\<a x="1">hi</a>
    ,
        \\{
        \\  "a": {
        \\    "@x": "1",
        \\    "#text": "hi"
        \\  }
        \\}
        \\
    );
}

test "attribute and child of same name do not collide" {
    try expectJson(
        \\<x id="1"><id>2</id></x>
    ,
        \\{
        \\  "x": {
        \\    "@id": "1",
        \\    "id": "2"
        \\  }
        \\}
        \\
    );
}

test "predefined and numeric entities decode" {
    try expectJson("<a>x &amp; y &#65; &#x42;</a>",
        \\{
        \\  "a": "x & y A B"
        \\}
        \\
    );
}

test "cdata is literal text" {
    try expectJson("<a><![CDATA[<b>&z]]></a>",
        \\{
        \\  "a": "<b>&z"
        \\}
        \\
    );
}

test "whitespace between element siblings is dropped" {
    try expectJson("<r>\n  <a>1</a>\n  <b>2</b>\n</r>",
        \\{
        \\  "r": {
        \\    "a": "1",
        \\    "b": "2"
        \\  }
        \\}
        \\
    );
}

test "leading/trailing prolog whitespace allowed" {
    try expectJson("\n  <a/>\n",
        \\{
        \\  "a": null
        \\}
        \\
    );
}

test "errors" {
    try testing.expectError(error.MismatchedTag, parse(testing.allocator, "<a></b>", .XML_1_0));
    try testing.expectError(error.MultipleRootElements, parse(testing.allocator, "<a/><b/>", .XML_1_0));
    try testing.expectError(error.DuplicateAttribute, parse(testing.allocator, "<a x=\"1\" x=\"2\"/>", .XML_1_0));
    try testing.expectError(error.UnsupportedEntity, parse(testing.allocator, "<a>&bogus;</a>", .XML_1_0));
    try testing.expectError(error.ContentOutsideRoot, parse(testing.allocator, "junk<a/>", .XML_1_0));
    try testing.expectError(error.MissingRootElement, parse(testing.allocator, "   ", .XML_1_0));
    try testing.expectError(error.UnclosedTag, parse(testing.allocator, "<a><b>", .XML_1_0));
}
