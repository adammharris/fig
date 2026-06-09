//! YAML tokenizer

const Tokenizer = @This();

const std = @import("std");
const testing = std.testing;
const Type = @import("yaml.zig").Type;

pub const Token = @import("../token.zig").Token(Kind);

pub const Kind = enum {
    // Structural
    indent,
    dedent,
    newline,
    dash,
    colon,
    explicit_key, // `?` explicit (complex) key indicator
    comma, // `,` flow entry separator
    flow_seq_start, // `[`
    flow_seq_end, // `]`
    flow_map_start, // `{`
    flow_map_end, // `}`
    scalar,
    comment,
    whitespace,
    block_header, // `|`/`>` plus chomping/indent indicators
    block_scalar, // raw body lines of a block scalar
    doc_start, // `---` document start marker
    doc_end, // `...` document end marker
    end_of_file,

    pub fn len(self: Kind) ?usize {
        return switch (self) {
            .end_of_file, .dedent => 0,
            .newline, .dash, .colon, .explicit_key, .comma, .flow_seq_start, .flow_seq_end, .flow_map_start, .flow_map_end => 1,
            else => null,
        };
    }
};

const TokenizeError = error{ InvalidIndent, TabIndent, InvalidBlockHeader, OutOfMemory, UnclosedString };

const Line = struct {
    start: usize,
    content_start: usize, // if blank line, equals end
    end: usize, // excludes newline
    newline_end: usize, // includes newline if present
    fn isBlank(self: *const Line) bool {
        return self.content_start == self.end;
    }
};

tokens: std.ArrayList(Token) = .empty,
i: usize = 0,
pending_block: ?PendingBlock = null,
flow_depth: usize = 0,
// Indentation of the line on which the outermost flow collection opened, and
// whether that collection is the document root. Continuation lines inside flow
// must be more indented than this (except the closing bracket, and the root,
// which has no indentation floor).
flow_open_indent: usize = 0,
flow_root: bool = false,

allocator: std.mem.Allocator,
source: []const u8 = "",
type: Type = .v1_2_2,

const PendingBlock = struct {
    /// Indentation (column) of the line the header sits on. Block content must
    /// be more indented than this, and the explicit-indent indicator is counted
    /// relative to it.
    header_indent: usize,
    explicit_indent: ?usize,
    /// True when the block scalar is the document root (`>`/`|` or `--- >`),
    /// whose content may sit at column 0; it ends only at a doc marker or EOF.
    root: bool = false,
};

pub fn tokenize(self: *Tokenizer) ![]const Token {
    errdefer self.tokens.deinit(self.allocator);
    try self.tokens.ensureTotalCapacity(self.allocator, self.source.len + 1);

    var current_indent: usize = 0;
    var indent_stack: std.ArrayList(usize) = .empty;
    defer indent_stack.deinit(self.allocator);
    try indent_stack.append(self.allocator, 0);

    // YAML is whitespace-sensitive, so we parse line-by-line.
    while (try self.getLine()) |line| {
        if (line.isBlank()) continue;

        // A line that is only whitespace (including tabs after the leading
        // spaces) is blank in any context. Inside flow it folds away as trivia;
        // in block context it does not participate in indentation structure.
        // Skipping it before the flow indentation rule keeps a tab on an
        // otherwise-empty line inside flow from looking like under-indented
        // content.
        if (lineAllWhitespace(self.source, line)) continue;

        // Inside a flow collection (`[`/`{`), indentation is not significant in
        // the block sense, but a few constraints still apply.
        if (self.flow_depth > 0) {
            // A document marker may not appear inside a flow collection; emit it
            // so the parser rejects it where it stands.
            if (line.content_start == line.start) {
                if (self.docMarker(line)) |kind| {
                    const cs = line.content_start;
                    try self.addToken(.init(kind, .init(cs, cs + 3)));
                    if (line.newline_end > line.end) {
                        try self.addToken(.init(.newline, .init(line.end, line.newline_end)));
                    }
                    continue;
                }
            }
            // Flow content must be more indented than the line the collection
            // opened on; only the closing bracket may sit at that indentation.
            const indent = line.content_start - line.start;
            const first = self.source[line.content_start];
            if (!self.flow_root and first != ']' and first != '}' and indent <= self.flow_open_indent) {
                return TokenizeError.InvalidIndent;
            }
            try self.tokenizeLineContent(line);
            if (self.i == line.newline_end and line.newline_end > line.end) {
                try self.addToken(.init(.newline, .init(line.end, line.newline_end)));
            }
            continue;
        }

        // A comment-only line does not participate in indentation structure;
        // emit just the comment (the parser treats it as trivia) and move on,
        // so an indented comment produces no spurious indent/dedent.
        if (self.source[line.content_start] == '#') {
            try self.addToken(.init(.comment, .init(line.content_start, line.end)));
            if (line.newline_end > line.end) {
                try self.addToken(.init(.newline, .init(line.end, line.newline_end)));
            }
            continue;
        }

        const indent = line.content_start - line.start;
        if (indent > current_indent) {
            try indent_stack.append(self.allocator, indent);
            try self.addToken(.init(.indent, .init(line.start, line.content_start)));
            current_indent = indent;
        } else if (indent < current_indent) {
            while (indent < current_indent) {
                _ = indent_stack.pop();
                current_indent = indent_stack.getLast();
                try self.addToken(.fixed(.dedent, line.content_start));
            }
            if (indent != current_indent) return TokenizeError.InvalidIndent;
        }

        // Document markers (`---`, `...`) are only recognized at column 0.
        // Any dedents above have already closed open containers.
        if (indent == 0) {
            if (self.docMarker(line)) |kind| {
                const cs = line.content_start;
                try self.addToken(.init(kind, .init(cs, cs + 3)));
                // Tokenize any content sharing the marker's line (e.g. `--- foo`).
                var rest = cs + 3;
                while (rest < line.end and isBlank(self.source[rest])) rest += 1;
                if (rest < line.end) {
                    try self.tokenizeLineContent(.{
                        .start = rest,
                        .content_start = rest,
                        .end = line.end,
                        .newline_end = line.newline_end,
                    });
                }
                if (self.i == line.newline_end) {
                    if (line.newline_end > line.end) {
                        try self.addToken(.init(.newline, .init(line.end, line.newline_end)));
                    }
                    try self.flushPendingBlock();
                }
                continue;
            }
        }

        // A tab in the indentation of a block mapping key or sequence entry is
        // using the tab as structural indentation, which YAML forbids. (A tab
        // before plain-scalar content is separation and is allowed.)
        if (self.tabIndentedStructure(line)) return TokenizeError.TabIndent;

        try self.tokenizeLineContent(line);
        if (self.i == line.newline_end) {
            if (line.newline_end > line.end) {
                try self.addToken(.init(.newline, .init(line.end, line.newline_end)));
            }
            try self.flushPendingBlock();
        }
    }

    while (indent_stack.items.len != 0) {
        _ = indent_stack.pop();
        if (indent_stack.items.len == 0) break;
        try self.addToken(.fixed(.dedent, self.i));
    }

    try self.addToken(.fixed(.end_of_file, self.i));
    return try self.tokens.toOwnedSlice(self.allocator);
}

