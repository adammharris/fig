const yaml = @This();
const Document = @import("../document.zig");
const AST = @import("../ast/ast.zig");

pub const Parser = @import("parser.zig");
pub const Tokenizer = @import("tokenizer.zig");
pub const Printer = @import("printer.zig");
pub const Materialize = @import("materialize.zig");
pub const Type = enum {
    v1_2_2,
    /// YAML 1.1 (2005). Differs from 1.2 almost entirely in *scalar type
    /// resolution* (the tag repository at yaml.org/type): `yes/no/on/off/y/n`
    /// booleans, leading-zero octal (`0777`) + binary (`0b…`) + sexagesimal
    /// (`190:20:30`) ints, `_` digit separators, mandatory-sign float exponents,
    /// and `!!timestamp` auto-resolution. Structure/syntax is unchanged.
    /// Resolution differences are pinned by the spec fixtures in
    /// `testdata/yaml-1.1/` (see `conformance_1_1.zig`); the resolver itself is
    /// still being filled in, so selecting this currently parses like 1.2.
    v1_1,
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
    /// Collapse the reference layer (aliases/merges/tags/anchors) into a core AST
    /// before handing it to a non-YAML printer. Optional Language decl: callers
    /// gate on `@hasDecl(Lang, "materialize")`.
    pub const materialize = Materialize.materialize;
    pub const TagMode = Materialize.TagMode;
};

// Test discovery: importing `yaml.zig` (from root.zig) pulls in every YAML
// submodule's tests, so the module owns its own test surface. The conformance
// suite is build-option-gated and stays in root.zig.
test {
    _ = @import("tokenizer.zig");
    _ = @import("parser.zig");
    _ = @import("printer.zig");
    _ = @import("materialize.zig");
    _ = @import("editor_helper.zig");
}
