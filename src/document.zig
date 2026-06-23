const Document = @This();
const std = @import("std");

const AST = @import("ast/ast.zig");
const Span = @import("util/span.zig");

/// A parsed document plus source-location metadata.
///
/// `source` is borrowed. `document.nodes` and `node_spans` are owned by this
/// value and freed by `deinit`.
source: []const u8,
ast: AST,
/// Indexed by node id: `node_spans[node.id]` is that node's source span.
node_spans: []const Span,
/// Indexed by node id: source span of the `&name` token attached to this node,
/// or null. Source-coupled, so it lives here (the editor uses it to splice);
/// the decoded name lives on `ast.node_anchors`. Empty when no anchors.
node_anchor_spans: []const ?Span = &.{},
/// Indexed by node id: source span of the `!tag` token attached to this node,
/// or null. Decoded tag text lives on `ast.node_tags`. Empty when no tags.
node_tag_spans: []const ?Span = &.{},

pub fn deinit(self: Document, allocator: std.mem.Allocator) void {
    var ast = self.ast;
    ast.deinit();
    allocator.free(self.node_spans);
    allocator.free(self.node_anchor_spans);
    allocator.free(self.node_tag_spans);
}

pub fn span(self: Document, node: AST.Node) Span {
    return self.node_spans[node.id];
}

/// Source span of the `&name` anchor token on `node`, or null. Returns null
/// when the document declares no anchors (the table is empty).
pub fn anchorSpan(self: Document, node: AST.Node) ?Span {
    if (node.id >= self.node_anchor_spans.len) return null;
    return self.node_anchor_spans[node.id];
}

/// Source span of the `!tag` token on `node`, or null. Returns null when the
/// document declares no tags (the table is empty).
pub fn tagSpan(self: Document, node: AST.Node) ?Span {
    if (node.id >= self.node_tag_spans.len) return null;
    return self.node_tag_spans[node.id];
}
