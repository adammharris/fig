//! The parser turns YAML tokens into a concrete syntax tree.
//! Depends on the tokenizer and the abstract Document struct.

const std = @import("std");
const AST = @import("../ast.zig");
const Document = @import("../document.zig");
const Span = @import("../util/span.zig");
const Unicode = @import("../util/util.zig").Unicode;
const testing = std.testing;
const Tokenizer = @import("tokenizer.zig");
const Token = Tokenizer.Token;
const Type = @import("yaml.zig").Type;

const Parser = @This();

const ContainerKind = enum { sequence, mapping };
const OpenContainer = struct {
    id: AST.Node.Id,
    kind: ContainerKind,
    first_child: ?AST.Node.Id = null,
    last_child: ?AST.Node.Id = null,
    pending_key: ?AST.Node.Id = null,
    pending_value_span: usize = 0,
    pending_sequence_item_span: ?usize = null,
    pending_sequence_item: bool = false,
    continues_sequence_item: bool = false,
};

nodes: std.ArrayList(AST.Node) = .empty,
node_spans: std.ArrayList(Span) = .empty,
container_stack: std.ArrayList(OpenContainer) = .empty,
owned_strings: std.ArrayList([]const u8) = .empty,
tokens: []const Token = &.{},
index: usize = 0,
force_new_container: bool = false,
root: ?AST.Node.Id = null,
doc_started: bool = false,
doc_ended: bool = false,

allocator: std.mem.Allocator,
source: []const u8 = "",

const ParseError = error{ UnexpectedToken, EmptyDocument, UnclosedString, InvalidUnicodeEscape, MultipleDocuments };
const ParserError = ParseError || std.mem.Allocator.Error;

/// Primary entry point
/// Pass allocator, input, and type, and get a Document.
pub fn parseAbstract(allocator: std.mem.Allocator, input: []const u8, format: Type) !AST {
    const parsed = try parse(allocator, input, format);
    allocator.free(parsed.node_spans);
    return parsed.ast;
}

pub fn parse(allocator: std.mem.Allocator, input: []const u8, format: Type) !Document {
    var parser: Parser = .{ .allocator = allocator };
    defer parser.deinit();
    return parser.parseOnce(input, format);
}

/// Secondary entry point, called on a parser object.
/// Caller must handle memory by calling `defer deinit` or similar.
pub fn parseOnce(self: *Parser, input: []const u8, format: Type) !Document {
    self.source = input;

    var tokenizer: Tokenizer = .{
        .allocator = self.allocator,
        .source = input,
        .type = format,
    };

    self.tokens = try tokenizer.tokenize();
    defer self.allocator.free(self.tokens);

    while (true) {
        self.skipTriviaNoNewline();
        switch (self.peek().kind) {
            .indent => {
                if (self.container_stack.items.len > 0 and self.currentContainer().continues_sequence_item) {
                    self.currentContainer().continues_sequence_item = false;
                } else {
                    self.force_new_container = true;
                }
                _ = self.advance();
            },
            .dedent => {
                try self.closePendingEmptyValue();
                const dedent = self.advance();
                const id = try self.closeContainer(dedent.span.end);
                try self.finishValue(id);
            },
            .newline => _ = self.advance(),
            .doc_start => {
                // A second document start (or one after content) is multi-doc,
                // which is out of scope.
                if (self.doc_started or self.nodes.items.len > 0) return ParseError.MultipleDocuments;
                self.doc_started = true;
                _ = self.advance();
            },
            .doc_end => {
                self.doc_ended = true;
                _ = self.advance();
            },
            .dash => {
                if (self.doc_ended) return ParseError.MultipleDocuments;
                try self.closeSequenceItemContinuation();
                try self.parseSequenceEntry();
            },
            .scalar => {
                if (self.doc_ended) return ParseError.MultipleDocuments;
                try self.closeSequenceItemContinuation();
                if (self.isMappingStart()) {
                    try self.parseMappingEntry();
                } else if (self.container_stack.items.len == 0 and self.root == null) {
                    // A bare scalar is a valid single-node document, but a plain
                    // scalar cannot begin with a flow indicator: such a token is
                    // malformed or unsupported flow, not a string. (Flow
                    // collections are handled in a later phase.)
                    if (invalidPlainStart(self.peek().source(self.source))) return ParseError.UnexpectedToken;
                    const value_id = try self.parseScalar();
                    try self.finishValue(value_id);
                } else {
                    return ParseError.UnexpectedToken;
                }
            },
            .block_header => {
                if (self.doc_ended) return ParseError.MultipleDocuments;
                try self.closeSequenceItemContinuation();
                if (self.container_stack.items.len == 0 and self.root == null) {
                    const value_id = try self.parseBlockScalar();
                    try self.finishValue(value_id);
                } else {
                    return ParseError.UnexpectedToken;
                }
            },
            .end_of_file => break,
            else => return ParseError.UnexpectedToken,
        }
    }

    if (self.nodes.items.len == 0) return ParseError.EmptyDocument;

    while (self.container_stack.items.len > 0) {
        try self.closePendingEmptyValue();
        const id = try self.closeContainer(self.peek().span.end);
        try self.finishValue(id);
    }

    const root = self.root orelse return ParseError.EmptyDocument;
    const nodes = try self.nodes.toOwnedSlice(self.allocator);
    errdefer self.allocator.free(nodes);
    self.nodes = .empty;
    const node_spans = try self.node_spans.toOwnedSlice(self.allocator);
    errdefer self.allocator.free(node_spans);
    self.node_spans = .empty;
    const owned_strings = try self.owned_strings.toOwnedSlice(self.allocator);
    self.owned_strings = .empty;
    return .{
        .source = input,
        .ast = .{
            .allocator = self.allocator,
            .owned_strings = owned_strings,
            .root = root,
            .nodes = nodes,
        },
        .node_spans = node_spans,
    };
}

