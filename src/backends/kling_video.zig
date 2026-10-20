//! Kling text-to-video and image-to-video (official v1 task API).
//!
//! `POST {host}/v1/videos/text2video` or `.../image2video`. `duration` is a
//! string on this protocol. `image_tail` is the last frame. Poll
//! `GET {create url}/{task_id}`. `code != 0` or `task_status: failed` fails the
//! task even when HTTP is 200. Auth is either a caller-supplied bearer token or
//! `jwt_hs256` (access key + secret), minted in `backend.zig`. This is the v1
//! wire format, not Omni/element/motion-control. Checked against the published
//! imageToVideo field names (model_name, image, image_tail, task_status).

const std = @import("std");
const types = @import("../types.zig");
const images = @import("../images.zig");
const util = @import("../util.zig");
const wire = @import("../wire.zig");

pub fn targetUrl(allocator: std.mem.Allocator, base_url: []const u8, req: types.GenRequest) ![]const u8 {
    const base = std.mem.trimEnd(u8, base_url, "/");
    if (std.mem.endsWith(u8, base, "/text2video") or std.mem.endsWith(u8, base, "/image2video")) return base;
    const leaf: []const u8 = if (images.first(req) != null) "image2video" else "text2video";
    return std.fmt.allocPrint(allocator, "{s}/v1/videos/{s}", .{ base, leaf });
}

pub fn buildBody(allocator: std.mem.Allocator, req: types.GenRequest) ![]u8 {
    const Body = struct {
        model_name: []const u8,
        prompt: []const u8,
        duration: ?[]const u8 = null,
        aspect_ratio: ?[]const u8 = null,
        image: ?[]const u8 = null,
        image_tail: ?[]const u8 = null,
    };
    const duration = if (req.duration) |d| try std.fmt.allocPrint(allocator, "{d}", .{d}) else null;
    const body = Body{
        .model_name = req.api_model,
        .prompt = req.prompt,
        .duration = duration,
        .aspect_ratio = req.ratio,
        .image = if (images.first(req)) |img| try klingImage(allocator, img) else null,
        .image_tail = if (images.last(req)) |img| try klingImage(allocator, img) else null,
    };
    return std.json.Stringify.valueAlloc(allocator, body, .{ .emit_null_optional_fields = false });
}

/// Kling takes a URL or raw base64, not a `data:` URL.
fn klingImage(allocator: std.mem.Allocator, img: types.InputImage) ![]const u8 {
    const bytes = img.bytes orelse return img.source;
    return util.base64EncodeAlloc(allocator, bytes);
}

pub fn parseCreate(allocator: std.mem.Allocator, status: u16, body: []const u8) !wire.TaskOutcome {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return .{ .api_error = try wire.rawError(allocator, status, body) };
    };
    defer parsed.deinit();
    const root = wire.rootObject(parsed.value) orelse
        return .{ .api_error = try std.fmt.allocPrint(allocator, "HTTP {d}: unexpected response", .{status}) };
    if (codeError(root)) |msg| return .{ .api_error = try std.fmt.allocPrint(allocator, "HTTP {d}: {s}", .{ status, msg }) };
    const data = objectField(root, "data") orelse
        return .{ .api_error = try std.fmt.allocPrint(allocator, "HTTP {d}: missing data", .{status}) };
    if (stringField(data, "task_status")) |st| {
        if (std.ascii.eqlIgnoreCase(st, "failed")) {
            return .{ .api_error = try std.fmt.allocPrint(allocator, "task failed: {s}", .{stringField(data, "task_status_msg") orelse "failed"}) };
        }
    }
    if (stringField(data, "task_id")) |id| return .{ .pending = try allocator.dupe(u8, id) };
    return .{ .api_error = try std.fmt.allocPrint(allocator, "HTTP {d}: missing task_id", .{status}) };
}

pub fn pollUrl(allocator: std.mem.Allocator, base_url: []const u8, task_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ std.mem.trimEnd(u8, base_url, "/"), task_id });
}

