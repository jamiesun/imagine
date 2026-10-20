//! Wan image generation and editing (DashScope multimodal-generation).
//!
//! `POST .../aigc/multimodal-generation/generation` is synchronous: no
//! `X-DashScope-Async` header, result in `output.choices[].message.content[].image`.
//! `POST .../aigc/image-generation/generation` is the async sibling and needs
//! `X-DashScope-Async: enable`. The header is chosen from the configured URL,
//! not inferred from the JSON. Up to 9 reference images, in caller order.
//! Model id is `api_model` (for example `wan2.7-image-pro`). Verified 2026-10-20.

const std = @import("std");
const types = @import("../types.zig");
const images = @import("../images.zig");
const wire = @import("../wire.zig");
const ds = @import("dashscope_wire.zig");

pub const parseCreate = ds.parseCreate;
pub const parsePoll = ds.parsePoll;
pub const pollUrl = ds.pollUrl;

const Part = struct {
    text: ?[]const u8 = null,
    image: ?[]const u8 = null,
};

pub fn buildBody(allocator: std.mem.Allocator, req: types.GenRequest) ![]u8 {
    var parts = std.ArrayList(Part).empty;
    try parts.append(allocator, .{ .text = req.prompt });
    for (req.images) |img| {
        try parts.append(allocator, .{ .image = try images.transmitUrl(allocator, img) });
    }

    const Content = struct {
        role: []const u8 = "user",
        content: []const Part,
    };
    const Input = struct { messages: []const Content };
    const Params = struct {
        size: ?[]const u8 = null,
        n: u32 = 1,
        watermark: ?bool = null,
    };
    const Body = struct {
        model: []const u8,
        input: Input,
        parameters: Params,
    };

    var size: ?[]const u8 = null;
    if (req.size) |s| size = try ds.starSize(allocator, s);
    if (size == null) {
        if (req.width) |w| {
            if (req.height) |h| size = try std.fmt.allocPrint(allocator, "{d}*{d}", .{ w, h });
        }
    }

    const body = Body{
        .model = req.api_model,
        .input = .{ .messages = &.{.{ .content = try parts.toOwnedSlice(allocator) }} },
        .parameters = .{ .size = size, .watermark = req.watermark },
    };
    return std.json.Stringify.valueAlloc(allocator, body, .{ .emit_null_optional_fields = false });
}

test "wan image body keeps reference order and star size" {
    var test_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer test_arena.deinit();
    const a = test_arena.allocator();
    const req = types.GenRequest{
        .prompt = "keep the face",
        .api_model = "wan2.7-image-pro",
        .size = "1280x1280",
        .images = &.{
            .{ .source = "https://example.com/face.png" },
            .{ .source = "https://example.com/cloth.png", .role = .reference },
        },
    };
    const body = try buildBody(a, req);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "wan2.7-image-pro") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "1280*1280") != null);
    const face = std.mem.indexOf(u8, body, "face.png").?;
    const cloth = std.mem.indexOf(u8, body, "cloth.png").?;
    try std.testing.expect(face < cloth);
    _ = wire;
}
