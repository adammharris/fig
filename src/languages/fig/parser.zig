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
const AST = @import("../../ast/ast.zig");
const Document = @import("../../document.zig");
const Span = @import("../../util/span.zig");
const datetime = @import("../../util/datetime.zig");
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
    /// A non-final `[]` referenced an empty sequence.
    FigEmptyAppendTarget,
    /// An assignment-final `[]` (`xs[] = v`) — `[]` appends only as a header
    /// (or as a mid-path "last element" step), never as an assignment target.
    FigAppendAssignment,
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
    /// A single-line quoted string closed at its matching quote, but more
    /// non-comment content followed on the same line — the classic
    /// wrapped-a-bare-string-in-unescaped-quotes slip (`k = "She said, "Hi""`).
    /// A quote-specific `FigTrailingContent` that names the bare-string fix.
    FigQuotedTrailingContent,
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
        error.FigAppendAssignment => "a final `[]` appends a container via a header, never a `= value`; write `key[]` on its own line with `> field = value` lines below, or spell the next index out: `key[N] = value`",
        error.FigEmptyContainer => "this container has no children; write an inline empty value instead: `key = {}` (map) or `key = []` (sequence)",
        error.FigInvalidValue => "missing value; write one after `=`, or `{}`/`[]` for an empty container",
        error.FigTypeMismatch => "the value does not satisfy its `: type` annotation; fix the value, or drop/correct the annotation",
        error.FigUnknownType => "unknown type name; the built-in types are int, float, bool, string, enum, char, datetime, date, time",
        error.FigTrailingContent => "unexpected content after this line's value or header; quote the whole value if it is one string (a `#` comment needs a space before it)",
        error.FigQuotedTrailingContent => "this string ends at its matching quote, and the rest of the line is stray content; fig bare strings need no outer quotes — write `key = She said, \"Hey there!\"`, or escape the inner quotes: `\"She said, \\\"Hey there!\\\"\"`",
        error.FigDanglingContinuation => "`+` has no `[]` append header to re-run; move it directly after its `a.b[]` group, or repeat the header",
        error.FigClosedFlowValue => "a value written inline as `[…]`/`{…}` is closed and cannot be extended later; write the block or header form if it needs to grow",
        error.FigUnclosedFlow => "this `[`/`{` value never finds its matching close; close it, or quote the whole value to make it a string",
        error.FigMixedFlowSeparators => "a flow object is fig (`=` pairs) or JSON (`:` pairs), never both in one object",
        error.FigUnclosedString => "unclosed string; add the closing quote (a single-line quote cannot span lines — use `'''` for multi-line)",
        error.FigBadEscape => "invalid escape; double quotes support \\n \\t \\r \\\\ \\\" \\uXXXX — use single quotes ('…') for raw text with literal backslashes",
        error.OutOfMemory => "out of memory",
    };
}

/// A short (few-word) noun phrase for `code` — distinct from `describe`'s full
/// teaching sentence. Meant to sit next to a caret (`^ duplicate key`), the
/// way rustc annotates a span, so a report scanned at a glance still names the
/// problem even with the longer message above it collapsed/scrolled past.
pub fn shortLabel(code: Error) []const u8 {
    return switch (code) {
        error.FigForeignSyntaxColon => "not a value assignment",
        error.FigFlowBareKeyColon => "bare key needs `=`",
        error.FigForeignSyntaxDash => "not a fig element marker",
        error.FigForeignSyntaxBracket => "not a fig header",
        error.FigElementInlineField => "field on element line",
        error.FigRootMarker => "stray `>` marker",
        error.FigSkippedLevel => "skipped nesting level",
        error.FigBadMarkerSeparator => "missing space after marker",
        error.FigBadKey => "invalid key",
        error.FigDuplicateKey => "duplicate key",
        error.FigMixedContainerChildren => "mixed container children",
        error.FigMixedSequenceAddressing => "mixed sequence addressing",
        error.FigKeyNotContainer => "not a container",
        error.FigIndexSkipped => "skipped index",
        error.FigIndexAlreadySet => "index already set",
        error.FigEmptyAppendTarget => "append target is empty",
        error.FigAppendAssignment => "cannot assign to `[]`",
        error.FigEmptyContainer => "empty container",
        error.FigInvalidValue => "missing value",
        error.FigTypeMismatch => "type mismatch",
        error.FigUnknownType => "unknown type",
        error.FigTrailingContent => "trailing content",
        error.FigQuotedTrailingContent => "trailing content after quote",
        error.FigDanglingContinuation => "dangling continuation",
        error.FigClosedFlowValue => "value is closed",
        error.FigUnclosedFlow => "unclosed flow",
        error.FigMixedFlowSeparators => "mixed `=`/`:` separators",
        error.FigUnclosedString => "unclosed string",
        error.FigBadEscape => "invalid escape",
        error.OutOfMemory => "out of memory",
    };
}

/// Shared byte-offset → line/col + `file:line:col:` report rendering — the
/// half of the diagnostic system that has nothing to do with fig's own error
/// codes. Every other language's parser (`json`, and `toml`/`yaml` to come)
/// reuses this same module rather than each growing its own copy — see
/// `src/parse_diagnostic.zig`'s doc comment. `Location`/`locateOffset` are
/// re-exported under their original names so existing call sites
/// (`Parser.locateOffset`, `Parser.Location`, in `main.zig`/`lsp/main.zig`)
/// keep working unchanged.
const parse_diagnostic = @import("../../parse_diagnostic.zig");
pub const Location = parse_diagnostic.Location;
pub const locateOffset = parse_diagnostic.locateOffset;

/// The compiler-style report both severities share: `file:line:col: <label>:
/// <message>`, then the offending source line and a caret marking the column.
/// Caller owns the returned bytes.
fn renderReportAlloc(allocator: Allocator, source: []const u8, offset: usize, file: []const u8, label: []const u8, message: []const u8) Allocator.Error![]u8 {
    return parse_diagnostic.renderReportAlloc(allocator, source, offset, file, label, message);
}

