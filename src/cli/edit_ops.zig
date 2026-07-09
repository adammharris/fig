//! In-place editing plumbing shared by `edit`/`set`/`insert`/`delete`/
//! `comment`: the single span-splice path (`applyEdit`) behind every
//! structural op, its embed-aware twin (`applyToEmbed`), and the small
//! per-format helpers (JSON requoting, empty-document seeds) those two lean
//! on.
const std = @import("std");
const fig = @import("fig");
const build_options = @import("build_options");

const types = @import("types.zig");
const fileio = @import("fileio.zig");

const Format = types.Format;
const EditOp = types.EditOp;
const Io = std.Io;

/// Extract the embedded config of `embed_type` from a host file and parse it.
/// The returned document's node spans are relative to the embedded region.
pub fn parseEmbeddedFromFile(allocator: std.mem.Allocator, io: Io, file: Io.File, embed_type: fig.Embed.Type) !fig.Document {
    const content = try fileio.readAll(allocator, io, file);
    const embedded = try fig.Embed.extract(allocator, content, embed_type);
    return embedded.document;
}

/// Apply one in-place edit to `content` (a complete document parsed under
/// `dialect`) and return the new bytes. The single span-splice path behind both
/// the `edit` and `comment` actions.
pub fn applyEdit(
    comptime Lang: type,
    allocator: std.mem.Allocator,
    content: []const u8,
    path: []fig.AST.PathSegment,
    text: []const u8,
    op: EditOp,
    dialect: Lang.Type,
) ![]u8 {
    var editor: fig.Editor(Lang) = .{ .allocator = allocator, .format = dialect };
    try editor.init(content);
    defer editor.deinit();
    switch (op) {
        .replace_value => try editor.replaceValAtPath(path, text),
        .replace_key => try editor.replaceKeyAtPath(path, text),
        .add_leading_comment => try editor.addLeadingComment(path, text),
        .set_trailing_comment => try editor.setTrailingComment(path, text),
        .delete_leading_comments => try editor.deleteLeadingComments(path),
        .delete_trailing_comment => try editor.deleteTrailingComment(path),
        .insert_key => |key| try editor.insertKey(path, key, text),
        .set => try editor.set(path, text),
        .set_sequence => |items| try editor.setSequence(path, items),
        .append_seq => try editor.appendToSeq(path, text),
        .prepend_seq => try editor.prependToSeq(path, text),
        .delete_key => try editor.deleteKey(path),
        .remove_seq_item => |index| try editor.removeSeqItem(path, index),
    }
    return allocator.dupe(u8, editor.source.items);
}

pub fn applyToFile(
    comptime Lang: type,
    allocator: std.mem.Allocator,
    io: Io,
    file: Io.File,
    path: []fig.AST.PathSegment,
    text: []const u8,
    op: EditOp,
    dialect: Lang.Type,
) !void {
    const content = try fileio.readAll(allocator, io, file);
    defer allocator.free(content);

    const edited = try applyEdit(Lang, allocator, content, path, text, op, dialect);
    try file.writePositionalAll(io, edited, 0);
    try file.setLength(io, edited.len);
}

/// Read back a comment from `content` (parsed under `dialect`) without writing:
/// the trailing (same-line) comment on the value at `path` when `inline_comment`,
/// else the own-line block above the node. Returns `null` when there is no such
/// comment (the CLI then prints a blank line). The read-only twin of `applyEdit`'s
/// comment ops.
pub fn getComment(
    comptime Lang: type,
    allocator: std.mem.Allocator,
    content: []const u8,
    path: []fig.AST.PathSegment,
    inline_comment: bool,
    dialect: Lang.Type,
) !?[]u8 {
    var editor: fig.Editor(Lang) = .{ .allocator = allocator, .format = dialect };
    try editor.init(content);
    defer editor.deinit();
    return if (inline_comment)
        editor.getTrailingComment(path)
    else
        editor.getLeadingComment(path);
}

