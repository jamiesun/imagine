//! Generic HTTP TTS. The wire contract is imagine's, not Qwen's.
//!
//! `POST {base}` JSON in, either a JSON document (`audio` base64) or a raw
//! audio body. Streaming, when the server's `/capabilities` says so, is
//! newline-delimited JSON:
//!   {"event":"meta","codec":"pcm_s16le","sample_rate_hz":24000,"channels":1}
//!   {"event":"audio_chunk","data":"<base64 pcm>"}
//!   {"event":"complete"}
//!   {"event":"error","message":"..."}
//! A server that finishes the whole clip and then slices the body must report
//! `streaming: false`. Qwen's `non_streaming_mode=false` is that case and must
//! not be advertised here. Protocol version: imagine.tts_http.v1.

const std = @import("std");
const types = @import("../types.zig");
const util = @import("../util.zig");
const audio = @import("../audio.zig");
const wire = @import("../wire.zig");

pub const Parsed = struct {
    outcome: wire.TaskOutcome,
    meta: types.AudioMeta = .{},
};

const Turn = struct {
    speaker: []const u8,
    text: []const u8,
    voice: ?[]const u8 = null,
    style: ?[]const u8 = null,
    language: ?[]const u8 = null,
};

pub fn buildBody(allocator: std.mem.Allocator, req: types.GenRequest) ![]u8 {
    const params = req.audio orelse types.AudioParams{};
    var turns = std.ArrayList(Turn).empty;
    for (params.dialogue) |t| {
        try turns.append(allocator, .{
            .speaker = t.speaker,
            .text = t.text,
            .voice = t.voice,
            .style = t.style,
            .language = t.language,
        });
    }
    const Ref = struct { mime_type: []const u8, data: []const u8 };
    var reference: ?Ref = null;
    if (params.reference) |r| {
        const bytes = r.bytes orelse return error.InputImageNotFetched;
        reference = .{ .mime_type = r.mime, .data = try util.base64EncodeAlloc(allocator, bytes) };
    }
    const Body = struct {
        model: []const u8,
        text: []const u8,
        mode: []const u8,
        ssml: bool = false,
        voice: ?[]const u8 = null,
        language: ?[]const u8 = null,
        style: ?[]const u8 = null,
        speed: ?f32 = null,
        pitch: ?f32 = null,
        format: ?[]const u8 = null,
        sample_rate: ?u32 = null,
        seed: ?i64 = null,
        stream: bool = false,
        reference_audio: ?Ref = null,
        reference_text: ?[]const u8 = null,
        dialogue: ?[]const Turn = null,
    };
    const body = Body{
        .model = req.api_model,
        .text = req.prompt,
        .mode = params.mode.toString(),
        .ssml = params.ssml,
        .voice = params.voice,
        .language = params.language,
        .style = params.style,
        .speed = params.speed,
        .pitch = params.pitch,
        .format = req.output_format,
        .sample_rate = params.sample_rate,
        .seed = req.seed,
        .stream = params.stream_applied,
        .reference_audio = reference,
        .reference_text = params.reference_text,
        .dialogue = if (turns.items.len > 0) try turns.toOwnedSlice(allocator) else null,
    };
    return std.json.Stringify.valueAlloc(allocator, body, .{ .emit_null_optional_fields = false });
}

pub fn siblingUrl(allocator: std.mem.Allocator, generate_url: []const u8, leaf: []const u8) ![]u8 {
    const q = std.mem.indexOfScalar(u8, generate_url, '?') orelse generate_url.len;
    var base = std.mem.trimEnd(u8, generate_url[0..q], "/");
    if (std.mem.endsWith(u8, base, "/generate")) base = base[0 .. base.len - "/generate".len];
    if (std.mem.endsWith(u8, base, "/capabilities") or std.mem.endsWith(u8, base, "/voices")) {
        if (std.mem.lastIndexOfScalar(u8, base, '/')) |at| base = base[0..at];
    }
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, leaf });
}

pub const ServerCaps = struct {
    speech: bool = true,
    voice_design: bool = false,
    voice_clone: bool = false,
    streaming: bool = false,
    style: bool = false,
    speed: bool = false,
    pitch: bool = false,
    max_chars: u32 = 0,
    formats: []const []const u8 = &.{ "wav", "pcm" },

    pub fn narrow(self: ServerCaps) types.Capabilities {
        const ceiling = types.BackendKind.tts_http.capabilities();
        return .{
            .speech = ceiling.speech and self.speech,
            .voice_design = ceiling.voice_design and self.voice_design,
            .voice_clone = ceiling.voice_clone and self.voice_clone,
            .native_dialogue = false,
            .max_speakers = 1,
            .style = self.style,
            .speed = self.speed,
            .pitch = self.pitch,
            .streaming = ceiling.streaming and self.streaming,
            .alignment = .unsupported,
            .max_chars = self.max_chars,
            .voice_list = true,
            .formats = if (self.formats.len > 0) self.formats else ceiling.formats,
        };
    }
};

