//! CLI-only teaching-style diagnostic rendering: cargo/rustc-shaped
//! `file:line:col` reports with a source-line gutter and a colored
//! underline, plus the shared `--quiet`/`--strict` warning contract every
//! action's parse path uses. This is a presentation layer over the
//! language-agnostic `fig.ParseDiagnostic.Rendered` shape — it never knows
//! about a specific language's own `Diagnostic`/`Warning` types beyond the
//! `describe`/`shortLabel` functions passed in by the caller.
const std = @import("std");
const fig = @import("fig");
const Io = std.Io;

/// Print a teaching report straight to `term`, cargo/rustc-style:
///   <label>: <message>
///   --> <file>:<line>:<col>
///    |
///   7 | <source line>
///    |          ~~~~ <short_label>
/// highlighting the reported `[offset, end)` span (a `~~~~` underline, or a
/// single `^` when `end` is null or the span is one byte), coloring the label
/// word and the highlight+`short_label` in `color`, and the `-->` pointer plus
/// the `N |` gutter in blue. Language-agnostic (every field is plain data —
/// see `fig.ParseDiagnostic.Rendered`), so every covered language (fig, JSON,
/// TOML/YAML to come) renders through this one function; only `renderAll`'s
/// per-language `describe`/`shortLabel` calls differ. This is a CLI-only
/// sibling of a language's own `Diagnostic.renderAlloc`/`Warning.renderAlloc`
/// (see `languages/fig/parser.zig`'s private `renderReportAlloc`, which still
/// produces its own plain `file:line:col: <label>: <message>` shape) — not a
/// replacement: the library's `renderAlloc` stays a plain, colorless string for
/// every other caller (the LSP reads the structured `code`/`offset` fields
/// directly and never calls it; the C ABI's `FigWarning`/`FigError` are plain
/// data too), so nothing outside this binary is affected by adding color or
/// reshaping the layout here.
///
/// Deliberately never buffered into an intermediate string: under
/// `Io.Terminal.Mode.windows_api`, `setColor` sets the real console's text
/// attributes via a direct syscall rather than writing escape bytes into the
/// stream, so it only works called live against the real terminal — see
/// `std.Io.Terminal.setColor`.
pub fn printDiag(term: *Io.Terminal, source: []const u8, file: []const u8, offset: usize, end: ?usize, label: []const u8, color: Io.Terminal.Color, message: []const u8, short_label: []const u8) !void {
    const loc = fig.ParseDiagnostic.locateOffset(source, offset);
    try term.setColor(color);
    try term.writer.writeAll(label);
    try term.setColor(.reset);
    try term.writer.print(": {s}\n", .{message});
    try term.setColor(.blue);
    try term.writer.writeAll("--> ");
    try term.setColor(.reset);
    try term.writer.print("{s}:{d}:{d}\n", .{ file, loc.line, loc.column });

    // Mirrors `renderReport`'s source-line + caret, but in the cargo/rustc
    // gutter shape: a blank `|` line, the numbered source line, then a
    // highlight line under the offending span carrying `short_label`. Capped
    // so a pathological line can't flood the terminal; the highlight mirrors
    // tabs in the source to stay aligned under them. The gutter's width
    // tracks the line number's digit count so the blank/highlight `|` lines
    // up under the source line's `|`.
    const max_shown = 160;
    const shown = loc.line_text[0..@min(loc.line_text.len, max_shown)];
    if (shown.len == 0) return; // EOF/blank line: nothing to point into

    var line_num_buf: [20]u8 = undefined;
    const line_num = std.fmt.bufPrint(&line_num_buf, "{d}", .{loc.line}) catch unreachable;

    try term.setColor(.blue);
    try term.writer.splatByteAll(' ', line_num.len);
    try term.writer.writeAll(" |\n");
    try term.writer.print("{s} | ", .{line_num});
    try term.setColor(.reset);
    try term.writer.print("{s}{s}\n", .{ shown, if (shown.len < loc.line_text.len) "…" else "" });

    if (loc.column - 1 <= shown.len) {
        try term.setColor(.blue);
        try term.writer.splatByteAll(' ', line_num.len);
        try term.writer.writeAll(" | ");
        try term.setColor(.reset);
        for (shown[0 .. loc.column - 1]) |c| try term.writer.writeByte(if (c == '\t') '\t' else ' ');
        try term.setColor(color);
        // Highlight the reported `[offset, end)` span rather than a single
        // point: a `~~~~` underline when the parser gave a real multi-byte
        // extent (`end`), a single `^` when it didn't (fall back to "just the
        // start") or when the span is exactly one byte — matching how a `^`
        // and a `~~~~` read identically for a one-character span anyway.
        // Never runs past the portion of the line actually printed above.
        const span_len = if (end) |e| (if (e > offset) e - offset else 1) else 1;
        const draw_len = @max(1, @min(span_len, shown.len - (loc.column - 1)));
        if (draw_len <= 1) {
            try term.writer.writeAll("^");
        } else {
            try term.writer.splatByteAll('~', draw_len);
        }
        try term.writer.print(" {s}\n", .{short_label});
        try term.setColor(.reset);
    }
}

