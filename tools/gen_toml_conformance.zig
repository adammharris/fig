//! Dev tool: vendor the toml-lang/toml-test corpus into fig's fixture tree.
//!
//! Unlike the yaml-test-suite (opaque meta-files needing decode/expansion), the
//! toml-test fixtures are already plain paired files:
//!     tests/valid/<group>/<name>.toml   + <name>.json   (typed expected value)
//!     tests/invalid/<group>/<name>.toml                  (must fail to parse)
//! so this tool just reads a `files-toml-<version>` manifest and copies the
//! listed `.toml` (and, for valid cases, the sibling `.json`) into:
//!     testdata/toml/valid/<group>__<name>.toml + .json
//!     testdata/toml/invalid/<group>__<name>.toml
//! The path separators are flattened into the filename so the corpus stays a
//! flat directory, matching the JSON/YAML harness layout.
//!
//! Usage: zig build gen-toml-conformance -- <path-to-toml-test> [<version>] [<fig-root>]
//!   <version> defaults to 1.0.0 (the manifest file is tests/files-toml-<version>).

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
        std.debug.print("usage: gen_toml_conformance <path-to-toml-test> [<version>] [<fig-root>]\n", .{});
        return error.MissingArgument;
    };
    const version = args.next() orelse "1.0.0";
    const fig_root = args.next() orelse ".";

    const tests_path = try std.fs.path.join(arena, &.{ suite, "tests" });
    const manifest_name = try std.fmt.allocPrint(arena, "files-toml-{s}", .{version});
    // 1.0.0 lives at testdata/toml/; other versions get a sibling version dir
    // (1.1.0 reclassifies some 1.0 cases, so it needs its own corpus).
    const base = if (std.mem.eql(u8, version, "1.0.0"))
        try std.fs.path.join(arena, &.{ fig_root, "testdata", "toml" })
    else
        try std.fs.path.join(arena, &.{ fig_root, "testdata", try std.fmt.allocPrint(arena, "toml-{s}", .{version}) });
    const valid_path = try std.fs.path.join(arena, &.{ base, "valid" });
    const invalid_path = try std.fs.path.join(arena, &.{ base, "invalid" });

    const cwd = std.Io.Dir.cwd();
    var tests_dir = try cwd.openDir(io, tests_path, .{});
    defer tests_dir.close(io);

    try cwd.createDirPath(io, valid_path);
    try cwd.createDirPath(io, invalid_path);
    var valid_dir = try cwd.openDir(io, valid_path, .{ .iterate = true });
    defer valid_dir.close(io);
    var invalid_dir = try cwd.openDir(io, invalid_path, .{ .iterate = true });
    defer invalid_dir.close(io);

    // Start clean: this tool only writes, so a test that has moved version
    // manifests (or been renamed upstream) must not leave a stale fixture.
    try clearFixtures(io, valid_dir);
    try clearFixtures(io, invalid_dir);

    const manifest = try tests_dir.readFileAlloc(io, manifest_name, arena, .limited(max_file));

    var n_valid: usize = 0;
    var n_invalid: usize = 0;

    var lines = std.mem.tokenizeScalar(u8, manifest, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r\t");
        if (line.len == 0) continue;
        if (!std.mem.endsWith(u8, line, ".toml")) continue; // .json lines handled via their .toml

        const is_valid = std.mem.startsWith(u8, line, "valid/");
        const is_invalid = std.mem.startsWith(u8, line, "invalid/");
        if (!is_valid and !is_invalid) continue;

        const prefix_len = if (is_valid) "valid/".len else "invalid/".len;
        const rel = line[prefix_len..]; // e.g. integer/literals.toml
        const flat = try flatten(arena, rel);

        const toml_data = try tests_dir.readFileAlloc(io, line, arena, .limited(max_file));
        const dest_dir = if (is_valid) valid_dir else invalid_dir;
        try dest_dir.writeFile(io, .{ .sub_path = flat, .data = toml_data });

        if (is_valid) {
            // Copy the sibling typed-JSON expectation.
            const json_src = try replaceExt(arena, line, ".json");
            const json_flat = try replaceExt(arena, flat, ".json");
            const json_data = try tests_dir.readFileAlloc(io, json_src, arena, .limited(max_file));
            try valid_dir.writeFile(io, .{ .sub_path = json_flat, .data = json_data });
            n_valid += 1;
        } else {
            n_invalid += 1;
        }
    }

    // Carry the upstream license alongside the vendored corpus.
    if (tests_dir.readFileAlloc(io, "../LICENSE", arena, .limited(max_file))) |license| {
        var base_dir = try cwd.openDir(io, base, .{});
        defer base_dir.close(io);
        try base_dir.writeFile(io, .{ .sub_path = "LICENSE", .data = license });
    } else |_| {}

    std.debug.print("toml-{s}: valid {d}  invalid {d}\n", .{ version, n_valid, n_invalid });
}

/// `integer/literals.toml` -> `integer__literals.toml`
fn flatten(arena: std.mem.Allocator, rel: []const u8) ![]u8 {
    const out = try arena.alloc(u8, rel.len + std.mem.count(u8, rel, "/")); // each '/' -> "__"
    var w: usize = 0;
    for (rel) |c| {
        if (c == '/') {
            out[w] = '_';
            out[w + 1] = '_';
            w += 2;
        } else {
            out[w] = c;
            w += 1;
        }
    }
    return out[0..w];
}

fn replaceExt(arena: std.mem.Allocator, path: []const u8, new_ext: []const u8) ![]u8 {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse path.len;
    return std.fmt.allocPrint(arena, "{s}{s}", .{ path[0..dot], new_ext });
}

fn clearFixtures(io: Io, dir: Io.Dir) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".toml") and !std.mem.endsWith(u8, entry.name, ".json")) continue;
        try names.append(a, try a.dupe(u8, entry.name));
    }
    for (names.items) |name| try dir.deleteFile(io, name);
}
