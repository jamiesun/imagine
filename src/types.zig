//! Shared core types for the imagine CLI.
//!
//! These types form the decoupling seam between the frontend (CLI parsing and
//! unified parameters) and the backends (per-provider request construction).
//! Nothing here imports a backend or the HTTP layer, so the types can be reused
//! and unit-tested in isolation.

const std = @import("std");

/// How an endpoint authenticates. Azure AI Foundry accepts both a bearer token
/// and an `api-key` header; Google's APIs take their key in `x-goog-api-key`;
/// `none` covers self-hosted endpoints (a local model server) that take no
/// credential at all.
pub const AuthScheme = enum {
    bearer,
    api_key,
    /// `x-goog-api-key: <key>` (Google AI Studio / Gemini API keys).
    google_api_key,
    /// `Authorization: Token <key>` (Vidu).
    token,
    /// HMAC-SHA256 JWT. `api_key` is the issuer (Kling access key); `api_secret`
    /// signs it. The header sent is still `Authorization: Bearer <jwt>`.
    jwt_hs256,
    /// Mint a bearer token from the GCE metadata server at request time.
    /// No static key is stored. This is billable Google Cloud access.
    google_metadata,
    none,

    pub fn fromString(s: []const u8) ?AuthScheme {
        if (std.mem.eql(u8, s, "bearer")) return .bearer;
        if (std.mem.eql(u8, s, "api-key") or std.mem.eql(u8, s, "api_key")) return .api_key;
        if (std.mem.eql(u8, s, "google_api_key") or std.mem.eql(u8, s, "google-api-key") or
            std.mem.eql(u8, s, "google") or std.mem.eql(u8, s, "gemini") or
            std.mem.eql(u8, s, "x-goog-api-key")) return .google_api_key;
        if (std.mem.eql(u8, s, "token")) return .token;
        if (std.mem.eql(u8, s, "jwt_hs256") or std.mem.eql(u8, s, "jwt-hs256") or
            std.mem.eql(u8, s, "kling_jwt")) return .jwt_hs256;
        if (std.mem.eql(u8, s, "google_metadata") or std.mem.eql(u8, s, "google-metadata") or
            std.mem.eql(u8, s, "metadata")) return .google_metadata;
        if (std.mem.eql(u8, s, "none")) return .none;
        return null;
    }

    /// Name of the header carrying the credential. Never called for `.none`,
    /// which sends no credential header at all.
    pub fn headerName(self: AuthScheme) []const u8 {
        return switch (self) {
            .bearer, .token, .jwt_hs256, .google_metadata => "Authorization",
            .api_key => "api-key",
            .google_api_key => "x-goog-api-key",
            .none => "",
        };
    }

    pub fn toString(self: AuthScheme) []const u8 {
        return switch (self) {
            .bearer => "bearer",
            .api_key => "api-key",
            .google_api_key => "google_api_key",
            .token => "token",
            .jwt_hs256 => "jwt_hs256",
            .google_metadata => "google_metadata",
            .none => "none",
        };
    }

    /// True when a resolved static key is enough to call the endpoint.
    /// `jwt_hs256` also needs `resolved_secret`. `google_metadata` and `none`
    /// do not read a key at config-load time.
    pub fn needsStaticKey(self: AuthScheme) bool {
        return switch (self) {
            .none, .google_metadata => false,
            else => true,
        };
    }
};

/// What a backend produces. The unified request covers both; only the output
/// naming (extension, `--json` key) and the progress wording differ.
pub const Media = enum {
    image,
    video,
    audio,

    pub fn toString(self: Media) []const u8 {
        return switch (self) {
            .image => "image",
            .video => "video",
            .audio => "audio",
        };
    }

    /// Output format used when the caller passed neither `--format` nor a model
    /// default. Providers always return these container formats, so the choice
    /// is only about the file name we write them to.
    pub fn defaultFormat(self: Media) []const u8 {
        return switch (self) {
            .image => "png",
            .video => "mp4",
            .audio => "wav",
        };
    }
};

/// Role of one `--image` / `--first-frame` / `--last-frame` / `--ref-image`.
/// `auto` keeps the historical `--image` meaning: first frame on video, a
/// reference on image backends. Explicit roles are never guessed from order.
pub const ImageRole = enum {
    auto,
    first_frame,
    last_frame,
    reference,

    pub fn toString(self: ImageRole) []const u8 {
        return switch (self) {
            .auto => "auto",
            .first_frame => "first_frame",
            .last_frame => "last_frame",
            .reference => "reference",
        };
    }
};

