const std = @import("std");
const builtin = @import("builtin");
const http = @import("http.zig");

/// Default cap on a buffered response body. A remote server (or a redirect to a
/// hostile one) must not be able to drive this client into unbounded memory
/// growth, so the accumulator refuses to exceed this size.
pub const default_max_response_body: usize = 10 * 1024 * 1024;

/// Wrapper for ArrayList to provide a writer interface, bounded by `max`.
const ArrayListWriter = struct {
    list: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    writer_obj: std.Io.Writer,
    /// Maximum total bytes the backing list may hold.
    max: usize,
    /// Set when a write was refused because it would exceed `max`. The caller
    /// maps the resulting WriteFailed to `error.ResponseBodyTooLarge` rather
    /// than silently truncating the body.
    overflowed: bool = false,
    buffer_storage: [0]u8 = .{},

    pub fn init(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, max: usize) ArrayListWriter {
        return .{
            .list = list,
            .allocator = allocator,
            .writer_obj = .{
                .vtable = &vtable,
                .buffer = &.{},
            },
            .max = max,
        };
    }

    pub fn writer(self: *ArrayListWriter) *std.Io.Writer {
        return &self.writer_obj;
    }

    const vtable = std.Io.Writer.VTable{
        .drain = drain,
    };

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *ArrayListWriter = @fieldParentPtr("writer_obj", w);
        var total: usize = 0;
        for (data) |slice| {
            // Fail closed the moment the cap would be exceeded: flag the overflow
            // and stop rather than resizing the list toward exhaustion.
            if (slice.len > self.max - self.list.items.len) {
                self.overflowed = true;
                return error.WriteFailed;
            }
            self.list.appendSlice(self.allocator, slice) catch return error.WriteFailed;
            total += slice.len;
        }
        _ = splat;
        return total;
    }
};

/// HTTP client for making requests
pub const Client = struct {
    allocator: std.mem.Allocator,
    client: std.http.Client,
    io_impl: *std.Io.Threaded,
    /// Cap applied to every buffered response body. Callers may lower it after
    /// init for stricter contexts.
    max_response_body: usize = default_max_response_body,
    /// Whether this client transparently follows HTTP redirects. Default false:
    /// a redirect is a classic SSRF escape (a policy-approved origin answers 302
    /// pointing at an internal target), so the outbound client fails closed and
    /// surfaces the redirect as `error.RedirectBlocked` instead of chasing it.
    /// An embedder that needs redirects can opt in explicitly after init.
    allow_redirects: bool = false,

    pub fn init(allocator: std.mem.Allocator) !Client {
        const io_ptr = try allocator.create(std.Io.Threaded);
        errdefer allocator.destroy(io_ptr);
        io_ptr.* = std.Io.Threaded.init(allocator, .{ .environ = .empty });

        return .{
            .allocator = allocator,
            .client = .{
                .allocator = allocator,
                .io = io_ptr.io(),
            },
            .io_impl = io_ptr,
        };
    }

    pub fn deinit(self: *Client) void {
        self.client.deinit();
        self.io_impl.deinit();
        self.allocator.destroy(self.io_impl);
    }

    /// Map the redirect policy to a std.http redirect behavior. `.not_allowed`
    /// makes a redirect response fail (std returns error.TooManyHttpRedirects),
    /// which the request helpers remap to `error.RedirectBlocked`. This is a
    /// pure seam so the fail-closed default can be tested without a network.
    fn redirectBehavior(allow_redirects: bool) std.http.Client.Request.RedirectBehavior {
        return if (allow_redirects) @enumFromInt(3) else .not_allowed;
    }

    /// Make a GET request and return the response body
    pub fn get(self: *Client, url: []const u8) ![]const u8 {
        var response_body: std.ArrayListUnmanaged(u8) = .empty;
        errdefer response_body.deinit(self.allocator);

        var writer_inst = ArrayListWriter.init(&response_body, self.allocator, self.max_response_body);
        const writer = writer_inst.writer();

        _ = self.client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .response_writer = writer,
            .redirect_behavior = redirectBehavior(self.allow_redirects),
        }) catch |err| {
            if (writer_inst.overflowed) return error.ResponseBodyTooLarge;
            if (err == error.TooManyHttpRedirects and !self.allow_redirects) return error.RedirectBlocked;
            return err;
        };

        return try response_body.toOwnedSlice(self.allocator);
    }

    /// Make a POST request with a body and return the response
    pub fn post(self: *Client, url: []const u8, body: []const u8, content_type: []const u8) ![]const u8 {
        var response_body: std.ArrayListUnmanaged(u8) = .empty;
        errdefer response_body.deinit(self.allocator);

        var writer_inst = ArrayListWriter.init(&response_body, self.allocator, self.max_response_body);
        const writer = writer_inst.writer();

        const headers = [_]std.http.Header{
            .{ .name = "content-type", .value = content_type },
        };

        _ = self.client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = body,
            .extra_headers = &headers,
            .response_writer = writer,
            .redirect_behavior = redirectBehavior(self.allow_redirects),
        }) catch |err| {
            if (writer_inst.overflowed) return error.ResponseBodyTooLarge;
            if (err == error.TooManyHttpRedirects and !self.allow_redirects) return error.RedirectBlocked;
            return err;
        };

        return try response_body.toOwnedSlice(self.allocator);
    }

    /// Make a generic HTTP request
    pub const RequestOptions = struct {
        method: std.http.Method = .GET,
        body: ?[]const u8 = null,
        headers: []const std.http.Header = &.{},
    };

    pub fn request(self: *Client, url: []const u8, options: RequestOptions) ![]const u8 {
        var response_body: std.ArrayListUnmanaged(u8) = .empty;
        errdefer response_body.deinit(self.allocator);

        var writer_inst = ArrayListWriter.init(&response_body, self.allocator, self.max_response_body);
        const writer = writer_inst.writer();

        _ = self.client.fetch(.{
            .location = .{ .url = url },
            .method = options.method,
            .payload = options.body,
            .extra_headers = options.headers,
            .response_writer = writer,
            .redirect_behavior = redirectBehavior(self.allow_redirects),
        }) catch |err| {
            if (writer_inst.overflowed) return error.ResponseBodyTooLarge;
            if (err == error.TooManyHttpRedirects and !self.allow_redirects) return error.RedirectBlocked;
            return err;
        };

        return try response_body.toOwnedSlice(self.allocator);
    }

    /// Stream a response body to a caller-provided `sink` instead of buffering.
    ///
    /// The `get`/`post`/`request` helpers accumulate the whole body in memory
    /// (capped by `max_response_body`) — convenient for small bodies. This
    /// streaming variant hands the response bytes straight to `sink` as they
    /// arrive, so an arbitrarily large body (a file download, a proxied stream)
    /// never has to fit in memory. The total-size budget and any backpressure
    /// are the sink's responsibility; `max_response_body` does not apply here.
    /// Redirects still fail closed as `error.RedirectBlocked` unless
    /// `allow_redirects` was set, so the SSRF guard is not weakened by streaming.
    pub fn requestStream(self: *Client, url: []const u8, sink: *std.Io.Writer, options: RequestOptions) !void {
        _ = self.client.fetch(.{
            .location = .{ .url = url },
            .method = options.method,
            .payload = options.body,
            .extra_headers = options.headers,
            .response_writer = sink,
            .redirect_behavior = redirectBehavior(self.allow_redirects),
        }) catch |err| {
            if (err == error.TooManyHttpRedirects and !self.allow_redirects) return error.RedirectBlocked;
            return err;
        };
    }

    /// GET convenience over `requestStream`: stream the response body to `sink`.
    pub fn getStream(self: *Client, url: []const u8, sink: *std.Io.Writer) !void {
        return self.requestStream(url, sink, .{ .method = .GET });
    }
};

