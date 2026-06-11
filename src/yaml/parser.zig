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
    // True for an indentless block sequence value: one opened (with no fresh
    // indent of its own) directly inside a mapping, so it shares that mapping's
    // column (`k:\n  revs:\n  - 1`). The single dedent that matches that shared
    // column must close BOTH this sequence and its enclosing mapping, so the
    // dedent handler keeps closing while this flag is set.
    shares_parent_indent: bool = false,
    // True between an explicit key (`? key`) and its value indicator (`:`): the
    // pending_key was introduced by `?` and a standalone `:` may supply its value.
    explicit_awaiting_value: bool = false,
    // True while a complex explicit key (a block sequence/mapping written after
    // `?`) is being parsed: the next child container that closes into this
    // mapping is the key, not a value.
    building_explicit_key: bool = false,
};

nodes: std.ArrayList(AST.Node) = .empty,
node_spans: std.ArrayList(Span) = .empty,
// YAML reference/annotation side-tables, kept length-synced with `nodes` by
// `addNode`. Decoded strings (node_tags/node_anchors) hand off to the AST; spans
// hand off to the Document. `anchors` is the name→id table (filled in a later
// phase; empty for tag-only documents).
node_tags: std.ArrayList(?[]const u8) = .empty,
node_anchors: std.ArrayList(?[]const u8) = .empty,
node_tag_spans: std.ArrayList(?Span) = .empty,
node_anchor_spans: std.ArrayList(?Span) = .empty,
anchors: std.ArrayList(AST.Anchor) = .empty,
// A node property (`!tag`; later `&anchor`) seen but not yet attached to the
// node it decorates. Consumed by the next `addNode`.
pending_tag: ?struct { text: []const u8, span: Span } = null,
container_stack: std.ArrayList(OpenContainer) = .empty,
owned_strings: std.ArrayList([]const u8) = .empty,
tokens: []const Token = &.{},
index: usize = 0,
force_new_container: bool = false,
// Count of indents opened solely to hold a scalar/flow value on the line after
// its key (`key:\n  value`). Such an indent opens no container, so its matching
// dedent must be skipped rather than closing the awaiting parent.
value_only_indents: usize = 0,
root: ?AST.Node.Id = null,
doc_started: bool = false,
doc_ended: bool = false,

allocator: std.mem.Allocator,
source: []const u8 = "",

const ParseError = error{ UnexpectedToken, EmptyDocument, UnclosedString, InvalidUnicodeEscape, MultipleDocuments, DuplicateProperty };
const ParserError = ParseError || std.mem.Allocator.Error;

/// Primary entry point
/// Pass allocator, input, and type, and get a Document.
pub fn parseAbstract(allocator: std.mem.Allocator, input: []const u8, format: Type) !AST {
    const parsed = try parse(allocator, input, format);
    // Drop the Document-side span tables; the abstract AST keeps the decoded
    // tag/anchor strings it carries itself.
    allocator.free(parsed.node_spans);
    allocator.free(parsed.node_tag_spans);
    allocator.free(parsed.node_anchor_spans);
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
        // A next-line scalar value occupies a fresh indent by itself; the only
        // thing that may follow it at that indent is its closing dedent. Content
        // there (`key:\n  value\n  more: x`) is over-indented and invalid.
        if (self.value_only_indents > 0) switch (self.peek().kind) {
            .newline, .dedent, .end_of_file => {},
            else => return ParseError.UnexpectedToken,
        };
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
                // A dedent matching an indent that only held a next-line scalar
                // value closes no container — just consume it.
                if (self.value_only_indents > 0) {
                    self.value_only_indents -= 1;
                    _ = self.advance();
                } else {
                    try self.closePendingEmptyValue();
                    const dedent = self.advance();
                    // Close the container at this indent. An indentless sequence
                    // shares its enclosing mapping's column and opened no indent
                    // of its own, so the one dedent matching that column must
                    // also close the mapping (and any further such nesting).
                    while (true) {
                        const close_parent_too = self.container_stack.items.len > 0 and
                            self.currentContainer().shares_parent_indent;
                        const id = try self.closeContainer(dedent.span.end);
                        try self.finishValue(id);
                        if (!close_parent_too) break;
                    }
                }
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
            .explicit_key => {
                if (self.doc_ended) return ParseError.MultipleDocuments;
                try self.closeSequenceItemContinuation();
                try self.parseExplicitKey();
            },
            .colon => {
                if (self.doc_ended) return ParseError.MultipleDocuments;
                // A complex key (`? - a`) whose sequence is still open on the
                // same line as its `:` must be closed first; that makes it the
                // pending key (via finishValue's building_explicit_key path).
                try self.closeOpenComplexKey();
                if (self.container_stack.items.len > 0 and self.currentContainer().explicit_awaiting_value) {
                    // A standalone `:` supplying the value for an explicit key.
                    const colon = self.advance();
                    self.currentContainer().explicit_awaiting_value = false;
                    self.currentContainer().pending_value_span = colon.span.end;
                    // An explicit value (`: - one`) may take a compact block sequence.
                    try self.parseMappingValue(true);
                } else {
                    // A leading `:` starts a block mapping entry with an empty key.
                    try self.closeSequenceItemContinuation();
                    try self.parseEmptyKeyEntry();
                }
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
                } else if (self.force_new_container and self.currentAwaitsValue()) {
                    // A plain scalar on the line after its key (`key:\n  value`):
                    // the fresh indent holds the value, not a new container.
                    const value_id = try self.parseScalar();
                    try self.attachDeferredValue(value_id);
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
            .flow_seq_start, .flow_map_start => {
                // A flow collection as a whole document, the value of a mapping
                // key / sequence item on the following line, or — when a `:`
                // follows it — a block mapping key (`[a, b]: value`).
                if (self.doc_ended) return ParseError.MultipleDocuments;
                try self.closeSequenceItemContinuation();
                const node_id = try self.parseFlowNode();
                self.skipTriviaNoNewline();
                if (self.peek().kind == .colon) {
                    // An implicit key must be a single line; a flow collection
                    // spanning lines cannot be a block mapping key.
                    const span = self.node_spans.items[node_id];
                    if (std.mem.indexOfScalar(u8, self.source[span.start..span.end], '\n') != null)
                        return ParseError.UnexpectedToken;
                    const mapping_id = try self.ensureContainer(.mapping);
                    try self.closePendingEmptyValue();
                    const colon = self.advance();
                    const parent = self.containerById(mapping_id);
                    parent.pending_key = node_id;
                    parent.pending_value_span = colon.span.end;
                    try self.parseMappingValue(false);
                } else {
                    try self.attachDeferredValue(node_id);
                }
            },
            .tag => {
                // A node property at a value/root position: stash it; the node it
                // decorates is parsed on a following loop iteration (and `addNode`
                // attaches it). Covers `!!str foo`, `!!seq [1]`, a tagged root, etc.
                if (self.doc_ended) return ParseError.MultipleDocuments;
                try self.consumePendingProperties();
            },
            .end_of_file => break,
            else => return ParseError.UnexpectedToken,
        }
    }

    while (self.container_stack.items.len > 0) {
        try self.closePendingEmptyValue();
        const id = try self.closeContainer(self.peek().span.end);
        try self.finishValue(id);
    }

    // An empty document — no content node, only comments, blank lines, or
    // document markers — is valid; its root is the null node.
    const root = self.root orelse try self.addNode(.null_, self.peek().span);
    const nodes = try self.nodes.toOwnedSlice(self.allocator);
    errdefer self.allocator.free(nodes);
    self.nodes = .empty;
    const node_spans = try self.node_spans.toOwnedSlice(self.allocator);
    errdefer self.allocator.free(node_spans);
    self.node_spans = .empty;
    const node_tags = try self.node_tags.toOwnedSlice(self.allocator);
    errdefer self.allocator.free(node_tags);
    self.node_tags = .empty;
    const node_anchors = try self.node_anchors.toOwnedSlice(self.allocator);
    errdefer self.allocator.free(node_anchors);
    self.node_anchors = .empty;
    const anchors = try self.anchors.toOwnedSlice(self.allocator);
    errdefer self.allocator.free(anchors);
    self.anchors = .empty;
    const node_tag_spans = try self.node_tag_spans.toOwnedSlice(self.allocator);
    errdefer self.allocator.free(node_tag_spans);
    self.node_tag_spans = .empty;
    const node_anchor_spans = try self.node_anchor_spans.toOwnedSlice(self.allocator);
    errdefer self.allocator.free(node_anchor_spans);
    self.node_anchor_spans = .empty;
    const owned_strings = try self.owned_strings.toOwnedSlice(self.allocator);
    self.owned_strings = .empty;
    return .{
        .source = input,
        .ast = .{
            .allocator = self.allocator,
            .owned_strings = owned_strings,
            .root = root,
            .nodes = nodes,
            .node_tags = node_tags,
            .node_anchors = node_anchors,
            .anchors = anchors,
        },
        .node_spans = node_spans,
        .node_tag_spans = node_tag_spans,
        .node_anchor_spans = node_anchor_spans,
    };
}

