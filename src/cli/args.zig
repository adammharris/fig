//! Command-line parsing: turns the raw arg iterator into a `CliConfig`
//! (`parseConfig`), plus the small format/path/embed-archetype resolvers that
//! parsing (and later, the action handlers) share.
const std = @import("std");
const fig = @import("fig");

const gron = @import("gron.zig");
const types = @import("types.zig");
const fileio = @import("fileio.zig");

const Format = types.Format;
const CliAction = types.CliAction;
const CliConfig = types.CliConfig;
const ArgError = types.ArgError;
const Detected = types.Detected;
const append_index = types.append_index;
const Io = std.Io;

/// Map a `--input`/`-i` format name to a `Format`. The enum member names cover
/// every accepted token (including `canonical` and `fig`) directly. Returns null
/// for an unknown name so callers can emit a tailored error.
pub fn parseFormatName(name: []const u8) ?Format {
    return std.meta.stringToEnum(Format, name);
}

pub fn parsePath(allocator: std.mem.Allocator, path: []const u8) ![]fig.AST.PathSegment {
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

                // `[-]` and `[$]` are the "end" tokens: `insert` reads the
                // sentinel as "append", and `delete` reads it as "the last
                // item" (`editor.removeSeqItem` special-cases it). Any other
                // caller that walks the path literally (e.g. `get`) just
                // sees an out-of-range index and surfaces NotFound.
                const inner = path[start..i];
                log.debug("number: {s}", .{inner});
                const seg: fig.AST.PathSegment = if (std.mem.eql(u8, inner, "-") or std.mem.eql(u8, inner, "$"))
                    .{ .index = append_index }
                else
                    .{ .index = try std.fmt.parseInt(usize, inner, 10) };
                try path_in_progress.append(allocator, seg);
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

/// Infer the parse strategy from a file's extension, or null when the extension
/// is missing/unrecognized — the caller then falls back to content sniffing
/// (`Language.detect`) rather than failing outright.
pub fn detectLanguageFromFileEnding(file_path: []const u8) ?Detected {
    const dot = std.mem.findLast(u8, file_path, ".");
    const ext = file_path[(dot orelse 0) + 1 .. file_path.len];

    // Markdown conventionally carries an embedded region (frontmatter, or
    // endmatter), but which archetype it is still has to be sniffed from the
    // actual bytes — a `` ```fig ``` ``-fenced or JSON frontmatter block (or a
    // YAML endmatter fence) must not be mistaken for `---` YAML frontmatter
    // just because the file ends in `.md`.
    if (std.mem.eql(u8, ext, "md") or std.mem.eql(u8, ext, "markdown")) {
        return .{ .format = .yaml, .embed_detect = true };
    }

    // `.figl` is the authoring dialect's canonical extension; `.fig` is
    // still accepted for back-compat. (The canonical form deliberately owns
    // no extension; select it with `--input canonical`.)
    if (std.mem.eql(u8, ext, "figl")) return .{ .format = .fig };
    if (std.mem.eql(u8, ext, "fig")) return .{ .format = .fig };

    // A dotenv file is conventionally named exactly `.env` — this function's
    // dot-split (on the LAST `.`) gives that an "extension" of literal `env`,
    // which doesn't match the `Format.dotenv` enum member name the generic
    // `stringToEnum` lookup below relies on. (A multi-suffix variant like
    // `.env.production` isn't recognized here — its last-dot extension is
    // `production` — pass `--input dotenv` explicitly for those.)
    if (std.mem.eql(u8, ext, "env")) return .{ .format = .dotenv };

    const format = std.meta.stringToEnum(Format, ext) orelse return null;
    return .{ .format = format };
}

/// Map a `--embed <archetype>` flag value to its `Embed.Type`. Lets any
/// embed-capable action target a region explicitly — overriding whatever
/// `resolveEmbedType`/`resolveEmbedTypeFromContent` would otherwise sniff —
/// so endmatter and JSON frontmatter are reachable. Returns null for an
/// unknown name.
pub fn embedTypeFromName(name: []const u8) ?fig.Embed.Type {
    if (std.mem.eql(u8, name, "frontmatter") or std.mem.eql(u8, name, "frontmatter-yaml"))
        return .FrontmatterYaml;
    if (std.mem.eql(u8, name, "frontmatter-json")) return .FrontmatterJson;
    if (std.mem.eql(u8, name, "frontmatter-fig")) return .FrontmatterFig;
    if (std.mem.eql(u8, name, "endmatter") or std.mem.eql(u8, name, "endmatter-yaml"))
        return .EndmatterYaml;
    return null;
}

/// The CLI `Format` an embed archetype's content is written in — the `get`
/// action's `--input`/`--output` twin of `Embed.innerFormat`. Lets an explicit
/// `--embed <archetype>` pick the right parser/printer on its own, without
/// also requiring a redundant `--input`/`--output` (or, worse, silently
/// keeping a same-named-extension guess that doesn't match the archetype —
/// e.g. `--embed frontmatter-fig` on a `.md` file, whose extension alone
/// says nothing about which archetype it actually is).
pub fn embedFormat(t: fig.Embed.Type) Format {
    return switch (fig.Embed.innerFormat(t)) {
        .yaml => .yaml,
        .json => .json,
        .fig => .fig,
    };
}

/// Resolve the embed archetype an action should operate on, given
/// already-read `content`. An explicit `embed` (a `--embed` flag, or a format
/// pinned outright some other way) always wins. Otherwise, when the file's
/// extension only implied "there's probably an embedded region here" without
/// saying which archetype (`detect_embed` — today only `.md`/`.markdown`,
/// via `Detected.embed_detect`), sniff the real bytes with `Embed.detect` so
/// a `` ```fig ``` ``-fenced or JSON frontmatter block (or a YAML endmatter
/// fence) isn't silently mistaken for `---` YAML frontmatter. Falls back to
/// the conventional `FrontmatterYaml` default when nothing is found at all —
/// e.g. a brand-new host file with no frontmatter yet — so `set`'s
/// open-or-init still seeds the same archetype it always has. Returns `null`
/// when this isn't an embed operation at all (no override, and the extension
/// implies no embed).
pub fn resolveEmbedTypeFromContent(content: []const u8, embed: ?fig.Embed.Type, detect_embed: bool) ?fig.Embed.Type {
    if (embed) |e| return e;
    if (!detect_embed) return null;
    return fig.Embed.detect(content) orelse .FrontmatterYaml;
}

/// Same as `resolveEmbedTypeFromContent`, but reads `input` itself first, for
/// call sites that haven't already buffered the file's bytes at the point
/// they need to decide. This only performs that read when a sniff is
/// actually needed (`embed == null and detect_embed`) — which today only
/// happens for a real `.md`/`.markdown` path, never stdin (`-`), so the extra
/// positional read is always safe: it's a second read of a regular, seekable
/// file, not a second (and empty) read of a pipe.
pub fn resolveEmbedType(io: Io, allocator: std.mem.Allocator, input: Io.File, embed: ?fig.Embed.Type, detect_embed: bool) !?fig.Embed.Type {
    if (embed) |e| return e;
    if (!detect_embed) return null;
    const content = try fileio.readAll(allocator, io, input);
    defer allocator.free(content);
    return fig.Embed.detect(content) orelse .FrontmatterYaml;
}

pub fn parseConfig(allocator: std.mem.Allocator, args: anytype) ArgError!CliConfig {
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

        // Skip extension detection when the user only asked for help (the
        // "file" is then `--help`, which has no real format). An unrecognized
        // extension is not an error here: `detect = true` defers to content
        // sniffing in the handler.
        const ext = if (requested_help) null else detectLanguageFromFileEnding(file_path);
        config.options = .{ .edit = .{
            .file = file_path,
            .path = path,
            .replacement = replacement,
            .key = edit_key,
            .requested_help = requested_help,
            .format = if (ext) |d| d.format else .json,
            .detect = !requested_help and ext == null,
            .embed = null,
            .detect_embed = if (ext) |d| d.embed_detect else false,
        } };
    } else if (std.mem.eql(u8, action_str, "set") or std.mem.eql(u8, action_str, "s")) {
        config.action = .set;

        // Leading flags in any order: `--seq`, `--embed <archetype>`, `--help`.
        // Positionals follow: file, path, then the value (or, with `--seq`, the
        // sequence items).
        var seq = false;
        var embed_override: ?fig.Embed.Type = null;
        var requested_help = false;
        var positionals: std.ArrayList([]const u8) = .empty;
        defer positionals.deinit(allocator);

        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                requested_help = true;
            } else if (std.mem.eql(u8, arg, "--seq")) {
                seq = true;
            } else if (std.mem.eql(u8, arg, "--embed")) {
                const name = args.next() orelse {
                    log.err("Missing archetype after {s}\n", .{arg});
                    return ArgError.MissingSetArgument;
                };
                embed_override = embedTypeFromName(name) orelse {
                    log.err("Unknown --embed archetype: {s} (frontmatter, frontmatter-json, endmatter)\n", .{name});
                    return ArgError.UnsupportedFileFormat;
                };
            } else {
                try positionals.append(allocator, arg);
            }
        }

        if (requested_help) {
            config.options = .{ .set = .{ .file = "", .path = &.{}, .value = "", .requested_help = true, .format = .json } };
        } else {
            // Need file, path, and at least one value (a scalar, or one or more
            // sequence items with `--seq`).
            if (positionals.items.len < 3) {
                log.err("set needs a file, a path, and a value (e.g. `fig set f.yaml a.b 1`).\n", .{});
                return ArgError.MissingSetArgument;
            }
            const file_path = positionals.items[0];
            const path = try parsePath(allocator, positionals.items[1]);
            const ext = detectLanguageFromFileEnding(file_path);
            const embed = embed_override;
            config.options = .{
                .set = .{
                    .file = file_path,
                    .path = path,
                    .value = if (seq) "" else positionals.items[2],
                    .seq = seq,
                    .values = if (seq) try allocator.dupe([]const u8, positionals.items[2..]) else &.{},
                    .requested_help = false,
                    .format = if (ext) |d| d.format else .json,
                    // Skip content sniffing when targeting an embed (the inner format
                    // is fixed by the archetype) or when the extension resolved it.
                    .detect = ext == null and embed == null,
                    .embed = embed,
                    .detect_embed = embed == null and (if (ext) |d| d.embed_detect else false),
                },
            };
        }
    } else if (std.mem.eql(u8, action_str, "insert") or std.mem.eql(u8, action_str, "i")) {
        config.action = .insert;

        const file_path = args.next() orelse {
            log.err("No file provided.\n", .{});
            return ArgError.MissingInsertArgument;
        };
        const requested_help = std.mem.eql(u8, file_path, "--help") or std.mem.eql(u8, file_path, "-h");

        var path: []fig.AST.PathSegment = &.{};
        var value: []const u8 = "";
        if (!requested_help) {
            const path_str = args.next() orelse {
                log.err("No path provided.\n", .{});
                return ArgError.MissingInsertArgument;
            };
            path = try parsePath(allocator, path_str);

            value = args.next() orelse {
                log.err("No value provided.\n", .{});
                return ArgError.MissingInsertArgument;
            };
        }

        const ext = if (requested_help) null else detectLanguageFromFileEnding(file_path);
        config.options = .{ .insert = .{
            .file = file_path,
            .path = path,
            .value = value,
            .requested_help = requested_help,
            .format = if (ext) |d| d.format else .json,
            .detect = !requested_help and ext == null,
            .embed = null,
            .detect_embed = if (ext) |d| d.embed_detect else false,
        } };
    } else if (std.mem.eql(u8, action_str, "delete") or std.mem.eql(u8, action_str, "d")) {
        config.action = .delete;

        const file_path = args.next() orelse {
            log.err("No file provided.\n", .{});
            return ArgError.MissingDeleteArgument;
        };
        const requested_help = std.mem.eql(u8, file_path, "--help") or std.mem.eql(u8, file_path, "-h");

        var path: []fig.AST.PathSegment = &.{};
        if (!requested_help) {
            const path_str = args.next() orelse {
                log.err("No path provided.\n", .{});
                return ArgError.MissingDeleteArgument;
            };
            path = try parsePath(allocator, path_str);
        }

        const ext = if (requested_help) null else detectLanguageFromFileEnding(file_path);
        config.options = .{ .delete = .{
            .file = file_path,
            .path = path,
            .requested_help = requested_help,
            .format = if (ext) |d| d.format else .json,
            .detect = !requested_help and ext == null,
            .embed = null,
            .detect_embed = if (ext) |d| d.embed_detect else false,
        } };
    } else if (std.mem.eql(u8, action_str, "comment") or std.mem.eql(u8, action_str, "c")) {
        config.action = .comment;

        // Leading flags, in any order: `--inline`, `--delete`, `--get`. Consume
        // them until the first non-flag token (the file).
        var inline_comment = false;
        var delete = false;
        var get = false;
        var file_path_arg = args.next();
        while (file_path_arg) |arg| {
            if (std.mem.eql(u8, arg, "--inline")) {
                inline_comment = true;
            } else if (std.mem.eql(u8, arg, "--delete")) {
                delete = true;
            } else if (std.mem.eql(u8, arg, "--get")) {
                get = true;
            } else break;
            file_path_arg = args.next();
        }
        const file_path = file_path_arg orelse {
            log.err("No file provided.\n", .{});
            return ArgError.MissingCommentArgument;
        };

        const requested_help = std.mem.eql(u8, file_path, "--help") or std.mem.eql(u8, file_path, "-h");

        var path: []fig.AST.PathSegment = &.{};
        var text: []const u8 = "";
        if (!requested_help) {
            const path_str = args.next() orelse {
                log.err("No path provided.\n", .{});
                return ArgError.MissingCommentArgument;
            };
            path = try parsePath(allocator, path_str);

            // Delete/get need no text; add/set requires it.
            if (!delete and !get) {
                text = args.next() orelse {
                    log.err("No comment text provided.\n", .{});
                    return ArgError.MissingCommentArgument;
                };
            }
        }

        const ext = if (requested_help) null else detectLanguageFromFileEnding(file_path);
        config.options = .{ .comment = .{
            .file = file_path,
            .path = path,
            .text = text,
            .inline_comment = inline_comment,
            .delete = delete,
            .get = get,
            .requested_help = requested_help,
            .format = if (ext) |d| d.format else .json,
            .detect = !requested_help and ext == null,
            .embed = null,
            .detect_embed = if (ext) |d| d.embed_detect else false,
        } };
    } else if (std.mem.eql(u8, action_str, "get") or std.mem.eql(u8, action_str, "g")) {
        config.action = .get;

        var input_override: ?Format = null;
        var output_override: ?Format = null;
        var lax_tags = false;
        var lossless = false;
        var quiet = false;
        var strict = false;
        // Explicit `--embed <archetype>` override and `--body` projection.
        var embed_override: ?fig.Embed.Type = null;
        var body = false;
        var serialize: fig.AST.SerializeOptions = .{};
        // gron projection overrides; null means "keep the gron default".
        var gron_root: ?[]const u8 = null;
        var gron_sep: ?[]const u8 = null;
        var gron_term: ?[]const u8 = null;
        var positionals: std.ArrayList([]const u8) = .empty;
        defer positionals.deinit(allocator);

        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--lax-tags")) {
                lax_tags = true;
            } else if (std.mem.eql(u8, arg, "--gron-root")) {
                gron_root = args.next() orelse {
                    log.err("Missing value after {s}\n", .{arg});
                    return ArgError.MissingGetArgument;
                };
            } else if (std.mem.eql(u8, arg, "--gron-sep")) {
                gron_sep = args.next() orelse {
                    log.err("Missing value after {s}\n", .{arg});
                    return ArgError.MissingGetArgument;
                };
            } else if (std.mem.eql(u8, arg, "--gron-term")) {
                // Empty is allowed (drop the terminator entirely).
                gron_term = args.next() orelse {
                    log.err("Missing value after {s}\n", .{arg});
                    return ArgError.MissingGetArgument;
                };
            } else if (std.mem.eql(u8, arg, "--lossless")) {
                lossless = true;
            } else if (std.mem.eql(u8, arg, "--lossy")) {
                lossless = false;
            } else if (std.mem.eql(u8, arg, "--compact")) {
                serialize.pretty = false;
            } else if (std.mem.eql(u8, arg, "--pretty")) {
                serialize.pretty = true;
            } else if (std.mem.eql(u8, arg, "--strip-comments")) {
                serialize.strip_comments = true;
            } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--no-warnings")) {
                quiet = true;
            } else if (std.mem.eql(u8, arg, "--strict")) {
                strict = true;
            } else if (std.mem.eql(u8, arg, "--embed")) {
                const name = args.next() orelse {
                    log.err("Missing archetype after {s}\n", .{arg});
                    return ArgError.MissingGetArgument;
                };
                embed_override = embedTypeFromName(name) orelse {
                    log.err("Unknown --embed archetype: {s} (frontmatter, frontmatter-json, endmatter)\n", .{name});
                    return ArgError.UnsupportedFileFormat;
                };
            } else if (std.mem.eql(u8, arg, "--body")) {
                body = true;
            } else if (std.mem.eql(u8, arg, "--indent")) {
                const n = args.next() orelse {
                    log.err("Missing value after {s}\n", .{arg});
                    return ArgError.MissingGetArgument;
                };
                serialize.indent = std.fmt.parseInt(u8, n, 10) catch {
                    log.err("Invalid --indent value: {s}\n", .{n});
                    return ArgError.MissingGetArgument;
                };
                // fig has no `pretty` gate of its own to read `indent`'s value
                // against (see `SerializeOptions.fig_indent`'s doc comment), so
                // an explicit `--indent` is fig's own on/off signal, independent
                // of the numeric width other formats use it for.
                serialize.fig_indent = true;
            } else if (std.mem.eql(u8, arg, "--width")) {
                const n = args.next() orelse {
                    log.err("Missing value after {s}\n", .{arg});
                    return ArgError.MissingGetArgument;
                };
                serialize.width = std.fmt.parseInt(u16, n, 10) catch {
                    log.err("Invalid --width value: {s}\n", .{n});
                    return ArgError.MissingGetArgument;
                };
            } else if (std.mem.eql(u8, arg, "--input") or std.mem.eql(u8, arg, "-i")) {
                const fmt = args.next() orelse {
                    log.err("Missing format value after {s}\n", .{arg});
                    return ArgError.MissingGetArgument;
                };
                // Delegate to the same enum-driven lookup `check`/`fmt`/`convert`
                // use, so this never again drifts out of sync with `Format` as
                // formats are added (this used to be its own hand-rolled chain
                // of literal comparisons — see git blame — which is exactly how
                // it silently fell behind when ini/dotenv/properties were added).
                input_override = parseFormatName(fmt) orelse {
                    log.err("Unsupported format: {s}\n", .{fmt});
                    return ArgError.UnsupportedFileFormat;
                };
            } else if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
                const fmt = args.next() orelse {
                    log.err("Missing format value after {s}\n", .{arg});
                    return ArgError.MissingGetArgument;
                };
                output_override = parseFormatName(fmt) orelse {
                    log.err("Unsupported format: {s}\n", .{fmt});
                    return ArgError.UnsupportedFileFormat;
                };
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

        const detected_input: ?Detected = if (!requested_help and input_override == null)
            detectLanguageFromFileEnding(file_path)
        else
            null;
        // An explicit `--embed` archetype wins outright; otherwise, when the
        // extension implies SOME embedded region (`.md`), the handler sniffs
        // which archetype it actually is at runtime (`resolveEmbedType`).
        const embed = embed_override;
        // No `--input` and an unrecognized extension ⇒ sniff the contents in the
        // handler. `.json` here is a placeholder `from`/`to`, overwritten once the
        // real format is known. An explicit `--embed` is never sniffed: its
        // archetype fixes the inner format outright (`embedFormat`), and that
        // wins over a same-named extension guess — e.g. `--embed frontmatter-fig`
        // on a `.md` file (whose extension alone says nothing about which
        // archetype it actually is) must read/render the embed as fig, not YAML.
        const needs_detect = !requested_help and input_override == null and embed_override == null and detected_input == null;
        const input_format = input_override orelse
            (if (embed_override) |et| embedFormat(et) else null) orelse
            (if (detected_input) |d| d.format else null) orelse .json;

        var gron_projection: gron.Projection = .gron;
        if (gron_root) |r| gron_projection.root_name = r;
        if (gron_sep) |s| gron_projection.assign = s;
        if (gron_term) |t| gron_projection.terminator = t;

        config.options = .{ .get = .{
            .file = file_path,
            .path = path,
            .from = input_format,
            .to = output_override orelse input_format,
            .requested_help = requested_help,
            .detect = needs_detect,
            .output_explicit = output_override != null,
            .lax_tags = lax_tags,
            .lossless = lossless,
            .embed = embed,
            .detect_embed = embed == null and (if (detected_input) |d| d.embed_detect else false),
            .body = body,
            .serialize = serialize,
            .quiet = quiet,
            .strict = strict,
            .gron_projection = gron_projection,
        } };
    } else if (std.mem.eql(u8, action_str, "check") or std.mem.eql(u8, action_str, "ck")) {
        config.action = .check;

        var input_override: ?Format = null;
        var spec: ?[]const u8 = null;
        var quiet = false;
        var requested_help = false;
        var files: std.ArrayList([]const u8) = .empty;
        defer files.deinit(allocator);

        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                requested_help = true;
            } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--no-warnings")) {
                quiet = true;
            } else if (std.mem.eql(u8, arg, "--input") or std.mem.eql(u8, arg, "-i")) {
                const fmt = args.next() orelse {
                    log.err("Missing format value after {s}\n", .{arg});
                    return ArgError.MissingCheckArgument;
                };
                input_override = parseFormatName(fmt) orelse {
                    log.err("Unsupported format: {s}\n", .{fmt});
                    return ArgError.UnsupportedFileFormat;
                };
            } else if (std.mem.eql(u8, arg, "--spec") or std.mem.eql(u8, arg, "-s")) {
                spec = args.next() orelse {
                    log.err("Missing version value after {s}\n", .{arg});
                    return ArgError.MissingCheckArgument;
                };
            } else {
                try files.append(allocator, arg);
            }
        }

        if (!requested_help and files.items.len == 0) {
            log.err("No file provided.\n", .{});
            return ArgError.MissingCheckArgument;
        }

        config.options = .{
            .check = .{
                // toOwnedSlice: the whole slice (allocated in the arena passed to
                // parseConfig) outlives this function, unlike `get` which only keeps
                // copies of individual positional headers.
                .files = try files.toOwnedSlice(allocator),
                .format = input_override,
                .spec = spec,
                .quiet = quiet,
                .requested_help = requested_help,
            },
        };
    } else if (std.mem.eql(u8, action_str, "fmt") or std.mem.eql(u8, action_str, "f")) {
        config.action = .fmt;

        var input_override: ?Format = null;
        var quiet = false;
        var strict = false;
        var dry_run = false;
        var diff_mode = false;
        var requested_help = false;
        var embed_override: ?fig.Embed.Type = null;
        var serialize: fig.AST.SerializeOptions = .{};
        var positionals: std.ArrayList([]const u8) = .empty;
        defer positionals.deinit(allocator);

        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                requested_help = true;
            } else if (std.mem.eql(u8, arg, "--dry-run")) {
                dry_run = true;
            } else if (std.mem.eql(u8, arg, "--diff")) {
                diff_mode = true;
            } else if (std.mem.eql(u8, arg, "--compact")) {
                serialize.pretty = false;
            } else if (std.mem.eql(u8, arg, "--pretty")) {
                serialize.pretty = true;
            } else if (std.mem.eql(u8, arg, "--strip-comments")) {
                serialize.strip_comments = true;
            } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--no-warnings")) {
                quiet = true;
            } else if (std.mem.eql(u8, arg, "--strict")) {
                strict = true;
            } else if (std.mem.eql(u8, arg, "--embed")) {
                const name = args.next() orelse {
                    log.err("Missing archetype after {s}\n", .{arg});
                    return ArgError.MissingFmtArgument;
                };
                embed_override = embedTypeFromName(name) orelse {
                    log.err("Unknown --embed archetype: {s} (frontmatter, frontmatter-json, frontmatter-fig, endmatter)\n", .{name});
                    return ArgError.UnsupportedFileFormat;
                };
            } else if (std.mem.eql(u8, arg, "--indent")) {
                const n = args.next() orelse {
                    log.err("Missing value after {s}\n", .{arg});
                    return ArgError.MissingFmtArgument;
                };
                serialize.indent = std.fmt.parseInt(u8, n, 10) catch {
                    log.err("Invalid --indent value: {s}\n", .{n});
                    return ArgError.MissingFmtArgument;
                };
                // See the matching comment on `get`'s `--indent` handling above.
                serialize.fig_indent = true;
            } else if (std.mem.eql(u8, arg, "--width")) {
                const n = args.next() orelse {
                    log.err("Missing value after {s}\n", .{arg});
                    return ArgError.MissingFmtArgument;
                };
                serialize.width = std.fmt.parseInt(u16, n, 10) catch {
                    log.err("Invalid --width value: {s}\n", .{n});
                    return ArgError.MissingFmtArgument;
                };
            } else if (std.mem.eql(u8, arg, "--input") or std.mem.eql(u8, arg, "-i")) {
                const fmt_name = args.next() orelse {
                    log.err("Missing format value after {s}\n", .{arg});
                    return ArgError.MissingFmtArgument;
                };
                input_override = parseFormatName(fmt_name) orelse {
                    log.err("Unsupported format: {s}\n", .{fmt_name});
                    return ArgError.UnsupportedFileFormat;
                };
            } else {
                try positionals.append(allocator, arg);
            }
        }

        if (!requested_help and positionals.items.len == 0) {
            log.err("No file provided.\n", .{});
            return ArgError.MissingFmtArgument;
        }
        // `fmt` reformats a whole file (or a whole embedded region) — there is no
        // sub-document path argument the way `get`/`edit`/etc. take one.
        if (!requested_help and positionals.items.len > 1) {
            log.err("fmt takes a single file, not a path within it: {s}\n", .{positionals.items[1]});
            return ArgError.MissingFmtArgument;
        }
        if (!requested_help and dry_run and diff_mode) {
            log.err("--dry-run and --diff are mutually exclusive.\n", .{});
            return ArgError.MissingFmtArgument;
        }

        const file_path = if (positionals.items.len > 0) positionals.items[0] else "-";

        const detected_input: ?Detected = if (!requested_help and input_override == null)
            detectLanguageFromFileEnding(file_path)
        else
            null;
        // An explicit `--embed` archetype wins outright; otherwise, when the
        // extension implies SOME embedded region (`.md`), the handler sniffs
        // which archetype it actually is at runtime.
        const embed = embed_override;
        const needs_detect = !requested_help and input_override == null and embed_override == null and detected_input == null;
        const from = input_override orelse
            (if (embed_override) |et| embedFormat(et) else null) orelse
            (if (detected_input) |d| d.format else null) orelse .json;

        config.options = .{ .fmt = .{
            .file = file_path,
            .from = from,
            .requested_help = requested_help,
            .detect = needs_detect,
            .serialize = serialize,
            .quiet = quiet,
            .strict = strict,
            .dry_run = dry_run,
            .diff = diff_mode,
            .embed = embed,
            .detect_embed = embed == null and (if (detected_input) |d| d.embed_detect else false),
        } };
    } else if (std.mem.eql(u8, action_str, "convert") or std.mem.eql(u8, action_str, "cv")) {
        config.action = .convert;

        var input_override: ?Format = null;
        var output_override: ?Format = null;
        var embed_override: ?fig.Embed.Type = null;
        var to_embed_override: ?fig.Embed.Type = null;
        var lax_tags = false;
        var lossless = false;
        var quiet = false;
        var strict = false;
        var write = false;
        var diff_mode = false;
        var requested_help = false;
        var serialize: fig.AST.SerializeOptions = .{};
        var positionals: std.ArrayList([]const u8) = .empty;
        defer positionals.deinit(allocator);

        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                requested_help = true;
            } else if (std.mem.eql(u8, arg, "--write") or std.mem.eql(u8, arg, "-w")) {
                write = true;
            } else if (std.mem.eql(u8, arg, "--dry-run")) {
                log.err("convert prints to stdout by default; pass --write/-w to write in place instead.\n", .{});
                return ArgError.MissingConvertArgument;
            } else if (std.mem.eql(u8, arg, "--diff")) {
                diff_mode = true;
            } else if (std.mem.eql(u8, arg, "--compact")) {
                serialize.pretty = false;
            } else if (std.mem.eql(u8, arg, "--pretty")) {
                serialize.pretty = true;
            } else if (std.mem.eql(u8, arg, "--strip-comments")) {
                serialize.strip_comments = true;
            } else if (std.mem.eql(u8, arg, "--lax-tags")) {
                lax_tags = true;
            } else if (std.mem.eql(u8, arg, "--lossless")) {
                lossless = true;
            } else if (std.mem.eql(u8, arg, "--lossy")) {
                lossless = false;
            } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--no-warnings")) {
                quiet = true;
            } else if (std.mem.eql(u8, arg, "--strict")) {
                strict = true;
            } else if (std.mem.eql(u8, arg, "--embed")) {
                const name = args.next() orelse {
                    log.err("Missing archetype after {s}\n", .{arg});
                    return ArgError.MissingConvertArgument;
                };
                embed_override = embedTypeFromName(name) orelse {
                    log.err("Unknown --embed archetype: {s} (frontmatter, frontmatter-json, frontmatter-fig, endmatter)\n", .{name});
                    return ArgError.UnsupportedFileFormat;
                };
            } else if (std.mem.eql(u8, arg, "--to-embed")) {
                const name = args.next() orelse {
                    log.err("Missing archetype after {s}\n", .{arg});
                    return ArgError.MissingConvertArgument;
                };
                to_embed_override = embedTypeFromName(name) orelse {
                    log.err("Unknown --to-embed archetype: {s} (frontmatter, frontmatter-json, frontmatter-fig, endmatter)\n", .{name});
                    return ArgError.UnsupportedFileFormat;
                };
            } else if (std.mem.eql(u8, arg, "--indent")) {
                const n = args.next() orelse {
                    log.err("Missing value after {s}\n", .{arg});
                    return ArgError.MissingConvertArgument;
                };
                serialize.indent = std.fmt.parseInt(u8, n, 10) catch {
                    log.err("Invalid --indent value: {s}\n", .{n});
                    return ArgError.MissingConvertArgument;
                };
                // See the matching comment on `get`'s `--indent` handling above.
                serialize.fig_indent = true;
            } else if (std.mem.eql(u8, arg, "--width")) {
                const n = args.next() orelse {
                    log.err("Missing value after {s}\n", .{arg});
                    return ArgError.MissingConvertArgument;
                };
                serialize.width = std.fmt.parseInt(u16, n, 10) catch {
                    log.err("Invalid --width value: {s}\n", .{n});
                    return ArgError.MissingConvertArgument;
                };
            } else if (std.mem.eql(u8, arg, "--input") or std.mem.eql(u8, arg, "-i")) {
                const fmt_name = args.next() orelse {
                    log.err("Missing format value after {s}\n", .{arg});
                    return ArgError.MissingConvertArgument;
                };
                input_override = parseFormatName(fmt_name) orelse {
                    log.err("Unsupported format: {s}\n", .{fmt_name});
                    return ArgError.UnsupportedFileFormat;
                };
            } else if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
                const fmt_name = args.next() orelse {
                    log.err("Missing format value after {s}\n", .{arg});
                    return ArgError.MissingConvertArgument;
                };
                output_override = parseFormatName(fmt_name) orelse {
                    log.err("Unsupported format: {s}\n", .{fmt_name});
                    return ArgError.UnsupportedFileFormat;
                };
            } else {
                try positionals.append(allocator, arg);
            }
        }

        if (!requested_help and positionals.items.len == 0) {
            log.err("No file provided.\n", .{});
            return ArgError.MissingConvertArgument;
        }
        if (!requested_help and positionals.items.len > 1) {
            log.err("convert takes a single file, not a path within it: {s}\n", .{positionals.items[1]});
            return ArgError.MissingConvertArgument;
        }
        if (!requested_help and output_override != null and to_embed_override != null) {
            log.err("--output and --to-embed are mutually exclusive: whole-file conversion picks the target format directly, embed-archetype conversion picks it via the archetype.\n", .{});
            return ArgError.MissingConvertArgument;
        }
        if (!requested_help and output_override == null and to_embed_override == null) {
            log.err("convert needs a target: pass --output <format> to convert the whole file, or --to-embed <archetype> to rehouse an embedded region.\n", .{});
            return ArgError.MissingConvertArgument;
        }
        if (!requested_help and input_override != null and to_embed_override != null) {
            log.err("--input is not used with --to-embed: the source archetype (--embed, else detected) fixes the input format.\n", .{});
            return ArgError.MissingConvertArgument;
        }
        if (!requested_help and embed_override != null and to_embed_override == null) {
            log.err("--embed requires --to-embed (embed-archetype conversion always changes the archetype); use `fmt --embed` to reformat without changing format.\n", .{});
            return ArgError.MissingConvertArgument;
        }

        const file_path = if (positionals.items.len > 0) positionals.items[0] else "-";

        const detected_input: ?Detected = if (!requested_help) detectLanguageFromFileEnding(file_path) else null;

        if (!requested_help and to_embed_override != null) {
            // Embed-archetype mode: `from`/`to`/`detect` are unused — the
            // source and target archetypes fix both formats. The source
            // archetype is never pinned by the extension alone (`.md` only
            // implies SOME embed, not which one) — an explicit `--embed`
            // wins, else `detect_embed` sniffs it from the content at runtime.
            const embed = embed_override;
            config.options = .{ .convert = .{
                .file = file_path,
                .requested_help = requested_help,
                .to_embed = to_embed_override,
                .embed = embed,
                .detect_embed = embed == null,
                .lax_tags = lax_tags,
                .lossless = lossless,
                .serialize = serialize,
                .quiet = quiet,
                .strict = strict,
                .write = write,
                .diff = diff_mode,
            } };
        } else {
            // Whole-file mode. A host document whose extension implies an
            // embed (currently only `.md`/`.markdown`) can't be converted
            // whole without either destroying its prose or guessing at a
            // fence convention for `--output`'s format — point the user at
            // `--to-embed` instead, unless they passed an explicit `--input`
            // that overrides the extension's guess entirely.
            if (!requested_help and input_override == null) {
                if (detected_input) |d| if (d.embed_detect) {
                    log.err("{s} is a host document (embedded config detected); use --to-embed <archetype> to convert its embedded region, or pass --input explicitly to force whole-file conversion.\n", .{file_path});
                    return ArgError.MissingConvertArgument;
                };
            }
            const needs_detect = !requested_help and input_override == null and detected_input == null;
            const from = input_override orelse (if (detected_input) |d| d.format else null) orelse .json;
            config.options = .{ .convert = .{
                .file = file_path,
                .requested_help = requested_help,
                .from = from,
                .to = output_override orelse .json,
                .detect = needs_detect,
                .lax_tags = lax_tags,
                .lossless = lossless,
                .serialize = serialize,
                .quiet = quiet,
                .strict = strict,
                .write = write,
                .diff = diff_mode,
            } };
        }
    } else {
        log.err("Action not recognized: {s}", .{action_str});
        config.action = .help;
        config.options = .{ .help = .{ .requested_help = true } };
    }

    return config;
}

