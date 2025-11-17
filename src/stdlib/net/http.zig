const std = @import("std");
const tcp = @import("tcp.zig");

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
    headers: Headers,
    body: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Request) void {
        self.allocator.free(self.path);
        self.headers.deinit();
        if (self.body) |b| self.allocator.free(b);
    }

    pub fn readBody(self: *Request) ![]const u8 {
        if (self.body) |b| return b;
        return &[_]u8{};
    }

    pub fn getHeader(self: *Request, key: []const u8) ?[]const u8 {
        return self.headers.get(key);
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
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: ServerConfig) !Server {
        const tcp_server = try tcp.TcpServer.init(allocator, config.host, config.port);

        return Server{
            .config = config,
            .tcp_server = tcp_server,
            .routes = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Server) void {
        self.tcp_server.deinit();
        for (self.routes.items) |*route_item| {
            route_item.deinit();
        }
        self.routes.deinit(self.allocator);
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

        // Find matching route
        var found = false;
        for (self.routes.items) |route_item| {
            if (route_item.method == req.method and std.mem.eql(u8, route_item.path, req.path)) {
                try route_item.handler(&req, &res);
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

        var lines = std.mem.splitScalar(u8, data, '\n');

        // Parse request line
        const request_line = lines.next() orelse return error.InvalidRequest;
        var parts = std.mem.splitScalar(u8, request_line, ' ');

        const method_str = parts.next() orelse return error.InvalidRequest;
        const method = Method.fromString(method_str) orelse return error.InvalidMethod;

        const path = parts.next() orelse return error.InvalidRequest;
        const path_trimmed = std.mem.trim(u8, path, "\r");

        // Parse headers
        var headers = Headers.init(allocator);
        errdefer headers.deinit();

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, "\r");
            if (trimmed.len == 0) break;

            var header_parts = std.mem.splitScalar(u8, trimmed, ':');
            const key = header_parts.next() orelse continue;
            const value = header_parts.rest();
            const value_trimmed = std.mem.trim(u8, value, " ");

            try headers.set(key, value_trimmed);
        }

        return Request{
            .method = method,
            .path = try allocator.dupe(u8, path_trimmed),
            .headers = headers,
            .allocator = allocator,
        };
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