pub fn deinit(self: *Parser) void {
    self.container_stack.deinit(self.allocator);
    self.nodes.deinit(self.allocator);
    self.node_spans.deinit(self.allocator);
    for (self.owned_strings.items) |string| {
        self.allocator.free(string);
    }
    self.owned_strings.deinit(self.allocator);
}

fn parseSequenceEntry(self: *Parser) ParserError!void {
    const dash = self.advance();
    const sequence_id = try self.ensureContainer(.sequence);
    self.clearPendingSequenceItem(sequence_id);
    self.skipTriviaNoNewline();

    switch (self.peek().kind) {
        .newline, .dedent, .end_of_file => {
            self.currentContainer().pending_sequence_item = true;
            self.currentContainer().pending_sequence_item_span = dash.span.end;
        },
        .scalar => {
            if (self.isMappingStart()) {
                const mapping_id = try self.openContainer(.mapping, self.peek().span.start);
                self.containerById(mapping_id).continues_sequence_item = true;
                try self.parseMappingEntry();
            } else {
                const value_id = try self.parseScalar();
                try self.finishValue(value_id);
            }
        },
        .block_header => {
            const value_id = try self.parseBlockScalar();
            try self.finishValue(value_id);
        },
        .dash => try self.parseSequenceEntry(),
        else => return ParseError.UnexpectedToken,
    }
}

fn parseMappingEntry(self: *Parser) ParserError!void {
    const mapping_id = try self.ensureContainer(.mapping);
    try self.closePendingEmptyValue();

    const key_id = try self.parseScalar();
    self.skipTriviaNoNewline();
    if (self.peek().kind != .colon) return ParseError.UnexpectedToken;
    const colon = self.advance();

    {
        const parent = self.containerById(mapping_id);
        parent.pending_key = key_id;
        parent.pending_value_span = colon.span.end;
    }

    self.skipTriviaNoNewline();
    switch (self.peek().kind) {
        .scalar => {
            if (self.isMappingStart()) {
                const child_id = try self.openContainer(.mapping, self.peek().span.start);
                try self.parseMappingEntry();
                const id = try self.closeContainer(self.node_spans.items[child_id].end);
                try self.finishValue(id);
            } else {
                const value_id = try self.parseScalar();
                try self.finishValue(value_id);
            }
        },
        .dash => {
            const child_id = try self.openContainer(.sequence, self.peek().span.start);
            try self.parseSequenceEntry();
            const id = try self.closeContainer(self.node_spans.items[child_id].end);
            try self.finishValue(id);
        },
        .block_header => {
            const value_id = try self.parseBlockScalar();
            try self.finishValue(value_id);
        },
        .newline, .dedent, .end_of_file => {},
        else => return ParseError.UnexpectedToken,
    }
}

fn parseScalar(self: *Parser) ParserError!AST.Node.Id {
    if (self.peek().kind != .scalar) return ParseError.UnexpectedToken;
    const token = self.advance();
    return self.addNode(try self.scalarKind(token.source(self.source)), token.span);
}

const BlockStyle = enum { literal, folded };
const BlockChomp = enum { clip, strip, keep };

/// Parses a block scalar: a `block_header` token, the header line's newline,
/// then an optional `block_scalar` body token. Produces a single string node
/// spanning the whole construct, with folding/chomping applied.
fn parseBlockScalar(self: *Parser) ParserError!AST.Node.Id {
    const header = self.advance();
    const header_source = header.source(self.source);

    // The tokenizer puts a trailing comment and the header-line newline between
    // the header and the body; skip past them to reach the body token.
    while (true) {
        switch (self.peek().kind) {
            .whitespace, .comment => _ = self.advance(),
            else => break,
        }
    }
    if (self.peek().kind == .newline) _ = self.advance();

    var span_end = header.span.end;
    var value: []const u8 = "";
    if (self.peek().kind == .block_scalar) {
        const body = self.advance();
        span_end = body.span.end;
        value = try self.decodeBlockScalar(header_source, header.span.start, body.source(self.source));
    }

    return self.addNode(.{ .string = value }, .init(header.span.start, span_end));
}

