//! fig authoring dialect — block-layer + flow-mode parser. See DESIGN.md for
//! the full grammar; this file implements the "Implied implementation shape":
//! a line splitter (markers/key/value dispatch, inline here rather than a
//! separate pass, since committed values can span many lines), a stack-based
//! block builder (depth counts + header baselines), a recursive-descent flow
//! sub-parser, and the literal-else-string value resolver (`tokenizer.zig`).
//!
//! Construction goes through an intermediate, mutable tree (`PendingContainer`
//! et al.) allocated in a per-parse arena, then converted bottom-up into the
//! immutable `AST` via `AST.Builder` at the end. This makes "navigate to an
//! arbitrary existing path and add a child" (dotted keys, index addressing,
//! header re-entry) tractable without fighting the frozen `Node` array other
//! parsers build directly into.
//!
//! Scope cuts (documented, not silent):
//!   * Authoring-time WARN diagnostics (indent/marker-count disagreement,
//!     coercion warnings) are not implemented — only DESIGN.md's hard errors.
//!   * Comment attachment honors a comment line's own marker depth when
//!     containers close: a comment at (or below) a closing container's child
//!     depth becomes its dangling run; a shallower one stays pending and binds
//!     to the next sibling line as its leading run.
//!   * Only LF line endings are recognized as line breaks (a lone `\r` is
//!     treated as ordinary trivia and trimmed where comments are captured).
//!   * The in-place editor (`edit`/`set`/`insert`/`delete`) is not wired for
//!     `.fig` — this module is the reader half of "reader + `fig fmt`".

pub const Parser = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const AST = @import("../ast/ast.zig");
const Document = @import("../document.zig");
const Span = @import("../util/span.zig");
const datetime = @import("../util/datetime.zig");
const tok = @import("tokenizer.zig");
const Type = @import("fig.zig").Type;

pub const Error = error{
    /// A container ended up with children of both shapes (`key = v` AND `*`).
    FigMixedContainerChildren,
    /// A sequence mixed `[]`/`[i]` addressing with `*` elements.
    FigMixedSequenceAddressing,
    /// A dotted/index path stepped into an existing scalar key.
    FigKeyNotContainer,
    /// An assignment or header re-defined an existing leaf key.
    FigDuplicateKey,
    /// `xs[i]` skipped ahead of the sequence's current length.
    FigIndexSkipped,
    /// A non-final (or assignment) `[]` referenced an empty sequence.
    FigEmptyAppendTarget,
    /// An assignment addressed an index that was already set.
    FigIndexAlreadySet,
    /// A header/element-opener container closed with zero children.
    FigEmptyContainer,
    /// A `>` marker with no open header above it.
    FigRootMarker,
    /// A marker run jumped more than one level deeper than the last.
    FigSkippedLevel,
    /// A marker run with no whitespace before the key that follows it.
    FigBadMarkerSeparator,
    /// A key was empty, or a bare key began with a structural character.
    FigBadKey,
    /// `key: value` (YAML/JSON habit) — `:` introduces a type, not a value.
    FigForeignSyntaxColon,
    /// `[section]`/`[[x]]` (TOML habit) at line start.
    FigForeignSyntaxBracket,
    /// A `-` element line (`- v`, `>-`, `> -`) — YAML habit; fig elements are `*`.
    FigForeignSyntaxDash,
    /// `* key = value` — an element's RHS looked like an inline field.
    FigElementInlineField,
    /// An assignment/element had no value at all.
    FigInvalidValue,
    /// A typed value (`: int`, `: bool`, ...) didn't match its annotation.
    FigTypeMismatch,
    /// An unrecognized `: type` name.
    FigUnknownType,
    /// Non-comment content survived after a value/header on its line.
    FigTrailingContent,
    /// A `+` continuation line with no `[]` append header (or `+`) as the most
    /// recent zero-marker structural line — nothing to re-run.
    FigDanglingContinuation,
    /// A dotted path / header stepped into a container written as a flow value.
    /// Flow values are closed (TOML inline-table rule): extending `k = {…}`
    /// with a later `k.x = …` reads as mutation of a value that presented
    /// itself as complete.
    FigClosedFlowValue,
    /// A `[`/`{` flow region never found its matching close.
    FigUnclosedFlow,
    /// One flow object mixed `=` (fig) and `:` (JSON) pair separators.
    FigMixedFlowSeparators,
} || tok.ScanError;

/// Arena for the whole intermediate tree — freed in one shot after the final
/// AST is built, so nothing here needs manual `deinit`.
allocator: Allocator,
source: []const u8 = "",
pos: usize = 0,
root: PendingContainer = .{},
root_dangling: std.ArrayList(AST.Comment) = .empty,
pending_leading: std.ArrayList(PendingComment) = .empty,
stack: std.ArrayList(Frame) = .empty,
/// The path of the most recent zero-marker `[]` append header, kept while only
/// deeper lines / comments / blanks / `+` lines follow — the target a `+`
/// continuation line re-runs. Any other zero-marker structural line clears it.
last_append_steps: ?[]const Step = null,

// ── Intermediate tree types ─────────────────────────────────────────────────

/// A container whose shape (map vs. sequence) is frozen the moment its first
/// child is added — root and every header/element-opener target start here.
const PendingContainer = struct {
    kind: enum { undecided, mapping, sequence } = .undecided,
    /// Created by a flow value (`[…]`/`{…}`) — closed to later extension via
    /// dotted paths, headers, or indexing (the TOML inline-table rule).
    closed: bool = false,
    mapping: Mapping = .{},
    sequence: Sequence = .{},

    fn open(self: *PendingContainer) Error!*PendingContainer {
        return if (self.closed) error.FigClosedFlowValue else self;
    }

    fn asMapping(self: *PendingContainer) Error!*Mapping {
        switch (self.kind) {
            .undecided => {
                self.kind = .mapping;
                return &self.mapping;
            },
            .mapping => return &self.mapping,
            .sequence => return error.FigMixedContainerChildren,
        }
    }

    fn asSequence(self: *PendingContainer) Error!*Sequence {
        switch (self.kind) {
            .undecided => {
                self.kind = .sequence;
                return &self.sequence;
            },
            .sequence => return &self.sequence,
            .mapping => return error.FigMixedContainerChildren,
        }
    }
};

const Mapping = struct {
    entries: std.ArrayList(*MEntry) = .empty,
};

const MEntry = struct {
    key: []const u8,
    /// Leading comments bind to the KEY (matches `AST.leadingCommentAnchor` for
    /// a `keyvalue`).
    key_leading: std.ArrayList(AST.Comment) = .empty,
    value: TNode,
};

const Sequence = struct {
    elements: std.ArrayList(*TNode) = .empty,
    style: enum { undecided, element, addressed } = .undecided,

    fn markElement(self: *Sequence) Error!void {
        switch (self.style) {
            .undecided => self.style = .element,
            .element => {},
            .addressed => return error.FigMixedSequenceAddressing,
        }
    }

    fn markAddressed(self: *Sequence) Error!void {
        switch (self.style) {
            .undecided => self.style = .addressed,
            .addressed => {},
            .element => return error.FigMixedSequenceAddressing,
        }
    }
};

const TValue = union(enum) {
    null_,
    boolean: bool,
    string: []const u8,
    number: tok.NumberResult,
    extended: struct { kind: tok.ExtKind, text: []const u8 },
    container: *PendingContainer,
};

const TNode = struct {
    value: TValue,
    /// `AST.trailingCommentAnchor`-equivalent: the value itself for a
    /// scalar/container, always applied directly to this node's built id.
    trailing: ?AST.Comment = null,
    /// Own leading comments — meaningful only when this TNode is NOT a map
    /// entry's value (sequence elements and root have no wrapping key to bind
    /// to instead).
    leading: std.ArrayList(AST.Comment) = .empty,
    /// Orphan comments at the end of this node's body (container-only).
    dangling: std.ArrayList(AST.Comment) = .empty,
};

/// A buffered comment line plus its own marker depth. The depth decides where
/// the comment lands when containers close: a comment at (or below) a closing
/// frame's child depth was written inside that container (its dangling run); a
/// shallower one belongs to whatever sibling line comes next (its leading
/// run). This is DESIGN.md's "a depth-prefixed comment attaches at that depth
/// to the next sibling".
const PendingComment = struct { comment: AST.Comment, depth: u32 };

const Frame = struct {
    container: *PendingContainer,
    /// The depth (relative to the active baseline) that this frame's children
    /// must be written at.
    child_depth: u32,
    /// The TNode wrapping `container` — where trailing/dangling comments land.
    owner: *TNode,
};

const IndexKind = union(enum) { literal: usize, append_or_last };
const Step = union(enum) { key: []const u8, index: IndexKind };

/// The outcome of resolving a HEADER line's final path segment: the container
/// to push as the next frame, its owner TNode (trailing/dangling target), and
/// — when reached via a map key — the entry (leading-comment target; a
/// sequence-index resolution has no entry, so leading binds to `owner` itself).
const Resolved = struct { container: *PendingContainer, owner: *TNode, entry: ?*MEntry };

// ── Entry points ─────────────────────────────────────────────────────────────

pub fn parseAbstract(allocator: Allocator, input: []const u8, format: Type) !AST {
    const parsed = try parse(allocator, input, format);
    allocator.free(parsed.node_spans);
    return parsed.ast;
}

