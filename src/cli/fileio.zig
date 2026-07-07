//! Low-level file/stdin plumbing shared by every CLI action: opening the
//! target (or `-` for stdin), reading it whole, and the create/seed/rollback
//! dance `set` uses when its target file doesn't exist yet.
const std = @import("std");
const Io = std.Io;

/// Currently, `fig` CLI only supports up to 10MB files.
pub const max_size = Io.Limit.limited(10 * 1024 * 1024);

pub fn getInput(io: Io, file_path: ?[]const u8, mode: std.Io.Dir.OpenFileOptions.Mode) !Io.File {
    const log = std.log.scoped(.getInput);
    // Get input file descriptor
    if (file_path) |fp| {
        if (std.mem.eql(u8, fp, "-")) {
            return Io.File.stdin();
        } else {
            // Get current working directory
            var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const cwd_path = try std.process.currentPath(io, &cwd_buf);
            const cwd = cwd_buf[0..cwd_path];
            log.debug("opening {s} in {s}", .{ fp, cwd });

            // Open directory (scope to files in this directory)
            const dir = try std.Io.Dir.cwd().openDir(io, cwd, .{});
            defer dir.close(io);

            // Open file, handle if it doesn't exist
            return dir.openFile(io, fp, .{ .mode = mode });
        }
    } else {
        log.err("No file provided.", .{});
        return error.MissingArgument;
    }
}

pub fn readAll(allocator: std.mem.Allocator, io: Io, file: Io.File) ![]u8 {
    var read_buffer: [4096]u8 = undefined;
    var file_reader = file.reader(io, &read_buffer);
    return file_reader.interface.allocRemaining(allocator, max_size);
}

/// Create `file_path` for read+write and seed it with `seed` — the `set`
/// action's "upsert into nothing" path (a `touch` folded into the existing
/// upsert verb). Most editors can't parse a truly empty buffer, so the file is
/// primed with a minimal valid empty document for its format (`{}` for JSON,
/// `.{}` for ZON, nothing for YAML/TOML — see `emptyDocSeed` in `edit_ops.zig`);
/// the subsequent `set` then lands the first key into a parseable document,
/// exactly as an absent embed block is seeded before its first key. Writing is
/// positional and leaves the read cursor at 0, so `applyToFile`'s `readAll`
/// reads the seed back.
pub fn createSeededFile(io: Io, file_path: []const u8, seed: []const u8) !Io.File {
    var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_path = try std.process.currentPath(io, &cwd_buf);
    const dir = try std.Io.Dir.cwd().openDir(io, cwd_buf[0..cwd_path], .{});
    defer dir.close(io);
    const file = try dir.createFile(io, file_path, .{ .read = true });
    if (seed.len > 0) try file.writePositionalAll(io, seed, 0);
    return file;
}

/// Best-effort unlink of a file `set` just created, used to roll back a
/// from-scratch create when the edit that followed it failed — so a failed
/// `set` never leaves a bare seed document (`{}`, `.{}`, …) littering the tree.
/// Silent on failure: this is cleanup on an already-failing path, and the edit
/// error is what the user needs to see.
pub fn deleteCreatedFile(io: Io, file_path: []const u8) void {
    var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_path = std.process.currentPath(io, &cwd_buf) catch return;
    const dir = std.Io.Dir.cwd().openDir(io, cwd_buf[0..cwd_path], .{}) catch return;
    defer dir.close(io);
    dir.deleteFile(io, file_path) catch {};
}
