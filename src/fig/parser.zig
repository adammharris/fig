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
//!   * Of DESIGN.md's WARN diagnostics, the comment-depth-mismatch lint is not
//!     implemented (needs offsets threaded through `PendingComment`), and the
//!     inline-`#`-truncation warn is deliberately skipped (indistinguishable
//!     from an ordinary trailing comment). The rest — the coercion warns, the
//!     indent/marker-count lint, flow-like strings, missing flow commas — are
//!     collected into `Report.warnings` (see `Warning`).
//!   * Comment attachment honors a comment line's own marker depth when
//!     containers close: a comment at (or below) a closing container's child
//!     depth becomes its dangling run; a shallower one stays pending and binds
//!     to the next sibling line as its leading run.
//!   * Only LF line endings are recognized as line breaks (a lone `\r` is
//!     treated as ordinary trivia and trimmed where comments are captured).
//!
//! Every built node also carries a source `Span` (see "AST assembly" below) —
//! the foundation `Editor(fig.Language.FIG)` needs to splice edits in place
//! (`edit`/`set`/`insert`/`delete`/`comment`; see `editor_helper.zig`).
//! Whole-container structural ops (rename/move/reorder a header, analogous to
//! TOML's `renameTable`/`moveTable`) are not implemented yet.

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
    /// A bare key before `:` in a flow object (`{x: 1}`) — JSON pairs require
    /// quoted keys; fig pairs use `=`.
    FigFlowBareKeyColon,
} || tok.ScanError;

/// The teaching message for `code` — DESIGN.md's "every diagnostic names the
/// fix": the format teaches its own conventions at the point of failure,
/// because the target user is editing over SSH with no docs open. One sentence,
/// always spelling the valid fig form.
pub fn describe(code: Error) []const u8 {
    return switch (code) {
        error.FigForeignSyntaxColon => "`:` introduces a type, not a value; write `key = value`, or `key: type = value`",
        error.FigFlowBareKeyColon => "a bare key cannot take a `:` pair; write `key = 1` (fig) or `\"key\": 1` (JSON)",
        error.FigForeignSyntaxDash => "`-` is YAML's element marker; fig elements are `*` — write `> *` then `> > host = a.com` (a scalar element is `* value`)",
        error.FigForeignSyntaxBracket => "`[section]` / `[[x]]` is TOML; fig section headers are bare dotted paths — write `section`, or `x[]` to append an element",
        error.FigElementInlineField => "an element's fields go on following lines; write `> *` then `> > host = a.com`, not `* host = a.com`",
        error.FigRootMarker => "root keys carry zero markers; remove the `>` (a marker line needs a parent header above it)",
        error.FigSkippedLevel => "this line skips a nesting level; depth may only grow one `>` at a time — add the missing parent line, or drop the extra `>`",
        error.FigBadMarkerSeparator => "put a space between the marker run and what follows: `> key`, not `>key`",
        error.FigBadKey => "empty or malformed key; a bare key cannot contain `.` `:` `=` `[` or whitespace, or begin with `>`/`-` — quote it: `\"my.key\" = x`",
        error.FigDuplicateKey => "duplicate key: this key already has a value here; remove one of the definitions (re-enter a header only to add NEW keys)",
        error.FigMixedContainerChildren => "a container holds either `key = value` entries or `*` elements, never both",
        error.FigMixedSequenceAddressing => "one sequence cannot mix `[]`/`[i]` addressing with `*` element lines; pick one spelling",
        error.FigKeyNotContainer => "this path steps into an existing non-container value; remove the extra path segment, or restructure the earlier value",
        error.FigIndexSkipped => "sequence indices cannot skip ahead; write the earlier element first (even `[n] = null`)",
        error.FigIndexAlreadySet => "this index already has a value; address a new index, or use a header-final `[]` to append",
        error.FigEmptyAppendTarget => "a non-final `[]` means \"the last element\", but this sequence is empty; append one first with a header-final `[]`",
        error.FigEmptyContainer => "this container has no children; write an inline empty value instead: `key = {}` (map) or `key = []` (sequence)",
        error.FigInvalidValue => "missing value; write one after `=`, or `{}`/`[]` for an empty container",
        error.FigTypeMismatch => "the value does not satisfy its `: type` annotation; fix the value, or drop/correct the annotation",
        error.FigUnknownType => "unknown type name; the built-in types are int, float, bool, string, enum, datetime, date, time",
        error.FigTrailingContent => "unexpected content after this line's value or header; quote the whole value if it is one string (a `#` comment needs a space before it)",
        error.FigDanglingContinuation => "`+` has no `[]` append header to re-run; move it directly after its `a.b[]` group, or repeat the header",
        error.FigClosedFlowValue => "a value written inline as `[…]`/`{…}` is closed and cannot be extended later; write the block or header form if it needs to grow",
        error.FigUnclosedFlow => "this `[`/`{` value never finds its matching close; close it, or quote the whole value to make it a string",
        error.FigMixedFlowSeparators => "a flow object is fig (`=` pairs) or JSON (`:` pairs), never both in one object",
        error.FigUnclosedString => "unclosed string; add the closing quote (a single-line quote cannot span lines — use `'''` for multi-line)",
        error.FigBadEscape => "invalid escape; double quotes support \\n \\t \\r \\\\ \\\" \\uXXXX — use single quotes ('…') for raw text with literal backslashes",
        error.OutOfMemory => "out of memory",
    };
}

/// 1-based line/column plus the full offending line — shared by `Diagnostic`
/// (errors) and `Warning` (lints) so both render the same report shape.
pub const Location = struct { line: usize, column: usize, line_text: []const u8 };

/// Locate `offset` in `source`. A cursor resting exactly past a newline means
/// the problem was detected while finishing the previous line (duplicate key,
/// unclosed flow at EOF, …) — report end-of-that-line, not column 1 of an
/// empty next one.
pub fn locateOffset(source: []const u8, offset: usize) Location {
    var at = @min(offset, source.len);
    if (at > 0 and source[at - 1] == '\n') at -= 1;
    var line: usize = 1;
    var line_start: usize = 0;
    for (source[0..at], 0..) |c, i| {
        if (c == '\n') {
            line += 1;
            line_start = i + 1;
        }
    }
    const line_end = std.mem.indexOfScalarPos(u8, source, line_start, '\n') orelse source.len;
    return .{ .line = line, .column = at - line_start + 1, .line_text = source[line_start..line_end] };
}

