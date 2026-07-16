const std = @import("std");
const builtin = @import("builtin");
const tcp = @import("tcp.zig");
const http_parser = @import("http_parser.zig");
const websocket = @import("websocket.zig");

pub const Method = enum {
    GET,
    POST,
    PUT,
    DELETE,
    PATCH,
    HEAD,
    OPTIONS,

    pub fn fromString(s: []const u8) ?Method {
        if (std.mem.eql(u8, s, "GET")) return .GET;
        if (std.mem.eql(u8, s, "POST")) return .POST;
        if (std.mem.eql(u8, s, "PUT")) return .PUT;
        if (std.mem.eql(u8, s, "DELETE")) return .DELETE;
        if (std.mem.eql(u8, s, "PATCH")) return .PATCH;
        if (std.mem.eql(u8, s, "HEAD")) return .HEAD;
        if (std.mem.eql(u8, s, "OPTIONS")) return .OPTIONS;
        return null;
    }

    pub fn toString(self: Method) []const u8 {
        return switch (self) {
            .GET => "GET",
            .POST => "POST",
            .PUT => "PUT",
            .DELETE => "DELETE",
            .PATCH => "PATCH",
            .HEAD => "HEAD",
            .OPTIONS => "OPTIONS",
        };
    }
};

pub const Headers = struct {
    map: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Headers {
        return Headers{
            .map = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Headers) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.map.deinit();
    }

    pub fn set(self: *Headers, key: []const u8, value: []const u8) !void {
        // Fail closed on anything that could break the field framing. A name
        // that is not an RFC 7230 token, or a value carrying CR/LF/NUL, is the
        // classic response-splitting vector: it would let an attacker-tainted
        // value inject extra header lines or a premature body separator.
        if (!http_parser.isToken(key)) return error.InvalidHeaderName;
        if (!http_parser.validHeaderValue(value)) return error.InvalidHeaderValue;

        const value_duped = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_duped);

        const gop = try self.map.getOrPut(key);
        if (gop.found_existing) {
            // Keep the existing owned key; replace the value and free the old one
            // exactly once so repeated sets of the same header do not leak.
            self.allocator.free(gop.value_ptr.*);
            gop.value_ptr.* = value_duped;
        } else {
            // New entry: the map currently holds the caller's transient key slice.
            // Replace it with an owned copy the map keeps for its lifetime.
            const key_duped = self.allocator.dupe(u8, key) catch |err| {
                // Roll back the slot so the map never retains the transient key.
                _ = self.map.remove(key);
                return err;
            };
            gop.key_ptr.* = key_duped;
            gop.value_ptr.* = value_duped;
        }
    }

    pub fn get(self: *Headers, key: []const u8) ?[]const u8 {
        return self.map.get(key);
    }
};

pub const Request = struct {
    method: Method,
    path: []const u8,
    query_string: ?[]const u8 = null,
    headers: Headers,
    body: []const u8,
    allocator: std.mem.Allocator,
    parsed: http_parser.RequestParser.ParsedRequest,
    cookies: std.StringHashMap([]const u8),
    /// Path parameters captured from a `:name` route pattern, keyed by name with
    /// percent-decoded values. Empty for a request that matched a static route.
    /// Populated by `Server.dispatch` once the winning route is chosen; read via
    /// `getParam`.
    params: std.StringHashMap([]const u8),

    pub fn deinit(self: *Request) void {
        self.headers.deinit();
        self.parsed.deinit();

        // Free cookie map
        var it = self.cookies.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.cookies.deinit();

        // Free path-parameter map
        var pit = self.params.iterator();
        while (pit.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.params.deinit();
    }

    pub fn readBody(self: *Request) ![]const u8 {
        return self.body;
    }

    pub fn getHeader(self: *Request, key: []const u8) ?[]const u8 {
        return self.parsed.getHeader(key);
    }

    pub fn getQuery(self: *Request, key: []const u8) ?[]const u8 {
        return self.parsed.getQuery(key);
    }

    /// Get a path parameter captured from a `:name` route segment. The value is
    /// percent-decoded. Returns null for an unknown name or a static route.
    pub fn getParam(self: *Request, name: []const u8) ?[]const u8 {
        return self.params.get(name);
    }

    /// Get a cookie value by name
    pub fn getCookie(self: *Request, name: []const u8) ?[]const u8 {
        return self.cookies.get(name);
    }

    /// The `If-Modified-Since` request time as seconds since the Unix epoch, or
    /// null when the header is absent or not a valid IMF-fixdate. A handler
    /// compares it against a resource's mtime to decide whether to answer `304`.
    pub fn ifModifiedSince(self: *Request) ?i64 {
        const raw = self.getHeader("if-modified-since") orelse return null;
        return parseHttpDate(raw);
    }

    /// Parse the JSON body into `T`.
    ///
    /// Returns the owning `std.json.Parsed(T)` rather than a bare value: the
    /// result carries an arena that backs any allocated fields (strings, slices,
    /// nested objects). The caller must `defer result.deinit()` and read the
    /// decoded data through `result.value`. Returning the bare value would either
    /// leak the arena or leave heap-backed fields dangling once it is freed.
    pub fn jsonBody(self: *Request, comptime T: type) !std.json.Parsed(T) {
        return std.json.parseFromSlice(T, self.allocator, self.body, .{});
    }
};

pub const StatusCode = enum(u16) {
    Continue = 100,
    SwitchingProtocols = 101,
    OK = 200,
    Created = 201,
    Accepted = 202,
    NoContent = 204,
    PartialContent = 206,
    MovedPermanently = 301,
    Found = 302,
    SeeOther = 303,
    NotModified = 304,
    TemporaryRedirect = 307,
    PermanentRedirect = 308,
    BadRequest = 400,
    Unauthorized = 401,
    Forbidden = 403,
    NotFound = 404,
    MethodNotAllowed = 405,
    NotAcceptable = 406,
    RequestTimeout = 408,
    Conflict = 409,
    LengthRequired = 411,
    PreconditionFailed = 412,
    PayloadTooLarge = 413,
    UnsupportedMediaType = 415,
    RangeNotSatisfiable = 416,
    UnprocessableEntity = 422,
    TooManyRequests = 429,
    InternalServerError = 500,
    NotImplemented = 501,
    BadGateway = 502,
    ServiceUnavailable = 503,
    GatewayTimeout = 504,
    HttpVersionNotSupported = 505,

    pub fn toInt(self: StatusCode) u16 {
        return @intFromEnum(self);
    }

    pub fn toString(self: StatusCode) []const u8 {
        return switch (self) {
            .Continue => "Continue",
            .SwitchingProtocols => "Switching Protocols",
            .OK => "OK",
            .Created => "Created",
            .Accepted => "Accepted",
            .NoContent => "No Content",
            .PartialContent => "Partial Content",
            .MovedPermanently => "Moved Permanently",
            .Found => "Found",
            .SeeOther => "See Other",
            .NotModified => "Not Modified",
            .TemporaryRedirect => "Temporary Redirect",
            .PermanentRedirect => "Permanent Redirect",
            .BadRequest => "Bad Request",
            .Unauthorized => "Unauthorized",
            .Forbidden => "Forbidden",
            .NotFound => "Not Found",
            .MethodNotAllowed => "Method Not Allowed",
            .NotAcceptable => "Not Acceptable",
            .RequestTimeout => "Request Timeout",
            .Conflict => "Conflict",
            .LengthRequired => "Length Required",
            .PreconditionFailed => "Precondition Failed",
            .PayloadTooLarge => "Payload Too Large",
            .UnsupportedMediaType => "Unsupported Media Type",
            .RangeNotSatisfiable => "Range Not Satisfiable",
            .UnprocessableEntity => "Unprocessable Entity",
            .TooManyRequests => "Too Many Requests",
            .InternalServerError => "Internal Server Error",
            .NotImplemented => "Not Implemented",
            .BadGateway => "Bad Gateway",
            .ServiceUnavailable => "Service Unavailable",
            .GatewayTimeout => "Gateway Timeout",
            .HttpVersionNotSupported => "HTTP Version Not Supported",
        };
    }

    /// Whether this status forbids a message body (and thus any framing header
    /// that would imply one). RFC 9110/9112: 1xx, 204, and 304 responses never
    /// carry a body, so `send` must neither write body bytes nor synthesize a
    /// `Content-Length`. This is distinct from `HEAD`, which keeps the
    /// `Content-Length` the `GET` would have sent but omits only the body.
    pub fn bodyless(self: StatusCode) bool {
        return switch (self) {
            .Continue, .SwitchingProtocols, .NoContent, .NotModified => true,
            else => false,
        };
    }
};

pub const CookieOptions = struct {
    max_age: ?i64 = null, // seconds
    path: ?[]const u8 = null,
    domain: ?[]const u8 = null,
    secure: bool = false,
    http_only: bool = false,
    same_site: ?[]const u8 = null, // "Strict", "Lax", "None"
};

/// A cookie name/value/attribute must carry no control bytes (CR/LF/NUL are the
/// response-splitting vector) and no `;`, which would otherwise let a value
/// forge additional cookie attributes such as `; Secure` or `; Domain=`.
fn validCookieComponent(s: []const u8) bool {
    if (!http_parser.validHeaderValue(s)) return false;
    for (s) |c| {
        if (c == ';') return false;
    }
    return true;
}

/// Bodies smaller than this are sent uncompressed even when the client accepts
/// gzip: the ~18 bytes of gzip framing would otherwise inflate a short payload.
const gzip_min_bytes = 256;

/// gzip-compress `data` into a freshly allocated buffer the caller owns.
///
/// The std flate compressor writes through an `Io.Writer`, so the output is an
/// `Allocating` writer (grows as needed) and the required `max_window_len`
/// scratch window is a heap slice freed on return. `Container.gzip` produces a
/// complete RFC 1952 member (header + DEFLATE data + CRC32/ISIZE footer).
fn gzipCompress(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    // `Compress.init` asserts the output has >8 bytes of buffer; seed a small
    // capacity so the assertion holds before the writer grows on demand.
    var out: std.Io.Writer.Allocating = try .initCapacity(allocator, 64);
    errdefer out.deinit();

    const window = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(window);

    var comp = try std.compress.flate.Compress.init(&out.writer, window, .gzip, .default);
    try comp.writer.writeAll(data);
    try comp.finish();

    return out.toOwnedSlice();
}

const http_day_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const http_month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

/// An IMF-fixdate is always exactly this many bytes: "Sun, 06 Nov 1994 08:49:37 GMT".
const http_date_len = 29;

/// Format `unix_secs` (seconds since the Unix epoch, UTC) into `buf` as an RFC
/// 9110 IMF-fixdate — the single date form a server is required to emit for
/// `Date`, `Last-Modified`, and `Expires`. Pre-epoch inputs clamp to the epoch;
/// server-generated dates are never before 1970. Returns the written slice.
fn writeHttpDate(buf: *[http_date_len]u8, unix_secs: i64) []const u8 {
    const secs: u64 = if (unix_secs < 0) 0 else @intCast(unix_secs);
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const ed = es.getEpochDay();
    const yd = ed.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    // 1970-01-01 (epoch day 0) was a Thursday; day-of-week is 0=Sunday.
    const dow: usize = @intCast((ed.day + 4) % 7);
    // The format is fixed-width, so it always fills exactly http_date_len bytes.
    return std.fmt.bufPrint(buf, "{s}, {d:0>2} {s} {d:0>4} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
        http_day_names[dow],
        @as(u32, md.day_index) + 1,
        http_month_names[@intFromEnum(md.month) - 1],
        yd.year,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    }) catch unreachable;
}

/// Format `unix_secs` as an owned IMF-fixdate string. Convenience wrapper over
/// `writeHttpDate` for callers that need a heap copy (e.g. a `Last-Modified`
/// header value).
pub fn formatHttpDate(allocator: std.mem.Allocator, unix_secs: i64) ![]u8 {
    var buf: [http_date_len]u8 = undefined;
    return allocator.dupe(u8, writeHttpDate(&buf, unix_secs));
}

/// Parse an RFC 9110 IMF-fixdate ("Sun, 06 Nov 1994 08:49:37 GMT") into seconds
/// since the Unix epoch (UTC). Returns null for any input that is not exactly
/// this form. The two obsolete formats (RFC 850, asctime) are intentionally not
/// accepted: they are only used as a conditional-request optimisation, and a
/// null simply falls back to serving the full response, which is always safe.
pub fn parseHttpDate(s: []const u8) ?i64 {
    if (s.len != http_date_len) return null;
    // Fixed offsets: "Www, DD Mon YYYY HH:MM:SS GMT".
    if (s[3] != ',' or s[4] != ' ' or s[7] != ' ' or s[11] != ' ' or s[16] != ' ') return null;
    if (s[19] != ':' or s[22] != ':' or s[25] != ' ') return null;
    if (!std.mem.eql(u8, s[26..29], "GMT")) return null;

    const day = twoDigit(s[5..7]) orelse return null;
    const month = monthFromName(s[8..11]) orelse return null;
    const year = fourDigit(s[12..16]) orelse return null;
    const hour = twoDigit(s[17..19]) orelse return null;
    const min = twoDigit(s[20..22]) orelse return null;
    const sec = twoDigit(s[23..25]) orelse return null;
    if (year < 1970 or month < 1 or month > 12 or day < 1 or day > 31) return null;
    if (hour > 23 or min > 59 or sec > 60) return null; // 60 tolerates a leap second

    // Days from 1970-01-01 to the year/month start, then the day-of-month.
    var days: i64 = 0;
    var y: u16 = 1970;
    while (y < year) : (y += 1) days += std.time.epoch.getDaysInYear(y);
    var m: u4 = 1;
    while (m < month) : (m += 1) days += std.time.epoch.getDaysInMonth(y, @enumFromInt(m));
    days += @as(i64, day) - 1;

    return days * std.time.epoch.secs_per_day + @as(i64, hour) * 3600 + @as(i64, min) * 60 + sec;
}

