//! Wan text-to-video and image-to-video (DashScope video-synthesis).
//!
//! Async only: `X-DashScope-Async: enable`, then `GET /api/v1/tasks/{id}`.
//! First frame and last frame go in `input.media[]` as `first_frame` / `last_frame`.
//! `--image` on a video model is the first frame. Reference video and driving
//! audio are different media types and are not accepted through `--image`.
//! `parameters.resolution` is `720P` / `1080P`. Ratio is sent only for text-to-video;
//! image-to-video follows the input frame. Verified 2026-10-20.

const std = @import("std");
const types = @import("../types.zig");
const images = @import("../images.zig");
const ds = @import("dashscope_wire.zig");

pub const parseCreate = ds.parseCreate;
pub const parsePoll = ds.parsePoll;
pub const pollUrl = ds.pollUrl;

const Media = struct {
    type: []const u8,
    url: []const u8,
};

pub fn buildBody(allocator: std.mem.Allocator, req: types.GenRequest) ![]u8 {
    var media = std.ArrayList(Media).empty;
    if (images.first(req)) |img| {
        try media.append(allocator, .{ .type = "first_frame", .url = try images.transmitUrl(allocator, img) });
    }
    if (images.last(req)) |img| {
        try media.append(allocator, .{ .type = "last_frame", .url = try images.transmitUrl(allocator, img) });
    }
    const has_media = media.items.len > 0;

    const Input = struct {
        prompt: []const u8,
        media: ?[]const Media = null,
    };
    const Params = struct {
        resolution: ?[]const u8 = null,
        ratio: ?[]const u8 = null,
        duration: ?u32 = null,
        watermark: ?bool = null,
        seed: ?i64 = null,
    };
    const Body = struct {
        model: []const u8,
        input: Input,
        parameters: Params,
    };
    const body = Body{
        .model = req.api_model,
        .input = .{
            .prompt = req.prompt,
            .media = if (has_media) try media.toOwnedSlice(allocator) else null,
        },
        .parameters = .{
            .resolution = if (req.resolution) |r| ds.wanTier(r) else null,
            .ratio = if (has_media) null else req.ratio,
            .duration = req.duration,
            .watermark = req.watermark,
            .seed = req.seed,
        },
    };
    return std.json.Stringify.valueAlloc(allocator, body, .{ .emit_null_optional_fields = false });
}

test "wan video maps first and last frames and uppercases resolution" {
    var test_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer test_arena.deinit();
    const a = test_arena.allocator();
    const req = types.GenRequest{
        .prompt = "the gate closes",
        .api_model = "wan2.7-i2v",
        .resolution = "720p",
        .duration = 5,
        .ratio = "16:9",
        .images = &.{
            .{ .source = "https://example.com/open.png", .role = .first_frame },
            .{ .source = "https://example.com/shut.png", .role = .last_frame },
        },
    };
    const body = try buildBody(a, req);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"first_frame\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"last_frame\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "720P") != null);
    // Image-to-video follows the frame; a ratio would describe a different API.
    try std.testing.expect(std.mem.indexOf(u8, body, "16:9") == null);
}

test "wan text-to-video keeps ratio and omits media" {
    var test_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer test_arena.deinit();
    const a = test_arena.allocator();
    const req = types.GenRequest{
        .prompt = "fog",
        .api_model = "wan2.7-t2v",
        .ratio = "9:16",
        .duration = 5,
    };
    const body = try buildBody(a, req);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "9:16") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "media") == null);
}
