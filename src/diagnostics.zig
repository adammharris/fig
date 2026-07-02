//! Serialization diagnostics: a read-only pass that reports what a conversion
//! would silently lose.
//!
//! fig's printers degrade or drop data whenever the target format can't hold a
//! value or a comment natively — a TOML `null` vanishes, a datetime collapses to
//! a string, a block comment becomes a run of `#` lines, plain JSON drops every
//! comment. None of that is an error (the output is still valid), so it happens
//! quietly. `analyze` surfaces it: it walks the AST exactly as a printer would
//! and returns one `Warning` per lossy event, each tagged with a `cause` so a
//! consumer (the CLI, a binding) can choose which to show.
//!
//! This is a separate pass, NOT instrumentation threaded through the printers:
//! the printers stay untouched, and the format-capability knowledge lives in one
//! place here (reusing `Lossless.needsEnvelope`/`isUnrepresentable` for the
//! formats whose capability the lossless layer already models). The walk shape
//! mirrors `Lossless.lossyStrip` — same dotted/`[i]` path building — but emits
//! instead of removing.
//!
//! Scope is serialization only. Read-side lossiness (deserialize's
//! `ignore_unknown_fields`, YAML materialize dropping tags/anchors) is not
//! covered here; the model is additive if that is ever wanted.

const std = @import("std");
const Allocator = std.mem.Allocator;
const AST = @import("ast/ast.zig");
const Lossless = @import("lossless.zig");
const Writer = std.Io.Writer;

const ExtKind = AST.Node.Kind.Extended.ExtKind;
const Format = AST.SerializeFormat;

/// One thing a conversion to a given format would lose.
pub const Warning = struct {
    code: Code,
    cause: Cause,
    /// Dotted/`[i]` path to the affected node, relative to the analyzed root.
    /// Empty (`""`) means the document root itself. Arena-owned by `analyze`.
    path: []const u8,
    /// Small extra context — for `type_degraded`, the type the value collapses
    /// to ("string", "number", …); otherwise empty. Static (not arena-owned).
    note: []const u8 = "",

    pub const Code = enum {
        /// A carried comment is not emitted at all (the target/mode has no comment
        /// syntax, or it was explicitly stripped).
        comment_dropped,
        /// A block comment is rendered as a run of line comments (the target has
        /// no block-comment syntax).
        comment_style_degraded,
        /// A node is removed entirely because the target cannot represent it even
        /// degraded (today: a `null` bound for TOML).
        value_dropped,
        /// An `extended` or non-finite value is rendered as a poorer type (a
        /// datetime/enum as a string, a char as a number, `inf`/`nan` quoted).
        type_degraded,
    };

    /// Why the loss happens — so a consumer can keep or ignore each class.
    pub const Cause = enum {
        /// The target format inherently cannot represent it.
        format_limitation,
        /// A caller option forced it (e.g. `strip_comments`).
        explicit_option,
    };

    /// Write the default human-readable message (no trailing newline). Bindings
    /// may instead render their own text from the structured fields.
    pub fn render(self: Warning, writer: *Writer, format: Format) Writer.Error!void {
        const fmt = @tagName(format);
        switch (self.code) {
            .value_dropped => {
                try writer.print("dropped {s} value at ", .{self.note});
                try writeLoc(writer, self.path);
                try writer.print(" ({s} cannot represent it)", .{fmt});
            },
            .type_degraded => {
                try writer.writeAll("degraded value at ");
                try writeLoc(writer, self.path);
                try writer.print(" to {s} ({s} has no native type for it)", .{ self.note, fmt });
            },
            .comment_dropped => {
                if (self.cause == .explicit_option) {
                    try writer.writeAll("stripped comment at ");
                    try writeLoc(writer, self.path);
                } else {
                    try writer.writeAll("dropped comment at ");
                    try writeLoc(writer, self.path);
                    try writer.print(" ({s} has no comment syntax here)", .{fmt});
                }
            },
            .comment_style_degraded => {
                try writer.writeAll("block comment at ");
                try writeLoc(writer, self.path);
                try writer.print(" rendered as line comments ({s} has no block comments)", .{fmt});
            },
        }
    }
};