fn twoDigit(s: []const u8) ?u8 {
    const hi = std.fmt.charToDigit(s[0], 10) catch return null;
    const lo = std.fmt.charToDigit(s[1], 10) catch return null;
    return hi * 10 + lo;
}

fn fourDigit(s: []const u8) ?u16 {
    var v: u16 = 0;
    for (s) |c| v = v * 10 + (std.fmt.charToDigit(c, 10) catch return null);
    return v;
}

fn monthFromName(s: []const u8) ?u4 {
    for (http_month_names, 0..) |name, i| {
        if (std.mem.eql(u8, s, name)) return @intCast(i + 1);
    }
    return null;
}

pub const Response = struct {
    status_code: StatusCode = .OK,
    headers: Headers,
    body: ?[]const u8 = null,
    stream: std.Io.net.Stream,
    allocator: std.mem.Allocator,
    io: std.Io,
    sent: bool = false,
    /// Deadline for gaining socket writability before sending, in
    /// milliseconds. 0 (or negative) disables the gate. Set by the server from
    /// its configured write timeout so a peer that stops reading cannot pin the
    /// worker while the response is flushed.
    write_timeout_ms: i32 = 0,
    /// When true the body is suppressed but all headers (including an accurate
    /// `Content-Length`) are still emitted. Set by the server for `HEAD`, whose
    /// response must be byte-identical to the `GET` response minus the body.
    head_only: bool = false,
    /// True between `beginStream` and `endStream`: the response is being written
    /// incrementally as `Transfer-Encoding: chunked` rather than buffered.
    streaming: bool = false,
    /// Set by the compression middleware when the client advertised `gzip` in
    /// `Accept-Encoding`. `send` honours it by actually gzip-compressing the body
    /// and only then emitting `Content-Encoding: gzip` — the header is never set
    /// unless the bytes on the wire are genuinely compressed.
    wants_gzip: bool = false,
    /// Set-Cookie is the one response field that legitimately repeats. The
    /// single-value `Headers` map would collapse multiple cookies into one, so
    /// each fully-formatted cookie line is accumulated here and emitted as its
    /// own `Set-Cookie:` header in `send`.
    set_cookies: std.ArrayList([]const u8) = .empty,

    pub fn init(allocator: std.mem.Allocator, stream: std.Io.net.Stream, io: std.Io) Response {
        return Response{
            .headers = Headers.init(allocator),
            .stream = stream,
            .allocator = allocator,
            .io = io,
        };
    }

    pub fn deinit(self: *Response) void {
        self.headers.deinit();
        for (self.set_cookies.items) |cookie| self.allocator.free(cookie);
        self.set_cookies.deinit(self.allocator);
        if (self.body) |b| self.allocator.free(b);
    }

    pub fn status(self: *Response, code: StatusCode) *Response {
        self.status_code = code;
        return self;
    }

    pub fn setHeader(self: *Response, key: []const u8, value: []const u8) !*Response {
        try self.headers.set(key, value);
        return self;
    }

    /// Append the status line, all headers, and every accumulated Set-Cookie
    /// line to `buf`, terminated by the blank line that ends the header block.
    /// Shared by the buffered `send` and the streaming `beginStream` paths so
    /// both emit exactly the same framing.
    fn serializeHeaders(self: *Response, buf: *std.ArrayList(u8)) !void {
        try buf.appendSlice(self.allocator, "HTTP/1.1 ");
        const status_code_str = try std.fmt.allocPrint(self.allocator, "{d}", .{self.status_code.toInt()});
        defer self.allocator.free(status_code_str);
        try buf.appendSlice(self.allocator, status_code_str);
        try buf.appendSlice(self.allocator, " ");
        try buf.appendSlice(self.allocator, self.status_code.toString());
        try buf.appendSlice(self.allocator, "\r\n");

        // RFC 9110 §6.6.1: an origin server with a clock sends `Date` on every
        // response it generates. Synthesize it from the wall clock unless the
        // handler already set one explicitly.
        if (self.headers.get("Date") == null) {
            const ns = std.Io.Timestamp.now(self.io, .real).nanoseconds;
            const unix_secs: i64 = @intCast(@divTrunc(ns, std.time.ns_per_s));
            var date_buf: [http_date_len]u8 = undefined;
            try self.headers.set("Date", writeHttpDate(&date_buf, unix_secs));
        }

        var it = self.headers.map.iterator();
        while (it.next()) |entry| {
            try buf.appendSlice(self.allocator, entry.key_ptr.*);
            try buf.appendSlice(self.allocator, ": ");
            try buf.appendSlice(self.allocator, entry.value_ptr.*);
            try buf.appendSlice(self.allocator, "\r\n");
        }

        // Set-Cookie fields, one line each so multiple cookies survive intact.
        for (self.set_cookies.items) |cookie| {
            try buf.appendSlice(self.allocator, "Set-Cookie: ");
            try buf.appendSlice(self.allocator, cookie);
            try buf.appendSlice(self.allocator, "\r\n");
        }

        try buf.appendSlice(self.allocator, "\r\n");
    }

    /// Block until the socket is writable or the write deadline elapses, so a
    /// peer that has stopped reading cannot pin this worker inside a blocking
    /// flush. A non-positive `write_timeout_ms` disables the gate.
    fn gateWritable(self: *Response) !void {
        if (self.write_timeout_ms <= 0) return;
        var fds = [_]std.posix.pollfd{.{
            .fd = self.stream.socket.handle,
            .events = std.posix.POLL.OUT,
            .revents = 0,
        }};
        if ((try std.posix.poll(&fds, self.write_timeout_ms)) == 0) return error.WriteTimeout;
    }

    pub fn send(self: *Response, data: []const u8) !void {
        if (self.sent) return error.AlreadySent;

        // Optionally gzip the body. Compress first so `Content-Encoding` and
        // `Content-Length` describe the exact bytes written — the header is only
        // set when the payload is genuinely compressed. Tiny bodies are left
        // alone: gzip framing overhead would make them larger, not smaller. A
        // HEAD still compresses so its `Content-Length` matches the GET body.
        // A 1xx/204/304 status carries no body and no framing header that would
        // imply one; HEAD carries the framing headers (so its Content-Length
        // matches the GET body) but still omits the body bytes.
        const bodyless = self.status_code.bodyless();
        const omit_body = self.head_only or bodyless;

        var body = data;
        var gzipped: ?[]u8 = null;
        defer if (gzipped) |g| self.allocator.free(g);
        if (self.wants_gzip and !bodyless and data.len >= gzip_min_bytes) {
            const g = try gzipCompress(self.allocator, data);
            gzipped = g;
            body = g;
            try self.headers.set("Content-Encoding", "gzip");
        }

        // Auto-set Content-Length only for statuses that may carry a body. A
        // bodyless status must not synthesize one (a handler may still set it
        // explicitly on a 304 to mirror the would-be 200 response).
        if (!bodyless and self.headers.get("Content-Length") == null) {
            const len_str = try std.fmt.allocPrint(self.allocator, "{d}", .{body.len});
            defer self.allocator.free(len_str);
            try self.headers.set("Content-Length", len_str);
        }

        var header_buf: std.ArrayList(u8) = .empty;
        defer header_buf.deinit(self.allocator);
        try self.serializeHeaders(&header_buf);

        try self.gateWritable();

        // Write header and body using stream writer
        var write_buf: [4096]u8 = undefined;
        var writer = self.stream.writer(self.io, &write_buf);

        // Write header
        try writer.interface.writeAll(header_buf.items);

        // Write body if present. HEAD carries the full headers (Content-Length
        // reflects what the GET body would be) but no body; a 1xx/204/304 status
        // carries neither framing header nor body. `omit_body` covers both.
        if (body.len > 0 and !omit_body) {
            try writer.interface.writeAll(body);
        }

        // Flush any buffered data
        try writer.interface.flush();

        self.sent = true;
    }

    /// Stream `len` bytes of `file` starting at byte `offset` as the response
    /// body, copying to the socket in fixed-size blocks so an arbitrarily large
    /// file (or byte range) is never held in memory at once — the whole point of
    /// serving static assets without allocating them.
    ///
    /// Headers are written first; unless the status is bodyless, `Content-Length`
    /// is set to `len` when the caller has not already supplied one (a range
    /// caller sets `Content-Range` and lets this fill in the matching length).
    /// `head_only`/bodyless statuses emit the headers and no body, exactly like
    /// `send`. `file` must have been opened with this response's `io` provider.
    pub fn sendFile(self: *Response, file: std.Io.File, offset: u64, len: usize) !void {
        if (self.sent) return error.AlreadySent;

        const bodyless = self.status_code.bodyless();
        const omit_body = self.head_only or bodyless;

        if (!bodyless and self.headers.get("Content-Length") == null) {
            const len_str = try std.fmt.allocPrint(self.allocator, "{d}", .{len});
            defer self.allocator.free(len_str);
            try self.headers.set("Content-Length", len_str);
        }

        var header_buf: std.ArrayList(u8) = .empty;
        defer header_buf.deinit(self.allocator);
        try self.serializeHeaders(&header_buf);

        try self.gateWritable();
        var write_buf: [4096]u8 = undefined;
        var writer = self.stream.writer(self.io, &write_buf);
        try writer.interface.writeAll(header_buf.items);

        if (!omit_body and len > 0) {
            var block: [16 * 1024]u8 = undefined;
            var remaining = len;
            var pos = offset;
            while (remaining > 0) {
                const want = @min(remaining, block.len);
                const n = try file.readPositionalAll(self.io, block[0..want], pos);
                // A short read before `len` bytes means the file was truncated
                // out from under us (the size was stat'd earlier). The framing
                // promised `len`, so this connection can only be abandoned.
                if (n == 0) return error.UnexpectedEndOfFile;
                try writer.interface.writeAll(block[0..n]);
                remaining -= n;
                pos += n;
            }
        }

        try writer.interface.flush();
        self.sent = true;
    }

    /// Begin a chunked (`Transfer-Encoding: chunked`) response for a body whose
    /// length is not known up front. Emits the status line and headers, then the
    /// caller streams the body with `writeChunk` and finishes with `endStream`.
    /// Chunked framing is self-delimiting, so keep-alive may continue afterward.
    ///
    /// A `HEAD` response has no body, so this collapses to sending just the
    /// headers and marking the response complete.
    pub fn beginStream(self: *Response) !void {
        if (self.sent) return error.AlreadySent;

        // Chunked framing carries the body length; a Content-Length would
        // conflict, so it must not be present.
        if (self.headers.get("Content-Length") != null) return error.InvalidHeader;
        try self.headers.set("Transfer-Encoding", "chunked");

        var header_buf: std.ArrayList(u8) = .empty;
        defer header_buf.deinit(self.allocator);
        try self.serializeHeaders(&header_buf);

        try self.gateWritable();
        var write_buf: [4096]u8 = undefined;
        var writer = self.stream.writer(self.io, &write_buf);
        try writer.interface.writeAll(header_buf.items);
        try writer.interface.flush();

        // HEAD: headers only, no chunk stream. Mark done so writeChunk/endStream
        // are rejected and the connection can move on.
        if (self.head_only) {
            self.sent = true;
        } else {
            self.streaming = true;
        }
    }

    /// Write one `Transfer-Encoding: chunked` chunk. Empty writes are skipped
    /// because a zero-length chunk is the terminator that `endStream` emits.
    pub fn writeChunk(self: *Response, data: []const u8) !void {
        if (!self.streaming) return error.NotStreaming;
        if (data.len == 0) return;

        try self.gateWritable();
        var write_buf: [4096]u8 = undefined;
        var writer = self.stream.writer(self.io, &write_buf);
        // chunk-size (hex) CRLF, chunk-data, CRLF
        try writer.interface.print("{x}\r\n", .{data.len});
        try writer.interface.writeAll(data);
        try writer.interface.writeAll("\r\n");
        try writer.interface.flush();
    }

    /// Emit the terminating zero-length chunk and complete the response.
    pub fn endStream(self: *Response) !void {
        if (!self.streaming) return error.NotStreaming;

        try self.gateWritable();
        var write_buf: [4096]u8 = undefined;
        var writer = self.stream.writer(self.io, &write_buf);
        try writer.interface.writeAll("0\r\n\r\n");
        try writer.interface.flush();

        self.streaming = false;
        self.sent = true;
    }

    pub fn json(self: *Response, value: anytype) !void {
        _ = try self.setHeader("Content-Type", "application/json");

        // Use std.json.Stringify with Io.Writer
        var json_buf: std.ArrayList(u8) = .empty;
        defer json_buf.deinit(self.allocator);

        // Create Io.Writer
        var writer_impl: std.Io.Writer.Allocating = .init(self.allocator);
        defer writer_impl.deinit();

        // Create Stringify instance
        var stringify: std.json.Stringify = .{
            .writer = &writer_impl.writer,
        };

        // Write the value
        try stringify.write(value);

        // Get written data
        try self.send(writer_impl.written());
    }

    pub fn html(self: *Response, data: []const u8) !void {
        _ = try self.setHeader("Content-Type", "text/html; charset=utf-8");
        try self.send(data);
    }

    pub fn text(self: *Response, data: []const u8) !void {
        _ = try self.setHeader("Content-Type", "text/plain; charset=utf-8");
        try self.send(data);
    }

    /// Set `Last-Modified` from `unix_secs` (seconds since the Unix epoch, UTC)
    /// as an RFC 9110 IMF-fixdate. Pairs with `Request.ifModifiedSince` to drive
    /// a `304 Not Modified` conditional response.
    pub fn setLastModified(self: *Response, unix_secs: i64) !*Response {
        var buf: [http_date_len]u8 = undefined;
        return self.setHeader("Last-Modified", writeHttpDate(&buf, unix_secs));
    }

    /// Set a cookie with optional parameters.
    ///
    /// Every caller-supplied component is validated up front: a cookie name that
    /// is not an RFC 7230 token, or a value/attribute carrying CR/LF/NUL or a
    /// stray `;`, would let attacker-tainted input inject extra cookie
    /// attributes or split the response into forged headers. `SameSite=None` is
    /// additionally rejected without `Secure`, matching the modern browser rule
    /// that cross-site cookies must be Secure.
    pub fn setCookie(self: *Response, name: []const u8, value: []const u8, options: CookieOptions) !*Response {
        if (!http_parser.isToken(name)) return error.InvalidCookieName;
        if (!validCookieComponent(value)) return error.InvalidCookieValue;
        if (options.path) |p| {
            if (!validCookieComponent(p)) return error.InvalidCookieAttribute;
        }
        if (options.domain) |d| {
            if (!validCookieComponent(d)) return error.InvalidCookieAttribute;
        }
        if (options.same_site) |same_site| {
            const is_strict = std.mem.eql(u8, same_site, "Strict");
            const is_lax = std.mem.eql(u8, same_site, "Lax");
            const is_none = std.mem.eql(u8, same_site, "None");
            if (!is_strict and !is_lax and !is_none) return error.InvalidSameSite;
            // A SameSite=None cookie is sent on cross-site requests; browsers
            // only honour it when Secure, so emitting one without Secure is a
            // silent no-op at best and a downgrade vector at worst.
            if (is_none and !options.secure) return error.InsecureSameSiteNone;
        }

        var cookie_value: std.ArrayList(u8) = .empty;
        defer cookie_value.deinit(self.allocator);

        // name=value
        try cookie_value.appendSlice(self.allocator, name);
        try cookie_value.append(self.allocator, '=');
        try cookie_value.appendSlice(self.allocator, value);

        // Max-Age
        if (options.max_age) |max_age| {
            try cookie_value.appendSlice(self.allocator, "; Max-Age=");
            const age_str = try std.fmt.allocPrint(self.allocator, "{d}", .{max_age});
            defer self.allocator.free(age_str);
            try cookie_value.appendSlice(self.allocator, age_str);
        }

        // Path
        if (options.path) |path| {
            try cookie_value.appendSlice(self.allocator, "; Path=");
            try cookie_value.appendSlice(self.allocator, path);
        }

        // Domain
        if (options.domain) |domain| {
            try cookie_value.appendSlice(self.allocator, "; Domain=");
            try cookie_value.appendSlice(self.allocator, domain);
        }

        // Secure
        if (options.secure) {
            try cookie_value.appendSlice(self.allocator, "; Secure");
        }

        // HttpOnly
        if (options.http_only) {
            try cookie_value.appendSlice(self.allocator, "; HttpOnly");
        }

        // SameSite
        if (options.same_site) |same_site| {
            try cookie_value.appendSlice(self.allocator, "; SameSite=");
            try cookie_value.appendSlice(self.allocator, same_site);
        }

        // Append as its own Set-Cookie line; ownership transfers to the list.
        const cookie_str = try self.allocator.dupe(u8, cookie_value.items);
        errdefer self.allocator.free(cookie_str);
        try self.set_cookies.append(self.allocator, cookie_str);

        return self;
    }

    /// Upgrade connection to WebSocket
    pub fn upgradeWebSocket(self: *Response, req: *Request) !*websocket.WebSocket {
        if (self.sent) return error.AlreadySent;

        // Validate WebSocket upgrade headers
        const upgrade_header = req.getHeader("upgrade") orelse return error.MissingUpgradeHeader;
        _ = req.getHeader("connection") orelse return error.MissingConnectionHeader;
        const ws_key = req.getHeader("sec-websocket-key") orelse return error.MissingWebSocketKey;

        // Check for "websocket" in upgrade header (case insensitive)
        var upgrade_lower: [32]u8 = undefined;
        const upgrade_normalized = std.ascii.lowerString(&upgrade_lower, upgrade_header);
        if (std.mem.indexOf(u8, upgrade_normalized, "websocket") == null) {
            return error.InvalidUpgradeHeader;
        }

        // Generate WebSocket accept key
        const magic_string = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
        const combined = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ ws_key, magic_string });
        defer self.allocator.free(combined);

        var hasher = std.crypto.hash.Sha1.init(.{});
        hasher.update(combined);
        var hash: [20]u8 = undefined;
        hasher.final(&hash);

        // Base64 encode
        const encoder = std.base64.standard.Encoder;
        var encoded: [28]u8 = undefined;
        const accept_key = encoder.encode(&encoded, &hash);

        // Send 101 Switching Protocols response
        var header_buf: std.ArrayList(u8) = .empty;
        defer header_buf.deinit(self.allocator);

        try header_buf.appendSlice(self.allocator, "HTTP/1.1 101 Switching Protocols\r\n");
        try header_buf.appendSlice(self.allocator, "Upgrade: websocket\r\n");
        try header_buf.appendSlice(self.allocator, "Connection: Upgrade\r\n");
        try header_buf.appendSlice(self.allocator, "Sec-WebSocket-Accept: ");
        try header_buf.appendSlice(self.allocator, accept_key);
        try header_buf.appendSlice(self.allocator, "\r\n\r\n");

        // Write handshake response
        var write_buf: [512]u8 = undefined;
        var writer = self.stream.writer(self.io, &write_buf);
        try writer.interface.writeAll(header_buf.items);

        self.sent = true;

        // Generate unique ID
        var id_bytes: [8]u8 = undefined;
        self.io.random(&id_bytes);
        const id = try std.fmt.allocPrint(self.allocator, "ws_{d}", .{std.mem.readInt(u64, &id_bytes, .little)});
        defer self.allocator.free(id);

        // Create and return WebSocket, handing it the same stream and Io runtime
        // that served the request.
        const ws = try self.allocator.create(websocket.WebSocket);
        ws.* = try websocket.WebSocket.init(self.allocator, self.io, self.stream, id);
        return ws;
    }
};

