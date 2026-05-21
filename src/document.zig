//! The universal document representation.
//! Lower-level modules such as json/parser.zig depend on this,
//! taking in a string and returning a Document.

const Document = @This();
const std = @import("std");
const Span = @import("util/span.zig");

/// Represents a unit of data in a document.
/// Has an ID, a kind, and a span.
pub const Node = struct {
    /// Node.Ids are arbitrary, but should be deterministic.
    pub const Id = u32;
    /// Can be terminal: null, bool, string, number.
    /// Or point to other nodes: sequence, mapping, keyvalue.
    pub const Kind = union(enum) {
        // TODO?: trivia,
        null_,
        boolean,
        string,
        number,
        sequence: ?Id,
        mapping: ?Id,
        keyvalue: struct { key: Id, value: Id },
        pub fn equals(self: Kind, other: Kind) bool {
            return switch (self) {
                .keyvalue => |value, tag| {
                    return tag == std.meta.activeTag(other) and value.key == other.keyvalue.key and value.value == other.keyvalue.value;
                },
                inline else => |value, tag| {
                    return tag == std.meta.activeTag(other) and value == @field(other, @tagName(tag));
                },
            };
        }
    };

    /// Should guarantee that document.nodes[node.id] == node
    id: Id,
    kind: Kind,
    /// Refers to string slice in Document.source
    span: Span,

    /// Indicates "next" value when inside a sequence/mapping.
    /// Null indicates that this is the last node in the sequence/mapping.
    next_sibling: ?Id = null,
    pub fn equals(self: Node, other: Node) bool {
        if (self.id != other.id) return false;
        if (!self.span.equals(other.span)) return false;
        if (self.next_sibling != other.next_sibling) return false;
        if (!self.kind.equals(other.kind)) return false;
        return true;
    }
    fn dumpSiblingList(
        first_id: ?Node.Id,
        writer: *std.Io.Writer,
        source: []const u8,
        depth: usize,
        nodes: []const Node,
    ) error{WriteFailed}!void {
        var current_id: ?Node.Id = first_id;
        while (current_id) |id| {
            const node = &nodes[id];
            try node.dump(writer, source, depth, nodes);
            current_id = node.next_sibling;
            if (current_id != null) {
                try writer.print("\n", .{});
            }
        }
    }
    pub fn dump(self: *const Node, writer: *std.Io.Writer, source: []const u8, depth: usize, nodes: []const Node) error{WriteFailed}!void {
        for (0..depth) |_| {
            try writer.writeAll("    ");
        }
        switch (self.kind) {
            .null_ => try writer.writeAll("null"),
            .boolean, .number => {
                try writer.print("{s}", .{source[self.span.start..self.span.end]});
            },
            .string => {
                // a hack to normalize string quotes
                if (self.span.len() >= 2 and source[self.span.start] == '\"' and source[self.span.end - 1] == '\"') {
                    try writer.print("{s}", .{source[self.span.start + 1 .. self.span.end - 1]});
                } else {
                    try writer.print("{s}", .{source[self.span.start..self.span.end]});
                }
            },
            .sequence => |child| {
                if (child) |c| {
                    const child_depth = if (depth == 0) 0 else depth + 1;
                    if (depth > 0) try writer.print("\n", .{});
                    try dumpSiblingList(c, writer, source, child_depth, nodes);
                } else try writer.print("(empty sequence)", .{});
            },
            .mapping => |child| {
                if (child) |c| {
                    const child_depth = if (depth == 0) 0 else depth + 1;
                    if (depth > 0) try writer.print("\n", .{});
                    try dumpSiblingList(c, writer, source, child_depth, nodes);
                } else try writer.print("(empty mapping)", .{});
            },
            .keyvalue => |kv| {
                try nodes[kv.key].dump(writer, source, 0, nodes);
                switch (nodes[kv.value].kind) {
                    .mapping => |child| {
                        if (child) |c| {
                            try writer.print(":\n", .{});
                            try dumpSiblingList(c, writer, source, depth + 1, nodes);
                        } else {
                            try writer.print(": (empty mapping)\n", .{});
                        }
                    },
                    .sequence => |child| {
                        if (child) |c| {
                            try writer.print(":\n", .{});
                            try dumpSiblingList(c, writer, source, depth + 1, nodes);
                        } else {
                            try writer.print(": (empty sequence)\n", .{});
                        }
                    },
                    else => {
                        try writer.print(": ", .{});
                        try nodes[kv.value].dump(writer, source, 0, nodes);
                    },
                }
            },
        }
    }
};

