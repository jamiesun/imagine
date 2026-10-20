//! Shared DashScope task envelope.
//!
//! Create responses are either an inline result (`output.choices[].message.content[].image`
//! or `output.video_url`) or `{output.task_id, output.task_status}`. Polling is
//! `GET {origin}/api/v1/tasks/{task_id}`. Verified against the Wan text-to-video,
//! image-to-video, and image generation references on 2026-10-20.
//! HTTP 200 with `task_status: FAILED` is a failed task, not success.

const std = @import("std");
const types = @import("../types.zig");
const wire = @import("../wire.zig");

pub fn asyncHeader(url: []const u8) bool {
    return std.mem.indexOf(u8, url, "video-synthesis") != null or
        std.mem.indexOf(u8, url, "image-generation") != null;
}

pub fn pollUrl(allocator: std.mem.Allocator, base_url: []const u8, task_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/api/v1/tasks/{s}", .{ origin(base_url), task_id });
}

fn origin(url: []const u8) []const u8 {
    const scheme = std.mem.indexOf(u8, url, "://") orelse return url;
    const rest = url[scheme + 3 ..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return url;
    return url[0 .. scheme + 3 + slash];
}

pub fn parseCreate(allocator: std.mem.Allocator, status: u16, body: []const u8) !wire.TaskOutcome {
    return parse(allocator, status, body, null, true);
}

pub fn parsePoll(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    task_id: []const u8,
    status: u16,
    body: []const u8,
) !wire.PollOutcome {
    _ = base_url;
    return switch (try parse(allocator, status, body, task_id, false)) {
        .pending => .pending,
        .done => |assets| .{ .done = assets },
        .api_error => |msg| .{ .api_error = msg },
    };
}

fn parse(
    allocator: std.mem.Allocator,
    status: u16,
    body: []const u8,
    task_id: ?[]const u8,
    allow_create: bool,
) !wire.TaskOutcome {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return .{ .api_error = try wire.rawError(allocator, status, body) };
    };
    defer parsed.deinit();
    const root = wire.rootObject(parsed.value) orelse
        return .{ .api_error = try std.fmt.allocPrint(allocator, "HTTP {d}: unexpected response", .{status}) };

    if (root.get("code")) |cv| {
        if (cv == .string and root.get("output") == null) {
            return .{ .api_error = try failText(allocator, status, root, task_id) };
        }
    }

    const output_v = root.get("output");
    const output = if (output_v) |ov| (if (ov == .object) ov.object else null) else null;

    if (output) |o| {
        if (try collectAssets(allocator, o)) |assets| {
            if (assets.len > 0) return .{ .done = assets };
        }
        if (o.get("task_status")) |sv| {
            if (sv == .string) {
                const state = sv.string;
                if (eql(state, "FAILED") or eql(state, "CANCELED") or eql(state, "UNKNOWN")) {
                    return .{ .api_error = try failText(allocator, status, root, taskId(o) orelse task_id) };
                }
                if (eql(state, "SUCCEEDED")) {
                    return .{ .api_error = try std.fmt.allocPrint(allocator, "task {s} succeeded but returned no asset url", .{taskId(o) orelse task_id orelse "?"}) };
                }
            }
        }
        if (taskId(o)) |id| {
            _ = allow_create;
            return .{ .pending = try allocator.dupe(u8, id) };
        }
    }
    if (status >= 400) return .{ .api_error = try failText(allocator, status, root, task_id) };
    return .{ .api_error = try std.fmt.allocPrint(allocator, "HTTP {d}: unexpected DashScope response", .{status}) };
}

