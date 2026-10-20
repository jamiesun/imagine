//! Role-aware view of `GenRequest.images`.
//! Validation lives in `check.zig`. These helpers assume that already passed,
//! so a video backend can treat one `auto` image as the first frame.

const std = @import("std");
const types = @import("types.zig");
const util = @import("util.zig");

pub fn transmitUrl(allocator: std.mem.Allocator, img: types.InputImage) ![]const u8 {
    const bytes = img.bytes orelse return img.source;
    return util.dataUrlAlloc(allocator, bytes, img.mime);
}

pub fn first(req: types.GenRequest) ?types.InputImage {
    for (req.images) |img| if (img.role == .first_frame) return img;
    for (req.images) |img| if (img.role == .auto) return img;
    return null;
}

pub fn last(req: types.GenRequest) ?types.InputImage {
    for (req.images) |img| if (img.role == .last_frame) return img;
    return null;
}

pub fn references(allocator: std.mem.Allocator, req: types.GenRequest) ![]types.InputImage {
    var n: usize = 0;
    for (req.images) |img| {
        if (img.role == .reference) n += 1;
    }
    const out = try allocator.alloc(types.InputImage, n);
    var i: usize = 0;
    for (req.images) |img| {
        if (img.role == .reference) {
            out[i] = img;
            i += 1;
        }
    }
    return out;
}