test "http client basic" {
    const allocator = std.testing.allocator;

    var client = try Client.init(allocator);
    defer client.deinit();

    // This test would require actual HTTP server
    // Skip for now
}

test "bounded response writer fails closed past the cap" {
    // Drive the writer exactly as std.http.Client.fetch would, proving the
    // cap refuses an over-large body instead of growing without bound.
    const allocator = std.testing.allocator;
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(allocator);

    var w = ArrayListWriter.init(&body, allocator, 8);
    const writer = w.writer();

    // Writes up to the cap succeed and are retained verbatim.
    try writer.writeAll("hello");
    try std.testing.expectEqual(@as(usize, 5), body.items.len);
    try std.testing.expect(!w.overflowed);

    // The write that would cross the cap is refused; the flag lets the caller
    // surface error.ResponseBodyTooLarge rather than truncate silently.
    try std.testing.expectError(error.WriteFailed, writer.writeAll("world!!"));
    try std.testing.expect(w.overflowed);
    try std.testing.expect(body.items.len <= 8);
}

test "outbound client refuses redirects by default (ssrf escape)" {
    // Fail-closed default: a redirect is not followed but surfaced as an error.
    try std.testing.expectEqual(
        std.http.Client.Request.RedirectBehavior.not_allowed,
        Client.redirectBehavior(false),
    );
    // Explicit opt-in restores bounded redirect following.
    try std.testing.expect(Client.redirectBehavior(true) != .not_allowed);
}

test "bounded response writer accepts a body up to the exact cap" {
    const allocator = std.testing.allocator;
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(allocator);

    var w = ArrayListWriter.init(&body, allocator, 5);
    const writer = w.writer();

    try writer.writeAll("hello");
    try std.testing.expect(!w.overflowed);
    try std.testing.expectEqualStrings("hello", body.items);
}

// Streams a two-chunk body so the client's streaming consumption is exercised
// against a real chunked (Transfer-Encoding: chunked) response over the wire.
fn streamHandler(req: *http.Request, res: *http.Response) anyerror!void {
    _ = req;
    try res.beginStream();
    try res.writeChunk("Wiki");
    try res.writeChunk("pedia");
    try res.endStream();
}

test "getStream consumes a chunked response body without buffering it whole" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    // A Nexus server streams the body as chunked; the client decodes and
    // streams it into a caller sink. This exercises both halves of item 1283
    // end to end: server streaming response + client streaming consumption.
    var server = try http.Server.init(allocator, .{ .port = 0, .host = "127.0.0.1", .worker_count = 1 });
    defer server.deinit();
    try server.route("GET", "/stream", streamHandler);
    try server.start();
    const port = server.tcp_server.boundPort();

    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/stream", .{port});
    defer allocator.free(url);

    var client = try Client.init(allocator);
    defer client.deinit();

    // The caller owns the sink and its size budget; here a bounded ArrayList
    // writer collects the decoded body for the assertion.
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(allocator);
    var sink = ArrayListWriter.init(&body, allocator, 1024);

    try client.getStream(url, sink.writer());
    try std.testing.expectEqualStrings("Wikipedia", body.items);
}
