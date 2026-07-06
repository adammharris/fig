//! Dev tool: vendor fig's Zig source into the Rust crate so the published crate
//! is self-contained.
//!
//! The Rust binding compiles the fig core from source with `zig build` (see
//! bindings/rust/fig/build.rs). In a checkout that source is found by walking up
//! to the repo root, but a crate published to crates.io cannot reach outside its
//! own directory — so before packaging we copy the minimal source set into
//! bindings/rust/fig/zig, which Cargo.toml's `include` force-adds to the tarball.
//!
//! This is the cross-platform replacement for a shell `cp`: it runs through the
//! same Zig toolchain the crate already requires, so it works on Windows too.
//!
//! Run via `zig build vendor-rust`. Driven by build.zig as: vendor-rust <src-root> <dest-dir>

const std = @import("std");
const Dir = std.Io.Dir;

// The set `zig build install-c-lib` actually reads: the build scripts, the whole
// Zig source rooted at src/c_api.zig, and the public header. testdata/, tools/,
// and the other bindings are not needed to build the static library.
const files = [_][]const u8{ "build.zig", "build.zig.zon" };
const trees = [_][]const u8{ "src", "bindings/c/include" };

// Dual license, single source of truth at the repo root. crates.io takes the
// SPDX `license` field, but a published crate should also carry the license
// *text*; copy it into each crate dir (git-ignored, `include`-added for fig,
// default-packaged for fig-macros) so neither has to vendor its own copy.
const license_files = [_][]const u8{ "LICENSE-MIT", "LICENSE-APACHE" };
const crate_dirs = [_][]const u8{ "bindings/rust/fig", "bindings/rust/fig-macros" };

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next(); // argv0
    const src_root_path = args.next() orelse return error.MissingArgument;
    const dest_root_path = args.next() orelse return error.MissingArgument;

    const cwd = Dir.cwd();
    var src_root = try cwd.openDir(io, src_root_path, .{});
    defer src_root.close(io);

    // Start from a clean slate so a removed source file doesn't linger in the vendor.
    cwd.deleteTree(io, dest_root_path) catch {};
    try cwd.createDirPath(io, dest_root_path);
    var dest_root = try cwd.openDir(io, dest_root_path, .{});
    defer dest_root.close(io);

    inline for (files) |name| {
        try src_root.copyFile(name, dest_root, name, io, .{ .make_path = true });
    }
    inline for (trees) |name| {
        try copyTree(io, arena, src_root, dest_root, name);
    }

    // Fan the root license files out into each crate dir (paths relative to the
    // repo root we were handed as src_root).
    inline for (crate_dirs) |crate_dir| {
        var dir = try cwd.openDir(io, try std.fs.path.join(arena, &.{ src_root_path, crate_dir }), .{});
        defer dir.close(io);
        inline for (license_files) |name| {
            try src_root.copyFile(name, dir, name, io, .{ .make_path = true });
        }
        // The crate README crates.io renders on the package page. The canonical
        // text is the repo-root `fig.md` (the same content the npm package
        // vendors as its own README). Only the top-level `fig` crate gets one —
        // `fig-macros` is an internal helper re-exported through `fig`'s derive
        // feature, so it stays README-less. Git-ignored here; `include`-added.
        if (comptime std.mem.eql(u8, crate_dir, "bindings/rust/fig")) {
            try src_root.copyFile("fig.md", dir, "README.md", io, .{ .make_path = true });
        }
    }

    std.debug.print("vendor-rust: copied {d} files + {d} trees + {d} licenses x{d} crates + 1 readme -> {s}\n", .{ files.len, trees.len, license_files.len, crate_dirs.len, dest_root_path });
}

/// Recursively copy `sub` from `src_root` to the same relative path under `dest_root`.
fn copyTree(io: std.Io, arena: std.mem.Allocator, src_root: Dir, dest_root: Dir, sub: []const u8) !void {
    var dir = try src_root.openDir(io, sub, .{ .iterate = true });
    defer dir.close(io);
    try dest_root.createDirPath(io, sub);

    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        const dest_path = try std.fs.path.join(arena, &.{ sub, entry.path });
        switch (entry.kind) {
            // copyFile's `make_path` builds parents, so directory entries only
            // matter for preserving (rare) empty directories.
            .directory => try dest_root.createDirPath(io, dest_path),
            .file => try entry.dir.copyFile(entry.basename, dest_root, dest_path, io, .{ .make_path = true }),
            else => {},
        }
    }
}
