//! The parser turns YAML tokens into a concrete syntax tree.
//! Depends on the tokenizer and the abstract Document struct.

const std = @import("std");
const AST = @import("../ast/ast.zig");
const Document = @import("../document.zig");
const util = @import("../util/util.zig");
const Span = @import("../util/span.zig");
const Unicode = util.Unicode;
const ascii = util.ascii;
const datetime = util.datetime;
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
    /// A comment on the `key:` line whose value is a block collection on the
    /// following lines (`contents: # note\n- a`). It belongs to the entry, not to
    /// the value's first child, so it is parked here and bound to the value (as
    /// its trailing comment) when the entry is completed in `finishValue`.
    pending_value_trailing: ?AST.Comment = null,
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
    // Source column of the `?` indicator while `building_explicit_key`. A dedent
    // that lands BELOW this column ends the explicit entry with a null value and
    // closes this mapping; one landing AT it leaves room for a `:` value line.
    explicit_key_col: usize = 0,
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
// Node properties (`!tag`, `&anchor`) seen but not yet attached to the node they
// decorate. Consumed by the next `addNode`.
pending_tag: ?PendingTag = null,
pending_anchor: ?PendingAnchor = null,
// When a second property of the same kind appears before its node is built, the
// earlier one belongs to a container that opens first and its first key/element
// carries the later one (`&map\n&key k: v`, `top: &node\n  &k key: v`). The
// earlier property is parked here and claimed by the next `openContainer`.
container_tag: ?PendingTag = null,
container_anchor: ?PendingAnchor = null,
container_stack: std.ArrayList(OpenContainer) = .empty,
owned_strings: std.ArrayList([]const u8) = .empty,
// Named tag handles (`!e!`, `!prefix!`) declared by `%TAG` directives in this
// document. A named handle used by a tag must be declared (the `!` and `!!`
// default handles are always available and not listed). Per-document by
// construction: a stream is parsed one document at a time, each with a fresh
// Parser, so a handle declared for one document is not visible to the next.
tag_handles: std.ArrayList([]const u8) = .empty,
tokens: []const Token = &.{},
index: usize = 0,
// Comment layer. Captured centrally in `advance` (the only place a comment
// token is consumed) and reset on each `.newline`. `pending_leading` buffers
// own-line comments until the next non-container node claims them (`addNode`,
// unless `parking_container`). Comment text borrows `source`. `pending_leading`
// is reserved to `tokens.len` once so `advance` can append without failing.
node_comments: std.ArrayList(AST.NodeComments) = .empty,
pending_leading: std.ArrayList(AST.Comment) = .empty,
last_value_id: ?AST.Node.Id = null,
comments_seen: bool = false,
/// True between a value-indicator `:` and the line's end. A comment seen while
/// set, with no inline value built yet, is the entry's trailing comment (its
/// value is a block collection below), not leading of that value's first child.
colon_line: bool = false,
// Suppresses leading-comment claiming while a container node is built: a comment
// above a collection belongs to the collection's first key/item (which the
// printer renders), not to the container node (which it does not).
parking_container: bool = false,
force_new_container: bool = false,
// Count of indents opened solely to hold a scalar/flow value on the line after
// its key (`key:\n  value`). Such an indent opens no container, so its matching
// dedent must be skipped rather than closing the awaiting parent.
value_only_indents: usize = 0,
root: ?AST.Node.Id = null,
doc_started: bool = false,
doc_ended: bool = false,
// True while still on the `---` marker line. A block collection may not begin
// there (`--- a: b`, `--- - x` are invalid — only a scalar or flow node fits on
// the marker line); cleared at the first newline.
on_doc_start_line: bool = false,
// True once a directive (`%YAML`/`%TAG`/reserved) has been seen for the current
// document but its `---` directives-end marker has not yet appeared. The marker
// is mandatory, so anything other than another directive or the `---` is an
// error (`%YAML 1.2` alone, or followed by `...`).
directives_pending: bool = false,
// True once a `%YAML` directive has been seen for the current document, to
// reject a duplicate one (at most one per document).
yaml_directive_seen: bool = false,

allocator: std.mem.Allocator,
source: []const u8 = "",
/// The YAML version whose scalar-resolution rules `scalarKind` applies. Set
/// from the `format` passed to `parseOnce`. `.v1_1` routes plain scalars
/// through `scalarKind1_1` (1.1 tag-repository resolution); `.v1_2_2` uses the
/// 1.2 core schema. The spec fixtures under `testdata/yaml-1.1/` pin 1.1.
version: Type = .v1_2_2,

const PendingTag = struct { text: []const u8, span: Span };
const PendingAnchor = struct { name: []const u8, span: Span };