fn decodeBlockScalar(self: *Parser, header: []const u8, header_start: usize, body: []const u8) ParserError![]const u8 {
    const style: BlockStyle = if (header[0] == '|') .literal else .folded;
    var chomp: BlockChomp = .clip;
    var explicit: ?usize = null;
    for (header[1..]) |c| switch (c) {
        '-' => chomp = .strip,
        '+' => chomp = .keep,
        '1'...'9' => explicit = c - '0',
        else => {},
    };

    const content_indent: usize = if (explicit) |d|
        self.lineIndentOf(header_start) + d
    else
        autodetectIndent(body);

    // Split into physical lines, dropping the empty segment a trailing newline
    // would otherwise create so it does not read as an extra blank line.
    const ends_nl = body.len > 0 and body[body.len - 1] == '\n';
    const work = if (ends_nl) body[0 .. body.len - 1] else body;

    var total_lines: usize = 0;
    var last_content: ?usize = null;
    {
        var it = LineIter{ .source = work };
        var idx: usize = 0;
        while (it.next()) |line| : (idx += 1) {
            if (!isAllWhitespace(line)) last_content = idx;
            total_lines += 1;
        }
    }

    var decoded: std.ArrayList(u8) = .empty;
    errdefer decoded.deinit(self.allocator);

    if (last_content) |last| {
        var it = LineIter{ .source = work };
        var idx: usize = 0;
        var emitted = false;
        var prev_blank = false;
        var prev_more = false;
        while (it.next()) |line| : (idx += 1) {
            if (idx > last) break; // trailing blanks are decided by chomping
            const blank = isAllWhitespace(line);
            const text = if (blank) "" else dedentLine(line, content_indent);
            const more = text.len > 0 and text[0] == ' ';

            if (style == .literal) {
                if (emitted) try decoded.append(self.allocator, '\n');
                try decoded.appendSlice(self.allocator, text);
            } else if (!emitted) {
                try decoded.appendSlice(self.allocator, text);
            } else if (blank) {
                try decoded.append(self.allocator, '\n');
            } else {
                if (prev_blank) {
                    // The blank line already emitted the break.
                } else if (prev_more or more) {
                    try decoded.append(self.allocator, '\n');
                } else {
                    try decoded.append(self.allocator, ' ');
                }
                try decoded.appendSlice(self.allocator, text);
            }

            emitted = true;
            prev_blank = blank;
            prev_more = more and !blank;
        }

        const trailing_blanks = total_lines - 1 - last;
        const present_breaks = trailing_blanks + @as(usize, if (ends_nl) 1 else 0);
        const keep_breaks: usize = switch (chomp) {
            .strip => 0,
            .clip => @min(present_breaks, 1),
            .keep => present_breaks,
        };
        for (0..keep_breaks) |_| try decoded.append(self.allocator, '\n');
    } else if (chomp == .keep) {
        const present_breaks = (total_lines -| 1) + @as(usize, if (ends_nl) 1 else 0);
        for (0..present_breaks) |_| try decoded.append(self.allocator, '\n');
    }

    return self.ownString(try decoded.toOwnedSlice(self.allocator));
}

/// Counts the leading spaces on the source line containing `pos`.
fn lineIndentOf(self: *const Parser, pos: usize) usize {
    var start = pos;
    while (start > 0 and self.source[start - 1] != '\n') start -= 1;
    var i = start;
    while (i < pos and self.source[i] == ' ') i += 1;
    return i - start;
}

const LineIter = struct {
    source: []const u8,
    i: usize = 0,
    done: bool = false,
    fn next(self: *LineIter) ?[]const u8 {
        if (self.done) return null;
        const start = self.i;
        while (self.i < self.source.len and self.source[self.i] != '\n') self.i += 1;
        const line = self.source[start..self.i];
        if (self.i < self.source.len) self.i += 1 else self.done = true;
        return line;
    }
};

fn isAllWhitespace(line: []const u8) bool {
    for (line) |c| {
        if (c != ' ' and c != '\t') return false;
    }
    return true;
}

fn dedentLine(line: []const u8, n: usize) []const u8 {
    var k: usize = 0;
    while (k < n and k < line.len and line[k] == ' ') k += 1;
    return line[k..];
}

fn autodetectIndent(body: []const u8) usize {
    var it = LineIter{ .source = body };
    while (it.next()) |line| {
        if (isAllWhitespace(line)) continue;
        var k: usize = 0;
        while (k < line.len and line[k] == ' ') k += 1;
        return k;
    }
    return 0;
}

fn ensureContainer(self: *Parser, kind: ContainerKind) ParserError!AST.Node.Id {
    if (!self.force_new_container and self.container_stack.items.len > 0) {
        const current = self.currentContainer();
        if (current.kind == kind) return current.id;
    }

    self.force_new_container = false;
    return self.openContainer(kind, startOfCurrentToken(self));
}

fn openContainer(self: *Parser, kind: ContainerKind, start: usize) ParserError!AST.Node.Id {
    const id = try self.addNode(switch (kind) {
        .sequence => .{ .sequence = null },
        .mapping => .{ .mapping = null },
    }, .init(start, start));

    try self.container_stack.append(self.allocator, .{
        .id = id,
        .kind = kind,
    });

    return id;
}

fn closeContainer(self: *Parser, span_end: usize) ParserError!AST.Node.Id {
    if (self.container_stack.items.len == 0) return ParseError.UnexpectedToken;
    const container = self.container_stack.pop().?;
    if (container.first_child == null) {
        self.node_spans.items[container.id].end = span_end;
    }
    return container.id;
}

fn finishValue(self: *Parser, value_id: AST.Node.Id) ParserError!void {
    if (self.container_stack.items.len == 0) {
        self.root = value_id;
        return;
    }

    const parent = self.currentContainer();
    switch (parent.kind) {
        .sequence => {
            self.attachChild(parent, value_id);
            parent.pending_sequence_item = false;
            parent.pending_sequence_item_span = null;
        },
        .mapping => {
            const key_id = parent.pending_key orelse return ParseError.UnexpectedToken;
            parent.pending_key = null;

            const key_span = self.node_spans.items[key_id];
            const value_span = self.node_spans.items[value_id];
            const pair_id = try self.addNode(.{ .keyvalue = .{
                .key = key_id,
                .value = value_id,
            } }, .{
                .start = key_span.start,
                .end = value_span.end,
            });

            self.attachChild(parent, pair_id);
        },
    }
}

