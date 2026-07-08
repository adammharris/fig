//! plist reader: parses Apple's XML property list format into the shared fig
//! AST. Scope: the XML variant only (`<plist>…</plist>`) — old-style ASCII
//! (NeXTSTEP/OpenStep `{ key = value; }`) and binary plist (`bplist00…`) are
//! separate, larger efforts (a different grammar entirely, and for binary, a
//! different byte-level format with no text lexer at all) and not attempted
//! here. See `PropertyList-1.0.dtd` (Apple, vendored nowhere — it's tiny and
//! quoted in full below) for the grammar this reader implements:
//!
//!   plist  := (array | data | date | dict | real | integer | string | true | false)
//!   dict   := (key, plistObject)*        -- alternating key/value, in order
//!   array  := (plistObject)*
//!   key, string, data, date := #PCDATA
//!   true, false := EMPTY                  -- `<true/>` / `<false/>`
//!   integer := ("+"|"-")? digit+
//!   real    := ("+"|"-")? digit+ ("." digit*)? (("e"|"E") ("+"|"-")? digit+)?
//!
//! Lexing is delegated entirely to the XML tokenizer (`../xml/tokenizer.zig`)
//! — it is purely lexical (tag/name/text-run tokens, no semantics), so this
//! reader shares it as-is rather than duplicating a scanner. Everything below
//! is plist-specific: the DTD-aware grammar, alternating-pair dict parsing,
//! numeric/boolean/date/data validation, and the AST shape.
//!
//! Data model (config-oriented, reader-only, much more direct than the
//! generic XML reader's since plist's DTD gives every element a fixed,
//! typed meaning — no attribute-folding, no `#text`, no repeated-child
//! collapsing):
//!   * `dict` → `mapping` (a real key/value mapping, not folded attributes).
//!     A duplicate `<key>` follows plist's/`plutil`'s own last-wins
//!     convention: the later value replaces the earlier one, kept at the
//!     earlier key's position.
//!   * `array` → `sequence`.
//!   * `string`/`integer`/`real`/`true`/`false` → the matching AST scalar.
//!     `integer`/`real` text is trimmed of surrounding whitespace but
//!     otherwise kept verbatim (no reparse-and-reformat), like TOML's numbers.
//!   * `date`/`data` → an `extended` scalar (`ExtKind.plist_date`/
//!     `.plist_data`) — the same mechanism TOML datetimes and ZON enum/char
//!     literals use for a format-specific lexical type the abstract model has
//!     no scalar of its own for. `data`'s payload is stored with ALL
//!     whitespace stripped (real plist files commonly wrap base64 across
//!     many lines) so the intrinsic bytes are exactly the decoded value, per
//!     the `Extended.text` convention.
//!   * The document root is either `<plist [version="1.0"]>OBJECT</plist>`
//!     (the normal, Xcode/`plutil`-authored shape) or a bare OBJECT with no
//!     `<plist>` wrapper at all — `plutil -lint` accepts both, so this reader
//!     does too. Either way, the resulting AST root is just that object's own
//!     node (a mapping/sequence/scalar) — unlike the generic XML reader,
//!     there is no synthetic one-entry wrapper mapping, since plist objects
//!     are already typed values, not anonymous elements needing a name.
//!
//! No attributes are recognized anywhere except an optional `version` on
//! `<plist>` (ignored); any other attribute, anywhere, is `UnexpectedAttribute`.

const Parser = @This();

const std = @import("std");
const AST = @import("../../ast/ast.zig");
const Document = @import("../../document.zig");
const Type = @import("plist.zig").Type;
const Span = @import("../../util/span.zig");
const Tokenizer = @import("../xml/tokenizer.zig");

const Id = AST.Node.Id;
const ExtKind = AST.Node.Kind.Extended.ExtKind;
const NumberKind = @FieldType(AST.Node.Kind.Number, "kind");

allocator: std.mem.Allocator,
version: Type = .XML,
source: []const u8 = "",
tokens: []const Tokenizer.Token = &.{},
pos: usize = 0,
nodes: std.ArrayList(AST.Node) = .empty,
spans: std.ArrayList(Span) = .empty,
owned_strings: std.ArrayList([]const u8) = .empty,

