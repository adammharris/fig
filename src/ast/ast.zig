//! AST = Abstract Syntax Tree
//!
//! This data structure represents an abstract form of a document.
//! Two documents of different formats can theoretically have the same AST.
//!
//! The AST only uses its allocator when conversion is necessary
//! to represent a file's data in a normalized, format-independent form.
//! (For example, when storing decoded escape codes.)
//!
//! This file owns the struct itself — its fields, the node model, the comment
//! layer, and equality. The rest of the surface is split across sibling files
//! for readability and re-exported below as `AST` methods (see "Sub-modules").

const AST = @This();
const std = @import("std");
const activeTag = std.meta.activeTag;
const Allocator = std.mem.Allocator;
const util = @import("../util/util.zig");

// ── Sub-modules ─────────────────────────────────────────────────────────────
// The AST's behavior is split across sibling files, each operating on a
// `*const AST`/`*AST`. Zig 0.16 has no `usingnamespace`, so every method defined
// there is surfaced here as a decl alias: `ast.foo()` resolves `foo` on this
// type, and the aliased function receives the AST as its first parameter. The
// `Node`/`Comment`/etc. types those files lean on are declared in THIS file, so
// the imports below are mutually recursive — fine, since decl access is lazy.
const reader = @import("reader.zig");
const serializer = @import("serialize_options.zig");

// Builder — programmatic, bottom-up construction (the write path). Its file is
// itself the `Builder` struct, so the import IS the type.
pub const Builder = @import("builder.zig");

// Navigation + opt-in YAML reference-layer resolution (the read path).
pub const PathSegment = reader.PathSegment;
pub const ResolveError = reader.ResolveError;
pub const child = reader.child;
pub const next = reader.next;
pub const lastChild = reader.lastChild;
pub const firstChildKey = reader.firstChildKey;
pub const getNodeByPath = reader.getNodeByPath;
pub const getKeyByPath = reader.getKeyByPath;
pub const getValByPath = reader.getValByPath;
pub const resolveAlias = reader.resolveAlias;
pub const resolveDeep = reader.resolveDeep;
pub const mergedChild = reader.mergedChild;

// Serialization — render the AST to each supported format (the output path).
pub const SerializeFormat = serializer.SerializeFormat;
pub const SerializeOptions = serializer.SerializeOptions;
pub const SerializeError = serializer.SerializeError;
pub const serialize = serializer.serialize;
pub const serializeWith = serializer.serializeWith;
pub const serializeNode = serializer.serializeNode;
pub const serializeNodeWith = serializer.serializeNodeWith;

pub fn deinit(self: *AST) void {
    for (self.owned_strings) |string| {
        self.allocator.free(string);
    }
    self.allocator.free(self.owned_strings);
    self.allocator.free(self.nodes);
    // Free only the OUTER slices of the YAML reference-layer side-tables. Their
    // inner strings (tag text, anchor names) alias `self.source` or already live
    // in `owned_strings`; freeing them here would double-free.
    self.allocator.free(self.node_tags);
    self.allocator.free(self.node_anchors);
    self.allocator.free(self.anchors);
    // Free each entry's `leading` slice (its own allocation) then the outer
    // table. Comment *text* aliases `self.source` or lives in `owned_strings`
    // (already freed above), so it is not freed here — same discipline as the
    // reference-layer tables.
    for (self.node_comments) |nc| {
        self.allocator.free(nc.leading);
        self.allocator.free(nc.dangling);
    }
    self.allocator.free(self.node_comments);
}

allocator: Allocator,
owned_strings: []const []const u8 = &.{},

/// Points to first sequence/mapping that contains all other nodes.
root: Node.Id,

/// Complete node tree, such that `ast.nodes[node.id] == node`
nodes: []const Node,

// ── YAML reference/annotation layer (side-tables) ──────────────────────────
// These hold the DECODED data the resolver/materializer/printers need. Printers
// take `*const AST` (never `Document`), so the decoded names/strings must live
// here; only the source *spans* of the `&name`/`!tag` tokens live on `Document`.
// All three are empty (`&.{}`) for documents with no anchors/aliases/tags, and
// for non-YAML formats.

