//! Main entrypoint for `fig` CLI
//! Design:
//! fig <file> <action> [action options] [--flags]

const std = @import("std");
const Io = std.Io;
const fig = @import("fig");

const log = std.log.scoped(.main);
const arg_log = std.log.scoped(.arg);

const title_string = "\n=========\n   FIG\n=========\n\n";
const help_string =
\\Usage: fig <file> <action> [action options] --[flags]
\\Possible actions:
\\  print: prints file contents to stdout
\\  edit: edits part of file (not yet implemented)
\\
;
var current_file: []const u8 = "";

/// Currently, `fig` CLI only supports up to 10MB files.
const max_size = 10 * 1024 * 1024; // 10 MB limit

const CliAction = enum {
  print, // default
  edit,
  // TODO: more actions
};

const CliConfig = struct {
    file_path: ?[]const u8 = null,
    action: CliAction = .print,
    show_help: bool = false,
};

pub fn main(init: std.process.Init) !void {
  // Respected environment variables
  const NO_COLOR = init.environ_map.contains("NO_COLOR");
  const CLICOLOR_FORCE = init.environ_map.contains("CLICOLOR_FORCE");

  // Setting up arena allocator, io, terminal/stderr writer
	const arena: std.mem.Allocator = init.arena.allocator();
	const io = init.io;
	const stderr_color_mode = try Io.Terminal.Mode.detect(io, Io.File.stderr(), NO_COLOR, CLICOLOR_FORCE);
	const stdout_color_mode = try Io.Terminal.Mode.detect(io, Io.File.stdout(), NO_COLOR, CLICOLOR_FORCE);
	var stdout_buf: [512]u8 = undefined;
	var stderr_buf: [512]u8 = undefined;
	var stdout = Io.File.stdout().writer(io, &stdout_buf);
	var stderr = Io.File.stdout().writer(io, &stderr_buf);
	const stderr_terminal = std.Io.Terminal{ .writer = &stderr.interface, .mode = stderr_color_mode };
	var stdout_terminal = std.Io.Terminal{ .writer = &stdout.interface, .mode = stdout_color_mode };

	// Accessing command line arguments:
	const args = try init.minimal.args.toSlice(arena);

	// CLI config structs
	var config = CliConfig{};

	for (args, 0..args.len) |arg, i| {
		arg_log.debug("`{s}`", .{arg});
		if (i == 0) continue;

		// Check argument to see if it is a --flag
		if (std.mem.startsWith(u8, arg, "--")) {
		  if (std.mem.eql(u8, arg, "--help")) config.show_help = true;
			continue;
		}

		// Get a file for argument 1
		if (config.file_path == null) {
      config.file_path = arg;
      continue;
    }

		// Handle action
		if (config.action == .print) {
      if (std.mem.eql(u8, arg, "print")) {
        config.action = .print;
      } else if (std.mem.eql(u8, arg, "edit")) {
        config.action = .edit;
      } else {
        log.err("Unknown action: {s}", .{arg});
        return; //error.UnknownAction
      }
      continue;
    }
	}

	// Now, act on config
	if (config.show_help) {
	// TODO: if config.action, show help for action
	  try print(stderr_terminal, title_string);
		try print(stderr_terminal, help_string);
		return;
	}

	// Get input file descriptor
	var input: Io.File = undefined;
	var is_stdin = false;
	if (config.file_path) |fp| {
	  if (std.mem.eql(u8, fp, "-")) {
			input = Io.File.stdin();
			is_stdin = true;
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
      input = dir.openFile(io, fp, .{}) catch |err| switch (err) {
        error.FileNotFound => {
          log.err("Oops! {s} does not exist.", .{fp});
          return;
        },
        else => return err,
      };
		}
	} else {
	  log.err("No file provided.", .{});
		return;
	}
	defer if (!is_stdin) input.close(io);

	switch (config.action) {
  	.print => {
      // Get file reader
      var read_buffer: [4096]u8 = undefined;
      var file_reader = input.reader(io, &read_buffer);
      // Stream file contents
      _ = file_reader.interface.streamRemaining(stdout_terminal.writer) catch |err| switch (err)  {
        error.ReadFailed => return file_reader.err.?,
        else => return err,
      };
      try stdout_terminal.writer.flush();
    },
    .edit => {
      try print(stderr_terminal, "Edits not supported yet!\n");
    }
	}
}

fn print(term: Io.Terminal, str: []const u8) !void {
	const view = try std.unicode.Utf8View.init(str);
	var iter = view.iterator();
	while (iter.nextCodepoint()) |codepoint| {
			try term.writer.print("{u}", .{codepoint});
	}
	try term.writer.flush();
}