pub fn parse(allocator: Allocator, input: []const u8, format: Type) Error!Document {
    _ = format;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    var self: Parser = .{ .allocator = arena_state.allocator(), .source = input };
    try self.run();

    var b = AST.Builder.init(allocator);
    // `finish` only moves `nodes`/`owned_strings` out; the comment side-table's
    // outer spines (`comments`/`view_comments`) are never consumed by it, so
    // `deinit` is still required on the success path too (mirrors every
    // `Builder` call site, including its own tests).
    defer b.deinit();
    const root_id = try self.buildRoot(&b);
    var ast = try b.finish(root_id);
    errdefer ast.deinit();

    const node_spans = try allocator.alloc(Span, ast.nodes.len);
    @memset(node_spans, Span.init(0, 0));

    return .{ .source = input, .ast = ast, .node_spans = node_spans };
}

// ── Main line loop ──────────────────────────────────────────────────────────

fn run(self: *Parser) Error!void {
    while (self.pos < self.source.len) {
        self.skipSpacesTabs(); // cosmetic indent — never load-bearing
        const m = try self.scanMarkers();
        // A `*` element marker already committed this to an element line (even
        // a bare `*` opener with no value, or one carrying only a trailing
        // comment), so skip the blank/comment-only shortcuts below.
        if (!m.star) {
            // A TRULY blank line (nothing at all, not even a comment) is skipped
            // outright. This must NOT reuse `atEndOfContent` (which also treats a
            // leading `#` as "content is over") — a comment-only line has to fall
            // through to the `#` handling below, or it would never be consumed
            // and the main loop would spin forever at the same position.
            if (self.atTrueLineEnd()) {
                self.skipToNextLine();
                continue;
            }
            if (self.peek() == '#') {
                self.advance();
                var j = self.pos;
                while (j < self.source.len and self.source[j] != '\n') j += 1;
                const text = std.mem.trim(u8, self.source[self.pos..j], " \t\r");
                try self.pending_leading.append(self.allocator, .{ .comment = .{ .text = text, .style = .line }, .depth = m.depth });
                self.pos = j;
                self.skipToNextLine();
                continue;
            }
        }
        try self.processContentLine(m.depth, m.star);
    }
    try self.closeFramesAbove(0);
    for (self.pending_leading.items) |pc| {
        try self.root_dangling.append(self.allocator, pc.comment);
    }
    self.pending_leading.clearRetainingCapacity();
}

fn processContentLine(self: *Parser, depth: u32, star: bool) Error!void {
    try self.closeFramesAbove(depth);
    const required: u32 = if (self.stack.items.len == 0) 0 else self.stack.items[self.stack.items.len - 1].child_depth;
    if (depth != required) return if (required == 0) error.FigRootMarker else error.FigSkippedLevel;
    const target: *PendingContainer = if (self.stack.items.len == 0) &self.root else self.stack.items[self.stack.items.len - 1].container;

    // A lone `+` (optionally with a trailing comment) is a continuation line:
    // it re-runs the most recent zero-marker `[]` append header. Any other
    // zero-marker structural line breaks the chain (comments, blanks, and
    // deeper body lines do not — they never reach this point at depth 0).
    const is_plus = !star and self.peek() == '+' and self.isPlusLine();
    if (depth == 0 and !is_plus) self.last_append_steps = null;
    if (is_plus) return self.parseContinuationLine(depth);

    // `star` = the prefix carried a `*` element marker (scanMarkers consumed
    // it, along with the separator).
    if (star) return self.parseElementLine(target, depth);
    switch (self.peek().?) {
        // A `-` element line is the YAML habit (and fig's own pre-`*`
        // spelling) — hard error naming the `*` form.
        '-' => return error.FigForeignSyntaxDash,
        '[' => return error.FigForeignSyntaxBracket,
        else => try self.parseKeyLine(target, depth),
    }
}

/// `pos` sits on a `+`: is this a continuation line (`+` alone, or followed by
/// whitespace / a comment / end-of-line)? Anything glued to the `+` falls
/// through to the key path (where `+` is not a bare-key char → `FigBadKey`).
fn isPlusLine(self: *Parser) bool {
    const j = self.pos + 1;
    if (j >= self.source.len) return true;
    return switch (self.source[j]) {
        ' ', '\t', '\r', '\n', '#' => true,
        else => false,
    };
}

/// A `+` continuation: append another element to the sequence of the most
/// recent `[]` append header and re-anchor the baseline to it, exactly as if
/// the header line had been written again.
fn parseContinuationLine(self: *Parser, depth: u32) Error!void {
    self.advance(); // '+'
    if (depth != 0) return error.FigDanglingContinuation;
    const steps = self.last_append_steps orelse return error.FigDanglingContinuation;
    self.skipSpacesTabs();
    if (!self.atEndOfContent()) return error.FigTrailingContent;
    const leading = try self.drainPendingLeading();
    const parent = try self.navigateIntermediate(&self.root, steps);
    const resolved = try self.resolveHeaderFinal(parent, steps[steps.len - 1]);
    try self.appendComments(&resolved.owner.leading, leading);
    if (try self.scanTrailingCommentOnly()) |cm| resolved.owner.trailing = .{ .text = cm };
    self.consumeLineEnd();
    try self.stack.append(self.allocator, .{ .container = resolved.container, .child_depth = 1, .owner = resolved.owner });
}

/// Pop frames deeper than `depth`, validating each closes non-empty. Buffered
/// comments written at (or below) a closing frame's child depth were inside
/// that container — they become its dangling run; shallower ones stay pending
/// for the next sibling line (its leading run).
fn closeFramesAbove(self: *Parser, depth: u32) Error!void {
    while (self.stack.items.len > 0 and self.stack.items[self.stack.items.len - 1].child_depth > depth) {
        const frame = self.stack.pop().?;
        if (frame.container.kind == .undecided) return error.FigEmptyContainer;
        if (self.pending_leading.items.len > 0) {
            var kept: std.ArrayList(PendingComment) = .empty;
            for (self.pending_leading.items) |pc| {
                if (pc.depth >= frame.child_depth) {
                    try frame.owner.dangling.append(self.allocator, pc.comment);
                } else {
                    try kept.append(self.allocator, pc);
                }
            }
            self.pending_leading = kept; // arena-allocated; the old spine needs no free
        }
    }
}

fn drainPendingLeading(self: *Parser) Error!std.ArrayList(AST.Comment) {
    var result: std.ArrayList(AST.Comment) = .empty;
    for (self.pending_leading.items) |pc| try result.append(self.allocator, pc.comment);
    self.pending_leading.clearRetainingCapacity();
    return result;
}

fn appendComments(self: *Parser, dst: *std.ArrayList(AST.Comment), src: std.ArrayList(AST.Comment)) Error!void {
    if (src.items.len == 0) return;
    try dst.appendSlice(self.allocator, src.items);
}

// ── Markers ──────────────────────────────────────────────────────────────────

const Markers = struct {
    depth: u32,
    /// A `*` element marker ended the prefix — spaced (`> *`, the normalized
    /// form), glued (`>*`), or, at root, a bare leading `*` (a zero-marker
    /// sequence element). scanMarkers consumed it and its separator.
    star: bool,
};

/// Count a run of `>` markers (spaced runs like `> > >` count the same as
/// `>>>`), consume an optional `*` element marker ending the run (`> *`, `>*`,
/// or a bare `*` at root), then require exactly one whitespace separator
/// before the body — unless the rest of the line is empty/a comment (a
/// marker-only line: `>>` is blank, `*` is a map-element opener). The `*` is a
/// role suffix, not a counted mark: depth is the `>` count alone. A `-` where
/// the element marker would sit is the YAML habit — a hard error naming `*`.
fn scanMarkers(self: *Parser) Error!Markers {
    var count: u32 = 0;
    scan: while (self.peek() == '>') {
        count += 1;
        self.advance();
        while (self.peek() == ' ' or self.peek() == '\t') {
            const save = self.pos;
            self.skipSpacesTabs();
            if (self.peek() == '*') break :scan; // spaced `> *` ends the run
            if (self.peek() != '>') {
                self.pos = save;
                break;
            }
        }
    }
    // `>-` glued to the run — the old dash element spelling.
    if (count > 0 and self.peek() == '-') return error.FigForeignSyntaxDash;
    if (self.peek() == '*') {
        self.advance();
        if (self.peek() == ' ' or self.peek() == '\t') {
            self.skipSpacesTabs();
        } else if (self.peek() == ':') {
            // Typed element `*: type = v`: the `:` binds to the positional-key
            // `*` (mirrors `key: type`), so no separator space is required —
            // leave `pos` on the `:` for `parseElementLine`.
        } else if (!self.atEndOfContent()) {
            return error.FigBadMarkerSeparator;
        }
        return .{ .depth = count, .star = true };
    }
    if (count > 0) {
        if (self.peek() == ' ' or self.peek() == '\t') {
            self.skipSpacesTabs();
        } else if (!self.atEndOfContent()) {
            return error.FigBadMarkerSeparator;
        }
    }
    return .{ .depth = count, .star = false };
}

// ── Header / assignment lines ────────────────────────────────────────────────

fn parseKeyLine(self: *Parser, target: *PendingContainer, depth: u32) Error!void {
    const steps = try self.scanKeyPath();
    self.skipSpacesTabs();
    if (self.peek() == ':') {
        self.advance();
        self.skipSpacesTabs();
        const type_start = self.pos;
        while (self.pos < self.source.len and tok.isBareKeyChar(self.source[self.pos])) self.pos += 1;
        const type_name = self.source[type_start..self.pos];
        if (type_name.len == 0) return error.FigBadKey;
        self.skipSpacesTabs();
        if (self.peek() != '=') return error.FigForeignSyntaxColon;
        self.advance();
        try self.finishAssignment(target, steps, type_name);
    } else if (self.peek() == '=') {
        self.advance();
        try self.finishAssignment(target, steps, null);
    } else {
        try self.finishHeader(target, steps, depth);
    }
}

