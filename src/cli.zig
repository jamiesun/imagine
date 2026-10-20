//! Command-line parsing for imagine.
//!
//! Produces a typed `Command` (or a help/error message) from raw argv. Kept
//! free of side effects so it is straightforward to test; `main.zig` executes
//! the parsed command.

const std = @import("std");
const version = @import("version.zig");
const types = @import("types.zig");

pub const Common = struct {
    config_path: ?[]const u8 = null,
    json: bool = false,
};

pub const Generate = struct {
    common: Common = .{},
    model: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    output: ?[]const u8 = null,
    n: u32 = 1,
    size: ?[]const u8 = null,
    width: ?u32 = null,
    height: ?u32 = null,
    format: ?[]const u8 = null,
    compression: ?u32 = null,
    quality: ?[]const u8 = null,
    seed: ?i64 = null,
    steps: ?u32 = null,
    /// Video: clip length in seconds.
    duration: ?u32 = null,
    /// Video: resolution token (`720p`, `1080p`, ...).
    resolution: ?[]const u8 = null,
    /// Video: aspect-ratio token (`16:9`, `9:16`, ...).
    ratio: ?[]const u8 = null,
    /// Repeatable input/reference images: paths or http(s) URLs.
    images: []const []const u8 = &.{},
    /// Ark watermark; unset leaves the provider default alone.
    watermark: ?bool = null,
    /// Async video tasks: seconds between status polls.
    poll_interval: ?u32 = null,
    /// Async video tasks: overall deadline in seconds.
    timeout: ?u32 = null,
    concurrency: ?usize = null,
    dry_run: bool = false,
    /// Explicitly authorize requests routed to endpoints that may incur charges.
    authorize_spend: bool = false,
    quiet: bool = false,
    first_frames: []const []const u8 = &.{},
    last_frames: []const []const u8 = &.{},
    ref_images: []const []const u8 = &.{},
    text_file: ?[]const u8 = null,
    ssml_file: ?[]const u8 = null,
    dialogue_file: ?[]const u8 = null,
    voice: ?[]const u8 = null,
    language: ?[]const u8 = null,
    style: ?[]const u8 = null,
    speed: ?f32 = null,
    pitch: ?f32 = null,
    voice_reference: ?[]const u8 = null,
    reference_text: ?[]const u8 = null,
    sample_rate: ?u32 = null,
    stream: types.StreamChoice = .off,
    speech_mode: ?[]const u8 = null,
};

pub const Batch = struct {
    common: Common = .{},
    manifest: ?[]const u8 = null,
    concurrency: ?usize = null,
    /// Async video tasks: seconds between status polls.
    poll_interval: ?u32 = null,
    /// Async video tasks: overall deadline in seconds.
    timeout: ?u32 = null,
    dry_run: bool = false,
    /// Explicitly authorize requests routed to endpoints that may incur charges.
    authorize_spend: bool = false,
    quiet: bool = false,
};

pub const Compose = struct {
    base: ?[]const u8 = null,
    svg: ?[]const u8 = null,
    output: ?[]const u8 = null,
    x: i32 = 0,
    y: i32 = 0,
    width: ?u32 = null,
    height: ?u32 = null,
    opacity: f32 = 1.0,
    blend: ?[]const u8 = null,
};

pub const SvgRender = struct {
    input: ?[]const u8 = null,
    output: ?[]const u8 = null,
    width: ?u32 = null,
    height: ?u32 = null,
};

pub const PngCompose = struct {
    base: ?[]const u8 = null,
    output: ?[]const u8 = null,
    layers: []const []const u8 = &.{},
};

pub const TextRender = struct {
    text: ?[]const u8 = null,
    output: ?[]const u8 = null,
    width: ?u32 = null,
    height: ?u32 = null,
    font: ?[]const u8 = null,
    size: u32 = 64,
    color: []const u8 = "#000000",
    stroke: ?[]const u8 = null,
    stroke_width: f32 = 0,
    text_align: []const u8 = "left",
    line_height: f32 = 1.2,
    padding: u32 = 0,
};

pub const ConfigInit = struct {
    common: Common = .{},
    force: bool = false,
    format: ?[]const u8 = null,
};

pub const ConfigConvert = struct {
    common: Common = .{},
    output: ?[]const u8 = null,
    to: ?[]const u8 = null,
    force: bool = false,
};

pub const Voices = struct {
    common: Common = .{},
    model: ?[]const u8 = null,
    authorize_spend: bool = false,
};

pub const Command = union(enum) {
    generate: Generate,
    batch: Batch,
    voices: Voices,
    compose: Compose,
    svg_render: SvgRender,
    png_compose: PngCompose,
    text_render: TextRender,
    models: Common,
    config_path: Common,
    config_init: ConfigInit,
    config_convert: ConfigConvert,
    config_show: Common,
    version,
};

pub const Parsed = union(enum) {
    command: Command,
    help: []const u8,
    err: []const u8,
};