fn closePendingEmptyValue(self: *Parser) ParserError!void {
    if (self.container_stack.items.len == 0) return;

    const parent = self.currentContainer();
    switch (parent.kind) {
        .sequence => if (parent.pending_sequence_item) {
            const span = parent.pending_sequence_item_span orelse 0;
            const value_id = try self.addNode(.null_, .init(span, span));
            try self.finishValue(value_id);
        },
        .mapping => if (parent.pending_key != null) {
            const value_id = try self.addNode(.null_, .init(parent.pending_value_span, parent.pending_value_span));
            try self.finishValue(value_id);
        },
    }
}

fn closeSequenceItemContinuation(self: *Parser) ParserError!void {
    if (self.container_stack.items.len == 0) return;
    if (!self.currentContainer().continues_sequence_item) return;

    self.currentContainer().continues_sequence_item = false;
    try self.closePendingEmptyValue();
    const id = try self.closeContainer(self.node_spans.items[self.currentContainer().id].end);
    try self.finishValue(id);
}

fn clearPendingSequenceItem(self: *Parser, sequence_id: AST.Node.Id) void {
    const parent = self.containerById(sequence_id);
    parent.pending_sequence_item = false;
    parent.pending_sequence_item_span = null;
}

fn attachChild(self: *Parser, parent: *OpenContainer, child_id: AST.Node.Id) void {
    if (parent.first_child) |_| {
        self.nodes.items[parent.last_child.?].next_sibling = child_id;
    } else {
        parent.first_child = child_id;
        switch (parent.kind) {
            .sequence => self.nodes.items[parent.id].kind = .{ .sequence = child_id },
            .mapping => self.nodes.items[parent.id].kind = .{ .mapping = child_id },
        }
    }

    parent.last_child = child_id;
    self.node_spans.items[parent.id].end = self.node_spans.items[child_id].end;
}

fn scalarKind(self: *Parser, source: []const u8) ParserError!AST.Node.Kind {
    if (source.len >= 2 and source[0] == '\'') return .{ .string = try self.getSingleQuotedString(source) };
    if (source.len >= 2 and source[0] == '"') return .{ .string = try self.getDoubleQuotedString(source) };
    if (std.mem.eql(u8, source, "{}")) return .{ .mapping = null };
    if (std.mem.eql(u8, source, "[]")) return .{ .sequence = null };
    if (eqlAny(source, &.{ "null", "Null", "NULL", "~" })) return .null_;
    if (eqlAny(source, &.{ "true", "True", "TRUE" })) return .{ .boolean = true };
    if (eqlAny(source, &.{ "false", "False", "FALSE" })) return .{ .boolean = false };
    switch (classifyNumber(source)) {
        .integer => return .{ .number = .{ .raw = source, .kind = .integer } },
        .float => return .{ .number = .{ .raw = source, .kind = .float } },
        .not_number => {},
    }
    return .{ .string = source };
}

fn eqlAny(source: []const u8, options: []const []const u8) bool {
    for (options) |option| {
        if (std.mem.eql(u8, source, option)) return true;
    }
    return false;
}

fn getSingleQuotedString(self: *Parser, source: []const u8) ParserError![]const u8 {
    if (source.len < 2 or source[0] != '\'' or source[source.len - 1] != '\'') {
        return ParseError.UnclosedString;
    }
    const inner = source[1 .. source.len - 1];

    if (std.mem.indexOfScalar(u8, inner, '\'') == null) return inner;

    var decoded: std.ArrayList(u8) = .empty;
    errdefer decoded.deinit(self.allocator);

    var index: usize = 0;
    while (index < inner.len) {
        if (inner[index] != '\'') {
            try decoded.append(self.allocator, inner[index]);
            index += 1;
            continue;
        }

        if (index + 1 >= inner.len or inner[index + 1] != '\'') {
            return ParseError.UnexpectedToken;
        }
        try decoded.append(self.allocator, '\'');
        index += 2;
    }

    return self.ownString(try decoded.toOwnedSlice(self.allocator));
}

fn getDoubleQuotedString(self: *Parser, source: []const u8) ParserError![]const u8 {
    if (source.len < 2 or source[0] != '"' or source[source.len - 1] != '"') {
        return ParseError.UnclosedString;
    }
    const inner = source[1 .. source.len - 1];

    if (std.mem.indexOfScalar(u8, inner, '\\') == null) return inner;

    var decoded: std.ArrayList(u8) = .empty;
    errdefer decoded.deinit(self.allocator);

    var index: usize = 0;
    while (index < inner.len) {
        const char = inner[index];
        if (char != '\\') {
            try decoded.append(self.allocator, char);
            index += 1;
            continue;
        }

        index += 1;
        if (index >= inner.len) return ParseError.UnclosedString;

        switch (inner[index]) {
            '0' => try decoded.append(self.allocator, 0x00),
            'a' => try decoded.append(self.allocator, 0x07),
            'b' => try decoded.append(self.allocator, 0x08),
            't', '\t' => try decoded.append(self.allocator, '\t'),
            'n' => try decoded.append(self.allocator, '\n'),
            'v' => try decoded.append(self.allocator, 0x0b),
            'f' => try decoded.append(self.allocator, 0x0c),
            'r' => try decoded.append(self.allocator, '\r'),
            'e' => try decoded.append(self.allocator, 0x1b),
            ' ' => try decoded.append(self.allocator, ' '),
            '"' => try decoded.append(self.allocator, '"'),
            '/' => try decoded.append(self.allocator, '/'),
            '\\' => try decoded.append(self.allocator, '\\'),
            'N' => try appendCodepoint(&decoded, self.allocator, 0x85),
            '_' => try appendCodepoint(&decoded, self.allocator, 0xA0),
            'L' => try appendCodepoint(&decoded, self.allocator, 0x2028),
            'P' => try appendCodepoint(&decoded, self.allocator, 0x2029),
            'x' => {
                const codepoint = try parseHexEscape(inner, index + 1, 2);
                try appendCodepoint(&decoded, self.allocator, codepoint);
                index += 2;
            },
            'u' => {
                const codepoint = try parseHexEscape(inner, index + 1, 4);
                try appendCodepoint(&decoded, self.allocator, codepoint);
                index += 4;
            },
            'U' => {
                const codepoint = try parseHexEscape(inner, index + 1, 8);
                try appendCodepoint(&decoded, self.allocator, codepoint);
                index += 8;
            },
            else => return ParseError.UnexpectedToken,
        }
        index += 1;
    }

    return self.ownString(try decoded.toOwnedSlice(self.allocator));
}

