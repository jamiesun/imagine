//! Backend dispatch and generation orchestration.
//!
//! Per-provider code is intentionally tiny: request-body construction plus, for
//! async-task providers, the three small parsers that carry a task from create
//! to download (`parseCreate` / `pollUrl` / `parsePoll`). Everything
//! provider-agnostic — credential resolution, auth headers, transport, the
//! create→poll→download loop, sync response parsing, base64 decode, URL
//! fallback — lives here so adding a backend stays a small, local change.

const std = @import("std");
const types = @import("types.zig");
const wire = @import("wire.zig");
const http = @import("http.zig");
const util = @import("util.zig");

const openai_image = @import("backends/openai_image.zig");
const azure_flux = @import("backends/azure_flux.zig");
const qwen_image = @import("backends/qwen_image.zig");
const seedance = @import("backends/seedance.zig");
const volcengine_image = @import("backends/volcengine_image.zig");
const gemini_video = @import("backends/gemini_video.zig");
const ltx2_video = @import("backends/ltx2_video.zig");
const mai_image = @import("backends/mai_image.zig");
const dashscope_image = @import("backends/dashscope_image.zig");
const dashscope_video = @import("backends/dashscope_video.zig");
const dashscope_wire = @import("backends/dashscope_wire.zig");
const vidu_video = @import("backends/vidu_video.zig");
const kling_video = @import("backends/kling_video.zig");
const minimax_video = @import("backends/minimax_video.zig");
const siliconflow_image = @import("backends/siliconflow_image.zig");
const tts_http = @import("backends/tts_http.zig");
const google_cloud_tts = @import("backends/google_cloud_tts.zig");
const gemini_tts = @import("backends/gemini_tts.zig");
const jwt = @import("jwt.zig");
const audio_util = @import("audio.zig");

const user_agent = "imagine/" ++ @import("version.zig").string;

/// Execution context for one generation task. Async-task backends (video) need
/// a clock to wait between polls and a deadline to give up on.
pub const GenOptions = struct {
    io: std.Io,
    /// Async-task backends: seconds to wait between status polls.
    poll_interval_secs: u32 = 5,
    /// Async-task backends: overall deadline for one task, in seconds.
    timeout_secs: u32 = 600,
};

/// File extension for the asset a backend will write. Image backends follow
/// `--format` (the provider returns what it was asked for, or its own default);
/// `gemini_video` and `ltx2_video` are pinned to mp4 because their APIs have no
/// container parameter, and naming the file anything else would be a lie.
pub fn outputExt(kind: types.BackendKind, format: ?[]const u8) []const u8 {
    return switch (kind) {
        .gemini_video, .ltx2_video, .dashscope_video, .vidu_video, .kling_video, .minimax_video => "mp4",
        .tts_http, .google_cloud_tts, .gemini_tts => audioExt(format),
        else => util.extForFormat(format orelse kind.media().defaultFormat()),
    };
}

fn audioExt(format: ?[]const u8) []const u8 {
    const f = format orelse return "wav";
    if (std.ascii.eqlIgnoreCase(f, "mp3")) return "mp3";
    if (std.ascii.eqlIgnoreCase(f, "ogg") or std.ascii.eqlIgnoreCase(f, "opus")) return "ogg";
    if (std.ascii.eqlIgnoreCase(f, "pcm") or std.ascii.eqlIgnoreCase(f, "linear16")) return "pcm";
    if (std.ascii.eqlIgnoreCase(f, "wav")) return "wav";
    return util.extForFormat(f);
}

/// Target URL for a generation request. Some backends route to different
/// endpoints depending on parameters (e.g. `mai_image` edits vs generations).
pub fn targetUrl(kind: types.BackendKind, allocator: std.mem.Allocator, base_url: []const u8, req: types.GenRequest) ![]const u8 {
    return switch (kind) {
        .mai_image => mai_image.resolveUrl(allocator, base_url, req),
        .vidu_video => vidu_video.targetUrl(allocator, base_url, req),
        .kling_video => kling_video.targetUrl(allocator, base_url, req),
        .google_cloud_tts => google_cloud_tts.targetUrl(allocator, base_url, req),
        else => base_url,
    };
}