fn getLine(self: *Tokenizer) TokenizeError!?Line {
    if (self.i >= self.source.len) return null;

    const start = self.i;
    while (self.i < self.source.len and self.source[self.i] != '\n') {
        self.i += 1;
    }

    const end = self.i;
    if (self.i < self.source.len and self.source[self.i] == '\n') {
        self.i += 1;
    }

    // Indentation is leading spaces only. A tab after them is separation or
    // scalar content (YAML forbids tabs *as* indentation, but allows them as
    // whitespace between/within nodes), so it is handled downstream, not here.
    var content_start = start;
    while (content_start < end and self.source[content_start] == ' ') {
        content_start += 1;
    }

    return .{
        .start = start,
        .content_start = content_start,
        .end = end,
        .newline_end = self.i,
    };
}

fn tokenizeLineContent(self: *Tokenizer, line_in: Line) TokenizeError!void {
    var line = line_in;
    var cursor = line.content_start;
    var at_content_start = true;

    while (cursor < line.end) {
        switch (self.source[cursor]) {
            ' ', '\t' => {
                const end = whitespaceEnd(self.source, cursor, line.end);
                try self.addToken(.init(.whitespace, .init(cursor, end)));
                cursor = end;
            },
            '#' => {
                // A `#` starts a comment only at the start of content or when
                // preceded by whitespace; otherwise (e.g. `]#x`, `,#x`) it is
                // ordinary scalar text.
                if (cursor == line.content_start or isBlank(self.source[cursor - 1])) {
                    try self.addToken(.init(.comment, .init(cursor, line.end)));
                    return;
                }
                try self.handlePlain(cursor, &line, &cursor, &at_content_start);
            },
            ':' => {
                // A colon is a mapping value indicator only when followed by
                // whitespace or the end of line. Otherwise (e.g. `http://x`)
                // it is part of a plain scalar. In flow, a `:` may also abut a
                // JSON-style key (a quoted scalar or a flow collection) with no
                // separating space (`"key":value`).
                if (colonIsIndicator(self.source, cursor, line.end, self.flow_depth > 0) or self.jsonKeyColon()) {
                    try self.addToken(.fixed(.colon, cursor));
                    cursor += 1;
                    // After a value indicator we are at the start of the value
                    // node, so a following `-`/`?` is an indicator (`k: - a` is a
                    // compact block sequence).
                    at_content_start = true;
                } else {
                    try self.handlePlain(cursor, &line, &cursor, &at_content_start);
                }
            },
            '[' => {
                if (self.flow_depth == 0) self.openFlow(line);
                try self.addToken(.fixed(.flow_seq_start, cursor));
                self.flow_depth += 1;
                cursor += 1;
                at_content_start = false;
            },
            '{' => {
                if (self.flow_depth == 0) self.openFlow(line);
                try self.addToken(.fixed(.flow_map_start, cursor));
                self.flow_depth += 1;
                cursor += 1;
                at_content_start = false;
            },
            ']' => {
                try self.addToken(.fixed(.flow_seq_end, cursor));
                if (self.flow_depth > 0) self.flow_depth -= 1;
                cursor += 1;
                at_content_start = false;
            },
            '}' => {
                try self.addToken(.fixed(.flow_map_end, cursor));
                if (self.flow_depth > 0) self.flow_depth -= 1;
                cursor += 1;
                at_content_start = false;
            },
            ',' => {
                if (self.flow_depth > 0) {
                    try self.addToken(.fixed(.comma, cursor));
                    cursor += 1;
                    at_content_start = false;
                } else {
                    try self.handlePlain(cursor, &line, &cursor, &at_content_start);
                }
            },
            '\'', '"' => {
                // Continuation lines of a multi-line quoted scalar must out-indent
                // the line it sits on — except a root scalar, or one written on
                // its own line (where the floor is the parent, which we don't
                // track here, so we skip the check rather than over-reject).
                const floor: ?usize = if (self.precededOnlyByTrivia() or cursor == line.content_start)
                    null
                else
                    line.content_start - line.start;
                const end = try self.multilineQuotedEnd(cursor, floor);
                if (end > line.end) {
                    // The quoted scalar ran onto following lines. Emit it whole,
                    // then continue tokenizing the rest of its closing line.
                    try self.addToken(.init(.scalar, .init(cursor, end)));
                    line = self.remainderLine(end);
                    self.i = line.newline_end;
                    cursor = end;
                    at_content_start = false;
                    continue;
                }
                try self.addScalar(cursor, end);
                cursor = end;
                at_content_start = false;
            },
            '|', '>' => {
                // A `|`/`>` in value position begins a block scalar. Block
                // scalars do not occur inside flow, so there it is plain text.
                // (Anywhere else `|`/`>` is swallowed by scalarEnd before
                // reaching this switch, so the current byte being `|`/`>` means
                // we are at value start.)
                if (self.flow_depth == 0) {
                    if (blockHeaderEnd(self.source, cursor, line.end)) |hdr_end| {
                        // A header preceded only by a doc marker / trivia is the
                        // document root (`>` or `--- >`); its body may sit at col 0.
                        // Check before emitting the header token itself.
                        const root = self.precededOnlyByTrivia();
                        try self.addToken(.init(.block_header, .init(cursor, hdr_end)));
                        var rest = hdr_end;
                        while (rest < line.end and isBlank(self.source[rest])) rest += 1;
                        if (rest < line.end and self.source[rest] == '#') {
                            try self.addToken(.init(.comment, .init(rest, line.end)));
                        }
                        self.pending_block = .{
                            .header_indent = line.content_start - line.start,
                            .explicit_indent = explicitIndent(self.source, cursor, hdr_end),
                            .root = root,
                        };
                        return;
                    }
                    // At value start (outside flow) a `|`/`>` can only be a block
                    // header; one with a malformed indicator (`|0`, `|10`, doubled
                    // chomping) is invalid — a plain scalar may not begin with it.
                    return TokenizeError.InvalidBlockHeader;
                }
                try self.handlePlain(cursor, &line, &cursor, &at_content_start);
            },
            '-' => {
                // A dash is a sequence entry indicator only at the start of a
                // node and when followed by whitespace or end of line. It is
                // never an entry indicator inside flow. Otherwise (e.g. `-3`) it
                // begins a plain scalar.
                if (self.flow_depth == 0 and at_content_start and followedByBlank(self.source, cursor, line.end)) {
                    // A block sequence `-` separated from a preceding `?`/`:` by a
                    // tab uses the tab as the new collection's indentation, which
                    // is forbidden (`?\t-`, `:\t-`).
                    if (cursor > line.content_start and self.source[cursor - 1] == '\t') return TokenizeError.TabIndent;
                    try self.addToken(.fixed(.dash, cursor));
                    cursor += 1;
                    // A dash starts a node, so a nested `-`/`?` right after it is
                    // also an indicator (`- - c` is a nested sequence).
                    at_content_start = true;
                } else {
                    try self.handlePlain(cursor, &line, &cursor, &at_content_start);
                }
            },
            '?' => {
                // A `?` is an explicit-key indicator at the start of a node (or
                // anywhere in flow) when followed by whitespace or end of line.
                // `at_content_start` stays true: the key that follows may itself
                // begin with an indicator (e.g. `? - a`). Otherwise (e.g. `?x`)
                // it is ordinary plain text.
                if ((self.flow_depth > 0 or at_content_start) and followedByBlank(self.source, cursor, line.end)) {
                    try self.addToken(.fixed(.explicit_key, cursor));
                    cursor += 1;
                } else {
                    try self.handlePlain(cursor, &line, &cursor, &at_content_start);
                }
            },
            else => try self.handlePlain(cursor, &line, &cursor, &at_content_start),
        }
    }

    // When a multi-line scalar advanced us onto a later line, that line's break
    // belongs to us; emit it here. Callers detect this via `self.i` having moved
    // past the original line and skip their own newline handling.
    if (line.start != line_in.start and line.newline_end > line.end) {
        try self.addToken(.init(.newline, .init(line.end, line.newline_end)));
    }
}

