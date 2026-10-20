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
const overlay = @import("overlay.zig");
const text = @import("text.zig");
const check = @import("check.zig");
const audio_util = @import("audio.zig");

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
        .config_convert => |c| cmdConfigConvert(ctx, c),
        .config_show => |c| cmdConfigShow(ctx, c),
        .models => |c| cmdModels(ctx, c),
        .generate => |g| cmdGenerate(ctx, g),
        .voices => |v| cmdVoices(ctx, v),
        .batch => |b| cmdBatch(ctx, b),
        .svg_render => |r| cmdSvgRender(ctx, r),
        .png_compose => |p| cmdPngCompose(ctx, p),
        .text_render => |t| cmdTextRender(ctx, t),
        .compose => |c| cmdCompose(ctx, c),
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
    const fmt = selectInitFormat(ctx, c.format, path) catch return 2;
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
    const data = switch (fmt) {
        .toml => config.template,
        .json => config.json_template,
    };
    try cwd.writeFile(ctx.io, .{ .sub_path = path, .data = data });
    try outf(ctx, "wrote starter {s} config to {s}\nedit model names/URLs, then set your API key (default env: AZURE_OPENAI_APIKEY)\nrun `imagine models` to list configured models\n", .{ fmt.toString(), path });
    return 0;
}

fn cmdConfigConvert(ctx: Ctx, c: cli.ConfigConvert) !u8 {
    var cfg = loadConfig(ctx, c.common.config_path) catch |e| return reportConfigError(ctx, e, c.common.config_path);
    defer cfg.deinit();

    const fmt = selectConvertFormat(ctx, c.to, c.output, cfg.source_format) catch return 2;
    const rendered = try config.renderAlloc(ctx.arena, cfg, fmt);

    if (c.output) |out_raw| {
        const path = try expandPath(ctx, out_raw);
        const cwd = std.Io.Dir.cwd();
        const exists = blk: {
            cwd.access(ctx.io, path, .{}) catch break :blk false;
            break :blk true;
        };
        if (exists and !c.force) {
            try printErr(ctx.io, try std.fmt.allocPrint(ctx.arena, "output already exists: {s} (use --force to overwrite)\n", .{path}));
            return 1;
        }
        if (util.dirName(path)) |_| {
            try util.ensureParentDir(ctx.io, cwd, path);
        }
        try cwd.writeFile(ctx.io, .{ .sub_path = path, .data = rendered });
        try outf(ctx, "wrote {s} config to {s}\n", .{ fmt.toString(), path });
    } else {
        try printOut(ctx.io, rendered);
    }
    return 0;
}

fn cmdConfigShow(ctx: Ctx, c: cli.Common) !u8 {
    var cfg = loadConfig(ctx, c.config_path) catch |e| return reportConfigError(ctx, e, c.config_path);
    defer cfg.deinit();

    if (cfg.source == .preset) {
        try printErr(ctx.io, "no config file found; showing built-in defaults (run 'imagine config init' to write one)\n");
    }

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
        source: []const u8,
        config_path: ?[]const u8,
        output_dir: []const u8,
        concurrency: u32,
        poll_interval: u32,
        task_timeout: u32,
        models: []Model,
    };

    var models = try ctx.arena.alloc(Model, cfg.models.len);
    for (cfg.models, 0..) |m, mi| {
        var eps = try ctx.arena.alloc(Endpoint, m.endpoints.len);
        for (m.endpoints, 0..) |ep, ei| {
            const key_disp = if (ep.auth == .none)
                try ctx.arena.dupe(u8, "(not required)")
            else if (ep.resolved_key) |k|
                try util.redactKey(ctx.arena, k)
            else
                try ctx.arena.dupe(u8, "(unset)");
            eps[ei] = .{
                .base_url = ep.base_url,
                .auth = ep.auth.toString(),
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
        .source = cfg.source.toString(),
        .config_path = cfg.source_path,
        .output_dir = cfg.output_dir,
        .concurrency = cfg.concurrency,
        .poll_interval = cfg.poll_interval,
        .task_timeout = cfg.task_timeout,
        .models = models,
    };
    // Omit nulls: an unset optional is the common case and 11 nulls per model
    // drown the values that are actually configured.
    const json = try std.json.Stringify.valueAlloc(ctx.arena, show, .{
        .whitespace = .indent_2,
        .emit_null_optional_fields = false,
    });
    try outf(ctx, "{s}\n", .{json});
    return 0;
}

fn cmdModels(ctx: Ctx, c: cli.Common) !u8 {
    var cfg = loadConfig(ctx, c.config_path) catch |e| return reportConfigError(ctx, e, c.config_path);
    defer cfg.deinit();

    // A preset whose name a configured model claims is unreachable, so it is
    // not listed at all — `findPreset` resolves the same way.
    var visible = std.ArrayList(types.ModelConfig).empty;
    for (cfg.presets) |m| {
        if (cfg.findModel(m.name) == null) try visible.append(ctx.arena, m);
    }
    const presets = visible.items;

    if (c.json) {
        const Item = struct {
            name: []const u8,
            backend: []const u8,
            media: []const u8,
            api_model: []const u8,
            endpoints: usize,
            credential_status: []const u8,
            availability: []const u8,
            source: []const u8,
            capabilities: types.Capabilities,
        };
        var items = try ctx.arena.alloc(Item, cfg.models.len + presets.len);
        var i: usize = 0;
        for (cfg.models) |m| {
            items[i] = .{
                .name = m.name,
                .backend = m.backend.toString(),
                .media = m.backend.media().toString(),
                .api_model = m.api_model,
                .endpoints = m.endpoints.len,
                .credential_status = credentialStatus(m),
                .availability = "unknown",
                .source = cfg.source.toString(),
                .capabilities = m.backend.capabilities(),
            };
            i += 1;
        }
        // Presets are always listed so an agent can see what is callable with
        // nothing but an API key; `source` tells them apart from real config.
        for (presets) |m| {
            items[i] = .{
                .name = m.name,
                .backend = m.backend.toString(),
                .media = m.backend.media().toString(),
                .api_model = m.api_model,
                .endpoints = m.endpoints.len,
                .credential_status = credentialStatus(m),
                .availability = "unknown",
                .source = "preset",
                .capabilities = m.backend.capabilities(),
            };
            i += 1;
        }
        const json = try std.json.Stringify.valueAlloc(ctx.arena, items, .{ .whitespace = .indent_2 });
        try outf(ctx, "{s}\n", .{json});
        return 0;
    }

    try outf(ctx, "configured models ({d}, source={s}):\n", .{ cfg.models.len, cfg.source.toString() });
    for (cfg.models) |m| {
        try outf(ctx, "  {s:<28} backend={s:<17} endpoints={d} [credentials={s}, availability=unknown]\n", .{ m.name, m.backend.toString(), m.endpoints.len, credentialStatus(m) });
    }
    if (presets.len > 0) {
        try outf(ctx, "built-in presets ({d}, credential from env):\n", .{presets.len});
        for (presets) |m| {
            try outf(ctx, "  {s:<28} backend={s:<17} env={s} [credentials={s}, availability=unknown]\n", .{
                m.name,
                m.backend.toString(),
                m.endpoints[0].api_key_env orelse "-",
                credentialStatus(m),
            });
        }
    }
    return 0;
}

fn credentialStatus(m: types.ModelConfig) []const u8 {
    var required: usize = 0;
    var configured: usize = 0;
    for (m.endpoints) |ep| {
        switch (ep.auth) {
            .none => continue,
            // The token is minted at call time. Listing does not contact the
            // metadata server, and there is no static key to be "missing".
            .google_metadata => {
                required += 1;
                configured += 1;
            },
            .jwt_hs256 => {
                required += 1;
                if (ep.resolved_key != null and ep.resolved_secret != null) configured += 1;
            },
            else => {
                required += 1;
                if (ep.resolved_key != null) configured += 1;
            },
        }
    }
    if (required == 0) return "not_required";
    if (configured == 0) return "missing";
    if (configured < required) return "partial";
    return "configured";
}

/// One provider request the CLI is about to make, as the spend boundary sees it.
const SpendItem = struct {
    model: []const u8,
    kind: types.BackendKind,
    req: types.GenRequest,
    /// True when this task carries a credential, so the provider may charge for
    /// it. Keyless local endpoints (`auth = "none"`) and endpoints whose key did
    /// not resolve are not billable: the first spends nothing, the second fails
    /// on its missing credential before any provider call.
    billable: bool,
};

fn spendItem(model: *const types.ModelConfig, endpoint: *const types.Endpoint, req: types.GenRequest) SpendItem {
    return .{
        .model = model.name,
        .kind = model.backend,
        .req = req,
        .billable = switch (endpoint.auth) {
            .none => false,
            .google_metadata => true,
            .jwt_hs256 => endpoint.resolved_key != null and endpoint.resolved_secret != null,
            else => endpoint.resolved_key != null,
        },
    };
}

/// The `-n` tasks `generate` is about to dispatch: one entry per provider call,
/// with endpoints round-robined exactly as the scheduler will assign them.
fn generateSpendItems(ctx: Ctx, model: *const types.ModelConfig, req: types.GenRequest, count: u32) ![]const SpendItem {
    const items = try ctx.arena.alloc(SpendItem, count);
    for (items, 0..) |*item, i| {
        item.* = spendItem(model, &model.endpoints[i % model.endpoints.len], req);
    }
    return items;
}

/// The tasks `batch` is about to dispatch.
fn batchSpendItems(ctx: Ctx, tasks: []const scheduler.Task) ![]const SpendItem {
    const items = try ctx.arena.alloc(SpendItem, tasks.len);
    for (tasks, 0..) |task, i| {
        items[i] = spendItem(task.model, task.endpoint, task.req);
    }
    return items;
}

/// True when `name` (a model name or backend kind) appears in the
/// comma-separated `IMAGINE_DENY_BACKENDS` list. Entries are case-insensitive
/// and may be backend kinds or aliases (`seedance`, `ark_video`, ...) or a
/// substring of the model name (`doubao-seedance`).
fn denyListHit(deny: []const u8, kind: types.BackendKind, model: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, deny, ", ");
    while (it.next()) |entry| {
        if (types.BackendKind.fromString(entry)) |k| {
            if (k == kind) return entry;
        }
        if (std.ascii.eqlIgnoreCase(entry, kind.toString())) return entry;
        if (std.ascii.indexOfIgnoreCase(model, entry) != null) return entry;
    }
    return null;
}