fn finishHeader(self: *Parser, target: *PendingContainer, steps: []const Step, depth: u32) Error!void {
    if (!self.atEndOfContent()) return error.FigTrailingContent;
    const leading = try self.drainPendingLeading();
    const parent = try self.navigateIntermediate(target, steps);
    const last = steps[steps.len - 1];
    const resolved = try self.resolveHeaderFinal(parent, last);
    if (resolved.entry) |e| {
        try self.appendComments(&e.key_leading, leading);
    } else {
        try self.appendComments(&resolved.owner.leading, leading);
    }
    if (try self.scanTrailingCommentOnly()) |cm| resolved.owner.trailing = .{ .text = cm };
    self.consumeLineEnd();
    try self.stack.append(self.allocator, .{ .container = resolved.container, .child_depth = depth + 1, .owner = resolved.owner });
    // A zero-marker header whose FINAL step is `[]` arms the `+` continuation
    // (processContentLine already cleared any previous chain for this line).
    if (depth == 0) switch (last) {
        .index => |idx| {
            if (idx == .append_or_last) self.last_append_steps = steps;
        },
        .key => {},
    };
}

fn finishAssignment(self: *Parser, target: *PendingContainer, steps: []const Step, type_name: ?[]const u8) Error!void {
    self.skipSpacesTabs();
    const leading = try self.drainPendingLeading();
    const parent = try self.navigateIntermediate(target, steps);
    const last = steps[steps.len - 1];
    var value_node = try self.parseAssignedValue(type_name);
    self.consumeLineEnd();
    switch (last) {
        .key => |k| {
            const m = try parent.asMapping();
            if (self.findEntry(m, k) != null) return error.FigDuplicateKey;
            const entry = try self.allocator.create(MEntry);
            entry.* = .{ .key = k, .value = value_node };
            try self.appendComments(&entry.key_leading, leading);
            try m.entries.append(self.allocator, entry);
        },
        .index => |idx| {
            const s = try parent.asSequence();
            try s.markAddressed();
            try self.appendComments(&value_node.leading, leading);
            switch (idx) {
                .literal => |n| {
                    if (n < s.elements.items.len) return error.FigIndexAlreadySet;
                    if (n > s.elements.items.len) return error.FigIndexSkipped;
                    try s.elements.append(self.allocator, try self.boxNode(value_node));
                },
                .append_or_last => {
                    if (s.elements.items.len == 0) return error.FigEmptyAppendTarget;
                    s.elements.items[s.elements.items.len - 1] = try self.boxNode(value_node);
                },
            }
        },
    }
}

// ── Element (`-`) lines ──────────────────────────────────────────────────────

/// The element `*` marker (and its separator) has already been consumed by
/// `scanMarkers`; `pos` sits on the element body (or a typing `:`).
fn parseElementLine(self: *Parser, target: *PendingContainer, depth: u32) Error!void {
    self.skipSpacesTabs();
    const leading = try self.drainPendingLeading();
    const seq = try target.asSequence();
    try seq.markElement();

    if (self.atEndOfContent()) {
        const child = try self.allocator.create(PendingContainer);
        child.* = .{};
        const el = try self.allocator.create(TNode);
        el.* = .{ .value = .{ .container = child } };
        try self.appendComments(&el.leading, leading);
        try seq.elements.append(self.allocator, el);
        if (try self.scanTrailingCommentOnly()) |cm| el.trailing = .{ .text = cm };
        self.consumeLineEnd();
        try self.stack.append(self.allocator, .{ .container = child, .child_depth = depth + 1, .owner = el });
        return;
    }

    if (self.peek() == ':') {
        self.advance();
        self.skipSpacesTabs();
        const type_start = self.pos;
        while (self.pos < self.source.len and tok.isBareKeyChar(self.source[self.pos])) self.pos += 1;
        const type_name = self.source[type_start..self.pos];
        if (type_name.len == 0) return error.FigBadKey;
        self.skipSpacesTabs();
        if (self.peek() != '=') return error.FigForeignSyntaxColon;
        self.advance();
        var node = try self.parseAssignedValue(type_name);
        self.consumeLineEnd();
        try self.appendComments(&node.leading, leading);
        try seq.elements.append(self.allocator, try self.boxNode(node));
        return;
    }

    const c = self.peek().?;
    if (c == '\'' or c == '"' or c == '[' or c == '{') {
        var node = try self.parseUntypedValue(false);
        self.consumeLineEnd();
        try self.appendComments(&node.leading, leading);
        try seq.elements.append(self.allocator, try self.boxNode(node));
        return;
    }

    // Bare value: the "no inline field on an element" guardrail runs BEFORE
    // sniffing, on the raw (untrimmed) rest of the line.
    const start = self.pos;
    var k = start;
    while (k < self.source.len and self.source[k] != '\n') k += 1;
    if (std.mem.indexOf(u8, self.source[start..k], " = ") != null) return error.FigElementInlineField;

    var node = try self.parseUntypedValue(false);
    self.consumeLineEnd();
    try self.appendComments(&node.leading, leading);
    try seq.elements.append(self.allocator, try self.boxNode(node));
}

// ── Key-path scanning (shared by headers and assignments) ───────────────────

fn scanKeyPath(self: *Parser) Error![]Step {
    var steps: std.ArrayList(Step) = .empty;
    while (true) {
        const key = try self.scanKeySeg();
        try steps.append(self.allocator, .{ .key = key });
        while (self.peek() == '[') {
            try steps.append(self.allocator, .{ .index = try self.scanIndexSeg() });
        }
        if (self.peek() == '.') {
            self.advance();
            continue;
        }
        break;
    }
    return steps.toOwnedSlice(self.allocator);
}

fn scanKeySeg(self: *Parser) Error![]const u8 {
    const c = self.peek() orelse return error.FigBadKey;
    if (c == '"') {
        const r = try tok.scanDoubleQuoted(self.allocator, self.source, self.pos);
        self.pos = r.end;
        return r.text;
    }
    if (c == '\'') {
        const r = try tok.scanSingleQuoted(self.allocator, self.source, self.pos);
        self.pos = r.end;
        return r.text;
    }
    const start = self.pos;
    while (self.pos < self.source.len and tok.isBareKeyChar(self.source[self.pos])) self.pos += 1;
    if (self.pos == start) return error.FigBadKey;
    const text = self.source[start..self.pos];
    if (text[0] == '-' or text[0] == '>') return error.FigBadKey;
    return text;
}

fn scanIndexSeg(self: *Parser) Error!IndexKind {
    std.debug.assert(self.peek() == '[');
    self.advance();
    if (self.peek() == ']') {
        self.advance();
        return .append_or_last;
    }
    const start = self.pos;
    while (self.pos < self.source.len and std.ascii.isDigit(self.source[self.pos])) self.pos += 1;
    if (self.pos == start or self.peek() != ']') return error.FigBadKey;
    const n = std.fmt.parseInt(usize, self.source[start..self.pos], 10) catch return error.FigBadKey;
    self.advance(); // ']'
    return .{ .literal = n };
}

// ── Path navigation ──────────────────────────────────────────────────────────

fn findEntry(self: *Parser, m: *Mapping, key: []const u8) ?*MEntry {
    _ = self;
    for (m.entries.items) |e| if (std.mem.eql(u8, e.key, key)) return e;
    return null;
}

/// Resolve every step except the last, creating/reusing intermediate
/// containers. `[]`/`[i]` here always mean "the last existing element" (never
/// creates) — only a HEADER line's OVERALL final `[]` appends.
fn navigateIntermediate(self: *Parser, start: *PendingContainer, steps: []const Step) Error!*PendingContainer {
    var cur = start;
    for (steps[0 .. steps.len - 1]) |step| {
        switch (step) {
            .key => |k| {
                const m = try cur.asMapping();
                cur = try self.getOrCreateMapContainer(m, k);
            },
            .index => |idx| {
                const s = try cur.asSequence();
                try s.markAddressed();
                cur = try self.getOrCreateSeqContainer(s, idx);
            },
        }
    }
    return cur;
}

fn getOrCreateMapContainer(self: *Parser, m: *Mapping, key: []const u8) Error!*PendingContainer {
    if (self.findEntry(m, key)) |e| {
        return switch (e.value.value) {
            .container => |c| c.open(),
            else => error.FigKeyNotContainer,
        };
    }
    const child = try self.allocator.create(PendingContainer);
    child.* = .{};
    const entry = try self.allocator.create(MEntry);
    entry.* = .{ .key = key, .value = .{ .value = .{ .container = child } } };
    try m.entries.append(self.allocator, entry);
    return child;
}

fn getOrCreateSeqContainer(self: *Parser, s: *Sequence, idx: IndexKind) Error!*PendingContainer {
    switch (idx) {
        .literal => |n| {
            if (n < s.elements.items.len) {
                return switch (s.elements.items[n].value) {
                    .container => |c| c.open(),
                    else => error.FigKeyNotContainer,
                };
            } else if (n == s.elements.items.len) {
                const child = try self.allocator.create(PendingContainer);
                child.* = .{};
                const el = try self.allocator.create(TNode);
                el.* = .{ .value = .{ .container = child } };
                try s.elements.append(self.allocator, el);
                return child;
            } else return error.FigIndexSkipped;
        },
        .append_or_last => {
            if (s.elements.items.len == 0) return error.FigEmptyAppendTarget;
            const last = s.elements.items[s.elements.items.len - 1];
            return switch (last.value) {
                .container => |c| c.open(),
                else => error.FigKeyNotContainer,
            };
        },
    }
}