/// The compiler-style report both severities share: `file:line:col: <label>:
/// <message>`, then the offending source line and a caret marking the column.
/// Caller owns the returned bytes.
fn renderReportAlloc(allocator: Allocator, source: []const u8, offset: usize, file: []const u8, label: []const u8, message: []const u8) Allocator.Error![]u8 {
    const loc = locateOffset(source, offset);
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    renderReport(&aw.writer, loc, file, label, message) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn renderReport(w: *std.Io.Writer, loc: Location, file: []const u8, label: []const u8, message: []const u8) std.Io.Writer.Error!void {
    try w.print("{s}:{d}:{d}: {s}: {s}\n", .{ file, loc.line, loc.column, label, message });
    // The offending line, capped so a pathological line can't flood the
    // terminal. The caret line mirrors tabs so it stays aligned under them.
    const max_shown = 160;
    const shown = loc.line_text[0..@min(loc.line_text.len, max_shown)];
    if (shown.len == 0) return; // EOF/blank line: nothing to point into
    try w.print("    {s}{s}\n", .{ shown, if (shown.len < loc.line_text.len) "…" else "" });
    if (loc.column - 1 <= shown.len) {
        try w.writeAll("    ");
        for (shown[0 .. loc.column - 1]) |c| try w.writeByte(if (c == '\t') '\t' else ' ');
        try w.writeAll("^\n");
    }
}

/// A parse failure plus the byte position where the parser stopped. The parser
/// is single-pass, so when an error is returned its cursor sits on (or just
/// after) the offending token — precise enough for `file:line:col` without
/// threading a location through every error site.
pub const Diagnostic = struct {
    code: Error,
    /// Byte offset into the source where parsing stopped.
    offset: usize,

    /// 1-based line/column of `offset`, plus the full offending line.
    pub fn locate(self: Diagnostic, source: []const u8) Parser.Location {
        return locateOffset(source, self.offset);
    }

    /// Render `file:line:col: error: <message>` + source line + caret.
    pub fn renderAlloc(self: Diagnostic, allocator: Allocator, source: []const u8, file: []const u8) Allocator.Error![]u8 {
        return renderReportAlloc(allocator, source, self.offset, file, "error", describe(self.code));
    }
};

/// An authoring-time lint (DESIGN.md "Authoring-time diagnostics", warn
/// severity): the tree is well-defined, but the line is a likely mistake.
/// Collected during the parse and returned via `Report` — the caller decides
/// presentation (`--quiet` silences, `--strict` promotes to failure).
pub const Warning = struct {
    code: Code,
    /// Byte offset of the surprising token (see `locateOffset`).
    offset: usize,

    pub const Code = enum {
        /// A bare token spelling a bool/null from another config language
        /// (`Yes`, `ON`, `TRUE`, `Null`) fell to a plain string — the Norway
        /// class, surfaced instead of silently coerced either way.
        string_looks_like_literal,
        /// A digit-only token with a leading zero (`007`) kept its padding as
        /// a string (the TOML leading-zero rule).
        string_leading_zero,
        /// A bare date/time with no `T`+zone (`2026-07-01`) sniffed to a
        /// datetime value; a full RFC-3339 timestamp never warns.
        ambiguous_datetime,
        /// A balanced, well-formed `[…]`/`{…}` separated from trailing content
        /// by whitespace (`[80, 443] x`) fell to a bare string. Glued shapes
        /// (`[Blog](/x)`, `[a-z]*.md`) are the intended bare strings and never
        /// warn.
        flow_like_string,
        /// A bare flow value contains ` = ` (`{x = 1 y = 2}` → `x = "1 y =
        /// 2"`) — almost always a missing comma between pairs.
        flow_missing_comma,
        /// A line's visual indentation disagrees with its `>` marker count
        /// (convention: 2 spaces per level, no tabs). Meaning follows the
        /// count; the indent is the redundant cross-check that just failed.
        indent_marker_mismatch,
    };

    /// The teaching message — same name-the-fix contract as `describe`.
    pub fn describeWarning(code: Code) []const u8 {
        return switch (code) {
            .string_looks_like_literal => "this spells a boolean/null in other config languages, but fig literals are lowercase-only, so it stays the string it spells; quote it to make the string explicit, or lowercase it for the literal",
            .string_leading_zero => "a leading zero is not a number in fig, so the padding was kept as a string; quote it to make that explicit, or drop the zero for a number",
            .ambiguous_datetime => "a bare date/time becomes a datetime value, not text; quote it if you meant a string",
            .flow_like_string => "this looks like a `[…]`/`{…}` flow value with trailing content, so the whole line was read as one bare string; remove the trailing content for a collection, or quote the value to affirm the string",
            .flow_missing_comma => "a bare flow value containing ` = ` usually means a missing comma between pairs; add the comma, or quote the value if it really is text",
            .indent_marker_mismatch => "indentation disagrees with the `>` marker count (convention: 2 spaces per level); meaning follows the count — fix whichever signal is wrong",
        };
    }

    /// Render `file:line:col: warning: <message>` + source line + caret.
    pub fn renderAlloc(self: Warning, allocator: Allocator, source: []const u8, file: []const u8) Allocator.Error![]u8 {
        return renderReportAlloc(allocator, source, self.offset, file, "warning", describeWarning(self.code));
    }
};

/// Everything a parse reports besides the tree: the failure diagnostic (set
/// only on error) and the authoring-time warnings (valid on success AND on
/// failure — warns collected before the error still stand). `warnings` is
/// allocated with the allocator passed to `parseWithReport`; the caller owns it.
pub const Report = struct {
    diag: ?Diagnostic = null,
    warnings: []const Warning = &.{},
};

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
/// Overrides `pos` as the `Diagnostic` offset when set — for error sites where
/// the cursor has already moved past the token that actually offends (set via
/// `failAt`). `pos` is the right answer everywhere else.
fail_offset: ?usize = null,
/// Byte offset of the start of the line currently being processed (set once
/// per iteration of the main loop in `run`). The fallback span anchor for a
/// container whose opener carries no more precise position of its own (a
/// bare `*` element-opener, an `[]`-append-created element, …) — always a
/// valid position on that container's own opening line, which is all
/// `Editor(Fig)`'s line-based splicing needs (see `lineStartBefore`).
cur_line_start: usize = 0,
/// Authoring-time lints collected during the pass (arena-backed; duped out to
/// the caller by `parseWithReport`). Empty unless a warn site fired.
warnings: std.ArrayList(Warning) = .empty,

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
    /// Source span of the key token itself (quotes included when quoted) —
    /// mirrors every other parser's `keyvalue.key` span convention, so
    /// `Editor(Fig)` can splice a rename in place.
    key_span: Span = Span.init(0, 0),
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
    /// Source span of this value. For a scalar, the token's own tight span
    /// (quotes/brackets included where the value opens with one). For a
    /// container, the position right after its opening marker/bracket at
    /// creation time (`buildNode` widens `.end` to the container's full
    /// extent once every child's own span is known — see "AST assembly").
    span: Span = Span.init(0, 0),
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
/// A dotted-path key segment plus its own source span (quotes included when
/// quoted) — carried through path navigation so every container the path
/// touches (intermediate dotted segments included) can stamp an accurate
/// `key_span` on the `MEntry` it creates or reuses.
const KeySeg = struct { name: []const u8, span: Span };
const Step = union(enum) { key: KeySeg, index: IndexKind };

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
    return parseImpl(allocator, input, format, null);
}

