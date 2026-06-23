//! Serialization — the canonical output formats, their options/errors, and the
//! `serialize*` entry points that dispatch to each format's printer. The public
//! functions here are re-exported as `AST` methods from `ast.zig`.

const std = @import("std");
const Writer = std.Io.Writer;
const build_options = @import("build_options");

const AST = @import("ast.zig");
const Node = AST.Node;

// Printers are pulled in only for the formats compiled into this build. A gated
// format's `*Printer` is `void`, so the matching `serialize` arm below (guarded
// by the same comptime flag) is never analyzed and the printer never compiles.
const JsonPrinter = if (build_options.lang_json) @import("../json/printer.zig") else void;
const YamlPrinter = if (build_options.lang_yaml) @import("../yaml/printer.zig") else void;
const TomlPrinter = if (build_options.lang_toml) @import("../toml/printer.zig") else void;
const ZonPrinter = if (build_options.lang_zon) @import("../zon/printer.zig") else void;
// The native format is the AST's own 1:1 encoding — always compiled in (no
// language gate), so it needs no `void` fallback or comptime guard below.
const NativePrinter = @import("../native/printer.zig");

/// The canonical output format families.
pub const SerializeFormat = enum { json, jsonc, json5, yaml, toml, zon, native };

/// Knobs controlling how a value is rendered. The defaults reproduce fig's
/// historical output (pretty-printed, two-space indent), so `.{}` is a no-op
/// change for existing callers.
///
/// Honored where each setting is meaningful:
///   * `pretty` — JSON/JSON5 (multi-line vs. minified) and ZON (`zig fmt`
///     multi-line vs. inline `.{ a, b }`). TOML uses it to gate array wrapping
///     (`true`: wrap arrays wider than `width`; `false`: keep every array on one
///     line). YAML ignores it (its compact flow style is not yet emitted).
///   * `indent` — JSON/JSON5 spaces per level, and the per-level indent of TOML's
///     wrapped arrays. ZON keeps its idiomatic four-space block indent; YAML has
///     its own fixed layout.
///   * `width` — TOML only: the column budget that decides whether a mapping
///     renders as an inline table (`k = { ... }`) or a `[section]`, and whether an
///     array stays on one line or wraps. A value/line that fits within `width`
///     stays inline; one that exceeds it expands.
///   * `strip_comments` — every format: drop the AST's carried comments instead
///     of emitting them. Honored uniformly (it blanks the comment side-table
///     before printing), so it works even for the formats whose printers take no
///     options.
pub const SerializeOptions = struct {
    /// `true`: multi-line, indented output. `false`: compact single-line output
    /// with no insignificant whitespace.
    pretty: bool = true,
    /// Spaces per indentation level when `pretty` is set (JSON; TOML wrapped
    /// arrays).
    indent: u8 = 2,
    /// Column budget for TOML's inline-vs-expanded layout decision. Anything that
    /// renders within this many columns stays inline; wider values expand to
    /// sections / wrapped arrays. Ignored by the other formats.
    width: u16 = 80,
    /// `true`: do not emit comments carried on the AST (a clean, comment-free
    /// render). `false` (default): preserve them where the target format allows.
    strip_comments: bool = false,
};

/// `self`, or a comment-stripped *view* of it when `options.strip_comments` is
/// set. The view is a shallow struct copy that shares all node/string storage and
/// only blanks `node_comments`, so stripping costs no allocation. `buf` provides
/// the view's stack storage; the returned pointer is valid for `buf`'s lifetime.
fn commentView(self: *const AST, options: SerializeOptions, buf: *AST) *const AST {
    if (!options.strip_comments) return self;
    buf.* = self.*;
    buf.node_comments = &.{};
    return buf;
}

/// The canonical set of ways serialization can fail
pub const SerializeError = Writer.Error || error{
    UnresolvedAlias, // a YAML `*alias` reached a non-YAML printer (materialize first)
    NullUnsupported, // a `null` reached a format with no null type (TOML)
    NonStringKey, // a mapping key was not a string (TOML, ZON)
    FormatDisabled, // the target format was compiled out of this build
    NestingTooDeep, // container nesting exceeded the native printer's depth guard
};

/// Render the whole AST to `writer` in the given format, using default options.
/// Does not handle aliases, tags, or lossless `$fig` envelopes.
pub fn serialize(self: *const AST, writer: *Writer, format: SerializeFormat) SerializeError!void {
    return self.serializeWith(writer, format, .{});
}

/// Render the whole AST to `writer`, controlling output style via `options`.
pub fn serializeWith(self: *const AST, writer: *Writer, format: SerializeFormat, options: SerializeOptions) SerializeError!void {
    var buf: AST = undefined;
    const ast = commentView(self, options, &buf);
    return switch (format) {
        .json => if (comptime build_options.lang_json) JsonPrinter.print(writer, ast, options) else error.FormatDisabled,
        .jsonc => if (comptime build_options.lang_json) JsonPrinter.printc(writer, ast, options) else error.FormatDisabled,
        .json5 => if (comptime build_options.lang_json) JsonPrinter.print5(writer, ast, options) else error.FormatDisabled,
        .yaml => if (comptime build_options.lang_yaml) YamlPrinter.print(writer, ast) else error.FormatDisabled,
        .toml => if (comptime build_options.lang_toml) TomlPrinter.print(writer, ast, options) else error.FormatDisabled,
        .zon => if (comptime build_options.lang_zon) ZonPrinter.print(writer, ast, options) else error.FormatDisabled,
        .native => NativePrinter.print(writer, ast),
    };
}

/// Render the subtree rooted at `id` to `writer`, using default options.
pub fn serializeNode(self: *const AST, writer: *Writer, format: SerializeFormat, id: Node.Id) SerializeError!void {
    return self.serializeNodeWith(writer, format, id, .{});
}

/// Render the subtree rooted at `id`, controlling output style via `options`.
pub fn serializeNodeWith(self: *const AST, writer: *Writer, format: SerializeFormat, id: Node.Id, options: SerializeOptions) SerializeError!void {
    var buf: AST = undefined;
    const ast = commentView(self, options, &buf);
    return switch (format) {
        .json => if (comptime build_options.lang_json) JsonPrinter.printNode(writer, ast, id, 0, options) else error.FormatDisabled,
        .jsonc => if (comptime build_options.lang_json) JsonPrinter.printNodec(writer, ast, id, 0, options) else error.FormatDisabled,
        .json5 => if (comptime build_options.lang_json) JsonPrinter.printNode5(writer, ast, id, 0, options) else error.FormatDisabled,
        .yaml => if (comptime build_options.lang_yaml) YamlPrinter.printNode(writer, ast, id, 0) else error.FormatDisabled,
        .toml => if (comptime build_options.lang_toml) TomlPrinter.printNode(writer, ast, id, 0, options) else error.FormatDisabled,
        .zon => if (comptime build_options.lang_zon) ZonPrinter.printNode(writer, ast, id, 0, options) else error.FormatDisabled,
        .native => NativePrinter.printNode(writer, ast, id, 0),
    };
}