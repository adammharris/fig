//! Main entrypoint for `fig` CLI
//! Design:
//! fig <action> [action options] [--flags]

const std = @import("std");
const fig = @import("fig");
const Io = std.Io;

const title_string = "\n=========\n   FIG\n=========\n\n";
const version = "0.0.0-alpha";

/// Currently, `fig` CLI only supports up to 10MB files.
const max_size = Io.Limit.limited(10 * 1024 * 1024);
const Format = enum { json, jsonc, yaml, yml };

const CliAction = enum {
    help,
    version,
    edit,
    get,
};

const CliActionOptions = union(CliAction) {
    help: struct {
        requested_help: bool = false,
    },
    version: struct {},
    edit: struct {
        file: []const u8,
        path: []fig.AST.PathSegment,
        replacement: []const u8,
        key: bool = false,
        requested_help: bool = false,
        format: Format,
    },
    get: struct {
        file: []const u8,
        path: ?[]fig.AST.PathSegment = null,
        from: Format,
        to: Format,
        requested_help: bool = false,
    },
};

const CliConfig = struct {
    action: CliAction = .help,
    options: CliActionOptions = .{ .help = .{} },
    binary_name: []const u8 = "fig",
    requested_help: bool = false,
};

const Help = struct {
    fn general(term: *Io.Terminal, binary_name: []const u8) !void {
        try term.writer.print(
            \\Usage:
            \\  {s} <action> [action options] --[flags]
            \\Possible actions:
            \\  help: prints this text (default action)
            \\  version: prints version number
            \\  edit: edits part of file
            \\  get: print a file or a specific part of a file to stdout
            \\
            \\For information on action options, pass --help or -h
            \\to the action you would like to learn about.
            \\
        , .{binary_name});
        try term.writer.flush();
    }

    fn edit(term: *Io.Terminal, binary_name: []const u8) !void {
        try term.writer.print(
            \\Usage: {s} edit [--key] <file> <path> <replacement>
            \\  --key: edit the object key at path instead of the value
            \\  path format: dot syntax for keys, bracket syntax for indices
            \\    example: school.class[0].student[3]
            \\
        , .{binary_name});
        try term.writer.flush();
    }

    fn get(term: *Io.Terminal, binary_name: []const u8) !void {
        try term.writer.print(
            \\Usage: {s} get [--input json|yaml] [--output json|yaml] <file> [path]
            \\  -i, --input: input format of file (defaults to matching the file extension)
            \\  -o, --output:   output format (defaults to the input format)
            \\  path format: dot syntax for keys, bracket syntax for indices
            \\    example: school.class[0].student[3]
            \\
        , .{binary_name});
        try term.writer.flush();
    }
};

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
    var stderr = Io.File.stdout().writer(io, &stderr_buf);
    var stderr_terminal = std.Io.Terminal{ .writer = &stderr.interface, .mode = stderr_color_mode };
    var stdout_terminal = std.Io.Terminal{ .writer = &stdout.interface, .mode = stdout_color_mode };

    // Accessing command line arguments:
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();

    const config = parseConfig(init.arena.allocator(), &args) catch |err| switch (err) {
        ArgError.UnsupportedFileFormat => {
            try stderr_terminal.writer.print("Try using `--input <format>` to manually specify a format.\n", .{});
            comptime var supported_formats: []const u8 = "";
            inline for (@typeInfo(Format).@"enum".fields) |field|
                supported_formats = supported_formats ++ std.fmt.comptimePrint("\n- {s}", .{field.name});
            try stderr_terminal.writer.print("Supported formats:{s}\n", .{supported_formats});
            try stderr_terminal.writer.flush();
            std.process.exit(2);
        },
        ArgError.MissingEditArgument => {
            try Help.edit(&stderr_terminal, "fig");
            std.process.exit(2);
        },
        ArgError.MissingGetArgument => {
            try Help.get(&stderr_terminal, "fig");
            std.process.exit(2);
        },
        else => return err,
    };

    // Now, act on config
    return switch (config.action) {
        .help => {
            try stderr_terminal.writer.print(title_string, .{});
            try Help.general(&stderr_terminal, config.binary_name);
        },
        .version => {
            try stdout_terminal.writer.print("{s}\n", .{version});
            try stdout_terminal.writer.flush();
        },
        .edit => {
            const opts = config.options.edit;
            if (opts.requested_help) {
                try Help.edit(&stdout_terminal, config.binary_name);
                return;
            }
            const input = try getInput(io, opts.file, .read_write);
            defer if (!std.mem.eql(u8, opts.file, "-")) input.close(io);

            switch (opts.format) {
                .json, .jsonc => {
                    const replacement = try std.fmt.allocPrint(init.arena.allocator(), "\"{s}\"", .{opts.replacement});
                    try editDocument(fig.Language.JSON, init.arena.allocator(), io, input, opts.path, replacement, opts.key);
                },
                .yaml, .yml => {
                    try editDocument(fig.Language.YAML, init.arena.allocator(), io, input, opts.path, opts.replacement, opts.key);
                },
            }
        },
        .get => {
            const opts = config.options.get;
            if (opts.requested_help) {
                try Help.get(&stdout_terminal, config.binary_name);
                return;
            }
            const input = try getInput(io, opts.file, .read_only);
            defer if (!std.mem.eql(u8, opts.file, "-")) input.close(io);

            const doc = switch (opts.from) {
                .json, .jsonc => try parseFromFile(fig.Language.JSON, init.arena.allocator(), io, input),
                .yaml, .yml => try parseFromFile(fig.Language.YAML, init.arena.allocator(), io, input),
            };

            const node_id = if (opts.path) |p| (try doc.ast.getValByPath(p)).id else doc.ast.root;

            switch (opts.to) {
                .json, .jsonc => {
                    if (opts.path == null) {
                        try fig.Language.JSON.print(stdout_terminal.writer, &doc.ast);
                    } else {
                        try fig.Language.JSON.printNode(stdout_terminal.writer, &doc.ast, node_id, 0);
                    }
                },
                .yaml, .yml => {
                    if (opts.path == null) {
                        try fig.Language.YAML.print(stdout_terminal.writer, &doc.ast);
                    } else {
                        try fig.Language.YAML.printNode(stdout_terminal.writer, &doc.ast, node_id, 0);
                    }
                },
            }
            try stdout_terminal.writer.flush();
        },
    };
}