const ParseError = error{ UnexpectedToken, EmptyDocument, UnclosedString, InvalidUnicodeEscape, MultipleDocuments, DuplicateProperty, UndefinedAlias, InvalidDirective, UndefinedTagHandle };
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
    self.version = format;

    var tokenizer: Tokenizer = .{
        .allocator = self.allocator,
        .source = input,
        .type = format,
    };

    self.tokens = try tokenizer.tokenize();
    defer self.allocator.free(self.tokens);

    // Reserve once so `advance` (non-fallible) can buffer leading comments with
    // `appendAssumeCapacity`. There can be at most one comment per token.
    try self.pending_leading.ensureTotalCapacity(self.allocator, self.tokens.len);

    while (true) {
        self.skipTriviaNoNewline();
        // A next-line scalar value occupies a fresh indent by itself; the only
        // thing that may follow it at that indent is its closing dedent. Content
        // there (`key:\n  value\n  more: x`) is over-indented and invalid.
        if (self.value_only_indents > 0) switch (self.peek().kind) {
            .newline, .dedent, .end_of_file => {},
            else => return ParseError.UnexpectedToken,
        };
        // A directive must be followed by a `---` directives-end marker. While one
        // is pending, only more directives, blank lines, or that marker are valid;
        // content, a `...` end, or EOF means the marker is missing.
        if (self.directives_pending) switch (self.peek().kind) {
            .directive, .newline, .doc_start => {},
            else => return ParseError.InvalidDirective,
        };
        switch (self.peek().kind) {
            .indent => {
                if (self.container_stack.items.len > 0 and self.currentContainer().continues_sequence_item) {
                    // A compact item container (`- key:` / `- -`) shares its
                    // sequence's dash level and opened no indent of its own. An
                    // indent landing AT the item's own column is its content — a
                    // sibling key (`- a: 1\n  b: 2`): absorb it by clearing the
                    // flag. One landing DEEPER is the pending key's block value
                    // (`- key:\n    nested: v`): open a fresh container for it,
                    // keeping the flag so the next sibling dash (or EOF) still
                    // closes the item — otherwise the value's children flatten
                    // into the item mapping (`{key: null, nested: v}`).
                    if (self.columnOf(self.peek().span.end) > self.currentContainerIndent()) {
                        self.force_new_container = true;
                    } else {
                        self.currentContainer().continues_sequence_item = false;
                    }
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
                } else if (self.force_new_container and (self.pending_anchor != null or self.pending_tag != null)) {
                    // The indent being closed held only a node property (`seq:\n
                    // &a\n- x`): it opened no container, so skip the close and keep
                    // the property for the value at the dedented (indentless) level.
                    self.force_new_container = false;
                    _ = self.advance();
                } else {
                    try self.closePendingEmptyValue();
                    const dedent = self.advance();
                    const dedent_col = self.columnOf(dedent.span.start);
                    // Close the container at this indent. Two flags mean a
                    // container shares its parent's indent level and opened no
                    // indent of its own, so the single dedent matching that level
                    // must also close the parent (and any further such nesting):
                    //   - `shares_parent_indent`: an indentless block sequence
                    //     shares its enclosing mapping's column (`k:\n  s:\n  - 1`).
                    //   - `continues_sequence_item`: an item container opened on a
                    //     dash line (`- k: v` → a mapping; `- - x` → a sequence)
                    //     shares its enclosing sequence's dash level, since the
                    //     content after the `-` pushes no indent of its own. Without
                    //     this the enclosing sequence is closed lazily against the
                    //     wrong level and every following key lands one level too
                    //     deep (a top-level field then reads as "dropped").
                    while (true) {
                        var close_parent_too = self.container_stack.items.len > 0 and
                            (self.currentContainer().shares_parent_indent or
                                self.currentContainer().continues_sequence_item);
                        // A complex explicit key with no `:` value (`? - a` then a
                        // dedent to a shallower sibling): the key container opened
                        // mid-line, so this dedent must also close the explicit
                        // mapping with a null value — but only when it lands BELOW
                        // the `?` column. Landing AT it leaves room for a `:` value
                        // line (`? - a\n  - b\n: c`), so the mapping stays open.
                        if (!close_parent_too and self.container_stack.items.len >= 2) {
                            const parent = self.container_stack.items[self.container_stack.items.len - 2];
                            if (parent.building_explicit_key and dedent_col < parent.explicit_key_col)
                                close_parent_too = true;
                        }
                        const id = try self.closeContainer(dedent.span.end);
                        try self.finishValue(id);
                        if (!close_parent_too) break;
                        try self.closePendingEmptyValue();
                    }
                    // A dedent landing exactly at an open compact item mapping's
                    // own column returns to a SIBLING key within that item (`- k:\n
                    // v: 1\n  sib: 2`): the first key's block value just closed, and
                    // the next key belongs to the same item mapping. Clear the
                    // continuation flag so it is treated as a sibling rather than
                    // closing the item. (The tokenizer admits this column via a
                    // sequence-entry content level; a dedent BELOW the item column
                    // leaves the flag set, so the item still closes there.)
                    if (self.container_stack.items.len > 0) {
                        const c = self.currentContainer();
                        if (c.continues_sequence_item and c.kind == .mapping and
                            self.columnOf(self.node_spans.items[c.id].start) == dedent_col)
                            c.continues_sequence_item = false;
                    }
                }
            },
            .newline => {
                self.on_doc_start_line = false;
                _ = self.advance();
            },
            .doc_start => {
                // A second document start (or one after content) is multi-doc,
                // which is out of scope.
                if (self.doc_started or self.nodes.items.len > 0) return ParseError.MultipleDocuments;
                self.doc_started = true;
                self.on_doc_start_line = true;
                // The `---` ends any directives prefix and resolves it.
                self.directives_pending = false;
                _ = self.advance();
            },
            .directive => {
                // Directives may only introduce a document: before its `---`, with
                // no content yet. A directive after content (`foo\n%YAML`) or after
                // the `---`/content of this single document is invalid.
                if (self.doc_started or self.doc_ended or self.root != null or
                    self.nodes.items.len > 0 or self.container_stack.items.len > 0)
                    return ParseError.InvalidDirective;
                const tok = self.advance();
                try self.parseDirective(tok.source(self.source));
                self.directives_pending = true;
            },
            .doc_end => {
                self.doc_ended = true;
                _ = self.advance();
            },
            .dash => {
                if (self.doc_ended) return ParseError.MultipleDocuments;
                // A block sequence cannot begin on the `---` marker line.
                if (self.on_doc_start_line) return ParseError.UnexpectedToken;
                // A block sequence's `-` must begin its own line. A property on the
                // same line before it (`&anchor - x`) is invalid — unlike a compact
                // `: - x` value, which is parsed in parseMappingValue, not here.
                if (self.pendingPropOnLineOf(self.peek().span.start)) return ParseError.UnexpectedToken;
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
                // A deferred explicit key (`?` alone on its line) whose `:` arrives
                // with no key content: the key is empty (null). closeOpenComplexKey
                // already resolved the case where key content WAS supplied, leaving
                // building_explicit_key set only when none was.
                if (self.container_stack.items.len > 0 and self.currentContainer().building_explicit_key) {
                    const null_key = try self.addNode(.null_, .init(self.peek().span.start, self.peek().span.start));
                    const m = self.currentContainer();
                    m.building_explicit_key = false;
                    m.pending_key = null_key;
                    m.explicit_awaiting_value = true;
                }
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
                    // A block mapping cannot begin on the `---` marker line.
                    if (self.on_doc_start_line) return ParseError.UnexpectedToken;
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
            .alias => {
                // An alias is a whole value node (`k: *a`, `- *a`, `*a : b`).
                if (self.doc_ended) return ParseError.MultipleDocuments;
                try self.closeSequenceItemContinuation();
                if (self.isMappingStart()) {
                    try self.parseMappingEntry();
                } else if (self.container_stack.items.len == 0 and self.root == null) {
                    const value_id = try self.parseAlias();
                    try self.finishValue(value_id);
                } else if (self.force_new_container and self.currentAwaitsValue()) {
                    const value_id = try self.parseAlias();
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
                } else if (self.force_new_container and self.currentAwaitsValue()) {
                    // A block scalar written on the line after its key (`k:\n  >1`).
                    const value_id = try self.parseBlockScalar();
                    try self.attachDeferredValue(value_id);
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
            .tag, .anchor => {
                // A node property at a value/root position: stash it; the node it
                // decorates is parsed on a following loop iteration (and `addNode`
                // attaches it). Covers `!!str foo`, `&a [1]`, `&a key: v`, an
                // anchored/tagged root, an anchor on its own line, etc.
                if (self.doc_ended) return ParseError.MultipleDocuments;
                const in_container = self.container_stack.items.len > 0;
                try self.consumePendingProperties();
                // A property standing alone on its line inside a container is valid
                // only as a deferred value that out-indents its key/dash (a fresh
                // indent over a mapping awaiting a value or a sequence after a dash).
                // Otherwise it is misplaced: at the key's own column (`seq:\n&a\n-
                // x`), or floating in a sequence with no dash (`- a\n&b\n- c`).
                if (in_container) switch (self.peek().kind) {
                    .newline, .dedent, .end_of_file => {
                        if (!(self.force_new_container and self.currentAwaitsValue()))
                            return ParseError.UnexpectedToken;
                    },
                    else => {},
                };
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

    // A parked container property that never opened a container means two
    // properties of one kind decorated a single node (`&a &b scalar`) — invalid.
    if (self.container_anchor != null or self.container_tag != null) return ParseError.DuplicateProperty;

    // Every alias must reference an anchor defined earlier in the document.
    try self.resolveAliasesOrError();

    // An empty document — no content node, only comments, blank lines, or
    // document markers — is valid; its root is the null node.
    const root = self.root orelse try self.addNode(.null_, self.peek().span);
    // End-of-document orphan comments dangle off the root.
    try self.claimDangling(root);
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
    var ast: AST = .{
        .allocator = self.allocator,
        .owned_strings = owned_strings,
        .root = root,
        .nodes = nodes,
        .node_tags = node_tags,
        .node_anchors = node_anchors,
        .anchors = anchors,
    };
    if (self.comments_seen) {
        ast.node_comments = try self.node_comments.toOwnedSlice(self.allocator);
        self.node_comments = .empty;
    }
    return .{
        .source = input,
        .ast = ast,
        .node_spans = node_spans,
        .node_tag_spans = node_tag_spans,
        .node_anchor_spans = node_anchor_spans,
    };
}

/// Validate a directive line (`line` is the token text, starting with `%`).
/// `%YAML` carries exactly one `major.minor` version and at most one may appear
/// per document; `%TAG` carries a handle and a prefix; any other name is a
/// reserved directive, accepted and ignored. fig does not act on directives —
/// tags are kept verbatim for round-tripping — so this only checks their syntax.
fn parseDirective(self: *Parser, line: []const u8) ParserError!void {
    std.debug.assert(line.len > 0 and line[0] == '%');
    var i: usize = 1;
    const name_start = i;
    while (i < line.len and !isDirectiveSpace(line[i])) i += 1;
    const name = line[name_start..i];
    if (name.len == 0) return ParseError.InvalidDirective; // `%` with no name

    if (std.mem.eql(u8, name, "YAML")) {
        // At most one `%YAML` per document.
        if (self.yaml_directive_seen) return ParseError.InvalidDirective;
        self.yaml_directive_seen = true;
        i = skipDirectiveSpace(line, i);
        const ver_start = i;
        while (i < line.len and !isDirectiveSpace(line[i])) i += 1;
        if (!isYamlVersion(line[ver_start..i])) return ParseError.InvalidDirective;
        try requireDirectiveEnd(line, i);
    } else if (std.mem.eql(u8, name, "TAG")) {
        i = skipDirectiveSpace(line, i);
        const handle_start = i;
        while (i < line.len and !isDirectiveSpace(line[i])) i += 1;
        const handle = line[handle_start..i];
        if (handle.len == 0) return ParseError.InvalidDirective; // missing handle
        i = skipDirectiveSpace(line, i);
        const prefix_start = i;
        while (i < line.len and !isDirectiveSpace(line[i])) i += 1;
        if (i == prefix_start) return ParseError.InvalidDirective; // missing prefix
        try requireDirectiveEnd(line, i);
        // Record a named handle (`!e!`) so tags may use it. The `!`/`!!` default
        // handles need no declaration; recording them is harmless.
        try self.tag_handles.append(self.allocator, handle);
    }
    // else: a reserved directive — accepted and ignored (params unrestricted).
}

fn isDirectiveSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r';
}

fn skipDirectiveSpace(line: []const u8, i: usize) usize {
    var j = i;
    while (j < line.len and isDirectiveSpace(line[j])) j += 1;
    return j;
}

/// A `%YAML` version is `major.minor`, both non-empty digit runs.
fn isYamlVersion(s: []const u8) bool {
    const dot = std.mem.indexOfScalar(u8, s, '.') orelse return false;
    const major = s[0..dot];
    const minor = s[dot + 1 ..];
    if (major.len == 0 or minor.len == 0) return false;
    for (major) |c| if (!std.ascii.isDigit(c)) return false;
    for (minor) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// After a directive's parameters only blanks and an optional `#` comment may
/// follow (a comment must be whitespace-separated, which the parameter scan,
/// stopping at the first space, already guarantees).
fn requireDirectiveEnd(line: []const u8, i: usize) ParseError!void {
    const j = skipDirectiveSpace(line, i);
    if (j < line.len and line[j] != '#') return ParseError.InvalidDirective;
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
    self.tag_handles.deinit(self.allocator);
    // After a successful parse these `leading` slices moved to the AST and the
    // list is empty; on an error path they are freed here. Text borrows `source`.
    for (self.node_comments.items) |nc| self.allocator.free(nc.leading);
    self.node_comments.deinit(self.allocator);
    self.pending_leading.deinit(self.allocator);
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
        .alias => {
            // A sequence entry that is an alias (`- *a`), or an alias key mapping
            // entry (`- *a : b`).
            if (self.isMappingStart()) {
                const mapping_id = try self.openContainer(.mapping, self.peek().span.start);
                self.containerById(mapping_id).continues_sequence_item = true;
                try self.parseMappingEntry();
            } else {
                const value_id = try self.parseAlias();
                try self.finishValue(value_id);
            }
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
        .dash => {
            // A compact nested sequence (`- - c`): the inner dash opens a
            // sequence nested inside this one, rather than continuing it. Open it
            // as a child container marked to absorb the following line's indent
            // (`continues_sequence_item`, as the compact-value and complex-key
            // paths do), then parse its first entry. Without the explicit open,
            // `ensureContainer` would return this same sequence and the entries
            // would flatten (`- - c` → [c] instead of [[c]]).
            const inner_id = try self.openContainer(.sequence, self.peek().span.start);
            self.containerById(inner_id).continues_sequence_item = true;
            try self.parseSequenceEntry();
        },
        else => return ParseError.UnexpectedToken,
    }
}

fn parseMappingEntry(self: *Parser) ParserError!void {
    const mapping_id = try self.ensureContainer(.mapping);
    try self.closePendingEmptyValue();

    const key_id = try self.parseKeyNode();
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
        .alias => {
            const value_id = try self.parseAlias();
            try self.finishValue(value_id);
            try self.requireValueEnd();
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
    // `?` alone on its line, with no property decorating the key: the key is
    // supplied by following lines (an indentless or indented block collection,
    // `?\n- a\n- b`), not empty. Defer like a complex key — the following content
    // closes into this mapping as its key (building_explicit_key), and a `:` that
    // arrives with no key content resolves to a null key (see the `.colon`
    // main-loop handler). A pending property (`? &a\n`) instead decorates an
    // empty key node here and now, so it falls through to the null-key arm.
    if (self.peek().kind == .newline and self.pending_anchor == null and self.pending_tag == null) {
        self.containerById(mapping_id).building_explicit_key = true;
        self.containerById(mapping_id).explicit_key_col = self.columnOf(marker.span.start);
        return;
    }
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
                self.containerById(mapping_id).explicit_key_col = self.columnOf(marker.span.start);
                const key_map_id = try self.openContainer(.mapping, self.peek().span.start);
                self.containerById(key_map_id).continues_sequence_item = true;
                try self.parseMappingEntry();
                return;
            }
            break :key try self.parseScalar();
        },
        .flow_seq_start, .flow_map_start => flow: {
            const node_id = try self.parseFlowNode();
            self.skipTriviaNoNewline();
            if (self.peek().kind == .colon) {
                // A complex key that is itself a flow-keyed block mapping
                // (`? []: x`): open a key mapping with the flow node as its first
                // key, mirroring the block-mapping key path.
                self.containerById(mapping_id).building_explicit_key = true;
                self.containerById(mapping_id).explicit_key_col = self.columnOf(marker.span.start);
                const key_map_id = try self.openContainer(.mapping, self.node_spans.items[node_id].start);
                self.containerById(key_map_id).continues_sequence_item = true;
                const colon = self.advance();
                const km = self.containerById(key_map_id);
                km.pending_key = node_id;
                km.pending_value_span = colon.span.end;
                try self.parseMappingValue(false);
                return;
            }
            break :flow node_id;
        },
        .block_header => try self.parseBlockScalar(),
        .alias => try self.parseAlias(), // `? *a`
        .dash => {
            // A complex key that is itself a block sequence (`? - a\n  - b`).
            // Open it as a child container and mark the mapping as building its
            // key; when the sequence closes — at the dedent before `:`, or when
            // the `:` itself closes it — it becomes the pending key (see
            // finishValue), not a value.
            self.containerById(mapping_id).building_explicit_key = true;
            self.containerById(mapping_id).explicit_key_col = self.columnOf(marker.span.start);
            const seq_id = try self.openContainer(.sequence, self.peek().span.start);
            self.containerById(seq_id).continues_sequence_item = true;
            try self.parseSequenceEntry();
            return;
        },
        .colon => {
            // A complex key that is itself an empty-key block mapping (`? : x`):
            // the `:`-led entry on the `?` line is a one-entry mapping serving as
            // the key, mirroring the block-mapping key path (`? a: b`).
            self.containerById(mapping_id).building_explicit_key = true;
            self.containerById(mapping_id).explicit_key_col = self.columnOf(marker.span.start);
            const key_map_id = try self.openContainer(.mapping, self.peek().span.start);
            self.containerById(key_map_id).continues_sequence_item = true;
            try self.parseEmptyKeyEntry();
            return;
        },
        // `?` alone on its line with a decorating property (`? &a\n`), or `?` at
        // end of entry, is a null key.
        .newline, .dedent, .end_of_file => try self.addNode(.null_, .init(marker.span.end, marker.span.end)),
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

/// Validates that every `*name` alias references an anchor `&name` defined
/// earlier in the document (YAML aliases refer backward). `self.anchors` is in
/// node-id order, so an alias resolves to the nearest preceding anchor of the
/// same name; an alias with none is `error.UndefinedAlias`.
fn resolveAliasesOrError(self: *Parser) ParserError!void {
    for (self.nodes.items) |node| {
        const name = switch (node.kind) {
            .alias => |n| n,
            else => continue,
        };
        var found = false;
        for (self.anchors.items) |a| {
            if (a.node >= node.id) break; // sorted by id; no anchor at/after the alias
            if (std.mem.eql(u8, a.name, name)) found = true;
        }
        if (!found) return ParseError.UndefinedAlias;
    }
}

/// Parses a `*name` alias token into an `alias` node. The target anchor is not
/// resolved here; a post-parse pass validates that every alias resolves (see
/// `resolveAliasesOrError`).
fn parseAlias(self: *Parser) ParserError!AST.Node.Id {
    // An alias node takes no properties: `&b *a` / `!!str *a` are malformed
    // (`c-ns-alias-node ::= "*" ns-anchor-name`, nothing else).
    if (self.pending_anchor != null or self.pending_tag != null) return ParseError.UnexpectedToken;
    const token = self.advance(); // .alias, span covers `*name`
    return self.addNode(.{ .alias = token.source(self.source)[1..] }, token.span);
}

/// Parses an implicit mapping key, which is usually a scalar but may also be an
/// alias (`*a : b`).
fn parseKeyNode(self: *Parser) ParserError!AST.Node.Id {
    return if (self.peek().kind == .alias) self.parseAlias() else self.parseScalar();
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
    return self.columnOf(self.node_spans.items[id].start);
}

/// The source column (offset from the start of its line) of byte position `pos`.
fn columnOf(self: *const Parser, pos: usize) usize {
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
    while (true) {
        switch (self.peek().kind) {
            .tag => {
                const t = self.advance();
                try self.stashTag(t.source(self.source), t.span);
            },
            .anchor => {
                const a = self.advance();
                try self.stashAnchor(a.source(self.source)[1..], a.span);
            },
            else => break,
        }
        self.skipFlowTrivia();
    }
    // A property with no node of its own — terminated by a flow indicator —
    // decorates an implicit null (`{!!str : bar}`, `[&a, x]`, `{a: !!str}`).
    if (self.pending_tag != null or self.pending_anchor != null) switch (self.peek().kind) {
        .comma, .colon, .flow_map_end, .flow_seq_end => {
            const at = self.peek().span.start;
            return self.addNode(.null_, .init(at, at));
        },
        else => {},
    };
    return switch (self.peek().kind) {
        .flow_seq_start => self.parseFlowSequence(),
        .flow_map_start => self.parseFlowMapping(),
        .alias => self.parseAlias(),
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
    const empty: AST.Node.Kind = switch (kind) {
        .sequence => .{ .sequence = null },
        .mapping => .{ .mapping = null },
    };
    // A container claims a parked container-slot property (an anchor/tag that
    // preceded it while another property is pending for its first child); the
    // pending property is preserved for that child. With no parked property, the
    // container takes the pending one normally (a lone `&a` before a collection).
    // A container node never carries leading comments itself (see `addNode`);
    // keep them buffered for its first child.
    self.parking_container = true;
    const id = if (self.container_anchor != null or self.container_tag != null) blk: {
        const child_anchor = self.pending_anchor;
        const child_tag = self.pending_tag;
        self.pending_anchor = self.container_anchor;
        self.pending_tag = self.container_tag;
        self.container_anchor = null;
        self.container_tag = null;
        const new_id = try self.addNode(empty, .init(start, start));
        self.pending_anchor = child_anchor;
        self.pending_tag = child_tag;
        break :blk new_id;
    } else try self.addNode(empty, .init(start, start));
    self.parking_container = false;

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
    // This value is the trailing-comment candidate: in both a sequence element
    // and a mapping entry, the value node is the trailing anchor.
    self.last_value_id = value_id;
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

            // A comment parked on the `key:` line binds to this value as its
            // trailing comment (it rides the `key:` line, above the block value).
            if (parent.pending_value_trailing) |c| {
                self.node_comments.items[value_id].trailing = c;
                parent.pending_value_trailing = null;
                self.comments_seen = true;
            }

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
    // While descending into a freshly-opened deeper container (an indent just set
    // `force_new_container` for a compact item's block value, e.g. `- k:\n    a:
    // 1`), the open item continuation is an ANCESTOR being extended, not a sibling
    // to close. Closing it here would attach the deeper content one level too
    // shallow (`{k: null, a: 1}` instead of `{k: {a: 1}}`). For every pre-existing
    // case `force_new_container` is false when this runs (the old indent handler
    // cleared the flag before any indent could coexist), so this is a no-op there.
    if (self.force_new_container) return;
    // Close every stacked same-line continuation container, not just one:
    // compact nested sequences (`- - - x`) leave several sequences open with no
    // dedent between them, and a shallower sibling on the next line must close
    // all of them at once (`- - - []` then `- - - {}` are siblings, not nested).
    while (self.container_stack.items.len > 0 and self.currentContainer().continues_sequence_item) {
        self.currentContainer().continues_sequence_item = false;
        try self.closePendingEmptyValue();
        const id = try self.closeContainer(self.node_spans.items[self.currentContainer().id].end);
        try self.finishValue(id);
    }
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
    if (self.version == .v1_1) return scalarKind1_1(source);
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

// ── YAML 1.1 scalar type resolution ─────────────────────────────────────────
//
// 1.1 resolves plain scalars by the tag repository (yaml.org/type), which
// diverges from 1.2's core schema: `yes`/`no`/`on`/`off`/`y`/`n` booleans,
// leading-zero octal (`0777`) + binary (`0b…`) + sexagesimal (`190:20:30`)
// ints, `_` digit separators, floats requiring a `.` with a *signed* exponent,
// and `!!timestamp` auto-resolution. The lexeme stays in `number.raw` /
// `extended.text`; value normalization (radix, `_`, base-60) is the consumer's
// job — see `conformance_1_1.zig`, which recomputes from the raw.
fn scalarKind1_1(source: []const u8) AST.Node.Kind {
    if (eqlAny(source, &.{ "null", "Null", "NULL", "~" })) return .null_;
    if (bool1_1(source)) |b| return .{ .boolean = b };
    switch (classify1_1Number(source)) {
        .integer => return .{ .number = .{ .raw = source, .kind = .integer } },
        .float => return .{ .number = .{ .raw = source, .kind = .float } },
        .not_number => {},
    }
    if (classify1_1Timestamp(source)) |kind| return .{ .extended = .{ .kind = kind, .text = source } };
    return .{ .string = source };
}

/// YAML 1.1 boolean tag: `y|Y|yes|Yes|YES|true|True|TRUE|on|On|ON` (true) and
/// the matching negatives (false). Only these exact spellings; `yes_please`
/// stays a string.
fn bool1_1(source: []const u8) ?bool {
    if (eqlAny(source, &.{ "y", "Y", "yes", "Yes", "YES", "true", "True", "TRUE", "on", "On", "ON" })) return true;
    if (eqlAny(source, &.{ "n", "N", "no", "No", "NO", "false", "False", "FALSE", "off", "Off", "OFF" })) return false;
    return null;
}

/// Every char of `s` is a `pred` digit or a `_` separator, with at least one
/// real digit (so `0x` / `0b` with an empty body is rejected).
fn digitRun(s: []const u8, comptime pred: fn (u8) bool) bool {
    var any = false;
    for (s) |c| {
        if (c == '_') continue;
        if (!pred(c)) return false;
        any = true;
    }
    return any;
}

/// Classify a plain scalar against the YAML 1.1 int/float tags. Order matters:
/// `.inf`/`.nan` and sexagesimal are checked before the radix prefixes, and the
/// radix prefixes before the decimal/octal/float fork.
fn classify1_1Number(source: []const u8) NumberClass {
    if (source.len == 0) return .not_number;
    if (isInfNan(source)) return .float;

    var s = source;
    if (s[0] == '+' or s[0] == '-') s = s[1..];
    if (s.len == 0) return .not_number;

    // Sexagesimal (`H:MM:SS[.frac]`) — int or float depending on a trailing `.`.
    if (std.mem.indexOfScalar(u8, s, ':') != null) return classify1_1Base60(s);

    // Radix-prefixed integers: hex `0x…`, binary `0b…`.
    if (s.len >= 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X'))
        return if (digitRun(s[2..], ascii.isHex)) .integer else .not_number;
    if (s.len >= 2 and s[0] == '0' and (s[1] == 'b' or s[1] == 'B'))
        return if (digitRun(s[2..], ascii.isBinary)) .integer else .not_number;

    // A `.` makes it a base-10 float (1.1 requires the dot; `1e3` is a string).
    if (std.mem.indexOfScalar(u8, s, '.') != null)
        return if (is1_1Base10Float(s)) .float else .not_number;

    // Leading-zero octal `0[0-7_]+` (1.1 has no `0o`; `08` is therefore a string).
    if (s.len >= 2 and s[0] == '0')
        return if (digitRun(s[1..], ascii.isOctal)) .integer else .not_number;

    // Plain decimal `0 | [1-9][0-9_]*`.
    if (s.len == 1 and s[0] == '0') return .integer;
    if (s[0] >= '1' and s[0] <= '9') {
        for (s[1..]) |c| if (!(ascii.isDigit(c) or c == '_')) return .not_number;
        return .integer;
    }
    return .not_number;
}

/// 1.1 base-10 float: `([0-9][0-9_]*)?\.[0-9_]*([eE][-+][0-9]+)?` (sign already
/// stripped). The dot is mandatory; an exponent, if present, must carry a sign.
fn is1_1Base10Float(s: []const u8) bool {
    var i: usize = 0;
    // Optional integer part.
    if (i < s.len and ascii.isDigit(s[i])) {
        i += 1;
        while (i < s.len and (ascii.isDigit(s[i]) or s[i] == '_')) i += 1;
    }
    // Mandatory `.`.
    if (i >= s.len or s[i] != '.') return false;
    i += 1;
    // Fractional digits (may be empty: `5.`).
    while (i < s.len and (ascii.isDigit(s[i]) or s[i] == '_')) i += 1;
    // Optional signed exponent.
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        i += 1;
        if (i >= s.len or (s[i] != '+' and s[i] != '-')) return false;
        i += 1;
        var exp_digits: usize = 0;
        while (i < s.len and ascii.isDigit(s[i])) : (i += 1) exp_digits += 1;
        if (exp_digits == 0) return false;
    }
    return i == s.len;
}

/// Sexagesimal: `[1-9][0-9_]*(:[0-5]?[0-9])+` (int) or the same with a trailing
/// `.[0-9_]*` fractional (float). `s` is sign-stripped and known to contain `:`.
fn classify1_1Base60(s: []const u8) NumberClass {
    var body = s;
    var is_float = false;
    if (std.mem.indexOfScalar(u8, s, '.')) |dot| {
        is_float = true;
        for (s[dot + 1 ..]) |c| if (!(ascii.isDigit(c) or c == '_')) return .not_number;
        body = s[0..dot];
    }

    var groups = std.mem.splitScalar(u8, body, ':');
    var idx: usize = 0;
    var trailing: usize = 0;
    while (groups.next()) |g| : (idx += 1) {
        if (g.len == 0) return .not_number;
        if (idx == 0) {
            // First group `[1-9][0-9_]*` (int) / `[0-9][0-9_]*` (float).
            if (!ascii.isDigit(g[0])) return .not_number;
            if (!is_float and g[0] == '0') return .not_number;
            for (g[1..]) |c| if (!(ascii.isDigit(c) or c == '_')) return .not_number;
        } else {
            // Subsequent groups `[0-5]?[0-9]`.
            if (g.len < 1 or g.len > 2) return .not_number;
            for (g) |c| if (!ascii.isDigit(c)) return .not_number;
            if (g.len == 2 and g[0] > '5') return .not_number;
            trailing += 1;
        }
    }
    if (trailing == 0) return .not_number;
    return if (is_float) .float else .integer;
}

/// YAML 1.1 `!!timestamp`: a `YYYY-MM-DD` date or a full date-time with an
/// optional `Z`/`±HH:MM` zone, via the shared datetime validator. Time-only and
/// minute-precision forms are refused — a bare `:`-run is a sexagesimal number
/// in 1.1 (resolved earlier), and the canonical timestamp carries seconds.
/// Returns the matching extended kind, or null for a non-timestamp.
fn classify1_1Timestamp(source: []const u8) ?AST.Node.Kind.Extended.ExtKind {
    const kind = datetime.classify(source, .{
        .allow_time_only = false,
        .allow_minute_precision = false,
    }) catch return null;
    return switch (kind) {
        .offset_datetime => .offset_datetime,
        .local_datetime => .local_datetime,
        .local_date => .local_date,
        .local_time => .local_time,
    };
}

const eqlAny = util.eqlAny;

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
    Unicode.encodeAppend(decoded, allocator, codepoint) catch |err| switch (err) {
        error.InvalidCodepoint => return ParseError.InvalidUnicodeEscape,
        error.OutOfMemory => return error.OutOfMemory,
    };
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
            const ok = if (hex) ascii.isHex(source[i]) else ascii.isOctal(source[i]);
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
    switch (self.peek().kind) {
        // An implicit block mapping key must be a single line; a multi-line
        // scalar (e.g. a folded quoted string) cannot be a key.
        .scalar => if (std.mem.indexOfScalar(u8, self.peek().source(self.source), '\n') != null) return false,
        // An alias may be a key (`*a : b`).
        .alias => {},
        else => return false,
    }

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
    // Consume any pending node properties onto this node and keep all side-tables
    // length-synced with `nodes`.
    const tag = self.pending_tag;
    const anchor = self.pending_anchor;
    self.pending_tag = null;
    self.pending_anchor = null;
    var node_span = span;
    // Extend the node's span leftward to cover its property prefix, so the editor
    // sees `&a !tag value` as one editable unit (a replace can't orphan `&a `).
    if (tag) |t| node_span.start = @min(node_span.start, t.span.start);
    if (anchor) |a| node_span.start = @min(node_span.start, a.span.start);
    try self.node_spans.append(self.allocator, node_span);
    try self.node_tags.append(self.allocator, if (tag) |t| t.text else null);
    try self.node_tag_spans.append(self.allocator, if (tag) |t| t.span else null);
    try self.node_anchors.append(self.allocator, if (anchor) |a| a.name else null);
    try self.node_anchor_spans.append(self.allocator, if (anchor) |a| a.span else null);
    if (anchor) |a| try self.anchors.append(self.allocator, .{ .name = a.name, .node = id });
    try self.node_comments.append(self.allocator, .{});
    // Buffered leading comments bind to the first non-container node built after
    // them — a key, a scalar/flow value, or a sequence item. A container node
    // (`parking_container`) is skipped so the comment falls through to its first
    // child, which the printer actually renders.
    if (!self.parking_container) try self.claimLeading(id);
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
        switch (self.peek().kind) {
            .tag => {
                const t = self.advance();
                try self.stashTag(t.source(self.source), t.span);
            },
            .anchor => {
                const a = self.advance();
                // Strip the leading `&`; the name is the rest of the token.
                try self.stashAnchor(a.source(self.source)[1..], a.span);
            },
            else => break,
        }
    }
}

/// True when a pending anchor/tag property sits on the same source line as the
/// token starting at `at` (no newline between them).
fn pendingPropOnLineOf(self: *const Parser, at: usize) bool {
    const sameLine = struct {
        fn f(src: []const u8, from: usize, to: usize) bool {
            return from <= to and std.mem.indexOfScalar(u8, src[from..to], '\n') == null;
        }
    }.f;
    if (self.pending_anchor) |p| if (sameLine(self.source, p.span.end, at)) return true;
    if (self.pending_tag) |p| if (sameLine(self.source, p.span.end, at)) return true;
    return false;
}

/// Record an anchor as pending. A second pending anchor means the first belongs
/// to a container about to open (parked in `container_anchor`); a third is a real
/// duplicate on one node.
fn stashAnchor(self: *Parser, name: []const u8, span: Span) ParserError!void {
    if (self.pending_anchor) |prev| {
        if (self.container_anchor != null) return ParseError.DuplicateProperty;
        self.container_anchor = prev;
        self.pending_anchor = null;
    }
    self.pending_anchor = .{ .name = name, .span = span };
}

/// A tag using a *named* handle (`!handle!suffix`) is valid only if that handle
/// was declared by a `%TAG` directive in this document. The `!` (primary) and
/// `!!` (secondary) default handles, local tags (`!suffix`), and verbatim tags
/// (`!<uri>`) need no declaration. Scoping is per-document because each document
/// in a stream is parsed by a fresh Parser (see `tag_handles`).
fn validateTagHandle(self: *const Parser, text: []const u8) ParseError!void {
    if (text.len < 2) return; // `!` non-specific tag
    if (text[1] == '<' or text[1] == '!') return; // verbatim, or secondary `!!`
    // A named handle has a second `!` closing it (`!e!foo` → handle `!e!`). No
    // second `!` means a local tag (`!suffix`), which uses the primary handle.
    const close = std.mem.indexOfScalarPos(u8, text, 1, '!') orelse return;
    const handle = text[0 .. close + 1];
    for (self.tag_handles.items) |declared| {
        if (std.mem.eql(u8, declared, handle)) return;
    }
    return ParseError.UndefinedTagHandle;
}

fn stashTag(self: *Parser, text: []const u8, span: Span) ParserError!void {
    try self.validateTagHandle(text);
    if (self.pending_tag) |prev| {
        if (self.container_tag != null) return ParseError.DuplicateProperty;
        self.container_tag = prev;
        self.pending_tag = null;
    }
    self.pending_tag = .{ .text = text, .span = span };
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
    switch (token.kind) {
        // The single choke point for comment trivia: every skip site funnels
        // through here, so capture once.
        .comment => self.captureComment(token),
        // A newline closes the current value's trailing-comment window — a
        // comment on the next line leads the following node instead.
        .newline => {
            self.last_value_id = null;
            self.colon_line = false;
        },
        // A value-indicator opens the window in which a same-line comment trails
        // the entry rather than leading its (block) value's first child.
        .colon => self.colon_line = true,
        else => {},
    }
    return token;
}

// ── comments ────────────────────────────────────────────────────────────────

/// Classify the just-advanced comment token. While the previous value's window
/// is open (`last_value_id` set — no newline since it finished) the comment is on
/// the same line and trails it; otherwise it buffers as leading for the next
/// node. YAML has only line comments, so `style` is always `.line`.
fn captureComment(self: *Parser, token: Token) void {
    const c: AST.Comment = .{ .text = commentText(token.source(self.source)), .style = .line };
    if (self.last_value_id) |id| {
        self.node_comments.items[id].trailing = c;
        self.comments_seen = true;
        self.last_value_id = null; // one trailing per value
    } else if (self.colon_line and self.awaitsBlockValue()) {
        // `key: # note` with the value on following lines — the comment trails the
        // entry. Parked on the mapping entry; bound to the value in `finishValue`.
        self.currentContainer().pending_value_trailing = c;
        self.comments_seen = true;
    } else {
        // Capacity reserved in `parseOnce`, so this cannot fail.
        self.pending_leading.appendAssumeCapacity(c);
    }
}

/// True when the current container is a mapping with a recorded key but no value
/// yet — i.e. a `key:` whose (block) value is still to come.
fn awaitsBlockValue(self: *Parser) bool {
    if (self.container_stack.items.len == 0) return false;
    const c = self.currentContainer();
    return c.kind == .mapping and c.pending_key != null;
}

/// Strip the leading `#` and surrounding spaces from a comment token's bytes
/// (which borrow `source`).
fn commentText(raw: []const u8) []const u8 {
    const body = if (raw.len > 0 and raw[0] == '#') raw[1..] else raw;
    return std.mem.trim(u8, body, " \t\r");
}

/// Hand the buffered leading comments to node `id` as an owned slice, then clear
/// the buffer (retaining its reserved capacity). No-op when nothing is buffered.
fn claimLeading(self: *Parser, id: AST.Node.Id) ParserError!void {
    if (self.pending_leading.items.len == 0) return;
    const owned = try self.allocator.dupe(AST.Comment, self.pending_leading.items);
    self.pending_leading.clearRetainingCapacity();
    self.node_comments.items[id].leading = owned;
    self.comments_seen = true;
}

/// Hand buffered orphan comments (no node followed them — at end of document) to
/// container `id` as its `dangling` run. Mid-document orphans are instead claimed
/// as the next sibling's leading by indentation, so this only fires at EOF.
fn claimDangling(self: *Parser, id: AST.Node.Id) ParserError!void {
    if (self.pending_leading.items.len == 0) return;
    const owned = try self.allocator.dupe(AST.Comment, self.pending_leading.items);
    self.pending_leading.clearRetainingCapacity();
    self.node_comments.items[id].dangling = owned;
    self.comments_seen = true;
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

test "yaml directive: %YAML before document is consumed" {
    const doc = try Parser.parse(testing.allocator, "%YAML 1.2\n---\nfoo\n", .v1_2_2);
    defer doc.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "foo", doc.ast.nodes[doc.ast.root].kind.string);
}

test "yaml directive: %TAG declares a handle used by a tag" {
    const doc = try Parser.parse(testing.allocator, "%TAG !e! tag:example.com,2000:app/\n---\n!e!foo bar\n", .v1_2_2);
    defer doc.deinit(testing.allocator);
    const root = doc.ast.nodes[doc.ast.root];
    try testing.expectEqualSlices(u8, "bar", root.kind.string);
    try testing.expectEqualSlices(u8, "!e!foo", doc.ast.node_tags[root.id].?);
}

test "yaml directive: a reserved directive is ignored" {
    const doc = try Parser.parse(testing.allocator, "%FOO bar baz # ignored\n---\n\"x\"\n", .v1_2_2);
    defer doc.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "x", doc.ast.nodes[doc.ast.root].kind.string);
}

test "yaml directive: %YAML without a following marker is rejected" {
    try testParserError("%YAML 1.2\n", error.InvalidDirective);
}

test "yaml directive: a directive followed by `...` is rejected" {
    try testParserError("%YAML 1.2\n...\n", error.InvalidDirective);
}

test "yaml directive: duplicate %YAML is rejected" {
    try testParserError("%YAML 1.2\n%YAML 1.2\n---\n", error.InvalidDirective);
}

test "yaml directive: malformed %YAML version is rejected" {
    try testParserError("%YAML 1.2 foo\n---\n", error.InvalidDirective);
}

test "yaml directive: a directive after content is rejected" {
    try testParserError("---\nkey: value\n%YAML 1.2\n---\n", error.InvalidDirective);
}

test "yaml directive: an undeclared named tag handle is rejected" {
    try testParserError("--- !prefix!A\na: b\n", error.UndefinedTagHandle);
}

test "yaml directive: a multiline plain scalar may absorb a %-line (XLQ9)" {
    // `%YAML 1.2` here is a plain-scalar continuation, not a directive.
    const doc = try Parser.parse(testing.allocator, "---\nscalar\n%YAML 1.2\n", .v1_2_2);
    defer doc.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "scalar %YAML 1.2", doc.ast.nodes[doc.ast.root].kind.string);
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

test "yaml anchor/alias: anchor recorded, alias resolves to it" {
    const doc = try Parser.parse(testing.allocator, "a: &x 1\nb: *x\n", .v1_2_2);
    defer doc.deinit(testing.allocator);
    const a_val = try doc.ast.getValByPath(&.{.{ .key = "a" }});
    try testing.expectEqualSlices(u8, "x", doc.ast.node_anchors[a_val.id].?);
    const b_val = try doc.ast.getValByPath(&.{.{ .key = "b" }});
    try testing.expectEqualSlices(u8, "x", b_val.kind.alias);
    try testing.expectEqual(a_val.id, try doc.ast.resolveAlias(b_val));
}

test "yaml anchor/alias: anchor on a collection" {
    const doc = try Parser.parse(testing.allocator, "a: &x [1, 2]\nb: *x\n", .v1_2_2);
    defer doc.deinit(testing.allocator);
    const a_val = try doc.ast.getValByPath(&.{.{ .key = "a" }});
    try testing.expect(a_val.kind == .sequence);
    try testing.expectEqualSlices(u8, "x", doc.ast.node_anchors[a_val.id].?);
    const b_val = try doc.ast.getValByPath(&.{.{ .key = "b" }});
    try testing.expectEqual(a_val.id, try doc.ast.resolveAlias(b_val));
}

test "yaml anchor/alias: nearest preceding anchor wins on redefinition" {
    const doc = try Parser.parse(testing.allocator, "- &x 1\n- &x 2\n- *x\n", .v1_2_2);
    defer doc.deinit(testing.allocator);
    const item1 = try doc.ast.getValByPath(&.{.{ .index = 1 }}); // the second &x
    const alias = try doc.ast.getValByPath(&.{.{ .index = 2 }});
    try testing.expectEqual(item1.id, try doc.ast.resolveAlias(alias));
}

test "yaml anchor/alias: undefined alias is rejected" {
    try testParserError("p: *missing\n", error.UndefinedAlias);
}

test "yaml merge: << pulls keys, host overrides, sequence earlier-wins" {
    const src =
        \\base: &b
        \\  x: 1
        \\  y: 2
        \\over: &o
        \\  x: 9
        \\derived:
        \\  <<: [*o, *b]
        \\  y: 3
        \\
    ;
    const doc = try Parser.parse(testing.allocator, src, .v1_2_2);
    defer doc.deinit(testing.allocator);
    const derived = try doc.ast.getValByPath(&.{.{ .key = "derived" }});
    // y: host wins (3)
    const y = (try doc.ast.mergedChild(derived, "y")).?;
    try testing.expectEqualSlices(u8, "3", doc.ast.nodes[y].kind.number.raw);
    // x: not local → from merge; earlier source (*o) wins over *b → 9
    const x = (try doc.ast.mergedChild(derived, "x")).?;
    try testing.expectEqualSlices(u8, "9", doc.ast.nodes[x].kind.number.raw);
    // absent key → null
    try testing.expect((try doc.ast.mergedChild(derived, "nope")) == null);
}

test "yaml merge: cyclic alias does not hang" {
    // A mapping that merges itself via an anchor on itself.
    const doc = try Parser.parse(testing.allocator, "a: &m\n  <<: *m\n  k: 1\n", .v1_2_2);
    defer doc.deinit(testing.allocator);
    const a = try doc.ast.getValByPath(&.{.{ .key = "a" }});
    // Direct key resolves without touching the cycle.
    try testing.expect((try doc.ast.mergedChild(a, "k")) != null);
    // A missing key forces the merge to be followed → cycle detected, not a hang.
    try testing.expectError(error.AliasCycle, doc.ast.mergedChild(a, "absent"));
}

test "yaml: captures leading/trailing comments; block-scalar # stays content" {
    const doc = try Parser.parse(testing.allocator,
        \\# document header
        \\name: fig # the project
        \\nums:
        \\# first item
        \\- 1
        \\- 2 # second
        \\text: |
        \\  # not a comment
        \\  body
    , .v1_2_2);
    defer doc.deinit(testing.allocator);
    const ast = doc.ast;
    const root = ast.nodes[ast.root];

    const kv_name = ast.nodes[root.kind.mapping.?].kind.keyvalue;
    // The document header leads the first key (renders at column 0 above it).
    try testing.expectEqualStrings("document header", ast.comments(kv_name.key).leading[0].text);
    try testing.expectEqualStrings("the project", ast.comments(kv_name.value).trailing.?.text);

    const kv_nums = ast.nodes[ast.nodes[root.kind.mapping.?].next_sibling.?].kind.keyvalue;
    const seq = ast.nodes[kv_nums.value];
    const item1 = ast.nodes[seq.kind.sequence.?];
    const item2 = ast.nodes[item1.next_sibling.?];
    try testing.expectEqualStrings("first item", ast.comments(item1.id).leading[0].text);
    try testing.expectEqualStrings("second", ast.comments(item2.id).trailing.?.text);

    // The `#` line inside the `|` block scalar is content, not a comment: it
    // lives in the string value and produces no trailing comment.
    const kv_text = ast.nodes[ast.nodes[ast.nodes[root.kind.mapping.?].next_sibling.?].next_sibling.?].kind.keyvalue;
    const text_val = ast.nodes[kv_text.value];
    try testing.expect(text_val.kind == .string);
    try testing.expect(std.mem.indexOf(u8, text_val.kind.string, "# not a comment") != null);
    try testing.expect(ast.comments(kv_text.value).trailing == null);
}

test "yaml: comment-free document carries no comment table" {
    const doc = try Parser.parse(testing.allocator, "a: 1\nb: [2, 3]\n", .v1_2_2);
    defer doc.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), doc.ast.node_comments.len);
}

test "yaml anchor: collection and its first key both anchored" {
    // 6BFJ/7BMT shape: the container claims the earlier property, its first key
    // the later one.
    const doc = try Parser.parse(testing.allocator, "top: &node\n  &k key: one\n", .v1_2_2);
    defer doc.deinit(testing.allocator);
    const top = try doc.ast.getValByPath(&.{.{ .key = "top" }});
    try testing.expect(top.kind == .mapping);
    try testing.expectEqualSlices(u8, "node", doc.ast.node_anchors[top.id].?);
}

test "yaml anchor: next-line value must out-indent its key" {
    // SKE5 valid (anchor out-indents), G9HC invalid (anchor at the key's column).
    {
        const doc = try Parser.parse(testing.allocator, "seq:\n &a\n- x\n", .v1_2_2);
        defer doc.deinit(testing.allocator);
        const seq = try doc.ast.getValByPath(&.{.{ .key = "seq" }});
        try testing.expect(seq.kind == .sequence);
        try testing.expectEqualSlices(u8, "a", doc.ast.node_anchors[seq.id].?);
    }
    try testParserError("seq:\n&a\n- x\n", error.UnexpectedToken); // G9HC
}

test "yaml anchor: misplaced property is rejected" {
    try testParserError("&anchor - sequence entry\n", error.UnexpectedToken); // SY6V (same line)
    try testParserError("- a\n&b\n- c\n", error.UnexpectedToken); // GT5M (floating in seq)
}

test "yaml: a block collection cannot begin on the --- marker line" {
    try testParserError("--- a: b\n", error.UnexpectedToken);
    try testParserError("--- &anchor a: b\n", error.UnexpectedToken); // CXX2
    try testParserError("--- - x\n", error.UnexpectedToken);
    // ...but a mapping on the line after the marker is fine.
    const doc = try Parser.parse(testing.allocator, "---\na: b\n", .v1_2_2);
    defer doc.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "b", (try doc.ast.getValByPath(&.{.{ .key = "a" }})).kind.string);
}

test "yaml plain scalar: trailing comment on a continuation line" {
    const doc = try Parser.parse(testing.allocator, "b: plain\n value  # comment\n", .v1_2_2);
    defer doc.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "plain value", (try doc.ast.getValByPath(&.{.{ .key = "b" }})).kind.string);
}

