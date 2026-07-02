//! fig authoring dialect printer — renders an AST in the `fig fmt` house
//! style (DESIGN.md "What `fig fmt` normalizes"):
//!
//!   * Spaced marker runs (`> > key`) and NO leading indentation — the markers
//!     themselves form the visual ruler (each level shifts the line two
//!     columns, the same geometry indentation would add, without a redundant
//!     second signal to maintain). An `--indent` mode that adds derived
//!     indentation on top is a possible future opt-in.
//!   * Fits-or-breaks: a container value renders as inline flow iff every
//!     descendant is flow-representable, no comment would be dropped or
//!     re-anchored, no object directly contains another object, and the whole
//!     line fits `options.width`. All-or-nothing per node — no partial
//!     hoisting of the widest member — so output is stable under small edits.
//!   * Dotted-key collapse: chains of single-child maps collapse to `a.b.c`.
//!   * Sections at the document root: scalar/inline children print as dotted
//!     assignments; a map prints under a dotted section header while its block
//!     body stays within depth 2 and hoists each child to its own section when
//!     it would nest deeper; a sequence of maps prints as a `path[]` append
//!     header with `+` continuation blocks for the rest of its elements.
//!   * Comments are conservative blockers: any spelling a re-parse would not
//!     re-anchor identically falls back to the nested form that does.
//!
//! Every emitted document parses back to the same AST (modulo comments, which
//! DO round-trip).

const Printer = @This();
const std = @import("std");
const AST = @import("../ast/ast.zig");
const tok = @import("tokenizer.zig");
const Writer = std.Io.Writer;

pub const Error = Writer.Error || error{ UnresolvedAlias, NonStringKey };

/// Deepest `>` count a section header's block body may reach before the map is
/// hoisted into per-child sections instead.
const max_body_depth = 2;
/// Recursion guard for the section path buffer (collapse/hoist recursion is
/// bounded by tree depth; 128 dotted segments is far past any real config).
const path_cap = 128;

writer: *Writer,
ast: *const AST,
options: AST.SerializeOptions,
/// Dotted path (key node ids) of the section currently being emitted.
path: [path_cap]AST.Node.Id = undefined,
path_len: usize = 0,
/// Section separation state: a blank line goes between two sections when
/// either side is multi-line (or carries leading comments).
started: bool = false,
prev_multiline: bool = false,

pub fn print(writer: *Writer, ast: *const AST, options: AST.SerializeOptions) Error!void {
    var p: Printer = .{ .writer = writer, .ast = ast, .options = options };
    try p.leadingComments(ast.leadingCommentAnchor(ast.root), 0);
    try p.root(ast.root);
    try writer.flush();
}

pub fn printNode(writer: *Writer, ast: *const AST, id: AST.Node.Id, depth: usize, options: AST.SerializeOptions) Error!void {
    var p: Printer = .{ .writer = writer, .ast = ast, .options = options };
    switch (ast.nodes[id].kind) {
        .mapping => if (depth == 0) {
            try p.emitSections(id);
            for (p.danglingOf(id)) |c| try p.commentLines(c, 0);
        } else try p.mapBody(id, depth),
        .sequence => try p.seqBody(id, depth),
        else => {
            try p.value(id, false);
            try p.writer.writeByte('\n');
        },
    }
}

/// The root is a map or a sequence (never a bare scalar in the fig dialect —
/// see DESIGN.md). A root map is emitted as sections; a root sequence as
/// zero-marker `-` elements.
fn root(self: *Printer, id: AST.Node.Id) Error!void {
    switch (self.ast.nodes[id].kind) {
        .mapping => {
            try self.emitSections(id);
            for (self.danglingOf(id)) |c| try self.commentLines(c, 0);
        },
        .sequence => try self.seqBody(id, 0), // prints its own dangling run
        else => {
            // Not authorable in fig, but total: fall back to a single bare
            // value line so nothing silently vanishes.
            try self.value(id, false);
            try self.writer.writeByte('\n');
        },
    }
}

// ── Section emission (document root) ────────────────────────────────────────

fn emitSections(self: *Printer, map_id: AST.Node.Id) Error!void {
    var cur = self.ast.nodes[map_id].kind.mapping;
    while (cur) |kv_id| : (cur = self.ast.nodes[kv_id].next_sibling) {
        try self.emitSection(kv_id);
    }
}

