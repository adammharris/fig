//! The parser turns a JSON-formatted []const u8 into an AST.
//! It uses the Tokenizer to tokenize the string, and then converts
//! the token slice into an AST incrementally.
//!
//! This parser temporarily allocates and frees memory for the tokenizer
//! and for the in-progress containers, including three ArrayLists
//! for `node`s, `Span`s, and `OpenContainer`s.
//!
//! Decoded string escape allocations are transferred into the returned AST's
//! `owned_strings` slice and must be freed with `ast.deinit();`

const Parser = @This();

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const log = std.log.scoped(.parser);
const Unicode = @import("../../util/util.zig").Unicode;
const AST = @import("../../ast/ast.zig");
const Document = @import("../../document.zig");
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const Token = @import("../../token.zig").Token(Tokenizer.Kind);
const Type = @import("json.zig").Type;
const Span = @import("../../util/span.zig");

const parse_diagnostic = @import("../../parse_diagnostic.zig");

const ContainerKind = enum { array, object };
/// Either an array or object in the process of being parsed.
const OpenContainer = struct {
    id: AST.Node.Id,
    kind: ContainerKind,
    first_child: ?AST.Node.Id = null,
    last_child: ?AST.Node.Id = null,
    pending_key: ?AST.Node.Id = null,
    /// Object only: every key text seen so far, to warn on a repeat (see
    /// `Warning.Code.duplicate_key`). Freed when the container closes
    /// (`closeContainer`) or, on an aborted parse, in `Parser.deinit`.
    seen_keys: std.StringHashMapUnmanaged(void) = .empty,
};

// State
state: State = .ExpectValue,
nodes: std.ArrayList(AST.Node) = .empty,
node_spans: std.ArrayList(Span) = .empty,
container_stack: std.ArrayList(OpenContainer) = .empty,
owned_strings: std.ArrayList([]const u8) = .empty,

// Comment layer (JSON5/JSONC only — strict JSON never tokenizes a comment).
// `node_comments` grows in lockstep with `nodes`. `pending_leading` buffers
// own-line comments until the next node claims them (in `addNode`). Comment text
// borrows `input` (comments carry no escapes). Materialized only when
// `comments_seen`.
node_comments: std.ArrayList(AST.NodeComments) = .empty,
pending_leading: std.ArrayList(AST.Comment) = .empty,
/// The most recently completed value node — the candidate a same-line trailing
/// comment binds to. Reset to null by a newline or a comma (both close the
/// trailing window), so a post-comma/own-line comment becomes leading instead.
last_value_id: ?AST.Node.Id = null,
comments_seen: bool = false,

root: ?AST.Node.Id = null,

// Initial fields
allocator: std.mem.Allocator,
/// Which JSON dialect is being parsed. Gates the JSON5-only grammar
/// (unquoted keys, trailing commas, `Infinity`/`NaN`, single-quoted strings).
format: Type = .JSON,

/// Error-recovery mode: when set, a per-token dispatch failure is recorded
/// into `diagnostics` and the parser resyncs to the next safe token instead of
/// aborting — see `resync`. Off by default; `parseCollecting` turns it on.
/// `error.OutOfMemory` is never recovered (it is not a document defect).
recover: bool = false,
/// Every parse error hit so far, in source order. Populated on EVERY failure
/// (not just in `recover` mode) — the single-shot entry points
/// (`parse`/`parseWithReport`) still stop at the first, but the location is
/// captured the same way either way, so `parseWithReport`'s `Report.diag`
/// never has to re-derive it differently from `parseCollecting`'s
/// `Report.errors[0]`.
diagnostics: std.ArrayList(Diagnostic) = .empty,
/// Authoring-time lints collected during the parse (see `Warning.Code`).
/// Valid alongside a failure too, same as fig's.
warnings: std.ArrayList(Warning) = .empty,

const ParseError = error{ UnclosedObject, UnclosedArray, UnclosedString, InvalidBool, InvalidNumber, UnexpectedToken, InvalidUnicodeEscape };
const ParserError = ParseError || std.mem.Allocator.Error;
const TokenizeError = Tokenizer.TokenizeError;

/// The union of every error this parser can produce — both the one-shot
/// tokenizer (which runs to completion before the token loop even starts, so
/// its failures need describing too) and the token-dispatch parser. Kept as
/// one flat set (mirrors fig's `Error = error{...} || tok.ScanError`) so a
/// `Diagnostic` needs only one `code` field regardless of which stage failed.
pub const Error = ParserError || TokenizeError;

/// The teaching message for `code` — one sentence naming the fix, same
/// contract as fig's `describe` (DESIGN.md "every diagnostic names the fix").
/// JSON's flatter, single-state-machine grammar means many distinct mistakes
/// (a missing comma, a bad key, a stray token) all surface as the same
/// `UnexpectedToken` — so that message stays intentionally general; the
/// caret still narrows it to the exact offending token.
pub fn describe(code: Error) []const u8 {
    return switch (code) {
        error.UnclosedObject => "unclosed object; add the missing `}`",
        error.UnclosedArray => "unclosed array; add the missing `]`",
        error.UnclosedString => "unclosed string; a JSON string cannot span multiple lines — add the closing quote, or escape the newline as `\\n`",
        error.InvalidBool => "not a valid boolean; JSON's only booleans are the lowercase literals `true` and `false`",
        error.InvalidNumber => "not a valid number; a JSON number allows at most one `.` and one exponent (`e`/`E`)",
        error.UnexpectedToken => "unexpected token here; check for a missing comma, colon, key, or closing bracket/brace",
        error.InvalidUnicodeEscape => "invalid `\\u` escape; it needs exactly 4 hex digits (e.g. `\\u00e9`)",
        error.MissingToken => "missing token",
        error.UnexpectedSlash => "a `/` here must start a `//` or `/* */` comment, and strict JSON has no comments at all — use a .jsonc/.json5 file, or remove it",
        error.MissingCloseBrace => "missing `}` to close this object",
        error.MissingOpenQuote => "object keys must be quoted strings in strict JSON — write `\"key\"`, or use a .json5 file for unquoted keys",
        error.MissingColon => "missing `:` between this key and its value",
        error.MissingCloseBracket => "missing `]` to close this array",
        error.LeadingZero => "a number cannot have a leading zero; write the digits without the padding, or quote it as a string to keep the padding (e.g. a zip code)",
        error.UnexpectedEndOfInput => "the document ended before this value/token was complete",
        error.UnclosedComment => "unclosed block comment; add the closing `*/`",
        error.OutOfMemory => "out of memory",
    };
}

/// A short (few-word) noun phrase for `code` — for a caret annotation
/// (`^ unexpected token`), same purpose as fig's `shortLabel`.
pub fn shortLabel(code: Error) []const u8 {
    return switch (code) {
        error.UnclosedObject => "unclosed object",
        error.UnclosedArray => "unclosed array",
        error.UnclosedString => "unclosed string",
        error.InvalidBool => "invalid boolean",
        error.InvalidNumber => "invalid number",
        error.UnexpectedToken => "unexpected token",
        error.InvalidUnicodeEscape => "invalid unicode escape",
        error.MissingToken => "missing token",
        error.UnexpectedSlash => "comments not allowed here",
        error.MissingCloseBrace => "missing `}`",
        error.MissingOpenQuote => "key must be quoted",
        error.MissingColon => "missing `:`",
        error.MissingCloseBracket => "missing `]`",
        error.LeadingZero => "leading zero",
        error.UnexpectedEndOfInput => "unexpected end of input",
        error.UnclosedComment => "unclosed comment",
        error.OutOfMemory => "out of memory",
    };
}

