const std = @import("std");
const tcp = @import("tcp.zig");

/// HTTP/2 implementation for gRPC support
/// RFC 7540 - Hypertext Transfer Protocol Version 2 (HTTP/2)

pub const Error = error{
    InvalidPreface,
    InvalidFrame,
    ConnectionError,
    StreamError,
    FlowControlError,
    ProtocolError,
};

/// HTTP/2 frame types
pub const FrameType = enum(u8) {
    data = 0x0,
    headers = 0x1,
    priority = 0x2,
    rst_stream = 0x3,
    settings = 0x4,
    push_promise = 0x5,
    ping = 0x6,
    goaway = 0x7,
    window_update = 0x8,
    continuation = 0x9,
};

/// HTTP/2 frame flags
pub const FrameFlags = packed struct(u8) {
    end_stream: bool = false,
    end_headers: bool = false,
    padded: bool = false,
    priority: bool = false,
    _reserved: u4 = 0,
};

/// HTTP/2 frame header (9 bytes)
pub const FrameHeader = struct {
    length: u24,
    type: FrameType,
    flags: u8,
    stream_id: u31,
    reserved: u1 = 0,

    pub fn parse(data: []const u8) !FrameHeader {
        if (data.len < 9) return Error.InvalidFrame;

        const length = (@as(u24, data[0]) << 16) | (@as(u24, data[1]) << 8) | data[2];
        const frame_type = @as(FrameType, @enumFromInt(data[3]));
        const flags = data[4];
        const stream_id_raw = std.mem.readInt(u32, data[5..9], .big);
        const reserved = @as(u1, @intCast((stream_id_raw >> 31) & 1));
        const stream_id = @as(u31, @intCast(stream_id_raw & 0x7FFFFFFF));

        return FrameHeader{
            .length = length,
            .type = frame_type,
            .flags = flags,
            .stream_id = stream_id,
            .reserved = reserved,
        };
    }

    pub fn write(self: FrameHeader, buffer: []u8) !void {
        if (buffer.len < 9) return Error.InvalidFrame;

        // Length (24 bits)
        buffer[0] = @intCast((self.length >> 16) & 0xFF);
        buffer[1] = @intCast((self.length >> 8) & 0xFF);
        buffer[2] = @intCast(self.length & 0xFF);

        // Type
        buffer[3] = @intFromEnum(self.type);

        // Flags
        buffer[4] = self.flags;

        // Stream ID with reserved bit
        const stream_id_with_reserved = (@as(u32, self.reserved) << 31) | @as(u32, self.stream_id);
        std.mem.writeInt(u32, buffer[5..9], stream_id_with_reserved, .big);
    }
};

/// HTTP/2 settings
pub const Settings = struct {
    header_table_size: u32 = 4096,
    enable_push: bool = true,
    max_concurrent_streams: u32 = 100,
    initial_window_size: u32 = 65535,
    max_frame_size: u32 = 16384,
    max_header_list_size: u32 = 8192,

    pub const SettingId = enum(u16) {
        header_table_size = 0x1,
        enable_push = 0x2,
        max_concurrent_streams = 0x3,
        initial_window_size = 0x4,
        max_frame_size = 0x5,
        max_header_list_size = 0x6,
    };
};

