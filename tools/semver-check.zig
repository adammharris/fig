//! Dev tool: C ABI **diff** against the last released tag, turned into a SemVer
//! verdict. Where `abi-check.zig` proves the header and implementation agree at a
//! single point in time, this tool compares the *current* header (passed as this
//! tool's first argument) against the header as it existed at the most recent
//! `core/v*` git tag and classifies the delta:
//!
//!   * a removed function, or a changed signature (return type / parameter list)
//!     -> MAJOR (breaking)
//!   * only new functions added                                  -> MINOR (feature)
//!   * no change to the function surface                         -> PATCH
//!
//! From that verdict and the baseline version it computes the minimum acceptable
//! next version and checks the canonical version (from build.zig.zon, passed in by
//! build.zig) against it — failing if you've added or broken ABI without bumping
//! far enough. 0.x baselines follow SemVer's "anything goes in 0.x" rule (a
//! breaking change is a minor bump, a feature is a patch bump).
//!
//! When the delta is breaking (MAJOR), it ALSO requires the header's
//! `FIG_ABI_VERSION` — the binary C ABI contract counter, distinct from the
//! marketing version — to have incremented past the baseline's, so a breaking ABI
//! change can never ship under the same ABI-version number. (A baseline tag that
//! predates the macro carries no number to compare against, so the requirement is
//! waived for it.)
//!
//! Baseline discovery is automatic: `git describe --tags --abbrev=0 --match
//! 'core/v*'` finds the most recent release reachable from HEAD on the *core's*
//! own tag line (see "Release tagging" in docs/VERSIONING.md — the core, CLI,
//! Rust crate, and npm package each get their own `<track>/vX.Y.Z` tags, since
//! they version independently), and `git show <tag>:<path>` reads that
//! release's header — trying the header's current repo path first, then its
//! pre-move path (`include/fig.h`, moved to `bindings/c/include/fig.h`), since
//! older tags predating a header relocation only have it at the old path.
//! `core/v*` is also the tag Zig consumers `zig fetch` against to pin a core
//! version, so this baseline is always a real, fetchable release. With no git
//! / no matching tags (e.g. a source tarball, or a repo that hasn't cut a core
//! release yet), the tool prints a note and exits 0 rather than breaking the
//! build.
//!
//! Coverage: the exported function surface (names + normalized signatures) AND
//! the `typedef struct/enum` surface — struct field layout (order, type, array
//! size) and enum *values* — applying fig's forward-compat policy (size-gated
//! structs may append fields = MINOR; adding an enumerator = MINOR; reordering/
//! retyping/removing a field or changing an enumerator's value = MAJOR). C has no
//! name mangling, so this string-level compare of normalized declarations stands
//! in for a real symbol-table diff. NOT expanded: typedef/macro aliases and
//! `#if`-gated declarations — review those by hand for a major bump.
//!
//! Usage (driven by build.zig): semver-check <header.h> <major.minor.patch> <repo-root>

const std = @import("std");

const max_file = 4 * 1024 * 1024;

const Ver = struct {
    major: u32,
    minor: u32,
    patch: u32,

    fn order(a: Ver, b: Ver) std.math.Order {
        if (a.major != b.major) return std.math.order(a.major, b.major);
        if (a.minor != b.minor) return std.math.order(a.minor, b.minor);
        return std.math.order(a.patch, b.patch);
    }
};

const Fn = struct {
    name: []const u8,
    /// The whole declaration, whitespace-normalized: return type + name + params.
    sig: []const u8,
};

const Verdict = enum { major, minor, patch };

/// More-severe wins: a single major delta anywhere forces a major bump.
fn worse(a: Verdict, b: Verdict) Verdict {
    return if (@intFromEnum(a) < @intFromEnum(b)) a else b;
}

