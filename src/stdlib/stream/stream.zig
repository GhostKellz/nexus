const std = @import("std");
const fs = @import("../fs/file.zig");

const Io = std.Io;

/// Stream events
pub const StreamEvent = enum {
    data,
    end,
    @"error",
    close,
};

/// Stream callback.
///
/// `context` is the opaque pointer bound when the callback was registered; it
/// lets every stream instance carry its own state instead of smuggling it
/// through shared function-local `var` statics (which are process-global and
/// therefore neither instance-safe nor reentrant). `data` is the chunk, or
/// null to signal end-of-stream.
pub const StreamCallback = *const fn (context: ?*anyopaque, data: ?[]const u8) anyerror!void;

/// Default high-water mark. Once this many unconsumed bytes are buffered, the
/// stream reports backpressure — `push`/`write` return `false` — so a
/// cooperating producer stops until the buffer drains. It bounds the memory a
/// producer can force a stream to hold while no consumer is keeping up.
pub const default_high_water_mark = 16 * 1024;

// Stream contract (applies to Readable, Writable, and Transform):
//
//   * Buffering: bytes with no ready consumer are retained in an owned buffer,
//     never dropped. Pausing a readable buffers rather than discards.
//   * Backpressure: `push`/`write` return `true` while the buffer stays below
//     `high_water_mark` and `false` once it reaches it. A cooperating producer
//     treats `false` as "stop and wait". (The in-memory file sink flushes at
//     `end`, so a piped in-memory pair cannot mid-stream-drain; backpressure is
//     surfaced to direct producers via the return value.)
//   * pause/resume: while paused a readable buffers pushed data; `unpause`
//     flushes the buffer to the consumer in order, then resumes live delivery.
//   * Ordering: zero or more `data` deliveries, then at most one of `end`
//     (all data consumed) or `error`, then at most one `close`. `end` flushes
//     any buffered data first, so `end` never precedes buffered `data`.
//   * error: `emitError` delivers the error name to `on_error` (if set) and
//     then closes the stream. No further events fire after close.
//   * cancellation: `close` fires `on_close` once, drops any buffered data, and
//     is idempotent. After close, `push`/`write` fail with `error.StreamClosed`.
//   * ownership: each stream owns its buffer and any bound context (freed on
//     `deinit`). Callbacks borrow their `data` argument for the call only.

