//! Dev tool: set or bump an artifact's version, keeping fig's cross-artifact
//! invariants valid automatically. The read-only mirror of this tool is
//! `tools/version-floor.zig`, which *checks* the same invariants; this one
//! *edits* the manifests so you never hand-sync them (and never trip the floor
//! checker by forgetting a coupled field). See docs/VERSIONING.md.
//!
//! Usage (driven by build.zig — `zig build version-set -- <args>`):
//!   version-set <fig-binary> <repo-root> <artifact> <version|major|minor|patch> [--dry-run]
//!
//!   fig-binary: path to a built `fig` CLI binary (injected by build.zig via
//!               addArtifactArg — not something you pass through `--`), used
//!               to sync fig.md by shelling out rather than hand-parsing it.
//!   artifact: core | cli | rust | npm   (wasi is derived — see below)
//!   version : an explicit SemVer ("2.4.0") OR a bump keyword incrementing the
//!             artifact's current value (major -> X+1.0.0, minor -> X.Y+1.0,
//!             patch -> X.Y.Z+1).
//!   --dry-run: print the edits it *would* make and touch nothing.
//!
//! What it keeps consistent, in one shot:
//!   * fig-wasi's package.json version is pinned EXACTLY to `cli_version`, so any
//!     change to `cli` carries `wasi` with it (and `version-set wasi ...` is
//!     rejected — bump the CLI instead);
//!   * the Rust `fig-macros` dependency pin tracks the `[workspace.package]`
//!     version, so a `rust` bump edits both;
//!   * the `artifact >= core` floor: bumping `core` auto-raises any of
//!     cli/rust/npm that would fall below it (and, via the wasi pin, wasi too);
//!   * fig.md's frontmatter `version` (the README's displayed version) mirrors
//!     the core version exactly, kept in sync via `fig set fig.md version ...`
//!     — dogfooding fig's own frontmatter editing instead of hand-parsing the
//!     markdown here (same self-hosting pattern as `tools/sync-figl.zig`).
//!
//! After writing manifests it refreshes the lockfiles (Cargo.lock,
//! package-lock.json) by shelling out to cargo/npm; if a toolchain is missing it
//! warns and prints the command to run by hand rather than failing the bump.
//!
//! `abi_version`/`FIG_ABI_VERSION` is intentionally NOT handled here: it's a bare
//! ABI-contract integer bumped only on a deliberate breaking-ABI decision that
//! `zig build semver-check` guards — not a marketing version.

const std = @import("std");
const fields = @import("version_fields.zig");
const Dir = std.Io.Dir;

const max_file = 1 * 1024 * 1024;

const Artifact = enum { core, cli, rust, npm, wasi };
const Bump = enum { major, minor, patch };

