const json = @This();
const AST = @import("../../ast/ast.zig");
const Document = @import("../../document.zig");

pub const Parser = @import("parser.zig");
pub const Tokenizer = @import("tokenizer.zig");
pub const Printer = @import("printer.zig");
pub const Type = enum {
    JSON,
    JSONC,
    JSON5,
};

pub const Language = struct {
    pub const Type = json.Type;
    pub const Parser = json.Parser;
    pub const default_type: json.Type = .JSON;
    pub fn parse(parser: *json.Parser, input: []const u8, format: json.Type) !Document {
        return json.Parser.parse(parser.allocator, input, format);
    }
    pub const print = Printer.print;
    pub const printNode = Printer.printNode;
};

// Test discovery: importing `json.zig` (from root.zig) pulls in every JSON
// submodule's tests, so the module owns its own test surface. `editor_helper.zig`
// holds the JSON/JSON5 editor tests; conformance suites are build-option-gated
// and stay in root.zig.
test {
    _ = @import("tokenizer.zig");
    _ = @import("parser.zig");
    _ = @import("printer.zig");
    _ = @import("editor_helper.zig");
}