/// Readable stream
pub const Readable = struct {
    on_data: ?StreamCallback = null,
    on_data_ctx: ?*anyopaque = null,
    on_end: ?StreamCallback = null,
    on_end_ctx: ?*anyopaque = null,
    on_error: ?StreamCallback = null,
    on_error_ctx: ?*anyopaque = null,
    on_close: ?StreamCallback = null,
    on_close_ctx: ?*anyopaque = null,
    is_ended: bool = false,
    is_closed: bool = false,
    is_paused: bool = false,
    /// Bytes with no ready consumer (none attached yet, or the stream is paused).
    /// Owned by the stream and flushed in order once a consumer attaches or the
    /// stream resumes, so producer data is never silently dropped nor leaked.
    pending: std.ArrayList(u8),
    /// Backpressure threshold; see `default_high_water_mark`. Callers may lower it
    /// after `init` (e.g. tests) to exercise the backpressure path.
    high_water_mark: usize = default_high_water_mark,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Readable {
        return Readable{
            .pending = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Readable) void {
        self.pending.deinit(self.allocator);
    }

    pub fn onData(self: *Readable, callback: StreamCallback, context: ?*anyopaque) !*Readable {
        self.on_data = callback;
        self.on_data_ctx = context;
        // Deliver anything buffered before this consumer attached (unless paused,
        // in which case the flush waits for `unpause`).
        try self.flushPending();
        return self;
    }

    pub fn onEnd(self: *Readable, callback: StreamCallback, context: ?*anyopaque) !*Readable {
        self.on_end = callback;
        self.on_end_ctx = context;
        // If the stream already ended before this consumer attached, fire now.
        if (self.is_ended) {
            try callback(context, null);
        }
        return self;
    }

    pub fn onError(self: *Readable, callback: StreamCallback, context: ?*anyopaque) *Readable {
        self.on_error = callback;
        self.on_error_ctx = context;
        return self;
    }

    pub fn onClose(self: *Readable, callback: StreamCallback, context: ?*anyopaque) *Readable {
        self.on_close = callback;
        self.on_close_ctx = context;
        return self;
    }

    /// Deliver `data`, or signal end-of-stream with `null`.
    ///
    /// Returns whether the producer may keep pushing: `true` when the chunk was
    /// delivered live or the buffer is still below `high_water_mark`, `false`
    /// once the buffer has reached the mark (backpressure). `end` always returns
    /// `true`. Pushing after `end`/`close` fails rather than silently vanishing.
    pub fn push(self: *Readable, data: ?[]const u8) !bool {
        if (self.is_closed) return error.StreamClosed;
        if (self.is_ended) return error.StreamEnded;

        if (data) |d| {
            if (self.on_data != null and !self.is_paused) {
                // Live delivery: the callback borrows `d` for the call only.
                try self.on_data.?(self.on_data_ctx, d);
                return true;
            }
            // No ready consumer: retain an owned copy for later delivery.
            try self.pending.appendSlice(self.allocator, d);
            return self.pending.items.len < self.high_water_mark;
        }

        // End of stream: deliver any buffered bytes first so `end` never
        // precedes the `data` it follows. This terminal flush is not gated by
        // pause — a paused consumer still needs the final bytes and the end
        // signal. Then fire `on_end` exactly once.
        try self.deliverPending();
        self.is_ended = true;
        if (self.on_end) |callback| {
            try callback(self.on_end_ctx, null);
        }
        return true;
    }

    /// Deliver any buffered bytes to the consumer, in order. A no-op when no
    /// consumer is attached (the bytes stay buffered for a later `onData`).
    fn deliverPending(self: *Readable) !void {
        if (self.pending.items.len == 0) return;
        if (self.on_data) |callback| {
            try callback(self.on_data_ctx, self.pending.items);
            self.pending.clearRetainingCapacity();
        }
    }

    /// Flush buffered bytes unless paused, in which case they wait for `unpause`.
    fn flushPending(self: *Readable) !void {
        if (self.is_paused) return;
        try self.deliverPending();
    }

    pub fn pause(self: *Readable) void {
        self.is_paused = true;
    }

    /// Resume live delivery and flush anything buffered while paused, in order.
    pub fn unpause(self: *Readable) !void {
        self.is_paused = false;
        try self.flushPending();
    }

    /// Deliver an error to `on_error` (as the error name) and then close. No
    /// further events fire afterwards. Idempotent once closed.
    pub fn emitError(self: *Readable, err: anyerror) !void {
        if (self.is_closed) return;
        if (self.on_error) |callback| {
            try callback(self.on_error_ctx, @errorName(err));
        }
        try self.close();
    }

    /// Cancel the stream: fire `on_close` once, drop any buffered data, and
    /// reject further pushes. Idempotent.
    pub fn close(self: *Readable) !void {
        if (self.is_closed) return;
        self.is_closed = true;
        self.pending.clearRetainingCapacity();
        if (self.on_close) |callback| {
            try callback(self.on_close_ctx, null);
        }
    }

    pub fn pipe(self: *Readable, writable: *Writable) !*Writable {
        // The destination pointer *is* the callback context, stored per-instance
        // on this stream. Any number of independent pipelines can therefore run
        // concurrently without clobbering one another; the previous design shared
        // a single static `dest`, so a second pipe silently hijacked the first.
        const Pipe = struct {
            fn onData(ctx: ?*anyopaque, data: ?[]const u8) !void {
                const dest: *Writable = @ptrCast(@alignCast(ctx.?));
                if (data) |d| {
                    // The in-memory sink buffers without a mid-stream drain, so
                    // the backpressure return is not actionable here; a direct
                    // producer observes it via `write`'s return instead.
                    _ = try dest.write(d);
                }
            }

            fn onEnd(ctx: ?*anyopaque, _: ?[]const u8) !void {
                const dest: *Writable = @ptrCast(@alignCast(ctx.?));
                try dest.end();
            }
        };

        _ = try self.onData(Pipe.onData, writable);
        _ = try self.onEnd(Pipe.onEnd, writable);
        return writable;
    }
};

/// Writable stream
pub const Writable = struct {
    on_finish: ?StreamCallback = null,
    on_finish_ctx: ?*anyopaque = null,
    on_error: ?StreamCallback = null,
    on_error_ctx: ?*anyopaque = null,
    on_close: ?StreamCallback = null,
    on_close_ctx: ?*anyopaque = null,
    is_ended: bool = false,
    is_closed: bool = false,
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),
    /// Backpressure threshold; see `default_high_water_mark`.
    high_water_mark: usize = default_high_water_mark,
    /// Optional heap context owned by this stream and freed on deinit. Factory
    /// helpers (e.g. createWriteStream) use it to bind callback state to the
    /// stream's lifetime without handing the caller a separate handle to manage.
    owned_context: ?*anyopaque = null,
    owned_context_free: ?*const fn (std.mem.Allocator, *anyopaque) void = null,

    pub fn init(allocator: std.mem.Allocator) Writable {
        return Writable{
            .allocator = allocator,
            .buffer = .empty,
        };
    }

    pub fn deinit(self: *Writable) void {
        self.buffer.deinit(self.allocator);
        if (self.owned_context) |ctx| {
            if (self.owned_context_free) |free_fn| {
                free_fn(self.allocator, ctx);
            }
            self.owned_context = null;
        }
    }

    pub fn onFinish(self: *Writable, callback: StreamCallback, context: ?*anyopaque) *Writable {
        self.on_finish = callback;
        self.on_finish_ctx = context;
        return self;
    }

    pub fn onError(self: *Writable, callback: StreamCallback, context: ?*anyopaque) *Writable {
        self.on_error = callback;
        self.on_error_ctx = context;
        return self;
    }

    pub fn onClose(self: *Writable, callback: StreamCallback, context: ?*anyopaque) *Writable {
        self.on_close = callback;
        self.on_close_ctx = context;
        return self;
    }

    /// Buffer `data` for delivery at `end`.
    ///
    /// Returns whether the producer may keep writing: `true` while the buffer is
    /// below `high_water_mark`, `false` once it has reached it (backpressure).
    /// Writing after `end`/`close` fails rather than silently accumulating.
    pub fn write(self: *Writable, data: []const u8) !bool {
        if (self.is_closed) return error.StreamClosed;
        if (self.is_ended) return error.StreamEnded;
        try self.buffer.appendSlice(self.allocator, data);
        return self.buffer.items.len < self.high_water_mark;
    }

    /// True once buffered bytes reach the high-water mark and the producer should
    /// wait. This in-memory sink flushes at `end`, so a producer streaming large
    /// volumes should `end` (or split into multiple streams) to drain.
    pub fn needsDrain(self: *Writable) bool {
        return self.buffer.items.len >= self.high_water_mark;
    }

    pub fn end(self: *Writable) !void {
        if (self.is_ended or self.is_closed) return;

        self.is_ended = true;
        if (self.on_finish) |callback| {
            try callback(self.on_finish_ctx, self.buffer.items);
        }
    }

    /// Deliver an error to `on_error` (as the error name) and then close.
    /// Idempotent once closed.
    pub fn emitError(self: *Writable, err: anyerror) !void {
        if (self.is_closed) return;
        if (self.on_error) |callback| {
            try callback(self.on_error_ctx, @errorName(err));
        }
        try self.close();
    }

    /// Cancel the stream: fire `on_close` once and reject further writes.
    /// Idempotent. Buffered bytes are retained until `deinit` frees them.
    pub fn close(self: *Writable) !void {
        if (self.is_closed) return;
        self.is_closed = true;
        if (self.on_close) |callback| {
            try callback(self.on_close_ctx, null);
        }
    }

    pub fn getData(self: *Writable) []const u8 {
        return self.buffer.items;
    }
};