/// A parsed enumerator. `value` is the effective integer where we can evaluate
/// it (so `1`, `0x1`, and `1u << 0` compare equal), else the raw expression text
/// (so two unevaluable spellings still compare, just conservatively).
const EnumVal = union(enum) {
    num: i64,
    text: []const u8,

    fn eql(a: EnumVal, b: EnumVal) bool {
        return switch (a) {
            .num => |x| switch (b) {
                .num => |y| x == y,
                .text => false,
            },
            .text => |x| switch (b) {
                .num => false,
                .text => |y| std.mem.eql(u8, x, y),
            },
        };
    }
};

const Enumerator = struct { name: []const u8, value: EnumVal };

const Field = struct {
    /// The whole normalized declaration, e.g. "char message[256]" — the array
    /// dimension is part of it, so resizing `message` reads as a layout change.
    sig: []const u8,
    /// The declared identifier (before any `[`), e.g. "message".
    name: []const u8,
};

/// A `typedef enum {...} Name;` or `typedef struct {...} Name;`. Opaque handles
/// (`typedef struct Foo Foo;`, no body) carry no layout and are skipped.
const Aggregate = struct {
    name: []const u8,
    is_struct: bool,
    /// A struct whose first field is `uint32_t size` — the version-tag marker of
    /// the size-gated forward-compat policy, for which appending fields is safe.
    size_gated: bool,
    fields: []Field, // structs
    enumerators: []Enumerator, // enums
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next(); // argv0
    const header_path = args.next() orelse return error.MissingArgument;
    const want_version_str = args.next() orelse return error.MissingArgument;
    const repo_root = args.next() orelse return error.MissingArgument;

    const want_version = parseVer(want_version_str) orelse return error.BadVersionArg;

    const cwd = std.Io.Dir.cwd();
    const current_header = try cwd.readFileAlloc(io, header_path, arena, .limited(max_file));

    // --- Discover the baseline release via git (best-effort). ---
    const tag = runGit(arena, io, init.gpa, repo_root, &.{
        "describe", "--tags", "--abbrev=0", "--match", "core/v*",
    }) orelse {
        std.debug.print(
            "semver-check: no release tag found (no git history or no core/v* tags) — skipping diff.\n",
            .{},
        );
        return;
    };
    const tag_trimmed = std.mem.trim(u8, tag, " \t\r\n");

    // Try the header's current repo path first, then its pre-move path — a tag
    // cut before a header relocation (e.g. include/fig.h -> bindings/c/include/
    // fig.h) only has it at the old one.
    const header_paths = [_][]const u8{ "bindings/c/include/fig.h", "include/fig.h" };
    var baseline_header_opt: ?[]u8 = null;
    for (header_paths) |p| {
        const spec = try std.fmt.allocPrint(arena, "{s}:{s}", .{ tag_trimmed, p });
        if (runGit(arena, io, init.gpa, repo_root, &.{ "show", spec })) |h| {
            baseline_header_opt = h;
            break;
        }
    }
    const baseline_header = baseline_header_opt orelse {
        std.debug.print(
            "semver-check: could not read the header at {s} (tried {s} and {s}) — skipping diff.\n",
            .{ tag_trimmed, header_paths[0], header_paths[1] },
        );
        return;
    };

    // Baseline version: prefer the header macros (what actually shipped), fall
    // back to the tag string (strip a leading 'v').
    const baseline_version = headerVersion(baseline_header) orelse
        parseVer(std.mem.trimStart(u8, tag_trimmed, "v")) orelse
        return error.BadBaselineVersion;

    // --- Diff the function surfaces. ---
    const base_fns = try collectFns(arena, baseline_header);
    const cur_fns = try collectFns(arena, current_header);

    var added: std.ArrayList(Fn) = .empty;
    var removed: std.ArrayList(Fn) = .empty;
    var changed: std.ArrayList([2]Fn) = .empty; // [base, current]

    for (cur_fns) |c| {
        if (findFn(base_fns, c.name)) |b| {
            if (!std.mem.eql(u8, b.sig, c.sig)) try changed.append(arena, .{ b, c });
        } else try added.append(arena, c);
    }
    for (base_fns) |b| {
        if (findFn(cur_fns, b.name) == null) try removed.append(arena, b);
    }

    var verdict: Verdict =
        if (removed.items.len > 0 or changed.items.len > 0) .major
        else if (added.items.len > 0) .minor
        else .patch;

    // --- Diff the struct/enum surfaces (layout + enumerator values). ---
    const base_aggs = try collectAggregates(arena, baseline_header);
    const cur_aggs = try collectAggregates(arena, current_header);
    const agg = try diffAggregates(arena, base_aggs, cur_aggs);
    verdict = worse(verdict, agg.verdict);

    // --- C ABI contract version (FIG_ABI_VERSION). A breaking delta must bump it.
    // A baseline that predates the macro has no number to compare, so the rule is
    // waived there (null base); a present baseline with a missing current is a
    // failure (the macro must not be removed). ---
    const base_abi = macroInt(baseline_header, "FIG_ABI_VERSION");
    const cur_abi = macroInt(current_header, "FIG_ABI_VERSION");
    const abi_ok = if (verdict != .major)
        true // only a breaking change demands an ABI-version bump
    else if (base_abi) |ba|
        (if (cur_abi) |ca| ca > ba else false)
    else
        true; // baseline predates FIG_ABI_VERSION — nothing to compare

    // --- Report. ---
    std.debug.print("semver-check: C ABI diff (function surface)\n", .{});
    std.debug.print("  baseline {s} ({d} symbols)  ->  working tree ({d} symbols)\n", .{
        tag_trimmed, base_fns.len, cur_fns.len,
    });
    for (added.items) |f| std.debug.print("  + {s}\n", .{f.sig});
    for (removed.items) |f| std.debug.print("  - {s}\n", .{f.sig});
    for (changed.items) |pair| {
        std.debug.print("  ~ {s}\n      was: {s}\n      now: {s}\n", .{ pair[0].name, pair[0].sig, pair[1].sig });
    }
    if (added.items.len == 0 and removed.items.len == 0 and changed.items.len == 0) {
        std.debug.print("  (no change to the exported function surface)\n", .{});
    }

    std.debug.print("semver-check: C ABI diff (struct/enum surface)\n", .{});
    std.debug.print("  baseline ({d} aggregates)  ->  working tree ({d} aggregates)\n", .{
        base_aggs.len, cur_aggs.len,
    });
    for (agg.lines) |line| std.debug.print("  {s}\n", .{line});
    if (agg.lines.len == 0) {
        std.debug.print("  (no change to struct layout or enum values)\n", .{});
    }

    std.debug.print("semver-check: C ABI contract version (FIG_ABI_VERSION)\n", .{});
    std.debug.print("  baseline {s}  ->  working tree {s}\n", .{
        if (base_abi) |ba| std.fmt.allocPrint(arena, "v{d}", .{ba}) catch "?" else "(absent)",
        if (cur_abi) |ca| std.fmt.allocPrint(arena, "v{d}", .{ca}) catch "?" else "(absent)",
    });

    const suggested = bump(baseline_version, verdict);
    const required = switch (verdict) {
        .major, .minor => suggested, // an API delta demands at least this version
        .patch => baseline_version, // no delta: just don't regress below the release
    };

    std.debug.print("verdict: {s}  (suggested next version: {d}.{d}.{d})\n", .{
        @tagName(verdict), suggested.major, suggested.minor, suggested.patch,
    });

    var failed = false;

    if (want_version.order(required) == .lt) {
        std.debug.print(
            "build.zig.zon: {d}.{d}.{d}  ->  FAIL: bump to >= {d}.{d}.{d} before release\n",
            .{ want_version.major, want_version.minor, want_version.patch, required.major, required.minor, required.patch },
        );
        failed = true;
    } else {
        std.debug.print("build.zig.zon: {d}.{d}.{d}  ->  OK (covers the ABI delta)\n", .{
            want_version.major, want_version.minor, want_version.patch,
        });
    }

    if (!abi_ok) {
        std.debug.print(
            "FIG_ABI_VERSION  ->  FAIL: a breaking (MAJOR) ABI change must increment it past the baseline ({s})\n",
            .{if (base_abi) |ba| std.fmt.allocPrint(arena, "v{d}", .{ba}) catch "?" else "(absent)"},
        );
        failed = true;
    }

    if (failed) {
        std.debug.print(
            "note: typedef/macro aliases and #if-gated declarations are not expanded — review those by hand for a major bump.\n",
            .{},
        );
        std.process.exit(1);
    }
}

