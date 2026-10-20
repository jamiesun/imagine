//! Audio container helpers and text segmentation.
//!
//! Imagine writes the bytes a provider returned. The only container work here is
//! wrapping raw PCM in a single WAV header when the provider said the bytes are
//! PCM and the caller asked for wav. It does not resample, concatenate, or
//! invent timestamps.

const std = @import("std");
const types = @import("types.zig");

pub fn sha256Hex(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const out = try allocator.alloc(u8, digest.len * 2);
    const charset = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out[i * 2] = charset[b >> 4];
        out[i * 2 + 1] = charset[b & 0x0f];
    }
    return out;
}

pub fn utf8Len(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

/// 44-byte canonical PCM WAV (16-bit little-endian) plus `pcm`.
pub fn wavFromPcm(allocator: std.mem.Allocator, pcm: []const u8, sample_rate: u32, channels: u16) ![]u8 {
    if (channels == 0 or sample_rate == 0) return error.BadWav;
    if (pcm.len % (@as(usize, channels) * 2) != 0) return error.BadWav;
    const out = try allocator.alloc(u8, 44 + pcm.len);
    writeWavHeader(out[0..44], pcm.len, sample_rate, channels);
    @memcpy(out[44..], pcm);
    return out;
}

pub fn writeWavHeader(header: []u8, pcm_len: usize, sample_rate: u32, channels: u16) void {
    std.debug.assert(header.len >= 44);
    const byte_rate: u32 = sample_rate * @as(u32, channels) * 2;
    const block: u16 = channels * 2;
    @memcpy(header[0..4], "RIFF");
    std.mem.writeInt(u32, header[4..8], @intCast(36 + pcm_len), .little);
    @memcpy(header[8..12], "WAVE");
    @memcpy(header[12..16], "fmt ");
    std.mem.writeInt(u32, header[16..20], 16, .little);
    std.mem.writeInt(u16, header[20..22], 1, .little);
    std.mem.writeInt(u16, header[22..24], channels, .little);
    std.mem.writeInt(u32, header[24..28], sample_rate, .little);
    std.mem.writeInt(u32, header[28..32], byte_rate, .little);
    std.mem.writeInt(u16, header[32..34], block, .little);
    std.mem.writeInt(u16, header[34..36], 16, .little);
    @memcpy(header[36..40], "data");
    std.mem.writeInt(u32, header[40..44], @intCast(pcm_len), .little);
}

/// One RIFF/WAVE container whose declared size matches the buffer.
/// A second RIFF+WAVE pair means two wav files were concatenated.
pub fn validateWav(bytes: []const u8) bool {
    if (wavContainerCount(bytes) != 1) return false;
    if (bytes.len < 44) return false;
    const declared: usize = std.mem.readInt(u32, bytes[4..8], .little);
    // 0xFFFFFFFF is a streaming placeholder, not a finished file.
    if (declared == 0xffffffff) return false;
    return declared + 8 == bytes.len;
}

pub fn wavContainerCount(bytes: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i + 12 <= bytes.len) : (i += 1) {
        if (std.mem.eql(u8, bytes[i..][0..4], "RIFF") and std.mem.eql(u8, bytes[i + 8 ..][0..4], "WAVE")) {
            n += 1;
        }
    }
    return n;
}

pub fn isPcmMime(mime: []const u8) bool {
    return std.mem.indexOf(u8, mime, "L16") != null or
        std.mem.indexOf(u8, mime, "l16") != null or
        std.mem.indexOf(u8, mime, "pcm") != null or
        std.ascii.eqlIgnoreCase(mime, "audio/raw");
}

pub fn looksLikeWav(bytes: []const u8) bool {
    return bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WAVE");
}

pub fn looksLikeMp3(bytes: []const u8) bool {
    if (bytes.len >= 3 and std.mem.eql(u8, bytes[0..3], "ID3")) return true;
    return bytes.len >= 2 and bytes[0] == 0xff and (bytes[1] & 0xe0) == 0xe0;
}