/// Resolve a HEADER line's final path segment: get-or-create the container to
/// push as the next frame. A plain key may be re-entered (fine, per
/// DESIGN.md); a header-final `[]` always appends a fresh, forced-mapping
/// element.
fn resolveHeaderFinal(self: *Parser, parent: *PendingContainer, last: Step) Error!Resolved {
    switch (last) {
        .key => |k| {
            const m = try parent.asMapping();
            if (self.findEntry(m, k)) |e| {
                const c = switch (e.value.value) {
                    .container => |cc| try cc.open(),
                    else => return error.FigDuplicateKey,
                };
                return .{ .container = c, .owner = &e.value, .entry = e };
            }
            const child = try self.allocator.create(PendingContainer);
            child.* = .{};
            const entry = try self.allocator.create(MEntry);
            entry.* = .{ .key = k, .value = .{ .value = .{ .container = child } } };
            try m.entries.append(self.allocator, entry);
            return .{ .container = child, .owner = &entry.value, .entry = entry };
        },
        .index => |idx| {
            const s = try parent.asSequence();
            try s.markAddressed();
            switch (idx) {
                .literal => |n| {
                    if (n < s.elements.items.len) {
                        const el = s.elements.items[n];
                        const c = switch (el.value) {
                            .container => |cc| try cc.open(),
                            else => return error.FigKeyNotContainer,
                        };
                        return .{ .container = c, .owner = el, .entry = null };
                    } else if (n == s.elements.items.len) {
                        const child = try self.allocator.create(PendingContainer);
                        child.* = .{};
                        const el = try self.allocator.create(TNode);
                        el.* = .{ .value = .{ .container = child } };
                        try s.elements.append(self.allocator, el);
                        return .{ .container = child, .owner = el, .entry = null };
                    } else return error.FigIndexSkipped;
                },
                .append_or_last => {
                    const child = try self.allocator.create(PendingContainer);
                    child.* = .{};
                    _ = try child.asMapping(); // append-created elements are always map-shaped
                    const el = try self.allocator.create(TNode);
                    el.* = .{ .value = .{ .container = child } };
                    try s.elements.append(self.allocator, el);
                    return .{ .container = child, .owner = el, .entry = null };
                },
            }
        },
    }
}

fn boxNode(self: *Parser, node: TNode) Error!*TNode {
    const p = try self.allocator.create(TNode);
    p.* = node;
    return p;
}

// ── Values ───────────────────────────────────────────────────────────────────

fn parseAssignedValue(self: *Parser, type_name: ?[]const u8) Error!TNode {
    self.skipSpacesTabs();
    if (type_name) |t| {
        if (std.mem.eql(u8, t, "string")) return self.parseUntypedValue(true);
        const res = self.scanBareRestOfLine();
        if (res.text.len == 0) return error.FigInvalidValue;
        var node = try self.applyKnownType(t, res.text);
        if (res.comment) |cm| node.trailing = .{ .text = cm };
        return node;
    }
    return self.parseUntypedValue(false);
}

/// `force_string_bare`: set only for `: string =`, where a bare RHS is taken
/// verbatim (sniffing off) and a committed (quote/flow) RHS is an error — a
/// string annotation doesn't accept a collection.
fn parseUntypedValue(self: *Parser, force_string_bare: bool) Error!TNode {
    const c = self.peek() orelse return error.FigInvalidValue;
    switch (c) {
        '\'' => return self.parseQuotedOrTriple('\'', force_string_bare),
        '"' => return self.parseQuotedOrTriple('"', force_string_bare),
        '[', '{' => {
            if (force_string_bare) return error.FigTypeMismatch;
            // Commitment is decided by the shape of the WHOLE RHS, not just the
            // first char (DESIGN.md "Committed values"): a balanced `[…]`/`{…}`
            // with trailing content — a markdown link, glob, regex — was never
            // flow, so it is a bare string, left unquoted.
            if (tok.classifyBracketCommit(self.source, self.pos) == .bare_trailing) {
                const res = self.scanBareRestOfLine();
                if (res.text.len == 0) return error.FigInvalidValue;
                // Opened with a delimiter → sniffing is off; it is a string.
                var node: TNode = .{ .value = .{ .string = res.text } };
                if (res.comment) |cm| node.trailing = .{ .text = cm };
                return node;
            }
            // `.flow` (terminal close) and `.unclosed` (multi-line / truncation)
            // both commit: the flow parser succeeds or raises a hard error.
            //
            // A `# …` after the opening `[`/`{`, with nothing else on the line,
            // is a block-layer trailing comment on the flow value — the
            // multiline-string opener rule's flow twin (DESIGN.md "Multiline
            // strings"): the opener line is still block-layer; flow content
            // begins at the next newline. Captured here, then skipped by the
            // flow parser's `skipFlowWs` as interior trivia. An opener comment
            // wins over a close-line one, mirroring the `'''` rule.
            const opener_comment = self.scanFlowOpenerComment();
            var node = try self.parseFlowValue();
            const trailing = try self.scanTrailingCommentOnly();
            node.trailing = if (opener_comment) |oc|
                .{ .text = oc }
            else if (trailing) |t|
                .{ .text = t }
            else
                null;
            return node;
        },
        else => {
            const res = self.scanBareRestOfLine();
            if (res.text.len == 0) return error.FigInvalidValue;
            var node: TNode = if (force_string_bare)
                .{ .value = .{ .string = res.text } }
            else
                self.sniffToNode(res.text);
            if (res.comment) |cm| node.trailing = .{ .text = cm };
            return node;
        },
    }
}

fn parseQuotedOrTriple(self: *Parser, q: u8, force_string_bare: bool) Error!TNode {
    _ = force_string_bare; // a quoted/multiline RHS is always a valid string
    if (self.isTripleAt(self.pos, q)) {
        const r = if (q == '\'')
            try tok.scanTripleSingle(self.allocator, self.source, self.pos)
        else
            try tok.scanTripleDouble(self.allocator, self.source, self.pos);
        self.pos = r.end;
        var node: TNode = .{ .value = .{ .string = r.text } };
        const trailing = try self.scanTrailingCommentOnly();
        node.trailing = if (r.opener_comment) |oc| .{ .text = oc } else if (trailing) |t| .{ .text = t } else null;
        return node;
    }
    const r = if (q == '\'')
        try tok.scanSingleQuoted(self.allocator, self.source, self.pos)
    else
        try tok.scanDoubleQuoted(self.allocator, self.source, self.pos);
    self.pos = r.end;
    var node: TNode = .{ .value = .{ .string = r.text } };
    if (try self.scanTrailingCommentOnly()) |t| node.trailing = .{ .text = t };
    return node;
}

fn sniffToNode(self: *Parser, text: []const u8) TNode {
    _ = self;
    return switch (tok.sniffBare(text)) {
        .null_ => .{ .value = .null_ },
        .boolean => |b| .{ .value = .{ .boolean = b } },
        .number => |n| .{ .value = .{ .number = n } },
        .datetime => |d| .{ .value = .{ .extended = .{ .kind = d.kind, .text = d.raw } } },
        .string => .{ .value = .{ .string = text } },
    };
}

/// Explicit typing (`key: type = value`): the annotation is checked and
/// coercing, never stored (DESIGN.md "Explicit typing").
fn applyKnownType(self: *Parser, type_name: []const u8, text: []const u8) Error!TNode {
    _ = self;
    if (std.mem.eql(u8, type_name, "int")) {
        const n = tok.sniffNumber(text) orelse return error.FigTypeMismatch;
        if (n.kind != .integer) return error.FigTypeMismatch;
        return .{ .value = .{ .number = n } };
    }
    if (std.mem.eql(u8, type_name, "float")) {
        if (std.mem.eql(u8, text, "inf") or std.mem.eql(u8, text, "-inf") or std.mem.eql(u8, text, "nan")) {
            return .{ .value = .{ .extended = .{ .kind = .number_special, .text = text } } };
        }
        const n = tok.sniffNumber(text) orelse return error.FigTypeMismatch;
        return .{ .value = .{ .number = .{ .raw = n.raw, .kind = .float } } };
    }
    if (std.mem.eql(u8, type_name, "bool")) {
        if (std.mem.eql(u8, text, "true")) return .{ .value = .{ .boolean = true } };
        if (std.mem.eql(u8, text, "false")) return .{ .value = .{ .boolean = false } };
        return error.FigTypeMismatch;
    }
    if (std.mem.eql(u8, type_name, "enum")) {
        if (text.len == 0) return error.FigTypeMismatch;
        return .{ .value = .{ .extended = .{ .kind = .enum_literal, .text = text } } };
    }
    if (std.mem.eql(u8, type_name, "datetime") or std.mem.eql(u8, type_name, "date") or std.mem.eql(u8, type_name, "time")) {
        const k = datetime.classify(text, .{}) catch return error.FigTypeMismatch;
        const ext: tok.ExtKind = switch (k) {
            .offset_datetime => .offset_datetime,
            .local_datetime => .local_datetime,
            .local_date => .local_date,
            .local_time => .local_time,
        };
        const ok = if (std.mem.eql(u8, type_name, "date"))
            ext == .local_date
        else if (std.mem.eql(u8, type_name, "time"))
            ext == .local_time
        else
            true; // "datetime" accepts any of the four shapes
        if (!ok) return error.FigTypeMismatch;
        return .{ .value = .{ .extended = .{ .kind = ext, .text = text } } };
    }
    return error.FigUnknownType;
}

