const yaml = @This();
const Document = @import("../document.zig");
const AST = @import("../ast.zig");

pub const Parser = @import("parser.zig");
pub const Tokenizer = @import("tokenizer.zig");
pub const Printer = @import("printer.zig");
pub const Type = enum {
    v1_2_2,
    // TODO: earlier versions of YAML spec?
};

pub const Language = struct {
    pub const Type = yaml.Type;
    pub const Parser = yaml.Parser;
    pub const default_type: yaml.Type = .v1_2_2;
    pub fn parse(parser: *yaml.Parser, input: []const u8, format: yaml.Type) !Document {
        return yaml.Parser.parse(parser.allocator, input, format);
    }
    pub const print = Printer.print;
    pub const printNode = Printer.printNode;
};
