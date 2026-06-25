//! Dev tool: C ABI **diff** against the last released tag, turned into a SemVer
//! verdict. Where `abi-check.zig` proves the header and implementation agree at a
//! single point in time, this tool compares the *current* `include/fig.h` against
//! the header as it existed at the most recent `v*` git tag and classifies the
//! delta:
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
//! Baseline discovery is automatic: `git describe --tags --abbrev=0 --match 'v*'`
//! finds the most recent release reachable from HEAD, and `git show <tag>:include/
//! fig.h` reads that release's header. With no git / no tags (e.g. a source
//! tarball), the tool prints a note and exits 0 rather than breaking the build.
//!
//! Limitations (same class abidiff would still catch): struct field layout and
//! enum *values* are not compared — only the function surface and its signatures.
//! C has no name mangling, so this string-level compare of normalized prototypes
//! is what stands in for a real symbol-table diff.
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
        "describe", "--tags", "--abbrev=0", "--match", "v*",
    }) orelse {
        std.debug.print(
            "semver-check: no release tag found (no git history or no v* tags) — skipping diff.\n",
            .{},
        );
        return;
    };
    const tag_trimmed = std.mem.trim(u8, tag, " \t\r\n");

    const baseline_spec = try std.fmt.allocPrint(arena, "{s}:include/fig.h", .{tag_trimmed});
    const baseline_header = runGit(arena, io, init.gpa, repo_root, &.{ "show", baseline_spec }) orelse {
        std.debug.print(
            "semver-check: could not read include/fig.h at {s} — skipping diff.\n",
            .{tag_trimmed},
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

    const verdict: Verdict =
        if (removed.items.len > 0 or changed.items.len > 0) .major
        else if (added.items.len > 0) .minor
        else .patch;

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

    const suggested = bump(baseline_version, verdict);
    const required = switch (verdict) {
        .major, .minor => suggested, // an API delta demands at least this version
        .patch => baseline_version, // no delta: just don't regress below the release
    };

    std.debug.print("verdict: {s}  (suggested next version: {d}.{d}.{d})\n", .{
        @tagName(verdict), suggested.major, suggested.minor, suggested.patch,
    });

    if (want_version.order(required) == .lt) {
        std.debug.print(
            "build.zig.zon: {d}.{d}.{d}  ->  FAIL: bump to >= {d}.{d}.{d} before release\n",
            .{ want_version.major, want_version.minor, want_version.patch, required.major, required.minor, required.patch },
        );
        std.debug.print(
            "note: struct layout and enum values are not compared — review those by hand for a major bump.\n",
            .{},
        );
        std.process.exit(1);
    }

    std.debug.print("build.zig.zon: {d}.{d}.{d}  ->  OK (covers the ABI delta)\n", .{
        want_version.major, want_version.minor, want_version.patch,
    });
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
