//! Microsoft AI (MAI) image generation & editing backend on Azure AI Foundry.
//!
//! Models supported include `MAI-Image-2.6`, `MAI-Image-2.6-Flash`, `MAI-Image-2.5`, etc.
//!
//! Two wire forms:
//!   1. Text-to-Image (T2I) generations:
//!      POST {base_url}/mai/v1/images/generations
//!      Content-Type: application/json
//!      Body: { "model": "...", "prompt": "...", "width": 1024, "height": 1024, "n": 1 }
//!
//!   2. Image-to-Image (I2I) / Surgical Edits:
//!      POST {base_url}/mai/v1/images/edits
//!      Content-Type: multipart/form-data; boundary=...
//!      Fields:
//!        - `model`: model deployment name
//!        - `prompt`: prompt text
//!        - `width`, `height`: optional pixel dimensions
//!        - `image`: binary image data (repeated for each reference image, up to 5)
//!
//! Both endpoints return OpenAI-shaped `{ "data": [ { "b64_json": "..." } ] }` responses,
//! which the standard `backend.parseResponse` decodes.

const std = @import("std");
const types = @import("../types.zig");

pub const boundary = "---------------------------imagineBoundary7e31b8162f4";

pub fn isEdit(req: types.GenRequest) bool {
    return req.images.len > 0;
}

/// Resolve target endpoint URL based on whether reference images are present.
pub fn resolveUrl(allocator: std.mem.Allocator, base_url: []const u8, req: types.GenRequest) ![]const u8 {
    if (isEdit(req)) {
        if (std.mem.endsWith(u8, base_url, "/images/generations")) {
            const prefix = base_url[0 .. base_url.len - "/images/generations".len];
            return std.fmt.allocPrint(allocator, "{s}/images/edits", .{prefix});
        }
        if (std.mem.endsWith(u8, base_url, "/images/edits")) {
            return base_url;
        }
        if (std.mem.endsWith(u8, base_url, "/")) {
            return std.fmt.allocPrint(allocator, "{s}images/edits", .{base_url});
        }
        return std.fmt.allocPrint(allocator, "{s}/images/edits", .{base_url});
    } else {
        if (std.mem.endsWith(u8, base_url, "/images/edits")) {
            const prefix = base_url[0 .. base_url.len - "/images/edits".len];
            return std.fmt.allocPrint(allocator, "{s}/images/generations", .{prefix});
        }
        return base_url;
    }
}

/// Content-Type header override for edit requests.
pub fn contentType(allocator: std.mem.Allocator, req: types.GenRequest) !?[]const u8 {
    if (isEdit(req)) {
        return try std.fmt.allocPrint(allocator, "multipart/form-data; boundary={s}", .{boundary});
    }
    return null;
}

pub fn buildBody(allocator: std.mem.Allocator, req: types.GenRequest) ![]u8 {
    if (isEdit(req)) {
        if (req.images.len > 5) return error.TooManyReferenceImages;
        return buildMultipartBody(allocator, req, req.images);
    } else {
        return buildJsonBody(allocator, req);
    }
}

fn resolveWidthHeight(req: types.GenRequest) struct { w: ?u32, h: ?u32 } {
    var width = req.width;
    var height = req.height;
    if (width == null or height == null) {
        if (req.size) |s| {
            if (types.parseSize(s)) |wh| {
                if (width == null) width = wh.w;
                if (height == null) height = wh.h;
            }
        }
    }
    return .{ .w = width, .h = height };
}

fn buildJsonBody(allocator: std.mem.Allocator, req: types.GenRequest) ![]u8 {
    const wh = resolveWidthHeight(req);

    const Body = struct {
        model: []const u8,
        prompt: []const u8,
        width: ?u32 = null,
        height: ?u32 = null,
        n: u32 = 1,
    };

    const body = Body{
        .model = req.api_model,
        .prompt = req.prompt,
        .width = wh.w,
        .height = wh.h,
        .n = req.n,
    };

    return std.json.Stringify.valueAlloc(allocator, body, .{ .emit_null_optional_fields = false });
}

fn appendFmt(list: *std.ArrayList(u8), arena: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(arena, fmt, args);
    defer arena.free(s);
    try list.appendSlice(arena, s);
}

fn buildMultipartBody(allocator: std.mem.Allocator, req: types.GenRequest, images: []const types.InputImage) ![]u8 {
    var buf = std.ArrayList(u8).empty;

    try appendFmt(&buf, allocator, "--{s}\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n{s}\r\n", .{ boundary, req.api_model });
    try appendFmt(&buf, allocator, "--{s}\r\nContent-Disposition: form-data; name=\"prompt\"\r\n\r\n{s}\r\n", .{ boundary, req.prompt });

    const wh = resolveWidthHeight(req);
    if (wh.w) |w| {
        try appendFmt(&buf, allocator, "--{s}\r\nContent-Disposition: form-data; name=\"width\"\r\n\r\n{d}\r\n", .{ boundary, w });
    }
    if (wh.h) |h| {
        try appendFmt(&buf, allocator, "--{s}\r\nContent-Disposition: form-data; name=\"height\"\r\n\r\n{d}\r\n", .{ boundary, h });
    }

    var name_buf: [32]u8 = undefined;
    for (images, 0..) |img, idx| {
        const bytes = img.bytes orelse return error.InputImageNotFetched;
        const filename = std.fs.path.basename(img.source);
        const safe_filename = if (filename.len > 0 and !std.mem.startsWith(u8, filename, "http"))
            filename
        else
            std.fmt.bufPrint(&name_buf, "image_{d}.png", .{idx + 1}) catch "image.png";

        try appendFmt(&buf, allocator, "--{s}\r\nContent-Disposition: form-data; name=\"image\"; filename=\"{s}\"\r\nContent-Type: {s}\r\n\r\n", .{
            boundary,
            safe_filename,
            img.mime,
        });
        try buf.appendSlice(allocator, bytes);
        try buf.appendSlice(allocator, "\r\n");
    }

    try appendFmt(&buf, allocator, "--{s}--\r\n", .{boundary});
    return buf.toOwnedSlice(allocator);
}

