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

/// Per-frame and per-message ceilings. RFC 6455 hard-caps a control frame at
/// 125 bytes; the data-frame and reassembled-message caps bound how much memory
/// a single peer can force the server to buffer before the stream is rejected.
pub const limits = struct {
    pub const max_control_payload = 125;
    pub const max_frame_payload = 16 * 1024 * 1024;
    pub const max_message_size = 64 * 1024 * 1024;
};

/// Endpoint role. RFC 6455 §5.1 makes masking directional: a client MUST mask
/// every frame it sends and a server MUST reject any unmasked frame (and the
/// reverse for a client), so identical frame bytes are valid or invalid
/// depending on which side reads them.
pub const Role = enum { server, client };

/// Decode the 4-bit opcode nibble into a defined opcode. The reserved ranges
/// (0x3-0x7 non-control, 0xB-0xF control) have no enum member, so a bare
/// `@enumFromInt` on them is illegal behaviour — a safety panic that a crafted
/// frame could use to crash the worker. Rejecting them here keeps parsing
/// total over all 256 first-byte values.
fn opcodeFromNibble(nibble: u8) !Opcode {
    return switch (nibble) {
        0x0 => .continuation,
        0x1 => .text,
        0x2 => .binary,
        0x8 => .close,
        0x9 => .ping,
        0xA => .pong,
        else => error.InvalidOpcode,
    };
}

/// Control frames are exactly the opcodes with the high bit of the nibble set.
fn isControlOpcode(opcode: Opcode) bool {
    return (@intFromEnum(opcode) & 0x8) != 0;
}

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
        // Decode the opcode before anything else so a reserved value is a clean
        // error instead of an illegal-behaviour panic.
        const opcode = try opcodeFromNibble(byte1 & 0x0F);

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

        // No extension is ever negotiated, so any reserved bit is a protocol
        // violation rather than data we can silently ignore.
        if (rsv1 or rsv2 or rsv3) return error.ReservedBitsSet;

        if (isControlOpcode(opcode)) {
            // Control frames must not be fragmented and cannot exceed 125 bytes
            // (RFC 6455 §5.5); this also caps close/ping/pong buffering.
            if (!fin) return error.FragmentedControlFrame;
            if (payload_len > limits.max_control_payload) return error.ControlFrameTooLarge;
        } else if (payload_len > limits.max_frame_payload) {
            // Reject an oversized data frame before a caller allocates for it.
            return error.FrameTooLarge;
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

/// Stateful validator for the stream of frames arriving from one peer. It
/// enforces the rules `FrameHeader.parse` cannot decide from a single header in
/// isolation: correct masking for the endpoint role, well-formed fragmentation
/// sequencing, and a ceiling on the reassembled message size. One instance
/// tracks one direction of one connection; a returned error is a protocol
/// failure the caller must act on (fail the connection), never ignore.
pub const FrameValidator = struct {
    role: Role,
    /// Data opcode (text/binary) of a fragmented message in progress, or null
    /// when no message is currently open.
    message_opcode: ?Opcode = null,
    /// Bytes accumulated so far for the message being reassembled.
    message_size: u64 = 0,

    pub fn init(role: Role) FrameValidator {
        return .{ .role = role };
    }

    /// Validate one parsed frame header in arrival order, updating fragmentation
    /// state. Must be called for every frame in sequence.
    pub fn accept(self: *FrameValidator, header: FrameHeader) !void {
        // Directional masking (RFC 6455 §5.1): a server rejects unmasked client
        // frames; a client rejects masked server frames.
        switch (self.role) {
            .server => if (!header.mask) return error.UnmaskedClientFrame,
            .client => if (header.mask) return error.MaskedServerFrame,
        }

        // Control frames may be injected between the fragments of a data
        // message and carry no continuation state; parse already bounded their
        // size and required FIN.
        if (isControlOpcode(header.opcode)) return;

        switch (header.opcode) {
            .continuation => {
                // A continuation with no message open has nothing to continue.
                if (self.message_opcode == null) return error.UnexpectedContinuation;
            },
            .text, .binary => {
                // A new data frame while a message is still open means the peer
                // never sent the FIN/continuation sequence for the last one.
                if (self.message_opcode != null) return error.ExpectedContinuation;
                self.message_opcode = header.opcode;
            },
            else => unreachable, // control opcodes returned above
        }

        self.message_size += header.payload_len;
        if (self.message_size > limits.max_message_size) return error.MessageTooLarge;

        if (header.fin) {
            // Message complete: reset for the next one.
            self.message_opcode = null;
            self.message_size = 0;
        }
    }
};

/// A text-frame payload (and the reason text of a close frame) must be valid
/// UTF-8; RFC 6455 requires the endpoint to fail the connection otherwise.
pub fn validateTextPayload(data: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(data)) return error.InvalidUtf8;
}