/// Transform stream
pub const Transform = struct {
    readable: Readable,
    writable: Writable,
    transform_fn: *const fn (chunk: []const u8, allocator: std.mem.Allocator) anyerror![]u8,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        transform_fn: *const fn (chunk: []const u8, allocator: std.mem.Allocator) anyerror![]u8,
    ) Transform {
        return Transform{
            .readable = Readable.init(allocator),
            .writable = Writable.init(allocator),
            .transform_fn = transform_fn,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Transform) void {
        self.readable.deinit();
        self.writable.deinit();
    }

    /// Transform `data` and push it downstream. Returns the readable side's
    /// backpressure signal. A failing transform is delivered as an error on the
    /// readable (then closed) rather than propagated as a raw host error.
    pub fn write(self: *Transform, data: []const u8) !bool {
        const transformed = self.transform_fn(data, self.allocator) catch |err| {
            try self.readable.emitError(err);
            return false;
        };
        defer self.allocator.free(transformed);
        return self.readable.push(transformed);
    }

    pub fn end(self: *Transform) !void {
        _ = try self.readable.push(null);
        try self.writable.end();
    }

    pub fn pipe(self: *Transform, writable: *Writable) !*Writable {
        return self.readable.pipe(writable);
    }
};

/// Heap context bound to a file-backed writable stream. Owns its path copy and
/// is freed through the writable's `owned_context_free` hook on deinit.
const FileSink = struct {
    allocator: std.mem.Allocator,
    io: Io,
    path: []const u8,

    fn onFinish(ctx: ?*anyopaque, data: ?[]const u8) !void {
        const self: *FileSink = @ptrCast(@alignCast(ctx.?));
        if (data) |d| {
            try fs.writeFile(self.allocator, self.io, self.path, d);
        }
    }

    fn free(allocator: std.mem.Allocator, ctx: *anyopaque) void {
        const self: *FileSink = @ptrCast(@alignCast(ctx));
        allocator.free(self.path);
        allocator.destroy(self);
    }
};