/// Indexed by node id: the decoded tag string attached to that node (e.g.
/// `"!!str"`, `"!foo"`), or null. Empty when the document declares no tags.
node_tags: []const ?[]const u8 = &.{},

/// Indexed by node id: the anchor NAME defined on that node (no leading `&`),
/// or null. Empty when the document declares no anchors.
node_anchors: []const ?[]const u8 = &.{},

/// Anchor definitions in source/id order (redefinition allowed → duplicate
/// names permitted). Consulted by `resolveAlias`/`mergedChild`. Empty when the
/// document declares no anchors.
anchors: []const Anchor = &.{},

// ── Comment layer (side-table) ─────────────────────────────────────────────
// Comments are trivia: they ride alongside a value but are NOT part of it, so
// (like the reference layer above) they live in a node-id-indexed side-table
// and are excluded from `eql`. The reason to carry them in the AST at all is
// cross-format conversion — a comment captured from YAML can be re-emitted as a
// JSON5 `//`/`/* */`. The source marker is therefore NOT stored: only the
// marker-stripped content and whether it was a line or block comment (a hint
// each printer honors or downgrades). Empty (`&.{}`) for comment-free documents.

/// Indexed by node id: the comments bound to that node. Empty when the document
/// carries no comments. Read via `comments(id)`, which guards the table length.
node_comments: []const NodeComments = &.{},

pub const Anchor = struct { name: []const u8, node: Node.Id };

pub const Comment = struct {
    /// Marker-stripped content. A `block` comment may contain newlines; a `line`
    /// comment never does.
    text: []const u8,
    /// The author's original form — a hint. A printer whose target format lacks
    /// the requested form downgrades (a `block` rendered to YAML/TOML becomes a
    /// run of `#` line comments).
    style: Style = .line,

    pub const Style = enum { line, block };

    pub fn eql(self: Comment, other: Comment) bool {
        return self.style == other.style and util.eql(u8, self.text, other.text);
    }
};

/// Comments bound to one node: a run of own-line comments above it (in source
/// order), at most one same-line trailing comment, and — on a container node —
/// a run of `dangling` comments that sit at the END of its body with no child
/// after them (an orphan in an empty `[]`, or comments before the closing brace /
/// at end of document). `dangling` is empty for non-containers.
pub const NodeComments = struct {
    leading: []const Comment = &.{},
    trailing: ?Comment = null,
    dangling: []const Comment = &.{},

    pub fn isEmpty(self: NodeComments) bool {
        return self.leading.len == 0 and self.trailing == null and self.dangling.len == 0;
    }

    pub fn eql(self: NodeComments, other: NodeComments) bool {
        if (self.leading.len != other.leading.len) return false;
        for (self.leading, other.leading) |a, b| if (!a.eql(b)) return false;
        if (self.dangling.len != other.dangling.len) return false;
        for (self.dangling, other.dangling) |a, b| if (!a.eql(b)) return false;
        if ((self.trailing == null) != (other.trailing == null)) return false;
        if (self.trailing) |t| if (!t.eql(other.trailing.?)) return false;
        return true;
    }
};

/// Read the comments bound to `id`, tolerating a short or absent `node_comments`
/// table (returns the empty value for ids past its end).
pub fn comments(self: *const AST, id: Node.Id) NodeComments {
    return if (id < self.node_comments.len) self.node_comments[id] else .{};
}

/// The node a container child's *leading* comment binds to: the key of a
/// `keyvalue` entry (so the comment renders above the key), else the child node
/// itself (a sequence element). Shared by every printer that emits comments.
pub fn leadingCommentAnchor(self: *const AST, id: Node.Id) Node.Id {
    return switch (self.nodes[id].kind) {
        .keyvalue => |kv| kv.key,
        else => id,
    };
}

