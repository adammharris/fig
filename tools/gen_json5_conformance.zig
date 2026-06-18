//! Dev tool: vendor the json5/json5-tests corpus into fig's fixture tree.
//!
//! The json5-tests suite encodes the expected outcome in the FILE EXTENSION
//! rather than a directory split (README.md of the suite):
//!     *.json   valid JSON  -> must remain valid JSON5 (ACCEPT)
//!     *.json5  JSON5 feature -> valid ES5 (ACCEPT)
//!     *.js     valid ES5 that JSON5 forbids (REJECT)
//!     *.txt    invalid ES5 (REJECT)
//! Companion `.errorSpec`/`.editorconfig`/`.md` files describe expected error
//! positions for the suite's own JS runner; fig's scoreboard is accept/reject,
//! so they are skipped.
//!
//! Cases live in category subdirs (numbers/, strings/, objects/, ...). This tool
//! walks them and copies each fixture into a flat tree, prefixing the category
//! into the name (matching the JSON/TOML harness layout):
//!     numbers/positive-infinity.json5 -> testdata/json5/numbers__positive-infinity.json5
//! The `todo/` dir (features fig does not target yet, e.g. Unicode unquoted
//! keys) and the `.git/` dir are skipped.
//!
//! Usage: zig build gen-json5-conformance -- <path-to-json5-tests> [<fig-root>]

const std = @import("std");
const Io = std.Io;

const max_file = 8 * 1024 * 1024;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next(); // binary name
    const suite = args.next() orelse {
        std.debug.print("usage: gen_json5_conformance <path-to-json5-tests> [<fig-root>]\n", .{});
        return error.MissingArgument;
    };
    const fig_root = args.next() orelse ".";

    const dest = try std.fs.path.join(arena, &.{ fig_root, "testdata", "json5" });

    const cwd = std.Io.Dir.cwd();
    var suite_dir = try cwd.openDir(io, suite, .{ .iterate = true });
    defer suite_dir.close(io);

    try cwd.createDirPath(io, dest);
    var dest_dir = try cwd.openDir(io, dest, .{ .iterate = true });
    defer dest_dir.close(io);

    // Start clean so renamed/removed upstream fixtures leave no stale copy.
    try clearFixtures(io, dest_dir);

    var counts = Counts{};

    // One level of category dirs, each holding fixtures directly.
    var it = suite_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory) {
            if (std.mem.eql(u8, entry.name, ".git")) continue;
            if (std.mem.eql(u8, entry.name, "todo")) continue;
            var cat = try suite_dir.openDir(io, entry.name, .{ .iterate = true });
            defer cat.close(io);
            try copyCategory(io, arena, cat, entry.name, dest_dir, &counts);
        } else if (entry.kind == .file) {
            try copyOne(io, arena, suite_dir, "", entry.name, dest_dir, &counts);
        }
    }

    std.debug.print(
        "json5: accept {d} (json {d}, json5 {d})  reject {d} (js {d}, txt {d})\n",
        .{ counts.json + counts.json5, counts.json, counts.json5, counts.js + counts.txt, counts.js, counts.txt },
    );
}

const Counts = struct { json: usize = 0, json5: usize = 0, js: usize = 0, txt: usize = 0 };

fn copyCategory(io: Io, arena: std.mem.Allocator, cat: Io.Dir, group: []const u8, dest_dir: Io.Dir, counts: *Counts) !void {
    var it = cat.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        try copyOne(io, arena, cat, group, entry.name, dest_dir, counts);
    }
}

fn copyOne(io: Io, arena: std.mem.Allocator, src_dir: Io.Dir, group: []const u8, name: []const u8, dest_dir: Io.Dir, counts: *Counts) !void {
    const ext = extOf(name);
    if (std.mem.eql(u8, ext, "json")) {
        counts.json += 1;
    } else if (std.mem.eql(u8, ext, "json5")) {
        counts.json5 += 1;
    } else if (std.mem.eql(u8, ext, "js")) {
        counts.js += 1;
    } else if (std.mem.eql(u8, ext, "txt")) {
        // misc/empty.txt is a genuine fixture (empty input must be rejected);
        // every other .txt is an invalid-ES5 case. Take them all.
        counts.txt += 1;
    } else {
        return; // .errorSpec / .editorconfig / .md / etc.
    }

    const flat = if (group.len == 0)
        try arena.dupe(u8, name)
    else
        try std.fmt.allocPrint(arena, "{s}__{s}", .{ group, name });

    const data = try src_dir.readFileAlloc(io, name, arena, .limited(max_file));
    try dest_dir.writeFile(io, .{ .sub_path = flat, .data = data });
}

fn extOf(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "";
    return name[dot + 1 ..];
}

fn clearFixtures(io: Io, dir: Io.Dir) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const ext = extOf(entry.name);
        const known = std.mem.eql(u8, ext, "json") or std.mem.eql(u8, ext, "json5") or
            std.mem.eql(u8, ext, "js") or std.mem.eql(u8, ext, "txt");
        if (!known) continue;
        try names.append(a, try a.dupe(u8, entry.name));
    }
    for (names.items) |name| try dir.deleteFile(io, name);
}