fn ownString(self: *Parser, string: []const u8) ParserError![]const u8 {
    errdefer self.allocator.free(string);
    try self.owned_strings.append(self.allocator, string);
    return string;
}

fn parseHexEscape(source: []const u8, start: usize, digits: usize) ParserError!u21 {
    if (start + digits > source.len) return ParseError.UnclosedString;
    return std.fmt.parseInt(u21, source[start .. start + digits], 16) catch return ParseError.InvalidUnicodeEscape;
}

fn appendCodepoint(decoded: *std.ArrayList(u8), allocator: std.mem.Allocator, codepoint: u21) ParserError!void {
    if (Unicode.isHighSurrogate(codepoint) or Unicode.isLowSurrogate(codepoint)) {
        return ParseError.InvalidUnicodeEscape;
    }

    var buf: [4]u8 = undefined;
    const written = std.unicode.utf8Encode(codepoint, &buf) catch return ParseError.InvalidUnicodeEscape;
    try decoded.appendSlice(allocator, buf[0..written]);
}

const NumberClass = enum { not_number, integer, float };

// The YAML tokenizer doesn't distinguish numbers from other plain scalars, so
// we classify them here against the YAML 1.2.2 core schema: decimal ints with
// an optional sign, hex (0x) and octal (0o) ints, floats with fractions and/or
// exponents, and the special floats .inf / .nan.
fn classifyNumber(source: []const u8) NumberClass {
    if (source.len == 0) return .not_number;
    if (isInfNan(source)) return .float;

    // Hex and octal integers take no sign in the core schema.
    if (source.len > 2 and source[0] == '0' and (source[1] == 'x' or source[1] == 'o')) {
        const hex = source[1] == 'x';
        var i: usize = 2;
        while (i < source.len) : (i += 1) {
            const ok = if (hex) std.ascii.isHex(source[i]) else (source[i] >= '0' and source[i] <= '7');
            if (!ok) return .not_number;
        }
        return .integer;
    }

    var i: usize = 0;
    if (source[i] == '+' or source[i] == '-') i += 1;

    var mantissa_digits: usize = 0;
    while (i < source.len and std.ascii.isDigit(source[i])) : (i += 1) mantissa_digits += 1;

    var is_float = false;
    if (i < source.len and source[i] == '.') {
        is_float = true;
        i += 1;
        while (i < source.len and std.ascii.isDigit(source[i])) : (i += 1) mantissa_digits += 1;
    }
    if (mantissa_digits == 0) return .not_number;

    if (i < source.len and (source[i] == 'e' or source[i] == 'E')) {
        is_float = true;
        i += 1;
        if (i < source.len and (source[i] == '+' or source[i] == '-')) i += 1;
        var exp_digits: usize = 0;
        while (i < source.len and std.ascii.isDigit(source[i])) : (i += 1) exp_digits += 1;
        if (exp_digits == 0) return .not_number;
    }

    if (i != source.len) return .not_number;
    return if (is_float) .float else .integer;
}

fn isInfNan(source: []const u8) bool {
    var body = source;
    if (source[0] == '+' or source[0] == '-') body = source[1..];
    if (eqlAny(body, &.{ ".inf", ".Inf", ".INF" })) return true;
    return eqlAny(source, &.{ ".nan", ".NaN", ".NAN" });
}

/// True when a plain scalar token cannot legally begin a YAML plain scalar.
/// The empty flow collections `[]` and `{}` are the only flow forms accepted
/// for now; everything else flow-shaped is rejected until flow parsing lands.
fn invalidPlainStart(source: []const u8) bool {
    if (source.len == 0) return false;
    return switch (source[0]) {
        '[', ']', '{', '}', ',' => !std.mem.eql(u8, source, "[]") and !std.mem.eql(u8, source, "{}"),
        '?' => source.len >= 2 and (source[1] == ' ' or source[1] == '\t'),
        else => false,
    };
}

fn isMappingStart(self: *const Parser) bool {
    if (self.peek().kind != .scalar) return false;

    var lookahead = self.index + 1;
    while (lookahead < self.tokens.len) : (lookahead += 1) {
        switch (self.tokens[lookahead].kind) {
            .whitespace, .comment => {},
            .colon => return true,
            else => return false,
        }
    }
    return false;
}

fn addNode(self: *Parser, kind: AST.Node.Kind, span: Span) ParserError!AST.Node.Id {
    const id: AST.Node.Id = @intCast(self.nodes.items.len);
    try self.nodes.append(self.allocator, .{
        .id = id,
        .kind = kind,
        .next_sibling = null,
    });
    try self.node_spans.append(self.allocator, span);
    return id;
}

fn startOfCurrentToken(self: *const Parser) usize {
    return self.peek().span.start;
}

fn currentContainer(self: *Parser) *OpenContainer {
    return &self.container_stack.items[self.container_stack.items.len - 1];
}

