//! Dev tool: expand the yaml-test-suite into fig's accept/reject fixture tree.
//!
//! This is a Zig port of the former scripts/gen_yaml_conformance.py. It parses
//! the suite's `src/*.yaml` meta-files with fig itself, so regenerating the
//! conformance corpus needs no third-party YAML library — just `zig build`.
//!
//! The meta structure fig must parse is a simple sequence of mappings whose
//! fields are plain or `|`-block scalars; the exotic YAML under test lives inside
//! those opaque block scalars, so fig is not parsing the constructs it is being
//! tested on. It is, however, somewhat circular — after a fig parser change,
//! cross-check the output against an independent parser (e.g. PyYAML).
//!
//! Each test item is written to:
//!     testdata/yaml/accept/<id>.yaml   (must parse)
//!     testdata/yaml/reject/<id>.yaml   (must fail to parse)
//!     testdata/yaml/stream/<id>.yaml   (purely multi-document; must split +
//!                                       parse via Embed.extractStream)
//! Multi-item files become <id>-1.yaml, <id>-2.yaml, ... The only out-of-scope
//! tests now are *failing* multi-document streams (a passing one is handled by
//! Embed.extractStream); they are listed in testdata/yaml/skiplist.txt.
//!
//! Usage: zig build gen-yaml-conformance -- <path-to-yaml-test-suite> [<fig-root>]

const std = @import("std");
const fig = @import("fig");
const AST = fig.AST;
const Io = std.Io;
const activeTag = std.meta.activeTag;

const max_file = 4 * 1024 * 1024;

