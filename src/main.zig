//! imagine — entry point and command execution.
//!
//! Parsing lives in `cli.zig`; this module loads config, builds the unified
//! request, fans work into scheduler tasks, and renders human or `--json`
//! output. It is the only module that performs process I/O (stdout/stderr,
//! exit codes, the shared HTTP client).

const std = @import("std");
const cli = @import("cli.zig");
const config = @import("config.zig");
const types = @import("types.zig");
const backend = @import("backend.zig");
const scheduler = @import("scheduler.zig");
const util = @import("util.zig");
const version = @import("version.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const argv = try collectArgs(arena, init.minimal.args);
    const env = makeEnv(init.environ_map);

    const parsed = try cli.parse(arena, argv);
    switch (parsed) {
        .help => |h| {
            try printOut(io, h);
            return 0;
        },
        .err => |e| {
            try printErr(io, e);
            try printErr(io, "\n");
            return 2;
        },
        .command => |cmd| return runCommand(.{
            .gpa = gpa,
            .arena = arena,
            .io = io,
            .env = env,
        }, cmd),
    }
}

const Ctx = struct {
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    env: config.Env,
};

fn runCommand(ctx: Ctx, cmd: cli.Command) !u8 {
    return switch (cmd) {
        .version => blk: {
            try outf(ctx, "{s} {s}\n", .{ version.name, version.string });
            break :blk 0;
        },
        .config_path => |c| cmdConfigPath(ctx, c),
        .config_init => |c| cmdConfigInit(ctx, c),
        .config_show => |c| cmdConfigShow(ctx, c),
        .models => |c| cmdModels(ctx, c),
        .generate => |g| cmdGenerate(ctx, g),
        .batch => |b| cmdBatch(ctx, b),
    };
}

// ---------------------------------------------------------------------------
// config commands
// ---------------------------------------------------------------------------

fn cmdConfigPath(ctx: Ctx, c: cli.Common) !u8 {
    const path = try config.resolvePath(ctx.arena, ctx.env, c.config_path);
    try outf(ctx, "{s}\n", .{path});
    return 0;
}

fn cmdConfigInit(ctx: Ctx, c: cli.ConfigInit) !u8 {
    const raw = try config.resolvePath(ctx.arena, ctx.env, c.common.config_path);
    const path = try expandPath(ctx, raw);
    const cwd = std.Io.Dir.cwd();

    const exists = blk: {
        cwd.access(ctx.io, path, .{}) catch break :blk false;
        break :blk true;
    };
    if (exists and !c.force) {
        try printErr(ctx.io, try std.fmt.allocPrint(ctx.arena, "config already exists: {s} (use --force to overwrite)\n", .{path}));
        return 1;
    }

    if (util.dirName(path)) |_| {
        try util.ensureParentDir(ctx.io, cwd, path);
    }
    try cwd.writeFile(ctx.io, .{ .sub_path = path, .data = config.template });
    try outf(ctx, "wrote starter config to {s}\nedit it, then set your API key (default env: AZURE_API_KEY)\n", .{path});
    return 0;
}

fn cmdConfigShow(ctx: Ctx, c: cli.Common) !u8 {
    var cfg = loadConfig(ctx, c.config_path) catch |e| return reportConfigError(ctx, e, c.config_path);
    defer cfg.deinit();

    const Endpoint = struct {
        base_url: []const u8,
        auth: []const u8,
        api_key_env: ?[]const u8,
        key: []const u8,
    };
    const Model = struct {
        name: []const u8,
        backend: []const u8,
        api_model: []const u8,
        endpoints: []Endpoint,
        defaults: types.ModelDefaults,
    };
    const Show = struct {
        config_path: ?[]const u8,
        output_dir: []const u8,
        concurrency: u32,
        models: []Model,
    };

    var models = try ctx.arena.alloc(Model, cfg.models.len);
    for (cfg.models, 0..) |m, mi| {
        var eps = try ctx.arena.alloc(Endpoint, m.endpoints.len);
        for (m.endpoints, 0..) |ep, ei| {
            const key_disp = if (ep.resolved_key) |k|
                try util.redactKey(ctx.arena, k)
            else
                try ctx.arena.dupe(u8, "(unset)");
            eps[ei] = .{
                .base_url = ep.base_url,
                .auth = @tagName(ep.auth),
                .api_key_env = ep.api_key_env,
                .key = key_disp,
            };
        }
        models[mi] = .{
            .name = m.name,
            .backend = m.backend.toString(),
            .api_model = m.api_model,
            .endpoints = eps,
            .defaults = m.defaults,
        };
    }
    const show = Show{
        .config_path = cfg.source_path,
        .output_dir = cfg.output_dir,
        .concurrency = cfg.concurrency,
        .models = models,
    };
    const json = try std.json.Stringify.valueAlloc(ctx.arena, show, .{ .whitespace = .indent_2 });
    try outf(ctx, "{s}\n", .{json});
    return 0;
}

