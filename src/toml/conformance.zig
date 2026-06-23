//! TOML conformance scoreboard against toml-lang/toml-test
//! (https://github.com/toml-lang/toml-test).
//!
//! A ratcheting scoreboard like the YAML harness: each run prints a tally and
//! asserts the score has not dropped below a recorded baseline.
//!
//!   invalid/ : parse-only — fig must reject every file.
//!   valid/   : tagged-JSON comparison — each .toml has a sibling .json that
//!              pins every scalar's type + value (toml-test's own format). fig
//!              parses the .toml, the JSON parser parses the .json, and the two
//!              trees are compared structurally (tables unordered, arrays
//!              ordered, leaves by type + normalized value). This catches silent
//!              mis-parses a pass/fail check can't see.
//!
//! Fixtures are vendored by tools/gen_toml_conformance.zig.
//! Run with: zig build test -Dtoml-conformance=true

const std = @import("std");
const testing = std.testing;

const AST = @import("../ast/ast.zig");
const Parser = @import("parser.zig");
const TomlType = @import("toml.zig").Type;
const JsonParser = @import("../json/parser.zig");
const JsonType = @import("../json/json.zig").Type;

const max_fixture_size = 1024 * 1024;

// Baseline scores. A ratchet: raise as coverage improves; never lower without a
// deliberate reason. A run below baseline fails the test.
// Full conformance for both versions. Every valid file matches its expected
// typed JSON exactly; every invalid file is rejected.
const valid_1_0_baseline = 209;
const invalid_1_0_baseline = 495;
const valid_1_1_baseline = 218;
const invalid_1_1_baseline = 488;

const Score = struct { correct: usize = 0, total: usize = 0 };

test "toml conformance: scoreboard" {
    const v10 = try scoreValidDir("testdata/toml/valid", .TOML_1_0);
    const inv10 = try scoreInvalidDir("testdata/toml/invalid", .TOML_1_0);
    const v11 = try scoreValidDir("testdata/toml-1.1.0/valid", .TOML_1_1);
    const inv11 = try scoreInvalidDir("testdata/toml-1.1.0/invalid", .TOML_1_1);

    std.debug.print(
        \\
        \\TOML conformance (toml-test)
        \\  1.0.0  valid: {d}/{d} (baseline {d})   invalid: {d}/{d} (baseline {d})
        \\  1.1.0  valid: {d}/{d} (baseline {d})   invalid: {d}/{d} (baseline {d})
        \\
    , .{
        v10.correct,   v10.total,   valid_1_0_baseline,
        inv10.correct, inv10.total, invalid_1_0_baseline,
        v11.correct,   v11.total,   valid_1_1_baseline,
        inv11.correct, inv11.total, invalid_1_1_baseline,
    });

    try testing.expect(v10.correct >= valid_1_0_baseline);
    try testing.expect(inv10.correct >= invalid_1_0_baseline);
    try testing.expect(v11.correct >= valid_1_1_baseline);
    try testing.expect(inv11.correct >= invalid_1_1_baseline);
}

fn scoreInvalidDir(dir_path: []const u8, version: TomlType) !Score {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var score: Score = .{};
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".toml")) continue;
        const input = try dir.readFileAlloc(io, entry.name, testing.allocator, .limited(max_fixture_size));
        defer testing.allocator.free(input);

        score.total += 1;
        if (Parser.parse(testing.allocator, input, version)) |doc| {
            var d = doc;
            d.deinit(testing.allocator);
        } else |_| score.correct += 1;
    }
    return score;
}

fn scoreValidDir(dir_path: []const u8, version: TomlType) !Score {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var score: Score = .{};
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".toml")) continue;

        const toml_src = try dir.readFileAlloc(io, entry.name, testing.allocator, .limited(max_fixture_size));
        defer testing.allocator.free(toml_src);

        const json_name = try std.fmt.allocPrint(testing.allocator, "{s}.json", .{entry.name[0 .. entry.name.len - ".toml".len]});
        defer testing.allocator.free(json_name);
        const json_src = dir.readFileAlloc(io, json_name, testing.allocator, .limited(max_fixture_size)) catch continue;
        defer testing.allocator.free(json_src);

        score.total += 1;

        var toml_doc = Parser.parse(testing.allocator, toml_src, version) catch continue;
        defer toml_doc.deinit(testing.allocator);
        var json_doc = JsonParser.parse(testing.allocator, json_src, JsonType.JSON) catch continue;
        defer json_doc.deinit(testing.allocator);

        if (matchValue(&toml_doc.ast, toml_doc.ast.root, &json_doc.ast, json_doc.ast.root)) {
            score.correct += 1;
        }
    }
    return score;
}

