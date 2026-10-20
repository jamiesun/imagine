//! Google Cloud Text-to-Speech REST (`text:synthesize`).
//!
//! This is not the Gemini API and not the gRPC streaming API. Auth is a bearer
//! access token (`GOOGLE_CLOUD_TTS_TOKEN`) or `google_metadata` (GCE metadata
//! server). A Gemini API key is not an OAuth token. SSML `<mark>` timepoints
//! require v1beta1; a `/v1/` URL is rewritten to `/v1beta1/` only for SSML.
//! LINEAR16 bytes are wrapped in one WAV header when the caller asked for wav.
//! They are never renamed to `.mp3`. Checked 2026-10-20 against the
//! text.synthesize and v1beta1 timepoint references.

const std = @import("std");
const types = @import("../types.zig");
const audio = @import("../audio.zig");
const util = @import("../util.zig");
const wire = @import("../wire.zig");

pub const Parsed = struct {
    outcome: wire.TaskOutcome,
    meta: types.AudioMeta = .{},
};

pub fn targetUrl(allocator: std.mem.Allocator, base_url: []const u8, req: types.GenRequest) ![]const u8 {
    const ssml = if (req.audio) |a| a.ssml else false;
    if (!ssml) return base_url;
    if (std.mem.indexOf(u8, base_url, "/v1beta1/")) |_| return base_url;
    if (std.mem.indexOf(u8, base_url, "/v1/")) |at| {
        return std.fmt.allocPrint(allocator, "{s}/v1beta1/{s}", .{ base_url[0..at], base_url[at + "/v1/".len ..] });
    }
    return base_url;
}

pub fn voicesUrl(allocator: std.mem.Allocator, base_url: []const u8) ![]u8 {
    const marker = "/text:synthesize";
    if (std.mem.indexOf(u8, base_url, marker)) |at| {
        return std.fmt.allocPrint(allocator, "{s}/voices", .{base_url[0..at]});
    }
    return std.fmt.allocPrint(allocator, "{s}/voices", .{std.mem.trimEnd(u8, base_url, "/")});
}

pub fn buildBody(allocator: std.mem.Allocator, req: types.GenRequest) ![]u8 {
    const params = req.audio orelse types.AudioParams{};
    const voice_name = params.voice orelse "";
    const language = params.language orelse languageFromVoice(voice_name) orelse "en-US";
    const encoding = encodingFor(req.output_format);
    const rate = params.sample_rate orelse 24000;
    const Input = struct {
        text: ?[]const u8 = null,
        ssml: ?[]const u8 = null,
    };
    const Voice = struct {
        languageCode: []const u8,
        name: []const u8,
    };
    const AudioConfig = struct {
        audioEncoding: []const u8,
        speakingRate: ?f32 = null,
        pitch: ?f32 = null,
        sampleRateHertz: ?u32 = null,
    };
    const Body = struct {
        input: Input,
        voice: Voice,
        audioConfig: AudioConfig,
        enableTimePointing: ?[]const []const u8 = null,
    };
    const body = Body{
        .input = if (params.ssml) .{ .ssml = req.prompt } else .{ .text = req.prompt },
        .voice = .{ .languageCode = language, .name = voice_name },
        .audioConfig = .{
            .audioEncoding = encoding,
            .speakingRate = params.speed,
            .pitch = params.pitch,
            .sampleRateHertz = if (std.mem.eql(u8, encoding, "LINEAR16")) rate else params.sample_rate,
        },
        .enableTimePointing = if (params.ssml) &.{"SSML_MARK"} else null,
    };
    return std.json.Stringify.valueAlloc(allocator, body, .{ .emit_null_optional_fields = false });
}

fn encodingFor(format: ?[]const u8) []const u8 {
    const fmt = format orelse return "LINEAR16";
    if (std.ascii.eqlIgnoreCase(fmt, "mp3")) return "MP3";
    if (std.ascii.eqlIgnoreCase(fmt, "ogg") or std.ascii.eqlIgnoreCase(fmt, "opus")) return "OGG_OPUS";
    return "LINEAR16";
}

pub fn languageFromVoice(voice: []const u8) ?[]const u8 {
    // en-US-Chirp3-HD-Charon -> en-US. Gemini names like "Kore" do not match.
    const dash = std.mem.indexOfScalar(u8, voice, '-') orelse return null;
    const second = std.mem.indexOfScalar(u8, voice[dash + 1 ..], '-') orelse return null;
    if (dash == 0 or second == 0) return null;
    return voice[0 .. dash + 1 + second];
}

