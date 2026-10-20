//! Gemini speech generation on the Interactions API.
//!
//! Not `gemini_video` and not Gemini Live. Auth is `x-goog-api-key`. A single
//! speaker is `generation_config.speech_config: [{voice}]`. Two speakers are
//! `speech_config.speakers` plus one text part per turn, in order, with
//! `speech_metadata.speaker`. More than two speakers is rejected before the
//! request. Audio is `steps[].content[]` where `type` is `audio` and `data` is
//! base64. If that payload is raw PCM and the caller asked for wav, it is
//! wrapped once. mp3 is not offered: this API does not return mp3 and imagine
//! does not transcode. Checked 2026-10-20 against the Gemini speech generation
//! guide (`gemini-3.8-flash-tts` is an example model id, not a hardcoded one).

const std = @import("std");
const types = @import("../types.zig");
const audio = @import("../audio.zig");
const util = @import("../util.zig");
const wire = @import("../wire.zig");

pub const Parsed = struct {
    outcome: wire.TaskOutcome,
    meta: types.AudioMeta = .{},
};

const Annotation = struct {
    type: []const u8 = "speech_metadata",
    style: ?[]const u8 = null,
    speaker: ?[]const u8 = null,
};

const TextPart = struct {
    type: []const u8 = "text",
    text: []const u8,
    annotations: ?[]const Annotation = null,
};

const UserInput = struct {
    type: []const u8 = "user_input",
    content: []const TextPart,
};

pub fn buildBody(allocator: std.mem.Allocator, req: types.GenRequest) ![]u8 {
    const params = req.audio orelse types.AudioParams{};
    var parts = std.ArrayList(TextPart).empty;
    if (params.mode == .dialogue and params.dialogue.len > 0) {
        for (params.dialogue) |turn| {
            const ann = Annotation{ .speaker = if (turn.speaker.len > 0) turn.speaker else null, .style = turn.style };
            const anns = try allocator.alloc(Annotation, 1);
            anns[0] = ann;
            try parts.append(allocator, .{ .text = turn.text, .annotations = anns });
        }
    } else {
        var part = TextPart{ .text = req.prompt };
        if (params.style) |style| {
            const anns = try allocator.alloc(Annotation, 1);
            anns[0] = .{ .style = style };
            part.annotations = anns;
        }
        try parts.append(allocator, part);
    }

    var speakers = std.ArrayList(struct { speaker: []const u8, voice: []const u8 }).empty;
    if (params.mode == .dialogue) {
        for (params.dialogue) |turn| {
            var seen = false;
            for (speakers.items) |s| {
                if (std.mem.eql(u8, s.speaker, turn.speaker)) seen = true;
            }
            if (!seen) {
                const voice = turn.voice orelse params.voice orelse return error.MissingVoice;
                try speakers.append(allocator, .{ .speaker = turn.speaker, .voice = voice });
            }
        }
    }

    const want_pcm = if (req.output_format) |f| std.ascii.eqlIgnoreCase(f, "pcm") else false;
    const ResponseFormat = struct {
        type: []const u8 = "audio",
        mime_type: ?[]const u8 = null,
    };

    if (speakers.items.len > 1) {
        const Speech = struct {
            speakers: []const @TypeOf(speakers.items[0]),
        };
        const Gen = struct { speech_config: Speech };
        const Body = struct {
            model: []const u8,
            input: []const UserInput,
            response_format: ResponseFormat,
            generation_config: Gen,
        };
        const body = Body{
            .model = req.api_model,
            .input = &.{.{ .content = try parts.toOwnedSlice(allocator) }},
            .response_format = .{ .mime_type = if (want_pcm) "audio/l16" else null },
            .generation_config = .{ .speech_config = .{ .speakers = try speakers.toOwnedSlice(allocator) } },
        };
        return std.json.Stringify.valueAlloc(allocator, body, .{ .emit_null_optional_fields = false });
    }

    const One = struct { voice: []const u8 };
    const Gen = struct { speech_config: []const One };
    const Body = struct {
        model: []const u8,
        input: []const UserInput,
        response_format: ResponseFormat,
        generation_config: Gen,
    };
    const voice = if (params.mode == .dialogue and speakers.items.len == 1) speakers.items[0].voice else params.voice orelse "";
    const body = Body{
        .model = req.api_model,
        .input = &.{.{ .content = try parts.toOwnedSlice(allocator) }},
        .response_format = .{ .mime_type = if (want_pcm) "audio/l16" else null },
        .generation_config = .{ .speech_config = &.{.{ .voice = voice }} },
    };
    return std.json.Stringify.valueAlloc(allocator, body, .{ .emit_null_optional_fields = false });
}

