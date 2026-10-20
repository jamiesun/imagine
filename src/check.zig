//! Usage checks that run before any provider HTTP call.
//! A message means exit code 2. Null means the request may proceed.

const std = @import("std");
const types = @import("types.zig");

pub fn usageError(allocator: std.mem.Allocator, kind: types.BackendKind, req: types.GenRequest, override: ?types.Capabilities) !?[]u8 {
    const caps = override orelse kind.capabilities();
    const media = kind.media();

    if (media != .audio and req.audio != null) {
        return try std.fmt.allocPrint(allocator, "backend {s} is {s} and does not accept audio options (--voice, --text-file, --dialogue-file, --stream, ...)", .{ kind.toString(), media.toString() });
    }
    if (media == .audio) {
        if (req.images.len > 0) {
            return try std.fmt.allocPrint(allocator, "backend {s} does not accept --image; voice references use --voice-reference", .{kind.toString()});
        }
        if (req.duration != null or req.resolution != null or req.ratio != null or req.watermark != null or
            req.steps != null or req.size != null or req.width != null or req.height != null or
            req.quality != null or req.output_compression != null)
        {
            return try std.fmt.allocPrint(allocator, "backend {s} does not accept image or video options (size, duration, ratio, watermark, steps, ...)", .{kind.toString()});
        }
        if (req.audio) |audio| {
            if (try audioMsg(allocator, kind, caps, req.prompt, req.output_format, audio)) |msg| return msg;
        } else if (req.prompt.len == 0) {
            return try allocator.dupe(u8, "missing text: pass --prompt, --text-file, --ssml-file, or --dialogue-file");
        }
        return null;
    }

    return imageMsg(allocator, kind, caps, req);
}

fn audioMsg(
    allocator: std.mem.Allocator,
    kind: types.BackendKind,
    caps: types.Capabilities,
    prompt: []const u8,
    format: ?[]const u8,
    audio: types.AudioParams,
) !?[]u8 {
    const mode_ok = switch (audio.mode) {
        .speech => caps.speech,
        .voice_design => caps.voice_design,
        .voice_clone => caps.voice_clone,
        .dialogue => true,
    };
    if (!mode_ok) {
        return try std.fmt.allocPrint(allocator, "backend {s} does not support {s}", .{ kind.toString(), audio.mode.toString() });
    }
    if (audio.ssml and !caps.ssml) {
        return try std.fmt.allocPrint(allocator, "backend {s} does not support SSML", .{kind.toString()});
    }
    if (audio.speed != null and !caps.speed) {
        return try std.fmt.allocPrint(allocator, "backend {s} does not support --speed", .{kind.toString()});
    }
    if (audio.pitch != null and !caps.pitch) {
        return try std.fmt.allocPrint(allocator, "backend {s} does not support --pitch", .{kind.toString()});
    }
    if (audio.style != null and audio.mode != .voice_design and !caps.style) {
        return try std.fmt.allocPrint(allocator, "backend {s} does not support --style", .{kind.toString()});
    }
    if (audio.stream == .on and !caps.streaming) {
        return try std.fmt.allocPrint(allocator, "backend {s} does not support incremental --stream (refusing rather than buffering a finished file and pretending it was streamed)", .{kind.toString()});
    }
    if (format) |fmt| {
        if (caps.formats.len > 0 and !formatAllowed(caps, fmt)) {
            return try std.fmt.allocPrint(allocator, "backend {s} does not support --format {s}", .{ kind.toString(), fmt });
        }
    }
    if (audio.mode == .voice_clone) {
        if (audio.reference == null) {
            return try allocator.dupe(u8, "voice_clone requires --voice-reference");
        }
        if (audio.reference_text == null or audio.reference_text.?.len == 0) {
            return try allocator.dupe(u8, "voice_clone requires --reference-text (the transcript of the reference audio)");
        }
    }
    if (audio.mode == .voice_design and (audio.style == null or audio.style.?.len == 0)) {
        return try allocator.dupe(u8, "voice_design requires --style (the voice description)");
    }
    if (audio.mode == .dialogue) {
        if (audio.dialogue.len == 0) return try allocator.dupe(u8, "dialogue requires --dialogue-file");
        if (caps.native_dialogue) {
            const speakers = distinctSpeakers(audio.dialogue);
            if (speakers > caps.max_speakers) {
                return try std.fmt.allocPrint(allocator, "backend {s} accepts at most {d} speakers in one request; this dialogue has {d}. imagine will not pretend a single request did it — split turns or use a model that supports them", .{ kind.toString(), caps.max_speakers, speakers });
            }
        } else if (audio.dialogue.len != 1) {
            return try std.fmt.allocPrint(allocator, "backend {s} has no native multi-speaker request; pass one turn at a time", .{kind.toString()});
        }
    } else if (prompt.len == 0) {
        return try allocator.dupe(u8, "missing text: pass --prompt, --text-file, or --ssml-file");
    }
    if (kind == .google_cloud_tts and audio.mode != .dialogue and (audio.voice == null or audio.voice.?.len == 0)) {
        return try allocator.dupe(u8, "google_cloud_tts requires --voice (a Cloud TTS voice name, not a Gemini voice)");
    }
    if (kind == .gemini_tts and audio.mode != .dialogue and (audio.voice == null or audio.voice.?.len == 0)) {
        return try allocator.dupe(u8, "gemini_tts requires --voice");
    }
    return null;
}