/// Default chunk size for incremental file reads. Each `pump` iteration reads at
/// most this many bytes, so a large file is streamed piece by piece instead of
/// being slurped whole into one file-sized allocation.
pub const default_chunk_size = 16 * 1024;

/// A readable stream backed by a file, read incrementally.
///
/// Unlike an eager reader, construction only *opens* the file; no bytes are read
/// until `pump` runs. `pump` then reads bounded `chunk_size` blocks and pushes
/// each to the readable's consumer in order before signalling end-of-stream, so
/// peak memory is one chunk (when a consumer is attached) rather than the whole
/// file. Attach consumers on `.readable` before calling `pump` for live,
/// chunk-by-chunk delivery.
pub const FileReadStream = struct {
    readable: Readable,
    file: fs.File,
    /// Per-read block size; lowerable (e.g. tests) to force multiple chunks.
    chunk_size: usize = default_chunk_size,

    pub fn deinit(self: *FileReadStream) void {
        self.file.close();
        self.readable.deinit();
    }

    /// Read the file incrementally, pushing each bounded chunk to the consumer
    /// in order, then signal end. Reads happen here on demand — not at
    /// construction — so no file-sized buffer is ever allocated. Positional
    /// reads keep the offset explicit and independent of any shared cursor.
    pub fn pump(self: *FileReadStream) !void {
        const allocator = self.readable.allocator;
        const buf = try allocator.alloc(u8, self.chunk_size);
        defer allocator.free(buf);

        var offset: u64 = 0;
        while (true) {
            const n = try self.file.file.readPositionalAll(self.file.io, buf, offset);
            if (n == 0) break;
            offset += n;
            _ = try self.readable.push(buf[0..n]);
            // A short read from a `*All` positional read means EOF was reached.
            if (n < buf.len) break;
        }
        _ = try self.readable.push(null);
    }
};

/// Create an incremental readable stream from a file.
///
/// Opens `path` but does not read it; the caller attaches consumers on the
/// returned stream's `.readable` and then calls `pump` to stream the contents in
/// bounded chunks. The file handle is owned by the stream and closed on `deinit`.
pub fn createReadStream(allocator: std.mem.Allocator, io: Io, path: []const u8) !FileReadStream {
    const file = try fs.File.open(allocator, io, path, .{ .read = true });
    errdefer {
        var f = file;
        f.close();
    }
    return FileReadStream{
        .readable = Readable.init(allocator),
        .file = file,
    };
}