pub const ParseError = error{
    /// No root element at all (empty or whitespace-only document).
    MissingRoot,
    /// More than one top-level object (either two root elements with no
    /// `<plist>` wrapper, or a `<plist>` whose body holds 2+ objects).
    MultipleRoots,
    /// Non-whitespace text where only markup is allowed (outside the root,
    /// or directly inside a `dict`/`array`).
    UnexpectedText,
    MismatchedTag,
    /// An attribute on anything other than `<plist>`'s own `version`.
    UnexpectedAttribute,
    /// An element name outside the DTD's fixed vocabulary.
    UnknownElement,
    UnexpectedToken,
    /// A `dict` body held something other than a `<key>` where one was
    /// expected (DTD: `dict := (key, plistObject)*`).
    DictKeyExpected,
    /// A `<key>` with no following value element (a dangling key, or the
    /// dict closing immediately after it).
    DictValueMissing,
    InvalidInteger,
    InvalidReal,
    /// `<date>`'s content isn't even loosely ISO-8601-shaped.
    InvalidDate,
    /// `<true>`/`<false>` held non-whitespace content — the DTD marks both
    /// EMPTY.
    InvalidBoolean,
    /// `<data>`'s decoded content has a byte outside the base64 alphabet
    /// (`A-Za-z0-9+/`) plus optional trailing `=` padding.
    InvalidBase64,
    /// A `<string>`/`<key>`/`<integer>`/`<real>`/`<date>`/`<data>` held a
    /// nested element — every one of these is DTD `#PCDATA` (or EMPTY), text
    /// only.
    NestedElementInScalar,
    UnsupportedEntity,
} || Tokenizer.TokenizeError;

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

    try self.skipInsignificantWhitespace();
    if (self.curKind() != .lt) return error.MissingRoot;
    const root_id = try self.parseDocumentRoot();

    try self.skipInsignificantWhitespace();
    switch (self.curKind()) {
        .eof => {},
        .lt, .lt_slash => return error.MultipleRoots,
        else => return error.UnexpectedToken,
    }

    const nodes = try self.nodes.toOwnedSlice(allocator);
    const spans = try self.spans.toOwnedSlice(allocator);
    const owned = try self.owned_strings.toOwnedSlice(allocator);
    return .{
        .source = input,
        .ast = .{ .allocator = allocator, .owned_strings = owned, .root = root_id, .nodes = nodes },
        .node_spans = spans,
    };
}

/// Positioned at the root `lt`. Either a `<plist>` wrapper around exactly one
/// object, or a bare object with no wrapper at all (both `plutil`-valid).
fn parseDocumentRoot(self: *Parser) ParseError!Id {
    const sp = self.cur().span;
    self.advance(); // lt
    if (self.curKind() != .name) return error.UnexpectedToken;
    const name = self.curText();
    self.advance();

    if (!std.mem.eql(u8, name, "plist")) return self.parseValueFromName(name, sp);

    try self.skipPlistAttributes();
    if (self.curKind() == .slash_gt) {
        self.advance();
        return error.MissingRoot; // `<plist/>` — no object inside
    }
    if (self.curKind() != .gt) return error.UnexpectedToken;
    self.advance();

    try self.skipInsignificantWhitespace();
    if (self.curKind() == .lt_slash) return error.MissingRoot; // `<plist></plist>`
    if (self.curKind() != .lt) return error.UnexpectedToken;
    const inner = try self.parseValue();

    try self.skipInsignificantWhitespace();
    switch (self.curKind()) {
        .lt => return error.MultipleRoots, // a second object before `</plist>`
        .lt_slash => {},
        else => return error.UnexpectedToken,
    }
    self.advance(); // lt_slash
    if (self.curKind() != .name or !std.mem.eql(u8, self.curText(), "plist")) return error.MismatchedTag;
    self.advance();
    if (self.curKind() != .gt) return error.UnexpectedToken;
    self.advance();
    return inner;
}

/// Skip `<plist>`'s own attributes — only `version` is recognized (and its
/// value ignored: this reader targets the one plist format regardless).
fn skipPlistAttributes(self: *Parser) ParseError!void {
    while (self.curKind() == .name) {
        const aname = self.curText();
        self.advance();
        if (!std.mem.eql(u8, aname, "version")) return error.UnexpectedAttribute;
        if (self.curKind() != .eq) return error.UnexpectedToken;
        self.advance();
        if (self.curKind() != .attr_value) return error.UnexpectedToken;
        self.advance();
    }
}

