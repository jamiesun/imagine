//! Configuration loading for imagine.
//!
//! Config is JSON at `~/.imagine/config.json` (override with `$IMAGINE_CONFIG`
//! or `--config`). The file declares logical models, each mapping to a backend
//! and one-or-more endpoints (url + credential). Multiple endpoints on a model
//! are what allow the scheduler to fan a single model's work across keys.
//!
//! The loader is decoupled from the process environment via the small `Env`
//! interface so it can be unit-tested with a stub.

const std = @import("std");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const default_rel_path = ".imagine/config.json";
pub const env_config_path = "IMAGINE_CONFIG";

/// Minimal environment lookup so config parsing does not depend on a concrete
/// environment source (process env in production, a map in tests).
pub const Env = struct {
    context: *const anyopaque,
    func: *const fn (*const anyopaque, []const u8) ?[]const u8,

    pub fn get(self: Env, name: []const u8) ?[]const u8 {
        return self.func(self.context, name);
    }

    /// An Env that always returns null. Useful for tests and listing without
    /// resolving any credentials.
    pub fn empty() Env {
        const S = struct {
            fn f(_: *const anyopaque, _: []const u8) ?[]const u8 {
                return null;
            }
        };
        return .{ .context = undefined, .func = S.f };
    }
};

pub const Error = error{
    NotObject,
    MissingModels,
    EmptyModels,
    ModelNotObject,
    MissingBackend,
    UnknownBackend,
    MissingEndpoints,
    EmptyEndpoints,
    EndpointNotObject,
    MissingBaseUrl,
    UnknownAuth,
    BadFieldType,
} || Allocator.Error || std.json.ParseError(std.json.Scanner);

pub const Config = struct {
    gpa: Allocator,
    arena: *std.heap.ArenaAllocator,
    output_dir: []const u8,
    /// 0 means "auto" (derive from endpoint count).
    concurrency: u32,
    models: []types.ModelConfig,
    /// Path the config was loaded from, if any (informational).
    source_path: ?[]const u8 = null,

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
        self.gpa.destroy(self.arena);
    }

    pub fn findModel(self: *const Config, name: []const u8) ?*const types.ModelConfig {
        for (self.models) |*m| {
            if (std.mem.eql(u8, m.name, name)) return m;
        }
        return null;
    }
};

/// Resolve the config file path. Precedence: explicit > $IMAGINE_CONFIG >
/// $HOME/.imagine/config.json. Returned memory is owned by `arena`.
pub fn resolvePath(arena: Allocator, env: Env, explicit: ?[]const u8) ![]u8 {
    if (explicit) |p| return arena.dupe(u8, p);
    if (env.get(env_config_path)) |p| {
        if (p.len > 0) return arena.dupe(u8, p);
    }
    const home = env.get("HOME") orelse env.get("USERPROFILE") orelse ".";
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ home, default_rel_path });
}

fn getStr(obj: *const std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn getU32(obj: *const std.json.ObjectMap, key: []const u8) Error!?u32 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| if (i < 0) Error.BadFieldType else @intCast(i),
        .null => null,
        else => Error.BadFieldType,
    };
}

fn parseDefaults(arena: Allocator, obj: *const std.json.ObjectMap) !types.ModelDefaults {
    var d: types.ModelDefaults = .{};
    if (getStr(obj, "size")) |s| d.size = try arena.dupe(u8, s);
    if (getStr(obj, "output_format")) |s| d.output_format = try arena.dupe(u8, s);
    if (getStr(obj, "quality")) |s| d.quality = try arena.dupe(u8, s);
    d.width = try getU32(obj, "width");
    d.height = try getU32(obj, "height");
    d.output_compression = try getU32(obj, "output_compression");
    return d;
}

