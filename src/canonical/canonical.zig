//! The canonical form: a total, 1:1 text encoding of the AST.
//!
//! (Formerly "native". This is the AST's own oracle serialization, NOT the
//! human-facing `fig` authoring dialect — that is a separate, ergonomic surface
//! over the same AST, specified in DESIGN.md and living under `src/fig_format/`.)
//!
//! It is a bijection with `ast.zig`'s `Node.Kind` plus the YAML reference layer,
//! so any document round-trips through it unchanged. Two roles:
//!   * default/debug representation (`Printer.print`), available without any
//!     format-specific codec;
//!   * comparison oracle: serialize two documents to native text and compare.
//!
//! Unlike JSON, it can represent every AST variant (int/float distinction,
//! extended scalars, non-string keys, anchors/tags/aliases), so test fixtures
//! that previously borrowed the JSON parser as an AST-literal syntax can use
//! `Parser.parseAbstract` instead — letting JSON *reading* become optional.

pub const Printer = @import("printer.zig");
pub const Parser = @import("parser.zig");

/// Parse native text into an owned AST (free with `ast.deinit()`).
pub const parseAbstract = Parser.parseAbstract;
/// Parse native text into a Document (free with `doc.deinit(allocator)`).
pub const parse = Parser.parse;
/// Print an AST as native text (trailing newline, flushes).
pub const print = Printer.print;
/// Print a subtree (no trailing newline, no flush).
pub const printNode = Printer.printNode;

test {
    _ = Printer;
    _ = Parser;
}