fn parseFromFile(comptime Lang: type, allocator: std.mem.Allocator, io: Io, file: Io.File) !fig.Document {
    // Get file reader
    var read_buffer: [4096]u8 = undefined;
    var file_reader = file.reader(io, &read_buffer);
    // Stream file contents
    const content = try file_reader.interface.allocRemaining(allocator, max_size);
    return try Lang.Parser.parse(allocator, content, Lang.default_type);
}

fn editDocument(
    comptime Lang: type,
    allocator: std.mem.Allocator,
    io: Io,
    file: Io.File,
    path: []fig.AST.PathSegment,
    replacement: []const u8,
    edit_key: bool,
) !void {
    // Get file reader
    var read_buffer: [4096]u8 = undefined;
    var file_reader = file.reader(io, &read_buffer);
    // Stream file contents
    const content = try file_reader.interface.allocRemaining(allocator, max_size);
    defer allocator.free(content);

    var editor: fig.Editor(Lang) = .{ .allocator = allocator };
    try editor.init(content);
    defer editor.deinit();
    if (edit_key) {
        try editor.replaceKeyAtPath(path, replacement);
    } else {
        try editor.replaceValAtPath(path, replacement);
    }
    try file.writePositionalAll(io, editor.source.items, 0);
    try file.setLength(io, editor.source.items.len);
}

fn getInput(io: Io, file_path: ?[]const u8, mode: std.Io.Dir.OpenFileOptions.Mode) !Io.File {
    const log = std.log.scoped(.getInput);
    // Get input file descriptor
    if (file_path) |fp| {
        if (std.mem.eql(u8, fp, "-")) {
            return Io.File.stdin();
        } else {
            // Get current working directory
            var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const cwd_path = try std.process.currentPath(io, &cwd_buf);
            const cwd = cwd_buf[0..cwd_path];
            log.debug("opening {s} in {s}", .{ fp, cwd });

            // Open directory (scope to files in this directory)
            const dir = try std.Io.Dir.cwd().openDir(io, cwd, .{});
            defer dir.close(io);

            // Open file, handle if it doesn't exist
            return dir.openFile(io, fp, .{ .mode = mode });
        }
    } else {
        log.err("No file provided.", .{});
        return error.MissingArgument;
    }
}

fn parsePath(allocator: std.mem.Allocator, path: []const u8) ![]fig.AST.PathSegment {
    const log = std.log.scoped(.parsePath);
    var path_in_progress: std.ArrayList(fig.AST.PathSegment) = .empty;
    var i: usize = 0;
    while (i < path.len) {
        switch (path[i]) {
            '.' => {
                // Dot is a separator. Else branch parses the key.
                i += 1;
            },
            '[' => {
                // Skip open bracket
                const start = i + 1;
                i = start;
                // Loop until end or close bracket
                while (i < path.len and path[i] != ']') : (i += 1) {}
                if (i >= path.len or i == start) return error.InvalidPath;

                // Add number to path_in_progress
                log.debug("number: {s}", .{path[start..i]});
                try path_in_progress.append(allocator, .{ .index = try std.fmt.parseInt(usize, path[start..i], 10) });
                // Skip close bracket
                i += 1;
            },
            else => {
                const start = i;
                // Loop until a dot or open bracket
                while (i < path.len and path[i] != '.' and path[i] != '[') : (i += 1) {}
                if (i == start) return ArgError.InvalidPath;
                const key = path[start..i];

                log.debug("key: {s}", .{key});
                try path_in_progress.append(allocator, .{ .key = key });
            },
        }
    }
    return path_in_progress.toOwnedSlice(allocator);
}

