//! Dev tool: cross-artifact version floor. fig versions each shipped artifact on
//! its OWN SemVer track —
//!
//!   * the Zig core + C ABI   -> `.version` in build.zig.zon
//!   * the CLI binary         -> `cli_version` in build.zig
//!   * the Rust crate         -> `[workspace.package] version` in bindings/rust/Cargo.toml
//!   * the npm package        -> `"version"` in bindings/typescript/package.json
//!   * the fig-wasi npm pkg   -> `"version"` in bindings/wasi/package.json
//!
//! so a binding-only (or CLI-only) change (a Rust convenience method, a TS typing
//! fix, a CLI flag redesign) can bump that artifact without forcing a core
//! release, and vice versa. The one invariant tying the tracks together: every
//! artifact's version must be >= the core version it embeds. All of them
//! compile/bundle the core from this same tree, so the core they embed is
//! exactly build.zig.zon's `.version`. Enforcing `artifact >= core` guarantees
//! two things:
//!
//!   * a BREAKING core bump (major) pulls every artifact's major up with it — an
//!     artifact can't keep an older-looking number while shipping a newer core;
//!   * reading an artifact's version is never an underestimate of the core inside.
//!
//! It does NOT require equality: an artifact may run ahead of the core for
//! artifact-only releases (this is exactly what a CLI-only flag-breaking change
//! looks like — see docs/VERSIONING.md). Per-language SemVer tools (zig build
//! semver-check for the C ABI, cargo-semver-checks for the Rust API) still guard
//! each surface's own compatibility; this only enforces the floor between them.
//!
//! Two EXACT-equality pins, not floors (both hand-written mirrors that must
//! track their target, so a bump that misses one would publish something
//! inconsistent):
//!
//!   * `fig-macros`'s version pin in `[workspace.dependencies]` of Cargo.toml
//!     must equal the workspace package version — `fig`/`fig-macros` are one
//!     release unit on the Rust track;
//!   * fig-wasi's package.json version must equal `cli_version` — it's a
//!     repackaging of the CLI itself (same actions as the native binary, just
//!     over WASI/npx), not an independent binding, and per docs/VERSIONING.md
//!     the release tag IS `cli_version`, so this also keeps fig-wasi's
//!     published version in lockstep with the tag.
//!
//! Usage (driven by build.zig):
//!   version-floor <build.zig.zon> <build.zig> <Cargo.toml> <package.json> <wasi-package.json>

const std = @import("std");
const fields = @import("version_fields.zig");

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
    const build_zig_path = args.next() orelse return error.MissingArgument;
    const cargo_path = args.next() orelse return error.MissingArgument;
    const pkg_path = args.next() orelse return error.MissingArgument;
    const wasi_pkg_path = args.next() orelse return error.MissingArgument;

    const cwd = std.Io.Dir.cwd();
    const zon = try cwd.readFileAlloc(io, zon_path, arena, .limited(max_file));
    const build_zig = try cwd.readFileAlloc(io, build_zig_path, arena, .limited(max_file));
    const cargo = try cwd.readFileAlloc(io, cargo_path, arena, .limited(max_file));
    const pkg = try cwd.readFileAlloc(io, pkg_path, arena, .limited(max_file));
    const wasi_pkg = try cwd.readFileAlloc(io, wasi_pkg_path, arena, .limited(max_file));

    const core_str = fields.zonVersion(zon) orelse return fail("build.zig.zon", "no `.version` field");
    const cli_str = fields.buildZigCliVersion(build_zig) orelse return fail("build.zig", "no `cli_version` field");
    const rust_str = fields.cargoWorkspaceVersion(cargo) orelse return fail("Cargo.toml", "no `[workspace.package] version`");
    const ts_str = fields.jsonVersion(pkg) orelse return fail("package.json", "no `\"version\"` field");
    const wasi_str = fields.jsonVersion(wasi_pkg) orelse return fail("bindings/wasi/package.json", "no `\"version\"` field");

    const macros_pin = fields.cargoFigMacrosPin(cargo) orelse
        return fail("Cargo.toml", "no `fig-macros` version pin in [workspace.dependencies]");

    const core = std.SemanticVersion.parse(core_str) catch return fail("build.zig.zon", "unparseable `.version`");
    const cli = std.SemanticVersion.parse(cli_str) catch return fail("build.zig", "unparseable `cli_version`");
    const rust = std.SemanticVersion.parse(rust_str) catch return fail("Cargo.toml", "unparseable version");
    const ts = std.SemanticVersion.parse(ts_str) catch return fail("package.json", "unparseable version");
    const wasi = std.SemanticVersion.parse(wasi_str) catch return fail("bindings/wasi/package.json", "unparseable version");

    std.debug.print("version-floor: core (build.zig.zon) {s}\n", .{core_str});
    std.debug.print("  cli (build.zig cli_version)  {s}\n", .{cli_str});
    std.debug.print("  rust crate (Cargo.toml)      {s}  (fig-macros pin {s})\n", .{ rust_str, macros_pin });
    std.debug.print("  npm package (package.json)   {s}\n", .{ts_str});
    std.debug.print("  fig-wasi (wasi/package.json) {s}\n", .{wasi_str});

    var failed = false;
    if (cli.order(core) == .lt) {
        std.debug.print("  FAIL: cli {s} < core {s} (an artifact must be >= the core it embeds)\n", .{ cli_str, core_str });
        failed = true;
    }
    if (rust.order(core) == .lt) {
        std.debug.print("  FAIL: rust crate {s} < core {s} (an artifact must be >= the core it embeds)\n", .{ rust_str, core_str });
        failed = true;
    }
    if (ts.order(core) == .lt) {
        std.debug.print("  FAIL: npm package {s} < core {s} (an artifact must be >= the core it embeds)\n", .{ ts_str, core_str });
        failed = true;
    }
    if (!std.mem.eql(u8, macros_pin, rust_str)) {
        std.debug.print("  FAIL: fig-macros pin {s} != workspace version {s} (the pin must track the Rust crate version)\n", .{ macros_pin, rust_str });
        failed = true;
    }
    if (wasi.order(cli) != .eq) {
        std.debug.print("  FAIL: fig-wasi {s} != cli {s} (fig-wasi repackages the CLI, so it must track cli_version exactly)\n", .{ wasi_str, cli_str });
        failed = true;
    }

    if (failed) std.process.exit(1);
    std.debug.print("version-floor: OK (cli/bindings >= embedded core; fig-macros pin matches; fig-wasi tracks cli_version)\n", .{});
}

fn fail(file: []const u8, why: []const u8) noreturn {
    std.debug.print("version-floor: FAIL: {s}: {s}\n", .{ file, why });
    std.process.exit(1);
}
