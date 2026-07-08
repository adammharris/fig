//! By convention, root.zig is the root source file when making a package.
const build_options = @import("build_options");
pub const Language = @import("languages/language.zig");
// TODO: Language.detect(file: []const u8);

pub const Editor = @import("editor.zig").Editor;
pub const Document = @import("document.zig");
pub const AST = @import("ast/ast.zig");
pub const Embed = @import("embed.zig");
pub const Lossless = @import("lossless.zig");
/// Serialization diagnostics: report what a cross-format conversion would lose.
pub const Diagnostics = @import("diagnostics.zig");
/// Shared parse-diagnostic rendering (byte-offset → line/col, the
/// `file:line:col: label: message` report, the language-agnostic `Rendered`
/// shape). Each language keeps its own error/warning codes and teaching
/// messages; only the offset/rendering machinery is shared — see the module
/// doc comment.
pub const ParseDiagnostic = @import("parse_diagnostic.zig");
/// The canonical form: the AST's own 1:1, total, bijective text encoding — the
/// comparison oracle and lossless serialization.
pub const Canonical = @import("canonical/canonical.zig");
/// Deprecated alias for `Canonical`; kept so existing Zig consumers (the Diaryx
/// git dep) keep building. Prefer `Canonical`.
pub const Native = Canonical;
/// The fig authoring dialect: the human-facing, hand-writable surface over the
/// same AST. Reader + `fig fmt` printer; see src/languages/fig/DESIGN.md.
pub const Fig = @import("languages/fig/fig.zig");

/// Reflection-based deserialization into native Zig types (à la `std.json`).
pub const deserialize = @import("deserialize.zig");

test {
    // Each language module's own `test {}` block pulls in its submodules' tests,
    // so root only imports the module entry points. Build-option-gated
    // conformance suites stay enumerated below.
    _ = @import("languages/json/json.zig");
    _ = @import("languages/yaml/yaml.zig");
    _ = @import("languages/toml/toml.zig");
    _ = @import("languages/zon/zon.zig");
    _ = @import("languages/xml/xml.zig");
    _ = @import("languages/fig/fig.zig");
    _ = @import("languages/ini/ini.zig");
    _ = @import("languages/dotenv/dotenv.zig");
    _ = @import("languages/properties/properties.zig");
    _ = @import("languages/shared/flat_map.zig");
    _ = @import("editor.zig");
    _ = @import("embed.zig");
    _ = @import("lossless.zig");
    _ = @import("diagnostics.zig");
    _ = @import("parse_diagnostic.zig");
    _ = @import("canonical/canonical.zig");
    _ = @import("deserialize.zig");
    _ = @import("c_api.zig");
    _ = @import("util/util.zig");
    if (build_options.json_conformance) {
        _ = @import("languages/json/conformance.zig");
    }
    if (build_options.json5_conformance) {
        _ = @import("languages/json/json5_conformance.zig");
    }
    if (build_options.yaml_conformance) {
        _ = @import("languages/yaml/conformance.zig");
        _ = @import("languages/yaml/conformance_1_1.zig");
    }
    if (build_options.toml_conformance) {
        _ = @import("languages/toml/conformance.zig");
    }
    if (build_options.xml_conformance) {
        _ = @import("languages/xml/conformance.zig");
    }
}