/// Emit one map entry at section level: the current dotted `path` plus this
/// entry's key names the target, and the value's shape picks the spelling.
fn emitSection(self: *Printer, kv_id: AST.Node.Id) Error!void {
    const kv = self.ast.nodes[kv_id].kind.keyvalue;
    self.path[self.path_len] = kv.key;
    self.path_len += 1;
    defer self.path_len -= 1;
    const can_extend = self.path_len < path_cap;

    // Dotted collapse: step through single-child maps (`a.b.c …`).
    if (can_extend) if (self.collapseChild(kv_id)) |child| return self.emitSection(child);

    const v = kv.value;
    switch (self.ast.nodes[v].kind) {
        .mapping => |first_opt| {
            if (self.fitsInline(v, self.pathWidth() + 3, .allow_trailing))
                return self.sectionAssign(kv.key, v);
            // Hoist: a body that would pass the depth budget reads better as
            // sections. Only when every comment re-anchors: the map itself
            // gets no dedicated line, so it must carry none of its own.
            //
            // Consecutive FLAT children (scalar / inline-fitting) group under
            // ONE header re-entry — naming the path once instead of repeating
            // it per line — while each deep child gets its own section.
            // Headers are re-enterable, so interleaved flat runs stay legal
            // and key order is preserved exactly. A lone flat child stays a
            // dotted assignment (one line beats a two-line header group).
            if (can_extend and first_opt != null and
                self.blockDepthMap(v, 1) > max_body_depth and
                !self.keyHasLeading(kv.key) and !self.hasTrailingOrDangling(v))
            {
                var cur = first_opt;
                while (cur != null) {
                    // Measure the run of consecutive flat children at `cur`.
                    var run_len: usize = 0;
                    var scan = cur;
                    while (scan) |child| : (scan = self.ast.nodes[child].next_sibling) {
                        if (!self.isFlatChild(child)) break;
                        run_len += 1;
                    }
                    if (run_len == 1) {
                        try self.emitSection(cur.?);
                        cur = self.ast.nodes[cur.?].next_sibling;
                    } else if (run_len >= 2) {
                        try self.beginSection(true, null);
                        try self.writePath();
                        try self.writer.writeByte('\n');
                        for (0..run_len) |_| {
                            try self.mapEntryLine(cur.?, 1);
                            cur = self.ast.nodes[cur.?].next_sibling;
                        }
                    }
                    // `cur` now sits on a deep child (or the end).
                    if (cur) |deep| {
                        try self.emitSection(deep);
                        cur = self.ast.nodes[deep].next_sibling;
                    }
                }
                return;
            }
            // Dotted section header + block body.
            try self.beginSection(true, kv.key);
            try self.writePath();
            try self.trailingComment(v);
            try self.writer.writeByte('\n');
            try self.mapBody(v, 1);
        },
        .sequence => |first_opt| {
            if (self.fitsInline(v, self.pathWidth() + 3, .allow_trailing))
                return self.sectionAssign(kv.key, v);
            // A list of maps is the append header's home turf: `path[]` for
            // the first element, `+` for the rest, fields one `>` deep.
            if (first_opt != null and self.allElementsMappings(v) and
                !self.keyHasLeading(kv.key) and !self.hasTrailingOrDangling(v))
                return self.emitAppendGroup(v);
            // Otherwise a header + `>-` element lines (scalars/inline stay
            // one line each; anything else nests).
            try self.beginSection(true, kv.key);
            try self.writePath();
            try self.trailingComment(v);
            try self.writer.writeByte('\n');
            try self.seqBody(v, 1);
        },
        else => return self.sectionAssign(kv.key, v),
    }
}

/// A single-line section: `path = value` (scalar or inline flow).
fn sectionAssign(self: *Printer, anchor_key: AST.Node.Id, v: AST.Node.Id) Error!void {
    try self.beginSection(false, anchor_key);
    try self.writePath();
    switch (self.ast.nodes[v].kind) {
        .mapping, .sequence => {
            try self.writer.writeAll(" = ");
            try self.flowValue(v);
        },
        else => {
            _ = try self.writeTypeAnnotation(v);
            try self.writer.writeAll(" = ");
            try self.value(v, false);
        },
    }
    try self.trailingComment(v);
    try self.writer.writeByte('\n');
}

/// `path[]` for the first element, `+` for each further one. Emitted as ONE
/// section (blank lines around the group, none inside it).
fn emitAppendGroup(self: *Printer, seq_id: AST.Node.Id) Error!void {
    var cur = self.ast.nodes[seq_id].kind.sequence;
    var i: usize = 0;
    while (cur) |el| : ({
        cur = self.ast.nodes[el].next_sibling;
        i += 1;
    }) {
        if (i == 0) try self.beginSection(true, null);
        try self.leadingComments(el, 0);
        if (i == 0) {
            try self.writePath();
            try self.writer.writeAll("[]");
        } else {
            try self.writer.writeByte('+');
        }
        try self.trailingComment(el);
        try self.writer.writeByte('\n');
        try self.mapBody(el, 1);
    }
}

/// Blank-line separation, then the section's leading comments (anchored to
/// `anchor` — the key a re-parse of the section's first line binds them to).
fn beginSection(self: *Printer, multiline: bool, anchor: ?AST.Node.Id) Error!void {
    const has_lead = if (anchor) |a| self.commentsOn() and self.ast.comments(a).leading.len > 0 else false;
    const ml = multiline or has_lead;
    if (self.started and (ml or self.prev_multiline)) try self.writer.writeByte('\n');
    self.started = true;
    self.prev_multiline = ml;
    if (anchor) |a| try self.leadingComments(a, 0);
}

fn writePath(self: *Printer) Error!void {
    for (self.path[0..self.path_len], 0..) |key_id, i| {
        if (i > 0) try self.writer.writeByte('.');
        try self.writeKey(key_id);
    }
}

fn pathWidth(self: *const Printer) usize {
    var w: usize = if (self.path_len > 0) self.path_len - 1 else 0; // dots
    for (self.path[0..self.path_len]) |key_id| w += self.keyWidth(key_id);
    return w;
}

/// Would this entry render as a single body line under a header at depth 1
/// (scalar, or a container fitting inline)? Deep children — anything needing
/// its own nested body — get hoisted to their own sections instead.
fn isFlatChild(self: *const Printer, kv_id: AST.Node.Id) bool {
    const chain = self.resolveChain(kv_id);
    const end = self.ast.nodes[chain.end_kv].kind.keyvalue;
    return switch (self.ast.nodes[end.value].kind) {
        .mapping, .sequence => self.fitsInline(end.value, 2 + chain.key_width + 3, .allow_trailing),
        else => true,
    };
}

fn allElementsMappings(self: *const Printer, seq_id: AST.Node.Id) bool {
    var cur = self.ast.nodes[seq_id].kind.sequence;
    while (cur) |el| : (cur = self.ast.nodes[el].next_sibling) {
        if (self.ast.nodes[el].kind != .mapping) return false;
    }
    return true;
}