pub fn getCommentFromFile(
    comptime Lang: type,
    allocator: std.mem.Allocator,
    io: Io,
    file: Io.File,
    path: []fig.AST.PathSegment,
    inline_comment: bool,
    dialect: Lang.Type,
) !?[]u8 {
    const content = try fileio.readAll(allocator, io, file);
    defer allocator.free(content);
    return getComment(Lang, allocator, content, path, inline_comment, dialect);
}

/// Read a comment from the embedded config of a host file: extract the region,
/// parse only that slice as its inner format, and read the comment from it. The
/// read-only twin of `applyToEmbed`.
pub fn getCommentFromEmbed(
    allocator: std.mem.Allocator,
    io: Io,
    file: Io.File,
    embed_type: fig.Embed.Type,
    path: []fig.AST.PathSegment,
    inline_comment: bool,
) !?[]u8 {
    const content = try fileio.readAll(allocator, io, file);
    defer allocator.free(content);

    const embedded = try fig.Embed.extract(allocator, content, embed_type);
    defer embedded.deinit(allocator);
    const region = embedded.region;
    const inner = content[region.content.start..region.content.end];

    return switch (embed_type) {
        .FrontmatterYaml, .EndmatterYaml => if (comptime build_options.lang_yaml)
            try getComment(fig.Language.YAML, allocator, inner, path, inline_comment, fig.Language.YAML.default_type)
        else
            return error.FormatDisabled,
        // Strict JSON frontmatter has no comment syntax: nothing to read.
        .FrontmatterJson => if (comptime build_options.lang_json)
            try getComment(fig.Language.JSON, allocator, inner, path, inline_comment, .JSON)
        else
            return error.FormatDisabled,
        .FrontmatterFig => if (comptime build_options.lang_fig)
            try getComment(fig.Language.FIG, allocator, inner, path, inline_comment, fig.Language.FIG.default_type)
        else
            return error.FormatDisabled,
    };
}

/// Apply an edit to the embedded config of a host file in place: extract the
/// region, edit only that slice as its inner format, then splice it back between
/// the retained fences so the rest of the host file is byte-identical.
pub fn applyToEmbed(
    allocator: std.mem.Allocator,
    io: Io,
    file: Io.File,
    embed_type: fig.Embed.Type,
    path: []fig.AST.PathSegment,
    text: []const u8,
    op: EditOp,
) !void {
    const content = try fileio.readAll(allocator, io, file);
    defer allocator.free(content);

    // Locate the region; when it's absent and the op can seed a fresh block
    // (`set` / insert-a-key), synthesize an empty one — the CLI's open-or-init.
    // `base` is the document the edited content splices back into: the original
    // file, or the synthesized host carrying the new empty block.
    var base: []const u8 = content;
    var created_host: ?[]u8 = null;
    defer if (created_host) |h| allocator.free(h);
    const region = reg: {
        if (fig.Embed.locateRegion(content, embed_type)) |r| {
            break :reg r;
        } else |err| switch (err) {
            error.NotFound => {
                if (!opSeedsEmptyRegion(op)) return err;
                const created = try fig.Embed.initRegion(allocator, content, embed_type);
                created_host = created.host;
                base = created.host;
                break :reg created.region;
            },
            else => return err,
        }
    };
    const inner = base[region.content.start..region.content.end];

    const edited_inner = switch (embed_type) {
        .FrontmatterYaml, .EndmatterYaml => if (comptime build_options.lang_yaml)
            try applyEdit(fig.Language.YAML, allocator, inner, path, text, op, fig.Language.YAML.default_type)
        else
            return error.FormatDisabled,
        // JSON frontmatter is plain (strict) JSON: an inserted/replaced key or
        // value is quoted as a JSON string, while a comment op rides through
        // unquoted and the editor rejects it (strict JSON has no comment syntax).
        .FrontmatterJson => if (comptime build_options.lang_json) blk: {
            const j = try jsonifyEdit(allocator, op, text);
            break :blk try applyEdit(fig.Language.JSON, allocator, inner, path, j.text, j.op, .JSON);
        } else return error.FormatDisabled,
        .FrontmatterFig => if (comptime build_options.lang_fig)
            try applyEdit(fig.Language.FIG, allocator, inner, path, text, op, fig.Language.FIG.default_type)
        else
            return error.FormatDisabled,
    };

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, base[0..region.content.start]);
    try out.appendSlice(allocator, edited_inner);
    try out.appendSlice(allocator, base[region.content.end..]);

    try file.writePositionalAll(io, out.items, 0);
    try file.setLength(io, out.items.len);
}