pub const usage =
    \\imagine — universal image & video generation CLI for AI agents
    \\
    \\USAGE:
    \\  imagine <command> [options]
    \\
    \\COMMANDS:
    \\  generate        Generate an image, a video, or speech from a prompt
    \\  batch <file>    Generate from a JSON manifest of jobs
    \\  voices          List voices for one audio model (-m)
    \\  svg render      Render an SVG to a PNG
    \\  png compose     Compose PNG layers over a base PNG
    \\  text render     Render styled text to a transparent PNG
    \\  compose         Shortcut: render one SVG and overlay it on a PNG
    \\  models          List configured models + built-in presets (--json for machine)
    \\  config path     Print the resolved config file path
    \\  config init     Write a starter config (--force to overwrite)
    \\  config convert  Convert config between TOML and JSON
    \\  config show     Print effective config (credentials redacted)
    \\  version         Print version
    \\  help            Show this help
    \\
    \\GENERATE OPTIONS:
    \\  -m, --model <name>        Model to route to (optional if only one model)
    \\  -p, --prompt <text>       Text prompt (or one of the text-file options below)
    \\  -o, --output <path>       Output file (single) or stem (multiple)
    \\  -n, --n <count>           Number of assets (default 1)
    \\  -s, --size <WxH|token>    Size string (openai_image); a ratio token for video
    \\      --width <px>          Width (azure_flux; also derives size for openai_image)
    \\      --height <px>         Height (azure_flux; also derives size for openai_image)
    \\      --format <fmt>        png | jpeg | mp4 | wav | mp3 | pcm | ogg
    \\      --compression <0-100> Output compression (openai_image)
    \\      --quality <q>         low | medium | high | auto   (openai_image)
    \\      --seed <int>          Seed (where supported)
    \\      --steps <n>           Denoising steps (qwen_image num_inference_steps)
    \\      --image <path|url>    Repeat for multi-ref (Qwen max 10, MAI max 5); one for others
    \\      --images <p1,p2,...>  Multiple reference images (comma-separated)
    \\      --first-frame <path> Video first frame (not together with --image)
    \\      --last-frame <path>  Video last frame (requires a first frame)
    \\      --ref-image <path>   Role-specific reference (Vidu up to 7, Wan up to 9)
    \\      --watermark           Force the provider watermark on
    \\      --no-watermark        Force the provider watermark off
    \\  -c, --concurrency <num>   Parallel requests (default: endpoint count)
    \\      --config <path>       Use a specific config file
    \\      --json                Emit a JSON result object to stdout
    \\      --dry-run             Print request bodies without calling the API
    \\      --authorize-spend     Explicitly allow potentially billable API tasks
    \\  -q, --quiet               Suppress progress output
    \\
    \\VIDEO OPTIONS (seedance | gemini_video | ltx2_video backends):
    \\      --duration <sec>      Clip length in seconds
    \\      --resolution <r>      480p | 720p | 1080p | 4k
    \\      --ratio <r>           16:9 | 9:16 | 1:1 | ...   (also --size <ratio>)
    \\      --poll-interval <sec> Seconds between task status polls (default 5)
    \\      --timeout <sec>       Give up on one video task after N seconds (default 600)
    \\
    \\AUDIO OPTIONS (tts_http | google_cloud_tts | gemini_tts):
    \\      --text-file <path>   Prompt text from a file (instead of --prompt)
    \\      --ssml-file <path>   SSML document (google_cloud_tts)
    \\      --dialogue-file <p>  JSON array of {speaker,text,voice?,style?}
    \\      --voice <name>       Voice name (required for Cloud TTS and Gemini TTS)
    \\      --language <tag>     Language tag where the provider accepts one
    \\      --style <text>       Style, or the voice description for voice_design
    \\      --speed <float>      Speaking rate where supported
    \\      --pitch <float>      Pitch where supported
    \\      --mode <mode>        speech | voice_design | voice_clone | dialogue
    \\      --voice-reference <p> Reference audio for voice_clone
    \\      --reference-text <t> Transcript of that reference audio
    \\      --sample-rate <hz>   Requested sample rate
    \\      --stream [on|off|auto] Incremental audio. Bare --stream means on.
    \\                          off is the default. A server that only buffers
    \\                          the finished clip must say streaming false.
    \\
    \\SVG RENDER OPTIONS:
    \\      --input <svg>         Input SVG (required)
    \\  -o, --output <png>        Output PNG path (required)
    \\      --width <px>          Rendered width
    \\      --height <px>         Rendered height
    \\
    \\PNG COMPOSE OPTIONS:
    \\      --base <png>          Base PNG image (required)
    \\      --layer <spec>        Layer spec: path.png,x=0,y=0,opacity=1,blend=normal
    \\  -o, --output <png>        Output PNG path (required)
    \\
    \\TEXT RENDER OPTIONS:
    \\      --text <text>         Text; literal \n is treated as a line break
    \\  -o, --output <png>        Output PNG path (required)
    \\      --width <px>          Canvas width (required)
    \\      --height <px>         Canvas height (auto if omitted)
    \\      --font <name>         Font family (default Arial)
    \\      --size <px>           Font size (default 64)
    \\      --color <css>         Fill color (default #000000)
    \\      --stroke <css>        Stroke color
    \\      --stroke-width <px>   Stroke width
    \\      --align <mode>        left | center | right
    \\      --line-height <num>   Line-height multiplier (default 1.2)
    \\      --padding <px>        Canvas padding (default 0)
    \\
    \\COMPOSE SHORTCUT OPTIONS:
    \\      --base <png>          Base PNG image (required)
    \\      --svg <svg>           SVG overlay image (required)
    \\  -o, --output <png>        Output PNG path (required)
    \\      --x <px>              Overlay x offset (default 0)
    \\      --y <px>              Overlay y offset (default 0)
    \\      --width <px>          Rendered SVG width
    \\      --height <px>         Rendered SVG height
    \\      --opacity <0-1>       Layer opacity (default 1)
    \\      --blend <mode>        normal | multiply | screen | overlay | darken | lighten
    \\
    \\MODELS:
    \\  Logical model names come from ~/.imagine/config.toml (dynamic), or from
    \\  ephemeral env when no config file exists. Run `imagine models`.
    \\  backends: mai_image        (Azure MAI image: T2I + multi-image edits)
    \\            openai_image     (OpenAI-compatible /v1/images/generations)
    \\            azure_flux       (Azure FLUX; uses --width/--height)
    \\            qwen_image       (local Qwen-Image server; --size/--steps/--image edit)
    \\            volcengine_image (Ark Seedream image; env ARK_API_KEY)
    \\            seedance         (Ark Seedance video; env ARK_API_KEY)
    \\            gemini_video     (Gemini Omni video; env GEMINI_API_KEY)
    \\            ltx2_video       (self-hosted LTX-2 video service)
    \\            dashscope_image  (Wan image; DASHSCOPE_API_KEY; no preset, URL is account-specific)
    \\            dashscope_video  (Wan video; first/last frame; async header from the URL)
    \\            vidu_video       (Vidu; Authorization: Token; ref images or frames, not both)
    \\            kling_video      (Kling v1; jwt_hs256 access key + secret, or a bearer token)
    \\            minimax_video    (MiniMax video; file retrieve then an unauthenticated CDN GET)
    \\            siliconflow_image (SiliconFlow image; at most one reference)
    \\            tts_http         (imagine TTS protocol; integrations/qwen3-tts)
    \\            google_cloud_tts (Cloud Text-to-Speech REST, not a Gemini API key)
    \\            gemini_tts       (Gemini Interactions speech; not gemini_video)
    \\  Video backends create a provider task and poll it: expect minutes, not
    \\  seconds. They write one file per task and default to the .mp4 extension.
    \\  Self-hosted endpoints (e.g. a local Qwen-Image server) need no credential:
    \\  set auth = "none" on the endpoint, or IMAGINE_AUTH=none when going ephemeral.
    \\  Size limits are provider-specific; use model defaults in config or --dry-run.
    \\
    \\ENVIRONMENT:
    \\  IMAGINE_CONFIG            Override config path (default ~/.imagine/config.toml)
    \\  AZURE_OPENAI_APIKEY       Default credential for OpenAI/Azure backends
    \\  ARK_API_KEY               Credential for volcengine_image / seedance
    \\  GEMINI_API_KEY            Credential for gemini_video
    \\  IMAGINE_BASE_URL          Ephemeral: endpoint URL (required if no file)
    \\  IMAGINE_MODEL             Ephemeral: logical model name (required if no file)
    \\  IMAGINE_API_MODEL         Ephemeral: api model field (default: IMAGINE_MODEL)
    \\  IMAGINE_BACKEND           Ephemeral: backend name (default openai_image)
    \\  IMAGINE_AUTH              Ephemeral: bearer | api-key | google_api_key | none
    \\  IMAGINE_API_KEY           Ephemeral: inline API key (overrides env key)
    \\  IMAGINE_API_KEY_ENV       Ephemeral: env var name for key (default: backend's)
    \\  IMAGINE_SIZE/WIDTH/STEPS  Ephemeral model defaults
    \\  IMAGINE_DURATION/RESOLUTION/RATIO  Ephemeral video model defaults
    \\  IMAGINE_AUTHORIZE_SPEND   =1 authorizes billable tasks (like --authorize-spend)
    \\
    \\EXAMPLES:
    \\  imagine models --json
    \\  imagine generate -m <model> -p "a red fox in autumn" -o fox.png
    \\  # no config file — ephemeral env:
    \\  IMAGINE_BASE_URL=https://host/v1/images/generations \\
    \\  IMAGINE_MODEL=MAI-Image-2.6-Flash AZURE_OPENAI_APIKEY=... \\
    \\    imagine generate -p "a fox" -o fox.png
    \\  # local Qwen-Image server (no key needed):
    \\  IMAGINE_BASE_URL=http://127.0.0.1:8000/v1/images/generations \\
    \\  IMAGINE_MODEL=qwen-image-2.1 IMAGINE_BACKEND=qwen_image IMAGINE_AUTH=none \\
    \\    imagine generate -p "a neon Qwen sign" --size 16:9 --steps 40 -o qwen.png
    \\  IMAGINE_BASE_URL=http://127.0.0.1:8000/v1/images/generations \\
    \\  IMAGINE_MODEL=qwen-image-2.1 IMAGINE_BACKEND=qwen_image IMAGINE_AUTH=none \\
    \\    imagine generate -p "replace the background" --image photo.png -o edited.png
    \\  # video (Ark Seedance / Gemini Omni) — key from env, model from `imagine models`
    \\  imagine generate -m doubao-seedance-2-5-260628 -p "a fox in snow" \\
    \\    --duration 5 --resolution 720p --ratio 16:9 -o fox.mp4
    \\  imagine generate -m gemini-omni-1.1-flash -p "a marble run" --image first.png -o run.mp4
    \\  imagine batch jobs.json
    \\  imagine svg render --input badge.svg -o badge.png --width 256
    \\  imagine text render --text "SALE\n50% OFF" -o copy.png --width 900 --font "PingFang SC" --size 72 --align center
    \\  imagine png compose --base photo.png --layer badge.png,x=24,y=24,blend=normal -o composed.png
    \\  imagine compose --base photo.png --svg badge.svg -o composed.png --x 24 --y 24 --width 256
    \\  imagine config convert --config ~/.imagine/config.json --to toml -o ~/.imagine/config.toml
    \\
;

const FlagSplit = struct { name: []const u8, value: ?[]const u8 };

fn split(arg: []const u8) FlagSplit {
    if (std.mem.startsWith(u8, arg, "--")) {
        if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
            return .{ .name = arg[0..eq], .value = arg[eq + 1 ..] };
        }
    }
    return .{ .name = arg, .value = null };
}

const Cursor = struct {
    args: []const []const u8,
    i: usize = 0,

    fn value(self: *Cursor, fs: FlagSplit, arena: std.mem.Allocator) !?[]const u8 {
        if (fs.value) |v| return v;
        if (self.i + 1 >= self.args.len) return null;
        self.i += 1;
        return try arena.dupe(u8, self.args[self.i]);
    }
};

fn parseU32(s: []const u8) ?u32 {
    return std.fmt.parseInt(u32, s, 10) catch null;
}

/// Parse argv (excluding the program name). Allocations use `arena`.
pub fn parse(arena: std.mem.Allocator, args: []const []const u8) !Parsed {
    if (args.len == 0) return .{ .help = usage };

    const cmd = args[0];
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        return .{ .help = usage };
    }
    if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-V")) {
        return .{ .command = .version };
    }
    if (std.mem.eql(u8, cmd, "generate") or std.mem.eql(u8, cmd, "gen") or std.mem.eql(u8, cmd, "g")) {
        return parseGenerate(arena, args[1..]);
    }
    if (std.mem.eql(u8, cmd, "batch")) {
        return parseBatch(arena, args[1..]);
    }
    if (std.mem.eql(u8, cmd, "svg")) {
        return parseSvg(arena, args[1..]);
    }
    if (std.mem.eql(u8, cmd, "png")) {
        return parsePng(arena, args[1..]);
    }
    if (std.mem.eql(u8, cmd, "text")) {
        return parseText(arena, args[1..]);
    }
    if (std.mem.eql(u8, cmd, "compose")) {
        return parseCompose(arena, args[1..]);
    }
    if (std.mem.eql(u8, cmd, "models")) {
        return parseCommon(arena, args[1..], .models);
    }
    if (std.mem.eql(u8, cmd, "voices")) {
        return parseVoices(arena, args[1..]);
    }
    if (std.mem.eql(u8, cmd, "config")) {
        return parseConfig(arena, args[1..]);
    }
    return .{ .err = try std.fmt.allocPrint(arena, "unknown command: '{s}' (try 'imagine help')", .{cmd}) };
}

