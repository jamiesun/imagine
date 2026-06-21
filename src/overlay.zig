//! PNG and SVG raster composition support.
//!
//! PNG decoding/encoding uses stb via a tiny C shim. SVG rendering uses the
//! resvg C API when the binary is built with `-Dsvg-overlay=true`.

const std = @import("std");
const build_options = @import("build_options");

const Allocator = std.mem.Allocator;

const c = if (build_options.svg_overlay_enabled)
    @cImport({
        @cInclude("stb_shim.h");
        @cInclude("resvg.h");
    })
else
    @cImport({
        @cInclude("stb_shim.h");
    });

pub const BlendMode = enum {
    normal,
    multiply,
    screen,
    overlay,
    darken,
    lighten,

    pub fn fromString(s: []const u8) ?BlendMode {
        if (std.ascii.eqlIgnoreCase(s, "normal")) return .normal;
        if (std.ascii.eqlIgnoreCase(s, "multiply")) return .multiply;
        if (std.ascii.eqlIgnoreCase(s, "screen")) return .screen;
        if (std.ascii.eqlIgnoreCase(s, "overlay")) return .overlay;
        if (std.ascii.eqlIgnoreCase(s, "darken")) return .darken;
        if (std.ascii.eqlIgnoreCase(s, "lighten")) return .lighten;
        return null;
    }

    pub fn toString(self: BlendMode) []const u8 {
        return @tagName(self);
    }
};

pub const Layer = struct {
    path: []const u8,
    x: i32 = 0,
    y: i32 = 0,
    opacity: f32 = 1.0,
    blend: BlendMode = .normal,
};

pub const SvgRenderOptions = struct {
    input_path: []const u8,
    output_path: []const u8,
    width: ?u32 = null,
    height: ?u32 = null,
};

pub const SvgDataRenderOptions = struct {
    svg: []const u8,
    output_path: []const u8,
    width: ?u32 = null,
    height: ?u32 = null,
    resources_dir: ?[]const u8 = null,
};

pub const PngComposeOptions = struct {
    base_path: []const u8,
    output_path: []const u8,
    layers: []const Layer,
};

pub const SvgComposeOptions = struct {
    base_path: []const u8,
    svg_path: []const u8,
    output_path: []const u8,
    x: i32 = 0,
    y: i32 = 0,
    width: ?u32 = null,
    height: ?u32 = null,
    opacity: f32 = 1.0,
    blend: BlendMode = .normal,
};

pub const Error = error{
    SvgOverlayDisabled,
    InvalidBasePng,
    InvalidLayerPng,
    InvalidDimensions,
    InvalidSvg,
    InvalidOpacity,
    WriteFailed,
} || Allocator.Error;

pub fn renderSvgToPng(arena: Allocator, opts: SvgRenderOptions) Error!void {
    const image = try renderSvg(arena, opts.input_path, opts.width, opts.height);
    defer arena.free(image.pixels);
    try writePng(arena, opts.output_path, image);
}

pub fn renderSvgDataToPng(arena: Allocator, opts: SvgDataRenderOptions) Error!void {
    const image = try renderSvgData(arena, opts.svg, opts.resources_dir, opts.width, opts.height);
    defer arena.free(image.pixels);
    try writePng(arena, opts.output_path, image);
}

pub fn composePng(arena: Allocator, opts: PngComposeOptions) Error!void {
    var base = try loadPng(opts.base_path, Error.InvalidBasePng);
    defer base.deinit();

    for (opts.layers) |layer| {
        if (layer.opacity < 0 or layer.opacity > 1 or !std.math.isFinite(layer.opacity)) return Error.InvalidOpacity;
        var image = try loadPng(layer.path, Error.InvalidLayerPng);
        defer image.deinit();
        blend(&base, .{ .width = image.width, .height = image.height, .pixels = image.pixels }, layer);
    }

    try writePng(arena, opts.output_path, .{ .width = base.width, .height = base.height, .pixels = base.pixels });
}

/// Convenience command: render one SVG in memory, then compose it over one PNG.
pub fn compose(arena: Allocator, opts: SvgComposeOptions) Error!void {
    var base = try loadPng(opts.base_path, Error.InvalidBasePng);
    defer base.deinit();

    const svg = try renderSvg(arena, opts.svg_path, opts.width, opts.height);
    defer arena.free(svg.pixels);

    blend(&base, svg, .{
        .path = opts.svg_path,
        .x = opts.x,
        .y = opts.y,
        .opacity = opts.opacity,
        .blend = opts.blend,
    });

    try writePng(arena, opts.output_path, .{ .width = base.width, .height = base.height, .pixels = base.pixels });
}

const StbImage = struct {
    width: u32,
    height: u32,
    pixels: []u8,

    fn deinit(self: *StbImage) void {
        c.imagine_stbi_image_free(self.pixels.ptr);
    }
};

const ImageView = struct {
    width: u32,
    height: u32,
    pixels: []u8,
};

