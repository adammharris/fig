const toml = @This();
const AST = @import("../ast/ast.zig");
const Document = @import("../document.zig");

pub const Parser = @import("parser.zig");
pub const Tokenizer = @import("tokenizer.zig");
pub const Printer = @import("printer.zig");

pub const Type = enum {
    /// TOML 1.0.0 (stable, finalized).
    TOML_1_0,
    /// TOML 1.1.0 (draft): newlines + trailing commas in inline tables,
    /// seconds-optional times, `\e` and `\xHH` string escapes.
    TOML_1_1,
};

pub const Language = struct {
    pub const Type = toml.Type;
    pub const Parser = toml.Parser;
    pub const default_type: toml.Type = .TOML_1_1;
    pub fn parse(parser: *toml.Parser, input: []const u8, format: toml.Type) !Document {
        return toml.Parser.parse(parser.allocator, input, format);
    }
    pub const print = Printer.print;
    pub const printNode = Printer.printNode;
};

// Test discovery for the TOML module: importing `toml.zig` (from root.zig) pulls
// in every TOML submodule's tests, so the module owns its own test surface rather
// than root.zig enumerating each file. `editor_helper.zig` holds the TOML editor
// tests; conformance is gated by a build option and stays in root.zig.
test {
    _ = @import("tokenizer.zig");
    _ = @import("parser.zig");
    _ = @import("printer.zig");
    _ = @import("editor_helper.zig");
}