/// The node a container child's *trailing* comment binds to: the value of a
/// `keyvalue` entry (so the comment renders after the value), else the child
/// node itself.
pub fn trailingCommentAnchor(self: *const AST, id: Node.Id) Node.Id {
    return switch (self.nodes[id].kind) {
        .keyvalue => |kv| kv.value,
        else => id,
    };
}

/// Compare two ASTs' comment layers. Separate from `eql` (which ignores
/// comments) so round-trip tests can assert comments survived.
pub fn commentsEql(self: AST, b: AST) bool {
    const n = @max(self.node_comments.len, b.node_comments.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const x: NodeComments = if (i < self.node_comments.len) self.node_comments[i] else .{};
        const y: NodeComments = if (i < b.node_comments.len) b.node_comments[i] else .{};
        if (!x.eql(y)) return false;
    }
    return true;
}

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
        /// A leaf scalar a source format gives special lexical meaning that the
        /// abstract model has no first-class variant for: TOML datetimes, ZON
        /// enum/char literals, etc. The `kind` tag records which, and `text` is
        /// the value's intrinsic bytes (kept verbatim, like `number.raw` — the
        /// payload IS the value, so it lives inline, not in a side-table). Adding
        /// a new such scalar is a new `ExtKind`, not a new union arm: the outer
        /// switches stay closed; only the printers (where cross-format rendering
        /// is inherently type-specific) gain an `ExtKind` case.
        extended: Extended,
        sequence: ?Id,
        mapping: ?Id,
        keyvalue: struct { key: Id, value: Id },
        /// A `*name` alias: a reference to an anchored node. The payload is the
        /// alias name (no leading `*`); the target is resolved on demand via
        /// `resolveAlias` (kept out of the node so equal documents compare equal
        /// regardless of whether resolution has run). A non-YAML printer never
        /// sees this — `materialize` expands aliases to copied subtrees first.
        alias: []const u8,
        pub const Number = struct {
            raw: []const u8,
            kind: enum { integer, float },
            pub fn eql(self: Number, other: Number) bool {
                return self.kind == other.kind and util.eql(u8, self.raw, other.raw);
            }
        };
        pub const Extended = struct {
            kind: ExtKind,
            text: []const u8,
            /// Which special scalar this is. The first four are RFC-3339-derived
            /// TOML datetimes (`text` is the raw timestamp). `enum_literal`'s
            /// `text` is the decoded name without the leading `.`; `char_literal`'s
            /// `text` is the decimal Unicode codepoint (so non-ZON printers can
            /// treat it as a number, while the ZON printer re-encodes `'A'`).
            pub const ExtKind = enum {
                offset_datetime,
                local_datetime,
                local_date,
                local_time,
                enum_literal,
                char_literal,
                /// A non-finite JSON5 number (`Infinity`, `-Infinity`, `NaN`).
                /// `text` is the source lexeme verbatim, sign included. No JSON
                /// number can hold these, so they ride in an extended scalar.
                number_special,
            };
            pub fn eql(self: Extended, other: Extended) bool {
                return self.kind == other.kind and util.eql(u8, self.text, other.text);
            }
        };
        pub fn eql(self: Kind, other: Kind) bool {
            if (activeTag(self) != activeTag(other)) return false;
            return switch (self) {
                .null_ => true,
                .boolean => |value| value == other.boolean,
                .string => |value| util.eql(u8, value, other.string),
                .number => |value| value.eql(other.number),
                .extended => |value| value.eql(other.extended),
                .sequence => |value| value == other.sequence,
                .mapping => |value| value == other.mapping,
                .keyvalue => |value| value.key == other.keyvalue.key and value.value == other.keyvalue.value,
                .alias => |value| util.eql(u8, value, other.alias),
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

test {
    // Pull the split-out surface into the test binary so each sibling's `test {}`
    // blocks run (only `builder.zig` carries tests today, but keep all three
    // referenced so future tests there are picked up automatically).
    _ = Builder;
    _ = reader;
    _ = serializer;
}