pub fn looksLikeOgg(bytes: []const u8) bool {
    return bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "OggS");
}

/// Sample rate from an `audio/L16;rate=24000` style MIME, if present.
pub fn sampleRateFromMime(mime: []const u8) ?u32 {
    const key = "rate=";
    const at = std.mem.indexOf(u8, mime, key) orelse return null;
    const rest = mime[at + key.len ..];
    var end = rest.len;
    for (rest, 0..) |c, i| {
        if (c < '0' or c > '9') {
            end = i;
            break;
        }
    }
    if (end == 0) return null;
    return std.fmt.parseInt(u32, rest[0..end], 10) catch null;
}

pub const Segment = struct {
    text: []const u8,
    char_start: usize,
    char_end: usize,
};

/// Split `text` into pieces of at most `max_chars` Unicode scalars, preferring
/// a sentence boundary. Pieces cover the input exactly once, in order. A long
/// sentence with no boundary is cut at `max_chars` so no character is dropped
/// and none is repeated.
pub fn splitText(allocator: std.mem.Allocator, text: []const u8, max_chars: u32) ![]Segment {
    if (max_chars == 0) return error.BadLimit;
    var out = std.ArrayList(Segment).empty;
    var byte_i: usize = 0;
    var char_base: usize = 0;
    while (byte_i < text.len) {
        var byte_j = byte_i;
        var chars: usize = 0;
        var break_byte: ?usize = null;
        var break_chars: usize = 0;
        while (byte_j < text.len and chars < max_chars) {
            const len = std.unicode.utf8ByteSequenceLength(text[byte_j]) catch {
                byte_j += 1;
                chars += 1;
                continue;
            };
            if (byte_j + len > text.len) break;
            const ch = text[byte_j .. byte_j + len];
            byte_j += len;
            chars += 1;
            if (chars > 1 and isBreak(ch)) {
                break_byte = byte_j;
                break_chars = chars;
            }
        }
        const end_byte = break_byte orelse byte_j;
        const end_chars = if (break_byte != null) break_chars else chars;
        if (end_byte == byte_i) break;
        try out.append(allocator, .{
            .text = text[byte_i..end_byte],
            .char_start = char_base,
            .char_end = char_base + end_chars,
        });
        byte_i = end_byte;
        char_base += end_chars;
    }
    return out.toOwnedSlice(allocator);
}

fn isBreak(ch: []const u8) bool {
    return std.mem.eql(u8, ch, "\n") or std.mem.eql(u8, ch, ".") or std.mem.eql(u8, ch, "!") or
        std.mem.eql(u8, ch, "?") or std.mem.eql(u8, ch, ";") or std.mem.eql(u8, ch, "。") or
        std.mem.eql(u8, ch, "！") or std.mem.eql(u8, ch, "？") or std.mem.eql(u8, ch, "；");
}

pub fn parseDialogue(allocator: std.mem.Allocator, bytes: []const u8) ![]types.DialogueTurn {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const arr = switch (parsed.value) {
        .array => |a| a,
        .object => |o| blk: {
            const v = o.get("turns") orelse o.get("dialogue") orelse return error.BadDialogue;
            if (v != .array) return error.BadDialogue;
            break :blk v.array;
        },
        else => return error.BadDialogue,
    };
    var turns = try allocator.alloc(types.DialogueTurn, arr.items.len);
    for (arr.items, 0..) |item, i| {
        if (item != .object) return error.BadDialogue;
        const o = item.object;
        const text = switch (o.get("text") orelse return error.BadDialogue) {
            .string => |s| try allocator.dupe(u8, s),
            else => return error.BadDialogue,
        };
        const speaker = if (o.get("speaker")) |sv| switch (sv) {
            .string => |s| try allocator.dupe(u8, s),
            else => return error.BadDialogue,
        } else try allocator.dupe(u8, "");
        turns[i] = .{
            .speaker = speaker,
            .text = text,
            .voice = if (jsonString(o, "voice")) |s| try allocator.dupe(u8, s) else null,
            .style = if (jsonString(o, "style")) |s| try allocator.dupe(u8, s) else null,
            .language = if (jsonString(o, "language")) |s| try allocator.dupe(u8, s) else null,
        };
    }
    return turns;
}