/// What a TTS model can actually do. Backend defaults describe the protocol,
/// not a promise that every model id behind it is entitled or identical.
pub const AlignmentLevel = enum {
    unsupported,
    ssml_mark,
    word,

    pub fn toString(self: AlignmentLevel) []const u8 {
        return switch (self) {
            .unsupported => "unsupported",
            .ssml_mark => "ssml_mark",
            .word => "word",
        };
    }
};

pub const SpeechMode = enum {
    speech,
    voice_design,
    voice_clone,
    dialogue,

    pub fn toString(self: SpeechMode) []const u8 {
        return switch (self) {
            .speech => "speech",
            .voice_design => "voice_design",
            .voice_clone => "voice_clone",
            .dialogue => "dialogue",
        };
    }

    pub fn fromString(s: []const u8) ?SpeechMode {
        if (std.mem.eql(u8, s, "speech") or std.mem.eql(u8, s, "tts")) return .speech;
        if (std.mem.eql(u8, s, "voice_design") or std.mem.eql(u8, s, "voice-design")) return .voice_design;
        if (std.mem.eql(u8, s, "voice_clone") or std.mem.eql(u8, s, "voice-clone")) return .voice_clone;
        if (std.mem.eql(u8, s, "dialogue")) return .dialogue;
        return null;
    }
};

pub const StreamChoice = enum {
    off,
    /// Reject before any generation request when the model is not incremental.
    on,
    /// Use incremental streaming only when the model says it supports it.
    auto,

    pub fn fromString(s: []const u8) ?StreamChoice {
        if (std.mem.eql(u8, s, "on") or std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "1")) return .on;
        if (std.mem.eql(u8, s, "off") or std.mem.eql(u8, s, "false") or std.mem.eql(u8, s, "0")) return .off;
        if (std.mem.eql(u8, s, "auto")) return .auto;
        return null;
    }
};

pub const Capabilities = struct {
    first_frame: bool = false,
    last_frame: bool = false,
    max_auto_images: usize = 0,
    max_ref_images: usize = 0,
    /// Total images of every role. 0 means no image input.
    max_images: usize = 0,
    speech: bool = false,
    voice_design: bool = false,
    voice_clone: bool = false,
    native_dialogue: bool = false,
    max_speakers: u32 = 1,
    ssml: bool = false,
    style: bool = false,
    speed: bool = false,
    pitch: bool = false,
    /// True incremental audio. "Generate everything, then chunk the body" is false.
    streaming: bool = false,
    alignment: AlignmentLevel = .unsupported,
    /// UTF-8 code points. 0 means imagine does not split; the provider enforces its own limit.
    max_chars: u32 = 0,
    voice_list: bool = false,
    /// Empty: this backend does not constrain `--format` here (image/video keep their own rules).
    formats: []const []const u8 = &.{},
};

/// How a backend's wire protocol is driven. `sync` finishes inside one request;
/// `async_task` needs a create call plus status polling (video generation).
pub const Flow = enum {
    sync,
    async_task,
};

/// How images from the repeatable `--image` flag reach a provider.
pub const InputImageStyle = enum {
    /// Accepts a URL as-is, and a base64 `data:` URL for local files.
    url_or_data_url,
    /// Needs image bytes plus a MIME type; URL inputs are fetched before the
    /// backend builds its provider-specific inline representation.
    bytes_base64,
    /// Takes no image at all: sending any would be silently dropped, so the CLI
    /// rejects `--image` for these backends instead.
    unsupported,
};