/// Construct the provider request body for a model's backend. For async-task
/// backends this is the *create* request body (what `--dry-run` prints).
pub fn buildBody(kind: types.BackendKind, allocator: std.mem.Allocator, req: types.GenRequest) ![]u8 {
    return switch (kind) {
        .openai_image => openai_image.buildBody(allocator, req),
        .azure_flux => azure_flux.buildBody(allocator, req),
        .qwen_image => qwen_image.buildBody(allocator, req),
        .seedance => seedance.buildBody(allocator, req),
        .volcengine_image => volcengine_image.buildBody(allocator, req),
        .gemini_video => gemini_video.buildBody(allocator, req),
        .ltx2_video => ltx2_video.buildBody(allocator, req),
        .mai_image => mai_image.buildBody(allocator, req),
        .dashscope_image => dashscope_image.buildBody(allocator, req),
        .dashscope_video => dashscope_video.buildBody(allocator, req),
        .vidu_video => vidu_video.buildBody(allocator, req),
        .kling_video => kling_video.buildBody(allocator, req),
        .minimax_video => minimax_video.buildBody(allocator, req),
        .siliconflow_image => siliconflow_image.buildBody(allocator, req),
        .tts_http => tts_http.buildBody(allocator, req),
        .google_cloud_tts => google_cloud_tts.buildBody(allocator, req),
        .gemini_tts => gemini_tts.buildBody(allocator, req),
    };
}

/// Result of one generation attempt. API/HTTP/credential failures are reported
/// via `err` (a human-readable message) rather than as Zig errors, so callers
/// can aggregate per-task outcomes. Only allocation failure propagates.
pub const GenResult = struct {
    /// One entry per produced asset (image, video, or audio), ready to write to disk.
    assets: [][]u8 = &.{},
    err: ?[]const u8 = null,
    /// Present for audio, and when a provider reported a credit count.
    meta: ?types.AudioMeta = null,

    pub fn ok(self: GenResult) bool {
        return self.err == null;
    }
};

const Outcome = union(enum) {
    assets: []types.Payload,
    api_error: []const u8,
};

/// The provider-specific half of the async-task flow. A backend is only listed
/// here when `BackendKind.flow()` reports `.async_task`.
const Async = struct {
    parse_create: *const fn (std.mem.Allocator, u16, []const u8) std.mem.Allocator.Error!wire.TaskOutcome,
    poll_url: *const fn (std.mem.Allocator, []const u8, []const u8) std.mem.Allocator.Error![]u8,
    parse_poll: *const fn (std.mem.Allocator, []const u8, []const u8, u16, []const u8) std.mem.Allocator.Error!wire.PollOutcome,
};

/// Exhaustive on purpose: a new backend must decide whether it polls or not.
fn asyncImpl(kind: types.BackendKind) ?Async {
    return switch (kind) {
        .seedance => .{
            .parse_create = seedance.parseCreate,
            .poll_url = seedance.pollUrl,
            .parse_poll = seedance.parsePoll,
        },
        .gemini_video => .{
            .parse_create = gemini_video.parseCreate,
            .poll_url = gemini_video.pollUrl,
            .parse_poll = gemini_video.parsePoll,
        },
        .ltx2_video => .{
            .parse_create = ltx2_video.parseCreate,
            .poll_url = ltx2_video.pollUrl,
            .parse_poll = ltx2_video.parsePoll,
        },
        .dashscope_image => .{
            .parse_create = dashscope_image.parseCreate,
            .poll_url = dashscope_image.pollUrl,
            .parse_poll = dashscope_image.parsePoll,
        },
        .dashscope_video => .{
            .parse_create = dashscope_video.parseCreate,
            .poll_url = dashscope_video.pollUrl,
            .parse_poll = dashscope_video.parsePoll,
        },
        .vidu_video => .{
            .parse_create = vidu_video.parseCreate,
            .poll_url = vidu_video.pollUrl,
            .parse_poll = vidu_video.parsePoll,
        },
        .kling_video => .{
            .parse_create = kling_video.parseCreate,
            .poll_url = kling_video.pollUrl,
            .parse_poll = kling_video.parsePoll,
        },
        .minimax_video => .{
            .parse_create = minimax_video.parseCreate,
            .poll_url = minimax_video.pollUrl,
            .parse_poll = minimax_video.parsePoll,
        },
        .openai_image, .azure_flux, .qwen_image, .volcengine_image, .mai_image, .siliconflow_image, .tts_http, .google_cloud_tts, .gemini_tts => null,
    };
}

