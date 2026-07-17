//! The inputs every build helper in `build/` shares, bundled so each `add`
//! entry point takes one `Context` instead of re-threading the same five
//! parameters. Built once in `build.zig` after the target/optimize/strip
//! triple is resolved and the single `build_options` module is created, then
//! handed to `artifacts`, `tools`, `checks` and `tests` in turn.
//!
//! This is a "struct file": the file's top-level *is* the struct, so callers
//! write `const Context = @import("Context.zig");` and take a `ctx: Context`.

const std = @import("std");
const Options = @import("Options.zig");

/// The build graph everything hangs off of.
b: *std.Build,
/// The target selected from `-Dtarget` (or the host default). `.result` gives
/// the resolved `std.Target` for `.cpu.arch`/`.abi` queries.
target: std.Build.ResolvedTarget,
/// The optimize mode from `-Doptimize` (or the default).
optimize: std.builtin.OptimizeMode,
/// Whether to strip debug info (`-Dstrip`, defaulting to on for ReleaseSmall).
strip: bool,
/// The one `build_options` module instance, shared by every artifact. Built
/// once because `addOptions` per-module would generate a fresh module from the
/// same generated file, which Zig rejects ("file belongs to two modules").
options_mod: *std.Build.Module,
/// The package-identity numbers (core/abi/cli versions + epoch), sourced from
/// `build.zig`. Carried here because more than one stage needs them: `tests`
/// rebuilds a second `build_options` for the conformance run, and `checks`
/// embeds the version into the abi/semver tool args.
ver: Options.Versions,