/// Identifies which backend module builds a request body for a model. Adding a
/// new provider means adding a variant here and a module under `backends/`.
/// Logical model names are never hardcoded — they come from config (the one
/// exception is the convenience preset catalog in `presets.zig`).
///
/// Routing metadata (media kind, flow, credential env, download auth, image
/// input shape and limit) lives on this enum because every module already
/// depends on `types.zig`; the wire
/// formats themselves live in `backends/*`.
pub const BackendKind = enum {
    /// OpenAI-compatible `images/generations` (Azure OpenAI, OpenAI, etc.).
    openai_image,
    /// Azure-hosted Black Forest Labs FLUX (width/height body).
    azure_flux,
    /// Qwen-Image text-to-image and multi-reference editing (`QwenImage21Pipeline`)
    /// served locally over an OpenAI-compatible `images/generations` endpoint.
    /// See `integrations/qwen-image`.
    qwen_image,
    /// Volcengine Ark video generation (Seedance): create task, poll, download.
    seedance,
    /// Volcengine Ark image generation (Seedream), OpenAI-style sync response.
    volcengine_image,
    /// Google Gemini video generation through the Interactions API (Gemini
    /// Omni): an interaction yields a Files reference that is polled and then
    /// downloaded. Veo is a different protocol (`generateContent` +
    /// `:predictLongRunning`) and deliberately has no alias here.
    gemini_video,
    /// Self-hosted LTX-2 service using imagine's documented async video contract.
    ltx2_video,
    /// Microsoft AI image generation & multi-reference editing (Azure Foundry).
    mai_image,
    /// Alibaba Model Studio Wan image (multimodal-generation, sync or async).
    dashscope_image,
    /// Alibaba Model Studio Wan video (video-synthesis, async task).
    dashscope_video,
    /// Vidu video: text, image, start-end, or reference-to-video.
    vidu_video,
    /// Kling text-to-video / image-to-video (v1 task API, JWT or bearer).
    kling_video,
    /// MiniMax video generation (create, query, file retrieve).
    minimax_video,
    /// SiliconFlow image generation. Response is not assumed to be OpenAI-shaped.
    siliconflow_image,
    /// Self-hosted TTS speaking imagine's documented `tts_http` contract.
    tts_http,
    /// Google Cloud Text-to-Speech REST (`text:synthesize`), not Gemini.
    google_cloud_tts,
    /// Gemini speech generation via the Interactions API, not `gemini_video`.
    gemini_tts,

    pub fn fromString(s: []const u8) ?BackendKind {
        // openai_image is canonical; azure_image is kept as a legacy alias.
        if (std.mem.eql(u8, s, "openai_image") or std.mem.eql(u8, s, "openai-image") or
            std.mem.eql(u8, s, "azure_image") or std.mem.eql(u8, s, "azure-image"))
            return .openai_image;
        if (std.mem.eql(u8, s, "azure_flux") or std.mem.eql(u8, s, "azure-flux")) return .azure_flux;
        // Version-agnostic aliases: `-m`/api_model pick the concrete checkpoint.
        if (std.mem.eql(u8, s, "qwen_image") or std.mem.eql(u8, s, "qwen-image") or
            std.mem.eql(u8, s, "qwen")) return .qwen_image;
        if (std.mem.eql(u8, s, "seedance") or std.mem.eql(u8, s, "ark_video") or
            std.mem.eql(u8, s, "ark-video") or std.mem.eql(u8, s, "volcengine_video"))
            return .seedance;
        if (std.mem.eql(u8, s, "volcengine_image") or std.mem.eql(u8, s, "volcengine-image") or
            std.mem.eql(u8, s, "seedream") or std.mem.eql(u8, s, "ark_image"))
            return .volcengine_image;
        if (std.mem.eql(u8, s, "gemini_video") or std.mem.eql(u8, s, "gemini-video") or
            std.mem.eql(u8, s, "gemini_omni") or std.mem.eql(u8, s, "gemini-omni"))
            return .gemini_video;
        if (std.mem.eql(u8, s, "ltx2_video") or std.mem.eql(u8, s, "ltx2-video") or
            std.mem.eql(u8, s, "ltx_video") or std.mem.eql(u8, s, "ltx-2") or
            std.mem.eql(u8, s, "ltx2")) return .ltx2_video;
        if (std.mem.eql(u8, s, "mai_image") or std.mem.eql(u8, s, "mai-image") or
            std.mem.eql(u8, s, "mai")) return .mai_image;
        if (std.mem.eql(u8, s, "dashscope_image") or std.mem.eql(u8, s, "dashscope-image") or
            std.mem.eql(u8, s, "wan_image") or std.mem.eql(u8, s, "wan-image"))
            return .dashscope_image;
        if (std.mem.eql(u8, s, "dashscope_video") or std.mem.eql(u8, s, "dashscope-video") or
            std.mem.eql(u8, s, "wan_video") or std.mem.eql(u8, s, "wan-video"))
            return .dashscope_video;
        if (std.mem.eql(u8, s, "vidu_video") or std.mem.eql(u8, s, "vidu-video") or
            std.mem.eql(u8, s, "vidu")) return .vidu_video;
        if (std.mem.eql(u8, s, "kling_video") or std.mem.eql(u8, s, "kling-video") or
            std.mem.eql(u8, s, "kling")) return .kling_video;
        if (std.mem.eql(u8, s, "minimax_video") or std.mem.eql(u8, s, "minimax-video") or
            std.mem.eql(u8, s, "minimax") or std.mem.eql(u8, s, "hailuo"))
            return .minimax_video;
        if (std.mem.eql(u8, s, "siliconflow_image") or std.mem.eql(u8, s, "siliconflow-image") or
            std.mem.eql(u8, s, "siliconflow")) return .siliconflow_image;
        if (std.mem.eql(u8, s, "tts_http") or std.mem.eql(u8, s, "tts-http")) return .tts_http;
        if (std.mem.eql(u8, s, "google_cloud_tts") or std.mem.eql(u8, s, "google-cloud-tts"))
            return .google_cloud_tts;
        if (std.mem.eql(u8, s, "gemini_tts") or std.mem.eql(u8, s, "gemini-tts")) return .gemini_tts;
        return null;
    }

    pub fn toString(self: BackendKind) []const u8 {
        return switch (self) {
            .openai_image => "openai_image",
            .azure_flux => "azure_flux",
            .qwen_image => "qwen_image",
            .seedance => "seedance",
            .volcengine_image => "volcengine_image",
            .gemini_video => "gemini_video",
            .ltx2_video => "ltx2_video",
            .mai_image => "mai_image",
            .dashscope_image => "dashscope_image",
            .dashscope_video => "dashscope_video",
            .vidu_video => "vidu_video",
            .kling_video => "kling_video",
            .minimax_video => "minimax_video",
            .siliconflow_image => "siliconflow_image",
            .tts_http => "tts_http",
            .google_cloud_tts => "google_cloud_tts",
            .gemini_tts => "gemini_tts",
        };
    }

    pub fn media(self: BackendKind) Media {
        return switch (self) {
            .seedance, .gemini_video, .ltx2_video, .dashscope_video, .vidu_video, .kling_video, .minimax_video => .video,
            .tts_http, .google_cloud_tts, .gemini_tts => .audio,
            else => .image,
        };
    }

    pub fn flow(self: BackendKind) Flow {
        return switch (self) {
            .seedance, .gemini_video, .ltx2_video, .dashscope_image, .dashscope_video, .vidu_video, .kling_video, .minimax_video => .async_task,
            else => .sync,
        };
    }

    /// Canonical environment variable holding this provider's API key. Used by
    /// ephemeral mode when `IMAGINE_API_KEY_ENV` does not name one.
    pub fn defaultKeyEnv(self: BackendKind) []const u8 {
        return switch (self) {
            .seedance, .volcengine_image => "ARK_API_KEY",
            .gemini_video, .gemini_tts => "GEMINI_API_KEY",
            .ltx2_video => "LTX2_API_KEY",
            .dashscope_image, .dashscope_video => "DASHSCOPE_API_KEY",
            .vidu_video => "VIDU_API_KEY",
            .kling_video => "KLING_ACCESS_KEY",
            .minimax_video => "MINIMAX_API_KEY",
            .siliconflow_image => "SILICONFLOW_API_KEY",
            .google_cloud_tts => "GOOGLE_CLOUD_TTS_TOKEN",
            .tts_http => "TTS_API_KEY",
            else => "AZURE_OPENAI_APIKEY",
        };
    }

    /// Second credential for backends that sign a request (Kling access key + secret).
    pub fn defaultSecretEnv(self: BackendKind) ?[]const u8 {
        return switch (self) {
            .kling_video => "KLING_SECRET_KEY",
            else => null,
        };
    }

    /// True when the produced asset URL must be fetched with the same credential
    /// as the create call (Gemini Files API). Provider CDN URLs (Ark, Azure) are
    /// pre-signed and reject a request that also carries an auth header.
    pub fn assetNeedsAuth(self: BackendKind) bool {
        return switch (self) {
            .gemini_video => true,
            else => false,
        };
    }

    pub fn inputImageStyle(self: BackendKind) InputImageStyle {
        return switch (self) {
            .gemini_video, .ltx2_video, .qwen_image, .mai_image => .bytes_base64,
            .seedance, .volcengine_image, .dashscope_image, .dashscope_video, .vidu_video, .kling_video, .minimax_video, .siliconflow_image => .url_or_data_url,
            .openai_image, .azure_flux, .tts_http, .google_cloud_tts, .gemini_tts => .unsupported,
        };
    }

    /// Maximum number of `--image` (role `auto`) inputs. Role-specific limits
    /// live on `capabilities()`.
    pub fn maxInputImages(self: BackendKind) usize {
        return self.capabilities().max_auto_images;
    }

    pub fn capabilities(self: BackendKind) Capabilities {
        return switch (self) {
            .openai_image, .azure_flux => .{},
            .qwen_image => .{ .max_auto_images = 10, .max_ref_images = 10, .max_images = 10 },
            .mai_image => .{ .max_auto_images = 5, .max_ref_images = 5, .max_images = 5 },
            .volcengine_image => .{ .max_auto_images = 1, .max_ref_images = 1, .max_images = 1 },
            .siliconflow_image => .{ .max_auto_images = 1, .max_ref_images = 1, .max_images = 1 },
            // Wan image: 0–9 reference images on the multimodal generation API
            // (verified 2026-10-20 against the Wan image generation and editing reference).
            .dashscope_image => .{ .max_auto_images = 9, .max_ref_images = 9, .max_images = 9 },
            .seedance, .gemini_video, .ltx2_video => .{
                .first_frame = true,
                .max_auto_images = 1,
                .max_images = 1,
            },
            // Wan video: first frame and first+last. Reference video/audio is a
            // different media type and is not accepted as --image.
            .dashscope_video => .{
                .first_frame = true,
                .last_frame = true,
                .max_auto_images = 1,
                .max_images = 2,
            },
            .vidu_video => .{
                .first_frame = true,
                .last_frame = true,
                .max_auto_images = 1,
                .max_ref_images = 7,
                .max_images = 7,
            },
            .kling_video => .{
                .first_frame = true,
                .last_frame = true,
                .max_auto_images = 1,
                .max_images = 2,
            },
            .minimax_video => .{
                .first_frame = true,
                .last_frame = true,
                .max_auto_images = 1,
                .max_ref_images = 1,
                .max_images = 3,
            },
            // Protocol ceiling. A live server's /capabilities response can only
            // narrow this; it is fetched before a generation POST.
            .tts_http => .{
                .speech = true,
                .voice_design = true,
                .voice_clone = true,
                .native_dialogue = false,
                .max_speakers = 1,
                .style = true,
                .streaming = true,
                .voice_list = true,
                .formats = &.{ "wav", "pcm" },
            },
            // Cloud Text-to-Speech sync synthesize is 5000 characters.
            // Bidirectional gRPC streaming is a different API and is not this backend.
            .google_cloud_tts => .{
                .speech = true,
                .ssml = true,
                .speed = true,
                .pitch = true,
                .streaming = false,
                .alignment = .ssml_mark,
                .max_chars = 5000,
                .voice_list = true,
                .formats = &.{ "mp3", "wav", "pcm", "ogg" },
            },
            // Interactions speech API: single voice, or up to two speakers.
            // Not Gemini Live, and not a word-level aligner.
            .gemini_tts => .{
                .speech = true,
                .style = true,
                .native_dialogue = true,
                .max_speakers = 2,
                .streaming = false,
                .voice_list = false,
                .formats = &.{ "wav", "pcm" },
            },
        };
    }
};