fn cmdModels(ctx: Ctx, c: cli.Common) !u8 {
    var cfg = loadConfig(ctx, c.config_path) catch |e| return reportConfigError(ctx, e, c.config_path);
    defer cfg.deinit();

    if (c.json) {
        const Item = struct {
            name: []const u8,
            backend: []const u8,
            api_model: []const u8,
            endpoints: usize,
            ready: bool,
        };
        var items = try ctx.arena.alloc(Item, cfg.models.len);
        for (cfg.models, 0..) |m, i| {
            items[i] = .{
                .name = m.name,
                .backend = m.backend.toString(),
                .api_model = m.api_model,
                .endpoints = m.endpoints.len,
                .ready = modelReady(m),
            };
        }
        const json = try std.json.Stringify.valueAlloc(ctx.arena, items, .{ .whitespace = .indent_2 });
        try outf(ctx, "{s}\n", .{json});
        return 0;
    }

    try outf(ctx, "configured models ({d}):\n", .{cfg.models.len});
    for (cfg.models) |m| {
        const ready = if (modelReady(m)) "ready" else "no key";
        try outf(ctx, "  {s:<16} backend={s:<12} endpoints={d} [{s}]\n", .{ m.name, m.backend.toString(), m.endpoints.len, ready });
    }
    return 0;
}