/// A parse failure plus the byte span where it fired. The parser doesn't
/// thread a location through every helper's return site (`getString`,
/// `getNumber`, …); instead the main token loop (`parse_once`) knows which
/// token it was dispatching when an error propagates and anchors the
/// diagnostic on that token's whole span — less surgical than fig's per-site
/// overrides (an invalid `\u` escape mid-string points at the whole string,
/// not the 4 offending hex chars), but a real location beats none, and JSON's
/// flat grammar rarely needs finer resolution. A tokenizer failure (before the
/// token loop starts) anchors on the tokenizer's cursor instead.
pub const Diagnostic = struct {
    code: Error,
    offset: usize,
    end: ?usize = null,

    /// 1-based line/column of `offset`, plus the full offending line.
    pub fn locate(self: Diagnostic, source: []const u8) parse_diagnostic.Location {
        return parse_diagnostic.locateOffset(source, self.offset);
    }

    /// Render `file:line:col: error: <message>` + source line + caret.
    pub fn renderAlloc(self: Diagnostic, allocator: std.mem.Allocator, source: []const u8, file: []const u8) std.mem.Allocator.Error![]u8 {
        return parse_diagnostic.renderReportAlloc(allocator, source, self.offset, file, "error", describe(self.code));
    }
};

/// An authoring-time lint: the document is valid JSON, but the shape is a
/// likely mistake. Collected during the parse (valid alongside a failure too);
/// the caller (CLI `--quiet`/`--strict`, a future language server) decides how
/// to present it — same contract as fig's `Warning`.
pub const Warning = struct {
    code: Code,
    offset: usize,
    end: ?usize = null,

    pub const Code = enum {
        /// A key appears more than once in one object. Legal per the JSON
        /// spec (which does not forbid it), but consumers disagree on which
        /// value wins (this library's own `getValByPath` resolves to the
        /// FIRST; most JS-based tooling resolves to the LAST) — so one value
        /// is always silently discarded, which is rarely what a hand-edited
        /// or merged file meant.
        duplicate_key,
    };

    pub fn describeWarning(code: Code) []const u8 {
        return switch (code) {
            .duplicate_key => "this key already appears earlier in the object; the JSON spec allows it, but most consumers keep only ONE of the two values (which one is implementation-defined) and silently discard the other — remove one of the two, or rename a key if both were intended",
        };
    }

    /// A short (few-word) noun phrase for `code` — mirrors `shortLabel`.
    pub fn shortLabel(code: Code) []const u8 {
        return switch (code) {
            .duplicate_key => "duplicate key",
        };
    }

    pub fn locate(self: Warning, source: []const u8) parse_diagnostic.Location {
        return parse_diagnostic.locateOffset(source, self.offset);
    }

    /// Render `file:line:col: warning: <message>` + source line + caret.
    pub fn renderAlloc(self: Warning, allocator: std.mem.Allocator, source: []const u8, file: []const u8) std.mem.Allocator.Error![]u8 {
        return parse_diagnostic.renderReportAlloc(allocator, source, self.offset, file, "warning", describeWarning(self.code));
    }
};

/// Everything a parse reports besides the tree — mirrors fig's `Report`
/// (`languages/fig/parser.zig`) field-for-field, so the CLI treats every
/// language's report the same shape (see `main.zig`'s `checkOne`).
pub const Report = struct {
    diag: ?Diagnostic = null,
    /// Every parse error, in source order — populated ONLY by the recovering
    /// entry point (`parseCollecting`), which resyncs past each failure and
    /// keeps going. The single-shot `parse`/`parseWithReport` stop at the
    /// first error and leave this empty, setting `diag` alone. When
    /// non-empty, `diag` mirrors `errors[0]`.
    errors: []const Diagnostic = &.{},
    warnings: []const Warning = &.{},
};

const State = enum {
    ExpectValue,

    ExpectArrayValueOrEnd,
    ExpectArrayCommaOrEnd,

    ExpectObjectKeyOrEnd,
    ExpectObjectKey,
    ExpectObjectColon,
    ExpectObjectValue,
    ExpectObjectCommaOrEnd,

    ExpectEndOfFile,
};

/// Expects "true" or "false", translates to boolean
pub fn getBool(slice: []const u8) ParseError!bool {
    if (std.mem.eql(u8, slice, "true")) return true;
    if (std.mem.eql(u8, slice, "false")) return false;
    return error.InvalidBool;
}

/// Removes double quotes. If the string contains escape codes,
/// decodes and stores the allocated string in the AST's `owned_strings`.
pub fn getString(self: *Parser, slice: []const u8) ParserError![]const u8 {
    const json5 = self.format == .JSON5;
    // JSON5 strings may also be single-quoted; the closing quote must match.
    const quote: u8 = if (slice.len >= 1) slice[0] else 0;
    const valid_quote = quote == '"' or (json5 and quote == '\'');
    if (slice.len < 2 or !valid_quote or slice[slice.len - 1] != quote) {
        return ParseError.UnclosedString;
    }
    const inner = slice[1 .. slice.len - 1];

    // Fast path: no escapes, can safely point into source.
    if (std.mem.indexOfScalar(u8, inner, '\\') == null) return inner;

    // String contains escapes, so we need to allocate a new decoded string.
    var decoded: std.ArrayList(u8) = .empty;
    errdefer decoded.deinit(self.allocator);

    var i: usize = 0;
    while (i < inner.len) {
        const c = inner[i];
        if (c != '\\') {
            try decoded.append(self.allocator, c);
            i += 1;
            continue;
        }

        i += 1;
        if (i >= inner.len) return ParseError.UnclosedString;

        switch (inner[i]) {
            '"' => try decoded.append(self.allocator, '"'), // double quote
            '\\' => try decoded.append(self.allocator, '\\'), // backslash
            '/' => try decoded.append(self.allocator, '/'), // slash
            'b' => try decoded.append(self.allocator, 0x08), // backspace
            'f' => try decoded.append(self.allocator, 0x0c), // formfeed
            'n' => try decoded.append(self.allocator, '\n'), // newline
            'r' => try decoded.append(self.allocator, '\r'), // return
            't' => try decoded.append(self.allocator, '\t'), // tab
            // JSON5-only escapes.
            '\'' => if (json5) try decoded.append(self.allocator, '\'') else return ParseError.UnexpectedToken,
            'v' => if (json5) try decoded.append(self.allocator, 0x0b) else return ParseError.UnexpectedToken,
            '0' => if (json5) try decoded.append(self.allocator, 0x00) else return ParseError.UnexpectedToken,
            'x' => { // \xHH hex escape (one code point U+00HH)
                if (!json5) return ParseError.UnexpectedToken;
                if (i + 2 >= inner.len) return ParseError.UnclosedString;
                const byte = std.fmt.parseInt(u8, inner[i + 1 .. i + 3], 16) catch return ParseError.InvalidUnicodeEscape;
                var xbuf: [4]u8 = undefined;
                const xwritten = std.unicode.utf8Encode(byte, &xbuf) catch return ParseError.InvalidUnicodeEscape;
                try decoded.appendSlice(self.allocator, xbuf[0..xwritten]);
                i += 2;
            },
            // Line continuations: a backslash before a line terminator emits
            // nothing (the source line wraps). CRLF counts as one terminator.
            '\n' => {
                if (!json5) return ParseError.UnexpectedToken;
            },
            '\r' => {
                if (!json5) return ParseError.UnexpectedToken;
                if (i + 1 < inner.len and inner[i + 1] == '\n') i += 1;
            },
            'u' => { // unicode
                // JSON \u escapes encode one UTF-16 code unit in 4 hex chars.
                if (i + 4 >= inner.len) return ParseError.UnclosedString;
                const bytes = inner[i + 1 .. i + 5];
                const first_unit = std.fmt.parseInt(u16, bytes, 16) catch return ParseError.InvalidUnicodeEscape;
                var codepoint: u21 = first_unit;
                i += 4;

                // If the escape contains an unpaired surrogate, preserve the
                // raw source representation rather than failing. JSONTestSuite
                // treats these as implementation-defined `i_` cases, and the
                // AST cannot losslessly normalize them into UTF-8.
                if (Unicode.isHighSurrogate(codepoint)) {
                    if (i + 6 >= inner.len) {
                        decoded.deinit(self.allocator);
                        return inner;
                    }
                    if (inner[i + 1] != '\\' or inner[i + 2] != 'u') {
                        decoded.deinit(self.allocator);
                        return inner;
                    }
                    const nextBytes = inner[i + 3 .. i + 7];
                    const low_unit = std.fmt.parseInt(u16, nextBytes, 16) catch return ParseError.InvalidUnicodeEscape;
                    if (!Unicode.isLowSurrogate(low_unit)) {
                        decoded.deinit(self.allocator);
                        return inner;
                    }
                    codepoint = 0x10000 + ((@as(u21, first_unit) - 0xD800) << 10) + (@as(u21, low_unit) - 0xDC00);
                    i += 6;
                } else if (Unicode.isLowSurrogate(codepoint)) {
                    decoded.deinit(self.allocator);
                    return inner;
                }

                var buf: [4]u8 = undefined;
                const written = std.unicode.utf8Encode(codepoint, &buf) catch return ParseError.InvalidUnicodeEscape;
                try decoded.appendSlice(self.allocator, buf[0..written]);
            },
            // JSON5 NonEscapeCharacter: any other escaped char is itself
            // (`\q` -> `q`). Strict JSON rejects unknown escapes.
            else => if (json5) try decoded.append(self.allocator, inner[i]) else return ParseError.UnexpectedToken,
        }
        i += 1;
    }
    const owned = try decoded.toOwnedSlice(self.allocator);
    errdefer self.allocator.free(owned);

    try self.owned_strings.append(self.allocator, owned);
    return owned;
}

