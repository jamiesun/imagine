//! Command-line parsing for imagine.
//!
//! Produces a typed `Command` (or a help/error message) from raw argv. Kept
//! free of side effects so it is straightforward to test; `main.zig` executes
//! the parsed command.

const std = @import("std");
const version = @import("version.zig");

pub const Common = struct {
    config_path: ?[]const u8 = null,
    json: bool = false,
};

pub const Generate = struct {
    common: Common = .{},
    model: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    output: ?[]const u8 = null,
    n: u32 = 1,
    size: ?[]const u8 = null,
    width: ?u32 = null,
    height: ?u32 = null,
    format: ?[]const u8 = null,
    compression: ?u32 = null,
    quality: ?[]const u8 = null,
    seed: ?i64 = null,
    concurrency: ?usize = null,
    dry_run: bool = false,
    quiet: bool = false,
};

pub const Batch = struct {
    common: Common = .{},
    manifest: ?[]const u8 = null,
    concurrency: ?usize = null,
    dry_run: bool = false,
    quiet: bool = false,
};

pub const ConfigInit = struct {
    common: Common = .{},
    force: bool = false,
};

pub const Command = union(enum) {
    generate: Generate,
    batch: Batch,
    models: Common,
    config_path: Common,
    config_init: ConfigInit,
    config_show: Common,
    version,
};

pub const Parsed = union(enum) {
    command: Command,
    help: []const u8,
    err: []const u8,
};

pub const usage =
    \\imagine — universal image generation CLI for AI agents
    \\
    \\USAGE:
    \\  imagine <command> [options]
    \\
    \\COMMANDS:
    \\  generate        Generate image(s) from a prompt
    \\  batch <file>    Generate from a JSON manifest of jobs
    \\  models          List configured models (--json for machine output)
    \\  config path     Print the resolved config file path
    \\  config init     Write a starter config (--force to overwrite)
    \\  config show     Print effective config (credentials redacted)
    \\  version         Print version
    \\  help            Show this help
    \\
    \\GENERATE OPTIONS:
    \\  -m, --model <name>        Model to route to (required)
    \\  -p, --prompt <text>       Text prompt (required; or pass as positional)
    \\  -o, --output <path>       Output file (single) or stem (multiple)
    \\  -n, --n <count>           Number of images (default 1)
    \\  -s, --size <WxH>          Size for gpt-image models (see MODEL SIZES)
    \\      --width <px>          Width for FLUX models (use instead of --size)
    \\      --height <px>         Height for FLUX models
    \\      --format <fmt>        png | jpeg   (gpt-image output_format)
    \\      --compression <0-100> Output compression (gpt-image)
    \\      --quality <q>         low | medium | high | auto   (gpt-image)
    \\      --seed <int>          Seed (where supported)
    \\  -c, --concurrency <num>   Parallel requests (default: endpoint count)
    \\      --config <path>       Use a specific config file
    \\      --json                Emit a JSON result object to stdout
    \\      --dry-run             Print request bodies without calling the API
    \\  -q, --quiet               Suppress progress output
    \\
    \\MODEL SIZES (Azure):
    \\  gpt-image-1.5   1024x1024, 1536x1024, 1024x1536, auto
    \\  gpt-image-2     any WxH, both sides multiple of 16, longest edge <= 3840
    \\  FLUX.2-pro      --width/--height each >= 64; width*height <= 2048x2048 (4 MP)
    \\
    \\ENVIRONMENT:
    \\  IMAGINE_CONFIG            Override config path (default ~/.imagine/config.json)
    \\
    \\EXAMPLES:
    \\  imagine generate -m gpt-image-1.5 -p "a red fox in autumn" -o fox.png
    \\  imagine generate -m FLUX.2-pro -p "a city at dusk" --width 1024 --height 1024
    \\  imagine generate -m gpt-image-2 -p "logo" -n 4 -o logo.png -c 4
    \\  imagine batch jobs.json
    \\  imagine models --json
    \\
;

const FlagSplit = struct { name: []const u8, value: ?[]const u8 };

fn split(arg: []const u8) FlagSplit {
    if (std.mem.startsWith(u8, arg, "--")) {
        if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
            return .{ .name = arg[0..eq], .value = arg[eq + 1 ..] };
        }
    }
    return .{ .name = arg, .value = null };
}

const Cursor = struct {
    args: []const []const u8,
    i: usize = 0,

    fn value(self: *Cursor, fs: FlagSplit, arena: std.mem.Allocator) !?[]const u8 {
        if (fs.value) |v| return v;
        if (self.i + 1 >= self.args.len) return null;
        self.i += 1;
        return try arena.dupe(u8, self.args[self.i]);
    }
};

fn parseU32(s: []const u8) ?u32 {
    return std.fmt.parseInt(u32, s, 10) catch null;
}

