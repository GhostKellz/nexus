const std = @import("std");

/// Bounds enforced while parsing an HTTP/1 request. They cap the work a single
/// untrusted request can impose (memory + iteration) and are the ceilings the
/// framing loop in http.zig reads against, so a slow or oversized peer cannot
/// grow the accumulation buffer without limit.
pub const limits = struct {
    /// Longest allowed request line (method SP target SP version).
    pub const max_request_line = 8 * 1024;
    /// Maximum number of header fields.
    pub const max_header_count = 100;
    /// Maximum size of the whole header block (everything before the blank line).
    pub const max_header_section = 32 * 1024;
    /// Maximum length of a single header field name.
    pub const max_header_name = 256;
    /// Maximum length of a single header field value.
    pub const max_header_value = 8 * 1024;
    /// Maximum declared/observed request body length.
    pub const max_body = 10 * 1024 * 1024;
};

/// HTTP/1 field-name token character (RFC 7230 `tchar`). Anything else in a
/// header name (space, control byte, separator) is rejected so a smuggled or
/// obfuscated field cannot masquerade as a framing header.
fn isTokenChar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9' => true,
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

pub fn isToken(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!isTokenChar(c)) return false;
    }
    return true;
}

/// A header value may contain visible characters and blanks (SP/HTAB) but no
/// other control bytes; embedded CR/LF/NUL are the classic response-splitting
/// and smuggling vectors.
pub fn validHeaderValue(s: []const u8) bool {
    for (s) |c| {
        if (c == '\t') continue;
        if (c < 0x20 or c == 0x7f) return false;
    }
    return true;
}

fn validVersion(v: []const u8) bool {
    return std.mem.eql(u8, v, "HTTP/1.1") or std.mem.eql(u8, v, "HTTP/1.0");
}

/// The request target must be non-empty and free of control bytes; spaces are
/// already excluded because the request line splits on SP.
fn validPath(p: []const u8) bool {
    if (p.len == 0) return false;
    for (p) |c| {
        if (c < 0x20 or c == 0x7f) return false;
    }
    return true;
}

/// Result of `frame`: the exact number of bytes that make up one complete
/// request (header block + separator + declared body).
pub const Framing = struct {
    total: usize,
};

/// Decide whether `data` already holds a complete request and, if so, how long
/// it is. Returns `null` while the header terminator has not yet arrived (the
/// caller should read more), and errors when a bound is exceeded so the caller
/// can answer 400 instead of buffering without limit.
///
/// This performs only the minimal Content-Length scan needed to size the body
/// read; `RequestParser.parse` remains the strict authority that rejects
/// conflicting/duplicate framing headers, so a smuggling attempt that slips a
/// wrong length past this sizing pass is still refused before it is acted on.
pub fn frame(data: []const u8) !?Framing {
    var header_end: usize = 0;
    var separator_len: usize = 0;

    if (std.mem.indexOf(u8, data, "\r\n\r\n")) |pos| {
        header_end = pos;
        separator_len = 4;
    } else if (std.mem.indexOf(u8, data, "\n\n")) |pos| {
        header_end = pos;
        separator_len = 2;
    } else {
        if (data.len > limits.max_header_section) return error.HeadersTooLarge;
        return null;
    }

    if (header_end > limits.max_header_section) return error.HeadersTooLarge;

    const body_len = (try scanContentLength(data[0..header_end])) orelse 0;
    if (body_len > limits.max_body) return error.BodyTooLarge;

    return Framing{ .total = header_end + separator_len + body_len };
}

/// Find the first Content-Length in a header block for framing purposes.
fn scanContentLength(header_section: []const u8) !?usize {
    var lines = std.mem.splitScalar(u8, header_section, '\n');
    _ = lines.next(); // request line
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len == 0) continue;
        const colon_pos = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = line[0..colon_pos];
        if (name.len > limits.max_header_name) continue;
        var lowercase_buf: [limits.max_header_name]u8 = undefined;
        const lowercase_name = std.ascii.lowerString(lowercase_buf[0..name.len], name);
        if (std.mem.eql(u8, lowercase_name, "content-length")) {
            const value = std.mem.trim(u8, line[colon_pos + 1 ..], " \t");
            return std.fmt.parseInt(usize, value, 10) catch error.InvalidContentLength;
        }
    }
    return null;
}