/// Builds a Line for the remainder of the source starting at `pos` (used to
/// resume tokenizing the closing line of a multi-line scalar).
/// True when `line` puts a tab in its indentation region (right after the
/// leading spaces) and then begins a block mapping key or sequence entry — i.e.
/// the tab is being used as structural indentation, which is invalid.
fn tabIndentedStructure(self: *const Tokenizer, line: Line) bool {
    const cs = line.content_start;
    if (cs >= line.end or self.source[cs] != '\t') return false;

    var ws = cs;
    while (ws < line.end and isBlank(self.source[ws])) ws += 1;
    if (ws >= line.end) return false;

    const fc = self.source[ws];
    if (fc == '-' and (ws + 1 >= line.end or isBlank(self.source[ws + 1]))) return true;
    const se = scalarEnd(self.source, ws, line.end, false);
    return se < line.end and self.source[se] == ':';
}

fn remainderLine(self: *const Tokenizer, pos: usize) Line {
    var end = pos;
    while (end < self.source.len and self.source[end] != '\n') end += 1;
    const newline_end = if (end < self.source.len) end + 1 else end;
    return .{ .start = pos, .content_start = pos, .end = end, .newline_end = newline_end };
}

const PlainContinuation = struct { content_end: usize, last_line: Line };

/// Emits a plain scalar starting at `start`. If it reaches end of line in block
/// context, it may continue onto more-indented following lines (a multi-line
/// plain scalar), which are gathered into one token; the parser folds the breaks.
fn handlePlain(self: *Tokenizer, start: usize, line: *Line, cursor: *usize, at_content_start: *bool) TokenizeError!void {
    const flow = self.flow_depth > 0;
    if (flow) {
        // A plain scalar inside flow may fold across line breaks; gather it whole.
        const fend = self.flowPlainEnd(start);
        if (fend > start) try self.addToken(.init(.scalar, .init(start, fend)));
        if (fend > line.end) {
            // The scalar ran onto following lines; resume on the line it ended on.
            line.* = self.remainderLine(fend);
            self.i = line.newline_end;
        }
        cursor.* = fend;
        at_content_start.* = false;
        return;
    }
    const end = scalarEnd(self.source, start, line.end, flow);
    // Only a genuine plain scalar continues; a "scalar" that begins with a block
    // or flow indicator (e.g. a malformed `> text` header) is not plain text, so
    // gathering it would mask the error.
    if (!flow and end == line.end and plainContinuationStart(self.source[start])) {
        const indent = line.content_start - line.start;
        // A root scalar (the whole document) has no indentation floor; an inline
        // value's continuation must out-indent the key line it sits on; a value
        // written on its own line (`key:\n  v`) may have continuation lines at
        // its own indent, so the floor is one less.
        const floor: ?usize = if (self.precededOnlyByTrivia() and start == line.content_start)
            null
        else if (start == line.content_start)
            (if (indent > 0) indent - 1 else 0)
        else
            indent;
        if (try self.gatherPlainContinuation(line.*, floor)) |g| {
            try self.addToken(.init(.scalar, .init(start, g.content_end)));
            line.* = g.last_line;
            cursor.* = g.last_line.end;
            at_content_start.* = false;
            return;
        }
    }
    try self.addScalar(start, end);
    cursor.* = end;
    at_content_start.* = false;
}