/// Whether `op` can seed a freshly-created empty embed region — only the ops
/// that establish a first entry (`set` upserts it; `insert_key` adds it). Other
/// ops (replace/delete/comment/sequence) require an already-present region.
pub fn opSeedsEmptyRegion(op: EditOp) bool {
    return switch (op) {
        .set, .insert_key => true,
        else => false,
    };
}

/// Recast an edit for a JSON-family target: strict JSON has no bare literals,
/// so an inserted/replaced key or value must be wrapped as a JSON string (parity
/// with `edit`'s value replacement). Comment and delete ops carry no value and
/// pass through untouched. Returns the (possibly requoted) text and op.
pub fn jsonifyEdit(allocator: std.mem.Allocator, op: EditOp, text: []const u8) !struct { text: []const u8, op: EditOp } {
    const text_out = switch (op) {
        .replace_value, .replace_key, .insert_key, .set, .append_seq, .prepend_seq => try std.fmt.allocPrint(allocator, "\"{s}\"", .{text}),
        // `set_sequence` carries its items in the op payload (requoted below);
        // comment ops and structural deletes carry no value text.
        .set_sequence, .add_leading_comment, .set_trailing_comment, .delete_leading_comments, .delete_trailing_comment, .delete_key, .remove_seq_item => text,
    };
    const op_out: EditOp = switch (op) {
        .insert_key => |key| .{ .insert_key = try std.fmt.allocPrint(allocator, "\"{s}\"", .{key}) },
        .set_sequence => |items| blk: {
            const quoted = try allocator.alloc([]const u8, items.len);
            for (items, 0..) |it, i| quoted[i] = try std.fmt.allocPrint(allocator, "\"{s}\"", .{it});
            break :blk .{ .set_sequence = quoted };
        },
        else => op,
    };
    return .{ .text = text_out, .op = op_out };
}

/// Map the CLI's JSON-family `Format` to the parser dialect the editor reparses
/// under, so editing a JSONC/JSON5 file keeps its comments valid on reparse.
pub fn jsonDialect(format: Format) fig.Language.JSON.Type {
    return switch (format) {
        .jsonc => .JSONC,
        .json5 => .JSON5,
        else => .JSON,
    };
}

/// The minimal valid empty document for `format`, used to seed a file `set`
/// creates from scratch before landing its first key. `null` means the format
/// has no empty-document form to seed into — the non-editable/projection formats
/// (XML/canonical/gron) — so a from-scratch `set` on it is refused before any
/// file is created. fig, like YAML/TOML, seeds from an empty file: an empty fig
/// document parses as an empty map (see `buildRoot`), so the first `set` lands
/// its key into it. JSON5 shares JSON's `{}` seed even though its in-place edit
/// is unsupported: the clearer `UnsupportedJson5Edit` error then fires at edit
/// time rather than a confusing "cannot seed" here.
pub fn emptyDocSeed(format: Format) ?[]const u8 {
    return switch (format) {
        .json, .jsonc, .json5 => "{}\n",
        // dotenv/.properties/ini all parse an empty file as an empty (but
        // present) root mapping — same empty-string seed as YAML/TOML/fig —
        // so `set` can create one from scratch and land its first root-level
        // key into it. (INI's own auto-vivify guard in `Editor.set` only
        // matters for a 2+-segment path creating a brand-new SECTION; a
        // single root-level key from an empty file is unaffected.)
        .yaml, .yml, .toml, .fig, .dotenv, .properties, .ini => "",
        .zon => ".{}\n",
        // An empty NestedText file parses as `.null_` (see `nestedtext/
        // parser.zig`), and `Editor(NestedText)`'s `insertKey` promotes that
        // root straight to a one-entry mapping (see its `nt_edit.ntInsertKey`)
        // — same empty-string seed as YAML/TOML/fig/dotenv/.properties/ini.
        .nestedtext => "",
        .xml, .canonical, .gron, .plist => null,
    };
}