// Manifest paths, relative to the repo root, keyed by which field lives there.
const zon_rel = "build.zig.zon";
const build_zig_rel = "build.zig";
const cargo_rel = "bindings/rust/Cargo.toml";
const ts_pkg_rel = "bindings/typescript/package.json";
const wasi_pkg_rel = "bindings/wasi/package.json";
const fig_md_rel = "fig.md";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.next(); // argv0
    const fig_binary = args.next() orelse return usage("missing <fig-binary>");
    const repo_root = args.next() orelse return usage("missing <repo-root>");

    var positional: [2]?[]const u8 = .{ null, null };
    var n_pos: usize = 0;
    var dry_run = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return usage(std.fmt.allocPrint(arena, "unknown flag `{s}`", .{arg}) catch "unknown flag");
        } else {
            if (n_pos >= positional.len) return usage("too many arguments");
            positional[n_pos] = arg;
            n_pos += 1;
        }
    }
    const artifact_str = positional[0] orelse return usage("missing <artifact>");
    const spec = positional[1] orelse return usage("missing <version|major|minor|patch>");

    const artifact = std.meta.stringToEnum(Artifact, artifact_str) orelse
        return usage(std.fmt.allocPrint(arena, "unknown artifact `{s}` (want core|cli|rust|npm)", .{artifact_str}) catch "unknown artifact");
    if (artifact == .wasi)
        fail("fig-wasi is pinned to cli_version; bump the CLI instead: `zig build version-set -- cli {s}`", .{spec});

    // Read every manifest up front (all edits are computed against these
    // originals, so overlapping edits in one file splice cleanly).
    const cwd = Dir.cwd();
    const zon = try readRel(io, arena, cwd, repo_root, zon_rel);
    const build_zig = try readRel(io, arena, cwd, repo_root, build_zig_rel);
    const cargo = try readRel(io, arena, cwd, repo_root, cargo_rel);
    const ts_pkg = try readRel(io, arena, cwd, repo_root, ts_pkg_rel);
    const wasi_pkg = try readRel(io, arena, cwd, repo_root, wasi_pkg_rel);

    // Current values.
    const core_cur = fields.zonVersion(zon) orelse fail("no `.version` in {s}", .{zon_rel});
    const cli_cur = fields.buildZigCliVersion(build_zig) orelse fail("no `cli_version` in {s}", .{build_zig_rel});
    const rust_cur = fields.cargoWorkspaceVersion(cargo) orelse fail("no `[workspace.package] version` in {s}", .{cargo_rel});
    const macros_cur = fields.cargoFigMacrosPin(cargo) orelse fail("no `fig-macros` pin in {s}", .{cargo_rel});
    const npm_cur = fields.jsonVersion(ts_pkg) orelse fail("no `\"version\"` in {s}", .{ts_pkg_rel});
    const wasi_cur = fields.jsonVersion(wasi_pkg) orelse fail("no `\"version\"` in {s}", .{wasi_pkg_rel});

    // Resolve the primary target for the named artifact.
    const cur_for_artifact = switch (artifact) {
        .core => core_cur,
        .cli => cli_cur,
        .rust => rust_cur,
        .npm => npm_cur,
        .wasi => unreachable,
    };
    const target = resolveTarget(arena, cur_for_artifact, spec) catch |err| switch (err) {
        error.BadCurrent => fail("current {s} version `{s}` is not valid SemVer — can't bump it", .{ artifact_str, cur_for_artifact }),
        error.BadVersion => fail("`{s}` is not a valid SemVer version or bump keyword (major|minor|patch)", .{spec}),
        else => return err,
    };

    // Desired end-state (wasi is always == cli; macros pin is always == rust).
    var d_core = core_cur;
    var d_cli = cli_cur;
    var d_rust = rust_cur;
    var d_npm = npm_cur;
    switch (artifact) {
        .core => d_core = target,
        .cli => d_cli = target,
        .rust => d_rust = target,
        .npm => d_npm = target,
        .wasi => unreachable,
    }

    // A directly-named artifact must not be dropped below the core it embeds.
    if (artifact != .core and less(target, d_core))
        fail("{s} {s} would be below core {s} — an artifact must be >= the core it embeds (bump core first)", .{ artifact_str, target, d_core });

    // Floor auto-raise: a core bump pulls any lagging dependent up with it.
    raiseToFloor(&d_cli, d_core, "cli");
    raiseToFloor(&d_rust, d_core, "rust");
    raiseToFloor(&d_npm, d_core, "npm");
    const d_wasi = d_cli; // exact pin
    const d_macros = d_rust; // exact pin

    // Build the per-file edit sets against the original text.
    var touched_cargo = false;
    var touched_ts = false;
    var touched_wasi = false;
    var touched_fig_md = false;
    std.debug.print("version-set: planned changes{s}:\n", .{if (dry_run) " (dry run — nothing written)" else ""});
    var any = false;

    if (!std.mem.eql(u8, d_core, core_cur)) {
        any = true;
        touched_fig_md = true;
        const edits = [_]Edit{.{ .range = fields.zonVersionRange(zon).?, .value = d_core }};
        try writeEdits(io, arena, cwd, repo_root, zon_rel, zon, &edits, dry_run);
        report(zon_rel, "core", core_cur, d_core);
        report(fig_md_rel, "version (frontmatter, via `fig set`)", core_cur, d_core);
    }
    if (!std.mem.eql(u8, d_cli, cli_cur)) {
        any = true;
        const edits = [_]Edit{.{ .range = fields.buildZigCliVersionRange(build_zig).?, .value = d_cli }};
        try writeEdits(io, arena, cwd, repo_root, build_zig_rel, build_zig, &edits, dry_run);
        report(build_zig_rel, "cli", cli_cur, d_cli);
    }
    {
        var cargo_edits: std.ArrayList(Edit) = .empty;
        if (!std.mem.eql(u8, d_rust, rust_cur))
            try cargo_edits.append(arena, .{ .range = fields.cargoWorkspaceVersionRange(cargo).?, .value = d_rust });
        if (!std.mem.eql(u8, d_macros, macros_cur))
            try cargo_edits.append(arena, .{ .range = fields.cargoFigMacrosPinRange(cargo).?, .value = d_macros });
        if (cargo_edits.items.len > 0) {
            any = true;
            touched_cargo = true;
            try writeEdits(io, arena, cwd, repo_root, cargo_rel, cargo, cargo_edits.items, dry_run);
            if (!std.mem.eql(u8, d_rust, rust_cur)) report(cargo_rel, "rust", rust_cur, d_rust);
            if (!std.mem.eql(u8, d_macros, macros_cur)) report(cargo_rel, "fig-macros pin", macros_cur, d_macros);
        }
    }
    if (!std.mem.eql(u8, d_npm, npm_cur)) {
        any = true;
        touched_ts = true;
        const edits = [_]Edit{.{ .range = fields.jsonVersionRange(ts_pkg).?, .value = d_npm }};
        try writeEdits(io, arena, cwd, repo_root, ts_pkg_rel, ts_pkg, &edits, dry_run);
        report(ts_pkg_rel, "npm", npm_cur, d_npm);
    }
    if (!std.mem.eql(u8, d_wasi, wasi_cur)) {
        any = true;
        touched_wasi = true;
        const edits = [_]Edit{.{ .range = fields.jsonVersionRange(wasi_pkg).?, .value = d_wasi }};
        try writeEdits(io, arena, cwd, repo_root, wasi_pkg_rel, wasi_pkg, &edits, dry_run);
        report(wasi_pkg_rel, "fig-wasi", wasi_cur, d_wasi);
    }

    if (!any) {
        std.debug.print("  (nothing to do — {s} is already {s})\n", .{ artifact_str, target });
        return;
    }

    // Refresh lockfiles so they don't lag the manifests we just edited.
    if (!dry_run) {
        if (touched_cargo) refreshCargo(io, gpa, arena, repo_root);
        if (touched_ts) refreshNpm(io, gpa, arena, repo_root, "bindings/typescript");
        if (touched_wasi) refreshNpm(io, gpa, arena, repo_root, "bindings/wasi");
        if (touched_fig_md) setFigMdVersion(io, gpa, arena, fig_binary, repo_root, d_core);
    }

    // Final version table (mirrors version-floor's format).
    std.debug.print("\nversion-set: result\n", .{});
    std.debug.print("  core (build.zig.zon)         {s}\n", .{d_core});
    std.debug.print("  cli (build.zig cli_version)  {s}\n", .{d_cli});
    std.debug.print("  rust crate (Cargo.toml)      {s}  (fig-macros pin {s})\n", .{ d_rust, d_macros });
    std.debug.print("  npm package (package.json)   {s}\n", .{d_npm});
    std.debug.print("  fig-wasi (wasi/package.json) {s}\n", .{d_wasi});
    std.debug.print("  fig.md (frontmatter version) {s}\n", .{d_core});
    if (!dry_run)
        std.debug.print("\nversion-set: done — now run `zig build check` to verify.\n", .{});
}

