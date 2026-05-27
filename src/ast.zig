//! AST = Abstract Syntax Tree
//!
//! This data structure represents an abstract form of a document.
//! Two documents of different formats can theoretically have the same AST.
//!
//! The AST only uses its allocator when conversion is necessary
//! to represent a file's data in a normalized, format-independent form.
//! (For example, when storing decoded escape codes.)

const AST = @This();
const activeTag = @import("std").meta.activeTag;
const Allocator = @import("std").mem.Allocator;
const util = @import("util/util.zig");

pub fn deinit(self: *AST) void {
    for (self.owned_strings) |string| {
        self.allocator.free(string);
    }
    self.allocator.free(self.owned_strings);
    self.allocator.free(self.nodes);
}

allocator: Allocator,
owned_strings: []const []const u8 = &.{},

/// Points to first sequence/mapping that contains all other nodes.
root: Node.Id,

/// Complete node tree, such that `ast.nodes[node.id] == node`
nodes: []const Node,

/// Represents a unit of data in an AST.
pub const Node = struct {
    /// Unique number identifier for this node.
    id: Id,
    kind: Kind,
    /// Indicates "next" value when inside a sequence/mapping.
    next_sibling: ?Id = null,

    pub const Id = u32;
    pub const Kind = union(enum) {
        null_,
        boolean: bool,
        string: []const u8,
        number: Number,
        sequence: ?Id,
        mapping: ?Id,
        keyvalue: struct { key: Id, value: Id },
        pub const Number = struct {
            raw: []const u8,
            kind: enum { integer, float },
            pub fn eql(self: Number, other: Number) bool {
                return self.kind == other.kind and util.eql(u8, self.raw, other.raw);
            }
        };
        pub fn eql(self: Kind, other: Kind) bool {
            if (activeTag(self) != activeTag(other)) return false;
            return switch (self) {
                .null_ => true,
                .boolean => |value| value == other.boolean,
                .string => |value| util.eql(u8, value, other.string),
                .number => |value| value.eql(other.number),
                .sequence => |value| value == other.sequence,
                .mapping => |value| value == other.mapping,
                .keyvalue => |value| value.key == other.keyvalue.key and value.value == other.keyvalue.value,
            };
        }
    };

    pub fn eql(self: Node, other: Node) bool {
        if (self.id != other.id) return false;
        if (self.next_sibling != other.next_sibling) return false;
        if (!self.kind.eql(other.kind)) return false;
        return true;
    }
};

/// Function to tell if two documents are equal abstractly (does not compare source text).
pub fn eql(self: AST, b: AST) bool {
    return self.root == b.root and util.eql(Node, self.nodes, b.nodes);
}

// ==================
// NAVIGATION HELPERS
// ==================

/// Returns a node's child. Returns an error if the given node is not a container.
pub fn child(self: *const AST, node: *const Node) !?Node {
    const child_id = switch (node.kind) {
        .mapping, .sequence => |first_child| first_child,
        else => return error.NotAContainer,
    };
    return if (child_id) |id| self.nodes[id] else null;
}

/// Iterate on a node to find the next sibling.
pub fn next(self: *const AST, node: *const Node) ?Node {
    return if (self.nodes[node.id].next_sibling) |id| self.nodes[id] else null;
}

/// Represents part of a path in the Document structure. Used like:
/// ```zig
/// &[_]Document.PathSegment{
///     .{ .index = 0 },
///     .{ .key = "hello" }
/// }
/// ```
pub const PathSegment = union(enum) {
    key: []const u8,
    index: usize,
};

/// Get a node at a specific path. If a keyvalue is found, get the key.
pub fn getKeyByPath(self: *const AST, path: []const PathSegment) !Node {
    const node = self.nodes[try self.getIdByPath(path)];
    if (activeTag(node.kind) == .keyvalue)
        return self.nodes[node.kind.keyvalue.key]
    else
        return node;
}

/// Get a node at a specific path. If a keyvalue is found, get the value.
pub fn getValByPath(self: *const AST, path: []const PathSegment) !Node {
    const node = self.nodes[try self.getIdByPath(path)];
    if (activeTag(node.kind) == .keyvalue)
        return self.nodes[node.kind.keyvalue.value]
    else
        return node;
}

/// Takes a PathSegment array and runs getChildNodeId for each one.
fn getIdByPath(self: *const AST, path: []const PathSegment) !Node.Id {
    var current_node = self.root;
    for (path) |segment| {
        current_node = try self.getChildNodeId(current_node, segment);
    }
    return current_node;
}

/// Traverses down node tree according to segment.
/// Can return keyvalue node that must be deconstructed.
fn getChildNodeId(self: *const AST, parent_id: Node.Id, segment: PathSegment) !Node.Id {
    var current_node = parent_id;
    switch (segment) {
        .key => {
            current_node = switch (self.nodes[current_node].kind) {
                .mapping => |first_child| first_child orelse return error.NotFound,
                else => return error.NotAMapping,
            };
            // node is a mapping. Find the first child keyvalue.
            // Loop through keyvalue siblings to find matching key.
            while (true) {
                // Only string keys are allowed.
                const keyvalue = switch (self.nodes[current_node].kind) {
                    .keyvalue => |keyval| keyval,
                    else => return error.InvalidDocument,
                };
                const node_key = switch (self.nodes[keyvalue.key].kind) {
                    .string => |key| key,
                    else => return error.InvalidDocument,
                };
                if (util.eql(u8, segment.key, node_key)) break;
                current_node = self.nodes[current_node].next_sibling orelse return error.NotFound;
            }
            // We found the right keyvalue node! Return the keyvalue wrapper node.
            return current_node;
        },
        .index => {
            current_node = switch (self.nodes[current_node].kind) {
                .sequence => |first_child| first_child orelse return error.NotFound,
                else => return error.NotASequence,
            };
            // node is a sequence. Find first value.
            for (0..segment.index) |_| {
                current_node = self.nodes[current_node].next_sibling orelse return error.NotFound;
            }
            return current_node;
        },
    }
}