// ── Block bodies ─────────────────────────────────────────────────────────────

fn body(self: *Printer, id: AST.Node.Id, depth: usize) Error!void {
    switch (self.ast.nodes[id].kind) {
        .mapping => try self.mapBody(id, depth),
        .sequence => try self.seqBody(id, depth),
        else => unreachable,
    }
}

/// Emit every entry of map `id` as block lines at `depth` (then the map's own
/// dangling comment run).
fn mapBody(self: *Printer, map_id: AST.Node.Id, depth: usize) Error!void {
    var cur = self.ast.nodes[map_id].kind.mapping;
    while (cur) |kv_id| : (cur = self.ast.nodes[kv_id].next_sibling) {
        try self.mapEntryLine(kv_id, depth);
    }
    for (self.danglingOf(map_id)) |c| try self.commentLines(c, depth);
}

/// One map entry as block line(s) at `depth`: leading comments, marker run,
/// (collapsed) dotted key, then value — inline, nested body, or scalar.
fn mapEntryLine(self: *Printer, kv_id: AST.Node.Id, depth: usize) Error!void {
    const chain = self.resolveChain(kv_id);
    const end = self.ast.nodes[chain.end_kv].kind.keyvalue;
    try self.leadingComments(end.key, depth);
    try self.writeMarkers(depth);
    try self.writeChainKeys(kv_id, chain.end_kv);
    const v = end.value;
    switch (self.ast.nodes[v].kind) {
        .mapping, .sequence => {
            if (self.fitsInline(v, 2 * depth + chain.key_width + 3, .allow_trailing)) {
                try self.writer.writeAll(" = ");
                try self.flowValue(v);
                try self.trailingComment(v);
                try self.writer.writeByte('\n');
            } else {
                // Nested container header (`> key`, children one deeper).
                try self.trailingComment(v);
                try self.writer.writeByte('\n');
                try self.body(v, depth + 1);
            }
        },
        else => {
            _ = try self.writeTypeAnnotation(v);
            try self.writer.writeAll(" = ");
            try self.value(v, false);
            try self.trailingComment(v);
            try self.writer.writeByte('\n');
        },
    }
}

/// Emit every element of sequence `id` as `>-` lines at `depth` (bare `-` at
/// the root), then the sequence's own dangling comment run.
fn seqBody(self: *Printer, seq_id: AST.Node.Id, depth: usize) Error!void {
    var cur = self.ast.nodes[seq_id].kind.sequence;
    while (cur) |el| : (cur = self.ast.nodes[el].next_sibling) {
        try self.leadingComments(el, depth);
        try self.writeElementMarkers(depth);
        switch (self.ast.nodes[el].kind) {
            .mapping, .sequence => {
                // Element leading comments are already printed, so they don't
                // block the inline form.
                if (self.fitsInline(el, elementPrefixWidth(depth), .allow_leading_trailing)) {
                    try self.writer.writeByte(' ');
                    try self.flowValue(el);
                    try self.trailingComment(el);
                    try self.writer.writeByte('\n');
                } else {
                    try self.trailingComment(el);
                    try self.writer.writeByte('\n');
                    try self.body(el, depth + 1);
                }
            },
            else => {
                const annotated = try self.writeTypeAnnotation(el);
                try self.writer.writeAll(if (annotated) " = " else " ");
                try self.value(el, false);
                try self.trailingComment(el);
                try self.writer.writeByte('\n');
            },
        }
    }
    for (self.danglingOf(seq_id)) |c| try self.commentLines(c, depth);
}

// ── Layout decisions ─────────────────────────────────────────────────────────

const CommentPolicy = enum {
    /// Any comment disqualifies (interior flow position — comments would drop).
    strict,
    /// The node's own trailing comment prints after the line (value position).
    allow_trailing,
    /// Leading comments print before the line too (element position).
    allow_leading_trailing,
};

fn budget(self: *const Printer) usize {
    return self.options.width;
}

fn fitsInline(self: *const Printer, id: AST.Node.Id, prefix_width: usize, policy: CommentPolicy) bool {
    const w = self.inlineWidth(id, policy) orelse return false;
    return prefix_width + w <= self.budget();
}

/// Width of `id` rendered as inline flow, or null when it is not
/// flow-eligible: a comment would be dropped or re-anchored (dangling always;
/// leading/trailing per `policy`), the node has no flow spelling (enum
/// literal, non-finite float, char literal, alias), or an object directly
/// contains another object (that much structure reads better as block lines).
fn inlineWidth(self: *const Printer, id: AST.Node.Id, policy: CommentPolicy) ?usize {
    if (self.commentsOn()) {
        const c = self.ast.comments(id);
        if (c.dangling.len > 0) return null;
        switch (policy) {
            .strict => if (c.leading.len > 0 or c.trailing != null) return null,
            .allow_trailing => if (c.leading.len > 0) return null,
            .allow_leading_trailing => {},
        }
    }
    switch (self.ast.nodes[id].kind) {
        .null_ => return 4,
        .boolean => |b| return @as(usize, if (b) 4 else 5),
        .number => |n| return n.raw.len,
        // A multi-line string deserves a real `'''`/`"""` block, which only
        // exists in block position — so it forces its container out of flow.
        .string => |s| return if (std.mem.indexOfScalar(u8, s, '\n') != null) null else scalarStringWidth(s, false, true),
        .extended => |e| return switch (e.kind) {
            .offset_datetime, .local_datetime, .local_date, .local_time => e.text.len,
            // enum/non-finite need `: type =`; char has no flow spelling.
            else => null,
        },
        .alias, .keyvalue => return null,
        .sequence => |first_opt| {
            var w: usize = 2; // "[" + "]"
            var cur = first_opt;
            var i: usize = 0;
            while (cur) |el| : ({
                cur = self.ast.nodes[el].next_sibling;
                i += 1;
            }) {
                const ew = self.inlineWidth(el, .strict) orelse return null;
                w += ew + (if (i > 0) @as(usize, 2) else 0); // ", "
            }
            return w;
        },
        .mapping => |first_opt| {
            if (first_opt == null) return 2; // "{}"
            var w: usize = 4; // "{ " + " }"
            var cur = first_opt;
            var i: usize = 0;
            while (cur) |kv_id| : ({
                cur = self.ast.nodes[kv_id].next_sibling;
                i += 1;
            }) {
                const kv = self.ast.nodes[kv_id].kind.keyvalue;
                if (self.commentsOn() and self.ast.comments(kv.key).leading.len > 0) return null;
                if (self.ast.nodes[kv.value].kind == .mapping) return null; // object-in-object
                const vw = self.inlineWidth(kv.value, .strict) orelse return null;
                w += self.keyWidth(kv.key) + 3 + vw + (if (i > 0) @as(usize, 2) else 0);
            }
            return w;
        },
    }
}

