//! SiliconFlow image generation.
//!
//! `POST /v1/images/generations` with `image_size`, optional `num_inference_steps`
//! and `seed`. The success body is `images[].url`, which is not the OpenAI
//! `data[]` shape, so this is not `openai_image`. One reference image is sent
//! as `image` when the caller passed one; models that cannot edit fail at the
//! server instead of having the image dropped. Checked 2026-10-20 against
//! SiliconFlow's image generations reference.

const std = @import("std");
const types = @import("../types.zig");
const images = @import("../images.zig");
const wire = @import("../wire.zig");

pub fn buildBody(allocator: std.mem.Allocator, req: types.GenRequest) ![]u8 {
    const size = req.size orelse blk: {
        if (req.width) |w| {
            if (req.height) |h| break :blk try std.fmt.allocPrint(allocator, "{d}x{d}", .{ w, h });
        }
        break :blk null;
    };
    const Body = struct {
        model: []const u8,
        prompt: []const u8,
        image_size: ?[]const u8 = null,
        num_inference_steps: ?u32 = null,
        seed: ?i64 = null,
        image: ?[]const u8 = null,
    };
    const img: ?[]const u8 = if (req.images.len > 0) try images.transmitUrl(allocator, req.images[0]) else null;
    const body = Body{
        .model = req.api_model,
        .prompt = req.prompt,
        .image_size = size,
        .num_inference_steps = req.steps,
        .seed = req.seed,
        .image = img,
    };
    return std.json.Stringify.valueAlloc(allocator, body, .{ .emit_null_optional_fields = false });
}

pub fn parse(allocator: std.mem.Allocator, status: u16, body: []const u8) !wire.TaskOutcome {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return .{ .api_error = try wire.rawError(allocator, status, body) };
    };
    defer parsed.deinit();
    const root = wire.rootObject(parsed.value) orelse
        return .{ .api_error = try std.fmt.allocPrint(allocator, "HTTP {d}: unexpected response", .{status}) };
    if (root.get("error") != null or status >= 400) {
        return .{ .api_error = try wire.apiError(allocator, status, body, root) };
    }
    var list = std.ArrayList(types.Payload).empty;
    if (root.get("images")) |iv| try appendImages(allocator, &list, iv);
    if (root.get("data")) |dv| try appendImages(allocator, &list, dv);
    if (list.items.len == 0) return .{ .api_error = try std.fmt.allocPrint(allocator, "HTTP {d}: no images in response", .{status}) };
    return .{ .done = try list.toOwnedSlice(allocator) };
}

fn appendImages(allocator: std.mem.Allocator, list: *std.ArrayList(types.Payload), v: std.json.Value) !void {
    if (v != .array) return;
    for (v.array.items) |item| {
        if (item != .object) continue;
        if (item.object.get("url")) |uv| {
            if (uv == .string) try list.append(allocator, .{ .url = try allocator.dupe(u8, uv.string) });
        } else if (item.object.get("b64_json")) |bv| {
            if (bv == .string) {
                const util = @import("../util.zig");
                const bytes = util.base64DecodeAlloc(allocator, bv.string) catch continue;
                try list.append(allocator, .{ .bytes = bytes });
            }
        }
    }
}

test "siliconflow body uses image_size and keeps a reference" {
    var test_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer test_arena.deinit();
    const a = test_arena.allocator();
    const req = types.GenRequest{
        .prompt = "a fox",
        .api_model = "black-forest-labs/FLUX.1-schnell",
        .size = "1024x1024",
        .steps = 4,
        .images = &.{.{ .source = "https://example.com/ref.png" }},
    };
    const body = try buildBody(a, req);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"image_size\":\"1024x1024\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "num_inference_steps") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "ref.png") != null);
}

test "siliconflow parses images[].url" {
    var test_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer test_arena.deinit();
    const a = test_arena.allocator();
    const outcome = try parse(a, 200, "{\"images\":[{\"url\":\"https://cdn.example/a.png\"}],\"seed\":1}");
    try std.testing.expectEqualStrings("https://cdn.example/a.png", outcome.done[0].url);
}