/// Credential headers for one endpoint, reused by every call of one task. Owns
/// the storage behind `extra`, so the slice it hands out stays valid as long as
/// the value is not copied after `extra()` is taken.
const Auth = struct {
    std: http.StdHeaders = .{
        .user_agent = .{ .override = user_agent },
        .content_type = .{ .override = "application/json" },
    },
    extra_buf: [4]http.Header = undefined,
    extra_len: usize = 0,

    fn extra(self: *const Auth) []const http.Header {
        return self.extra_buf[0..self.extra_len];
    }

    /// The same credential for a GET: no body, so no content type.
    fn getHeaders(self: *const Auth) http.StdHeaders {
        var h = self.std;
        h.content_type = .omit;
        return h;
    }
};

const AuthResult = union(enum) {
    ok: Auth,
    err: []const u8,
};

/// Credential headers for one call. A message in `err` is a finished failure
/// (missing key, metadata, signing); it is not a Zig error.
fn prepareAuth(
    client: *std.http.Client,
    allocator: std.mem.Allocator,
    model: *const types.ModelConfig,
    endpoint: *const types.Endpoint,
    io: std.Io,
) std.mem.Allocator.Error!AuthResult {
    const key: ?[]const u8 = switch (endpoint.auth) {
        .none, .google_metadata => null,
        else => endpoint.resolved_key orelse {
            const env_name = endpoint.api_key_env orelse "(none)";
            return .{ .err = try std.fmt.allocPrint(
                allocator,
                "missing credential: set ${s} or add api_key to endpoint for model '{s}'",
                .{ env_name, model.name },
            ) };
        },
    };

    // Standard headers go through std.http's overridable `headers` field so
    // each is emitted exactly once. Putting User-Agent in `extra_headers`
    // instead produced a DUPLICATE User-Agent (std.http adds its own default),
    // which Azure's gateway rejects as "Bad Request - Invalid Header".
    var auth: Auth = .{};
    switch (endpoint.auth) {
        .none => {},
        .google_metadata => {
            const token = (try fetchMetadataToken(client, allocator)) orelse {
                return .{ .err = try allocator.dupe(u8, "google_metadata: the metadata server did not return an access token") };
            };
            auth.std.authorization = .{ .override = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token}) };
        },
        .bearer => auth.std.authorization = .{
            .override = try std.fmt.allocPrint(allocator, "Bearer {s}", .{key.?}),
        },
        .token => auth.std.authorization = .{
            .override = try std.fmt.allocPrint(allocator, "Token {s}", .{key.?}),
        },
        .jwt_hs256 => {
            const secret = endpoint.resolved_secret orelse {
                const env_name = endpoint.api_secret_env orelse model.backend.defaultSecretEnv() orelse "KLING_SECRET_KEY";
                return .{ .err = try std.fmt.allocPrint(allocator, "missing signing secret: set ${s} for model '{s}'", .{ env_name, model.name }) };
            };
            const now: i64 = @intCast(std.Io.Clock.real.now(io).toSeconds());
            const token = jwt.hs256(allocator, key.?, secret, now) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return .{ .err = try std.fmt.allocPrint(allocator, "cannot sign request: {s}", .{@errorName(e)}) },
            };
            auth.std.authorization = .{ .override = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token}) };
        },
        .api_key, .google_api_key => {
            auth.extra_buf[0] = .{ .name = endpoint.auth.headerName(), .value = key.? };
            auth.extra_len = 1;
        },
    }
    if (model.backend == .dashscope_video or
        (model.backend == .dashscope_image and dashscope_wire.asyncHeader(endpoint.base_url)))
    {
        auth.extra_buf[auth.extra_len] = .{ .name = "X-DashScope-Async", .value = "enable" };
        auth.extra_len += 1;
    }
    return .{ .ok = auth };
}

