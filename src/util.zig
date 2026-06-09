//! Small, dependency-light helpers shared across modules: base64 decoding,
//! path/home expansion, filename helpers and credential redaction.

const std = @import("std");

/// Decode a standard base64 string into freshly allocated bytes.
pub fn base64DecodeAlloc(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    const dec = std.base64.standard.Decoder;
    const trimmed = std.mem.trim(u8, src, " \r\n\t");
    const len = try dec.calcSizeForSlice(trimmed);
    const out = try allocator.alloc(u8, len);
    errdefer allocator.free(out);
    try dec.decode(out, trimmed);
    return out;
}

/// Expand a leading `~` to the user's home directory. Returns a newly allocated
/// path. If `path` does not start with `~`, it is duplicated unchanged.
pub fn expandTilde(allocator: std.mem.Allocator, home: ?[]const u8, path: []const u8) ![]u8 {
    if (path.len == 0) return allocator.dupe(u8, path);
    if (path[0] != '~') return allocator.dupe(u8, path);
    const h = home orelse return allocator.dupe(u8, path);
    // "~" or "~/..."
    if (path.len == 1) return allocator.dupe(u8, h);
    if (path[1] == '/') {
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ h, path[1..] });
    }
    // "~user" form is not supported; return unchanged.
    return allocator.dupe(u8, path);
}

/// File extension (no dot) for an output format name.
pub fn extForFormat(format: ?[]const u8) []const u8 {
    const f = format orelse return "png";
    if (std.ascii.eqlIgnoreCase(f, "jpeg") or std.ascii.eqlIgnoreCase(f, "jpg")) return "jpg";
    if (std.ascii.eqlIgnoreCase(f, "webp")) return "webp";
    if (std.ascii.eqlIgnoreCase(f, "png")) return "png";
    return f;
}

/// A compact UTC timestamp suitable for filenames, e.g. `20260609-235901`.
pub fn timestampName(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const secs: u64 = @intCast(std.Io.Clock.real.now(io).toSeconds());
    const epoch = std.time.epoch.EpochSeconds{ .secs = secs };
    const day = epoch.getEpochDay();
    const year_day = day.calculateYearDay();
    const md = year_day.calculateMonthDay();
    const ds = epoch.getDaySeconds();
    return std.fmt.allocPrint(allocator, "{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}", .{
        year_day.year,
        md.month.numeric(),
        md.day_index + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    });
}

/// Insert `-N` before the extension of `path`. `a/b/img.png` + 2 -> `a/b/img-2.png`.
pub fn numberedPath(allocator: std.mem.Allocator, path: []const u8, n: usize) ![]u8 {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.');
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    // Only treat the dot as an extension separator if it is in the basename.
    if (dot) |d| {
        if (slash == null or d > slash.?) {
            return std.fmt.allocPrint(allocator, "{s}-{d}{s}", .{ path[0..d], n, path[d..] });
        }
    }
    return std.fmt.allocPrint(allocator, "{s}-{d}", .{ path, n });
}

/// Redact a credential for display: keep a short prefix/suffix, mask the rest.
pub fn redactKey(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    if (key.len == 0) return allocator.dupe(u8, "(empty)");
    if (key.len <= 8) return allocator.dupe(u8, "****");
    return std.fmt.allocPrint(allocator, "{s}…{s}", .{ key[0..4], key[key.len - 4 ..] });
}

/// Directory portion of a path, or null if there is none.
pub fn dirName(path: []const u8) ?[]const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return null;
    if (slash == 0) return path[0..1];
    return path[0..slash];
}

/// Ensure the parent directory of `path` exists, creating it (and any missing
/// ancestors) if needed. Tolerates the directory already existing — including
/// when it is a symlink to a directory, which `createDirPath` itself reports as
/// `error.NotDir` (e.g. macOS `/tmp` -> `private/tmp`). Checking `access` first
/// also follows symlinks, so an existing linked directory short-circuits before
/// we ever try to create it.
pub fn ensureParentDir(io: std.Io, cwd: std.Io.Dir, path: []const u8) !void {
    const dir = dirName(path) orelse return;
    if (cwd.access(io, dir, .{})) |_| {
        return;
    } else |_| {}
    cwd.createDirPath(io, dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
}

test "base64 decode" {
    const out = try base64DecodeAlloc(std.testing.allocator, "aGVsbG8=");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("hello", out);
}

test "expandTilde" {
    const a = std.testing.allocator;
    const p = try expandTilde(a, "/home/u", "~/.imagine/config.json");
    defer a.free(p);
    try std.testing.expectEqualStrings("/home/u/.imagine/config.json", p);
    const p2 = try expandTilde(a, "/home/u", "/abs/path");
    defer a.free(p2);
    try std.testing.expectEqualStrings("/abs/path", p2);
}

test "numberedPath" {
    const a = std.testing.allocator;
    const p = try numberedPath(a, "out/img.png", 3);
    defer a.free(p);
    try std.testing.expectEqualStrings("out/img-3.png", p);
    const p2 = try numberedPath(a, "noext", 1);
    defer a.free(p2);
    try std.testing.expectEqualStrings("noext-1", p2);
}

test "extForFormat" {
    try std.testing.expectEqualStrings("png", extForFormat(null));
    try std.testing.expectEqualStrings("jpg", extForFormat("jpeg"));
}