fn unknownFlag(arena: std.mem.Allocator, name: []const u8) !Parsed {
    return .{ .err = try std.fmt.allocPrint(arena, "unknown or misplaced option: '{s}'", .{name}) };
}

fn missingValue(arena: std.mem.Allocator, name: []const u8) !Parsed {
    return .{ .err = try std.fmt.allocPrint(arena, "option '{s}' requires a value", .{name}) };
}

fn parseGenerate(arena: std.mem.Allocator, args: []const []const u8) !Parsed {
    var g = Generate{};
    var images = std.ArrayList([]const u8).empty;
    var first_frames = std.ArrayList([]const u8).empty;
    var last_frames = std.ArrayList([]const u8).empty;
    var ref_images = std.ArrayList([]const u8).empty;
    var cur = Cursor{ .args = args };
    var positional: ?[]const u8 = null;

    while (cur.i < args.len) : (cur.i += 1) {
        const fs = split(args[cur.i]);
        const name = fs.name;
        if (std.mem.eql(u8, name, "-m") or std.mem.eql(u8, name, "--model")) {
            g.model = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
        } else if (std.mem.eql(u8, name, "-p") or std.mem.eql(u8, name, "--prompt")) {
            g.prompt = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
        } else if (std.mem.eql(u8, name, "-o") or std.mem.eql(u8, name, "--output")) {
            g.output = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
        } else if (std.mem.eql(u8, name, "-n") or std.mem.eql(u8, name, "--n") or std.mem.eql(u8, name, "--count")) {
            const v = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
            g.n = parseU32(v) orelse return .{ .err = try std.fmt.allocPrint(arena, "invalid --n: {s}", .{v}) };
        } else if (std.mem.eql(u8, name, "-s") or std.mem.eql(u8, name, "--size")) {
            g.size = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
        } else if (std.mem.eql(u8, name, "--width")) {
            const v = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
            g.width = parseU32(v) orelse return .{ .err = try std.fmt.allocPrint(arena, "invalid --width: {s}", .{v}) };
        } else if (std.mem.eql(u8, name, "--height")) {
            const v = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
            g.height = parseU32(v) orelse return .{ .err = try std.fmt.allocPrint(arena, "invalid --height: {s}", .{v}) };
        } else if (std.mem.eql(u8, name, "--format") or std.mem.eql(u8, name, "-f")) {
            g.format = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
        } else if (std.mem.eql(u8, name, "--compression")) {
            const v = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
            g.compression = parseU32(v) orelse return .{ .err = try std.fmt.allocPrint(arena, "invalid --compression: {s}", .{v}) };
        } else if (std.mem.eql(u8, name, "--quality")) {
            g.quality = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
        } else if (std.mem.eql(u8, name, "--seed")) {
            const v = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
            g.seed = std.fmt.parseInt(i64, v, 10) catch return .{ .err = try std.fmt.allocPrint(arena, "invalid --seed: {s}", .{v}) };
        } else if (std.mem.eql(u8, name, "--steps")) {
            const v = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
            g.steps = parseU32(v) orelse return .{ .err = try std.fmt.allocPrint(arena, "invalid --steps: {s}", .{v}) };
        } else if (std.mem.eql(u8, name, "--duration")) {
            const v = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
            g.duration = parseU32(v) orelse return .{ .err = try std.fmt.allocPrint(arena, "invalid --duration: {s}", .{v}) };
        } else if (std.mem.eql(u8, name, "--resolution")) {
            g.resolution = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
        } else if (std.mem.eql(u8, name, "--ratio")) {
            g.ratio = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
        } else if (std.mem.eql(u8, name, "--image")) {
            try images.append(arena, (try cur.value(fs, arena)) orelse return missingValue(arena, name));
        } else if (std.mem.eql(u8, name, "--images")) {
            const v = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
            var it = std.mem.splitScalar(u8, v, ',');
            while (it.next()) |item| {
                const trimmed = std.mem.trim(u8, item, " \t");
                if (trimmed.len > 0) {
                    try images.append(arena, trimmed);
                }
            }
        } else if (std.mem.eql(u8, name, "--watermark")) {
            g.watermark = true;
        } else if (std.mem.eql(u8, name, "--no-watermark")) {
            g.watermark = false;
        } else if (std.mem.eql(u8, name, "--poll-interval")) {
            const v = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
            g.poll_interval = parseU32(v) orelse return .{ .err = try std.fmt.allocPrint(arena, "invalid --poll-interval: {s}", .{v}) };
        } else if (std.mem.eql(u8, name, "--timeout")) {
            const v = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
            g.timeout = parseU32(v) orelse return .{ .err = try std.fmt.allocPrint(arena, "invalid --timeout: {s}", .{v}) };
        } else if (std.mem.eql(u8, name, "-c") or std.mem.eql(u8, name, "--concurrency")) {
            const v = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
            g.concurrency = parseU32(v) orelse return .{ .err = try std.fmt.allocPrint(arena, "invalid --concurrency: {s}", .{v}) };
        } else if (std.mem.eql(u8, name, "--config")) {
            g.common.config_path = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
        } else if (std.mem.eql(u8, name, "--json")) {
            g.common.json = true;
        } else if (std.mem.eql(u8, name, "--dry-run")) {
            g.dry_run = true;
        } else if (std.mem.eql(u8, name, "--first-frame")) {
            try first_frames.append(arena, (try cur.value(fs, arena)) orelse return missingValue(arena, name));
        } else if (std.mem.eql(u8, name, "--last-frame")) {
            try last_frames.append(arena, (try cur.value(fs, arena)) orelse return missingValue(arena, name));
        } else if (std.mem.eql(u8, name, "--ref-image")) {
            try ref_images.append(arena, (try cur.value(fs, arena)) orelse return missingValue(arena, name));
        } else if (std.mem.eql(u8, name, "--text-file")) {
            g.text_file = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
        } else if (std.mem.eql(u8, name, "--ssml-file")) {
            g.ssml_file = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
        } else if (std.mem.eql(u8, name, "--dialogue-file")) {
            g.dialogue_file = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
        } else if (std.mem.eql(u8, name, "--voice")) {
            g.voice = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
        } else if (std.mem.eql(u8, name, "--language")) {
            g.language = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
        } else if (std.mem.eql(u8, name, "--style")) {
            g.style = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
        } else if (std.mem.eql(u8, name, "--speed")) {
            const v = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
            g.speed = std.fmt.parseFloat(f32, v) catch return .{ .err = try std.fmt.allocPrint(arena, "invalid --speed: {s}", .{v}) };
        } else if (std.mem.eql(u8, name, "--pitch")) {
            const v = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
            g.pitch = std.fmt.parseFloat(f32, v) catch return .{ .err = try std.fmt.allocPrint(arena, "invalid --pitch: {s}", .{v}) };
        } else if (std.mem.eql(u8, name, "--mode")) {
            g.speech_mode = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
        } else if (std.mem.eql(u8, name, "--voice-reference")) {
            g.voice_reference = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
        } else if (std.mem.eql(u8, name, "--reference-text")) {
            g.reference_text = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
        } else if (std.mem.eql(u8, name, "--sample-rate")) {
            const v = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
            g.sample_rate = parseU32(v) orelse return .{ .err = try std.fmt.allocPrint(arena, "invalid --sample-rate: {s}", .{v}) };
        } else if (std.mem.eql(u8, name, "--stream")) {
            if (fs.value) |v| {
                g.stream = types.StreamChoice.fromString(v) orelse return .{ .err = try std.fmt.allocPrint(arena, "invalid --stream: {s}", .{v}) };
            } else if (cur.i + 1 < args.len and types.StreamChoice.fromString(args[cur.i + 1]) != null) {
                const v = (try cur.value(fs, arena)).?;
                g.stream = types.StreamChoice.fromString(v).?;
            } else {
                g.stream = .on;
            }
        } else if (std.mem.eql(u8, name, "--authorize-spend")) {
            g.authorize_spend = true;
        } else if (std.mem.eql(u8, name, "-q") or std.mem.eql(u8, name, "--quiet")) {
            g.quiet = true;
        } else if (std.mem.startsWith(u8, name, "-")) {
            return unknownFlag(arena, name);
        } else {
            if (positional == null) positional = try arena.dupe(u8, args[cur.i]);
        }
    }

    g.images = try images.toOwnedSlice(arena);
    g.first_frames = try first_frames.toOwnedSlice(arena);
    g.last_frames = try last_frames.toOwnedSlice(arena);
    g.ref_images = try ref_images.toOwnedSlice(arena);
    const text_sources: usize = @intFromBool(g.prompt != null or positional != null) +
        @intFromBool(g.text_file != null) +
        @intFromBool(g.ssml_file != null) +
        @intFromBool(g.dialogue_file != null);
    if (text_sources > 1) return .{ .err = try arena.dupe(u8, "pass only one of --prompt, --text-file, --ssml-file, or --dialogue-file") };
    if (text_sources == 0) return .{ .err = try arena.dupe(u8, "missing required option: --prompt") };
    if (g.prompt == null) g.prompt = positional;
    // --model is optional when exactly one model is configured (validated in main).
    if (g.n == 0) return .{ .err = try arena.dupe(u8, "--n must be >= 1") };
    if (g.steps) |s| {
        if (s == 0) return .{ .err = try arena.dupe(u8, "--steps must be >= 1") };
    }
    if (g.duration) |d| {
        if (d == 0) return .{ .err = try arena.dupe(u8, "--duration must be >= 1") };
    }
    if (try checkPollOptions(arena, g.poll_interval, g.timeout)) |err| return err;

    return .{ .command = .{ .generate = g } };
}

