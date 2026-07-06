//! Rendered-width measurement shared by the format printers' inline-layout
//! decisions. The one honest way to know how wide a value will be is to emit it
//! with the very function that produces the real output, against a writer that
//! counts and discards — so the estimate can never drift from the bytes actually
//! written (the alternative, hand-summed arithmetic widths, silently rots the
//! moment the emitter's spelling changes). TOML and YAML both measure this way;
//! fig keeps its own arithmetic pass for now.
const std = @import("std");

/// Byte width of whatever `render` writes, or `null` if `render` errors — which
/// callers read as "no inline spelling, keep it block". `render` is invoked as
/// `render(writer, args...)`, so pass the emit function and its trailing args:
///
///   width.rendered(writeInline, .{ ast, id })  // measures writeInline(w, ast, id)
///
/// The scratch buffer only feeds the discarding drain; `fullCount()` tallies
/// every byte regardless of its size, so a small fixed buffer measures values of
/// any length.
pub fn rendered(comptime render: anytype, args: anytype) ?usize {
    var buf: [64]u8 = undefined;
    var disc = std.Io.Writer.Discarding.init(&buf);
    @call(.auto, render, .{&disc.writer} ++ args) catch return null;
    return std.math.cast(usize, disc.fullCount());
}