/// A billable call to a paid cloud video backend (Seedance / Gemini video).
/// Self-hosted LTX-2 is excluded: it only becomes billable when someone gives
/// it a credential, and it is not a pay-per-second cloud product.
fn isPaidVideo(item: SpendItem) bool {
    return item.billable and item.kind.media() == .video and item.kind != .ltx2_video;
}

fn envTruthy(raw: ?[]const u8) bool {
    const v = raw orelse return false;
    return std.mem.eql(u8, v, "1") or std.ascii.eqlIgnoreCase(v, "true") or std.ascii.eqlIgnoreCase(v, "yes");
}

const stop_and_ask =
    "STOP: do not retry, do not switch to another paid backend, and do not set the override yourself.\n" ++
    "Report this block to the user with model, clip count, duration and resolution, and wait for their explicit approval.\n";

/// Hard guard that runs before spend authorization:
///   * `IMAGINE_DENY_BACKENDS` refuses listed backends/models outright;
///   * paid cloud video additionally needs `IMAGINE_SPEND_OK=1`, on top of
///     `--authorize-spend`, so an agent adding the flag alone cannot spend.
fn spendGuard(ctx: Ctx, items: []const SpendItem) !bool {
    if (ctx.env.get("IMAGINE_DENY_BACKENDS")) |deny| {
        for (items) |item| {
            if (denyListHit(deny, item.kind, item.model)) |entry| {
                try printErr(ctx.io, try std.fmt.allocPrint(ctx.arena, "imagine: backend denied by IMAGINE_DENY_BACKENDS ({s}): model={s} backend={s}; nothing was sent\n", .{ entry, item.model, item.kind.toString() }));
                try printErr(ctx.io, stop_and_ask);
                return false;
            }
        }
    }
    if (envTruthy(ctx.env.get("IMAGINE_SPEND_OK"))) return true;
    for (items) |item| {
        if (!isPaidVideo(item)) continue;
        try printErr(ctx.io, try std.fmt.allocPrint(ctx.arena, "imagine: paid cloud video (model={s} backend={s}) requires IMAGINE_SPEND_OK=1 in addition to --authorize-spend; nothing was sent\n", .{ item.model, item.kind.toString() }));
        try printErr(ctx.io, stop_and_ask);
        return false;
    }
    return true;
}

/// Explicit spend authorization. `imagine` ships no price data, so instead of
/// guessing a cost it prints the exact task plan and refuses to dispatch any
/// billable task until the caller acknowledges it. Authorization comes from the
/// invocation (`--authorize-spend` or `IMAGINE_AUTHORIZE_SPEND=1`) and is
/// deliberately not a config-file key: a shared config must not be able to
/// authorize spending silently.
fn authorizeSpend(ctx: Ctx, items: []const SpendItem, authorized: bool) !bool {
    if (!try spendGuard(ctx, items)) return false;
    var billable: usize = 0;
    for (items) |item| {
        if (item.billable) billable += 1;
    }
    if (billable == 0) return true;

    try printErr(ctx.io, try std.fmt.allocPrint(
        ctx.arena,
        "spend authorization: {d} of {d} task(s) call a credentialed provider endpoint\n" ++
            "cost estimate: unavailable (imagine has no provider price data)\n",
        .{ billable, items.len },
    ));
    var index: usize = 0;
    for (items) |item| {
        if (!item.billable) continue;
        index += 1;
        try printSpendItem(ctx, index, item);
    }
    if (authorized) {
        try printErr(ctx.io, "spend authorized: dispatching\n");
        return true;
    }
    try printErr(ctx.io, "blocked before any HTTP request; rerun with --authorize-spend to allow these tasks\n");
    return false;
}

fn spendAuthorized(ctx: Ctx, flag: bool) bool {
    if (flag) return true;
    const raw = ctx.env.get("IMAGINE_AUTHORIZE_SPEND") orelse return false;
    return std.mem.eql(u8, raw, "1") or
        std.ascii.eqlIgnoreCase(raw, "true") or
        std.ascii.eqlIgnoreCase(raw, "yes");
}

fn printSpendItem(ctx: Ctx, index: usize, item: SpendItem) !void {
    const video = item.kind.media() == .video;
    try printErr(ctx.io, try std.fmt.allocPrint(
        ctx.arena,
        "  [{d}] model={s} backend={s} size={s} duration={s} resolution={s} ratio={s}\n",
        .{
            index,
            item.model,
            item.kind.toString(),
            try spendSize(ctx, item.kind, item.req),
            if (video) try spendDuration(ctx, item.req.duration) else "n/a",
            if (video) item.req.resolution orelse "provider-default" else "n/a",
            if (video) spendRatio(item.req) else "n/a",
        },
    ));
}

/// The effective size a request carries: the `--size` token when set, `WxH`
/// derived from `--width/--height`, or a note that the provider default applies.
fn spendSize(ctx: Ctx, kind: types.BackendKind, req: types.GenRequest) ![]const u8 {
    if (req.size) |size| return size;
    if (req.width != null or req.height != null) {
        return std.fmt.allocPrint(ctx.arena, "{s}x{s}", .{
            if (req.width) |w| try std.fmt.allocPrint(ctx.arena, "{d}", .{w}) else "?",
            if (req.height) |h| try std.fmt.allocPrint(ctx.arena, "{d}", .{h}) else "?",
        });
    }
    return if (kind.media() == .video) "n/a" else "provider-default";
}

fn spendDuration(ctx: Ctx, duration: ?u32) ![]const u8 {
    return if (duration) |value| try std.fmt.allocPrint(ctx.arena, "{d}s", .{value}) else "provider-default";
}