/// Returns lossless struct representation of a number
pub fn getNumber(slice: []const u8) ParseError!AST.Node.Kind.Number {
    // JSON5 hexadecimal integers (`0xC8`, optionally signed) carry no dot and
    // no exponent; their `e`/`E` digits are part of the radix, not a float
    // exponent, so classify them before the dot/exponent heuristic.
    const body = if (slice.len > 0 and (slice[0] == '+' or slice[0] == '-')) slice[1..] else slice;
    if (body.len >= 2 and body[0] == '0' and (body[1] == 'x' or body[1] == 'X'))
        return .{ .raw = slice, .kind = .integer };

    var numDots: usize = 0;
    for (slice) |char| {
        if (char == '.') numDots += 1;
    }
    return .{ .raw = slice, .kind = switch (numDots) {
        0 => if (std.mem.indexOfAny(u8, slice, "eE") == null) .integer else .float,
        1 => .float,
        else => return error.InvalidNumber,
    } };
}

/// Main entry function
pub fn parseAbstract(allocator: std.mem.Allocator, input: []const u8, format: Type) !AST {
    const parsed = try parse(allocator, input, format);
    allocator.free(parsed.node_spans);
    return parsed.ast;
}

pub fn parse(allocator: std.mem.Allocator, input: []const u8, format: Type) !Document {
    return parseImpl(allocator, input, format, null, false);
}

/// `parse`, but also fills `out`: `diag` on failure (error code + byte span,
/// for `file:line:col` teaching messages), `warnings` always (authoring-time
/// lints — currently just `duplicate_key`). Mirrors fig's
/// `Parser.parseWithReport` — the hook the CLI renders reports from.
pub fn parseWithReport(allocator: std.mem.Allocator, input: []const u8, format: Type, out: *Report) !Document {
    return parseImpl(allocator, input, format, out, false);
}

/// `parseWithReport`, but recovers past each parser-level error (resyncing to
/// the next safe token — see `resync`) to collect the WHOLE file's diagnostics
/// in one pass (`out.errors`, source order) rather than stopping at the first.
/// A TOKENIZER failure (before the token loop even starts) is never
/// recoverable — it still stops the parse after exactly one diagnostic. On any
/// error the return value is still the first error code and the tree is NOT
/// built (both consumers discard it); a clean parse returns the Document
/// exactly as `parseWithReport` would. `out.diag` mirrors `errors[0]`. Mirrors
/// fig's `Parser.parseCollecting`.
pub fn parseCollecting(allocator: std.mem.Allocator, input: []const u8, format: Type, out: *Report) !Document {
    return parseImpl(allocator, input, format, out, true);
}

fn parseImpl(allocator: std.mem.Allocator, input: []const u8, format: Type, out: ?*Report, recover: bool) !Document {
    var parser: Parser = .{ .allocator = allocator, .recover = recover };
    defer parser.deinit();
    const result = parser.parse_once(input, format);
    // Warnings are duped out on every exit path (they are valid alongside a
    // failure too), before `parser.deinit()` frees the list.
    if (out) |o| o.warnings = allocator.dupe(Warning, parser.warnings.items) catch &.{};
    return result catch |err| {
        if (out) |o| {
            if (parser.diagnostics.items.len > 0) {
                o.diag = parser.diagnostics.items[0];
                if (recover) o.errors = allocator.dupe(Diagnostic, parser.diagnostics.items) catch &.{};
            }
        }
        return err;
    };
}

fn parse_once(self: *Parser, input: []const u8, kind: Type) !Document {
    self.format = kind;
    var tokenizer: Tokenizer = .{
        .allocator = self.allocator,
        .str = input,
        .kind = kind,
    };

    const tokens = tokenizer.tokenize() catch |err| {
        // The tokenizer's cursor sits on (or just after) the offending byte —
        // precise enough for `file:line:col` without threading a location
        // through its many scan-error sites (mirrors the parser's own
        // token-span anchor below).
        try self.diagnostics.append(self.allocator, .{ .code = err, .offset = tokenizer.index });
        return err;
    };
    defer self.allocator.free(tokens);

    // Each Document.Node has an id, a kind, and a next_sibling ID.
    // We produce them from the tokens.

    var i: usize = 0;
    while (i < tokens.len) {
        const token = tokens[i];
        switch (token.kind) {
            // A newline closes the previous value's trailing-comment window: a
            // comment on the next line leads the next node instead.
            .whitespace => {
                if (std.mem.indexOfScalar(u8, input[token.span.start..token.span.end], '\n') != null)
                    self.last_value_id = null;
                i += 1;
                continue;
            },
            .comment => {
                try self.handleComment(input, tokens, i);
                i += 1;
                continue;
            },
            else => {},
        }

        self.dispatchToken(input, token) catch |err| {
            if (err == error.OutOfMemory) return err; // never a document defect
            // Anchor on the WHOLE token being dispatched when the error fired
            // — the exact site varies (a bad key, a missing colon, an
            // unclosed container noticed at EOF), but the current token is
            // always a reasonable, precise-enough caret.
            try self.diagnostics.append(self.allocator, .{ .code = err, .offset = token.span.start, .end = token.span.end });
            if (!self.recover) return err;
            const sync = self.resync(tokens, i);
            switch (tokens[sync].kind) {
                .comma => {
                    // Consume the comma ourselves and put the parser into the
                    // state it legally produces, so the next key/value parses
                    // normally from the token right after it.
                    if (self.container_stack.items.len > 0) {
                        const top = self.container_stack.items[self.container_stack.items.len - 1];
                        self.state = switch (top.kind) {
                            .array => .ExpectArrayValueOrEnd,
                            .object => .ExpectObjectKey,
                        };
                    }
                    i = sync + 1;
                },
                .close_bracket, .close_brace => {
                    // Leave the closer for the normal dispatch to consume,
                    // but fix the state first so it's legal to see it (the
                    // failure may have left `self.state` expecting something
                    // else entirely, e.g. a colon).
                    if (self.container_stack.items.len > 0) {
                        const top = self.container_stack.items[self.container_stack.items.len - 1];
                        self.state = switch (top.kind) {
                            .array => .ExpectArrayCommaOrEnd,
                            .object => .ExpectObjectCommaOrEnd,
                        };
                    }
                    i = sync;
                },
                // Nothing left to resync onto (EOF): stop recovering. Falls
                // through to the shared diagnostics check below, which
                // returns `diagnostics.items[0].code` — the first failure,
                // same contract as the non-recovering path.
                else => break,
            }
            continue;
        };
        i += 1;
    }

    if (self.diagnostics.items.len > 0) {
        // Recover mode collected 1+ errors (or the loop above stopped early):
        // the tree may be malformed (dangling open containers, no root), so
        // don't try to build it — return the first failure's code, matching
        // the non-recovering contract exactly. `parseImpl` reads the full list
        // out of `self.diagnostics` for `Report.errors` before this unwinds.
        return self.diagnostics.items[0].code;
    }

    // Ready to return a Document!
    const root = self.root orelse return ParseError.UnexpectedToken;

    const nodes = try self.nodes.toOwnedSlice(self.allocator);
    errdefer self.allocator.free(nodes);
    self.nodes = .empty;

    const node_spans = try self.node_spans.toOwnedSlice(self.allocator);
    errdefer self.allocator.free(node_spans);
    self.node_spans = .empty;

    const owned_strings = try self.owned_strings.toOwnedSlice(self.allocator);
    self.owned_strings = .empty;

    var ast: AST = .{
        .allocator = self.allocator,
        .owned_strings = owned_strings,
        .root = root,
        .nodes = nodes,
    };
    // Materialized last (no fallible step follows): hand the owned `leading`
    // slices to the AST. Only when comments were actually attached.
    if (self.comments_seen) {
        ast.node_comments = try self.node_comments.toOwnedSlice(self.allocator);
        self.node_comments = .empty;
    }

    return .{
        .source = input,
        .ast = ast,
        .node_spans = node_spans,
    };
}