/// A parse failure plus the byte position where the parser stopped. The parser
/// is single-pass, so when an error is returned its cursor sits on (or just
/// after) the offending token — precise enough for `file:line:col` without
/// threading a location through every error site.
pub const Diagnostic = struct {
    code: Error,
    /// Byte offset into the source where parsing stopped — the caret anchor.
    offset: usize,
    /// Byte offset just past the offending token, when the parser knows its
    /// exact extent (e.g. a `: type` value that failed its annotation). Lets an
    /// editor squiggle precisely that token instead of the whole rest of the
    /// line (which would swallow a trailing comment); null means "no known end,
    /// fall back to end-of-line". Always on `offset`'s line — never spans one.
    end: ?usize = null,

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
    /// Byte offset just past the surprising token, when the extent is known
    /// (almost always — a warn fires on a specific value/token). Mirrors
    /// `Diagnostic.end`: lets an editor squiggle exactly that token instead of
    /// running to end-of-line. Always on `offset`'s line; null means "no known
    /// end, fall back to end-of-line".
    end: ?usize = null,

    pub const Code = enum {
        /// A bare token spelling a bool/null from another config language
        /// (`Yes`, `ON`, `TRUE`, `Null`) fell to a plain string — the Norway
        /// class, surfaced instead of silently coerced either way.
        string_looks_like_literal,
        /// A digit-only token with a leading zero (`007`) kept its padding as
        /// a string (the TOML leading-zero rule).
        string_leading_zero,
        /// A number-shaped token that no valid number spelling accepts — a
        /// trailing-dot float (`1.`, `42.`) or a leading-dot float (`.5`,
        /// `.25`) — fell to a string. Narrow by design (only a clean integer +
        /// a single trailing `.`, or a single leading `.` + clean digits), so
        /// version strings (`1.2.3`), prose (`12 monkeys`), and `.e5`/`..`
        /// never warn. Write the missing zero (`0.5`, `1.0`) for the number,
        /// or quote to affirm the string.
        string_looks_like_number,
        /// A bare clock time with no date (`10:30`) sniffed to a datetime
        /// value. Narrower than it first looks: a bare *date* (`2026-07-01`)
        /// no longer warns — that shape is the overwhelmingly common,
        /// deliberate hand-authored case (frontmatter dates, deadlines,
        /// changelog entries), so warning on it was noise, not signal. A bare
        /// time has no such safe majority: `HH:MM[:SS]` is exactly the shape
        /// of a duration, a ratio, or a sports score too, and neither seconds
        /// nor fractional precision discriminate a clock time from those —
        /// there is no unambiguous subset to carve out the way `T`/zone does
        /// for dates. Any value with a `T`/space date-time separator
        /// (`local_datetime`) or a zone (`offset_datetime`) already stays
        /// silent — those separators aren't things prose/durations produce by
        /// coincidence.
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
            .string_looks_like_number => "a bare leading or trailing dot is not a valid number in fig, so this was kept as a string; write the missing zero (`0.5`, `1.0`) for a number, or quote it to affirm the string",
            .ambiguous_datetime => "a bare clock time becomes a datetime value, not text (also a duration/ratio shape); quote it if you meant a string",
            .flow_like_string => "this looks like a `[…]`/`{…}` flow value with trailing content, so the whole line was read as one bare string; remove the trailing content for a collection, or quote the value to affirm the string",
            .flow_missing_comma => "a bare flow value containing ` = ` usually means a missing comma between pairs; add the comma, or quote the value if it really is text",
            .indent_marker_mismatch => "indentation disagrees with the `>` marker count (convention: 2 spaces per level); meaning follows the count — fix whichever signal is wrong",
        };
    }

    /// A short (few-word) noun phrase for `code` — distinct from
    /// `describeWarning`'s full teaching sentence. See the top-level
    /// `shortLabel` (for `Diagnostic`'s `Error` codes) for why this exists
    /// alongside it: a caret annotation, rustc-style.
    pub fn shortLabel(code: Code) []const u8 {
        return switch (code) {
            .string_looks_like_literal => "looks like a boolean/null",
            .string_leading_zero => "leading zero",
            .string_looks_like_number => "leading/trailing dot",
            .ambiguous_datetime => "ambiguous datetime",
            .flow_like_string => "looks like a flow value",
            .flow_missing_comma => "missing comma",
            .indent_marker_mismatch => "indent/marker mismatch",
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
    /// Every parse error, in source order — populated ONLY by the recovering
    /// entry point (`parseCollecting`), which skips past each failure to the
    /// next line and keeps going, so a language server can squiggle a whole
    /// file's mistakes at once (and `check` can list them in one pass). The
    /// single-shot `parse`/`parseWithReport` stop at the first error and leave
    /// this empty, setting `diag` alone. When non-empty, `diag` mirrors
    /// `errors[0]`. Allocated with the caller's allocator; the caller owns it.
    errors: []const Diagnostic = &.{},
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
/// The offending token's end offset, paired with `fail_offset` (set via
/// `failSpan`) — populates `Diagnostic.end` so an editor can squiggle exactly
/// that token. Null for the point-only error sites (caret alone).
fail_end: ?usize = null,
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
/// Error-recovery mode: when set, `run` catches each per-line failure into
/// `diagnostics` and resyncs to the next line instead of returning the first
/// error. Off by default — `parse`/`parseWithReport` keep their single-shot
/// contract; `parseCollecting` turns it on. `error.OutOfMemory` is never
/// recovered (it is not a document defect).
recover: bool = false,
/// Recoverable parse errors, in source order (arena-backed; duped out to the
/// caller's `Report.errors` by `parseImpl`). Populated only in `recover` mode;
/// empty otherwise.
diagnostics: std.ArrayList(Diagnostic) = .empty,
/// `PendingContainer.reentries` resolved to built node ids during AST
/// assembly (arena-backed; duped out to `Document.reentry_headers`). Empty
/// unless some header re-opened an existing container.
built_reentries: std.ArrayList(Document.ReentryHeader) = .empty,

// ── Intermediate tree types ─────────────────────────────────────────────────

/// A container whose shape (map vs. sequence) is frozen the moment its first
/// child is added — root and every header/element-opener target start here.
const PendingContainer = struct {
    kind: enum { undecided, mapping, sequence } = .undecided,
    /// Created by a flow value (`[…]`/`{…}`) — closed to later extension via
    /// dotted paths, headers, or indexing (the TOML inline-table rule).
    closed: bool = false,
    /// Created by a header-final `[]` append (or a `+` re-run of one). Those
    /// elements are pre-committed to map shape at birth, which would bypass
    /// the `.undecided` → `FigEmptyContainer` check at frame close — this flag
    /// lets the close path apply the same "no empty block containers" rule.
    born_of_append: bool = false,
    mapping: Mapping = .{},
    sequence: Sequence = .{},
    /// Byte offsets (source order) of every LATER header line whose final path
    /// segment re-OPENED this container (DESIGN.md "re-entering a path to add
    /// new keys is fine") — the header-line positions the owning `TNode.span`
    /// cannot carry, since it is stamped once at creation. Only header-FINAL
    /// re-opens are recorded: a header/assignment whose final segment CREATES
    /// something new anchors its own line through that new node's span, and a
    /// mid-path re-open always rides a line anchored by its final segment one
    /// way or the other. Threaded out to `Document.reentry_headers` (keyed by
    /// built node id) during AST assembly, so `Editor(Fig)`'s region gather
    /// can remove/relocate every physical header occurrence.
    reentries: std.ArrayList(usize) = .empty,

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
    /// The explicit `: type =` annotation, recorded as a cross-format type tag
    /// (`ast.node_tags`) so the annotation round-trips through `fig fmt`. Set by
    /// `applyKnownType`/`parseAssignedValue`; applied in `buildNode`. Null for an
    /// untyped value (`key = value`).
    tag: ?AST.Tag = null,
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
    allocator.free(parsed.reentry_headers);
    return parsed.ast;
}

pub fn parse(allocator: Allocator, input: []const u8, format: Type) Error!Document {
    return parseImpl(allocator, input, format, null, false);
}

/// `parse`, but also fills `out`: `diag` on failure (error code + byte offset,
/// for `file:line:col` teaching messages), `warnings` always (authoring-time
/// lints, allocated with `allocator` — the caller owns/frees them). The hook
/// the CLI (and eventually the C ABI) renders reports from.
pub fn parseWithReport(allocator: Allocator, input: []const u8, format: Type, out: *Report) Error!Document {
    return parseImpl(allocator, input, format, out, false);
}

/// `parseWithReport`, but recovers past each error to collect the WHOLE file's
/// diagnostics in one pass (`out.errors`, source order) rather than stopping at
/// the first — the entry a language server wants, so every mistake squiggles at
/// once. On any error the return value is still the first error code and the
/// tree is NOT built (both consumers discard it); a clean parse returns the
/// Document exactly as `parseWithReport` would. `out.diag` mirrors `errors[0]`.
pub fn parseCollecting(allocator: Allocator, input: []const u8, format: Type, out: *Report) Error!Document {
    return parseImpl(allocator, input, format, out, true);
}

fn parseImpl(allocator: Allocator, input: []const u8, format: Type, out: ?*Report, recover: bool) Error!Document {
    _ = format;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    var self: Parser = .{ .allocator = arena_state.allocator(), .source = input, .recover = recover };
    // Warnings are duped out on every exit path (they are valid alongside a
    // failure too). Best-effort under OOM — the tree, not the lint list, is
    // the load-bearing result. Runs before the arena defer (LIFO), while
    // `self.warnings` is still alive.
    defer if (out) |o| {
        o.warnings = allocator.dupe(Warning, self.warnings.items) catch &.{};
    };
    self.run() catch |err| {
        // Non-recover mode (or an unrecoverable OOM in recover mode): the first
        // error is the whole story — report it and stop.
        if (out) |o| o.diag = .{ .code = err, .offset = self.fail_offset orelse self.pos, .end = self.fail_end };
        return err;
    };

    // Recover mode collected its errors into `self.diagnostics` instead of
    // returning them. If any fired, the tree may be malformed, so skip building
    // it: surface every diagnostic (source order) and return the first code, so
    // callers that branch on "did it parse?" behave exactly as before.
    if (self.diagnostics.items.len > 0) {
        if (out) |o| {
            o.diag = self.diagnostics.items[0];
            o.errors = allocator.dupe(Diagnostic, self.diagnostics.items) catch &.{};
        }
        return self.diagnostics.items[0].code;
    }

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
    errdefer allocator.free(node_spans);
    const reentry_headers = try allocator.dupe(Document.ReentryHeader, self.built_reentries.items);

    return .{ .source = input, .ast = ast, .node_spans = node_spans, .reentry_headers = reentry_headers };
}

/// Return `err` with the diagnostic caret pinned to `offset` — for the sites
/// where the cursor has already scanned past the token that actually offends
/// (e.g. the `:` of `key: value`, consumed before the missing `=` is noticed).
fn failAt(self: *Parser, offset: usize, err: Error) Error {
    self.fail_offset = offset;
    return err;
}

/// Like `failAt`, but also pins the offending token's end (`start..end`) so the
/// diagnostic carries a tight range — an editor squiggles exactly that token
/// instead of running to end-of-line and swallowing a trailing comment.
fn failSpan(self: *Parser, start: usize, end: usize, err: Error) Error {
    self.fail_offset = start;
    self.fail_end = end;
    return err;
}

/// Record an authoring-time lint anchored at `offset`, with no known token end
/// (the squiggle falls back to end-of-line). Prefer `warnAt` when the offending
/// token's extent is known — most warn sites know it.
fn warn(self: *Parser, code: Warning.Code, offset: usize) Error!void {
    try self.warnings.append(self.allocator, .{ .code = code, .offset = offset });
}

/// Record an authoring-time lint spanning `[start, end)` — a precise token
/// extent so an editor squiggles exactly that token instead of the whole line.
fn warnAt(self: *Parser, code: Warning.Code, start: usize, end: usize) Error!void {
    try self.warnings.append(self.allocator, .{ .code = code, .offset = start, .end = end });
}

// ── Main line loop ──────────────────────────────────────────────────────────

fn run(self: *Parser) Error!void {
    while (self.pos < self.source.len) {
        const line_start = self.pos;
        self.cur_line_start = line_start;
        self.processLine(line_start) catch |err| {
            // In recover mode, a per-line failure is recorded and the scanner
            // resyncs to the next line so the rest of the file still reports.
            // OOM is never a document defect — always propagate it. Outside
            // recover mode nothing changes: the first error stops the parse.
            if (!self.recover or err == error.OutOfMemory) return err;
            try self.recordRecoverable(err, line_start);
        };
    }
    // Container-close and comment-drain that trail the last line. A failure
    // here (e.g. an empty container at EOF) recovers the same way, but with no
    // line left to resync to — recording it is enough, and `parseImpl` will
    // bail before building the (now-known-malformed) tree.
    self.finishRun() catch |err| {
        if (!self.recover or err == error.OutOfMemory) return err;
        try self.recordRecoverable(err, self.source.len);
    };
}

/// One physical line: indent lint, blank/comment shortcuts, then the content
/// dispatch. Factored out of `run` so the loop can wrap exactly one line in the
/// recovery catch (the blank/comment "skip this line" paths just `return`).
fn processLine(self: *Parser, line_start: usize) Error!void {
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
        return;
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
        // Squiggle from the first post-indent char through the marker run
        // (`self.pos` sits past it after `scanMarkers`) — the two signals that
        // disagree — instead of running to end-of-line.
        if (tabbed or indent.len != 2 * m.depth) try self.warnAt(.indent_marker_mismatch, line_start + indent.len, self.pos);
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
            return;
        }
    }
    try self.processContentLine(m.depth, m.star);
}