/// HTTP request parser
pub const RequestParser = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) RequestParser {
        return RequestParser{
            .allocator = allocator,
        };
    }

    pub const ParsedRequest = struct {
        method: []const u8,
        path: []const u8,
        query_string: ?[]const u8,
        http_version: []const u8,
        headers: std.StringHashMap([]const u8),
        body: []const u8,
        allocator: std.mem.Allocator,

        pub fn deinit(self: *ParsedRequest) void {
            // Free all header keys and values
            var it = self.headers.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            self.headers.deinit();
        }

        /// Get query parameter value
        pub fn getQuery(self: *const ParsedRequest, key: []const u8) ?[]const u8 {
            if (self.query_string == null) return null;

            var iter = std.mem.splitScalar(u8, self.query_string.?, '&');
            while (iter.next()) |pair| {
                var pair_iter = std.mem.splitScalar(u8, pair, '=');
                const param_key = pair_iter.next() orelse continue;
                const param_value = pair_iter.next() orelse "";

                if (std.mem.eql(u8, param_key, key)) {
                    return param_value;
                }
            }
            return null;
        }

        /// Get header value (case-insensitive)
        pub fn getHeader(self: *const ParsedRequest, name: []const u8) ?[]const u8 {
            // Try lowercase
            var lowercase_buf: [256]u8 = undefined;
            if (name.len > lowercase_buf.len) return null;

            const lowercase = std.ascii.lowerString(&lowercase_buf, name);
            if (self.headers.get(lowercase)) |value| {
                return value;
            }

            // Try as-is
            return self.headers.get(name);
        }
    };

    /// Parse a complete, framed HTTP/1 request from raw bytes.
    ///
    /// The buffer must contain exactly one request (the framing loop in
    /// http.zig guarantees this via `frame`). Parsing is strict and fails
    /// closed: a malformed request line, illegal header syntax, or any framing
    /// ambiguity (conflicting/duplicate `Content-Length`, `Transfer-Encoding`,
    /// body length that disagrees with `Content-Length`) is rejected rather
    /// than normalized, which is what closes the request-smuggling surface.
    pub fn parse(self: *RequestParser, data: []const u8) !ParsedRequest {
        // A well-formed request terminates its header block with a blank line.
        // Refuse to guess when it is absent: treating a truncated buffer as
        // "all headers" is how a partial or smuggled request slips through.
        var header_end: usize = 0;
        var separator_len: usize = 0;

        if (std.mem.indexOf(u8, data, "\r\n\r\n")) |pos| {
            header_end = pos;
            separator_len = 4;
        } else if (std.mem.indexOf(u8, data, "\n\n")) |pos| {
            header_end = pos;
            separator_len = 2;
        } else {
            return error.MalformedRequest;
        }

        if (header_end > limits.max_header_section) return error.HeadersTooLarge;

        const header_section = data[0..header_end];
        const body = if (header_end + separator_len <= data.len)
            data[header_end + separator_len ..]
        else
            "";

        // Request line: exactly method SP request-target SP HTTP-version.
        var lines = std.mem.splitScalar(u8, header_section, '\n');
        const request_line_raw = lines.next() orelse return error.InvalidRequest;
        const request_line = std.mem.trimEnd(u8, request_line_raw, "\r");
        if (request_line.len > limits.max_request_line) return error.RequestLineTooLong;

        var request_parts = std.mem.splitScalar(u8, request_line, ' ');
        const method = request_parts.next() orelse return error.InvalidMethod;
        const raw_path = request_parts.next() orelse return error.InvalidPath;
        const clean_version = request_parts.next() orelse return error.InvalidVersion;
        // A fourth token means a space leaked into the target or version — a
        // request-line injection vector, so reject rather than silently drop it.
        if (request_parts.next() != null) return error.InvalidRequest;

        if (!isToken(method)) return error.InvalidMethod;
        if (!validPath(raw_path)) return error.InvalidPath;
        if (!validVersion(clean_version)) return error.InvalidVersion;

        // Split path and query string
        var path: []const u8 = raw_path;
        var query_string: ?[]const u8 = null;

        if (std.mem.indexOfScalar(u8, raw_path, '?')) |qmark_pos| {
            path = raw_path[0..qmark_pos];
            query_string = raw_path[qmark_pos + 1 ..];
        }

        // Parse headers with strict syntax + framing-conflict defenses.
        var headers = std.StringHashMap([]const u8).init(self.allocator);
        errdefer {
            var it = headers.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            headers.deinit();
        }

        var header_count: usize = 0;
        var content_length: ?usize = null;

        while (lines.next()) |raw_line| {
            const line = std.mem.trimEnd(u8, raw_line, "\r");
            if (line.len == 0) continue;

            // Obsolete line folding (a field continued on a line starting with
            // SP/HTAB) is a smuggling vector; RFC 7230 requires rejecting it.
            if (line[0] == ' ' or line[0] == '\t') return error.ObsoleteLineFolding;

            const colon_pos = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidHeader;
            const name = line[0..colon_pos];
            const value = std.mem.trimStart(u8, line[colon_pos + 1 ..], " \t");

            // A non-token name also catches whitespace before the colon, which
            // is another way to smuggle a framing header past a lax proxy.
            if (!isToken(name)) return error.InvalidHeaderName;
            if (name.len > limits.max_header_name) return error.HeaderNameTooLong;
            if (value.len > limits.max_header_value) return error.HeaderValueTooLong;
            if (!validHeaderValue(value)) return error.InvalidHeaderValue;

            header_count += 1;
            if (header_count > limits.max_header_count) return error.TooManyHeaders;

            var lowercase_buf: [limits.max_header_name]u8 = undefined;
            const lowercase_name = std.ascii.lowerString(lowercase_buf[0..name.len], name);

            // Framing headers are the smuggling-sensitive ones: reject
            // conflicting duplicates and any Transfer-Encoding (chunked is not
            // decoded here, so accepting it would leave an undecoded body).
            if (std.mem.eql(u8, lowercase_name, "content-length")) {
                const parsed_len = std.fmt.parseInt(usize, value, 10) catch return error.InvalidContentLength;
                if (content_length) |existing| {
                    if (existing != parsed_len) return error.ConflictingContentLength;
                }
                content_length = parsed_len;
            } else if (std.mem.eql(u8, lowercase_name, "transfer-encoding")) {
                return error.UnsupportedTransferEncoding;
            }

            const name_copy = try self.allocator.dupe(u8, lowercase_name);
            errdefer self.allocator.free(name_copy);
            const value_copy = try self.allocator.dupe(u8, value);
            errdefer self.allocator.free(value_copy);

            const gop = try headers.getOrPut(name_copy);
            if (gop.found_existing) {
                // Duplicate non-framing header: keep the first value and free
                // the redundant copies (the map still owns the original key).
                self.allocator.free(name_copy);
                self.allocator.free(value_copy);
                continue;
            }
            gop.value_ptr.* = value_copy;
        }

        // The declared length must match the framed body exactly; a shorter or
        // longer body is the other half of a smuggling pair.
        if (content_length) |len| {
            if (body.len != len) return error.ContentLengthMismatch;
        }
        if (body.len > limits.max_body) return error.BodyTooLarge;

        return ParsedRequest{
            .method = method,
            .path = path,
            .query_string = query_string,
            .http_version = clean_version,
            .headers = headers,
            .body = body,
            .allocator = self.allocator,
        };
    }
};