const BareScan = struct { text: []const u8, comment: ?[]const u8 };

/// Capture a bare RHS to end of line, honoring the `#`-after-whitespace rule
/// (a `#` glued to non-whitespace, e.g. a URL fragment, stays literal).
/// Leaves `self.pos` at the newline/EOF (never past it).
fn scanBareRestOfLine(self: *Parser) BareScan {
    const start = self.pos;
    var i = start;
    var prev_space = true; // the separator space before the value was already skipped
    var comment_start: ?usize = null;
    while (i < self.source.len and self.source[i] != '\n') : (i += 1) {
        const ch = self.source[i];
        if (ch == '#' and prev_space) {
            comment_start = i;
            break;
        }
        prev_space = (ch == ' ' or ch == '\t');
    }
    const value_end = comment_start orelse i;
    const text = std.mem.trim(u8, self.source[start..value_end], " \t\r");
    var comment: ?[]const u8 = null;
    var line_end = value_end;
    if (comment_start) |cs| {
        var j = cs + 1;
        while (j < self.source.len and self.source[j] != '\n') j += 1;
        comment = std.mem.trim(u8, self.source[cs + 1 .. j], " \t\r");
        line_end = j;
    }
    self.pos = line_end;
    return .{ .text = text, .comment = comment };
}

/// After a committed value (quote/flow/multiline) ends, the rest of the line
/// may only be whitespace and an optional `# comment` — anything else is
/// `FigTrailingContent`. Leaves `self.pos` at the newline/EOF.
fn scanTrailingCommentOnly(self: *Parser) Error!?[]const u8 {
    self.skipSpacesTabs();
    if (self.pos >= self.source.len or self.source[self.pos] == '\n') return null;
    if (self.source[self.pos] == '#') {
        const cs = self.pos + 1;
        var j = cs;
        while (j < self.source.len and self.source[j] != '\n') j += 1;
        const c = std.mem.trim(u8, self.source[cs..j], " \t\r");
        self.pos = j;
        return c;
    }
    return error.FigTrailingContent;
}

// ── Flow mode (recursive descent; fig-inline ∪ JSON5) ────────────────────────

/// Peek (without consuming) a `# …` comment that is the only thing after the
/// opening `[`/`{` on its line. Called with `self.pos` on the opening bracket.
/// Returns the trimmed comment text, or null when the line carries flow
/// content instead. Not consumed on purpose: `skipFlowWs` discards the same
/// span during the flow parse, so capture and parse stay independent.
fn scanFlowOpenerComment(self: *const Parser) ?[]const u8 {
    var i = self.pos + 1; // past the opening bracket
    while (i < self.source.len and (self.source[i] == ' ' or self.source[i] == '\t')) i += 1;
    if (i >= self.source.len or self.source[i] != '#') return null;
    var j = i + 1;
    while (j < self.source.len and self.source[j] != '\n') j += 1;
    return std.mem.trim(u8, self.source[i + 1 .. j], " \t\r");
}

fn parseFlowValue(self: *Parser) Error!TNode {
    return switch (self.peek().?) {
        '[' => self.parseFlowArray(),
        '{' => self.parseFlowObject(),
        else => unreachable,
    };
}

/// Skip whitespace, newlines, and `#` comments between flow tokens. Comments are
/// discarded (a documented scope cut: flow-interior comments are not attached to
/// the AST). Every call site is a structural boundary — after `[`/`{`/`,`/`:`/`=`
/// or a completed value — so a `#` here is unambiguously a comment, not the
/// fragment of a bare value (which `scanFlowBareValue` handles via the
/// `#`-after-whitespace rule).
fn skipFlowWs(self: *Parser) void {
    while (self.pos < self.source.len) {
        switch (self.source[self.pos]) {
            ' ', '\t', '\r', '\n' => self.pos += 1,
            '#' => while (self.pos < self.source.len and self.source[self.pos] != '\n') : (self.pos += 1) {},
            else => return,
        }
    }
}

fn parseFlowArray(self: *Parser) Error!TNode {
    self.advance(); // '['
    const seq = try self.allocator.create(PendingContainer);
    seq.* = .{ .closed = true };
    const s = try seq.asSequence();
    self.skipFlowWs();
    if (self.peek() == ']') {
        self.advance();
        return .{ .value = .{ .container = seq } };
    }
    while (true) {
        const v = try self.parseFlowScalarOrNested();
        try s.elements.append(self.allocator, try self.boxNode(v));
        self.skipFlowWs();
        const p = self.peek() orelse return error.FigUnclosedFlow;
        if (p == ',') {
            self.advance();
            self.skipFlowWs();
            if (self.peek() == ']') {
                self.advance();
                break;
            }
            continue;
        }
        if (p == ']') {
            self.advance();
            break;
        }
        return error.FigUnclosedFlow;
    }
    return .{ .value = .{ .container = seq } };
}

fn parseFlowObject(self: *Parser) Error!TNode {
    self.advance(); // '{'
    const map = try self.allocator.create(PendingContainer);
    map.* = .{ .closed = true };
    const m = try map.asMapping();
    self.skipFlowWs();
    if (self.peek() == '}') {
        self.advance();
        return .{ .value = .{ .container = map } };
    }
    // A flow object is EITHER fig-inline (`=` pairs, keys bare or quoted) OR
    // JSON (`:` pairs, keys quoted) — the pair separator selects the spelling,
    // and it may not change within one object. `:` with a bare key is the
    // YAML/JSON5 habit and errors with the same fix as the block layer.
    var mode: ?enum { fig, json } = null;
    while (true) {
        const key = try self.parseFlowKey();
        self.skipFlowWs();
        const sep = self.peek() orelse return error.FigUnclosedFlow;
        const this_mode: @TypeOf(mode) = switch (sep) {
            '=' => .fig,
            ':' => if (key.quoted) .json else return error.FigForeignSyntaxColon,
            else => return error.FigUnclosedFlow,
        };
        if (mode) |mm| {
            if (mm != this_mode) return error.FigMixedFlowSeparators;
        } else mode = this_mode;
        self.advance();
        self.skipFlowWs();
        const v = try self.parseFlowScalarOrNested();
        if (self.findEntry(m, key.text) != null) return error.FigDuplicateKey;
        const entry = try self.allocator.create(MEntry);
        entry.* = .{ .key = key.text, .value = v };
        try m.entries.append(self.allocator, entry);
        self.skipFlowWs();
        const p = self.peek() orelse return error.FigUnclosedFlow;
        if (p == ',') {
            self.advance();
            self.skipFlowWs();
            if (self.peek() == '}') {
                self.advance();
                break;
            }
            continue;
        }
        if (p == '}') {
            self.advance();
            break;
        }
        return error.FigUnclosedFlow;
    }
    return .{ .value = .{ .container = map } };
}

const FlowKey = struct { text: []const u8, quoted: bool };

fn parseFlowKey(self: *Parser) Error!FlowKey {
    const c = self.peek() orelse return error.FigBadKey;
    if (c == '"') {
        const r = try tok.scanDoubleQuoted(self.allocator, self.source, self.pos);
        self.pos = r.end;
        return .{ .text = r.text, .quoted = true };
    }
    if (c == '\'') {
        const r = try tok.scanSingleQuoted(self.allocator, self.source, self.pos);
        self.pos = r.end;
        return .{ .text = r.text, .quoted = true };
    }
    const start = self.pos;
    while (self.pos < self.source.len and !isFlowKeyStop(self.source[self.pos])) self.pos += 1;
    if (self.pos == start) return error.FigBadKey;
    return .{ .text = self.source[start..self.pos], .quoted = false };
}

/// A bare flow KEY ends at the separator/space/close set (keys never contain
/// whitespace). A bare flow VALUE is different — see `scanFlowBareValue`.
fn isFlowKeyStop(c: u8) bool {
    return switch (c) {
        ',', ']', '}', ':', '=', ' ', '\t', '\n', '\r' => true,
        else => false,
    };
}

fn parseFlowScalarOrNested(self: *Parser) Error!TNode {
    self.skipFlowWs();
    const c = self.peek() orelse return error.FigUnclosedFlow;
    if (c == '[' or c == '{') {
        // A balanced bracket group with trailing content — a markdown link, a
        // glob, a regex — is a bare-string element, not a nested collection:
        // the flow twin of the block layer's balanced-then-trailing rule. This
        // is what lets `[Blog](/Blog.md)` sit unquoted in a flow list.
        if (tok.classifyFlowBracket(self.source, self.pos) == .bare_trailing) {
            const text = self.scanFlowBareBracket();
            if (text.len == 0) return error.FigInvalidValue;
            // Opened with a delimiter → sniffing is off; it is a string.
            return .{ .value = .{ .string = text } };
        }
        return self.parseFlowValue();
    }
    if (c == '"') {
        const r = try tok.scanDoubleQuoted(self.allocator, self.source, self.pos);
        self.pos = r.end;
        return .{ .value = .{ .string = r.text } };
    }
    if (c == '\'') {
        const r = try tok.scanSingleQuoted(self.allocator, self.source, self.pos);
        self.pos = r.end;
        return .{ .value = .{ .string = r.text } };
    }
    const text = self.scanFlowBareValue();
    if (text.len == 0) return error.FigInvalidValue;
    // `Infinity`/`NaN` are NOT recognized here (JSON5 is dropped): they sniff to
    // plain strings, exactly as bare `inf`/`nan` do in the block layer.
    return self.sniffToNode(text);
}

