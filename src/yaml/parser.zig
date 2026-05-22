const Parser = @This();
const Document = @import("../document.zig");

pub fn parse() !Document {
    return .{
        .root = 0,
        .source = "placeholder",
        .nodes = [_]Document.Node{
            .{
                .id = 0,
                .kind = .null_,
                .span = .{ .start = 0, .end = 0 },
                .next_sibling = null,
            }
        }
    };
}