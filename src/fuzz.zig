//! Fuzz targets for the hand-written tokenizers and parsers.
//!
//! Test-only: this module is reachable solely from `root.zig`'s `test {}` block,
//! so nothing here is analyzed in a library/CLI/wasm build. That is also what
//! makes the canonical oracle below unconditionally available — every call site
//! gates it as `lang_canonical or @import("builtin").is_test` (see
//! `ast/serialize_options.zig`), and `is_test` always holds here, so the target
//! needs no `-Dcanonical=true`.
//!
//! Two targets, deliberately split by what they can prove:
//!
//!   * `detect` — BREADTH. `Language.detect` runs every compiled-in parser over
//!     the same bytes (see its ordering note), so one target sweeps all eleven
//!     grammars for crashes, hangs, and leaks. It cannot check correctness: the
//!     result is just an enum, and each probe throws its Document away.
//!
//!   * canonical round-trip — DEPTH. The canonical form is a bijection with the
//!     AST (`canonical/canonical.zig`), which is the one property strong enough
//!     to catch a SILENT mis-parse — a parser that accepts input and builds the
//!     wrong tree. `detect` would never notice.
//!
//! Neither asserts `parse -> print == original`: printers render from the AST,
//! not the borrowed `Document.source`, so byte-identical output is not a
//! property of this codebase and asserting it would only encode today's
//! formatting. The reprint check below is idempotence — a weaker, true claim.
//!
//! Run: `zig build test` runs both as deterministic smoke tests (the empty-tape
//! case, plus any corpus). Real fuzzing needs the `fuzz` step.
//!
//! On Zig 0.16's fuzz API: `testOne` receives a `*std.testing.Smith` — a
//! structured generator — NOT the input slice older versions passed. The bytes
//! under test are synthesized here, from Smith decisions. The corollary is a
//! trap worth stating outright: `FuzzInputOptions.corpus` entries are Smith
//! DECISION TAPES, not source text, so the fixtures under `testdata/` cannot be
//! seeded as a corpus — they are ordinary files, and the conformance suites
//! already read them as such. Modeled on `std/zig/tokenizer.zig`'s own fuzz test.

const std = @import("std");

const Canonical = @import("canonical/canonical.zig");
const Language = @import("languages/language.zig");

/// Byte weights shaping random input into something the parsers will actually
/// walk into rather than reject on the first token. The first entry must span
/// the full range (`Smith` asserts every later entry falls inside it) and stays
/// at weight 1: it is what still reaches the tokenizers' invalid-UTF-8 and
/// control-byte paths, which are exactly where a hand-written scanner tends to
/// run off the end of its buffer.
///
/// Everything after it is a structural character these grammars branch on,
/// weighted up because a uniform random byte string is almost all rejected at
/// depth 0 and proves nothing about the parser bodies.
const structural_weights: []const std.testing.Smith.Weight = &.{
    .rangeAtMost(u8, 0x00, 0xff, 1), // full span: invalid UTF-8, NUL, control bytes
    .rangeAtMost(u8, 0x20, 0x7e, 8), // printable ASCII: keys, values, bare scalars
    // Newline carries more grammar here than any other byte: INI, dotenv,
    // `.properties`, YAML, NestedText and fig are all line-oriented, and a
    // tokenizer bug at a line boundary is the common case.
    .value(u8, '\n', 6),
    // Indentation. YAML and NestedText derive STRUCTURE from it, so without
    // leading whitespace their block paths are unreachable.
    .value(u8, ' ', 5),
    .value(u8, '\t', 3), // and tabs, which several of those formats reject
    // Assignment/separator: TOML, INI, dotenv, `.properties`, fig, ZON.
    .value(u8, '=', 4),
    .value(u8, ':', 4), // JSON, YAML, NestedText
    // Bracket pairs: JSON/ZON arrays, TOML/INI section headers, fig groups.
    .value(u8, '[', 4),
    .value(u8, ']', 4),
    .value(u8, '{', 4),
    .value(u8, '}', 4),
    .value(u8, '"', 4), // quoted-string paths (escape handling) in every format
    .value(u8, ',', 3), // JSON/ZON separators
    .value(u8, '<', 3), // XML/plist tags
    .value(u8, '>', 3), // and fig's `>` section depth
    .value(u8, '#', 3), // comments: TOML, YAML, INI, dotenv, fig
    .value(u8, '-', 3), // YAML sequence entries
    .value(u8, '.', 2), // TOML dotted keys, ZON's leading `.`
    .value(u8, '&', 2), // YAML anchors
    .value(u8, '*', 2), // YAML aliases, fig elements
    .value(u8, '\\', 2), // escapes, and INI's unquoted `C:\a\b` values
};

