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
    stream: std.net.Stream,
    allocator: std.mem.Allocator,
    is_closed: bool = false,
    id: []const u8,
    room: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, stream: std.net.Stream, id: []const u8) !WebSocket {
        const id_copy = try allocator.dupe(u8, id);
        return WebSocket{
            .stream = stream,
            .allocator = allocator,
            .id = id_copy,
        };
    }

    pub fn deinit(self: *WebSocket) void {
        if (!self.is_closed) {
            self.close() catch {};
        }
        self.allocator.free(self.id);
        if (self.room) |room| {
            self.allocator.free(room);
        }
    }

    /// Join a room
    pub fn join(self: *WebSocket, room_name: []const u8) !void {
        if (self.room) |old_room| {
            self.allocator.free(old_room);
        }
        self.room = try self.allocator.dupe(u8, room_name);
    }

    /// Leave current room
    pub fn leave(self: *WebSocket) void {
        if (self.room) |room| {
            self.allocator.free(room);
            self.room = null;
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

        _ = try self.stream.writeAll(buffer.items);
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

        self.send(&[_]u8{}, .close) catch {};
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

/// WebSocket server with broadcast and room support
pub const WebSocketServer = struct {
    tcp_server: tcp.TcpServer,
    allocator: std.mem.Allocator,
    clients: std.ArrayList(*WebSocket),
    next_id: usize = 0,
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, host: []const u8, port: u16) !WebSocketServer {
        const tcp_server = try tcp.TcpServer.init(allocator, host, port);
        return WebSocketServer{
            .tcp_server = tcp_server,
            .allocator = allocator,
            .clients = std.ArrayList(*WebSocket).init(allocator),
        };
    }

    pub fn deinit(self: *WebSocketServer) void {
        // Close all connections
        for (self.clients.items) |client| {
            client.deinit();
            self.allocator.destroy(client);
        }
        self.clients.deinit();
        self.tcp_server.deinit();
    }

    pub fn accept(self: *WebSocketServer) !*WebSocket {
        var conn = try self.tcp_server.accept();

        // Perform WebSocket handshake
        try performHandshake(self.allocator, &conn);

        // Generate unique ID
        self.mutex.lock();
        defer self.mutex.unlock();

        const id = try std.fmt.allocPrint(self.allocator, "ws_{d}", .{self.next_id});
        defer self.allocator.free(id);
        self.next_id += 1;

        // Create WebSocket and add to clients
        const ws = try self.allocator.create(WebSocket);
        ws.* = try WebSocket.init(self.allocator, conn.stream, id);
        try self.clients.append(ws);

        return ws;
    }

    /// Broadcast message to all connected clients
    pub fn broadcast(self: *WebSocketServer, message: []const u8, opcode: Opcode) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var i: usize = 0;
        while (i < self.clients.items.len) {
            const client = self.clients.items[i];
            if (client.is_closed) {
                // Remove closed connections
                _ = self.clients.swapRemove(i);
                client.deinit();
                self.allocator.destroy(client);
            } else {
                client.send(message, opcode) catch |err| {
                    std.debug.print("Broadcast error for client {s}: {}\n", .{ client.id, err });
                };
                i += 1;
            }
        }
    }

    /// Broadcast to specific room
    pub fn broadcastToRoom(self: *WebSocketServer, room: []const u8, message: []const u8, opcode: Opcode) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.clients.items) |client| {
            if (client.room) |client_room| {
                if (std.mem.eql(u8, client_room, room) and !client.is_closed) {
                    client.send(message, opcode) catch |err| {
                        std.debug.print("Room broadcast error for client {s}: {}\n", .{ client.id, err });
                    };
                }
            }
        }
    }

    /// Broadcast to all except one client
    pub fn broadcastExcept(self: *WebSocketServer, except_id: []const u8, message: []const u8, opcode: Opcode) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.clients.items) |client| {
            if (!std.mem.eql(u8, client.id, except_id) and !client.is_closed) {
                client.send(message, opcode) catch |err| {
                    std.debug.print("Broadcast error for client {s}: {}\n", .{ client.id, err });
                };
            }
        }
    }

    /// Get number of connected clients
    pub fn clientCount(self: *WebSocketServer) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.clients.items.len;
    }

    /// Remove a client from the server
    pub fn removeClient(self: *WebSocketServer, ws: *WebSocket) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.clients.items, 0..) |client, i| {
            if (client == ws) {
                _ = self.clients.swapRemove(i);
                break;
            }
        }
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
