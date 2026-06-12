//! Dev tool: STRUCTURAL conformance check against the yaml-test-suite `tree:`.
//!
//! The conformance scoreboard (src/yaml/conformance.zig) is pass/fail only: a
//! fixture fig *accepts* but parses to the WRONG SHAPE still counts as a pass.
//! This tool closes that blind spot by comparing the *structure* of fig's parse
//! against the suite's canonical event tree (`tree:`) for every in-scope accept
//! case.
//!
//! fig's AST stores decoded strings only — no scalar-style tracking — so a
//! byte-exact event match is impossible (it can't reproduce `:`/`'`/`"`/`|`/`>`
//! style indicators, nor `null` vs `~` presentation). So both sides are
//! NORMALIZED to a structure-only token stream:
//!     +SEQ -> [    -SEQ -> ]    +MAP -> {    -MAP -> }
//!     =VAL -> S    =ALI -> S    (every scalar/alias is an opaque leaf)
//!     +STR/-STR/+DOC/-DOC -> dropped (fig is single-document; root == doc body)
//! A mismatch here is a genuine mis-parse: wrong nesting, a dropped/extra node,
//! a key/value miscount. This is what catches `- - c` (flat vs nested), the
//! BD7L indentless-return shape, and flow `?`-key gaps.
//!
//! Usage: zig build check-yaml-trees -- <path-to-yaml-test-suite> [<fig-root>]
//! Like the scoreboard, this RATCHETS: it exits nonzero only if the structural
//! mismatch count rises above `mismatch_baseline` — so a regression that breaks a
//! currently-correct parse fails the run, while the known-exotic mismatches
//! (compact nested sequences `- - c`, complex `?` keys) are tracked without
//! blocking. Lower the baseline as those are fixed; never raise it silently.

const std = @import("std");
const fig = @import("fig");
const AST = fig.AST;
const Io = std.Io;
const activeTag = std.meta.activeTag;

const max_file = 4 * 1024 * 1024;

// Known structural mismatches: fig accepts these but parses them to the wrong
// shape (the pass/fail scoreboard rates them as passes). Two root causes:
//   - compact nested sequences flatten: `- - c` -> [c] not [[c]]
//     (3ALJ, 6BCT, 7ZZ5, A2M4, W42U; AB8U is the multi-line-plain sibling)
//   - a collection used as a complex `?` key collapses into sibling null entries
//     (6PBE, KK5P, M2N8, M2N8-1, RZP5, XW4D)
// All are exotic block constructs absent from typical frontmatter. RATCHET: the
// run fails if the count rises above this; lower it as fixes land.
const mismatch_baseline = 12;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    const suite = args.next() orelse {
        std.debug.print("usage: check_yaml_trees <path-to-yaml-test-suite> [<fig-root>]\n", .{});
        return error.MissingArgument;
    };

    const src_path = try std.fs.path.join(arena, &.{ suite, "src" });
    const cwd = std.Io.Dir.cwd();
    var src_dir = try cwd.openDir(io, src_path, .{ .iterate = true });
    defer src_dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var it = src_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".yaml")) continue;
        try names.append(arena, try arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThanStr);

    var n_checked: usize = 0;
    var n_match: usize = 0;
    var n_empty_doc: usize = 0;
    var mismatches: std.ArrayList([]const u8) = .empty;
    var parse_errs: std.ArrayList([]const u8) = .empty;

    for (names.items) |name| {
        const base = name[0 .. name.len - ".yaml".len];
        const content = try src_dir.readFileAlloc(io, name, arena, .limited(max_file));

        const Lang = fig.Language.YAML;
        var meta = Lang.Parser.parse(arena, content, Lang.default_type) catch continue;
        defer meta.deinit(arena);
        const mast = &meta.ast;

        const root = mast.nodes[mast.root];
        if (activeTag(root.kind) != .sequence) continue;
        var first_child = root.kind.sequence;
        const first = if (first_child) |id| mast.nodes[id] else continue;

        var i: usize = 0;
        while (first_child) |id| : (i += 1) {
            const item = mast.nodes[id];
            first_child = item.next_sibling;

            const yaml = fieldString(mast, item, "yaml") orelse fieldString(mast, first, "yaml") orelse continue;
            const tree = fieldString(mast, item, "tree") orelse fieldString(mast, first, "tree") orelse continue;
            const fail = fieldBool(mast, item, "fail");
            if (fieldBool(mast, item, "skip") or fieldBool(mast, first, "skip")) continue;
            if (fail) continue; // only accept cases have a meaningful tree to match
            if (std.mem.count(u8, tree, "+DOC") >= 2) continue; // multi-document: out of scope

            const test_id = if (i == 0) base else try std.fmt.allocPrint(arena, "{s}-{d}", .{ base, i });
            const data = try decode(arena, yaml);

            // Parse with fig. A parse error here means the accept scoreboard would
            // also fail it — report separately, it's not a structural question.
            var doc = Lang.Parser.parse(arena, data, Lang.default_type) catch {
                try parse_errs.append(arena, try arena.dupe(u8, test_id));
                continue;
            };
            defer doc.deinit(arena);

            const want = try normalizeSuiteTree(arena, tree);
            const got = try emitFigStructure(arena, &doc.ast);

            n_checked += 1;
            // Benign divergence: an empty/comment/marker-only document. The suite
            // models it as a document with no content node (tree normalizes to
            // ""); fig deliberately yields a `null_` root (-> "S"). Documented
            // choice ("empty doc -> null root"), not a mis-parse — don't flag it.
            const empty_doc_null = std.mem.eql(u8, want, "") and
                activeTag(doc.ast.nodes[doc.ast.root].kind) == .null_;
            if (std.mem.eql(u8, want, got)) {
                n_match += 1;
            } else if (empty_doc_null) {
                n_empty_doc += 1;
            } else {
                try mismatches.append(arena, try std.fmt.allocPrint(
                    arena,
                    "{s}\n    want: {s}\n    got:  {s}\n    yaml: {s}",
                    .{ test_id, want, got, oneLine(arena, data) catch data },
                ));
            }
        }
    }

    std.debug.print("\nStructural tree conformance (in-scope single-doc accept cases)\n", .{});
    std.debug.print("  checked: {d}   match: {d}   mismatch: {d}   (empty-doc->null: {d}, parse-error: {d})\n\n", .{
        n_checked, n_match, mismatches.items.len, n_empty_doc, parse_errs.items.len,
    });
    if (mismatches.items.len > 0) {
        std.debug.print("MISMATCHES (fig parses to the wrong shape):\n", .{});
        for (mismatches.items) |m| std.debug.print("  {s}\n", .{m});
    }
    if (parse_errs.items.len > 0) {
        std.debug.print("\nPARSE ERRORS (would also fail accept scoreboard): {s}\n", .{
            try std.mem.join(arena, " ", parse_errs.items),
        });
    }
    std.debug.print("\n  baseline {d}; ", .{mismatch_baseline});
    if (mismatches.items.len > mismatch_baseline) {
        std.debug.print("REGRESSION: {d} > baseline.\n", .{mismatches.items.len});
        return error.StructuralRegression;
    }
    std.debug.print("ok ({d} <= baseline).\n", .{mismatches.items.len});
}

