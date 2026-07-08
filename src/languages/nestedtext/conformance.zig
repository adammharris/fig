//! NestedText conformance scoreboard against the official test suite
//! (https://github.com/KenKundert/nestedtext_tests, MIT — vendored verbatim
//! to `testdata/nestedtext/tests.json`; see its `LICENSE` there).
//!
//! `tests.json` is `{"load_tests": {<name>: {load_in, load_out, load_err,
//! ...}, ...}}` — `load_in` is base64-encoded NestedText source; `load_out`
//! is the expected loaded value as plain JSON (present, possibly `null`, for
//! a valid case) or `load_err` is a non-empty object (an invalid case, which
//! must fail to parse — message/line/col PARITY is not required, only that
//! fig rejects it, same policy TOML/INI use for their own invalid corpora).
//!
//! `tests.json` is itself parsed with fig's own JSON reader (dogfooding, and
//! matching TOML's conformance harness, which parses its `.json` fixtures
//! the same way) rather than `std.json` — see `matchesLoadOut`'s structural
//! comparison against the freshly-parsed NestedText AST.
//!
//! Run with: zig build test -Dnestedtext-conformance=true

const std = @import("std");
const testing = std.testing;

const AST = @import("../../ast/ast.zig");
const Parser = @import("parser.zig");
const flat_map = @import("../shared/flat_map.zig");
const JsonParser = @import("../json/parser.zig");

const max_fixture_size = 4 * 1024 * 1024;

// Baseline scores. A ratchet: raise as coverage improves; never lower
// without a deliberate reason. A run below baseline fails the test.
// FULL conformance: all 148 official cases (80 valid, 68 invalid) pass.
const valid_baseline = 80;
const invalid_baseline = 68;

const Score = struct { correct: usize = 0, total: usize = 0 };

fn field(ast: *const AST, map_id: AST.Node.Id, key: []const u8) ?AST.Node.Id {
    const kv_id = flat_map.lookupChild(ast.nodes, map_id, key) orelse return null;
    return ast.nodes[kv_id].kind.keyvalue.value;
}

fn decodeBase64(a: std.mem.Allocator, s: []const u8) ![]u8 {
    const decoder = std.base64.standard.Decoder;
    const size = try decoder.calcSizeForSlice(s);
    const buf = try a.alloc(u8, size);
    errdefer a.free(buf);
    try decoder.decode(buf, s);
    return buf;
}

/// Structural comparison of a plain JSON value (from `tests.json`, parsed by
/// fig's own JSON reader) against a NestedText-parsed AST: object keys
/// compared order-insensitively (`flat_map.lookupChild`), arrays
/// order-sensitively, and every NestedText leaf compared as a *string*
/// (NestedText has no typed scalars — a JSON `80` in `load_out` is really
/// always a JSON *string* `"80"`, since the reference implementation only
/// ever produces strings, but a number/bool defensively stringifies here too
/// in case a future test ever contains one literally).
fn matchesLoadOut(nt: *const AST, nt_id: AST.Node.Id, j: *const AST, j_id: AST.Node.Id) bool {
    switch (j.nodes[j_id].kind) {
        .null_ => return nt.nodes[nt_id].kind == .null_,
        .string => |s| return nt.nodes[nt_id].kind == .string and std.mem.eql(u8, s, nt.nodes[nt_id].kind.string),
        .number => |n| return nt.nodes[nt_id].kind == .string and std.mem.eql(u8, n.raw, nt.nodes[nt_id].kind.string),
        .boolean => |b| return nt.nodes[nt_id].kind == .string and std.mem.eql(u8, if (b) "true" else "false", nt.nodes[nt_id].kind.string),
        .sequence => |first_j| {
            if (nt.nodes[nt_id].kind != .sequence) return false;
            var jc = first_j;
            var nc = nt.nodes[nt_id].kind.sequence;
            while (jc) |jid| {
                const nid = nc orelse return false;
                if (!matchesLoadOut(nt, nid, j, jid)) return false;
                jc = j.nodes[jid].next_sibling;
                nc = nt.nodes[nid].next_sibling;
            }
            return nc == null;
        },
        .mapping => |first_j| {
            if (nt.nodes[nt_id].kind != .mapping) return false;
            var jcount: usize = 0;
            var jc = first_j;
            while (jc) |jid| : (jc = j.nodes[jid].next_sibling) jcount += 1;
            var ncount: usize = 0;
            var nc = nt.nodes[nt_id].kind.mapping;
            while (nc) |nid| : (nc = nt.nodes[nid].next_sibling) ncount += 1;
            if (jcount != ncount) return false;
            jc = first_j;
            while (jc) |jid| : (jc = j.nodes[jid].next_sibling) {
                const jkv = j.nodes[jid].kind.keyvalue;
                const key = j.nodes[jkv.key].kind.string;
                const nt_kv_id = flat_map.lookupChild(nt.nodes, nt_id, key) orelse return false;
                const nkv = nt.nodes[nt_kv_id].kind.keyvalue;
                if (!matchesLoadOut(nt, nkv.value, j, jkv.value)) return false;
            }
            return true;
        },
        .keyvalue, .alias, .extended => return false,
    }
}