/// HTTP/2 stream
pub const Stream = struct {
    id: u31,
    state: State,
    window_size: i32,
    headers: std.StringHashMap([]const u8),
    data: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub const State = enum {
        idle,
        reserved_local,
        reserved_remote,
        open,
        half_closed_local,
        half_closed_remote,
        closed,
    };

    pub fn init(allocator: std.mem.Allocator, id: u31) Stream {
        return Stream{
            .id = id,
            .state = .idle,
            .window_size = 65535,
            .headers = std.StringHashMap([]const u8).init(allocator),
            .data = std.ArrayList(u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Stream) void {
        var it = self.headers.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.headers.deinit();
        self.data.deinit();
    }
};

/// HTTP/2 connection
pub const Connection = struct {
    tcp_conn: tcp.TcpConnection,
    settings: Settings,
    streams: std.AutoHashMap(u31, *Stream),
    next_stream_id: u31 = 1,
    window_size: i32 = 65535,
    allocator: std.mem.Allocator,
    is_client: bool,

    const PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

    pub fn init(allocator: std.mem.Allocator, tcp_conn: tcp.TcpConnection, is_client: bool) Connection {
        return Connection{
            .tcp_conn = tcp_conn,
            .settings = Settings{},
            .streams = std.AutoHashMap(u31, *Stream).init(allocator),
            .allocator = allocator,
            .is_client = is_client,
        };
    }

    pub fn deinit(self: *Connection) void {
        var it = self.streams.valueIterator();
        while (it.next()) |stream| {
            stream.*.deinit();
            self.allocator.destroy(stream.*);
        }
        self.streams.deinit();
    }

    /// Send connection preface (client only)
    pub fn sendPreface(self: *Connection) !void {
        if (!self.is_client) return;

        try self.tcp_conn.writeAll(PREFACE);

        // Send initial SETTINGS frame
        try self.sendSettings();
    }

    /// Verify connection preface (server only)
    pub fn verifyPreface(self: *Connection) !void {
        if (self.is_client) return;

        var buf: [24]u8 = undefined;
        const n = try self.tcp_conn.read(&buf);

        if (n != PREFACE.len or !std.mem.eql(u8, buf[0..n], PREFACE)) {
            return Error.InvalidPreface;
        }

        std.debug.print("✓ HTTP/2 preface verified\n", .{});
    }

    /// Send SETTINGS frame
    pub fn sendSettings(self: *Connection) !void {
        var payload: [36]u8 = undefined;
        var offset: usize = 0;

        // Header table size
        std.mem.writeInt(u16, payload[offset..][0..2], @intFromEnum(Settings.SettingId.header_table_size), .big);
        std.mem.writeInt(u32, payload[offset + 2 ..][0..4], self.settings.header_table_size, .big);
        offset += 6;

        // Enable push
        std.mem.writeInt(u16, payload[offset..][0..2], @intFromEnum(Settings.SettingId.enable_push), .big);
        std.mem.writeInt(u32, payload[offset + 2 ..][0..4], if (self.settings.enable_push) 1 else 0, .big);
        offset += 6;

        // Max concurrent streams
        std.mem.writeInt(u16, payload[offset..][0..2], @intFromEnum(Settings.SettingId.max_concurrent_streams), .big);
        std.mem.writeInt(u32, payload[offset + 2 ..][0..4], self.settings.max_concurrent_streams, .big);
        offset += 6;

        // Initial window size
        std.mem.writeInt(u16, payload[offset..][0..2], @intFromEnum(Settings.SettingId.initial_window_size), .big);
        std.mem.writeInt(u32, payload[offset + 2 ..][0..4], self.settings.initial_window_size, .big);
        offset += 6;

        // Max frame size
        std.mem.writeInt(u16, payload[offset..][0..2], @intFromEnum(Settings.SettingId.max_frame_size), .big);
        std.mem.writeInt(u32, payload[offset + 2 ..][0..4], self.settings.max_frame_size, .big);
        offset += 6;

        // Max header list size
        std.mem.writeInt(u16, payload[offset..][0..2], @intFromEnum(Settings.SettingId.max_header_list_size), .big);
        std.mem.writeInt(u32, payload[offset + 2 ..][0..4], self.settings.max_header_list_size, .big);
        offset += 6;

        try self.sendFrame(.settings, 0, 0, payload[0..offset]);
    }

    /// Send a frame
    pub fn sendFrame(
        self: *Connection,
        frame_type: FrameType,
        flags: u8,
        stream_id: u31,
        payload: []const u8,
    ) !void {
        var header_buf: [9]u8 = undefined;

        const header = FrameHeader{
            .length = @intCast(payload.len),
            .type = frame_type,
            .flags = flags,
            .stream_id = stream_id,
        };

        try header.write(&header_buf);

        try self.tcp_conn.writeAll(&header_buf);
        if (payload.len > 0) {
            try self.tcp_conn.writeAll(payload);
        }
    }

    /// Read a frame
    pub fn readFrame(self: *Connection) !struct { header: FrameHeader, payload: []u8 } {
        var header_buf: [9]u8 = undefined;
        const n = try self.tcp_conn.read(&header_buf);

        if (n != 9) return Error.InvalidFrame;

        const header = try FrameHeader.parse(&header_buf);

        // Read payload
        const payload = try self.allocator.alloc(u8, header.length);
        errdefer self.allocator.free(payload);

        if (header.length > 0) {
            const payload_read = try self.tcp_conn.readAll(payload);
            if (payload_read < header.length) return Error.InvalidFrame;
        }

        return .{ .header = header, .payload = payload };
    }

    /// Create a new stream
    pub fn createStream(self: *Connection) !*Stream {
        const stream_id = self.next_stream_id;
        self.next_stream_id += 2; // Client uses odd, server uses even

        const stream = try self.allocator.create(Stream);
        errdefer self.allocator.destroy(stream);

        stream.* = Stream.init(self.allocator, stream_id);
        try self.streams.put(stream_id, stream);

        return stream;
    }

    /// Get stream by ID
    pub fn getStream(self: *Connection, stream_id: u31) ?*Stream {
        return self.streams.get(stream_id);
    }

    /// Send HEADERS frame
    pub fn sendHeaders(
        self: *Connection,
        stream_id: u31,
        headers: []const struct { name: []const u8, value: []const u8 },
        end_stream: bool,
    ) !void {
        // Simplified HPACK encoding (would need full implementation)
        var payload: std.ArrayList(u8) = .{};
        defer payload.deinit(self.allocator);

        for (headers) |header| {
            // Literal header field with incremental indexing
            try payload.append(self.allocator, 0x40); // Literal header
            try payload.append(self.allocator, @intCast(header.name.len));
            try payload.appendSlice(self.allocator, header.name);
            try payload.append(self.allocator, @intCast(header.value.len));
            try payload.appendSlice(self.allocator, header.value);
        }

        const flags: u8 = if (end_stream) 0x05 else 0x04; // END_HEADERS | END_STREAM
        try self.sendFrame(.headers, flags, stream_id, payload.items);
    }

    /// Send DATA frame
    pub fn sendData(self: *Connection, stream_id: u31, data: []const u8, end_stream: bool) !void {
        const flags: u8 = if (end_stream) 0x01 else 0x00; // END_STREAM
        try self.sendFrame(.data, flags, stream_id, data);
    }

    /// Send PING frame
    pub fn sendPing(self: *Connection, data: [8]u8) !void {
        try self.sendFrame(.ping, 0, 0, &data);
    }

    /// Send GOAWAY frame
    pub fn sendGoAway(self: *Connection, last_stream_id: u31, error_code: u32) !void {
        var payload: [8]u8 = undefined;
        std.mem.writeInt(u32, payload[0..4], last_stream_id, .big);
        std.mem.writeInt(u32, payload[4..8], error_code, .big);

        try self.sendFrame(.goaway, 0, 0, &payload);
    }
};

/// HTTP/2 server for gRPC
pub const Server = struct {
    tcp_server: tcp.TcpServer,
    settings: Settings,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, host: []const u8, port: u16) !Server {
        return Server{
            .tcp_server = try tcp.TcpServer.init(allocator, host, port),
            .settings = Settings{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Server) void {
        self.tcp_server.deinit();
    }

    pub fn accept(self: *Server) !Connection {
        const tcp_conn = try self.tcp_server.accept();

        var h2_conn = Connection.init(self.allocator, tcp_conn, false);

        // Verify HTTP/2 preface
        try h2_conn.verifyPreface();

        // Send initial SETTINGS
        try h2_conn.sendSettings();

        std.debug.print("✓ HTTP/2 connection established\n", .{});

        return h2_conn;
    }
};

test "http2 frame header" {
    var buf: [9]u8 = undefined;

    const header = FrameHeader{
        .length = 100,
        .type = .headers,
        .flags = 0x04,
        .stream_id = 1,
    };

    try header.write(&buf);

    const parsed = try FrameHeader.parse(&buf);

    try std.testing.expectEqual(header.length, parsed.length);
    try std.testing.expectEqual(header.type, parsed.type);
    try std.testing.expectEqual(header.flags, parsed.flags);
    try std.testing.expectEqual(header.stream_id, parsed.stream_id);
}