/// Both `generate` and `batch` bound async video tasks with these; a zero would
/// silently mean "give up immediately", so it is a usage error instead.
fn checkPollOptions(arena: std.mem.Allocator, poll_interval: ?u32, timeout: ?u32) !?Parsed {
    if (poll_interval) |p| {
        if (p == 0) return .{ .err = try arena.dupe(u8, "--poll-interval must be >= 1") };
    }
    if (timeout) |t| {
        if (t == 0) return .{ .err = try arena.dupe(u8, "--timeout must be >= 1") };
    }
    return null;
}

fn parseBatch(arena: std.mem.Allocator, args: []const []const u8) !Parsed {
    var b = Batch{};
    var cur = Cursor{ .args = args };
    while (cur.i < args.len) : (cur.i += 1) {
        const fs = split(args[cur.i]);
        const name = fs.name;
        if (std.mem.eql(u8, name, "-c") or std.mem.eql(u8, name, "--concurrency")) {
            const v = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
            b.concurrency = parseU32(v) orelse return .{ .err = try std.fmt.allocPrint(arena, "invalid --concurrency: {s}", .{v}) };
        } else if (std.mem.eql(u8, name, "--poll-interval")) {
            const v = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
            b.poll_interval = parseU32(v) orelse return .{ .err = try std.fmt.allocPrint(arena, "invalid --poll-interval: {s}", .{v}) };
        } else if (std.mem.eql(u8, name, "--timeout")) {
            const v = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
            b.timeout = parseU32(v) orelse return .{ .err = try std.fmt.allocPrint(arena, "invalid --timeout: {s}", .{v}) };
        } else if (std.mem.eql(u8, name, "--config")) {
            b.common.config_path = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
        } else if (std.mem.eql(u8, name, "--json")) {
            b.common.json = true;
        } else if (std.mem.eql(u8, name, "--dry-run")) {
            b.dry_run = true;
        } else if (std.mem.eql(u8, name, "--authorize-spend")) {
            b.authorize_spend = true;
        } else if (std.mem.eql(u8, name, "-q") or std.mem.eql(u8, name, "--quiet")) {
            b.quiet = true;
        } else if (std.mem.startsWith(u8, name, "-")) {
            return unknownFlag(arena, name);
        } else {
            if (b.manifest == null) b.manifest = try arena.dupe(u8, args[cur.i]);
        }
    }
    if (b.manifest == null) return .{ .err = try arena.dupe(u8, "batch requires a manifest file path") };
    if (try checkPollOptions(arena, b.poll_interval, b.timeout)) |err| return err;
    return .{ .command = .{ .batch = b } };
}