pub fn parseCapabilities(allocator: std.mem.Allocator, body: []const u8) !ServerCaps {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    var caps = ServerCaps{};
    if (root.get("modes")) |mv| {
        if (mv == .array) {
            caps.speech = false;
            caps.voice_design = false;
            caps.voice_clone = false;
            for (mv.array.items) |item| {
                if (item != .string) continue;
                if (types.SpeechMode.fromString(item.string)) |mode| switch (mode) {
                    .speech => caps.speech = true,
                    .voice_design => caps.voice_design = true,
                    .voice_clone => caps.voice_clone = true,
                    .dialogue => {},
                };
            }
        }
    }
    if (boolField(root, "streaming")) |v| caps.streaming = v;
    if (boolField(root, "style")) |v| caps.style = v;
    if (boolField(root, "speed")) |v| caps.speed = v;
    if (boolField(root, "pitch")) |v| caps.pitch = v;
    if (root.get("max_chars")) |v| {
        if (v == .integer and v.integer > 0) caps.max_chars = @intCast(v.integer);
    }
    if (root.get("formats")) |v| {
        if (v == .array) {
            var fmts = try allocator.alloc([]const u8, v.array.items.len);
            var n: usize = 0;
            for (v.array.items) |item| {
                if (item == .string) {
                    fmts[n] = try allocator.dupe(u8, item.string);
                    n += 1;
                }
            }
            caps.formats = fmts[0..n];
        }
    }
    return caps;
}

fn boolField(o: std.json.ObjectMap, key: []const u8) ?bool {
    const v = o.get(key) orelse return null;
    return if (v == .bool) v.bool else null;
}

pub fn parse(allocator: std.mem.Allocator, status: u16, body: []const u8, content_type: ?[]const u8) !Parsed {
    if (status < 400 and content_type != null and std.mem.startsWith(u8, content_type.?, "audio/")) {
        if (body.len == 0) return .{ .outcome = .{ .api_error = try allocator.dupe(u8, "empty audio response") } };
        const list = try allocator.alloc(types.Payload, 1);
        list[0] = .{ .bytes = try allocator.dupe(u8, body) };
        return .{
            .outcome = .{ .done = list },
            .meta = .{
                .mime = try allocator.dupe(u8, content_type.?),
                .alignment = "unsupported",
                .stream_applied = false,
            },
        };
    }
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return .{ .outcome = .{ .api_error = try wire.rawError(allocator, status, body) } };
    };
    defer parsed.deinit();
    const root = wire.rootObject(parsed.value) orelse
        return .{ .outcome = .{ .api_error = try std.fmt.allocPrint(allocator, "HTTP {d}: unexpected response", .{status}) } };
    if (root.get("error") != null or status >= 400) {
        return .{ .outcome = .{ .api_error = try wire.apiError(allocator, status, body, root) } };
    }
    const audio_v = root.get("audio") orelse
        return .{ .outcome = .{ .api_error = try std.fmt.allocPrint(allocator, "HTTP {d}: response has no audio", .{status}) } };
    if (audio_v != .string) return .{ .outcome = .{ .api_error = try allocator.dupe(u8, "audio field is not base64") } };
    const bytes = util.base64DecodeAlloc(allocator, audio_v.string) catch
        return .{ .outcome = .{ .api_error = try allocator.dupe(u8, "audio field is not valid base64") } };
    const list = try allocator.alloc(types.Payload, 1);
    list[0] = .{ .bytes = bytes };
    var meta = types.AudioMeta{ .stream_applied = false, .alignment = "unsupported" };
    if (root.get("mime")) |v| {
        if (v == .string) meta.mime = try allocator.dupe(u8, v.string);
    }
    if (root.get("sample_rate_hz")) |v| {
        if (v == .integer and v.integer > 0) meta.sample_rate_hz = @intCast(v.integer);
    }
    if (root.get("channels")) |v| {
        if (v == .integer and v.integer > 0) meta.channels = @intCast(v.integer);
    }
    if (root.get("duration_ms")) |v| {
        if (v == .integer and v.integer >= 0) meta.duration_ms = @intCast(v.integer);
    }
    if (root.get("alignment")) |v| {
        if (v == .object) {
            meta.alignment_json = try std.json.Stringify.valueAlloc(allocator, v, .{});
            meta.alignment = null;
        }
    }
    return .{ .outcome = .{ .done = list }, .meta = meta };
}