/// Convert a language's own `Diagnostic`/`Warning` slice (each carries a typed
/// `code` that only that language's `describe`/`shortLabel`-shaped functions
/// know how to read) into the language-agnostic `fig.ParseDiagnostic.Rendered`
/// shape `printDiag` and the `check` action work with — computed once, right
/// after parsing, so nothing downstream needs per-language knowledge. `items`
/// is any `[]const T` for a `T` with `{ code, offset, end }` fields (a
/// language's `Diagnostic` or `Warning`); `describeFn`/`labelFn` are that
/// type's own `describe`/`shortLabel`-shaped functions. Allocates with `a`
/// (the CLI's arena — never freed individually, same as the reports this
/// replaces).
pub fn renderAll(a: std.mem.Allocator, items: anytype, comptime describeFn: anytype, comptime labelFn: anytype) ![]const fig.ParseDiagnostic.Rendered {
    const out = try a.alloc(fig.ParseDiagnostic.Rendered, items.len);
    for (items, 0..) |it, i| out[i] = .{ .offset = it.offset, .end = it.end, .message = describeFn(it.code), .short_label = labelFn(it.code) };
    return out;
}

/// Render one parse failure as a `printDiag` teaching report and exit(2) — the
/// `get`-time twin of `check`'s per-error loop, for the single diagnostic a
/// non-recovering parse produces. Shared by every language with a `Report`
/// (fig, JSON; TOML/YAML to come) so `get`'s error path doesn't repeat this
/// print-flush-exit sequence per language.
pub fn reportParseError(term: *Io.Terminal, source: []const u8, file: []const u8, offset: usize, end: ?usize, message: []const u8, short_label: []const u8) !void {
    try printDiag(term, source, file, offset, end, "error", .red, message, short_label);
    try term.writer.flush();
    std.process.exit(2);
}

/// A scalar/null value reaching the fig printer as a document root has no
/// authoring spelling there (`languages/fig/printer.zig`'s `root` hard-errors
/// with `FigUnrepresentableRoot` rather than emit non-conforming output) — print
/// the teaching message and exit(1) here rather than let the raw error escape
/// to `main`'s top level. Letting it escape would still work, but would print
/// nothing but a bare Zig stack trace: `main`'s return-error path and this
/// function share one positional writer over stderr's fd, while an escaping
/// error is reported through the Zig runtime's OWN separate stderr writer (the
/// same `debug_io`-vs-`stderr_terminal` split documented in `cli/main.zig` for
/// `std.log`) — on redirection, whichever writes second silently clobbers the
/// first from byte 0, so any warning already printed disappears too. Exiting
/// here, like every other user-facing CLI failure in this binary, sidesteps
/// that entirely.
pub fn reportFigUnrepresentableRoot(term: *Io.Terminal) noreturn {
    term.writer.writeAll("error: a scalar value cannot be the root of a .fig/.figl document; use canonical form or another output format instead (see docs/spec.md § 2).\n") catch {};
    term.writer.flush() catch {};
    std.process.exit(1);
}