// ── tagged-JSON comparison ──────────────────────────────────────────────────

const TagType = enum {
    string,
    integer,
    float,
    bool,
    datetime,
    @"datetime-local",
    @"date-local",
    @"time-local",
};

const Leaf = struct { tag: TagType, value: []const u8 };

/// If `j_id` is a toml-test tagged leaf (`{"type": T, "value": V}` with both
/// values plain strings and T a known type), return it; else null (it's a real
/// table/array). A genuine TOML table with keys "type"/"value" has *tagged
/// objects* as its values, so its "type" value is not a bare string — the
/// disambiguation toml-test decoders rely on.
fn asLeaf(ja: *const AST, j_id: AST.Node.Id) ?Leaf {
    const node = ja.nodes[j_id];
    if (node.kind != .mapping) return null;
    var type_str: ?[]const u8 = null;
    var value_str: ?[]const u8 = null;
    var count: usize = 0;
    var cur = node.kind.mapping;
    while (cur) |id| : (cur = ja.nodes[id].next_sibling) {
        count += 1;
        const kv = ja.nodes[id].kind.keyvalue;
        const key = ja.nodes[kv.key].kind.string;
        const val = ja.nodes[kv.value].kind;
        if (val != .string) return null; // a real table value
        if (std.mem.eql(u8, key, "type")) type_str = val.string;
        if (std.mem.eql(u8, key, "value")) value_str = val.string;
    }
    if (count != 2 or type_str == null or value_str == null) return null;
    const tag = std.meta.stringToEnum(TagType, type_str.?) orelse return null;
    return .{ .tag = tag, .value = value_str.? };
}

fn matchValue(ta: *const AST, t_id: AST.Node.Id, ja: *const AST, j_id: AST.Node.Id) bool {
    if (asLeaf(ja, j_id)) |leaf| return matchLeaf(ta, t_id, leaf);
    return switch (ja.nodes[j_id].kind) {
        .mapping => matchTable(ta, t_id, ja, j_id),
        .sequence => matchArray(ta, t_id, ja, j_id),
        else => false,
    };
}

fn matchTable(ta: *const AST, t_id: AST.Node.Id, ja: *const AST, j_id: AST.Node.Id) bool {
    const tn = ta.nodes[t_id];
    if (tn.kind != .mapping) return false;
    var jcount: usize = 0;
    var jc = ja.nodes[j_id].kind.mapping;
    while (jc) |jid| : (jc = ja.nodes[jid].next_sibling) {
        jcount += 1;
        const jkv = ja.nodes[jid].kind.keyvalue;
        const jkey = ja.nodes[jkv.key].kind.string;
        const tv = childByKey(ta, tn, jkey) orelse return false;
        if (!matchValue(ta, tv, ja, jkv.value)) return false;
    }
    return jcount == countChildren(ta, tn);
}