pub fn deinit(self: *Parser) void {
    self.container_stack.deinit(self.allocator);
    self.nodes.deinit(self.allocator);
    self.node_spans.deinit(self.allocator);
    self.node_tags.deinit(self.allocator);
    self.node_anchors.deinit(self.allocator);
    self.node_tag_spans.deinit(self.allocator);
    self.node_anchor_spans.deinit(self.allocator);
    self.anchors.deinit(self.allocator);
    for (self.owned_strings.items) |string| {
        self.allocator.free(string);
    }
    self.owned_strings.deinit(self.allocator);
}

fn parseSequenceEntry(self: *Parser) ParserError!void {
    const dash = self.advance();
    const sequence_id = try self.ensureContainer(.sequence);
    // A preceding dash at this same indent with no value (`-\n- x`) is a null
    // entry: finalize it (creating its null node — which also consumes a tag like
    // `- !!str\n- y`) before starting this entry. When the previous dash's value
    // was instead deferred to a more-indented line, `ensureContainer` opened a new
    // child container, so `currentContainer` is not this sequence and nothing is
    // finalized here.
    if (self.currentContainer().id == sequence_id) try self.closePendingEmptyValue();
    self.clearPendingSequenceItem(sequence_id);
    self.skipTriviaNoNewline();
    try self.consumePendingProperties(); // `- !!str x`

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
        .flow_seq_start, .flow_map_start => {
            const value_id = try self.parseFlowNode();
            try self.finishValue(value_id);
        },
        .explicit_key => {
            // A sequence entry whose value is an explicit-key mapping (`- ? k`).
            const mapping_id = try self.openContainer(.mapping, self.peek().span.start);
            self.containerById(mapping_id).continues_sequence_item = true;
            try self.parseExplicitKey();
        },
        .colon => {
            // A sequence entry whose value is an empty-key mapping (`- : v`).
            const mapping_id = try self.openContainer(.mapping, self.peek().span.start);
            self.containerById(mapping_id).continues_sequence_item = true;
            try self.parseEmptyKeyEntry();
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

    // An implicit key (`key:`) may not take a compact block sequence on its own
    // line; the sequence must start on the next line.
    try self.parseMappingValue(false);
}

/// Parses the value following a mapping key's `:` indicator. The pending key is
/// already recorded on the current mapping container; an inline value is built
/// and attached immediately, while a value written on following lines (a block
/// collection, or nothing) is left for the indent/dedent machinery to attach.
/// `allow_compact` enables a block collection whose first entry sits on the `:`
/// line (a compact sequence `: - one` or compact mapping `: moon: white`); this
/// is only legal after an explicit-value indicator.
fn parseMappingValue(self: *Parser, allow_compact: bool) ParserError!void {
    self.skipTriviaNoNewline();
    try self.consumePendingProperties(); // `k: !!int 5` (or `k: !!str` → tagged null)
    switch (self.peek().kind) {
        .scalar => {
            if (allow_compact and self.isMappingStart()) {
                // A compact block mapping as an explicit value (`: moon: white`):
                // the nested mapping begins on the `:` line. Legal only after an
                // explicit-value indicator; an implicit `a: b: c` is invalid. As
                // with a key mapping, a tab separating it from the `:` would act
                // as the nested mapping's indentation, which is forbidden.
                if (self.tabBetween(self.currentContainer().pending_value_span, self.peek().span.start))
                    return ParseError.UnexpectedToken;
                const child_id = try self.openContainer(.mapping, self.peek().span.start);
                try self.parseMappingEntry();
                const id = try self.closeContainer(self.node_spans.items[child_id].end);
                try self.finishValue(id);
            } else {
                // An inline value is a single scalar; it cannot itself be a block
                // mapping (`a: b: c` / `a: 'b': c` are invalid — a nested block
                // mapping needs its own line and deeper indent), so a `:`
                // trailing the value is junk.
                const value_id = try self.parseScalar();
                try self.finishValue(value_id);
                try self.requireValueEnd();
            }
        },
        .dash => {
            // A compact block sequence whose first entry sits on the `:` line
            // (explicit `: - one`). Only valid after an explicit-value indicator
            // — an implicit `key: - one` is malformed. Leave it open like the
            // main-loop sequence path so entries on following lines attach to it;
            // the `continues_sequence_item` flag stops the next indent from
            // opening a fresh container, and the sequence closes on the matching
            // dedent or the next shallower entry (via closeSequenceItemContinuation).
            if (!allow_compact) return ParseError.UnexpectedToken;
            const seq_id = try self.openContainer(.sequence, self.peek().span.start);
            self.containerById(seq_id).continues_sequence_item = true;
            try self.parseSequenceEntry();
        },
        .block_header => {
            const value_id = try self.parseBlockScalar();
            try self.finishValue(value_id);
        },
        .flow_seq_start, .flow_map_start => {
            const value_id = try self.parseFlowNode();
            try self.finishValue(value_id);
            try self.requireValueEnd();
        },
        .newline, .dedent, .end_of_file => {},
        else => return ParseError.UnexpectedToken,
    }
}

/// After an inline value (a scalar or flow collection written on the same line
/// as its `:` or `-`), only same-line trivia and the line break may follow.
/// Trailing content — a second mapping entry (`k: v x: y`), a stray `:`
/// (`a: b: c`), or junk after a flow collection (`{a: b}x`) — is invalid.
fn requireValueEnd(self: *Parser) ParserError!void {
    while (self.peek().kind == .whitespace) _ = self.advance();
    switch (self.peek().kind) {
        .newline, .comment, .dedent, .end_of_file => {},
        else => return ParseError.UnexpectedToken,
    }
}

/// True when the source span `[from, to)` contains a tab. Used to reject a tab
/// that separates an explicit `?`/`:` indicator from a nested block mapping,
/// where the tab would be standing in for the mapping's indentation.
fn tabBetween(self: *const Parser, from: usize, to: usize) bool {
    if (from > to or to > self.source.len) return false;
    return std.mem.indexOfScalar(u8, self.source[from..to], '\t') != null;
}

/// Parses an explicit-key entry (`? key`). Records the key on the current
/// mapping and marks it awaiting a `:` value indicator (which arrives on a later
/// line, or never — an explicit key with no `:` has a null value). The key may
/// be a plain/quoted scalar, a flow collection, a block scalar, a block sequence
/// (a complex key, parsed via `building_explicit_key`), or empty. A block
/// *mapping* as the key is still unsupported and is rejected.
fn parseExplicitKey(self: *Parser) ParserError!void {
    const marker = self.advance(); // explicit_key `?`
    const mapping_id = try self.ensureContainer(.mapping);
    try self.closePendingEmptyValue();

    self.skipTriviaNoNewline();
    try self.consumePendingProperties(); // `? !!str key`
    const key_id = switch (self.peek().kind) {
        .scalar => key: {
            if (self.isMappingStart()) {
                // A complex key that is itself a block mapping (`? earth: blue`).
                // The nested mapping's indentation comes from the key's column;
                // if a tab (not spaces) separates it from `?`, the tab acts as
                // that indentation, which YAML forbids (`?\tkey:`).
                if (self.tabBetween(marker.span.end, self.peek().span.start))
                    return ParseError.UnexpectedToken;
                // Mirror the block-sequence key path: open it as a child
                // container, mark the mapping as building its key, and let
                // finishValue (via building_explicit_key) record it as the
                // pending key when it closes at the dedent before `:`.
                self.containerById(mapping_id).building_explicit_key = true;
                const key_map_id = try self.openContainer(.mapping, self.peek().span.start);
                self.containerById(key_map_id).continues_sequence_item = true;
                try self.parseMappingEntry();
                return;
            }
            break :key try self.parseScalar();
        },
        .flow_seq_start, .flow_map_start => try self.parseFlowNode(),
        .block_header => try self.parseBlockScalar(),
        .dash => {
            // A complex key that is itself a block sequence (`? - a\n  - b`).
            // Open it as a child container and mark the mapping as building its
            // key; when the sequence closes — at the dedent before `:`, or when
            // the `:` itself closes it — it becomes the pending key (see
            // finishValue), not a value.
            self.containerById(mapping_id).building_explicit_key = true;
            const seq_id = try self.openContainer(.sequence, self.peek().span.start);
            self.containerById(seq_id).continues_sequence_item = true;
            try self.parseSequenceEntry();
            return;
        },
        // `?` directly before its `:` (or end of entry) is an empty (null) key.
        .colon, .newline, .dedent, .end_of_file => try self.addNode(.null_, .init(marker.span.end, marker.span.end)),
        else => return ParseError.UnexpectedToken,
    };

    const parent = self.containerById(mapping_id);
    parent.pending_key = key_id;
    parent.pending_value_span = self.node_spans.items[key_id].end;
    parent.explicit_awaiting_value = true;
}

/// Parses a block mapping entry whose key is empty (`: value`). The current
/// token is the `:`; the key is the null node.
fn parseEmptyKeyEntry(self: *Parser) ParserError!void {
    const mapping_id = try self.ensureContainer(.mapping);
    try self.closePendingEmptyValue();

    const colon = self.advance(); // `:`
    const key_id = try self.addNode(.null_, .init(colon.span.start, colon.span.start));
    {
        const parent = self.containerById(mapping_id);
        parent.pending_key = key_id;
        parent.pending_value_span = colon.span.end;
    }
    try self.parseMappingValue(false);
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

    // An explicit indentation indicator counts from the owning node's column
    // (the enclosing mapping/sequence), not the header line's leading indent —
    // which differs for a nested block like `- k: |2`.
    const parent_indent = self.currentContainerIndent();

    var span_end = header.span.end;
    var value: []const u8 = "";
    if (self.peek().kind == .block_scalar) {
        const body = self.advance();
        span_end = body.span.end;
        value = try self.decodeBlockScalar(header_source, parent_indent, body.source(self.source));
    }

    return self.addNode(.{ .string = value }, .init(header.span.start, span_end));
}

fn decodeBlockScalar(self: *Parser, header: []const u8, parent_indent: usize, body: []const u8) ParserError![]const u8 {
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
        parent_indent + d
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

/// The source column of the innermost open container — the indentation of the
/// node that owns a block scalar value (a mapping's key column, a sequence's
/// dash column). 0 at the document root (no enclosing container).
fn currentContainerIndent(self: *const Parser) usize {
    if (self.container_stack.items.len == 0) return 0;
    const id = self.container_stack.items[self.container_stack.items.len - 1].id;
    const pos = self.node_spans.items[id].start;
    var start = pos;
    while (start > 0 and self.source[start - 1] != '\n') start -= 1;
    return pos - start;
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

/// Parses a flow node: a flow sequence `[...]`, flow mapping `{...}`, or a
/// flow scalar. Flow content ignores indentation and line breaks, so newlines
/// are treated as trivia throughout.
fn parseFlowNode(self: *Parser) ParserError!AST.Node.Id {
    self.skipFlowTrivia();
    // A tag on a flow node (`[!!str x]`, `{!!int 1: a}`). Flow trivia spans line
    // breaks, so drain with the flow-aware skipper rather than the block one.
    while (self.peek().kind == .tag) {
        if (self.pending_tag != null) return ParseError.DuplicateProperty;
        const t = self.advance();
        self.pending_tag = .{ .text = t.source(self.source), .span = t.span };
        self.skipFlowTrivia();
    }
    // A tag with no node of its own — terminated by a flow indicator — decorates
    // an implicit null (`{!!str : bar}`, `[!!str, x]`, `{a: !!str}`).
    if (self.pending_tag != null) switch (self.peek().kind) {
        .comma, .colon, .flow_map_end, .flow_seq_end => {
            const at = self.peek().span.start;
            return self.addNode(.null_, .init(at, at));
        },
        else => {},
    };
    return switch (self.peek().kind) {
        .flow_seq_start => self.parseFlowSequence(),
        .flow_map_start => self.parseFlowMapping(),
        .scalar => {
            if (invalidFlowScalar(self.peek().source(self.source))) return ParseError.UnexpectedToken;
            return self.parseScalar();
        },
        else => ParseError.UnexpectedToken,
    };
}

/// A plain scalar inside flow may not begin with a comment indicator, and the
/// indicators `-`/`?`/`:` are valid first characters only when followed by
/// plain-safe content — a bare one (here, abutting a flow indicator) is not.
fn invalidFlowScalar(source: []const u8) bool {
    if (source.len == 0) return true;
    if (source[0] == '#') return true;
    if (source.len == 1) return source[0] == '-' or source[0] == '?' or source[0] == ':';
    return false;
}

fn parseFlowSequence(self: *Parser) ParserError!AST.Node.Id {
    const open = self.advance(); // flow_seq_start
    const seq_id = try self.addNode(.{ .sequence = null }, open.span);
    var last: ?AST.Node.Id = null;

    self.skipFlowTrivia();
    while (self.peek().kind != .flow_seq_end) {
        if (self.peek().kind == .end_of_file) return ParseError.UnexpectedToken;

        const item = try self.parseFlowSequenceItem();
        if (last) |prev| {
            self.nodes.items[prev].next_sibling = item;
        } else {
            self.nodes.items[seq_id].kind = .{ .sequence = item };
        }
        last = item;

        self.skipFlowTrivia();
        switch (self.peek().kind) {
            .comma => {
                _ = self.advance();
                self.skipFlowTrivia();
            },
            .flow_seq_end => {},
            else => return ParseError.UnexpectedToken,
        }
    }

    const close = self.advance(); // flow_seq_end
    self.node_spans.items[seq_id].end = close.span.end;
    return seq_id;
}

/// Parses a single flow-sequence element. Usually a plain flow node, but an
/// element may also be a single-pair mapping: either explicit (`[? k : v]`) or
/// implicit (`[a: b]`). Such a pair is wrapped in its own one-entry mapping node.
fn parseFlowSequenceItem(self: *Parser) ParserError!AST.Node.Id {
    const explicit = self.peek().kind == .explicit_key;
    if (explicit) {
        _ = self.advance();
        self.skipFlowTrivia();
    }

    const key_id: AST.Node.Id = switch (self.peek().kind) {
        // An empty key: `[: v]` (value-only) or a bare `[?]`.
        .colon => try self.addNode(.null_, self.peek().span),
        .comma, .flow_seq_end => if (explicit)
            try self.addNode(.null_, self.peek().span)
        else
            return ParseError.UnexpectedToken,
        else => try self.parseFlowNode(),
    };
    // An implicit key's `:` must be on the same line as the key; an explicit
    // (`?`) key's value indicator may follow a line break.
    if (explicit) self.skipFlowTrivia() else self.skipFlowInlineTrivia();

    // Without a `:` it is a plain element — unless `?` already forced a pair.
    if (self.peek().kind != .colon) {
        if (!explicit) return key_id;
        const at = self.node_spans.items[key_id].end;
        return self.wrapFlowPair(key_id, try self.addNode(.null_, .init(at, at)));
    }

    _ = self.advance(); // colon
    self.skipFlowTrivia();
    const value_id: AST.Node.Id = switch (self.peek().kind) {
        .comma, .flow_seq_end => empty: {
            const at = self.node_spans.items[key_id].end;
            break :empty try self.addNode(.null_, .init(at, at));
        },
        else => try self.parseFlowNode(),
    };
    return self.wrapFlowPair(key_id, value_id);
}

/// Wraps a key/value pair as a standalone single-entry mapping node (used for a
/// flow pair that appears as a flow-sequence element).
fn wrapFlowPair(self: *Parser, key_id: AST.Node.Id, value_id: AST.Node.Id) ParserError!AST.Node.Id {
    const key_span = self.node_spans.items[key_id];
    const value_span = self.node_spans.items[value_id];
    const pair_id = try self.addNode(.{ .keyvalue = .{
        .key = key_id,
        .value = value_id,
    } }, .{ .start = key_span.start, .end = value_span.end });
    return self.addNode(.{ .mapping = pair_id }, .{ .start = key_span.start, .end = value_span.end });
}

fn parseFlowMapping(self: *Parser) ParserError!AST.Node.Id {
    const open = self.advance(); // flow_map_start
    const map_id = try self.addNode(.{ .mapping = null }, open.span);
    var last: ?AST.Node.Id = null;

    self.skipFlowTrivia();
    while (self.peek().kind != .flow_map_end) {
        if (self.peek().kind == .end_of_file) return ParseError.UnexpectedToken;

        // An optional `?` introduces the key explicitly; in flow either the key
        // or the value (or both) may be empty (`{? a :, : b, ?}`).
        if (self.peek().kind == .explicit_key) {
            _ = self.advance();
            self.skipFlowTrivia();
        }

        const key_id = switch (self.peek().kind) {
            // An empty key, e.g. `{: v}` (value-only) or a bare `{?}`.
            .colon, .comma, .flow_map_end => try self.addNode(.null_, self.peek().span),
            else => try self.parseFlowNode(),
        };
        self.skipFlowTrivia();

        var value_id: AST.Node.Id = undefined;
        if (self.peek().kind == .colon) {
            _ = self.advance();
            self.skipFlowTrivia();
            value_id = switch (self.peek().kind) {
                // `{a: , b}` / `{a:}` — an explicit but empty value is null.
                .comma, .flow_map_end => empty: {
                    const at = self.node_spans.items[key_id].end;
                    break :empty try self.addNode(.null_, .init(at, at));
                },
                else => try self.parseFlowNode(),
            };
        } else {
            // `{a, b}` — a bare key has an implicit null value.
            const at = self.node_spans.items[key_id].end;
            value_id = try self.addNode(.null_, .init(at, at));
        }

        const key_span = self.node_spans.items[key_id];
        const value_span = self.node_spans.items[value_id];
        const pair_id = try self.addNode(.{ .keyvalue = .{
            .key = key_id,
            .value = value_id,
        } }, .{ .start = key_span.start, .end = value_span.end });

        if (last) |prev| {
            self.nodes.items[prev].next_sibling = pair_id;
        } else {
            self.nodes.items[map_id].kind = .{ .mapping = pair_id };
        }
        last = pair_id;

        self.skipFlowTrivia();
        switch (self.peek().kind) {
            .comma => {
                _ = self.advance();
                self.skipFlowTrivia();
            },
            .flow_map_end => {},
            else => return ParseError.UnexpectedToken,
        }
    }

    const close = self.advance(); // flow_map_end
    self.node_spans.items[map_id].end = close.span.end;
    return map_id;
}

fn skipFlowTrivia(self: *Parser) void {
    while (true) switch (self.peek().kind) {
        .whitespace, .newline, .comment, .indent, .dedent => _ = self.advance(),
        else => return,
    };
}

/// Skips only same-line trivia (no line breaks). Used to find an implicit flow
/// pair's `:`, which must sit on the key's line.
fn skipFlowInlineTrivia(self: *Parser) void {
    while (true) switch (self.peek().kind) {
        .whitespace, .comment => _ = self.advance(),
        else => return,
    };
}

fn ensureContainer(self: *Parser, kind: ContainerKind) ParserError!AST.Node.Id {
    if (!self.force_new_container and self.container_stack.items.len > 0) {
        const current = self.currentContainer();
        if (current.kind == kind) return current.id;
        // A mapping key at a block sequence's indentation is valid only as the
        // return to an enclosing mapping after an indentless sequence value
        // (`one:\n- 2\nfour: 5`). An indentless sequence shares its parent key's
        // column and opens no indent, so no dedent closes it; the reappearing key
        // at that column is the signal to close it here, attach it to the
        // enclosing mapping's pending key, and continue in that mapping. When no
        // mapping encloses the sequence it is a root/sibling sequence and the key
        // mixes seq+map at one level (`- a\n- b\nk: v`) — invalid.
        if (kind == .mapping and current.kind == .sequence) {
            var has_enclosing_mapping = false;
            for (self.container_stack.items[0 .. self.container_stack.items.len - 1]) |c| {
                if (c.kind == .mapping) has_enclosing_mapping = true;
            }
            if (!has_enclosing_mapping) return ParseError.UnexpectedToken;

            try self.closePendingEmptyValue();
            const id = try self.closeContainer(self.node_spans.items[current.id].end);
            try self.finishValue(id);
            // The sequence's parent is now current; recurse to land in the
            // enclosing mapping (closing further indentless sequences if nested).
            return self.ensureContainer(kind);
        }
    }

    // An indentless block sequence opened as a mapping value (no fresh indent
    // preceded it, and a mapping encloses it) shares that mapping's column.
    // Record it so the matching dedent closes the mapping too (see the dedent
    // handler). Indented sequences arrive with `force_new_container` set and a
    // dedent of their own, so they are not flagged.
    const shares_parent = kind == .sequence and !self.force_new_container and
        self.container_stack.items.len > 0 and self.currentContainer().kind == .mapping;
    self.force_new_container = false;
    const id = try self.openContainer(kind, startOfCurrentToken(self));
    if (shares_parent) self.containerById(id).shares_parent_indent = true;
    return id;
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

/// True when the current container is mid-entry, waiting for a value: a mapping
/// with a recorded key, or a sequence with a dash awaiting its item.
fn currentAwaitsValue(self: *Parser) bool {
    if (self.container_stack.items.len == 0) return false;
    const c = self.currentContainer();
    return switch (c.kind) {
        .mapping => c.pending_key != null,
        .sequence => c.pending_sequence_item,
    };
}

/// Attaches a value that may have been written on the line after its key. If a
/// fresh indent was opened solely to hold it (`force_new_container`), that
/// indent's matching dedent must be skipped, so record it.
fn attachDeferredValue(self: *Parser, value_id: AST.Node.Id) ParserError!void {
    if (self.force_new_container) {
        self.value_only_indents += 1;
        self.force_new_container = false;
    }
    try self.finishValue(value_id);
}

fn finishValue(self: *Parser, value_id: AST.Node.Id) ParserError!void {
    if (self.container_stack.items.len == 0) {
        // A second top-level node means trailing junk after the root (or a
        // second document); reject rather than silently overwriting the root.
        if (self.root != null) return ParseError.UnexpectedToken;
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
            // A complex explicit key just finished: it becomes the pending key,
            // and a `:` value indicator may now follow.
            if (parent.building_explicit_key) {
                parent.building_explicit_key = false;
                parent.pending_key = value_id;
                parent.pending_value_span = self.node_spans.items[value_id].end;
                parent.explicit_awaiting_value = true;
                return;
            }

            const key_id = parent.pending_key orelse return ParseError.UnexpectedToken;
            parent.pending_key = null;
            parent.explicit_awaiting_value = false;

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
            parent.explicit_awaiting_value = false;
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

/// If a complex explicit key's container (a block sequence opened after `?`) is
/// still open — its `:` sits on the same line, so no dedent closed it — close it
/// now. finishValue's `building_explicit_key` path then records it as the key.
fn closeOpenComplexKey(self: *Parser) ParserError!void {
    if (self.container_stack.items.len < 2) return;
    const parent = &self.container_stack.items[self.container_stack.items.len - 2];
    if (!parent.building_explicit_key) return;

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
    // A multi-line plain scalar folds its line breaks; it is always a string
    // (no number/bool/null spans lines).
    if (std.mem.indexOfScalar(u8, source, '\n') != null) return .{ .string = try self.foldPlainScalar(source) };
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

/// Folds a multi-line plain scalar: line breaks fold like flow scalars (a lone
/// break becomes a space, a blank line a newline) with continuation-line
/// indentation stripped.
fn foldPlainScalar(self: *Parser, source: []const u8) ParserError![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(self.allocator);
    var i: usize = 0;
    while (i < source.len) {
        if (source[i] == '\n') {
            i = try foldFlowBreak(&out, self.allocator, source, i);
            continue;
        }
        try out.append(self.allocator, source[i]);
        i += 1;
    }
    return self.ownString(try out.toOwnedSlice(self.allocator));
}

fn getSingleQuotedString(self: *Parser, source: []const u8) ParserError![]const u8 {
    if (source.len < 2 or source[0] != '\'' or source[source.len - 1] != '\'') {
        return ParseError.UnclosedString;
    }
    const inner = source[1 .. source.len - 1];

    if (std.mem.indexOfScalar(u8, inner, '\'') == null and
        std.mem.indexOfScalar(u8, inner, '\n') == null) return inner;

    var decoded: std.ArrayList(u8) = .empty;
    errdefer decoded.deinit(self.allocator);

    var index: usize = 0;
    while (index < inner.len) {
        if (inner[index] == '\n') {
            index = try foldFlowBreak(&decoded, self.allocator, inner, index);
            continue;
        }
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

/// Folds a run of line breaks in a flow (quoted) scalar where `inner[i]` is a
/// newline: trailing whitespace of the line just ended is dropped, the leading
/// whitespace of each continuation line is skipped, a lone break becomes a
/// space, and each additional (blank) line becomes a newline. Returns the index
/// past the run.
fn foldFlowBreak(out: *std.ArrayList(u8), allocator: std.mem.Allocator, inner: []const u8, at: usize) ParserError!usize {
    while (out.items.len > 0) {
        const last = out.items[out.items.len - 1];
        if (last != ' ' and last != '\t') break;
        out.items.len -= 1;
    }

    var i = at + 1;
    var breaks: usize = 1;
    while (true) {
        while (i < inner.len and (inner[i] == ' ' or inner[i] == '\t')) i += 1;
        if (i < inner.len and inner[i] == '\n') {
            breaks += 1;
            i += 1;
            continue;
        }
        break;
    }

    if (breaks == 1) {
        try out.append(allocator, ' ');
    } else {
        for (0..breaks - 1) |_| try out.append(allocator, '\n');
    }
    return i;
}

fn getDoubleQuotedString(self: *Parser, source: []const u8) ParserError![]const u8 {
    if (source.len < 2 or source[0] != '"' or source[source.len - 1] != '"') {
        return ParseError.UnclosedString;
    }
    const inner = source[1 .. source.len - 1];

    if (std.mem.indexOfScalar(u8, inner, '\\') == null and
        std.mem.indexOfScalar(u8, inner, '\n') == null) return inner;

    var decoded: std.ArrayList(u8) = .empty;
    errdefer decoded.deinit(self.allocator);

    var index: usize = 0;
    while (index < inner.len) {
        const char = inner[index];
        if (char == '\n') {
            index = try foldFlowBreak(&decoded, self.allocator, inner, index);
            continue;
        }
        if (char != '\\') {
            try decoded.append(self.allocator, char);
            index += 1;
            continue;
        }

        index += 1;
        if (index >= inner.len) return ParseError.UnclosedString;

        // An escaped line break joins the lines directly, dropping the leading
        // whitespace of the continuation.
        if (inner[index] == '\n') {
            index += 1;
            while (index < inner.len and (inner[index] == ' ' or inner[index] == '\t')) index += 1;
            continue;
        }

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
/// Flow collections are now tokenized as their own tokens, so the only forms
/// that still reach here flow-shaped are a leading `,` and the explicit-key
/// indicator `? `.
fn invalidPlainStart(source: []const u8) bool {
    if (source.len == 0) return false;
    return switch (source[0]) {
        ',' => true,
        '?' => source.len >= 2 and (source[1] == ' ' or source[1] == '\t'),
        else => false,
    };
}

fn isMappingStart(self: *const Parser) bool {
    if (self.peek().kind != .scalar) return false;
    // An implicit block mapping key must be a single line; a multi-line scalar
    // (e.g. a folded quoted string) cannot be a key.
    if (std.mem.indexOfScalar(u8, self.peek().source(self.source), '\n') != null) return false;

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
    // Consume any pending node property onto this node and keep all side-tables
    // length-synced with `nodes`.
    const tag = self.pending_tag;
    self.pending_tag = null;
    var node_span = span;
    // Extend the node's span leftward to cover its property prefix, so the editor
    // sees `!tag value` as one editable unit (and a replace can't orphan `!tag `).
    if (tag) |t| node_span.start = @min(node_span.start, t.span.start);
    try self.node_spans.append(self.allocator, node_span);
    try self.node_tags.append(self.allocator, if (tag) |t| t.text else null);
    try self.node_tag_spans.append(self.allocator, if (tag) |t| t.span else null);
    try self.node_anchors.append(self.allocator, null);
    try self.node_anchor_spans.append(self.allocator, null);
    return id;
}

/// Drain leading node-property tokens (tags; later anchors) onto the parser's
/// pending state, to be attached to the next node by `addNode`. A node may carry
/// at most one tag, so a second one before the node is rejected. A tag with no
/// following node is not an error: it decorates an implicit null (`k: !!str`,
/// or `!!str` alone → a tagged null root), created downstream by the empty-value
/// machinery or the root fallback, which also routes through `addNode`.
fn consumePendingProperties(self: *Parser) ParserError!void {
    while (true) {
        self.skipTriviaNoNewline();
        if (self.peek().kind != .tag) break;
        if (self.pending_tag != null) return ParseError.DuplicateProperty;
        const t = self.advance();
        self.pending_tag = .{ .text = t.source(self.source), .span = t.span };
    }
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

test "yaml tag: attaches to mapping value and extends span left" {
    const doc = try Parser.parse(testing.allocator, "k: !!int 5\n", .v1_2_2);
    defer doc.deinit(testing.allocator);
    const value = try doc.ast.getValByPath(&.{.{ .key = "k" }});
    // At parse the value is still classified structurally (tags apply at
    // materialize), but the tag string is recorded on the side-table...
    try testing.expectEqualSlices(u8, "!!int", doc.ast.node_tags[value.id].?);
    // ...and the node's span was extended leftward to cover the `!!int ` prefix.
    try testing.expectEqualSlices(u8, "!!int 5", Span.of(u8, doc.span(value), doc.source));
    try testing.expectEqualSlices(u8, "!!int", Span.of(u8, doc.tagSpan(value).?, doc.source));
}

test "yaml tag: on root scalar" {
    const doc = try Parser.parse(testing.allocator, "!!str foo\n", .v1_2_2);
    defer doc.deinit(testing.allocator);
    const root = doc.ast.nodes[doc.ast.root];
    try testing.expectEqualSlices(u8, "foo", root.kind.string);
    try testing.expectEqualSlices(u8, "!!str", doc.ast.node_tags[root.id].?);
}

test "yaml tag: bare bang is a tagged null root" {
    const doc = try Parser.parse(testing.allocator, "!\n", .v1_2_2);
    defer doc.deinit(testing.allocator);
    const root = doc.ast.nodes[doc.ast.root];
    try testing.expect(root.kind == .null_);
    try testing.expectEqualSlices(u8, "!", doc.ast.node_tags[root.id].?);
}

test "yaml tag: empty value is a tagged null" {
    const doc = try Parser.parse(testing.allocator, "t: !!str\n", .v1_2_2);
    defer doc.deinit(testing.allocator);
    const value = try doc.ast.getValByPath(&.{.{ .key = "t" }});
    try testing.expect(value.kind == .null_);
    try testing.expectEqualSlices(u8, "!!str", doc.ast.node_tags[value.id].?);
}

test "yaml tag: two tags on one node is rejected" {
    try testParserError("!!str !!int x\n", error.DuplicateProperty);
}

test "yaml tag: flow tagged-null value" {
    const doc = try Parser.parse(testing.allocator, "{a: !!str}\n", .v1_2_2);
    defer doc.deinit(testing.allocator);
    const a_val = try doc.ast.getValByPath(&.{.{ .key = "a" }});
    try testing.expect(a_val.kind == .null_);
    try testing.expectEqualSlices(u8, "!!str", doc.ast.node_tags[a_val.id].?);
}

test "yaml tag: flow tagged-null key" {
    const doc = try Parser.parse(testing.allocator, "{!!str : bar}\n", .v1_2_2);
    defer doc.deinit(testing.allocator);
    const root = doc.ast.nodes[doc.ast.root];
    const kv = doc.ast.nodes[root.kind.mapping.?];
    const key = doc.ast.nodes[kv.kind.keyvalue.key];
    try testing.expect(key.kind == .null_);
    try testing.expectEqualSlices(u8, "!!str", doc.ast.node_tags[key.id].?);
}

test "yaml tag: deferred null sequence item keeps its tag and the next item" {
    // Regression: `- !!str\n- y` must be [null(tagged), "y"], not drop item 0 /
    // leak the tag into item 1.
    const doc = try Parser.parse(testing.allocator, "- !!str\n- y\n", .v1_2_2);
    defer doc.deinit(testing.allocator);
    const item0 = try doc.ast.getValByPath(&.{.{ .index = 0 }});
    const item1 = try doc.ast.getValByPath(&.{.{ .index = 1 }});
    try testing.expect(item0.kind == .null_);
    try testing.expectEqualSlices(u8, "!!str", doc.ast.node_tags[item0.id].?);
    try testing.expectEqualSlices(u8, "y", item1.kind.string);
    try testing.expect(doc.ast.node_tags[item1.id] == null);
}

test "yaml tag: untagged node has null side-table entry" {
    const doc = try Parser.parse(testing.allocator, "a: 1\n", .v1_2_2);
    defer doc.deinit(testing.allocator);
    const value = try doc.ast.getValByPath(&.{.{ .key = "a" }});
    try testing.expect(doc.ast.node_tags[value.id] == null);
    try testing.expect(doc.tagSpan(value) == null);
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

test "yaml empty documents have a null root" {
    // Truly empty, comment-only, blank-only, and marker-only inputs are all valid
    // documents whose root is the null node.
    for ([_][]const u8{ "", "# just a comment\n", "\n\n", "...\n", "---\n" }) |input| {
        const doc = try Parser.parse(testing.allocator, input, .v1_2_2);
        defer doc.deinit(testing.allocator);
        try testing.expect(std.meta.activeTag(doc.ast.nodes[doc.ast.root].kind) == .null_);
    }
}

test "yaml block-context empty keys" {
    // `: value` is a mapping entry with a null key.
    const doc = try Parser.parse(testing.allocator, ": a\n: b\n", .v1_2_2);
    defer doc.deinit(testing.allocator);
    const map = doc.ast.nodes[doc.ast.root];
    try testing.expect(std.meta.activeTag(map.kind) == .mapping);
    const first = doc.ast.nodes[map.kind.mapping.?];
    try testing.expect(std.meta.activeTag(doc.ast.nodes[first.kind.keyvalue.key].kind) == .null_);
    try testing.expectEqualSlices(u8, "a", doc.ast.nodes[first.kind.keyvalue.value].kind.string);

    // A bare `:` is the entry {null: null}.
    const bare = try Parser.parse(testing.allocator, ":\n", .v1_2_2);
    defer bare.deinit(testing.allocator);
    try testing.expect(std.meta.activeTag(bare.ast.nodes[bare.ast.root].kind) == .mapping);

    // `- :` is a sequence entry whose value is an empty-key mapping.
    const seq = try Parser.parse(testing.allocator, "- :\n", .v1_2_2);
    defer seq.deinit(testing.allocator);
    try testing.expect(std.meta.activeTag((try seq.ast.getValByPath(&.{.{ .index = 0 }})).kind) == .mapping);
}

test "yaml indented comment does not affect structure" {
    // A comment line (even indented) is not content and must not open/close an
    // indentation scope.
    const input =
        \\a: 1
        \\  # indented comment
        \\b: 2
        \\
    ;
    const doc = try Parser.parse(testing.allocator, input, .v1_2_2);
    defer doc.deinit(testing.allocator);
    try testing.expect(std.meta.activeTag((try doc.ast.getValByPath(&.{.{ .key = "a" }})).kind) == .number);
    try testing.expect(std.meta.activeTag((try doc.ast.getValByPath(&.{.{ .key = "b" }})).kind) == .number);
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

test "yaml flow sequence of scalars" {
    const doc = try Parser.parse(testing.allocator, "tags: [a, b, 3]\n", .v1_2_2);
    defer doc.deinit(testing.allocator);
    const tags = try doc.ast.getValByPath(&.{.{ .key = "tags" }});
    try testing.expect(std.meta.activeTag(tags.kind) == .sequence);
    try testing.expectEqualSlices(u8, "a", (try doc.ast.getValByPath(&.{ .{ .key = "tags" }, .{ .index = 0 } })).kind.string);
    try testing.expectEqualSlices(u8, "b", (try doc.ast.getValByPath(&.{ .{ .key = "tags" }, .{ .index = 1 } })).kind.string);
    try testing.expect(std.meta.activeTag((try doc.ast.getValByPath(&.{ .{ .key = "tags" }, .{ .index = 2 } })).kind) == .number);
}

test "yaml flow mapping with quoted keys and nested flow" {
    const doc = try Parser.parse(testing.allocator, "m: {a: 1, \"b c\": [x, y], d}\n", .v1_2_2);
    defer doc.deinit(testing.allocator);
    try testing.expect(std.meta.activeTag((try doc.ast.getValByPath(&.{ .{ .key = "m" }, .{ .key = "a" } })).kind) == .number);
    const nested = try doc.ast.getValByPath(&.{ .{ .key = "m" }, .{ .key = "b c" } });
    try testing.expect(std.meta.activeTag(nested.kind) == .sequence);
    try testing.expectEqualSlices(u8, "y", (try doc.ast.getValByPath(&.{ .{ .key = "m" }, .{ .key = "b c" }, .{ .index = 1 } })).kind.string);
    // A bare key in a flow mapping has an implicit null value.
    try testing.expect(std.meta.activeTag((try doc.ast.getValByPath(&.{ .{ .key = "m" }, .{ .key = "d" } })).kind) == .null_);
}

test "yaml flow collection spanning multiple lines" {
    const input =
        \\matrix: [
        \\  [1, 2],
        \\  [3, 4],
        \\]
        \\
    ;
    const doc = try Parser.parse(testing.allocator, input, .v1_2_2);
    defer doc.deinit(testing.allocator);
    const cell = try doc.ast.getValByPath(&.{ .{ .key = "matrix" }, .{ .index = 1 }, .{ .index = 0 } });
    try testing.expectEqualSlices(u8, "3", cell.kind.number.raw);
}

test "yaml rejects malformed flow" {
    try testParserError("x: [a, b\n", error.UnexpectedToken); // unterminated
    try testParserError("x: [a]]\n", error.UnexpectedToken); // extra close
    try testParserError("flow: [a,\nb]\n", error.InvalidIndent); // under-indented continuation
    try testParserError("x: [-]\n", error.UnexpectedToken); // bare dash flow scalar
}

test "yaml tabs as separation produce clean values" {
    const doc = try Parser.parse(testing.allocator, "key:\tvalue\nflag:\ttrue\n", .v1_2_2);
    defer doc.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "value", (try doc.ast.getValByPath(&.{.{ .key = "key" }})).kind.string);
    try testing.expect((try doc.ast.getValByPath(&.{.{ .key = "flag" }})).kind.boolean == true);
}

test "yaml multi-line plain scalar folds into a value" {
    const input =
        \\desc: this is
        \\  a long
        \\  value
        \\next: x
        \\
    ;
    const doc = try Parser.parse(testing.allocator, input, .v1_2_2);
    defer doc.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "this is a long value", (try doc.ast.getValByPath(&.{.{ .key = "desc" }})).kind.string);
    try testing.expectEqualSlices(u8, "x", (try doc.ast.getValByPath(&.{.{ .key = "next" }})).kind.string);
}

test "yaml multi-line plain scalar blank line becomes newline" {
    const input =
        \\desc: one
        \\  two
        \\
        \\  three
        \\
    ;
    const doc = try Parser.parse(testing.allocator, input, .v1_2_2);
    defer doc.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "one two\nthree", (try doc.ast.getValByPath(&.{.{ .key = "desc" }})).kind.string);
}

test "yaml multi-line plain scalar as sequence entry" {
    const input =
        \\- one
        \\  two
        \\- three
        \\
    ;
    const doc = try Parser.parse(testing.allocator, input, .v1_2_2);
    defer doc.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "one two", (try doc.ast.getValByPath(&.{.{ .index = 0 }})).kind.string);
    try testing.expectEqualSlices(u8, "three", (try doc.ast.getValByPath(&.{.{ .index = 1 }})).kind.string);
}

test "yaml plain value is not folded across a mapping key" {
    // The more-indented line has a colon, so it is a nested structure, not a
    // continuation — this is invalid and must not silently fold.
    try testParserError("a: b\n  c: d\n", error.UnexpectedToken);
}

test "yaml multi-line double-quoted scalar folds breaks" {
    // Single break folds to a space; a blank line becomes a newline; leading
    // whitespace on continuation lines is stripped.
    const input =
        \\msg: "one
        \\  two
        \\
        \\  three"
        \\
    ;
    const doc = try Parser.parse(testing.allocator, input, .v1_2_2);
    defer doc.deinit(testing.allocator);
    const msg = try doc.ast.getValByPath(&.{.{ .key = "msg" }});
    try testing.expectEqualSlices(u8, "one two\nthree", msg.kind.string);
}

test "yaml multi-line single-quoted scalar folds breaks" {
    const input =
        \\msg: 'it''s
        \\  here'
        \\
    ;
    const doc = try Parser.parse(testing.allocator, input, .v1_2_2);
    defer doc.deinit(testing.allocator);
    const msg = try doc.ast.getValByPath(&.{.{ .key = "msg" }});
    try testing.expectEqualSlices(u8, "it's here", msg.kind.string);
}

test "yaml double-quoted escaped line break joins directly" {
    const doc = try Parser.parse(testing.allocator, "v: \"a\\\n  b\"\n", .v1_2_2);
    defer doc.deinit(testing.allocator);
    const v = try doc.ast.getValByPath(&.{.{ .key = "v" }});
    try testing.expectEqualSlices(u8, "ab", v.kind.string);
}

test "yaml multi-line quoted scalar as value not key" {
    // A multi-line quoted scalar can be a value...
    const ok = try Parser.parse(testing.allocator, "k: \"a\n  b\"\n", .v1_2_2);
    defer ok.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "a b", (try ok.ast.getValByPath(&.{.{ .key = "k" }})).kind.string);
    // ...but not a block mapping key.
    try testParserError("\"a\n b\": 1\n", error.UnexpectedToken);
}

test "yaml getValByPath chains through nested mappings and sequences" {
    const input =
        \\outer:
        \\  items:
        \\    - first
        \\    - second
        \\  meta:
        \\    name: ada
        \\
    ;
    const doc = try Parser.parse(testing.allocator, input, .v1_2_2);
    defer doc.deinit(testing.allocator);

    // key -> key -> index chaining (previously failed: intermediate keyvalue).
    const second = try doc.ast.getValByPath(&.{ .{ .key = "outer" }, .{ .key = "items" }, .{ .index = 1 } });
    try testing.expectEqualSlices(u8, "second", second.kind.string);

    // key -> key -> key chaining.
    const name = try doc.ast.getValByPath(&.{ .{ .key = "outer" }, .{ .key = "meta" }, .{ .key = "name" } });
    try testing.expectEqualSlices(u8, "ada", name.kind.string);
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
    const first = try doc.ast.getValByPath(&.{ .{ .key = "steps" }, .{ .index = 0 } });
    try testing.expectEqualSlices(u8, "do a\ndo b\n", first.kind.string);
    const second = try doc.ast.getValByPath(&.{ .{ .key = "steps" }, .{ .index = 1 } });
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

test "yaml root block scalar with column-0 content" {
    // `--- >` (or bare `>`): the body may sit at column 0.
    const doc = try Parser.parse(testing.allocator, "--- >\nline1\nline2\nline3\n", .v1_2_2);
    defer doc.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "line1 line2 line3\n", doc.ast.nodes[doc.ast.root].kind.string);

    // A `#` line is content inside a block scalar, not a comment.
    const hash = try Parser.parse(testing.allocator, "--- |\nline1\n# kept\nline3\n", .v1_2_2);
    defer hash.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "line1\n# kept\nline3\n", hash.ast.nodes[hash.ast.root].kind.string);
}

test "yaml next-line plain value folds same-indent continuations" {
    // The value lines all sit at the same indent (deeper than the key).
    const doc = try Parser.parse(testing.allocator, "plain:\n  one two\n  three\nnext: x\n", .v1_2_2);
    defer doc.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "one two three", (try doc.ast.getValByPath(&.{.{ .key = "plain" }})).kind.string);
    try testing.expectEqualSlices(u8, "x", (try doc.ast.getValByPath(&.{.{ .key = "next" }})).kind.string);
}

test "yaml explicit block keys" {
    // `? key` / `: value` forms a normal mapping entry.
    const doc = try Parser.parse(testing.allocator, "? key\n: value\nplain: x\n", .v1_2_2);
    defer doc.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "value", (try doc.ast.getValByPath(&.{.{ .key = "key" }})).kind.string);
    try testing.expectEqualSlices(u8, "x", (try doc.ast.getValByPath(&.{.{ .key = "plain" }})).kind.string);
}

test "yaml explicit key with empty value is null" {
    // `? a` / `? b` with no `:` give a and b null values; `c:` is also null.
    const doc = try Parser.parse(testing.allocator, "? a\n? b\nc:\n", .v1_2_2);
    defer doc.deinit(testing.allocator);
    for ([_][]const u8{ "a", "b", "c" }) |key| {
        try testing.expect(std.meta.activeTag((try doc.ast.getValByPath(&.{.{ .key = key }})).kind) == .null_);
    }
}

test "yaml mapping mixes explicit and implicit entries" {
    const input =
        \\mapping:
        \\  ? sky
        \\  : blue
        \\  sea: green
        \\
    ;
    const doc = try Parser.parse(testing.allocator, input, .v1_2_2);
    defer doc.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "blue", (try doc.ast.getValByPath(&.{ .{ .key = "mapping" }, .{ .key = "sky" } })).kind.string);
    try testing.expectEqualSlices(u8, "green", (try doc.ast.getValByPath(&.{ .{ .key = "mapping" }, .{ .key = "sea" } })).kind.string);
}

test "yaml explicit block-scalar key" {
    const doc = try Parser.parse(testing.allocator, "? |\n  block key\n: value\n", .v1_2_2);
    defer doc.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "value", (try doc.ast.getValByPath(&.{.{ .key = "block key\n" }})).kind.string);
}

test "yaml flow pairs in flow sequences" {
    // An implicit flow pair: the element is a single-entry mapping.
    const implicit = try Parser.parse(testing.allocator, "[ a: 1, b: 2 ]\n", .v1_2_2);
    defer implicit.deinit(testing.allocator);
    try testing.expect(std.meta.activeTag((try implicit.ast.getValByPath(&.{ .{ .index = 0 }, .{ .key = "a" } })).kind) == .number);
    try testing.expect(std.meta.activeTag((try implicit.ast.getValByPath(&.{ .{ .index = 1 }, .{ .key = "b" } })).kind) == .number);

    // An explicit flow pair and a plain element side by side.
    const explicit = try Parser.parse(testing.allocator, "[ ? k : v, plain ]\n", .v1_2_2);
    defer explicit.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "v", (try explicit.ast.getValByPath(&.{ .{ .index = 0 }, .{ .key = "k" } })).kind.string);
    try testing.expectEqualSlices(u8, "plain", (try explicit.ast.getValByPath(&.{.{ .index = 1 }})).kind.string);
}

test "yaml rejects implicit flow pair with colon on next line" {
    // An implicit key's `:` must be on the key's line.
    try testParserError("[ key\n  : value ]\n", error.UnexpectedToken);
}

test "yaml flow JSON-style adjacent colons" {
    // After a quoted (JSON-style) key, `:` may abut the value with no space.
    const doc = try Parser.parse(testing.allocator, "{ \"a\":1, \"b\": 2 }\n", .v1_2_2);
    defer doc.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "1", (try doc.ast.getValByPath(&.{.{ .key = "a" }})).kind.number.raw);
    try testing.expectEqualSlices(u8, "2", (try doc.ast.getValByPath(&.{.{ .key = "b" }})).kind.number.raw);

    // The adjacent colon may also sit on a continuation line in flow.
    const wrapped = try Parser.parse(testing.allocator, "{ \"foo\"\n  :bar }\n", .v1_2_2);
    defer wrapped.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "bar", (try wrapped.ast.getValByPath(&.{.{ .key = "foo" }})).kind.string);

    // A literal quote inside a plain scalar is NOT a JSON key.
    const plain = try Parser.parse(testing.allocator, "[ ab:cd ]\n", .v1_2_2);
    defer plain.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "ab:cd", (try plain.ast.getValByPath(&.{.{ .index = 0 }})).kind.string);
}