pub const Fetched = struct {
    status: u16 = 0,
    body: []u8 = &.{},
    err: ?[]const u8 = null,
};

/// GET with the same credential headers a generation call would use.
/// Used for TTS `/capabilities` and `/voices` before any generate POST.
pub fn fetchAuthorized(
    client: *std.http.Client,
    allocator: std.mem.Allocator,
    model: *const types.ModelConfig,
    endpoint: *const types.Endpoint,
    url: []const u8,
    io: std.Io,
) std.mem.Allocator.Error!Fetched {
    const auth = switch (try prepareAuth(client, allocator, model, endpoint, io)) {
        .err => |msg| return .{ .err = msg },
        .ok => |ready| ready,
    };
    const res = http.get(client, allocator, url, auth.getHeaders(), auth.extra()) catch |e| {
        return .{ .err = try std.fmt.allocPrint(allocator, "request failed: {s}", .{@errorName(e)}) };
    };
    return .{ .status = res.status, .body = res.body };
}

/// Resolve `--image` into a form the backend can send. Local files are read by
/// the caller; a URL is downloaded here when the provider only accepts bytes.
/// Returns the input unchanged when it already has bytes, or when the backend
/// accepts URLs directly. `error.InputImageUnsupported` means the backend takes
/// no image at all — the caller reports that as a usage error before this point.
pub fn resolveInputImage(
    client: *std.http.Client,
    allocator: std.mem.Allocator,
    kind: types.BackendKind,
    image: types.InputImage,
) !types.InputImage {
    if (kind.inputImageStyle() == .unsupported) return error.InputImageUnsupported;
    if (image.bytes != null) return image;
    if (kind.inputImageStyle() == .url_or_data_url) return image;
    if (!util.isHttpUrl(image.source)) return error.InputImageUnreadable;

    const res = try http.get(client, allocator, image.source, .{ .user_agent = .{ .override = user_agent } }, &.{});
    if (res.status >= 400) return error.InputImageDownloadFailed;
    return .{
        .source = image.source,
        .bytes = res.body,
        // A URL often has no extension to trust; the bytes do not lie.
        .mime = util.sniffImageMime(res.body) orelse image.mime,
    };
}

/// Generate assets for a single (model, endpoint) pair. `allocator` should be a
/// per-task arena; all returned memory lives in it.
pub fn generate(
    client: *std.http.Client,
    allocator: std.mem.Allocator,
    model: *const types.ModelConfig,
    endpoint: *const types.Endpoint,
    req: types.GenRequest,
    opts: GenOptions,
) std.mem.Allocator.Error!GenResult {
    const auth = switch (try prepareAuth(client, allocator, model, endpoint, opts.io)) {
        .err => |msg| return .{ .err = msg },
        .ok => |ready| ready,
    };

    const body = buildBody(model.backend, allocator, req) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .err = try std.fmt.allocPrint(
            allocator,
            "cannot build {s} request: {s}",
            .{ model.backend.toString(), @errorName(e) },
        ) },
    };

    if (model.backend == .tts_http) {
        if (req.audio) |params| if (params.stream_applied) {
            return generateTtsStream(client, allocator, endpoint, &auth, body, req);
        };
    }

    return switch (model.backend.flow()) {
        .sync => generateSync(client, allocator, model.backend, endpoint, &auth, body, req),
        .async_task => generateAsync(client, allocator, model.backend, endpoint, &auth, body, req, opts),
    };
}

fn fetchMetadataToken(client: *std.http.Client, allocator: std.mem.Allocator) std.mem.Allocator.Error!?[]u8 {
    const url = "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token";
    const res = http.get(client, allocator, url, .{ .user_agent = .{ .override = user_agent } }, &.{
        .{ .name = "Metadata-Flavor", .value = "Google" },
    }) catch return null;
    if (res.status >= 400) return null;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, res.body, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const tok = parsed.value.object.get("access_token") orelse return null;
    if (tok != .string or tok.string.len == 0) return null;
    return try allocator.dupe(u8, tok.string);
}

