//! Main entrypoint for `fig` CLI
//! Design:
//! fig <action> [action options] [--flags]
//!
//! This file is deliberately thin: process/terminal setup, `std.log` routing,
//! and `parseConfig`'s error-to-help mapping, then a dispatch switch straight
//! into `actions.zig`. Everything else (arg parsing, format/embed detection,
//! parse dispatch, in-place editing, reformat/convert, diagnostic rendering)
//! lives in its own sibling module — see each file's own doc comment.

const std = @import("std");
const fig = @import("fig");
const build_options = @import("build_options");
const Io = std.Io;

const types = @import("types.zig");
const help = @import("help.zig");
const args_mod = @import("args.zig");
const actions = @import("actions.zig");

// CLI-only sibling modules pulled in only through `actions.zig`/`args.zig`'s
// imports; referenced again in the `test {}` block at the bottom of this file
// so every leaf module's tests are guaranteed to land in the `exe_tests`
// binary regardless of Zig's lazy per-decl analysis.
const gron = @import("gron.zig");
const diff = @import("diff.zig");
const fileio = @import("fileio.zig");
const diag_report = @import("diag_report.zig");
const parse_dispatch = @import("parse_dispatch.zig");
const edit_ops = @import("edit_ops.zig");
const reformat = @import("reformat.zig");

const Help = help.Help;
const ArgError = types.ArgError;

// Logging for the CLI binary. `std.log`'s default handler (`std.log.defaultLog`)
// writes to stderr through `std.Options.debug_io` — a statically initialized,
// globally-shared `Io.Threaded` singleton, deliberately independent from the
// application's own `Io` instance (see the doc comment on `debug_io`). That
// means it opens its own positional `Io.File.Writer` over fd 2, separate from
// `stderr_terminal` below, each tracking its own `pos` from 0. When stderr is a
// regular file (redirected to disk rather than a tty), both writers do
// `pwrite`-style positional writes, so whichever one flushes second overwrites
// bytes the other already wrote instead of appending after them — corrupting
// the output. (Interleaving on a tty is harmless because tty writes are
// non-positional appends; the corruption only bites on redirection, which is
// why this was easy to miss.) Route `std.log` through `stderr_terminal` once
// `main` has constructed it, so there is only ever one `Io.File.Writer`/one
// `pos` counter over stderr.
pub const std_options: std.Options = .{ .logFn = logFn };

/// Set by `main` right after `stderr_terminal` is constructed. `null` before
/// that point (there are no `std.log` call sites that early), in which case we
/// fall back to the stdlib default.
var g_log_terminal: ?*Io.Terminal = null;

fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const t = g_log_terminal orelse return std.log.defaultLog(level, scope, format, args);
    std.log.defaultLogFileTerminal(level, scope, format, args, t.*) catch return;
    // `std.log.defaultLog` flushes before returning (its `unlockStderr` does
    // so implicitly); match that so a log line right before `process.exit`
    // isn't lost sitting in `stderr_terminal`'s buffer.
    t.writer.flush() catch {};
}

// The core library's version — the same numbers `fig_version` exposes over
// the C ABI — sourced from `build.zig`'s `version` (parsed from
// build.zig.zon). Independent of `cli_version` below; see
// docs/VERSIONING.md's "Independent versioning" section for why the CLI and
// the core it embeds move on separate SemVer tracks.
const core_version = std.fmt.comptimePrint("{d}.{d}.{d}", .{
    build_options.version_major,
    build_options.version_minor,
    build_options.version_patch,
});

// The CLI binary's OWN version (`cli_version` in build.zig) — its
// compatibility contract is flags/defaults/exit codes, not the library API,
// so it moves independently of `core_version` above (only ever floored by
// it — see `zig build version-floor`).
const cli_version = std.fmt.comptimePrint("{d}.{d}.{d}", .{
    build_options.cli_version_major,
    build_options.cli_version_minor,
    build_options.cli_version_patch,
});

// The current marketing epoch (`epoch` in build.zig) — purely cosmetic, no
// compatibility meaning; see `fig version`'s output.
const epoch = build_options.epoch;