test "yaml: a property-only line at a different column than its node" {
    // M5C3 shape: a tag on its own line (col 3) above the block header it
    // decorates (col 2). The property line is not a structural indent level.
    const doc = try Parser.parse(testing.allocator, "folded:\n   !foo\n  >1\n value\n", .v1_2_2);
    defer doc.deinit(testing.allocator);
    const v = try doc.ast.getValByPath(&.{.{ .key = "folded" }});
    try testing.expect(v.kind == .string);
    try testing.expectEqualSlices(u8, "!foo", doc.ast.node_tags[v.id].?);
}

test "yaml block scalar: next-line header with explicit indent over the owner column" {
    // `folded:\n  >1\n value`: content indents from the key column (0) + 1, not
    // the header line's indent.
    const doc = try Parser.parse(testing.allocator, "folded:\n  >1\n value\n", .v1_2_2);
    defer doc.deinit(testing.allocator);
    const v = try doc.ast.getValByPath(&.{.{ .key = "folded" }});
    try testing.expect(v.kind == .string);
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

/// Test helper: render a parse's structure-only shape (`[`/`]` sequence,
/// `{`/`}` mapping, `S` scalar/alias leaf), the same normalization
/// tools/check_yaml_trees.zig diffs against the yaml-test-suite event tree. Used
/// to lock the *shape* of constructs the pass/fail scoreboard can't see.
fn shape(alloc: std.mem.Allocator, src: []const u8) ![]u8 {
    var doc = try Parser.parse(alloc, src, .v1_2_2);
    defer doc.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try shapeNode(alloc, &doc.ast, doc.ast.nodes[doc.ast.root], &out);
    return out.toOwnedSlice(alloc);
}

fn shapeNode(alloc: std.mem.Allocator, ast: *const AST, node: AST.Node, out: *std.ArrayList(u8)) !void {
    switch (node.kind) {
        .null_, .boolean, .string, .number, .extended, .alias => try shapePush(alloc, out, "S"),
        .sequence => |first| {
            try shapePush(alloc, out, "[");
            var child = first;
            while (child) |cid| : (child = ast.nodes[cid].next_sibling) try shapeNode(alloc, ast, ast.nodes[cid], out);
            try shapePush(alloc, out, "]");
        },
        .mapping => |first| {
            try shapePush(alloc, out, "{");
            var child = first;
            while (child) |cid| : (child = ast.nodes[cid].next_sibling) {
                const kv = ast.nodes[cid].kind.keyvalue;
                try shapeNode(alloc, ast, ast.nodes[kv.key], out);
                try shapeNode(alloc, ast, ast.nodes[kv.value], out);
            }
            try shapePush(alloc, out, "}");
        },
        .keyvalue => unreachable,
    }
}

fn shapePush(alloc: std.mem.Allocator, out: *std.ArrayList(u8), tok: []const u8) !void {
    if (out.items.len > 0) try out.append(alloc, ' ');
    try out.appendSlice(alloc, tok);
}

fn expectShape(src: []const u8, want: []const u8) !void {
    const got = try shape(testing.allocator, src);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, want, got);
}