/// Scans the lines following a plain scalar to see whether it continues onto
/// more-indented plain-text lines. Returns the span end (trimmed end of the last
/// continuation line) and that line, or null if there is no continuation. Sets
/// `self.i` to resume after the last continuation line.
fn gatherPlainContinuation(self: *Tokenizer, line: Line, floor: ?usize) TokenizeError!?PlainContinuation {
    var probe = line.newline_end;
    var result: ?PlainContinuation = null;

    while (probe < self.source.len) {
        const line_start = probe;
        var end = line_start;
        while (end < self.source.len and self.source[end] != '\n') end += 1;
        const newline_end = if (end < self.source.len) end + 1 else end;

        var spaces = line_start;
        while (spaces < end and self.source[spaces] == ' ') spaces += 1;
        var ws = line_start;
        while (ws < end and isBlank(self.source[ws])) ws += 1;

        // Blank lines are interior fold breaks; include them only if a real
        // continuation line follows (handled by not advancing `result`).
        if (ws == end) {
            probe = newline_end;
            continue;
        }

        // Indentation is the leading spaces; a following tab is separation that
        // the parser's fold strips. Under-indentation ends the continuation.
        if (floor) |f| if (spaces - line_start <= f) break;
        const fc = self.source[ws];
        if (!plainContinuationLineStart(fc)) break;
        // A leading sequence/explicit-key/value indicator starts a structure.
        if ((fc == '-' or fc == '?' or fc == ':') and
            (ws + 1 >= end or isBlank(self.source[ws + 1]))) break;
        // A colon or comment anywhere makes this a mapping entry or comment, not
        // a pure plain continuation.
        if (scalarEnd(self.source, ws, end, false) != end) break;

        result = .{
            .content_end = trimRightSpaces(self.source, ws, end),
            .last_line = .{ .start = line_start, .content_start = spaces, .end = end, .newline_end = newline_end },
        };
        probe = newline_end;
    }

    if (result) |r| self.i = r.last_line.newline_end;
    return result;
}

/// Scans a plain scalar inside a flow collection, which (unlike a block plain
/// scalar) may fold across line breaks freely. Returns the trimmed end of the
/// scalar's content — which may lie on a later line. The scan stops at a flow
/// indicator (`,`/`[`/`]`/`{`/`}` or a `:` value indicator), a comment, a
/// document marker at column 0, or EOF. The parser folds the captured breaks.
fn flowPlainEnd(self: *const Tokenizer, start: usize) usize {
    const source = self.source;
    var i = start;
    var last_content = start; // exclusive end of the last non-blank byte seen
    while (i < source.len) {
        switch (source[i]) {
            '\n' => {
                if (self.docMarkerAt(i + 1)) break;
                i += 1;
                while (i < source.len and (source[i] == ' ' or source[i] == '\t')) i += 1;
                // A comment line (`#` at the start of a continuation line) breaks
                // a flow plain scalar; it cannot resume after the comment.
                if (i < source.len and source[i] == '#') break;
            },
            ',', '[', ']', '{', '}' => break,
            ':' => {
                // A `:` is a value indicator (and so ends the scalar) when
                // followed by whitespace/EOL or, in flow, a `,`/`]`/`}`.
                const next: u8 = if (i + 1 < source.len) source[i + 1] else 0;
                if (next == 0 or next == ' ' or next == '\t' or next == '\n' or
                    next == ',' or next == ']' or next == '}') break;
                i += 1;
                last_content = i;
            },
            '#' => {
                if (i > start and isBlank(source[i - 1])) break;
                i += 1;
                last_content = i;
            },
            else => |c| {
                i += 1;
                if (!isBlank(c)) last_content = i;
            },
        }
    }
    return last_content;
}

/// True when `c` can begin a plain-scalar continuation line (i.e. it is not an
/// indicator that would start a different kind of node).
fn plainContinuationStart(c: u8) bool {
    return switch (c) {
        '#', '[', ']', '{', '}', ',', '\'', '"', '&', '*', '!', '|', '>', '@', '`', '%' => false,
        else => true,
    };
}

/// Whether a continuation line of an already-open block plain scalar may begin
/// with `c`. Unlike the node-start rule above, the scalar is already running, so
/// indicators that are special only at node start (`!`, `&`, `*`, quotes,
/// brackets, `|`, `>`, `@`, `%`, ...) are ordinary plain content here. Only a
/// line-leading `#` (a comment) breaks the scalar; the caller separately handles
/// a `-`/`?`/`:`+space structure indicator and an embedded `:` value indicator.
fn plainContinuationLineStart(c: u8) bool {
    return c != '#';
}

fn addToken(self: *Tokenizer, token: Token) TokenizeError!void {
    try self.tokens.append(self.allocator, token);
}

fn addScalar(self: *Tokenizer, start: usize, end: usize) TokenizeError!void {
    const trimmed_end = trimRightSpaces(self.source, start, end);
    if (trimmed_end > start) {
        try self.addToken(.init(.scalar, .init(start, trimmed_end)));
    }
}

fn scalarEnd(source: []const u8, start: usize, line_end: usize, flow: bool) usize {
    var end = start;
    while (end < line_end) : (end += 1) {
        switch (source[end]) {
            // A colon ends the scalar only when it is a value indicator,
            // i.e. followed by whitespace or end of line.
            ':' => if (colonIsIndicator(source, end, line_end, flow)) break,
            // A `#` begins a comment only when preceded by whitespace.
            '#' => if (end > start and isBlank(source[end - 1])) break,
            // Flow indicators terminate a plain scalar inside a flow collection.
            ',', '[', ']', '{', '}' => if (flow) break,
            else => {},
        }
    }
    return end;
}