test "yaml flow collection as a block mapping key" {
    const doc = try Parser.parse(testing.allocator, "[a, b]: value\n", .v1_2_2);
    defer doc.deinit(testing.allocator);
    const map = doc.ast.nodes[doc.ast.root];
    try testing.expect(std.meta.activeTag(map.kind) == .mapping);
    const pair = doc.ast.nodes[map.kind.mapping.?];
    try testing.expect(std.meta.activeTag(doc.ast.nodes[pair.kind.keyvalue.key].kind) == .sequence);
    try testing.expectEqualSlices(u8, "value", doc.ast.nodes[pair.kind.keyvalue.value].kind.string);

    // A flow collection key spanning lines is not a valid implicit key.
    try testParserError("[1\n]: x\n", error.UnexpectedToken);
}

test "yaml multi-line plain flow scalar folds" {
    // A plain scalar inside flow folds its line breaks like a quoted one.
    const seq = try Parser.parse(testing.allocator, "[ a\n  b, c ]\n", .v1_2_2);
    defer seq.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "a b", (try seq.ast.getValByPath(&.{.{ .index = 0 }})).kind.string);
    try testing.expectEqualSlices(u8, "c", (try seq.ast.getValByPath(&.{.{ .index = 1 }})).kind.string);

    // A multi-line plain scalar as a flow mapping key.
    const map = try Parser.parse(testing.allocator, "{ multi\n  line: value }\n", .v1_2_2);
    defer map.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "value", (try map.ast.getValByPath(&.{.{ .key = "multi line" }})).kind.string);
}

