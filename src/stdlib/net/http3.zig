const std = @import("std");
const quic = @import("quic.zig");
const hpack = @import("hpack.zig");

/// HTTP/3 implementation
/// RFC 9114 - HTTP/3

pub const Error = error{
    ProtocolError,
    InternalError,
    StreamCreationError,
    ClosedCriticalStream,
    FrameUnexpected,
    FrameError,
    ExcessiveLoad,
    IdError,
    SettingsError,
    MissingSettings,
    RequestRejected,
    RequestCancelled,
    RequestIncomplete,
    MessageError,
    ConnectError,
    VersionFallback,
};

/// HTTP/3 frame types
pub const FrameType = enum(u64) {
    data = 0x00,
    headers = 0x01,
    cancel_push = 0x03,
    settings = 0x04,
    push_promise = 0x05,
    goaway = 0x07,
    max_push_id = 0x0d,

    pub fn fromInt(value: u64) ?FrameType {
        return switch (value) {
            0x00 => .data,
            0x01 => .headers,
            0x03 => .cancel_push,
            0x04 => .settings,
            0x05 => .push_promise,
            0x07 => .goaway,
            0x0d => .max_push_id,
            else => null,
        };
    }
};

/// HTTP/3 settings
pub const Settings = enum(u64) {
    qpack_max_table_capacity = 0x01,
    max_field_section_size = 0x06,
    qpack_blocked_streams = 0x07,

    /// Reserved settings (MUST be ignored)
    pub fn isReserved(id: u64) bool {
        // 0x00, 0x02, 0x03, 0x04, 0x05 are reserved from HTTP/2
        return id == 0x00 or id == 0x02 or id == 0x03 or id == 0x04 or id == 0x05;
    }
};

/// HTTP/3 stream types
pub const StreamType = enum(u64) {
    control = 0x00,
    push = 0x01,
    qpack_encoder = 0x02,
    qpack_decoder = 0x03,
};

/// HTTP/3 frame
pub const Frame = struct {
    frame_type: u64,
    payload: []const u8,

    pub fn parse(data: []const u8) !struct { frame: Frame, consumed: usize } {
        var offset: usize = 0;

        // Parse frame type (variable-length integer)
        const type_result = try quic.VarInt.decode(data[offset..]);
        offset += type_result.len;

        // Parse length (variable-length integer)
        const len_result = try quic.VarInt.decode(data[offset..]);
        offset += len_result.len;

        const payload_len: usize = @intCast(len_result.value);
        if (data.len < offset + payload_len) return Error.FrameError;

        return .{
            .frame = Frame{
                .frame_type = type_result.value,
                .payload = data[offset .. offset + payload_len],
            },
            .consumed = offset + payload_len,
        };
    }

    pub fn encode(self: *const Frame, allocator: std.mem.Allocator) ![]u8 {
        const type_len = quic.VarInt.encodedLength(self.frame_type);
        const payload_len_enc = quic.VarInt.encodedLength(self.payload.len);
        const total_len = type_len + payload_len_enc + self.payload.len;

        var buf = try allocator.alloc(u8, total_len);
        var offset: usize = 0;

        offset += try quic.VarInt.encode(self.frame_type, buf[offset..]);
        offset += try quic.VarInt.encode(self.payload.len, buf[offset..]);
        @memcpy(buf[offset..], self.payload);

        return buf;
    }
};