/// A single concrete API target for a model: one URL plus one credential. A
/// model owns a slice of these, which is what enables concurrent scheduling of
/// the same logical model across several keys/regions.
pub const Endpoint = struct {
    base_url: []const u8,
    /// Inline key (discouraged but supported). Takes precedence when present.
    api_key: ?[]const u8 = null,
    /// Environment variable to read the key from.
    api_key_env: ?[]const u8 = null,
    /// Kling signing secret, or any future second credential. Not a bearer token.
    api_secret: ?[]const u8 = null,
    api_secret_env: ?[]const u8 = null,
    auth: AuthScheme = .bearer,
    /// Resolved credential, filled in by config loading. Never serialized.
    resolved_key: ?[]const u8 = null,
    resolved_secret: ?[]const u8 = null,
};

/// Per-model defaults that fill in any frontend parameter the caller omitted.
pub const ModelDefaults = struct {
    size: ?[]const u8 = null,
    width: ?u32 = null,
    height: ?u32 = null,
    output_format: ?[]const u8 = null,
    output_compression: ?u32 = null,
    quality: ?[]const u8 = null,
    /// Denoising steps for diffusion backends (`qwen_image`).
    steps: ?u32 = null,
    // ---- video ----
    /// Clip length in seconds (video backends).
    duration: ?u32 = null,
    /// Resolution token such as `720p` / `1080p` (video backends).
    resolution: ?[]const u8 = null,
    /// Aspect-ratio token such as `16:9` (video backends).
    ratio: ?[]const u8 = null,
    /// Provider watermark (`volcengine_image` / `seedance`).
    watermark: ?bool = null,
};