fn parseEndpoint(arena: Allocator, env: Env, v: Value) !types.Endpoint {
    if (v != .object) return Error.EndpointNotObject;
    const obj = &v.object;
    const base_url = getStr(obj, "base_url") orelse return Error.MissingBaseUrl;

    var ep: types.Endpoint = .{ .base_url = try arena.dupe(u8, base_url) };

    if (getStr(obj, "api_key")) |k| ep.api_key = try arena.dupe(u8, k);
    if (getStr(obj, "api_key_env")) |k| ep.api_key_env = try arena.dupe(u8, k);
    if (getStr(obj, "auth")) |a| {
        ep.auth = types.AuthScheme.fromString(a) orelse return Error.UnknownAuth;
    }

    // Resolve credential now when possible, but never fail here: listing and
    // `config show` must work without keys present. Generation validates later.
    // Trim surrounding whitespace/newlines: a trailing '\n' (common with
    // `export KEY=$(cat file)`) would otherwise produce an invalid auth header.
    if (ep.api_key) |k| {
        const t = std.mem.trim(u8, k, " \t\r\n");
        if (t.len > 0) ep.resolved_key = t;
    } else if (ep.api_key_env) |name| {
        if (env.get(name)) |val| {
            const t = std.mem.trim(u8, val, " \t\r\n");
            if (t.len > 0) ep.resolved_key = try arena.dupe(u8, t);
        }
    }
    return ep;
}

fn parseModel(arena: Allocator, env: Env, name: []const u8, v: Value) !types.ModelConfig {
    if (v != .object) return Error.ModelNotObject;
    const obj = &v.object;

    const backend_str = getStr(obj, "backend") orelse return Error.MissingBackend;
    const backend = types.BackendKind.fromString(backend_str) orelse return Error.UnknownBackend;

    const endpoints_v = obj.get("endpoints") orelse return Error.MissingEndpoints;
    if (endpoints_v != .array) return Error.MissingEndpoints;
    const arr = endpoints_v.array;
    if (arr.items.len == 0) return Error.EmptyEndpoints;

    const endpoints = try arena.alloc(types.Endpoint, arr.items.len);
    for (arr.items, 0..) |item, i| {
        endpoints[i] = try parseEndpoint(arena, env, item);
    }

    const api_model = if (getStr(obj, "api_model")) |am|
        try arena.dupe(u8, am)
    else
        try arena.dupe(u8, name);

    var defaults: types.ModelDefaults = .{};
    if (obj.get("defaults")) |dv| {
        if (dv == .object) defaults = try parseDefaults(arena, &dv.object);
    }

    return .{
        .name = try arena.dupe(u8, name),
        .backend = backend,
        .api_model = api_model,
        .endpoints = endpoints,
        .defaults = defaults,
    };
}

/// Parse config from raw JSON bytes. `gpa` backs both the returned Config's
/// arena and the temporary JSON parse; all retained data is copied into the
/// arena so the parse scratch can be freed.
pub fn loadFromBytes(gpa: Allocator, json_bytes: []const u8, env: Env) Error!Config {
    const arena_ptr = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena_ptr);
    arena_ptr.* = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_ptr.deinit();
    const arena = arena_ptr.allocator();

    var parsed = try std.json.parseFromSlice(Value, gpa, json_bytes, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return Error.NotObject;
    const root = &parsed.value.object;

    const output_dir = if (getStr(root, "output_dir")) |d|
        try arena.dupe(u8, d)
    else
        try arena.dupe(u8, "~/.imagine/outputs");

    const concurrency: u32 = (try getU32(root, "concurrency")) orelse 0;

    const models_v = root.get("models") orelse return Error.MissingModels;
    if (models_v != .object) return Error.MissingModels;
    const models_obj = &models_v.object;
    if (models_obj.count() == 0) return Error.EmptyModels;

    const models = try arena.alloc(types.ModelConfig, models_obj.count());
    var it = models_obj.iterator();
    var i: usize = 0;
    while (it.next()) |entry| : (i += 1) {
        models[i] = try parseModel(arena, env, entry.key_ptr.*, entry.value_ptr.*);
    }

    return .{
        .gpa = gpa,
        .arena = arena_ptr,
        .output_dir = output_dir,
        .concurrency = concurrency,
        .models = models,
    };
}

/// Read and parse the config file at `path`.
pub fn loadFromFile(gpa: Allocator, io: std.Io, path: []const u8, env: Env) !Config {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(8 * 1024 * 1024)) catch |err| {
        return err;
    };
    defer gpa.free(bytes);
    var cfg = try loadFromBytes(gpa, bytes, env);
    cfg.source_path = try cfg.arena.allocator().dupe(u8, path);
    return cfg;
}

