const std = @import("std");
const tcp = @import("tcp.zig");

/// WebSocket opcodes
pub const Opcode = enum(u8) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
};

/// WebSocket frame header
pub const FrameHeader = struct {
    fin: bool,
    rsv1: bool = false,
    rsv2: bool = false,
    rsv3: bool = false,
    opcode: Opcode,
    mask: bool,
    payload_len: u64,
    masking_key: ?[4]u8 = null,

    pub fn parse(data: []const u8) !FrameHeader {
        if (data.len < 2) return error.InvalidFrame;

        const byte1 = data[0];
        const byte2 = data[1];

        const fin = (byte1 & 0x80) != 0;
        const rsv1 = (byte1 & 0x40) != 0;
        const rsv2 = (byte1 & 0x20) != 0;
        const rsv3 = (byte1 & 0x10) != 0;
        const opcode = @as(Opcode, @enumFromInt(byte1 & 0x0F));

        const mask = (byte2 & 0x80) != 0;
        var payload_len: u64 = byte2 & 0x7F;

        var offset: usize = 2;

        if (payload_len == 126) {
            if (data.len < 4) return error.InvalidFrame;
            payload_len = std.mem.readInt(u16, data[2..4], .big);
            offset = 4;
        } else if (payload_len == 127) {
            if (data.len < 10) return error.InvalidFrame;
            payload_len = std.mem.readInt(u64, data[2..10], .big);
            offset = 10;
        }

        var masking_key: ?[4]u8 = null;
        if (mask) {
            if (data.len < offset + 4) return error.InvalidFrame;
            masking_key = data[offset..][0..4].*;
            offset += 4;
        }

        return FrameHeader{
            .fin = fin,
            .rsv1 = rsv1,
            .rsv2 = rsv2,
            .rsv3 = rsv3,
            .opcode = opcode,
            .mask = mask,
            .payload_len = payload_len,
            .masking_key = masking_key,
        };
    }

    pub fn write(self: FrameHeader, writer: anytype) !void {
        var byte1: u8 = 0;
        if (self.fin) byte1 |= 0x80;
        if (self.rsv1) byte1 |= 0x40;
        if (self.rsv2) byte1 |= 0x20;
        if (self.rsv3) byte1 |= 0x10;
        byte1 |= @intFromEnum(self.opcode);

        try writer.writeByte(byte1);

        var byte2: u8 = 0;
        if (self.mask) byte2 |= 0x80;

        if (self.payload_len < 126) {
            byte2 |= @intCast(self.payload_len);
            try writer.writeByte(byte2);
        } else if (self.payload_len < 65536) {
            byte2 |= 126;
            try writer.writeByte(byte2);
            try writer.writeInt(u16, @intCast(self.payload_len), .big);
        } else {
            byte2 |= 127;
            try writer.writeByte(byte2);
            try writer.writeInt(u64, self.payload_len, .big);
        }

        if (self.masking_key) |key| {
            try writer.writeAll(&key);
        }
    }
};

