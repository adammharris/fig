//! YAML 1.1 resolution scoreboard.
//!
//! Where `conformance.zig` scores the upstream yaml-test-suite (1.2-only, pure
//! accept/reject), this harness pins **YAML 1.1 scalar type resolution** — the
//! one area where 1.1 and 1.2 genuinely diverge. Each fixture in
//! `testdata/yaml-1.1/` is a `.yaml` paired with a sibling `.json` that tags
//! every scalar with `{type, value}` (the toml-test format reused by the TOML
//! harness). fig parses the `.yaml` under `Type.v1_1`, the JSON parser parses
//! the `.json`, and the two trees are compared leaf by leaf (type + normalized
//! value). This catches the silent mis-resolutions a pass/fail check can't see:
//! `yes` must become a bool, `0777` an octal int, `1e3` must stay a string.
//!
//! Like the other suites this is a *ratchet*: the score must not drop below the
//! recorded baseline. The 1.1 resolver is still being implemented (selecting
//! `.v1_1` currently parses like 1.2), so the baseline starts at the count that
//! already passes by 1.2/1.1 overlap and is raised as resolution lands.
//!
//! Run with: zig build test -Dyaml-conformance=true

const std = @import("std");
const testing = std.testing;

const AST = @import("../../ast/ast.zig");
const Parser = @import("parser.zig");
const YamlType = @import("yaml.zig").Type;
const JsonParser = @import("../json/parser.zig");
const JsonType = @import("../json/json.zig").Type;

const max_fixture_size = 1024 * 1024;

// Ratchet baseline: the number of `testdata/yaml-1.1/` fixtures whose every
// scalar resolves to the 1.1-expected type+value. Raise this as the 1.1
// resolver lands; never lower it without a deliberate reason.
//
// 14/14: the full `scalarKind1_1` resolver is in (`src/languages/yaml/parser.zig`) —
// yes/no/on/off booleans, leading-zero octal + binary + hex + sexagesimal
// (underscored) ints, `.`-required signed-exponent floats, and `!!timestamp`
// auto-resolution; `1e3`/`0o17`/`08`/`0x` correctly stay strings.
const valid_1_1_baseline = 14;

const Score = struct { correct: usize = 0, total: usize = 0 };

test "yaml 1.1 resolution: scoreboard" {
    const score = try scoreValidDir("testdata/yaml-1.1", .v1_1);

    std.debug.print(
        \\
        \\YAML 1.1 resolution (testdata/yaml-1.1, tagged-JSON comparison)
        \\  valid: {d}/{d}   baseline {d}
        \\
    , .{ score.correct, score.total, valid_1_1_baseline });

    try testing.expect(score.correct >= valid_1_1_baseline);
}

fn scoreValidDir(dir_path: []const u8, version: YamlType) !Score {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var score: Score = .{};
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".yaml")) continue;

        const yaml_src = try dir.readFileAlloc(io, entry.name, testing.allocator, .limited(max_fixture_size));
        defer testing.allocator.free(yaml_src);

        const json_name = try std.fmt.allocPrint(testing.allocator, "{s}.json", .{entry.name[0 .. entry.name.len - ".yaml".len]});
        defer testing.allocator.free(json_name);
        const json_src = dir.readFileAlloc(io, json_name, testing.allocator, .limited(max_fixture_size)) catch continue;
        defer testing.allocator.free(json_src);

        score.total += 1;

        var yaml_doc = Parser.parse(testing.allocator, yaml_src, version) catch continue;
        defer yaml_doc.deinit(testing.allocator);
        var json_doc = JsonParser.parse(testing.allocator, json_src, JsonType.JSON) catch continue;
        defer json_doc.deinit(testing.allocator);

        if (matchValue(&yaml_doc.ast, yaml_doc.ast.root, &json_doc.ast, json_doc.ast.root)) {
            score.correct += 1;
        }
    }
    return score;
}

// ── tagged-JSON comparison (mirrors src/languages/toml/conformance.zig, plus `null`) ───

