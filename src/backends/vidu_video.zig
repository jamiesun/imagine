//! Vidu video tasks.
//!
//! Auth is `Authorization: Token <key>`, not Bearer. One configured base URL
//! (the `/ent/v2` root, or a concrete create URL) selects the endpoint:
//!   text2video, img2video, start-end2video, reference2video.
//! Poll `GET {ent/v2}/tasks/{id}/creations`. `state: success` carries
//! `creations[].url` (24h). `failed` is HTTP 200. Verified against the Vidu Q2
//! reference-to-video reference on 2026-10-20. Subject ids are not `--image`.

const std = @import("std");
const types = @import("../types.zig");
const images = @import("../images.zig");
const wire = @import("../wire.zig");

pub fn targetUrl(allocator: std.mem.Allocator, base_url: []const u8, req: types.GenRequest) ![]const u8 {
    const base = std.mem.trimEnd(u8, base_url, "/");
    if (std.mem.endsWith(u8, base, "text2video") or std.mem.endsWith(u8, base, "img2video") or
        std.mem.endsWith(u8, base, "start-end2video") or std.mem.endsWith(u8, base, "reference2video"))
    {
        return base;
    }
    const root = entRoot(base);
    const name = pathName(req);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, name });
}

fn pathName(req: types.GenRequest) []const u8 {
    var refs: usize = 0;
    var framed = false;
    for (req.images) |img| switch (img.role) {
        .reference => refs += 1,
        else => framed = true,
    };
    if (refs > 0) return "reference2video";
    if (images.last(req) != null) return "start-end2video";
    if (framed) return "img2video";
    return "text2video";
}

fn entRoot(base: []const u8) []const u8 {
    if (std.mem.lastIndexOf(u8, base, "/ent/v2")) |at| return base[0 .. at + "/ent/v2".len];
    return base;
}

pub fn buildBody(allocator: std.mem.Allocator, req: types.GenRequest) ![]u8 {
    var urls = std.ArrayList([]const u8).empty;
    if (pathName(req)[0] == 'r') {
        for (req.images) |img| {
            if (img.role == .reference) try urls.append(allocator, try images.transmitUrl(allocator, img));
        }
    } else {
        if (images.first(req)) |img| try urls.append(allocator, try images.transmitUrl(allocator, img));
        if (images.last(req)) |img| try urls.append(allocator, try images.transmitUrl(allocator, img));
    }
    const Body = struct {
        model: []const u8,
        prompt: []const u8,
        images: ?[]const []const u8 = null,
        duration: ?u32 = null,
        seed: ?i64 = null,
        resolution: ?[]const u8 = null,
        aspect_ratio: ?[]const u8 = null,
    };
    const ratio = req.ratio orelse if (req.size) |s| (if (std.mem.indexOfScalar(u8, s, ':') != null) s else null) else null;
    const body = Body{
        .model = req.api_model,
        .prompt = req.prompt,
        .images = if (urls.items.len > 0) try urls.toOwnedSlice(allocator) else null,
        .duration = req.duration,
        .seed = req.seed,
        .resolution = if (req.resolution) |r| lowerP(allocator, r) catch r else null,
        .aspect_ratio = ratio,
    };
    return std.json.Stringify.valueAlloc(allocator, body, .{ .emit_null_optional_fields = false });
}

fn lowerP(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    const out = try allocator.alloc(u8, s.len);
    for (s, 0..) |c, i| out[i] = if (c == 'P') 'p' else c;
    return out;
}

pub fn parseCreate(allocator: std.mem.Allocator, status: u16, body: []const u8) !wire.TaskOutcome {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return .{ .api_error = try wire.rawError(allocator, status, body) };
    };
    defer parsed.deinit();
    const root = wire.rootObject(parsed.value) orelse
        return .{ .api_error = try std.fmt.allocPrint(allocator, "HTTP {d}: unexpected response", .{status}) };
    if (root.get("task_id")) |id| {
        if (id == .string) return .{ .pending = try allocator.dupe(u8, id.string) };
    }
    return .{ .api_error = try describe(allocator, status, root, null) };
}