const Skip = struct { id: []const u8, reasons: []const u8 };

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next(); // binary name
    const suite = args.next() orelse {
        std.debug.print(
            "usage: gen_yaml_conformance <path-to-yaml-test-suite> [<fig-root>]\n",
            .{},
        );
        return error.MissingArgument;
    };
    const fig_root = args.next() orelse ".";

    const src_path = try std.fs.path.join(arena, &.{ suite, "src" });
    const accept_path = try std.fs.path.join(arena, &.{ fig_root, "testdata", "yaml", "accept" });
    const reject_path = try std.fs.path.join(arena, &.{ fig_root, "testdata", "yaml", "reject" });
    // Multi-document streams: parsed via the Embed.extractStream splitter (the
    // single-document parser refuses a stream), so they get their own category.
    // A failing stream lands in reject-stream (extractStream must error on it).
    const stream_path = try std.fs.path.join(arena, &.{ fig_root, "testdata", "yaml", "stream" });
    const reject_stream_path = try std.fs.path.join(arena, &.{ fig_root, "testdata", "yaml", "reject-stream" });
    const yaml_path = try std.fs.path.join(arena, &.{ fig_root, "testdata", "yaml" });

    const cwd = std.Io.Dir.cwd();
    var src_dir = try cwd.openDir(io, src_path, .{ .iterate = true });
    defer src_dir.close(io);
    var accept_dir = try cwd.openDir(io, accept_path, .{ .iterate = true });
    defer accept_dir.close(io);
    var reject_dir = try cwd.openDir(io, reject_path, .{ .iterate = true });
    defer reject_dir.close(io);
    try cwd.createDirPath(io, stream_path);
    var stream_dir = try cwd.openDir(io, stream_path, .{ .iterate = true });
    defer stream_dir.close(io);
    try cwd.createDirPath(io, reject_stream_path);
    var reject_stream_dir = try cwd.openDir(io, reject_stream_path, .{ .iterate = true });
    defer reject_stream_dir.close(io);
    var yaml_dir = try cwd.openDir(io, yaml_path, .{});
    defer yaml_dir.close(io);

    // Start from a clean corpus: this tool only writes, so stale fixtures from a
    // previous run (or a test that has since moved category) must be cleared.
    try clearFixtures(io, accept_dir);
    try clearFixtures(io, reject_dir);
    try clearFixtures(io, stream_dir);
    try clearFixtures(io, reject_stream_dir);

    // Collect and sort the source file names for deterministic output.
    var names: std.ArrayList([]const u8) = .empty;
    var it = src_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".yaml")) continue;
        try names.append(arena, try arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThanStr);

    var n_accept: usize = 0;
    var n_reject: usize = 0;
    var n_stream: usize = 0;
    var n_reject_stream: usize = 0;
    var n_noyaml: usize = 0;
    var skips: std.ArrayList(Skip) = .empty;

    for (names.items) |name| {
        const base = name[0 .. name.len - ".yaml".len];
        const content = try src_dir.readFileAlloc(io, name, arena, .limited(max_file));

        const Lang = fig.Language.YAML;
        var doc = Lang.Parser.parse(arena, content, Lang.default_type) catch |err| {
            std.debug.print("fig failed to parse {s}: {s}\n", .{ name, @errorName(err) });
            return err;
        };
        defer doc.deinit(arena);
        const ast = &doc.ast;

        const root = ast.nodes[ast.root];
        if (activeTag(root.kind) != .sequence) continue;
        var first_child = root.kind.sequence;
        const first = if (first_child) |id| ast.nodes[id] else continue;

        var i: usize = 0;
        while (first_child) |id| : (i += 1) {
            const item = ast.nodes[id];
            first_child = item.next_sibling;

            // `yaml`/`tree` inherit item 0's value when absent; `fail` does not
            // (a later case that omits it is a valid case).
            const yaml = fieldString(ast, item, "yaml") orelse fieldString(ast, first, "yaml") orelse {
                n_noyaml += 1;
                continue;
            };
            const tree = fieldString(ast, item, "tree") orelse fieldString(ast, first, "tree") orelse "";
            const fail = fieldBool(ast, item, "fail");
            // `skip: true` marks a case the suite authors deem unreliable (valid by
            // the grammar but not usefully so, likely to be made invalid later) and
            // ask runners to exclude. It inherits from item 0 like tags/tree.
            if (fieldBool(ast, item, "skip") or fieldBool(ast, first, "skip")) continue;

            const test_id = if (i == 0)
                base
            else
                try std.fmt.allocPrint(arena, "{s}-{d}", .{ base, i });
            const data = try decode(arena, yaml);

            const reasons = try outOfScopeReasons(arena, tree);
            const file = try std.fmt.allocPrint(arena, "{s}.yaml", .{test_id});
            if (reasons.len > 0) {
                // A multi-document stream is handled by the Embed.extractStream
                // splitter: a passing one must split + parse (stream/), a failing
                // one must make the splitter error (reject-stream/). Any other
                // out-of-scope reason is skiplisted.
                if (reasons.len == 1 and std.mem.eql(u8, reasons[0], "multi-document")) {
                    if (fail) {
                        try reject_stream_dir.writeFile(io, .{ .sub_path = file, .data = data });
                        n_reject_stream += 1;
                    } else {
                        try stream_dir.writeFile(io, .{ .sub_path = file, .data = data });
                        n_stream += 1;
                    }
                } else {
                    try skips.append(arena, .{
                        .id = test_id,
                        .reasons = try std.mem.join(arena, " ", reasons),
                    });
                }
                continue;
            }

            if (fail) {
                try reject_dir.writeFile(io, .{ .sub_path = file, .data = data });
                n_reject += 1;
            } else {
                try accept_dir.writeFile(io, .{ .sub_path = file, .data = data });
                n_accept += 1;
            }
        }
    }

    std.mem.sort(Skip, skips.items, {}, lessThanSkip);
    try writeSkiplist(io, yaml_dir, arena, skips.items);

    std.debug.print(
        "accept: {d}  reject: {d}  stream: {d}  reject-stream: {d}  out-of-scope(skipped): {d}  no-yaml-field: {d}\n",
        .{ n_accept, n_reject, n_stream, n_reject_stream, skips.items.len, n_noyaml },
    );
}

fn clearFixtures(io: Io, dir: Io.Dir) !void {
    // Collect names first, then delete, to avoid mutating during iteration.
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".yaml")) continue;
        try names.append(a, try a.dupe(u8, entry.name));
    }
    for (names.items) |name| try dir.deleteFile(io, name);
}

/// The string value of `key` in a mapping node, or null if absent / non-string.
fn fieldString(ast: *const AST, map: AST.Node, key: []const u8) ?[]const u8 {
    if (activeTag(map.kind) != .mapping) return null;
    var cur = map.kind.mapping;
    while (cur) |id| {
        const node = ast.nodes[id];
        const kv = switch (node.kind) {
            .keyvalue => |k| k,
            else => return null,
        };
        const name = switch (ast.nodes[kv.key].kind) {
            .string => |s| s,
            else => "",
        };
        if (std.mem.eql(u8, name, key)) {
            return switch (ast.nodes[kv.value].kind) {
                .string => |s| s,
                else => null,
            };
        }
        cur = node.next_sibling;
    }
    return null;
}

