const std = @import("std");
const tcp = @import("tcp.zig");
const hpack = @import("hpack.zig");

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
    // Non-exhaustive: RFC 7540 §4.1 requires unknown frame types to be ignored,
    // not rejected. Keeping this open means @enumFromInt on an unknown type byte
    // is well-defined instead of an illegal-behavior panic, and processFrame's
    // else-prong discards it.
    _,
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

/// Stream priority
pub const Priority = struct {
    stream_dependency: u31 = 0,
    weight: u8 = 16, // Default weight
    exclusive: bool = false,

    pub fn parse(data: []const u8) !Priority {
        if (data.len < 5) return Error.InvalidFrame;

        const dependency_raw = std.mem.readInt(u32, data[0..4], .big);
        const exclusive = (dependency_raw >> 31) == 1;
        const stream_dependency = @as(u31, @intCast(dependency_raw & 0x7FFFFFFF));
        const weight = data[4];

        return Priority{
            .stream_dependency = stream_dependency,
            .weight = weight,
            .exclusive = exclusive,
        };
    }

    pub fn write(self: Priority, buffer: []u8) !void {
        if (buffer.len < 5) return Error.InvalidFrame;

        const dependency_with_exclusive = (@as(u32, if (self.exclusive) 1 else 0) << 31) | @as(u32, self.stream_dependency);
        std.mem.writeInt(u32, buffer[0..4], dependency_with_exclusive, .big);
        buffer[4] = self.weight;
    }
};

/// HTTP/2 stream
pub const Stream = struct {
    id: u31,
    state: State,
    window_size: i32,
    headers: std.StringHashMap([]const u8),
    data: std.ArrayList(u8),
    priority: Priority,
    dependency_count: u32 = 0,
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
            .data = .empty,
            .priority = Priority{},
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
        self.data.deinit(self.allocator);
    }

    pub fn updatePriority(self: *Stream, priority: Priority) void {
        self.priority = priority;
    }

    pub fn incrementDependencyCount(self: *Stream) void {
        self.dependency_count += 1;
    }

    pub fn decrementDependencyCount(self: *Stream) void {
        if (self.dependency_count > 0) {
            self.dependency_count -= 1;
        }
    }
};

