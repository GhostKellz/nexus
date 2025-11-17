const std = @import("std");
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
        const key_duped = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_duped);
        const value_duped = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_duped);

        try self.map.put(key_duped, value_duped);
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

    /// Get a cookie value by name
    pub fn getCookie(self: *Request, name: []const u8) ?[]const u8 {
        return self.cookies.get(name);
    }

    /// Parse JSON body into a type
    pub fn jsonBody(self: *Request, comptime T: type) !T {
        const parsed = try std.json.parseFromSlice(T, self.allocator, self.body, .{});
        return parsed.value;
    }
};

pub const StatusCode = enum(u16) {
    OK = 200,
    Created = 201,
    NoContent = 204,
    BadRequest = 400,
    Unauthorized = 401,
    Forbidden = 403,
    NotFound = 404,
    InternalServerError = 500,

    pub fn toInt(self: StatusCode) u16 {
        return @intFromEnum(self);
    }

    pub fn toString(self: StatusCode) []const u8 {
        return switch (self) {
            .OK => "OK",
            .Created => "Created",
            .NoContent => "No Content",
            .BadRequest => "Bad Request",
            .Unauthorized => "Unauthorized",
            .Forbidden => "Forbidden",
            .NotFound => "Not Found",
            .InternalServerError => "Internal Server Error",
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

pub const Response = struct {
    status_code: StatusCode = .OK,
    headers: Headers,
    body: ?[]const u8 = null,
    stream: std.Io.net.Stream,
    allocator: std.mem.Allocator,
    sent: bool = false,

    pub fn init(allocator: std.mem.Allocator, stream: std.Io.net.Stream) Response {
        return Response{
            .headers = Headers.init(allocator),
            .stream = stream,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Response) void {
        self.headers.deinit();
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

    pub fn send(self: *Response, data: []const u8) !void {
        if (self.sent) return error.AlreadySent;

        // Set Content-Length if not set
        if (self.headers.get("Content-Length") == null) {
            const len_str = try std.fmt.allocPrint(self.allocator, "{d}", .{data.len});
            defer self.allocator.free(len_str);
            try self.headers.set("Content-Length", len_str);
        }

        // Build response header
        var header_buf: std.ArrayList(u8) = .{};
        defer header_buf.deinit(self.allocator);

        // Status line
        try header_buf.appendSlice(self.allocator, "HTTP/1.1 ");
        const status_code_str = try std.fmt.allocPrint(self.allocator, "{d}", .{self.status_code.toInt()});
        defer self.allocator.free(status_code_str);
        try header_buf.appendSlice(self.allocator, status_code_str);
        try header_buf.appendSlice(self.allocator, " ");
        try header_buf.appendSlice(self.allocator, self.status_code.toString());
        try header_buf.appendSlice(self.allocator, "\r\n");

        // Headers
        var it = self.headers.map.iterator();
        while (it.next()) |entry| {
            try header_buf.appendSlice(self.allocator, entry.key_ptr.*);
            try header_buf.appendSlice(self.allocator, ": ");
            try header_buf.appendSlice(self.allocator, entry.value_ptr.*);
            try header_buf.appendSlice(self.allocator, "\r\n");
        }

        // End headers
        try header_buf.appendSlice(self.allocator, "\r\n");

        // Write header and body using netWrite
        // We need the Io object - get it from TcpConnection
        // For now, write directly using posix (we'll improve this)
        const header_slice = header_buf.items;

        // Write header
        _ = try std.posix.write(self.stream.socket.handle, header_slice);

        // Write body if present
        if (data.len > 0) {
            _ = try std.posix.write(self.stream.socket.handle, data);
        }

        self.sent = true;
    }

    pub fn json(self: *Response, value: anytype) !void {
        _ = try self.setHeader("Content-Type", "application/json");

        // Use std.json.Stringify with Io.Writer
        var json_buf: std.ArrayList(u8) = .{};
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

    /// Set a cookie with optional parameters
    pub fn setCookie(self: *Response, name: []const u8, value: []const u8, options: CookieOptions) !*Response {
        var cookie_value: std.ArrayList(u8) = .{};
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

        // Set the Set-Cookie header
        const cookie_str = try self.allocator.dupe(u8, cookie_value.items);
        defer self.allocator.free(cookie_str);
        try self.headers.set("Set-Cookie", cookie_str);

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
        var header_buf: std.ArrayList(u8) = .{};
        defer header_buf.deinit(self.allocator);

        try header_buf.appendSlice(self.allocator, "HTTP/1.1 101 Switching Protocols\r\n");
        try header_buf.appendSlice(self.allocator, "Upgrade: websocket\r\n");
        try header_buf.appendSlice(self.allocator, "Connection: Upgrade\r\n");
        try header_buf.appendSlice(self.allocator, "Sec-WebSocket-Accept: ");
        try header_buf.appendSlice(self.allocator, accept_key);
        try header_buf.appendSlice(self.allocator, "\r\n\r\n");

        // Write handshake response
        _ = try std.posix.write(self.stream.socket.handle, header_buf.items);

        self.sent = true;

        // Generate unique ID
        const id = try std.fmt.allocPrint(self.allocator, "ws_{d}", .{std.crypto.random.int(u64)});
        defer self.allocator.free(id);

        // Convert std.Io.net.Stream to std.net.Stream
        const net_stream = std.net.Stream{ .handle = self.stream.socket.handle };

        // Create and return WebSocket
        const ws = try self.allocator.create(websocket.WebSocket);
        ws.* = try websocket.WebSocket.init(self.allocator, net_stream, id);
        return ws;
    }
};

pub const RouteHandler = *const fn (req: *Request, res: *Response) anyerror!void;

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
};

pub const Server = struct {
    config: ServerConfig,
    tcp_server: tcp.TcpServer,
    routes: std.ArrayList(Route),
    middlewares: std.ArrayList(*const fn (*Request, *Response, *const fn () anyerror!void) anyerror!void),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: ServerConfig) !Server {
        const tcp_server = try tcp.TcpServer.init(allocator, config.host, config.port);

        return Server{
            .config = config,
            .tcp_server = tcp_server,
            .routes = .{},
            .middlewares = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Server) void {
        self.tcp_server.deinit();
        for (self.routes.items) |*route_item| {
            route_item.deinit();
        }
        self.routes.deinit(self.allocator);
        self.middlewares.deinit(self.allocator);
    }

    /// Add middleware to server
    pub fn use(self: *Server, middleware: *const fn (*Request, *Response, *const fn () anyerror!void) anyerror!void) !void {
        try self.middlewares.append(self.allocator, middleware);
    }

    pub fn route(self: *Server, method: []const u8, path: []const u8, handler: RouteHandler) !void {
        const method_enum = Method.fromString(method) orelse return error.InvalidMethod;

        const route_obj = Route{
            .method = method_enum,
            .path = try self.allocator.dupe(u8, path),
            .handler = handler,
            .allocator = self.allocator,
        };

        try self.routes.append(self.allocator, route_obj);
    }

    pub fn listen(self: *Server) !void {
        std.debug.print("Server listening on {s}:{d}\n", .{ self.config.host, self.config.port });

        while (true) {
            var conn = try self.tcp_server.accept();
            defer conn.close();

            self.handleConnection(&conn) catch |err| {
                std.debug.print("Error handling connection: {}\n", .{err});
            };
        }
    }

    fn handleConnection(self: *Server, conn: *tcp.TcpConnection) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        // Read request
        var buffer: [8192]u8 = undefined;
        const n = try conn.read(&buffer);
        if (n == 0) return;

        // Parse request
        var req = try self.parseRequest(arena_allocator, buffer[0..n]);
        defer req.deinit();

        // Create response
        var res = Response.init(arena_allocator, conn.stream);
        defer res.deinit();

        // Execute route handler directly (middleware will be simpler pattern for now)
        // Find matching route
        var found = false;
        for (self.routes.items) |route_item| {
            if (route_item.method == req.method and std.mem.eql(u8, route_item.path, req.path)) {
                // Execute middlewares inline before handler
                for (self.middlewares.items) |middleware| {
                    const noop = struct {
                        fn call() anyerror!void {}
                    }.call;
                    try middleware(&req, &res, &noop);
                    // If response was already sent by middleware (e.g., auth failed), stop
                    if (res.sent) break;
                }

                // Execute handler if response not sent
                if (!res.sent) {
                    try route_item.handler(&req, &res);
                }
                found = true;
                break;
            }
        }

        // Send 404 if no route found
        if (!found) {
            res.status_code = .NotFound;
            try res.text("Not Found");
        }
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

test "http headers" {
    const allocator = std.testing.allocator;
    var headers = Headers.init(allocator);
    defer headers.deinit();

    try headers.set("Content-Type", "application/json");
    try std.testing.expectEqualStrings("application/json", headers.get("Content-Type").?);
}
