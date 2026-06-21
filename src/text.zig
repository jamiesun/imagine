//! Text layer SVG generation.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Align = enum {
    left,
    center,
    right,

    pub fn fromString(s: []const u8) ?Align {
        if (std.ascii.eqlIgnoreCase(s, "left")) return .left;
        if (std.ascii.eqlIgnoreCase(s, "center")) return .center;
        if (std.ascii.eqlIgnoreCase(s, "right")) return .right;
        return null;
    }
};

pub const Options = struct {
    text: []const u8,
    width: u32,
    height: ?u32 = null,
    font: []const u8 = "Arial",
    size: u32 = 64,
    color: []const u8 = "#000000",
    stroke: ?[]const u8 = null,
    stroke_width: f32 = 0,
    text_align: Align = .left,
    line_height: f32 = 1.2,
    padding: u32 = 0,
};

pub const Error = error{
    EmptyText,
    InvalidDimensions,
    InvalidLineHeight,
    InvalidStroke,
} || Allocator.Error;

pub fn renderSvgAlloc(arena: Allocator, opts: Options) Error!struct { svg: []const u8, width: u32, height: u32 } {
    if (opts.text.len == 0) return Error.EmptyText;
    if (opts.width == 0 or opts.size == 0) return Error.InvalidDimensions;
    if (!std.math.isFinite(opts.line_height) or opts.line_height <= 0) return Error.InvalidLineHeight;
    if (!std.math.isFinite(opts.stroke_width) or opts.stroke_width < 0) return Error.InvalidStroke;

    const lines = try splitLines(arena, opts.text);
    if (lines.len == 0) return Error.EmptyText;

    const line_step = opts.line_height * @as(f32, @floatFromInt(opts.size));
    const content_h = @as(f32, @floatFromInt(opts.size)) + @as(f32, @floatFromInt(lines.len - 1)) * line_step;
    const auto_h = opts.padding * 2 + ceilU32(content_h + opts.stroke_width * 2);
    const height = opts.height orelse auto_h;
    if (height == 0) return Error.InvalidDimensions;

    const x = switch (opts.text_align) {
        .left => @as(f32, @floatFromInt(opts.padding)),
        .center => @as(f32, @floatFromInt(opts.width)) / 2.0,
        .right => @as(f32, @floatFromInt(opts.width -| opts.padding)),
    };
    const anchor = switch (opts.text_align) {
        .left => "start",
        .center => "middle",
        .right => "end",
    };
    const y = @as(f32, @floatFromInt(opts.padding)) + opts.stroke_width;

    var out = std.ArrayList(u8).empty;
    try appendFmt(&out, arena,
        \\<svg xmlns="http://www.w3.org/2000/svg" width="{d}" height="{d}" viewBox="0 0 {d} {d}">
        \\<text x="{d:.3}" y="{d:.3}" text-anchor="{s}" dominant-baseline="text-before-edge" font-family="{s}" font-size="{d}" fill="{s}"
    , .{
        opts.width,
        height,
        opts.width,
        height,
        x,
        y,
        anchor,
        try escapeXml(arena, opts.font),
        opts.size,
        try escapeXml(arena, opts.color),
    });
    if (opts.stroke) |stroke| {
        if (opts.stroke_width > 0) {
            try appendFmt(&out, arena, " stroke=\"{s}\" stroke-width=\"{d:.3}\" paint-order=\"stroke fill\"", .{ try escapeXml(arena, stroke), opts.stroke_width });
        }
    }
    try out.appendSlice(arena, ">\n");
    for (lines, 0..) |line, i| {
        const dy: f32 = if (i == 0) 0 else line_step;
        try appendFmt(&out, arena, "<tspan x=\"{d:.3}\" dy=\"{d:.3}\">{s}</tspan>\n", .{ x, dy, try escapeXml(arena, line) });
    }
    try out.appendSlice(arena, "</text>\n</svg>\n");

    return .{ .svg = try out.toOwnedSlice(arena), .width = opts.width, .height = height };
}

fn splitLines(arena: Allocator, raw: []const u8) ![]const []const u8 {
    const decoded = try decodeEscapedNewlines(arena, raw);
    var lines = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, decoded, '\n');
    while (it.next()) |line| {
        try lines.append(arena, line);
    }
    return lines.toOwnedSlice(arena);
}

fn decodeEscapedNewlines(arena: Allocator, raw: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '\\' and i + 1 < raw.len and raw[i + 1] == 'n') {
            try out.append(arena, '\n');
            i += 1;
        } else {
            try out.append(arena, raw[i]);
        }
    }
    return out.toOwnedSlice(arena);
}

fn escapeXml(arena: Allocator, raw: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    for (raw) |c| {
        switch (c) {
            '&' => try out.appendSlice(arena, "&amp;"),
            '<' => try out.appendSlice(arena, "&lt;"),
            '>' => try out.appendSlice(arena, "&gt;"),
            '"' => try out.appendSlice(arena, "&quot;"),
            '\'' => try out.appendSlice(arena, "&apos;"),
            else => try out.append(arena, c),
        }
    }
    return out.toOwnedSlice(arena);
}

fn appendFmt(list: *std.ArrayList(u8), arena: Allocator, comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(arena, fmt, args);
    try list.appendSlice(arena, s);
}

fn ceilU32(v: f32) u32 {
    return @intFromFloat(@ceil(v));
}

test "text svg escapes content and decodes newlines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rendered = try renderSvgAlloc(arena.allocator(), .{
        .text = "A&B\\n<C>",
        .width = 300,
        .size = 20,
        .text_align = .center,
    });
    try std.testing.expect(std.mem.indexOf(u8, rendered.svg, "A&amp;B") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.svg, "&lt;C&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.svg, "text-anchor=\"middle\"") != null);
}
