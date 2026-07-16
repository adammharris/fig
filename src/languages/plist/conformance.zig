//! plist conformance scoreboard against `testdata/plist/{valid,invalid}/`.
//!
//! A ratcheting scoreboard like the TOML/NestedText harnesses: each run prints a
//! tally and asserts the score has not dropped below a recorded baseline.
//!
//!   valid/   : every `.plist` must PARSE. Where a sibling `.json` exists it is
//!              a `plutil -convert json` oracle, and fig's tree is additionally
//!              compared against it structurally — the check that catches a
//!              silent mis-parse (a real read as a string, a nested dict quietly
//!              flattened) that a pass/fail check cannot see.
//!   invalid/ : parse-only — fig must reject every file.
//!
//! Unlike TOML's and YAML-1.1's corpora, the oracles here are **plain** JSON,
//! not toml-test's `{"type": T, "value": V}` tagged encoding: they are whatever
//! `plutil` itself emits, so there is no `asLeaf` disambiguation step and the
//! expected type of each leaf is carried by the JSON token's own kind (a JSON
//! number means fig must have produced a number, etc.). Everything else — the
//! order-insensitive mapping compare, the order-sensitive array compare, the
//! recursive walk driven from the oracle side — mirrors
//! `src/languages/toml/conformance.zig` directly.
//!
//! 7 of the 9 valid fixtures have an oracle. The 2 that do not are a property of
//! `plutil`'s JSON writer, not an oversight, and for two DIFFERENT reasons —
//! both confirmed by running it, since the distinction decides whether an
//! oracle could ever be added:
//!
//!   * `kitchen-sink.plist` — JSON has no date and no byte-string, so `plutil
//!     -convert json` refuses ("Invalid object in plist for JSON format") on any
//!     file containing `<date>`/`<data>`. `kitchen-sink-nodatedata.plist` exists
//!     purely so the kitchen-sink's *other* type coverage still gets an oracle:
//!     it is `kitchen-sink.plist` with exactly those two keys removed.
//!   * `root-string.plist` — refused for an unrelated reason: `plutil`'s JSON
//!     writer requires a CONTAINER at the root and rejects a bare scalar one.
//!     Nothing about `<string>` is unconvertible; the root position is. fig
//!     itself is happy to read a bare-scalar root (that IS the fixture's point),
//!     so this one is scored on parse-success alone and its value is pinned by
//!     `parser.zig`'s own "bare root scalar" unit test instead.
//!
//! Those two are therefore held only to "must not error". Every other valid
//! fixture is held to the full structural compare — including `dup-keys.plist`,
//! whose oracle (`{"a":"2"}`) is what pins the last-wins duplicate-`<key>`
//! convention `parser.zig` documents to `plutil`'s ACTUAL behaviour rather than
//! to our reading of it.
//!
//! Fixtures are vendored by hand from real system `Info.plist` files
//! (`real-*.plist`), hand-authored DTD-coverage cases, and `plutil`-verified
//! edge cases; every `.json` beside them is the verbatim output of
//! `plutil -convert json -o <name>.json <name>.plist`.
//! Run with: zig build test -Dplist=true -Dplist-conformance=true

const std = @import("std");
const testing = std.testing;

const AST = @import("../../ast/ast.zig");
const Parser = @import("parser.zig");
const PlistType = @import("plist.zig").Type;
const JsonParser = @import("../json/parser.zig");
const JsonType = @import("../json/json.zig").Type;

const max_fixture_size = 1024 * 1024;

// Baseline scores. A ratchet: raise as coverage improves; never lower without a
// deliberate reason. A run below baseline fails the test.
//
// Full conformance for the vendored corpus: every valid file parses, every one
// of the seven that `plutil` could convert matches its oracle exactly, and every
// invalid file is rejected. Independently corroborated when this harness was
// written — `plutil -lint` accepts all 9 valid fixtures and rejects all 5
// invalid ones, so fig agrees with the reference implementation on every file,
// and is neither over-permissive nor over-strict on this corpus.
//
// `oracle_baseline` is deliberately tracked apart from `parsed_baseline` rather
// than folded into it — an oracle-less fixture is only held to "does not error",
// a far weaker claim, and merging the two would let a silent mis-parse hide
// behind a passing parse count. Keeping them separate also means adding a
// fixture that `plutil` cannot convert can never dilute the oracle score.
const parsed_baseline = 9;
const oracle_baseline = 7;
const rejected_baseline = 5;

const Score = struct { correct: usize = 0, total: usize = 0 };

