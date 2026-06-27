//! Dev tool: cross-artifact version floor. fig versions each shipped artifact on
//! its OWN SemVer track —
//!
//!   * the Zig core + C ABI   -> `.version` in build.zig.zon
//!   * the Rust crate         -> `[workspace.package] version` in bindings/rust/Cargo.toml
//!   * the npm package        -> `"version"` in bindings/typescript/package.json
//!
//! so a binding-only change (a Rust convenience method, a TS typing fix) can bump
//! that binding without forcing a core release, and vice versa. The one invariant
//! tying the tracks together: a binding's version must be >= the core version it
//! embeds. Both bindings compile/bundle the core from this same tree, so the core
//! they embed is exactly build.zig.zon's `.version`. Enforcing `binding >= core`
//! guarantees two things:
//!
//!   * a BREAKING core bump (major) pulls every binding's major up with it — a
//!     binding can't keep an older-looking number while shipping a newer core;
//!   * reading a binding's version is never an underestimate of the core inside.
//!
//! It does NOT require equality: a binding may run ahead of the core for
//! binding-only releases. This replaces the old hand-mirrored "all four versions
//! must match" rule. Per-language SemVer tools (zig build semver-check for the C
//! ABI, cargo-semver-checks for the Rust API) still guard each surface's own
//! compatibility; this only enforces the floor between them.
//!
//! It ALSO enforces one Rust-internal consistency rule: the `fig-macros` version
//! pin in `[workspace.dependencies]` must equal the workspace package version.
//! `fig` and `fig-macros` are one release unit on the Rust track, and the pin is a
//! hand-written mirror of the workspace version, so a bump that misses it would
//! publish a `fig` that depends on the wrong `fig-macros`. (Unlike the core floor,
//! this is exact equality — it's a pin, not a floor.)
//!
//! Usage (driven by build.zig): version-floor <build.zig.zon> <Cargo.toml> <package.json>

const std = @import("std");

const max_file = 1 * 1024 * 1024;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next(); // argv0
    const zon_path = args.next() orelse return error.MissingArgument;
    const cargo_path = args.next() orelse return error.MissingArgument;
    const pkg_path = args.next() orelse return error.MissingArgument;

    const cwd = std.Io.Dir.cwd();
    const zon = try cwd.readFileAlloc(io, zon_path, arena, .limited(max_file));
    const cargo = try cwd.readFileAlloc(io, cargo_path, arena, .limited(max_file));
    const pkg = try cwd.readFileAlloc(io, pkg_path, arena, .limited(max_file));

    const core_str = zonVersion(zon) orelse return fail("build.zig.zon", "no `.version` field");
    const rust_str = cargoWorkspaceVersion(cargo) orelse return fail("Cargo.toml", "no `[workspace.package] version`");
    const ts_str = jsonVersion(pkg) orelse return fail("package.json", "no `\"version\"` field");

    const macros_pin = cargoFigMacrosPin(cargo) orelse
        return fail("Cargo.toml", "no `fig-macros` version pin in [workspace.dependencies]");

    const core = std.SemanticVersion.parse(core_str) catch return fail("build.zig.zon", "unparseable `.version`");
    const rust = std.SemanticVersion.parse(rust_str) catch return fail("Cargo.toml", "unparseable version");
    const ts = std.SemanticVersion.parse(ts_str) catch return fail("package.json", "unparseable version");

    std.debug.print("version-floor: core (build.zig.zon) {s}\n", .{core_str});
    std.debug.print("  rust crate (Cargo.toml)      {s}  (fig-macros pin {s})\n", .{ rust_str, macros_pin });
    std.debug.print("  npm package (package.json)   {s}\n", .{ts_str});

    var failed = false;
    if (rust.order(core) == .lt) {
        std.debug.print("  FAIL: rust crate {s} < core {s} (a binding must be >= the core it embeds)\n", .{ rust_str, core_str });
        failed = true;
    }
    if (ts.order(core) == .lt) {
        std.debug.print("  FAIL: npm package {s} < core {s} (a binding must be >= the core it embeds)\n", .{ ts_str, core_str });
        failed = true;
    }
    if (!std.mem.eql(u8, macros_pin, rust_str)) {
        std.debug.print("  FAIL: fig-macros pin {s} != workspace version {s} (the pin must track the Rust crate version)\n", .{ macros_pin, rust_str });
        failed = true;
    }

    if (failed) std.process.exit(1);
    std.debug.print("version-floor: OK (bindings >= embedded core; fig-macros pin matches)\n", .{});
}

fn fail(file: []const u8, why: []const u8) noreturn {
    std.debug.print("version-floor: FAIL: {s}: {s}\n", .{ file, why });
    std.process.exit(1);
}

/// The string after `.version = "..."` in a build.zig.zon.
fn zonVersion(text: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, text, ".version") orelse return null;
    return quotedAfter(text, at + ".version".len);
}

/// The version under `[workspace.package]` in a Cargo.toml: the first
/// `version = "..."` line at or after that section header (so the resolver line
/// and the `[workspace.dependencies]` pins are never mistaken for it).
fn cargoWorkspaceVersion(text: []const u8) ?[]const u8 {
    const sec = std.mem.indexOf(u8, text, "[workspace.package]") orelse return null;
    var lines = std.mem.splitScalar(u8, text[sec..], '\n');
    _ = lines.next(); // the header line itself
    while (lines.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "[")) return null; // next section, not found
        if (std.mem.startsWith(u8, trimmed, "version")) {
            const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
            return quotedAfter(trimmed, eq + 1);
        }
    }
    return null;
}

/// The `version = "..."` inside the `fig-macros = { ... }` dependency entry of a
/// Cargo.toml. Finds the `fig-macros` *key* (the next non-space char after the
/// token is `=`, which excludes the `members = [..., "fig-macros"]` array entry
/// and the `path = "fig-macros"` value), then the `version` inside its table.
fn cargoFigMacrosPin(text: []const u8) ?[]const u8 {
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
        return quotedAfter(text[0..line_end], veq + 1);
    }
    return null;
}

fn skipSpace(text: []const u8, idx: usize) usize {
    var i = idx;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    return i;
}

/// The string after the first `"version"` key in a package.json.
fn jsonVersion(text: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, text, "\"version\"") orelse return null;
    const colon = std.mem.indexOfScalarPos(u8, text, at + "\"version\"".len, ':') orelse return null;
    return quotedAfter(text, colon + 1);
}

/// The contents of the next double-quoted string at or after `idx`.
fn quotedAfter(text: []const u8, idx: usize) ?[]const u8 {
    const open = std.mem.indexOfScalarPos(u8, text, idx, '"') orelse return null;
    const close = std.mem.indexOfScalarPos(u8, text, open + 1, '"') orelse return null;
    return text[open + 1 .. close];
}