/// Parse one plistObject positioned at its opening `lt`.
fn parseValue(self: *Parser) ParseError!Id {
    const sp = self.cur().span;
    self.advance(); // lt
    if (self.curKind() != .name) return error.UnexpectedToken;
    const name = self.curText();
    self.advance();
    return self.parseValueFromName(name, sp);
}

/// Dispatch on an already-consumed opening tag name (shared by the wrapped-
/// and bare-root cases and every recursive `parseValue` call).
fn parseValueFromName(self: *Parser, name: []const u8, sp: Span) ParseError!Id {
    const eq = std.mem.eql;
    if (eq(u8, name, "dict")) return self.parseDict(sp);
    if (eq(u8, name, "array")) return self.parseArray(sp);
    if (eq(u8, name, "string")) return self.parseStringScalar(sp);
    if (eq(u8, name, "integer")) return self.parseNumberScalar(sp, .integer);
    if (eq(u8, name, "real")) return self.parseNumberScalar(sp, .float);
    if (eq(u8, name, "true")) return self.parseBoolScalar(sp, true);
    if (eq(u8, name, "false")) return self.parseBoolScalar(sp, false);
    if (eq(u8, name, "date")) return self.parseExtendedScalar(sp, .plist_date);
    if (eq(u8, name, "data")) return self.parseExtendedScalar(sp, .plist_data);
    // `key` only ever appears where `parseDict` explicitly looks for it.
    return error.UnknownElement;
}

/// After an element's name, before its body: no attributes are ever valid on
/// a plistObject (only `<plist>` — handled separately — carries one).
/// Returns whether the tag self-closed (`<.../>`, i.e. empty content).
fn expectNoAttrsThenBody(self: *Parser) ParseError!bool {
    if (self.curKind() == .name) return error.UnexpectedAttribute;
    if (self.curKind() == .slash_gt) {
        self.advance();
        return true;
    }
    if (self.curKind() != .gt) return error.UnexpectedToken;
    self.advance();
    return false;
}

fn parseDict(self: *Parser, sp: Span) ParseError!Id {
    if (try self.expectNoAttrsThenBody()) return self.buildMapping(&.{}, self.extent(sp));

    var entries: std.ArrayList(Id) = .empty;
    defer entries.deinit(self.allocator);
    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(self.allocator);

    while (true) {
        try self.skipInsignificantWhitespace();
        if (self.curKind() == .lt_slash) break;
        if (self.curKind() != .lt) return error.UnexpectedToken;

        const key_sp = self.cur().span;
        self.advance(); // lt
        if (self.curKind() != .name or !std.mem.eql(u8, self.curText(), "key")) return error.DictKeyExpected;
        self.advance();
        const key_text = try self.parseElementTextContent("key");
        const key_extent = self.extent(key_sp); // full `<key>…</key>`

        try self.skipInsignificantWhitespace();
        if (self.curKind() != .lt) return error.DictValueMissing;
        const value_id = try self.parseValue();

        // Last-wins duplicate handling (matches `plutil`/JSON convention):
        // overwrite the earlier entry's value in place rather than appending
        // a second entry for the same key.
        var replaced = false;
        for (entries.items, keys.items) |eid, existing_key| {
            if (std.mem.eql(u8, existing_key, key_text)) {
                self.nodes.items[eid].kind.keyvalue.value = value_id;
                replaced = true;
                break;
            }
        }
        if (!replaced) {
            const key_id = try self.stringNode(key_text, key_extent);
            // The entry span covers the whole `<key>…</key> … <value…>` pair
            // (both lines) so `Editor(Plist)` deletes/moves an entry as a unit;
            // the value's own end was recorded full-extent by `parseValue`.
            const entry_span = Span.init(key_sp.start, self.spans.items[value_id].end);
            const kv_id = try self.addNode(.{ .keyvalue = .{ .key = key_id, .value = value_id } }, entry_span);
            try entries.append(self.allocator, kv_id);
            try keys.append(self.allocator, key_text);
        }
    }
    self.advance(); // lt_slash
    if (self.curKind() != .name or !std.mem.eql(u8, self.curText(), "dict")) return error.MismatchedTag;
    self.advance();
    if (self.curKind() != .gt) return error.UnexpectedToken;
    self.advance();
    return self.buildMapping(entries.items, self.extent(sp));
}