/// Shared per-format routing for the structural `insert`/`delete` actions —
/// the `edit` handler's format switch, minus the value-replacement specifics.
/// JSON-family inputs requote the inserted key/value via `jsonifyEdit`; YAML,
/// TOML, and ZON take the text verbatim as a literal. `embed` routes through the
/// host-document splicer instead. `op` already encodes which editor primitive
/// runs and `path` is the container path it operates on.
pub fn applyStructuralEdit(
    allocator: std.mem.Allocator,
    io: Io,
    input: Io.File,
    resolved: Format,
    embed: ?fig.Embed.Type,
    path: []fig.AST.PathSegment,
    text: []const u8,
    op: EditOp,
) !void {
    if (embed) |embed_type| return applyToEmbed(allocator, io, input, embed_type, path, text, op);
    switch (resolved) {
        .json, .jsonc => |f| if (comptime build_options.lang_json) {
            const j = try jsonifyEdit(allocator, op, text);
            try applyToFile(fig.Language.JSON, allocator, io, input, path, j.text, j.op, jsonDialect(f));
        } else return error.FormatDisabled,
        .yaml, .yml => if (comptime build_options.lang_yaml)
            try applyToFile(fig.Language.YAML, allocator, io, input, path, text, op, fig.Language.YAML.default_type)
        else
            return error.FormatDisabled,
        .toml => if (comptime build_options.lang_toml)
            try applyToFile(fig.Language.TOML, allocator, io, input, path, text, op, fig.Language.TOML.default_type)
        else
            return error.FormatDisabled,
        .zon => if (comptime build_options.lang_zon)
            try applyToFile(fig.Language.ZON, allocator, io, input, path, text, op, fig.Language.ZON.default_type)
        else
            return error.FormatDisabled,
        .xml => return error.UnsupportedXmlEdit,
        // INI: one level of `[section]` nesting on top of the same flat
        // `key = value` shape as dotenv/.properties. `Editor(Ini)` carries
        // its own small guards (see `editor.zig`'s `Ini` branches) for the
        // two things that genuinely need them: refusing to line-delete a
        // scattered `[section]` header, and refusing to auto-vivify a
        // brand-new section via `set` (INI has no empty-mapping literal to
        // do that with) — everything else (root/section key insert-replace-
        // delete, leading comments) flows through the generic engine.
        .ini => if (comptime build_options.lang_ini)
            try applyToFile(fig.Language.INI, allocator, io, input, path, text, op, fig.Language.INI.default_type)
        else
            return error.FormatDisabled,
        // dotenv/.properties: flat `KEY=value` only (no nesting/sequences),
        // so the generic block-mapping editor covers every op the CLI
        // exposes here — `=` separator + the first-insert-into-an-empty-
        // mapping fix live in `Editor`'s `kv_sep`/`insertBlockKey`.
        .dotenv => if (comptime build_options.lang_dotenv)
            try applyToFile(fig.Language.DOTENV, allocator, io, input, path, text, op, fig.Language.DOTENV.default_type)
        else
            return error.FormatDisabled,
        .properties => if (comptime build_options.lang_properties)
            try applyToFile(fig.Language.PROPERTIES, allocator, io, input, path, text, op, fig.Language.PROPERTIES.default_type)
        else
            return error.FormatDisabled,
        // plist: XML-based but a strict, typed subset, so it (unlike generic
        // `.xml`) has a real span-splicing editor. `Editor(Plist)` renders
        // typed value elements and uses `<!-- -->` comments; see
        // `languages/plist/editor_helper.zig`.
        .plist => if (comptime build_options.lang_plist)
            try applyToFile(fig.Language.PLIST, allocator, io, input, path, text, op, fig.Language.PLIST.default_type)
        else
            return error.FormatDisabled,
        .json5 => return error.UnsupportedJson5Edit,
        .canonical => return error.UnsupportedCanonicalEdit,
        .fig => if (comptime build_options.lang_fig)
            try applyToFile(fig.Language.FIG, allocator, io, input, path, text, op, fig.Language.FIG.default_type)
        else
            return error.FormatDisabled,
        .gron => return error.UnsupportedGronEdit,
        // NestedText: `Editor(NestedText)` covers insert/set/delete/append/
        // prepend/remove/move/reorder plus leading (own-line) comments; a
        // same-line trailing comment has no spelling in this grammar (see
        // `nestedtext/editor_helper.zig`'s `trailingCommentMarker` override),
        // and inserting into a genuinely empty inline `{}`/`[]` is declined
        // with `error.EmptyInlineContainer` rather than guessed at.
        .nestedtext => if (comptime build_options.lang_nestedtext)
            try applyToFile(fig.Language.NESTEDTEXT, allocator, io, input, path, text, op, fig.Language.NESTEDTEXT.default_type)
        else
            return error.FormatDisabled,
    }
}