fn parseI32(s: []const u8) ?i32 {
    return std.fmt.parseInt(i32, s, 10) catch null;
}

fn parseF32(s: []const u8) ?f32 {
    return std.fmt.parseFloat(f32, s) catch null;
}

fn parseCompose(arena: std.mem.Allocator, args: []const []const u8) !Parsed {
    var c = Compose{};
    var cur = Cursor{ .args = args };
    while (cur.i < args.len) : (cur.i += 1) {
        const fs = split(args[cur.i]);
        const name = fs.name;
        if (std.mem.eql(u8, name, "--base")) {
            c.base = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
        } else if (std.mem.eql(u8, name, "--svg")) {
            c.svg = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
        } else if (std.mem.eql(u8, name, "-o") or std.mem.eql(u8, name, "--output")) {
            c.output = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
        } else if (std.mem.eql(u8, name, "--x")) {
            const v = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
            c.x = parseI32(v) orelse return .{ .err = try std.fmt.allocPrint(arena, "invalid --x: {s}", .{v}) };
        } else if (std.mem.eql(u8, name, "--y")) {
            const v = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
            c.y = parseI32(v) orelse return .{ .err = try std.fmt.allocPrint(arena, "invalid --y: {s}", .{v}) };
        } else if (std.mem.eql(u8, name, "--width")) {
            const v = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
            c.width = parseU32(v) orelse return .{ .err = try std.fmt.allocPrint(arena, "invalid --width: {s}", .{v}) };
        } else if (std.mem.eql(u8, name, "--height")) {
            const v = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
            c.height = parseU32(v) orelse return .{ .err = try std.fmt.allocPrint(arena, "invalid --height: {s}", .{v}) };
        } else if (std.mem.eql(u8, name, "--opacity")) {
            const v = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
            c.opacity = parseF32(v) orelse return .{ .err = try std.fmt.allocPrint(arena, "invalid --opacity: {s}", .{v}) };
        } else if (std.mem.eql(u8, name, "--blend")) {
            c.blend = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
        } else if (std.mem.startsWith(u8, name, "-")) {
            return unknownFlag(arena, name);
        }
    }
    if (c.base == null) return .{ .err = try arena.dupe(u8, "compose requires --base <png>") };
    if (c.svg == null) return .{ .err = try arena.dupe(u8, "compose requires --svg <svg>") };
    if (c.output == null) return .{ .err = try arena.dupe(u8, "compose requires --output <png>") };
    if (c.width == 0 or c.height == 0) return .{ .err = try arena.dupe(u8, "--width/--height must be >= 1 when provided") };
    if (c.opacity < 0 or c.opacity > 1) return .{ .err = try arena.dupe(u8, "--opacity must be between 0 and 1") };
    return .{ .command = .{ .compose = c } };
}