fn parseArray(self: *Parser, sp: Span) ParseError!Id {
    if (try self.expectNoAttrsThenBody()) return self.buildSequence(&.{}, self.extent(sp));

    var items: std.ArrayList(Id) = .empty;
    defer items.deinit(self.allocator);
    while (true) {
        try self.skipInsignificantWhitespace();
        if (self.curKind() == .lt_slash) break;
        if (self.curKind() != .lt) return error.UnexpectedToken;
        try items.append(self.allocator, try self.parseValue());
    }
    self.advance(); // lt_slash
    if (self.curKind() != .name or !std.mem.eql(u8, self.curText(), "array")) return error.MismatchedTag;
    self.advance();
    if (self.curKind() != .gt) return error.UnexpectedToken;
    self.advance();
    return self.buildSequence(items.items, self.extent(sp));
}

fn parseStringScalar(self: *Parser, sp: Span) ParseError!Id {
    const text = try self.parseElementTextContent("string");
    return self.stringNode(text, self.extent(sp));
}

fn parseNumberScalar(self: *Parser, sp: Span, kind: NumberKind) ParseError!Id {
    const tag_name = if (kind == .integer) "integer" else "real";
    const raw = try self.parseElementTextContent(tag_name);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    switch (kind) {
        .integer => if (!isValidIntegerText(trimmed)) return error.InvalidInteger,
        .float => if (!isValidRealText(trimmed)) return error.InvalidReal,
    }
    return self.addNode(.{ .number = .{ .raw = trimmed, .kind = kind } }, self.extent(sp));
}

fn parseBoolScalar(self: *Parser, sp: Span, val: bool) ParseError!Id {
    const tag_name: []const u8 = if (val) "true" else "false";
    if (!try self.expectNoAttrsThenBody()) {
        while (self.curKind() != .lt_slash) {
            switch (self.curKind()) {
                .char_data => {
                    if (!isWhitespaceOnly(self.curText())) return error.InvalidBoolean;
                    self.advance();
                },
                .eof => return error.UnexpectedToken,
                else => return error.InvalidBoolean,
            }
        }
        self.advance(); // lt_slash
        if (self.curKind() != .name or !std.mem.eql(u8, self.curText(), tag_name)) return error.MismatchedTag;
        self.advance();
        if (self.curKind() != .gt) return error.UnexpectedToken;
        self.advance();
    }
    return self.addNode(.{ .boolean = val }, self.extent(sp));
}

fn parseExtendedScalar(self: *Parser, sp: Span, kind: ExtKind) ParseError!Id {
    const tag_name = if (kind == .plist_date) "date" else "data";
    const raw = try self.parseElementTextContent(tag_name);
    const text = if (kind == .plist_data) try self.stripAllWhitespace(raw) else std.mem.trim(u8, raw, " \t\r\n");
    switch (kind) {
        .plist_data => if (!isValidBase64(text)) return error.InvalidBase64,
        .plist_date => if (!isValidDateText(text)) return error.InvalidDate,
        else => unreachable,
    }
    return self.addNode(.{ .extended = .{ .kind = kind, .text = text } }, self.extent(sp));
}

// ── scalar text content ──────────────────────────────────────────────────────

/// Read a PCDATA-only element's decoded, owned content: entity references
/// resolved, CDATA taken literally, no nested elements allowed. `tag_name`
/// verifies the matching close tag.
fn parseElementTextContent(self: *Parser, tag_name: []const u8) ParseError![]const u8 {
    if (try self.expectNoAttrsThenBody()) return "";

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(self.allocator);
    while (self.curKind() != .lt_slash) {
        switch (self.curKind()) {
            .char_data => {
                try self.decodeInto(&buf, self.curText());
                self.advance();
            },
            .cdata => {
                try buf.appendSlice(self.allocator, self.curText());
                self.advance();
            },
            .lt => return error.NestedElementInScalar,
            .eof => return error.UnexpectedToken,
            else => return error.UnexpectedToken,
        }
    }
    self.advance(); // lt_slash
    if (self.curKind() != .name or !std.mem.eql(u8, self.curText(), tag_name)) return error.MismatchedTag;
    self.advance();
    if (self.curKind() != .gt) return error.UnexpectedToken;
    self.advance();
    return self.dupe(buf.items);
}

/// Decode XML entity references (predefined `&amp; &lt; &gt; &quot; &apos;`
/// and numeric `&#dd; / &#xhh;`) into `buf`. Duplicated in miniature from
/// `../xml/parser.zig`'s `decodeInto` (that one is a private method, not
/// `pub`) — small enough that sharing it isn't worth a cross-language import.
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