fn generateSync(
    client: *std.http.Client,
    allocator: std.mem.Allocator,
    kind: types.BackendKind,
    endpoint: *const types.Endpoint,
    auth: *const Auth,
    body: []const u8,
    req: types.GenRequest,
) std.mem.Allocator.Error!GenResult {
    const url = targetUrl(kind, allocator, endpoint.base_url, req) catch |e| {
        return .{ .err = try std.fmt.allocPrint(allocator, "cannot resolve URL for {s}: {s}", .{ kind.toString(), @errorName(e) }) };
    };

    var auth_std = auth.std;
    if (kind == .mai_image and mai_image.isEdit(req)) {
        if (mai_image.contentType(allocator, req) catch null) |ct| {
            auth_std.content_type = .{ .override = ct };
        }
    }

    const res = http.post(client, allocator, url, auth_std, auth.extra(), body) catch |e| {
        return .{ .err = try std.fmt.allocPrint(allocator, "request failed: {s}", .{@errorName(e)}) };
    };

    const parsed = parseSync(allocator, kind, res.status, res.body, req) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .err = try std.fmt.allocPrint(allocator, "cannot parse {s} response: {s}", .{ kind.toString(), @errorName(e) }) },
    };
    switch (parsed.outcome) {
        .api_error => |msg| return .{ .err = msg },
        .pending => return .{ .err = try allocator.dupe(u8, "sync backend returned a task id; this protocol is asynchronous and needs its own backend") },
        .done => |payloads| {
            var result = try fetchPayloads(client, allocator, kind, auth, payloads, res.status);
            if (result.ok() and kind.media() == .audio) {
                if (try rejectBadAudio(allocator, req, result.assets)) |msg| return .{ .err = msg };
                result.meta = parsed.meta;
            }
            return result;
        },
    }
}

const SyncParsed = struct {
    outcome: wire.TaskOutcome,
    meta: types.AudioMeta = .{},
};

fn parseSync(allocator: std.mem.Allocator, kind: types.BackendKind, status: u16, body: []const u8, req: types.GenRequest) !SyncParsed {
    const rate = if (req.audio) |a| a.sample_rate else null;
    return switch (kind) {
        .siliconflow_image => .{ .outcome = try siliconflow_image.parse(allocator, status, body) },
        .tts_http => blk: {
            const parsed = try tts_http.parse(allocator, status, body, null);
            break :blk .{ .outcome = parsed.outcome, .meta = parsed.meta };
        },
        .google_cloud_tts => blk: {
            const parsed = try google_cloud_tts.parse(allocator, status, body, req.output_format, rate, req.prompt);
            break :blk .{ .outcome = parsed.outcome, .meta = parsed.meta };
        },
        .gemini_tts => blk: {
            const parsed = try gemini_tts.parse(allocator, status, body, req.output_format, rate);
            break :blk .{ .outcome = parsed.outcome, .meta = parsed.meta };
        },
        else => blk: {
            const outcome = try parseResponse(allocator, status, body);
            break :blk switch (outcome) {
                .api_error => |msg| .{ .outcome = .{ .api_error = msg } },
                .assets => |payloads| .{ .outcome = .{ .done = payloads } },
            };
        },
    };
}

fn rejectBadAudio(allocator: std.mem.Allocator, req: types.GenRequest, assets: [][]u8) std.mem.Allocator.Error!?[]const u8 {
    const fmt = req.output_format orelse "wav";
    if (!std.ascii.eqlIgnoreCase(fmt, "wav")) return null;
    for (assets) |asset| {
        if (!audio_util.validateWav(asset)) {
            return try std.fmt.allocPrint(allocator, "audio payload is not a single valid wav; refusing to write it as success", .{});
        }
    }
    return null;
}

const StreamCtx = struct {
    parser: *tts_http.StreamParser,
    allocator: std.mem.Allocator,
};