/// Parse argv (excluding the program name). Allocations use `arena`.
pub fn parse(arena: std.mem.Allocator, args: []const []const u8) !Parsed {
    if (args.len == 0) return .{ .help = usage };

    const cmd = args[0];
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        return .{ .help = usage };
    }
    if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-V")) {
        return .{ .command = .version };
    }
    if (std.mem.eql(u8, cmd, "generate") or std.mem.eql(u8, cmd, "gen") or std.mem.eql(u8, cmd, "g")) {
        return parseGenerate(arena, args[1..]);
    }
    if (std.mem.eql(u8, cmd, "batch")) {
        return parseBatch(arena, args[1..]);
    }
    if (std.mem.eql(u8, cmd, "models")) {
        return parseCommon(arena, args[1..], .models);
    }
    if (std.mem.eql(u8, cmd, "config")) {
        return parseConfig(arena, args[1..]);
    }
    return .{ .err = try std.fmt.allocPrint(arena, "unknown command: '{s}' (try 'imagine help')", .{cmd}) };
}

fn unknownFlag(arena: std.mem.Allocator, name: []const u8) !Parsed {
    return .{ .err = try std.fmt.allocPrint(arena, "unknown or misplaced option: '{s}'", .{name}) };
}

fn missingValue(arena: std.mem.Allocator, name: []const u8) !Parsed {
    return .{ .err = try std.fmt.allocPrint(arena, "option '{s}' requires a value", .{name}) };
}

fn parseGenerate(arena: std.mem.Allocator, args: []const []const u8) !Parsed {
    var g = Generate{};
    var cur = Cursor{ .args = args };
    var positional: ?[]const u8 = null;

    while (cur.i < args.len) : (cur.i += 1) {
        const fs = split(args[cur.i]);
        const name = fs.name;
        if (std.mem.eql(u8, name, "-m") or std.mem.eql(u8, name, "--model")) {
            g.model = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
        } else if (std.mem.eql(u8, name, "-p") or std.mem.eql(u8, name, "--prompt")) {
            g.prompt = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
        } else if (std.mem.eql(u8, name, "-o") or std.mem.eql(u8, name, "--output")) {
            g.output = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
        } else if (std.mem.eql(u8, name, "-n") or std.mem.eql(u8, name, "--n") or std.mem.eql(u8, name, "--count")) {
            const v = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
            g.n = parseU32(v) orelse return .{ .err = try std.fmt.allocPrint(arena, "invalid --n: {s}", .{v}) };
        } else if (std.mem.eql(u8, name, "-s") or std.mem.eql(u8, name, "--size")) {
            g.size = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
        } else if (std.mem.eql(u8, name, "--width")) {
            const v = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
            g.width = parseU32(v) orelse return .{ .err = try std.fmt.allocPrint(arena, "invalid --width: {s}", .{v}) };
        } else if (std.mem.eql(u8, name, "--height")) {
            const v = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
            g.height = parseU32(v) orelse return .{ .err = try std.fmt.allocPrint(arena, "invalid --height: {s}", .{v}) };
        } else if (std.mem.eql(u8, name, "--format") or std.mem.eql(u8, name, "-f")) {
            g.format = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
        } else if (std.mem.eql(u8, name, "--compression")) {
            const v = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
            g.compression = parseU32(v) orelse return .{ .err = try std.fmt.allocPrint(arena, "invalid --compression: {s}", .{v}) };
        } else if (std.mem.eql(u8, name, "--quality")) {
            g.quality = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
        } else if (std.mem.eql(u8, name, "--seed")) {
            const v = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
            g.seed = std.fmt.parseInt(i64, v, 10) catch return .{ .err = try std.fmt.allocPrint(arena, "invalid --seed: {s}", .{v}) };
        } else if (std.mem.eql(u8, name, "-c") or std.mem.eql(u8, name, "--concurrency")) {
            const v = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
            g.concurrency = parseU32(v) orelse return .{ .err = try std.fmt.allocPrint(arena, "invalid --concurrency: {s}", .{v}) };
        } else if (std.mem.eql(u8, name, "--config")) {
            g.common.config_path = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
        } else if (std.mem.eql(u8, name, "--json")) {
            g.common.json = true;
        } else if (std.mem.eql(u8, name, "--dry-run")) {
            g.dry_run = true;
        } else if (std.mem.eql(u8, name, "-q") or std.mem.eql(u8, name, "--quiet")) {
            g.quiet = true;
        } else if (std.mem.startsWith(u8, name, "-")) {
            return unknownFlag(arena, name);
        } else {
            if (positional == null) positional = try arena.dupe(u8, args[cur.i]);
        }
    }

    if (g.prompt == null) g.prompt = positional;
    if (g.model == null) return .{ .err = try arena.dupe(u8, "missing required option: --model") };
    if (g.prompt == null) return .{ .err = try arena.dupe(u8, "missing required option: --prompt") };
    if (g.n == 0) return .{ .err = try arena.dupe(u8, "--n must be >= 1") };

    return .{ .command = .{ .generate = g } };
}