/// HTTP/2 connection
pub const Connection = struct {
    tcp_conn: tcp.TcpConnection,
    settings: Settings,
    streams: std.AutoHashMap(u31, *Stream),
    next_stream_id: u31 = 1,
    window_size: i32 = 65535,
    hpack_encoder: hpack.Context,
    hpack_decoder: hpack.Context,
    allocator: std.mem.Allocator,
    is_client: bool,

    const PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

    pub fn init(allocator: std.mem.Allocator, tcp_conn: tcp.TcpConnection, is_client: bool) Connection {
        return Connection{
            .tcp_conn = tcp_conn,
            .settings = Settings{},
            .streams = std.AutoHashMap(u31, *Stream).init(allocator),
            .hpack_encoder = hpack.Context.init(allocator),
            .hpack_decoder = hpack.Context.init(allocator),
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
        self.hpack_encoder.deinit();
        self.hpack_decoder.deinit();
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
        // HPACK encode headers
        var payload_buffer: [16384]u8 = undefined; // Max frame size
        var offset: usize = 0;

        for (headers) |header| {
            // Use literal with incremental indexing for most headers
            const header_len = try hpack.encodeHeader(
                payload_buffer[offset..],
                &self.hpack_encoder,
                header.name,
                header.value,
                .literal_with_indexing,
            );
            offset += header_len;
        }

        const flags: u8 = if (end_stream) 0x05 else 0x04; // END_HEADERS | END_STREAM
        try self.sendFrame(.headers, flags, stream_id, payload_buffer[0..offset]);
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

    /// Send PRIORITY frame
    pub fn sendPriority(self: *Connection, stream_id: u31, priority: Priority) !void {
        var payload: [5]u8 = undefined;
        try priority.write(&payload);
        try self.sendFrame(.priority, 0, stream_id, &payload);
    }

    /// Send WINDOW_UPDATE frame
    pub fn sendWindowUpdate(self: *Connection, stream_id: u31, increment: u32) !void {
        var payload: [4]u8 = undefined;
        std.mem.writeInt(u32, &payload, increment, .big);
        try self.sendFrame(.window_update, 0, stream_id, &payload);
    }

    /// Send RST_STREAM frame
    pub fn sendRstStream(self: *Connection, stream_id: u31, error_code: u32) !void {
        var payload: [4]u8 = undefined;
        std.mem.writeInt(u32, &payload, error_code, .big);
        try self.sendFrame(.rst_stream, 0, stream_id, &payload);
    }

    /// Process incoming frame
    pub fn processFrame(self: *Connection, frame: struct { header: FrameHeader, payload: []u8 }) !void {
        defer self.allocator.free(frame.payload);

        switch (frame.header.type) {
            .data => try self.handleDataFrame(frame.header, frame.payload),
            .headers => try self.handleHeadersFrame(frame.header, frame.payload),
            .priority => try self.handlePriorityFrame(frame.header, frame.payload),
            .rst_stream => try self.handleRstStreamFrame(frame.header, frame.payload),
            .settings => try self.handleSettingsFrame(frame.header, frame.payload),
            .ping => try self.handlePingFrame(frame.header, frame.payload),
            .goaway => try self.handleGoAwayFrame(frame.header, frame.payload),
            .window_update => try self.handleWindowUpdateFrame(frame.header, frame.payload),
            else => {
                std.debug.print("Unhandled frame type: {}\n", .{frame.header.type});
            },
        }
    }

    fn handleDataFrame(self: *Connection, header: FrameHeader, payload: []const u8) !void {
        const stream = self.getStream(header.stream_id) orelse return Error.StreamError;

        // Update flow control window
        stream.window_size -= @intCast(payload.len);
        self.window_size -= @intCast(payload.len);

        // Append data to stream
        try stream.data.appendSlice(stream.allocator, payload);

        // Update stream state
        if ((header.flags & 0x01) != 0) { // END_STREAM
            stream.state = if (stream.state == .open) .half_closed_remote else .closed;
        }

        // Send WINDOW_UPDATE if needed
        if (stream.window_size < 32768) {
            const increment = 65535 - @as(u32, @intCast(stream.window_size));
            try self.sendWindowUpdate(header.stream_id, increment);
            stream.window_size += @intCast(increment);
        }
    }

    fn handleHeadersFrame(self: *Connection, header: FrameHeader, payload: []const u8) !void {
        var stream = self.getStream(header.stream_id) orelse blk: {
            // Create new stream
            const new_stream = try self.createStream();
            break :blk new_stream;
        };

        // Decode HPACK-encoded headers
        var header_data = payload;
        var priority_len: usize = 0;

        // Handle priority if present
        if ((header.flags & 0x20) != 0) { // PRIORITY flag
            if (payload.len >= 5) {
                const priority = try Priority.parse(payload[0..5]);
                stream.updatePriority(priority);
                priority_len = 5;
                header_data = payload[5..];
            }
        }

        // Decode headers
        var decoded_headers = try hpack.decodeHeaderBlock(header_data, &self.hpack_decoder, self.allocator);
        defer {
            for (decoded_headers.items) |h| {
                self.allocator.free(h.name);
                self.allocator.free(h.value);
            }
            decoded_headers.deinit(self.allocator);
        }

        // Store headers in stream
        for (decoded_headers.items) |h| {
            try stream.headers.put(
                try self.allocator.dupe(u8, h.name),
                try self.allocator.dupe(u8, h.value),
            );
        }

        stream.state = .open;

        if ((header.flags & 0x01) != 0) { // END_STREAM
            stream.state = .half_closed_remote;
        }
    }

    fn handlePriorityFrame(self: *Connection, header: FrameHeader, payload: []const u8) !void {
        const stream = self.getStream(header.stream_id) orelse return Error.StreamError;
        const priority = try Priority.parse(payload);

        stream.updatePriority(priority);

        // Update dependency graph
        if (priority.stream_dependency != 0) {
            if (self.getStream(priority.stream_dependency)) |dep_stream| {
                dep_stream.incrementDependencyCount();
            }
        }
    }

    fn handleRstStreamFrame(self: *Connection, header: FrameHeader, payload: []const u8) !void {
        _ = payload;

        if (self.getStream(header.stream_id)) |stream| {
            stream.state = .closed;
        }
    }

    fn handleSettingsFrame(self: *Connection, header: FrameHeader, payload: []const u8) !void {
        if ((header.flags & 0x01) != 0) { // ACK flag
            return; // Settings acknowledged
        }

        // Parse settings
        var offset: usize = 0;
        while (offset + 6 <= payload.len) : (offset += 6) {
            const setting_id = std.mem.readInt(u16, payload[offset..][0..2], .big);
            const value = std.mem.readInt(u32, payload[offset + 2 ..][0..4], .big);

            switch (setting_id) {
                1 => self.settings.header_table_size = value,
                2 => self.settings.enable_push = value != 0,
                3 => self.settings.max_concurrent_streams = value,
                4 => self.settings.initial_window_size = value,
                5 => self.settings.max_frame_size = value,
                6 => self.settings.max_header_list_size = value,
                else => {},
            }
        }

        // Send SETTINGS ACK
        try self.sendFrame(.settings, 0x01, 0, &[_]u8{});
    }

    fn handlePingFrame(self: *Connection, header: FrameHeader, payload: []const u8) !void {
        if ((header.flags & 0x01) == 0) { // Not ACK, send response
            try self.sendFrame(.ping, 0x01, 0, payload);
        }
    }

    fn handleGoAwayFrame(_: *Connection, _: FrameHeader, _: []const u8) !void {
        // Connection is closing
        std.debug.print("GOAWAY received, closing connection\n", .{});
    }

    fn handleWindowUpdateFrame(self: *Connection, header: FrameHeader, payload: []const u8) !void {
        const increment = std.mem.readInt(u32, payload[0..4], .big) & 0x7FFFFFFF;

        if (header.stream_id == 0) {
            // Connection-level window update
            self.window_size += @intCast(increment);
        } else {
            // Stream-level window update
            if (self.getStream(header.stream_id)) |stream| {
                stream.window_size += @intCast(increment);
            }
        }
    }

    /// Run event loop to process frames
    pub fn runEventLoop(self: *Connection) !void {
        while (true) {
            const frame = self.readFrame() catch |err| {
                if (err == error.ConnectionClosed) break;
                return err;
            };

            try self.processFrame(frame);
        }
    }

    /// Get sorted list of streams by priority
    pub fn getStreamsByPriority(self: *Connection) ![]u31 {
        var stream_ids: std.ArrayList(u31) = .empty;
        defer stream_ids.deinit(self.allocator);

        var it = self.streams.keyIterator();
        while (it.next()) |id| {
            try stream_ids.append(self.allocator, id.*);
        }

        const ids = try stream_ids.toOwnedSlice(self.allocator);

        // Sort by weight (simplified - real implementation would use full dependency tree)
        std.sort.block(u31, ids, self, struct {
            fn lessThan(conn: *Connection, a: u31, b: u31) bool {
                const stream_a = conn.getStream(a) orelse return false;
                const stream_b = conn.getStream(b) orelse return true;
                return stream_a.priority.weight > stream_b.priority.weight;
            }
        }.lessThan);

        return ids;
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

test "http2 frame header rejects short buffer" {
    const truncated = [_]u8{ 0x00, 0x00, 0x08, 0x00 }; // only 4 of 9 bytes
    try std.testing.expectError(Error.InvalidFrame, FrameHeader.parse(&truncated));
}

test "http2 frame header tolerates unknown frame type" {
    // Type byte 0xFF is not a defined frame type. Parsing it must not panic on
    // @enumFromInt (FrameType is non-exhaustive); the value round-trips as an
    // unnamed enum tag so processFrame's else-prong can ignore it per RFC 7540.
    var buf = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    buf[3] = 0xFF; // frame type
    buf[8] = 0x01; // stream id = 1
    const parsed = try FrameHeader.parse(&buf);
    try std.testing.expectEqual(@as(u8, 0xFF), @intFromEnum(parsed.type));
    try std.testing.expectEqual(@as(u31, 1), parsed.stream_id);
}

test "http2 priority round-trips through the 5-byte wire form" {
    const priority = Priority{
        .stream_dependency = 5,
        .weight = 20,
        .exclusive = true,
    };

    var buffer: [5]u8 = undefined;
    try priority.write(&buffer);

    const parsed = try Priority.parse(&buffer);

    try std.testing.expectEqual(priority.stream_dependency, parsed.stream_dependency);
    try std.testing.expectEqual(priority.weight, parsed.weight);
    try std.testing.expectEqual(priority.exclusive, parsed.exclusive);
}

test "http2 stream starts idle and tracks priority updates" {
    const allocator = std.testing.allocator;

    var stream = Stream.init(allocator, 1);
    defer stream.deinit();

    try std.testing.expectEqual(Stream.State.idle, stream.state);

    stream.state = .open;
    try std.testing.expectEqual(Stream.State.open, stream.state);

    stream.updatePriority(Priority{ .weight = 30 });
    try std.testing.expectEqual(@as(u8, 30), stream.priority.weight);
}