/// Run `git -C <root> <args...>`, returning trimmed-nothing stdout on a clean
/// exit, or null on any failure (missing git, non-zero exit, unreadable object).
fn runGit(
    arena: std.mem.Allocator,
    io: std.Io,
    gpa: std.mem.Allocator,
    root: []const u8,
    git_args: []const []const u8,
) ?[]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    argv.append(arena, "git") catch return null;
    argv.append(arena, "-C") catch return null;
    argv.append(arena, root) catch return null;
    argv.appendSlice(arena, git_args) catch return null;

    const res = std.process.run(gpa, io, .{ .argv = argv.items }) catch return null;
    // run() hands back caller-owned stdout/stderr on `gpa`; copy what we keep into
    // the arena and free the originals so the leak checker stays quiet.
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    switch (res.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    return arena.dupe(u8, res.stdout) catch null;
}

fn bump(base: Ver, verdict: Verdict) Ver {
    if (base.major == 0) {
        // 0.x: breaking changes are allowed in a minor bump; features in a patch.
        return switch (verdict) {
            .major => .{ .major = 0, .minor = base.minor + 1, .patch = 0 },
            .minor, .patch => .{ .major = 0, .minor = base.minor, .patch = base.patch + 1 },
        };
    }
    return switch (verdict) {
        .major => .{ .major = base.major + 1, .minor = 0, .patch = 0 },
        .minor => .{ .major = base.major, .minor = base.minor + 1, .patch = 0 },
        .patch => .{ .major = base.major, .minor = base.minor, .patch = base.patch + 1 },
    };
}