test "parse simple GET request" {
    const allocator = std.testing.allocator;

    const request_data =
        \\GET /api/users HTTP/1.1
        \\Host: localhost:3000
        \\User-Agent: test
        \\
        \\
    ;

    var parser = RequestParser.init(allocator);
    var parsed = try parser.parse(request_data);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("GET", parsed.method);
    try std.testing.expectEqualStrings("/api/users", parsed.path);
    try std.testing.expectEqualStrings("HTTP/1.1", parsed.http_version);
    try std.testing.expect(parsed.getHeader("host") != null);
}

test "parse request with query parameters" {
    const allocator = std.testing.allocator;

    const request_data =
        \\GET /search?q=hello&limit=10 HTTP/1.1
        \\Host: localhost
        \\
        \\
    ;

    var parser = RequestParser.init(allocator);
    var parsed = try parser.parse(request_data);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("/search", parsed.path);
    try std.testing.expect(parsed.query_string != null);

    const q_value = parsed.getQuery("q");
    try std.testing.expect(q_value != null);
    try std.testing.expectEqualStrings("hello", q_value.?);

    const limit_value = parsed.getQuery("limit");
    try std.testing.expect(limit_value != null);
    try std.testing.expectEqualStrings("10", limit_value.?);
}

test "parse POST request with body" {
    const allocator = std.testing.allocator;

    const request_data =
        \\POST /api/users HTTP/1.1
        \\Host: localhost
        \\Content-Type: application/json
        \\Content-Length: 24
        \\
        \\{"name":"John","age":30}
    ;

    var parser = RequestParser.init(allocator);
    var parsed = try parser.parse(request_data);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("POST", parsed.method);
    try std.testing.expectEqualStrings("/api/users", parsed.path);
    try std.testing.expectEqualStrings("{\"name\":\"John\",\"age\":30}", parsed.body);

    const content_type = parsed.getHeader("content-type");
    try std.testing.expect(content_type != null);
    try std.testing.expectEqualStrings("application/json", content_type.?);
}

