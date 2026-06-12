//! By convention, root.zig is the root source file when making a package.
const build_options = @import("build_options");
pub const Language = @import("language.zig");
// TODO: Language.detect(file: []const u8);

pub const Editor = @import("editor.zig").Editor;
pub const Document = @import("document.zig");
pub const AST = @import("ast.zig");
pub const Embed = @import("embed.zig");

test {
    _ = @import("json/tokenizer.zig");
    _ = @import("json/parser.zig");
    _ = @import("json/printer.zig");
    _ = @import("yaml/tokenizer.zig");
    _ = @import("yaml/parser.zig");
    _ = @import("yaml/printer.zig");
    _ = @import("yaml/materialize.zig");
    _ = @import("toml/tokenizer.zig");
    _ = @import("toml/parser.zig");
    _ = @import("toml/printer.zig");
    _ = @import("zon/parser.zig");
    _ = @import("zon/printer.zig");
    _ = @import("editor.zig");
    _ = @import("embed.zig");
    _ = @import("c_api.zig");
    if (build_options.json_conformance) {
        _ = @import("json/conformance.zig");
    }
    if (build_options.yaml_conformance) {
        _ = @import("yaml/conformance.zig");
    }
    if (build_options.toml_conformance) {
        _ = @import("toml/conformance.zig");
    }
}