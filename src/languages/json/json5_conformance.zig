//! JSON5 conformance scoreboard against json5/json5-tests
//! (https://github.com/json5/json5-tests).
//!
//! The suite encodes the expected outcome in the file EXTENSION, not a
//! directory split (see that repo's README):
//!     *.json   valid JSON  -> must remain valid JSON5  (ACCEPT)
//!     *.json5  JSON5 feature, valid ES5                (ACCEPT)
//!     *.js     valid ES5 that JSON5 forbids            (REJECT)
//!     *.txt    invalid ES5                             (REJECT)
//!
//! A ratcheting scoreboard like the TOML/YAML harnesses: each run prints a tally
//! and asserts the score has not dropped below a recorded baseline.
//!
//! On top of accept/reject, every `.json` fixture is *also* parsed by the strict
//! JSON parser and the two trees are compared: JSON5 mode must parse ordinary
//! JSON to exactly the same AST it would in strict mode (catches a silent
//! mis-parse a pass/fail check can't see).
//!
//! Fixtures are vendored by tools/gen_json5_conformance.zig.
//! Run with: zig build test -Djson5-conformance=true

const std = @import("std");
const testing = std.testing;

const AST = @import("../../ast/ast.zig");
const Parser = @import("parser.zig");
const JsonType = @import("json.zig").Type;

const max_fixture_size = 1024 * 1024;
const dir_path = "testdata/json5";

// Baselines. A ratchet: raise as coverage improves; never lower without a
// deliberate reason. A run below baseline fails the test.
// Full conformance: every accept fixture parses, every reject fixture is
// refused. The one plain-JSON tree gap is irregular-block-comment.json, a
// `.json` fixture that actually contains a block comment — strict JSON rejects
// it (so the trees can't match), JSON5 accepts it. That is correct, not a miss.
const accept_baseline = 81;
const reject_baseline = 31;
const json_match_baseline = 25;

const Score = struct { correct: usize = 0, total: usize = 0 };

test "json5 conformance: scoreboard" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var accept: Score = .{};
    var reject: Score = .{};
    var json_match: Score = .{};

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const ext = extOf(entry.name);
        const should_accept = std.mem.eql(u8, ext, "json") or std.mem.eql(u8, ext, "json5");
        const should_reject = std.mem.eql(u8, ext, "js") or std.mem.eql(u8, ext, "txt");
        if (!should_accept and !should_reject) continue;

        const input = try dir.readFileAlloc(io, entry.name, testing.allocator, .limited(max_fixture_size));
        defer testing.allocator.free(input);

        const parsed = Parser.parse(testing.allocator, input, .JSON5);

        if (should_accept) {
            accept.total += 1;
            if (parsed) |doc| {
                var d = doc;
                accept.correct += 1;

                // Cross-check: plain JSON must parse identically in JSON5 mode.
                if (std.mem.eql(u8, ext, "json")) {
                    json_match.total += 1;
                    if (Parser.parse(testing.allocator, input, .JSON)) |jdoc| {
                        var jd = jdoc;
                        if (d.ast.eql(jd.ast)) json_match.correct += 1 else logMismatch(entry.name);
                        jd.deinit(testing.allocator);
                    } else |_| logMismatch(entry.name);
                }

                d.deinit(testing.allocator);
            } else |err| logFail("accept", entry.name, err);
        } else {
            reject.total += 1;
            if (parsed) |doc| {
                var d = doc;
                d.deinit(testing.allocator);
                logFail("reject", entry.name, null);
            } else |_| reject.correct += 1;
        }
    }

    std.debug.print(
        \\
        \\JSON5 conformance (json5-tests)
        \\  accept: {d}/{d} (baseline {d})
        \\  reject: {d}/{d} (baseline {d})
        \\  plain-JSON tree match: {d}/{d} (baseline {d})
        \\
    , .{
        accept.correct,     accept.total,     accept_baseline,
        reject.correct,     reject.total,     reject_baseline,
        json_match.correct, json_match.total, json_match_baseline,
    });

    try testing.expect(accept.correct >= accept_baseline);
    try testing.expect(reject.correct >= reject_baseline);
    try testing.expect(json_match.correct >= json_match_baseline);
}

fn extOf(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "";
    return name[dot + 1 ..];
}

fn logFail(comptime kind: []const u8, name: []const u8, err: ?anyerror) void {
    if (err) |e| {
        std.debug.print("  json5 {s} FAIL: {s} ({s})\n", .{ kind, name, @errorName(e) });
    } else {
        std.debug.print("  json5 {s} FAIL: {s} (parsed but should not)\n", .{ kind, name });
    }
}

fn logMismatch(name: []const u8) void {
    std.debug.print("  json5 tree MISMATCH vs strict JSON: {s}\n", .{name});
}