fn parseSvg(arena: std.mem.Allocator, args: []const []const u8) !Parsed {
    if (args.len == 0) return .{ .err = try arena.dupe(u8, "svg requires a subcommand: render") };
    if (!std.mem.eql(u8, args[0], "render")) {
        return .{ .err = try std.fmt.allocPrint(arena, "unknown svg subcommand: '{s}'", .{args[0]}) };
    }
    var r = SvgRender{};
    var cur = Cursor{ .args = args[1..] };
    while (cur.i < args[1..].len) : (cur.i += 1) {
        const fs = split(args[1..][cur.i]);
        const name = fs.name;
        if (std.mem.eql(u8, name, "--input") or std.mem.eql(u8, name, "-i")) {
            r.input = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
        } else if (std.mem.eql(u8, name, "-o") or std.mem.eql(u8, name, "--output")) {
            r.output = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
        } else if (std.mem.eql(u8, name, "--width")) {
            const v = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
            r.width = parseU32(v) orelse return .{ .err = try std.fmt.allocPrint(arena, "invalid --width: {s}", .{v}) };
        } else if (std.mem.eql(u8, name, "--height")) {
            const v = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
            r.height = parseU32(v) orelse return .{ .err = try std.fmt.allocPrint(arena, "invalid --height: {s}", .{v}) };
        } else if (std.mem.startsWith(u8, name, "-")) {
            return unknownFlag(arena, name);
        }
    }
    if (r.input == null) return .{ .err = try arena.dupe(u8, "svg render requires --input <svg>") };
    if (r.output == null) return .{ .err = try arena.dupe(u8, "svg render requires --output <png>") };
    if (r.width == 0 or r.height == 0) return .{ .err = try arena.dupe(u8, "--width/--height must be >= 1 when provided") };
    return .{ .command = .{ .svg_render = r } };
}

fn parsePng(arena: std.mem.Allocator, args: []const []const u8) !Parsed {
    if (args.len == 0) return .{ .err = try arena.dupe(u8, "png requires a subcommand: compose") };
    if (!std.mem.eql(u8, args[0], "compose")) {
        return .{ .err = try std.fmt.allocPrint(arena, "unknown png subcommand: '{s}'", .{args[0]}) };
    }
    var p = PngCompose{};
    var layers = std.ArrayList([]const u8).empty;
    var cur = Cursor{ .args = args[1..] };
    while (cur.i < args[1..].len) : (cur.i += 1) {
        const fs = split(args[1..][cur.i]);
        const name = fs.name;
        if (std.mem.eql(u8, name, "--base")) {
            p.base = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
        } else if (std.mem.eql(u8, name, "--layer")) {
            const v = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
            try layers.append(arena, v);
        } else if (std.mem.eql(u8, name, "-o") or std.mem.eql(u8, name, "--output")) {
            p.output = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
        } else if (std.mem.startsWith(u8, name, "-")) {
            return unknownFlag(arena, name);
        }
    }
    if (p.base == null) return .{ .err = try arena.dupe(u8, "png compose requires --base <png>") };
    if (p.output == null) return .{ .err = try arena.dupe(u8, "png compose requires --output <png>") };
    if (layers.items.len == 0) return .{ .err = try arena.dupe(u8, "png compose requires at least one --layer <spec>") };
    p.layers = try layers.toOwnedSlice(arena);
    return .{ .command = .{ .png_compose = p } };
}

