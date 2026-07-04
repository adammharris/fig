//! Unified diff — a CLI-only line diff between two versions of the same text,
//! rendered `diff -u` style. Used by `fig fmt --diff` to show what reformatting
//! would change instead of dumping the whole reformatted file (`--dry-run`).
//!
//! Scope is deliberately narrow: two in-memory UTF-8 strings, line-granularity,
//! unified-diff *output* only (no patch application, no character-level
//! intraline highlighting, no three-way merge). That's the whole job `fmt
//! --diff` needs, so it's hand-rolled rather than pulled in as a dependency —
//! `fig` otherwise has zero (see `build.zig.zon`), and this is small and
//! well-understood enough not to be the first exception.
//!
//! Algorithm: classic O(N*M) dynamic-programming LCS over lines, after
//! trimming the common prefix/suffix first. The trim matters more than the
//! O(N*M) bound in practice — `fmt` diffs are almost always a small localized
//! formatting change inside an otherwise-identical file, so the DP table only
//! ever covers the actually-changed middle, not the whole file. A file with no
//! localized common region at all (e.g. two unrelated files) still works, just
//! with a bigger table; `fmt` only ever calls this on a file against its own
//! reformatted self, so that pathological case doesn't arise here.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// One line of the alignment between `old` and `new`: present in both
/// (`.equal`, carrying either copy since they're byte-identical), or only on
/// one side.
const Op = union(enum) {
    equal: []const u8,
    delete: []const u8,
    insert: []const u8,
};

/// Split `text` into lines without their terminating `\n`, matching
/// `std.mem.splitScalar` semantics: a trailing newline does NOT produce a
/// trailing empty line, but a trailing empty line without a final newline
/// (i.e. `text` ending in `\n\n`... no wait, text with no final newline at all
/// after a blank line) still shows up as `""`. Concretely: `"a\nb\n"` -> `{"a",
/// "b"}`; `"a\nb"` -> `{"a", "b"}`; `"a\n\n"` -> `{"a", ""}`.
fn splitLines(allocator: Allocator, text: []const u8) ![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);
    if (text.len == 0) return lines.toOwnedSlice(allocator);

    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| try lines.append(allocator, line);
    // `splitScalar` always yields a trailing "" segment when `text` ends in
    // '\n' (the empty tail after the last separator) — drop it so a final
    // newline doesn't register as an extra blank line.
    if (text[text.len - 1] == '\n') _ = lines.pop();
    return lines.toOwnedSlice(allocator);
}

/// Longest-common-subsequence edit script between `old_lines[lo_o..hi_o]` and
/// `new_lines[lo_n..hi_n]`, appended to `out` in order. Standard backward-DP +
/// forward-walk LCS; the ranges let callers trim a common prefix/suffix first
/// without copying slices.
fn lcsOps(
    allocator: Allocator,
    old_lines: []const []const u8,
    new_lines: []const []const u8,
    out: *std.ArrayList(Op),
) !void {
    const n = old_lines.len;
    const m = new_lines.len;
    if (n == 0 and m == 0) return;
    if (n == 0) {
        for (new_lines) |l| try out.append(allocator, .{ .insert = l });
        return;
    }
    if (m == 0) {
        for (old_lines) |l| try out.append(allocator, .{ .delete = l });
        return;
    }

    // dp[i][j] = length of the LCS of old_lines[i..] and new_lines[j..],
    // flattened into one (n+1)*(m+1) row-major slice.
    const stride = m + 1;
    const dp = try allocator.alloc(u32, (n + 1) * stride);
    defer allocator.free(dp);
    @memset(dp[n * stride ..], 0); // dp[n][*] = 0
    for (0..n + 1) |i| dp[i * stride + m] = 0; // dp[*][m] = 0

    var i = n;
    while (i > 0) {
        i -= 1;
        var j = m;
        while (j > 0) {
            j -= 1;
            dp[i * stride + j] = if (std.mem.eql(u8, old_lines[i], new_lines[j]))
                dp[(i + 1) * stride + (j + 1)] + 1
            else
                @max(dp[(i + 1) * stride + j], dp[i * stride + (j + 1)]);
        }
    }

    // Walk forward, preferring the direction the DP table says preserves the
    // LCS; ties go to `delete` before `insert` so runs come out old-then-new,
    // matching conventional diff output.
    i = 0;
    var j: usize = 0;
    while (i < n and j < m) {
        if (std.mem.eql(u8, old_lines[i], new_lines[j])) {
            try out.append(allocator, .{ .equal = old_lines[i] });
            i += 1;
            j += 1;
        } else if (dp[(i + 1) * stride + j] >= dp[i * stride + (j + 1)]) {
            try out.append(allocator, .{ .delete = old_lines[i] });
            i += 1;
        } else {
            try out.append(allocator, .{ .insert = new_lines[j] });
            j += 1;
        }
    }
    while (i < n) : (i += 1) try out.append(allocator, .{ .delete = old_lines[i] });
    while (j < m) : (j += 1) try out.append(allocator, .{ .insert = new_lines[j] });
}