/// Create a writable stream that flushes its buffered contents to a file when
/// `end()` is called. The target path and IO are bound to the stream through an
/// owned `FileSink` context that is released on `deinit`.
pub fn createWriteStream(allocator: std.mem.Allocator, io: Io, path: []const u8) !Writable {
    var stream = Writable.init(allocator);
    errdefer stream.deinit();

    const path_copy = try allocator.dupe(u8, path);
    errdefer allocator.free(path_copy);

    const sink = try allocator.create(FileSink);
    // No fallible operations follow, so ownership of `sink` (and `path_copy`,
    // which it now holds) transfers to the stream without a double-free window.
    sink.* = .{ .allocator = allocator, .io = io, .path = path_copy };

    stream.on_finish = FileSink.onFinish;
    stream.on_finish_ctx = sink;
    stream.owned_context = sink;
    stream.owned_context_free = FileSink.free;

    return stream;
}

/// Collects delivered chunks into an owned buffer; used as a shared test sink.
/// Also records terminal events so ordering and cancellation can be asserted.
const TestCollector = struct {
    buffer: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,
    ended: bool = false,
    closed: bool = false,
    /// Number of non-null `data` deliveries — lets a test assert chunking.
    chunks: usize = 0,
    /// The error name delivered to `on_error`. `@errorName` returns a static
    /// slice, so storing it directly is safe (no lifetime concern).
    error_name: ?[]const u8 = null,

    fn onData(ctx: ?*anyopaque, data: ?[]const u8) !void {
        const self: *TestCollector = @ptrCast(@alignCast(ctx.?));
        if (data) |d| {
            try self.buffer.appendSlice(self.allocator, d);
            self.chunks += 1;
        } else {
            self.ended = true;
        }
    }

    fn onErr(ctx: ?*anyopaque, data: ?[]const u8) !void {
        const self: *TestCollector = @ptrCast(@alignCast(ctx.?));
        self.error_name = data;
    }

    fn onClose(ctx: ?*anyopaque, _: ?[]const u8) !void {
        const self: *TestCollector = @ptrCast(@alignCast(ctx.?));
        self.closed = true;
    }

    fn deinit(self: *TestCollector) void {
        self.buffer.deinit(self.allocator);
    }
};

test "readable stream delivers data to a context-bound callback" {
    const allocator = std.testing.allocator;

    var stream = Readable.init(allocator);
    defer stream.deinit();

    var collector = TestCollector{ .allocator = allocator };
    defer collector.deinit();

    _ = try stream.onData(TestCollector.onData, &collector);

    _ = try stream.push("Hello, Stream!");
    try std.testing.expectEqualStrings("Hello, Stream!", collector.buffer.items);
}

test "readable buffers data pushed before a consumer attaches" {
    const allocator = std.testing.allocator;

    var stream = Readable.init(allocator);
    defer stream.deinit();

    // Push before any consumer exists: bytes must be retained, not dropped/leaked.
    _ = try stream.push("early ");
    _ = try stream.push("bytes");

    var collector = TestCollector{ .allocator = allocator };
    defer collector.deinit();

    // Attaching the consumer flushes the buffered bytes.
    _ = try stream.onData(TestCollector.onData, &collector);
    try std.testing.expectEqualStrings("early bytes", collector.buffer.items);
}

test "pipe supports multiple independent concurrent pipelines" {
    const allocator = std.testing.allocator;

    var src_a = Readable.init(allocator);
    defer src_a.deinit();
    var dst_a = Writable.init(allocator);
    defer dst_a.deinit();

    var src_b = Readable.init(allocator);
    defer src_b.deinit();
    var dst_b = Writable.init(allocator);
    defer dst_b.deinit();

    _ = try src_a.pipe(&dst_a);
    _ = try src_b.pipe(&dst_b);

    // Interleave writes across both pipelines; each must stay isolated.
    _ = try src_a.push("aaa");
    _ = try src_b.push("bbb");
    _ = try src_a.push("AAA");

    try std.testing.expectEqualStrings("aaaAAA", dst_a.getData());
    try std.testing.expectEqualStrings("bbb", dst_b.getData());
}