fn containerById(self: *Parser, id: AST.Node.Id) *OpenContainer {
    for (self.container_stack.items) |*container| {
        if (container.id == id) return container;
    }
    unreachable;
}

fn skipTriviaNoNewline(self: *Parser) void {
    while (true) {
        switch (self.peek().kind) {
            .whitespace, .comment => _ = self.advance(),
            else => return,
        }
    }
}

fn peek(self: *const Parser) Token {
    return self.tokens[self.index];
}

fn advance(self: *Parser) Token {
    const token = self.tokens[self.index];
    self.index += 1;
    return token;
}

// =======
// Testing
// =======

fn testParser(input: []const u8, expected: AST) !void {
    const doc = try Parser.parse(testing.allocator, input, .v1_2_2);
    defer doc.deinit(testing.allocator);
    try testing.expect(expected.eql(doc.ast));
}

fn testParserError(input: []const u8, expected_error: anyerror) !void {
    if (Parser.parse(testing.allocator, input, .v1_2_2)) |doc| {
        defer doc.deinit(testing.allocator);
        try testing.expect(false);
    } else |err| {
        try testing.expectEqual(expected_error, err);
    }
}

test "simple YAML document" {
    try testParser(
        \\- hello: world
    , .{ .allocator = testing.allocator, .root = 0, .nodes = &[_]AST.Node{
        .{ .id = 0, .kind = .{ .sequence = 1 }, .next_sibling = null },
        .{
            .id = 1,
            .kind = .{ .mapping = 4 },
            .next_sibling = null,
        },
        .{
            .id = 2,
            .kind = .{ .string = "hello" },
            .next_sibling = null,
        },
        .{
            .id = 3,
            .kind = .{ .string = "world" },
            .next_sibling = null,
        },
        .{
            .id = 4,
            .kind = .{ .keyvalue = .{ .key = 2, .value = 3 } },
            .next_sibling = null,
        },
    } });
}

test "yaml flat mapping" {
    try testParser(
        "name: Ada\nage: 37\n",
        .{ .allocator = testing.allocator, .root = 0, .nodes = &[_]AST.Node{
            .{ .id = 0, .kind = .{ .mapping = 3 }, .next_sibling = null },
            .{ .id = 1, .kind = .{ .string = "name" }, .next_sibling = null },
            .{ .id = 2, .kind = .{ .string = "Ada" }, .next_sibling = null },
            .{ .id = 3, .kind = .{ .keyvalue = .{ .key = 1, .value = 2 } }, .next_sibling = 6 },
            .{ .id = 4, .kind = .{ .string = "age" }, .next_sibling = null },
            .{ .id = 5, .kind = .{ .number = .{ .raw = "37", .kind = .integer } }, .next_sibling = null },
            .{ .id = 6, .kind = .{ .keyvalue = .{ .key = 4, .value = 5 } }, .next_sibling = null },
        } },
    );
}

test "yaml nested mapping" {
    try testParser(
        "root:\n  child: value\nnext: true\n",
        .{ .allocator = testing.allocator, .root = 0, .nodes = &[_]AST.Node{
            .{ .id = 0, .kind = .{ .mapping = 6 }, .next_sibling = null },
            .{ .id = 1, .kind = .{ .string = "root" }, .next_sibling = null },
            .{ .id = 2, .kind = .{ .mapping = 5 }, .next_sibling = null },
            .{ .id = 3, .kind = .{ .string = "child" }, .next_sibling = null },
            .{ .id = 4, .kind = .{ .string = "value" }, .next_sibling = null },
            .{ .id = 5, .kind = .{ .keyvalue = .{ .key = 3, .value = 4 } }, .next_sibling = null },
            .{ .id = 6, .kind = .{ .keyvalue = .{ .key = 1, .value = 2 } }, .next_sibling = 9 },
            .{ .id = 7, .kind = .{ .string = "next" }, .next_sibling = null },
            .{ .id = 8, .kind = .{ .boolean = true }, .next_sibling = null },
            .{ .id = 9, .kind = .{ .keyvalue = .{ .key = 7, .value = 8 } }, .next_sibling = null },
        } },
    );
}

test "yaml sequence item mapping continuation" {
    const input =
        \\- adapter: CodeLLDB
        \\  label: Debug library tests
        \\  build:
        \\    command: zig
        \\    args:
        \\      - build
        \\      - install-tests
        \\
    ;

    const doc = try Parser.parse(testing.allocator, input, .v1_2_2);
    defer doc.deinit(testing.allocator);

    const label = try doc.ast.getValByPath(&.{
        .{ .index = 0 },
        .{ .key = "label" },
    });
    try testing.expectEqualSlices(u8, "Debug library tests", label.kind.string);

    const build = try doc.ast.getValByPath(&.{
        .{ .index = 0 },
        .{ .key = "build" },
    });
    try testing.expect(std.meta.activeTag(build.kind) == .mapping);

    var args_pair_id = build.kind.mapping.?;
    while (!std.mem.eql(u8, "args", doc.ast.nodes[doc.ast.nodes[args_pair_id].kind.keyvalue.key].kind.string)) {
        args_pair_id = doc.ast.nodes[args_pair_id].next_sibling orelse return error.NotFound;
    }

    const args = doc.ast.nodes[doc.ast.nodes[args_pair_id].kind.keyvalue.value];
    try testing.expect(std.meta.activeTag(args.kind) == .sequence);
    const first_arg_id = args.kind.sequence.?;
    const second_arg = doc.ast.nodes[doc.ast.nodes[first_arg_id].next_sibling.?];
    try testing.expectEqualSlices(u8, "install-tests", second_arg.kind.string);
}