pub const RouteHandler = *const fn (req: *Request, res: *Response) anyerror!void;

/// A middleware receives the request/response plus the running `Chain`. It runs
/// its "before" work, calls `next.next()` to invoke the rest of the pipeline
/// (later middleware, then the route handler), and then runs any "after" work
/// once that returns — the onion model. Skipping `next.next()` short-circuits
/// the pipeline (e.g. an auth failure that has already written a response).
pub const MiddlewareFn = *const fn (req: *Request, res: *Response, next: *Chain) anyerror!void;

/// Ordered middleware pipeline terminating in the route handler.
///
/// `next` walks a single cursor forward: each call runs the stage at the cursor
/// and advances it by one, so a middleware that calls `next.next()` exactly once
/// runs the following stage exactly once. When the middleware list is exhausted
/// the terminal handler runs (also exactly once); further calls are no-ops so a
/// stray extra `next.next()` cannot double-invoke the handler.
pub const Chain = struct {
    req: *Request,
    res: *Response,
    middlewares: []const MiddlewareFn,
    handler: RouteHandler,
    index: usize = 0,

    pub fn next(self: *Chain) anyerror!void {
        const i = self.index;
        self.index += 1;
        if (i < self.middlewares.len) {
            try self.middlewares[i](self.req, self.res, self);
        } else if (i == self.middlewares.len) {
            try self.handler(self.req, self.res);
        }
        // i > middlewares.len: the pipeline is already exhausted; ignore the
        // surplus invocation rather than run the handler again.
    }
};

/// Whether a route pattern segment is a `:name` capture (a leading colon plus a
/// non-empty name). A bare `:` is treated as a literal segment, not a capture.
fn isParamSegment(seg: []const u8) bool {
    return seg.len >= 2 and seg[0] == ':';
}

/// Match a registered route `pattern` against a request `path`, returning the
/// number of `:name` captures on a match and null on a mismatch.
///
/// Matching is segment-wise on '/': the two must split into the same number of
/// segments, each literal pattern segment must equal the corresponding path
/// segment byte-for-byte, and each `:name` segment matches any single non-empty
/// segment. This makes the trailing slash significant (`/a` and `/a/` split into
/// different segment counts, so they never collide) and keeps `%2F` inside a
/// segment literal rather than acting as a separator. Only captured values are
/// percent-decoded (in `bindParams`); static segments are compared as received.
fn matchRoute(pattern: []const u8, path: []const u8) ?usize {
    var pit = std.mem.splitScalar(u8, pattern, '/');
    var sit = std.mem.splitScalar(u8, path, '/');
    var params: usize = 0;
    while (true) {
        const p = pit.next();
        const s = sit.next();
        if (p == null and s == null) return params; // exhausted in lockstep
        if (p == null or s == null) return null; // differing segment counts
        const pseg = p.?;
        const sseg = s.?;
        if (isParamSegment(pseg)) {
            // A capture must bind a real segment; an empty one (e.g. a double
            // slash or trailing slash) is not a value.
            if (sseg.len == 0) return null;
            params += 1;
        } else if (!std.mem.eql(u8, pseg, sseg)) {
            return null;
        }
    }
}

/// Percent-decode one path segment into a freshly allocated buffer. A truncated
/// or non-hex `%` escape is rejected (`error.BadPercentEncoding`) so a malformed
/// request yields 400 rather than a silently mangled parameter. `+` is left
/// literal — plus-as-space is a query-string convention, not a path one.
fn percentDecodeSegment(allocator: std.mem.Allocator, seg: []const u8) ![]u8 {
    // Decoding never grows the input, so one segment-sized buffer suffices.
    const buf = try allocator.alloc(u8, seg.len);
    errdefer allocator.free(buf);
    var w: usize = 0;
    var i: usize = 0;
    while (i < seg.len) {
        if (seg[i] == '%') {
            if (i + 3 > seg.len) return error.BadPercentEncoding;
            const hi = std.fmt.charToDigit(seg[i + 1], 16) catch return error.BadPercentEncoding;
            const lo = std.fmt.charToDigit(seg[i + 2], 16) catch return error.BadPercentEncoding;
            buf[w] = @as(u8, hi) * 16 + @as(u8, lo);
            i += 3;
        } else {
            buf[w] = seg[i];
            i += 1;
        }
        w += 1;
    }
    // A decoded escape shrinks the segment; hand back an allocation sized to the
    // result so the returned slice is independently freeable (freeing a
    // sub-slice of the original buffer is a size mismatch).
    if (w != buf.len) return allocator.realloc(buf, w);
    return buf;
}

/// Populate `map` with the `:name` captures of `pattern` from `path`, decoding
/// each captured segment. Assumes `matchRoute(pattern, path)` already reported a
/// match, so the two split into equal segment counts. Propagates
/// `error.BadPercentEncoding` from a malformed capture.
fn bindParams(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    path: []const u8,
    map: *std.StringHashMap([]const u8),
) !void {
    var pit = std.mem.splitScalar(u8, pattern, '/');
    var sit = std.mem.splitScalar(u8, path, '/');
    while (true) {
        const p = pit.next() orelse break;
        const s = sit.next() orelse break;
        if (!isParamSegment(p)) continue;
        const value = try percentDecodeSegment(allocator, s);
        errdefer allocator.free(value);
        const name = try allocator.dupe(u8, p[1..]);
        errdefer allocator.free(name);
        try map.put(name, value);
    }
}

pub const Route = struct {
    method: Method,
    path: []const u8,
    handler: RouteHandler,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Route) void {
        self.allocator.free(self.path);
    }
};

pub const ServerConfig = struct {
    port: u16,
    host: []const u8 = "0.0.0.0",
    /// Wall-clock budget for reading one complete request (headers + declared
    /// body), in milliseconds. Enforced as an absolute deadline across all
    /// socket reads, so a slow-send ("slowloris") client that dribbles bytes
    /// cannot hold a worker open indefinitely. 0 (or negative) disables it.
    read_timeout_ms: i32 = 30_000,
    /// Budget for gaining socket writability before sending a response, in
    /// milliseconds. 0 (or negative) disables it.
    write_timeout_ms: i32 = 30_000,
    /// Number of worker threads that concurrently accept and handle
    /// connections. Each worker owns one connection at a time and closes it as
    /// soon as the request is served, so this is the hard cap on connections
    /// handled in parallel. 0 derives a bounded default from the CPU count.
    /// Values above `max_workers` are clamped so the pool is never unbounded.
    ///
    /// When more than one worker runs the server allocator must be thread-safe:
    /// each worker allocates its own per-connection arena from it concurrently.
    worker_count: usize = 0,
    /// Maximum number of requests served on one keep-alive connection before the
    /// server closes it (sending `Connection: close` on the last response). Caps
    /// how long a single client can monopolize a worker. Must be >= 1.
    max_keepalive_requests: usize = 100,
};

/// Upper bound on pool size, independent of a huge configured value or an
/// unusual CPU count, so the worker pool can never be unbounded.
const max_workers = 256;

/// Resolve the configured worker count into a concrete thread count, always in
/// `[1, max_workers]`: 0 means "derive from CPU count", and both the configured
/// and derived paths are clamped so the pool is neither zero-sized (which would
/// accept nothing) nor unbounded.
fn resolveWorkerCount(configured: usize, cpu_count: usize) usize {
    if (configured != 0) return @min(configured, max_workers);
    const derived = if (cpu_count == 0) 1 else cpu_count;
    return @min(derived, max_workers);
}

/// Whether a served connection may be reused for another request.
const Persistence = enum { keep_alive, close };

/// One fully framed request plus whether the socket read overshot into a
/// following request (i.e. the client pipelined). `data` is owned by the caller.
const Framed = struct {
    data: []u8,
    pipelined: bool,
};