test "applyEdit performs the structural ops on YAML" {
    if (comptime !build_options.lang_yaml) return error.SkipZigTest;
    const t = std.testing;
    const Y = fig.Language.YAML;
    const dia = Y.default_type;

    // insert_key appends a mapping entry.
    {
        const out = try applyEdit(Y, t.allocator, "a: 1\n", &.{}, "2", .{ .insert_key = "b" }, dia);
        defer t.allocator.free(out);
        try t.expectEqualStrings("a: 1\nb: 2\n", out);
    }
    // append_seq / prepend_seq on a block sequence.
    {
        const app = try applyEdit(Y, t.allocator, "- x\n- y\n", &.{}, "z", .append_seq, dia);
        defer t.allocator.free(app);
        try t.expectEqualStrings("- x\n- y\n- z\n", app);

        const pre = try applyEdit(Y, t.allocator, "- x\n- y\n", &.{}, "w", .prepend_seq, dia);
        defer t.allocator.free(pre);
        try t.expectEqualStrings("- w\n- x\n- y\n", pre);
    }
    // delete_key removes a mapping entry; remove_seq_item drops an item.
    {
        var dk_path = [_]fig.AST.PathSegment{.{ .key = "a" }};
        const dk = try applyEdit(Y, t.allocator, "a: 1\nb: 2\n", &dk_path, "", .delete_key, dia);
        defer t.allocator.free(dk);
        try t.expectEqualStrings("b: 2\n", dk);

        const ri = try applyEdit(Y, t.allocator, "- x\n- y\n- z\n", &.{}, "", .{ .remove_seq_item = 1 }, dia);
        defer t.allocator.free(ri);
        try t.expectEqualStrings("- x\n- z\n", ri);
    }
}