/// A bare flow value runs to the next `,`/`]`/`}`/newline — spaces included, so
/// `[Adam Harris, Makena Harris]` yields two-word strings (DESIGN.md
/// `BAREVAL ::= flow bare token up to , ] }`). A `#` after whitespace ends the
/// value and opens a comment (skipped by the following `skipFlowWs`); a `#`
/// glued to non-whitespace stays literal. Trailing whitespace is trimmed.
fn scanFlowBareValue(self: *Parser) []const u8 {
    const start = self.pos;
    var prev_space = false;
    while (self.pos < self.source.len) : (self.pos += 1) {
        const ch = self.source[self.pos];
        switch (ch) {
            ',', ']', '}', '\n' => break,
            '#' => if (prev_space) break,
            else => {},
        }
        prev_space = (ch == ' ' or ch == '\t');
    }
    return std.mem.trim(u8, self.source[start..self.pos], " \t\r");
}

/// Bracket-aware bare flow value for a balanced-then-trailing element (one whose
/// first char is `[`/`{`, e.g. a markdown link). `[`/`{` raise a nesting depth
/// and `]`/`}` lower it, so an interior `]` (the `]` of `[text]`) does NOT
/// terminate the value — only a `,`/`]`/`}` at depth 0, a newline, or a `#`
/// after whitespace does. Trailing whitespace is trimmed.
fn scanFlowBareBracket(self: *Parser) []const u8 {
    const start = self.pos;
    var depth: usize = 0;
    var prev_space = false;
    while (self.pos < self.source.len) : (self.pos += 1) {
        const ch = self.source[self.pos];
        switch (ch) {
            '[', '{' => depth += 1,
            ']', '}' => {
                if (depth == 0) break;
                depth -= 1;
            },
            ',', '\n' => if (depth == 0) break,
            '#' => if (prev_space and depth == 0) break,
            else => {},
        }
        prev_space = (ch == ' ' or ch == '\t');
    }
    return std.mem.trim(u8, self.source[start..self.pos], " \t\r");
}

// ── AST assembly (bottom-up, via AST.Builder) ────────────────────────────────

fn buildRoot(self: *Parser, b: *AST.Builder) Error!AST.Node.Id {
    var root_wrap: TNode = .{ .value = .{ .container = &self.root } };
    root_wrap.dangling = self.root_dangling;
    return self.buildNode(b, &root_wrap);
}

fn buildNode(self: *Parser, b: *AST.Builder, node: *TNode) Error!AST.Node.Id {
    const id: AST.Node.Id = switch (node.value) {
        .null_ => try b.addNull(),
        .boolean => |v| try b.addBool(v),
        .string => |s| try b.addString(s),
        .number => |n| try b.addNumberRaw(n.raw, n.kind == .float),
        .extended => |e| try b.addExtended(e.kind, e.text),
        .container => |c| try self.buildContainer(b, c),
    };
    if (node.trailing) |t| try b.setTrailingComment(id, t);
    for (node.dangling.items) |c| try b.addDanglingComment(id, c);
    return id;
}

fn buildContainer(self: *Parser, b: *AST.Builder, c: *PendingContainer) Error!AST.Node.Id {
    switch (c.kind) {
        .undecided => return error.FigEmptyContainer,
        .mapping => {
            var entries: std.ArrayList(AST.Builder.Entry) = .empty;
            for (c.mapping.entries.items) |e| {
                const key_id = try b.addString(e.key);
                if (e.key_leading.items.len > 0) try b.setComments(key_id, .{ .leading = e.key_leading.items });
                const value_id = try self.buildNode(b, &e.value);
                try entries.append(self.allocator, .{ .key = key_id, .value = value_id });
            }
            return b.addMapping(entries.items);
        },
        .sequence => {
            var ids: std.ArrayList(AST.Node.Id) = .empty;
            for (c.sequence.elements.items) |el| {
                const el_id = try self.buildNode(b, el);
                for (el.leading.items) |lc| try b.addLeadingComment(el_id, lc);
                try ids.append(self.allocator, el_id);
            }
            return b.addSequence(ids.items);
        },
    }
}

// ── Char-level helpers ───────────────────────────────────────────────────────

fn peek(self: *Parser) ?u8 {
    return if (self.pos < self.source.len) self.source[self.pos] else null;
}

fn advance(self: *Parser) void {
    if (self.pos < self.source.len) self.pos += 1;
}

fn skipSpacesTabs(self: *Parser) void {
    while (self.pos < self.source.len and (self.source[self.pos] == ' ' or self.source[self.pos] == '\t')) self.pos += 1;
}

fn atEndOfContent(self: *Parser) bool {
    const p = self.peek();
    return p == null or p.? == '\n' or p.? == '#';
}

/// Stricter than `atEndOfContent`: true only for real end-of-line/EOF, never
/// for a `#` — used where a comment must NOT be swallowed as "blank".
fn atTrueLineEnd(self: *Parser) bool {
    const p = self.peek();
    return p == null or p.? == '\n';
}

fn skipToNextLine(self: *Parser) void {
    if (self.pos < self.source.len and self.source[self.pos] == '\n') self.pos += 1;
}

fn consumeLineEnd(self: *Parser) void {
    while (self.pos < self.source.len and self.source[self.pos] != '\n') self.pos += 1;
    self.skipToNextLine();
}

fn isTripleAt(self: *Parser, pos: usize, q: u8) bool {
    return pos + 3 <= self.source.len and self.source[pos] == q and self.source[pos + 1] == q and self.source[pos + 2] == q;
}

// =========
// TESTS
// =========

const testing = std.testing;

fn expectParse(input: []const u8, expected: AST) !void {
    var ast = try parseAbstract(testing.allocator, input, .Fig);
    defer ast.deinit();
    try testing.expect(expected.eql(ast));
}

test "root map with a scalar assignment" {
    try expectParse("x = 1\n", .{ .allocator = testing.allocator, .root = 3, .nodes = &.{
        .{ .id = 0, .kind = .{ .string = "x" } },
        .{ .id = 1, .kind = .{ .number = .{ .raw = "1", .kind = .integer } } },
        .{ .id = 2, .kind = .{ .keyvalue = .{ .key = 0, .value = 1 } } },
        .{ .id = 3, .kind = .{ .mapping = 2 } },
    } });
}

test "literal-else-string sniffing" {
    var ast = try parseAbstract(testing.allocator,
        \\a = true
        \\b = Yes
        \\c = 007
        \\d = 12 monkeys
        \\e = null
    , .Fig);
    defer ast.deinit();
    try testing.expect((try ast.getValByPath(&.{.{ .key = "a" }})).kind.boolean == true);
    try testing.expectEqualStrings("Yes", (try ast.getValByPath(&.{.{ .key = "b" }})).kind.string);
    try testing.expectEqualStrings("007", (try ast.getValByPath(&.{.{ .key = "c" }})).kind.string);
    try testing.expectEqualStrings("12 monkeys", (try ast.getValByPath(&.{.{ .key = "d" }})).kind.string);
    try testing.expect((try ast.getValByPath(&.{.{ .key = "e" }})).kind == .null_);
}

test "nested containers via markers" {
    var ast = try parseAbstract(testing.allocator,
        \\database
        \\> host = localhost
        \\> pool
        \\>> size = 10
    , .Fig);
    defer ast.deinit();
    try testing.expectEqualStrings("localhost", (try ast.getValByPath(&.{ .{ .key = "database" }, .{ .key = "host" } })).kind.string);
    try testing.expectEqualStrings("10", (try ast.getValByPath(&.{ .{ .key = "database" }, .{ .key = "pool" }, .{ .key = "size" } })).kind.number.raw);
}

test "dotted key flattener" {
    var ast = try parseAbstract(testing.allocator,
        \\cache
        \\> redis.host = 127.0.0.1
    , .Fig);
    defer ast.deinit();
    try testing.expectEqualStrings("127.0.0.1", (try ast.getValByPath(&.{ .{ .key = "cache" }, .{ .key = "redis" }, .{ .key = "host" } })).kind.string);
}

test "sequence via star elements" {
    var ast = try parseAbstract(testing.allocator,
        \\servers
        \\> *
        \\>> host = a.com
        \\> *
        \\>> host = b.com
    , .Fig);
    defer ast.deinit();
    try testing.expectEqualStrings("a.com", (try ast.getValByPath(&.{ .{ .key = "servers" }, .{ .index = 0 }, .{ .key = "host" } })).kind.string);
    try testing.expectEqualStrings("b.com", (try ast.getValByPath(&.{ .{ .key = "servers" }, .{ .index = 1 }, .{ .key = "host" } })).kind.string);
}

test "scalar sequence" {
    var ast = try parseAbstract(testing.allocator,
        \\ports
        \\> * 1
        \\> * 2
    , .Fig);
    defer ast.deinit();
    try testing.expectEqualStrings("2", (try ast.getValByPath(&.{ .{ .key = "ports" }, .{ .index = 1 } })).kind.number.raw);
}

test "dotted section header re-anchors baseline" {
    var ast = try parseAbstract(testing.allocator,
        \\services.web.frontend
        \\> replicas = 3
    , .Fig);
    defer ast.deinit();
    try testing.expectEqualStrings("3", (try ast.getValByPath(&.{ .{ .key = "services" }, .{ .key = "web" }, .{ .key = "frontend" }, .{ .key = "replicas" } })).kind.number.raw);
}

