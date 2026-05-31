const std = @import("std");
const testing = std.testing;

const Parser = @import("parser.zig");
const JsonType = @import("json.zig").Type;

const max_fixture_size = 1024 * 1024;

test "json conformance: edgecase JSONTestSuite files" {
    try runConformanceDir(
        "testdata/json/edgecase",
        'i',
        .implementation_defined,
    );
}

test "json conformance: valid JSONTestSuite files" {
    try runConformanceDir(
        "testdata/json/accept",
        'y',
        .should_pass,
    );
}

test "json conformance: invalid JSONTestSuite files" {
    try runConformanceDir(
        "testdata/json/reject",
        'n',
        .should_fail,
    );
}

const Expected = enum {
    should_pass,
    should_fail,
    implementation_defined,
};

const rejected_edgecase_fixtures = [_][]const u8{
    // This parser does NOT accept UTF-16 directly.
    // Users are expected to transcode to UTF-8 first.
    "i_string_UTF-16LE_with_BOM.json",
    "i_string_utf16BE_no_BOM.json",
    "i_string_utf16LE_no_BOM.json",
};

fn shouldRejectEdgecase(name: []const u8) bool {
    for (rejected_edgecase_fixtures) |fixture| {
        if (std.mem.eql(u8, name, fixture)) return true;
    }
    return false;
}

fn runConformanceDir(dir_path: []const u8, prefix: u8, expected: Expected) !void {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (entry.name.len == 0 or entry.name[0] != prefix) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

        const input = try dir.readFileAlloc(
            io,
            entry.name,
            testing.allocator,
            .limited(max_fixture_size),
        );
        defer testing.allocator.free(input);

        switch (expected) {
            .should_pass => {
                var doc = Parser.parse(testing.allocator, input, JsonType.JSON) catch |err| {
                    std.debug.print("Expected valid JSON fixture to parse: {s}, err={any}\n", .{
                        entry.name,
                        err,
                    });
                    return err;
                };
                defer doc.deinit(testing.allocator);
            },
            .should_fail => {
                if (Parser.parse(testing.allocator, input, JsonType.JSON)) |doc| {
                    defer doc.deinit(testing.allocator);
                    std.debug.print("Expected invalid JSON fixture to fail: {s}\n", .{
                        entry.name,
                    });
                    return error.ExpectedParseFailure;
                } else |_| {}
            },
            .implementation_defined => {
                const should_reject = shouldRejectEdgecase(entry.name);
                if (Parser.parse(testing.allocator, input, JsonType.JSON)) |doc| {
                    defer doc.deinit(testing.allocator);
                    if (should_reject) {
                        std.debug.print("Expected edgecase JSON fixture to fail: {s}\n", .{
                            entry.name,
                        });
                        return error.ExpectedParseFailure;
                    }
                } else |err| {
                    if (!should_reject) {
                        std.debug.print("Expected edgecase JSON fixture to parse: {s}, err={any}\n", .{
                            entry.name,
                            err,
                        });
                        return err;
                    }
                }
            },
        }
    }
}