/// Video aspect ratio: `--ratio` wins, then a ratio-shaped `--size`, else the
/// provider default.
fn spendRatio(req: types.GenRequest) []const u8 {
    if (req.ratio) |ratio| return ratio;
    if (req.size) |size| {
        if (util.isRatio(size)) return size;
    }
    return "provider-default";
}

fn cmdVoices(ctx: Ctx, v: cli.Voices) !u8 {
    var cfg = loadConfig(ctx, v.common.config_path) catch |e| return reportConfigError(ctx, e, v.common.config_path);
    defer cfg.deinit();
    const model = (try resolveModel(ctx, &cfg, v.model)) orelse return 2;
    if (!model.backend.capabilities().voice_list) {
        try printErr(ctx.io, try std.fmt.allocPrint(ctx.arena, "backend {s} does not publish a voice list\n", .{model.backend.toString()}));
        return 2;
    }
    const req = types.GenRequest{ .prompt = "", .api_model = model.api_model };
    const endpoint = &model.endpoints[0];
    if (!try authorizeSpend(ctx, &.{spendItem(model, endpoint, req)}, spendAuthorized(ctx, v.authorize_spend))) return 2;

    const url = switch (model.backend) {
        .google_cloud_tts => try @import("backends/google_cloud_tts.zig").voicesUrl(ctx.arena, endpoint.base_url),
        .tts_http => try @import("backends/tts_http.zig").siblingUrl(ctx.arena, endpoint.base_url, "voices"),
        else => {
            try printErr(ctx.io, "this backend has no voices URL\n");
            return 2;
        },
    };
    var client = std.http.Client{ .allocator = ctx.gpa, .io = ctx.io };
    defer client.deinit();
    const res = try backend.fetchAuthorized(&client, ctx.arena, model, endpoint, url, ctx.io);
    if (res.err) |msg| {
        try printErr(ctx.io, msg);
        try printErr(ctx.io, "\n");
        return 1;
    }
    if (res.status >= 400) {
        try printErr(ctx.io, try std.fmt.allocPrint(ctx.arena, "voices request failed (HTTP {d})\n", .{res.status}));
        return 1;
    }
    const names = try voiceNamesFromBody(ctx.arena, res.body);
    if (v.common.json) {
        const out = try std.json.Stringify.valueAlloc(ctx.arena, names, .{ .whitespace = .indent_2 });
        try outf(ctx, "{s}\n", .{out});
    } else {
        if (names.len == 0) try outf(ctx, "(no voices)\n", .{});
        for (names) |name| try outf(ctx, "{s}\n", .{name});
    }
    return 0;
}

fn voiceNamesFromBody(allocator: std.mem.Allocator, body: []const u8) ![][]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return &.{};
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o.get("voices") orelse return &.{},
        .array => parsed.value,
        else => return &.{},
    };
    if (root != .array) return &.{};
    var out = std.ArrayList([]const u8).empty;
    for (root.array.items) |item| switch (item) {
        .string => |s| try out.append(allocator, try allocator.dupe(u8, s)),
        .object => |o| {
            const name = if (o.get("name")) |v| (if (v == .string) v.string else null) else null;
            if (name) |s| try out.append(allocator, try allocator.dupe(u8, s));
        },
        else => {},
    };
    return out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// generate
// ---------------------------------------------------------------------------

fn cmdGenerate(ctx: Ctx, g: cli.Generate) !u8 {
    var cfg = loadConfig(ctx, g.common.config_path) catch |e| return reportConfigError(ctx, e, g.common.config_path);
    defer cfg.deinit();

    const model = (try resolveModel(ctx, &cfg, g.model)) orelse return 2;

    var req = types.GenRequest{
        .prompt = g.prompt orelse "",
        .api_model = model.api_model,
        .size = g.size,
        .width = g.width,
        .height = g.height,
        .n = 1,
        .output_format = g.format,
        .output_compression = g.compression,
        .quality = g.quality,
        .seed = g.seed,
        .steps = g.steps,
        .duration = g.duration,
        .resolution = g.resolution,
        .ratio = g.ratio,
        .watermark = g.watermark,
    };
    req.applyDefaults(model.defaults);
    if (try fillGenerateRequest(ctx, g, model.backend, &req)) |code| return code;

    var client = std.http.Client{ .allocator = ctx.gpa, .io = ctx.io };
    defer client.deinit();

    var caps_override: ?types.Capabilities = null;
    if (!g.dry_run and model.backend == .tts_http) {
        caps_override = fetchTtsCaps(ctx, &client, model, &model.endpoints[0]) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Usage => return 2,
            else => return e,
        };
    }

    const expanded = try expandAudioRequests(ctx, model.backend, req, caps_override);
    if (expanded.segmented and g.n > 1) {
        try printErr(ctx.io, "-n cannot be combined with long-text or dialogue expansion; one request already becomes several files\n");
        return 2;
    }
    for (expanded.requests) |*item| {
        if (try check.usageError(ctx.arena, model.backend, item.*, caps_override)) |msg| {
            try printErr(ctx.io, msg);
            try printErr(ctx.io, "\n");
            return 2;
        }
        applyStream(item, model.backend, caps_override);
    }

    if (g.dry_run) {
        if (model.backend == .tts_http and g.stream == .on) {
            try printErr(ctx.io, "dry-run did not fetch /capabilities; a real run rejects --stream when the server reports streaming false\n");
        }
        for (expanded.requests, 0..) |item, i| {
            if (expanded.requests.len > 1) try outf(ctx, "segment {d}/{d}\n", .{ i + 1, expanded.requests.len });
            const code = dryRun(ctx, model, item, if (expanded.requests.len == 1) g.n else 1, &cfg, g.poll_interval, g.timeout) catch |e| switch (e) {
                error.DryRunBodyUnavailable => return 2,
                else => |err| return err,
            };
            if (code != 0) return code;
        }
        return 0;
    }

    const task_count: u32 = if (expanded.requests.len == 1) g.n else @intCast(expanded.requests.len);
    if (!try authorizeSpend(ctx, try generateSpendItems(ctx, model, expanded.requests[0], task_count), spendAuthorized(ctx, g.authorize_spend))) return 2;

    for (expanded.requests) |*item| {
        if (try resolveRequestImages(ctx, &client, model.backend, item)) |code| return code;
    }

    const ext = backend.outputExt(model.backend, expanded.requests[0].output_format);
    const base = try resolveOutputBase(ctx, &cfg, g.output, ext);

    var tasks = try ctx.arena.alloc(scheduler.Task, task_count);
    for (0..task_count) |i| {
        const path = if (task_count == 1) base else try util.numberedPath(ctx.arena, base, i + 1);
        const item = if (expanded.requests.len == 1) expanded.requests[0] else expanded.requests[i];
        tasks[i] = .{
            .model = model,
            .endpoint = &model.endpoints[i % model.endpoints.len],
            .req = item,
            .output_path = path,
            .arena = std.heap.ArenaAllocator.init(ctx.gpa),
        };
    }
    defer for (tasks) |*t| t.arena.deinit();

    const conc = chooseConcurrency(g.concurrency, cfg.concurrency, model.endpoints.len, @as(usize, task_count));
    if (!g.quiet and !g.common.json) {
        try outf(ctx, "generating {d} {s}(s) with '{s}' across {d} endpoint(s), concurrency {d}\n", .{ task_count, model.backend.media().toString(), model.name, model.endpoints.len, conc });
    }

    scheduler.run(tasks, .{
        .concurrency = conc,
        .io = ctx.io,
        .client = &client,
        .progress = !g.quiet and !g.common.json,
        .poll_interval_secs = g.poll_interval orelse cfg.poll_interval,
        .timeout_secs = g.timeout orelse cfg.task_timeout,
    });

    if (expanded.segmented) writeSegmentsSidecar(ctx, base, expanded, tasks) catch {};
    return try renderResults(ctx, model, tasks, g.common.json);
}

const Expanded = struct {
    requests: []types.GenRequest,
    segmented: bool = false,
    segments: []const audio_util.Segment = &.{},
};