pub fn parsePoll(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    task_id: []const u8,
    status: u16,
    body: []const u8,
) !wire.PollOutcome {
    _ = base_url;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return .{ .api_error = try wire.rawError(allocator, status, body) };
    };
    defer parsed.deinit();
    const root = wire.rootObject(parsed.value) orelse
        return .{ .api_error = try std.fmt.allocPrint(allocator, "HTTP {d}: unexpected response", .{status}) };
    if (codeError(root)) |msg| return .{ .api_error = try std.fmt.allocPrint(allocator, "task {s} failed: {s}", .{ task_id, msg }) };
    const data = objectField(root, "data") orelse
        return .{ .api_error = try std.fmt.allocPrint(allocator, "task {s}: missing data", .{task_id}) };
    const st = stringField(data, "task_status") orelse return .pending;
    if (std.ascii.eqlIgnoreCase(st, "succeed") or std.ascii.eqlIgnoreCase(st, "succeeded")) {
        const result = objectField(data, "task_result") orelse
            return .{ .api_error = try std.fmt.allocPrint(allocator, "task {s} succeeded but returned no task_result", .{task_id}) };
        const videos = result.get("videos") orelse
            return .{ .api_error = try std.fmt.allocPrint(allocator, "task {s} succeeded but returned no videos", .{task_id}) };
        if (videos != .array or videos.array.items.len == 0 or videos.array.items[0] != .object) {
            return .{ .api_error = try std.fmt.allocPrint(allocator, "task {s} succeeded but returned no videos", .{task_id}) };
        }
        const url_v = videos.array.items[0].object.get("url") orelse
            return .{ .api_error = try std.fmt.allocPrint(allocator, "task {s} succeeded but returned no url", .{task_id}) };
        if (url_v != .string) return .{ .api_error = try std.fmt.allocPrint(allocator, "task {s} succeeded but returned no url", .{task_id}) };
        const list = try allocator.alloc(types.Payload, 1);
        list[0] = .{ .url = try allocator.dupe(u8, url_v.string) };
        return .{ .done = list };
    }
    if (std.ascii.eqlIgnoreCase(st, "failed")) {
        return .{ .api_error = try std.fmt.allocPrint(allocator, "task {s} failed: {s}", .{ task_id, stringField(data, "task_status_msg") orelse "failed" }) };
    }
    return .pending;
}

fn codeError(root: std.json.ObjectMap) ?[]const u8 {
    const v = root.get("code") orelse return null;
    const bad = switch (v) {
        .integer => |i| i != 0,
        .string => |s| !std.mem.eql(u8, s, "0"),
        else => false,
    };
    if (!bad) return null;
    return stringField(root, "message") orelse "kling error";
}

fn objectField(o: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const v = o.get(key) orelse return null;
    return if (v == .object) v.object else null;
}

fn stringField(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

test "kling image2video sends duration as a string and a tail frame" {
    var test_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer test_arena.deinit();
    const a = test_arena.allocator();
    const req = types.GenRequest{
        .prompt = "push in",
        .api_model = "kling-v2-1",
        .duration = 5,
        .ratio = "16:9",
        .images = &.{
            .{ .source = "https://example.com/a.png", .role = .first_frame },
            .{ .source = "https://example.com/b.png", .role = .last_frame },
        },
    };
    const url = try targetUrl(a, "https://api-beijing.klingai.com", req);
    try std.testing.expectEqualStrings("https://api-beijing.klingai.com/v1/videos/image2video", url);
    const body = try buildBody(a, req);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"duration\":\"5\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "image_tail") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "model_name") != null);
}

test "kling succeed and nonzero code" {
    var test_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer test_arena.deinit();
    const a = test_arena.allocator();
    const created = try parseCreate(a, 200, "{\"code\":0,\"data\":{\"task_id\":\"k1\",\"task_status\":\"submitted\"}}");
    try std.testing.expectEqualStrings("k1", created.pending);
    const done = try parsePoll(a, "https://api.klingai.com/v1/videos/text2video", "k1", 200,
        \\{"code":0,"data":{"task_status":"succeed","task_result":{"videos":[{"url":"https://cdn.example/k.mp4"}]}}}
    );
    try std.testing.expectEqualStrings("https://cdn.example/k.mp4", done.done[0].url);
    const denied = try parseCreate(a, 200, "{\"code\":1000,\"message\":\"access denied\"}");
    try std.testing.expect(std.mem.indexOf(u8, denied.api_error, "access denied") != null);
}