/// One token's worth of the state machine — extracted from `parse_once`'s
/// main loop so it can be `catch`-wrapped there (single-shot: propagate;
/// `recover`: record + resync — see `resync`) without duplicating the switch.
/// Bodies are unchanged from the original inline dispatch.
fn dispatchToken(self: *Parser, input: []const u8, token: Token) ParserError!void {
    switch (self.state) {
            .ExpectValue => {
                switch (token.kind) {
                    .open_brace => {
                        const id = try self.addNode(.{ .mapping = null }, token.span);
                        try self.openContainer(.object, id);
                        self.state = .ExpectObjectKeyOrEnd;
                    },
                    .open_bracket => {
                        const id = try self.addNode(.{ .sequence = null }, token.span);
                        try self.openContainer(.array, id);
                        self.state = .ExpectArrayValueOrEnd;
                    },
                    .null_ => {
                        const id = try self.addTokenNode(input, token);
                        try self.finishValue(id);
                    },
                    .true_, .false_ => {
                        const id = try self.addTokenNode(input, token);
                        try self.finishValue(id);
                    },
                    .string => {
                        const id = try self.addTokenNode(input, token);
                        try self.finishValue(id);
                    },
                    .number, .identifier => {
                        const id = try self.addTokenNode(input, token);
                        try self.finishValue(id);
                    },
                    else => return ParseError.UnexpectedToken,
                }
            },

            .ExpectArrayValueOrEnd => {
                switch (token.kind) {
                    .open_bracket => {
                        const id = try self.addNode(.{ .sequence = null }, token.span);
                        try self.openContainer(.array, id);
                        self.state = .ExpectArrayValueOrEnd;
                    },
                    .open_brace => {
                        const id = try self.addNode(.{ .mapping = null }, token.span);
                        try self.openContainer(.object, id);
                        self.state = .ExpectObjectKeyOrEnd;
                    },
                    .null_ => {
                        const id = try self.addTokenNode(input, token);
                        try self.finishValue(id);
                    },
                    .true_, .false_ => {
                        const id = try self.addTokenNode(input, token);
                        try self.finishValue(id);
                    },
                    .string => {
                        const id = try self.addTokenNode(input, token);
                        try self.finishValue(id);
                    },
                    .number, .identifier => {
                        const id = try self.addTokenNode(input, token);
                        try self.finishValue(id);
                    },
                    .close_bracket => {
                        const id = try self.closeContainer(token.span.end);
                        try self.finishValue(id);
                    },
                    else => return ParseError.UnexpectedToken,
                }
            },
            .ExpectArrayCommaOrEnd => {
                switch (token.kind) {
                    .close_bracket => {
                        const id = try self.closeContainer(token.span.end);
                        try self.finishValue(id);
                    },
                    .comma => {
                        // JSON5 permits a trailing comma: route to the state
                        // that also accepts `]`. Strict JSON must then see a
                        // value, so `[1,]` stays an error.
                        self.state = if (self.format == .JSON5) .ExpectArrayValueOrEnd else .ExpectValue;
                    },
                    else => return ParseError.UnexpectedToken,
                }
            },

            .ExpectObjectKeyOrEnd => {
                switch (token.kind) {
                    .string, .identifier, .true_, .false_, .null_ => {
                        try self.beginKey(input, token);
                    },
                    .close_brace => {
                        const id = try self.closeContainer(token.span.end);
                        try self.finishValue(id);
                    },
                    else => return ParseError.UnexpectedToken,
                }
            },
            .ExpectObjectKey => {
                switch (token.kind) {
                    .string, .identifier, .true_, .false_, .null_ => {
                        try self.beginKey(input, token);
                    },
                    else => return ParseError.UnexpectedToken,
                }
            },
            .ExpectObjectColon => {
                switch (token.kind) {
                    .colon => {
                        self.state = .ExpectObjectValue;
                    },
                    else => return ParseError.UnexpectedToken,
                }
            },
            .ExpectObjectValue => {
                switch (token.kind) {
                    .open_brace => {
                        const id = try self.addNode(.{ .mapping = null }, token.span);
                        try self.openContainer(.object, id);
                        self.state = .ExpectObjectKeyOrEnd;
                    },
                    .open_bracket => {
                        const id = try self.addNode(.{ .sequence = null }, token.span);
                        try self.openContainer(.array, id);
                        self.state = .ExpectArrayValueOrEnd;
                    },
                    .null_ => {
                        const id = try self.addTokenNode(input, token);
                        try self.finishValue(id);
                    },
                    .true_, .false_ => {
                        const id = try self.addTokenNode(input, token);
                        try self.finishValue(id);
                    },
                    .string => {
                        const id = try self.addTokenNode(input, token);
                        try self.finishValue(id);
                    },
                    .number, .identifier => {
                        const id = try self.addTokenNode(input, token);
                        try self.finishValue(id);
                    },
                    else => return ParseError.UnexpectedToken,
                }
            },
            .ExpectObjectCommaOrEnd => {
                switch (token.kind) {
                    .close_brace => {
                        const id = try self.closeContainer(token.span.end);
                        try self.finishValue(id);
                    },
                    // JSON5 permits a trailing comma before `}`.
                    .comma => self.state = if (self.format == .JSON5) .ExpectObjectKeyOrEnd else .ExpectObjectKey,
                    else => return ParseError.UnexpectedToken,
                }
            },

            .ExpectEndOfFile => {
                switch (token.kind) {
                    .end_of_file => {},
                    else => return ParseError.UnexpectedToken,
                }
            },
        }
}