fn fillGenerateRequest(ctx: Ctx, g: cli.Generate, kind: types.BackendKind, req: *types.GenRequest) !?u8 {
    if (g.text_file) |path| req.prompt = try readTextInput(ctx, path, "--text-file") orelse return 2;
    if (g.ssml_file) |path| req.prompt = try readTextInput(ctx, path, "--ssml-file") orelse return 2;

    var images = std.ArrayList(types.InputImage).empty;
    if (try appendInputImages(ctx, &images, g.images, .auto)) |code| return code;
    if (try appendInputImages(ctx, &images, g.first_frames, .first_frame)) |code| return code;
    if (try appendInputImages(ctx, &images, g.last_frames, .last_frame)) |code| return code;
    if (try appendInputImages(ctx, &images, g.ref_images, .reference)) |code| return code;
    req.images = try images.toOwnedSlice(ctx.arena);

    const audio_flags = g.voice != null or g.language != null or g.style != null or g.speed != null or
        g.pitch != null or g.voice_reference != null or g.reference_text != null or g.sample_rate != null or
        g.speech_mode != null or g.dialogue_file != null or g.ssml_file != null or g.text_file != null or
        g.stream != .off;
    if (audio_flags or kind.media() == .audio) {
        var params = types.AudioParams{
            .voice = g.voice,
            .language = g.language,
            .style = g.style,
            .speed = g.speed,
            .pitch = g.pitch,
            .sample_rate = g.sample_rate,
            .reference_text = g.reference_text,
            .stream = g.stream,
            .ssml = g.ssml_file != null,
        };
        if (g.speech_mode) |raw| {
            params.mode = types.SpeechMode.fromString(raw) orelse {
                try printErr(ctx.io, try std.fmt.allocPrint(ctx.arena, "invalid --mode: {s}\n", .{raw}));
                return 2;
            };
        }
        if (g.dialogue_file) |path| {
            const raw = try readTextInput(ctx, path, "--dialogue-file") orelse return 2;
            params.dialogue = audio_util.parseDialogue(ctx.arena, raw) catch {
                try printErr(ctx.io, "--dialogue-file must be a JSON array of {speaker, text} objects\n");
                return 2;
            };
            if (g.speech_mode == null) params.mode = .dialogue;
        }
        if (g.voice_reference) |path| {
            params.reference = readAudioInput(ctx, path) catch |e| switch (e) {
                error.InputImageUnreadable => return 2,
                else => return e,
            };
        }
        req.audio = params;
    }
    return null;
}

fn appendInputImages(ctx: Ctx, list: *std.ArrayList(types.InputImage), sources: []const []const u8, role: types.ImageRole) !?u8 {
    for (sources) |source| {
        var img = readInputImage(ctx, source) catch |e| switch (e) {
            error.InputImageUnreadable => return 2,
            else => return e,
        };
        img.role = role;
        try list.append(ctx.arena, img);
    }
    return null;
}

fn readTextInput(ctx: Ctx, raw: []const u8, flag: []const u8) !?[]u8 {
    const path = try expandPath(ctx, raw);
    return std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .limited(8 * 1024 * 1024)) catch |e| {
        try printErr(ctx.io, try std.fmt.allocPrint(ctx.arena, "cannot read {s} '{s}': {s}\n", .{ flag, path, @errorName(e) }));
        return null;
    };
}

fn readAudioInput(ctx: Ctx, raw: []const u8) !types.AudioInput {
    if (util.isHttpUrl(raw)) {
        return .{ .source = try ctx.arena.dupe(u8, raw), .mime = "audio/wav" };
    }
    const path = try expandPath(ctx, raw);
    const bytes = std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .limited(max_input_image_bytes)) catch |e| {
        try printErr(ctx.io, try std.fmt.allocPrint(ctx.arena, "cannot read --voice-reference '{s}': {s}\n", .{ path, @errorName(e) }));
        return error.InputImageUnreadable;
    };
    return .{ .source = path, .bytes = bytes, .mime = "audio/wav" };
}

fn expandAudioRequests(ctx: Ctx, kind: types.BackendKind, req: types.GenRequest, override: ?types.Capabilities) !Expanded {
    const caps = override orelse kind.capabilities();
    const params = req.audio orelse {
        const one = try ctx.arena.alloc(types.GenRequest, 1);
        one[0] = req;
        return .{ .requests = one };
    };
    if (params.mode == .dialogue and params.dialogue.len > 1) {
        var speakers: u32 = 0;
        for (params.dialogue, 0..) |turn, i| {
            var seen = false;
            for (params.dialogue[0..i]) |prev| {
                if (std.mem.eql(u8, prev.speaker, turn.speaker)) seen = true;
            }
            if (!seen) speakers += 1;
        }
        const native = caps.native_dialogue and speakers <= caps.max_speakers and speakers > 0;
        if (!native) {
            const out = try ctx.arena.alloc(types.GenRequest, params.dialogue.len);
            for (params.dialogue, 0..) |turn, i| {
                var copy = req;
                var audio = params;
                audio.mode = .speech;
                audio.dialogue = &.{};
                audio.voice = turn.voice orelse params.voice;
                audio.style = turn.style orelse params.style;
                audio.language = turn.language orelse params.language;
                copy.prompt = turn.text;
                copy.audio = audio;
                out[i] = copy;
            }
            return .{ .requests = out, .segmented = true };
        }
    }
    if (caps.max_chars > 0 and params.mode != .dialogue and !params.ssml and audio_util.utf8Len(req.prompt) > caps.max_chars) {
        const parts = try audio_util.splitText(ctx.arena, req.prompt, caps.max_chars);
        const out = try ctx.arena.alloc(types.GenRequest, parts.len);
        for (parts, 0..) |part, i| {
            var copy = req;
            copy.prompt = part.text;
            out[i] = copy;
        }
        return .{ .requests = out, .segmented = true, .segments = parts };
    }
    const one = try ctx.arena.alloc(types.GenRequest, 1);
    one[0] = req;
    return .{ .requests = one };
}

fn applyStream(req: *types.GenRequest, kind: types.BackendKind, override: ?types.Capabilities) void {
    if (req.audio == null) return;
    var params = req.audio.?;
    const streaming = (override orelse kind.capabilities()).streaming;
    params.stream_applied = kind == .tts_http and streaming and (params.stream == .on or params.stream == .auto);
    req.audio = params;
}

fn fetchTtsCaps(ctx: Ctx, client: *std.http.Client, model: *const types.ModelConfig, endpoint: *const types.Endpoint) !types.Capabilities {
    const tts = @import("backends/tts_http.zig");
    const url = try tts.siblingUrl(ctx.arena, endpoint.base_url, "capabilities");
    const res = try backend.fetchAuthorized(client, ctx.arena, model, endpoint, url, ctx.io);
    if (res.err) |msg| {
        try printErr(ctx.io, msg);
        try printErr(ctx.io, "\n");
        return error.Usage;
    }
    if (res.status >= 400) {
        try printErr(ctx.io, try std.fmt.allocPrint(ctx.arena, "tts capabilities request failed (HTTP {d})\n", .{res.status}));
        return error.Usage;
    }
    const server = tts.parseCapabilities(ctx.arena, res.body) catch {
        try printErr(ctx.io, "tts capabilities response was not the imagine.tts_http document\n");
        return error.Usage;
    };
    return server.narrow();
}

fn resolveRequestImages(ctx: Ctx, client: *std.http.Client, kind: types.BackendKind, req: *types.GenRequest) !?u8 {
    if (req.images.len > 0) {
        const resolved = try ctx.arena.alloc(types.InputImage, req.images.len);
        for (req.images, 0..) |img, i| {
            resolved[i] = backend.resolveInputImage(client, ctx.arena, kind, img) catch {
                try printErr(ctx.io, try std.fmt.allocPrint(ctx.arena, "cannot fetch --image '{s}' for backend {s}\n", .{ img.source, kind.toString() }));
                return 1;
            };
        }
        req.images = resolved;
    }
    if (req.audio) |*params| {
        if (params.reference) |ref| {
            if (ref.bytes == null and util.isHttpUrl(ref.source)) {
                const got = backend.fetchAuthorized(client, ctx.arena, &.{ .name = "", .backend = kind, .api_model = req.api_model, .endpoints = &.{} }, &.{ .base_url = "", .auth = .none }, ref.source, ctx.io) catch return 1;
                // A reference download must not send the API key. auth none above does that.
                if (got.err != null or got.status >= 400) {
                    try printErr(ctx.io, try std.fmt.allocPrint(ctx.arena, "cannot fetch --voice-reference '{s}'\n", .{ref.source}));
                    return 1;
                }
                params.reference = .{ .source = ref.source, .bytes = got.body, .mime = ref.mime };
            }
        }
    }
    return null;
}