// A slice-backed stand-in for the process arg iterator `parseConfig` consumes.
const TestArgs = struct {
    items: []const []const u8,
    i: usize = 0,
    fn next(self: *TestArgs) ?[]const u8 {
        if (self.i >= self.items.len) return null;
        defer self.i += 1;
        return self.items[self.i];
    }
};

test "parsePath reads the [-]/[$] append sentinel and literal indices" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const dash = try parsePath(a, "list[-]");
    try t.expectEqual(@as(usize, 2), dash.len);
    try t.expectEqualStrings("list", dash[0].key);
    try t.expectEqual(append_index, dash[1].index);

    const dollar = try parsePath(a, "list[$]");
    try t.expectEqual(append_index, dollar[1].index);

    const literal = try parsePath(a, "a.b[2]");
    try t.expectEqual(@as(usize, 2), literal[2].index);
}

test "parseConfig routes insert/delete to the right action and path tail" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // insert into a mapping: trailing key, value captured.
    var ins = TestArgs{ .items = &.{ "fig", "insert", "f.yaml", "a.newkey", "42" } };
    const ic = try parseConfig(a, &ins);
    try t.expectEqual(CliAction.insert, ic.action);
    try t.expectEqualStrings("newkey", ic.options.insert.path[1].key);
    try t.expectEqualStrings("42", ic.options.insert.value);
    try t.expectEqual(Format.yaml, ic.options.insert.format);

    // insert append onto a sequence: trailing sentinel index.
    var app = TestArgs{ .items = &.{ "fig", "insert", "f.yaml", "list[-]", "z" } };
    const ac = try parseConfig(a, &app);
    try t.expectEqual(append_index, ac.options.insert.path[1].index);

    // delete by index: format sniffed later, path tail is an index.
    var del = TestArgs{ .items = &.{ "fig", "delete", "f.toml", "list[1]" } };
    const dc = try parseConfig(a, &del);
    try t.expectEqual(CliAction.delete, dc.action);
    try t.expectEqual(@as(usize, 1), dc.options.delete.path[1].index);
    try t.expectEqual(Format.toml, dc.options.delete.format);
}