/// After a parse error at `tokens[start]` (only reachable in `recover` mode),
/// scan forward for a safe resumption point: the next `,`/`]`/`}` at the SAME
/// nesting depth as the error, tracking any `[`/`{` seen along the way so a
/// well-formed nested value inside the garbage doesn't confuse the scan (a
/// `,` or closer belonging to a nested container it opens doesn't count).
/// A depth-0 closer whose kind doesn't match the currently open container
/// (`]` while an object is open, or vice versa — garbage, not a real close of
/// anything reachable here) is skipped like ordinary content rather than
/// accepted: the caller always resumes dispatch AT the token this returns for
/// the close-bracket/brace case, so returning a non-matching one would hand
/// dispatch a token it rejects in the very same state, re-erroring on the
/// same index forever. Falls back to the tokenizer's own trailing
/// `end_of_file` token when no such point exists before it (unclosed to the
/// end of the document), or when a matching closer would close a container
/// that isn't actually open (nothing left to recover into at the root) — the
/// caller's outer loop treats landing on `end_of_file` as "stop recovering",
/// so this always terminates.
fn resync(self: *Parser, tokens: []const Token, start: usize) usize {
    var depth: isize = 0;
    var j = start;
    while (j < tokens.len) : (j += 1) {
        switch (tokens[j].kind) {
            .open_brace, .open_bracket => depth += 1,
            .close_brace, .close_bracket => {
                if (depth == 0) {
                    if (self.container_stack.items.len == 0) return tokens.len - 1;
                    const top = self.container_stack.items[self.container_stack.items.len - 1];
                    const matches = (tokens[j].kind == .close_brace and top.kind == .object) or
                        (tokens[j].kind == .close_bracket and top.kind == .array);
                    if (matches) return j;
                    // Mismatched closer: doesn't belong to anything open at
                    // this depth (e.g. `]` while an object is open) — treat it
                    // as ordinary garbage and keep scanning past it.
                    continue;
                }
                depth -= 1;
            },
            .comma => if (depth == 0) return j,
            .end_of_file => return j,
            else => {},
        }
    }
    return tokens.len - 1;
}

pub fn deinit(self: *Parser) void {
    // An aborted parse can still have open containers whose `seen_keys` map
    // was never freed by a normal `closeContainer` — do it here instead.
    for (self.container_stack.items) |*c| c.seen_keys.deinit(self.allocator);
    self.container_stack.deinit(self.allocator);
    self.nodes.deinit(self.allocator);
    self.node_spans.deinit(self.allocator);
    for (self.owned_strings.items) |string| {
        self.allocator.free(string);
    }
    self.owned_strings.deinit(self.allocator);
    // After a successful parse these `leading` slices moved to the AST and the
    // list is empty; on an error path they are freed here. Text borrows `input`.
    for (self.node_comments.items) |nc| self.allocator.free(nc.leading);
    self.node_comments.deinit(self.allocator);
    self.pending_leading.deinit(self.allocator);
    self.diagnostics.deinit(self.allocator);
    self.warnings.deinit(self.allocator);
}

// ===============
// PARSING HELPERS
// ===============

/// Add an incomplete node to self.nodes. Called as soon as `[` or `{` is found.
fn addNode(self: *Parser, kind: AST.Node.Kind, span: Span) !AST.Node.Id {
    const id: AST.Node.Id = @intCast(self.nodes.items.len);
    try self.nodes.append(self.allocator, .{
        .id = id,
        .kind = kind,
        .next_sibling = null, // Update if there is a next sibling
    });
    try self.node_spans.append(self.allocator, span);
    try self.node_comments.append(self.allocator, .{});
    // Buffered leading comments bind to the first node opened for the next
    // child — a key (object entry), a value (array element / root), or a
    // container. The keyvalue *pair* node (minted in `finishValue`) sees an
    // already-drained buffer, so this is a no-op there.
    try self.claimLeading(id);
    return id;
}

fn addTokenNode(self: *Parser, input: []const u8, token: Token) !AST.Node.Id {
    return self.addNode(try self.tokenKind(input, token), token.span);
}

fn tokenKind(self: *Parser, input: []const u8, token: Token) ParserError!AST.Node.Kind {
    const raw = token.source(input);
    return switch (token.kind) {
        .null_ => .null_,
        .true_, .false_ => .{ .boolean = try getBool(raw) },
        .string => .{ .string = try self.getString(raw) },
        .number => specialNumber(raw) orelse .{ .number = try getNumber(raw) },
        // A bare identifier is only a value when it spells `Infinity`/`NaN`.
        .identifier => specialNumber(raw) orelse return ParseError.UnexpectedToken,
        else => ParseError.UnexpectedToken,
    };
}

/// `Infinity`/`NaN` (optionally signed) lift to an extended `number_special`
/// node — no JSON number can hold a non-finite value. Returns null otherwise.
fn specialNumber(raw: []const u8) ?AST.Node.Kind {
    const body = if (raw.len > 0 and (raw[0] == '+' or raw[0] == '-')) raw[1..] else raw;
    if (std.mem.eql(u8, body, "Infinity") or std.mem.eql(u8, body, "NaN"))
        return .{ .extended = .{ .kind = .number_special, .text = raw } };
    return null;
}

/// Record the pending object key from a `.string` (quoted), `.identifier`
/// (unquoted), or bare keyword (`true`/`false`/`null`) token, then expect `:`.
fn beginKey(self: *Parser, input: []const u8, token: Token) ParserError!void {
    // Only quoted strings are legal keys in strict JSON; the rest are JSON5.
    if (token.kind != .string and self.format != .JSON5) return ParseError.UnexpectedToken;
    const key_id = try self.addKeyNode(input, token);
    const parent = &self.container_stack.items[self.container_stack.items.len - 1];
    parent.pending_key = key_id;
    self.state = .ExpectObjectColon;
}

/// Build a string-valued key node. A quoted string is decoded; an identifier or
/// keyword key is its verbatim source text.
fn addKeyNode(self: *Parser, input: []const u8, token: Token) ParserError!AST.Node.Id {
    const kind: AST.Node.Kind = switch (token.kind) {
        .string => .{ .string = try self.getString(token.source(input)) },
        .identifier, .true_, .false_, .null_ => .{ .string = token.source(input) },
        else => return ParseError.UnexpectedToken,
    };
    return self.addNode(kind, token.span);
}

/// Attaches a completed child to the current open container.
fn attachChild(self: *Parser, parent: *OpenContainer, child_id: AST.Node.Id) void {
    if (parent.first_child != null) {
        self.nodes.items[parent.last_child.?].next_sibling = child_id;
    } else {
        parent.first_child = child_id;
        switch (parent.kind) {
            .array => self.nodes.items[parent.id].kind = .{ .sequence = child_id },
            .object => self.nodes.items[parent.id].kind = .{ .mapping = child_id },
        }
    }
    parent.last_child = child_id;
}