fn parseVer(s: []const u8) ?Ver {
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, s, " \t\r\n"), '.');
    const major = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const minor = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const patch = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    return .{ .major = major, .minor = minor, .patch = patch };
}

/// The version spelled by a header's `#define FIG_VERSION_*` lines, or null.
fn headerVersion(header: []const u8) ?Ver {
    return .{
        .major = macroInt(header, "FIG_VERSION_MAJOR") orelse return null,
        .minor = macroInt(header, "FIG_VERSION_MINOR") orelse return null,
        .patch = macroInt(header, "FIG_VERSION_PATCH") orelse return null,
    };
}

fn macroInt(text: []const u8, name: []const u8) ?u32 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed, "#define")) continue;
        var it = std.mem.tokenizeAny(u8, trimmed, " \t");
        _ = it.next(); // #define
        const macro = it.next() orelse continue;
        if (!std.mem.eql(u8, macro, name)) continue;
        const value = it.next() orelse return null;
        return std.fmt.parseInt(u32, value, 10) catch null;
    }
    return null;
}

fn isNameChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '_';
}

/// Extract every `fig_*` function declaration as a (name, normalized-signature)
/// pair. Comments and preprocessor lines are stripped, the text is split into
/// `;`-terminated statements, and any statement whose first `fig_<name>` token is
/// immediately followed by `(` is treated as a function declaration whose whole
/// normalized text is the signature.
fn collectFns(arena: std.mem.Allocator, header: []const u8) ![]Fn {
    const no_comments = try stripComments(arena, header);
    const no_directives = try stripDirectives(arena, no_comments);
    const scrubbed = try scrubCpp(arena, no_directives);

    var list: std.ArrayList(Fn) = .empty;
    var stmts = std.mem.splitScalar(u8, scrubbed, ';');
    while (stmts.next()) |stmt| {
        const sig = try normalizeWs(arena, stmt);
        if (sig.len == 0) continue;
        const name = functionName(sig) orelse continue;
        try list.append(arena, .{ .name = name, .sig = sig });
    }
    std.mem.sort(Fn, list.items, {}, lessThanFn);
    return list.items;
}