/// Deepest `>` count `mapBody(map_id, depth)` would emit — used to decide
/// header-vs-hoist at section level. Mirrors mapBody's decisions exactly.
fn blockDepthMap(self: *const Printer, map_id: AST.Node.Id, depth: usize) usize {
    var maxd = depth;
    var cur = self.ast.nodes[map_id].kind.mapping;
    while (cur) |kv_id| : (cur = self.ast.nodes[kv_id].next_sibling) {
        const chain = self.resolveChain(kv_id);
        const end = self.ast.nodes[chain.end_kv].kind.keyvalue;
        switch (self.ast.nodes[end.value].kind) {
            .mapping => {
                if (self.fitsInline(end.value, 2 * depth + chain.key_width + 3, .allow_trailing)) continue;
                maxd = @max(maxd, self.blockDepthMap(end.value, depth + 1));
            },
            .sequence => {
                if (self.fitsInline(end.value, 2 * depth + chain.key_width + 3, .allow_trailing)) continue;
                maxd = @max(maxd, self.blockDepthSeq(end.value, depth + 1));
            },
            else => {},
        }
    }
    return maxd;
}

fn blockDepthSeq(self: *const Printer, seq_id: AST.Node.Id, depth: usize) usize {
    var maxd = depth;
    var cur = self.ast.nodes[seq_id].kind.sequence;
    while (cur) |el| : (cur = self.ast.nodes[el].next_sibling) {
        switch (self.ast.nodes[el].kind) {
            .mapping => {
                if (self.fitsInline(el, elementPrefixWidth(depth), .allow_leading_trailing)) continue;
                maxd = @max(maxd, self.blockDepthMap(el, depth + 1));
            },
            .sequence => {
                if (self.fitsInline(el, elementPrefixWidth(depth), .allow_leading_trailing)) continue;
                maxd = @max(maxd, self.blockDepthSeq(el, depth + 1));
            },
            else => {},
        }
    }
    return maxd;
}

/// Columns before an element's value: `- ` at root, `> >- ` etc. below.
fn elementPrefixWidth(depth: usize) usize {
    return if (depth == 0) 2 else 2 * depth + 1;
}

const Chain = struct { end_kv: AST.Node.Id, key_width: usize };

/// Walk the dotted-key collapse chain starting at `kv_id`: follow single-child
/// maps as far as comment anchors allow, accumulating the dotted key width.
fn resolveChain(self: *const Printer, kv_id: AST.Node.Id) Chain {
    var cur = kv_id;
    var w = self.keyWidth(self.ast.nodes[cur].kind.keyvalue.key);
    while (self.collapseChild(cur)) |child| {
        cur = child;
        w += 1 + self.keyWidth(self.ast.nodes[cur].kind.keyvalue.key);
    }
    return .{ .end_kv = cur, .key_width = w };
}

/// If `kv_id`'s value is a single-entry map that a dotted-key collapse may
/// step through, return that inner keyvalue. Blocked by any comment whose
/// anchor a re-parse of the collapsed spelling would move: the outer key's
/// leading run (it would re-anchor onto the chain's final key) and the
/// intermediate map's own comments (its line disappears entirely).
fn collapseChild(self: *const Printer, kv_id: AST.Node.Id) ?AST.Node.Id {
    const kv = self.ast.nodes[kv_id].kind.keyvalue;
    switch (self.ast.nodes[kv.value].kind) {
        .mapping => |first_opt| {
            const first = first_opt orelse return null;
            if (self.ast.nodes[first].next_sibling != null) return null;
            if (self.commentsOn()) {
                if (self.ast.comments(kv.key).leading.len > 0) return null;
                const vc = self.ast.comments(kv.value);
                if (vc.leading.len > 0 or vc.trailing != null or vc.dangling.len > 0) return null;
            }
            return first;
        },
        else => return null,
    }
}

/// Write the dotted keys of a collapse chain: `kv_id`'s key through
/// `end_kv`'s, joined by `.`.
fn writeChainKeys(self: *Printer, kv_id: AST.Node.Id, end_kv: AST.Node.Id) Error!void {
    var cur = kv_id;
    try self.writeKey(self.ast.nodes[cur].kind.keyvalue.key);
    while (cur != end_kv) {
        cur = self.collapseChild(cur).?;
        try self.writer.writeByte('.');
        try self.writeKey(self.ast.nodes[cur].kind.keyvalue.key);
    }
}

