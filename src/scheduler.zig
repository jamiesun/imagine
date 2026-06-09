//! Concurrent task scheduler.
//!
//! A `Task` is one image-generation unit already bound to a concrete endpoint.
//! Endpoint assignment (round-robin across a model's endpoints) happens in the
//! command layer; the scheduler just runs up to `concurrency` tasks in
//! parallel. Worker threads share one threadsafe `std.http.Client` and each
//! task owns a private arena, so there is no cross-thread allocator contention.

const std = @import("std");
const types = @import("types.zig");
const backend = @import("backend.zig");
const util = @import("util.zig");

pub const Task = struct {
    // ---- inputs (filled by caller) ----
    model: *const types.ModelConfig,
    endpoint: *const types.Endpoint,
    req: types.ImageRequest,
    /// Final output path (single image) or stem (multiple images), already
    /// tilde-expanded. Multiple images become `<stem>-N.<ext>`.
    output_path: []const u8,
    /// Per-task arena; caller inits before run() and deinits after reading
    /// results. All result memory lives here.
    arena: std.heap.ArenaAllocator,

    // ---- outputs (filled by worker) ----
    written_paths: []const []const u8 = &.{},
    bytes_total: usize = 0,
    err: ?[]const u8 = null,

    pub fn ok(self: *const Task) bool {
        return self.err == null;
    }
};

pub const RunOptions = struct {
    concurrency: usize,
    io: std.Io,
    client: *std.http.Client,
    /// Print one progress line per finished task to stderr.
    progress: bool = true,
};

const Context = struct {
    tasks: []Task,
    next: std.atomic.Value(usize),
    opts: RunOptions,
};

/// Run all tasks, blocking until complete. Results are written back into each
/// task. Never fails as a whole: per-task failures are recorded in `task.err`.
pub fn run(tasks: []Task, opts: RunOptions) void {
    if (tasks.len == 0) return;

    var ctx = Context{
        .tasks = tasks,
        .next = std.atomic.Value(usize).init(0),
        .opts = opts,
    };

    const want = @max(@as(usize, 1), @min(opts.concurrency, tasks.len));

    // Single worker: run inline, no thread spawn overhead.
    if (want == 1) {
        workerLoop(&ctx);
        return;
    }

    var threads: [64]std.Thread = undefined;
    const spawn_count = @min(want, threads.len);
    var spawned: usize = 0;
    while (spawned < spawn_count) : (spawned += 1) {
        threads[spawned] = std.Thread.spawn(.{}, workerLoop, .{&ctx}) catch break;
    }

    // If we could not spawn any thread, fall back to inline execution.
    if (spawned == 0) {
        workerLoop(&ctx);
        return;
    }

    // The current thread also participates, then we join the rest.
    workerLoop(&ctx);
    for (threads[0..spawned]) |t| t.join();
}

fn workerLoop(ctx: *Context) void {
    while (true) {
        const i = ctx.next.fetchAdd(1, .monotonic);
        if (i >= ctx.tasks.len) break;
        processTask(ctx, &ctx.tasks[i], i);
    }
}

fn processTask(ctx: *Context, task: *Task, index: usize) void {
    const a = task.arena.allocator();

    const result = backend.generate(ctx.opts.client, a, task.model, task.endpoint, task.req) catch |e| {
        task.err = std.fmt.allocPrint(a, "out of memory: {s}", .{@errorName(e)}) catch "out of memory";
        report(ctx, task, index);
        return;
    };

    if (!result.ok()) {
        task.err = result.err;
        report(ctx, task, index);
        return;
    }

    writeImages(ctx.opts.io, a, task, result.images) catch |e| {
        task.err = std.fmt.allocPrint(a, "failed to write image: {s}", .{@errorName(e)}) catch "write error";
        report(ctx, task, index);
        return;
    };

    report(ctx, task, index);
}

fn writeImages(io: std.Io, a: std.mem.Allocator, task: *Task, images: [][]u8) !void {
    const paths = try a.alloc([]const u8, images.len);
    var total: usize = 0;
    const cwd = std.Io.Dir.cwd();
    for (images, 0..) |img, i| {
        const path = if (images.len == 1)
            task.output_path
        else
            try util.numberedPath(a, task.output_path, i + 1);

        try util.ensureParentDir(io, cwd, path);
        try cwd.writeFile(io, .{ .sub_path = path, .data = img });
        paths[i] = path;
        total += img.len;
    }
    task.written_paths = paths;
    task.bytes_total = total;
}

fn report(ctx: *Context, task: *Task, index: usize) void {
    if (!ctx.opts.progress) return;
    // std.debug.print locks stderr internally, so concurrent task lines never
    // interleave.
    const n = ctx.tasks.len;
    if (task.ok()) {
        const path = if (task.written_paths.len > 0) task.written_paths[0] else task.output_path;
        std.debug.print("[{d}/{d}] ok   {s} -> {s} ({d} bytes)\n", .{ index + 1, n, task.model.name, path, task.bytes_total });
    } else {
        std.debug.print("[{d}/{d}] FAIL {s}: {s}\n", .{ index + 1, n, task.model.name, task.err.? });
    }
}