/// Trailing work after the last line is consumed: close every still-open frame
/// back to root, and flush any dangling comments to the root.
fn finishRun(self: *Parser) Error!void {
    try self.closeFramesAbove(0);
    for (self.pending_leading.items) |pc| {
        try self.root_dangling.append(self.allocator, pc.comment);
    }
    self.pending_leading.clearRetainingCapacity();
}

/// Record a recoverable error at its diagnostic offset, then resync the scanner
/// past the offending line so the loop keeps making progress.
fn recordRecoverable(self: *Parser, err: Error, line_start: usize) Error!void {
    try self.diagnostics.append(self.allocator, .{ .code = err, .offset = self.fail_offset orelse self.pos, .end = self.fail_end });
    // Consumed — do not leak this failure's anchors into the next line's report.
    self.fail_offset = null;
    self.fail_end = null;
    self.recoverToNextLine(line_start);
}

/// Resync to the start of the line after the one the failure began on, so the
/// loop keeps reporting. `line_start` (the current line's true start) anchors
/// this — NOT the raw cursor, which for a late-detected error (a duplicate key
/// noticed only after its line's newline was consumed) already sits at the next
/// line's start; scanning from there would swallow that still-unread line.
fn recoverToNextLine(self: *Parser, line_start: usize) void {
    // End (then start-of-next) of the line the failure began on.
    var eol = line_start;
    while (eol < self.source.len and self.source[eol] != '\n') eol += 1;
    const next = if (eol < self.source.len) eol + 1 else eol;
    if (self.pos <= next) {
        // A single-line failure — the cursor is still on this line, or resting
        // exactly at the next line's start (the late-detection case above).
        // Resume at `next`: the failed line is skipped, the following one kept.
        self.pos = next;
    } else {
        // The failing construct (a `'''` string / `[`…`]` flow) already
        // consumed past this line — resume after wherever it stopped, so its
        // body isn't re-scanned as if each physical line were a fresh entry.
        var at = self.pos;
        while (at < self.source.len and self.source[at] != '\n') at += 1;
        self.pos = if (at < self.source.len) at + 1 else at;
    }
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
        // A `[]`-appended element was pre-committed to map shape at birth, so
        // the `.undecided` check above never sees it — but one that closes
        // with zero entries is the same authoring mistake, and errors the same.
        if (frame.container.born_of_append and frame.container.mapping.entries.items.len == 0) return error.FigEmptyContainer;
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
            // `consumeLineEnd` above has already advanced `self.pos` past this
            // line's newline (onto the START of the next line) — the default
            // "current cursor" anchor would misattribute the diagnostic to
            // whatever follows. Pin it to the actual conflicting key's own
            // span instead.
            if (self.findEntry(m, k.name) != null) return self.failSpan(k.span.start, k.span.end, error.FigDuplicateKey);
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
                // `xs[] = v` is not assignable: `[]` appends only as a header
                // (or as a mid-path "last element" step) — a `= value` on it
                // has no defined target, so it is a teaching error whether the
                // sequence is empty or not. (`xs[N] = v` with N == the current
                // length is the explicit-append spelling; see `.literal` above.)
                .append_or_last => return error.FigAppendAssignment,
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
                // A header re-opening an existing container: record this
                // line's position on it (see `PendingContainer.reentries`).
                try c.reentries.append(self.allocator, k.span.start);
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
                        // An `xs[i]` header re-opening an existing element —
                        // the index-addressed twin of the `.key` re-open
                        // above. No key span exists for an index step; the
                        // line start is the same-line anchor the region
                        // gather needs.
                        try c.reentries.append(self.allocator, self.cur_line_start);
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
                    child.* = .{ .born_of_append = true };
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
        if (std.mem.eql(u8, t, "string")) {
            // `: string =` selects the raw-text sub-parser AND records the tag, so
            // the annotation round-trips and `fig fmt` can re-emit the value bare
            // (the annotation turns sniffing off on re-read — no re-quoting needed).
            var node = try self.parseUntypedValue(true);
            node.tag = .{ .kind = .string };
            return node;
        }
        const res = self.scanBareRestOfLine();
        if (res.text.len == 0) return error.FigInvalidValue;
        // `scanBareRestOfLine` has parked `pos` at end-of-line (past any trailing
        // comment), so a raw `pos` anchor would point the caret INTO the comment.
        // Pin the diagnostic to the value's own span instead — that is what
        // failed its annotation, and what an editor should squiggle.
        const vspan = self.spanOf(res.text);
        var node = self.applyKnownType(t, res.text) catch |err| return self.failSpan(vspan.start, vspan.end, err);
        node.span = vspan;
        if (res.comment) |cm| node.trailing = .{ .text = cm };
        return node;
    }
    return self.parseUntypedValue(false);
}