/// Validate a close-frame payload: it is either empty, or a 2-byte status code
/// optionally followed by a UTF-8 reason. A lone status byte is malformed, and
/// the status code must be one defined for use on the wire.
pub fn validateClosePayload(data: []const u8) !void {
    if (data.len == 0) return;
    if (data.len == 1) return error.InvalidCloseFrame;
    const code = std.mem.readInt(u16, data[0..2], .big);
    if (!validCloseCode(code)) return error.InvalidCloseCode;
    if (data.len > 2 and !std.unicode.utf8ValidateSlice(data[2..])) return error.InvalidUtf8;
}

/// Close status codes permitted to appear on the wire (RFC 6455 §7.4). 1004,
/// 1005, 1006 and 1015 are reserved and MUST NOT be sent; anything below 1000
/// or in 1016-2999 is undefined. 3000-4999 is the registered/private range.
fn validCloseCode(code: u16) bool {
    return switch (code) {
        1000, 1001, 1002, 1003, 1007, 1008, 1009, 1010, 1011 => true,
        else => code >= 3000 and code <= 4999,
    };
}

/// Return the trimmed value of the first header named `name` (case-insensitive),
/// or null if absent. Header lines end at the blank line; the request line is
/// skipped. Both CRLF and bare-LF line endings are tolerated.
fn headerValue(request: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, request, '\n');
    _ = lines.next(); // request line
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) break; // end of header block
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        if (std.ascii.eqlIgnoreCase(key, name)) {
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
    }
    return null;
}

/// Whether a comma-separated header value contains `token` (case-insensitive),
/// e.g. `Connection: keep-alive, Upgrade`.
fn tokenListContains(value: []const u8, token: []const u8) bool {
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |part| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, part, " \t"), token)) return true;
    }
    return false;
}

/// Validate a client WebSocket upgrade request and return its
/// `Sec-WebSocket-Key`. The handshake is fail-closed: a request missing the
/// `Upgrade: websocket` token, an `Upgrade` entry in `Connection`, exactly
/// `Sec-WebSocket-Version: 13`, or a well-formed 24-char base64 key is rejected
/// rather than upgraded, so a non-WebSocket or downgraded client cannot cross
/// into the frame path.
pub fn validateHandshakeRequest(request: []const u8) ![]const u8 {
    const upgrade = headerValue(request, "Upgrade") orelse return error.MissingUpgradeHeader;
    if (!std.ascii.eqlIgnoreCase(upgrade, "websocket")) return error.MissingUpgradeHeader;

    const connection = headerValue(request, "Connection") orelse return error.MissingConnectionUpgrade;
    if (!tokenListContains(connection, "Upgrade")) return error.MissingConnectionUpgrade;

    const version = headerValue(request, "Sec-WebSocket-Version") orelse return error.UnsupportedWebSocketVersion;
    if (!std.mem.eql(u8, version, "13")) return error.UnsupportedWebSocketVersion;

    const key = headerValue(request, "Sec-WebSocket-Key") orelse return error.MissingWebSocketKey;
    // 16 random bytes base64-encode to exactly 24 characters ending in "==".
    if (key.len != 24 or !std.mem.endsWith(u8, key, "==")) return error.InvalidWebSocketKey;
    return key;
}