/// In flow context, a `:` directly following a JSON-style key — a quoted scalar
/// or a closed flow collection — is a value indicator even without a separating
/// space (`{"a":1}`). Checks the previous emitted token so a literal quote inside
/// a plain scalar (`ab":c`) is not mistaken for a quoted key.
fn jsonKeyColon(self: *const Tokenizer) bool {
    if (self.flow_depth == 0) return false;
    // Skip trivia back to the last real token; in flow the key and its `:` may
    // be separated by line breaks and comments.
    var idx = self.tokens.items.len;
    while (idx > 0) : (idx -= 1) switch (self.tokens.items[idx - 1].kind) {
        .whitespace, .newline, .comment => {},
        else => break,
    };
    if (idx == 0) return false;
    const prev = self.tokens.items[idx - 1];
    return switch (prev.kind) {
        .flow_seq_end, .flow_map_end => true,
        .scalar => blk: {
            const s = prev.source(self.source);
            break :blk s.len > 0 and (s[0] == '"' or s[0] == '\'');
        },
        else => false,
    };
}

/// A `:` is a mapping value indicator when followed by whitespace/EOL, or — in
/// flow context — when followed by a flow indicator (`,`/`]`/`}`).
fn colonIsIndicator(source: []const u8, i: usize, line_end: usize, flow: bool) bool {
    if (followedByBlank(source, i, line_end)) return true;
    if (!flow) return false;
    return switch (source[i + 1]) {
        ',', ']', '}' => true,
        else => false,
    };
}

fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t';
}

fn lineAllWhitespace(source: []const u8, line: Line) bool {
    var i = line.content_start;
    while (i < line.end) : (i += 1) {
        if (!isBlank(source[i])) return false;
    }
    return true;
}

/// Detects a document marker (`---` or `...`) occupying its own column-0 line.
/// The three marker bytes must be followed by whitespace or end of line.
fn docMarker(self: *const Tokenizer, line: Line) ?Kind {
    const cs = line.content_start;
    if (line.end - cs < 3) return null;
    const c = self.source[cs];
    if (c != '-' and c != '.') return null;
    if (self.source[cs + 1] != c or self.source[cs + 2] != c) return null;
    if (cs + 3 != line.end and !isBlank(self.source[cs + 3])) return null;
    return if (c == '-') .doc_start else .doc_end;
}

/// True when the byte after `i` is whitespace or `i` is the last byte on the line.
fn followedByBlank(source: []const u8, i: usize, line_end: usize) bool {
    return i + 1 >= line_end or isBlank(source[i + 1]);
}

/// If a block-scalar header (`|`/`>` plus optional chomping/indent indicators)
/// occupies the rest of the line, returns the index just past the indicators.
/// The indicators may be followed only by whitespace and/or a comment.
fn blockHeaderEnd(source: []const u8, start: usize, line_end: usize) ?usize {
    var i = start + 1;
    var seen_chomp = false;
    var seen_indent = false;
    while (i < line_end) : (i += 1) {
        switch (source[i]) {
            '+', '-' => {
                if (seen_chomp) return null;
                seen_chomp = true;
            },
            '1'...'9' => {
                if (seen_indent) return null;
                seen_indent = true;
            },
            else => break,
        }
    }
    const indicators_end = i;
    while (i < line_end and isBlank(source[i])) i += 1;
    if (i < line_end) {
        // The only thing allowed after the indicators is a comment, and a `#`
        // is a comment only when separated from the indicators by whitespace.
        if (source[i] != '#' or i == indicators_end) return null;
    }
    return indicators_end;
}

/// Extracts the explicit indentation indicator digit from a header, if present.
fn explicitIndent(source: []const u8, start: usize, header_end: usize) ?usize {
    var i = start + 1;
    while (i < header_end) : (i += 1) {
        if (source[i] >= '1' and source[i] <= '9') return source[i] - '0';
    }
    return null;
}

fn openFlow(self: *Tokenizer, line: Line) void {
    self.flow_open_indent = line.content_start - line.start;
    // A flow collection that is the whole document — nothing but a `---` marker
    // and trivia precedes it — is the root node, which has no indentation floor
    // for its content.
    self.flow_root = self.precededOnlyByTrivia();
}

fn flushPendingBlock(self: *Tokenizer) TokenizeError!void {
    const info = self.pending_block orelse return;
    self.pending_block = null;
    try self.consumeBlockBody(info);
}

/// Consumes the indented body lines of a block scalar (already past the header
/// line's newline) and emits a single `block_scalar` token spanning them. The
/// body runs until the first non-blank line indented no more than the content
/// indentation; blank lines are always included so chomping can see them.
fn consumeBlockBody(self: *Tokenizer, info: PendingBlock) TokenizeError!void {
    const body_start = self.i;
    var content_indent: ?usize = if (info.explicit_indent) |d| info.header_indent + d else null;
    // While auto-detecting, the largest indentation seen on a leading empty
    // line: it is an error for one to be more indented than the first content
    // line (YAML 1.2.2 §8.1.1.1).
    var max_leading_blank: usize = 0;
    // Smallest column at which a tab appears in a leading empty line. A tab is
    // invalid only inside the indentation zone, i.e. before the content indent.
    var min_blank_tab: ?usize = null;
    var last_end = body_start;

    while (self.i < self.source.len) {
        const line_start = self.i;
        var end = line_start;
        while (end < self.source.len and self.source[end] != '\n') end += 1;
        const newline_end = if (end < self.source.len) end + 1 else end;

        var spaces = line_start;
        while (spaces < end and self.source[spaces] == ' ') spaces += 1;
        var ws = line_start;
        while (ws < end and isBlank(self.source[ws])) ws += 1;
        const blank = ws == end;
        const indent = spaces - line_start;

        if (blank) {
            if (content_indent == null) {
                // A tab is never block indentation, so an otherwise-blank line
                // whose tab sits past the indentation zone (deeper than the
                // header for a non-root block, or anywhere for a root block) is
                // actually the first content line — the tab is content — and it
                // fixes the auto-detected content indent. A tab inside the
                // indentation zone (`foo: |\n\t...`) stays an error.
                if (ws > spaces and (info.root or indent > info.header_indent)) {
                    if (max_leading_blank > indent) return TokenizeError.InvalidIndent;
                    content_indent = indent;
                } else {
                    if (ws > spaces) {
                        const tab_col = spaces - line_start;
                        if (min_blank_tab == null or tab_col < min_blank_tab.?) min_blank_tab = tab_col;
                    }
                    if (indent > max_leading_blank) max_leading_blank = indent;
                }
            }
        } else {
            // A document marker at column 0 ends a root block scalar (whose
            // content may otherwise sit at column 0 and never dedent).
            if (info.root and indent == 0 and self.docMarkerAt(line_start)) break;
            if (content_indent) |ci| {
                if (indent < ci) break;
            } else {
                // A root block scalar's content may sit at column 0.
                if (!info.root and indent <= info.header_indent) break;
                if (max_leading_blank > indent) return TokenizeError.InvalidIndent;
                if (min_blank_tab) |col| if (col < indent) return TokenizeError.TabIndent;
                content_indent = indent;
            }
        }

        self.i = newline_end;
        last_end = newline_end;
    }

    // An empty block scalar whose only lines carried tabs has tabs in the
    // indentation zone (there is no content to measure against).
    if (content_indent == null and min_blank_tab != null) return TokenizeError.TabIndent;

    if (last_end > body_start) {
        try self.addToken(.init(.block_scalar, .init(body_start, last_end)));
    }
}