test "embedTypeFromName maps archetype names" {
    const t = std.testing;
    try t.expectEqual(@as(?fig.Embed.Type, .FrontmatterYaml), embedTypeFromName("frontmatter"));
    try t.expectEqual(@as(?fig.Embed.Type, .FrontmatterYaml), embedTypeFromName("frontmatter-yaml"));
    try t.expectEqual(@as(?fig.Embed.Type, .FrontmatterJson), embedTypeFromName("frontmatter-json"));
    try t.expectEqual(@as(?fig.Embed.Type, .FrontmatterFig), embedTypeFromName("frontmatter-fig"));
    try t.expectEqual(@as(?fig.Embed.Type, .EndmatterYaml), embedTypeFromName("endmatter"));
    try t.expectEqual(@as(?fig.Embed.Type, null), embedTypeFromName("bogus"));
}

test "detectLanguageFromFileEnding: .md/.markdown defer the archetype to a runtime sniff" {
    const t = std.testing;
    const md = detectLanguageFromFileEnding("post.md").?;
    try t.expectEqual(Format.yaml, md.format);
    try t.expect(md.embed_detect);

    const markdown = detectLanguageFromFileEnding("post.markdown").?;
    try t.expect(markdown.embed_detect);

    // Other extensions imply no embed at all.
    const yaml = detectLanguageFromFileEnding("f.yaml").?;
    try t.expect(!yaml.embed_detect);

    const figl_ext = detectLanguageFromFileEnding("f.figl").?;
    try t.expectEqual(Format.fig, figl_ext.format);
    try t.expect(!figl_ext.embed_detect);

    // `.fig` remains accepted for back-compat.
    const fig_ext = detectLanguageFromFileEnding("f.fig").?;
    try t.expectEqual(Format.fig, fig_ext.format);
    try t.expect(!fig_ext.embed_detect);
}