test "yaml empty flow collection scalars" {
    const doc = try Parser.parse(testing.allocator, "env: {}\ntags: []\n", .v1_2_2);
    defer doc.deinit(testing.allocator);

    const env = try doc.ast.getValByPath(&.{.{ .key = "env" }});
    try testing.expectEqual(@as(?AST.Node.Id, null), env.kind.mapping);

    const tags = try doc.ast.getValByPath(&.{.{ .key = "tags" }});
    try testing.expectEqual(@as(?AST.Node.Id, null), tags.kind.sequence);
}

test "yaml decodes single quoted scalars" {
    const input =
        \\single: 'here''s to "quotes"'
        \\path: 'C:\Temp'
        \\"quoted:key": 'value # not comment'
        \\
    ;

    const doc = try Parser.parse(testing.allocator, input, .v1_2_2);
    defer doc.deinit(testing.allocator);

    const single = try doc.ast.getValByPath(&.{.{ .key = "single" }});
    try testing.expectEqualSlices(u8, "here's to \"quotes\"", single.kind.string);

    const path = try doc.ast.getValByPath(&.{.{ .key = "path" }});
    try testing.expectEqualSlices(u8, "C:\\Temp", path.kind.string);

    const quoted_key = try doc.ast.getValByPath(&.{.{ .key = "quoted:key" }});
    try testing.expectEqualSlices(u8, "value # not comment", quoted_key.kind.string);
}

test "yaml decodes double quoted scalars" {
    const input = "double: \"quote: \\\" slash: \\\\ newline: \\n tab: \\t zero: \\0 hex: \\x41 unicode: \\u00E9 big: \\U0001D11E\"\nnumber: \"37\"\nplain: 37\n";
    const doc = try Parser.parse(testing.allocator, input, .v1_2_2);
    defer doc.deinit(testing.allocator);

    const double = try doc.ast.getValByPath(&.{.{ .key = "double" }});
    try testing.expectEqualSlices(u8, "quote: \" slash: \\ newline: \n tab: \t zero: \x00 hex: A unicode: \xC3\xA9 big: \xF0\x9D\x84\x9E", double.kind.string);

    const quoted_number = try doc.ast.getValByPath(&.{.{ .key = "number" }});
    try testing.expectEqualSlices(u8, "37", quoted_number.kind.string);

    const plain_number = try doc.ast.getValByPath(&.{.{ .key = "plain" }});
    try testing.expect(std.meta.activeTag(plain_number.kind) == .number);
}

test "yaml rejects invalid double quoted escapes" {
    try testParserError("bad: \"\\c\"\n", error.UnexpectedToken);
    try testParserError("bad: \"\\xq0\"\n", error.InvalidUnicodeEscape);
    try testParserError("bad: \"\\uD800\"\n", error.InvalidUnicodeEscape);
}

test "yaml core schema type resolution" {
    const input =
        \\n1: null
        \\n2: NULL
        \\n3: ~
        \\b1: True
        \\b2: FALSE
        \\i1: 42
        \\i2: -7
        \\i3: +5
        \\i4: 0x1A
        \\i5: 0o17
        \\f1: 3.14
        \\f2: 1e3
        \\f3: -.inf
        \\f4: .nan
        \\s1: yes
        \\s2: 1_000
        \\s3: 0x
        \\
    ;
    const doc = try Parser.parse(testing.allocator, input, .v1_2_2);
    defer doc.deinit(testing.allocator);

    const ast = &doc.ast;
    for ([_][]const u8{ "n1", "n2", "n3" }) |key| {
        try testing.expect(std.meta.activeTag((try ast.getValByPath(&.{.{ .key = key }})).kind) == .null_);
    }
    try testing.expect((try ast.getValByPath(&.{.{ .key = "b1" }})).kind.boolean == true);
    try testing.expect((try ast.getValByPath(&.{.{ .key = "b2" }})).kind.boolean == false);

    const Case = struct { key: []const u8, kind: enum { integer, float }, raw: []const u8 };
    const numbers = [_]Case{
        .{ .key = "i1", .kind = .integer, .raw = "42" },
        .{ .key = "i2", .kind = .integer, .raw = "-7" },
        .{ .key = "i3", .kind = .integer, .raw = "+5" },
        .{ .key = "i4", .kind = .integer, .raw = "0x1A" },
        .{ .key = "i5", .kind = .integer, .raw = "0o17" },
        .{ .key = "f1", .kind = .float, .raw = "3.14" },
        .{ .key = "f2", .kind = .float, .raw = "1e3" },
        .{ .key = "f3", .kind = .float, .raw = "-.inf" },
        .{ .key = "f4", .kind = .float, .raw = ".nan" },
    };
    for (numbers) |c| {
        const number = (try ast.getValByPath(&.{.{ .key = c.key }})).kind.number;
        try testing.expectEqualSlices(u8, c.raw, number.raw);
        try testing.expectEqualStrings(@tagName(c.kind), @tagName(number.kind));
    }

    // Things that look number-ish but are not core-schema numbers stay strings.
    for ([_][]const u8{ "s1", "s2", "s3" }) |key| {
        try testing.expect(std.meta.activeTag((try ast.getValByPath(&.{.{ .key = key }})).kind) == .string);
    }
}

