const std = @import("std");
const Io = std.Io;

const bookmatter = @import("bookmatter");

const log = std.log.scoped(.main);
const arg_log = std.log.scoped(.arg);

const title_string = "\n   BOOKMATTER\n================\n\n";

pub fn main(init: std.process.Init) !void {
	// This is appropriate for anything that lives as long as the process.
	const arena: std.mem.Allocator = init.arena.allocator();

	// Get io
	const io = init.io;

	// Get stderr writer
	var stderr_buffer: [1024]u8 = undefined;
	var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
	const stderr_writer = &stderr_file_writer.interface;

	// Get terminal
	const term: Io.Terminal = .{
			.writer = stderr_writer,
			.mode = Io.Terminal.Mode.escape_codes,
	};

	// Accessing command line arguments:
	const args = try init.minimal.args.toSlice(arena);
	var argv: u16 = 0;
	for (args) |arg| {
		arg_log.debug("{s}", .{arg});

		// Check first argument to see if it is a --flag
		if (argv == 1 and (std.mem.find(u8, arg, "--") == null)) {
		  // Get current working directory
			var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
			const cwd_path = try std.process.currentPath(io, &cwd_buf);
			const cwd = cwd_buf[0..cwd_path];
			std.log.debug("opening {s} in {s}", .{arg, cwd});

			// Open directory (scope to files in this directory)
			const dir = try std.Io.Dir.cwd().openDir(io, cwd, .{});
			defer dir.close(io);

			// Open file, handle if it doesn't exist
			const file = dir.openFile(io, arg, .{}) catch |err| switch (err) {
				error.FileNotFound => {
					std.log.err("Oops! {s} does not exist.", .{arg});
					continue;
				},
				else => return err,
			};
			defer file.close(io);

			// Get file reader
			var read_buffer: [4096]u8 = undefined;
			var file_reader = file.reader(io, &read_buffer);
			// Stream file contents
			_ = file_reader.interface.streamRemaining(stderr_writer) catch |err| switch (err)  {
			  error.ReadFailed => return file_reader.err.?,
				else => return err,
			};
			try stderr_writer.flush();
		}
		// Check for --help on any arg number
		if (std.mem.eql(u8, arg, "--help")) {
				try print(term, title_string);
		}
		argv += 1;
}

// Now check stdin


}

fn print_rainbow(term: Io.Terminal, str: []const u8) !void {
	const colors = [_]Io.Terminal.Color{ .green, .blue, .cyan };

	const view = try std.unicode.Utf8View.init(str);
	var iter = view.iterator();

	var i: usize = 0;
	while (iter.nextCodepoint()) |codepoint| {
			const color = colors[i % colors.len];
			try Io.Terminal.setColor(term, color);
			try term.writer.print("{u}", .{codepoint});
			try Io.Terminal.setColor(term, Io.Terminal.Color.reset);
			i += 1;
	}
	try term.writer.flush();
}

fn print(term: Io.Terminal, str: []const u8) !void {
	const view = try std.unicode.Utf8View.init(str);
	var iter = view.iterator();
	while (iter.nextCodepoint()) |codepoint| {
			try term.writer.print("{u}", .{codepoint});
	}
	try term.writer.flush();
}

fn get_file() !Io.File {

}