test "yaml compact nested sequences keep their nesting" {
    // `- - x` nests rather than flattening to [x]; a following entry at the outer
    // column is a sibling, and three dashes nest three deep.
    try expectShape("- - s1\n  - s2\n- s3\n", "[ [ S S ] S ]");
    try expectShape("- - - x\n- - - y\n", "[ [ [ S ] ] [ [ S ] ] ]");
}

test "yaml key after a nested block sequence is a sibling, not absorbed" {
    // A block sequence of mappings (`- k: v`) stacks two containers (the
    // sequence and each item mapping) but occupies a single tokenizer indent
    // level, so the dedent out of it must close both. Otherwise a following key
    // at the parent's column lands one level too deep — which a struct
    // deserializer reads as the top-level field being silently dropped.
    // Indentless sequence value:
    try expectShape("a:\n  items:\n  - k: 1\n  - k: 2\nb: 2\n", "{ S { S [ { S S } { S S } ] } S S }");
    // Indented sequence value (the dash level is its own tokenizer indent):
    try expectShape("a:\n  items:\n    - k: 1\n    - k: 2\nb: 2\n", "{ S { S [ { S S } { S S } ] } S S }");
    // Two levels deep: the key closes back across both, and a top-level key too.
    try expectShape("root:\n  a:\n    items:\n    - k: 1\n  b: 2\ntop: 9\n", "{ S { S { S [ { S S } ] } S S } S S }");
    // Sequence-of-scalars (single container level) still works as before.
    try expectShape("a:\n  items:\n  - 1\n  - 2\nb: 2\n", "{ S { S [ S S ] } S S }");
    // Top-level indentless sequence of mappings, then a sibling key.
    try expectShape("aud:\n- name: x\n  pub: true\nm: true\n", "{ S [ { S S S S } ] S S }");
}