test "resolveEmbedTypeFromContent: explicit override wins, else sniffs, else falls back to YAML" {
    const t = std.testing;

    // An explicit override always wins, regardless of content.
    try t.expectEqual(@as(?fig.Embed.Type, .EndmatterYaml), resolveEmbedTypeFromContent("anything", .EndmatterYaml, true));

    // Not a detect_embed case at all (e.g. a plain .json file): no embed.
    try t.expectEqual(@as(?fig.Embed.Type, null), resolveEmbedTypeFromContent("{}", null, false));

    // detect_embed sniffs the real archetype from the bytes — this is the
    // fig-frontmatter regression: a `.md` file whose actual content is a
    // ```fig fenced block must resolve to FrontmatterFig, not be assumed to
    // be YAML just because the extension is `.md`.
    try t.expectEqual(
        @as(?fig.Embed.Type, .FrontmatterFig),
        resolveEmbedTypeFromContent("```fig\ntitle = hi\n```\nbody\n", null, true),
    );
    try t.expectEqual(
        @as(?fig.Embed.Type, .FrontmatterJson),
        resolveEmbedTypeFromContent(";;;\n{\"a\":1}\n;;;\nbody\n", null, true),
    );
    try t.expectEqual(
        @as(?fig.Embed.Type, .FrontmatterYaml),
        resolveEmbedTypeFromContent("---\na: 1\n---\nbody\n", null, true),
    );

    // Nothing detected at all (e.g. a brand-new/plain host file): falls back
    // to the historical FrontmatterYaml default rather than `null`, so `set`'s
    // open-or-init still seeds the same archetype it always has.
    try t.expectEqual(@as(?fig.Embed.Type, .FrontmatterYaml), resolveEmbedTypeFromContent("just prose\n", null, true));
    try t.expectEqual(@as(?fig.Embed.Type, .FrontmatterYaml), resolveEmbedTypeFromContent("", null, true));
}

