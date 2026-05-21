//! Main entrypoint for `fig` CLI
//! Design:
//! fig <action> [action options] [--flags]

const std = @import("std");
const fig = @import("fig");
const Io = std.Io;

const log = std.log.scoped(.main);
const arg_log = std.log.scoped(.arg);

const title_string = "\n=========\n   FIG\n=========\n\n";
const version = "0.0.0-alpha";

/// Currently, `fig` CLI only supports up to 10MB files.
const max_size = Io.Limit.limited(10 * 1024 * 1024);

const CliAction = enum {
  help, // default
  @"--help", @"-h",
  version,
  @"--version", @"-v",
  print, p,
  edit, e,
  // TODO: more actions
};

const CliActionOptions = union(CliAction) {
  help, @"--help", @"-h",
  version, @"--version", @"-v",
  print: struct {
    file: []const u8,
    requested_help: bool = false,
  }, p,
  edit: struct {
    file: []const u8,
    path: []fig.Document.PathSegment,
    replacement: []const u8,
    requested_help: bool = false,
  }, e,
};

const CliConfig = struct {
  action: CliAction = .help,
  options: CliActionOptions = .help,
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
        \\  print: prints generic representation of file to stdout
        \\  edit: edits part of file (not yet implemented)
        \\
        \\For information on action options, pass --help or -h
        \\to the action you would like to learn about.
        \\
      , .{binary_name});
    try term.writer.flush();
  }

  fn print(term: *Io.Terminal, binary_name: []const u8) !void {
    try term.writer.print(
      \\Usage: {s} print <file>
      \\  Formatting options planned in the future.
      \\
    , .{binary_name});
    try term.writer.flush();
  }

  fn edit(term: *Io.Terminal, binary_name: []const u8) !void {
    try term.writer.print(
      \\Usage: {s} edit <file> <path> <replacement>
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

	// CLI config structs
	var config = CliConfig{};

	config.binary_name = args.next() orelse "fig";

	if (args.next()) |arg| {
    config.action = std.meta.stringToEnum(CliAction, arg) orelse c: {
      arg_log.err("Action not recognized.", .{});
      break :c .help;
    };
	} else {
	  arg_log.err("Action not provided.", .{});
			config.action = .help;
	}

	// Now, act on config
	return switch (config.action) {
	  .help, .@"--help", .@"-h" => {
  	  try print(&stderr_terminal, title_string);
  		try Help.general(&stderr_terminal, config.binary_name);
		},
		.version, .@"--version", .@"-v" => {
  		try stdout_terminal.writer.print("{s}\n", .{version});
      try stdout_terminal.writer.flush();
		},
		.print, .p => {
		  if (args.next()) |file_path| {
				const input = try getInput(io, file_path);
        // TODO: don't close if stdin (also in edit branch)
  			defer input.close(io);
        if (std.mem.endsWith(u8, file_path, ".json")) {
          try printJsonDocument(init.arena.allocator(), io, &stdout_terminal, input);
        } else {
          log.err("Unsupported document type.\n", .{});
          std.process.exit(2);
        }
			} else {
	      log.err("No file provided.\n", .{});
        try Help.print(&stderr_terminal, config.binary_name);
        std.process.exit(2);
			}
    },
    .edit, .e => {
      if (args.next()) |file_path| {
        const input = try getInput(io, file_path);
        defer input.close(io);
        // Get path and replacement from CLI args
        var path: []fig.Document.PathSegment = undefined;
        var replacement: []const u8 = undefined;
        if (args.next()) |p| {
          path = try parsePath(init.arena.allocator(), p);
        } else {
          log.err("No path provided.\n", .{});
          try Help.edit(&stderr_terminal, config.binary_name);
          std.process.exit(2);
        }
        if (args.next()) |r| replacement = r else {
          log.err("No replacement provided.\n", .{});
          try Help.edit(&stderr_terminal, config.binary_name);
          std.process.exit(2);
        }
        if (std.mem.endsWith(u8, file_path, ".json")) {
          try editJsonDocument(init.arena.allocator(), io, &stdout_terminal, input, path, replacement);
        } else log.err("Unsupported document type.\n", .{});
      } else {
        log.err("No file provided.\n", .{});
        try Help.edit(&stderr_terminal, config.binary_name);
        std.process.exit(2);
      }
    },
	};
}

fn print(term: *Io.Terminal, str: []const u8) !void {
	const view = try std.unicode.Utf8View.init(str);
	var iter = view.iterator();
	while (iter.nextCodepoint()) |codepoint| {
			try term.writer.print("{u}", .{codepoint});
	}
	try term.writer.flush();
}

fn printJsonDocument(allocator: std.mem.Allocator, io: Io, term: *Io.Terminal, file: Io.File) !void {
  // Get file reader
  var read_buffer: [4096]u8 = undefined;
  var file_reader = file.reader(io, &read_buffer);
  // Stream file contents
  const content = try file_reader.interface.allocRemaining(allocator, max_size);
  defer allocator.free(content);

  const doc = try fig.Language.JSON.Parser.parse(allocator, content, .JSON);
  try doc.dump(term.writer);
}

fn editJsonDocument(
  allocator: std.mem.Allocator,
  io: Io,
  term: *Io.Terminal,
  file: Io.File,
  path: []fig.Document.PathSegment,
  replacement: []const u8
) !void {
  // Get file reader
  var read_buffer: [4096]u8 = undefined;
  var file_reader = file.reader(io, &read_buffer);
  // Stream file contents
  const content = try file_reader.interface.allocRemaining(allocator, max_size);
  defer allocator.free(content);

  var editor: fig.Editor(fig.Language.JSON) = .{.allocator = allocator};
  try editor.init(content);
  defer editor.deinit();
  try editor.replaceValAtPath(path, replacement);
  // Now write to term
  try print(term, editor.source.items);
}

fn getInput(io: Io, file_path: ?[]const u8) !Io.File {
  // Get input file descriptor
	if (file_path) |fp| {
	  if (std.mem.eql(u8, fp, "-")) {
      return Io.File.stdin();
		} else {
			 // Get current working directory
       var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
       const cwd_path = try std.process.currentPath(io, &cwd_buf);
       const cwd = cwd_buf[0..cwd_path];
       log.debug("opening {s} in {s}", .{fp, cwd});

       // Open directory (scope to files in this directory)
       const dir = try std.Io.Dir.cwd().openDir(io, cwd, .{});
       defer dir.close(io);

       // Open file, handle if it doesn't exist
       return dir.openFile(io, fp, .{});
		}
	} else {
	  log.err("No file provided.", .{});
		return error.MissingArgument;
	}
}

fn parsePath(allocator: std.mem.Allocator, path: []const u8) ![]fig.Document.PathSegment {
  var path_in_progress: std.ArrayList(fig.Document.PathSegment) = .empty;
  var i: usize = 0;
  while (i < path.len) {
    switch (path[i]) {
      '.' => {
        // Dot is a separator. The next loop iteration parses the key.
        i += 1;
      },
      '[' => {
        const start = i + 1;
        i = start;
        while (i < path.len and path[i] != ']') : (i += 1) {}
        if (i >= path.len or i == start) return error.InvalidPath;

        log.debug("number: {s}", .{path[start..i]});
        try path_in_progress.append(allocator,
          .{ .index = try std.fmt.parseInt(usize, path[start..i], 10)}
        );
        i += 1;
      },
      else => {
        const start = i;
        while (i < path.len and path[i] != '.' and path[i] != '[') : (i += 1) {}
        if (i == start) return error.InvalidPath;

        const key = path[start..i];
        const json_key = if (key.len >= 2 and key[0] == '"' and key[key.len - 1] == '"')
          key
        else
          try std.fmt.allocPrint(allocator, "\"{s}\"", .{key});

        log.debug("key: {s}", .{json_key});
        try path_in_progress.append(allocator, .{ .key = json_key });
      },
    }
  }
  return path_in_progress.toOwnedSlice(allocator);
}