test "yaml multi-line quoted flow scalar folds" {
    const doc = try Parser.parse(testing.allocator, "[ \"a\n  b\", 'c\n  d' ]\n", .v1_2_2);
    defer doc.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "a b", (try doc.ast.getValByPath(&.{.{ .index = 0 }})).kind.string);
    try testing.expectEqualSlices(u8, "c d", (try doc.ast.getValByPath(&.{.{ .index = 1 }})).kind.string);
}

test "yaml rejects comment inside a flow plain scalar" {
    // A comment line breaks a multi-line flow scalar; the text after it is then a
    // second element with no separating comma, which is invalid.
    try testParserError("[ word1\n  # xxx\n  word2 ]\n", error.UnexpectedToken);
}

test "yaml flow mapping with explicit keys and empty values" {
    // `? foo :` is foo→null; `: bar` is null→bar.
    const doc = try Parser.parse(testing.allocator, "{ ? foo :, : bar, }\n", .v1_2_2);
    defer doc.deinit(testing.allocator);
    try testing.expect(std.meta.activeTag((try doc.ast.getValByPath(&.{.{ .key = "foo" }})).kind) == .null_);
}

test "yaml next-line scalar value" {
    // A plain scalar value on the line after its key.
    const doc = try Parser.parse(testing.allocator, "key:\n  value\nnext: x\n", .v1_2_2);
    defer doc.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "value", (try doc.ast.getValByPath(&.{.{ .key = "key" }})).kind.string);
    try testing.expectEqualSlices(u8, "x", (try doc.ast.getValByPath(&.{.{ .key = "next" }})).kind.string);
}