test "yaml block value on a compact sequence-item key nests under that key" {
    // `- key:\n    nested: v` — the item mapping opens compactly on the dash line
    // (sharing the dash's tokenizer indent), so the deeper indent that follows is
    // the KEY's block value, not a sibling key. It must open a fresh container
    // nested under the key rather than flatten into the item (`{key: null, nested}`).
    try expectShape("- outer:\n    inner: 1\n", "[ { S { S S } } ]");
    // A nested block sequence value behaves the same way.
    try expectShape("- k:\n    - x\n    - y\n", "[ { S [ S S ] } ]");
    // A following dash at the outer column is a sibling item, and the deep value
    // closes correctly first.
    try expectShape("- outer:\n    inner: 1\n- second: 2\n", "[ { S { S S } } { S S } ]");
    // A sibling key at the item's own column is still absorbed (not nested), and
    // a later key may still deepen into its own block value.
    try expectShape("- a: 1\n  b: 2\n", "[ { S S S S } ]");
    try expectShape("- a: 1\n  b:\n    c: 2\n", "[ { S S S { S S } } ]");
}

test "yaml sibling key after a first key's block value returns to the item column" {
    // The first key's block value out-indents the item, and a following key at
    // the item's own column is its sibling — not a child of the value, and not a
    // new sequence entry. The `-` established that column without pushing it, so
    // the tokenizer admits the return via a sequence-entry content level.
    try expectShape("- outer:\n    inner: 1\n  sib: 2\n", "[ { S { S S } S S } ]");
    // The item then closes for a following sequence entry.
    try expectShape("- outer:\n    inner: 1\n  sib: 2\n- second: 3\n", "[ { S { S S } S S } { S S } ]");
    // The returned-to sibling may itself take a block value, then another sibling.
    try expectShape("- outer:\n    inner: 1\n  sib:\n    deep: 2\n  third: 3\n", "[ { S { S S } S { S S } S S } ]");
    // A return to a column that is NOT the item's (mis-indented) is still rejected.
    try testParserError("- outer:\n    inner: 1\n   sib: 2\n", error.InvalidIndent);
}