fn parseText(arena: std.mem.Allocator, args: []const []const u8) !Parsed {
    if (args.len == 0) return .{ .err = try arena.dupe(u8, "text requires a subcommand: render") };
    if (!std.mem.eql(u8, args[0], "render")) {
        return .{ .err = try std.fmt.allocPrint(arena, "unknown text subcommand: '{s}'", .{args[0]}) };
    }
    var t = TextRender{};
    var cur = Cursor{ .args = args[1..] };
    while (cur.i < args[1..].len) : (cur.i += 1) {
        const fs = split(args[1..][cur.i]);
        const name = fs.name;
        if (std.mem.eql(u8, name, "--text")) {
            t.text = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
        } else if (std.mem.eql(u8, name, "-o") or std.mem.eql(u8, name, "--output")) {
            t.output = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
        } else if (std.mem.eql(u8, name, "--width")) {
            const v = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
            t.width = parseU32(v) orelse return .{ .err = try std.fmt.allocPrint(arena, "invalid --width: {s}", .{v}) };
        } else if (std.mem.eql(u8, name, "--height")) {
            const v = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
            t.height = parseU32(v) orelse return .{ .err = try std.fmt.allocPrint(arena, "invalid --height: {s}", .{v}) };
        } else if (std.mem.eql(u8, name, "--font")) {
            t.font = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
        } else if (std.mem.eql(u8, name, "--size")) {
            const v = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
            t.size = parseU32(v) orelse return .{ .err = try std.fmt.allocPrint(arena, "invalid --size: {s}", .{v}) };
        } else if (std.mem.eql(u8, name, "--color")) {
            t.color = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
        } else if (std.mem.eql(u8, name, "--stroke")) {
            t.stroke = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
        } else if (std.mem.eql(u8, name, "--stroke-width")) {
            const v = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
            t.stroke_width = parseF32(v) orelse return .{ .err = try std.fmt.allocPrint(arena, "invalid --stroke-width: {s}", .{v}) };
        } else if (std.mem.eql(u8, name, "--align")) {
            t.text_align = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
        } else if (std.mem.eql(u8, name, "--line-height")) {
            const v = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
            t.line_height = parseF32(v) orelse return .{ .err = try std.fmt.allocPrint(arena, "invalid --line-height: {s}", .{v}) };
        } else if (std.mem.eql(u8, name, "--padding")) {
            const v = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
            t.padding = parseU32(v) orelse return .{ .err = try std.fmt.allocPrint(arena, "invalid --padding: {s}", .{v}) };
        } else if (std.mem.startsWith(u8, name, "-")) {
            return unknownFlag(arena, name);
        }
    }
    if (t.text == null) return .{ .err = try arena.dupe(u8, "text render requires --text <text>") };
    if (t.output == null) return .{ .err = try arena.dupe(u8, "text render requires --output <png>") };
    if (t.width == null) return .{ .err = try arena.dupe(u8, "text render requires --width <px>") };
    if (t.width.? == 0 or t.height == 0 or t.size == 0) return .{ .err = try arena.dupe(u8, "--width/--height/--size must be >= 1 when provided") };
    if (t.stroke_width < 0) return .{ .err = try arena.dupe(u8, "--stroke-width must be >= 0") };
    if (t.line_height <= 0) return .{ .err = try arena.dupe(u8, "--line-height must be > 0") };
    return .{ .command = .{ .text_render = t } };
}

fn parseVoices(arena: std.mem.Allocator, args: []const []const u8) !Parsed {
    var v = Voices{};
    var cur = Cursor{ .args = args };
    var positional: ?[]const u8 = null;
    while (cur.i < args.len) : (cur.i += 1) {
        const fs = split(args[cur.i]);
        const name = fs.name;
        if (std.mem.eql(u8, name, "-m") or std.mem.eql(u8, name, "--model")) {
            v.model = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
        } else if (std.mem.eql(u8, name, "--config")) {
            v.common.config_path = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
        } else if (std.mem.eql(u8, name, "--json")) {
            v.common.json = true;
        } else if (std.mem.eql(u8, name, "--authorize-spend")) {
            v.authorize_spend = true;
        } else if (std.mem.startsWith(u8, name, "-")) {
            return unknownFlag(arena, name);
        } else if (positional == null) {
            positional = try arena.dupe(u8, args[cur.i]);
        }
    }
    if (v.model == null) v.model = positional;
    return .{ .command = .{ .voices = v } };
}

fn parseCommon(arena: std.mem.Allocator, args: []const []const u8, comptime tag: std.meta.Tag(Command)) !Parsed {
    var c = Common{};
    var cur = Cursor{ .args = args };
    while (cur.i < args.len) : (cur.i += 1) {
        const fs = split(args[cur.i]);
        const name = fs.name;
        if (std.mem.eql(u8, name, "--config")) {
            c.config_path = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
        } else if (std.mem.eql(u8, name, "--json")) {
            c.json = true;
        } else if (std.mem.startsWith(u8, name, "-")) {
            return unknownFlag(arena, name);
        }
    }
    return switch (tag) {
        .models => .{ .command = .{ .models = c } },
        .config_path => .{ .command = .{ .config_path = c } },
        .config_show => .{ .command = .{ .config_show = c } },
        else => unreachable,
    };
}

fn parseConfig(arena: std.mem.Allocator, args: []const []const u8) !Parsed {
    if (args.len == 0) return .{ .err = try arena.dupe(u8, "config requires a subcommand: path | init | convert | show") };
    const sub = args[0];
    if (std.mem.eql(u8, sub, "path")) return parseCommon(arena, args[1..], .config_path);
    if (std.mem.eql(u8, sub, "show")) return parseCommon(arena, args[1..], .config_show);
    if (std.mem.eql(u8, sub, "convert")) {
        var cc = ConfigConvert{};
        var cur = Cursor{ .args = args[1..] };
        while (cur.i < args[1..].len) : (cur.i += 1) {
            const fs = split(args[1..][cur.i]);
            const name = fs.name;
            if (std.mem.eql(u8, name, "--config")) {
                cc.common.config_path = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
            } else if (std.mem.eql(u8, name, "--to") or std.mem.eql(u8, name, "--format")) {
                cc.to = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
            } else if (std.mem.eql(u8, name, "-o") or std.mem.eql(u8, name, "--output")) {
                cc.output = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
            } else if (std.mem.eql(u8, name, "--force") or std.mem.eql(u8, name, "-f")) {
                cc.force = true;
            } else if (std.mem.startsWith(u8, name, "-")) {
                return unknownFlag(arena, name);
            }
        }
        return .{ .command = .{ .config_convert = cc } };
    }
    if (std.mem.eql(u8, sub, "init")) {
        var ci = ConfigInit{};
        var cur = Cursor{ .args = args[1..] };
        while (cur.i < args[1..].len) : (cur.i += 1) {
            const fs = split(args[1..][cur.i]);
            const name = fs.name;
            if (std.mem.eql(u8, name, "--force") or std.mem.eql(u8, name, "-f")) {
                ci.force = true;
            } else if (std.mem.eql(u8, name, "--config")) {
                ci.common.config_path = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
            } else if (std.mem.eql(u8, name, "--format")) {
                ci.format = (try cur.value(fs, arena)) orelse return missingValue(arena, name);
            } else if (std.mem.startsWith(u8, name, "-")) {
                return unknownFlag(arena, name);
            }
        }
        return .{ .command = .{ .config_init = ci } };
    }
    return .{ .err = try std.fmt.allocPrint(arena, "unknown config subcommand: '{s}'", .{sub}) };
}

// ---- tests ----