test "yaml next-line scalar value nested" {
    const input =
        \\a:
        \\  b:
        \\    c
        \\  d: e
        \\
    ;
    const doc = try Parser.parse(testing.allocator, input, .v1_2_2);
    defer doc.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "c", (try doc.ast.getValByPath(&.{ .{ .key = "a" }, .{ .key = "b" } })).kind.string);
    try testing.expectEqualSlices(u8, "e", (try doc.ast.getValByPath(&.{ .{ .key = "a" }, .{ .key = "d" } })).kind.string);
}

test "yaml next-line flow value" {
    const doc = try Parser.parse(testing.allocator, "key:\n  [1, 2]\n", .v1_2_2);
    defer doc.deinit(testing.allocator);
    try testing.expect(std.meta.activeTag((try doc.ast.getValByPath(&.{.{ .key = "key" }})).kind) == .sequence);
    try testing.expectEqualSlices(u8, "2", (try doc.ast.getValByPath(&.{ .{ .key = "key" }, .{ .index = 1 } })).kind.number.raw);
}

test "yaml rejects content at a next-line value's indent" {
    // After `key:`'s scalar value, a mapping entry at the value's (deeper) indent
    // is over-indented and invalid.
    try testParserError("key:\n  word1 word2\n  no: key\n", error.UnexpectedToken);
    // A scalar value at the SAME indent as its key is not a value either.
    try testParserError("key:\nvalue\n", error.UnexpectedToken);
}