/// `force_string_bare`: set only for `: string =`, where the ENTIRE RHS is one
/// raw text run — the annotation is a TOTAL SINK that selects the raw-text
/// sub-parser (DESIGN.md "annotation selects the sub-parser"), turning off
/// sniffing, flow commitment AND the quote forms. Quote characters are literal
/// content (`x: string = "hi"` is the four-character string `"hi"`),
/// backslashes are literal (no escape processing), and a `'''`/`"""` opener is
/// content too — an author who wants escapes or multiline drops the annotation
/// and quotes normally. The trailing-`#`-comment rule is exactly the bare
/// rule (`scanBareRestOfLine`): a quote-led RHS behaves identically to a bare
/// one.
fn parseUntypedValue(self: *Parser, force_string_bare: bool) Error!TNode {
    if (force_string_bare) {
        // So `x: string = [ 1 + 2 ]` is the string `[ 1 + 2 ]`, never a
        // sequence — the quote-free escape hatch that needs no interior
        // escaping. (`fig fmt` re-emits the value bare so the form round-trips,
        // dropping the tag when the value has no bare spelling.)
        const res = self.scanBareRestOfLine();
        if (res.text.len == 0) return error.FigInvalidValue;
        var node: TNode = .{ .value = .{ .string = res.text }, .span = self.spanOf(res.text) };
        if (res.comment) |cm| node.trailing = .{ .text = cm };
        return node;
    }
    const c = self.peek() orelse return error.FigInvalidValue;
    switch (c) {
        '\'' => return self.parseQuotedOrTriple('\''),
        '"' => return self.parseQuotedOrTriple('"'),
        '[', '{' => {
            // Commitment is decided by the shape of the WHOLE RHS, not just the
            // first char (DESIGN.md "Committed values"): a balanced `[…]`/`{…}`
            // with trailing content — a markdown link, glob, regex — was never
            // flow, so it is a bare string, left unquoted.
            if (tok.classifyBracketCommit(self.source, self.pos) == .bare_trailing) {
                const vstart = self.pos;
                if (try self.flowLikePrefix(vstart)) {
                const close = tok.bracketCloseIndex(self.source, vstart) orelse vstart;
                try self.warnAt(.flow_like_string, vstart, close + 1);
            }
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
            var node: TNode = try self.sniffToNodeWarned(res.text, vstart);
            if (res.comment) |cm| node.trailing = .{ .text = cm };
            return node;
        },
    }
}

fn parseQuotedOrTriple(self: *Parser, q: u8) Error!TNode {
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
    // A single-line quote that closed early with more content on the line is
    // almost always a bare string wrapped in unescaped quotes (`k = "a "b""`).
    // Remap the generic trailing-content error to the quote-specific message
    // that names the bare-string fix; `scanTrailingCommentOnly` has already
    // parked `self.pos` on the stray content, so the caret lands there.
    const t = self.scanTrailingCommentOnly() catch |err| switch (err) {
        error.FigTrailingContent => return self.failAt(self.pos, error.FigQuotedTrailingContent),
        else => |e| return e,
    };
    if (t) |c| node.trailing = .{ .text = c };
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
    const end = offset + text.len; // the exact token extent, for a tight squiggle
    switch (node.value) {
        .string => {
            if (looksLikeLiteral(text)) {
                try self.warnAt(.string_looks_like_literal, offset, end);
            } else if (looksLikeLeadingZero(text)) {
                try self.warnAt(.string_leading_zero, offset, end);
            } else if (looksLikeTrailingDotNumber(text) or looksLikeLeadingDotNumber(text)) {
                try self.warnAt(.string_looks_like_number, offset, end);
            }
        },
        // Quietly, and only when ambiguous: a bare clock time reads as a
        // duration/ratio/score as easily as a time-of-day. A bare *date*
        // (`local_date`) does not warn — in hand-authored config it is
        // overwhelmingly a deliberate date (frontmatter, deadlines, changelog
        // entries), so flagging it was warn-fatigue on the common case, not a
        // catch on the rare one. A `T`/zone-carrying timestamp
        // (`local_datetime`/`offset_datetime`) is unambiguous (nobody types
        // `T` or `+HH:MM` mid-sentence) and stays silent too.
        .extended => |e| switch (e.kind) {
            .local_time => try self.warnAt(.ambiguous_datetime, offset, end),
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

/// `1.`-style: a clean integer followed by a single trailing dot (`1.`, `42.`,
/// `-3.`) — a number that fell to a string because no fig float spelling has a
/// bare trailing dot. Deliberately NARROW: the part before the dot must sniff
/// as a *decimal integer*, so a version string (`1.2.3`), a leading-zero token
/// (`09.`, already number-ish but not a clean int), and prose (`12 monkeys`)
/// never warn — only the "sig fig" trailing-dot case the coerce-with-`: float`
/// message addresses.
fn looksLikeTrailingDotNumber(text: []const u8) bool {
    if (text.len < 2 or text[text.len - 1] != '.') return false;
    const head = text[0 .. text.len - 1];
    const n = tok.sniffNumber(head) orelse return false;
    return n.kind == .integer;
}

/// `.5`-style: a single leading dot followed by clean digits only (`.5`,
/// `.25`) — the shorthand-float habit no fig number spelling accepts (and
/// `: float` does not coerce; the fix is writing the zero: `0.5`). As
/// deliberately NARROW as the trailing-dot twin above: `.5.6`, `.e5`, `..`, a
/// lone `.`, and a signed `-.5` never warn.
fn looksLikeLeadingDotNumber(text: []const u8) bool {
    if (text.len < 2 or text[0] != '.') return false;
    for (text[1..]) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

/// Explicit typing (`key: type = value`): the annotation is checked and
/// coercing, and now also STORED as a cross-format type tag (`ast.node_tags`)
/// so it round-trips (DESIGN.md "Explicit typing"). The value's VERBATIM lexeme
/// is kept as the node's `raw`/`text` — the coercion normalizers below run only
/// to *validate* (a genuine mismatch still errors), never to rewrite the bytes,
/// so `1.`/`09` survive exactly. `enum`/`datetime` map to distinct `extended`
/// node kinds that self-annotate on print, so they carry no tag.
fn applyKnownType(self: *Parser, type_name: []const u8, text: []const u8) Error!TNode {
    if (std.mem.eql(u8, type_name, "int")) {
        if (tok.sniffNumber(text)) |n| {
            if (n.kind != .integer) return error.FigTypeMismatch;
            return .{ .value = .{ .number = .{ .raw = text, .kind = .integer } }, .tag = .{ .kind = .integer } };
        }
        // Coercion opt-in: a leading-zero decimal (`09`, `007`) is a *string*
        // when bare (the Leading-zero rule), but `: int` is the author
        // overriding that default. Validate the shape (null → mismatch); keep the
        // authored lexeme verbatim so the padding round-trips.
        if ((try self.normalizeDecimal(text)) != null)
            return .{ .value = .{ .number = .{ .raw = text, .kind = .integer } }, .tag = .{ .kind = .integer } };
        return error.FigTypeMismatch;
    }
    if (std.mem.eql(u8, type_name, "float")) {
        if (std.mem.eql(u8, text, "inf") or std.mem.eql(u8, text, "-inf") or std.mem.eql(u8, text, "nan")) {
            return .{ .value = .{ .extended = .{ .kind = .number_special, .text = text } } };
        }
        if (tok.sniffNumber(text)) |_|
            return .{ .value = .{ .number = .{ .raw = text, .kind = .float } }, .tag = .{ .kind = .float } };
        // Coercion opt-in: a trailing-dot (`1.`) or leading-zero (`09`) token is
        // a string when bare, but `: float` overrides. Validate the shape (null →
        // mismatch); keep the authored lexeme verbatim (`1.` stays `1.`).
        if ((try self.normalizeCoercedFloat(text)) != null)
            return .{ .value = .{ .number = .{ .raw = text, .kind = .float } }, .tag = .{ .kind = .float } };
        return error.FigTypeMismatch;
    }
    if (std.mem.eql(u8, type_name, "bool")) {
        if (std.mem.eql(u8, text, "true")) return .{ .value = .{ .boolean = true }, .tag = .{ .kind = .boolean } };
        if (std.mem.eql(u8, text, "false")) return .{ .value = .{ .boolean = false }, .tag = .{ .kind = .boolean } };
        return error.FigTypeMismatch;
    }
    if (std.mem.eql(u8, type_name, "enum")) {
        if (text.len == 0) return error.FigTypeMismatch;
        return .{ .value = .{ .extended = .{ .kind = .enum_literal, .text = text } } };
    }
    if (std.mem.eql(u8, type_name, "char")) {
        // `: char = 'A'` — a single ZON-style char literal. The annotation is the
        // disambiguator (like `enum`/`float`): it turns a `'…'` RHS, which is a
        // length-1 string bare, into a `char_literal` extended scalar. Reusing the
        // Zig char codec keeps escapes (`'\n'`, `'\u{1F600}'`) working for free.
        // Stored as the decimal codepoint — the cross-format `char_literal`
        // invariant (see AST `ExtKind.char_literal`) — allocated in the parse arena
        // like `normalizeDecimal`, so the builder dupes it into the AST's strings.
        const cp: u21 = switch (std.zig.string_literal.parseCharLiteral(text)) {
            .success => |c| c,
            .failure => return error.FigTypeMismatch,
        };
        const raw = try std.fmt.allocPrint(self.allocator, "{d}", .{cp});
        return .{ .value = .{ .extended = .{ .kind = .char_literal, .text = raw } } };
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

/// Normalize a decimal-integer token that `sniffNumber` rejected only for its
/// leading zero (`09`, `007`, `-00`) into a valid integer raw: sign preserved
/// (`+` dropped), leading zeros stripped to at least one digit. Returns null if
/// the post-sign body isn't purely decimal digits (so a genuine mismatch still
/// errors). Arena-allocated; the builder dupes it into the AST's owned strings.
fn normalizeDecimal(self: *Parser, text: []const u8) Error!?[]const u8 {
    var i: usize = 0;
    const negative = text.len > 0 and text[0] == '-';
    if (text.len > 0 and (text[0] == '+' or text[0] == '-')) i = 1;
    const body = text[i..];
    if (body.len == 0) return null;
    for (body) |ch| if (!std.ascii.isDigit(ch)) return null;
    var start: usize = 0;
    while (start + 1 < body.len and body[start] == '0') start += 1; // keep ≥1 digit
    const digits = body[start..];
    return try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ if (negative) "-" else "", digits });
}

/// Normalize a token `: float` accepts by coercion but `sniffNumber` rejects:
/// a trailing-dot integer (`1.` → `1.0`) or a leading-zero decimal (`09` →
/// `9.0`). Returns null when neither shape applies (a real mismatch → error).
fn normalizeCoercedFloat(self: *Parser, text: []const u8) Error!?[]const u8 {
    // Trailing dot: `1.` — the head must be a clean decimal integer body.
    if (text.len >= 2 and text[text.len - 1] == '.') {
        if (try self.normalizeDecimal(text[0 .. text.len - 1])) |digits|
            return try std.fmt.allocPrint(self.allocator, "{s}.0", .{digits});
        return null;
    }
    // Leading-zero decimal in float position: `09` → `9.0`.
    if (try self.normalizeDecimal(text)) |digits|
        return try std.fmt.allocPrint(self.allocator, "{s}.0", .{digits});
    return null;
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
            if (try self.flowLikePrefix(vstart)) {
                const close = tok.bracketCloseIndex(self.source, vstart) orelse vstart;
                try self.warnAt(.flow_like_string, vstart, close + 1);
            }
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
    if (std.mem.indexOf(u8, text, " = ")) |i| try self.warnAt(.flow_missing_comma, vstart + i + 1, vstart + i + 2);
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
    // An empty (or comments-only) document leaves the root `undecided`. Fig has
    // no bare-scalar root, and an empty mapping is the natural seed for a fresh
    // file (`fig set new.figl k v` lands its first key into it), so coerce the
    // root to an empty map rather than raising the `FigEmptyContainer` error a
    // childless *nested* container still (correctly) does — the map/sequence
    // ambiguity that error guards against only bites once a key or `*` names a
    // real child, which the root here has none of.
    if (self.root.kind == .undecided) self.root.kind = .mapping;
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
    if (node.tag) |tag| try b.setTag(id, tag);
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
            const id = try b.addMappingFromEntries(kv_ids.items);
            try self.recordReentries(c, id);
            return .{ .id = id, .end = end };
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
            const id = try b.addSequence(ids.items);
            try self.recordReentries(c, id);
            return .{ .id = id, .end = end };
        },
    }
}

/// Resolve `c`'s recorded re-entry header-line offsets (if any) to the built
/// node id `id` — the `PendingContainer` → `Document.reentry_headers` bridge.
fn recordReentries(self: *Parser, c: *const PendingContainer, id: AST.Node.Id) Error!void {
    for (c.reentries.items) |off| {
        try self.built_reentries.append(self.allocator, .{ .node_id = id, .content_start = off });
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

test "empty document is an empty root map (seedable for a from-scratch `set`)" {
    // No bare-scalar root and no map/sequence ambiguity to resolve (there are no
    // children), so an empty file is the empty map `set new.figl k v` seeds into.
    try expectParse("", .{ .allocator = testing.allocator, .root = 0, .nodes = &.{
        .{ .id = 0, .kind = .{ .mapping = null } },
    } });
    // A comments-only / whitespace-only file is likewise an empty root map, not
    // the `FigEmptyContainer` a childless *nested* container still raises.
    try expectParse("# just a note\n", .{ .allocator = testing.allocator, .root = 0, .nodes = &.{
        .{ .id = 0, .kind = .{ .mapping = null } },
    } });
    try expectParse("\n\n  \n", .{ .allocator = testing.allocator, .root = 0, .nodes = &.{
        .{ .id = 0, .kind = .{ .mapping = null } },
    } });
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

test "reentry_headers records every header-final re-open, keyed by node id" {
    const src = "database\n> x = 1\nother = 1\ndatabase\n> y = 2\n";
    const parsed = try parse(testing.allocator, src, .Fig);
    defer parsed.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), parsed.reentry_headers.len);
    const rh = parsed.reentry_headers[0];
    const db = try parsed.ast.getValByPath(&.{.{ .key = "database" }});
    try testing.expectEqual(db.id, rh.node_id);
    // Anchored at the SECOND "database" header line (the re-open), which the
    // creating line's span cannot carry.
    try testing.expectEqual(std.mem.lastIndexOf(u8, src, "database").?, rh.content_start);
}

test "reentry_headers is empty without re-entry" {
    const parsed = try parse(testing.allocator, "database\n> x = 1\ndatabase.pool\n> y = 2\n", .Fig);
    defer parsed.deinit(testing.allocator);
    // `database.pool` CREATES pool (anchored by pool's own span) — a deeper
    // dotted path is not a re-open of `database` itself.
    try testing.expectEqual(@as(usize, 0), parsed.reentry_headers.len);
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

test "char literal via explicit typing → char_literal codepoint" {
    var ast = try parseAbstract(testing.allocator,
        \\letter: char = 'A'
        \\tab: char = '\t'
        \\quote: char = '\''
        \\emoji: char = '\u{1F600}'
        \\hash: char = '#'
    , .Fig);
    defer ast.deinit();
    // `: char =` reads a ZON-style char literal (escapes included) and stores the
    // decimal Unicode codepoint — the cross-format `char_literal` invariant.
    const cases = .{
        .{ "letter", "65" }, // 'A'
        .{ "tab", "9" }, // '\t'
        .{ "quote", "39" }, // '\''
        .{ "emoji", "128512" }, // '\u{1F600}'
        .{ "hash", "35" }, // '#' — a `#` glued inside quotes is not a comment
    };
    inline for (cases) |c| {
        const node = try ast.getValByPath(&.{.{ .key = c[0] }});
        try testing.expect(node.kind.extended.kind == .char_literal);
        try testing.expectEqualStrings(c[1], node.kind.extended.text);
    }
}

test "char literal rejects a non-char lexeme" {
    // A bare (unquoted) atom is not a char literal — quotes are the disambiguator.
    try testing.expectError(error.FigTypeMismatch, parseAbstract(testing.allocator, "x: char = A\n", .Fig));
    // Two codepoints in one literal is not a char.
    try testing.expectError(error.FigTypeMismatch, parseAbstract(testing.allocator, "x: char = 'ab'\n", .Fig));
}

test "explicit typing coerces number lookalikes but keeps the verbatim lexeme + tag" {
    var ast = try parseAbstract(testing.allocator,
        \\a: float = 1.
        \\b: int = 09
        \\c: float = 09
        \\d: int = -007
        \\e: string = [ 1 + 2 ]
    , .Fig);
    defer ast.deinit();
    // `: float`/`: int` accept a trailing-dot / leading-zero lexeme (bare-sniffing
    // rejects them), but the VERBATIM bytes are kept as the number raw — the
    // annotation is stored as a type tag, so both the lexeme and the `: type`
    // surface round-trip through `fig fmt`.
    const a = try ast.getValByPath(&.{.{ .key = "a" }});
    try testing.expect(a.kind.number.kind == .float);
    try testing.expectEqualStrings("1.", a.kind.number.raw);
    try testing.expect(ast.node_tags[a.id].?.kind == .float);
    const b = try ast.getValByPath(&.{.{ .key = "b" }});
    try testing.expect(b.kind.number.kind == .integer);
    try testing.expectEqualStrings("09", b.kind.number.raw);
    try testing.expect(ast.node_tags[b.id].?.kind == .integer);
    try testing.expectEqualStrings("09", (try ast.getValByPath(&.{.{ .key = "c" }})).kind.number.raw);
    try testing.expectEqualStrings("-007", (try ast.getValByPath(&.{.{ .key = "d" }})).kind.number.raw);
    // `: string` is a total sink: the bracketed RHS is verbatim text, not flow.
    const e = try ast.getValByPath(&.{.{ .key = "e" }});
    try testing.expectEqualStrings("[ 1 + 2 ]", e.kind.string);
    try testing.expect(ast.node_tags[e.id].?.kind == .string);
}

test ": string takes the ENTIRE RHS as raw text — quotes, backslashes, triple-quotes are content" {
    var ast = try parseAbstract(testing.allocator,
        \\a: string = "hello"
        \\b: string = 42
        \\c: string = a\nb
        \\d: string = '''
        \\e: string = 'single'
        \\f: string = """
    , .Fig);
    defer ast.deinit();
    // Quote characters are literal content: `a` is the SEVEN-character string
    // `"hello"` — no quote form exists under the annotation.
    try testing.expectEqualStrings("\"hello\"", (try ast.getValByPath(&.{.{ .key = "a" }})).kind.string);
    // Sniffing is off: a number lexeme is the string of its digits (unchanged).
    try testing.expectEqualStrings("42", (try ast.getValByPath(&.{.{ .key = "b" }})).kind.string);
    // Backslashes are literal — no escape processing (`a\nb` is four characters).
    try testing.expectEqualStrings("a\\nb", (try ast.getValByPath(&.{.{ .key = "c" }})).kind.string);
    // A triple-quote opener is content too: no multiline form under the
    // annotation (drop the annotation and quote normally for that).
    try testing.expectEqualStrings("'''", (try ast.getValByPath(&.{.{ .key = "d" }})).kind.string);
    try testing.expectEqualStrings("'single'", (try ast.getValByPath(&.{.{ .key = "e" }})).kind.string);
    try testing.expectEqualStrings("\"\"\"", (try ast.getValByPath(&.{.{ .key = "f" }})).kind.string);
    // Every one still records the `: string` tag.
    inline for (.{ "a", "b", "c", "d", "e", "f" }) |k| {
        const n = try ast.getValByPath(&.{.{ .key = k }});
        try testing.expect(ast.node_tags[n.id].?.kind == .string);
    }
}

test ": string quote-led RHS follows the BARE trailing-comment rule" {
    // A quote-led raw RHS behaves identically to a bare one: ` # ` after
    // whitespace opens a comment; a `#` glued to non-whitespace stays literal.
    var ast = try parseAbstract(testing.allocator,
        \\a: string = "hi" # note
        \\b: string = "x"#y
    , .Fig);
    defer ast.deinit();
    const a = try ast.getValByPath(&.{.{ .key = "a" }});
    try testing.expectEqualStrings("\"hi\"", a.kind.string);
    try testing.expectEqualStrings("note", ast.comments(a.id).trailing.?.text);
    try testing.expectEqualStrings("\"x\"#y", (try ast.getValByPath(&.{.{ .key = "b" }})).kind.string);
}

test ": string = \"hello\" is equivalent to the escaped-quote untagged spelling" {
    // The spec's §5.3 equivalence: `str: string = "hello"` ≡ `str = "\"hello\""`
    // (same VALUE; the first additionally records the type tag).
    var tagged = try parseAbstract(testing.allocator, "str: string = \"hello\"\n", .Fig);
    defer tagged.deinit();
    var quoted = try parseAbstract(testing.allocator, "str = \"\\\"hello\\\"\"\n", .Fig);
    defer quoted.deinit();
    const t = try tagged.getValByPath(&.{.{ .key = "str" }});
    const q = try quoted.getValByPath(&.{.{ .key = "str" }});
    try testing.expectEqualStrings("\"hello\"", t.kind.string);
    try testing.expectEqualStrings(t.kind.string, q.kind.string);
    try testing.expect(tagged.eql(quoted));
}

test "type-mismatch diagnostic anchors on the value span, not the trailing comment" {
    // A scalar-annotation failure (via `applyKnownType`, which runs AFTER the
    // line — incl. its comment — was scanned) must point at the VALUE, with a
    // tight end before the `#`.
    const cases = [_]struct { src: []const u8, value: []const u8 }{
        .{ .src = "x: int = hello # note\n", .value = "hello" },
        .{ .src = "y: bool = maybe # note\n", .value = "maybe" },
    };
    for (cases) |c| {
        var report: Report = .{};
        try testing.expectError(error.FigTypeMismatch, parseWithReport(testing.allocator, c.src, .Fig, &report));
        defer testing.allocator.free(report.warnings);
        const d = report.diag.?;
        // Caret sits at the value start, and the end stops at the value end —
        // never inside the ` # note` comment.
        const vstart = std.mem.indexOf(u8, c.src, c.value).?;
        try testing.expectEqual(vstart, d.offset);
        try testing.expect(d.end != null);
        try testing.expectEqual(vstart + c.value.len, d.end.?);
        try testing.expect(d.end.? < std.mem.indexOfScalar(u8, c.src, '#').?);
    }
}

test "parseCollecting recovers past each error and reports them all" {
    // Five distinct failures on five lines, with a clean line between two of
    // them — a language server wants every squiggle, not just the first. The
    // scanner must resync to the next line after each and keep going.
    const src =
        \\good = 1
        \\bad1: int = hello
        \\key: value
        \\fine = ok
        \\dup = 1
        \\dup = 2
        \\> orphan = 3
    ;
    var report: Report = .{};
    try testing.expectError(error.FigTypeMismatch, parseCollecting(testing.allocator, src, .Fig, &report));
    defer testing.allocator.free(report.errors);
    defer testing.allocator.free(report.warnings);
    // FigTypeMismatch (l2), FigForeignSyntaxColon (l3), FigDuplicateKey (l6),
    // FigRootMarker (l7) — the clean lines 1/4/5 do not add entries.
    try testing.expectEqual(@as(usize, 4), report.errors.len);
    try testing.expectEqual(Error.FigTypeMismatch, report.errors[0].code);
    try testing.expectEqual(Error.FigForeignSyntaxColon, report.errors[1].code);
    try testing.expectEqual(Error.FigDuplicateKey, report.errors[2].code);
    try testing.expectEqual(Error.FigRootMarker, report.errors[3].code);
    // `diag` mirrors the first error for single-error consumers.
    try testing.expectEqual(Error.FigTypeMismatch, report.errors[0].code);
    try testing.expect(report.diag != null);
    try testing.expectEqual(Error.FigTypeMismatch, report.diag.?.code);
    // Source order: each diagnostic sits on a later line than the last.
    var prev: usize = 0;
    for (report.errors) |d| {
        const loc = d.locate(src);
        try testing.expect(loc.line > prev);
        prev = loc.line;
    }
}

test "parseCollecting on a clean file returns the tree with no errors" {
    var report: Report = .{};
    const doc = try parseCollecting(testing.allocator, "a = 1\nb = two\n", .Fig, &report);
    defer doc.deinit(testing.allocator);
    defer testing.allocator.free(report.errors);
    defer testing.allocator.free(report.warnings);
    try testing.expectEqual(@as(usize, 0), report.errors.len);
    try testing.expect(report.diag == null);
    try testing.expectEqualStrings("1", (try doc.ast.getValByPath(&.{.{ .key = "a" }})).kind.number.raw);
}

test "committed values error rather than falling back to string" {
    try testing.expectError(error.FigUnclosedFlow, parseAbstract(testing.allocator, "ports = [80, 443\n", .Fig));
}

test "a single-line quote that closes early with trailing content is the quote-specific error" {
    // The classic slip: a bare string wrapped in unescaped outer quotes. The
    // quote committed, closed at its match, and left `Hey there!""` stray — a
    // quote-specific `FigTrailingContent` that names the bare-string fix.
    try testing.expectError(error.FigQuotedTrailingContent, parseAbstract(testing.allocator, "she = \"She said, \"Hey there!\"\"\n", .Fig));
    try testing.expectError(error.FigQuotedTrailingContent, parseAbstract(testing.allocator, "x = 'a' b\n", .Fig));
    // A clean quoted string with a genuine trailing comment is still fine.
    var ok = try parseAbstract(testing.allocator, "x = \"hi\"  # note\n", .Fig);
    defer ok.deinit();
    try testing.expectEqualStrings("hi", (try ok.getValByPath(&.{.{ .key = "x" }})).kind.string);
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

test "assignment-final [] is not assignable" {
    // `[]` appends only as a header (or mid-path step); `xs[] = v` is the
    // teaching error whether the sequence is empty…
    try testing.expectError(error.FigAppendAssignment, parseAbstract(testing.allocator, "xs[] = 1\n", .Fig));
    // …or already has elements (this used to silently REPLACE the last one).
    try testing.expectError(error.FigAppendAssignment, parseAbstract(testing.allocator, "xs[0] = 1\nxs[] = 2\n", .Fig));
    // The fixes the message names both work: the explicit next index appends…
    var ast = try parseAbstract(testing.allocator, "xs[0] = 1\nxs[1] = 2\n", .Fig);
    defer ast.deinit();
    try testing.expectEqualStrings("2", (try ast.getValByPath(&.{ .{ .key = "xs" }, .{ .index = 1 } })).kind.number.raw);
    // …and a mid-path `[]` ("the last element") still navigates fine.
    var mid = try parseAbstract(testing.allocator, "xs[]\n> a = 1\nxs[].b = 2\n", .Fig);
    defer mid.deinit();
    try testing.expectEqualStrings("2", (try mid.getValByPath(&.{ .{ .key = "xs" }, .{ .index = 0 }, .{ .key = "b" } })).kind.number.raw);
}

test "a non-final [] on an empty sequence is still the empty-append error" {
    // The other `FigEmptyAppendTarget` site (mid-path navigation) is unaffected
    // by the assignment-final ruling.
    try testing.expectError(error.FigEmptyAppendTarget, parseAbstract(testing.allocator, "xs[].a = 1\n", .Fig));
}

test "an []-appended element that closes empty is an empty container" {
    // Append-created elements are pre-committed to map shape at birth, but an
    // element with zero entries errors like every other empty block container —
    // closed by a following sibling line, at EOF, and with only a comment body.
    try testing.expectError(error.FigEmptyContainer, parseAbstract(testing.allocator, "xs[]\nb = 1\n", .Fig));
    try testing.expectError(error.FigEmptyContainer, parseAbstract(testing.allocator, "xs[]\n", .Fig));
    try testing.expectError(error.FigEmptyContainer, parseAbstract(testing.allocator, "xs[]\n> # note\n", .Fig));
    // A `+` re-run creates an element the same way — an empty one errors too.
    try testing.expectError(error.FigEmptyContainer, parseAbstract(testing.allocator, "xs[]\n> a = 1\n+\n", .Fig));
    // Every element getting fields keeps `[]` headers and `+` chains working.
    var ast = try parseAbstract(testing.allocator, "xs[]\n> a = 1\n+\n> a = 2\n", .Fig);
    defer ast.deinit();
    try testing.expectEqualStrings("1", (try ast.getValByPath(&.{ .{ .key = "xs" }, .{ .index = 0 }, .{ .key = "a" } })).kind.number.raw);
    try testing.expectEqualStrings("2", (try ast.getValByPath(&.{ .{ .key = "xs" }, .{ .index = 1 }, .{ .key = "a" } })).kind.number.raw);
}

test "content glued to a + is a key line, and + is not a bare-key char" {
    // `isPlusLine` only claims a LONE `+`; anything glued falls through to the
    // key path, where `+` cannot start (or appear in) a bare key.
    try testing.expectError(error.FigBadKey, parseAbstract(testing.allocator, "xs[]\n> a = 1\n+glued = 2\n", .Fig));
    try testing.expectError(error.FigBadKey, parseAbstract(testing.allocator, "+x\n", .Fig));
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
    const src = @embedFile("testdata/kitchen_sink.figl");
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
    const rendered = try report.diag.?.renderAlloc(testing.allocator, src, "app.figl");
    defer testing.allocator.free(rendered);
    try testing.expect(std.mem.startsWith(u8, rendered, "app.figl:1:"));
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
    // A trailing-dot number lookalike (`1.`) falls to a string and warns —
    // narrow, so version strings and prose stay silent.
    try expectWarnCodes("sig = 1.\n", &.{.string_looks_like_number});
    try expectWarnCodes("neg = -3.\n", &.{.string_looks_like_number});
    try expectWarnCodes("ver = 1.2.3\n", &.{});
    // The real literals, prose, quotes, and annotations never warn.
    try expectWarnCodes("ok = true\nn = null\nx = 0\nhex = 0xFF\n", &.{});
    try expectWarnCodes("real = 1.0\n", &.{});
    try expectWarnCodes("movie = 12 monkeys\ntitle = Yes Prime Minister\n", &.{});
    try expectWarnCodes("flag = \"true\"\n", &.{});
    try expectWarnCodes("norway: string = Yes\n", &.{});
    // A `: float` coercion silences the trailing-dot warn (the author opted in).
    try expectWarnCodes("sig: float = 1.\n", &.{});
}

test "leading-dot number lookalike falls to a string and warns" {
    // `.5` is still the string it spells — the warn surfaces the surprise.
    try expectWarnCodes("dot = .5\n", &.{.string_looks_like_number});
    try expectWarnCodes("q = .25\n", &.{.string_looks_like_number});
    var ast = try parseAbstract(testing.allocator, "dot = .5\n", .Fig);
    defer ast.deinit();
    try testing.expectEqualStrings(".5", (try ast.getValByPath(&.{.{ .key = "dot" }})).kind.string);
    // As narrow as the trailing-dot detector: only a single `.` + clean digits.
    try expectWarnCodes("v = .5.6\n", &.{});
    try expectWarnCodes("e = .e5\n", &.{});
    try expectWarnCodes("d = ..\n", &.{});
    try expectWarnCodes("s = -.5\n", &.{});
    // `: float` does NOT coerce a leading dot (no fig number spelling has one) —
    // the warn's advice must therefore be "write the zero", not `: float =`.
    try testing.expectError(error.FigTypeMismatch, parseAbstract(testing.allocator, "x: float = .5\n", .Fig));
}

test "coercion warns: ambiguous bare time only" {
    // A bare date is the common, deliberate case (frontmatter, deadlines) —
    // no warn.
    try expectWarnCodes("day = 2026-07-01\n", &.{});
    // A bare time collides with duration/ratio/score shapes — warns, with or
    // without seconds (precision doesn't disambiguate it from those).
    try expectWarnCodes("meet = 10:30\n", &.{.ambiguous_datetime});
    try expectWarnCodes("split = 10:30:00\n", &.{.ambiguous_datetime});
    // A `T`/zone-carrying timestamp is unambiguous; prose containing a time
    // never sniffs (the whole token has to match, not a substring).
    try expectWarnCodes("when = 2026-07-01T12:00:00Z\n", &.{});
    try expectWarnCodes("local = 2026-07-01T12:00:00\n", &.{});
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