const TagType = enum {
    @"null",
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

/// A toml-test tagged leaf is a 2-key mapping `{"type": T, "value": V}` whose
/// values are both plain strings. A genuine YAML mapping with keys "type"/
/// "value" has non-string (tagged) values, so it is not mistaken for a leaf.
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
        if (val != .string) return null;
        if (std.mem.eql(u8, key, "type")) type_str = val.string;
        if (std.mem.eql(u8, key, "value")) value_str = val.string;
    }
    if (count != 2 or type_str == null or value_str == null) return null;
    const tag = std.meta.stringToEnum(TagType, type_str.?) orelse return null;
    return .{ .tag = tag, .value = value_str.? };
}

fn matchValue(ya: *const AST, y_id: AST.Node.Id, ja: *const AST, j_id: AST.Node.Id) bool {
    if (asLeaf(ja, j_id)) |leaf| return matchLeaf(ya, y_id, leaf);
    return switch (ja.nodes[j_id].kind) {
        .mapping => matchTable(ya, y_id, ja, j_id),
        .sequence => matchArray(ya, y_id, ja, j_id),
        else => false,
    };
}

fn matchTable(ya: *const AST, y_id: AST.Node.Id, ja: *const AST, j_id: AST.Node.Id) bool {
    const yn = ya.nodes[y_id];
    if (yn.kind != .mapping) return false;
    var jcount: usize = 0;
    var jc = ja.nodes[j_id].kind.mapping;
    while (jc) |jid| : (jc = ja.nodes[jid].next_sibling) {
        jcount += 1;
        const jkv = ja.nodes[jid].kind.keyvalue;
        const jkey = ja.nodes[jkv.key].kind.string;
        const yv = childByKey(ya, yn, jkey) orelse return false;
        if (!matchValue(ya, yv, ja, jkv.value)) return false;
    }
    return jcount == countChildren(ya, yn);
}