/// Usually equal to 0 (so that self.nodes[0] == root node)
/// Points to first sequence/mapping that contains all other nodes.
root: Node.Id,
/// Complete node tree. Accessed by node id: self.nodes[node_id] = node
nodes: []const Node,
/// Plaintext document, to ground nodes in original truth
source: []const u8,

/// Function to tell if two documents are equal.
pub fn equals(self: Document, b: Document) bool {
    if (self.root != b.root) return false;
    //if (!std.mem.eql(u8, self.source, b.source)) return false;
    if (self.nodes.len != b.nodes.len) return false;

    for (self.nodes, b.nodes) |na, nb| {
        if (!na.equals(nb)) return false;
    }
    return true;
}

pub fn deinit(self: Document, allocator: std.mem.Allocator) void {
    allocator.free(self.nodes);
}

// Document Path Helpers

/// Represents part of a path in the Document structure.
/// Nodes can only be nested in either mappings or sequences.
pub const PathSegment = union(enum) {
    key: []const u8,
    index: usize,
};

// Used like:
// &[_]Document.PathSegment{
//   .{ .index = 0 },
//   .{ .key = "hello" }
// }

/// Get a node by path.
/// Can return a keyvalue node that should be deconstructed.
pub fn getNode(self: *const Document, path: []const PathSegment) !Node {
    return self.nodes[try self.getId(path)];
}

/// Same as getNode, but if a keyvalue is found, always returns key
pub fn getNodeKey(self: *const Document, path: []const PathSegment) !Node {
    const node = self.nodes[try self.getId(path)];
    if (std.meta.activeTag(node.kind) == .keyvalue) {
        return self.nodes[node.kind.keyvalue.key];
    }
    return node;
}

/// Same as getNode, but if a keyvalue is found, always returns value
pub fn getNodeVal(self: *const Document, path: []const PathSegment) !Node {
    const node = self.nodes[try self.getId(path)];
    if (std.meta.activeTag(node.kind) == .keyvalue) {
        return self.nodes[node.kind.keyvalue.value];
    }
    return node;
}

/// Takes a PathSegment array and runs getChildNodeId for each one.
fn getId(self: *const Document, path: []const PathSegment) !Node.Id {
    var current_node = self.root;
    for (path) |segment| {
        current_node = try self.getChildNodeId(current_node, segment);
    }
    return current_node;
}

/// Traverses down node tree according to segment
/// Can return keyvalue node that must be deconstructed.
fn getChildNodeId(self: *const Document, parent_id: Node.Id, segment: PathSegment) !Node.Id {
    var current_node = parent_id;
    switch (segment) {
        .key => {
            // node is a mapping. Find the first child keyvalue
            current_node = self.nodes[current_node].kind.mapping orelse return error.NotFound;
            // Loop through keyvalue siblings to find matching key
            while (true) {
                const span = self.nodes[self.nodes[current_node].kind.keyvalue.key].span;
                const node_key = self.source[span.start..span.end];
                if (std.mem.eql(u8, segment.key, node_key)) break;
                current_node = self.nodes[current_node].next_sibling orelse return error.NotFound;
            }
            // We found the right keyvalue node! Return the keyvalue wrapper node.
            return current_node;
        },
        .index => {
            // node is a sequence. Find first value.
            current_node = self.nodes[current_node].kind.sequence orelse return error.NotFound;
            for (0..segment.index) |_| {
                current_node = self.nodes[current_node].next_sibling orelse return error.NotFound;
            }
            return current_node;
        },
    }
}

pub fn dump(self: *const Document, writer: *std.Io.Writer) !void {
    try self.nodes[self.root].dump(writer, self.source, 0, self.nodes);
    try writer.flush();
}