/// The canonical grammar is a closed, JSON-like syntax, so it gets its own
/// narrower weights: the line-oriented and XML bytes above are noise here and
/// would spend the budget on input the parser rejects at the first token.
const canonical_weights: []const std.testing.Smith.Weight = &.{
    .rangeAtMost(u8, 0x00, 0xff, 1),
    .rangeAtMost(u8, 0x20, 0x7e, 8),
    .value(u8, '"', 5), // strings, and the escape decoder behind them
    .value(u8, '{', 4),
    .value(u8, '}', 4),
    .value(u8, '[', 4),
    .value(u8, ']', 4),
    .value(u8, ':', 4),
    .value(u8, ',', 4),
    .value(u8, '@', 3), // extended scalars: `@offset_datetime`, `@char_literal`, …
    .value(u8, '&', 2), // anchors
    .value(u8, '*', 2), // aliases
    .value(u8, '!', 2), // tags
    .value(u8, '~', 2), // the kind override (`~f`)
    .value(u8, '\n', 2), // comments terminate on it
    .value(u8, '/', 2), // and start with `//` or `/*`
};

/// Big enough to nest past the parsers' `max_depth` guards (512 for canonical)
/// so the recursion limits themselves get exercised, and to hold a document
/// with real structure rather than a single truncated token. Stack-allocated:
/// the fuzzer reruns `testOne` in a tight loop, so the input buffer should not
/// be a per-iteration heap allocation competing with the parser's own.
const max_input = 2048;

/// Breadth target: `Language.detect` tries every compiled-in parser in turn
/// (`languages/language.zig`), discarding each Document, so this one call
/// exercises all of them. The assertion is everything the test runner does
/// implicitly around it — no crash, no hang, no leak (each iteration gets a
/// fresh `testing.allocator` instance and fails on a leak) — which is why the
/// body ignores the result: `detect` returning null for random bytes is the
/// expected case, not a failure.
fn detectNeverCrashes(_: void, smith: *std.testing.Smith) anyerror!void {
    // The fuzzer must not see this harness's own coverage; only the parsers'.
    @disableInstrumentation();

    var buf: [max_input]u8 = undefined;
    const len = smith.sliceWeightedBytes(&buf, structural_weights);

    // `tryParse` frees every Document it builds, so a leak reported here is a
    // real one inside a parser's error path, not a harness artifact.
    _ = Language.detect(std.testing.allocator, buf[0..len]);
}

test "fuzz: detect never crashes or leaks on arbitrary input" {
    try std.testing.fuzz({}, detectNeverCrashes, .{});
}

/// Depth target: the canonical form claims to be a 1:1 encoding of the AST, so
/// for any input it ACCEPTS, printing and reparsing must land on the same tree.
/// This is the fuzzable generalization of `expectRoundTrip` in
/// `canonical/parser.zig` — same three assertions, arbitrary input instead of
/// hand-written fixtures.
///
/// The property is conditional on a successful parse: a rejected input proves
/// nothing about a bijection, so it returns rather than fails. What it does NOT
/// forgive is the reparse — the printer's output is canonical text by
/// construction, so if it fails to parse, the bijection is broken and that is a
/// bug, not bad input.
fn canonicalRoundTrips(_: void, smith: *std.testing.Smith) anyerror!void {
    @disableInstrumentation();

    const allocator = std.testing.allocator;

    var buf: [max_input]u8 = undefined;
    const len = smith.sliceWeightedBytes(&buf, canonical_weights);

    // Most random input is not canonical text; `NestingTooDeep` from the depth
    // guard lands here too, which is the guard working.
    var ast = Canonical.parseAbstract(allocator, buf[0..len]) catch return;
    defer ast.deinit();

    var first: std.Io.Writer.Allocating = .init(allocator);
    defer first.deinit();
    // Total over every node kind, and the parser's guard matches the printer's,
    // so anything parsed above prints — a failure here is a real defect.
    try Canonical.print(&first.writer, &ast);

    var reparsed = try Canonical.parseAbstract(allocator, first.written());
    defer reparsed.deinit();

    // The bijection itself: same tree in, same tree out.
    try std.testing.expect(ast.eql(reparsed));
    // `eql` deliberately ignores comments, so they need their own check or the
    // canonical form would be free to silently drop them.
    try std.testing.expect(ast.commentsEql(reparsed));

    // Idempotence. Only from the SECOND print on: the first print normalizes
    // whatever spelling the input used (spacing, comment placement), so
    // comparing it to the input would be false. Comparing print(parse(print(x)))
    // to print(x) is the real claim — the canonical form has one spelling per
    // document, so re-rendering a reparsed tree must be byte-identical.
    var second: std.Io.Writer.Allocating = .init(allocator);
    defer second.deinit();
    try Canonical.print(&second.writer, &reparsed);
    try std.testing.expectEqualStrings(first.written(), second.written());
}

test "fuzz: canonical print output reparses to an equal AST" {
    try std.testing.fuzz({}, canonicalRoundTrips, .{});
}