/// The first `fig_<name>` in `sig` that is immediately followed by `(` and not
/// the tail of a longer identifier — i.e. the declared function's name.
fn functionName(sig: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, sig, i, "fig_")) |pos| {
        if (pos > 0 and isNameChar(sig[pos - 1])) {
            i = pos + 4;
            continue;
        }
        var end = pos + 4;
        while (end < sig.len and isNameChar(sig[end])) end += 1;
        if (end < sig.len and sig[end] == '(') return sig[pos..end];
        i = end;
    }
    return null;
}

/// Replace `//...` and `/*...*/` comments with a single space.
fn stripComments(arena: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (i + 1 < text.len and text[i] == '/' and text[i + 1] == '/') {
            while (i < text.len and text[i] != '\n') i += 1;
            try out.append(arena, ' ');
        } else if (i + 1 < text.len and text[i] == '/' and text[i + 1] == '*') {
            i += 2;
            while (i + 1 < text.len and !(text[i] == '*' and text[i + 1] == '/')) i += 1;
            i += 2;
            try out.append(arena, ' ');
        } else {
            try out.append(arena, text[i]);
            i += 1;
        }
    }
    return out.items;
}

/// Drop preprocessor directives, including the continuation lines of a `\`-ended
/// `#define` (otherwise a multi-line macro body leaks into the next declaration).
fn stripDirectives(arena: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var in_continuation = false;
    while (lines.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (in_continuation or std.mem.startsWith(u8, trimmed, "#")) {
            const rstripped = std.mem.trimEnd(u8, line, " \t\r");
            in_continuation = std.mem.endsWith(u8, rstripped, "\\");
            continue;
        }
        try out.appendSlice(arena, line);
        try out.append(arena, '\n');
    }
    return out.items;
}

/// Remove the `extern "C"` wrapper and any braces, so a declaration that happens
/// to follow `extern "C" {` (or an enum/struct body) isn't glued onto its sig.
/// Brace bodies don't contain `;`, so this never splits a real declaration.
fn scrubCpp(arena: std.mem.Allocator, text: []const u8) ![]u8 {
    const no_extern = try std.mem.replaceOwned(u8, arena, text, "extern \"C\"", " ");
    for (no_extern) |*c| {
        if (c.* == '{' or c.* == '}') c.* = ' ';
    }
    return no_extern;
}

/// Collapse every run of whitespace to a single space and trim the ends.
fn normalizeWs(arena: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var prev_space = true; // leading: suppress
    for (text) |c| {
        const is_space = c == ' ' or c == '\t' or c == '\n' or c == '\r';
        if (is_space) {
            if (!prev_space) try out.append(arena, ' ');
            prev_space = true;
        } else {
            try out.append(arena, c);
            prev_space = false;
        }
    }
    if (out.items.len > 0 and out.items[out.items.len - 1] == ' ') _ = out.pop();
    return out.items;
}

fn findFn(fns: []const Fn, name: []const u8) ?Fn {
    for (fns) |f| if (std.mem.eql(u8, f.name, name)) return f;
    return null;
}

fn lessThanFn(_: void, a: Fn, b: Fn) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

// ============================================================================
// Struct/enum (aggregate) surface — layout and enumerator values.
//
// A C struct's ABI is positional: a caller compiled against the old header reads
// field N at its old offset, so reordering, retyping, resizing (including an
// array dimension), or removing a field is a break. Appending a field is *also* a
// break in general (it changes sizeof, so an array of the struct re-strides) —
// EXCEPT for fig's size-versioned structs, whose first field is `uint32_t size`:
// the library writes only the fields `size` covers, so an older caller's smaller
// layout still works and an appended field is additive (MINOR). We detect that
// marker and apply the looser rule only to those.
//
// For enums, adding an enumerator is additive (callers already decode-unknown per
// fig.h's forward-compat note), but changing an existing enumerator's integer
// value silently reassigns meaning under every caller — a break.
// ============================================================================