// ── Comment queries ──────────────────────────────────────────────────────────

fn commentsOn(self: *const Printer) bool {
    return !self.options.strip_comments;
}

fn danglingOf(self: *const Printer, id: AST.Node.Id) []const AST.Comment {
    if (!self.commentsOn()) return &.{};
    return self.ast.comments(id).dangling;
}

fn keyHasLeading(self: *const Printer, key_id: AST.Node.Id) bool {
    return self.commentsOn() and self.ast.comments(key_id).leading.len > 0;
}

fn hasTrailingOrDangling(self: *const Printer, id: AST.Node.Id) bool {
    if (!self.commentsOn()) return false;
    const c = self.ast.comments(id);
    return c.trailing != null or c.dangling.len > 0;
}

// ── Line primitives ──────────────────────────────────────────────────────────

/// The spaced marker run for a key/comment line: `"> "` per level, so the last
/// space doubles as the marker↔key separator (`> > key`).
fn writeMarkers(self: *Printer, depth: usize) Error!void {
    for (0..depth) |_| try self.writer.writeAll("> ");
}

/// The marker run for an element line: the `-` glues to the final marker
/// (`> >-`); a root element is a bare `-`.
fn writeElementMarkers(self: *Printer, depth: usize) Error!void {
    if (depth == 0) {
        try self.writer.writeByte('-');
        return;
    }
    for (0..depth - 1) |_| try self.writer.writeAll("> ");
    try self.writer.writeAll(">-");
}

fn writeKey(self: *Printer, key_id: AST.Node.Id) Error!void {
    const name = switch (self.ast.nodes[key_id].kind) {
        .string => |s| s,
        else => return error.NonStringKey,
    };
    try self.writeBareOrQuoted(name, true, false);
}

fn keyWidth(self: *const Printer, key_id: AST.Node.Id) usize {
    return switch (self.ast.nodes[key_id].kind) {
        .string => |s| scalarStringWidth(s, true, false),
        else => 0, // fails with NonStringKey at write time regardless
    };
}

/// `enum_literal`/`number_special` scalars only round-trip through the fig
/// dialect via an explicit `: type`, since there is no bare spelling for them
/// (DESIGN.md "Enum: explicit-only"). Returns whether an annotation was
/// written (an annotated element needs ` = ` where a plain one has a space).
fn writeTypeAnnotation(self: *Printer, id: AST.Node.Id) Error!bool {
    switch (self.ast.nodes[id].kind) {
        .extended => |e| switch (e.kind) {
            .enum_literal => {
                try self.writer.writeAll(": enum");
                return true;
            },
            .number_special => {
                try self.writer.writeAll(": float");
                return true;
            },
            else => return false,
        },
        else => return false,
    }
}

/// A scalar (or, in flow position, any) value. `in_flow` tightens the
/// bare-string rules to what survives inside `[…]`/`{…}`.
fn value(self: *Printer, id: AST.Node.Id, in_flow: bool) Error!void {
    switch (self.ast.nodes[id].kind) {
        .null_ => try self.writer.writeAll("null"),
        .boolean => |b| try self.writer.writeAll(if (b) "true" else "false"),
        .number => |n| try self.writer.writeAll(n.raw),
        .string => |s| if (!in_flow and std.mem.indexOfScalar(u8, s, '\n') != null) {
            try self.writeMultilineString(s);
        } else {
            try self.writeBareOrQuoted(s, false, in_flow);
        },
        .extended => |e| try self.writeExtended(e, in_flow),
        .mapping, .sequence => try self.flowValue(id),
        .keyvalue => unreachable,
        .alias => return error.UnresolvedAlias,
    }
}

/// A container in flow spelling: `[a, b]` / `{ x = 1 }` (fig-inline pairs).
fn flowValue(self: *Printer, id: AST.Node.Id) Error!void {
    switch (self.ast.nodes[id].kind) {
        .sequence => |first_opt| {
            try self.writer.writeByte('[');
            var cur = first_opt;
            var i: usize = 0;
            while (cur) |el| : ({
                cur = self.ast.nodes[el].next_sibling;
                i += 1;
            }) {
                if (i > 0) try self.writer.writeAll(", ");
                try self.value(el, true);
            }
            try self.writer.writeByte(']');
        },
        .mapping => |first_opt| {
            if (first_opt == null) {
                try self.writer.writeAll("{}");
                return;
            }
            try self.writer.writeAll("{ ");
            var cur = first_opt;
            var i: usize = 0;
            while (cur) |kv_id| : ({
                cur = self.ast.nodes[kv_id].next_sibling;
                i += 1;
            }) {
                if (i > 0) try self.writer.writeAll(", ");
                const kv = self.ast.nodes[kv_id].kind.keyvalue;
                try self.writeKey(kv.key);
                try self.writer.writeAll(" = ");
                try self.value(kv.value, true);
            }
            try self.writer.writeAll(" }");
        },
        else => unreachable,
    }
}

fn writeExtended(self: *Printer, e: AST.Node.Kind.Extended, in_flow: bool) Error!void {
    switch (e.kind) {
        .offset_datetime, .local_datetime, .local_date, .local_time => try self.writer.writeAll(e.text),
        .enum_literal, .number_special => try self.writer.writeAll(e.text),
        // A char literal has no fig spelling; it degrades to its decoded text.
        .char_literal => {
            const cp = std.fmt.parseInt(u21, e.text, 10) catch {
                try self.writeBareOrQuoted(e.text, false, in_flow);
                return;
            };
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cp, &buf) catch {
                try self.writeBareOrQuoted(e.text, false, in_flow);
                return;
            };
            try self.writeBareOrQuoted(buf[0..len], false, in_flow);
        },
    }
}