fn loadPng(path: []const u8, err: Error) Error!StbImage {
    var w: c_int = 0;
    var h: c_int = 0;
    var channels: c_int = 0;
    const path_z = try std.heap.c_allocator.dupeZ(u8, path);
    defer std.heap.c_allocator.free(path_z);

    const ptr = c.imagine_stbi_load(path_z.ptr, &w, &h, &channels, 4) orelse return err;
    if (w <= 0 or h <= 0) {
        c.imagine_stbi_image_free(ptr);
        return err;
    }
    const len: usize = @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4;
    return .{
        .width = @intCast(w),
        .height = @intCast(h),
        .pixels = ptr[0..len],
    };
}

fn writePng(arena: Allocator, path: []const u8, image: ImageView) Error!void {
    const out_z = try arena.dupeZ(u8, path);
    const ok = c.imagine_stbi_write_png(out_z.ptr, @intCast(image.width), @intCast(image.height), 4, image.pixels.ptr, @intCast(image.width * 4));
    if (ok == 0) return Error.WriteFailed;
}

fn renderSvg(arena: Allocator, path: []const u8, requested_w: ?u32, requested_h: ?u32) Error!ImageView {
    if (!build_options.svg_overlay_enabled) return Error.SvgOverlayDisabled;

    const opt = c.resvg_options_create() orelse return Error.InvalidSvg;
    defer c.resvg_options_destroy(opt);
    c.resvg_options_load_system_fonts(opt);

    if (std.fs.path.dirname(path)) |dir| {
        const dir_z = try arena.dupeZ(u8, dir);
        c.resvg_options_set_resources_dir(opt, dir_z.ptr);
    }

    const path_z = try arena.dupeZ(u8, path);
    var tree: ?*c.resvg_render_tree = null;
    if (c.resvg_parse_tree_from_file(path_z.ptr, opt, &tree) != c.RESVG_OK) return Error.InvalidSvg;
    defer c.resvg_tree_destroy(tree.?);

    return renderTree(arena, tree.?, requested_w, requested_h);
}

fn renderSvgData(arena: Allocator, svg: []const u8, resources_dir: ?[]const u8, requested_w: ?u32, requested_h: ?u32) Error!ImageView {
    if (!build_options.svg_overlay_enabled) return Error.SvgOverlayDisabled;

    const opt = c.resvg_options_create() orelse return Error.InvalidSvg;
    defer c.resvg_options_destroy(opt);
    c.resvg_options_load_system_fonts(opt);

    if (resources_dir) |dir| {
        const dir_z = try arena.dupeZ(u8, dir);
        c.resvg_options_set_resources_dir(opt, dir_z.ptr);
    }

    var tree: ?*c.resvg_render_tree = null;
    if (c.resvg_parse_tree_from_data(svg.ptr, svg.len, opt, &tree) != c.RESVG_OK) return Error.InvalidSvg;
    defer c.resvg_tree_destroy(tree.?);

    return renderTree(arena, tree.?, requested_w, requested_h);
}

fn renderTree(arena: Allocator, tree: *c.resvg_render_tree, requested_w: ?u32, requested_h: ?u32) Error!ImageView {
    const intrinsic = c.resvg_get_image_size(tree);
    if (intrinsic.width <= 0 or intrinsic.height <= 0) return Error.InvalidDimensions;

    const dims = resolveDimensions(intrinsic.width, intrinsic.height, requested_w, requested_h) orelse return Error.InvalidDimensions;
    const pixel_len = @as(usize, dims.width) * @as(usize, dims.height) * 4;
    const pixels = try arena.alloc(u8, pixel_len);
    @memset(pixels, 0);

    var transform = c.resvg_transform_identity();
    transform.a = @as(f32, @floatFromInt(dims.width)) / intrinsic.width;
    transform.d = @as(f32, @floatFromInt(dims.height)) / intrinsic.height;
    c.resvg_render(tree, transform, dims.width, dims.height, @ptrCast(pixels.ptr));

    premulToStraight(pixels);
    return .{ .width = dims.width, .height = dims.height, .pixels = pixels };
}

fn resolveDimensions(intrinsic_w: f32, intrinsic_h: f32, requested_w: ?u32, requested_h: ?u32) ?struct { width: u32, height: u32 } {
    const w = requested_w orelse 0;
    const h = requested_h orelse 0;
    if (w > 0 and h > 0) return .{ .width = w, .height = h };
    if (w > 0) {
        const computed = roundPositive(@as(f32, @floatFromInt(w)) * intrinsic_h / intrinsic_w) orelse return null;
        return .{ .width = w, .height = computed };
    }
    if (h > 0) {
        const computed = roundPositive(@as(f32, @floatFromInt(h)) * intrinsic_w / intrinsic_h) orelse return null;
        return .{ .width = computed, .height = h };
    }
    return .{
        .width = roundPositive(intrinsic_w) orelse return null,
        .height = roundPositive(intrinsic_h) orelse return null,
    };
}

fn roundPositive(v: f32) ?u32 {
    if (!std.math.isFinite(v) or v <= 0) return null;
    const rounded = @ceil(v);
    if (rounded > @as(f32, @floatFromInt(std.math.maxInt(u32)))) return null;
    return @intFromFloat(rounded);
}