fn collectAssets(allocator: std.mem.Allocator, output: std.json.ObjectMap) !?[]types.Payload {
    var list = std.ArrayList(types.Payload).empty;
    if (output.get("video_url")) |uv| {
        if (uv == .string) try list.append(allocator, .{ .url = try allocator.dupe(u8, uv.string) });
    }
    if (output.get("results")) |rv| {
        if (rv == .array) {
            for (rv.array.items) |item| {
                if (item == .object) {
                    if (item.object.get("url")) |uv| {
                        if (uv == .string) try list.append(allocator, .{ .url = try allocator.dupe(u8, uv.string) });
                    }
                }
            }
        }
    }
    if (output.get("choices")) |cv| {
        if (cv == .array) {
            for (cv.array.items) |choice| {
                if (choice != .object) continue;
                const msg = choice.object.get("message") orelse continue;
                if (msg != .object) continue;
                const content = msg.object.get("content") orelse continue;
                if (content != .array) continue;
                for (content.array.items) |part| {
                    if (part != .object) continue;
                    if (part.object.get("image")) |iv| {
                        if (iv == .string) try list.append(allocator, .{ .url = try allocator.dupe(u8, iv.string) });
                    }
                }
            }
        }
    }
    if (list.items.len == 0) return null;
    return try list.toOwnedSlice(allocator);
}

fn taskId(output: std.json.ObjectMap) ?[]const u8 {
    const v = output.get("task_id") orelse return null;
    return if (v == .string) v.string else null;
}

fn failText(allocator: std.mem.Allocator, status: u16, root: std.json.ObjectMap, task_id: ?[]const u8) ![]u8 {
    const output = if (root.get("output")) |ov| (if (ov == .object) ov.object else null) else null;
    const msg = if (output) |o| stringField(o, "message") else null;
    const top = stringField(root, "message");
    const text = msg orelse top orelse "request failed";
    const id = task_id orelse if (output) |o| taskId(o) else null;
    const req = stringField(root, "request_id");
    if (id) |task| {
        if (req) |rid| {
            return std.fmt.allocPrint(allocator, "task {s} failed: {s} (request_id={s})", .{ task, text, rid });
        }
        return std.fmt.allocPrint(allocator, "task {s} failed: {s}", .{ task, text });
    }
    if (req) |rid| return std.fmt.allocPrint(allocator, "HTTP {d}: {s} (request_id={s})", .{ status, text, rid });
    return std.fmt.allocPrint(allocator, "HTTP {d}: {s}", .{ status, text });
}

fn stringField(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

pub fn starSize(allocator: std.mem.Allocator, size: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, size, 'x') == null and std.mem.indexOfScalar(u8, size, 'X') == null) {
        return size;
    }
    const out = try allocator.alloc(u8, size.len);
    for (size, 0..) |c, i| out[i] = if (c == 'x' or c == 'X') '*' else c;
    return out;
}

pub fn wanTier(s: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(s, "720p")) return "720P";
    if (std.ascii.eqlIgnoreCase(s, "1080p")) return "1080P";
    return s;
}

test "dashscope create task id and succeeded video url" {
    var test_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer test_arena.deinit();
    const a = test_arena.allocator();
    const created = try parseCreate(a, 200,
        \\{"output":{"task_id":"t1","task_status":"PENDING"},"request_id":"r1"}
    );
    try std.testing.expectEqualStrings("t1", created.pending);

    const done = try parsePoll(a, "https://ws.cn-beijing.maas.aliyuncs.com/api/v1/services/aigc/video-generation/video-synthesis", "t1", 200,
        \\{"output":{"task_id":"t1","task_status":"SUCCEEDED","video_url":"https://cdn.example/v.mp4"},"request_id":"r2"}
    );
    try std.testing.expectEqualStrings("https://cdn.example/v.mp4", done.done[0].url);

    const failed = try parsePoll(a, "https://ws.example/api/v1/tasks/t1", "t1", 200,
        \\{"output":{"task_id":"t1","task_status":"FAILED","code":"InvalidParameter","message":"bad size"},"request_id":"r3"}
    );
    try std.testing.expect(std.mem.indexOf(u8, failed.api_error, "bad size") != null);
    try std.testing.expect(std.mem.indexOf(u8, failed.api_error, "r3") != null);
}

test "dashscope inline image choices are a finished create" {
    var test_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer test_arena.deinit();
    const a = test_arena.allocator();
    const done = try parseCreate(a, 200,
        \\{"output":{"choices":[{"message":{"content":[{"image":"https://cdn.example/a.png","type":"image"}]}}]},"request_id":"r"}
    );
    try std.testing.expectEqualStrings("https://cdn.example/a.png", done.done[0].url);
}