fn matchArray(ta: *const AST, t_id: AST.Node.Id, ja: *const AST, j_id: AST.Node.Id) bool {
    if (ta.nodes[t_id].kind != .sequence) return false;
    var tc = ta.nodes[t_id].kind.sequence;
    var jc = ja.nodes[j_id].kind.sequence;
    while (true) {
        const tid = tc orelse return jc == null;
        const jid = jc orelse return false;
        if (!matchValue(ta, tid, ja, jid)) return false;
        tc = ta.nodes[tid].next_sibling;
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

fn matchLeaf(ta: *const AST, t_id: AST.Node.Id, leaf: Leaf) bool {
    const node = ta.nodes[t_id].kind;
    return switch (leaf.tag) {
        .string => node == .string and std.mem.eql(u8, node.string, leaf.value),
        .bool => node == .boolean and std.mem.eql(u8, if (node.boolean) "true" else "false", leaf.value),
        .integer => node == .number and node.number.kind == .integer and intEqual(node.number.raw, leaf.value),
        .float => node == .number and node.number.kind == .float and floatEqual(node.number.raw, leaf.value),
        .datetime => node == .extended and node.extended.kind == .offset_datetime and datetimeEqual(node.extended.text, leaf.value),
        .@"datetime-local" => node == .extended and node.extended.kind == .local_datetime and datetimeEqual(node.extended.text, leaf.value),
        .@"date-local" => node == .extended and node.extended.kind == .local_date and datetimeEqual(node.extended.text, leaf.value),
        .@"time-local" => node == .extended and node.extended.kind == .local_time and datetimeEqual(node.extended.text, leaf.value),
    };
}

/// Normalize a TOML integer (any radix, underscores, sign) to a decimal string
/// and compare to the expected decimal.
fn intEqual(raw: []const u8, expected: []const u8) bool {
    var buf: [64]u8 = undefined;
    var len: usize = 0;
    for (raw) |c| {
        if (c == '_') continue;
        if (len >= buf.len) return false;
        buf[len] = c;
        len += 1;
    }
    // parseInt with base 0 auto-detects 0x/0o/0b and a leading sign.
    const v = std.fmt.parseInt(i64, buf[0..len], 0) catch return false;
    var out: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&out, "{d}", .{v}) catch return false;
    return std.mem.eql(u8, s, expected);
}

fn floatEqual(raw: []const u8, expected: []const u8) bool {
    const a = parseTomlFloat(raw) orelse return false;
    const b = parseTomlFloat(expected) orelse return false;
    if (std.math.isNan(a)) return std.math.isNan(b);
    if (std.math.isNan(b)) return false;
    return a == b;
}

fn parseTomlFloat(s: []const u8) ?f64 {
    var buf: [64]u8 = undefined;
    var len: usize = 0;
    for (s) |c| {
        if (c == '_') continue;
        if (len >= buf.len) return null;
        buf[len] = c;
        len += 1;
    }
    const stripped = buf[0..len];
    if (eqAny(stripped, &.{ "inf", "+inf" })) return std.math.inf(f64);
    if (std.mem.eql(u8, stripped, "-inf")) return -std.math.inf(f64);
    if (eqAny(stripped, &.{ "nan", "+nan", "-nan" })) return std.math.nan(f64);
    return std.fmt.parseFloat(f64, stripped) catch null;
}

/// Compare datetimes after normalizing the separator to `T` and letters to
/// upper-case (`t`/`z` → `T`/`Z`, space → `T`).
fn datetimeEqual(raw: []const u8, expected: []const u8) bool {
    var s1: [64]u8 = undefined;
    var s2: [64]u8 = undefined;
    var ra: [64]u8 = undefined;
    var eb: [64]u8 = undefined;
    // TOML 1.1 times may omit seconds (`13:37`); toml-test's canonical value
    // always has them (`13:37:00`). Pad both sides before normalizing.
    const a = normalizeDatetime(insertSeconds(raw, &s1), &ra) orelse return false;
    const b = normalizeDatetime(insertSeconds(expected, &s2), &eb) orelse return false;
    return std.mem.eql(u8, a, b);
}

/// Insert `:00` after `HH:MM` when seconds are absent. `s` is a datetime/time;
/// the time starts at index 0 (time-only) or 11 (after `DATE` + separator).
fn insertSeconds(s: []const u8, buf: []u8) []const u8 {
    const time_start: usize = if (s.len >= 3 and s[2] == ':') 0 else if (s.len >= 11) 11 else return s;
    const mm_end = time_start + 5; // past HH:MM
    if (s.len < mm_end) return s;
    if (s.len > mm_end and s[mm_end] == ':') return s; // already has seconds
    if (mm_end + 3 > buf.len or s.len + 3 > buf.len) return s;
    @memcpy(buf[0..mm_end], s[0..mm_end]);
    @memcpy(buf[mm_end .. mm_end + 3], ":00");
    @memcpy(buf[mm_end + 3 .. s.len + 3], s[mm_end..]);
    return buf[0 .. s.len + 3];
}

/// Normalize separator → `T`, letters → upper-case, and fractional seconds to
/// exactly three digits (toml-test's canonical millisecond precision: `.6` →
/// `.600`, `.123456` → `.123`), applied to both sides so they compare equal.
fn normalizeDatetime(s: []const u8, buf: []u8) ?[]const u8 {
    var w: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (w >= buf.len) return null;
        const c = s[i];
        if (i == 10 and c == ' ') {
            buf[w] = 'T';
            w += 1;
            i += 1;
        } else if (c == '.') {
            buf[w] = '.';
            w += 1;
            i += 1;
            const start = i;
            while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
            const frac = s[start..i];
            var k: usize = 0;
            while (k < 3) : (k += 1) {
                if (w >= buf.len) return null;
                buf[w] = if (k < frac.len) frac[k] else '0';
                w += 1;
            }
        } else {
            buf[w] = std.ascii.toUpper(c);
            w += 1;
            i += 1;
        }
    }
    return buf[0..w];
}

fn eqAny(s: []const u8, options: []const []const u8) bool {
    for (options) |o| if (std.mem.eql(u8, s, o)) return true;
    return false;
}