pub fn parse(allocator: std.mem.Allocator, status: u16, body: []const u8, format: ?[]const u8, sample_rate: ?u32) !Parsed {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return .{ .outcome = .{ .api_error = try wire.rawError(allocator, status, body) } };
    };
    defer parsed.deinit();
    const root = wire.rootObject(parsed.value) orelse
        return .{ .outcome = .{ .api_error = try std.fmt.allocPrint(allocator, "HTTP {d}: unexpected response", .{status}) } };
    if (root.get("error") != null or status >= 400) {
        return .{ .outcome = .{ .api_error = try wire.apiError(allocator, status, body, root) } };
    }
    const found = findAudio(root) orelse
        return .{ .outcome = .{ .api_error = try allocator.dupe(u8, "response has no audio content") } };
    var bytes = util.base64DecodeAlloc(allocator, found.data) catch
        return .{ .outcome = .{ .api_error = try allocator.dupe(u8, "audio data is not valid base64") } };
    const mime = found.mime orelse "";
    const rate = sample_rate orelse audio.sampleRateFromMime(mime) orelse 24000;
    var meta = types.AudioMeta{
        .stream_applied = false,
        .alignment = "unsupported",
        .sample_rate_hz = rate,
        .channels = 1,
    };
    const want_wav = format == null or std.ascii.eqlIgnoreCase(format.?, "wav");
    if (audio.looksLikeWav(bytes)) {
        if (!audio.validateWav(bytes)) {
            return .{ .outcome = .{ .api_error = try allocator.dupe(u8, "provider returned a wav that is not a single valid container") } };
        }
        meta.mime = "audio/wav";
        meta.container = "wav";
        meta.codec = "pcm_s16le";
    } else if (want_wav and (audio.isPcmMime(mime) or mime.len == 0 or std.ascii.eqlIgnoreCase(format orelse "", "pcm") == false)) {
        if (std.ascii.eqlIgnoreCase(format orelse "", "pcm")) {
            meta.mime = "audio/L16";
            meta.codec = "pcm_s16le";
        } else {
            const wrapped = audio.wavFromPcm(allocator, bytes, rate, 1) catch {
                return .{ .outcome = .{ .api_error = try allocator.dupe(u8, "pcm payload is not a whole number of samples") } };
            };
            bytes = wrapped;
            meta.mime = "audio/wav";
            meta.container = "wav";
            meta.codec = "pcm_s16le";
        }
    } else {
        meta.mime = if (mime.len > 0) try allocator.dupe(u8, mime) else "application/octet-stream";
    }
    if (std.ascii.eqlIgnoreCase(format orelse "", "mp3")) {
        return .{ .outcome = .{ .api_error = try allocator.dupe(u8, "gemini_tts did not return mp3; refusing to rename the payload") } };
    }
    const list = try allocator.alloc(types.Payload, 1);
    list[0] = .{ .bytes = bytes };
    return .{ .outcome = .{ .done = list }, .meta = meta };
}

const Found = struct { data: []const u8, mime: ?[]const u8 };

fn findAudio(root: std.json.ObjectMap) ?Found {
    if (root.get("steps")) |steps| {
        if (steps == .array) {
            var last: ?Found = null;
            for (steps.array.items) |step| {
                if (step != .object) continue;
                const content = step.object.get("content") orelse continue;
                if (content != .array) continue;
                for (content.array.items) |part| {
                    if (part != .object) continue;
                    const typ = if (part.object.get("type")) |v| (if (v == .string) v.string else "") else "";
                    if (!std.mem.eql(u8, typ, "audio")) continue;
                    const data = if (part.object.get("data")) |v| (if (v == .string) v.string else null) else null;
                    if (data) |d| {
                        const mime = if (part.object.get("mime_type")) |v| (if (v == .string) v.string else null) else null;
                        last = .{ .data = d, .mime = mime };
                    }
                }
            }
            if (last) |f| return f;
        }
    }
    return null;
}

test "single speaker and two-speaker bodies differ" {
    var test_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer test_arena.deinit();
    const a = test_arena.allocator();
    const one = types.GenRequest{
        .prompt = "hello",
        .api_model = "gemini-3.8-flash-tts",
        .audio = .{ .voice = "Kore", .style = "calm" },
    };
    const body = try buildBody(a, one);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"voice\":\"Kore\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "speakers") == null);

    const two = types.GenRequest{
        .prompt = "",
        .api_model = "gemini-3.8-flash-tts",
        .audio = .{
            .mode = .dialogue,
            .dialogue = &.{
                .{ .speaker = "Joe", .text = "Hi", .voice = "Puck" },
                .{ .speaker = "Jane", .text = "Hello", .voice = "Kore" },
            },
        },
    };
    const body2 = try buildBody(a, two);
    defer a.free(body2);
    const joe = std.mem.indexOf(u8, body2, "Hi").?;
    const jane = std.mem.indexOf(u8, body2, "Hello").?;
    try std.testing.expect(joe < jane);
    try std.testing.expect(std.mem.indexOf(u8, body2, "speakers") != null);
}

test "interactions audio data becomes one wav" {
    var test_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer test_arena.deinit();
    const a = test_arena.allocator();
    const raw =
        \\{"steps":[{"type":"model_output","content":[{"type":"audio","mime_type":"audio/l16;rate=8000","data":"AAA="}]}]}
    ;
    const parsed = try parse(a, 200, raw, "wav", null);
    try std.testing.expect(audio.validateWav(parsed.outcome.done[0].bytes));
    try std.testing.expectEqual(@as(?u32, 8000), parsed.meta.sample_rate_hz);
}