const AggDiff = struct { verdict: Verdict, lines: [][]const u8 };

fn skipWs(s: []const u8, idx: usize) usize {
    var i = idx;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\n' or s[i] == '\r')) i += 1;
    return i;
}

fn readIdent(s: []const u8, idx: usize) []const u8 {
    var e = idx;
    while (e < s.len and isNameChar(s[e])) e += 1;
    return s[idx..e];
}

/// Extract every `typedef enum {...} Name;` / `typedef struct {...} Name;` as an
/// Aggregate. Opaque handles (`typedef struct Foo Foo;`, no `{`) carry no layout
/// and are skipped, as is anything that is not a struct/enum typedef.
fn collectAggregates(arena: std.mem.Allocator, header: []const u8) ![]Aggregate {
    const no_comments = try stripComments(arena, header);
    const text = try stripDirectives(arena, no_comments);

    var list: std.ArrayList(Aggregate) = .empty;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, "typedef")) |pos| {
        const after_kw = pos + "typedef".len;
        // Require a real keyword boundary on both sides.
        if ((pos > 0 and isNameChar(text[pos - 1])) or
            (after_kw < text.len and isNameChar(text[after_kw])))
        {
            i = after_kw;
            continue;
        }
        const kw_at = skipWs(text, after_kw);
        const kw = readIdent(text, kw_at);
        const is_struct = std.mem.eql(u8, kw, "struct");
        const is_enum = std.mem.eql(u8, kw, "enum");
        if (!is_struct and !is_enum) {
            i = after_kw;
            continue;
        }

        var k = skipWs(text, kw_at + kw.len);
        const tag = readIdent(text, k); // optional tag name
        k = skipWs(text, k + tag.len);

        if (k >= text.len or text[k] != '{') {
            // Forward/opaque typedef — no body to compare. Skip to its `;`.
            const semi = std.mem.indexOfScalarPos(u8, text, k, ';') orelse break;
            i = semi + 1;
            continue;
        }

        // Capture the brace body (handles nesting defensively, though fig's
        // aggregates don't nest).
        var depth: usize = 0;
        var b = k;
        var body_end: usize = k;
        while (b < text.len) : (b += 1) {
            if (text[b] == '{') {
                depth += 1;
            } else if (text[b] == '}') {
                depth -= 1;
                if (depth == 0) {
                    body_end = b;
                    break;
                }
            }
        }
        if (depth != 0) break; // unbalanced — give up rather than misparse
        const body = text[k + 1 .. body_end];

        const alias_at = skipWs(text, body_end + 1);
        const alias = readIdent(text, alias_at);
        const name = if (alias.len > 0) alias else tag;
        const semi = std.mem.indexOfScalarPos(u8, text, alias_at, ';') orelse text.len;
        i = @min(semi + 1, text.len);
        if (name.len == 0) continue;

        if (is_struct) {
            const fields = try parseFields(arena, body);
            const gated = fields.len > 0 and
                std.mem.eql(u8, fields[0].name, "size") and
                std.mem.startsWith(u8, fields[0].sig, "uint32_t");
            try list.append(arena, .{
                .name = name,
                .is_struct = true,
                .size_gated = gated,
                .fields = fields,
                .enumerators = &.{},
            });
        } else {
            try list.append(arena, .{
                .name = name,
                .is_struct = false,
                .size_gated = false,
                .fields = &.{},
                .enumerators = try parseEnumerators(arena, body),
            });
        }
    }
    return list.items;
}

fn parseFields(arena: std.mem.Allocator, body: []const u8) ![]Field {
    var list: std.ArrayList(Field) = .empty;
    var it = std.mem.splitScalar(u8, body, ';');
    while (it.next()) |chunk| {
        const sig = try normalizeWs(arena, chunk);
        if (sig.len == 0) continue;
        const name = fieldName(sig);
        if (name.len == 0) continue;
        try list.append(arena, .{ .sig = sig, .name = name });
    }
    return list.items;
}