test "yaml complex explicit keys take collections as the key" {
    // Explicit key that is a block sequence, with a null value (closes on the
    // dedent to a sibling) and with a `:` value at the `?` column.
    try expectShape("c1:\n  ? - a\nc2:\n  ? - a\n  : b\n", "{ S { [ S ] S } S { [ S ] S } }");
    // `?` alone on its line: an indentless sequence is the key, another the value.
    try expectShape("?\n- a\n- b\n:\n- c\n- d\n", "{ [ S S ] [ S S ] }");
    // An inline empty-key mapping, and a flow-keyed mapping, serve as the key.
    try expectShape("- ? : x\n", "[ { { S S } S } ]");
    try expectShape("? []: x\n", "{ { [ ] S } S }");
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

test "yaml 1.1 resolves booleans, radix ints, sexagesimal, and timestamps" {
    const src =
        \\flag: yes
        \\off_flag: Off
        \\octal: 0777
        \\binary: 0b1010
        \\hex: 0x_0A
        \\under: 1_000
        \\base60: 190:20:30
        \\fixed: 685_230.15
        \\when: 2001-12-15T02:59:43.1Z
        \\day: 2002-12-14
        \\
    ;
    var doc = try Parser.parse(testing.allocator, src, .v1_1);
    defer doc.deinit(testing.allocator);
    const ast = &doc.ast;
    try testing.expect((try ast.getValByPath(&.{.{ .key = "flag" }})).kind.boolean == true);
    try testing.expect((try ast.getValByPath(&.{.{ .key = "off_flag" }})).kind.boolean == false);
    try testing.expect((try ast.getValByPath(&.{.{ .key = "octal" }})).kind.number.kind == .integer);
    try testing.expect((try ast.getValByPath(&.{.{ .key = "binary" }})).kind.number.kind == .integer);
    try testing.expect((try ast.getValByPath(&.{.{ .key = "hex" }})).kind.number.kind == .integer);
    try testing.expect((try ast.getValByPath(&.{.{ .key = "under" }})).kind.number.kind == .integer);
    try testing.expect((try ast.getValByPath(&.{.{ .key = "base60" }})).kind.number.kind == .integer);
    try testing.expect((try ast.getValByPath(&.{.{ .key = "fixed" }})).kind.number.kind == .float);
    try testing.expect((try ast.getValByPath(&.{.{ .key = "when" }})).kind.extended.kind == .offset_datetime);
    try testing.expect((try ast.getValByPath(&.{.{ .key = "day" }})).kind.extended.kind == .local_date);
}

test "yaml 1.1 vs 1.2 scalar divergence" {
    // Tokens typed in 1.2 but kept as strings in 1.1 (and vice versa). The same
    // source resolves differently per version.
    const src =
        \\exp: 1e3
        \\prefixed_octal: 0o17
        \\bare_hex: 0x
        \\invalid_octal: 08
        \\
    ;
    var v11 = try Parser.parse(testing.allocator, src, .v1_1);
    defer v11.deinit(testing.allocator);
    // 1.1: all four are plain strings (no `.`+signed-exp float, no `0o`, etc.).
    inline for (.{ "exp", "prefixed_octal", "bare_hex", "invalid_octal" }) |key| {
        try testing.expect(std.meta.activeTag((try v11.ast.getValByPath(&.{.{ .key = key }})).kind) == .string);
    }

    var v12 = try Parser.parse(testing.allocator, src, .v1_2_2);
    defer v12.deinit(testing.allocator);
    // 1.2 core schema: `1e3` is a float and `0o17` an octal int.
    try testing.expect((try v12.ast.getValByPath(&.{.{ .key = "exp" }})).kind.number.kind == .float);
    try testing.expect((try v12.ast.getValByPath(&.{.{ .key = "prefixed_octal" }})).kind.number.kind == .integer);
}