/// `parse`, but also fills `out`: `diag` on failure (error code + byte offset,
/// for `file:line:col` teaching messages), `warnings` always (authoring-time
/// lints, allocated with `allocator` — the caller owns/frees them). The hook
/// the CLI (and eventually the C ABI) renders reports from.
pub fn parseWithReport(allocator: Allocator, input: []const u8, format: Type, out: *Report) Error!Document {
    return parseImpl(allocator, input, format, out);
}

fn parseImpl(allocator: Allocator, input: []const u8, format: Type, out: ?*Report) Error!Document {
    _ = format;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    var self: Parser = .{ .allocator = arena_state.allocator(), .source = input };
    // Warnings are duped out on every exit path (they are valid alongside a
    // failure too). Best-effort under OOM — the tree, not the lint list, is
    // the load-bearing result. Runs before the arena defer (LIFO), while
    // `self.warnings` is still alive.
    defer if (out) |o| {
        o.warnings = allocator.dupe(Warning, self.warnings.items) catch &.{};
    };
    self.run() catch |err| {
        if (out) |o| o.diag = .{ .code = err, .offset = self.fail_offset orelse self.pos };
        return err;
    };

    var b = AST.Builder.init(allocator);
    // `finish` only moves `nodes`/`owned_strings` out; the comment side-table's
    // outer spines (`comments`/`view_comments`) are never consumed by it, so
    // `deinit` is still required on the success path too (mirrors every
    // `Builder` call site, including its own tests).
    defer b.deinit();
    const root_id = try self.buildRoot(&b);
    var ast = try b.finish(root_id);
    errdefer ast.deinit();
    const node_spans = try b.takeSpans();

    return .{ .source = input, .ast = ast, .node_spans = node_spans };
}

/// Return `err` with the diagnostic caret pinned to `offset` — for the sites
/// where the cursor has already scanned past the token that actually offends
/// (e.g. the `:` of `key: value`, consumed before the missing `=` is noticed).
fn failAt(self: *Parser, offset: usize, err: Error) Error {
    self.fail_offset = offset;
    return err;
}

/// Record an authoring-time lint anchored at `offset` (see `Warning`).
fn warn(self: *Parser, code: Warning.Code, offset: usize) Error!void {
    try self.warnings.append(self.allocator, .{ .code = code, .offset = offset });
}

// ── Main line loop ──────────────────────────────────────────────────────────