fn modelReady(m: types.ModelConfig) bool {
    for (m.endpoints) |ep| {
        if (ep.resolved_key != null) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// generate
// ---------------------------------------------------------------------------

fn cmdGenerate(ctx: Ctx, g: cli.Generate) !u8 {
    var cfg = loadConfig(ctx, g.common.config_path) catch |e| return reportConfigError(ctx, e, g.common.config_path);
    defer cfg.deinit();

    const model = cfg.findModel(g.model.?) orelse return reportUnknownModel(ctx, &cfg, g.model.?);

    var req = types.ImageRequest{
        .prompt = g.prompt.?,
        .api_model = model.api_model,
        .size = g.size,
        .width = g.width,
        .height = g.height,
        .n = 1,
        .output_format = g.format,
        .output_compression = g.compression,
        .quality = g.quality,
        .seed = g.seed,
    };
    req.applyDefaults(model.defaults);

    if (g.dry_run) return dryRun(ctx, model, req, g.n);

    // Resolve the output base path and extension.
    const ext = util.extForFormat(req.output_format);
    const base = try resolveOutputBase(ctx, &cfg, g.output, ext);

    // Build one task per requested image, round-robining endpoints.
    var tasks = try ctx.arena.alloc(scheduler.Task, g.n);
    for (0..g.n) |i| {
        const path = if (g.n == 1) base else try util.numberedPath(ctx.arena, base, i + 1);
        tasks[i] = .{
            .model = model,
            .endpoint = &model.endpoints[i % model.endpoints.len],
            .req = req,
            .output_path = path,
            .arena = std.heap.ArenaAllocator.init(ctx.gpa),
        };
    }
    defer for (tasks) |*t| t.arena.deinit();

    var client = std.http.Client{ .allocator = ctx.gpa, .io = ctx.io };
    defer client.deinit();

    const conc = chooseConcurrency(g.concurrency, cfg.concurrency, model.endpoints.len, g.n);
    if (!g.quiet and !g.common.json) {
        try outf(ctx, "generating {d} image(s) with '{s}' across {d} endpoint(s), concurrency {d}\n", .{ g.n, model.name, model.endpoints.len, conc });
    }

    scheduler.run(tasks, .{
        .concurrency = conc,
        .io = ctx.io,
        .client = &client,
        .progress = !g.quiet and !g.common.json,
    });

    return try renderResults(ctx, model, tasks, g.common.json);
}

fn dryRun(ctx: Ctx, model: *const types.ModelConfig, req: types.ImageRequest, n: u32) !u8 {
    const body = try backend.buildBody(model.backend, ctx.arena, req);
    const ep = &model.endpoints[0];
    try outf(ctx,
        \\dry run (no API call)
        \\  model:    {s}
        \\  backend:  {s}
        \\  endpoint: {s}
        \\  images:   {d}
        \\  request body (n=1 per call):
        \\{s}
        \\
    , .{ model.name, model.backend.toString(), ep.base_url, n, body });
    return 0;
}

// ---------------------------------------------------------------------------
// batch
// ---------------------------------------------------------------------------

fn cmdBatch(ctx: Ctx, b: cli.Batch) !u8 {
    var cfg = loadConfig(ctx, b.common.config_path) catch |e| return reportConfigError(ctx, e, b.common.config_path);
    defer cfg.deinit();

    const manifest_path = try expandPath(ctx, b.manifest.?);
    const bytes = std.Io.Dir.cwd().readFileAlloc(ctx.io, manifest_path, ctx.arena, .limited(8 * 1024 * 1024)) catch |e| {
        try printErr(ctx.io, try std.fmt.allocPrint(ctx.arena, "cannot read manifest '{s}': {s}\n", .{ manifest_path, @errorName(e) }));
        return 1;
    };

    var parsed = std.json.parseFromSlice(std.json.Value, ctx.arena, bytes, .{}) catch |e| {
        try printErr(ctx.io, try std.fmt.allocPrint(ctx.arena, "invalid manifest JSON: {s}\n", .{@errorName(e)}));
        return 1;
    };
    defer parsed.deinit();

    const jobs_v = switch (parsed.value) {
        .object => |o| o.get("jobs") orelse {
            try printErr(ctx.io, "manifest must have a 'jobs' array\n");
            return 1;
        },
        .array => parsed.value,
        else => {
            try printErr(ctx.io, "manifest must be an object with 'jobs' or a top-level array\n");
            return 1;
        },
    };
    if (jobs_v != .array or jobs_v.array.items.len == 0) {
        try printErr(ctx.io, "manifest has no jobs\n");
        return 1;
    }

    // Expand jobs into tasks.
    var tasks = std.ArrayList(scheduler.Task).empty;

    for (jobs_v.array.items) |job_v| {
        if (job_v != .object) continue;
        const job = job_v.object;
        const model_name = jsonStr(job, "model") orelse {
            try printErr(ctx.io, "each job needs a 'model'\n");
            return 1;
        };
        const model = cfg.findModel(model_name) orelse return reportUnknownModel(ctx, &cfg, model_name);
        const prompt = jsonStr(job, "prompt") orelse {
            try printErr(ctx.io, try std.fmt.allocPrint(ctx.arena, "job for model '{s}' needs a 'prompt'\n", .{model_name}));
            return 1;
        };

        var req = types.ImageRequest{
            .prompt = try ctx.arena.dupe(u8, prompt),
            .api_model = model.api_model,
            .size = if (jsonStr(job, "size")) |s| try ctx.arena.dupe(u8, s) else null,
            .width = jsonU32(job, "width"),
            .height = jsonU32(job, "height"),
            .n = 1,
            .output_format = if (jsonStr(job, "format")) |s| try ctx.arena.dupe(u8, s) else null,
            .output_compression = jsonU32(job, "compression"),
            .quality = if (jsonStr(job, "quality")) |s| try ctx.arena.dupe(u8, s) else null,
            .seed = jsonI64(job, "seed"),
        };
        req.applyDefaults(model.defaults);

        const n = jsonU32(job, "n") orelse 1;
        const ext = util.extForFormat(req.output_format);
        const base = if (jsonStr(job, "output")) |o|
            try expandPath(ctx, o)
        else
            try defaultOutputPath(ctx, &cfg, ext);

        for (0..n) |i| {
            const path = if (n == 1) base else try util.numberedPath(ctx.arena, base, i + 1);
            try tasks.append(ctx.arena, .{
                .model = model,
                .endpoint = &model.endpoints[i % model.endpoints.len],
                .req = req,
                .output_path = path,
                .arena = std.heap.ArenaAllocator.init(ctx.gpa),
            });
        }
    }

    const task_slice = try tasks.toOwnedSlice(ctx.arena);
    if (task_slice.len == 0) {
        try printErr(ctx.io, "no valid jobs in manifest\n");
        return 1;
    }
    defer for (task_slice) |*t| t.arena.deinit();

    if (b.dry_run) {
        try outf(ctx, "dry run: {d} task(s) from manifest\n", .{task_slice.len});
        for (task_slice) |*t| {
            const body = try backend.buildBody(t.model.backend, ctx.arena, t.req);
            try outf(ctx, "  {s} -> {s}\n    {s}\n", .{ t.model.name, t.output_path, body });
        }
        return 0;
    }

    var client = std.http.Client{ .allocator = ctx.gpa, .io = ctx.io };
    defer client.deinit();

    const conc = chooseConcurrency(b.concurrency, cfg.concurrency, distinctEndpoints(task_slice), task_slice.len);
    if (!b.quiet and !b.common.json) {
        try outf(ctx, "running {d} task(s), concurrency {d}\n", .{ task_slice.len, conc });
    }

    scheduler.run(task_slice, .{
        .concurrency = conc,
        .io = ctx.io,
        .client = &client,
        .progress = !b.quiet and !b.common.json,
    });

    return try renderBatchResults(ctx, task_slice, b.common.json);
}

// ---------------------------------------------------------------------------
// result rendering
// ---------------------------------------------------------------------------

fn renderResults(ctx: Ctx, model: *const types.ModelConfig, tasks: []scheduler.Task, json: bool) !u8 {
    var ok_count: usize = 0;
    for (tasks) |*t| {
        if (t.ok()) ok_count += 1;
    }
    const failed = tasks.len - ok_count;

    if (json) {
        const ImageOut = struct { path: []const u8, bytes: usize };
        var images = std.ArrayList(ImageOut).empty;
        var errors = std.ArrayList([]const u8).empty;
        for (tasks) |*t| {
            if (t.ok()) {
                for (t.written_paths) |p| try images.append(ctx.arena, .{ .path = p, .bytes = t.bytes_total });
            } else {
                try errors.append(ctx.arena, t.err.?);
            }
        }
        const Result = struct {
            ok: bool,
            model: []const u8,
            backend: []const u8,
            requested: usize,
            succeeded: usize,
            failed: usize,
            images: []ImageOut,
            errors: [][]const u8,
        };
        const result = Result{
            .ok = failed == 0,
            .model = model.name,
            .backend = model.backend.toString(),
            .requested = tasks.len,
            .succeeded = ok_count,
            .failed = failed,
            .images = try images.toOwnedSlice(ctx.arena),
            .errors = try errors.toOwnedSlice(ctx.arena),
        };
        const out = try std.json.Stringify.valueAlloc(ctx.arena, result, .{ .whitespace = .indent_2 });
        try outf(ctx, "{s}\n", .{out});
    } else {
        try outf(ctx, "done: {d} succeeded, {d} failed\n", .{ ok_count, failed });
    }
    return if (failed == 0) 0 else 1;
}

fn renderBatchResults(ctx: Ctx, tasks: []scheduler.Task, json: bool) !u8 {
    var ok_count: usize = 0;
    for (tasks) |*t| {
        if (t.ok()) ok_count += 1;
    }
    const failed = tasks.len - ok_count;

    if (json) {
        const ImageOut = struct { model: []const u8, path: []const u8, bytes: usize, ok: bool, err: ?[]const u8 };
        var items = try ctx.arena.alloc(ImageOut, tasks.len);
        for (tasks, 0..) |*t, i| {
            const p = if (t.written_paths.len > 0) t.written_paths[0] else t.output_path;
            items[i] = .{ .model = t.model.name, .path = p, .bytes = t.bytes_total, .ok = t.ok(), .err = t.err };
        }
        const Result = struct {
            ok: bool,
            total: usize,
            succeeded: usize,
            failed: usize,
            tasks: []ImageOut,
        };
        const result = Result{ .ok = failed == 0, .total = tasks.len, .succeeded = ok_count, .failed = failed, .tasks = items };
        const out = try std.json.Stringify.valueAlloc(ctx.arena, result, .{ .whitespace = .indent_2 });
        try outf(ctx, "{s}\n", .{out});
    } else {
        try outf(ctx, "batch done: {d} succeeded, {d} failed\n", .{ ok_count, failed });
    }
    return if (failed == 0) 0 else 1;
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

fn chooseConcurrency(cli_val: ?usize, cfg_val: u32, endpoints: usize, tasks: usize) usize {
    const want: usize = if (cli_val) |v| v else if (cfg_val > 0) cfg_val else @max(@as(usize, 1), endpoints);
    return @max(@as(usize, 1), @min(want, tasks));
}

fn distinctEndpoints(tasks: []scheduler.Task) usize {
    // Upper bound on useful parallelism: count distinct endpoint pointers.
    var count: usize = 0;
    for (tasks, 0..) |*t, i| {
        var seen = false;
        for (tasks[0..i]) |*p| {
            if (p.endpoint == t.endpoint) {
                seen = true;
                break;
            }
        }
        if (!seen) count += 1;
    }
    return @max(@as(usize, 1), count);
}

fn resolveOutputBase(ctx: Ctx, cfg: *const config.Config, output: ?[]const u8, ext: []const u8) ![]const u8 {
    if (output) |o| return expandPath(ctx, o);
    return defaultOutputPath(ctx, cfg, ext);
}

fn defaultOutputPath(ctx: Ctx, cfg: *const config.Config, ext: []const u8) ![]const u8 {
    const dir = try expandPath(ctx, cfg.output_dir);
    const stamp = try util.timestampName(ctx.arena, ctx.io);
    return std.fmt.allocPrint(ctx.arena, "{s}/imagine-{s}.{s}", .{ dir, stamp, ext });
}

fn expandPath(ctx: Ctx, path: []const u8) ![]u8 {
    const home = ctx.env.get("HOME") orelse ctx.env.get("USERPROFILE");
    return util.expandTilde(ctx.arena, home, path);
}

fn loadConfig(ctx: Ctx, explicit: ?[]const u8) !config.Config {
    const raw = try config.resolvePath(ctx.arena, ctx.env, explicit);
    const path = try expandPath(ctx, raw);
    return config.loadFromFile(ctx.gpa, ctx.io, path, ctx.env);
}

fn reportConfigError(ctx: Ctx, e: anyerror, explicit: ?[]const u8) !u8 {
    const raw = config.resolvePath(ctx.arena, ctx.env, explicit) catch "(unknown)";
    switch (e) {
        error.FileNotFound => {
            try printErr(ctx.io, try std.fmt.allocPrint(ctx.arena, "no config found at {s}\nrun 'imagine config init' to create one\n", .{raw}));
        },
        else => {
            try printErr(ctx.io, try std.fmt.allocPrint(ctx.arena, "failed to load config {s}: {s}\n", .{ raw, @errorName(e) }));
        },
    }
    return 1;
}

fn reportUnknownModel(ctx: Ctx, cfg: *const config.Config, name: []const u8) !u8 {
    try printErr(ctx.io, try std.fmt.allocPrint(ctx.arena, "unknown model: '{s}'\navailable models:\n", .{name}));
    for (cfg.models) |m| {
        try printErr(ctx.io, try std.fmt.allocPrint(ctx.arena, "  {s}\n", .{m.name}));
    }
    return 1;
}

fn jsonStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn jsonU32(obj: std.json.ObjectMap, key: []const u8) ?u32 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| if (i < 0) null else @intCast(i),
        else => null,
    };
}

fn jsonI64(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        else => null,
    };
}

fn collectArgs(arena: Allocator, args: std.process.Args) ![]const []const u8 {
    var it = args.iterate();
    _ = it.next(); // skip program name
    var list = std.ArrayList([]const u8).empty;
    while (it.next()) |a| try list.append(arena, try arena.dupe(u8, a));
    return list.toOwnedSlice(arena);
}

fn makeEnv(map: *std.process.Environ.Map) config.Env {
    const S = struct {
        fn get(ctx: *const anyopaque, name: []const u8) ?[]const u8 {
            const m: *const std.process.Environ.Map = @ptrCast(@alignCast(ctx));
            return m.get(name);
        }
    };
    return .{ .context = map, .func = S.get };
}

fn printOut(io: Io, bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
}

fn printErr(io: Io, bytes: []const u8) !void {
    try std.Io.File.stderr().writeStreamingAll(io, bytes);
}

fn outf(ctx: Ctx, comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(ctx.arena, fmt, args);
    try printOut(ctx.io, s);
}

test {
    std.testing.refAllDecls(@This());
}