/// A logical model the user can route to by name. Maps to exactly one backend
/// and one or more endpoints.
pub const ModelConfig = struct {
    name: []const u8,
    backend: BackendKind,
    /// The `model` value sent in the request body. Defaults to `name`.
    api_model: []const u8,
    endpoints: []Endpoint,
    defaults: ModelDefaults = .{},
};

/// One input/reference image for image-to-video or image editing. `source` is
/// what the caller typed (URL or path); `bytes` is filled in when the file had
/// to be read, either because the source is a local path or because the backend
/// only accepts raw bytes.
pub const InputImage = struct {
    source: []const u8,
    bytes: ?[]const u8 = null,
    mime: []const u8 = "image/png",
    role: ImageRole = .auto,
};

/// One local or remote audio file used as a voice-clone reference.
pub const AudioInput = struct {
    source: []const u8,
    bytes: ?[]const u8 = null,
    mime: []const u8 = "audio/wav",
};

pub const DialogueTurn = struct {
    speaker: []const u8,
    text: []const u8,
    voice: ?[]const u8 = null,
    style: ?[]const u8 = null,
    language: ?[]const u8 = null,
};

/// TTS fields that do not fit the image/video request. Absent on image and
/// video calls. Qwen-specific wire names stay in the tts_http server, not here.
pub const AudioParams = struct {
    mode: SpeechMode = .speech,
    ssml: bool = false,
    voice: ?[]const u8 = null,
    language: ?[]const u8 = null,
    style: ?[]const u8 = null,
    speed: ?f32 = null,
    pitch: ?f32 = null,
    sample_rate: ?u32 = null,
    reference: ?AudioInput = null,
    reference_text: ?[]const u8 = null,
    dialogue: []const DialogueTurn = &.{},
    stream: StreamChoice = .off,
    /// Set by the CLI after capability checks. The backend streams only when this is true.
    stream_applied: bool = false,
};