pub const StreamParser = struct {
    buf: std.ArrayList(u8) = .empty,
    pcm: std.ArrayList(u8) = .empty,
    codec: []const u8 = "pcm_s16le",
    sample_rate: u32 = 24000,
    channels: u16 = 1,
    saw_chunk: bool = false,
    done: bool = false,
    failed: ?[]const u8 = null,

    pub fn push(self: *StreamParser, allocator: std.mem.Allocator, bytes: []const u8) !void {
        try self.buf.appendSlice(allocator, bytes);
        while (std.mem.indexOfScalar(u8, self.buf.items, '\n')) |at| {
            const line = try allocator.dupe(u8, std.mem.trim(u8, self.buf.items[0..at], " \r\t"));
            defer allocator.free(line);
            const rest = try allocator.dupe(u8, self.buf.items[at + 1 ..]);
            defer allocator.free(rest);
            self.buf.clearRetainingCapacity();
            try self.buf.appendSlice(allocator, rest);
            if (line.len > 0) try self.event(allocator, line);
        }
    }

    fn event(self: *StreamParser, allocator: std.mem.Allocator, line: []const u8) !void {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
            self.failed = "malformed stream event";
            return;
        };
        defer parsed.deinit();
        if (parsed.value != .object) {
            self.failed = "malformed stream event";
            return;
        }
        const o = parsed.value.object;
        const name = if (o.get("event")) |v| (if (v == .string) v.string else "") else "";
        if (std.mem.eql(u8, name, "meta")) {
            if (o.get("codec")) |v| {
                if (v == .string) self.codec = try allocator.dupe(u8, v.string);
            }
            if (o.get("sample_rate_hz")) |v| {
                if (v == .integer and v.integer > 0) self.sample_rate = @intCast(v.integer);
            }
            if (o.get("channels")) |v| {
                if (v == .integer and v.integer > 0 and v.integer <= 8) self.channels = @intCast(v.integer);
            }
        } else if (std.mem.eql(u8, name, "audio_chunk")) {
            const data = if (o.get("data")) |v| (if (v == .string) v.string else null) else null;
            const raw = data orelse {
                self.failed = "audio_chunk missing data";
                return;
            };
            const bytes = util.base64DecodeAlloc(allocator, raw) catch {
                self.failed = "audio_chunk is not base64";
                return;
            };
            try self.pcm.appendSlice(allocator, bytes);
            self.saw_chunk = true;
        } else if (std.mem.eql(u8, name, "complete")) {
            self.done = true;
        } else if (std.mem.eql(u8, name, "error")) {
            const msg = if (o.get("message")) |v| (if (v == .string) v.string else "stream error") else "stream error";
            self.failed = try allocator.dupe(u8, msg);
        }
    }

    pub const Finish = union(enum) {
        wav: []u8,
        err: []const u8,
    };

    pub fn finish(self: *StreamParser, allocator: std.mem.Allocator) !Finish {
        if (self.failed) |msg| return .{ .err = msg };
        if (!self.done) return .{ .err = "audio stream ended before a complete event" };
        if (!self.saw_chunk or self.pcm.items.len == 0) return .{ .err = "audio stream completed with no audio" };
        if (std.mem.eql(u8, self.codec, "pcm_s16le")) {
            const wav = audio.wavFromPcm(allocator, self.pcm.items, self.sample_rate, self.channels) catch {
                return .{ .err = "pcm payload does not fit one wav container" };
            };
            return .{ .wav = wav };
        }
        if (std.mem.eql(u8, self.codec, "wav")) {
            const out = try allocator.dupe(u8, self.pcm.items);
            if (!audio.validateWav(out)) {
                allocator.free(out);
                return .{ .err = "streamed wav is not a single valid container" };
            }
            return .{ .wav = out };
        }
        return .{ .err = "stream codec is not pcm_s16le or wav" };
    }
};

test "stream delivers the first chunk before complete" {
    var test_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer test_arena.deinit();
    const a = test_arena.allocator();
    var p = StreamParser{};
    try p.push(a, "{\"event\":\"meta\",\"codec\":\"pcm_s16le\",\"sample_rate_hz\":8000,\"channels\":1}\n");
    try p.push(a, "{\"event\":\"audio_chunk\",\"data\":\"AAA=\"}\n");
    try std.testing.expect(p.saw_chunk);
    try std.testing.expect(!p.done);
    try std.testing.expect(p.pcm.items.len > 0);
    try p.push(a, "{\"event\":\"audio_chunk\",\"data\":\"AQA=\"}\n{\"event\":\"complete\"}\n");
    const finished = try p.finish(a);
    try std.testing.expect(audio.validateWav(finished.wav));
    try std.testing.expectEqual(@as(usize, 1), audio.wavContainerCount(finished.wav));
}

test "incomplete stream does not look like success" {
    var test_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer test_arena.deinit();
    const a = test_arena.allocator();
    var p = StreamParser{};
    try p.push(a, "{\"event\":\"audio_chunk\",\"data\":\"AAA=\"}\n");
    const finished = try p.finish(a);
    try std.testing.expect(std.mem.indexOf(u8, finished.err, "complete") != null);
}

test "capabilities narrow streaming" {
    var test_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer test_arena.deinit();
    const a = test_arena.allocator();
    const caps = try parseCapabilities(a,
        \\{"protocol":"imagine.tts_http.v1","modes":["speech","voice_clone"],"streaming":false,"formats":["wav"]}
    );
    const narrowed = caps.narrow();
    try std.testing.expect(!narrowed.streaming);
    try std.testing.expect(narrowed.voice_clone);
    try std.testing.expect(!narrowed.voice_design);
}
