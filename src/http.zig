//! Thin, transport-only wrapper over `std.http.Client`.
//!
//! `std.http.Client.fetch` is documented threadsafe, so a single client is
//! shared across scheduler worker threads. Each call captures the response body
//! into an `Allocating` writer backed by the caller-supplied allocator (in
//! practice a per-task arena), which keeps allocations thread-local and cleanup
//! trivial. Nothing provider-specific lives here.

const std = @import("std");

pub const Header = std.http.Header;
pub const StdHeaders = std.http.Client.Request.Headers;

pub const Response = struct {
    status: u16,
    body: []u8,
};

pub const max_response_bytes: usize = 64 * 1024 * 1024;

/// Perform a POST with a raw body. `std_headers` overrides std.http's built-in
/// headers (User-Agent, Content-Type, Authorization, ...) so they are emitted
/// once; `extra` carries any non-standard headers (e.g. Azure's `api-key`).
/// `allocator` owns the returned `Response.body`.
pub fn post(
    client: *std.http.Client,
    allocator: std.mem.Allocator,
    url: []const u8,
    std_headers: StdHeaders,
    extra: []const Header,
    body: []const u8,
) !Response {
    return request(client, allocator, .POST, url, std_headers, extra, body);
}

/// POST and hand each received body slice to `on_chunk` before the response
/// is complete. The chunk buffer is 8 KiB and is reused; `on_chunk` must copy
/// anything it needs to keep. Returns the HTTP status.
pub fn postStream(
    client: *std.http.Client,
    url: []const u8,
    std_headers: StdHeaders,
    extra: []const Header,
    body: []const u8,
    ctx: *anyopaque,
    on_chunk: *const fn (*anyopaque, []const u8) anyerror!void,
) !u16 {
    const uri = try std.Uri.parse(url);
    var req = try client.request(.POST, uri, .{
        .headers = std_headers,
        .extra_headers = extra,
        .keep_alive = true,
        .redirect_behavior = .unhandled,
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = body.len };
    var body_writer = try req.sendBodyUnflushed(&.{});
    try body_writer.writer.writeAll(body);
    try body_writer.end();
    try req.connection.?.flush();

    var response = try req.receiveHead(&.{});
    const status: u16 = @intFromEnum(response.head.status);
    var transfer_buffer: [8192]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    var chunk: [8192]u8 = undefined;
    while (true) {
        const n = reader.readSliceShort(&chunk) catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
            else => |e| return e,
        };
        if (n == 0) break;
        try on_chunk(ctx, chunk[0..n]);
        if (n < chunk.len) break;
    }
    return status;
}

/// Perform a GET. `allocator` owns the returned `Response.body`.
pub fn get(
    client: *std.http.Client,
    allocator: std.mem.Allocator,
    url: []const u8,
    std_headers: StdHeaders,
    extra: []const Header,
) !Response {
    return request(client, allocator, .GET, url, std_headers, extra, null);
}

fn request(
    client: *std.http.Client,
    allocator: std.mem.Allocator,
    method: std.http.Method,
    url: []const u8,
    std_headers: StdHeaders,
    extra: []const Header,
    body: ?[]const u8,
) !Response {
    var sink: std.Io.Writer.Allocating = .init(allocator);
    errdefer sink.deinit();

    const res = try client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = body,
        .headers = std_headers,
        .extra_headers = extra,
        .response_writer = &sink.writer,
    });

    const owned = try sink.toOwnedSlice();
    return .{ .status = @intFromEnum(res.status), .body = owned };
}