fn onTtsChunk(ptr: *anyopaque, bytes: []const u8) anyerror!void {
    const ctx: *StreamCtx = @ptrCast(@alignCast(ptr));
    try ctx.parser.push(ctx.allocator, bytes);
}

fn generateTtsStream(
    client: *std.http.Client,
    allocator: std.mem.Allocator,
    endpoint: *const types.Endpoint,
    auth: *const Auth,
    body: []const u8,
    req: types.GenRequest,
) std.mem.Allocator.Error!GenResult {
    const url = targetUrl(.tts_http, allocator, endpoint.base_url, req) catch |e| {
        return .{ .err = try std.fmt.allocPrint(allocator, "cannot resolve URL for tts_http: {s}", .{@errorName(e)}) };
    };
    var parser = tts_http.StreamParser{};
    var ctx = StreamCtx{ .parser = &parser, .allocator = allocator };
    const status = http.postStream(client, url, auth.std, auth.extra(), body, &ctx, onTtsChunk) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .err = try std.fmt.allocPrint(allocator, "request failed: {s}", .{@errorName(e)}) },
    };
    if (status >= 400 and parser.failed == null) {
        return .{ .err = try std.fmt.allocPrint(allocator, "request failed (HTTP {d})", .{status}) };
    }
    const finished = try parser.finish(allocator);
    switch (finished) {
        .err => |msg| return .{ .err = msg },
        .wav => |wav| {
            if (!audio_util.validateWav(wav)) {
                return .{ .err = try allocator.dupe(u8, "audio stream is not a single valid wav") };
            }
            const assets = try allocator.alloc([]u8, 1);
            assets[0] = wav;
            return .{
                .assets = assets,
                .meta = .{
                    .mime = "audio/wav",
                    .container = "wav",
                    .codec = "pcm_s16le",
                    .sample_rate_hz = parser.sample_rate,
                    .channels = parser.channels,
                    .stream_applied = true,
                    .alignment = "unsupported",
                },
            };
        },
    }
}

/// Create a task, then poll it until it produces assets. Poll failures are not
/// retried (the same policy as sync backends): whatever the provider reports is
/// what surfaces. `--poll-interval` and `--timeout` bound the wait.
fn generateAsync(
    client: *std.http.Client,
    allocator: std.mem.Allocator,
    kind: types.BackendKind,
    endpoint: *const types.Endpoint,
    auth: *const Auth,
    body: []const u8,
    req: types.GenRequest,
    opts: GenOptions,
) std.mem.Allocator.Error!GenResult {
    const impl = asyncImpl(kind) orelse return .{ .err = try std.fmt.allocPrint(
        allocator,
        "backend '{s}' has no async-task implementation",
        .{kind.toString()},
    ) };

    const create_url = targetUrl(kind, allocator, endpoint.base_url, req) catch |e| {
        return .{ .err = try std.fmt.allocPrint(allocator, "cannot resolve URL for {s}: {s}", .{ kind.toString(), @errorName(e) }) };
    };
    const created = http.post(client, allocator, create_url, auth.std, auth.extra(), body) catch |e| {
        return .{ .err = try std.fmt.allocPrint(allocator, "request failed: {s}", .{@errorName(e)}) };
    };

    var task_id: []const u8 = undefined;
    switch (try impl.parse_create(allocator, created.status, created.body)) {
        .api_error => |msg| return .{ .err = msg },
        .done => |payloads| return fetchPayloads(client, allocator, kind, auth, payloads, created.status),
        .pending => |id| task_id = id,
    }

    const deadline = std.Io.Clock.awake.now(opts.io)
        .addDuration(std.Io.Duration.fromSeconds(opts.timeout_secs));
    const interval = std.Io.Duration.fromSeconds(@max(@as(u32, 1), opts.poll_interval_secs));

    while (true) {
        if (std.Io.Clock.awake.now(opts.io).nanoseconds >= deadline.nanoseconds) {
            return .{ .err = try std.fmt.allocPrint(
                allocator,
                "task {s} did not finish within {d}s (raise --timeout to wait longer)",
                .{ task_id, opts.timeout_secs },
            ) };
        }
        std.Io.sleep(opts.io, interval, .awake) catch |e| {
            return .{ .err = try std.fmt.allocPrint(
                allocator,
                "waiting for task {s} failed: {s}",
                .{ task_id, @errorName(e) },
            ) };
        };

        const url = try impl.poll_url(allocator, create_url, task_id);
        const res = http.get(client, allocator, url, auth.getHeaders(), auth.extra()) catch |e| {
            return .{ .err = try std.fmt.allocPrint(allocator, "status request failed: {s}", .{@errorName(e)}) };
        };
        switch (try impl.parse_poll(allocator, endpoint.base_url, task_id, res.status, res.body)) {
            .api_error => |msg| return .{ .err = msg },
            .pending => {},
            .done => |payloads| return fetchPayloads(client, allocator, kind, auth, payloads, res.status),
        }
    }
}