// Quoted scalars may span multiple lines; this scans to the closing quote
// across line breaks (the quote delimits them unambiguously) and validates each
// continuation line: it may not be a document marker, carry a tab in its
// indentation, or — when `floor` is set — be indented no more than `floor`.
// The parser folds the captured line breaks when it decodes the string.
fn multilineQuotedEnd(self: *const Tokenizer, start: usize, floor: ?usize) TokenizeError!usize {
    const source = self.source;
    const double = source[start] == '"';
    var i = start + 1;
    while (i < source.len) {
        const c = source[i];
        if (c == '\n') {
            const line_start = i + 1;
            if (self.docMarkerAt(line_start)) return TokenizeError.UnclosedString;
            var spaces = line_start;
            while (spaces < source.len and source[spaces] == ' ') spaces += 1;
            var ws = line_start;
            while (ws < source.len and isBlank(source[ws])) ws += 1;
            const blank = ws >= source.len or source[ws] == '\n';
            if (!blank) {
                // Indentation is measured in spaces; a tab after them is
                // separation. Under-indentation (too few spaces) is the error.
                if (floor) |f| if (spaces - line_start <= f) return TokenizeError.InvalidIndent;
            }
            i += 1;
            continue;
        }
        if (double) {
            if (c == '\\') {
                // A backslash escapes the next char; if that is a newline (an
                // escaped line break) let the newline branch validate the line.
                if (i + 1 < source.len and source[i + 1] == '\n') i += 1 else i += 2;
                continue;
            }
            if (c == '"') return i + 1;
        } else {
            if (c == '\'') {
                if (i + 1 < source.len and source[i + 1] == '\'') {
                    i += 2;
                    continue;
                }
                return i + 1;
            }
        }
        i += 1;
    }
    return TokenizeError.UnclosedString;
}

/// True when a document marker (`---`/`...`) begins at column-0 position `pos`.
fn docMarkerAt(self: *const Tokenizer, pos: usize) bool {
    if (pos + 3 > self.source.len) return false;
    const c = self.source[pos];
    if (c != '-' and c != '.') return false;
    if (self.source[pos + 1] != c or self.source[pos + 2] != c) return false;
    const after = pos + 3;
    return after >= self.source.len or self.source[after] == '\n' or isBlank(self.source[after]);
}

/// True when only a document-start marker and trivia have been emitted so far —
/// i.e. the next node is the document root, which has no indentation floor.
fn precededOnlyByTrivia(self: *const Tokenizer) bool {
    for (self.tokens.items) |t| switch (t.kind) {
        .doc_start, .newline, .whitespace, .comment => {},
        else => return false,
    };
    return true;
}

fn trimRightSpaces(source: []const u8, start: usize, end: usize) usize {
    var trimmed = end;
    while (trimmed > start and source[trimmed - 1] == ' ') {
        trimmed -= 1;
    }
    return trimmed;
}

fn whitespaceEnd(source: []const u8, start: usize, line_end: usize) usize {
    var end = start;
    while (end < line_end and (source[end] == ' ' or source[end] == '\t')) {
        end += 1;
    }
    return end;
}

// =======
// Testing
// =======

fn testTokenizer(input: []const u8, expected: []const Token) !void {
    var tokenizer: Tokenizer = .{ .allocator = testing.allocator, .source = input };
    const tokens = try tokenizer.tokenize();
    defer testing.allocator.free(tokens);
    try testing.expectEqualSlices(Token, expected, tokens);
}

fn testTokenizerError(input: []const u8, expected_error: anyerror) !void {
    var tokenizer: Tokenizer = .{ .allocator = testing.allocator, .source = input };
    if (tokenizer.tokenize()) |tokens| {
        defer testing.allocator.free(tokens);
        try testing.expect(false);
    } else |err| {
        try testing.expectEqual(expected_error, err);
    }
}

fn tok(kind: Token.Kind, start: usize, end: usize) Token {
    return Token.init(kind, .init(start, end));
}

test "yaml flat mapping" {
    try testTokenizer(
        "name: Ada\nage: 37\n",
        &.{
            tok(.scalar, 0, 4),
            tok(.colon, 4, 5),
            tok(.whitespace, 5, 6),
            tok(.scalar, 6, 9),
            tok(.newline, 9, 10),
            tok(.scalar, 10, 13),
            tok(.colon, 13, 14),
            tok(.whitespace, 14, 15),
            tok(.scalar, 15, 17),
            tok(.newline, 17, 18),
            tok(.end_of_file, 18, 18),
        },
    );
}