/// Clean binary payload for `--dry-run` display.
pub fn cleanDryRunBody(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;

    const part_header_needle = "Content-Disposition: form-data; name=\"image\";";
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, body, pos, part_header_needle)) |header_idx| {
        try out.appendSlice(allocator, body[pos..header_idx]);

        const header_end_rel = std.mem.indexOf(u8, body[header_idx..], "\r\n\r\n") orelse break;
        const data_start = header_idx + header_end_rel + 4;
        try out.appendSlice(allocator, body[header_idx..data_start]);

        const next_boundary = std.mem.indexOfPos(u8, body, data_start, boundary) orelse break;
        const data_end = if (next_boundary >= 4 and std.mem.eql(u8, body[next_boundary - 4 .. next_boundary], "\r\n--"))
            next_boundary - 4
        else if (next_boundary >= 2 and std.mem.eql(u8, body[next_boundary - 2 .. next_boundary], "--"))
            next_boundary - 2
        else
            next_boundary;

        const byte_count = if (data_end >= data_start) data_end - data_start else 0;
        try appendFmt(&out, allocator, "<{d} bytes of binary image data elided>\r\n", .{byte_count});
        pos = data_end + 2;
    }

    try out.appendSlice(allocator, body[pos..]);
    return out.toOwnedSlice(allocator);
}

// ---- tests ----

test "mai_image text-to-image produces JSON with width/height" {
    const a = std.testing.allocator;
    const req = types.GenRequest{
        .prompt = "a majestic mountain",
        .api_model = "MAI-Image-2.6",
        .size = "1024x1024",
    };
    const body = try buildBody(a, req);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"MAI-Image-2.6\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"prompt\":\"a majestic mountain\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"width\":1024") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"height\":1024") != null);
}

test "mai_image edit produces multipart body with image parts" {
    const a = std.testing.allocator;
    const imgs = [_]types.InputImage{
        .{ .source = "photo1.png", .bytes = "BIN1", .mime = "image/png" },
        .{ .source = "photo2.jpg", .bytes = "BIN2", .mime = "image/jpeg" },
    };
    const req = types.GenRequest{
        .prompt = "fuse styles",
        .api_model = "MAI-Image-2.6",
        .size = "768x768",
        .images = &imgs,
    };
    const body = try buildBody(a, req);
    defer a.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, boundary) != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "name=\"model\"\r\n\r\nMAI-Image-2.6") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "name=\"prompt\"\r\n\r\nfuse styles") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "name=\"width\"\r\n\r\n768") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "filename=\"photo1.png\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Content-Type: image/png\r\n\r\nBIN1\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "filename=\"photo2.jpg\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Content-Type: image/jpeg\r\n\r\nBIN2\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, body, "--\r\n"));
}

test "mai_image rejects more than 5 reference images" {
    const a = std.testing.allocator;
    const imgs = [_]types.InputImage{
        .{ .source = "1.png", .bytes = "X", .mime = "image/png" },
        .{ .source = "2.png", .bytes = "X", .mime = "image/png" },
        .{ .source = "3.png", .bytes = "X", .mime = "image/png" },
        .{ .source = "4.png", .bytes = "X", .mime = "image/png" },
        .{ .source = "5.png", .bytes = "X", .mime = "image/png" },
        .{ .source = "6.png", .bytes = "X", .mime = "image/png" },
    };
    const req = types.GenRequest{
        .prompt = "too many",
        .api_model = "MAI-Image-2.6",
        .images = &imgs,
    };
    try std.testing.expectError(error.TooManyReferenceImages, buildBody(a, req));
}

test "mai_image resolveUrl switches between generations and edits" {
    const a = std.testing.allocator;
    const base = "https://jettai2.services.ai.azure.com/mai/v1/images/generations";

    const t2i_req = types.GenRequest{ .prompt = "x", .api_model = "m" };
    const t2i_url = try resolveUrl(a, base, t2i_req);
    try std.testing.expectEqualStrings("https://jettai2.services.ai.azure.com/mai/v1/images/generations", t2i_url);

    const edit_req = types.GenRequest{
        .prompt = "x",
        .api_model = "m",
        .images = &.{.{ .source = "a.png", .bytes = "X", .mime = "image/png" }},
    };
    const edit_url = try resolveUrl(a, base, edit_req);
    defer a.free(edit_url);
    try std.testing.expectEqualStrings("https://jettai2.services.ai.azure.com/mai/v1/images/edits", edit_url);
}

test "mai_image cleanDryRunBody elides binary bytes" {
    const a = std.testing.allocator;
    const imgs = [_]types.InputImage{
        .{ .source = "cat.png", .bytes = "SECRET-BINARY-BYTES-12345", .mime = "image/png" },
    };
    const req = types.GenRequest{
        .prompt = "edit cat",
        .api_model = "MAI-Image-2.6",
        .images = &imgs,
    };
    const body = try buildBody(a, req);
    defer a.free(body);

    const cleaned = try cleanDryRunBody(a, body);
    defer a.free(cleaned);

    try std.testing.expect(std.mem.indexOf(u8, cleaned, "SECRET-BINARY-BYTES-12345") == null);
    try std.testing.expect(std.mem.indexOf(u8, cleaned, "bytes of binary image data elided") != null);
}
