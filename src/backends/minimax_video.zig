//! MiniMax / Hailuo video generation.
//!
//! `POST {base}` (usually `https://api.minimax.io/v1/video_generation`) returns
//! `task_id`. Status is `GET {origin}/v1/query/video_generation?task_id=`.
//! Success yields `file_id`, not a video URL. The file URL is a second
//! authenticated GET (`/v1/files/retrieve`) whose JSON `file.download_url` is a
//! CDN link and must be fetched *without* the MiniMax credential. `base_resp.status_code`
//! other than 0 fails the call. A reference image is `subject_reference`, which
//! is not the same field as the first frame. Checked 2026-10-20 against the
//! published video generation guide (create / query / retrieve).

const std = @import("std");
const types = @import("../types.zig");
const images = @import("../images.zig");
const wire = @import("../wire.zig");

const Subject = struct {
    type: []const u8 = "character",
    image: []const []const u8,
};

pub fn buildBody(allocator: std.mem.Allocator, req: types.GenRequest) ![]u8 {
    var refs = std.ArrayList([]const u8).empty;
    for (req.images) |img| {
        if (img.role == .reference) try refs.append(allocator, try images.transmitUrl(allocator, img));
    }
    const Body = struct {
        model: []const u8,
        prompt: []const u8,
        duration: ?u32 = null,
        resolution: ?[]const u8 = null,
        first_frame_image: ?[]const u8 = null,
        last_frame_image: ?[]const u8 = null,
        subject_reference: ?[]const Subject = null,
    };
    const body = Body{
        .model = req.api_model,
        .prompt = req.prompt,
        .duration = req.duration,
        .resolution = if (req.resolution) |r| upperP(allocator, r) catch r else null,
        .first_frame_image = if (images.first(req)) |img| try images.transmitUrl(allocator, img) else null,
        .last_frame_image = if (images.last(req)) |img| try images.transmitUrl(allocator, img) else null,
        .subject_reference = if (refs.items.len > 0) &.{.{ .image = try refs.toOwnedSlice(allocator) }} else null,
    };
    return std.json.Stringify.valueAlloc(allocator, body, .{ .emit_null_optional_fields = false });
}

fn upperP(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    const out = try allocator.alloc(u8, s.len);
    for (s, 0..) |c, i| out[i] = if (c == 'p') 'P' else c;
    return out;
}

pub fn parseCreate(allocator: std.mem.Allocator, status: u16, body: []const u8) !wire.TaskOutcome {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return .{ .api_error = try wire.rawError(allocator, status, body) };
    };
    defer parsed.deinit();
    const root = wire.rootObject(parsed.value) orelse
        return .{ .api_error = try std.fmt.allocPrint(allocator, "HTTP {d}: unexpected response", .{status}) };
    if (baseError(root)) |msg| return .{ .api_error = try std.fmt.allocPrint(allocator, "HTTP {d}: {s}", .{ status, msg }) };
    if (root.get("task_id")) |id| {
        if (id == .string and id.string.len > 0) return .{ .pending = try allocator.dupe(u8, id.string) };
    }
    return .{ .api_error = try std.fmt.allocPrint(allocator, "HTTP {d}: missing task_id", .{status}) };
}

pub fn pollUrl(allocator: std.mem.Allocator, base_url: []const u8, task_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/v1/query/video_generation?task_id={s}", .{ origin(base_url), task_id });
}

pub fn parsePoll(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    task_id: []const u8,
    status: u16,
    body: []const u8,
) !wire.PollOutcome {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return .{ .api_error = try wire.rawError(allocator, status, body) };
    };
    defer parsed.deinit();
    const root = wire.rootObject(parsed.value) orelse
        return .{ .api_error = try std.fmt.allocPrint(allocator, "HTTP {d}: unexpected response", .{status}) };
    if (baseError(root)) |msg| return .{ .api_error = try std.fmt.allocPrint(allocator, "task {s} failed: {s}", .{ task_id, msg }) };
    const st = if (root.get("status")) |v| (if (v == .string) v.string else "") else "";
    if (std.ascii.eqlIgnoreCase(st, "success")) {
        const file_v = root.get("file_id") orelse
            return .{ .api_error = try std.fmt.allocPrint(allocator, "task {s} succeeded but returned no file_id", .{task_id}) };
        const file_id: []const u8 = switch (file_v) {
            .string => |s| s,
            .integer => |i| try std.fmt.allocPrint(allocator, "{d}", .{i}),
            else => return .{ .api_error = try std.fmt.allocPrint(allocator, "task {s} succeeded but returned no file_id", .{task_id}) },
        };
        const retrieve = try std.fmt.allocPrint(allocator, "{s}/v1/files/retrieve?file_id={s}", .{ origin(base_url), file_id });
        const list = try allocator.alloc(types.Payload, 1);
        list[0] = .{ .relay = .{ .url = retrieve, .field = "file.download_url" } };
        return .{ .done = list };
    }
    if (std.ascii.eqlIgnoreCase(st, "fail") or std.ascii.eqlIgnoreCase(st, "failed")) {
        return .{ .api_error = try std.fmt.allocPrint(allocator, "task {s} failed", .{task_id}) };
    }
    return .pending;
}

fn origin(url: []const u8) []const u8 {
    const scheme = std.mem.indexOf(u8, url, "://") orelse return url;
    const rest = url[scheme + 3 ..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return url;
    return url[0 .. scheme + 3 + slash];
}

fn baseError(root: std.json.ObjectMap) ?[]const u8 {
    const v = root.get("base_resp") orelse return null;
    if (v != .object) return null;
    const code = v.object.get("status_code") orelse return null;
    const bad = switch (code) {
        .integer => |i| i != 0,
        else => false,
    };
    if (!bad) return null;
    if (v.object.get("status_msg")) |m| {
        if (m == .string and m.string.len > 0) return m.string;
    }
    return "minimax error";
}

test "minimax body separates first frame from subject reference" {
    var test_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer test_arena.deinit();
    const a = test_arena.allocator();
    const req = types.GenRequest{
        .prompt = "walks through rain",
        .api_model = "MiniMax-Hailuo-2.3",
        .resolution = "1080p",
        .duration = 6,
        .images = &.{
            .{ .source = "https://example.com/first.png", .role = .first_frame },
            .{ .source = "https://example.com/face.png", .role = .reference },
        },
    };
    const body = try buildBody(a, req);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "first_frame_image") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "subject_reference") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "1080P") != null);
    const poll = try pollUrl(a, "https://api.minimax.io/v1/video_generation", "task-1");
    try std.testing.expectEqualStrings("https://api.minimax.io/v1/query/video_generation?task_id=task-1", poll);
}

test "minimax success becomes a relay download and failure is not success" {
    var test_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer test_arena.deinit();
    const a = test_arena.allocator();
    const created = try parseCreate(a, 200, "{\"task_id\":\"m1\",\"base_resp\":{\"status_code\":0,\"status_msg\":\"success\"}}");
    try std.testing.expectEqualStrings("m1", created.pending);
    const done = try parsePoll(a, "https://api.minimax.io/v1/video_generation", "m1", 200,
        \\{"task_id":"m1","status":"Success","file_id":"file-9","base_resp":{"status_code":0}}
    );
    try std.testing.expect(std.mem.indexOf(u8, done.done[0].relay.url, "file-9") != null);
    try std.testing.expectEqualStrings("file.download_url", done.done[0].relay.field);
    const failed = try parsePoll(a, "https://api.minimax.io/v1/video_generation", "m1", 200, "{\"status\":\"Fail\",\"base_resp\":{\"status_code\":0}}");
    try std.testing.expect(failed == .api_error);
}