test "yaml flat sequence" {
    try testTokenizer(
        "- one\n- two\n",
        &.{
            tok(.dash, 0, 1),
            tok(.whitespace, 1, 2),
            tok(.scalar, 2, 5),
            tok(.newline, 5, 6),
            tok(.dash, 6, 7),
            tok(.whitespace, 7, 8),
            tok(.scalar, 8, 11),
            tok(.newline, 11, 12),
            tok(.end_of_file, 12, 12),
        },
    );
}

test "yaml nested indentation" {
    try testTokenizer(
        \\root:
        \\  child: value
        \\next: value
        \\
    ,
        &.{
            tok(.scalar, 0, 4),
            tok(.colon, 4, 5),
            tok(.newline, 5, 6),
            tok(.indent, 6, 8),
            tok(.scalar, 8, 13),
            tok(.colon, 13, 14),
            tok(.whitespace, 14, 15),
            tok(.scalar, 15, 20),
            tok(.newline, 20, 21),
            tok(.dedent, 21, 21),
            tok(.scalar, 21, 25),
            tok(.colon, 25, 26),
            tok(.whitespace, 26, 27),
            tok(.scalar, 27, 32),
            tok(.newline, 32, 33),
            tok(.end_of_file, 33, 33),
        },
    );
}

test "yaml quoted scalars are single tokens" {
    try testTokenizer(
        "quoted: 'a: # b'\n",
        &.{
            tok(.scalar, 0, 6),
            tok(.colon, 6, 7),
            tok(.whitespace, 7, 8),
            tok(.scalar, 8, 16),
            tok(.newline, 16, 17),
            tok(.end_of_file, 17, 17),
        },
    );

    try testTokenizer(
        "\"quoted:key\": \"value # not comment\"\n",
        &.{
            tok(.scalar, 0, 12),
            tok(.colon, 12, 13),
            tok(.whitespace, 13, 14),
            tok(.scalar, 14, 35),
            tok(.newline, 35, 36),
            tok(.end_of_file, 36, 36),
        },
    );
}

test "yaml quoted scalars must be closed" {
    try testTokenizerError("'unterminated", error.UnclosedString);
    try testTokenizerError("\"unterminated", error.UnclosedString);
    // A quote left open runs to EOF without a close: still unterminated.
    try testTokenizerError("key: \"a\n  b", error.UnclosedString);
}

test "yaml multi-line quoted scalar is one token" {
    // `"a\n  b"` spans two lines but is a single scalar token; the closing
    // line's newline is emitted after it.
    try testTokenizer(
        "k: \"a\n  b\"\n",
        &.{
            tok(.scalar, 0, 1),
            tok(.colon, 1, 2),
            tok(.whitespace, 2, 3),
            tok(.scalar, 3, 10),
            tok(.newline, 10, 11),
            tok(.end_of_file, 11, 11),
        },
    );
}

test "yaml tab is separation, not an error" {
    // The tab between `key:` and the value is whitespace, not part of the value.
    try testTokenizer(
        "key:\tvalue\n",
        &.{
            tok(.scalar, 0, 3),
            tok(.colon, 3, 4),
            tok(.whitespace, 4, 5),
            tok(.scalar, 5, 10),
            tok(.newline, 10, 11),
            tok(.end_of_file, 11, 11),
        },
    );
}

test "yaml tab as structural indentation is rejected" {
    // A tab indenting a mapping key / sequence entry is invalid...
    try testTokenizerError("a:\n\tb: 1\n", error.TabIndent);
    try testTokenizerError("a:\n  \tb: 1\n", error.TabIndent);
    // ...but a tab before a plain scalar value is separation (no error).
    var t: Tokenizer = .{ .allocator = testing.allocator, .source = "a:\n \tb\n" };
    const toks = try t.tokenize();
    testing.allocator.free(toks);
}

test "yaml tab as block-scalar content vs indentation" {
    // A tab past the (space) indentation zone is block-scalar content, so the
    // line is the first content line — valid.
    var ok: Tokenizer = .{ .allocator = testing.allocator, .source = "foo: |\n \t\nbar: 1\n" };
    const toks = try ok.tokenize();
    testing.allocator.free(toks);
    // A tab inside the indentation zone (column 0, no leading space) is invalid.
    try testTokenizerError("foo: |\n\t\nbar: 1\n", error.TabIndent);
}

test "yaml tab-only blank line inside flow is skipped" {
    // A line that is only a tab inside a flow collection is a blank fold break,
    // not under-indented content.
    var t: Tokenizer = .{ .allocator = testing.allocator, .source = "- [\n\t\n foo\n ]\n" };
    const toks = try t.tokenize();
    testing.allocator.free(toks);
}

test "yaml blank line with a tab is skipped" {
    try testTokenizer(
        "a: 1\n \t\nb: 2\n",
        &.{
            tok(.scalar, 0, 1),
            tok(.colon, 1, 2),
            tok(.whitespace, 2, 3),
            tok(.scalar, 3, 4),
            tok(.newline, 4, 5),
            tok(.scalar, 8, 9),
            tok(.colon, 9, 10),
            tok(.whitespace, 10, 11),
            tok(.scalar, 11, 12),
            tok(.newline, 12, 13),
            tok(.end_of_file, 13, 13),
        },
    );
}

test "yaml multi-line plain scalar is gathered into one token" {
    // `a` plus the more-indented `b` become a single scalar token spanning both
    // lines; `next` at the key indent is separate.
    try testTokenizer(
        "k: a\n  b\nnext: x\n",
        &.{
            tok(.scalar, 0, 1),
            tok(.colon, 1, 2),
            tok(.whitespace, 2, 3),
            tok(.scalar, 3, 8),
            tok(.newline, 8, 9),
            tok(.scalar, 9, 13),
            tok(.colon, 13, 14),
            tok(.whitespace, 14, 15),
            tok(.scalar, 15, 16),
            tok(.newline, 16, 17),
            tok(.end_of_file, 17, 17),
        },
    );
}

test "yaml multi-line quoted scalar continuation rules" {
    // A document marker may not appear inside a quoted scalar.
    try testTokenizerError("\"a\n---\nb\"\n", error.UnclosedString);
    // An inline value's continuation must out-indent its line. A tab provides
    // no space-indentation, so a tab-led continuation is under-indented too.
    try testTokenizerError("k: \"a\nb\"\n", error.InvalidIndent);
    try testTokenizerError("k: \"a\n\tb\"\n", error.InvalidIndent);
}

