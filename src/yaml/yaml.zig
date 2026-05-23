const yaml = @This();
const Document = @import("../document.zig");
const AST = @import("../ast.zig");

pub const Parser = @import("parser.zig");
pub const Tokenizer = @import("tokenizer.zig");
pub const Printer = @import("printer.zig");

pub const Language = struct {
    pub const Type = enum {
        v1_2_2,
        // TODO: earlier versions of YAML spec?
    };
    pub const Parser = yaml.Parser;
    pub const default_type: Type = .v1_2_2;
    pub fn parse(parser: *yaml.Parser, input: []const u8, format: Type) !Document {
        return yaml.Parser.parse(parser.allocator, input, format);
    }
    pub fn print(writer: *@import("std").Io.Writer, document: *const AST) !void {
        return yaml.Printer.print(writer, document);
    }
};