fn finishValue(self: *Parser, value_id: AST.Node.Id) !void {
    // This value is now the trailing-comment candidate (the value node is the
    // trailing anchor for both array elements and object entries).
    self.last_value_id = value_id;
    // If there is no parent, the parsing is complete
    if (self.container_stack.items.len == 0) {
        self.root = value_id;
        self.state = .ExpectEndOfFile;
        return;
    }

    const parent = &self.container_stack.items[self.container_stack.items.len - 1];

    switch (parent.kind) {
        .array => {
            self.attachChild(parent, value_id);
            self.state = .ExpectArrayCommaOrEnd;
        },
        .object => {
            const key_id = parent.pending_key orelse return ParseError.UnexpectedToken;
            parent.pending_key = null;

            // Authoring-time lint: JSON permits duplicate keys within one
            // object (the spec does not forbid it), but every mainstream
            // parser keeps only the LAST value, so an earlier duplicate is
            // silently discarded — warn rather than stay silent about it (see
            // `Warning.Code.duplicate_key`).
            const key_span = self.node_spans.items[key_id];
            const key_text = self.nodes.items[key_id].kind.string;
            if (parent.seen_keys.contains(key_text)) {
                try self.warnings.append(self.allocator, .{ .code = .duplicate_key, .offset = key_span.start, .end = key_span.end });
            } else {
                try parent.seen_keys.put(self.allocator, key_text, {});
            }

            const value_span = self.node_spans.items[value_id];
            const pair_id = try self.addNode(.{ .keyvalue = .{
                .key = key_id,
                .value = value_id,
            } }, .{
                .start = key_span.start,
                .end = value_span.end,
            });

            self.attachChild(parent, pair_id);
            self.state = .ExpectObjectCommaOrEnd;
        },
    }
}

// ── comments ────────────────────────────────────────────────────────────────

/// Classify and attach the comment at `tokens[i]`. It trails the most recently
/// completed value when that value's trailing window is still open
/// (`last_value_id` set — no newline since) AND the comment is the last thing on
/// its line (`endsLine`). Otherwise it buffers as leading for the next node. The
/// `endsLine` test is what disambiguates `1, // trail` (trailing) from
/// `1, /*c*/ b` (leading of `b`).
fn handleComment(self: *Parser, input: []const u8, tokens: []const Token, i: usize) !void {
    const c = parseComment(tokens[i].source(input));
    const comment_start = tokens[i].span.start;
    if (self.last_value_id != null and endsLine(input, tokens, i)) {
        const id = self.last_value_id.?;
        self.last_value_id = null; // one trailing per value
        // A comment on the CLOSING line of a multi-line container (`]` / `}` then
        // `// c`) belongs at the bottom of the body, not on the value's line — so
        // it joins the container's `dangling` run rather than its `trailing`
        // (which is reserved for the opening line). An inline container, or a
        // scalar, keeps the same-line `trailing`.
        if (self.multilineContainer(input, id, comment_start)) {
            try self.appendDangling(id, c);
        } else {
            self.setTrailing(id, c);
        }
    } else if (endsLine(input, tokens, i) and self.container_stack.items.len > 0 and
        afterOpenDelimiter(input, tokens, i))
    {
        // `[ // note` / `{ // note` — the comment rides the line the container
        // opened on, so it trails the container value (mirrors YAML's `key: #`).
        self.setTrailing(self.container_stack.items[self.container_stack.items.len - 1].id, c);
    } else {
        try self.pending_leading.append(self.allocator, c);
    }
}

/// Whether the comment at `tokens[i]` is the last content on its source line —
/// i.e. the next significant token is a newline, a comma, or a closing
/// delimiter / EOF. A value/key (or another comment) appearing first on the same
/// line means this comment instead leads that following content.
fn endsLine(input: []const u8, tokens: []const Token, i: usize) bool {
    var j = i + 1;
    while (j < tokens.len) : (j += 1) {
        switch (tokens[j].kind) {
            .whitespace => {
                if (std.mem.indexOfScalar(u8, input[tokens[j].span.start..tokens[j].span.end], '\n') != null)
                    return true;
            },
            .comma, .close_brace, .close_bracket, .end_of_file => return true,
            else => return false,
        }
    }
    return true;
}

/// Whether the most recent significant token before `tokens[i]`, on the same
/// line, is a container-opening `[`/`{`. Identifies a comment that rides the
/// line a container opened on (`[ // c`), which trails the container value.
fn afterOpenDelimiter(input: []const u8, tokens: []const Token, i: usize) bool {
    var j = i;
    while (j > 0) {
        j -= 1;
        switch (tokens[j].kind) {
            .whitespace => {
                if (std.mem.indexOfScalar(u8, input[tokens[j].span.start..tokens[j].span.end], '\n') != null)
                    return false; // crossed a newline → not the open line
            },
            .open_bracket, .open_brace => return true,
            else => return false,
        }
    }
    return false;
}

/// Strip the markers from a comment token's raw bytes (which borrow `input`) and
/// classify line vs block.
fn parseComment(raw: []const u8) AST.Comment {
    if (raw.len >= 2 and raw[1] == '*') {
        // `/* … */` — the tokenizer guarantees the closing `*/`.
        return .{ .text = std.mem.trim(u8, raw[2 .. raw.len - 2], " \t\r\n"), .style = .block };
    }
    // `// …` to end of line.
    return .{ .text = std.mem.trim(u8, raw[2..], " \t\r"), .style = .line };
}

/// Hand the buffered leading comments to node `id`, transferring ownership of
/// the slice. No-op when nothing is buffered.
fn claimLeading(self: *Parser, id: AST.Node.Id) !void {
    if (self.pending_leading.items.len == 0) return;
    const owned = try self.pending_leading.toOwnedSlice(self.allocator);
    self.pending_leading = .empty;
    self.node_comments.items[id].leading = owned;
    self.comments_seen = true;
}

fn setTrailing(self: *Parser, id: AST.Node.Id, c: AST.Comment) void {
    self.node_comments.items[id].trailing = c;
    self.comments_seen = true;
}

/// Whether `id` is a container whose opening delimiter is on an earlier line than
/// `comment_start` — i.e. a multi-line `[ … ]`/`{ … }` whose close is on the
/// comment's line. (An inline, single-line container returns false.)
fn multilineContainer(self: *Parser, input: []const u8, id: AST.Node.Id, comment_start: usize) bool {
    switch (self.nodes.items[id].kind) {
        .sequence, .mapping => {},
        else => return false,
    }
    const open = self.node_spans.items[id].start;
    if (comment_start <= open) return false;
    return std.mem.indexOfScalar(u8, input[open..comment_start], '\n') != null;
}

/// Append one comment to `id`'s existing `dangling` run (reallocating). Used for
/// a closing-line comment that follows the orphans already claimed at the close.
fn appendDangling(self: *Parser, id: AST.Node.Id, c: AST.Comment) !void {
    const old = self.node_comments.items[id].dangling;
    const grown = try self.allocator.alloc(AST.Comment, old.len + 1);
    @memcpy(grown[0..old.len], old);
    grown[old.len] = c;
    self.allocator.free(old);
    self.node_comments.items[id].dangling = grown;
    self.comments_seen = true;
}

/// Hand buffered orphan comments (no node followed them, e.g. before a closing
/// delimiter or at EOF) to container `id` as its `dangling` run.
fn claimDangling(self: *Parser, id: AST.Node.Id) !void {
    if (self.pending_leading.items.len == 0) return;
    const owned = try self.pending_leading.toOwnedSlice(self.allocator);
    self.pending_leading = .empty;
    self.node_comments.items[id].dangling = owned;
    self.comments_seen = true;
}

/// Pushes stack metadata for a container node that already exists in self.nodes
fn openContainer(self: *Parser, kind: ContainerKind, node_id: AST.Node.Id) !void {
    try self.container_stack.append(self.allocator, .{
        .id = node_id,
        .kind = kind,
    });
}

/// Pops the current container, patches its span end, and returns the node ID.
/// Orphan comments buffered before the close delimiter become the container's
/// `dangling` run.
fn closeContainer(self: *Parser, span_end: usize) !AST.Node.Id {
    if (self.container_stack.items.len == 0) return ParseError.UnexpectedToken;
    var container = self.container_stack.pop().?;
    container.seen_keys.deinit(self.allocator);
    self.node_spans.items[container.id].end = span_end;
    try self.claimDangling(container.id);
    return container.id;
}

// =======
// Testing
// =======