/// Unified frontend request. Backends translate this into provider-specific
/// JSON. Width/height and `size` are both accepted; backends use whichever the
/// provider understands and derive one from the other when needed.
pub const GenRequest = struct {
    prompt: []const u8,
    /// Model value sent to the provider API (already resolved from api_model).
    api_model: []const u8,
    size: ?[]const u8 = null,
    width: ?u32 = null,
    height: ?u32 = null,
    /// Assets requested for this single API call. The scheduler expands the
    /// user's -n into separate tasks, so this is normally 1.
    n: u32 = 1,
    output_format: ?[]const u8 = null,
    output_compression: ?u32 = null,
    quality: ?[]const u8 = null,
    seed: ?i64 = null,
    /// Denoising steps; only diffusion backends (`qwen_image`) send this.
    steps: ?u32 = null,
    // ---- video ----
    /// Clip length in seconds.
    duration: ?u32 = null,
    /// Resolution token such as `720p` / `1080p`.
    resolution: ?[]const u8 = null,
    /// Aspect-ratio token such as `16:9`.
    ratio: ?[]const u8 = null,
    /// Input/reference images. Most backends accept at most one; Qwen accepts ten; MAI accepts five.
    images: []const InputImage = &.{},
    /// Provider watermark. Ark defaults it to *on* for images and *off* for
    /// video, so this is only sent when the caller decides.
    watermark: ?bool = null,
    /// Set for audio backends. Image and video requests leave this null.
    audio: ?AudioParams = null,

    /// Apply model defaults for any field the caller left null.
    pub fn applyDefaults(self: *GenRequest, d: ModelDefaults) void {
        if (self.size == null) self.size = d.size;
        if (self.width == null) self.width = d.width;
        if (self.height == null) self.height = d.height;
        if (self.output_format == null) self.output_format = d.output_format;
        if (self.output_compression == null) self.output_compression = d.output_compression;
        if (self.quality == null) self.quality = d.quality;
        if (self.steps == null) self.steps = d.steps;
        if (self.duration == null) self.duration = d.duration;
        if (self.resolution == null) self.resolution = d.resolution;
        if (self.ratio == null) self.ratio = d.ratio;
        if (self.watermark == null) self.watermark = d.watermark;
    }
};