test "yaml explicit value compact block sequence" {
    // After an explicit-value `:`, a compact block sequence (first entry on the
    // `:` line) may continue on following lines.
    const doc = try Parser.parse(testing.allocator, "? k\n: - one\n  - two\n", .v1_2_2);
    defer doc.deinit(testing.allocator);
    const seq = try doc.ast.getValByPath(&.{.{ .key = "k" }});
    try testing.expect(std.meta.activeTag(seq.kind) == .sequence);
    try testing.expectEqualSlices(u8, "one", (try doc.ast.getValByPath(&.{ .{ .key = "k" }, .{ .index = 0 } })).kind.string);
    try testing.expectEqualSlices(u8, "two", (try doc.ast.getValByPath(&.{ .{ .key = "k" }, .{ .index = 1 } })).kind.string);
}

test "yaml rejects compact block sequence as implicit mapping value" {
    // `key: - a` (block sequence compact on an implicit key's line) is invalid;
    // the sequence must begin on the next line.
    try testParserError("key: - a\n     - b\n", error.UnexpectedToken);
}

test "yaml sequence entry with explicit-key mapping value" {
    // `- ? : x` is a sequence entry whose value is an explicit-key mapping with
    // an empty (null) key.
    const entry = try Parser.parse(testing.allocator, "- ? : x\n", .v1_2_2);
    defer entry.deinit(testing.allocator);
    const pair = try entry.ast.getValByPath(&.{.{ .index = 0 }});
    try testing.expect(std.meta.activeTag(pair.kind) == .mapping);
}