test "parse rejects a request with no header terminator" {
    var parser = RequestParser.init(std.testing.allocator);
    try std.testing.expectError(error.MalformedRequest, parser.parse("GET / HTTP/1.1\r\nHost: x\r\n"));
}

test "parse rejects an unsupported HTTP version" {
    var parser = RequestParser.init(std.testing.allocator);
    try std.testing.expectError(error.InvalidVersion, parser.parse("GET / HTTP/2.0\r\n\r\n"));
    try std.testing.expectError(error.InvalidVersion, parser.parse("GET / FTP/1.1\r\n\r\n"));
}

test "parse rejects a non-token method" {
    var parser = RequestParser.init(std.testing.allocator);
    try std.testing.expectError(error.InvalidMethod, parser.parse("GE(T / HTTP/1.1\r\n\r\n"));
}

test "parse rejects a request line with an extra token" {
    // A space smuggled into the target/version yields a fourth field.
    var parser = RequestParser.init(std.testing.allocator);
    try std.testing.expectError(error.InvalidRequest, parser.parse("GET /a b HTTP/1.1\r\n\r\n"));
}

test "parse rejects conflicting duplicate Content-Length (smuggling)" {
    var parser = RequestParser.init(std.testing.allocator);
    const data = "POST / HTTP/1.1\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\nhello";
    try std.testing.expectError(error.ConflictingContentLength, parser.parse(data));
}

test "parse rejects Content-Length combined with Transfer-Encoding (smuggling)" {
    var parser = RequestParser.init(std.testing.allocator);
    const data = "POST / HTTP/1.1\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\nhello";
    try std.testing.expectError(error.UnsupportedTransferEncoding, parser.parse(data));
}

test "parse rejects a body that disagrees with Content-Length" {
    var parser = RequestParser.init(std.testing.allocator);
    // Declares 10 bytes but only 5 are present.
    try std.testing.expectError(error.ContentLengthMismatch, parser.parse("POST / HTTP/1.1\r\nContent-Length: 10\r\n\r\nhello"));
}

test "parse rejects obsolete line folding" {
    var parser = RequestParser.init(std.testing.allocator);
    const data = "GET / HTTP/1.1\r\nHost: example.com\r\n\tfolded\r\n\r\n";
    try std.testing.expectError(error.ObsoleteLineFolding, parser.parse(data));
}