test "plist conformance: scoreboard" {
    var parsed: Score = .{};
    var oracle: Score = .{};
    try scoreValidDir("testdata/plist/valid", &parsed, &oracle);
    const rejected = try scoreInvalidDir("testdata/plist/invalid");

    std.debug.print(
        \\
        \\plist conformance (testdata/plist)
        \\  valid   parsed:   {d}/{d} (baseline {d})
        \\  valid   vs plutil oracle: {d}/{d} (baseline {d})
        \\  invalid rejected: {d}/{d} (baseline {d})
        \\
    , .{
        parsed.correct,   parsed.total,   parsed_baseline,
        oracle.correct,   oracle.total,   oracle_baseline,
        rejected.correct, rejected.total, rejected_baseline,
    });

    try testing.expect(parsed.correct >= parsed_baseline);
    try testing.expect(oracle.correct >= oracle_baseline);
    try testing.expect(rejected.correct >= rejected_baseline);
}

fn scoreInvalidDir(dir_path: []const u8) !Score {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var score: Score = .{};
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".plist")) continue;
        const input = try dir.readFileAlloc(io, entry.name, testing.allocator, .limited(max_fixture_size));
        defer testing.allocator.free(input);

        score.total += 1;
        if (Parser.parse(testing.allocator, input, PlistType.XML)) |doc| {
            var d = doc;
            d.deinit(testing.allocator);
            // Named, not just tallied — a regression names the fixture that
            // started being accepted, not just a score delta.
            std.debug.print("  should have been rejected but parsed: {s}\n", .{entry.name});
        } else |_| score.correct += 1;
    }
    return score;
}

/// Walk `valid/`, filling both tallies in one pass: `parsed` counts every
/// `.plist` (the floor — it must not error), `oracle` counts only those with a
/// sibling `.json` (the ceiling — the tree must match `plutil`'s). One pass
/// rather than two because the oracle check needs the parsed document anyway.
fn scoreValidDir(dir_path: []const u8, parsed: *Score, oracle: *Score) !void {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".plist")) continue;

        const plist_src = try dir.readFileAlloc(io, entry.name, testing.allocator, .limited(max_fixture_size));
        defer testing.allocator.free(plist_src);

        const json_name = try std.fmt.allocPrint(testing.allocator, "{s}.json", .{entry.name[0 .. entry.name.len - ".plist".len]});
        defer testing.allocator.free(json_name);
        // `null` is the ordinary case, not an error: 2 of the 9 fixtures have no
        // oracle because `plutil` refuses to emit one (see the module doc).
        const json_src: ?[]u8 = dir.readFileAlloc(io, json_name, testing.allocator, .limited(max_fixture_size)) catch null;
        defer if (json_src) |s| testing.allocator.free(s);

        parsed.total += 1;
        if (json_src != null) oracle.total += 1;

        var plist_doc = Parser.parse(testing.allocator, plist_src, PlistType.XML) catch |err| {
            std.debug.print("  valid case failed to parse: {s} ({s})\n", .{ entry.name, @errorName(err) });
            continue;
        };
        defer plist_doc.deinit(testing.allocator);
        parsed.correct += 1;

        const oracle_src = json_src orelse continue;
        var json_doc = try JsonParser.parse(testing.allocator, oracle_src, JsonType.JSON);
        defer json_doc.deinit(testing.allocator);

        if (matchValue(&plist_doc.ast, plist_doc.ast.root, &json_doc.ast, json_doc.ast.root)) {
            oracle.correct += 1;
        } else {
            std.debug.print("  valid case parsed to the wrong value: {s}\n", .{entry.name});
        }
    }
}

// ── plutil-JSON comparison (mirrors src/languages/toml/conformance.zig) ──────

/// Recurse driven from the ORACLE side: the JSON node says what fig must have
/// produced, and the plist node either satisfies it or does not. Driving from
/// the oracle (rather than fig's tree) is what makes a missing key a mismatch
/// rather than a silently skipped comparison.
fn matchValue(pa: *const AST, p_id: AST.Node.Id, ja: *const AST, j_id: AST.Node.Id) bool {
    const pn = pa.nodes[p_id].kind;
    return switch (ja.nodes[j_id].kind) {
        .mapping => matchDict(pa, p_id, ja, j_id),
        .sequence => matchArray(pa, p_id, ja, j_id),
        .string => |s| switch (pn) {
            .string => |ps| std.mem.eql(u8, ps, s),
            // Unreachable with today's corpus and kept deliberately: `plutil`
            // will not convert `<date>`/`<data>` to JSON at all, so no oracle
            // can contain one. If a future oracle is ever produced by some other
            // tool that DOES stringify them, compare the extended scalar's
            // intrinsic text rather than silently failing on the node kind.
            .extended => |e| std.mem.eql(u8, e.text, s),
            else => false,
        },
        .number => |n| pn == .number and numberEqual(pn.number, n),
        .boolean => |b| pn == .boolean and pn.boolean == b,
        // plist's DTD has no null: there is no element that could produce one,
        // so an oracle containing one would mean the oracle is wrong, not fig.
        .null_ => false,
        // fig's JSON reader never yields these at a value position.
        .keyvalue, .alias, .extended => false,
    };
}