test "nestedtext conformance: scoreboard" {
    const a = testing.allocator;

    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var dir = try std.Io.Dir.cwd().openDir(io, "testdata/nestedtext", .{});
    defer dir.close(io);
    const bytes = try dir.readFileAlloc(io, "tests.json", a, .limited(max_fixture_size));
    defer a.free(bytes);

    var doc = try JsonParser.parseAbstract(a, bytes, .JSON);
    defer doc.deinit();

    const load_tests_id = field(&doc, doc.root, "load_tests") orelse return error.MissingLoadTests;

    var valid: Score = .{};
    var invalid: Score = .{};

    var cur = doc.nodes[load_tests_id].kind.mapping;
    while (cur) |kv_id| : (cur = doc.nodes[kv_id].next_sibling) {
        const case_id = doc.nodes[kv_id].kind.keyvalue.value;

        const load_err_id = field(&doc, case_id, "load_err");
        const has_err = if (load_err_id) |id|
            (doc.nodes[id].kind == .mapping and doc.nodes[id].kind.mapping != null)
        else
            false;

        const load_in_id = field(&doc, case_id, "load_in") orelse continue;
        if (doc.nodes[load_in_id].kind != .string) continue;
        const input = decodeBase64(a, doc.nodes[load_in_id].kind.string) catch continue;
        defer a.free(input);

        // Named per-case, not just tallied — a regression prints exactly
        // which official test case broke, not just a score delta.
        const name = doc.nodes[doc.nodes[kv_id].kind.keyvalue.key].kind.string;

        if (has_err) {
            invalid.total += 1;
            if (Parser.parseAbstract(a, input, .NESTEDTEXT)) |good| {
                var g = good;
                g.deinit();
                std.debug.print("  should have been rejected but parsed: {s}\n", .{name});
            } else |_| {
                invalid.correct += 1;
            }
        } else {
            valid.total += 1;
            var nt_ast = Parser.parseAbstract(a, input, .NESTEDTEXT) catch |err| {
                std.debug.print("  valid case failed to parse: {s} ({s})\n", .{ name, @errorName(err) });
                continue;
            };
            defer nt_ast.deinit();
            const load_out_id = field(&doc, case_id, "load_out");
            const expect_null = load_out_id == null or doc.nodes[load_out_id.?].kind == .null_;
            const ok = if (expect_null)
                nt_ast.nodes[nt_ast.root].kind == .null_
            else
                matchesLoadOut(&nt_ast, nt_ast.root, &doc, load_out_id.?);
            if (ok) {
                valid.correct += 1;
            } else {
                std.debug.print("  valid case parsed to the wrong value: {s}\n", .{name});
            }
        }
    }

    std.debug.print(
        \\
        \\NestedText conformance (nestedtext_tests)
        \\  valid:   {d}/{d} (baseline {d})
        \\  invalid: {d}/{d} (baseline {d})
        \\
    , .{ valid.correct, valid.total, valid_baseline, invalid.correct, invalid.total, invalid_baseline });

    try testing.expect(valid.correct >= valid_baseline);
    try testing.expect(invalid.correct >= invalid_baseline);
}