test "parseConfig routes set, --seq, and --embed" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Scalar upsert: path + value captured, format from extension.
    var s = TestArgs{ .items = &.{ "fig", "set", "f.yaml", "a.b", "1" } };
    const sc = try parseConfig(a, &s);
    try t.expectEqual(CliAction.set, sc.action);
    try t.expectEqualStrings("b", sc.options.set.path[1].key);
    try t.expectEqualStrings("1", sc.options.set.value);
    try t.expect(!sc.options.set.seq);
    try t.expectEqual(Format.yaml, sc.options.set.format);

    // --seq collects the trailing items into `values`.
    var sq = TestArgs{ .items = &.{ "fig", "set", "--seq", "f.yaml", "tags", "x", "y", "z" } };
    const sqc = try parseConfig(a, &sq);
    try t.expect(sqc.options.set.seq);
    try t.expectEqual(@as(usize, 3), sqc.options.set.values.len);
    try t.expectEqualStrings("z", sqc.options.set.values[2]);

    // --embed selects the archetype explicitly (endmatter here).
    var em = TestArgs{ .items = &.{ "fig", "set", "--embed", "endmatter", "post.md", "k", "v" } };
    const emc = try parseConfig(a, &em);
    try t.expectEqual(@as(?fig.Embed.Type, .EndmatterYaml), emc.options.set.embed);

    // --embed frontmatter-fig routes to the fig-fenced archetype.
    var fm = TestArgs{ .items = &.{ "fig", "set", "--embed", "frontmatter-fig", "post.md", "k", "v" } };
    const fmc = try parseConfig(a, &fm);
    try t.expectEqual(@as(?fig.Embed.Type, .FrontmatterFig), fmc.options.set.embed);

    // No --embed on a `.md` file: the fix for the fig-frontmatter
    // autodetection bug — `embed` stays null and `detect_embed` fires, so
    // the handler sniffs the actual archetype from the file's bytes at
    // runtime instead of the extension alone assuming YAML frontmatter.
    var md = TestArgs{ .items = &.{ "fig", "set", "post.md", "k", "v" } };
    const mdc = try parseConfig(a, &md);
    try t.expectEqual(@as(?fig.Embed.Type, null), mdc.options.set.embed);
    try t.expect(mdc.options.set.detect_embed);
}

