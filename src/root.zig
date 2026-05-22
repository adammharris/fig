//! By convention, root.zig is the root source file when making a package.
const std = @import("std");

pub const Language = @import("language.zig");
// TODO: Language.detect(file: []const u8);

pub const Editor = @import("editor.zig").Editor;
pub const Document = @import("document.zig");

test {
    _ = @import("json/tokenizer.zig");
    _ = @import("json/parser.zig");
    _ = @import("yaml/tokenizer.zig");
    _ = @import("yaml/parser.zig");
    _ = @import("editor.zig");
}