test "yaml colon is an indicator only before whitespace" {
    // A colon followed by a non-space (a URL) stays inside the plain scalar.
    try testTokenizer(
        "url: http://example.com\n",
        &.{
            tok(.scalar, 0, 3),
            tok(.colon, 3, 4),
            tok(.whitespace, 4, 5),
            tok(.scalar, 5, 23),
            tok(.newline, 23, 24),
            tok(.end_of_file, 24, 24),
        },
    );

    // `a:b` with no trailing space is a single plain scalar.
    try testTokenizer(
        "a:b\n",
        &.{
            tok(.scalar, 0, 3),
            tok(.newline, 3, 4),
            tok(.end_of_file, 4, 4),
        },
    );
}

test "yaml dash is an indicator only before whitespace" {
    // `-3` is a (negative) plain scalar, not an empty sequence entry.
    try testTokenizer(
        "value: -3\n",
        &.{
            tok(.scalar, 0, 5),
            tok(.colon, 5, 6),
            tok(.whitespace, 6, 7),
            tok(.scalar, 7, 9),
            tok(.newline, 9, 10),
            tok(.end_of_file, 10, 10),
        },
    );
}

test "yaml explicit key indicator" {
    // `? ` at node start is an explicit-key indicator; the standalone `:` on the
    // next line is the value indicator.
    try testTokenizer(
        "? key\n: value\n",
        &.{
            tok(.explicit_key, 0, 1),
            tok(.whitespace, 1, 2),
            tok(.scalar, 2, 5),
            tok(.newline, 5, 6),
            tok(.colon, 6, 7),
            tok(.whitespace, 7, 8),
            tok(.scalar, 8, 13),
            tok(.newline, 13, 14),
            tok(.end_of_file, 14, 14),
        },
    );

    // `?x` (no separating space) is ordinary plain text, not an indicator.
    try testTokenizer(
        "?x\n",
        &.{
            tok(.scalar, 0, 2),
            tok(.newline, 2, 3),
            tok(.end_of_file, 3, 3),
        },
    );
}

test "yaml document markers" {
    try testTokenizer(
        "---\nname: Ada\n...\n",
        &.{
            tok(.doc_start, 0, 3),
            tok(.newline, 3, 4),
            tok(.scalar, 4, 8),
            tok(.colon, 8, 9),
            tok(.whitespace, 9, 10),
            tok(.scalar, 10, 13),
            tok(.newline, 13, 14),
            tok(.doc_end, 14, 17),
            tok(.newline, 17, 18),
            tok(.end_of_file, 18, 18),
        },
    );
}

test "yaml flow collection indicators are distinct tokens" {
    try testTokenizer(
        "tags: [a, b]\n",
        &.{
            tok(.scalar, 0, 4),
            tok(.colon, 4, 5),
            tok(.whitespace, 5, 6),
            tok(.flow_seq_start, 6, 7),
            tok(.scalar, 7, 8),
            tok(.comma, 8, 9),
            tok(.whitespace, 9, 10),
            tok(.scalar, 10, 11),
            tok(.flow_seq_end, 11, 12),
            tok(.newline, 12, 13),
            tok(.end_of_file, 13, 13),
        },
    );
}

test "yaml flow spans lines and ignores indentation" {
    // The continuation line is not an indent; inside flow it is plain trivia.
    try testTokenizer(
        "x: [\n  a,\n]\n",
        &.{
            tok(.scalar, 0, 1),
            tok(.colon, 1, 2),
            tok(.whitespace, 2, 3),
            tok(.flow_seq_start, 3, 4),
            tok(.newline, 4, 5),
            tok(.scalar, 7, 8),
            tok(.comma, 8, 9),
            tok(.newline, 9, 10),
            tok(.flow_seq_end, 10, 11),
            tok(.newline, 11, 12),
            tok(.end_of_file, 12, 12),
        },
    );
}

test "yaml block scalar header and body are single tokens" {
    // The `|` header and the two indented body lines become one block_header
    // plus one block_scalar token; the body is not tokenized as structure.
    try testTokenizer(
        "text: |\n  a\n  b\nnext: x\n",
        &.{
            tok(.scalar, 0, 4),
            tok(.colon, 4, 5),
            tok(.whitespace, 5, 6),
            tok(.block_header, 6, 7),
            tok(.newline, 7, 8),
            tok(.block_scalar, 8, 16),
            tok(.scalar, 16, 20),
            tok(.colon, 20, 21),
            tok(.whitespace, 21, 22),
            tok(.scalar, 22, 23),
            tok(.newline, 23, 24),
            tok(.end_of_file, 24, 24),
        },
    );
}

test "yaml block scalar header carries indicators" {
    try testTokenizer(
        "k: |2-\n    x\n",
        &.{
            tok(.scalar, 0, 1),
            tok(.colon, 1, 2),
            tok(.whitespace, 2, 3),
            tok(.block_header, 3, 6),
            tok(.newline, 6, 7),
            tok(.block_scalar, 7, 13),
            tok(.end_of_file, 13, 13),
        },
    );
}

test "yaml block scalar rejects tabs and bad indentation" {
    try testTokenizerError("foo: |\n\t\nbar: 1\n", error.TabIndent);
    try testTokenizerError("foo: |\n     \n  ok\n", error.InvalidIndent);
}

test "yaml hash starts a comment only after whitespace" {
    // `a#b` has no comment: the hash is part of the plain scalar.
    try testTokenizer(
        "a#b\n",
        &.{
            tok(.scalar, 0, 3),
            tok(.newline, 3, 4),
            tok(.end_of_file, 4, 4),
        },
    );

    // `a #b` does: the hash is preceded by whitespace.
    try testTokenizer(
        "a #b\n",
        &.{
            tok(.scalar, 0, 1),
            tok(.comment, 2, 4),
            tok(.newline, 4, 5),
            tok(.end_of_file, 5, 5),
        },
    );
}