/// A string containing newlines, in block value position: `'''` raw when the
/// content round-trips verbatim, else `"""` with `\`, `"`, and `\r` escaped
/// (escaping every `"` also rules out an accidental `"""` terminator).
/// Content and closer are emitted flush-left: a raw block is verbatim by
/// definition (indent would become content), and a column-0 closer pins the
/// escaped flavor's smart-dedent at zero so leading whitespace in the value
/// survives. The tokenizer drops the newline before the closer's line, so a
/// value's own trailing newline (or lack of one) round-trips exactly.
fn writeMultilineString(self: *Printer, s: []const u8) Error!void {
    const raw_ok = std.mem.indexOf(u8, s, "'''") == null and
        std.mem.indexOfScalar(u8, s, '\r') == null;
    if (raw_ok) {
        try self.writer.writeAll("'''\n");
        try self.writer.writeAll(s);
        try self.writer.writeAll("\n'''");
        return;
    }
    try self.writer.writeAll("\"\"\"\n");
    for (s) |c| switch (c) {
        '\\' => try self.writer.writeAll("\\\\"),
        '"' => try self.writer.writeAll("\\\""),
        '\r' => try self.writer.writeAll("\\r"),
        else => try self.writer.writeByte(c),
    };
    try self.writer.writeAll("\n\"\"\"");
}

/// Bare when the literal-else-string sniff would round-trip it unchanged
/// (and, for a key, when it contains no structural character); a minimal
/// double-quoted form otherwise. Correctness-first: this always double-quotes
/// rather than picking single vs. double by escape content (a house-style
/// nicety left for later).
fn writeBareOrQuoted(self: *Printer, s: []const u8, is_key: bool, in_flow: bool) Error!void {
    if (isBareSafe(s, is_key, in_flow)) {
        try self.writer.writeAll(s);
        return;
    }
    try self.writer.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try self.writer.writeAll("\\\""),
        '\\' => try self.writer.writeAll("\\\\"),
        '\n' => try self.writer.writeAll("\\n"),
        '\r' => try self.writer.writeAll("\\r"),
        '\t' => try self.writer.writeAll("\\t"),
        else => try self.writer.writeByte(c),
    };
    try self.writer.writeByte('"');
}

fn quotedWidth(s: []const u8) usize {
    var w: usize = 2;
    for (s) |c| w += @as(usize, switch (c) {
        '"', '\\', '\n', '\r', '\t' => 2,
        else => 1,
    });
    return w;
}

fn scalarStringWidth(s: []const u8, is_key: bool, in_flow: bool) usize {
    return if (isBareSafe(s, is_key, in_flow)) s.len else quotedWidth(s);
}

fn isBareSafe(s: []const u8, is_key: bool, in_flow: bool) bool {
    if (s.len == 0) return false;
    if (s[0] == ' ' or s[s.len - 1] == ' ') return false;
    for (s) |c| {
        if (c == '\n' or c == '\r' or c == '\t') return false;
        if (is_key and !tok.isBareKeyChar(c)) return false;
    }
    if (is_key and (s[0] == '-' or s[0] == '>')) return false;
    if (!is_key) {
        // A bare non-key value must round-trip through the literal-else-string
        // sniff as a plain string, and must not open a committed form.
        switch (s[0]) {
            '\'', '"' => return false, // opens a committed string form
            '[', '{' => {
                // In flow position a leading bracket always opens a nested
                // collection — there is no bare-trailing rescue there.
                if (in_flow) return false;
                // A leading bracket is bare-safe only when it re-parses as a
                // bare string — a balanced close with trailing content
                // (markdown link, glob, regex). A terminal close would commit
                // to flow and a non-closing bracket would error (DESIGN.md
                // "Committed values").
                if (tok.classifyBracketCommit(s, 0) != .bare_trailing) return false;
            },
            else => {},
        }
        if (in_flow) for (s) |c| switch (c) {
            // A bare flow value runs to the next `,`/`]`/`}` — any of these
            // inside the string would truncate it.
            ',', ']', '}' => return false,
            else => {},
        };
        // A `#` at the start or after whitespace would re-parse as a comment and
        // truncate the bare value — quote to preserve it (the `#`-after-
        // whitespace rule, mirrored).
        var prev_ws = true;
        for (s) |c| {
            if (c == '#' and prev_ws) return false;
            prev_ws = (c == ' ' or c == '\t');
        }
        switch (tok.sniffBare(s)) {
            .string => {},
            else => return false,
        }
    }
    return true;
}

fn leadingComments(self: *Printer, id: AST.Node.Id, depth: usize) Error!void {
    if (!self.commentsOn()) return;
    for (self.ast.comments(id).leading) |c| try self.commentLines(c, depth);
}

fn trailingComment(self: *Printer, id: AST.Node.Id) Error!void {
    if (!self.commentsOn()) return;
    const c = self.ast.comments(id).trailing orelse return;
    try self.writer.writeAll(" #");
    if (c.text.len != 0) {
        try self.writer.writeByte(' ');
        for (c.text) |ch| try self.writer.writeByte(if (ch == '\n') ' ' else ch);
    }
}

fn commentLines(self: *Printer, c: AST.Comment, depth: usize) Error!void {
    var it = std.mem.splitScalar(u8, c.text, '\n');
    while (it.next()) |line| {
        try self.writeMarkers(depth);
        try self.writer.writeByte('#');
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len != 0) {
            try self.writer.writeByte(' ');
            try self.writer.writeAll(trimmed);
        }
        try self.writer.writeByte('\n');
    }
}

// =========
// TESTS
// =========

const Parser = @import("parser.zig");