/// Normalize the suite's event `tree:` to a structure-only token stream.
fn normalizeSuiteTree(arena: std.mem.Allocator, tree: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, tree, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " ");
        if (line.len == 0) continue;
        const tok: ?[]const u8 =
            if (std.mem.startsWith(u8, line, "+SEQ")) "["
            else if (std.mem.startsWith(u8, line, "-SEQ")) "]"
            else if (std.mem.startsWith(u8, line, "+MAP")) "{"
            else if (std.mem.startsWith(u8, line, "-MAP")) "}"
            else if (std.mem.startsWith(u8, line, "=VAL")) "S"
            else if (std.mem.startsWith(u8, line, "=ALI")) "S"
            else null; // +STR/-STR/+DOC/-DOC and anything else: dropped
        if (tok) |t| {
            if (out.items.len > 0) try out.append(arena, ' ');
            try out.appendSlice(arena, t);
        }
    }
    return out.items;
}

/// Emit fig's parse as the same structure-only token stream.
fn emitFigStructure(arena: std.mem.Allocator, ast: *const AST) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try emitNode(arena, ast, ast.nodes[ast.root], &out);
    return out.items;
}

fn emitNode(arena: std.mem.Allocator, ast: *const AST, node: AST.Node, out: *std.ArrayList(u8)) !void {
    switch (node.kind) {
        .null_, .boolean, .string, .number, .alias => try push(arena, out, "S"),
        .sequence => |first| {
            try push(arena, out, "[");
            var child = first;
            while (child) |cid| : (child = ast.nodes[cid].next_sibling) {
                try emitNode(arena, ast, ast.nodes[cid], out);
            }
            try push(arena, out, "]");
        },
        .mapping => |first| {
            try push(arena, out, "{");
            var child = first;
            while (child) |cid| : (child = ast.nodes[cid].next_sibling) {
                const kv = ast.nodes[cid].kind.keyvalue;
                try emitNode(arena, ast, ast.nodes[kv.key], out);
                try emitNode(arena, ast, ast.nodes[kv.value], out);
            }
            try push(arena, out, "}");
        },
        .keyvalue => unreachable,
    }
}

fn push(arena: std.mem.Allocator, out: *std.ArrayList(u8), tok: []const u8) !void {
    if (out.items.len > 0) try out.append(arena, ' ');
    try out.appendSlice(arena, tok);
}

fn oneLine(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        if (c == '\n') try out.appendSlice(arena, "\\n") else try out.append(arena, c);
    }
    return out.items;
}

// ── meta-field readers (shared shape with gen_yaml_conformance.zig) ──────────

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

fn decode(arena: std.mem.Allocator, src: []const u8) ![]const u8 {
    const space = "\xe2\x90\xa3";
    const em_dash = "\xe2\x80\x94";
    const guillemet = "\xc2\xbb";
    const cr_in = "\xe2\x86\x90";
    const bom_in = "\xe2\x87\x94";
    const newline_in = "\xe2\x86\xb5";
    const no_final = "\xe2\x88\x8e";

    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < src.len) {
        if (matchAt(src, i, space)) {
            try out.append(arena, ' ');
            i += space.len;
        } else if (matchAt(src, i, em_dash) or matchAt(src, i, guillemet)) {
            var j = i;
            while (matchAt(src, j, em_dash)) j += em_dash.len;
            if (matchAt(src, j, guillemet)) {
                try out.append(arena, '\t');
                i = j + guillemet.len;
            } else if (i == j) {
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
            try out.appendSlice(arena, "\xef\xbb\xbf");
            i += bom_in.len;
        } else if (matchAt(src, i, no_final)) {
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

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}