pub fn pollUrl(allocator: std.mem.Allocator, base_url: []const u8, task_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/tasks/{s}/creations", .{ entRoot(std.mem.trimEnd(u8, base_url, "/")), task_id });
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
    const state_v = root.get("state") orelse
        return .{ .api_error = try describe(allocator, status, root, task_id) };
    if (state_v != .string) return .{ .api_error = try describe(allocator, status, root, task_id) };
    const state = state_v.string;
    if (std.mem.eql(u8, state, "success")) {
        const creations = root.get("creations") orelse
            return .{ .api_error = try std.fmt.allocPrint(allocator, "task {s} succeeded but returned no creations", .{task_id}) };
        if (creations != .array or creations.array.items.len == 0) {
            return .{ .api_error = try std.fmt.allocPrint(allocator, "task {s} succeeded but returned no creations", .{task_id}) };
        }
        const first = creations.array.items[0];
        if (first != .object) return .{ .api_error = try std.fmt.allocPrint(allocator, "task {s} succeeded but returned no creations", .{task_id}) };
        const url_v = first.object.get("url") orelse
            return .{ .api_error = try std.fmt.allocPrint(allocator, "task {s} succeeded but returned no url", .{task_id}) };
        if (url_v != .string) return .{ .api_error = try std.fmt.allocPrint(allocator, "task {s} succeeded but returned no url", .{task_id}) };
        const list = try allocator.alloc(types.Payload, 1);
        list[0] = .{ .url = try allocator.dupe(u8, url_v.string) };
        return .{ .done = list };
    }
    if (std.mem.eql(u8, state, "failed")) {
        return .{ .api_error = try describe(allocator, status, root, task_id) };
    }
    return .pending;
}

fn describe(allocator: std.mem.Allocator, status: u16, root: std.json.ObjectMap, task_id: ?[]const u8) ![]u8 {
    const err_code = if (root.get("err_code")) |v| (if (v == .string and v.string.len > 0) v.string else null) else null;
    const msg = err_code orelse if (root.get("message")) |v| (if (v == .string) v.string else null) else null;
    const text = msg orelse "request failed";
    if (task_id) |id| return std.fmt.allocPrint(allocator, "task {s} failed: {s}", .{ id, text });
    return std.fmt.allocPrint(allocator, "HTTP {d}: {s}", .{ status, text });
}

test "vidu routes reference images and frames to different paths" {
    var test_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer test_arena.deinit();
    const a = test_arena.allocator();
    const refs = types.GenRequest{
        .prompt = "two people",
        .api_model = "viduq2",
        .images = &.{
            .{ .source = "https://example.com/a.png", .role = .reference },
            .{ .source = "https://example.com/b.png", .role = .reference },
        },
    };
    const url = try targetUrl(a, "https://api.vidu.com/ent/v2", refs);
    try std.testing.expectEqualStrings("https://api.vidu.com/ent/v2/reference2video", url);
    const frames = types.GenRequest{
        .prompt = "close",
        .api_model = "viduq2",
        .images = &.{
            .{ .source = "https://example.com/a.png", .role = .first_frame },
            .{ .source = "https://example.com/b.png", .role = .last_frame },
        },
    };
    const url2 = try targetUrl(a, "https://api.vidu.com/ent/v2/", frames);
    try std.testing.expectEqualStrings("https://api.vidu.com/ent/v2/start-end2video", url2);
}

test "vidu success and failed states" {
    var test_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer test_arena.deinit();
    const a = test_arena.allocator();
    const created = try parseCreate(a, 200, "{\"task_id\":\"v1\",\"state\":\"created\"}");
    try std.testing.expectEqualStrings("v1", created.pending);
    const done = try parsePoll(a, "https://api.vidu.com/ent/v2/reference2video", "v1", 200,
        \\{"id":"v1","state":"success","creations":[{"id":"c","url":"https://cdn.example/v.mp4"}]}
    );
    try std.testing.expectEqualStrings("https://cdn.example/v.mp4", done.done[0].url);
    const failed = try parsePoll(a, "https://api.vidu.com/ent/v2", "v1", 200, "{\"state\":\"failed\",\"err_code\":\"CreditNotEnough\"}");
    try std.testing.expect(std.mem.indexOf(u8, failed.api_error, "CreditNotEnough") != null);
}