fn premulToStraight(pixels: []u8) void {
    var i: usize = 0;
    while (i + 3 < pixels.len) : (i += 4) {
        const a: u32 = pixels[i + 3];
        if (a == 0) {
            pixels[i] = 0;
            pixels[i + 1] = 0;
            pixels[i + 2] = 0;
        } else if (a < 255) {
            pixels[i] = unpremul(pixels[i], a);
            pixels[i + 1] = unpremul(pixels[i + 1], a);
            pixels[i + 2] = unpremul(pixels[i + 2], a);
        }
    }
}

fn blend(base: *StbImage, layer_image: ImageView, layer: Layer) void {
    for (0..layer_image.height) |sy| {
        const dy_signed = @as(i64, layer.y) + @as(i64, @intCast(sy));
        if (dy_signed < 0 or dy_signed >= base.height) continue;
        const dy: usize = @intCast(dy_signed);

        for (0..layer_image.width) |sx| {
            const dx_signed = @as(i64, layer.x) + @as(i64, @intCast(sx));
            if (dx_signed < 0 or dx_signed >= base.width) continue;
            const dx: usize = @intCast(dx_signed);

            const si = (@as(usize, sy) * layer_image.width + @as(usize, sx)) * 4;
            const di = (dy * base.width + dx) * 4;
            blendPixel(base.pixels[di .. di + 4], layer_image.pixels[si .. si + 4], layer.opacity, layer.blend);
        }
    }
}

fn blendPixel(dst: []u8, src: []const u8, opacity: f32, mode: BlendMode) void {
    const effective_alpha_f = @round(@as(f32, @floatFromInt(src[3])) * opacity);
    const sa: u32 = @intFromFloat(@min(@as(f32, 255), @max(@as(f32, 0), effective_alpha_f)));
    if (sa == 0) return;

    const da: u32 = dst[3];
    const inv_sa = 255 - sa;
    const out_a = sa + div255(da * inv_sa);

    const br = blendChannel(src[0], dst[0], mode);
    const bg = blendChannel(src[1], dst[1], mode);
    const bb = blendChannel(src[2], dst[2], mode);

    const out_pr = br * sa + div255(@as(u32, dst[0]) * da) * inv_sa;
    const out_pg = bg * sa + div255(@as(u32, dst[1]) * da) * inv_sa;
    const out_pb = bb * sa + div255(@as(u32, dst[2]) * da) * inv_sa;

    dst[0] = unpremulDiv255(out_pr, out_a);
    dst[1] = unpremulDiv255(out_pg, out_a);
    dst[2] = unpremulDiv255(out_pb, out_a);
    dst[3] = @intCast(out_a);
}

fn blendChannel(src: u8, dst: u8, mode: BlendMode) u32 {
    const s: u32 = src;
    const d: u32 = dst;
    return switch (mode) {
        .normal => s,
        .multiply => div255(s * d),
        .screen => 255 - div255((255 - s) * (255 - d)),
        .overlay => if (d < 128) div255(2 * s * d) else 255 - div255(2 * (255 - s) * (255 - d)),
        .darken => @min(s, d),
        .lighten => @max(s, d),
    };
}

fn div255(v: u32) u32 {
    return (v + 127) / 255;
}

fn unpremul(v: u8, a: u32) u8 {
    return @intCast(@min(@as(u32, 255), (@as(u32, v) * 255 + a / 2) / a));
}

fn unpremulDiv255(v_scaled: u32, a: u32) u8 {
    if (a == 0) return 0;
    return @intCast(@min(@as(u32, 255), (v_scaled + a / 2) / a));
}

test "dimension inference preserves aspect ratio" {
    try std.testing.expectEqual(@as(u32, 200), resolveDimensions(100, 50, 200, null).?.width);
    try std.testing.expectEqual(@as(u32, 100), resolveDimensions(100, 50, 200, null).?.height);
    try std.testing.expectEqual(@as(u32, 200), resolveDimensions(100, 50, null, 100).?.width);
}

test "blend modes parse" {
    try std.testing.expectEqual(BlendMode.multiply, BlendMode.fromString("multiply").?);
    try std.testing.expectEqual(BlendMode.screen, BlendMode.fromString("SCREEN").?);
    try std.testing.expect(BlendMode.fromString("unknown") == null);
}

test "alpha blend handles transparent and opaque source pixels" {
    var dst = [_]u8{ 10, 20, 30, 255 };
    blendPixel(dst[0..], &[_]u8{ 0, 0, 0, 0 }, 1.0, .normal);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 10, 20, 30, 255 }, dst[0..]);

    blendPixel(dst[0..], &[_]u8{ 80, 90, 100, 255 }, 1.0, .normal);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 80, 90, 100, 255 }, dst[0..]);
}

test "multiply blend darkens opaque pixels" {
    var dst = [_]u8{ 100, 100, 100, 255 };
    blendPixel(dst[0..], &[_]u8{ 128, 128, 128, 255 }, 1.0, .multiply);
    try std.testing.expect(dst[0] < 100);
}
