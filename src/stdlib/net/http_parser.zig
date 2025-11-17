const std = @import("std");

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

    /// Parse HTTP request from raw bytes
    pub fn parse(self: *RequestParser, data: []const u8) !ParsedRequest {
        // Split into headers and body
        const header_end = std.mem.indexOf(u8, data, "\r\n\r\n") orelse data.len;
        const header_section = data[0..header_end];
        const body = if (header_end + 4 <= data.len) data[header_end + 4 ..] else "";

        // Parse request line
        var lines = std.mem.splitScalar(u8, header_section, '\n');
        const request_line = lines.next() orelse return error.InvalidRequest;

        var request_parts = std.mem.splitScalar(u8, request_line, ' ');
        const method = request_parts.next() orelse return error.InvalidMethod;
        const raw_path = request_parts.next() orelse return error.InvalidPath;
        const http_version = request_parts.next() orelse return error.InvalidVersion;

        // Strip \r if present
        const clean_version = std.mem.trimRight(u8, http_version, "\r");

        // Split path and query string
        var path: []const u8 = raw_path;
        var query_string: ?[]const u8 = null;

        if (std.mem.indexOfScalar(u8, raw_path, '?')) |qmark_pos| {
            path = raw_path[0..qmark_pos];
            query_string = raw_path[qmark_pos + 1 ..];
        }

        // Parse headers
        var headers = std.StringHashMap([]const u8).init(self.allocator);
        errdefer headers.deinit();

        while (lines.next()) |line| {
            const clean_line = std.mem.trim(u8, line, "\r");
            if (clean_line.len == 0) continue;

            if (std.mem.indexOfScalar(u8, clean_line, ':')) |colon_pos| {
                const header_name = clean_line[0..colon_pos];
                const header_value = std.mem.trimLeft(u8, clean_line[colon_pos + 1 ..], " ");

                // Lowercase header name for case-insensitive lookup
                var lowercase_buf: [256]u8 = undefined;
                if (header_name.len > lowercase_buf.len) continue;

                const lowercase_name = std.ascii.lowerString(&lowercase_buf, header_name);
                const name_copy = try self.allocator.dupe(u8, lowercase_name);
                const value_copy = try self.allocator.dupe(u8, header_value);

                try headers.put(name_copy, value_copy);
            }
        }

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
        \\Content-Length: 27
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