/// Full edit script between `old` and `new`, trimming the common prefix/suffix
/// first so the DP in `lcsOps` only ever runs over the actually-changed middle.
fn diffOps(allocator: Allocator, old_lines: []const []const u8, new_lines: []const []const u8) ![]const Op {
    var prefix: usize = 0;
    const max_prefix = @min(old_lines.len, new_lines.len);
    while (prefix < max_prefix and std.mem.eql(u8, old_lines[prefix], new_lines[prefix])) prefix += 1;

    var suffix: usize = 0;
    const max_suffix = max_prefix - prefix;
    while (suffix < max_suffix and
        std.mem.eql(u8, old_lines[old_lines.len - 1 - suffix], new_lines[new_lines.len - 1 - suffix])) suffix += 1;

    var out: std.ArrayList(Op) = .empty;
    defer out.deinit(allocator);
    for (old_lines[0..prefix]) |l| try out.append(allocator, .{ .equal = l });
    try lcsOps(allocator, old_lines[prefix .. old_lines.len - suffix], new_lines[prefix .. new_lines.len - suffix], &out);
    for (old_lines[old_lines.len - suffix ..]) |l| try out.append(allocator, .{ .equal = l });
    return out.toOwnedSlice(allocator);
}

/// One `@@ -a,b +c,d @@` block: `[start, end)` into the full `ops` slice.
const Hunk = struct { start: usize, end: usize };

/// Group `ops` into unified-diff hunks: each changed run padded with up to
/// `context` lines of surrounding `.equal` context, merging runs whose gap is
/// small enough that their context would overlap.
fn buildHunks(allocator: Allocator, ops: []const Op, context: usize) ![]const Hunk {
    var hunks: std.ArrayList(Hunk) = .empty;
    defer hunks.deinit(allocator);

    var i: usize = 0;
    while (i < ops.len) {
        if (ops[i] == .equal) {
            i += 1;
            continue;
        }
        // `i` starts a change run. Back up to include leading context, but
        // never into the previous hunk's territory.
        const prev_end = if (hunks.items.len > 0) hunks.items[hunks.items.len - 1].end else 0;
        var start = i;
        var back: usize = 0;
        while (start > prev_end and back < context and ops[start - 1] == .equal) {
            start -= 1;
            back += 1;
        }

        // Extend forward past this change run, absorbing any further change
        // run that's within `2*context` equal lines of this one (so their
        // context regions would otherwise overlap), then stop and take
        // trailing context.
        var end = i;
        while (end < ops.len and ops[end] != .equal) end += 1;
        while (true) {
            var gap_end = end;
            while (gap_end < ops.len and ops[gap_end] == .equal) gap_end += 1;
            const gap = gap_end - end;
            if (gap_end >= ops.len) {
                end += @min(context, gap);
                break;
            }
            if (gap <= 2 * context) {
                var next_end = gap_end;
                while (next_end < ops.len and ops[next_end] != .equal) next_end += 1;
                end = next_end;
                continue;
            }
            end += context;
            break;
        }

        try hunks.append(allocator, .{ .start = start, .end = end });
        i = end;
    }
    return hunks.toOwnedSlice(allocator);
}

