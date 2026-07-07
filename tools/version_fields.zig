//! Shared locators for the version fields scattered across fig's manifests.
//!
//! Both `version-floor.zig` (read-only checker) and `version-set.zig` (the
//! bumper) need to find the exact same handful of version strings — the core
//! `.version` in build.zig.zon, `cli_version` in build.zig, the Rust workspace
//! version and its `fig-macros` pin in Cargo.toml, and the `"version"` in the
//! two package.json files. Rather than hand-parse ZON/TOML/JSON (fig can't
//! bootstrap-parse its own build manifests), each field has a tiny dedicated
//! scanner built on `std.mem` string search.
//!
//! Every locator comes in two forms:
//!   * `<field>Range(text)` -> the byte `Range` of the *value* (between the
//!     quotes), so a setter can splice a new value in place without disturbing
//!     surrounding bytes;
//!   * `<field>(text)` -> that same range as a slice, for a reader.
//!
//! Keeping these in one file means the checker and the setter can never drift
//! on where a field lives or how it's recognized.

const std = @import("std");

/// A half-open `[start, end)` byte range into the text a locator was given.
pub const Range = struct { start: usize, end: usize };

/// The `[start,end)` of the contents of the next double-quoted string at or
/// after `idx` (excludes the surrounding quotes).
pub fn quotedRangeAfter(text: []const u8, idx: usize) ?Range {
    const open = std.mem.indexOfScalarPos(u8, text, idx, '"') orelse return null;
    const close = std.mem.indexOfScalarPos(u8, text, open + 1, '"') orelse return null;
    return .{ .start = open + 1, .end = close };
}

/// The contents of the next double-quoted string at or after `idx`.
pub fn quotedAfter(text: []const u8, idx: usize) ?[]const u8 {
    const r = quotedRangeAfter(text, idx) orelse return null;
    return text[r.start..r.end];
}

/// Range of the string after `.version = "..."` in a build.zig.zon.
pub fn zonVersionRange(text: []const u8) ?Range {
    const at = std.mem.indexOf(u8, text, ".version") orelse return null;
    return quotedRangeAfter(text, at + ".version".len);
}
pub fn zonVersion(text: []const u8) ?[]const u8 {
    const r = zonVersionRange(text) orelse return null;
    return text[r.start..r.end];
}

/// Range of the quoted version string passed to `std.SemanticVersion.parse(...)`
/// in `build.zig`'s `const cli_version = std.SemanticVersion.parse("X.Y.Z") ...`
/// declaration. Anchors on the `cli_version` identifier (not just `parse(`,
/// since `version` above is parsed the same way) then takes the first quoted
/// string after it.
pub fn buildZigCliVersionRange(text: []const u8) ?Range {
    const at = std.mem.indexOf(u8, text, "cli_version") orelse return null;
    return quotedRangeAfter(text, at + "cli_version".len);
}
pub fn buildZigCliVersion(text: []const u8) ?[]const u8 {
    const r = buildZigCliVersionRange(text) orelse return null;
    return text[r.start..r.end];
}

/// Range of the version under `[workspace.package]` in a Cargo.toml: the first
/// `version = "..."` line at or after that section header (so the resolver line
/// and the `[workspace.dependencies]` pins are never mistaken for it).
pub fn cargoWorkspaceVersionRange(text: []const u8) ?Range {
    const sec = std.mem.indexOf(u8, text, "[workspace.package]") orelse return null;
    // Start scanning at the line after the section header.
    var i = (std.mem.indexOfScalarPos(u8, text, sec, '\n') orelse return null) + 1;
    while (i < text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
        const line = text[i..nl];
        const lead = line.len - std.mem.trimStart(u8, line, " \t").len;
        const trimmed = line[lead..];
        if (std.mem.startsWith(u8, trimmed, "[")) return null; // next section, not found
        if (std.mem.startsWith(u8, trimmed, "version")) {
            if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq_rel| {
                return quotedRangeAfter(text, i + lead + eq_rel + 1);
            }
        }
        i = nl + 1;
    }
    return null;
}
pub fn cargoWorkspaceVersion(text: []const u8) ?[]const u8 {
    const r = cargoWorkspaceVersionRange(text) orelse return null;
    return text[r.start..r.end];
}

/// Range of the `version = "..."` inside the `fig-macros = { ... }` dependency
/// entry of a Cargo.toml. Finds the `fig-macros` *key* (the next non-space char
/// after the token is `=`, which excludes the `members = [..., "fig-macros"]`
/// array entry and the `path = "fig-macros"` value), then the `version` inside
/// its table, scoped to that line.
pub fn cargoFigMacrosPinRange(text: []const u8) ?Range {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, "fig-macros")) |pos| {
        const after = pos + "fig-macros".len;
        i = after;
        const eq = skipSpace(text, after);
        if (eq >= text.len or text[eq] != '=') continue; // not the key — keep scanning
        // Scope the search to this entry: up to the end of its line / inline table.
        const line_end = std.mem.indexOfScalarPos(u8, text, eq, '\n') orelse text.len;
        const ver = std.mem.indexOfPos(u8, text[0..line_end], eq, "version") orelse continue;
        const veq = std.mem.indexOfScalarPos(u8, text[0..line_end], ver, '=') orelse continue;
        return quotedRangeAfter(text[0..line_end], veq + 1);
    }
    return null;
}
pub fn cargoFigMacrosPin(text: []const u8) ?[]const u8 {
    const r = cargoFigMacrosPinRange(text) orelse return null;
    return text[r.start..r.end];
}

fn skipSpace(text: []const u8, idx: usize) usize {
    var i = idx;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    return i;
}

/// Range of the string after the first `"version"` key in a package.json.
pub fn jsonVersionRange(text: []const u8) ?Range {
    const at = std.mem.indexOf(u8, text, "\"version\"") orelse return null;
    const colon = std.mem.indexOfScalarPos(u8, text, at + "\"version\"".len, ':') orelse return null;
    return quotedRangeAfter(text, colon + 1);
}
pub fn jsonVersion(text: []const u8) ?[]const u8 {
    const r = jsonVersionRange(text) orelse return null;
    return text[r.start..r.end];
}