test "parse rejects a header name with whitespace before the colon" {
    var parser = RequestParser.init(std.testing.allocator);
    // "X Y" is not a token, which also blocks the classic "Header :" bypass.
    try std.testing.expectError(error.InvalidHeaderName, parser.parse("GET / HTTP/1.1\r\nX Y: v\r\n\r\n"));
}

test "parse rejects a control byte in a header value" {
    var parser = RequestParser.init(std.testing.allocator);
    try std.testing.expectError(error.InvalidHeaderValue, parser.parse("GET / HTTP/1.1\r\nX: a\x01b\r\n\r\n"));
}

test "parse caps the header name length" {
    const allocator = std.testing.allocator;
    var parser = RequestParser.init(allocator);

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(allocator);
    try data.appendSlice(allocator, "GET / HTTP/1.1\r\n");
    try data.appendNTimes(allocator, 'X', limits.max_header_name + 1);
    try data.appendSlice(allocator, ": v\r\n\r\n");

    try std.testing.expectError(error.HeaderNameTooLong, parser.parse(data.items));
}

test "parse caps the header value length" {
    const allocator = std.testing.allocator;
    var parser = RequestParser.init(allocator);

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(allocator);
    try data.appendSlice(allocator, "GET / HTTP/1.1\r\nX: ");
    try data.appendNTimes(allocator, 'v', limits.max_header_value + 1);
    try data.appendSlice(allocator, "\r\n\r\n");

    try std.testing.expectError(error.HeaderValueTooLong, parser.parse(data.items));
}

test "parse caps the header count" {
    const allocator = std.testing.allocator;
    var parser = RequestParser.init(allocator);

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(allocator);
    try data.appendSlice(allocator, "GET / HTTP/1.1\r\n");
    var i: usize = 0;
    while (i < limits.max_header_count + 1) : (i += 1) {
        try data.appendSlice(allocator, "A: b\r\n");
    }
    try data.appendSlice(allocator, "\r\n");

    try std.testing.expectError(error.TooManyHeaders, parser.parse(data.items));
}

test "parse keeps the first value of a duplicate non-framing header" {
    const allocator = std.testing.allocator;
    var parser = RequestParser.init(allocator);
    var parsed = try parser.parse("GET / HTTP/1.1\r\nX-Test: first\r\nX-Test: second\r\n\r\n");
    defer parsed.deinit();
    try std.testing.expectEqualStrings("first", parsed.getHeader("x-test").?);
}

test "parse fails cleanly under allocation failure without leaking" {
    // Drive every internal allocation to failure in turn: each must surface as
    // error.OutOfMemory with all prior allocations freed by the parser's
    // errdefer chain (the harness asserts no leak on every injected failure).
    const request =
        "POST /api/users HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Content-Length: 24\r\n\r\n" ++
        "{\"name\":\"John\",\"age\":30}";
    const Ctx = struct {
        fn run(allocator: std.mem.Allocator, data: []const u8) !void {
            var parser = RequestParser.init(allocator);
            var parsed = try parser.parse(data);
            parsed.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Ctx.run, .{request});
}

test "frame returns null until the header terminator arrives" {
    try std.testing.expectEqual(@as(?Framing, null), try frame("GET / HTTP/1.1\r\nHost: x"));
}

test "frame sizes a complete request including its body" {
    const data = "POST / HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello";
    const framing = (try frame(data)).?;
    try std.testing.expectEqual(data.len, framing.total);
}

test "frame sizes a bodyless request at the end of its headers" {
    const data = "GET / HTTP/1.1\r\nHost: x\r\n\r\n";
    const framing = (try frame(data)).?;
    try std.testing.expectEqual(data.len, framing.total);
}

test "frame rejects an oversized declared body" {
    const data = "POST / HTTP/1.1\r\nContent-Length: 999999999999\r\n\r\n";
    try std.testing.expectError(error.BodyTooLarge, frame(data));
}

test "frame rejects headers that exceed the section cap without a terminator" {
    const allocator = std.testing.allocator;
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(allocator);
    try data.appendNTimes(allocator, 'G', limits.max_header_section + 1);
    try std.testing.expectError(error.HeadersTooLarge, frame(data.items));
}