/// WebSocket connection
pub const WebSocket = struct {
    stream: std.Io.net.Socket.Handle,
    allocator: std.mem.Allocator,
    is_closed: bool = false,

    pub fn init(allocator: std.mem.Allocator, stream: std.Io.net.Socket.Handle) WebSocket {
        return WebSocket{
            .stream = stream,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *WebSocket) void {
        if (!self.is_closed) {
            self.close() catch {};
        }
    }

    pub fn send(self: *WebSocket, data: []const u8, opcode: Opcode) !void {
        if (self.is_closed) return error.WebSocketClosed;

        var buffer: std.ArrayList(u8) = .{};
        defer buffer.deinit(self.allocator);

        const header = FrameHeader{
            .fin = true,
            .opcode = opcode,
            .mask = false, // Server doesn't mask
            .payload_len = data.len,
        };

        const writer = buffer.writer(self.allocator);
        try header.write(writer);
        try buffer.appendSlice(self.allocator, data);

        try self.stream.writeAll(buffer.items);
    }

    pub fn sendText(self: *WebSocket, text: []const u8) !void {
        try self.send(text, .text);
    }

    pub fn sendBinary(self: *WebSocket, data: []const u8) !void {
        try self.send(data, .binary);
    }

    pub fn receive(self: *WebSocket) !Message {
        if (self.is_closed) return error.WebSocketClosed;

        // Read header bytes
        var header_buf: [14]u8 = undefined;
        const n = try self.stream.read(header_buf[0..2]);
        if (n < 2) return error.ConnectionClosed;

        const header = try FrameHeader.parse(header_buf[0..n]);

        // Read payload
        const payload = try self.allocator.alloc(u8, @intCast(header.payload_len));
        errdefer self.allocator.free(payload);

        const payload_read = try self.stream.readAll(payload);
        if (payload_read < header.payload_len) return error.IncompleteFrame;

        // Unmask if needed
        if (header.masking_key) |key| {
            for (payload, 0..) |*byte, i| {
                byte.* ^= key[i % 4];
            }
        }

        return Message{
            .opcode = header.opcode,
            .data = payload,
            .allocator = self.allocator,
        };
    }

    pub fn ping(self: *WebSocket) !void {
        try self.send(&[_]u8{}, .ping);
    }

    pub fn pong(self: *WebSocket) !void {
        try self.send(&[_]u8{}, .pong);
    }

    pub fn close(self: *WebSocket) !void {
        if (self.is_closed) return;

        try self.send(&[_]u8{}, .close);
        self.stream.close();
        self.is_closed = true;
    }
};

/// WebSocket message
pub const Message = struct {
    opcode: Opcode,
    data: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Message) void {
        self.allocator.free(self.data);
    }

    pub fn isText(self: Message) bool {
        return self.opcode == .text;
    }

    pub fn isBinary(self: Message) bool {
        return self.opcode == .binary;
    }

    pub fn isClose(self: Message) bool {
        return self.opcode == .close;
    }

    pub fn isPing(self: Message) bool {
        return self.opcode == .ping;
    }

    pub fn isPong(self: Message) bool {
        return self.opcode == .pong;
    }

    pub fn getText(self: Message) ?[]const u8 {
        if (self.isText()) return self.data;
        return null;
    }
};

/// WebSocket server
pub const WebSocketServer = struct {
    tcp_server: tcp.TcpServer,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, host: []const u8, port: u16) !WebSocketServer {
        const tcp_server = try tcp.TcpServer.init(allocator, host, port);
        return WebSocketServer{
            .tcp_server = tcp_server,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *WebSocketServer) void {
        self.tcp_server.deinit();
    }

    pub fn accept(self: *WebSocketServer) !WebSocket {
        var conn = try self.tcp_server.accept();

        // Perform WebSocket handshake
        try performHandshake(self.allocator, &conn);

        return WebSocket.init(self.allocator, conn.stream);
    }

    fn performHandshake(allocator: std.mem.Allocator, conn: *tcp.TcpConnection) !void {
        // Read HTTP request
        var buffer: [8192]u8 = undefined;
        const n = try conn.read(&buffer);

        // Extract WebSocket key
        const key = try extractWebSocketKey(buffer[0..n]);

        // Generate accept key
        const accept_key = try generateAcceptKey(allocator, key);
        defer allocator.free(accept_key);

        // Send handshake response
        const response = try std.fmt.allocPrint(
            allocator,
            "HTTP/1.1 101 Switching Protocols\r\n" ++
                "Upgrade: websocket\r\n" ++
                "Connection: Upgrade\r\n" ++
                "Sec-WebSocket-Accept: {s}\r\n" ++
                "\r\n",
            .{accept_key},
        );
        defer allocator.free(response);

        try conn.writeAll(response);
    }

    fn extractWebSocketKey(data: []const u8) ![]const u8 {
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "Sec-WebSocket-Key:")) {
                const key_start = std.mem.indexOf(u8, line, ":") orelse continue;
                const key = std.mem.trim(u8, line[key_start + 1 ..], " \r\n");
                return key;
            }
        }
        return error.WebSocketKeyNotFound;
    }

    fn generateAcceptKey(allocator: std.mem.Allocator, client_key: []const u8) ![]const u8 {
        const magic_string = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

        const combined = try std.fmt.allocPrint(allocator, "{s}{s}", .{ client_key, magic_string });
        defer allocator.free(combined);

        var hasher = std.crypto.hash.Sha1.init(.{});
        hasher.update(combined);
        var hash: [20]u8 = undefined;
        hasher.final(&hash);

        // Base64 encode
        const encoder = std.base64.standard.Encoder;
        var encoded: [28]u8 = undefined;
        const result = encoder.encode(&encoded, &hash);

        return try allocator.dupe(u8, result);
    }
};

test "websocket frame header" {
    const data = [_]u8{ 0x81, 0x05 }; // FIN=1, opcode=text, payload_len=5

    const header = try FrameHeader.parse(&data);

    try std.testing.expect(header.fin);
    try std.testing.expectEqual(Opcode.text, header.opcode);
    try std.testing.expectEqual(@as(u64, 5), header.payload_len);
}