/// Write a node path for messages: backtick-quoted, or "the document root" for
/// the empty (root) path.
fn writeLoc(writer: *Writer, path: []const u8) Writer.Error!void {
    if (path.len == 0) {
        try writer.writeAll("the document root");
    } else {
        try writer.writeByte('`');
        try writer.writeAll(path);
        try writer.writeByte('`');
    }
}

/// What the consumer is asking the printer to do — mirrors the subset of
/// `AST.SerializeOptions` that changes what gets lost, plus the lossless flag
/// (which lives outside `SerializeOptions`).
pub const Options = struct {
    /// Pretty (multi-line) output. Comment-bearing formats with no compact
    /// comment form (JSON5/JSONC/ZON) drop comments when this is false.
    pretty: bool = true,
    /// The caller asked to drop comments. Every comment becomes a
    /// `comment_dropped`/`explicit_option` warning.
    strip_comments: bool = false,
    /// Lossless conversion is in effect: unrepresentable values are preserved
    /// through a `$fig` envelope, so value losses are suppressed. (Comment
    /// losses still apply — the envelope path still prints comments normally.)
    lossless: bool = false,
};

/// Walk the subtree rooted at `root_id` as it would be serialized to `format`
/// and collect every lossy event. Warnings (and their `path` strings) are
/// allocated in `arena`; the returned slice is owned by the caller's arena.
pub fn analyze(arena: Allocator, ast: *const AST, root_id: AST.Node.Id, format: Format, options: Options) Allocator.Error![]Warning {
    var c = Collector{ .ast = ast, .arena = arena, .format = format, .options = options };
    try c.walk(root_id, "");
    return c.warnings.toOwnedSlice(arena);
}

const Collector = struct {
    ast: *const AST,
    arena: Allocator,
    format: Format,
    options: Options,
    warnings: std.ArrayList(Warning) = .empty,

    fn add(self: *Collector, w: Warning) Allocator.Error!void {
        try self.warnings.append(self.arena, w);
    }

    /// Visit one node: check its own value + comments, then recurse into a
    /// container's children (building each child's path).
    fn walk(self: *Collector, id: AST.Node.Id, path: []const u8) Allocator.Error!void {
        try self.checkComments(id, path);
        try self.checkValue(id, path);
        switch (self.ast.nodes[id].kind) {
            .mapping => |first| {
                var child = first;
                while (child) |cid| : (child = self.ast.nodes[cid].next_sibling) {
                    const kv = self.ast.nodes[cid].kind.keyvalue;
                    const child_path = try self.keyPath(path, kv.key);
                    // A mapping entry's leading comment binds to its KEY node; its
                    // trailing/value losses ride the value node (checked in walk).
                    try self.checkComments(kv.key, child_path);
                    try self.walk(kv.value, child_path);
                }
            },
            .sequence => |first| {
                var child = first;
                var i: usize = 0;
                while (child) |cid| : (child = self.ast.nodes[cid].next_sibling) {
                    const child_path = try indexPath(self.arena, path, i);
                    i += 1;
                    try self.walk(cid, child_path);
                }
            },
            else => {},
        }
    }

    fn checkValue(self: *Collector, id: AST.Node.Id, path: []const u8) Allocator.Error!void {
        const loss = valueLoss(self.format, self.ast.nodes[id].kind) orelse return;
        // Under lossless, unrepresentable values are enveloped, not lost.
        if (self.options.lossless) return;
        try self.add(.{ .code = loss.code, .cause = .format_limitation, .path = path, .note = loss.note });
    }

    fn checkComments(self: *Collector, id: AST.Node.Id, path: []const u8) Allocator.Error!void {
        const nc = self.ast.comments(id);
        if (nc.isEmpty()) return;
        // An explicit `strip_comments` is the user asking for the drop: that's the
        // actionable reason, so it wins even when the target also couldn't hold
        // the comment (a consumer filtering out `explicit_option` then correctly
        // stays silent — it's not a surprising loss).
        if (self.options.strip_comments) {
            try self.add(.{ .code = .comment_dropped, .cause = .explicit_option, .path = path });
            return;
        }
        // Otherwise, a format with no comment syntax here drops it outright.
        if (!commentsEmitted(self.format, self.options.pretty)) {
            try self.add(.{ .code = .comment_dropped, .cause = .format_limitation, .path = path });
            return;
        }
        if (!blockComments(self.format) and hasBlock(nc)) {
            try self.add(.{ .code = .comment_style_degraded, .cause = .format_limitation, .path = path });
        }
    }

    /// `parent.key` (or `key` at the root). A non-string key shows as `?` (only
    /// its value can be a loss target, so the key text is a hint).
    fn keyPath(self: *Collector, parent: []const u8, key_id: AST.Node.Id) Allocator.Error![]const u8 {
        const name = switch (self.ast.nodes[key_id].kind) {
            .string => |s| s,
            else => "?",
        };
        if (parent.len == 0) return self.arena.dupe(u8, name);
        return std.fmt.allocPrint(self.arena, "{s}.{s}", .{ parent, name });
    }
};