pub const Server = struct {
    config: ServerConfig,
    tcp_server: tcp.TcpServer,
    routes: std.ArrayList(Route),
    middlewares: std.ArrayList(MiddlewareFn),
    allocator: std.mem.Allocator,
    /// Worker threads spawned by `start`/`listen`. Empty until the pool runs;
    /// reset to empty once joined.
    workers: []std.Thread = &.{},
    /// Set from any thread by `requestStop` to break the worker accept loops.
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(allocator: std.mem.Allocator, config: ServerConfig) !Server {
        const tcp_server = try tcp.TcpServer.init(allocator, config.host, config.port);

        return Server{
            .config = config,
            .tcp_server = tcp_server,
            .routes = .empty,
            .middlewares = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Server) void {
        // If the caller never joined the pool, stop and join it now so no worker
        // thread outlives the server it borrows (`tcp_server`, routes, allocator).
        if (self.workers.len != 0) self.shutdown();
        self.tcp_server.deinit();
        for (self.routes.items) |*route_item| {
            route_item.deinit();
        }
        self.routes.deinit(self.allocator);
        self.middlewares.deinit(self.allocator);
    }

    /// Add middleware to server
    pub fn use(self: *Server, middleware: MiddlewareFn) !void {
        try self.middlewares.append(self.allocator, middleware);
    }

    pub fn route(self: *Server, method: []const u8, path: []const u8, handler: RouteHandler) !void {
        const method_enum = Method.fromString(method) orelse return error.InvalidMethod;

        const path_copy = try self.allocator.dupe(u8, path);
        // If the append below fails, ownership of path_copy never transfers to
        // the routes list, so free it here rather than leaking it.
        errdefer self.allocator.free(path_copy);

        const route_obj = Route{
            .method = method_enum,
            .path = path_copy,
            .handler = handler,
            .allocator = self.allocator,
        };

        try self.routes.append(self.allocator, route_obj);
    }

    /// Start the bounded worker pool and block until the server is stopped.
    ///
    /// Concurrency model: `worker_count` threads each block in `accept` on the
    /// shared listening socket (the kernel serializes concurrent `accept`s and
    /// load-balances connections across them) and handle one connection at a
    /// time. A connection's lifetime is scoped to a single worker's
    /// `serveConnection` call — it is closed the moment its request is served,
    /// never held for the lifetime of the accept loop. Parallelism is therefore
    /// bounded exactly by the worker count.
    ///
    /// Blocks until another thread calls `requestStop`/`shutdown`; then every
    /// worker's blocked `accept` is cancelled, they finish any in-flight
    /// connection, and this returns once all have joined.
    pub fn listen(self: *Server) !void {
        try self.start();
        self.joinWorkers();
    }

    /// Spawn the worker pool and return immediately. Pair with `shutdown` (or
    /// let `deinit` clean up). Concurrency is bounded to a clamped, non-zero
    /// worker count; see `resolveWorkerCount`.
    pub fn start(self: *Server) !void {
        // The library stays silent about lifecycle; announcing the bound address
        // is a presentation concern owned by the caller (e.g. the `nexus serve`
        // CLI prints its own banner). Keeping `start` quiet stops ~30 in-process
        // server tests from spamming "Server listening" and leaves stderr for
        // real diagnostics.
        const n = resolveWorkerCount(self.config.worker_count, std.Thread.getCpuCount() catch 1);
        const workers = try self.allocator.alloc(std.Thread, n);
        errdefer self.allocator.free(workers);

        var spawned: usize = 0;
        // If a later spawn fails, stop and join the workers already running so a
        // partially started pool never leaks threads out of `start`.
        errdefer {
            self.stop_requested.store(true, .seq_cst);
            self.tcp_server.shutdownListener();
            for (workers[0..spawned]) |t| t.join();
        }
        while (spawned < n) : (spawned += 1) {
            workers[spawned] = try std.Thread.spawn(.{}, workerMain, .{self});
        }
        self.workers = workers;
    }

    /// Signal the pool to stop and cancel any blocked `accept`. Safe to call
    /// from any thread. Does not wait for workers; use `shutdown` (or `listen`'s
    /// return) to join them.
    pub fn requestStop(self: *Server) void {
        self.stop_requested.store(true, .seq_cst);
        self.tcp_server.shutdownListener();
    }

    /// Stop the pool and wait for every worker to finish its current connection
    /// and exit. Idempotent: a no-op once the pool has been joined.
    pub fn shutdown(self: *Server) void {
        if (self.workers.len == 0) return;
        self.requestStop();
        self.joinWorkers();
    }

    fn joinWorkers(self: *Server) void {
        for (self.workers) |t| t.join();
        self.allocator.free(self.workers);
        self.workers = &.{};
    }

    /// One worker thread: block in `accept`, hand each connection to
    /// `serveConnection`, and repeat until stop is requested. A cancelled or
    /// transiently failing `accept` re-checks the stop flag rather than
    /// propagating, so one bad accept neither kills the worker mid-service nor
    /// spins after shutdown.
    fn workerMain(self: *Server) void {
        while (!self.stop_requested.load(.acquire)) {
            var conn = self.tcp_server.accept() catch {
                if (self.stop_requested.load(.acquire)) break;
                continue;
            };
            self.serveConnection(&conn);
        }
    }

    /// Serve one connection to completion, then close it.
    ///
    /// The socket is reused for successive requests (HTTP/1.1 keep-alive) until
    /// the client asks to close, the per-connection request cap is reached, or a
    /// shutdown is in progress. The close is scoped to this call so the socket is
    /// released the moment the connection is done rather than deferred for the
    /// process lifetime.
    ///
    /// The stop flag is observed between requests, so a keep-alive connection
    /// idling between requests is only reclaimed once its next read wait expires
    /// (bounded by `read_timeout_ms`); prompt interruption of that idle wait is
    /// out of scope here and handled with the graceful-shutdown work.
    fn serveConnection(self: *Server, conn: *tcp.TcpConnection) void {
        defer conn.close();
        conn.write_timeout_ms = self.config.write_timeout_ms;

        // A cap of 0 is meaningless (serve nothing); treat it as "one request".
        const max = if (self.config.max_keepalive_requests == 0) 1 else self.config.max_keepalive_requests;
        var served: usize = 0;
        while (true) {
            served += 1;
            // Force close after the cap, or as soon as a stop is requested, so a
            // keep-alive client can never hold a worker past a shutdown or
            // monopolize it beyond the configured budget.
            const force_close = served >= max or self.stop_requested.load(.acquire);
            const outcome = self.handleConnection(conn, force_close) catch |err| {
                std.debug.print("Error handling connection: {}\n", .{err});
                break;
            };
            if (outcome == .close) break;
        }
    }

    /// Read, parse, route, and answer one request. Returns whether the
    /// connection may be reused for another request.
    ///
    /// `force_close` overrides any client keep-alive wish (the request cap was
    /// hit or a shutdown is running). A framing/parse failure, a pipelined read,
    /// or an HTTP/1.0-style close all resolve to `.close` and end the loop.
    fn handleConnection(self: *Server, conn: *tcp.TcpConnection, force_close: bool) !Persistence {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        // Read one complete, bounded request rather than trusting a single
        // socket read to contain a whole request. A malformed or oversized
        // request gets a 400 instead of a bare connection reset.
        const framed = self.readFullRequest(arena_allocator, conn) catch |err| {
            // A stalled peer that blew the read deadline gets 408; anything else
            // malformed gets 400. Both are best-effort before the connection closes.
            const code: StatusCode = if (err == error.ReadTimeout) .RequestTimeout else .BadRequest;
            self.sendErrorResponse(conn, code);
            return .close;
        };
        const f = framed orelse return .close; // peer closed before sending a request

        // Parse request
        var req = self.parseRequest(arena_allocator, f.data) catch |err| {
            // A chunked (or otherwise unsupported) transfer coding is a request
            // this server will not decode; answer 501 so the distinction from a
            // genuinely malformed 400 is honest.
            const code: StatusCode = if (err == error.UnsupportedTransferEncoding) .NotImplemented else .BadRequest;
            self.sendErrorResponse(conn, code);
            return .close;
        };
        defer req.deinit();

        // Create response
        var res = Response.init(arena_allocator, conn.stream, conn.io.io());
        res.write_timeout_ms = self.config.write_timeout_ms;
        defer res.deinit();

        // Decide persistence before dispatch so the handler sees the correct
        // Connection header and the loop knows whether to continue. A pipelined
        // read forces close: this server serves one request per round trip and
        // does not process a second request buffered behind the first.
        const persistent = self.requestPersistence(&req) and !force_close and !f.pipelined;
        try res.headers.set("Connection", if (persistent) "keep-alive" else "close");

        try self.dispatch(&req, &res);

        return if (persistent) .keep_alive else .close;
    }

    /// Route one parsed request to its handler and run middleware, applying the
    /// method semantics HTTP/1.1 requires:
    ///   * HEAD is served by the matching GET route with the body suppressed.
    ///   * OPTIONS on a known path returns 204 with an `Allow` header.
    ///   * A known path with no handler for the method returns 405 + `Allow`.
    ///   * An unknown path returns 404.
    fn dispatch(self: *Server, req: *Request, res: *Response) !void {
        // HEAD is a GET whose body is dropped on the wire (Response.head_only),
        // so it is routed against the GET handlers.
        const lookup: Method = if (req.method == .HEAD) .GET else req.method;
        if (req.method == .HEAD) res.head_only = true;

        // Choose the winning route deterministically: among routes whose pattern
        // matches this path and method, prefer the one with the fewest `:name`
        // captures (a fully static route beats a parameterized one), breaking
        // ties by registration order. `path_exists` tracks a path match under any
        // method so a wrong-method request can still answer 405 rather than 404.
        var path_exists = false;
        var best: ?Route = null;
        var best_params: usize = std.math.maxInt(usize);
        for (self.routes.items) |route_item| {
            const captures = matchRoute(route_item.path, req.path) orelse continue;
            path_exists = true;
            if (route_item.method != lookup) continue;
            if (captures < best_params) {
                best_params = captures;
                best = route_item;
            }
        }

        if (best) |route_item| {
            // Bind captures for the chosen route. A malformed percent-escape in a
            // captured segment is a client error, so answer 400 instead of
            // handing the handler a mangled parameter.
            bindParams(req.allocator, route_item.path, req.path, &req.params) catch {
                res.status_code = .BadRequest;
                try res.text("Bad Request");
                return;
            };

            // Run the middleware pipeline terminating in this handler. A
            // middleware that declines to call `next` (e.g. an auth failure that
            // already wrote a response) short-circuits the rest of the chain.
            var chain = Chain{
                .req = req,
                .res = res,
                .middlewares = self.middlewares.items,
                .handler = route_item.handler,
            };
            try chain.next();
            return;
        }

        // No handler ran. Distinguish "path exists, wrong method" (405/OPTIONS)
        // from a genuinely unknown path (404).
        if (path_exists) {
            try self.setAllowHeader(req, res);
            if (req.method == .OPTIONS) {
                res.status_code = .NoContent;
                try res.send("");
            } else {
                res.status_code = .MethodNotAllowed;
                try res.text("Method Not Allowed");
            }
            return;
        }

        res.status_code = .NotFound;
        try res.text("Not Found");
    }

    /// Set the `Allow` header for `req.path` from the registered routes. HEAD is
    /// implied wherever GET exists and OPTIONS is always offered, matching what
    /// `dispatch` actually serves. Methods are emitted in a fixed canonical
    /// order so the header is stable and testable.
    fn setAllowHeader(self: *Server, req: *Request, res: *Response) !void {
        var allowed = std.EnumSet(Method).empty;
        for (self.routes.items) |route_item| {
            if (matchRoute(route_item.path, req.path) != null) allowed.insert(route_item.method);
        }
        if (allowed.contains(.GET)) allowed.insert(.HEAD);
        allowed.insert(.OPTIONS);

        const order = [_]Method{ .GET, .HEAD, .POST, .PUT, .PATCH, .DELETE, .OPTIONS };
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(res.allocator);
        for (order) |m| {
            if (!allowed.contains(m)) continue;
            if (buf.items.len != 0) try buf.appendSlice(res.allocator, ", ");
            try buf.appendSlice(res.allocator, m.toString());
        }
        try res.headers.set("Allow", buf.items);
    }

    /// Whether the client's framing permits reusing the connection after this
    /// request. HTTP/1.1 defaults to keep-alive and HTTP/1.0 to close; an
    /// explicit `Connection` token overrides the version default either way.
    fn requestPersistence(self: *Server, req: *Request) bool {
        _ = self;
        const default_keep_alive = std.mem.eql(u8, req.parsed.http_version, "HTTP/1.1");
        const conn = req.getHeader("connection") orelse return default_keep_alive;
        // "close" always wins over "keep-alive" when both somehow appear.
        if (std.ascii.findIgnoreCase(conn, "close") != null) return false;
        if (std.ascii.findIgnoreCase(conn, "keep-alive") != null) return true;
        return default_keep_alive;
    }

    /// Read a single complete HTTP/1 request off the connection.
    ///
    /// Returns null when the peer closes without sending anything. Otherwise it
    /// accumulates socket reads until `http_parser.frame` reports a full
    /// request (header block plus the body declared by Content-Length), bounded
    /// by the parser's caps so a partial or oversized request cannot grow the
    /// buffer without limit. The returned `data` is exactly one request; if the
    /// read overshot into a following request the `Framed.pipelined` flag is set
    /// and those trailing bytes are dropped, since this server serves one
    /// request per round trip and closes rather than processing the pipelined
    /// remainder.
    fn readFullRequest(self: *Server, allocator: std.mem.Allocator, conn: *tcp.TcpConnection) !?Framed {
        var buffer: std.ArrayList(u8) = .empty;
        errdefer buffer.deinit(allocator);

        var chunk: [8192]u8 = undefined;

        // Absolute deadline shared by both read phases: every poll uses the time
        // still remaining, so a client that dribbles bytes just under a per-read
        // timeout still fails once the total budget is spent.
        const budget_ms = self.config.read_timeout_ms;
        const io = conn.io.io();
        const start_ns: i96 = std.Io.Timestamp.now(io, .awake).nanoseconds;

        // Phase 1: read until the header terminator is present. `frame` errors
        // if the header block exceeds its cap before a terminator appears.
        const total = while (true) {
            if (try http_parser.frame(buffer.items)) |framing| break framing.total;

            try conn.waitReadable(pollBudget(budget_ms, elapsedMs(io, start_ns)));
            const n = try conn.read(&chunk);
            if (n == 0) {
                if (buffer.items.len == 0) {
                    buffer.deinit(allocator);
                    return null;
                }
                return error.IncompleteRequest;
            }
            try buffer.appendSlice(allocator, chunk[0..n]);
        };

        // Phase 2: read the declared body to completion.
        while (buffer.items.len < total) {
            try conn.waitReadable(pollBudget(budget_ms, elapsedMs(io, start_ns)));
            const n = try conn.read(&chunk);
            if (n == 0) return error.IncompleteRequest;
            try buffer.appendSlice(allocator, chunk[0..n]);
        }

        // A buffer longer than the framed request means the client pipelined a
        // following request; report it so the caller closes after this one.
        const pipelined = buffer.items.len > total;
        buffer.shrinkRetainingCapacity(total);
        return Framed{ .data = try buffer.toOwnedSlice(allocator), .pipelined = pipelined };
    }

    /// Milliseconds elapsed since `start_ns` on the monotonic clock.
    fn elapsedMs(io: std.Io, start_ns: i96) i64 {
        const now_ns: i96 = std.Io.Timestamp.now(io, .awake).nanoseconds;
        return @intCast(@divFloor(now_ns - start_ns, std.time.ns_per_ms));
    }

    /// Poll timeout (ms) left before the read deadline given `elapsed_ms` spent.
    /// A non-positive budget disables the deadline (-1 blocks indefinitely).
    /// Once the budget is spent the timeout is 0, so `waitReadable` fails fast
    /// instead of blocking the accept loop on a stalled peer.
    fn pollBudget(budget_ms: i32, elapsed_ms: i64) i32 {
        if (budget_ms <= 0) return -1;
        const remaining = @as(i64, budget_ms) - elapsed_ms;
        if (remaining <= 0) return 0;
        return @intCast(remaining);
    }

    /// Best-effort minimal status response for requests that never reach a
    /// route (e.g. a malformed request). Write failures are ignored: the peer
    /// may already be gone, and there is no handler state to unwind.
    fn sendErrorResponse(self: *Server, conn: *tcp.TcpConnection, code: StatusCode) void {
        _ = self;
        var buf: [128]u8 = undefined;
        const reason = code.toString();
        const response = std.fmt.bufPrint(
            &buf,
            "HTTP/1.1 {d} {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
            .{ code.toInt(), reason, reason.len, reason },
        ) catch return;
        conn.writeAll(response) catch {};
    }

    fn parseRequest(self: *Server, allocator: std.mem.Allocator, data: []const u8) !Request {
        _ = self;

        // Use real HTTP parser
        var parser = http_parser.RequestParser.init(allocator);
        var parsed = try parser.parse(data);

        // Convert to Request struct
        const method = Method.fromString(parsed.method) orelse return error.InvalidMethod;

        // Create headers (already in parsed.headers)
        const headers = Headers.init(allocator);

        // Parse cookies from Cookie header
        var cookies = std.StringHashMap([]const u8).init(allocator);
        if (parsed.getHeader("cookie")) |cookie_header| {
            try parseCookies(allocator, cookie_header, &cookies);
        }

        return Request{
            .method = method,
            .path = parsed.path,
            .query_string = parsed.query_string,
            .headers = headers,
            .body = parsed.body,
            .allocator = allocator,
            .parsed = parsed,
            .cookies = cookies,
            .params = std.StringHashMap([]const u8).init(allocator),
        };
    }

    fn parseCookies(allocator: std.mem.Allocator, cookie_header: []const u8, cookies: *std.StringHashMap([]const u8)) !void {
        var iter = std.mem.splitScalar(u8, cookie_header, ';');
        while (iter.next()) |pair| {
            const trimmed = std.mem.trim(u8, pair, " \t");
            if (trimmed.len == 0) continue;

            if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq_pos| {
                const name = trimmed[0..eq_pos];
                const value = trimmed[eq_pos + 1 ..];

                const name_duped = try allocator.dupe(u8, name);
                errdefer allocator.free(name_duped);
                const value_duped = try allocator.dupe(u8, value);
                errdefer allocator.free(value_duped);

                try cookies.put(name_duped, value_duped);
            }
        }
    }
};

test "http method conversion" {
    try std.testing.expectEqual(Method.GET, Method.fromString("GET").?);
    try std.testing.expectEqualStrings("POST", Method.POST.toString());
}

test "resolveWorkerCount clamps into [1, max_workers] for every input" {
    // 0 means "derive from CPU count"; the derived value is clamped both ways.
    try std.testing.expectEqual(@as(usize, 1), resolveWorkerCount(0, 0)); // unknown cpu -> 1
    try std.testing.expectEqual(@as(usize, 4), resolveWorkerCount(0, 4)); // typical derive
    try std.testing.expectEqual(@as(usize, max_workers), resolveWorkerCount(0, 100_000)); // absurd cpu capped

    // Explicit values win but are still capped so the pool is never unbounded,
    // and never zero (which would accept nothing).
    try std.testing.expectEqual(@as(usize, 3), resolveWorkerCount(3, 1));
    try std.testing.expectEqual(@as(usize, max_workers), resolveWorkerCount(1_000_000, 8));
}

// Shared barrier state for the concurrency proof below. A route handler can only
// reach it through file scope because `RouteHandler` carries no user context.
const test_barrier_n = 3;
var test_barrier_arrived = std.atomic.Value(usize).init(0);

// Handler that blocks until `test_barrier_n` requests are being served at once.
// It can only succeed if that many handlers run simultaneously, so a serial
// server times out here while a pool with >= n workers rendezvouses and passes.
fn testBarrierHandler(req: *Request, res: *Response) anyerror!void {
    _ = req;
    _ = test_barrier_arrived.fetchAdd(1, .seq_cst);
    const start_ns: i96 = std.Io.Timestamp.now(res.io, .awake).nanoseconds;
    while (test_barrier_arrived.load(.seq_cst) < test_barrier_n) {
        const now_ns: i96 = std.Io.Timestamp.now(res.io, .awake).nanoseconds;
        if (now_ns - start_ns > 3 * std.time.ns_per_s) {
            res.status_code = .InternalServerError;
            try res.text("timeout");
            return;
        }
        std.Thread.yield() catch {};
    }
    try res.text("met");
}

const TestClientCtx = struct {
    allocator: std.mem.Allocator,
    port: u16,
    successes: *std.atomic.Value(usize),
};

fn testBarrierClient(ctx: *TestClientCtx) void {
    var client = tcp.TcpClient.init(ctx.allocator) catch return;
    defer client.deinit();
    client.connect("127.0.0.1", ctx.port) catch return;
    client.write("GET /barrier HTTP/1.1\r\nHost: t\r\n\r\n") catch return;

    var acc: std.ArrayList(u8) = .empty;
    defer acc.deinit(ctx.allocator);
    var buf: [4096]u8 = undefined;
    // The server closes the connection once the response is sent, so read to EOF.
    while (true) {
        const n = client.read(&buf) catch break;
        if (n == 0) break;
        acc.appendSlice(ctx.allocator, buf[0..n]) catch break;
    }
    if (std.mem.indexOf(u8, acc.items, "200 OK") != null and
        std.mem.indexOf(u8, acc.items, "met") != null)
    {
        _ = ctx.successes.fetchAdd(1, .seq_cst);
    }
}

test "bounded worker pool serves connections concurrently and shuts down clean" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    test_barrier_arrived.store(0, .seq_cst);

    var server = try Server.init(allocator, .{
        .port = 0,
        .host = "127.0.0.1",
        .worker_count = test_barrier_n,
        // Keep the read deadline short of the handler's 3s barrier deadline so a
        // hung test fails fast rather than pinning a worker.
        .read_timeout_ms = 5_000,
    });
    defer server.deinit();
    try server.route("GET", "/barrier", testBarrierHandler);

    try server.start();
    const port = server.tcp_server.boundPort();

    var successes = std.atomic.Value(usize).init(0);
    var ctx = TestClientCtx{ .allocator = allocator, .port = port, .successes = &successes };

    var clients: [test_barrier_n]std.Thread = undefined;
    var spawned: usize = 0;
    while (spawned < test_barrier_n) : (spawned += 1) {
        clients[spawned] = try std.Thread.spawn(.{}, testBarrierClient, .{&ctx});
    }
    for (clients[0..spawned]) |t| t.join();

    // All n handlers had to be in flight at once for the barrier to release, so
    // every client saw "met". A serial accept loop could never reach n.
    try std.testing.expectEqual(@as(usize, test_barrier_n), successes.load(.seq_cst));

    // Stop is honoured: every worker's blocked accept is cancelled and joins,
    // and the leak-checking allocator (via deinit) proves nothing was orphaned.
    server.shutdown();
    try std.testing.expectEqual(@as(usize, 0), server.workers.len);
}