fn writeSegmentsSidecar(ctx: Ctx, base: []const u8, expanded: Expanded, tasks: []scheduler.Task) !void {
    const Side = struct {
        index: usize,
        char_start: usize = 0,
        char_end: usize = 0,
        path: []const u8,
        text: []const u8,
    };
    var rows = try ctx.arena.alloc(Side, tasks.len);
    for (tasks, 0..) |task, i| {
        const seg = if (i < expanded.segments.len) expanded.segments[i] else audio_util.Segment{ .text = task.req.prompt, .char_start = 0, .char_end = 0 };
        rows[i] = .{
            .index = i + 1,
            .char_start = seg.char_start,
            .char_end = seg.char_end,
            .path = if (task.written_paths.len > 0) task.written_paths[0] else task.output_path,
            .text = task.req.prompt,
        };
    }
    const doc = try std.json.Stringify.valueAlloc(ctx.arena, rows, .{ .whitespace = .indent_2 });
    const path = try std.fmt.allocPrint(ctx.arena, "{s}.segments.json", .{base});
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = path, .data = doc });
}

/// `--image` on a backend that takes no image input. Silently ignoring the file
/// would let an agent believe the reference was used, so it is a usage error.
fn reportUnsupportedImage(ctx: Ctx, kind: types.BackendKind) !u8 {
    try printErr(ctx.io, try std.fmt.allocPrint(
        ctx.arena,
        "backend {s} takes no --image input (supported by: qwen_image up to 10, mai_image up to 5, seedance, gemini_video, volcengine_image, ltx2_video)\n",
        .{kind.toString()},
    ));
    return 2;
}

fn validateInputImageCount(ctx: Ctx, kind: types.BackendKind, count: usize) !bool {
    if (count == 0) return true;
    const max = kind.maxInputImages();
    if (max == 0) {
        _ = try reportUnsupportedImage(ctx, kind);
        return false;
    }
    if (count > max) {
        _ = try reportTooManyInputImages(ctx, kind, count, max);
        return false;
    }
    return true;
}

fn reportTooManyInputImages(ctx: Ctx, kind: types.BackendKind, count: usize, max: usize) !u8 {
    try printErr(ctx.io, try std.fmt.allocPrint(
        ctx.arena,
        "backend {s} accepts at most {d} --image input(s); received {d}\n",
        .{ kind.toString(), max, count },
    ));
    return 2;
}

/// The create body `--dry-run` prints. Inlined `--image` references can put
/// megabytes of base64 into that output, so each payload is elided; everything
/// else is verbatim. A body that cannot be built without network access (a URL
/// image for a bytes-only backend) is reported as a message, not a Zig trace.
fn dryRunBody(ctx: Ctx, model: *const types.ModelConfig, req: types.GenRequest) ![]const u8 {
    const body = backend.buildBody(model.backend, ctx.arena, req) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InputImageNotFetched => {
            try printErr(ctx.io, "this backend needs the --image bytes inline, but --dry-run makes no network call; pass a local file, or drop --dry-run to fetch the URL\n");
            return error.DryRunBodyUnavailable;
        },
        error.TooManyReferenceImages => {
            try printErr(ctx.io, "this backend supports at most 5 reference images\n");
            return error.DryRunBodyUnavailable;
        },
        error.MissingVoice => {
            try printErr(ctx.io, "this request needs --voice\n");
            return error.DryRunBodyUnavailable;
        },
    };
    if (model.backend == .mai_image) {
        const mai_image = @import("backends/mai_image.zig");
        if (mai_image.isEdit(req)) {
            return mai_image.cleanDryRunBody(ctx.arena, body);
        }
    }
    var redacted = body;
    for (req.images) |img| {
        const bytes = img.bytes orelse continue;
        if (bytes.len == 0) continue;
        const b64 = try util.base64EncodeAlloc(ctx.arena, bytes);
        while (std.mem.indexOf(u8, redacted, b64)) |at| {
            const note = try std.fmt.allocPrint(ctx.arena, "<{d} bytes of base64 elided>", .{b64.len});
            redacted = try std.fmt.allocPrint(ctx.arena, "{s}{s}{s}", .{ redacted[0..at], note, redacted[at + b64.len ..] });
        }
    }
    return redacted;
}

/// Largest `--image` file read into memory. Ark caps a request body at 64 MB and
/// a single image at 30 MB; 32 MB leaves room for the prompt and encoding.
const max_input_image_bytes: usize = 32 * 1024 * 1024;

/// Read each repeated `--image` input. Local files are read here so a typo
/// fails before any provider request; URLs are left for backend-specific fetch.
fn readInputImages(ctx: Ctx, sources: []const []const u8) ![]types.InputImage {
    const images = try ctx.arena.alloc(types.InputImage, sources.len);
    for (sources, 0..) |source, i| images[i] = try readInputImage(ctx, source);
    return images;
}

fn readInputImage(ctx: Ctx, raw: []const u8) !types.InputImage {
    if (util.isHttpUrl(raw)) {
        return .{
            .source = try ctx.arena.dupe(u8, raw),
            .mime = util.mimeForPath(raw),
        };
    }
    const path = try expandPath(ctx, raw);
    const bytes = std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .limited(max_input_image_bytes)) catch |e| {
        try printErr(ctx.io, try std.fmt.allocPrint(ctx.arena, "cannot read --image '{s}': {s}\n", .{ path, @errorName(e) }));
        return error.InputImageUnreadable;
    };
    return .{
        .source = path,
        .bytes = bytes,
        // Magic bytes beat the extension: a misnamed file would otherwise be
        // rejected by the provider for declaring the wrong type.
        .mime = util.sniffImageMime(bytes) orelse util.mimeForPath(path),
    };
}