test "applyEdit set upserts a scalar and reconciles a sequence on YAML" {
    if (comptime !build_options.lang_yaml) return error.SkipZigTest;
    const t = std.testing;
    const Y = fig.Language.YAML;
    const dia = Y.default_type;

    // set replaces an existing key …
    {
        var p = [_]fig.AST.PathSegment{.{ .key = "a" }};
        const out = try applyEdit(Y, t.allocator, "a: 1\nb: 2\n", &p, "9", .set, dia);
        defer t.allocator.free(out);
        try t.expectEqualStrings("a: 9\nb: 2\n", out);
    }
    // … and creates an absent one.
    {
        var p = [_]fig.AST.PathSegment{.{ .key = "c" }};
        const out = try applyEdit(Y, t.allocator, "a: 1\n", &p, "3", .set, dia);
        defer t.allocator.free(out);
        try t.expectEqualStrings("a: 1\nc: 3\n", out);
    }
    // set on an empty document seeds the first key — the open-or-init seed case.
    {
        var p = [_]fig.AST.PathSegment{.{ .key = "k" }};
        const out = try applyEdit(Y, t.allocator, "", &p, "v", .set, dia);
        defer t.allocator.free(out);
        try t.expectEqualStrings("k: v\n", out);
    }
    // set_sequence reconciles to the target list, keeping survivors' comments.
    {
        var p = [_]fig.AST.PathSegment{.{ .key = "tags" }};
        const items = [_][]const u8{ "c", "a", "d" };
        const out = try applyEdit(Y, t.allocator, "tags:\n- a # first\n- b # second\n- c # third\n", &p, "", .{ .set_sequence = &items }, dia);
        defer t.allocator.free(out);
        try t.expectEqualStrings("tags:\n- c # third\n- a # first\n- d\n", out);
    }
}

test "applyEdit performs the structural ops on dotenv, including from-empty insert" {
    if (comptime !build_options.lang_dotenv) return error.SkipZigTest;
    const t = std.testing;
    const D = fig.Language.DOTENV;
    const dia = D.default_type;

    // insert_key into a brand-new (empty) document — the from-scratch `set`
    // seed path, and the case that used to panic in `insertBlockKey` before
    // it learned to handle a childless block mapping.
    {
        const out = try applyEdit(D, t.allocator, "", &.{}, "bar", .{ .insert_key = "FOO" }, dia);
        defer t.allocator.free(out);
        try t.expectEqualStrings("FOO=bar\n", out);
    }
    // insert_key into an existing document uses '=' with no surrounding spaces.
    {
        const out = try applyEdit(D, t.allocator, "FOO=bar\n", &.{}, "qux", .{ .insert_key = "BAZ" }, dia);
        defer t.allocator.free(out);
        try t.expectEqualStrings("FOO=bar\nBAZ=qux\n", out);
    }
    // delete_key down to empty, then set seeds it again.
    {
        var dk_path = [_]fig.AST.PathSegment{.{ .key = "FOO" }};
        const dk = try applyEdit(D, t.allocator, "FOO=bar\n", &dk_path, "", .delete_key, dia);
        defer t.allocator.free(dk);
        try t.expectEqualStrings("", dk);

        var set_path = [_]fig.AST.PathSegment{.{ .key = "AGAIN" }};
        const out = try applyEdit(D, t.allocator, dk, &set_path, "v2", .set, dia);
        defer t.allocator.free(out);
        try t.expectEqualStrings("AGAIN=v2\n", out);
    }
}

test "applyEdit performs the structural ops on ini, root and section" {
    if (comptime !build_options.lang_ini) return error.SkipZigTest;
    const t = std.testing;
    const I = fig.Language.INI;
    const dia = I.default_type;

    // insert_key into a brand-new (empty) document.
    {
        const out = try applyEdit(I, t.allocator, "", &.{}, "fig", .{ .insert_key = "name" }, dia);
        defer t.allocator.free(out);
        try t.expectEqualStrings("name = fig\n", out);
    }
    // insert_key into an existing SECTION uses ' = ' with padding.
    {
        var path = [_]fig.AST.PathSegment{.{ .key = "server" }};
        const out = try applyEdit(I, t.allocator, "[server]\nhost = localhost\n", &path, "80", .{ .insert_key = "port" }, dia);
        defer t.allocator.free(out);
        try t.expectEqualStrings("[server]\nhost = localhost\nport = 80\n", out);
    }
    // delete_key on a `[section]` header itself is refused, not silently
    // corrupted.
    {
        var dk_path = [_]fig.AST.PathSegment{.{ .key = "server" }};
        try t.expectError(error.CannotDeleteSection, applyEdit(I, t.allocator, "[server]\nhost = localhost\n", &dk_path, "", .delete_key, dia));
    }
}