test "yaml complex block keys (block sequence as key)" {
    // Key on the next line, `:` after a dedent: `? - a\n  - b\n: c`.
    const multi = try Parser.parse(testing.allocator, "? - a\n  - b\n: c\n", .v1_2_2);
    defer multi.deinit(testing.allocator);
    {
        const map = multi.ast.nodes[multi.ast.root];
        try testing.expect(std.meta.activeTag(map.kind) == .mapping);
        const pair = multi.ast.nodes[map.kind.mapping.?];
        const key = multi.ast.nodes[pair.kind.keyvalue.key];
        try testing.expect(std.meta.activeTag(key.kind) == .sequence);
        try testing.expectEqualSlices(u8, "a", multi.ast.nodes[key.kind.sequence.?].kind.string);
        try testing.expectEqualSlices(u8, "c", multi.ast.nodes[pair.kind.keyvalue.value].kind.string);
    }

    // Key and `:` on adjacent lines at the same indent (no dedent between):
    // `complex: \n  ? - a\n  : b`.
    const compact = try Parser.parse(testing.allocator, "complex:\n  ? - a\n  : b\n", .v1_2_2);
    defer compact.deinit(testing.allocator);
    const inner = try compact.ast.getValByPath(&.{.{ .key = "complex" }});
    try testing.expect(std.meta.activeTag(inner.kind) == .mapping);
}