fn indexPath(arena: Allocator, parent: []const u8, i: usize) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}[{d}]", .{ parent, i });
}

// ── Capability table ────────────────────────────────────────────────────────
//
// The single source of truth for what each target format can hold. Keyed on the
// full 7-way `SerializeFormat` (not the coarser `Lossless.Target`) because the
// JSON family splits: plain JSON drops comments and quotes non-finite floats,
// while JSON5 keeps comments and has native `Infinity`/`NaN`, and JSONC keeps
// comments but still quotes non-finite. For the three formats whose type system
// the lossless layer already models exactly (YAML/TOML/ZON), value capability is
// delegated to `Lossless.needsEnvelope`/`isUnrepresentable`.

const Loss = struct { code: Warning.Code, note: []const u8 };

/// The value loss serializing `kind` to `format` would cause, or null if none.
/// Lossless suppression is the caller's concern (`checkValue`).
fn valueLoss(format: Format, kind: AST.Node.Kind) ?Loss {
    switch (format) {
        // Canonical is the lossless oracle: every kind round-trips.
        .canonical => return null,
        // Plain JSON / JSONC: no datetimes, enums, chars; non-finite floats quote.
        .json, .jsonc => switch (kind) {
            .extended => |e| return .{ .code = .type_degraded, .note = degradedNote(format, e.kind) },
            else => return null,
        },
        // JSON5 additionally has native non-finite floats.
        .json5 => switch (kind) {
            .extended => |e| {
                if (e.kind == .number_special) return null;
                return .{ .code = .type_degraded, .note = degradedNote(format, e.kind) };
            },
            else => return null,
        },
        // YAML/TOML/ZON: defer to the lossless capability model.
        .yaml, .toml, .zon => {
            const target: Lossless.Target = switch (format) {
                .yaml => .yaml,
                .toml => .toml,
                .zon => .zon,
                else => unreachable,
            };
            if (Lossless.isUnrepresentable(target, kind)) return .{ .code = .value_dropped, .note = dropNote(kind) };
            if (Lossless.needsEnvelope(target, kind)) {
                // `needsEnvelope` is true here only for `extended` kinds (a `null`
                // is either representable or already caught by `isUnrepresentable`).
                return switch (kind) {
                    .extended => |e| .{ .code = .type_degraded, .note = degradedNote(format, e.kind) },
                    else => null,
                };
            }
            return null;
        },
    }
}