// --- HTTP/1.1 framing / keep-alive / method-semantics tests (item 1000) ---
//
// These drive a real one-worker server over loopback so the framing, keep-alive
// loop, HEAD/OPTIONS/405/501 handling, chunked responses, and Connection-header
// persistence are exercised end to end on the wire, not just in isolation.

fn testHello(req: *Request, res: *Response) anyerror!void {
    _ = req;
    try res.text("hello");
}

// Streams a two-chunk body so the chunked-response framing is observable.
fn testStream(req: *Request, res: *Response) anyerror!void {
    _ = req;
    try res.beginStream();
    try res.writeChunk("Wiki");
    try res.writeChunk("pedia");
    try res.endStream();
}

// Echoes the request body verbatim, so a test can prove the server reassembled
// a body delivered across many socket reads with the bytes intact and in order.
fn testEcho(req: *Request, res: *Response) anyerror!void {
    try res.text(req.body);
}

/// Open a connection, send `request`, and read until the server closes the
/// socket, returning the full raw response. Requires the request (or server
/// policy) to close the connection so the read terminates. Caller owns the slice.
fn httpRoundTrip(allocator: std.mem.Allocator, port: u16, request: []const u8) ![]u8 {
    var client = try tcp.TcpClient.init(allocator);
    defer client.deinit();
    try client.connect("127.0.0.1", port);
    try client.write(request);

    var acc: std.ArrayList(u8) = .empty;
    errdefer acc.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = client.read(&buf) catch break;
        if (n == 0) break;
        try acc.appendSlice(allocator, buf[0..n]);
    }
    return acc.toOwnedSlice(allocator);
}

/// Length of the first complete Content-Length-framed response in `data`, or
/// null if more bytes are needed. Only understands the fixed-length responses
/// these tests generate, which is enough to split keep-alive responses apart.
fn frameResponse(data: []const u8) ?usize {
    const term = std.mem.indexOf(u8, data, "\r\n\r\n") orelse return null;
    const header_end = term + 4;
    var total = header_end;
    if (std.ascii.findIgnoreCase(data[0..header_end], "content-length:")) |pos| {
        var i = pos + "content-length:".len;
        while (i < header_end and data[i] == ' ') i += 1;
        var j = i;
        while (j < header_end and data[j] >= '0' and data[j] <= '9') j += 1;
        const cl = std.fmt.parseInt(usize, data[i..j], 10) catch return null;
        total = header_end + cl;
    }
    if (data.len < total) return null;
    return total;
}

/// Read exactly one response off `client`, buffering any overshoot in `acc` for
/// the next call. Returns an owned copy of that one response.
fn recvOneResponse(client: *tcp.TcpClient, allocator: std.mem.Allocator, acc: *std.ArrayList(u8)) ![]u8 {
    var buf: [1024]u8 = undefined;
    while (true) {
        if (frameResponse(acc.items)) |total| {
            const out = try allocator.dupe(u8, acc.items[0..total]);
            const rem = acc.items.len - total;
            std.mem.copyForwards(u8, acc.items[0..rem], acc.items[total..]);
            acc.shrinkRetainingCapacity(rem);
            return out;
        }
        const n = try client.read(&buf);
        if (n == 0) return error.Closed;
        try acc.appendSlice(allocator, buf[0..n]);
    }
}