test "writable stream" {
    const allocator = std.testing.allocator;

    var stream = Writable.init(allocator);
    defer stream.deinit();

    _ = try stream.write("Hello, ");
    _ = try stream.write("Stream!");

    try std.testing.expectEqualStrings("Hello, Stream!", stream.getData());
}

test "transform stream pipes transformed output to destination" {
    const allocator = std.testing.allocator;

    const uppercase = struct {
        fn transform(chunk: []const u8, alloc: std.mem.Allocator) ![]u8 {
            const result = try alloc.alloc(u8, chunk.len);
            _ = std.ascii.upperString(result, chunk);
            return result;
        }
    }.transform;

    var transform_stream = Transform.init(allocator, uppercase);
    defer transform_stream.deinit();

    var output = Writable.init(allocator);
    defer output.deinit();

    _ = try transform_stream.pipe(&output);

    _ = try transform_stream.write("hello");
    _ = try transform_stream.write(" world");
    try transform_stream.end();

    try std.testing.expectEqualStrings("HELLO WORLD", output.getData());
    try std.testing.expect(output.is_ended);
}

test "createWriteStream writes buffered payload to disk and frees context" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_abs = tmp_buf[0..try tmp.dir.realPath(io, &tmp_buf)];
    const path = try std.fs.path.join(allocator, &.{ tmp_abs, "write.out" });
    defer allocator.free(path);

    var stream = try createWriteStream(allocator, io, path);
    defer stream.deinit();

    _ = try stream.write("stream ");
    _ = try stream.write("payload");
    try stream.end();

    const written = try fs.readFile(allocator, io, path);
    defer allocator.free(written);
    try std.testing.expectEqualStrings("stream payload", written);
}

test "createReadStream streams file contents to a consumer on pump" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_abs = tmp_buf[0..try tmp.dir.realPath(io, &tmp_buf)];
    const path = try std.fs.path.join(allocator, &.{ tmp_abs, "read.in" });
    defer allocator.free(path);
    try fs.writeFile(allocator, io, path, "readable file body");

    var stream = try createReadStream(allocator, io, path);
    defer stream.deinit();

    var collector = TestCollector{ .allocator = allocator };
    defer collector.deinit();

    // Attach before pumping so delivery is live and incremental.
    _ = try stream.readable.onData(TestCollector.onData, &collector);
    _ = try stream.readable.onEnd(TestCollector.onData, &collector);
    try stream.pump();

    try std.testing.expectEqualStrings("readable file body", collector.buffer.items);
    try std.testing.expect(collector.ended);
}

test "createReadStream reads incrementally in bounded chunks" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_abs = tmp_buf[0..try tmp.dir.realPath(io, &tmp_buf)];
    const path = try std.fs.path.join(allocator, &.{ tmp_abs, "chunk.in" });
    defer allocator.free(path);
    // 10 bytes with a 4-byte chunk size must arrive as 3 chunks (4+4+2),
    // proving the file is streamed piece by piece, not slurped whole.
    try fs.writeFile(allocator, io, path, "0123456789");

    var stream = try createReadStream(allocator, io, path);
    defer stream.deinit();
    stream.chunk_size = 4;

    var collector = TestCollector{ .allocator = allocator };
    defer collector.deinit();

    _ = try stream.readable.onData(TestCollector.onData, &collector);
    _ = try stream.readable.onEnd(TestCollector.onData, &collector);
    try stream.pump();

    try std.testing.expectEqualStrings("0123456789", collector.buffer.items);
    try std.testing.expectEqual(@as(usize, 3), collector.chunks);
    try std.testing.expect(collector.ended);
}

test "pause buffers pushed data and unpause flushes it in order" {
    const allocator = std.testing.allocator;

    var stream = Readable.init(allocator);
    defer stream.deinit();

    var collector = TestCollector{ .allocator = allocator };
    defer collector.deinit();

    _ = try stream.onData(TestCollector.onData, &collector);

    // While paused, pushes must be retained rather than dropped (the pre-fix bug
    // silently discarded them). Nothing reaches the consumer yet.
    stream.pause();
    _ = try stream.push("one ");
    _ = try stream.push("two");
    try std.testing.expectEqualStrings("", collector.buffer.items);

    // Resuming flushes the buffered bytes to the consumer, in push order.
    try stream.unpause();
    try std.testing.expectEqualStrings("one two", collector.buffer.items);
}