fn expectPrint(input: []const u8, expected: []const u8) !void {
    var ast = try Parser.parseAbstract(std.testing.allocator, input, .Fig);
    defer ast.deinit();
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try print(&out.writer, &ast, .{});
    try std.testing.expectEqualStrings(expected, out.written());
}

fn expectRoundTrip(input: []const u8) !void {
    var ast1 = try Parser.parseAbstract(std.testing.allocator, input, .Fig);
    defer ast1.deinit();
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try print(&out.writer, &ast1, .{});
    var ast2 = try Parser.parseAbstract(std.testing.allocator, out.written(), .Fig);
    defer ast2.deinit();
    try std.testing.expect(ast1.eql(ast2));
    // Idempotence: a second fmt pass must be byte-identical.
    var out2: Writer.Allocating = .init(std.testing.allocator);
    defer out2.deinit();
    try print(&out2.writer, &ast2, .{});
    try std.testing.expectEqualStrings(out.written(), out2.written());
}

test "prints a flat map" {
    try expectPrint("x = 1\ny = hello\n",
        \\x = 1
        \\y = hello
        \\
    );
}

test "small nested maps inline; single-child chains collapse to dotted keys" {
    try expectPrint(
        \\database
        \\> host = localhost
        \\> pool
        \\>> size = 10
    ,
        \\database
        \\> host = localhost
        \\> pool.size = 10
        \\
    );
}

test "a leaf map of scalars fits inline at section level" {
    try expectPrint(
        \\point
        \\> x = 1
        \\> y = 2
    ,
        \\point = { x = 1, y = 2 }
        \\
    );
}

test "spaced markers, no indentation" {
    // Long values defeat the inline budget, forcing genuine nesting.
    try expectPrint(
        \\server
        \\> description = this line is deliberately padded far past the eighty column budget so it cannot inline
        \\> limits
        \\>> connections = this line is also deliberately padded far past the eighty column budget so it stays put
        \\>> burst = and one more long sibling so the limits container cannot be collapsed to one dotted key line
    ,
        \\server
        \\> description = this line is deliberately padded far past the eighty column budget so it cannot inline
        \\> limits
        \\> > connections = this line is also deliberately padded far past the eighty column budget so it stays put
        \\> > burst = and one more long sibling so the limits container cannot be collapsed to one dotted key line
        \\
    );
}

test "a deep map hoists into dotted sections (and nested lists of maps into [] headers)" {
    try expectPrint(
        \\workspace
        \\> resolver = "2"
        \\> metadata
        \\>> release
        \\>>> shared-version-key = a deliberately long value to keep the release table from fitting inline here
        \\>>> tag-message-etc = another deliberately long value to keep the release table from fitting inline
        \\>> replacements
        \\>>> -
        \\>>>> file = README.md
        \\>>>> search = a deliberately long pattern string so this element cannot fit in the inline flow budget
    ,
        \\workspace.resolver = "2"
        \\
        \\workspace.metadata.release
        \\> shared-version-key = a deliberately long value to keep the release table from fitting inline here
        \\> tag-message-etc = another deliberately long value to keep the release table from fitting inline
        \\
        \\workspace.metadata.replacements[]
        \\> file = README.md
        \\> search = a deliberately long pattern string so this element cannot fit in the inline flow budget
        \\
    );
}

test "a sequence of maps prints as a [] append header with + continuations" {
    try expectPrint(
        \\replacements[]
        \\> file = README.md
        \\> search = a deliberately long pattern string so this element cannot fit in the inline flow budget
        \\replacements[]
        \\> file = CHANGELOG.md
        \\> search = another deliberately long pattern string so the sequence cannot fit inline either way
    ,
        \\replacements[]
        \\> file = README.md
        \\> search = a deliberately long pattern string so this element cannot fit in the inline flow budget
        \\+
        \\> file = CHANGELOG.md
        \\> search = another deliberately long pattern string so the sequence cannot fit inline either way
        \\
    );
}

test "scalar lists inline when they fit, header + >- lines when they don't" {
    try expectPrint(
        \\ports
        \\> - 1
        \\> - 2
        \\members
        \\>- crates/some_long_crate_name_one
        \\>- crates/some_long_crate_name_two
        \\>- crates/some_long_crate_name_three
        \\>- crates/some_long_crate_name_four
    ,
        \\ports = [1, 2]
        \\
        \\members
        \\>- crates/some_long_crate_name_one
        \\>- crates/some_long_crate_name_two
        \\>- crates/some_long_crate_name_three
        \\>- crates/some_long_crate_name_four
        \\
    );
}

test "empty containers round-trip via = {} / = []" {
    try expectPrint("a = {}\nb = []\n", "a = {}\nb = []\n");
}

test "flow strings that would not survive bare are quoted" {
    // A comma inside a flow element would split it; a leading bracket would
    // nest; a sniffable number-string would change type.
    try expectPrint(
        \\xs = ["a, b", "[glob]", "99", plain]
    ,
        \\xs = ["a, b", "[glob]", "99", plain]
        \\
    );
}

test "comments keep their anchors through fmt" {
    try expectPrint(
        \\# on the section
        \\deps
        \\> # on serde's key
        \\> serde = 1 # trailing
        \\> other = this value is long enough to keep the whole deps table from ever fitting the inline budget
    ,
        \\# on the section
        \\deps
        \\> # on serde's key
        \\> serde = 1 # trailing
        \\> other = this value is long enough to keep the whole deps table from ever fitting the inline budget
        \\
    );
}

