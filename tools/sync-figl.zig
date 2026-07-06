//! Dev tool: keep the repo's hand-authored `.figl` files and the generated
//! artifacts they describe (GitHub Actions workflows, `build.zig.zon`) in
//! sync, by shelling out to the `fig` binary itself (`fig get -o <format>
//! <src>`) rather than re-implementing any parsing/printing here. Dogfoods the
//! same conversion path a user of `fig convert`/`fig get` would exercise.
//!
//! The `.figl` files are the source of truth: comments, structure, and intent
//! live there, and the generated files are a build artifact of them — the
//! inverse of how these repos are usually organized (hand-edited `.yml` +
//! `.zon`, `.figl` nowhere in sight). A leading comment in each `.figl` source
//! rides fig's cross-format comment preservation into the generated file, so
//! it (not this tool) is what tells a reader not to hand-edit the output.
//!
//! Two modes:
//!   sync_figl <fig-binary> <repo-root>            write mode (default): regenerate
//!                                                  every destination that differs.
//!   sync_figl <fig-binary> <repo-root> --check     check mode: fail (nonzero) if any
//!                                                  destination is stale or missing,
//!                                                  without writing anything. This is
//!                                                  what CI / the pre-commit hook run.
//!
//! Run via `zig build sync-figl` / `zig build check-figl`.

const std = @import("std");
const Dir = std.Io.Dir;

const Mapping = struct {
    src: []const u8,
    dest: []const u8,
    format: []const u8,
};

// The full set of generated artifacts this repo derives from a `.figl`
// source. Add a line here when a new generated file gets a `.figl` source.
const mappings = [_]Mapping{
    .{ .src = "figl/build.zig.figl", .dest = "build.zig.zon", .format = "zon" },
    .{ .src = "figl/ci.figl", .dest = ".github/workflows/ci.yml", .format = "yaml" },
    .{ .src = "figl/homebrew.figl", .dest = ".github/workflows/homebrew.yml", .format = "yaml" },
    .{ .src = "figl/release.figl", .dest = ".github/workflows/release.yml", .format = "yaml" },
};

const max_file = 4 * 1024 * 1024;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.next(); // argv0
    const fig_binary = args.next() orelse return error.MissingArgument;
    const repo_root = args.next() orelse return error.MissingArgument;
    var check_only = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--check")) check_only = true;
    }

    const cwd = Dir.cwd();
    var failed = false;

    for (mappings) |m| {
        const src_path = try std.fs.path.join(arena, &.{ repo_root, m.src });
        const dest_path = try std.fs.path.join(arena, &.{ repo_root, m.dest });

        const argv = [_][]const u8{ fig_binary, "get", "-o", m.format, src_path };
        const res = std.process.run(gpa, io, .{ .argv = &argv }) catch |err| {
            std.debug.print("sync-figl: failed to run `fig get -o {s} {s}`: {s}\n", .{ m.format, m.src, @errorName(err) });
            failed = true;
            continue;
        };
        defer gpa.free(res.stdout);
        defer gpa.free(res.stderr);
        switch (res.term) {
            .exited => |code| if (code != 0) {
                std.debug.print("sync-figl: `fig get -o {s} {s}` exited {d}:\n{s}\n", .{ m.format, m.src, code, res.stderr });
                failed = true;
                continue;
            },
            else => {
                std.debug.print("sync-figl: `fig get -o {s} {s}` did not exit cleanly:\n{s}\n", .{ m.format, m.src, res.stderr });
                failed = true;
                continue;
            },
        }
        const generated = res.stdout;

        const existing = cwd.readFileAlloc(io, dest_path, arena, .limited(max_file)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };

        const up_to_date = if (existing) |e| std.mem.eql(u8, e, generated) else false;

        if (check_only) {
            if (up_to_date) {
                std.debug.print("sync-figl: ok      {s}\n", .{m.dest});
            } else if (existing == null) {
                std.debug.print("sync-figl: MISSING {s} (run `zig build sync-figl`)\n", .{m.dest});
                failed = true;
            } else {
                std.debug.print("sync-figl: STALE   {s} (run `zig build sync-figl`)\n", .{m.dest});
                failed = true;
            }
            continue;
        }

        if (up_to_date) {
            std.debug.print("sync-figl: up to date  {s}\n", .{m.dest});
            continue;
        }

        const file = try cwd.createFile(io, dest_path, .{ .read = true });
        defer file.close(io);
        try file.writePositionalAll(io, generated, 0);
        try file.setLength(io, generated.len);
        std.debug.print("sync-figl: updated     {s}\n", .{m.dest});
    }

    if (failed) std.process.exit(1);
}
