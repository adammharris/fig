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
/// (fig authoring dialect only; empty for every other format.) One entry per
/// header line whose FINAL path segment re-OPENED an already-existing block
/// container — fig's "re-entering a path to add new keys" (DESIGN.md). A
/// container's `node_spans` entry anchors only the line that CREATED it, so
/// these extra header-line positions are what let `Editor(Fig)`'s region
/// gather remove/relocate every physical header occurrence, not just the
/// first. `content_start` is a byte offset on the re-entering header line, at
/// or after its marker prefix (the final key segment's start, or the line
/// start for an `[i]` header) — the same anchor contract `node_spans` gives
/// the editor's `lineStartBefore`-based line recovery.
reentry_headers: []const ReentryHeader = &.{},

pub const ReentryHeader = struct { node_id: AST.Node.Id, content_start: usize };

pub fn deinit(self: Document, allocator: std.mem.Allocator) void {
    var ast = self.ast;
    ast.deinit();
    allocator.free(self.node_spans);
    allocator.free(self.node_anchor_spans);
    allocator.free(self.node_tag_spans);
    allocator.free(self.reentry_headers);
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