/// Materialize payloads into bytes: base64 payloads pass through, URLs are
/// downloaded. Providers that gate their asset URLs behind the API credential
/// (Gemini Files) get the same headers as the create call; pre-signed CDN URLs
/// (Ark, Azure) must *not* carry them — Azure Storage rejects a request that has
/// both a SAS token and an Authorization header.
fn fetchPayloads(
    client: *std.http.Client,
    allocator: std.mem.Allocator,
    kind: types.BackendKind,
    auth: *const Auth,
    payloads: []types.Payload,
    status: u16,
) std.mem.Allocator.Error!GenResult {
    if (payloads.len == 0) {
        return .{ .err = try std.fmt.allocPrint(allocator, "no assets in response (HTTP {d})", .{status}) };
    }

    var out = try allocator.alloc([]u8, payloads.len);
    for (payloads, 0..) |p, i| {
        switch (p) {
            .bytes => |b| out[i] = b,
            .url => |u| {
                const got = try downloadUrl(client, allocator, auth, u, kind.assetNeedsAuth());
                if (got.err) |msg| return .{ .err = msg };
                out[i] = got.bytes;
            },
            .relay => |r| {
                const listing = try downloadUrl(client, allocator, auth, r.url, true);
                if (listing.err) |msg| return .{ .err = msg };
                const cdn = jsonField(allocator, listing.bytes, r.field) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return .{ .err = try allocator.dupe(u8, "retrieve response did not contain a download url") },
                };
                const file = try downloadUrl(client, allocator, auth, cdn, false);
                if (file.err) |msg| return .{ .err = msg };
                out[i] = file.bytes;
            },
        }
    }
    return .{ .assets = out };
}

const Downloaded = struct {
    bytes: []u8 = &.{},
    err: ?[]u8 = null,
};

fn downloadUrl(
    client: *std.http.Client,
    allocator: std.mem.Allocator,
    auth: *const Auth,
    url: []const u8,
    with_auth: bool,
) std.mem.Allocator.Error!Downloaded {
    const headers: http.StdHeaders = if (with_auth) auth.getHeaders() else .{
        .user_agent = .{ .override = user_agent },
    };
    const extra: []const http.Header = if (with_auth) auth.extra() else &.{};
    const dl = http.get(client, allocator, url, headers, extra) catch |e| {
        return .{ .err = try std.fmt.allocPrint(allocator, "failed to download asset url: {s}", .{@errorName(e)}) };
    };
    if (dl.status >= 400) {
        return .{ .err = try std.fmt.allocPrint(allocator, "failed to download asset url (HTTP {d})", .{dl.status}) };
    }
    return .{ .bytes = dl.body };
}

fn jsonField(allocator: std.mem.Allocator, body: []const u8, path: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    var cur = parsed.value;
    var it = std.mem.splitScalar(u8, path, '.');
    while (it.next()) |part| {
        if (cur != .object) return error.Missing;
        cur = cur.object.get(part) orelse return error.Missing;
    }
    if (cur != .string or cur.string.len == 0) return error.Missing;
    return try allocator.dupe(u8, cur.string);
}