fn testParser(input: []const u8, expected: AST) !void {
    var ast = try Parser.parseAbstract(testing.allocator, input, .JSON);
    defer ast.deinit();
    try testing.expect(expected.eql(ast));
}

fn testParserError(input: []const u8, expected_error: anyerror) !void {
    if (Parser.parseAbstract(testing.allocator, input, .JSON)) |ast| {
        var parsed = ast;
        defer parsed.deinit();
        try testing.expect(false);
    } else |err| {
        try testing.expectEqual(expected_error, err);
    }
}

test "simple JSON document" {
    try testParser(
        \\[{"hello":"world"}]
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

test "decodes JSON string escapes" {
    var ast = try Parser.parseAbstract(testing.allocator, "\"quote: \\\" slash: \\\\ newline: \\n tab: \\t backspace: \\b formfeed: \\f slash: \\/\"", .JSON);
    defer ast.deinit();

    const value = switch (ast.nodes[ast.root].kind) {
        .string => |string| string,
        else => return error.TestUnexpectedResult,
    };

    try testing.expectEqualSlices(u8, "quote: \" slash: \\ newline: \n tab: \t backspace: \x08 formfeed: \x0c slash: /", value);
}

test "decodes JSON unicode escapes" {
    var ast = try Parser.parseAbstract(testing.allocator, "\"A: \\u0041 latin: \\u00E9 clef: \\uD834\\uDD1E\"", .JSON);
    defer ast.deinit();

    const value = switch (ast.nodes[ast.root].kind) {
        .string => |string| string,
        else => return error.TestUnexpectedResult,
    };

    try testing.expectEqualSlices(u8, "A: A latin: é clef: 𝄞", value);
}

test "decodes escaped object keys" {
    var ast = try Parser.parseAbstract(testing.allocator, "{\"he\\u006clo\":1}", .JSON);
    defer ast.deinit();

    const value = try ast.getValByPath(&.{.{ .key = "hello" }});
    const number = switch (value.kind) {
        .number => |number| number,
        else => return error.TestUnexpectedResult,
    };

    try testing.expectEqualSlices(u8, "1", number.raw);
}

test "preserves unpaired unicode surrogate escapes as raw strings" {
    try testParser(
        "\"\\uD800\"",
        .{ .allocator = testing.allocator, .root = 0, .nodes = &[_]AST.Node{
            .{ .id = 0, .kind = .{ .string = "\\uD800" }, .next_sibling = null },
        } },
    );
    try testParser(
        "\"\\uDC00\"",
        .{ .allocator = testing.allocator, .root = 0, .nodes = &[_]AST.Node{
            .{ .id = 0, .kind = .{ .string = "\\uDC00" }, .next_sibling = null },
        } },
    );
    try testParser(
        "\"\\uD800x\"",
        .{ .allocator = testing.allocator, .root = 0, .nodes = &[_]AST.Node{
            .{ .id = 0, .kind = .{ .string = "\\uD800x" }, .next_sibling = null },
        } },
    );
    try testParser(
        "\"\\uD800\\u0041\"",
        .{ .allocator = testing.allocator, .root = 0, .nodes = &[_]AST.Node{
            .{ .id = 0, .kind = .{ .string = "\\uD800\\u0041" }, .next_sibling = null },
        } },
    );
}

test "UTF-8 BOM before document is ignored" {
    try testParser(
        "\xEF\xBB\xBF{}",
        .{ .allocator = testing.allocator, .root = 0, .nodes = &[_]AST.Node{
            .{ .id = 0, .kind = .{ .mapping = null }, .next_sibling = null },
        } },
    );
}

test "object trailing comma is rejected" {
    try testParserError("{\"a\":1,}", error.UnexpectedToken);
}

// ── JSON5 ────────────────────────────────────────────────────────────────────

fn parseJson5(input: []const u8) !AST {
    return Parser.parseAbstract(testing.allocator, input, .JSON5);
}

test "json5: trailing commas accepted (and still rejected in strict JSON)" {
    var arr = try parseJson5("[1,2,]");
    defer arr.deinit();
    try testing.expectEqual(@as(usize, 2), countItems(arr, arr.root));

    var obj = try parseJson5("{a:1,}");
    defer obj.deinit();
    try testing.expectEqual(@as(usize, 1), countItems(obj, obj.root));

    // Strict JSON keeps rejecting both.
    try testParserError("[1,2,]", error.UnexpectedToken);
    try testParserError("{\"a\":1,}", error.UnexpectedToken);
}

test "json5: leading comma is still rejected" {
    try testJson5Error("[,1]", error.UnexpectedToken);
    try testJson5Error("[,]", error.UnexpectedToken);
}

test "json5: unquoted and keyword object keys" {
    var ast = try parseJson5("{ hello: 1, $_$9: 2, while: 3, null: 4 }");
    defer ast.deinit();
    inline for (.{ "hello", "$_$9", "while", "null" }) |k| {
        const v = try ast.getValByPath(&.{.{ .key = k }});
        try testing.expect(v.kind == .number);
    }
}

test "json5: single-quoted strings, escapes, and line continuation" {
    var a = try parseJson5("'I can\\'t'");
    defer a.deinit();
    try testing.expectEqualSlices(u8, "I can't", a.nodes[a.root].kind.string);

    var b = try parseJson5("'line 1 \\\nline 2'");
    defer b.deinit();
    try testing.expectEqualSlices(u8, "line 1 line 2", b.nodes[b.root].kind.string);
}

test "json5: Infinity and NaN become extended number_special" {
    inline for (.{ "Infinity", "-Infinity", "+Infinity", "NaN" }) |lit| {
        var ast = try parseJson5(lit);
        defer ast.deinit();
        const k = ast.nodes[ast.root].kind;
        try testing.expect(k == .extended and k.extended.kind == .number_special);
        try testing.expectEqualSlices(u8, lit, k.extended.text);
    }
}

test "json5: hexadecimal, leading/trailing point, and signed numbers" {
    const cases = .{
        .{ "0xC8", AST.Node.Kind.Number{ .raw = "0xC8", .kind = .integer } },
        .{ "0xc8e4", AST.Node.Kind.Number{ .raw = "0xc8e4", .kind = .integer } },
        .{ "+15", AST.Node.Kind.Number{ .raw = "+15", .kind = .integer } },
        .{ ".5", AST.Node.Kind.Number{ .raw = ".5", .kind = .float } },
        .{ "5.", AST.Node.Kind.Number{ .raw = "5.", .kind = .float } },
    };
    inline for (cases) |c| {
        var ast = try parseJson5(c[0]);
        defer ast.deinit();
        const n = ast.nodes[ast.root].kind.number;
        try testing.expectEqual(c[1].kind, n.kind);
        try testing.expectEqualSlices(u8, c[1].raw, n.raw);
    }
}

test "json5: octal and lone-decimal forms are rejected" {
    try testJson5Error("010", error.LeadingZero);
    try testJson5Error("0x", error.UnexpectedToken);
    try testJson5Error(".", error.UnexpectedToken);
    try testJson5Error("+098", error.LeadingZero);
}

fn testJson5Error(input: []const u8, expected_error: anyerror) !void {
    if (Parser.parseAbstract(testing.allocator, input, .JSON5)) |ast| {
        var parsed = ast;
        defer parsed.deinit();
        try testing.expect(false);
    } else |err| {
        try testing.expectEqual(expected_error, err);
    }
}

test "json5: captures leading, trailing, line and block comments" {
    var ast = try parseJson5(
        \\{
        \\  // leading on a
        \\  a: 1, // trailing on a
        \\  /* block before b */
        \\  b: [
        \\    2 /* trailing block on 2 */,
        \\    3 // trailing on 3
        \\  ]
        \\}
    );
    defer ast.deinit();

    const root = ast.nodes[ast.root];
    const kv_a = ast.nodes[root.kind.mapping.?].kind.keyvalue;
    // Leading binds to the key, trailing to the value.
    try testing.expectEqualStrings("leading on a", ast.comments(kv_a.key).leading[0].text);
    try testing.expectEqualStrings("trailing on a", ast.comments(kv_a.value).trailing.?.text);

    const kv_b = ast.nodes[ast.nodes[root.kind.mapping.?].next_sibling.?].kind.keyvalue;
    try testing.expectEqualStrings("block before b", ast.comments(kv_b.key).leading[0].text);
    try testing.expect(ast.comments(kv_b.key).leading[0].style == .block);

    const seq = ast.nodes[kv_b.value];
    const e2 = ast.nodes[seq.kind.sequence.?];
    const e3 = ast.nodes[e2.next_sibling.?];
    try testing.expectEqualStrings("trailing block on 2", ast.comments(e2.id).trailing.?.text);
    try testing.expect(ast.comments(e2.id).trailing.?.style == .block);
    try testing.expectEqualStrings("trailing on 3", ast.comments(e3.id).trailing.?.text);
}

test "json5: post-comma comment leads the next entry, not trails the previous" {
    // The classic ambiguity: `1, /*c*/ b` — the comma closes 1's trailing window,
    // so `c` must lead `b`.
    var ast = try parseJson5("{ a: 1, /* c */ b: 2 }");
    defer ast.deinit();
    const root = ast.nodes[ast.root];
    const kv_a = ast.nodes[root.kind.mapping.?].kind.keyvalue;
    const kv_b = ast.nodes[ast.nodes[root.kind.mapping.?].next_sibling.?].kind.keyvalue;
    try testing.expect(ast.comments(kv_a.value).trailing == null);
    try testing.expectEqualStrings("c", ast.comments(kv_b.key).leading[0].text);
}

test "json5: comment-free document carries no comment table" {
    var ast = try parseJson5("{ a: 1, b: [2, 3] }");
    defer ast.deinit();
    try testing.expectEqual(@as(usize, 0), ast.node_comments.len);
}

// ── diagnostics ──────────────────────────────────────────────────────────────

test "parseWithReport anchors the diagnostic on the offending token" {
    var report: Report = .{};
    // `{"a": }` — the value slot is empty; the `}` is the unexpected token.
    const src = "{\"a\": }";
    try testing.expectError(error.UnexpectedToken, Parser.parseWithReport(testing.allocator, src, .JSON, &report));
    defer testing.allocator.free(report.warnings);
    const d = report.diag.?;
    try testing.expectEqual(error.UnexpectedToken, d.code);
    try testing.expectEqual(@as(usize, 6), d.offset); // the `}`
    try testing.expectEqual(@as(usize, 0), report.errors.len); // single-shot: no recovery
}

test "parseWithReport reports the tokenizer's own failures with a location" {
    var report: Report = .{};
    const src = "{\"a\": \"unterminated}";
    try testing.expectError(error.UnclosedString, Parser.parseWithReport(testing.allocator, src, .JSON, &report));
    defer testing.allocator.free(report.warnings);
    const d = report.diag.?;
    try testing.expectEqual(error.UnclosedString, d.code);
}

test "parseCollecting reports every error in one pass" {
    var report: Report = .{};
    // Three malformed entries in one object, using only lexically-valid
    // tokens (a bare identifier like `bogus` would fail at the TOKENIZER
    // stage in strict JSON, which is never recoverable — see `parse_once`'s
    // doc comment; these are genuine PARSER-level placement mistakes): a
    // missing value (`,` where `ExpectObjectValue` wants one), a stray number
    // before the next comma, and another stray number before the close.
    // Strict JSON should surface all three, not just the first.
    const src = "{\"a\": , \"b\": 1 2, \"c\": 3 4}";
    defer if (report.errors.len > 0) testing.allocator.free(report.errors);
    defer testing.allocator.free(report.warnings);
    try testing.expectError(error.UnexpectedToken, Parser.parseCollecting(testing.allocator, src, .JSON, &report));
    try testing.expectEqual(@as(usize, 3), report.errors.len);
    // Errors are recorded in source order.
    var last_offset: usize = 0;
    for (report.errors) |d| {
        try testing.expectEqual(error.UnexpectedToken, d.code);
        try testing.expect(d.offset >= last_offset);
        last_offset = d.offset;
    }
}

test "parseCollecting still recovers a trailing well-formed key/value after a broken one" {
    var report: Report = .{};
    defer if (report.errors.len > 0) testing.allocator.free(report.errors);
    defer testing.allocator.free(report.warnings);
    const src = "{\"bad\": , \"good\": 42}";
    try testing.expectError(error.UnexpectedToken, Parser.parseCollecting(testing.allocator, src, .JSON, &report));
    try testing.expectEqual(@as(usize, 1), report.errors.len);
}

test "parseCollecting terminates on a mismatched closer instead of looping forever" {
    // `]` while an OBJECT is open (not an array) is garbage at that position —
    // `resync` must not treat it as a valid sync point just because SOME
    // container happens to be open (see `resync`'s doc comment); otherwise
    // dispatch rejects the same token forever.
    var report: Report = .{};
    defer if (report.errors.len > 0) testing.allocator.free(report.errors);
    defer testing.allocator.free(report.warnings);
    const src = "{\"a\":1]";
    try testing.expectError(error.UnexpectedToken, Parser.parseCollecting(testing.allocator, src, .JSON, &report));
    try testing.expect(report.errors.len >= 1);

    // The reverse shape: `}` while an ARRAY is open.
    var report2: Report = .{};
    defer if (report2.errors.len > 0) testing.allocator.free(report2.errors);
    defer testing.allocator.free(report2.warnings);
    const src2 = "[1}";
    try testing.expectError(error.UnexpectedToken, Parser.parseCollecting(testing.allocator, src2, .JSON, &report2));
    try testing.expect(report2.errors.len >= 1);
}

test "duplicate object key warns without failing the parse" {
    var report: Report = .{};
    var ast = try Parser.parseWithReport(testing.allocator, "{\"a\": 1, \"a\": 2}", .JSON, &report);
    defer ast.deinit(testing.allocator);
    defer testing.allocator.free(report.warnings);
    try testing.expectEqual(@as(usize, 1), report.warnings.len);
    try testing.expectEqual(Warning.Code.duplicate_key, report.warnings[0].code);
    // The warning anchors on the SECOND (repeated) key, not the first.
    try testing.expectEqual(@as(usize, 9), report.warnings[0].offset);
}

test "no duplicate-key warning across sibling objects, or for array elements" {
    var report: Report = .{};
    var ast = try Parser.parseWithReport(testing.allocator, "[{\"a\": 1}, {\"a\": 2}]", .JSON, &report);
    defer ast.deinit(testing.allocator);
    defer testing.allocator.free(report.warnings);
    try testing.expectEqual(@as(usize, 0), report.warnings.len);
}

test "describe and shortLabel cover every Error variant" {
    // Exhaustiveness is enforced by the compiler (the switches in `describe`/
    // `shortLabel` must cover every `Error` member); this just checks a
    // sample renders non-empty teaching text.
    try testing.expect(describe(error.UnexpectedToken).len > 0);
    try testing.expect(shortLabel(error.LeadingZero).len > 0);
}

fn countItems(ast: AST, container: AST.Node.Id) usize {
    var n: usize = 0;
    var cur = switch (ast.nodes[container].kind) {
        .sequence, .mapping => |first| first,
        else => return 0,
    };
    while (cur) |id| : (cur = ast.nodes[id].next_sibling) n += 1;
    return n;
}