const Edit = struct { range: fields.Range, value: []const u8 };

fn ltEdit(_: void, a: Edit, b: Edit) bool {
    return a.range.start < b.range.start;
}

/// Splice `edits` (non-overlapping ranges into `text`) and either write the
/// result to `<root>/<rel>` or, in dry-run, just compute it and discard.
fn writeEdits(
    io: std.Io,
    arena: std.mem.Allocator,
    cwd: Dir,
    root: []const u8,
    rel: []const u8,
    text: []const u8,
    edits: []const Edit,
    dry_run: bool,
) !void {
    const sorted = try arena.dupe(Edit, edits);
    std.mem.sort(Edit, sorted, {}, ltEdit);
    var out: std.ArrayList(u8) = .empty;
    var pos: usize = 0;
    for (sorted) |e| {
        try out.appendSlice(arena, text[pos..e.range.start]);
        try out.appendSlice(arena, e.value);
        pos = e.range.end;
    }
    try out.appendSlice(arena, text[pos..]);
    if (dry_run) return;

    const path = try std.fs.path.join(arena, &.{ root, rel });
    const file = try cwd.createFile(io, path, .{ .read = true });
    defer file.close(io);
    try file.writePositionalAll(io, out.items, 0);
    try file.setLength(io, out.items.len);
}

fn report(file: []const u8, what: []const u8, old: []const u8, new: []const u8) void {
    std.debug.print("  {s}: {s} {s} -> {s}\n", .{ file, what, old, new });
}

fn readRel(io: std.Io, arena: std.mem.Allocator, cwd: Dir, root: []const u8, rel: []const u8) ![]u8 {
    const path = try std.fs.path.join(arena, &.{ root, rel });
    return cwd.readFileAlloc(io, path, arena, .limited(max_file));
}

/// If `*v` is below `floor_ver`, raise it and note why (used for the core floor).
fn raiseToFloor(v: *[]const u8, floor_ver: []const u8, name: []const u8) void {
    if (less(v.*, floor_ver)) {
        std.debug.print("  (auto-raising {s} {s} -> {s} to satisfy the >= core floor)\n", .{ name, v.*, floor_ver });
        v.* = floor_ver;
    }
}

fn parseBump(s: []const u8) ?Bump {
    return std.meta.stringToEnum(Bump, s);
}