fn dryRun(
    ctx: Ctx,
    model: *const types.ModelConfig,
    req: types.GenRequest,
    n: u32,
    cfg: *const config.Config,
    poll_interval: ?u32,
    timeout: ?u32,
) !u8 {
    const body = try dryRunBody(ctx, model, req);
    const ep = &model.endpoints[0];
    const target = backend.targetUrl(model.backend, ctx.arena, ep.base_url, req) catch ep.base_url;
    const media = model.backend.media();
    try outf(ctx,
        \\dry run (no API call)
        \\  model:    {s}
        \\  backend:  {s}
        \\  media:    {s}
        \\  endpoint: {s}
        \\  assets:   {d}
        \\  spend:    nothing dispatched; imagine has no price data, and a real
        \\            run asks for --authorize-spend before any provider call
        \\  request body (n=1 per call):
        \\{s}
        \\
    , .{ model.name, model.backend.toString(), media.toString(), target, n, body });
    if (model.backend.flow() == .async_task) {
        try outf(ctx,
            \\  async: this backend creates a provider task and polls it
            \\  poll:  every {d}s, giving up after {d}s (--poll-interval/--timeout)
            \\
        , .{ poll_interval orelse cfg.poll_interval, timeout orelse cfg.task_timeout });
    }
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
        const model = cfg.findModel(model_name) orelse cfg.findPreset(model_name) orelse {
            _ = try reportUnknownModel(ctx, &cfg, model_name);
            return 2;
        };
        const prompt = jsonStr(job, "prompt") orelse {
            try printErr(ctx.io, try std.fmt.allocPrint(ctx.arena, "job for model '{s}' needs a 'prompt'\n", .{model_name}));
            return 1;
        };

        var req = types.GenRequest{
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
            .steps = jsonU32(job, "steps"),
            .duration = jsonU32(job, "duration"),
            .resolution = if (jsonStr(job, "resolution")) |s| try ctx.arena.dupe(u8, s) else null,
            .ratio = if (jsonStr(job, "ratio")) |s| try ctx.arena.dupe(u8, s) else null,
            .watermark = jsonBool(job, "watermark"),
        };
        req.applyDefaults(model.defaults);
        const image_sources = batchImageSources(ctx.arena, job) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try printErr(ctx.io, "each job may specify either 'image' (a string) or 'images' (an array of strings), not both\n");
                return 1;
            },
        };
        req.images = readInputImages(ctx, image_sources) catch |e| switch (e) {
            error.InputImageUnreadable => return 2,
            else => return e,
        };
        if (jsonStr(job, "voice")) |voice| {
            req.audio = .{
                .voice = try ctx.arena.dupe(u8, voice),
                .language = if (jsonStr(job, "language")) |s| try ctx.arena.dupe(u8, s) else null,
                .style = if (jsonStr(job, "style")) |s| try ctx.arena.dupe(u8, s) else null,
            };
        }
        if (try check.usageError(ctx.arena, model.backend, req, null)) |msg| {
            try printErr(ctx.io, msg);
            try printErr(ctx.io, "\n");
            return 2;
        }

        const n = jsonU32(job, "n") orelse 1;
        const ext = backend.outputExt(model.backend, req.output_format);
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
        try outf(ctx, "dry run: {d} task(s) from manifest (nothing dispatched; a real run calls credentialed endpoints only with --authorize-spend)\n", .{task_slice.len});
        for (task_slice) |*t| {
            const body = dryRunBody(ctx, t.model, t.req) catch |e| switch (e) {
                error.DryRunBodyUnavailable => return 2,
                else => return e,
            };
            try outf(ctx, "  {s} -> {s}\n    {s}\n", .{ t.model.name, t.output_path, body });
        }
        return 0;
    }
    if (!try authorizeSpend(ctx, try batchSpendItems(ctx, task_slice), spendAuthorized(ctx, b.authorize_spend))) return 2;

    var client = std.http.Client{ .allocator = ctx.gpa, .io = ctx.io };
    defer client.deinit();

    // Same rule as `generate`: fetch every URL that a backend cannot accept
    // directly before the scheduler starts.
    for (task_slice) |*t| {
        if (t.req.images.len == 0) continue;
        const resolved = try ctx.arena.alloc(types.InputImage, t.req.images.len);
        for (t.req.images, 0..) |img, i| {
            resolved[i] = backend.resolveInputImage(&client, ctx.arena, t.model.backend, img) catch {
                try printErr(ctx.io, try std.fmt.allocPrint(ctx.arena, "cannot fetch --image '{s}' for backend {s}\n", .{ img.source, t.model.backend.toString() }));
                return 1;
            };
        }
        t.req.images = resolved;
    }

    const conc = chooseConcurrency(b.concurrency, cfg.concurrency, distinctEndpoints(task_slice), task_slice.len);
    if (!b.quiet and !b.common.json) {
        try outf(ctx, "running {d} task(s), concurrency {d}\n", .{ task_slice.len, conc });
    }

    scheduler.run(task_slice, .{
        .concurrency = conc,
        .io = ctx.io,
        .client = &client,
        .progress = !b.quiet and !b.common.json,
        .poll_interval_secs = b.poll_interval orelse cfg.poll_interval,
        .timeout_secs = b.timeout orelse cfg.task_timeout,
    });

    return try renderBatchResults(ctx, task_slice, b.common.json);
}

// ---------------------------------------------------------------------------
// result rendering
// ---------------------------------------------------------------------------

fn cmdCompose(ctx: Ctx, c: cli.Compose) !u8 {
    const base = try expandPath(ctx, c.base.?);
    const svg = try expandPath(ctx, c.svg.?);
    const output = try expandPath(ctx, c.output.?);
    const blend = if (c.blend) |b| overlay.BlendMode.fromString(b) orelse {
        try printErr(ctx.io, try std.fmt.allocPrint(ctx.arena, "unknown blend mode: {s}\n", .{b}));
        return 2;
    } else overlay.BlendMode.normal;

    if (util.dirName(output)) |_| {
        try util.ensureParentDir(ctx.io, std.Io.Dir.cwd(), output);
    }

    overlay.compose(ctx.arena, .{
        .base_path = base,
        .svg_path = svg,
        .output_path = output,
        .x = c.x,
        .y = c.y,
        .width = c.width,
        .height = c.height,
        .opacity = c.opacity,
        .blend = blend,
    }) catch |e| {
        return reportOverlayError(ctx, "compose", e);
    };

    try outf(ctx, "wrote composed PNG to {s}\n", .{output});
    return 0;
}

fn cmdSvgRender(ctx: Ctx, r: cli.SvgRender) !u8 {
    const input = try expandPath(ctx, r.input.?);
    const output = try expandPath(ctx, r.output.?);
    if (util.dirName(output)) |_| {
        try util.ensureParentDir(ctx.io, std.Io.Dir.cwd(), output);
    }
    overlay.renderSvgToPng(ctx.arena, .{
        .input_path = input,
        .output_path = output,
        .width = r.width,
        .height = r.height,
    }) catch |e| return reportOverlayError(ctx, "svg render", e);
    try outf(ctx, "wrote rendered PNG to {s}\n", .{output});
    return 0;
}

fn cmdPngCompose(ctx: Ctx, p: cli.PngCompose) !u8 {
    const base = try expandPath(ctx, p.base.?);
    const output = try expandPath(ctx, p.output.?);
    if (util.dirName(output)) |_| {
        try util.ensureParentDir(ctx.io, std.Io.Dir.cwd(), output);
    }

    var layers = try ctx.arena.alloc(overlay.Layer, p.layers.len);
    for (p.layers, 0..) |spec, i| {
        layers[i] = parseLayerSpec(ctx, spec) catch |e| {
            try printErr(ctx.io, try std.fmt.allocPrint(ctx.arena, "invalid layer spec '{s}': {s}\n", .{ spec, @errorName(e) }));
            return 2;
        };
    }

    overlay.composePng(ctx.arena, .{
        .base_path = base,
        .output_path = output,
        .layers = layers,
    }) catch |e| return reportOverlayError(ctx, "png compose", e);
    try outf(ctx, "wrote composed PNG to {s}\n", .{output});
    return 0;
}

fn cmdTextRender(ctx: Ctx, t: cli.TextRender) !u8 {
    const output = try expandPath(ctx, t.output.?);
    if (util.dirName(output)) |_| {
        try util.ensureParentDir(ctx.io, std.Io.Dir.cwd(), output);
    }
    const text_align = text.Align.fromString(t.text_align) orelse {
        try printErr(ctx.io, try std.fmt.allocPrint(ctx.arena, "unknown text align: {s} (expected left, center, or right)\n", .{t.text_align}));
        return 2;
    };
    const rendered = text.renderSvgAlloc(ctx.arena, .{
        .text = t.text.?,
        .width = t.width.?,
        .height = t.height,
        .font = t.font orelse "Arial",
        .size = t.size,
        .color = t.color,
        .stroke = t.stroke,
        .stroke_width = t.stroke_width,
        .text_align = text_align,
        .line_height = t.line_height,
        .padding = t.padding,
    }) catch |e| {
        try printErr(ctx.io, try std.fmt.allocPrint(ctx.arena, "text render failed: {s}\n", .{@errorName(e)}));
        return 1;
    };

    overlay.renderSvgDataToPng(ctx.arena, .{
        .svg = rendered.svg,
        .output_path = output,
        .width = rendered.width,
        .height = rendered.height,
    }) catch |e| return reportOverlayError(ctx, "text render", e);

    try outf(ctx, "wrote rendered text PNG to {s}\n", .{output});
    return 0;
}

fn reportOverlayError(ctx: Ctx, command: []const u8, e: anyerror) !u8 {
    switch (e) {
        error.SvgOverlayDisabled => {
            try printErr(ctx.io, try std.fmt.allocPrint(ctx.arena, "{s} requires SVG rendering support; rebuild with 'zig build -Dsvg-overlay=true' and ensure libresvg is installed\n", .{command}));
        },
        else => {
            try printErr(ctx.io, try std.fmt.allocPrint(ctx.arena, "{s} failed: {s}\n", .{ command, @errorName(e) }));
        },
    }
    return 1;
}