test "HEAD returns GET headers with no body" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var server = try Server.init(allocator, .{ .port = 0, .host = "127.0.0.1", .worker_count = 1 });
    defer server.deinit();
    try server.route("GET", "/hi", testHello);
    try server.start();
    const port = server.tcp_server.boundPort();

    const resp = try httpRoundTrip(allocator, port, "HEAD /hi HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n");
    defer allocator.free(resp);

    // Status and the GET's Content-Length are present, but the body is not: a
    // HEAD response is byte-identical to GET minus the entity body.
    try std.testing.expect(std.mem.indexOf(u8, resp, "200 OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "Content-Length: 5") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "hello") == null);
}

test "a server rebinds its port after a graceful shutdown" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    // First lifetime: serve one request on an OS-assigned port, then let the
    // whole server tear down (graceful shutdown joins the workers and closes the
    // listening socket). The served connection is actively closed by the server,
    // so its port lingers in kernel TIME_WAIT — exactly the state that makes a
    // naive rebind fail with AddressInUse.
    const port = blk: {
        var first = try Server.init(allocator, .{ .port = 0, .host = "127.0.0.1", .worker_count = 1 });
        defer first.deinit();
        try first.route("GET", "/hi", testHello);
        try first.start();
        const p = first.tcp_server.boundPort();

        const resp = try httpRoundTrip(allocator, p, "GET /hi HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n");
        allocator.free(resp);
        break :blk p;
    };

    // Second lifetime: bind the *same* concrete port and serve again. With
    // SO_REUSEADDR this must succeed immediately rather than failing while the
    // prior connection is still in TIME_WAIT — the whole point of the fix.
    var second = try Server.init(allocator, .{ .port = port, .host = "127.0.0.1", .worker_count = 1 });
    defer second.deinit();
    try second.route("GET", "/hi", testHello);
    try second.start();
    try std.testing.expectEqual(port, second.tcp_server.boundPort());

    const resp2 = try httpRoundTrip(allocator, port, "GET /hi HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n");
    defer allocator.free(resp2);
    try std.testing.expect(std.mem.indexOf(u8, resp2, "200 OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp2, "hello") != null);
}

test "OPTIONS on a known path returns 204 with Allow" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var server = try Server.init(allocator, .{ .port = 0, .host = "127.0.0.1", .worker_count = 1 });
    defer server.deinit();
    try server.route("GET", "/r", testHello);
    try server.route("POST", "/r", testHello);
    try server.start();
    const port = server.tcp_server.boundPort();

    const resp = try httpRoundTrip(allocator, port, "OPTIONS /r HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n");
    defer allocator.free(resp);

    try std.testing.expect(std.mem.indexOf(u8, resp, "204 No Content") != null);
    // GET implies HEAD, OPTIONS is always offered, emitted in canonical order.
    try std.testing.expect(std.mem.indexOf(u8, resp, "Allow: GET, HEAD, POST, OPTIONS") != null);
}

test "wrong method on a known path returns 405 with Allow" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var server = try Server.init(allocator, .{ .port = 0, .host = "127.0.0.1", .worker_count = 1 });
    defer server.deinit();
    try server.route("GET", "/r", testHello);
    try server.start();
    const port = server.tcp_server.boundPort();

    const resp = try httpRoundTrip(allocator, port, "DELETE /r HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n");
    defer allocator.free(resp);

    try std.testing.expect(std.mem.indexOf(u8, resp, "405 Method Not Allowed") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "Allow: GET, HEAD, OPTIONS") != null);
}

// --- Route-parameter matching tests (item 1011) ---

// Echoes the captured `:id` back so a test can assert the decoded value crossed
// the wire. Prefixed so a missing capture is visibly distinct from an empty one.
fn testEchoId(req: *Request, res: *Response) anyerror!void {
    const id = req.getParam("id") orelse "<none>";
    try res.text(id);
}

// A fully static route registered on the same shape as a parameterized one, to
// prove static wins the precedence tie.
fn testStaticMarker(req: *Request, res: *Response) anyerror!void {
    _ = req;
    try res.text("STATIC");
}

// A fixed resource modification time (2023-11-14T22:13:20Z) used by the
// conditional-request handler below so the 304 flow is deterministic.
const test_resource_mtime: i64 = 1_700_000_000;

// Answers a conditional GET: 304 when the client's If-Modified-Since is at or
// after the resource mtime, otherwise a normal 200 carrying Last-Modified.
fn testConditional(req: *Request, res: *Response) anyerror!void {
    if (req.ifModifiedSince()) |since| {
        if (since >= test_resource_mtime) {
            res.status_code = .NotModified;
            _ = try res.setLastModified(test_resource_mtime);
            try res.send("");
            return;
        }
    }
    _ = try res.setLastModified(test_resource_mtime);
    try res.text("fresh-body");
}

// Replies 204 No Content with an empty body, exercising the bodyless path.
fn testNoContent(req: *Request, res: *Response) anyerror!void {
    _ = req;
    res.status_code = .NoContent;
    try res.send("");
}

test "matchRoute counts captures, respects segment count, and keeps trailing slash significant" {
    // Static exact match, zero captures.
    try std.testing.expectEqual(@as(?usize, 0), matchRoute("/api/todos", "/api/todos"));
    // One capture binds one segment.
    try std.testing.expectEqual(@as(?usize, 1), matchRoute("/api/todos/:id", "/api/todos/42"));
    // Two captures.
    try std.testing.expectEqual(@as(?usize, 2), matchRoute("/u/:a/p/:b", "/u/1/p/2"));
    // Differing segment counts never match.
    try std.testing.expectEqual(@as(?usize, null), matchRoute("/api/todos", "/api/todos/42"));
    // Trailing slash is a distinct segment, so it does not collide.
    try std.testing.expectEqual(@as(?usize, null), matchRoute("/api/todos/:id", "/api/todos/42/"));
    try std.testing.expectEqual(@as(?usize, null), matchRoute("/api/todos", "/api/todos/"));
    // A capture cannot bind an empty segment.
    try std.testing.expectEqual(@as(?usize, null), matchRoute("/api/todos/:id", "/api/todos/"));
    // A literal mismatch fails even with matching arity.
    try std.testing.expectEqual(@as(?usize, null), matchRoute("/api/users/:id", "/api/todos/42"));
    // A bare ":" is literal, not a capture.
    try std.testing.expectEqual(@as(?usize, 0), matchRoute("/a/:", "/a/:"));
    try std.testing.expectEqual(@as(?usize, null), matchRoute("/a/:", "/a/x"));
}

test "percentDecodeSegment decodes escapes, keeps %2F literal, and rejects malformed input" {
    const a = std.testing.allocator;

    const ok = try percentDecodeSegment(a, "a%20b");
    defer a.free(ok);
    try std.testing.expectEqualStrings("a b", ok);

    // %2F decodes to a literal '/', which stays inside the segment because the
    // split happened before decoding.
    const slash = try percentDecodeSegment(a, "a%2Fb");
    defer a.free(slash);
    try std.testing.expectEqualStrings("a/b", slash);

    // Lower-case hex and a plain segment both round-trip.
    const plain = try percentDecodeSegment(a, "42");
    defer a.free(plain);
    try std.testing.expectEqualStrings("42", plain);

    // Truncated and non-hex escapes are rejected.
    try std.testing.expectError(error.BadPercentEncoding, percentDecodeSegment(a, "a%2"));
    try std.testing.expectError(error.BadPercentEncoding, percentDecodeSegment(a, "a%"));
    try std.testing.expectError(error.BadPercentEncoding, percentDecodeSegment(a, "a%zz"));
}

test "a parameterized route captures a percent-decoded value" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var server = try Server.init(allocator, .{ .port = 0, .host = "127.0.0.1", .worker_count = 1 });
    defer server.deinit();
    try server.route("GET", "/api/todos/:id", testEchoId);
    try server.start();
    const port = server.tcp_server.boundPort();

    // %20 in the id must reach the handler decoded to a space.
    const resp = try httpRoundTrip(allocator, port, "GET /api/todos/a%20b HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n");
    defer allocator.free(resp);

    try std.testing.expect(std.mem.indexOf(u8, resp, "200 OK") != null);
    // Body is exactly the decoded capture.
    const sep = std.mem.indexOf(u8, resp, "\r\n\r\n").?;
    try std.testing.expectEqualStrings("a b", resp[sep + 4 ..]);
}

test "a static route beats a parameterized one on the same shape" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var server = try Server.init(allocator, .{ .port = 0, .host = "127.0.0.1", .worker_count = 1 });
    defer server.deinit();
    // Register the parameterized route first: precedence must still pick the
    // fully static route for the exact path, independent of registration order.
    try server.route("GET", "/api/todos/:id", testEchoId);
    try server.route("GET", "/api/todos/count", testStaticMarker);
    try server.start();
    const port = server.tcp_server.boundPort();

    const resp = try httpRoundTrip(allocator, port, "GET /api/todos/count HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n");
    defer allocator.free(resp);

    const sep = std.mem.indexOf(u8, resp, "\r\n\r\n").?;
    try std.testing.expectEqualStrings("STATIC", resp[sep + 4 ..]);
}

test "a malformed percent-escape in a captured segment is a 400" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var server = try Server.init(allocator, .{ .port = 0, .host = "127.0.0.1", .worker_count = 1 });
    defer server.deinit();
    try server.route("GET", "/api/todos/:id", testEchoId);
    try server.start();
    const port = server.tcp_server.boundPort();

    // "%2" is a truncated escape: rejected before the handler runs.
    const resp = try httpRoundTrip(allocator, port, "GET /api/todos/%2 HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n");
    defer allocator.free(resp);

    try std.testing.expect(std.mem.indexOf(u8, resp, "400 Bad Request") != null);
}

test "a trailing slash does not match a slash-free parameterized route" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var server = try Server.init(allocator, .{ .port = 0, .host = "127.0.0.1", .worker_count = 1 });
    defer server.deinit();
    try server.route("GET", "/api/todos/:id", testEchoId);
    try server.start();
    const port = server.tcp_server.boundPort();

    // The trailing slash is a distinct (empty) segment, so this is a 404, not a
    // capture of "42".
    const resp = try httpRoundTrip(allocator, port, "GET /api/todos/42/ HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n");
    defer allocator.free(resp);

    try std.testing.expect(std.mem.indexOf(u8, resp, "404 Not Found") != null);
}

test "Allow on a parameterized path reflects its registered methods" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var server = try Server.init(allocator, .{ .port = 0, .host = "127.0.0.1", .worker_count = 1 });
    defer server.deinit();
    try server.route("GET", "/api/todos/:id", testEchoId);
    try server.route("DELETE", "/api/todos/:id", testEchoId);
    try server.start();
    const port = server.tcp_server.boundPort();

    // A wrong-method request on a matching parameter path still resolves the
    // Allow set through the parameter matcher.
    const resp = try httpRoundTrip(allocator, port, "POST /api/todos/42 HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n");
    defer allocator.free(resp);

    try std.testing.expect(std.mem.indexOf(u8, resp, "405 Method Not Allowed") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "Allow: GET, HEAD, DELETE, OPTIONS") != null);
}

test "writeHttpDate formats a known instant and round-trips through parseHttpDate" {
    // 2023-11-14T22:13:20Z is a Tuesday; the fixed-width IMF-fixdate is exact.
    var buf: [http_date_len]u8 = undefined;
    const formatted = writeHttpDate(&buf, test_resource_mtime);
    try std.testing.expectEqualStrings("Tue, 14 Nov 2023 22:13:20 GMT", formatted);

    // Parsing the emitted string recovers the original epoch seconds exactly.
    try std.testing.expectEqual(@as(?i64, test_resource_mtime), parseHttpDate(formatted));

    // The epoch itself is Thursday, 1970-01-01 00:00:00 GMT — the day-of-week
    // and zero-padding edge.
    const epoch = writeHttpDate(&buf, 0);
    try std.testing.expectEqualStrings("Thu, 01 Jan 1970 00:00:00 GMT", epoch);
    try std.testing.expectEqual(@as(?i64, 0), parseHttpDate(epoch));
}

test "parseHttpDate rejects malformed or obsolete date forms" {
    // Wrong length, wrong separators, non-GMT zone, and the RFC 850 form are all
    // rejected — a null just means "no conditional shortcut", which is safe.
    try std.testing.expectEqual(@as(?i64, null), parseHttpDate("not a date"));
    try std.testing.expectEqual(@as(?i64, null), parseHttpDate("Tue, 14 Nov 2023 22:13:20 UTC"));
    try std.testing.expectEqual(@as(?i64, null), parseHttpDate("Tuesday, 14-Nov-23 22:13:20 GMT"));
    try std.testing.expectEqual(@as(?i64, null), parseHttpDate("Xxx, 14 Xxx 2023 22:13:20 GMT"));
}

test "every response carries a synthesized Date header" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var server = try Server.init(allocator, .{ .port = 0, .host = "127.0.0.1", .worker_count = 1 });
    defer server.deinit();
    try server.route("GET", "/d", testHello);
    try server.start();
    const port = server.tcp_server.boundPort();

    const resp = try httpRoundTrip(allocator, port, "GET /d HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n");
    defer allocator.free(resp);

    // A Date header is present and its value parses as an IMF-fixdate.
    const marker = "Date: ";
    const at = std.mem.indexOf(u8, resp, marker) orelse return error.TestUnexpectedResult;
    const value = resp[at + marker.len .. at + marker.len + http_date_len];
    try std.testing.expect(parseHttpDate(value) != null);
}

test "a 204 response omits both body and Content-Length" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var server = try Server.init(allocator, .{ .port = 0, .host = "127.0.0.1", .worker_count = 1 });
    defer server.deinit();
    try server.route("DELETE", "/r", testNoContent);
    try server.start();
    const port = server.tcp_server.boundPort();

    const resp = try httpRoundTrip(allocator, port, "DELETE /r HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n");
    defer allocator.free(resp);

    try std.testing.expect(std.mem.indexOf(u8, resp, "204 No Content") != null);
    // A bodyless status must not synthesize a framing header, and the body after
    // the header terminator must be empty.
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, resp, "Content-Length:"));
    const term = std.mem.indexOf(u8, resp, "\r\n\r\n") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(resp.len, term + 4);
}

test "a HEAD response keeps Content-Length but drops the body" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var server = try Server.init(allocator, .{ .port = 0, .host = "127.0.0.1", .worker_count = 1 });
    defer server.deinit();
    try server.route("GET", "/h", testHello);
    try server.start();
    const port = server.tcp_server.boundPort();

    const resp = try httpRoundTrip(allocator, port, "HEAD /h HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n");
    defer allocator.free(resp);

    // Content-Length reflects the would-be GET body ("hello" = 5) yet no body
    // bytes follow the header terminator.
    try std.testing.expect(std.mem.indexOf(u8, resp, "Content-Length: 5") != null);
    const term = std.mem.indexOf(u8, resp, "\r\n\r\n") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(resp.len, term + 4);
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, resp, "hello"));
}