fn formatAllowed(caps: types.Capabilities, fmt: []const u8) bool {
    for (caps.formats) |ok| if (std.ascii.eqlIgnoreCase(ok, fmt)) return true;
    if (std.ascii.eqlIgnoreCase(fmt, "linear16")) return formatAllowed(caps, "pcm");
    return false;
}

fn distinctSpeakers(turns: []const types.DialogueTurn) u32 {
    var n: u32 = 0;
    for (turns, 0..) |t, i| {
        var seen = false;
        for (turns[0..i]) |prev| {
            if (std.mem.eql(u8, prev.speaker, t.speaker)) {
                seen = true;
                break;
            }
        }
        if (!seen) n += 1;
    }
    return n;
}

fn imageMsg(allocator: std.mem.Allocator, kind: types.BackendKind, caps: types.Capabilities, req: types.GenRequest) !?[]u8 {
    var n_auto: usize = 0;
    var n_first: usize = 0;
    var n_last: usize = 0;
    var n_ref: usize = 0;
    for (req.images) |img| switch (img.role) {
        .auto => n_auto += 1,
        .first_frame => n_first += 1,
        .last_frame => n_last += 1,
        .reference => n_ref += 1,
    };
    const total = n_auto + n_first + n_last + n_ref;
    if (total == 0) return null;
    if (caps.max_images == 0) {
        return try std.fmt.allocPrint(allocator, "backend {s} takes no --image input", .{kind.toString()});
    }
    if (n_first > 0 and n_auto > 0) {
        return try allocator.dupe(u8, "--image and --first-frame together are ambiguous; pass only one");
    }
    if (n_first > 1) return try allocator.dupe(u8, "at most one --first-frame");
    if (n_last > 1) return try allocator.dupe(u8, "at most one --last-frame");
    if (n_first > 0 and !caps.first_frame) {
        return try std.fmt.allocPrint(allocator, "backend {s} does not accept --first-frame", .{kind.toString()});
    }
    if (n_last > 0 and !caps.last_frame) {
        return try std.fmt.allocPrint(allocator, "backend {s} does not accept --last-frame", .{kind.toString()});
    }
    if (n_last > 0 and n_first == 0 and n_auto == 0) {
        return try allocator.dupe(u8, "--last-frame requires a first frame (--first-frame or a single --image)");
    }
    if (n_auto > caps.max_auto_images) {
        return try std.fmt.allocPrint(allocator, "backend {s} accepts at most {d} --image input(s); received {d}", .{ kind.toString(), caps.max_auto_images, n_auto });
    }
    if (n_ref > caps.max_ref_images) {
        return try std.fmt.allocPrint(allocator, "backend {s} accepts at most {d} --ref-image input(s); received {d}", .{ kind.toString(), caps.max_ref_images, n_ref });
    }
    if (n_ref > 0 and caps.max_ref_images == 0) {
        return try std.fmt.allocPrint(allocator, "backend {s} does not accept --ref-image", .{kind.toString()});
    }
    if (total > caps.max_images) {
        return try std.fmt.allocPrint(allocator, "backend {s} accepts at most {d} images in one request; received {d}", .{ kind.toString(), caps.max_images, total });
    }
    // Vidu reference-to-video is a different endpoint from first/last frame.
    if (kind == .vidu_video and n_ref > 0 and (n_first > 0 or n_last > 0 or n_auto > 0)) {
        return try allocator.dupe(u8, "vidu reference images and first/last frames are different APIs; pass only --ref-image or only a first/last frame");
    }
    return null;
}

test "video rejects a last frame without a first and ambiguous image flags" {
    var test_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer test_arena.deinit();
    const a = test_arena.allocator();
    const bad = types.GenRequest{
        .prompt = "x",
        .api_model = "m",
        .images = &.{.{ .source = "a.png", .role = .last_frame }},
    };
    const msg = (try usageError(a, .dashscope_video, bad, null)).?;
    defer a.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "last-frame") != null);

    const clash = types.GenRequest{
        .prompt = "x",
        .api_model = "m",
        .images = &.{
            .{ .source = "a.png", .role = .auto },
            .{ .source = "b.png", .role = .first_frame },
        },
    };
    const msg2 = (try usageError(a, .kling_video, clash, null)).?;
    defer a.free(msg2);
    try std.testing.expect(std.mem.indexOf(u8, msg2, "ambiguous") != null);
}

test "audio flags are rejected on image backends before any request" {
    var test_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer test_arena.deinit();
    const a = test_arena.allocator();
    const req = types.GenRequest{
        .prompt = "hi",
        .api_model = "m",
        .audio = .{ .voice = "Vivian" },
    };
    const msg = (try usageError(a, .openai_image, req, null)).?;
    defer a.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "audio") != null);
}

test "strict stream is rejected when the backend is not incremental" {
    var test_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer test_arena.deinit();
    const a = test_arena.allocator();
    const req = types.GenRequest{
        .prompt = "hi",
        .api_model = "m",
        .audio = .{ .voice = "en-US-Chirp3-HD-Charon", .stream = .on },
    };
    const msg = (try usageError(a, .google_cloud_tts, req, null)).?;
    defer a.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "--stream") != null);
}