fn parseCharRef(ent: []const u8) ?u21 {
    if (ent.len < 2) return null;
    const hex = ent[1] == 'x' or ent[1] == 'X';
    const digits = if (hex) ent[2..] else ent[1..];
    if (digits.len == 0) return null;
    return std.fmt.parseInt(u21, digits, if (hex) 16 else 10) catch null;
}

/// Copy `s` into a fresh, owned allocation with every ASCII whitespace byte
/// removed — `<data>` is commonly wrapped across many indented lines, and
/// none of that formatting is part of the base64 payload.
fn stripAllWhitespace(self: *Parser, s: []const u8) ParseError![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(self.allocator);
    for (s) |c| {
        if (!isAsciiWhitespace(c)) try buf.append(self.allocator, c);
    }
    return self.dupe(buf.items);
}

// ── validation ───────────────────────────────────────────────────────────────

fn isValidIntegerText(s: []const u8) bool {
    if (s.len == 0) return false;
    var i: usize = if (s[0] == '+' or s[0] == '-') 1 else 0;
    if (i >= s.len) return false;
    while (i < s.len) : (i += 1) {
        if (!std.ascii.isDigit(s[i])) return false;
    }
    return true;
}

/// DTD grammar: `("+" | "-")? d+ ("."d*)? ("E" ("+" | "-") d+)?`. Lenient
/// beyond the letter of that grammar in two ways real-world writers rely on:
/// lowercase `e` is accepted, and the exponent's sign is optional — matching
/// CoreFoundation's own parser rather than the DTD comment literally.
fn isValidRealText(s: []const u8) bool {
    if (s.len == 0) return false;
    var i: usize = if (s[0] == '+' or s[0] == '-') 1 else 0;
    const int_start = i;
    while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {}
    if (i == int_start) return false;
    if (i < s.len and s[i] == '.') {
        i += 1;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {}
    }
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        i += 1;
        if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
        const exp_start = i;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {}
        if (i == exp_start) return false;
    }
    return i == s.len;
}

/// Standard base64 alphabet (`A-Za-z0-9+/`) with 0-2 trailing `=` padding
/// bytes; an empty string (empty `<data></data>`) is valid.
fn isValidBase64(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len and s[i] != '=') : (i += 1) {
        const c = s[i];
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '/') return false;
    }
    var pad: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] != '=') return false;
        pad += 1;
    }
    return pad <= 2;
}

/// Loose ISO-8601-subset check (DTD: "should conform to a subset of ISO
/// 8601... smaller units may be omitted"): every byte is a digit or one of
/// `-:.TZ+`, and the text is non-empty. Not a full calendar validation (no
/// range checks on month/day/hour, unlike TOML's stricter datetime reader) —
/// this is reader-first scope; a bogus-but-well-shaped date still round-trips
/// as the same text.
fn isValidDateText(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        const ok = std.ascii.isDigit(c) or c == '-' or c == ':' or c == '.' or c == 'T' or c == 'Z' or c == '+';
        if (!ok) return false;
    }
    return true;
}

fn isWhitespaceOnly(s: []const u8) bool {
    for (s) |c| if (!isAsciiWhitespace(c)) return false;
    return true;
}

fn isAsciiWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

// ── node construction ────────────────────────────────────────────────────────

/// Full-extent span for an element whose opening `<` was captured in
/// `start_sp`, now that the whole element has been consumed: `tokens[pos-1]`
/// is its just-consumed closing `>` / `/>`, so the span runs from the opening
/// `<` through that close. The reader itself never needs extents (it walks the
/// node tree, not spans); these are the edit-grade spans `Editor(Plist)`
/// splices against — a value node covers `<string>hi</string>`, a container
/// `<dict>…</dict>`, so a replace/delete swaps the whole element. See
/// `editor_helper.zig`.
fn extent(self: *const Parser, start_sp: Span) Span {
    return Span.init(start_sp.start, self.tokens[self.pos - 1].span.end);
}

fn addNode(self: *Parser, kind: AST.Node.Kind, span: Span) ParseError!Id {
    const id: Id = @intCast(self.nodes.items.len);
    try self.nodes.append(self.allocator, .{ .id = id, .kind = kind, .next_sibling = null });
    try self.spans.append(self.allocator, span);
    return id;
}