test "a conditional GET yields 304 with no body when not modified" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var server = try Server.init(allocator, .{ .port = 0, .host = "127.0.0.1", .worker_count = 1 });
    defer server.deinit();
    try server.route("GET", "/c", testConditional);
    try server.start();
    const port = server.tcp_server.boundPort();

    // If-Modified-Since equal to the resource mtime → 304, no body, no
    // Content-Length synthesized.
    const not_modified = try httpRoundTrip(
        allocator,
        port,
        "GET /c HTTP/1.1\r\nHost: t\r\nIf-Modified-Since: Tue, 14 Nov 2023 22:13:20 GMT\r\nConnection: close\r\n\r\n",
    );
    defer allocator.free(not_modified);
    try std.testing.expect(std.mem.indexOf(u8, not_modified, "304 Not Modified") != null);
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, not_modified, "fresh-body"));

    // A stale If-Modified-Since → full 200 with the body and a Last-Modified.
    const modified = try httpRoundTrip(
        allocator,
        port,
        "GET /c HTTP/1.1\r\nHost: t\r\nIf-Modified-Since: Mon, 01 Jan 2001 00:00:00 GMT\r\nConnection: close\r\n\r\n",
    );
    defer allocator.free(modified);
    try std.testing.expect(std.mem.indexOf(u8, modified, "200 OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, modified, "fresh-body") != null);
    try std.testing.expect(std.mem.indexOf(u8, modified, "Last-Modified: Tue, 14 Nov 2023 22:13:20 GMT") != null);
}

test "a chunked request body is refused with 501" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var server = try Server.init(allocator, .{ .port = 0, .host = "127.0.0.1", .worker_count = 1 });
    defer server.deinit();
    try server.route("POST", "/u", testHello);
    try server.start();
    const port = server.tcp_server.boundPort();

    // Transfer-Encoding is not decoded here, so it is answered honestly with 501
    // rather than a misleading 400 or a silently mis-framed body.
    const resp = try httpRoundTrip(allocator, port, "POST /u HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\n\r\n");
    defer allocator.free(resp);

    try std.testing.expect(std.mem.indexOf(u8, resp, "501 Not Implemented") != null);
}

test "a streamed response is chunk-framed" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var server = try Server.init(allocator, .{ .port = 0, .host = "127.0.0.1", .worker_count = 1 });
    defer server.deinit();
    try server.route("GET", "/s", testStream);
    try server.start();
    const port = server.tcp_server.boundPort();

    const resp = try httpRoundTrip(allocator, port, "GET /s HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n");
    defer allocator.free(resp);

    try std.testing.expect(std.mem.indexOf(u8, resp, "Transfer-Encoding: chunked") != null);
    // 4-byte "Wiki", 5-byte "pedia", then the zero-length terminating chunk.
    try std.testing.expect(std.mem.indexOf(u8, resp, "4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n") != null);
}

test "a pipelined second request is not served and the connection closes" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var server = try Server.init(allocator, .{ .port = 0, .host = "127.0.0.1", .worker_count = 1 });
    defer server.deinit();
    try server.route("GET", "/p", testHello);
    try server.start();
    const port = server.tcp_server.boundPort();

    // Two requests in one write: the second is pipelined and must be dropped,
    // with the first response carrying Connection: close.
    const resp = try httpRoundTrip(
        allocator,
        port,
        "GET /p HTTP/1.1\r\nHost: t\r\n\r\nGET /p HTTP/1.1\r\nHost: t\r\n\r\n",
    );
    defer allocator.free(resp);

    try std.testing.expect(std.mem.indexOf(u8, resp, "Connection: close") != null);
    // Exactly one response was produced.
    try std.testing.expect(std.mem.indexOf(u8, resp, "hello") != null);
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOfPos(u8, resp, 1, "HTTP/1.1 "));
}

test "the keep-alive request cap forces a close on the last response" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var server = try Server.init(allocator, .{
        .port = 0,
        .host = "127.0.0.1",
        .worker_count = 1,
        .max_keepalive_requests = 1,
    });
    defer server.deinit();
    try server.route("GET", "/c", testHello);
    try server.start();
    const port = server.tcp_server.boundPort();

    // The client offers keep-alive (HTTP/1.1, no Connection header) but the cap
    // of 1 means the server closes anyway and advertises it.
    const resp = try httpRoundTrip(allocator, port, "GET /c HTTP/1.1\r\nHost: t\r\n\r\n");
    defer allocator.free(resp);

    try std.testing.expect(std.mem.indexOf(u8, resp, "Connection: close") != null);
}

test "keep-alive serves two requests on one connection" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var server = try Server.init(allocator, .{
        .port = 0,
        .host = "127.0.0.1",
        .worker_count = 1,
        .read_timeout_ms = 5_000,
    });
    defer server.deinit();
    try server.route("GET", "/k", testHello);
    try server.start();
    const port = server.tcp_server.boundPort();

    var client = try tcp.TcpClient.init(allocator);
    defer client.deinit();
    try client.connect("127.0.0.1", port);

    var acc: std.ArrayList(u8) = .empty;
    defer acc.deinit(allocator);

    // First request advertises keep-alive by HTTP/1.1 default.
    try client.write("GET /k HTTP/1.1\r\nHost: t\r\n\r\n");
    const first = try recvOneResponse(&client, allocator, &acc);
    defer allocator.free(first);
    try std.testing.expect(std.mem.indexOf(u8, first, "200 OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "Connection: keep-alive") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "hello") != null);

    // Reuse the same socket for a second request; a serial single-shot server
    // would have closed after the first and this write/read would fail.
    try client.write("GET /k HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n");
    const second = try recvOneResponse(&client, allocator, &acc);
    defer allocator.free(second);
    try std.testing.expect(std.mem.indexOf(u8, second, "200 OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, second, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, second, "Connection: close") != null);
}

test "a request body spanning many socket reads is reassembled intact" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    // A 64 KiB body far exceeds the server's 8 KiB read chunk, so the two-phase
    // reader must loop across ~8 reads to drain it. The client's writeAll of the
    // full request likewise partial-writes over the socket. This deterministically
    // exercises fragmented reads and partial writes without any sleep: the
    // outcome (an exact echo) never depends on timing. A per-byte-varying pattern
    // means a mis-ordered or dropped read would corrupt the echo and fail.
    const body = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(body);
    for (body, 0..) |*b, i| b.* = 'A' + @as(u8, @intCast(i % 26));

    var server = try Server.init(allocator, .{ .port = 0, .host = "127.0.0.1", .worker_count = 1 });
    defer server.deinit();
    try server.route("POST", "/echo", testEcho);
    try server.start();
    const port = server.tcp_server.boundPort();

    const request = try std.fmt.allocPrint(
        allocator,
        "POST /echo HTTP/1.1\r\nHost: t\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ body.len, body },
    );
    defer allocator.free(request);

    const resp = try httpRoundTrip(allocator, port, request);
    defer allocator.free(resp);

    try std.testing.expect(std.mem.indexOf(u8, resp, "200 OK") != null);
    // The echoed body is the response payload after the header terminator; it
    // must equal the sent body byte for byte.
    const sep = std.mem.indexOf(u8, resp, "\r\n\r\n").?;
    try std.testing.expectEqualStrings(body, resp[sep + 4 ..]);
}

test "a slow client that never completes its request is answered 408 and closed" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    // A short read budget bounds the slow-send ("slowloris") client: it sends a
    // partial request head with no terminator and then stalls. The server's read
    // deadline fires, it answers 408, and closes — so the client's read returns
    // the 408 then EOF. Deterministic and sleep-free: the client waits on the
    // server, not the clock.
    var server = try Server.init(allocator, .{
        .port = 0,
        .host = "127.0.0.1",
        .worker_count = 1,
        .read_timeout_ms = 100,
    });
    defer server.deinit();
    try server.route("GET", "/hi", testHello);
    try server.start();
    const port = server.tcp_server.boundPort();

    var client = try tcp.TcpClient.init(allocator);
    defer client.deinit();
    try client.connect("127.0.0.1", port);
    // A partial head: no blank line, so the request never completes.
    try client.write("GET /hi HTTP/1.1\r\nHost: t\r\n");

    var acc: std.ArrayList(u8) = .empty;
    defer acc.deinit(allocator);
    var buf: [512]u8 = undefined;
    while (true) {
        const n = client.read(&buf) catch break;
        if (n == 0) break;
        try acc.appendSlice(allocator, buf[0..n]);
    }
    try std.testing.expect(std.mem.indexOf(u8, acc.items, "408") != null);
}

// --- Middleware dispatcher (Chain) tests (item 1003) ---
//
// The dispatcher is exercised directly. Middleware and handlers carry no user
// context, so execution order is recorded through file-scope state; these tests
// run single-threaded, so a plain buffer is race-free. req/res are threaded
// through untouched, so the stubs are never dereferenced.
var mw_order: [16]u8 = undefined;
var mw_order_len: usize = 0;
fn mwRecord(c: u8) void {
    mw_order[mw_order_len] = c;
    mw_order_len += 1;
}

fn mwOuter(req: *Request, res: *Response, next: *Chain) anyerror!void {
    _ = req;
    _ = res;
    mwRecord('A');
    try next.next();
    mwRecord('a');
}
fn mwInner(req: *Request, res: *Response, next: *Chain) anyerror!void {
    _ = req;
    _ = res;
    mwRecord('B');
    try next.next();
    mwRecord('b');
}
fn mwShortCircuit(req: *Request, res: *Response, next: *Chain) anyerror!void {
    _ = req;
    _ = res;
    _ = next; // deliberately does not advance the chain
    mwRecord('S');
}
fn mwHandler(req: *Request, res: *Response) anyerror!void {
    _ = req;
    _ = res;
    mwRecord('H');
}

test "middleware chain runs onion order and invokes the handler once" {
    mw_order_len = 0;
    var req: Request = undefined;
    var res: Response = undefined;
    const mws = [_]MiddlewareFn{ mwOuter, mwInner };
    var chain = Chain{ .req = &req, .res = &res, .middlewares = &mws, .handler = mwHandler };
    try chain.next();
    // Before-next in registration order, the handler exactly once, then
    // after-next unwinding in reverse — the onion model.
    try std.testing.expectEqualStrings("ABHba", mw_order[0..mw_order_len]);
}

test "an empty middleware chain still runs the handler exactly once" {
    mw_order_len = 0;
    var req: Request = undefined;
    var res: Response = undefined;
    const mws = [_]MiddlewareFn{};
    var chain = Chain{ .req = &req, .res = &res, .middlewares = &mws, .handler = mwHandler };
    try chain.next();
    try std.testing.expectEqualStrings("H", mw_order[0..mw_order_len]);
}

test "a middleware that declines next short-circuits the pipeline" {
    mw_order_len = 0;
    var req: Request = undefined;
    var res: Response = undefined;
    const mws = [_]MiddlewareFn{ mwShortCircuit, mwInner };
    var chain = Chain{ .req = &req, .res = &res, .middlewares = &mws, .handler = mwHandler };
    try chain.next();
    // mwShortCircuit never called next, so neither mwInner nor the handler ran.
    try std.testing.expectEqualStrings("S", mw_order[0..mw_order_len]);
}

test "http headers" {
    const allocator = std.testing.allocator;
    var headers = Headers.init(allocator);
    defer headers.deinit();

    try headers.set("Content-Type", "application/json");
    try std.testing.expectEqualStrings("application/json", headers.get("Content-Type").?);
}

test "http headers repeated set replaces value without leaking" {
    // std.testing.allocator fails the test if the replaced value or a stray key
    // copy leaks, so this both checks semantics and guards the ownership fix.
    const allocator = std.testing.allocator;
    var headers = Headers.init(allocator);
    defer headers.deinit();

    try headers.set("Content-Type", "text/plain");
    try headers.set("Content-Type", "application/json");
    try headers.set("Content-Type", "text/html");

    // Only the last value survives and the map holds a single entry.
    try std.testing.expectEqualStrings("text/html", headers.get("Content-Type").?);
    try std.testing.expectEqual(@as(usize, 1), headers.map.count());
}

test "http jsonBody returns owned Parsed without leaking" {
    // jsonBody only reads allocator + body, so build a minimal Request and let
    // the leak-detecting allocator confirm the arena is released via deinit.
    const allocator = std.testing.allocator;
    var req: Request = undefined;
    req.allocator = allocator;
    req.body = "{\"id\":7,\"name\":\"nexus\"}";

    const Payload = struct { id: i32, name: []const u8 };
    const parsed = try req.jsonBody(Payload);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(i32, 7), parsed.value.id);
    try std.testing.expectEqualStrings("nexus", parsed.value.name);
}

test "read deadline arithmetic drives poll toward fail-fast" {
    // Disabled budget => block indefinitely (-1), never a spurious timeout.
    try std.testing.expectEqual(@as(i32, -1), Server.pollBudget(0, 0));
    try std.testing.expectEqual(@as(i32, -1), Server.pollBudget(-5, 999));

    // Time still remaining yields a positive, shrinking poll timeout.
    try std.testing.expectEqual(@as(i32, 700), Server.pollBudget(1000, 300));

    // A spent (or over-spent) budget collapses to 0 so waitReadable returns
    // immediately with error.ReadTimeout instead of blocking.
    try std.testing.expectEqual(@as(i32, 0), Server.pollBudget(1000, 1000));
    try std.testing.expectEqual(@as(i32, 0), Server.pollBudget(1000, 5000));
}

test "http headers repeated set of one key is leak-safe" {
    // Rewriting the same header key repeatedly must free each superseded value
    // exactly once; std.testing.allocator fails the test on any leak.
    const allocator = std.testing.allocator;
    var headers = Headers.init(allocator);
    defer headers.deinit();

    try headers.set("Cache-Control", "no-store");
    try headers.set("Cache-Control", "max-age=0");

    try std.testing.expectEqualStrings("max-age=0", headers.get("Cache-Control").?);
    try std.testing.expectEqual(@as(usize, 1), headers.map.count());
}

test "http header set rejects CRLF injection and non-token names" {
    const allocator = std.testing.allocator;
    var headers = Headers.init(allocator);
    defer headers.deinit();

    // A value carrying CRLF plus an injected field is the response-splitting
    // vector: it must be refused, not stored.
    try std.testing.expectError(error.InvalidHeaderValue, headers.set("X-Test", "ok\r\nSet-Cookie: evil=1"));
    // A bare NUL in the value is likewise rejected.
    try std.testing.expectError(error.InvalidHeaderValue, headers.set("X-Test", "a\x00b"));
    // A name with a space is not an RFC 7230 token.
    try std.testing.expectError(error.InvalidHeaderName, headers.set("Bad Name", "value"));
    // Fail-closed means nothing leaked into the map.
    try std.testing.expectEqual(@as(usize, 0), headers.map.count());
}