/// The boolean value of `key` in a mapping node; false if absent / non-boolean.
fn fieldBool(ast: *const AST, map: AST.Node, key: []const u8) bool {
    if (activeTag(map.kind) != .mapping) return false;
    var cur = map.kind.mapping;
    while (cur) |id| {
        const node = ast.nodes[id];
        const kv = switch (node.kind) {
            .keyvalue => |k| k,
            else => return false,
        };
        const name = switch (ast.nodes[kv.key].kind) {
            .string => |s| s,
            else => "",
        };
        if (std.mem.eql(u8, name, key)) {
            return switch (ast.nodes[kv.value].kind) {
                .boolean => |b| b,
                else => false,
            };
        }
        cur = node.next_sibling;
    }
    return false;
}

/// Out-of-scope reasons for a test (empty == in scope). The only remaining
/// out-of-scope feature is a multi-document stream that *also fails*: a passing
/// stream is handled by Embed.extractStream, but a failing one would need the
/// splitter to reject it (see the call site). Detected structurally from the
/// event tree (two or more `+DOC`).
fn outOfScopeReasons(arena: std.mem.Allocator, tree: []const u8) ![]const []const u8 {
    var reasons: std.ArrayList([]const u8) = .empty;
    if (std.mem.count(u8, tree, "+DOC") >= 2) try reasons.append(arena, "multi-document");
    return reasons.items;
}

/// Decode the yaml-test-suite whitespace placeholders into real bytes.
fn decode(arena: std.mem.Allocator, src: []const u8) ![]const u8 {
    const space = "\xe2\x90\xa3"; // ␣
    const em_dash = "\xe2\x80\x94"; // —
    const guillemet = "\xc2\xbb"; // »
    const cr_in = "\xe2\x86\x90"; // ←
    const bom_in = "\xe2\x87\x94"; // ⇔
    const newline_in = "\xe2\x86\xb5"; // ↵
    const no_final = "\xe2\x88\x8e"; // ∎

    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < src.len) {
        if (matchAt(src, i, space)) {
            try out.append(arena, ' ');
            i += space.len;
        } else if (matchAt(src, i, em_dash) or matchAt(src, i, guillemet)) {
            // `—*»` (zero+ EM DASH then ») is a hard tab. A run of EM DASHes not
            // terminated by `»` is literal text.
            var j = i;
            while (matchAt(src, j, em_dash)) j += em_dash.len;
            if (matchAt(src, j, guillemet)) {
                try out.append(arena, '\t');
                i = j + guillemet.len;
            } else if (i == j) {
                // A lone `»` (not preceded by a dash): also a tab per `—*»`.
                try out.append(arena, '\t');
                i += guillemet.len;
            } else {
                try out.appendSlice(arena, src[i .. i + em_dash.len]);
                i += em_dash.len;
            }
        } else if (matchAt(src, i, newline_in)) {
            try out.append(arena, '\n');
            i += newline_in.len;
        } else if (matchAt(src, i, cr_in)) {
            try out.append(arena, '\r');
            i += cr_in.len;
        } else if (matchAt(src, i, bom_in)) {
            try out.appendSlice(arena, "\xef\xbb\xbf"); // U+FEFF byte order mark
            i += bom_in.len;
        } else if (matchAt(src, i, no_final)) {
            // ∎ marks the absence of a final newline: it and any newline directly
            // after it are dropped.
            i += no_final.len;
            if (i < src.len and src[i] == '\n') i += 1;
        } else {
            try out.append(arena, src[i]);
            i += 1;
        }
    }
    return out.items;
}

fn matchAt(haystack: []const u8, i: usize, needle: []const u8) bool {
    return i + needle.len <= haystack.len and std.mem.eql(u8, haystack[i .. i + needle.len], needle);
}

fn writeSkiplist(io: Io, yaml_dir: Io.Dir, arena: std.mem.Allocator, skips: []const Skip) !void {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, "# Out-of-scope tests excluded from the conformance corpus.\n");
    try buf.appendSlice(arena, "# Generated by tools/gen_yaml_conformance.zig.\n");
    for (skips) |skip| {
        try buf.appendSlice(arena, skip.id);
        try buf.append(arena, '\t');
        try buf.appendSlice(arena, skip.reasons);
        try buf.append(arena, '\n');
    }
    try yaml_dir.writeFile(io, .{ .sub_path = "skiplist.txt", .data = buf.items });
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn lessThanSkip(_: void, a: Skip, b: Skip) bool {
    return std.mem.lessThan(u8, a.id, b.id);
}