fn stringNode(self: *Parser, owned: []const u8, span: Span) ParseError!Id {
    return self.addNode(.{ .string = owned }, span);
}

fn buildSequence(self: *Parser, items: []const Id, span: Span) ParseError!Id {
    self.link(items);
    return self.addNode(.{ .sequence = if (items.len == 0) null else items[0] }, span);
}

fn buildMapping(self: *Parser, entries: []const Id, span: Span) ParseError!Id {
    self.link(entries);
    return self.addNode(.{ .mapping = if (entries.len == 0) null else entries[0] }, span);
}

fn link(self: *Parser, ids: []const Id) void {
    if (ids.len == 0) return;
    for (ids[0 .. ids.len - 1], ids[1..]) |cur_id, next_id| {
        self.nodes.items[cur_id].next_sibling = next_id;
    }
    self.nodes.items[ids[ids.len - 1]].next_sibling = null;
}

fn intern(self: *Parser, owned: []u8) ParseError![]const u8 {
    errdefer self.allocator.free(owned);
    try self.owned_strings.append(self.allocator, owned);
    return owned;
}

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

/// Consume whitespace-only `char_data`; a non-whitespace run, or a `cdata`
/// section, where only markup is allowed is `UnexpectedText`. Used at the
/// document prolog/epilog and between a `dict`/`array`'s element children —
/// plist has no mixed content anywhere.
fn skipInsignificantWhitespace(self: *Parser) ParseError!void {
    while (self.curKind() == .char_data) {
        if (!isWhitespaceOnly(self.curText())) return error.UnexpectedText;
        self.advance();
    }
    if (self.curKind() == .cdata) return error.UnexpectedText;
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;
const build_options = @import("build_options");

fn expectJson(src: []const u8, expected: []const u8) !void {
    if (comptime !build_options.lang_json) return error.SkipZigTest;
    var doc = try parse(testing.allocator, src, .XML);
    defer doc.deinit(testing.allocator);
    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try doc.ast.serialize(&w, .json);
    try testing.expectEqualStrings(expected, w.buffered());
}

const plist_open =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    \\<plist version="1.0">
;

test "empty dict" {
    try expectJson(plist_open ++ "<dict/></plist>", "{}\n");
}

test "empty array" {
    try expectJson(plist_open ++ "<array/></plist>",
        \\[]
        \\
    );
}

test "scalars: string, integer, real, true, false" {
    try expectJson(plist_open ++
        \\<dict>
        \\  <key>s</key><string>hi</string>
        \\  <key>i</key><integer>-42</integer>
        \\  <key>r</key><real>3.14</real>
        \\  <key>t</key><true/>
        \\  <key>f</key><false/>
        \\</dict></plist>
    ,
        \\{
        \\  "s": "hi",
        \\  "i": -42,
        \\  "r": 3.14,
        \\  "t": true,
        \\  "f": false
        \\}
        \\
    );
}

test "date and data become extended scalars, quoted as strings in JSON" {
    try expectJson(plist_open ++
        \\<dict>
        \\  <key>d</key><date>2011-11-01T12:00:00Z</date>
        \\  <key>b</key><data>SGVsbG8=</data>
        \\</dict></plist>
    ,
        \\{
        \\  "d": "2011-11-01T12:00:00Z",
        \\  "b": "SGVsbG8="
        \\}
        \\
    );
}

test "data payload strips embedded whitespace" {
    var doc = try parse(testing.allocator, plist_open ++
        \\<dict><key>b</key><data>
        \\  SGVs
        \\  bG8=
        \\</data></dict></plist>
    , .XML);
    defer doc.deinit(testing.allocator);
    const node = try doc.ast.getValByPath(&.{.{ .key = "b" }});
    try testing.expectEqualStrings("SGVsbG8=", node.kind.extended.text);
}

test "nested array and dict" {
    try expectJson(plist_open ++
        \\<dict>
        \\  <key>arr</key>
        \\  <array>
        \\    <string>one</string>
        \\    <integer>2</integer>
        \\    <dict><key>k</key><string>v</string></dict>
        \\    <array><true/><false/></array>
        \\  </array>
        \\</dict></plist>
    ,
        \\{
        \\  "arr": [
        \\    "one",
        \\    2,
        \\    {
        \\      "k": "v"
        \\    },
        \\    [
        \\      true,
        \\      false
        \\    ]
        \\  ]
        \\}
        \\
    );
}

test "duplicate keys: last wins, position of first occurrence kept" {
    try expectJson(plist_open ++
        \\<dict><key>a</key><string>1</string><key>a</key><string>2</string></dict></plist>
    ,
        \\{
        \\  "a": "2"
        \\}
        \\
    );
}

test "bare root object with no <plist> wrapper" {
    try expectJson("<dict><key>a</key><string>b</string></dict>",
        \\{
        \\  "a": "b"
        \\}
        \\
    );
}

test "bare root scalar (non-container document)" {
    try expectJson(plist_open ++ "<string>just a string</string></plist>",
        \\"just a string"
        \\
    );
}

test "entities decode in string and key content" {
    try expectJson(plist_open ++ "<dict><key>k</key><string>x &amp; y &#65; &#x42;</string></dict></plist>",
        \\{
        \\  "k": "x & y A B"
        \\}
        \\
    );
}

test "node spans cover full element extents (edit-grade, not just the opening '<')" {
    // The reader anchors nothing at a bare `<`; every node's span runs from its
    // opening `<` through its closing `>` so `Editor(Plist)` can splice whole
    // elements. Locks the contract the editor depends on.
    var doc = try parse(testing.allocator, "<dict><key>k</key><integer>42</integer></dict>", .XML);
    defer doc.deinit(testing.allocator);
    const src = "<dict><key>k</key><integer>42</integer></dict>";

    // root dict: whole document
    try testing.expectEqualStrings(src, sliceSpan(src, doc.node_spans[doc.ast.root]));

    // the value node: the full `<integer>42</integer>`
    const val = try doc.ast.getValByPath(&.{.{ .key = "k" }});
    try testing.expectEqualStrings("<integer>42</integer>", sliceSpan(src, doc.node_spans[val.id]));

    // the key node: the full `<key>k</key>`
    const key = try doc.ast.getKeyByPath(&.{.{ .key = "k" }});
    try testing.expectEqualStrings("<key>k</key>", sliceSpan(src, doc.node_spans[key.id]));

    // the keyvalue entry: `<key>…</key>` through the value's close, as a unit
    const entry_id = doc.ast.nodes[doc.ast.root].kind.mapping.?;
    try testing.expectEqualStrings("<key>k</key><integer>42</integer>", sliceSpan(src, doc.node_spans[entry_id]));
}

fn sliceSpan(src: []const u8, sp: Span) []const u8 {
    return src[sp.start..sp.end];
}

test "errors" {
    try testing.expectError(error.MissingRoot, parse(testing.allocator, "   ", .XML));
    try testing.expectError(error.MissingRoot, parse(testing.allocator, "<plist version=\"1.0\"/>", .XML));
    try testing.expectError(error.MultipleRoots, parse(testing.allocator, "<dict/><dict/>", .XML));
    try testing.expectError(error.DictValueMissing, parse(testing.allocator, "<dict><key>a</key></dict>", .XML));
    try testing.expectError(error.DictKeyExpected, parse(testing.allocator, "<dict><string>x</string><string>y</string></dict>", .XML));
    try testing.expectError(error.MismatchedTag, parse(testing.allocator, "<dict><key>a</key><string>1</dict>", .XML));
    try testing.expectError(error.UnknownElement, parse(testing.allocator, "<dict><key>a</key><foo>b</foo></dict>", .XML));
    try testing.expectError(error.InvalidInteger, parse(testing.allocator, "<integer>12x</integer>", .XML));
    try testing.expectError(error.InvalidReal, parse(testing.allocator, "<real>abc</real>", .XML));
    try testing.expectError(error.InvalidBoolean, parse(testing.allocator, "<true>x</true>", .XML));
    try testing.expectError(error.InvalidBase64, parse(testing.allocator, "<data>not base64!</data>", .XML));
    try testing.expectError(error.NestedElementInScalar, parse(testing.allocator, "<string><b/></string>", .XML));
    try testing.expectError(error.UnsupportedEntity, parse(testing.allocator, "<string>&bogus;</string>", .XML));
    try testing.expectError(error.UnexpectedAttribute, parse(testing.allocator, "<dict x=\"1\"/>", .XML));
    try testing.expectError(error.UnexpectedText, parse(testing.allocator, "<dict>junk<key>a</key><string>b</string></dict>", .XML));
}