/// Build a Response that owns only the state setCookie touches (allocator,
/// headers, set_cookies). setCookie never reads the stream/io, so this mirrors
/// the jsonBody test's minimal-Request pattern and keeps the cookie tests free
/// of a live socket.
fn testResponse(allocator: std.mem.Allocator) Response {
    var res: Response = undefined;
    res.allocator = allocator;
    res.headers = Headers.init(allocator);
    res.set_cookies = .empty;
    return res;
}

fn deinitTestResponse(res: *Response) void {
    res.headers.deinit();
    for (res.set_cookies.items) |cookie| res.allocator.free(cookie);
    res.set_cookies.deinit(res.allocator);
}

test "setCookie rejects CRLF and attribute injection" {
    const allocator = std.testing.allocator;
    var res = testResponse(allocator);
    defer deinitTestResponse(&res);

    // CRLF in the value would split the response into a forged header.
    try std.testing.expectError(error.InvalidCookieValue, res.setCookie("sid", "abc\r\nSet-Cookie: evil=1", .{}));
    // A ';' in the value would forge cookie attributes (e.g. an added Domain).
    try std.testing.expectError(error.InvalidCookieValue, res.setCookie("sid", "abc; Domain=evil.test", .{}));
    // A non-token cookie name is refused.
    try std.testing.expectError(error.InvalidCookieName, res.setCookie("bad name", "abc", .{}));
    // Injection through the Path attribute is refused too.
    try std.testing.expectError(error.InvalidCookieAttribute, res.setCookie("sid", "abc", .{ .path = "/\r\nX: y" }));
    // Every rejection was fail-closed: nothing was accumulated.
    try std.testing.expectEqual(@as(usize, 0), res.set_cookies.items.len);
}

test "setCookie enforces SameSite=None requires Secure" {
    const allocator = std.testing.allocator;
    var res = testResponse(allocator);
    defer deinitTestResponse(&res);

    // SameSite=None without Secure is a silent-downgrade footgun: reject it.
    try std.testing.expectError(error.InsecureSameSiteNone, res.setCookie("sid", "abc", .{ .same_site = "None" }));
    // An unknown SameSite token is rejected rather than emitted verbatim.
    try std.testing.expectError(error.InvalidSameSite, res.setCookie("sid", "abc", .{ .same_site = "Nonsense" }));
    // None *with* Secure is accepted.
    _ = try res.setCookie("sid", "abc", .{ .same_site = "None", .secure = true });
    try std.testing.expectEqual(@as(usize, 1), res.set_cookies.items.len);
    try std.testing.expectEqualStrings("sid=abc; Secure; SameSite=None", res.set_cookies.items[0]);
}

test "setCookie accumulates multiple cookies without overwriting" {
    const allocator = std.testing.allocator;
    var res = testResponse(allocator);
    defer deinitTestResponse(&res);

    _ = try res.setCookie("a", "1", .{ .path = "/" });
    _ = try res.setCookie("b", "2", .{ .http_only = true });

    // Both survive as distinct Set-Cookie lines; the single-value Headers map
    // would have collapsed them into one.
    try std.testing.expectEqual(@as(usize, 2), res.set_cookies.items.len);
    try std.testing.expectEqualStrings("a=1; Path=/", res.set_cookies.items[0]);
    try std.testing.expectEqualStrings("b=2; HttpOnly", res.set_cookies.items[1]);
}

// --- Item 1006: honest middleware (compression, body-parser, auth) ---
//
// These exercise the real middleware in `middleware.zig` against a live
// loopback server, so the assertions are about the bytes on the wire rather
// than internal flags.
const mw = @import("middleware.zig");

// A repetitive body comfortably over `gzip_min_bytes`, so DEFLATE genuinely
// shrinks it and the compression path is actually taken.
const test_gzip_payload: []const u8 =
    "The quick brown fox jumps over the lazy dog. " ++
    "The quick brown fox jumps over the lazy dog. " ++
    "The quick brown fox jumps over the lazy dog. " ++
    "The quick brown fox jumps over the lazy dog. " ++
    "The quick brown fox jumps over the lazy dog. " ++
    "The quick brown fox jumps over the lazy dog. " ++
    "The quick brown fox jumps over the lazy dog. " ++
    "The quick brown fox jumps over the lazy dog. ";

fn testBigBody(req: *Request, res: *Response) anyerror!void {
    _ = req;
    try res.text(test_gzip_payload);
}

fn testAcceptSecret(token: []const u8) bool {
    return std.mem.eql(u8, token, "secret");
}

// Write `bytes` to the client in bounded slices. `TcpClient.write` issues a
// single `netWrite` and rejects a short write, so a large request body must be
// fed in chunks small enough to drain in one syscall.
fn sendAllChunked(client: *tcp.TcpClient, bytes: []const u8) !void {
    var i: usize = 0;
    while (i < bytes.len) {
        const end = @min(i + 16 * 1024, bytes.len);
        try client.write(bytes[i..end]);
        i = end;
    }
}

test "gzipCompress round-trips through a gzip decoder" {
    const allocator = std.testing.allocator;

    var original: [2048]u8 = undefined;
    for (&original, 0..) |*b, i| b.* = @as(u8, 'a') + @as(u8, @intCast(i % 16));

    const compressed = try gzipCompress(allocator, &original);
    defer allocator.free(compressed);

    // gzip member magic, and the repetitive input genuinely shrank.
    try std.testing.expect(compressed.len > 2);
    try std.testing.expectEqual(@as(u8, 0x1f), compressed[0]);
    try std.testing.expectEqual(@as(u8, 0x8b), compressed[1]);
    try std.testing.expect(compressed.len < original.len);

    var reader = std.Io.Reader.fixed(compressed);
    const window = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(window);
    var decomp = std.compress.flate.Decompress.init(&reader, .gzip, window);
    const restored = try decomp.reader.allocRemaining(allocator, .unlimited);
    defer allocator.free(restored);
    try std.testing.expectEqualSlices(u8, &original, restored);
}

test "compression middleware gzips a large body and the header is honest" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var server = try Server.init(allocator, .{ .port = 0, .host = "127.0.0.1", .worker_count = 1 });
    defer server.deinit();
    try server.use(mw.compression);
    try server.route("GET", "/big", testBigBody);
    try server.start();
    const port = server.tcp_server.boundPort();

    const resp = try httpRoundTrip(allocator, port, "GET /big HTTP/1.1\r\nHost: t\r\nAccept-Encoding: gzip\r\nConnection: close\r\n\r\n");
    defer allocator.free(resp);

    // The header is present only because the body was actually compressed, and
    // the plaintext never appears verbatim on the wire.
    try std.testing.expect(std.mem.indexOf(u8, resp, "Content-Encoding: gzip") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, test_gzip_payload) == null);

    // Decode the body and confirm it restores to the original payload.
    const body_start = std.mem.indexOf(u8, resp, "\r\n\r\n").? + 4;
    var reader = std.Io.Reader.fixed(resp[body_start..]);
    const window = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(window);
    var decomp = std.compress.flate.Decompress.init(&reader, .gzip, window);
    const restored = try decomp.reader.allocRemaining(allocator, .unlimited);
    defer allocator.free(restored);
    try std.testing.expectEqualStrings(test_gzip_payload, restored);
}

test "compression middleware leaves a tiny body uncompressed and unlabeled" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var server = try Server.init(allocator, .{ .port = 0, .host = "127.0.0.1", .worker_count = 1 });
    defer server.deinit();
    try server.use(mw.compression);
    // "hello" is 5 bytes, well under gzip_min_bytes.
    try server.route("GET", "/hi", testHello);
    try server.start();
    const port = server.tcp_server.boundPort();

    const resp = try httpRoundTrip(allocator, port, "GET /hi HTTP/1.1\r\nHost: t\r\nAccept-Encoding: gzip\r\nConnection: close\r\n\r\n");
    defer allocator.free(resp);

    // Sub-threshold: not compressed, so the encoding header must be absent and
    // the plaintext delivered unchanged.
    try std.testing.expect(std.mem.indexOf(u8, resp, "Content-Encoding") == null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "hello") != null);
}

test "bodyParser rejects a malformed JSON body with 400" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var server = try Server.init(allocator, .{ .port = 0, .host = "127.0.0.1", .worker_count = 1 });
    defer server.deinit();
    try server.use(mw.bodyParser);
    try server.route("POST", "/echo", testHello);
    try server.start();
    const port = server.tcp_server.boundPort();

    // Body "{ x" is 3 bytes of invalid JSON.
    const resp = try httpRoundTrip(allocator, port, "POST /echo HTTP/1.1\r\nHost: t\r\nContent-Type: application/json\r\nContent-Length: 3\r\nConnection: close\r\n\r\n{ x");
    defer allocator.free(resp);

    try std.testing.expect(std.mem.indexOf(u8, resp, "400 Bad Request") != null);
    // The handler never ran, so its body is absent.
    try std.testing.expect(std.mem.indexOf(u8, resp, "hello") == null);
}

test "bodyParser admits a well-formed JSON body" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var server = try Server.init(allocator, .{ .port = 0, .host = "127.0.0.1", .worker_count = 1 });
    defer server.deinit();
    try server.use(mw.bodyParser);
    try server.route("POST", "/echo", testHello);
    try server.start();
    const port = server.tcp_server.boundPort();

    // Body {"a":1} is 7 valid JSON bytes.
    const resp = try httpRoundTrip(allocator, port, "POST /echo HTTP/1.1\r\nHost: t\r\nContent-Type: application/json\r\nContent-Length: 7\r\nConnection: close\r\n\r\n{\"a\":1}");
    defer allocator.free(resp);

    try std.testing.expect(std.mem.indexOf(u8, resp, "200 OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "hello") != null);
}

test "bodyParser rejects an oversized JSON body with 413" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var server = try Server.init(allocator, .{ .port = 0, .host = "127.0.0.1", .worker_count = 1 });
    defer server.deinit();
    try server.use(mw.bodyParser);
    try server.route("POST", "/echo", testHello);
    try server.start();
    const port = server.tcp_server.boundPort();

    const body_len = mw.max_json_body + 1;
    const body = try allocator.alloc(u8, body_len);
    defer allocator.free(body);
    @memset(body, 'a');
    const header = try std.fmt.allocPrint(allocator, "POST /echo HTTP/1.1\r\nHost: t\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{body_len});
    defer allocator.free(header);

    var client = try tcp.TcpClient.init(allocator);
    defer client.deinit();
    try client.connect("127.0.0.1", port);
    try sendAllChunked(&client, header);
    try sendAllChunked(&client, body);

    var acc: std.ArrayList(u8) = .empty;
    defer acc.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = client.read(&buf) catch break;
        if (n == 0) break;
        try acc.appendSlice(allocator, buf[0..n]);
    }

    // The cap fires before any parse work, so the body never reaches the handler.
    try std.testing.expect(std.mem.indexOf(u8, acc.items, "413 Payload Too Large") != null);
    try std.testing.expect(std.mem.indexOf(u8, acc.items, "hello") == null);
}

test "auth rejects a request with no Authorization header" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    mw.token_verifier = null;

    var server = try Server.init(allocator, .{ .port = 0, .host = "127.0.0.1", .worker_count = 1 });
    defer server.deinit();
    try server.use(mw.auth);
    try server.route("GET", "/secure", testHello);
    try server.start();
    const port = server.tcp_server.boundPort();

    const resp = try httpRoundTrip(allocator, port, "GET /secure HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n");
    defer allocator.free(resp);

    try std.testing.expect(std.mem.indexOf(u8, resp, "401 Unauthorized") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "hello") == null);
}

test "auth fails closed when no verifier is configured" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    // No verifier installed: even a well-formed Bearer token must be rejected.
    mw.token_verifier = null;

    var server = try Server.init(allocator, .{ .port = 0, .host = "127.0.0.1", .worker_count = 1 });
    defer server.deinit();
    try server.use(mw.auth);
    try server.route("GET", "/secure", testHello);
    try server.start();
    const port = server.tcp_server.boundPort();

    const resp = try httpRoundTrip(allocator, port, "GET /secure HTTP/1.1\r\nHost: t\r\nAuthorization: Bearer anything\r\nConnection: close\r\n\r\n");
    defer allocator.free(resp);

    try std.testing.expect(std.mem.indexOf(u8, resp, "401 Unauthorized") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "hello") == null);
}

test "auth admits only a token the application verifier accepts" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    mw.token_verifier = &testAcceptSecret;
    // Reset after the server (and its workers) are fully torn down.
    defer mw.token_verifier = null;

    var server = try Server.init(allocator, .{ .port = 0, .host = "127.0.0.1", .worker_count = 1 });
    defer server.deinit();
    try server.use(mw.auth);
    try server.route("GET", "/secure", testHello);
    try server.start();
    const port = server.tcp_server.boundPort();

    // A token the verifier rejects → 401.
    {
        const resp = try httpRoundTrip(allocator, port, "GET /secure HTTP/1.1\r\nHost: t\r\nAuthorization: Bearer nope\r\nConnection: close\r\n\r\n");
        defer allocator.free(resp);
        try std.testing.expect(std.mem.indexOf(u8, resp, "401 Unauthorized") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp, "hello") == null);
    }

    // The exact token the verifier accepts → the handler runs.
    {
        const resp = try httpRoundTrip(allocator, port, "GET /secure HTTP/1.1\r\nHost: t\r\nAuthorization: Bearer secret\r\nConnection: close\r\n\r\n");
        defer allocator.free(resp);
        try std.testing.expect(std.mem.indexOf(u8, resp, "200 OK") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp, "hello") != null);
    }
}