fn detectLanguageFromFileEnding(file_path: []const u8) !Format {
    const dot = std.mem.findLast(u8, file_path, ".");
    return std.meta.stringToEnum(Format, file_path[(dot orelse 0) + 1..file_path.len]) orelse {
        const recognized_file_format = if (dot) |d| file_path[d..file_path.len] else "(none)";
        std.log.scoped(.detectLanguage).err("File `{s}` had ending: {s}", .{ file_path, recognized_file_format });
        return ArgError.UnsupportedFileFormat;
    };
}

const ArgError = error { UnsupportedFileFormat, MissingEditArgument, MissingGetArgument, OutOfMemory, Overflow, InvalidCharacter, InvalidPath };

fn parseConfig(allocator: std.mem.Allocator, args: anytype) ArgError!CliConfig {
    const log = std.log.scoped(.parseConfig);
    var config = CliConfig{};
    config.binary_name = args.next() orelse "fig";

    const action_str = args.next() orelse {
        config.action = .help;
        config.options = .{ .help = .{} };
        return config;
    };

    if (std.mem.eql(u8, action_str, "help") or std.mem.eql(u8, action_str, "--help") or std.mem.eql(u8, action_str, "-h")) {
        config.action = .help;
        config.options = .{ .help = .{ .requested_help = true } };
    } else if (std.mem.eql(u8, action_str, "version") or std.mem.eql(u8, action_str, "--version") or std.mem.eql(u8, action_str, "-v")) {
        config.action = .version;
        config.options = .{ .version = .{} };
    } else if (std.mem.eql(u8, action_str, "edit") or std.mem.eql(u8, action_str, "e")) {
        config.action = .edit;

        var edit_key = false;
        var file_path_arg = args.next();
        if (file_path_arg) |arg| {
            if (std.mem.eql(u8, arg, "--key")) {
                edit_key = true;
                file_path_arg = args.next();
            }
        }
        const file_path = file_path_arg orelse {
            log.err("No file provided.\n", .{});
            return ArgError.MissingEditArgument;
        };

        const requested_help = std.mem.eql(u8, file_path, "--help") or std.mem.eql(u8, file_path, "-h");

        var path: []fig.AST.PathSegment = &.{};
        var replacement: []const u8 = "";
        if (!requested_help) {
            const path_str = args.next() orelse {
                log.err("No path provided.\n", .{});
                return ArgError.MissingEditArgument;
            };
            path = try parsePath(allocator, path_str);

            replacement = args.next() orelse {
                log.err("No replacement provided.\n", .{});
                return ArgError.MissingEditArgument;
            };
        }

        config.options = .{ .edit = .{
            .file = file_path,
            .path = path,
            .replacement = replacement,
            .key = edit_key,
            .requested_help = requested_help,
            .format = try detectLanguageFromFileEnding(file_path),
        } };
    } else if (std.mem.eql(u8, action_str, "get") or std.mem.eql(u8, action_str, "g")) {
        config.action = .get;

        var input_override: ?Format = null;
        var output_override: ?Format = null;
        var positionals: std.ArrayList([]const u8) = .empty;
        defer positionals.deinit(allocator);

        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--input") or std.mem.eql(u8, arg, "-i")) {
                const fmt = args.next() orelse {
                    log.err("Missing format value after {s}\n", .{arg});
                    return ArgError.MissingGetArgument;
                };
                if (std.mem.eql(u8, fmt, "json")) {
                    input_override = .json;
                } else if (std.mem.eql(u8, fmt, "yaml") or std.mem.eql(u8, fmt, "yml")) {
                    input_override = .yaml;
                } else {
                    log.err("Unsupported format: {s}\n", .{fmt});
                    return ArgError.UnsupportedFileFormat;
                }
            } else if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
                const fmt = args.next() orelse {
                    log.err("Missing format value after {s}\n", .{arg});
                    return ArgError.MissingGetArgument;
                };
                if (std.mem.eql(u8, fmt, "json")) {
                    output_override = .json;
                } else if (std.mem.eql(u8, fmt, "yaml") or std.mem.eql(u8, fmt, "yml")) {
                    output_override = .yaml;
                } else {
                    log.err("Unsupported format: {s}\n", .{fmt});
                    return ArgError.UnsupportedFileFormat;
                }
            } else {
                try positionals.append(allocator, arg);
            }
        }

        const file_path = if (positionals.items.len > 0) positionals.items[0] else {
            log.err("No file provided.\n", .{});
            return ArgError.MissingGetArgument;
        };

        const requested_help = std.mem.eql(u8, file_path, "--help") or std.mem.eql(u8, file_path, "-h");

        var path: ?[]fig.AST.PathSegment = null;
        if (!requested_help and positionals.items.len > 1) {
            path = try parsePath(allocator, positionals.items[1]);
        }

        const detected_input = if (!requested_help and input_override == null)
            try detectLanguageFromFileEnding(file_path)
        else
            null;
        const input_format = input_override orelse detected_input orelse .json;

        config.options = .{ .get = .{
            .file = file_path,
            .path = path,
            .from = input_format,
            .to = output_override orelse input_format,
            .requested_help = requested_help,
        } };
    } else {
        log.err("Action not recognized: {s}", .{action_str});
        config.action = .help;
        config.options = .{ .help = .{ .requested_help = true } };
    }

    return config;
}