test "parseConfig routes convert: whole-file mode, embed mode, and their guards" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Whole-file mode: --input/--output resolve `from`/`to` directly.
    var wf = TestArgs{ .items = &.{ "fig", "convert", "-i", "yaml", "-o", "toml", "f.yaml" } };
    const wfc = try parseConfig(a, &wf);
    try t.expectEqual(CliAction.convert, wfc.action);
    try t.expectEqual(Format.yaml, wfc.options.convert.from);
    try t.expectEqual(Format.toml, wfc.options.convert.to);
    try t.expectEqual(@as(?fig.Embed.Type, null), wfc.options.convert.to_embed);
    try t.expect(!wfc.options.convert.detect);

    // Whole-file mode with an unrecognized extension: `--output` alone still
    // needs `from` sniffed at runtime.
    var det = TestArgs{ .items = &.{ "fig", "convert", "-o", "json", "f.weirdext" } };
    const detc = try parseConfig(a, &det);
    try t.expect(detc.options.convert.detect);

    // Embed mode: --to-embed alone (no --embed) defers source detection to
    // the handler (`detect_embed`); the file extension doesn't imply an
    // archetype here (not .md), so `embed` stays null.
    var em = TestArgs{ .items = &.{ "fig", "convert", "--to-embed", "frontmatter-json", "f.txt" } };
    const emc = try parseConfig(a, &em);
    try t.expectEqual(@as(?fig.Embed.Type, .FrontmatterJson), emc.options.convert.to_embed);
    try t.expectEqual(@as(?fig.Embed.Type, null), emc.options.convert.embed);
    try t.expect(emc.options.convert.detect_embed);

    // Embed mode on a `.md` file: the extension alone only implies SOME
    // embedded region, never which archetype — `embed` stays null and
    // `detect_embed` fires so the handler sniffs the actual fences at
    // runtime instead of assuming YAML frontmatter outright.
    var md = TestArgs{ .items = &.{ "fig", "convert", "--to-embed", "frontmatter-json", "post.md" } };
    const mdc = try parseConfig(a, &md);
    try t.expectEqual(@as(?fig.Embed.Type, null), mdc.options.convert.embed);
    try t.expect(mdc.options.convert.detect_embed);

    // Embed mode: explicit --embed overrides the extension default.
    var ov = TestArgs{ .items = &.{ "fig", "convert", "--embed", "endmatter", "--to-embed", "frontmatter-fig", "post.md" } };
    const ovc = try parseConfig(a, &ov);
    try t.expectEqual(@as(?fig.Embed.Type, .EndmatterYaml), ovc.options.convert.embed);
    try t.expectEqual(@as(?fig.Embed.Type, .FrontmatterFig), ovc.options.convert.to_embed);

    // The four guard rejections (no target at all; --output+--to-embed
    // together; --embed without --to-embed; whole-file --output on a `.md`
    // host document without an explicit --input) all return
    // `ArgError.MissingConvertArgument` after a `log.err` — verified manually
    // against the built CLI rather than here, since this test binary's
    // default runner (Zig 0.16) fails any test that logs at `.err`
    // regardless of whether the returned error was expected (see
    // `test_runner.zig`'s `log_err_count`), the same reason no other
    // `parseConfig` error path in this file is exercised as a unit test.

    // An explicit --input forces whole-file conversion on a `.md` file anyway.
    var mdforced = TestArgs{ .items = &.{ "fig", "convert", "-i", "yaml", "-o", "toml", "post.md" } };
    const mdforcedc = try parseConfig(a, &mdforced);
    try t.expectEqual(Format.yaml, mdforcedc.options.convert.from);
    try t.expect(!mdforcedc.options.convert.detect);
}