/// The declared identifier in a normalized field declaration: the name run that
/// ends at the first `[` (array field) or, lacking one, the trailing identifier.
fn fieldName(sig: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, sig, '[')) |br| {
        var st = br;
        while (st > 0 and isNameChar(sig[st - 1])) st -= 1;
        return sig[st..br];
    }
    var e = sig.len;
    while (e > 0 and !isNameChar(sig[e - 1])) e -= 1;
    var st = e;
    while (st > 0 and isNameChar(sig[st - 1])) st -= 1;
    return sig[st..e];
}

fn parseEnumerators(arena: std.mem.Allocator, body: []const u8) ![]Enumerator {
    var list: std.ArrayList(Enumerator) = .empty;
    var running: ?i64 = 0; // next implicit value (C: prev + 1, first is 0)
    var it = std.mem.splitScalar(u8, body, ',');
    while (it.next()) |raw| {
        const item = try normalizeWs(arena, raw);
        if (item.len == 0) continue;
        var name: []const u8 = item;
        var value: EnumVal = undefined;
        if (std.mem.indexOfScalar(u8, item, '=')) |eq| {
            name = std.mem.trim(u8, item[0..eq], " ");
            const expr = std.mem.trim(u8, item[eq + 1 ..], " ");
            if (evalEnum(expr)) |n| {
                value = .{ .num = n };
                running = n + 1;
            } else {
                value = .{ .text = expr };
                running = null; // can't track implicit values past an opaque one
            }
        } else if (running) |r| {
            value = .{ .num = r };
            running = r + 1;
        } else {
            value = .{ .text = "<implicit>" };
        }
        if (name.len == 0) continue;
        try list.append(arena, .{ .name = name, .value = value });
    }
    return list.items;
}

/// Evaluate the simple constant expressions C enumerators use here: integer
/// literals (decimal or `0x` hex, with optional u/U/l/L suffix), an optional
/// unary sign, and a single `<<` shift. Returns null for anything else, so the
/// caller falls back to a conservative text compare.
fn evalEnum(expr: []const u8) ?i64 {
    const e = std.mem.trim(u8, expr, " ");
    if (std.mem.indexOf(u8, e, "<<")) |p| {
        const l = parseLit(e[0..p]) orelse return null;
        const r = parseLit(e[p + 2 ..]) orelse return null;
        if (r < 0 or r > 62) return null;
        return l << @as(u6, @intCast(r));
    }
    return parseLit(e);
}

fn parseLit(s: []const u8) ?i64 {
    var t = std.mem.trim(u8, s, " ");
    if (t.len == 0) return null;
    var neg = false;
    if (t[0] == '-') {
        neg = true;
        t = std.mem.trim(u8, t[1..], " ");
    } else if (t[0] == '+') {
        t = std.mem.trim(u8, t[1..], " ");
    }
    while (t.len > 0) {
        const c = t[t.len - 1];
        if (c == 'u' or c == 'U' or c == 'l' or c == 'L') t = t[0 .. t.len - 1] else break;
    }
    if (t.len == 0) return null;
    const val: i64 = if (t.len > 2 and t[0] == '0' and (t[1] == 'x' or t[1] == 'X'))
        (std.fmt.parseInt(i64, t[2..], 16) catch return null)
    else
        (std.fmt.parseInt(i64, t, 10) catch return null);
    return if (neg) -val else val;
}

fn findAgg(aggs: []const Aggregate, name: []const u8) ?Aggregate {
    for (aggs) |a| if (std.mem.eql(u8, a.name, name)) return a;
    return null;
}

fn findEnum(items: []const Enumerator, name: []const u8) ?Enumerator {
    for (items) |e| if (std.mem.eql(u8, e.name, name)) return e;
    return null;
}

fn fmtVal(arena: std.mem.Allocator, v: EnumVal) []const u8 {
    return switch (v) {
        .num => |n| std.fmt.allocPrint(arena, "{d}", .{n}) catch "?",
        .text => |t| t,
    };
}

