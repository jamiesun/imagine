//! HMAC-SHA256 JWTs for providers that sign an access key (Kling).
//! No Google service-account RS256 here: the standard library can verify RSA
//! signatures but does not sign them, and imagine does not shell out to gcloud.

const std = @import("std");

fn b64(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const enc = std.base64.url_safe_no_pad.Encoder;
    const out = try allocator.alloc(u8, enc.calcSize(bytes.len));
    return enc.encode(out, bytes);
}

/// `Authorization` bearer value. `now_secs` is unix time. Lifetime is 30 minutes,
/// with `nbf` five seconds in the past, matching Kling's published JWT shape:
/// header `{"alg":"HS256","typ":"JWT"}`, payload `iss` / `exp` / `nbf`.
pub fn hs256(allocator: std.mem.Allocator, access_key: []const u8, secret: []const u8, now_secs: i64) ![]u8 {
    if (std.mem.indexOfScalar(u8, access_key, '"') != null or
        std.mem.indexOfScalar(u8, access_key, '\\') != null)
    {
        return error.InvalidAccessKey;
    }
    const header_json = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}";
    const payload_json = try std.fmt.allocPrint(allocator, "{{\"iss\":\"{s}\",\"exp\":{d},\"nbf\":{d}}}", .{
        access_key,
        now_secs + 1800,
        now_secs - 5,
    });
    const header = try b64(allocator, header_json);
    const payload = try b64(allocator, payload_json);
    const signing = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ header, payload });

    var mac: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, signing, secret);
    const sig = try b64(allocator, &mac);
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ signing, sig });
}

fn b64Decode(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const dec = std.base64.url_safe_no_pad.Decoder;
    const len = try dec.calcSizeForSlice(text);
    const out = try allocator.alloc(u8, len);
    try dec.decode(out, text);
    return out;
}

/// True when `token` was signed with `secret`. Used by tests; the CLI does not
/// need to verify tokens it just minted.
pub fn verifyHs256(allocator: std.mem.Allocator, token: []const u8, secret: []const u8) !bool {
    const dot = std.mem.lastIndexOfScalar(u8, token, '.') orelse return false;
    const signing = token[0..dot];
    const sig_text = token[dot + 1 ..];
    const sig = b64Decode(allocator, sig_text) catch return false;
    if (sig.len != std.crypto.auth.hmac.sha2.HmacSha256.mac_length) return false;
    var mac: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, signing, secret);
    return std.crypto.timing_safe.eql([std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8, mac, sig[0..std.crypto.auth.hmac.sha2.HmacSha256.mac_length].*);
}

test "kling-shaped jwt round trips" {
    var test_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer test_arena.deinit();
    const a = test_arena.allocator();
    const token = try hs256(a, "access-key", "secret-key", 1_700_000_000);
    defer a.free(token);
    try std.testing.expect(try verifyHs256(a, token, "secret-key"));
    try std.testing.expect(!try verifyHs256(a, token, "other"));
    // Three segments, URL-safe, no padding characters.
    var parts: usize = 0;
    var it = std.mem.splitScalar(u8, token, '.');
    while (it.next()) |_| parts += 1;
    try std.testing.expectEqual(@as(usize, 3), parts);
    try std.testing.expect(std.mem.indexOfScalar(u8, token, '=') == null);
}