test "append header appends and re-anchors" {
    var ast = try parseAbstract(testing.allocator,
        \\jobs.test.steps[]
        \\> uses = a
        \\jobs.test.steps[]
        \\> run = b
    , .Fig);
    defer ast.deinit();
    try testing.expectEqualStrings("a", (try ast.getValByPath(&.{ .{ .key = "jobs" }, .{ .key = "test" }, .{ .key = "steps" }, .{ .index = 0 }, .{ .key = "uses" } })).kind.string);
    try testing.expectEqualStrings("b", (try ast.getValByPath(&.{ .{ .key = "jobs" }, .{ .key = "test" }, .{ .key = "steps" }, .{ .index = 1 }, .{ .key = "run" } })).kind.string);
}

test "index addressing edits existing elements" {
    var ast = try parseAbstract(testing.allocator,
        \\clusters[0].name = alpha
        \\clusters[0].size = 3
        \\clusters[1].name = beta
    , .Fig);
    defer ast.deinit();
    try testing.expectEqualStrings("alpha", (try ast.getValByPath(&.{ .{ .key = "clusters" }, .{ .index = 0 }, .{ .key = "name" } })).kind.string);
    try testing.expectEqualStrings("3", (try ast.getValByPath(&.{ .{ .key = "clusters" }, .{ .index = 0 }, .{ .key = "size" } })).kind.number.raw);
    try testing.expectEqualStrings("beta", (try ast.getValByPath(&.{ .{ .key = "clusters" }, .{ .index = 1 }, .{ .key = "name" } })).kind.string);
}

test "skipping a sequence index errors" {
    try testing.expectError(error.FigIndexSkipped, parseAbstract(testing.allocator, "xs[1].a = 1\n", .Fig));
}

test "explicit typing" {
    var ast = try parseAbstract(testing.allocator,
        \\port: int = 8080
        \\mode: enum = creative
        \\huge: float = inf
    , .Fig);
    defer ast.deinit();
    try testing.expectEqualStrings("8080", (try ast.getValByPath(&.{.{ .key = "port" }})).kind.number.raw);
    const mode = try ast.getValByPath(&.{.{ .key = "mode" }});
    try testing.expect(mode.kind.extended.kind == .enum_literal);
    try testing.expectEqualStrings("creative", mode.kind.extended.text);
    const huge = try ast.getValByPath(&.{.{ .key = "huge" }});
    try testing.expect(huge.kind.extended.kind == .number_special);
}

test "explicit typing rejects a mismatch" {
    try testing.expectError(error.FigTypeMismatch, parseAbstract(testing.allocator, "port: int = hello\n", .Fig));
}

test "committed values error rather than falling back to string" {
    try testing.expectError(error.FigUnclosedFlow, parseAbstract(testing.allocator, "ports = [80, 443\n", .Fig));
}

test "balanced-then-trailing bracket RHS is a bare string, not committed flow" {
    var ast = try parseAbstract(testing.allocator,
        \\link = [Blog](/Blog/Blog.md)
        \\angle = [Archived Documents](</Archive/Archived documents.md>)
        \\glob = [a-z]*.md
        \\regex = [0-9]+ years
        \\bbcode = [b]bold[/b]
        \\frag = [x]#anchor
    , .Fig);
    defer ast.deinit();
    try testing.expectEqualStrings("[Blog](/Blog/Blog.md)", (try ast.getValByPath(&.{.{ .key = "link" }})).kind.string);
    try testing.expectEqualStrings("[Archived Documents](</Archive/Archived documents.md>)", (try ast.getValByPath(&.{.{ .key = "angle" }})).kind.string);
    try testing.expectEqualStrings("[a-z]*.md", (try ast.getValByPath(&.{.{ .key = "glob" }})).kind.string);
    try testing.expectEqualStrings("[0-9]+ years", (try ast.getValByPath(&.{.{ .key = "regex" }})).kind.string);
    try testing.expectEqualStrings("[b]bold[/b]", (try ast.getValByPath(&.{.{ .key = "bbcode" }})).kind.string);
    // `#` glued to the close is literal (not a comment) → part of the string.
    try testing.expectEqualStrings("[x]#anchor", (try ast.getValByPath(&.{.{ .key = "frag" }})).kind.string);
}

test "terminal bracket still commits to flow (with a trailing comment)" {
    var ast = try parseAbstract(testing.allocator,
        \\ports = [80, 443]  # real comment
        \\nested = [[a], [b]]
    , .Fig);
    defer ast.deinit();
    try testing.expectEqualStrings("443", (try ast.getValByPath(&.{ .{ .key = "ports" }, .{ .index = 1 } })).kind.number.raw);
    try testing.expectEqualStrings("b", (try ast.getValByPath(&.{ .{ .key = "nested" }, .{ .index = 1 }, .{ .index = 0 } })).kind.string);
}

test "markdown links are bare strings as sequence elements too" {
    var ast = try parseAbstract(testing.allocator,
        \\links
        \\> * [Blog](/Blog/Blog.md)
        \\> * [Resume](/Resume.md)
    , .Fig);
    defer ast.deinit();
    try testing.expectEqualStrings("[Blog](/Blog/Blog.md)", (try ast.getValByPath(&.{ .{ .key = "links" }, .{ .index = 0 } })).kind.string);
    try testing.expectEqualStrings("[Resume](/Resume.md)", (try ast.getValByPath(&.{ .{ .key = "links" }, .{ .index = 1 } })).kind.string);
}

test "a bracket that never closes on its line still errors (truncation)" {
    try testing.expectError(error.FigUnclosedFlow, parseAbstract(testing.allocator, "x = [oops\n", .Fig));
}

test "quotes: raw vs escaped" {
    var ast = try parseAbstract(testing.allocator,
        \\raw = 'C:\Users\me'
        \\esc = "line1\nline2"
    , .Fig);
    defer ast.deinit();
    try testing.expectEqualStrings("C:\\Users\\me", (try ast.getValByPath(&.{.{ .key = "raw" }})).kind.string);
    try testing.expectEqualStrings("line1\nline2", (try ast.getValByPath(&.{.{ .key = "esc" }})).kind.string);
}

test "comment marker only after whitespace" {
    var ast = try parseAbstract(testing.allocator,
        \\home = https://example.com
        \\api = https://example.com/v1#stable
    , .Fig);
    defer ast.deinit();
    try testing.expectEqualStrings("https://example.com", (try ast.getValByPath(&.{.{ .key = "home" }})).kind.string);
    try testing.expectEqualStrings("https://example.com/v1#stable", (try ast.getValByPath(&.{.{ .key = "api" }})).kind.string);
}

test "flow mode: fig-inline and pasted JSON" {
    var ast = try parseAbstract(testing.allocator,
        \\tags = [a, b, c]
        \\point = { x = 1, y = 2 }
        \\pasted = { "x": 1, "y": [2, 3] }
        \\empty_list = []
        \\empty_map = {}
    , .Fig);
    defer ast.deinit();
    try testing.expectEqualStrings("b", (try ast.getValByPath(&.{ .{ .key = "tags" }, .{ .index = 1 } })).kind.string);
    try testing.expectEqualStrings("1", (try ast.getValByPath(&.{ .{ .key = "point" }, .{ .key = "x" } })).kind.number.raw);
    try testing.expectEqualStrings("3", (try ast.getValByPath(&.{ .{ .key = "pasted" }, .{ .key = "y" }, .{ .index = 1 } })).kind.number.raw);
}

test "flow: bare values may contain spaces (up to the comma)" {
    var ast = try parseAbstract(testing.allocator,
        \\audience = [friends, Adam Harris, Makena Harris, public]
        \\who = { name = Adam Harris }
    , .Fig);
    defer ast.deinit();
    try testing.expectEqualStrings("Adam Harris", (try ast.getValByPath(&.{ .{ .key = "audience" }, .{ .index = 1 } })).kind.string);
    try testing.expectEqualStrings("Makena Harris", (try ast.getValByPath(&.{ .{ .key = "audience" }, .{ .index = 2 } })).kind.string);
    try testing.expectEqualStrings("Adam Harris", (try ast.getValByPath(&.{ .{ .key = "who" }, .{ .key = "name" } })).kind.string);
}

test "flow: JSON vs fig split — bare key + colon is the foreign-syntax error" {
    try testing.expectError(error.FigForeignSyntaxColon, parseAbstract(testing.allocator, "p = {x: 1}\n", .Fig));
}

test "flow: an object may not mix = and : separators" {
    try testing.expectError(error.FigMixedFlowSeparators, parseAbstract(testing.allocator, "p = {x = 1, \"y\": 2}\n", .Fig));
    try testing.expectError(error.FigMixedFlowSeparators, parseAbstract(testing.allocator, "p = {\"x\": 1, y = 2}\n", .Fig));
}

test "flow: Infinity/NaN are plain strings (JSON5 dropped)" {
    var ast = try parseAbstract(testing.allocator, "p = [Infinity, NaN, -Infinity]\n", .Fig);
    defer ast.deinit();
    try testing.expectEqualStrings("Infinity", (try ast.getValByPath(&.{ .{ .key = "p" }, .{ .index = 0 } })).kind.string);
    try testing.expectEqualStrings("NaN", (try ast.getValByPath(&.{ .{ .key = "p" }, .{ .index = 1 } })).kind.string);
}