/// Decoded result of a single asset from a provider response. Either raw bytes
/// (decoded from base64) or a URL the caller must still download.
pub const Payload = union(enum) {
    bytes: []u8,
    url: []const u8,
    /// GET `url` with the API credential. The JSON body has a CDN URL at
    /// `field` (one dot, e.g. `file.download_url`) which is then downloaded
    /// *without* that credential.
    relay: struct { url: []const u8, field: []const u8 },
};

/// Metadata known because the provider said so. Missing fields stay null;
/// imagine does not invent duration or timestamps.
pub const AudioMeta = struct {
    mime: ?[]const u8 = null,
    container: ?[]const u8 = null,
    codec: ?[]const u8 = null,
    sample_rate_hz: ?u32 = null,
    channels: ?u32 = null,
    duration_ms: ?u64 = null,
    voice: ?[]const u8 = null,
    /// JSON document for a sibling `*.alignment.json`, or null when there is none.
    alignment_json: ?[]const u8 = null,
    /// `unsupported` when this provider does not return timings. Null when an
    /// alignment file was written, or when the call was not audio.
    alignment: ?[]const u8 = null,
    stream_applied: ?bool = null,
    /// Provider-reported credit count. Not a currency amount.
    usage_credits: ?i64 = null,
};

/// Parse a "WxH" string (e.g. "1024x1024") into width/height.
pub fn parseSize(s: []const u8) ?struct { w: u32, h: u32 } {
    const idx = std.mem.indexOfScalar(u8, s, 'x') orelse
        std.mem.indexOfScalar(u8, s, 'X') orelse return null;
    const w = std.fmt.parseInt(u32, s[0..idx], 10) catch return null;
    const h = std.fmt.parseInt(u32, s[idx + 1 ..], 10) catch return null;
    return .{ .w = w, .h = h };
}

test "parseSize" {
    const r = parseSize("1024x768").?;
    try std.testing.expectEqual(@as(u32, 1024), r.w);
    try std.testing.expectEqual(@as(u32, 768), r.h);
    try std.testing.expect(parseSize("nope") == null);
}