fn jsonString(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// SSML `<mark>` timings. `granularity` is always `ssml_mark` — these are not words.
pub fn ssmlMarkAlignment(
    allocator: std.mem.Allocator,
    source: []const u8,
    text: []const u8,
    marks: []const Mark,
) ![]u8 {
    const hash = try sha256Hex(allocator, text);
    var list = std.ArrayList(u8).empty;
    try list.appendSlice(allocator, "{\"granularity\":\"ssml_mark\",\"source\":");
    try appendJsonString(&list, allocator, source);
    try list.appendSlice(allocator, ",\"time_unit\":\"seconds\",\"text_sha256\":");
    try appendJsonString(&list, allocator, hash);
    try list.appendSlice(allocator, ",\"marks\":[");
    for (marks, 0..) |m, i| {
        if (i > 0) try list.append(allocator, ',');
        try list.appendSlice(allocator, "{\"name\":");
        try appendJsonString(&list, allocator, m.name);
        try list.appendSlice(allocator, ",\"start\":");
        var buf: [64]u8 = undefined;
        const sec = try std.fmt.bufPrint(&buf, "{d}", .{m.seconds});
        try list.appendSlice(allocator, sec);
        try list.append(allocator, '}');
    }
    try list.appendSlice(allocator, "]}");
    return list.toOwnedSlice(allocator);
}

pub const Mark = struct { name: []const u8, seconds: f64 };

fn appendJsonString(list: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try list.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try list.appendSlice(allocator, "\\\""),
            '\\' => try list.appendSlice(allocator, "\\\\"),
            '\n' => try list.appendSlice(allocator, "\\n"),
            else => try list.append(allocator, c),
        }
    }
    try list.append(allocator, '"');
}

test "wav header matches payload and rejects a second container" {
    var test_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer test_arena.deinit();
    const a = test_arena.allocator();
    const pcm = [_]u8{ 0, 0, 1, 0, 2, 0, 3, 0 };
    const wav = try wavFromPcm(a, &pcm, 8000, 1);
    defer a.free(wav);
    try std.testing.expect(validateWav(wav));
    const glued = try std.mem.concat(a, u8, &.{ wav, wav });
    defer a.free(glued);
    try std.testing.expect(!validateWav(glued));
    try std.testing.expectEqual(@as(usize, 2), wavContainerCount(glued));
}

test "splitText covers the source once" {
    var test_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer test_arena.deinit();
    const a = test_arena.allocator();
    const text = "第一句。第二句！third sentence. tail";
    const parts = try splitText(a, text, 8);
    defer a.free(parts);
    try std.testing.expect(parts.len >= 2);
    var joined = std.ArrayList(u8).empty;
    defer joined.deinit(a);
    var prev: usize = 0;
    for (parts) |p| {
        try std.testing.expectEqual(prev, p.char_start);
        try joined.appendSlice(a, p.text);
        prev = p.char_end;
    }
    try std.testing.expectEqualStrings(text, joined.items);
}

test "dialogue file keeps speaker order" {
    var test_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer test_arena.deinit();
    const a = test_arena.allocator();
    const raw =
        \\[{"speaker":"Joe","text":"Hi","voice":"Puck"},{"speaker":"Jane","text":"Hello","style":"calm"}]
    ;
    const turns = try parseDialogue(a, raw);
    defer a.free(turns);
    try std.testing.expectEqual(@as(usize, 2), turns.len);
    try std.testing.expectEqualStrings("Jane", turns[1].speaker);
    try std.testing.expectEqualStrings("Hello", turns[1].text);
}