/// Render a full unified diff of `old` vs `new` to `writer`, `diff -u` style:
/// `--- <label>` / `+++ <label>` header (same label both sides — this is one
/// file's before/after, not two files), then one `@@ -a,b +c,d @@` block per
/// hunk with ` `/`-`/`+`-prefixed lines. `context` is the number of unchanged
/// lines shown around each change (3 matches conventional `diff -u`/`git
/// diff`). Writes nothing if `old == new`.
pub fn unifiedDiff(allocator: Allocator, writer: *Writer, label: []const u8, old: []const u8, new: []const u8, context: usize) !void {
    if (std.mem.eql(u8, old, new)) return;

    const old_lines = try splitLines(allocator, old);
    defer allocator.free(old_lines);
    const new_lines = try splitLines(allocator, new);
    defer allocator.free(new_lines);

    const ops = try diffOps(allocator, old_lines, new_lines);
    defer allocator.free(ops);
    const hunks = try buildHunks(allocator, ops, context);
    defer allocator.free(hunks);
    if (hunks.len == 0) return;

    try writer.print("--- {s}\n+++ {s}\n", .{ label, label });

    for (hunks) |hunk| {
        // Line numbers just before the hunk: count old/new lines consumed by
        // every op before `hunk.start`.
        var old_line: usize = 0;
        var new_line: usize = 0;
        for (ops[0..hunk.start]) |op| switch (op) {
            .equal => {
                old_line += 1;
                new_line += 1;
            },
            .delete => old_line += 1,
            .insert => new_line += 1,
        };

        var old_count: usize = 0;
        var new_count: usize = 0;
        for (ops[hunk.start..hunk.end]) |op| switch (op) {
            .equal => {
                old_count += 1;
                new_count += 1;
            },
            .delete => old_count += 1,
            .insert => new_count += 1,
        };

        // POSIX unified-diff convention: an empty side reports the line
        // number *before* which the (empty) range sits, with no `+1`.
        const old_start = if (old_count > 0) old_line + 1 else old_line;
        const new_start = if (new_count > 0) new_line + 1 else new_line;
        try writer.print("@@ -{d},{d} +{d},{d} @@\n", .{ old_start, old_count, new_start, new_count });

        for (ops[hunk.start..hunk.end]) |op| switch (op) {
            .equal => |l| try writer.print(" {s}\n", .{l}),
            .delete => |l| try writer.print("-{s}\n", .{l}),
            .insert => |l| try writer.print("+{s}\n", .{l}),
        };
    }
}

test "unifiedDiff: identical text writes nothing" {
    const allocator = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try unifiedDiff(allocator, &out.writer, "file", "a\nb\nc\n", "a\nb\nc\n", 3);
    try std.testing.expectEqualStrings("", out.written());
}

test "unifiedDiff: single-line change in the middle, full context" {
    const allocator = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try unifiedDiff(allocator, &out.writer, "f", "a\nb\nc\nd\ne\n", "a\nb\nX\nd\ne\n", 3);
    try std.testing.expectEqualStrings(
        \\--- f
        \\+++ f
        \\@@ -1,5 +1,5 @@
        \\ a
        \\ b
        \\-c
        \\+X
        \\ d
        \\ e
        \\
    , out.written());
}

test "unifiedDiff: two distant changes stay in separate hunks" {
    const allocator = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const old = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n";
    const new = "1\n2\nX\n4\n5\n6\n7\n8\n9\n10\nY\n12\n";
    try unifiedDiff(allocator, &out.writer, "f", old, new, 3);
    try std.testing.expectEqualStrings(
        \\--- f
        \\+++ f
        \\@@ -1,6 +1,6 @@
        \\ 1
        \\ 2
        \\-3
        \\+X
        \\ 4
        \\ 5
        \\ 6
        \\@@ -8,5 +8,5 @@
        \\ 8
        \\ 9
        \\ 10
        \\-11
        \\+Y
        \\ 12
        \\
    , out.written());
}

test "unifiedDiff: pure insertion at start reports a zero-count old range" {
    // context=0 isolates the insert-only hunk with no surrounding equal
    // lines, so old_count is genuinely 0 (not just small).
    const allocator = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try unifiedDiff(allocator, &out.writer, "f", "a\nb\n", "x\na\nb\n", 0);
    try std.testing.expectEqualStrings(
        \\--- f
        \\+++ f
        \\@@ -0,0 +1,1 @@
        \\+x
        \\
    , out.written());
}

test "unifiedDiff: pure insertion at start with context pulls in trailing lines" {
    const allocator = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try unifiedDiff(allocator, &out.writer, "f", "a\nb\n", "x\na\nb\n", 3);
    try std.testing.expectEqualStrings(
        \\--- f
        \\+++ f
        \\@@ -1,2 +1,3 @@
        \\+x
        \\ a
        \\ b
        \\
    , out.written());
}

test "unifiedDiff: no trailing newline on either side" {
    const allocator = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try unifiedDiff(allocator, &out.writer, "f", "a\nb", "a\nX", 3);
    try std.testing.expectEqualStrings(
        \\--- f
        \\+++ f
        \\@@ -1,2 +1,2 @@
        \\ a
        \\-b
        \\+X
        \\
    , out.written());
}
