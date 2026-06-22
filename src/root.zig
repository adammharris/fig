//! By convention, root.zig is the root source file when making a package.
const build_options = @import("build_options");
pub const Language = @import("language.zig");
// TODO: Language.detect(file: []const u8);

pub const Editor = @import("editor.zig").Editor;
pub const Document = @import("document.zig");
pub const AST = @import("ast.zig");
pub const Embed = @import("embed.zig");
pub const Lossless = @import("lossless.zig");
/// Serialization diagnostics: report what a cross-format conversion would lose.
pub const Diagnostics = @import("diagnostics.zig");
/// The native "fig" format: the AST's own 1:1 canonical text encoding.
pub const Native = @import("native/native.zig");

/// Reflection-based deserialization into native Zig types (à la `std.json`).
pub const deserialize = @import("deserialize.zig");

test {
    // Each language module's own `test {}` block pulls in its submodules' tests,
    // so root only imports the module entry points. Build-option-gated
    // conformance suites stay enumerated below.
    _ = @import("json/json.zig");
    _ = @import("yaml/yaml.zig");
    _ = @import("toml/toml.zig");
    _ = @import("zon/zon.zig");
    _ = @import("xml/xml.zig");
    _ = @import("editor.zig");
    _ = @import("embed.zig");
    _ = @import("lossless.zig");
    _ = @import("diagnostics.zig");
    _ = @import("native/native.zig");
    _ = @import("deserialize.zig");
    _ = @import("c_api.zig");
    _ = @import("util/util.zig");
    if (build_options.json_conformance) {
        _ = @import("json/conformance.zig");
    }
    if (build_options.json5_conformance) {
        _ = @import("json/json5_conformance.zig");
    }
    if (build_options.yaml_conformance) {
        _ = @import("yaml/conformance.zig");
    }
    if (build_options.toml_conformance) {
        _ = @import("toml/conformance.zig");
    }
    if (build_options.xml_conformance) {
        _ = @import("xml/conformance.zig");
    }
}