pub fn main(init: std.process.Init) !void {
    // Respected environment variables
    const NO_COLOR = init.environ_map.contains("NO_COLOR");
    const CLICOLOR_FORCE = init.environ_map.contains("CLICOLOR_FORCE");

    // Setting up arena allocator, io, terminal/stderr writer
    const io = init.io;
    const stderr_color_mode = try Io.Terminal.Mode.detect(io, Io.File.stderr(), NO_COLOR, CLICOLOR_FORCE);
    const stdout_color_mode = try Io.Terminal.Mode.detect(io, Io.File.stdout(), NO_COLOR, CLICOLOR_FORCE);
    var stdout_buf: [512]u8 = undefined;
    var stderr_buf: [512]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &stdout_buf);
    var stderr = Io.File.stderr().writer(io, &stderr_buf);
    var stderr_terminal = std.Io.Terminal{ .writer = &stderr.interface, .mode = stderr_color_mode };
    var stdout_terminal = std.Io.Terminal{ .writer = &stdout.interface, .mode = stdout_color_mode };
    // From here on, route `std.log` through this same writer (see `logFn`) so
    // it can't clobber `stderr_terminal`'s bytes when stderr is redirected.
    g_log_terminal = &stderr_terminal;

    // Accessing command line arguments:
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();

    const config = args_mod.parseConfig(init.arena.allocator(), &args) catch |err| switch (err) {
        ArgError.UnsupportedFileFormat => {
            try stderr_terminal.writer.print("Try using `--input <format>` to manually specify a format.\n", .{});
            comptime var supported_formats: []const u8 = "";
            inline for (@typeInfo(types.Format).@"enum".fields) |field|
                supported_formats = supported_formats ++ std.fmt.comptimePrint("\n- {s}", .{field.name});
            try stderr_terminal.writer.print("Supported formats:{s}\n", .{supported_formats});
            try stderr_terminal.writer.flush();
            std.process.exit(2);
        },
        ArgError.MissingEditArgument => {
            try Help.edit(&stderr_terminal, "fig");
            std.process.exit(2);
        },
        ArgError.MissingSetArgument => {
            try Help.set(&stderr_terminal, "fig");
            std.process.exit(2);
        },
        ArgError.MissingInsertArgument => {
            try Help.insert(&stderr_terminal, "fig");
            std.process.exit(2);
        },
        ArgError.MissingDeleteArgument => {
            try Help.delete(&stderr_terminal, "fig");
            std.process.exit(2);
        },
        ArgError.MissingGetArgument => {
            try Help.get(&stderr_terminal, "fig");
            std.process.exit(2);
        },
        ArgError.MissingCommentArgument => {
            try Help.comment(&stderr_terminal, "fig");
            std.process.exit(2);
        },
        ArgError.MissingCheckArgument => {
            try Help.check(&stderr_terminal, "fig");
            std.process.exit(2);
        },
        ArgError.MissingFmtArgument => {
            try Help.fmt(&stderr_terminal, "fig");
            std.process.exit(2);
        },
        ArgError.MissingConvertArgument => {
            try Help.convert(&stderr_terminal, "fig");
            std.process.exit(2);
        },
        else => return err,
    };

    const a = init.arena.allocator();

    // Now, act on config
    return switch (config.action) {
        .help => actions.runHelp(&stderr_terminal, config.binary_name),
        .version => actions.runVersion(&stdout_terminal, cli_version, core_version, epoch),
        .edit => actions.runEdit(a, io, &stdout_terminal, config.binary_name, config.options.edit),
        .set => actions.runSet(a, io, &stdout_terminal, &stderr_terminal, config.binary_name, config.options.set),
        .insert => actions.runInsert(a, io, &stdout_terminal, &stderr_terminal, config.binary_name, config.options.insert),
        .delete => actions.runDelete(a, io, &stdout_terminal, &stderr_terminal, config.binary_name, config.options.delete),
        .get => actions.runGet(a, io, &stdout_terminal, &stderr_terminal, config.binary_name, config.options.get),
        .comment => actions.runComment(a, io, &stdout_terminal, &stderr_terminal, config.binary_name, config.options.comment),
        .check => actions.runCheck(a, io, &stdout_terminal, &stderr_terminal, config.binary_name, config.options.check),
        .fmt => actions.runFmt(a, io, &stdout_terminal, &stderr_terminal, config.binary_name, config.options.fmt),
        .convert => actions.runConvert(a, io, &stdout_terminal, &stderr_terminal, config.binary_name, config.options.convert),
    };
}

// Pull every CLI-only leaf module's tests into the exe test binary. `gron`/
// `diff` are CLI-only formats that live here in the binary, never in the
// `fig` library, so `root.zig`'s test graph never reaches them; the rest are
// this binary's own split-out modules.
test {
    _ = types;
    _ = help;
    _ = fileio;
    _ = diag_report;
    _ = parse_dispatch;
    _ = edit_ops;
    _ = reformat;
    _ = args_mod;
    _ = actions;
    _ = gron;
    _ = diff;
}