fn parseArgs(arena: std.mem.Allocator, comptime items: []const []const u8) !Parsed {
    return parse(arena, items);
}

test "parse generate with flags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try parseArgs(a, &.{ "generate", "-m", "gpt-image-1.5", "-p", "a fox", "-n", "3", "-o", "x.png" });
    try std.testing.expect(p == .command);
    const g = p.command.generate;
    try std.testing.expectEqualStrings("gpt-image-1.5", g.model.?);
    try std.testing.expectEqualStrings("a fox", g.prompt.?);
    try std.testing.expectEqual(@as(u32, 3), g.n);
    try std.testing.expectEqualStrings("x.png", g.output.?);
}

test "parse generate collects repeated --image values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = try parseArgs(arena.allocator(), &.{
        "generate", "-p", "combine references", "--image", "first.png", "--image=second.jpg",
    });
    try std.testing.expect(p == .command);
    const images = p.command.generate.images;
    try std.testing.expectEqual(@as(usize, 2), images.len);
    try std.testing.expectEqualStrings("first.png", images[0]);
    try std.testing.expectEqualStrings("second.jpg", images[1]);
}

test "parse generate --steps and reject 0" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try parseArgs(a, &.{ "generate", "-p", "a fox", "--steps", "25" });
    try std.testing.expect(p == .command);
    try std.testing.expectEqual(@as(u32, 25), p.command.generate.steps.?);

    const bad = try parseArgs(a, &.{ "generate", "-p", "a fox", "--steps", "0" });
    try std.testing.expect(bad == .err);
}

test "parse generate equals form and positional prompt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try parseArgs(a, &.{ "g", "--model=FLUX.2-pro", "--width=512", "--height=512", "a cat" });
    const g = p.command.generate;
    try std.testing.expectEqualStrings("FLUX.2-pro", g.model.?);
    try std.testing.expectEqual(@as(u32, 512), g.width.?);
    try std.testing.expectEqualStrings("a cat", g.prompt.?);
}

test "missing model is allowed at parse (resolved in main)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = try parseArgs(arena.allocator(), &.{ "generate", "-p", "x" });
    try std.testing.expect(p == .command);
    try std.testing.expect(p.command.generate.model == null);
    try std.testing.expectEqualStrings("x", p.command.generate.prompt.?);
}

test "help and version" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect((try parseArgs(arena.allocator(), &.{"help"})) == .help);
    try std.testing.expect((try parseArgs(arena.allocator(), &.{"version"})).command == .version);
}

test "parse config convert" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = try parseArgs(arena.allocator(), &.{ "config", "convert", "--config", "config.json", "--to", "toml", "-o", "config.toml", "--force" });
    const c = p.command.config_convert;
    try std.testing.expectEqualStrings("config.json", c.common.config_path.?);
    try std.testing.expectEqualStrings("toml", c.to.?);
    try std.testing.expectEqualStrings("config.toml", c.output.?);
    try std.testing.expect(c.force);
}

test "parse compose" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = try parseArgs(arena.allocator(), &.{ "compose", "--base", "base.png", "--svg", "mark.svg", "-o", "out.png", "--x", "-4", "--width", "128", "--opacity", "0.5", "--blend", "multiply" });
    const c = p.command.compose;
    try std.testing.expectEqualStrings("base.png", c.base.?);
    try std.testing.expectEqualStrings("mark.svg", c.svg.?);
    try std.testing.expectEqualStrings("out.png", c.output.?);
    try std.testing.expectEqual(@as(i32, -4), c.x);
    try std.testing.expectEqual(@as(u32, 128), c.width.?);
    try std.testing.expectEqual(@as(f32, 0.5), c.opacity);
    try std.testing.expectEqualStrings("multiply", c.blend.?);
}

test "parse svg render and png compose" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const s = (try parseArgs(a, &.{ "svg", "render", "--input", "a.svg", "-o", "a.png", "--height", "300" })).command.svg_render;
    try std.testing.expectEqualStrings("a.svg", s.input.?);
    try std.testing.expectEqualStrings("a.png", s.output.?);
    try std.testing.expectEqual(@as(u32, 300), s.height.?);

    const p = (try parseArgs(a, &.{ "png", "compose", "--base", "base.png", "--layer", "a.png,x=1,y=2,opacity=0.7,blend=screen", "-o", "out.png" })).command.png_compose;
    try std.testing.expectEqualStrings("base.png", p.base.?);
    try std.testing.expectEqualStrings("out.png", p.output.?);
    try std.testing.expectEqual(@as(usize, 1), p.layers.len);
    try std.testing.expectEqualStrings("a.png,x=1,y=2,opacity=0.7,blend=screen", p.layers[0]);
}

test "parse text render" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const t = (try parseArgs(arena.allocator(), &.{ "text", "render", "--text", "A\\nB", "-o", "copy.png", "--width", "900", "--font", "PingFang SC", "--size", "72", "--color", "#fff", "--stroke", "#111", "--stroke-width", "3", "--align", "center", "--line-height", "1.18" })).command.text_render;
    try std.testing.expectEqualStrings("A\\nB", t.text.?);
    try std.testing.expectEqualStrings("copy.png", t.output.?);
    try std.testing.expectEqual(@as(u32, 900), t.width.?);
    try std.testing.expectEqualStrings("PingFang SC", t.font.?);
    try std.testing.expectEqual(@as(u32, 72), t.size);
    try std.testing.expectEqual(@as(f32, 3), t.stroke_width);
    try std.testing.expectEqualStrings("center", t.text_align);
}

test "parse generate supports repeated --image and comma --images" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const p1 = try parseArgs(a, &.{ "generate", "-m", "m", "-p", "hi", "--image", "1.png", "--image", "2.png" });
    const g1 = p1.command.generate;
    try std.testing.expectEqual(@as(usize, 2), g1.images.len);
    try std.testing.expectEqualStrings("1.png", g1.images[0]);
    try std.testing.expectEqualStrings("2.png", g1.images[1]);

    const p2 = try parseArgs(a, &.{ "generate", "-m", "m", "-p", "hi", "--images", "a.png, b.png,c.png" });
    const g2 = p2.command.generate;
    try std.testing.expectEqual(@as(usize, 3), g2.images.len);
    try std.testing.expectEqualStrings("a.png", g2.images[0]);
    try std.testing.expectEqualStrings("b.png", g2.images[1]);
    try std.testing.expectEqualStrings("c.png", g2.images[2]);
}