/// HTTP/3 request
pub const Request = struct {
    method: []const u8,
    path: []const u8,
    authority: []const u8,
    scheme: []const u8 = "https",
    headers: std.StringHashMap([]const u8),
    body: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Request {
        return Request{
            .method = "GET",
            .path = "/",
            .authority = "",
            .headers = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Request) void {
        self.headers.deinit();
    }

    pub fn setHeader(self: *Request, name: []const u8, value: []const u8) !void {
        try self.headers.put(name, value);
    }

    pub fn getHeader(self: *const Request, name: []const u8) ?[]const u8 {
        return self.headers.get(name);
    }
};

/// HTTP/3 response
pub const Response = struct {
    status: u16 = 200,
    headers: std.StringHashMap([]const u8),
    body: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Response {
        return Response{
            .headers = std.StringHashMap([]const u8).init(allocator),
            .body = std.ArrayList(u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Response) void {
        self.headers.deinit();
        self.body.deinit();
    }

    pub fn setHeader(self: *Response, name: []const u8, value: []const u8) !void {
        try self.headers.put(name, value);
    }

    pub fn getHeader(self: *const Response, name: []const u8) ?[]const u8 {
        return self.headers.get(name);
    }

    pub fn write(self: *Response, data: []const u8) !void {
        try self.body.appendSlice(data);
    }
};

/// HTTP/3 connection state
pub const ConnectionState = enum {
    idle,
    connecting,
    connected,
    closing,
    closed,
};

/// HTTP/3 connection
pub const Connection = struct {
    quic_conn: *quic.Connection,
    state: ConnectionState = .idle,
    is_server: bool,

    /// Control stream (unidirectional)
    control_stream: ?*quic.Stream = null,
    /// QPACK encoder stream
    qpack_encoder_stream: ?*quic.Stream = null,
    /// QPACK decoder stream
    qpack_decoder_stream: ?*quic.Stream = null,

    /// Remote control stream
    peer_control_stream: ?*quic.Stream = null,
    /// Remote QPACK encoder stream
    peer_qpack_encoder_stream: ?*quic.Stream = null,
    /// Remote QPACK decoder stream
    peer_qpack_decoder_stream: ?*quic.Stream = null,

    /// Settings received from peer
    peer_settings: ?SettingsFrame = null,
    /// Local settings
    local_settings: SettingsFrame = .{},

    /// Request streams (bidirectional)
    request_streams: std.AutoHashMap(u64, RequestStream),

    allocator: std.mem.Allocator,

    pub const SettingsFrame = struct {
        qpack_max_table_capacity: u64 = 0,
        max_field_section_size: u64 = 0,
        qpack_blocked_streams: u64 = 0,
    };

    pub const RequestStream = struct {
        stream: *quic.Stream,
        request: ?Request = null,
        response: ?Response = null,
    };

    pub fn init(allocator: std.mem.Allocator, quic_conn: *quic.Connection, is_server: bool) !*Connection {
        const conn = try allocator.create(Connection);
        conn.* = Connection{
            .quic_conn = quic_conn,
            .is_server = is_server,
            .request_streams = std.AutoHashMap(u64, RequestStream).init(allocator),
            .allocator = allocator,
        };
        return conn;
    }

    pub fn deinit(self: *Connection) void {
        self.request_streams.deinit();
        self.allocator.destroy(self);
    }

    /// Initialize HTTP/3 connection (create control and QPACK streams)
    pub fn connect(self: *Connection) !void {
        self.state = .connecting;

        // Create control stream (unidirectional)
        self.control_stream = try self.quic_conn.openUniStream();
        try self.sendStreamType(self.control_stream.?, .control);
        try self.sendSettings();

        // Create QPACK encoder stream
        self.qpack_encoder_stream = try self.quic_conn.openUniStream();
        try self.sendStreamType(self.qpack_encoder_stream.?, .qpack_encoder);

        // Create QPACK decoder stream
        self.qpack_decoder_stream = try self.quic_conn.openUniStream();
        try self.sendStreamType(self.qpack_decoder_stream.?, .qpack_decoder);

        self.state = .connected;
    }

    fn sendStreamType(self: *Connection, stream: *quic.Stream, stream_type: StreamType) !void {
        var buf: [8]u8 = undefined;
        const len = try quic.VarInt.encode(@intFromEnum(stream_type), &buf);
        _ = try stream.write(buf[0..len]);
        _ = self;
    }

    fn sendSettings(self: *Connection) !void {
        var payload_buf: [64]u8 = undefined;
        var payload_len: usize = 0;

        // QPACK_MAX_TABLE_CAPACITY
        payload_len += try quic.VarInt.encode(@intFromEnum(Settings.qpack_max_table_capacity), payload_buf[payload_len..]);
        payload_len += try quic.VarInt.encode(self.local_settings.qpack_max_table_capacity, payload_buf[payload_len..]);

        // MAX_FIELD_SECTION_SIZE
        payload_len += try quic.VarInt.encode(@intFromEnum(Settings.max_field_section_size), payload_buf[payload_len..]);
        payload_len += try quic.VarInt.encode(self.local_settings.max_field_section_size, payload_buf[payload_len..]);

        // QPACK_BLOCKED_STREAMS
        payload_len += try quic.VarInt.encode(@intFromEnum(Settings.qpack_blocked_streams), payload_buf[payload_len..]);
        payload_len += try quic.VarInt.encode(self.local_settings.qpack_blocked_streams, payload_buf[payload_len..]);

        const frame = Frame{
            .frame_type = @intFromEnum(FrameType.settings),
            .payload = payload_buf[0..payload_len],
        };

        const encoded = try frame.encode(self.allocator);
        defer self.allocator.free(encoded);

        if (self.control_stream) |stream| {
            _ = try stream.write(encoded);
        }
    }

    /// Send an HTTP/3 request (client-side)
    pub fn sendRequest(self: *Connection, request: *const Request) !*quic.Stream {
        // Create a new bidirectional stream for the request
        const stream = try self.quic_conn.openBidiStream();

        // Encode headers using QPACK (simplified - just use static encoding)
        var headers_buf = std.ArrayList(u8).init(self.allocator);
        defer headers_buf.deinit();

        // Required pseudo-headers
        try encodeHeader(&headers_buf, ":method", request.method);
        try encodeHeader(&headers_buf, ":path", request.path);
        try encodeHeader(&headers_buf, ":authority", request.authority);
        try encodeHeader(&headers_buf, ":scheme", request.scheme);

        // Regular headers
        var header_iter = request.headers.iterator();
        while (header_iter.next()) |entry| {
            try encodeHeader(&headers_buf, entry.key_ptr.*, entry.value_ptr.*);
        }

        // Send HEADERS frame
        const headers_frame = Frame{
            .frame_type = @intFromEnum(FrameType.headers),
            .payload = headers_buf.items,
        };
        const encoded_headers = try headers_frame.encode(self.allocator);
        defer self.allocator.free(encoded_headers);
        _ = try stream.write(encoded_headers);

        // Send DATA frame if there's a body
        if (request.body) |body| {
            const data_frame = Frame{
                .frame_type = @intFromEnum(FrameType.data),
                .payload = body,
            };
            const encoded_data = try data_frame.encode(self.allocator);
            defer self.allocator.free(encoded_data);
            _ = try stream.write(encoded_data);
        }

        // Track the request stream
        try self.request_streams.put(stream.id, .{ .stream = stream });

        return stream;
    }

    /// Simple header encoding (literal without indexing)
    fn encodeHeader(buf: *std.ArrayList(u8), name: []const u8, value: []const u8) !void {
        // Literal header field without indexing (0x00 prefix)
        try buf.append(0x20); // Literal without name reference

        // Name length and value
        var len_buf: [8]u8 = undefined;
        var len = try quic.VarInt.encode(name.len, &len_buf);
        try buf.appendSlice(len_buf[0..len]);
        try buf.appendSlice(name);

        // Value length and value
        len = try quic.VarInt.encode(value.len, &len_buf);
        try buf.appendSlice(len_buf[0..len]);
        try buf.appendSlice(value);
    }

    /// Close the connection
    pub fn close(self: *Connection) void {
        self.state = .closing;

        // Send GOAWAY frame on control stream
        if (self.control_stream) |stream| {
            var buf: [16]u8 = undefined;
            const len = quic.VarInt.encode(0, &buf) catch 0; // Last stream ID = 0
            const frame = Frame{
                .frame_type = @intFromEnum(FrameType.goaway),
                .payload = buf[0..len],
            };
            if (frame.encode(self.allocator)) |encoded| {
                _ = stream.write(encoded) catch {};
                self.allocator.free(encoded);
            } else |_| {}
        }

        self.quic_conn.close(0, "Connection closed");
        self.state = .closed;
    }
};

/// HTTP/3 server
pub const Server = struct {
    endpoint: quic.Endpoint,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, host: []const u8, port: u16) !Server {
        return Server{
            .endpoint = try quic.Endpoint.initServer(allocator, host, port),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Server) void {
        self.endpoint.deinit();
    }

    /// Accept a new HTTP/3 connection
    pub fn accept(self: *Server) !*Connection {
        const quic_conn = try self.endpoint.accept();
        const http3_conn = try Connection.init(self.allocator, quic_conn, true);
        try http3_conn.connect();
        return http3_conn;
    }
};

/// HTTP/3 client
pub const Client = struct {
    endpoint: quic.Endpoint,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Client {
        return Client{
            .endpoint = try quic.Endpoint.initClient(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Client) void {
        self.endpoint.deinit();
    }

    /// Connect to an HTTP/3 server
    pub fn connect(self: *Client, host: []const u8, port: u16) !*Connection {
        const quic_conn = try self.endpoint.connect(host, port);
        const http3_conn = try Connection.init(self.allocator, quic_conn, false);
        try http3_conn.connect();
        return http3_conn;
    }
};

// Tests
test "frame encoding" {
    const allocator = std.testing.allocator;

    const frame = Frame{
        .frame_type = @intFromEnum(FrameType.data),
        .payload = "Hello, HTTP/3!",
    };

    const encoded = try frame.encode(allocator);
    defer allocator.free(encoded);

    const result = try Frame.parse(encoded);
    try std.testing.expectEqual(@as(u64, @intFromEnum(FrameType.data)), result.frame.frame_type);
    try std.testing.expectEqualStrings("Hello, HTTP/3!", result.frame.payload);
}

test "request initialization" {
    const allocator = std.testing.allocator;

    var req = Request.init(allocator);
    defer req.deinit();

    req.method = "POST";
    req.path = "/api/data";
    req.authority = "example.com";

    try req.setHeader("content-type", "application/json");
    try std.testing.expectEqualStrings("application/json", req.getHeader("content-type").?);
}