test "AuthScheme/BackendKind round trips" {
    try std.testing.expectEqual(AuthScheme.bearer, AuthScheme.fromString("bearer").?);
    try std.testing.expectEqual(AuthScheme.api_key, AuthScheme.fromString("api-key").?);
    try std.testing.expectEqual(AuthScheme.google_api_key, AuthScheme.fromString("google").?);
    try std.testing.expectEqualStrings("x-goog-api-key", AuthScheme.google_api_key.headerName());
    try std.testing.expectEqual(AuthScheme.none, AuthScheme.fromString("none").?);
    try std.testing.expectEqual(AuthScheme.token, AuthScheme.fromString("token").?);
    try std.testing.expectEqual(AuthScheme.jwt_hs256, AuthScheme.fromString("kling_jwt").?);
    try std.testing.expectEqual(AuthScheme.google_metadata, AuthScheme.fromString("metadata").?);
    try std.testing.expect(BackendKind.fromString("dashscope_video") != null);
    try std.testing.expectEqual(BackendKind.gemini_tts, BackendKind.fromString("gemini-tts").?);
    try std.testing.expectEqual(BackendKind.google_cloud_tts, BackendKind.fromString("google_cloud_tts").?);
    try std.testing.expectEqual(Media.audio, BackendKind.tts_http.media());
    try std.testing.expectEqualStrings("wav", Media.audio.defaultFormat());
    try std.testing.expect(!BackendKind.google_cloud_tts.capabilities().streaming);
    try std.testing.expect(BackendKind.gemini_tts.capabilities().native_dialogue);
    try std.testing.expectEqual(@as(u32, 2), BackendKind.gemini_tts.capabilities().max_speakers);
    try std.testing.expectEqual(@as(usize, 9), BackendKind.dashscope_image.maxInputImages());
    try std.testing.expectEqual(BackendKind.openai_image, BackendKind.fromString("openai_image").?);
    try std.testing.expectEqual(BackendKind.openai_image, BackendKind.fromString("azure_image").?);
    try std.testing.expectEqual(BackendKind.azure_flux, BackendKind.fromString("azure-flux").?);
    try std.testing.expectEqual(BackendKind.qwen_image, BackendKind.fromString("qwen_image").?);
    try std.testing.expectEqual(BackendKind.qwen_image, BackendKind.fromString("qwen-image").?);
    try std.testing.expectEqual(BackendKind.seedance, BackendKind.fromString("seedance").?);
    try std.testing.expectEqual(BackendKind.volcengine_image, BackendKind.fromString("seedream").?);
    try std.testing.expectEqual(BackendKind.gemini_video, BackendKind.fromString("gemini_omni").?);
    try std.testing.expectEqual(BackendKind.ltx2_video, BackendKind.fromString("ltx-2").?);
    // Veo speaks a different protocol, so it must not resolve to this backend.
    try std.testing.expect(BackendKind.fromString("veo") == null);
}

test "backend routing metadata" {
    try std.testing.expectEqual(Media.video, BackendKind.seedance.media());
    try std.testing.expectEqual(Media.video, BackendKind.gemini_video.media());
    try std.testing.expectEqual(Media.video, BackendKind.ltx2_video.media());
    try std.testing.expectEqual(Media.image, BackendKind.volcengine_image.media());
    try std.testing.expectEqual(Flow.async_task, BackendKind.seedance.flow());
    try std.testing.expectEqual(Flow.async_task, BackendKind.gemini_video.flow());
    try std.testing.expectEqual(Flow.async_task, BackendKind.ltx2_video.flow());
    try std.testing.expectEqual(Flow.sync, BackendKind.volcengine_image.flow());
    try std.testing.expectEqualStrings("mp4", Media.video.defaultFormat());
    try std.testing.expectEqualStrings("png", Media.image.defaultFormat());
    try std.testing.expectEqualStrings("ARK_API_KEY", BackendKind.seedance.defaultKeyEnv());
    try std.testing.expectEqualStrings("GEMINI_API_KEY", BackendKind.gemini_video.defaultKeyEnv());
    try std.testing.expectEqualStrings("LTX2_API_KEY", BackendKind.ltx2_video.defaultKeyEnv());
    try std.testing.expectEqualStrings("AZURE_OPENAI_APIKEY", BackendKind.openai_image.defaultKeyEnv());
    try std.testing.expect(BackendKind.gemini_video.assetNeedsAuth());
    try std.testing.expect(!BackendKind.seedance.assetNeedsAuth());
    try std.testing.expectEqual(InputImageStyle.bytes_base64, BackendKind.gemini_video.inputImageStyle());
    try std.testing.expectEqual(InputImageStyle.bytes_base64, BackendKind.ltx2_video.inputImageStyle());
    try std.testing.expectEqual(InputImageStyle.bytes_base64, BackendKind.qwen_image.inputImageStyle());
    try std.testing.expectEqual(InputImageStyle.url_or_data_url, BackendKind.seedance.inputImageStyle());
    try std.testing.expectEqual(InputImageStyle.unsupported, BackendKind.openai_image.inputImageStyle());
    try std.testing.expectEqual(InputImageStyle.unsupported, BackendKind.azure_flux.inputImageStyle());
    try std.testing.expectEqual(@as(usize, 10), BackendKind.qwen_image.maxInputImages());
    try std.testing.expectEqual(@as(usize, 1), BackendKind.volcengine_image.maxInputImages());
    try std.testing.expectEqual(@as(usize, 0), BackendKind.openai_image.maxInputImages());
}