fn run(self: *Parser) Error!void {
    while (self.pos < self.source.len) {
        const line_start = self.pos;
        self.cur_line_start = line_start;
        self.skipSpacesTabs(); // cosmetic indent — never load-bearing (linted below)
        const indent = self.source[line_start..self.pos];
        const m = try self.scanMarkers();
        // A TRULY blank line (nothing at all, not even a comment) is skipped
        // outright — before the indent lint (trailing whitespace on an empty
        // line is not a depth signal). This must NOT reuse `atEndOfContent`
        // (which also treats a leading `#` as "content is over") — a
        // comment-only line has to fall through to the `#` handling below, or
        // it would never be consumed and the main loop would spin forever at
        // the same position.
        if (!m.star and self.atTrueLineEnd()) {
            self.skipToNextLine();
            continue;
        }
        // Indent/count lint (DESIGN.md "Depth diagnostics"): meaning lives in
        // the `>` count alone, but indentation — when present — is the
        // redundant second signal, and this is the only check that can catch a
        // deeper-by-one / same-depth miscount. Convention: `2 × depth` spaces,
        // no tabs. Bare and spaced-marker files (zero indent) stay lint-clean.
        // Comment lines are linted too: their depth is load-bearing for
        // attachment.
        if (indent.len > 0) {
            const tabbed = std.mem.indexOfScalar(u8, indent, '\t') != null;
            // Anchored at the first char AFTER the indent (the marker run /
            // key), not at the line start: a line-start offset sits right past
            // the previous newline, which `locateOffset` would step back over.
            if (tabbed or indent.len != 2 * m.depth) try self.warn(.indent_marker_mismatch, line_start + indent.len);
        }
        // A `*` element marker already committed this to an element line (even
        // a bare `*` opener with no value, or one carrying only a trailing
        // comment), so skip the comment-only shortcut below.
        if (!m.star) {
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
        const colon_pos = self.pos;
        self.advance();
        self.skipSpacesTabs();
        const type_start = self.pos;
        while (self.pos < self.source.len and tok.isBareKeyChar(self.source[self.pos])) self.pos += 1;
        const type_name = self.source[type_start..self.pos];
        if (type_name.len == 0) return error.FigBadKey;
        self.skipSpacesTabs();
        // `key: value` (the YAML habit) — the `:` is the offending token, not
        // the spot where the missing `=` was noticed, so pin the caret there.
        if (self.peek() != '=') return self.failAt(colon_pos, error.FigForeignSyntaxColon);
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
            if (self.findEntry(m, k.name) != null) return error.FigDuplicateKey;
            const entry = try self.allocator.create(MEntry);
            entry.* = .{ .key = k.name, .key_span = k.span, .value = value_node };
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
    // The position right after the `> *` marker prefix — before any trailing
    // whitespace is skipped — so a bare `*` opener (no value on its own line)
    // still anchors its container's span at a real, reconstructable position
    // on its own line (`Editor(Fig)` copies this prefix verbatim for a new
    // sibling element).
    const body_start = self.pos;
    self.skipSpacesTabs();
    const leading = try self.drainPendingLeading();
    const seq = try target.asSequence();
    try seq.markElement();

    if (self.atEndOfContent()) {
        const child = try self.allocator.create(PendingContainer);
        child.* = .{};
        const el = try self.allocator.create(TNode);
        el.* = .{ .value = .{ .container = child }, .span = Span.init(body_start, body_start) };
        try self.appendComments(&el.leading, leading);
        try seq.elements.append(self.allocator, el);
        if (try self.scanTrailingCommentOnly()) |cm| el.trailing = .{ .text = cm };
        self.consumeLineEnd();
        try self.stack.append(self.allocator, .{ .container = child, .child_depth = depth + 1, .owner = el });
        return;
    }

    if (self.peek() == ':') {
        const colon_pos = self.pos;
        self.advance();
        self.skipSpacesTabs();
        const type_start = self.pos;
        while (self.pos < self.source.len and tok.isBareKeyChar(self.source[self.pos])) self.pos += 1;
        const type_name = self.source[type_start..self.pos];
        if (type_name.len == 0) return error.FigBadKey;
        self.skipSpacesTabs();
        // Same caret pin as `parseKeyLine`: the `:` is the offending token.
        if (self.peek() != '=') return self.failAt(colon_pos, error.FigForeignSyntaxColon);
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

fn scanKeySeg(self: *Parser) Error!KeySeg {
    const c = self.peek() orelse return error.FigBadKey;
    const start = self.pos;
    if (c == '"') {
        const r = try tok.scanDoubleQuoted(self.allocator, self.source, self.pos);
        self.pos = r.end;
        return .{ .name = r.text, .span = Span.init(start, r.end) };
    }
    if (c == '\'') {
        const r = try tok.scanSingleQuoted(self.allocator, self.source, self.pos);
        self.pos = r.end;
        return .{ .name = r.text, .span = Span.init(start, r.end) };
    }
    while (self.pos < self.source.len and tok.isBareKeyChar(self.source[self.pos])) self.pos += 1;
    if (self.pos == start) return error.FigBadKey;
    const text = self.source[start..self.pos];
    if (text[0] == '-' or text[0] == '>') return error.FigBadKey;
    return .{ .name = text, .span = Span.init(start, self.pos) };
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

fn getOrCreateMapContainer(self: *Parser, m: *Mapping, seg: KeySeg) Error!*PendingContainer {
    if (self.findEntry(m, seg.name)) |e| {
        return switch (e.value.value) {
            .container => |c| c.open(),
            else => error.FigKeyNotContainer,
        };
    }
    const child = try self.allocator.create(PendingContainer);
    child.* = .{};
    const entry = try self.allocator.create(MEntry);
    entry.* = .{ .key = seg.name, .key_span = seg.span, .value = .{ .value = .{ .container = child }, .span = seg.span } };
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
                el.* = .{ .value = .{ .container = child }, .span = Span.init(self.cur_line_start, self.cur_line_start) };
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
            if (self.findEntry(m, k.name)) |e| {
                const c = switch (e.value.value) {
                    .container => |cc| try cc.open(),
                    else => return error.FigDuplicateKey,
                };
                return .{ .container = c, .owner = &e.value, .entry = e };
            }
            const child = try self.allocator.create(PendingContainer);
            child.* = .{};
            const entry = try self.allocator.create(MEntry);
            entry.* = .{ .key = k.name, .key_span = k.span, .value = .{ .value = .{ .container = child }, .span = k.span } };
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
                        el.* = .{ .value = .{ .container = child }, .span = Span.init(self.cur_line_start, self.cur_line_start) };
                        try s.elements.append(self.allocator, el);
                        return .{ .container = child, .owner = el, .entry = null };
                    } else return error.FigIndexSkipped;
                },
                .append_or_last => {
                    const child = try self.allocator.create(PendingContainer);
                    child.* = .{};
                    _ = try child.asMapping(); // append-created elements are always map-shaped
                    const el = try self.allocator.create(TNode);
                    el.* = .{ .value = .{ .container = child }, .span = Span.init(self.cur_line_start, self.cur_line_start) };
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
        node.span = self.spanOf(res.text);
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
                const vstart = self.pos;
                if (try self.flowLikePrefix(vstart)) try self.warn(.flow_like_string, vstart);
                const res = self.scanBareRestOfLine();
                if (res.text.len == 0) return error.FigInvalidValue;
                // Opened with a delimiter → sniffing is off; it is a string.
                var node: TNode = .{ .value = .{ .string = res.text }, .span = self.spanOf(res.text) };
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
            const vstart = self.pos;
            const res = self.scanBareRestOfLine();
            if (res.text.len == 0) return error.FigInvalidValue;
            var node: TNode = if (force_string_bare)
                .{ .value = .{ .string = res.text }, .span = self.spanOf(res.text) }
            else
                try self.sniffToNodeWarned(res.text, vstart);
            if (res.comment) |cm| node.trailing = .{ .text = cm };
            return node;
        },
    }
}

fn parseQuotedOrTriple(self: *Parser, q: u8, force_string_bare: bool) Error!TNode {
    _ = force_string_bare; // a quoted/multiline RHS is always a valid string
    const start = self.pos;
    if (self.isTripleAt(self.pos, q)) {
        const r = if (q == '\'')
            try tok.scanTripleSingle(self.allocator, self.source, self.pos)
        else
            try tok.scanTripleDouble(self.allocator, self.source, self.pos);
        self.pos = r.end;
        var node: TNode = .{ .value = .{ .string = r.text }, .span = Span.init(start, r.end) };
        const trailing = try self.scanTrailingCommentOnly();
        node.trailing = if (r.opener_comment) |oc| .{ .text = oc } else if (trailing) |t| .{ .text = t } else null;
        return node;
    }
    const r = if (q == '\'')
        try tok.scanSingleQuoted(self.allocator, self.source, self.pos)
    else
        try tok.scanDoubleQuoted(self.allocator, self.source, self.pos);
    self.pos = r.end;
    var node: TNode = .{ .value = .{ .string = r.text }, .span = Span.init(start, r.end) };
    if (try self.scanTrailingCommentOnly()) |t| node.trailing = .{ .text = t };
    return node;
}

fn sniffToNode(self: *Parser, text: []const u8) TNode {
    const span = self.spanOf(text);
    return switch (tok.sniffBare(text)) {
        .null_ => .{ .value = .null_, .span = span },
        .boolean => |b| .{ .value = .{ .boolean = b }, .span = span },
        .number => |n| .{ .value = .{ .number = n }, .span = span },
        .datetime => |d| .{ .value = .{ .extended = .{ .kind = d.kind, .text = d.raw } }, .span = span },
        .string => .{ .value = .{ .string = text }, .span = span },
    };
}

/// `sniffToNode` plus the coercion warns (DESIGN.md "Coercion diagnostics") —
/// the sniffing cost surfaced rather than removed. `offset` anchors the warn
/// at the value's first byte. Both bare-value positions (block RHS, flow
/// element) route through here; explicitly typed values never do (the
/// annotation is the author saying "I know").
fn sniffToNodeWarned(self: *Parser, text: []const u8, offset: usize) Error!TNode {
    const node = self.sniffToNode(text);
    switch (node.value) {
        .string => {
            if (looksLikeLiteral(text)) {
                try self.warn(.string_looks_like_literal, offset);
            } else if (looksLikeLeadingZero(text)) {
                try self.warn(.string_leading_zero, offset);
            }
        },
        // Quietly, and only when ambiguous: a bare date or clock time reads
        // as prose to some authors. A `T`-carrying timestamp is unambiguous
        // (nobody types `T` mid-sentence) and stays silent — warn-fatigue is
        // the failure mode this rule is calibrated against.
        .extended => |e| switch (e.kind) {
            .local_date, .local_time => try self.warn(.ambiguous_datetime, offset),
            else => {},
        },
        else => {},
    }
    return node;
}

/// Case-variant bool/null spellings from other config languages (`Yes`, `ON`,
/// `TRUE`, `Null`) — never literals in fig (the Norway fix), but surprising
/// enough as silent strings to earn a warn. Exact lowercase `true`/`false`/
/// `null` never reach here (they sniff to literals first).
fn looksLikeLiteral(text: []const u8) bool {
    const words = [_][]const u8{ "yes", "no", "on", "off", "true", "false", "null" };
    for (words) |w| {
        if (std.ascii.eqlIgnoreCase(text, w)) return true;
    }
    return false;
}

/// Does a `bare_trailing` value at `start` *look* like it wanted to be flow?
/// True iff the balanced bracket prefix (a) detaches from the trailing content
/// by whitespace and (b) is itself well-formed flow — `[80, 443] x`, not
/// `[Blog](/x)` / `[a-z]*.md` / `[b]x[/b]` (glued: the intended bare-string
/// shapes, DESIGN.md's warn-fatigue guard) and not `[80,, 443] x` (prefix
/// malformed: never parsed as flow in the first place). Well-formedness is
/// decided by a speculative sub-parse of the prefix alone; its containers land
/// in the shared arena and its warnings are discarded with the sub-parser.
fn flowLikePrefix(self: *Parser, start: usize) Error!bool {
    const close = tok.bracketCloseIndex(self.source, start) orelse return false;
    if (close + 1 >= self.source.len) return false;
    const sep = self.source[close + 1];
    if (sep != ' ' and sep != '\t') return false; // glued trailing → intended string
    const prefix = self.source[start .. close + 1];
    var sub: Parser = .{ .allocator = self.allocator, .source = prefix };
    _ = sub.parseFlowValue() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    return sub.pos == prefix.len;
}

/// `007`-style: digit-only (after an optional sign) with a leading zero — a
/// number lookalike the TOML leading-zero rule keeps as a string.
fn looksLikeLeadingZero(text: []const u8) bool {
    var s = text;
    if (s.len > 0 and (s[0] == '+' or s[0] == '-')) s = s[1..];
    if (s.len < 2 or s[0] != '0' or !std.ascii.isDigit(s[1])) return false;
    for (s[1..]) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
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
    const open = self.pos;
    self.advance(); // '['
    const seq = try self.allocator.create(PendingContainer);
    seq.* = .{ .closed = true };
    const s = try seq.asSequence();
    self.skipFlowWs();
    if (self.peek() == ']') {
        self.advance();
        return .{ .value = .{ .container = seq }, .span = Span.init(open, self.pos) };
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
    return .{ .value = .{ .container = seq }, .span = Span.init(open, self.pos) };
}

fn parseFlowObject(self: *Parser) Error!TNode {
    const open = self.pos;
    self.advance(); // '{'
    const map = try self.allocator.create(PendingContainer);
    map.* = .{ .closed = true };
    const m = try map.asMapping();
    self.skipFlowWs();
    if (self.peek() == '}') {
        self.advance();
        return .{ .value = .{ .container = map }, .span = Span.init(open, self.pos) };
    }
    // A flow object is EITHER fig-inline (`=` pairs, keys bare or quoted) OR
    // JSON (`:` pairs, keys quoted) — the pair separator selects the spelling,
    // and it may not change within one object. `:` with a bare key is the
    // YAML/JSON5 habit; its own error code so the message can name both fixes
    // (`key = 1` fig / `"key": 1` JSON).
    var mode: ?enum { fig, json } = null;
    while (true) {
        const key = try self.parseFlowKey();
        self.skipFlowWs();
        const sep = self.peek() orelse return error.FigUnclosedFlow;
        const this_mode: @TypeOf(mode) = switch (sep) {
            '=' => .fig,
            ':' => if (key.quoted) .json else return error.FigFlowBareKeyColon,
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
        entry.* = .{ .key = key.text, .key_span = key.span, .value = v };
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
    return .{ .value = .{ .container = map }, .span = Span.init(open, self.pos) };
}

const FlowKey = struct { text: []const u8, quoted: bool, span: Span };

fn parseFlowKey(self: *Parser) Error!FlowKey {
    const c = self.peek() orelse return error.FigBadKey;
    const start = self.pos;
    if (c == '"') {
        const r = try tok.scanDoubleQuoted(self.allocator, self.source, self.pos);
        self.pos = r.end;
        return .{ .text = r.text, .quoted = true, .span = Span.init(start, r.end) };
    }
    if (c == '\'') {
        const r = try tok.scanSingleQuoted(self.allocator, self.source, self.pos);
        self.pos = r.end;
        return .{ .text = r.text, .quoted = true, .span = Span.init(start, r.end) };
    }
    while (self.pos < self.source.len and !isFlowKeyStop(self.source[self.pos])) self.pos += 1;
    if (self.pos == start) return error.FigBadKey;
    return .{ .text = self.source[start..self.pos], .quoted = false, .span = Span.init(start, self.pos) };
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
            const vstart = self.pos;
            if (try self.flowLikePrefix(vstart)) try self.warn(.flow_like_string, vstart);
            const text = self.scanFlowBareBracket();
            if (text.len == 0) return error.FigInvalidValue;
            // Opened with a delimiter → sniffing is off; it is a string.
            return .{ .value = .{ .string = text }, .span = self.spanOf(text) };
        }
        return self.parseFlowValue();
    }
    if (c == '"') {
        const start = self.pos;
        const r = try tok.scanDoubleQuoted(self.allocator, self.source, self.pos);
        self.pos = r.end;
        return .{ .value = .{ .string = r.text }, .span = Span.init(start, r.end) };
    }
    if (c == '\'') {
        const start = self.pos;
        const r = try tok.scanSingleQuoted(self.allocator, self.source, self.pos);
        self.pos = r.end;
        return .{ .value = .{ .string = r.text }, .span = Span.init(start, r.end) };
    }
    const vstart = self.pos;
    const text = self.scanFlowBareValue();
    if (text.len == 0) return error.FigInvalidValue;
    // The missing-comma smell: a bare flow value swallowing a ` = ` almost
    // always means `{x = 1 y = 2}` — the pair separator of a *next* pair read
    // as value text. The scariest silent behavior bare flow values allow, so
    // it warns (quote the value to affirm genuine ` = ` text).
    if (std.mem.indexOf(u8, text, " = ")) |i| try self.warn(.flow_missing_comma, vstart + i + 1);
    // `Infinity`/`NaN` are NOT recognized here (JSON5 is dropped): they sniff to
    // plain strings, exactly as bare `inf`/`nan` do in the block layer.
    return try self.sniffToNodeWarned(text, vstart);
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
    var root_wrap: TNode = .{ .value = .{ .container = &self.root }, .span = Span.init(0, 0) };
    root_wrap.dangling = self.root_dangling;
    return self.buildNode(b, &root_wrap);
}

/// Build `node` into `b`, returning its id. For a container, `node.span.end`
/// is widened here to the full extent of its subtree — every child's own span
/// is already final by the time it's read back (`buildNode` recurses
/// bottom-up), so no separate position-tracking pass is needed during the
/// original line scan; only each container's OPENING position (stamped at
/// creation time — see `TNode.span`'s doc comment) had to be recorded there.
fn buildNode(self: *Parser, b: *AST.Builder, node: *TNode) Error!AST.Node.Id {
    const id: AST.Node.Id = switch (node.value) {
        .null_ => try b.addNull(),
        .boolean => |v| try b.addBool(v),
        .string => |s| try b.addString(s),
        .number => |n| try b.addNumberRaw(n.raw, n.kind == .float),
        .extended => |e| try b.addExtended(e.kind, e.text),
        .container => |c| blk: {
            const built = try self.buildContainer(b, c);
            node.span.end = @max(node.span.end, built.end);
            break :blk built.id;
        },
    };
    b.setSpan(id, node.span);
    if (node.trailing) |t| try b.setTrailingComment(id, t);
    for (node.dangling.items) |c| try b.addDanglingComment(id, c);
    return id;
}

const BuiltContainer = struct { id: AST.Node.Id, end: usize };

fn buildContainer(self: *Parser, b: *AST.Builder, c: *PendingContainer) Error!BuiltContainer {
    switch (c.kind) {
        .undecided => return error.FigEmptyContainer,
        .mapping => {
            var kv_ids: std.ArrayList(AST.Node.Id) = .empty;
            var end: usize = 0;
            for (c.mapping.entries.items) |e| {
                const key_id = try b.addString(e.key);
                b.setSpan(key_id, e.key_span);
                if (e.key_leading.items.len > 0) try b.setComments(key_id, .{ .leading = e.key_leading.items });
                const value_id = try self.buildNode(b, &e.value);
                const kv_id = try b.addKeyValue(key_id, value_id);
                b.setSpan(kv_id, Span.init(e.key_span.start, e.value.span.end));
                end = @max(end, e.value.span.end);
                try kv_ids.append(self.allocator, kv_id);
            }
            return .{ .id = try b.addMappingFromEntries(kv_ids.items), .end = end };
        },
        .sequence => {
            var ids: std.ArrayList(AST.Node.Id) = .empty;
            var end: usize = 0;
            for (c.sequence.elements.items) |el| {
                const el_id = try self.buildNode(b, el);
                end = @max(end, el.span.end);
                for (el.leading.items) |lc| try b.addLeadingComment(el_id, lc);
                try ids.append(self.allocator, el_id);
            }
            return .{ .id = try b.addSequence(ids.items), .end = end };
        },
    }
}

// ── Char-level helpers ───────────────────────────────────────────────────────

/// Span of `text` within `self.source`, valid only when `text` is literally a
/// subslice of it — true for every bare/trimmed token (`scanBareRestOfLine`,
/// `scanFlowBareValue`/`scanFlowBareBracket`, a bare key segment) but NOT for
/// a quoted/decoded string (those track their own `(start, r.end)` at the call
/// site, since escape decoding allocates a new buffer).
fn spanOf(self: *const Parser, text: []const u8) Span {
    const base = @intFromPtr(self.source.ptr);
    const start = @intFromPtr(text.ptr) - base;
    return Span.init(start, start + text.len);
}

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

// ── Span tests (Editor(Fig) foundation — see DESIGN.md's "no in-place editor
// yet" note; this is the prerequisite the editor's span-splice engine needs) ──

fn expectSpan(source: []const u8, path: []const AST.PathSegment, expected: []const u8) !void {
    const doc = try parse(testing.allocator, source, .Fig);
    defer doc.deinit(testing.allocator);
    const node = try doc.ast.getValByPath(path);
    const span = doc.span(node);
    try testing.expectEqualStrings(expected, source[span.start..span.end]);
}

/// Same as `expectSpan`, but reads the *keyvalue* wrapper's span (the raw node
/// at `path`, unwrapped by neither `getKeyByPath` nor `getValByPath`) — what
/// `Editor(Fig)`'s `deleteKey`/`moveKey` splice.
fn expectEntrySpan(source: []const u8, path: []const AST.PathSegment, expected: []const u8) !void {
    const doc = try parse(testing.allocator, source, .Fig);
    defer doc.deinit(testing.allocator);
    const node = try doc.ast.getNodeByPath(path);
    const span = doc.span(node);
    try testing.expectEqualStrings(expected, source[span.start..span.end]);
}

test "span: scalar assignment values are tight" {
    try expectSpan("x = 1\n", &.{.{ .key = "x" }}, "1");
    try expectSpan("title = My server\n", &.{.{ .key = "title" }}, "My server");
    try expectSpan("s = \"hi\\n\"\n", &.{.{ .key = "s" }}, "\"hi\\n\"");
    try expectSpan("s = 'raw'\n", &.{.{ .key = "s" }}, "'raw'");
}

test "span: keys are tight, quotes included" {
    try expectSpan("x = 1\n", &.{.{ .key = "x" }}, "1");
    const doc = try parse(testing.allocator, "\"my key\" = 1\n", .Fig);
    defer doc.deinit(testing.allocator);
    const key = try doc.ast.getKeyByPath(&.{.{ .key = "my key" }});
    try testing.expectEqualStrings("\"my key\"", "\"my key\" = 1\n"[doc.span(key).start..doc.span(key).end]);
}

test "span: nested marker-block value" {
    const src =
        \\database
        \\> host = localhost
        \\> pool
        \\> > size = 10
        \\
    ;
    try expectSpan(src, &.{ .{ .key = "database" }, .{ .key = "host" } }, "localhost");
    try expectSpan(src, &.{ .{ .key = "database" }, .{ .key = "pool" }, .{ .key = "size" } }, "10");
}

test "span: dotted flattener key segment" {
    const src =
        \\cache
        \\> redis.host = 127.0.0.1
        \\
    ;
    try expectSpan(src, &.{ .{ .key = "cache" }, .{ .key = "redis" }, .{ .key = "host" } }, "127.0.0.1");
}

test "span: flow container covers exactly its brackets" {
    try expectSpan("ports = [80, 443]\n", &.{.{ .key = "ports" }}, "[80, 443]");
    try expectSpan("p = { x = 1, y = 2 }\n", &.{.{ .key = "p" }}, "{ x = 1, y = 2 }");
    try expectSpan("ports = [80, 443]\n", &.{ .{ .key = "ports" }, .{ .index = 1 } }, "443");
}

test "span: a nested block container's keyvalue covers header through last body line" {
    const src =
        \\database
        \\> host = localhost
        \\> pool
        \\> > size = 10
        \\other = 1
        \\
    ;
    try expectEntrySpan(src, &.{ .{ .key = "database" }, .{ .key = "pool" } }, "pool\n> > size = 10");
    try expectEntrySpan(src, &.{.{ .key = "database" }}, "database\n> host = localhost\n> pool\n> > size = 10");
}

test "span: sequence element (map-shaped) covers its own body only" {
    const src =
        \\servers
        \\> *
        \\>> host = a.com
        \\> *
        \\>> host = b.com
        \\
    ;
    try expectSpan(src, &.{ .{ .key = "servers" }, .{ .index = 0 }, .{ .key = "host" } }, "a.com");
    try expectSpan(src, &.{ .{ .key = "servers" }, .{ .index = 1 }, .{ .key = "host" } }, "b.com");
}

test "span: append header re-anchored elements" {
    const src =
        \\jobs.test.steps[]
        \\> uses = a
        \\jobs.test.steps[]
        \\> run = b
        \\
    ;
    try expectSpan(src, &.{ .{ .key = "jobs" }, .{ .key = "test" }, .{ .key = "steps" }, .{ .index = 0 }, .{ .key = "uses" } }, "a");
    try expectSpan(src, &.{ .{ .key = "jobs" }, .{ .key = "test" }, .{ .key = "steps" }, .{ .index = 1 }, .{ .key = "run" } }, "b");
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
    try testing.expectError(error.FigFlowBareKeyColon, parseAbstract(testing.allocator, "p = {x: 1}\n", .Fig));
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
    const src = @embedFile("testdata/kitchen_sink.fig");
    var ast = try parseAbstract(testing.allocator, src, .Fig);
    defer ast.deinit();
    try testing.expectEqualStrings("2", (try ast.getValByPath(&.{.{ .key = "version" }})).kind.number.raw);
}

test "diagnostic captures the failing position" {
    // Line 3 (`level: info`) is the YAML-habit error; the caret pins to the
    // `:` (failAt), not where the cursor stopped after the would-be type name.
    const src = "logging\n> format = json\n> level: info\n";
    var report: Report = .{};
    defer testing.allocator.free(report.warnings);
    const result = parseWithReport(testing.allocator, src, .Fig, &report);
    try testing.expectError(error.FigForeignSyntaxColon, result);
    const d = report.diag.?;
    try testing.expectEqual(@as(Error!void, error.FigForeignSyntaxColon), @as(Error!void, d.code));
    const loc = d.locate(src);
    try testing.expectEqual(@as(usize, 3), loc.line);
    try testing.expectEqualStrings("> level: info", loc.line_text);
}

test "diagnostic renders file:line:col, the source line, and a caret" {
    const src = "key: value\n";
    var report: Report = .{};
    defer testing.allocator.free(report.warnings);
    _ = parseWithReport(testing.allocator, src, .Fig, &report) catch {};
    const rendered = try report.diag.?.renderAlloc(testing.allocator, src, "app.fig");
    defer testing.allocator.free(rendered);
    try testing.expect(std.mem.startsWith(u8, rendered, "app.fig:1:"));
    try testing.expect(std.mem.indexOf(u8, rendered, "error: `:` introduces a type, not a value") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "\n    key: value\n") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "^\n") != null);
}

test "report is empty on a clean parse" {
    var report: Report = .{};
    defer testing.allocator.free(report.warnings);
    var parsed = try parseWithReport(testing.allocator, "a = 1\n", .Fig, &report);
    defer parsed.deinit(testing.allocator);
    try testing.expect(report.diag == null);
    try testing.expectEqual(@as(usize, 0), report.warnings.len);
}

/// Parse `input`, expecting success, and return the warning codes in order
/// (testing-allocator-backed; caller frees).
fn collectWarnCodes(input: []const u8) ![]Warning.Code {
    var report: Report = .{};
    defer testing.allocator.free(report.warnings);
    var parsed = try parseWithReport(testing.allocator, input, .Fig, &report);
    defer parsed.deinit(testing.allocator);
    const codes = try testing.allocator.alloc(Warning.Code, report.warnings.len);
    for (report.warnings, 0..) |w, i| codes[i] = w.code;
    return codes;
}

fn expectWarnCodes(input: []const u8, expected: []const Warning.Code) !void {
    const codes = try collectWarnCodes(input);
    defer testing.allocator.free(codes);
    try testing.expectEqualSlices(Warning.Code, expected, codes);
}

test "coercion warns: literal lookalikes and leading zeros" {
    try expectWarnCodes("norway = Yes\n", &.{.string_looks_like_literal});
    try expectWarnCodes("switch = ON\n", &.{.string_looks_like_literal});
    try expectWarnCodes("shout = TRUE\n", &.{.string_looks_like_literal});
    try expectWarnCodes("nothing = Null\n", &.{.string_looks_like_literal});
    try expectWarnCodes("zip = 007\n", &.{.string_leading_zero});
    // The real literals, prose, quotes, and annotations never warn.
    try expectWarnCodes("ok = true\nn = null\nx = 0\nhex = 0xFF\n", &.{});
    try expectWarnCodes("movie = 12 monkeys\ntitle = Yes Prime Minister\n", &.{});
    try expectWarnCodes("flag = \"true\"\n", &.{});
    try expectWarnCodes("norway: string = Yes\n", &.{});
}

test "coercion warns: ambiguous datetime only" {
    try expectWarnCodes("day = 2026-07-01\n", &.{.ambiguous_datetime});
    // A full timestamp is unambiguous; prose containing a time never sniffs.
    try expectWarnCodes("when = 2026-07-01T12:00:00Z\n", &.{});
    try expectWarnCodes("note = call mom at 3:30\n", &.{});
}

test "flow-like string warns; markdown links and globs stay silent" {
    try expectWarnCodes("oops = [80, 443] x\n", &.{.flow_like_string});
    try expectWarnCodes("link = [Blog](/Blog.md)\n", &.{});
    try expectWarnCodes("glob = [a-z]*.md\n", &.{});
    try expectWarnCodes("bb = [b]x[/b]\n", &.{});
    // A malformed prefix never parsed as flow, so it doesn't warn either.
    try expectWarnCodes("odd = [80,, 443] x\n", &.{});
    // Flow-element position gets the same treatment.
    try expectWarnCodes("xs = [[80, 443] x, y]\n", &.{.flow_like_string});
    try expectWarnCodes("links = [[Blog](/Blog.md), [Resume](/Resume.md)]\n", &.{});
}

test "missing-comma flow object warns" {
    try expectWarnCodes("p = { x = 1 y = 2 }\n", &.{.flow_missing_comma});
    try expectWarnCodes("p = { x = 1, y = 2 }\n", &.{});
}

test "indent/count lint" {
    // Correct 2×depth indentation and unindented spaced markers: clean.
    try expectWarnCodes("a\n  > b = 1\n", &.{});
    try expectWarnCodes("a\n> b\n> > c = 1\n", &.{});
    // Wrong width, indented root line, tab indent: each warns.
    try expectWarnCodes("a\n > b = 1\n", &.{.indent_marker_mismatch});
    try expectWarnCodes("  a = 1\n", &.{.indent_marker_mismatch});
    try expectWarnCodes("a\n\t> b = 1\n", &.{.indent_marker_mismatch});
    // Comment lines participate (their depth is load-bearing for attachment).
    try expectWarnCodes("a\n  # note\n> b = 1\n", &.{.indent_marker_mismatch});
    try expectWarnCodes("a\n  > # note\n  > b = 1\n", &.{});
}