/// Built-in starter config written by `imagine config init`. The Azure endpoint
/// reads its key from `$AZURE_API_KEY`.
pub const template =
    \\{
    \\  "output_dir": "~/.imagine/outputs",
    \\  "concurrency": 0,
    \\  "models": {
    \\    "gpt-image-1.5": {
    \\      "backend": "azure_image",
    \\      "api_model": "gpt-image-1.5",
    \\      "endpoints": [
    \\        {
    \\          "base_url": "https://your-resource.services.ai.azure.com/openai/v1/images/generations",
    \\          "api_key_env": "AZURE_API_KEY",
    \\          "auth": "bearer"
    \\        }
    \\      ],
    \\      "defaults": {
    \\        "size": "1024x1024",
    \\        "output_format": "png",
    \\        "output_compression": 100,
    \\        "quality": "high"
    \\      }
    \\    },
    \\    "gpt-image-2": {
    \\      "backend": "azure_image",
    \\      "api_model": "gpt-image-2",
    \\      "endpoints": [
    \\        {
    \\          "base_url": "https://your-resource.services.ai.azure.com/openai/v1/images/generations",
    \\          "api_key_env": "AZURE_API_KEY",
    \\          "auth": "bearer"
    \\        }
    \\      ],
    \\      "defaults": {
    \\        "size": "1024x1024",
    \\        "output_format": "png",
    \\        "output_compression": 100
    \\      }
    \\    },
    \\    "FLUX.2-pro": {
    \\      "backend": "azure_flux",
    \\      "api_model": "FLUX.2-pro",
    \\      "endpoints": [
    \\        {
    \\          "base_url": "https://your-resource.services.ai.azure.com/providers/blackforestlabs/v1/flux-2-pro?api-version=preview",
    \\          "api_key_env": "AZURE_API_KEY",
    \\          "auth": "bearer"
    \\        }
    \\      ],
    \\      "defaults": {
    \\        "width": 1024,
    \\        "height": 1024
    \\      }
    \\    }
    \\  }
    \\}
    \\
;

// ---- tests ----

const TestEnv = struct {
    map: std.StringHashMap([]const u8),
    fn get(ctx: *const anyopaque, name: []const u8) ?[]const u8 {
        const self: *const TestEnv = @ptrCast(@alignCast(ctx));
        return self.map.get(name);
    }
    fn env(self: *const TestEnv) Env {
        return .{ .context = self, .func = TestEnv.get };
    }
};

test "loadFromBytes parses models, endpoints and defaults" {
    const a = std.testing.allocator;
    var te = TestEnv{ .map = std.StringHashMap([]const u8).init(a) };
    defer te.map.deinit();
    try te.map.put("AZURE_API_KEY", "secret-123");

    var cfg = try loadFromBytes(a, template, te.env());
    defer cfg.deinit();

    try std.testing.expectEqual(@as(usize, 3), cfg.models.len);
    const m = cfg.findModel("gpt-image-1.5").?;
    try std.testing.expectEqual(types.BackendKind.azure_image, m.backend);
    try std.testing.expectEqualStrings("gpt-image-1.5", m.api_model);
    try std.testing.expectEqual(@as(usize, 1), m.endpoints.len);
    try std.testing.expectEqualStrings("secret-123", m.endpoints[0].resolved_key.?);
    try std.testing.expectEqualStrings("1024x1024", m.defaults.size.?);

    const flux = cfg.findModel("FLUX.2-pro").?;
    try std.testing.expectEqual(types.BackendKind.azure_flux, flux.backend);
    try std.testing.expectEqual(@as(u32, 1024), flux.defaults.width.?);
}

test "resolvePath precedence" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    var te = TestEnv{ .map = std.StringHashMap([]const u8).init(a) };
    defer te.map.deinit();
    try te.map.put("HOME", "/home/u");

    const p = try resolvePath(arena.allocator(), te.env(), null);
    try std.testing.expectEqualStrings("/home/u/.imagine/config.json", p);

    const p2 = try resolvePath(arena.allocator(), te.env(), "/x/y.json");
    try std.testing.expectEqualStrings("/x/y.json", p2);
}

test "missing models errors" {
    const a = std.testing.allocator;
    try std.testing.expectError(Error.MissingModels, loadFromBytes(a, "{}", Env.empty()));
}