/// Turn a user `spec` (explicit SemVer or bump keyword) into a concrete version
/// string, incrementing `current` for the keyword forms.
fn resolveTarget(arena: std.mem.Allocator, current: []const u8, spec: []const u8) ![]const u8 {
    if (parseBump(spec)) |k| {
        const v = std.SemanticVersion.parse(current) catch return error.BadCurrent;
        return switch (k) {
            .major => std.fmt.allocPrint(arena, "{d}.0.0", .{v.major + 1}),
            .minor => std.fmt.allocPrint(arena, "{d}.{d}.0", .{ v.major, v.minor + 1 }),
            .patch => std.fmt.allocPrint(arena, "{d}.{d}.{d}", .{ v.major, v.minor, v.patch + 1 }),
        };
    }
    _ = std.SemanticVersion.parse(spec) catch return error.BadVersion;
    return spec;
}

/// True iff `a_str` sorts strictly before `b_str` by SemVer precedence.
fn less(a_str: []const u8, b_str: []const u8) bool {
    const a = std.SemanticVersion.parse(a_str) catch return false;
    const b = std.SemanticVersion.parse(b_str) catch return false;
    return a.order(b) == .lt;
}

fn refreshCargo(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, root: []const u8) void {
    const manifest = std.fs.path.join(arena, &.{ root, cargo_rel }) catch return;
    const argv = [_][]const u8{ "cargo", "update", "--manifest-path", manifest, "-p", "fig", "-p", "fig-macros" };
    runRefresh(io, gpa, &argv, "lockfile", "cargo update -p fig -p fig-macros (in bindings/rust)");
}

fn refreshNpm(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, root: []const u8, sub: []const u8) void {
    const prefix = std.fs.path.join(arena, &.{ root, sub }) catch return;
    const argv = [_][]const u8{ "npm", "install", "--package-lock-only", "--prefix", prefix };
    const label = std.fmt.allocPrint(arena, "npm install --package-lock-only (in {s})", .{sub}) catch "npm install --package-lock-only";
    runRefresh(io, gpa, &argv, "lockfile", label);
}

/// Sync fig.md's frontmatter `version` field to the new core version by
/// shelling out to the `fig` binary itself (`fig set fig.md version <v>`)
/// rather than hand-parsing the markdown here — the same self-hosting move
/// `tools/sync-figl.zig` makes for the generated `.figl` artifacts. Warns
/// (rather than failing the already-written manifest bump) if it can't run.
fn setFigMdVersion(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, fig_binary: []const u8, repo_root: []const u8, version: []const u8) void {
    const fig_md_path = std.fs.path.join(arena, &.{ repo_root, fig_md_rel }) catch {
        std.debug.print("version-set: WARN: could not build path to {s}; run yourself: fig set {s} version {s}\n", .{ fig_md_rel, fig_md_rel, version });
        return;
    };
    const argv = [_][]const u8{ fig_binary, "set", fig_md_path, "version", version };
    const label = std.fmt.allocPrint(arena, "fig set {s} version {s}", .{ fig_md_rel, version }) catch "fig set fig.md version";
    runRefresh(io, gpa, &argv, "fig.md", label);
}

/// Run a derived-file refresh command (lockfile regen or fig.md sync); on any
/// failure warn + print the manual command rather than aborting the
/// (already-written) bump. `what` names the kind of thing being refreshed
/// (e.g. "lockfile", "fig.md") for the log messages; `label` is the full
/// human-readable command.
fn runRefresh(io: std.Io, gpa: std.mem.Allocator, argv: []const []const u8, what: []const u8, label: []const u8) void {
    const res = std.process.run(gpa, io, .{ .argv = argv }) catch |err| {
        std.debug.print("version-set: WARN: could not refresh {s} ({s}): {s}\n  run it yourself: {s}\n", .{ what, label, @errorName(err), label });
        return;
    };
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    switch (res.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("version-set: WARN: {s} refresh `{s}` exited {d}:\n{s}\n  run it yourself once the toolchain is available.\n", .{ what, label, code, res.stderr });
            return;
        },
        else => {
            std.debug.print("version-set: WARN: {s} refresh `{s}` did not exit cleanly.\n  run it yourself once the toolchain is available.\n", .{ what, label });
            return;
        },
    }
    std.debug.print("version-set: refreshed {s} ({s})\n", .{ what, label });
}

fn usage(why: []const u8) noreturn {
    std.debug.print(
        \\version-set: {s}
        \\
        \\usage: zig build version-set -- <artifact> <version|major|minor|patch> [--dry-run]
        \\  artifact : core | cli | rust | npm   (fig-wasi tracks cli automatically)
        \\  version  : an explicit SemVer (e.g. 2.4.0) or a bump keyword
        \\
        \\examples:
        \\  zig build version-set -- rust patch
        \\  zig build version-set -- cli minor
        \\  zig build version-set -- core 4.0.0 --dry-run
        \\
    , .{why});
    std.process.exit(2);
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("version-set: FAIL: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}