test "yaml root scalar documents" {
    const plain = try Parser.parse(testing.allocator, "hello world\n", .v1_2_2);
    defer plain.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "hello world", plain.ast.nodes[plain.ast.root].kind.string);

    const number = try Parser.parse(testing.allocator, "42\n", .v1_2_2);
    defer number.deinit(testing.allocator);
    try testing.expect(std.meta.activeTag(number.ast.nodes[number.ast.root].kind) == .number);

    const quoted = try Parser.parse(testing.allocator, "\"quoted\"\n", .v1_2_2);
    defer quoted.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "quoted", quoted.ast.nodes[quoted.ast.root].kind.string);
}

test "yaml document markers wrap a single document" {
    const doc = try Parser.parse(testing.allocator, "---\nname: Ada\n...\n", .v1_2_2);
    defer doc.deinit(testing.allocator);
    const name = try doc.ast.getValByPath(&.{.{ .key = "name" }});
    try testing.expectEqualSlices(u8, "Ada", name.kind.string);
}

test "yaml rejects multiple documents" {
    try testParserError("---\na: 1\n---\nb: 2\n", error.MultipleDocuments);
    try testParserError("a: 1\n...\nb: 2\n", error.MultipleDocuments);
}

test "yaml colon inside a value stays in the scalar" {
    const doc = try Parser.parse(testing.allocator, "url: http://example.com\ntime: 12:30:00\n", .v1_2_2);
    defer doc.deinit(testing.allocator);
    const url = try doc.ast.getValByPath(&.{.{ .key = "url" }});
    try testing.expectEqualSlices(u8, "http://example.com", url.kind.string);
    const time = try doc.ast.getValByPath(&.{.{ .key = "time" }});
    try testing.expectEqualSlices(u8, "12:30:00", time.kind.string);
}

test "yaml literal block scalar preserves line breaks" {
    const input =
        \\desc: |
        \\  line one
        \\  line two
        \\next: x
        \\
    ;
    const doc = try Parser.parse(testing.allocator, input, .v1_2_2);
    defer doc.deinit(testing.allocator);
    const desc = try doc.ast.getValByPath(&.{.{ .key = "desc" }});
    try testing.expectEqualSlices(u8, "line one\nline two\n", desc.kind.string);
    const next = try doc.ast.getValByPath(&.{.{ .key = "next" }});
    try testing.expectEqualSlices(u8, "x", next.kind.string);
}

test "yaml folded block scalar folds line breaks" {
    const input =
        \\desc: >
        \\  one two
        \\  three
        \\
        \\  after blank
        \\
    ;
    const doc = try Parser.parse(testing.allocator, input, .v1_2_2);
    defer doc.deinit(testing.allocator);
    const desc = try doc.ast.getValByPath(&.{.{ .key = "desc" }});
    try testing.expectEqualSlices(u8, "one two three\nafter blank\n", desc.kind.string);
}

test "yaml block scalar chomping indicators" {
    // Clip (default) keeps one trailing newline; strip keeps none; keep keeps all.
    const clip = try Parser.parse(testing.allocator, "v: |\n  a\n\n\n", .v1_2_2);
    defer clip.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "a\n", (try clip.ast.getValByPath(&.{.{ .key = "v" }})).kind.string);

    const strip = try Parser.parse(testing.allocator, "v: |-\n  a\n\n\n", .v1_2_2);
    defer strip.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "a", (try strip.ast.getValByPath(&.{.{ .key = "v" }})).kind.string);

    const keep = try Parser.parse(testing.allocator, "v: |+\n  a\n\n\n", .v1_2_2);
    defer keep.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "a\n\n\n", (try keep.ast.getValByPath(&.{.{ .key = "v" }})).kind.string);
}

test "yaml block scalar explicit indent indicator preserves leading spaces" {
    // With `|2`, only two columns are indentation, so the extra spaces are content.
    const doc = try Parser.parse(testing.allocator, "v: |2\n    indented\n  flush\n", .v1_2_2);
    defer doc.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "  indented\nflush\n", (try doc.ast.getValByPath(&.{.{ .key = "v" }})).kind.string);
}

test "yaml block scalar as sequence entry and nested value" {
    const input =
        \\steps:
        \\  - |
        \\    do a
        \\    do b
        \\  - run
        \\
    ;
    const doc = try Parser.parse(testing.allocator, input, .v1_2_2);
    defer doc.deinit(testing.allocator);
    const steps = try doc.ast.getValByPath(&.{.{ .key = "steps" }});
    try testing.expect(std.meta.activeTag(steps.kind) == .sequence);
    const first = doc.ast.nodes[steps.kind.sequence.?];
    try testing.expectEqualSlices(u8, "do a\ndo b\n", first.kind.string);
    const second = doc.ast.nodes[first.next_sibling.?];
    try testing.expectEqualSlices(u8, "run", second.kind.string);
}

test "yaml empty block scalar is an empty string" {
    const doc = try Parser.parse(testing.allocator, "a: |\nb: 1\n", .v1_2_2);
    defer doc.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "", (try doc.ast.getValByPath(&.{.{ .key = "a" }})).kind.string);
    try testing.expect(std.meta.activeTag((try doc.ast.getValByPath(&.{.{ .key = "b" }})).kind) == .number);
}

test "yaml root block scalar document" {
    const doc = try Parser.parse(testing.allocator, "|\n  hello\n  world\n", .v1_2_2);
    defer doc.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "hello\nworld\n", doc.ast.nodes[doc.ast.root].kind.string);
}

test "yaml rejects flow-shaped root scalars" {
    try testParserError("[ a, b, c ] ]\n", error.UnexpectedToken);
    try testParserError("[-]\n", error.UnexpectedToken);
    try testParserError("? x\n", error.UnexpectedToken);
}
