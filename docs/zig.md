```fig
title = Using fig in Zig
author = adammharris
created = 2026-07-05T21:35:14-06:00
part_of = [docs](docs.md)
```

### `fig` in Zig

To add `fig` as a dependency, run `zig fetch --save https://github.com/adammharris/fig`. Then you can reference it in `build.zig`: `exe.root_module.addImport("fig", fig_dep.module("fig"))`

```zig
const std = @import("std");
const fig = @import("fig");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse JSON into a Document (the AST plus source spans).
    const doc = try fig.Language.JSON.Parser.parse(allocator, "{\"name\":\"fig\",\"nums\":[1,2]}", .JSON);
    defer doc.deinit(allocator);

    // Convert to YAML
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try doc.ast.serialize(&out.writer, .yaml);
    std.debug.print("{s}", .{out.written()}); // name: fig\nnums:\n- 1\n- 2\n
}
```