test "applyEdit performs the structural ops on .properties, including from-empty insert" {
    if (comptime !build_options.lang_properties) return error.SkipZigTest;
    const t = std.testing;
    const P = fig.Language.PROPERTIES;
    const dia = P.default_type;

    const out = try applyEdit(P, t.allocator, "", &.{}, "bar", .{ .insert_key = "foo" }, dia);
    defer t.allocator.free(out);
    try t.expectEqualStrings("foo=bar\n", out);
}

test "emptyDocSeed: dotenv/.properties/ini seed empty like YAML/TOML/fig" {
    try std.testing.expectEqualStrings("", emptyDocSeed(.dotenv).?);
    try std.testing.expectEqualStrings("", emptyDocSeed(.properties).?);
    try std.testing.expectEqualStrings("", emptyDocSeed(.ini).?);
}

test "jsonifyEdit quotes inserted key and value, leaves deletes bare" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ins = try jsonifyEdit(a, .{ .insert_key = "k" }, "v");
    try t.expectEqualStrings("\"v\"", ins.text);
    try t.expectEqualStrings("\"k\"", ins.op.insert_key);

    const app = try jsonifyEdit(a, .append_seq, "v");
    try t.expectEqualStrings("\"v\"", app.text);

    const del = try jsonifyEdit(a, .delete_key, "");
    try t.expectEqualStrings("", del.text);
    try t.expectEqual(EditOp.delete_key, del.op);

    // set quotes its value; set_sequence requotes each item.
    const s = try jsonifyEdit(a, .set, "v");
    try t.expectEqualStrings("\"v\"", s.text);
    try t.expectEqual(EditOp.set, s.op);

    const items = [_][]const u8{ "x", "y" };
    const sq = try jsonifyEdit(a, .{ .set_sequence = &items }, "");
    try t.expectEqualStrings("\"x\"", sq.op.set_sequence[0]);
    try t.expectEqualStrings("\"y\"", sq.op.set_sequence[1]);
}

test "emptyDocSeed: seedable formats round-trip a first `set`, others refuse" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The seed a from-scratch `set` writes must parse and accept the first key,
    // reproducing on-disk `createSeededFile` + `applyStructuralEdit` in memory.
    var path = [_]fig.AST.PathSegment{.{ .key = "hello" }};

    // YAML: empty seed, bare value.
    const yaml = try applyEdit(fig.Language.YAML, a, emptyDocSeed(.yaml).?, &path, "world", .set, fig.Language.YAML.default_type);
    try t.expectEqualStrings("hello: world\n", yaml);

    // JSON: `{}` seed, value requoted through the JSON path like the CLI does.
    const jv = try jsonifyEdit(a, .set, "world");
    const json = try applyEdit(fig.Language.JSON, a, emptyDocSeed(.json).?, &path, jv.text, jv.op, .JSON);
    try t.expect(std.mem.indexOf(u8, json, "\"hello\"") != null);
    try t.expect(std.mem.indexOf(u8, json, "\"world\"") != null);

    // TOML: empty seed, value already a TOML literal.
    const toml = try applyEdit(fig.Language.TOML, a, emptyDocSeed(.toml).?, &path, "\"world\"", .set, fig.Language.TOML.default_type);
    try t.expectEqualStrings("hello = \"world\"\n", toml);

    // fig: empty seed (an empty document parses as an empty map), bare value.
    const figc = try applyEdit(fig.Language.FIG, a, emptyDocSeed(.fig).?, &path, "world", .set, fig.Language.FIG.default_type);
    try t.expectEqualStrings("hello = world\n", figc);

    // Projection/non-stored formats (gron, canonical, xml) have no empty-document
    // form, so the create is refused before a file lands.
    try t.expectEqual(@as(?[]const u8, null), emptyDocSeed(.gron));
    try t.expectEqual(@as(?[]const u8, null), emptyDocSeed(.canonical));
}
