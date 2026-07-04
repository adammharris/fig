//! Shared parse-diagnostic rendering — the language-agnostic half of fig's
//! diagnostic system (see `languages/fig/parser.zig`'s `Location`/`Diagnostic`/
//! `Warning`, and DESIGN.md's "Authoring-time diagnostics"): locating a byte
//! offset in source text, and rendering the compiler-style `file:line:col:
//! label: message` report.
//!
//! Each language keeps its OWN `Error`/`Warning.Code` enums and `describe()`/
//! `shortLabel()` teaching-message functions (the failure modes differ per
//! format) and its own trivial `Diagnostic { code, offset, end }` /
//! `Report { diag, errors, warnings }` shape (duplicating a 3-field struct
//! per language costs nothing; duplicating the caret-rendering *behavior*
//! would). Only that offset-independent-of-code machinery lives here — fig's
//! parser re-exports `Location`/`locateOffset` from this module too (see its
//! own doc comment), so there is exactly one implementation of "find
//! line/col for a byte offset" in the whole codebase, not one per language.
//!
//! `Rendered` is the CLI/LSP-facing product: a language's `Diagnostic`/
//! `Warning` (which carries a typed `code` only that language's `describe`/
//! `shortLabel` know how to read) gets converted to a plain `Rendered` once,
//! right after parsing — so any generic consumer (the CLI's cargo-style
//! `printDiag` in `main.zig`, a future generalized language server) needs no
//! per-language knowledge at all.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// 1-based line/column plus the full offending source line.
pub const Location = struct { line: usize, column: usize, line_text: []const u8 };

/// Locate `offset` in `source`. A cursor resting exactly past a newline means
/// the problem was detected while finishing the previous line (an unclosed
/// container at EOF, a duplicate key noticed only once the value is attached,
/// …) — report end-of-that-line, not column 1 of an empty next one.
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

/// The compiler-style report every language shares: `file:line:col: <label>:
/// <message>`, then the offending source line and a caret marking the column.
/// Plain/colorless — the CLI's `printDiag` (`main.zig`) lays a fancier
/// cargo/rustc-style caret report on top of `locateOffset` directly instead of
/// calling this; this form is for plain-text consumers (library callers,
/// tests, anything that just wants a string).
pub fn renderReport(w: *std.Io.Writer, loc: Location, file: []const u8, label: []const u8, message: []const u8) std.Io.Writer.Error!void {
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

/// `renderReport`, allocating the result. Caller owns the returned bytes.
pub fn renderReportAlloc(allocator: Allocator, source: []const u8, offset: usize, file: []const u8, label: []const u8, message: []const u8) Allocator.Error![]u8 {
    const loc = locateOffset(source, offset);
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    renderReport(&aw.writer, loc, file, label, message) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

/// A fully-resolved diagnostic ready for CLI/LSP rendering — language-agnostic.
/// Pairs a parse-time `[offset, end)` span with the language's own
/// `describe(code)` (long teaching message) / `shortLabel(code)` (a few words,
/// for a caret annotation) strings, computed once at the call site right after
/// parsing.
pub const Rendered = struct {
    offset: usize,
    end: ?usize = null,
    message: []const u8,
    short_label: []const u8,
};

const testing = std.testing;

test "locateOffset finds line/column and backtracks past a trailing newline" {
    const src = "abc\ndef\nghi";
    var loc = locateOffset(src, 5); // 'e' on line 2
    try testing.expectEqual(@as(usize, 2), loc.line);
    try testing.expectEqual(@as(usize, 2), loc.column);
    try testing.expectEqualStrings("def", loc.line_text);

    // Resting exactly past a newline (e.g. an EOF right after "abc\n") reports
    // the end of the PREVIOUS line, not column 1 of an empty next one.
    loc = locateOffset("abc\n", 4);
    try testing.expectEqual(@as(usize, 1), loc.line);
    try testing.expectEqual(@as(usize, 4), loc.column);
    try testing.expectEqualStrings("abc", loc.line_text);
}

test "renderReportAlloc renders file:line:col plus the source line and caret" {
    const rendered = try renderReportAlloc(testing.allocator, "x = 1\ny = ?\n", 4, "test.txt", "error", "bad value");
    defer testing.allocator.free(rendered);
    try testing.expectEqualStrings(
        "test.txt:1:5: error: bad value\n    x = 1\n        ^\n",
        rendered,
    );
}