/// Every OTHER way a printer can fail — a value/shape the target format has no
/// spelling for at all (an array/nested table reaching INI/dotenv/`.properties`,
/// a non-identifier dotenv key, an XML document with more than one root key,
/// a non-string mapping key reaching TOML/ZON/XML, ...). Exhaustive over
/// `fig.AST.SerializeError` so a NEW variant is a compile error here rather
/// than silently falling through to a crash. `FigUnrepresentableRoot` is
/// included for completeness (a call site that forgets to special-case it
/// separately still gets a decent message) even though every current call
/// site intercepts it first via `reportFigUnrepresentableRoot`'s more specific
/// wording. Same reasoning as that function for why this exits here instead
/// of letting the error escape to `main`'s top level: an escaping error
/// prints nothing but a bare, unreadable Zig stack trace (see its doc).
pub fn reportSerializeError(term: *Io.Terminal, err: fig.AST.SerializeError) noreturn {
    const message: []const u8 = switch (err) {
        error.WriteFailed => "failed to write output",
        error.UnresolvedAlias => "an unresolved YAML alias reached the printer (internal error — please report this)",
        error.NullUnsupported => "a `null` value has no representation in this output format",
        error.NonStringKey => "a non-string mapping key has no representation in this output format",
        error.FormatDisabled => "the requested format was not compiled into this build",
        error.NestingTooDeep => "this document nests too deeply for the canonical printer's depth guard",
        error.RootNotSingleElement => "an XML document's root must be a mapping with exactly one key",
        error.NestedSequenceUnsupported => "an array with no enclosing key name has no XML representation",
        error.InvalidElementName => "a mapping key is not a valid XML element name",
        error.NonScalarValue => "an `@`-attribute or `#text` entry must be a plain scalar in XML",
        error.UnexpectedNodeKind => "an internal fig printer error occurred (please report this)",
        error.FigUnrepresentableRoot => "a scalar value cannot be the root of a .fig/.figl document; use canonical form or another output format instead (see docs/spec.md § 2)",
        error.UnsupportedValue => "this document contains an array, or a table nested deeper than this format allows (INI: one level of `[section]`; dotenv/`.properties`: none)",
        error.InvalidKey => "a mapping key is not valid in this output format (a dotenv key must be a bash identifier: `[A-Za-z_][A-Za-z0-9_]*`)",
    };
    term.writer.print("error: {s}\n", .{message}) catch {};
    term.writer.flush() catch {};
    std.process.exit(1);
}

/// Print every parse-time authoring warning in `warnings` (unless `--quiet`),
/// then exit(2) if `--strict` and any fired — `get`'s shared `--quiet`/
/// `--strict` contract for a language's authoring-time lints (fig's, JSON's
/// `duplicate_key`, …), so each language's call site is one line instead of
/// repeating the print/flush/strict-abort sequence.
pub fn handleParseWarnings(term: *Io.Terminal, source: []const u8, file: []const u8, kind_name: []const u8, warnings: anytype, comptime describeFn: anytype, comptime labelFn: anytype, quiet: bool, strict: bool) !void {
    if (warnings.len == 0) return;
    if (!quiet) {
        for (warnings) |w| try printDiag(term, source, file, w.offset, w.end, "warning", .yellow, describeFn(w.code), labelFn(w.code));
        try term.writer.flush();
    }
    if (strict) {
        try term.writer.print("error: {d} {s} warning(s); --strict aborts.\n", .{ warnings.len, kind_name });
        try term.writer.flush();
        std.process.exit(2);
    }
}