test "round-trips through a second parse (and fmt is idempotent)" {
    try expectRoundTrip(
        \\database
        \\> host = localhost
        \\> port = 5432
        \\servers
        \\> -
        \\>> host = a.com
        \\>> port = 1
    );
    try expectRoundTrip(
        \\workspace
        \\> resolver = "2"
        \\> members
        \\>>- crates/one_rather_long_member_path_aaaaaaaaaaaa
        \\>>- crates/two_rather_long_member_path_bbbbbbbbbbbb
        \\> package
        \\>> version = 1.6.1
        \\>> license-file = LICENSE.md
        \\> dependencies
        \\>> serde = { version = "1.0", features = [derive] }
        \\>> fig
        \\>>> version = 1.0.0
        \\>>> features-list = [serde, yaml, derive, indexmap, and, extra, entries, to, defeat, inlining, of, fig]
        \\> metadata
        \\>> replacements
        \\>>> -
        \\>>>> file = README.md
        \\>>>> search = a deliberately long pattern string so this element cannot fit in the inline flow budget
        \\>>> -
        \\>>>> file = CHANGELOG.md
        \\>>>> search = another deliberately long pattern string keeping the sequence out of the inline budget
        \\profile
        \\> release = { lto = fat, codegen-units = 1 }
    );
    try expectRoundTrip(
        \\values
        \\> answer = 42
        \\> flag = "true"
        \\> zip = 007
        \\> movie = 12 monkeys
        \\> when = 2026-07-01T12:00:00Z
        \\> class: enum = minecraft
        \\> huge: float = inf
        \\> long-tail = a sufficiently long value that the values table cannot be rendered through inline flow
    );
}

test "hoisting groups flat-sibling runs under one header re-entry" {
    // A map over the depth budget with a run of scalars AND a deep child:
    // the scalars share one `workspace.metadata.release` header instead of
    // each repeating the full dotted path; the deep child gets its own
    // `[]` section after.
    try expectPrint(
        \\workspace
        \\> metadata
        \\>> release
        \\>>> shared-version = true
        \\>>> consolidate-commits = true
        \\>>> push = false
        \\>>> publish = false
        \\>>> tag = false
        \\>>> tag-name = v{{version}}
        \\>>> tag-message = Release v{{version}}
        \\>>> pre-release-commit-message = chore: release v{{version}}
        \\>>> pre-release-replacements
        \\>>>> -
        \\>>>>> file = README.md
        \\>>>>> search = a deliberately long pattern string so this element cannot fit in the inline flow budget
        \\>>>> -
        \\>>>>> file = CHANGELOG.md
        \\>>>>> search = another deliberately long pattern string keeping the sequence out of the inline budget
    ,
        \\workspace.metadata.release
        \\> shared-version = true
        \\> consolidate-commits = true
        \\> push = false
        \\> publish = false
        \\> tag = false
        \\> tag-name = v{{version}}
        \\> tag-message = Release v{{version}}
        \\> pre-release-commit-message = chore: release v{{version}}
        \\
        \\workspace.metadata.release.pre-release-replacements[]
        \\> file = README.md
        \\> search = a deliberately long pattern string so this element cannot fit in the inline flow budget
        \\+
        \\> file = CHANGELOG.md
        \\> search = another deliberately long pattern string keeping the sequence out of the inline budget
        \\
    );
}

test "a lone flat child between deep siblings stays a dotted assignment" {
    try expectPrint(
        \\workspace
        \\> resolver = "2"
        \\> dependencies
        \\>> fig
        \\>>> version = 1.0.0
        \\>>> features-list = [serde, yaml, derive, indexmap, extras, and-more]
        \\>> chrono
        \\>>> version = "0.4"
        \\>>> features-list = [serde, std, clock, and, extra, padding, words, here]
    ,
        \\workspace.resolver = "2"
        \\
        \\workspace.dependencies
        \\> fig
        \\> > version = 1.0.0
        \\> > features-list = [serde, yaml, derive, indexmap, extras, and-more]
        \\> chrono
        \\> > version = "0.4"
        \\> > features-list = [serde, std, clock, and, extra, padding, words, here]
        \\
    );
}

test "multi-line strings print as ''' raw blocks (escaped \"\"\" when needed)" {
    // A trailing newline in the value becomes one empty line before the
    // flush-left closer (the tokenizer drops the newline before the closer's
    // line). Interior indentation is content and survives verbatim.
    try expectPrint("script = \"set -e\\nif x; then\\n  echo hi\\nfi\\n\"\n",
        \\script = '''
        \\set -e
        \\if x; then
        \\  echo hi
        \\fi
        \\
        \\'''
        \\
    );
    // Content containing ''' cannot be raw — escaped flavor, quotes escaped.
    try expectPrint("q = \"has '''\\nquotes\"\n",
        \\q = """
        \\has '''
        \\quotes
        \\"""
        \\
    );
}

test "multi-line strings round-trip (raw, escaped, trailing-newline shapes)" {
    try expectRoundTrip("a = \"x\\ny\"\nb = \"x\\ny\\n\"\nc = \"tail '''\\nline2\"\nd = \"\\n\\nleading blanks\"\n");
}

test "a container holding a multi-line string breaks out of flow" {
    try expectPrint("wrap\n> cmd = \"a\\nb\"\n",
        \\wrap.cmd = '''
        \\a
        \\b
        \\'''
        \\
    );
}

test "typed sequence elements keep their annotations" {
    try expectPrint(
        \\weights
        \\>-: int = 1
        \\>-: enum = heavy
        \\>- and a long plain string element so the whole weights sequence stays out of the inline budget
    ,
        \\weights
        \\>- 1
        \\>-: enum = heavy
        \\>- and a long plain string element so the whole weights sequence stays out of the inline budget
        \\
    );
}