/// The type an `extended` value collapses to in `format` — matches what each
/// printer actually writes (see `src/*/printer.zig`).
fn degradedNote(format: Format, ext: ExtKind) []const u8 {
    return switch (ext) {
        .enum_literal,
        .offset_datetime,
        .local_datetime,
        .local_date,
        .local_time,
        => "string",
        // A char literal's text is its codepoint: most printers emit it as a
        // number; TOML as an integer.
        .char_literal => switch (format) {
            .toml => "integer",
            else => "number",
        },
        // Non-finite floats quote in plain JSON/JSONC; elsewhere they degrade to
        // a plain string scalar (YAML/ZON — JSON5 keeps them natively, handled
        // before this is reached).
        .number_special => switch (format) {
            .json, .jsonc => "quoted string",
            else => "string",
        },
    };
}

fn dropNote(kind: AST.Node.Kind) []const u8 {
    return switch (kind) {
        .null_ => "null",
        else => "",
    };
}

/// Whether `format` emits comments at all in this mode. Plain JSON never does;
/// JSON5/JSONC/ZON only in pretty (multi-line) output; YAML/TOML/canonical always.
fn commentsEmitted(format: Format, pretty: bool) bool {
    return switch (format) {
        .json => false,
        .json5, .jsonc, .zon => pretty,
        .yaml, .toml, .canonical => true,
    };
}

/// Whether `format` has block-comment syntax (`/* … */`). Only the JSON5 family
/// and canonical do; YAML/TOML/ZON degrade a block comment to a line run.
fn blockComments(format: Format) bool {
    return switch (format) {
        .json5, .jsonc, .canonical => true,
        .json, .yaml, .toml, .zon => false,
    };
}

fn hasBlock(nc: AST.NodeComments) bool {
    for (nc.leading) |c| if (c.style == .block) return true;
    for (nc.dangling) |c| if (c.style == .block) return true;
    if (nc.trailing) |t| if (t.style == .block) return true;
    return false;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Build a small AST via the Builder, run `analyze`, and return the warnings in
/// an arena the caller owns.
fn analyzeBuilt(arena: Allocator, build: anytype, format: Format, options: Options) ![]Warning {
    var b = AST.Builder.init(arena);
    const root = try build(&b);
    var ast = try b.finish(root);
    return analyze(arena, &ast, ast.root, format, options);
}

test "null dropped for TOML, not for JSON/YAML" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Build = struct {
        fn f(b: *AST.Builder) !AST.Node.Id {
            const k = try b.addString("a");
            const v = try b.addNull();
            return b.addMapping(&.{.{ .key = k, .value = v }});
        }
    };

    const toml = try analyzeBuilt(arena, Build.f, .toml, .{});
    try testing.expectEqual(@as(usize, 1), toml.len);
    try testing.expectEqual(Warning.Code.value_dropped, toml[0].code);
    try testing.expectEqualStrings("a", toml[0].path);

    const json = try analyzeBuilt(arena, Build.f, .json, .{});
    try testing.expectEqual(@as(usize, 0), json.len);
}

test "datetime degrades to JSON, canonical to TOML" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Build = struct {
        fn f(b: *AST.Builder) !AST.Node.Id {
            return b.addExtended(.offset_datetime, "1979-05-27T07:32:00Z");
        }
    };

    const json = try analyzeBuilt(arena, Build.f, .json, .{});
    try testing.expectEqual(@as(usize, 1), json.len);
    try testing.expectEqual(Warning.Code.type_degraded, json[0].code);
    try testing.expectEqualStrings("string", json[0].note);

    const toml = try analyzeBuilt(arena, Build.f, .toml, .{});
    try testing.expectEqual(@as(usize, 0), toml.len);
}

test "non-finite float degrades to JSON but not JSON5" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Build = struct {
        fn f(b: *AST.Builder) !AST.Node.Id {
            return b.addExtended(.number_special, "Infinity");
        }
    };

    const json = try analyzeBuilt(arena, Build.f, .json, .{});
    try testing.expectEqual(@as(usize, 1), json.len);
    try testing.expectEqualStrings("quoted string", json[0].note);

    const json5 = try analyzeBuilt(arena, Build.f, .json5, .{});
    try testing.expectEqual(@as(usize, 0), json5.len);
}