fn renderResults(ctx: Ctx, model: *const types.ModelConfig, tasks: []scheduler.Task, json: bool) !u8 {
    var ok_count: usize = 0;
    for (tasks) |*t| {
        if (t.ok()) ok_count += 1;
    }
    const failed = tasks.len - ok_count;

    if (json) {
        const AssetOut = struct { path: []const u8, bytes: usize };
        const AudioOut = struct {
            path: []const u8,
            bytes: usize,
            mime: ?[]const u8 = null,
            container: ?[]const u8 = null,
            codec: ?[]const u8 = null,
            sample_rate_hz: ?u32 = null,
            channels: ?u32 = null,
            duration_ms: ?u64 = null,
            voice: ?[]const u8 = null,
            alignment_path: ?[]const u8 = null,
            alignment: ?[]const u8 = null,
            stream_applied: ?bool = null,
        };
        var images = std.ArrayList(AssetOut).empty;
        var videos = std.ArrayList(AssetOut).empty;
        var audios = std.ArrayList(AudioOut).empty;
        var errors = std.ArrayList([]const u8).empty;
        // Assets land under the key matching the model's media kind. The other
        // arrays stay present (and empty) so the image/video shape never changes.
        for (tasks) |*t| {
            if (!t.ok()) {
                try errors.append(ctx.arena, t.err.?);
                continue;
            }
            switch (model.backend.media()) {
                .video => for (t.written_paths) |p| try videos.append(ctx.arena, .{ .path = p, .bytes = t.bytes_total }),
                .audio => for (t.written_paths) |p| try audios.append(ctx.arena, .{
                    .path = p,
                    .bytes = t.bytes_total,
                    .mime = t.meta.mime,
                    .container = t.meta.container,
                    .codec = t.meta.codec,
                    .sample_rate_hz = t.meta.sample_rate_hz,
                    .channels = t.meta.channels,
                    .duration_ms = t.meta.duration_ms,
                    .voice = t.meta.voice,
                    .alignment_path = t.alignment_path,
                    .alignment = if (t.alignment_path != null) null else (t.meta.alignment orelse "unsupported"),
                    .stream_applied = t.meta.stream_applied,
                }),
                .image => for (t.written_paths) |p| try images.append(ctx.arena, .{ .path = p, .bytes = t.bytes_total }),
            }
        }
        const Result = struct {
            ok: bool,
            media: []const u8,
            model: []const u8,
            backend: []const u8,
            requested: usize,
            succeeded: usize,
            failed: usize,
            images: []AssetOut,
            videos: []AssetOut,
            audios: []AudioOut,
            errors: [][]const u8,
        };
        const result = Result{
            .ok = failed == 0,
            .media = model.backend.media().toString(),
            .model = model.name,
            .backend = model.backend.toString(),
            .requested = tasks.len,
            .succeeded = ok_count,
            .failed = failed,
            .images = try images.toOwnedSlice(ctx.arena),
            .videos = try videos.toOwnedSlice(ctx.arena),
            .audios = try audios.toOwnedSlice(ctx.arena),
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
        const TaskOut = struct {
            model: []const u8,
            media: []const u8,
            path: []const u8,
            bytes: usize,
            ok: bool,
            err: ?[]const u8,
        };
        var items = try ctx.arena.alloc(TaskOut, tasks.len);
        for (tasks, 0..) |*t, i| {
            const p = if (t.written_paths.len > 0) t.written_paths[0] else t.output_path;
            items[i] = .{
                .model = t.model.name,
                .media = t.model.backend.media().toString(),
                .path = p,
                .bytes = t.bytes_total,
                .ok = t.ok(),
                .err = t.err,
            };
        }
        const Result = struct {
            ok: bool,
            total: usize,
            succeeded: usize,
            failed: usize,
            tasks: []TaskOut,
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
    // 1) Explicit --config: file only.
    if (explicit) |p| {
        const path = try expandPath(ctx, p);
        return config.loadFromFile(ctx.gpa, ctx.io, path, ctx.env);
    }

    // 2) $IMAGINE_CONFIG: file only.
    if (ctx.env.get(config.env_config_path)) |p| {
        if (p.len > 0) {
            const path = try expandPath(ctx, p);
            return config.loadFromFile(ctx.gpa, ctx.io, path, ctx.env);
        }
    }

    // 3) Default toml, then legacy json.
    const raw = try config.resolvePath(ctx.arena, ctx.env, null);
    const path = try expandPath(ctx, raw);
    return config.loadFromFile(ctx.gpa, ctx.io, path, ctx.env) catch |e| {
        if (e != error.FileNotFound) return e;

        const legacy_raw = try config.resolveLegacyJsonPath(ctx.arena, ctx.env);
        const legacy_path = try expandPath(ctx, legacy_raw);
        return config.loadFromFile(ctx.gpa, ctx.io, legacy_path, ctx.env) catch |e2| {
            if (e2 != error.FileNotFound) return e2;

            // 4) Ephemeral env synthesis when no config file exists.
            if (config.ephemeralReady(ctx.env)) {
                return config.loadEphemeral(ctx.gpa, ctx.env);
            }
            if (config.ephemeralIntent(ctx.env)) {
                return error.EphemeralIncomplete;
            }
            // 5) Nothing configured at all: built-in presets are still callable
            //    with just their API key in the environment.
            return config.loadPresetsOnly(ctx.gpa, ctx.env);
        };
    };
}

/// Pick a model by name, or the sole configured model when `--model` is omitted.
/// For ephemeral configs, `--model` may retarget the single model's name/api_model.
fn resolveModel(ctx: Ctx, cfg: *config.Config, requested: ?[]const u8) !?*const types.ModelConfig {
    if (requested) |name| {
        if (cfg.findModel(name)) |m| return m;
        if (cfg.source == .ephemeral and cfg.models.len == 1) {
            const m = &cfg.models[0];
            m.name = try cfg.arena.allocator().dupe(u8, name);
            if (!cfg.ephemeral_api_model_set) {
                m.api_model = m.name;
            }
            return m;
        }
        // Built-in presets are the last resort, so a config model always wins.
        if (cfg.findPreset(name)) |m| return m;
        _ = try reportUnknownModel(ctx, cfg, name);
        return null;
    }
    if (cfg.models.len == 1) return &cfg.models[0];
    if (cfg.models.len == 0 and cfg.presets.len > 0) {
        try printErr(ctx.io, "missing required option: --model (nothing configured; pass a built-in preset name from `imagine models`)\n");
        return null;
    }
    try printErr(ctx.io, "missing required option: --model (multiple models configured; run `imagine models`)\n");
    return null;
}

fn selectInitFormat(ctx: Ctx, requested: ?[]const u8, path: []const u8) !config.Format {
    if (requested) |f| {
        return config.Format.fromString(f) orelse {
            try printErr(ctx.io, try std.fmt.allocPrint(ctx.arena, "unknown config format: {s} (expected toml or json)\n", .{f}));
            return error.InvalidConfigFormat;
        };
    }
    return config.inferFormatFromPath(path) orelse .toml;
}

fn selectConvertFormat(ctx: Ctx, requested: ?[]const u8, output: ?[]const u8, input: ?config.Format) !config.Format {
    if (requested) |f| {
        return config.Format.fromString(f) orelse {
            try printErr(ctx.io, try std.fmt.allocPrint(ctx.arena, "unknown config format: {s} (expected toml or json)\n", .{f}));
            return error.InvalidConfigFormat;
        };
    }
    if (output) |p| {
        if (config.inferFormatFromPath(p)) |f| return f;
    }
    return switch (input orelse .json) {
        .json => .toml,
        .toml => .json,
    };
}

fn reportConfigError(ctx: Ctx, e: anyerror, explicit: ?[]const u8) !u8 {
    const raw = config.resolvePath(ctx.arena, ctx.env, explicit) catch "(unknown)";
    switch (e) {
        error.FileNotFound => {
            const hint = try config.noConfigHint(ctx.arena, ctx.env);
            try printErr(ctx.io, try std.fmt.allocPrint(ctx.arena, "no config found at {s}\n{s}", .{ raw, hint }));
        },
        error.EphemeralIncomplete, error.EphemeralNoCredential => {
            const hint = try config.noConfigHint(ctx.arena, ctx.env);
            try printErr(ctx.io, hint);
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
    if (cfg.presets.len > 0) {
        try printErr(ctx.io, "built-in presets (key from env):\n");
        for (cfg.presets) |m| {
            try printErr(ctx.io, try std.fmt.allocPrint(ctx.arena, "  {s}\n", .{m.name}));
        }
    }
    return 1;
}

fn parseLayerSpec(ctx: Ctx, spec: []const u8) !overlay.Layer {
    var parts = std.mem.splitScalar(u8, spec, ',');
    const raw_path = parts.next() orelse return error.MissingLayerPath;
    if (raw_path.len == 0) return error.MissingLayerPath;

    var layer = overlay.Layer{ .path = try expandPath(ctx, raw_path) };
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse return error.BadLayerOption;
        const key = part[0..eq];
        const value = part[eq + 1 ..];
        if (std.mem.eql(u8, key, "x")) {
            layer.x = std.fmt.parseInt(i32, value, 10) catch return error.BadLayerX;
        } else if (std.mem.eql(u8, key, "y")) {
            layer.y = std.fmt.parseInt(i32, value, 10) catch return error.BadLayerY;
        } else if (std.mem.eql(u8, key, "opacity")) {
            layer.opacity = std.fmt.parseFloat(f32, value) catch return error.BadLayerOpacity;
            if (layer.opacity < 0 or layer.opacity > 1 or !std.math.isFinite(layer.opacity)) return error.BadLayerOpacity;
        } else if (std.mem.eql(u8, key, "blend")) {
            layer.blend = overlay.BlendMode.fromString(value) orelse return error.BadLayerBlend;
        } else {
            return error.BadLayerOption;
        }
    }
    return layer;
}

fn jsonStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn batchImageSources(arena: Allocator, job: std.json.ObjectMap) ![]const []const u8 {
    const single = job.get("image");
    const multiple = job.get("images");
    const has_single = if (single) |value| value != .null else false;
    const has_multiple = if (multiple) |value| value != .null else false;
    if (has_single and has_multiple) return error.ConflictingBatchImages;

    if (single) |value| {
        if (value != .null) {
            return switch (value) {
                .string => |source| blk: {
                    const sources = try arena.alloc([]const u8, 1);
                    sources[0] = source;
                    break :blk sources;
                },
                else => error.InvalidBatchImages,
            };
        }
    }
    if (multiple) |value| {
        if (value != .null) {
            const entries = switch (value) {
                .array => |array| array.items,
                else => return error.InvalidBatchImages,
            };
            const sources = try arena.alloc([]const u8, entries.len);
            for (entries, 0..) |entry, i| {
                sources[i] = switch (entry) {
                    .string => |source| source,
                    else => return error.InvalidBatchImages,
                };
            }
            return sources;
        }
    }
    return &.{};
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

fn jsonBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .bool => |b| b,
        else => null,
    };
}

fn collectArgs(arena: Allocator, args: std.process.Args) ![]const []const u8 {
    var it = try args.iterateAllocator(arena);
    defer it.deinit();
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

test "credentialStatus reports credentials, never availability" {
    var local_endpoints = [_]types.Endpoint{
        .{ .base_url = "http://local", .auth = .none },
    };
    const local_only = types.ModelConfig{
        .name = "m",
        .backend = .qwen_image,
        .api_model = "m",
        .endpoints = &local_endpoints,
    };
    try std.testing.expectEqualStrings("not_required", credentialStatus(local_only));

    var endpoints = [_]types.Endpoint{
        .{ .base_url = "http://local", .auth = .none },
        .{ .base_url = "http://paid", .auth = .bearer },
    };
    const model = types.ModelConfig{
        .name = "m",
        .backend = .openai_image,
        .api_model = "m",
        .endpoints = &endpoints,
    };
    // A paid endpoint still needs a key even when a keyless one sits next to it.
    try std.testing.expectEqualStrings("missing", credentialStatus(model));
    endpoints[1].resolved_key = "k";
    try std.testing.expectEqualStrings("configured", credentialStatus(model));

    var two_paid = [_]types.Endpoint{
        .{ .base_url = "http://a", .auth = .bearer },
        .{ .base_url = "http://b", .auth = .bearer, .resolved_key = "k" },
    };
    const mixed = types.ModelConfig{
        .name = "m",
        .backend = .openai_image,
        .api_model = "m",
        .endpoints = &two_paid,
    };
    try std.testing.expectEqualStrings("partial", credentialStatus(mixed));
    two_paid[0].resolved_key = "k";
    try std.testing.expectEqualStrings("configured", credentialStatus(mixed));
    two_paid[0].resolved_key = null;
    two_paid[1].resolved_key = null;
    try std.testing.expectEqualStrings("missing", credentialStatus(mixed));
}

test "deny list matches backend kinds, aliases and model substrings" {
    try std.testing.expect(denyListHit("seedance", .seedance, "doubao-seedance-2-5") != null);
    try std.testing.expect(denyListHit("ark_video", .seedance, "x") != null);
    try std.testing.expect(denyListHit("foo, Doubao-Seedance", .seedance, "doubao-seedance-2-5") != null);
    try std.testing.expect(denyListHit("seedance", .azure_flux, "MAI-Image-2.6") == null);
    try std.testing.expect(denyListHit("", .seedance, "doubao-seedance") == null);
}

test "only billable cloud video needs IMAGINE_SPEND_OK" {
    const req = types.GenRequest{ .prompt = "x", .api_model = "m" };
    try std.testing.expect(isPaidVideo(.{ .model = "s", .kind = .seedance, .req = req, .billable = true }));
    try std.testing.expect(isPaidVideo(.{ .model = "g", .kind = .gemini_video, .req = req, .billable = true }));
    try std.testing.expect(!isPaidVideo(.{ .model = "s", .kind = .seedance, .req = req, .billable = false }));
    try std.testing.expect(!isPaidVideo(.{ .model = "l", .kind = .ltx2_video, .req = req, .billable = true }));
    try std.testing.expect(!isPaidVideo(.{ .model = "m", .kind = .azure_flux, .req = req, .billable = true }));
}

test "only a task that carries a credential is billable" {
    const req = types.GenRequest{ .prompt = "x", .api_model = "m" };
    const local = types.Endpoint{ .base_url = "http://local", .auth = .none };
    const unkeyed = types.Endpoint{ .base_url = "http://paid", .auth = .bearer };
    const keyed = types.Endpoint{ .base_url = "http://paid", .auth = .bearer, .resolved_key = "k" };
    var keyed_endpoints = [_]types.Endpoint{keyed};
    const model = types.ModelConfig{
        .name = "m",
        .backend = .seedance,
        .api_model = "m",
        .endpoints = &keyed_endpoints,
    };

    // A local service spends nothing; a task whose key did not resolve fails on
    // its missing credential, so neither is gated.
    try std.testing.expect(!spendItem(&model, &local, req).billable);
    try std.testing.expect(!spendItem(&model, &unkeyed, req).billable);
    try std.testing.expect(spendItem(&model, &keyed, req).billable);
    const metadata = types.Endpoint{ .base_url = "http://metadata", .auth = .google_metadata };
    try std.testing.expect(spendItem(&model, &metadata, req).billable);
    const jwt_half = types.Endpoint{ .base_url = "http://kling", .auth = .jwt_hs256, .resolved_key = "ak" };
    const jwt_full = types.Endpoint{ .base_url = "http://kling", .auth = .jwt_hs256, .resolved_key = "ak", .resolved_secret = "sk" };
    try std.testing.expect(!spendItem(&model, &jwt_half, req).billable);
    try std.testing.expect(spendItem(&model, &jwt_full, req).billable);
}

test {
    std.testing.refAllDecls(@This());
}