fn parseBatch(arena: std.mem.Allocator, args: []const []const u8) !Parsed {
    var b = Batch{};
    var cur = Cursor{ .args = args };
    while (cur.i < args.len) : (cur.i += 1) {
        const fs = split(args[cur.i]);
        const name = fs.name;
        if (std.mem.eql(u8, name, "-c") or std.mem.eql(u8, name, "--concurrency")) {
            const v = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
            b.concurrency = parseU32(v) orelse return .{ .err = try std.fmt.allocPrint(arena, "invalid --concurrency: {s}", .{v}) };
        } else if (std.mem.eql(u8, name, "--config")) {
            b.common.config_path = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
        } else if (std.mem.eql(u8, name, "--json")) {
            b.common.json = true;
        } else if (std.mem.eql(u8, name, "--dry-run")) {
            b.dry_run = true;
        } else if (std.mem.eql(u8, name, "-q") or std.mem.eql(u8, name, "--quiet")) {
            b.quiet = true;
        } else if (std.mem.startsWith(u8, name, "-")) {
            return unknownFlag(arena, name);
        } else {
            if (b.manifest == null) b.manifest = try arena.dupe(u8, args[cur.i]);
        }
    }
    if (b.manifest == null) return .{ .err = try arena.dupe(u8, "batch requires a manifest file path") };
    return .{ .command = .{ .batch = b } };
}

fn parseCommon(arena: std.mem.Allocator, args: []const []const u8, comptime tag: std.meta.Tag(Command)) !Parsed {
    var c = Common{};
    var cur = Cursor{ .args = args };
    while (cur.i < args.len) : (cur.i += 1) {
        const fs = split(args[cur.i]);
        const name = fs.name;
        if (std.mem.eql(u8, name, "--config")) {
            c.config_path = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
        } else if (std.mem.eql(u8, name, "--json")) {
            c.json = true;
        } else if (std.mem.startsWith(u8, name, "-")) {
            return unknownFlag(arena, name);
        }
    }
    return switch (tag) {
        .models => .{ .command = .{ .models = c } },
        .config_path => .{ .command = .{ .config_path = c } },
        .config_show => .{ .command = .{ .config_show = c } },
        else => unreachable,
    };
}

fn parseConfig(arena: std.mem.Allocator, args: []const []const u8) !Parsed {
    if (args.len == 0) return .{ .err = try arena.dupe(u8, "config requires a subcommand: path | init | show") };
    const sub = args[0];
    if (std.mem.eql(u8, sub, "path")) return parseCommon(arena, args[1..], .config_path);
    if (std.mem.eql(u8, sub, "show")) return parseCommon(arena, args[1..], .config_show);
    if (std.mem.eql(u8, sub, "init")) {
        var ci = ConfigInit{};
        var cur = Cursor{ .args = args[1..] };
        while (cur.i < args[1..].len) : (cur.i += 1) {
            const fs = split(args[1..][cur.i]);
            const name = fs.name;
            if (std.mem.eql(u8, name, "--force") or std.mem.eql(u8, name, "-f")) {
                ci.force = true;
            } else if (std.mem.eql(u8, name, "--config")) {
                ci.common.config_path = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
            } else if (std.mem.startsWith(u8, name, "-")) {
                return unknownFlag(arena, name);
            }
        }
        return .{ .command = .{ .config_init = ci } };
    }
    return .{ .err = try std.fmt.allocPrint(arena, "unknown config subcommand: '{s}'", .{sub}) };
}

// ---- tests ----

fn parseArgs(arena: std.mem.Allocator, comptime items: []const []const u8) !Parsed {
    return parse(arena, items);
}

test "parse generate with flags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try parseArgs(a, &.{ "generate", "-m", "gpt-image-1.5", "-p", "a fox", "-n", "3", "-o", "x.png" });
    try std.testing.expect(p == .command);
    const g = p.command.generate;
    try std.testing.expectEqualStrings("gpt-image-1.5", g.model.?);
    try std.testing.expectEqualStrings("a fox", g.prompt.?);
    try std.testing.expectEqual(@as(u32, 3), g.n);
    try std.testing.expectEqualStrings("x.png", g.output.?);
}

test "parse generate equals form and positional prompt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try parseArgs(a, &.{ "g", "--model=FLUX.2-pro", "--width=512", "--height=512", "a cat" });
    const g = p.command.generate;
    try std.testing.expectEqualStrings("FLUX.2-pro", g.model.?);
    try std.testing.expectEqual(@as(u32, 512), g.width.?);
    try std.testing.expectEqualStrings("a cat", g.prompt.?);
}

test "missing model errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = try parseArgs(arena.allocator(), &.{ "generate", "-p", "x" });
    try std.testing.expect(p == .err);
}

test "help and version" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect((try parseArgs(arena.allocator(), &.{"help"})) == .help);
    try std.testing.expect((try parseArgs(arena.allocator(), &.{"version"})).command == .version);
}