test "lossless suppresses value warnings" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Build = struct {
        fn f(b: *AST.Builder) !AST.Node.Id {
            const k = try b.addString("a");
            const v = try b.addNull();
            return b.addMapping(&.{.{ .key = k, .value = v }});
        }
    };

    const toml = try analyzeBuilt(arena, Build.f, .toml, .{ .lossless = true });
    try testing.expectEqual(@as(usize, 0), toml.len);
}

test "comment dropped, style-degraded, and explicitly stripped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Build = struct {
        fn f(b: *AST.Builder) !AST.Node.Id {
            const k = try b.addString("a");
            const v = try b.addNumberRaw("1", false);
            const m = try b.addMapping(&.{.{ .key = k, .value = v }});
            // A block comment leads the entry (binds to the key node).
            try b.setComments(k, .{ .leading = &.{.{ .text = "note", .style = .block }} });
            return m;
        }
    };

    // YAML emits comments but has no block syntax → style degraded.
    const yaml = try analyzeBuilt(arena, Build.f, .yaml, .{});
    try testing.expectEqual(@as(usize, 1), yaml.len);
    try testing.expectEqual(Warning.Code.comment_style_degraded, yaml[0].code);
    try testing.expectEqualStrings("a", yaml[0].path);

    // Plain JSON has no comments at all → dropped, format limitation.
    const json = try analyzeBuilt(arena, Build.f, .json, .{});
    try testing.expectEqual(@as(usize, 1), json.len);
    try testing.expectEqual(Warning.Code.comment_dropped, json[0].code);
    try testing.expectEqual(Warning.Cause.format_limitation, json[0].cause);

    // JSON5 keeps block comments → no warning.
    const json5 = try analyzeBuilt(arena, Build.f, .json5, .{});
    try testing.expectEqual(@as(usize, 0), json5.len);

    // Explicit strip on a format that would otherwise keep it → explicit_option.
    const stripped = try analyzeBuilt(arena, Build.f, .json5, .{ .strip_comments = true });
    try testing.expectEqual(@as(usize, 1), stripped.len);
    try testing.expectEqual(Warning.Code.comment_dropped, stripped[0].code);
    try testing.expectEqual(Warning.Cause.explicit_option, stripped[0].cause);

    // Explicit strip wins even when the target ALSO can't hold comments: the user
    // asked for the drop, so it's `explicit_option`, not `format_limitation`.
    const stripped_json = try analyzeBuilt(arena, Build.f, .json, .{ .strip_comments = true });
    try testing.expectEqual(@as(usize, 1), stripped_json.len);
    try testing.expectEqual(Warning.Cause.explicit_option, stripped_json[0].cause);
}

test "path shapes match lossyStrip (dotted keys, bracket indices)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // { b: null, c: [1, null], d: { e: null } } → toml
    const Build = struct {
        fn f(b: *AST.Builder) !AST.Node.Id {
            const bk = try b.addString("b");
            const bv = try b.addNull();

            const c1 = try b.addNumberRaw("1", false);
            const c2 = try b.addNull();
            const cseq = try b.addSequence(&.{ c1, c2 });
            const ck = try b.addString("c");

            const ek = try b.addString("e");
            const ev = try b.addNull();
            const inner = try b.addMapping(&.{.{ .key = ek, .value = ev }});
            const dk = try b.addString("d");

            return b.addMapping(&.{
                .{ .key = bk, .value = bv },
                .{ .key = ck, .value = cseq },
                .{ .key = dk, .value = inner },
            });
        }
    };

    const w = try analyzeBuilt(arena, Build.f, .toml, .{});
    try testing.expectEqual(@as(usize, 3), w.len);
    try testing.expectEqualStrings("b", w[0].path);
    try testing.expectEqualStrings("c[1]", w[1].path);
    try testing.expectEqualStrings("d.e", w[2].path);
}