/// Order-INSENSITIVE, with an exact cardinality check. `plutil -convert json`
/// emits a `CFDictionary` in hash order, NOT the source document's order — so a
/// positional compare would fail every real fixture. The count equality is what
/// keeps this honest in the other direction: a key fig invented (or a duplicate
/// it failed to collapse) has no oracle entry to be visited by, and is caught
/// only by the totals disagreeing.
fn matchDict(pa: *const AST, p_id: AST.Node.Id, ja: *const AST, j_id: AST.Node.Id) bool {
    const pn = pa.nodes[p_id];
    if (pn.kind != .mapping) return false;
    var jcount: usize = 0;
    var jc = ja.nodes[j_id].kind.mapping;
    while (jc) |jid| : (jc = ja.nodes[jid].next_sibling) {
        jcount += 1;
        const jkv = ja.nodes[jid].kind.keyvalue;
        const jkey = ja.nodes[jkv.key].kind.string;
        const pv = childByKey(pa, pn, jkey) orelse return false;
        if (!matchValue(pa, pv, ja, jkv.value)) return false;
    }
    return jcount == countChildren(pa, pn);
}

/// Order-SENSITIVE, unlike `matchDict`: a plist `<array>` is a real sequence and
/// `plutil` preserves its order, so position is part of the value.
fn matchArray(pa: *const AST, p_id: AST.Node.Id, ja: *const AST, j_id: AST.Node.Id) bool {
    if (pa.nodes[p_id].kind != .sequence) return false;
    var pc = pa.nodes[p_id].kind.sequence;
    var jc = ja.nodes[j_id].kind.sequence;
    while (true) {
        const pid = pc orelse return jc == null;
        const jid = jc orelse return false;
        if (!matchValue(pa, pid, ja, jid)) return false;
        pc = pa.nodes[pid].next_sibling;
        jc = ja.nodes[jid].next_sibling;
    }
}

fn childByKey(ast: *const AST, mapping: AST.Node, key: []const u8) ?AST.Node.Id {
    var cur = mapping.kind.mapping;
    while (cur) |id| : (cur = ast.nodes[id].next_sibling) {
        const kv = ast.nodes[id].kind.keyvalue;
        if (std.mem.eql(u8, ast.nodes[kv.key].kind.string, key)) return kv.value;
    }
    return null;
}

fn countChildren(ast: *const AST, node: AST.Node) usize {
    var n: usize = 0;
    var cur = switch (node.kind) {
        .mapping, .sequence => |first| first,
        else => return 0,
    };
    while (cur) |id| : (cur = ast.nodes[id].next_sibling) n += 1;
    return n;
}

/// Integer/float kind parity is required — `<integer>` must not land as a float
/// or vice versa, and `plutil` maps the two elements onto JSON ints/reals
/// faithfully, so the oracle's own token kind is the expectation.
///
/// Integers compare textually only after normalization through `i64`: plist's
/// DTD permits a leading `+` and the corpus deliberately carries `i64` max, so
/// the raw bytes are not comparable but the parsed values are. Reals must NOT be
/// compared textually at all — `plutil` round-trips a `<real>` through a C
/// `double` and prints it back at 17 significant digits, so the oracle for
/// `3.14159` literally reads `3.1415899999999999`. Both spellings denote the
/// same `f64`, which is exactly what the comparison must assert.
fn numberEqual(p: AST.Node.Kind.Number, j: AST.Node.Kind.Number) bool {
    if (p.kind != j.kind) return false;
    return switch (p.kind) {
        .integer => blk: {
            const a = std.fmt.parseInt(i64, p.raw, 10) catch break :blk false;
            const b = std.fmt.parseInt(i64, j.raw, 10) catch break :blk false;
            break :blk a == b;
        },
        .float => blk: {
            const a = std.fmt.parseFloat(f64, p.raw) catch break :blk false;
            const b = std.fmt.parseFloat(f64, j.raw) catch break :blk false;
            break :blk a == b;
        },
    };
}
