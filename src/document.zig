const Document = @This();
const std = @import("std");

const AST = @import("ast.zig");
const Span = @import("util/span.zig");

/// A parsed document plus source-location metadata.
///
/// `source` is borrowed. `document.nodes` and `node_spans` are owned by this
/// value and freed by `deinit`.
source: []const u8,
ast: AST,
/// Indexed by node id: `node_spans[node.id]` is that node's source span.
node_spans: []const Span,

pub fn deinit(self: Document, allocator: std.mem.Allocator) void {
    var ast = self.ast;
    ast.deinit();
    allocator.free(self.node_spans);
}

pub fn span(self: Document, node: AST.Node) Span {
    return self.node_spans[node.id];
}