test "push reports backpressure once the buffer reaches the high-water mark" {
    const allocator = std.testing.allocator;

    var stream = Readable.init(allocator);
    defer stream.deinit();
    // Lower the mark so a couple of small pushes cross it. No consumer is
    // attached, so every push buffers.
    stream.high_water_mark = 4;

    // Below the mark: producer may keep going.
    try std.testing.expect(try stream.push("ab"));
    // Reaching/exceeding the mark: backpressure asserted.
    try std.testing.expect(!try stream.push("cd"));
}

test "close fires on_close once, drops buffered data, and rejects further pushes" {
    const allocator = std.testing.allocator;

    var stream = Readable.init(allocator);
    defer stream.deinit();

    var collector = TestCollector{ .allocator = allocator };
    defer collector.deinit();
    _ = stream.onClose(TestCollector.onClose, &collector);

    // Buffer some undelivered data, then cancel.
    _ = try stream.push("dropped");
    try stream.close();
    try std.testing.expect(collector.closed);
    try std.testing.expectEqual(@as(usize, 0), stream.pending.items.len);

    // close is idempotent: a second close does not re-fire on_close.
    collector.closed = false;
    try stream.close();
    try std.testing.expect(!collector.closed);

    // After close, pushing fails rather than silently vanishing.
    try std.testing.expectError(error.StreamClosed, stream.push("more"));
}

test "emitError delivers the error name then closes the readable" {
    const allocator = std.testing.allocator;

    var stream = Readable.init(allocator);
    defer stream.deinit();

    var collector = TestCollector{ .allocator = allocator };
    defer collector.deinit();
    _ = stream.onError(TestCollector.onErr, &collector);
    _ = stream.onClose(TestCollector.onClose, &collector);

    try stream.emitError(error.BrokenPipe);
    try std.testing.expectEqualStrings("BrokenPipe", collector.error_name.?);
    // error is terminal: the stream closes and rejects further pushes.
    try std.testing.expect(collector.closed);
    try std.testing.expect(stream.is_closed);
    try std.testing.expectError(error.StreamClosed, stream.push("x"));
}

test "end flushes buffered data before on_end even while paused" {
    const allocator = std.testing.allocator;

    var stream = Readable.init(allocator);
    defer stream.deinit();

    var collector = TestCollector{ .allocator = allocator };
    defer collector.deinit();
    _ = try stream.onData(TestCollector.onData, &collector);
    _ = try stream.onEnd(TestCollector.onData, &collector);

    // Buffer data while paused, then end. The terminal flush is not gated by
    // pause, so the buffered bytes must arrive before the end signal.
    stream.pause();
    _ = try stream.push("tail");
    try std.testing.expectEqualStrings("", collector.buffer.items);

    _ = try stream.push(null);
    try std.testing.expectEqualStrings("tail", collector.buffer.items);
    try std.testing.expect(collector.ended);
}

test "writable reports backpressure via write and needsDrain at the mark" {
    const allocator = std.testing.allocator;

    var stream = Writable.init(allocator);
    defer stream.deinit();
    stream.high_water_mark = 4;

    try std.testing.expect(try stream.write("ab"));
    try std.testing.expect(!stream.needsDrain());
    // Reaching the mark asserts backpressure on both the return and needsDrain.
    try std.testing.expect(!try stream.write("cd"));
    try std.testing.expect(stream.needsDrain());
}

test "writable emitError delivers the error name then closes" {
    const allocator = std.testing.allocator;

    var stream = Writable.init(allocator);
    defer stream.deinit();

    var collector = TestCollector{ .allocator = allocator };
    defer collector.deinit();
    _ = stream.onError(TestCollector.onErr, &collector);
    _ = stream.onClose(TestCollector.onClose, &collector);

    try stream.emitError(error.ConnectionResetByPeer);
    try std.testing.expectEqualStrings("ConnectionResetByPeer", collector.error_name.?);
    try std.testing.expect(collector.closed);
    // After close, writing fails rather than silently accumulating.
    try std.testing.expectError(error.StreamClosed, stream.write("x"));
}