/// WebSocket connection
pub const WebSocket = struct {
    stream: std.Io.net.Stream,
    io: std.Io,
    allocator: std.mem.Allocator,
    is_closed: bool = false,
    id: []const u8,
    room: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, stream: std.Io.net.Stream, id: []const u8) !WebSocket {
        const id_copy = try allocator.dupe(u8, id);
        return WebSocket{
            .stream = stream,
            .io = io,
            .allocator = allocator,
            .id = id_copy,
        };
    }

    pub fn deinit(self: *WebSocket) void {
        if (!self.is_closed) {
            // Best-effort close handshake during teardown; a failed close frame
            // still leaves the socket to be closed, so the error is ignorable.
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

        const header = FrameHeader{
            .fin = true,
            .opcode = opcode,
            .mask = false, // Server doesn't mask
            .payload_len = data.len,
        };

        // Serialize the frame header, then stream header + payload to the peer.
        var frame: std.Io.Writer.Allocating = .init(self.allocator);
        defer frame.deinit();
        try header.write(&frame.writer);
        try frame.writer.writeAll(data);

        var write_buf: [64]u8 = undefined;
        var stream_writer = self.stream.writer(self.io, &write_buf);
        try stream_writer.interface.writeAll(frame.written());
        try stream_writer.interface.flush();
    }

    pub fn sendText(self: *WebSocket, text: []const u8) !void {
        try self.send(text, .text);
    }

    pub fn sendBinary(self: *WebSocket, data: []const u8) !void {
        try self.send(data, .binary);
    }

    pub fn receive(self: *WebSocket) !Message {
        if (self.is_closed) return error.WebSocketClosed;

        var read_buf: [64]u8 = undefined;
        var stream_reader = self.stream.reader(self.io, &read_buf);
        const r = &stream_reader.interface;

        // Read header bytes
        var header_buf: [14]u8 = undefined;
        const n = try r.readSliceShort(header_buf[0..2]);
        if (n < 2) return error.ConnectionClosed;

        const header = try FrameHeader.parse(header_buf[0..n]);

        // Read payload
        const payload = try self.allocator.alloc(u8, @intCast(header.payload_len));
        errdefer self.allocator.free(payload);

        const payload_read = try r.readSliceShort(payload);
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

        // Best-effort close frame; the transport is closed unconditionally below,
        // so a failed courtesy close notification is safely ignorable.
        self.send(&[_]u8{}, .close) catch {};
        self.stream.close(self.io);
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
    mutex: std.Io.Mutex = .init,

    /// The `Io` runtime owned by the underlying TCP server. Every socket and
    /// synchronization primitive on this server is driven by it.
    fn io(self: *WebSocketServer) std.Io {
        return self.tcp_server.io.io();
    }

    pub fn init(allocator: std.mem.Allocator, host: []const u8, port: u16) !WebSocketServer {
        const tcp_server = try tcp.TcpServer.init(allocator, host, port);
        return WebSocketServer{
            .tcp_server = tcp_server,
            .allocator = allocator,
            .clients = .empty,
        };
    }

    pub fn deinit(self: *WebSocketServer) void {
        // Close all connections
        for (self.clients.items) |client| {
            client.deinit();
            self.allocator.destroy(client);
        }
        self.clients.deinit(self.allocator);
        self.tcp_server.deinit();
    }

    pub fn accept(self: *WebSocketServer) !*WebSocket {
        var conn = try self.tcp_server.accept();
        // Close the accepted socket if we fail before it is handed to a
        // WebSocket. Once `WebSocket.init` succeeds the socket is owned by `ws`
        // (whose `deinit` closes it), so this guard is disarmed to avoid a
        // double close.
        var stream_owned_by_ws = false;
        errdefer if (!stream_owned_by_ws) conn.close();

        // Perform WebSocket handshake
        try performHandshake(self.allocator, &conn);

        // Generate unique ID
        self.mutex.lockUncancelable(self.io());
        defer self.mutex.unlock(self.io());

        const id = try std.fmt.allocPrint(self.allocator, "ws_{d}", .{self.next_id});
        defer self.allocator.free(id);
        self.next_id += 1;

        // Create WebSocket and add to clients
        const ws = try self.allocator.create(WebSocket);
        errdefer self.allocator.destroy(ws);
        ws.* = try WebSocket.init(self.allocator, conn.io.io(), conn.stream, id);
        stream_owned_by_ws = true;
        errdefer ws.deinit();
        try self.clients.append(self.allocator, ws);

        return ws;
    }

    /// Broadcast message to all connected clients
    pub fn broadcast(self: *WebSocketServer, message: []const u8, opcode: Opcode) !void {
        self.mutex.lockUncancelable(self.io());
        defer self.mutex.unlock(self.io());

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
        self.mutex.lockUncancelable(self.io());
        defer self.mutex.unlock(self.io());

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
        self.mutex.lockUncancelable(self.io());
        defer self.mutex.unlock(self.io());

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
        self.mutex.lockUncancelable(self.io());
        defer self.mutex.unlock(self.io());
        return self.clients.items.len;
    }

    /// Remove a client from the server
    pub fn removeClient(self: *WebSocketServer, ws: *WebSocket) void {
        self.mutex.lockUncancelable(self.io());
        defer self.mutex.unlock(self.io());

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

        // Validate the upgrade request and extract the key.
        const key = try validateHandshakeRequest(buffer[0..n]);

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

test "frame parse rejects reserved opcodes instead of crashing" {
    // opcode 0x3 is reserved; the old @enumFromInt would panic on it. Every
    // reserved nibble must instead surface as a clean error.
    try std.testing.expectError(error.InvalidOpcode, FrameHeader.parse(&[_]u8{ 0x83, 0x00 }));
    try std.testing.expectError(error.InvalidOpcode, FrameHeader.parse(&[_]u8{ 0x8B, 0x00 })); // 0xB reserved control
}

test "frame parse rejects reserved bits (no extension negotiated)" {
    // FIN=1, RSV1=1, opcode=text: RSV set without an extension is a violation.
    try std.testing.expectError(error.ReservedBitsSet, FrameHeader.parse(&[_]u8{ 0xC1, 0x00 }));
}

test "frame parse enforces control-frame constraints" {
    // A close frame with FIN=0 is a fragmented control frame (forbidden).
    try std.testing.expectError(error.FragmentedControlFrame, FrameHeader.parse(&[_]u8{ 0x08, 0x00 }));
    // A ping declaring a 126-byte extended length exceeds the 125-byte cap.
    try std.testing.expectError(error.ControlFrameTooLarge, FrameHeader.parse(&[_]u8{ 0x89, 0x7E, 0x00, 0x7E }));
}

test "frame parse decodes 16-bit extended length (126 marker)" {
    // FIN=1, opcode=binary, len marker 126, 16-bit big-endian 0x0100 = 256.
    const header = try FrameHeader.parse(&[_]u8{ 0x82, 0x7E, 0x01, 0x00 });
    try std.testing.expectEqual(@as(u64, 256), header.payload_len);
    try std.testing.expectEqual(Opcode.binary, header.opcode);
    try std.testing.expect(header.masking_key == null);
}

test "frame parse decodes 64-bit extended length (127 marker)" {
    // FIN=1, opcode=binary, len marker 127, 64-bit big-endian 0x0000000000010000 = 65536.
    const header = try FrameHeader.parse(&[_]u8{ 0x82, 0x7F, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00 });
    try std.testing.expectEqual(@as(u64, 65536), header.payload_len);
}

test "frame parse rejects a truncated extended-length header" {
    // 126 marker promises two length bytes; only one is present.
    try std.testing.expectError(error.InvalidFrame, FrameHeader.parse(&[_]u8{ 0x82, 0x7E, 0x01 }));
    // 127 marker promises eight length bytes; only four are present.
    try std.testing.expectError(error.InvalidFrame, FrameHeader.parse(&[_]u8{ 0x82, 0x7F, 0x00, 0x00, 0x00, 0x00 }));
}

test "frame parse rejects a truncated masking key" {
    // FIN=1, opcode=text, mask bit set, len=5: four masking-key bytes are
    // required after the two-byte header but none are present.
    try std.testing.expectError(error.InvalidFrame, FrameHeader.parse(&[_]u8{ 0x81, 0x85, 0x01, 0x02 }));
}

test "frame parse rejects an oversized data frame before allocating" {
    // 127 marker with a 64-bit length of 0xFFFFFFFF (~4 GiB) far exceeds the
    // 16 MiB data-frame cap, so parsing fails before any payload allocation.
    try std.testing.expectError(error.FrameTooLarge, FrameHeader.parse(&[_]u8{ 0x82, 0x7F, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF }));
}

test "frame validator enforces directional masking" {
    // A server MUST reject an unmasked frame from a client.
    var server = FrameValidator.init(.server);
    try std.testing.expectError(error.UnmaskedClientFrame, server.accept(.{
        .fin = true,
        .opcode = .text,
        .mask = false,
        .payload_len = 3,
    }));

    // A client MUST reject a masked frame from a server.
    var client = FrameValidator.init(.client);
    try std.testing.expectError(error.MaskedServerFrame, client.accept(.{
        .fin = true,
        .opcode = .text,
        .mask = true,
        .payload_len = 3,
        .masking_key = .{ 1, 2, 3, 4 },
    }));
}

test "frame validator enforces fragmentation sequencing" {
    const mk = [4]u8{ 1, 2, 3, 4 };

    // A continuation with no message open has nothing to continue.
    var v1 = FrameValidator.init(.server);
    try std.testing.expectError(error.UnexpectedContinuation, v1.accept(.{
        .fin = true,
        .opcode = .continuation,
        .mask = true,
        .payload_len = 1,
        .masking_key = mk,
    }));

    // A fresh data frame while a message is still open is illegal.
    var v2 = FrameValidator.init(.server);
    try v2.accept(.{ .fin = false, .opcode = .text, .mask = true, .payload_len = 1, .masking_key = mk });
    try std.testing.expectError(error.ExpectedContinuation, v2.accept(.{
        .fin = true,
        .opcode = .text,
        .mask = true,
        .payload_len = 1,
        .masking_key = mk,
    }));

    // A well-formed fragmented message with an interleaved control frame is
    // accepted, and state resets so the next message can start.
    var v3 = FrameValidator.init(.server);
    try v3.accept(.{ .fin = false, .opcode = .text, .mask = true, .payload_len = 1, .masking_key = mk });
    try v3.accept(.{ .fin = true, .opcode = .ping, .mask = true, .payload_len = 0, .masking_key = mk });
    try v3.accept(.{ .fin = true, .opcode = .continuation, .mask = true, .payload_len = 1, .masking_key = mk });
    try v3.accept(.{ .fin = true, .opcode = .text, .mask = true, .payload_len = 1, .masking_key = mk });
}

test "frame validator caps reassembled message size" {
    var v = FrameValidator.init(.server);
    try std.testing.expectError(error.MessageTooLarge, v.accept(.{
        .fin = true,
        .opcode = .binary,
        .mask = true,
        .payload_len = limits.max_message_size + 1,
        .masking_key = .{ 1, 2, 3, 4 },
    }));
}

test "text payload must be valid UTF-8" {
    try validateTextPayload("héllo");
    try std.testing.expectError(error.InvalidUtf8, validateTextPayload(&[_]u8{ 0xFF, 0xFE }));
}

test "close payload code and reason validation" {
    try validateClosePayload(&[_]u8{}); // empty close is allowed
    // A lone status byte is malformed (must be 0 or >=2 bytes).
    try std.testing.expectError(error.InvalidCloseFrame, validateClosePayload(&[_]u8{0x03}));
    // 1000 (normal) is a valid on-the-wire code.
    try validateClosePayload(&[_]u8{ 0x03, 0xE8 });
    // 1005 is reserved and MUST NOT appear on the wire.
    try std.testing.expectError(error.InvalidCloseCode, validateClosePayload(&[_]u8{ 0x03, 0xED }));
    // A valid code with an invalid-UTF-8 reason is rejected.
    try std.testing.expectError(error.InvalidUtf8, validateClosePayload(&[_]u8{ 0x03, 0xE8, 0xFF }));
}

test "handshake request validation is fail-closed" {
    const valid =
        "GET /chat HTTP/1.1\r\n" ++
        "Host: example\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: keep-alive, Upgrade\r\n" ++
        "Sec-WebSocket-Version: 13\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n";
    try std.testing.expectEqualStrings("dGhlIHNhbXBsZSBub25jZQ==", try validateHandshakeRequest(valid));

    // Missing Upgrade header.
    try std.testing.expectError(error.MissingUpgradeHeader, validateHandshakeRequest(
        "GET / HTTP/1.1\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n",
    ));
    // Connection header without the Upgrade token.
    try std.testing.expectError(error.MissingConnectionUpgrade, validateHandshakeRequest(
        "GET / HTTP/1.1\r\nUpgrade: websocket\r\nConnection: keep-alive\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n",
    ));
    // Wrong protocol version (only 13 is supported).
    try std.testing.expectError(error.UnsupportedWebSocketVersion, validateHandshakeRequest(
        "GET / HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 8\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n",
    ));
    // Malformed key (wrong length).
    try std.testing.expectError(error.InvalidWebSocketKey, validateHandshakeRequest(
        "GET / HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: short\r\n\r\n",
    ));
}
