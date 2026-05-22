const Parser = @This();
const Document = @import("../document.zig");
const Type = @import("yaml.zig").Language.Type;

allocator: @import("std").mem.Allocator,

pub fn parse(self: *Parser, input: []const u8, format: Type) !Document {
    _ = format;
    const nodes = try self.allocator.alloc(Document.Node, 1);
    nodes[0] = .{
        .id = 0,
        .kind = .null_,
        .span = .{ .start = 0, .end = 0 },
        .next_sibling = null,
    };
    return .{
        .root = 0,
        .source = input,
        .nodes = nodes,
    };
}