fn diffAggregates(arena: std.mem.Allocator, base: []const Aggregate, cur: []const Aggregate) !AggDiff {
    var verdict: Verdict = .patch;
    var lines: std.ArrayList([]const u8) = .empty;

    for (cur) |c| {
        if (findAgg(base, c.name)) |b| {
            if (b.is_struct != c.is_struct) {
                verdict = worse(verdict, .major);
                try lines.append(arena, try std.fmt.allocPrint(arena, "~ {s}: changed between struct and enum (MAJOR)", .{c.name}));
            } else if (c.is_struct) {
                verdict = worse(verdict, try diffStruct(arena, &lines, b, c));
            } else {
                verdict = worse(verdict, try diffEnum(arena, &lines, b, c));
            }
        } else {
            verdict = worse(verdict, .minor);
            try lines.append(arena, try std.fmt.allocPrint(arena, "+ type {s} added (MINOR)", .{c.name}));
        }
    }
    for (base) |b| {
        if (findAgg(cur, b.name) == null) {
            verdict = worse(verdict, .major);
            try lines.append(arena, try std.fmt.allocPrint(arena, "- type {s} removed (MAJOR)", .{b.name}));
        }
    }
    return .{ .verdict = verdict, .lines = lines.items };
}

fn diffEnum(arena: std.mem.Allocator, lines: *std.ArrayList([]const u8), b: Aggregate, c: Aggregate) !Verdict {
    var v: Verdict = .patch;
    for (c.enumerators) |ce| {
        if (findEnum(b.enumerators, ce.name)) |be| {
            if (!be.value.eql(ce.value)) {
                v = worse(v, .major);
                try lines.append(arena, try std.fmt.allocPrint(arena, "~ {s}.{s}: enumerator value changed (was {s}, now {s}) (MAJOR)", .{ c.name, ce.name, fmtVal(arena, be.value), fmtVal(arena, ce.value) }));
            }
        } else {
            v = worse(v, .minor);
            try lines.append(arena, try std.fmt.allocPrint(arena, "+ {s}.{s}: enumerator added (MINOR)", .{ c.name, ce.name }));
        }
    }
    for (b.enumerators) |be| {
        if (findEnum(c.enumerators, be.name) == null) {
            v = worse(v, .major);
            try lines.append(arena, try std.fmt.allocPrint(arena, "- {s}.{s}: enumerator removed (MAJOR)", .{ c.name, be.name }));
        }
    }
    return v;
}

fn diffStruct(arena: std.mem.Allocator, lines: *std.ArrayList([]const u8), b: Aggregate, c: Aggregate) !Verdict {
    var v: Verdict = .patch;
    const n = @min(b.fields.len, c.fields.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (!std.mem.eql(u8, b.fields[i].sig, c.fields[i].sig)) {
            v = worse(v, .major);
            try lines.append(arena, try std.fmt.allocPrint(arena, "~ {s}: field {d} changed (was `{s}`, now `{s}`) (MAJOR)", .{ c.name, i, b.fields[i].sig, c.fields[i].sig }));
        }
    }

    // Appending fields is safe ONLY for a size-versioned struct (its layout is
    // size-gated). For any other struct it changes sizeof and is a break.
    const gated = b.size_gated and c.size_gated;
    if (c.fields.len < b.fields.len) {
        v = worse(v, .major);
        try lines.append(arena, try std.fmt.allocPrint(arena, "- {s}: {d} field(s) removed (MAJOR)", .{ c.name, b.fields.len - c.fields.len }));
    } else if (c.fields.len > b.fields.len) {
        var k = b.fields.len;
        while (k < c.fields.len) : (k += 1) {
            if (gated) {
                v = worse(v, .minor);
                try lines.append(arena, try std.fmt.allocPrint(arena, "+ {s}: field `{s}` appended (size-gated, MINOR)", .{ c.name, c.fields[k].sig }));
            } else {
                v = worse(v, .major);
                try lines.append(arena, try std.fmt.allocPrint(arena, "+ {s}: field `{s}` added (not size-gated — changes layout, MAJOR)", .{ c.name, c.fields[k].sig }));
            }
        }
    }
    return v;
}