/// Parse a provider JSON response into decoded payloads or an error message.
/// Shared across all current backends, which return the OpenAI-style
/// `{ "data": [ { "b64_json" | "url" } ] }` shape and
/// `{ "error": { "message" } }` for failures.
pub fn parseResponse(allocator: std.mem.Allocator, status: u16, body: []const u8) std.mem.Allocator.Error!Outcome {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        // Non-JSON body (e.g. an HTML error page). Surface a trimmed snippet.
        const snippet = body[0..@min(body.len, 280)];
        return .{ .api_error = try std.fmt.allocPrint(allocator, "HTTP {d}: {s}", .{ status, snippet }) };
    };
    defer parsed.deinit();

    const root = wire.rootObject(parsed.value) orelse
        return .{ .api_error = try std.fmt.allocPrint(allocator, "HTTP {d}: unexpected response", .{status}) };

    if (root.get("error")) |ev| {
        const msg = wire.extractErrorMessage(ev) orelse "unknown error";
        return .{ .api_error = try std.fmt.allocPrint(allocator, "HTTP {d}: {s}", .{ status, msg }) };
    }

    const data_v = root.get("data") orelse {
        // Some error responses put the message at the top level.
        if (root.get("message")) |mv| {
            if (mv == .string) return .{ .api_error = try std.fmt.allocPrint(allocator, "HTTP {d}: {s}", .{ status, mv.string }) };
        }
        if (status >= 400) {
            const snippet = body[0..@min(body.len, 280)];
            return .{ .api_error = try std.fmt.allocPrint(allocator, "HTTP {d}: {s}", .{ status, snippet }) };
        }
        return .{ .assets = &.{} };
    };
    if (data_v != .array) return .{ .assets = &.{} };

    var list = std.ArrayList(types.Payload).empty;
    for (data_v.array.items) |item| {
        if (item != .object) continue;
        const o = item.object;
        if (o.get("b64_json")) |bv| {
            if (bv == .string) {
                const bytes = util.base64DecodeAlloc(allocator, bv.string) catch continue;
                try list.append(allocator, .{ .bytes = bytes });
                continue;
            }
        }
        if (o.get("url")) |uv| {
            if (uv == .string) {
                try list.append(allocator, .{ .url = try allocator.dupe(u8, uv.string) });
            }
        }
    }
    return .{ .assets = try list.toOwnedSlice(allocator) };
}

// ---- tests ----

test "parseResponse decodes b64_json" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    // "aGk=" -> "hi"
    const body = "{\"data\":[{\"b64_json\":\"aGk=\"}]}";
    const outcome = try parseResponse(arena.allocator(), 200, body);
    try std.testing.expect(outcome == .assets);
    try std.testing.expectEqual(@as(usize, 1), outcome.assets.len);
    try std.testing.expectEqualStrings("hi", outcome.assets[0].bytes);
}

test "parseResponse surfaces error.message" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const body = "{\"error\":{\"message\":\"bad prompt\",\"code\":\"content_policy\"}}";
    const outcome = try parseResponse(arena.allocator(), 400, body);
    try std.testing.expect(outcome == .api_error);
    try std.testing.expect(std.mem.indexOf(u8, outcome.api_error, "bad prompt") != null);
}

test "parseResponse handles non-json" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const outcome = try parseResponse(arena.allocator(), 502, "<html>Bad Gateway</html>");
    try std.testing.expect(outcome == .api_error);
    try std.testing.expect(std.mem.indexOf(u8, outcome.api_error, "502") != null);
}

test "parseResponse captures url payloads" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const body = "{\"data\":[{\"url\":\"https://example.com/x.png\"}]}";
    const outcome = try parseResponse(arena.allocator(), 200, body);
    try std.testing.expect(outcome == .assets);
    try std.testing.expect(outcome.assets[0] == .url);
}

test "async-task backends and their implementations agree" {
    // `generate` picks the loop from `flow()`; keep the two switches honest.
    inline for (std.meta.tags(types.BackendKind)) |kind| {
        try std.testing.expectEqual(kind.flow() == .async_task, asyncImpl(kind) != null);
    }
}