fn matchArray(ya: *const AST, y_id: AST.Node.Id, ja: *const AST, j_id: AST.Node.Id) bool {
    if (ya.nodes[y_id].kind != .sequence) return false;
    var yc = ya.nodes[y_id].kind.sequence;
    var jc = ja.nodes[j_id].kind.sequence;
    while (true) {
        const yid = yc orelse return jc == null;
        const jid = jc orelse return false;
        if (!matchValue(ya, yid, ja, jid)) return false;
        yc = ya.nodes[yid].next_sibling;
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

fn matchLeaf(ya: *const AST, y_id: AST.Node.Id, leaf: Leaf) bool {
    const node = ya.nodes[y_id].kind;
    return switch (leaf.tag) {
        .@"null" => node == .null_,
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

fn intEqual(raw: []const u8, expected: []const u8) bool {
    const a = yamlIntToDecimal(raw) orelse return false;
    const b = std.fmt.parseInt(i64, expected, 10) catch return false;
    return a == b;
}

/// Resolve a YAML 1.1 integer lexeme to its value: sign, `_` separators, and
/// the five radixes — binary `0b…`, leading-zero octal `0…`, hex `0x…`, base-60
/// `H:MM:SS`, and plain decimal. Returns null for anything not a valid 1.1 int
/// (e.g. `0o17`, `08`), so a mis-typed scalar can't accidentally match.
fn yamlIntToDecimal(raw: []const u8) ?i64 {
    if (raw.len == 0) return null;
    var s = raw;
    var neg = false;
    if (s[0] == '+') {
        s = s[1..];
    } else if (s[0] == '-') {
        neg = true;
        s = s[1..];
    }
    if (s.len == 0) return null;

    // base 60 (sexagesimal): one or more `:`-separated decimal groups.
    if (std.mem.indexOfScalar(u8, s, ':') != null) {
        var val: i64 = 0;
        var groups = std.mem.splitScalar(u8, s, ':');
        while (groups.next()) |group| {
            if (group.len == 0) return null;
            var g: i64 = 0;
            for (group) |c| {
                if (c == '_') continue;
                if (c < '0' or c > '9') return null;
                g = g * 10 + @as(i64, c - '0');
            }
            val = val * 60 + g;
        }
        return if (neg) -val else val;
    }

    var base: u8 = 10;
    if (s.len >= 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
        base = 16;
        s = s[2..];
    } else if (s.len >= 2 and s[0] == '0' and (s[1] == 'b' or s[1] == 'B')) {
        base = 2;
        s = s[2..];
    } else if (s.len >= 2 and s[0] == '0') {
        base = 8; // leading-zero octal (1.1 has no `0o`)
        s = s[1..];
    }

    var buf: [64]u8 = undefined;
    var n: usize = 0;
    for (s) |c| {
        if (c == '_') continue;
        if (n >= buf.len) return null;
        buf[n] = c;
        n += 1;
    }
    if (n == 0) return if (base == 8) 0 else null; // bare "0"
    const v = std.fmt.parseInt(i64, buf[0..n], base) catch return null;
    return if (neg) -v else v;
}

fn floatEqual(raw: []const u8, expected: []const u8) bool {
    const a = yamlFloatToF64(raw) orelse return false;
    const b = yamlFloatToF64(expected) orelse return false;
    if (std.math.isNan(a)) return std.math.isNan(b);
    if (std.math.isNan(b)) return false;
    return a == b;
}

/// Resolve a YAML 1.1 float lexeme: sign, `_` separators, `.inf`/`.nan` (any
/// case), base-60 (`H:MM:SS.frac`), and ordinary decimal/exponent forms.
fn yamlFloatToF64(raw: []const u8) ?f64 {
    if (raw.len == 0) return null;
    var s = raw;
    var neg = false;
    if (s[0] == '+') {
        s = s[1..];
    } else if (s[0] == '-') {
        neg = true;
        s = s[1..];
    }
    if (s.len == 0) return null;

    if (std.ascii.eqlIgnoreCase(s, ".inf") or std.ascii.eqlIgnoreCase(s, "inf")) {
        return if (neg) -std.math.inf(f64) else std.math.inf(f64);
    }
    if (std.ascii.eqlIgnoreCase(s, ".nan") or std.ascii.eqlIgnoreCase(s, "nan")) {
        return std.math.nan(f64);
    }

    // base 60: `H:MM:SS.frac` — accumulate in base 60, last group may be float.
    if (std.mem.indexOfScalar(u8, s, ':') != null) {
        var val: f64 = 0;
        var groups = std.mem.splitScalar(u8, s, ':');
        while (groups.next()) |group| {
            const g = parseStripped(group) orelse return null;
            val = val * 60 + g;
        }
        return if (neg) -val else val;
    }

    const v = parseStripped(s) orelse return null;
    return if (neg) -v else v;
}

fn parseStripped(s: []const u8) ?f64 {
    var buf: [64]u8 = undefined;
    var n: usize = 0;
    for (s) |c| {
        if (c == '_') continue;
        if (n >= buf.len) return null;
        buf[n] = c;
        n += 1;
    }
    if (n == 0) return null;
    return std.fmt.parseFloat(f64, buf[0..n]) catch null;
}

/// Compare timestamps after normalizing the separator to `T` and letters to
/// upper-case (`t`/`z` → `T`/`Z`, space → `T`). Lenient on fractional digits.
fn datetimeEqual(raw: []const u8, expected: []const u8) bool {
    var a: [64]u8 = undefined;
    var b: [64]u8 = undefined;
    const na = normalizeDatetime(raw, &a) orelse return false;
    const nb = normalizeDatetime(expected, &b) orelse return false;
    return std.mem.eql(u8, na, nb);
}

fn normalizeDatetime(s: []const u8, buf: []u8) ?[]const u8 {
    var w: usize = 0;
    for (s, 0..) |c, i| {
        if (w >= buf.len) return null;
        if (i == 10 and (c == ' ' or c == 't')) {
            buf[w] = 'T';
        } else {
            buf[w] = std.ascii.toUpper(c);
        }
        w += 1;
    }
    return buf[0..w];
}