test "flow: JSONC-style trailing commas and # comments" {
    var ast = try parseAbstract(testing.allocator,
        \\nums = [
        \\  1,   # one
        \\  2,   # two
        \\  3,
        \\]
        \\obj = { "a": 1, "b": 2, }   # trailing comma in a JSON object
    , .Fig);
    defer ast.deinit();
    try testing.expectEqualStrings("3", (try ast.getValByPath(&.{ .{ .key = "nums" }, .{ .index = 2 } })).kind.number.raw);
    try testing.expectEqualStrings("2", (try ast.getValByPath(&.{ .{ .key = "obj" }, .{ .key = "b" } })).kind.number.raw);
}

test "glued >* element markers parse (scalars and maps)" {
    var ast = try parseAbstract(testing.allocator,
        \\ports
        \\>* 25565
        \\>* 25566
        \\servers
        \\>*
        \\>> host = a.com
        \\>*
        \\>> host = b.com
    , .Fig);
    defer ast.deinit();
    try testing.expectEqualStrings("25566", (try ast.getValByPath(&.{ .{ .key = "ports" }, .{ .index = 1 } })).kind.number.raw);
    try testing.expectEqualStrings("a.com", (try ast.getValByPath(&.{ .{ .key = "servers" }, .{ .index = 0 }, .{ .key = "host" } })).kind.string);
    try testing.expectEqualStrings("b.com", (try ast.getValByPath(&.{ .{ .key = "servers" }, .{ .index = 1 }, .{ .key = "host" } })).kind.string);
}

test "spaced > * is accepted and equals glued >*" {
    var glued = try parseAbstract(testing.allocator, "xs\n>* 1\n>* 2\n", .Fig);
    defer glued.deinit();
    var spaced = try parseAbstract(testing.allocator, "xs\n> * 1\n> * 2\n", .Fig);
    defer spaced.deinit();
    try testing.expect(glued.eql(spaced));
}

test "root sequence elements are bare stars" {
    var ast = try parseAbstract(testing.allocator, "* first\n* second\n", .Fig);
    defer ast.deinit();
    try testing.expectEqualStrings("second", (try ast.getValByPath(&.{.{ .index = 1 }})).kind.string);
}

test "dash element lines are a foreign-syntax error (YAML habit)" {
    try testing.expectError(error.FigForeignSyntaxDash, parseAbstract(testing.allocator, "- 25565\n", .Fig));
    try testing.expectError(error.FigForeignSyntaxDash, parseAbstract(testing.allocator, "xs\n>- 1\n", .Fig));
    try testing.expectError(error.FigForeignSyntaxDash, parseAbstract(testing.allocator, "xs\n> - 1\n", .Fig));
    try testing.expectError(error.FigForeignSyntaxDash, parseAbstract(testing.allocator, "xs\n> - host = a\n", .Fig));
}

test "a star glued to its value is a bad separator" {
    try testing.expectError(error.FigBadMarkerSeparator, parseAbstract(testing.allocator, "xs\n>*1\n", .Fig));
    try testing.expectError(error.FigBadMarkerSeparator, parseAbstract(testing.allocator, "*1\n", .Fig));
}

test "multiline strings: raw and dedented" {
    var ast = try parseAbstract(testing.allocator,
        \\license = '''
        \\line one
        \\line two
        \\'''
        \\banner = """
        \\    hi
        \\    there
        \\    """
    , .Fig);
    defer ast.deinit();
    try testing.expectEqualStrings("line one\nline two", (try ast.getValByPath(&.{.{ .key = "license" }})).kind.string);
    try testing.expectEqualStrings("hi\nthere", (try ast.getValByPath(&.{.{ .key = "banner" }})).kind.string);
}

test "element with inline field is a hard error" {
    try testing.expectError(error.FigElementInlineField, parseAbstract(testing.allocator, "xs\n> * host = a.com\n", .Fig));
}

test "skipped level errors" {
    try testing.expectError(error.FigSkippedLevel, parseAbstract(testing.allocator, "a\n>>> x = 1\n", .Fig));
}

test "root marker errors" {
    try testing.expectError(error.FigRootMarker, parseAbstract(testing.allocator, "> x = 1\n", .Fig));
}

test "mixed container children errors" {
    try testing.expectError(error.FigMixedContainerChildren, parseAbstract(testing.allocator,
        \\a
        \\> x = 1
        \\> *
    , .Fig));
}

test "duplicate key errors" {
    try testing.expectError(error.FigDuplicateKey, parseAbstract(testing.allocator, "x = 1\nx = 2\n", .Fig));
}

test "empty childless container errors" {
    try testing.expectError(error.FigEmptyContainer, parseAbstract(testing.allocator, "a\nb = 1\n", .Fig));
}

test "foreign syntax guardrail: key: value" {
    try testing.expectError(error.FigForeignSyntaxColon, parseAbstract(testing.allocator, "key: value\n", .Fig));
}

test "comments: leading and trailing" {
    var ast = try parseAbstract(testing.allocator,
        \\logging
        \\> # a comment
        \\> level = info                # inline comment
    , .Fig);
    defer ast.deinit();
    const level_key = try ast.getKeyByPath(&.{ .{ .key = "logging" }, .{ .key = "level" } });
    try testing.expectEqualStrings("a comment", ast.comments(level_key.id).leading[0].text);
    const level_val = try ast.getValByPath(&.{ .{ .key = "logging" }, .{ .key = "level" } });
    try testing.expectEqualStrings("inline comment", ast.comments(level_val.id).trailing.?.text);
}

test "+ continuation appends another element to the last [] header" {
    var ast = try parseAbstract(testing.allocator,
        \\replacements[]
        \\> file = README.md
        \\> exactly = 0
        \\+
        \\> file = CHANGELOG.md
        \\> exactly = 1
    , .Fig);
    defer ast.deinit();
    try testing.expectEqualStrings("README.md", (try ast.getValByPath(&.{ .{ .key = "replacements" }, .{ .index = 0 }, .{ .key = "file" } })).kind.string);
    try testing.expectEqualStrings("CHANGELOG.md", (try ast.getValByPath(&.{ .{ .key = "replacements" }, .{ .index = 1 }, .{ .key = "file" } })).kind.string);
}

test "+ continuation equals a repeated [] header" {
    var plussed = try parseAbstract(testing.allocator, "xs[]\n> a = 1\n+\n> a = 2\n", .Fig);
    defer plussed.deinit();
    var repeated = try parseAbstract(testing.allocator, "xs[]\n> a = 1\nxs[]\n> a = 2\n", .Fig);
    defer repeated.deinit();
    try testing.expect(plussed.eql(repeated));
}

test "+ re-runs a NESTED append header (last-element semantics)" {
    var ast = try parseAbstract(testing.allocator,
        \\spec.containers[]
        \\> name = app
        \\spec.containers[].ports[]
        \\> port = 80
        \\+
        \\> port = 443
    , .Fig);
    defer ast.deinit();
    try testing.expectEqualStrings("443", (try ast.getValByPath(&.{ .{ .key = "spec" }, .{ .key = "containers" }, .{ .index = 0 }, .{ .key = "ports" }, .{ .index = 1 }, .{ .key = "port" } })).kind.number.raw);
}

test "+ chain survives blanks and comments (attachment matches the repeated-header form)" {
    var plussed = try parseAbstract(testing.allocator, "xs[]\n> a = 1\n\n# note\n+\n> a = 2\n", .Fig);
    defer plussed.deinit();
    var repeated = try parseAbstract(testing.allocator, "xs[]\n> a = 1\n\n# note\nxs[]\n> a = 2\n", .Fig);
    defer repeated.deinit();
    try testing.expect(plussed.eql(repeated));
    try testing.expectEqualStrings("2", (try plussed.getValByPath(&.{ .{ .key = "xs" }, .{ .index = 1 }, .{ .key = "a" } })).kind.number.raw);
}

test "dangling + errors" {
    try testing.expectError(error.FigDanglingContinuation, parseAbstract(testing.allocator, "+\n> a = 1\n", .Fig));
    // A plain header (no `[]`) breaks the chain…
    try testing.expectError(error.FigDanglingContinuation, parseAbstract(testing.allocator, "xs[]\n> a = 1\nother\n> b = 1\n+\n> a = 2\n", .Fig));
    // …as does any other zero-marker structural line.
    try testing.expectError(error.FigDanglingContinuation, parseAbstract(testing.allocator, "xs[]\n> a = 1\nb = 2\n+\n> a = 2\n", .Fig));
    // A `+` carrying depth markers is never a continuation.
    try testing.expectError(error.FigDanglingContinuation, parseAbstract(testing.allocator, "xs[]\n> a = 1\n> +\n", .Fig));
}

test "flow values are closed: no later dotted/header/index extension" {
    try testing.expectError(error.FigClosedFlowValue, parseAbstract(testing.allocator, "a = { x = 1 }\na.y = 2\n", .Fig));
    try testing.expectError(error.FigClosedFlowValue, parseAbstract(testing.allocator, "a = { x = 1 }\na\n> y = 2\n", .Fig));
    try testing.expectError(error.FigClosedFlowValue, parseAbstract(testing.allocator, "xs = [1, 2]\nxs[2] = 3\n", .Fig));
}

test "full kitchen-sink file parses" {
    const src = @embedFile("testdata/kitchen_sink.fig.txt");
    var ast = try parseAbstract(testing.allocator, src, .Fig);
    defer ast.deinit();
    try testing.expectEqualStrings("2", (try ast.getValByPath(&.{.{ .key = "version" }})).kind.number.raw);
}