test "yaml rejects tab before a block sequence indicator" {
    // A tab separating a `?`/`:` from a `-` would indent the block with a tab.
    try testParserError("?\t-\n", error.TabIndent);
    try testParserError("? -\n:\t-\n", error.TabIndent);
}

test "yaml merge key is an ordinary string key" {
    // `<<` is a plain scalar; the merge is a composition-time concern, so for an
    // in-place editor it is just a key named "<<".
    const doc = try Parser.parse(testing.allocator, "<<: {a: 1}\nb: 2\n", .v1_2_2);
    defer doc.deinit(testing.allocator);
    try testing.expect(std.meta.activeTag((try doc.ast.getValByPath(&.{.{ .key = "<<" }})).kind) == .mapping);
    try testing.expect(std.meta.activeTag((try doc.ast.getValByPath(&.{.{ .key = "b" }})).kind) == .number);
}

test "yaml rejects flow-shaped root scalars" {
    try testParserError("[ a, b, c ] ]\n", error.UnexpectedToken);
    try testParserError("]\n", error.UnexpectedToken);
    // A leading `,` is still not a valid plain scalar.
    try testParserError(",x\n", error.UnexpectedToken);
}

test "yaml rejects malformed block-scalar indentation indicator" {
    // The indentation indicator must be a single digit 1-9: `0` and a second
    // digit are invalid, and a `|`/`>` may not begin a plain scalar.
    try testParserError("--- |0\n", error.InvalidBlockHeader);
    try testParserError("--- |10\n", error.InvalidBlockHeader);
    // A valid single-digit indicator with chomping still parses.
    const ok = try Parser.parse(testing.allocator, "--- |1-\n", .v1_2_2);
    defer ok.deinit(testing.allocator);
}

test "yaml explicit block indent counts from the owner column" {
    // `- k: |2`: the content indent is the key's column (2) + 2 = 4, not the
    // line's leading indent (0). The body must dedent by 4 and stop before the
    // sibling `m:`, rather than over-capturing it.
    const doc = try Parser.parse(testing.allocator, "- k: |2\n     X\n    y: 1\n  m: 2\n", .v1_2_2);
    defer doc.deinit(testing.allocator);
    const k = try doc.ast.getValByPath(&.{ .{ .index = 0 }, .{ .key = "k" } });
    try testing.expectEqualSlices(u8, " X\ny: 1\n", k.kind.string);
    const m = try doc.ast.getValByPath(&.{ .{ .index = 0 }, .{ .key = "m" } });
    try testing.expect(std.meta.activeTag(m.kind) == .number);
}

test "yaml rejects an inline mapping value" {
    // A mapping value on the `:` line cannot itself be a block mapping.
    try testParserError("a: b: c: d\n", error.UnexpectedToken);
    try testParserError("---\na: 'b': c\n", error.UnexpectedToken);
}

test "yaml rejects trailing content after a complete value" {
    // Junk after an inline scalar or flow value on the same line is invalid.
    try testParserError("key: \"v\" no key: nor value\n", error.UnexpectedToken);
    try testParserError("---\nx: { y: z }in: valid\n", error.UnexpectedToken);
}

test "yaml rejects a mapping key at a sequence's indent" {
    // A block sequence and mapping cannot share an indentation level when the
    // mapping key belongs to no enclosing mapping.
    try testParserError("- item1\n- item2\ninvalid: x\n", error.UnexpectedToken);
}

test "yaml indentless sequence returns to the enclosing mapping" {
    // A block sequence written at its parent key's column (no extra indent) is
    // that key's value; a sibling key at the same column ends the sequence and
    // belongs to the enclosing mapping — `four` is a sibling of `one`, not a
    // member of its sequence.
    const root = try Parser.parse(testing.allocator, "one:\n- 2\n- 3\nfour: 5\n", .v1_2_2);
    defer root.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "2", (try root.ast.getValByPath(&.{ .{ .key = "one" }, .{ .index = 0 } })).kind.number.raw);
    try testing.expectEqualSlices(u8, "3", (try root.ast.getValByPath(&.{ .{ .key = "one" }, .{ .index = 1 } })).kind.number.raw);
    try testing.expectEqualSlices(u8, "5", (try root.ast.getValByPath(&.{.{ .key = "four" }})).kind.number.raw);

    // The same, nested one level deeper: `c` is a sibling of `b` inside `a`.
    const nested = try Parser.parse(testing.allocator, "a:\n  b:\n  - 1\n  - 2\n  c: hello\n", .v1_2_2);
    defer nested.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "1", (try nested.ast.getValByPath(&.{ .{ .key = "a" }, .{ .key = "b" }, .{ .index = 0 } })).kind.number.raw);
    try testing.expectEqualSlices(u8, "hello", (try nested.ast.getValByPath(&.{ .{ .key = "a" }, .{ .key = "c" } })).kind.string);
}

test "yaml indentless sequence in a nested mapping closes on dedent to an outer key" {
    // The dedent variant: the sibling key sits at a *shallower* column than the
    // indentless sequence, so a single dedent must close both the sequence and
    // its enclosing mapping. `other` is a root sibling of `meta`, not nested
    // under it. (Regression: previously `other` was absorbed into `meta`.)
    const doc = try Parser.parse(testing.allocator, "meta:\n  revs:\n  - 1\n  - 2\nother: x\n", .v1_2_2);
    defer doc.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "1", (try doc.ast.getValByPath(&.{ .{ .key = "meta" }, .{ .key = "revs" }, .{ .index = 0 } })).kind.number.raw);
    try testing.expectEqualSlices(u8, "2", (try doc.ast.getValByPath(&.{ .{ .key = "meta" }, .{ .key = "revs" }, .{ .index = 1 } })).kind.number.raw);
    try testing.expectEqualSlices(u8, "x", (try doc.ast.getValByPath(&.{.{ .key = "other" }})).kind.string);

    // Two levels deep: one dedent closes the seq + its mapping, a second closes
    // the next mapping; `next` lands at the root.
    const deep = try Parser.parse(testing.allocator, "a:\n  b:\n    c:\n    - 1\n    - 2\nnext: y\n", .v1_2_2);
    defer deep.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "1", (try deep.ast.getValByPath(&.{ .{ .key = "a" }, .{ .key = "b" }, .{ .key = "c" }, .{ .index = 0 } })).kind.number.raw);
    try testing.expectEqualSlices(u8, "y", (try deep.ast.getValByPath(&.{.{ .key = "next" }})).kind.string);
}

test "yaml mapping as an explicit key" {
    // `? earth: blue\n: moon: white` — the key and value are each a mapping.
    const doc = try Parser.parse(testing.allocator, "? earth: blue\n: moon: white\n", .v1_2_2);
    defer doc.deinit(testing.allocator);
    const map = doc.ast.nodes[doc.ast.root];
    try testing.expect(std.meta.activeTag(map.kind) == .mapping);
    const pair = doc.ast.nodes[map.kind.mapping.?];
    try testing.expect(std.meta.activeTag(doc.ast.nodes[pair.kind.keyvalue.key].kind) == .mapping);
    try testing.expect(std.meta.activeTag(doc.ast.nodes[pair.kind.keyvalue.value].kind) == .mapping);

    // A tab standing in for the nested mapping's indentation is invalid.
    try testParserError("?\tkey:\n", error.UnexpectedToken);
    try testParserError("? key:\n:\tkey:\n", error.UnexpectedToken);
}

test "yaml plain scalar continuation may start with an indicator" {
    // On a continuation line `!`, `&`, etc. are plain content, not node-start
    // indicators; the scalar folds across the break with a space.
    const doc = try Parser.parse(testing.allocator, "safe: a b\n      !c d\nnext: 1\n", .v1_2_2);
    defer doc.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "a b !c d", (try doc.ast.getValByPath(&.{.{ .key = "safe" }})).kind.string);
}