pub fn parse(allocator: std.mem.Allocator, status: u16, body: []const u8, format: ?[]const u8, sample_rate: ?u32, source_text: []const u8) !Parsed {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return .{ .outcome = .{ .api_error = try wire.rawError(allocator, status, body) } };
    };
    defer parsed.deinit();
    const root = wire.rootObject(parsed.value) orelse
        return .{ .outcome = .{ .api_error = try std.fmt.allocPrint(allocator, "HTTP {d}: unexpected response", .{status}) } };
    if (root.get("error") != null or status >= 400) {
        return .{ .outcome = .{ .api_error = try wire.apiError(allocator, status, body, root) } };
    }
    const content = root.get("audioContent") orelse
        return .{ .outcome = .{ .api_error = try allocator.dupe(u8, "response has no audioContent") } };
    if (content != .string) return .{ .outcome = .{ .api_error = try allocator.dupe(u8, "audioContent is not base64") } };
    var bytes = util.base64DecodeAlloc(allocator, content.string) catch
        return .{ .outcome = .{ .api_error = try allocator.dupe(u8, "audioContent is not valid base64") } };
    const encoding = encodingFor(format);
    var meta = types.AudioMeta{ .stream_applied = false, .alignment = "unsupported" };
    if (std.mem.eql(u8, encoding, "LINEAR16")) {
        const rate = sample_rate orelse 24000;
        const want_wav = format == null or std.ascii.eqlIgnoreCase(format.?, "wav");
        if (want_wav) {
            if (!audio.looksLikeWav(bytes)) {
                const wrapped = audio.wavFromPcm(allocator, bytes, rate, 1) catch {
                    return .{ .outcome = .{ .api_error = try allocator.dupe(u8, "LINEAR16 payload is not a whole number of samples") } };
                };
                bytes = wrapped;
            }
            meta.mime = "audio/wav";
            meta.container = "wav";
            meta.codec = "pcm_s16le";
            meta.sample_rate_hz = rate;
            meta.channels = 1;
        } else {
            meta.mime = "audio/L16";
            meta.codec = "pcm_s16le";
            meta.sample_rate_hz = rate;
            meta.channels = 1;
        }
    } else if (std.mem.eql(u8, encoding, "MP3")) {
        if (!audio.looksLikeMp3(bytes)) {
            return .{ .outcome = .{ .api_error = try allocator.dupe(u8, "asked for mp3 but the payload is not an mp3 stream; refusing to rename it") } };
        }
        meta.mime = "audio/mpeg";
        meta.container = "mp3";
        meta.codec = "mp3";
    } else {
        meta.mime = "audio/ogg";
        meta.container = "ogg";
        meta.codec = "opus";
    }
    if (root.get("timepoints")) |tv| {
        if (tv == .array) {
            var marks = std.ArrayList(audio.Mark).empty;
            for (tv.array.items) |item| {
                if (item != .object) continue;
                const name = if (item.object.get("markName")) |v| (if (v == .string) v.string else null) else null;
                const sec = if (item.object.get("timeSeconds")) |v| switch (v) {
                    .float => v.float,
                    .integer => @as(f64, @floatFromInt(v.integer)),
                    else => null,
                } else null;
                if (name) |n| {
                    if (sec) |s| try marks.append(allocator, .{ .name = n, .seconds = s });
                }
            }
            if (marks.items.len > 0) {
                meta.alignment_json = try audio.ssmlMarkAlignment(allocator, "google_cloud_tts", source_text, marks.items);
                meta.alignment = null;
            }
        }
    }
    const list = try allocator.alloc(types.Payload, 1);
    list[0] = .{ .bytes = bytes };
    return .{ .outcome = .{ .done = list }, .meta = meta };
}

/// One voice name per line of JSON, for `imagine voices`.
pub fn voiceNames(allocator: std.mem.Allocator, body: []const u8) ![][]const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const voices = parsed.value.object.get("voices") orelse return &.{};
    if (voices != .array) return &.{};
    var out = std.ArrayList([]const u8).empty;
    for (voices.array.items) |item| {
        if (item != .object) continue;
        if (item.object.get("name")) |v| {
            if (v == .string) try out.append(allocator, try allocator.dupe(u8, v.string));
        }
    }
    return out.toOwnedSlice(allocator);
}

test "cloud tts ssml uses v1beta1 and mark pointing" {
    var test_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer test_arena.deinit();
    const a = test_arena.allocator();
    const req = types.GenRequest{
        .prompt = "<speak>Hi <mark name=\"m1\"/></speak>",
        .api_model = "texttospeech",
        .audio = .{ .ssml = true, .voice = "en-US-Chirp3-HD-Charon" },
    };
    const url = try targetUrl(a, "https://texttospeech.googleapis.com/v1/text:synthesize", req);
    try std.testing.expect(std.mem.indexOf(u8, url, "/v1beta1/") != null);
    const body = try buildBody(a, req);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"ssml\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "SSML_MARK") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "en-US") != null);
}

test "linear16 is wrapped as one wav and mp3 bytes are not renamed" {
    var test_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer test_arena.deinit();
    const a = test_arena.allocator();
    // "AAA=" is two zero bytes.
    const parsed = try parse(a, 200, "{\"audioContent\":\"AAA=\"}", "wav", 8000, "hi");
    try std.testing.expect(audio.validateWav(parsed.outcome.done[0].bytes));
    const bad = try parse(a, 200, "{\"audioContent\":\"aGk=\"}", "mp3", null, "hi");
    try std.testing.expect(bad.outcome == .api_error);
}
