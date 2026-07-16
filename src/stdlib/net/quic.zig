const std = @import("std");

/// QUIC protocol implementation foundation
/// RFC 9000 - QUIC: A UDP-Based Multiplexed and Secure Transport
/// RFC 9001 - Using TLS to Secure QUIC
/// RFC 9114 - HTTP/3
pub const Error = error{
    InvalidPacket,
    InvalidFrame,
    ConnectionError,
    StreamError,
    FlowControlError,
    CryptoError,
    VersionNegotiationRequired,
    ConnectionIdLimitExceeded,
    FrameEncodingError,
    TransportParameterError,
};

/// QUIC version
pub const Version = enum(u32) {
    /// QUIC v1 (RFC 9000)
    v1 = 0x00000001,
    /// QUIC v2 (RFC 9369)
    v2 = 0x6b3343cf,
    /// Version negotiation
    negotiation = 0x00000000,

    pub fn isSupported(version: u32) bool {
        return version == @intFromEnum(Version.v1) or version == @intFromEnum(Version.v2);
    }
};

/// QUIC packet types (long header)
pub const LongPacketType = enum(u2) {
    initial = 0x0,
    zero_rtt = 0x1,
    handshake = 0x2,
    retry = 0x3,
};

/// QUIC frame types
pub const FrameType = enum(u64) {
    padding = 0x00,
    ping = 0x01,
    ack = 0x02,
    ack_ecn = 0x03,
    reset_stream = 0x04,
    stop_sending = 0x05,
    crypto = 0x06,
    new_token = 0x07,
    stream = 0x08, // 0x08-0x0f (with flags)
    max_data = 0x10,
    max_stream_data = 0x11,
    max_streams_bidi = 0x12,
    max_streams_uni = 0x13,
    data_blocked = 0x14,
    stream_data_blocked = 0x15,
    streams_blocked_bidi = 0x16,
    streams_blocked_uni = 0x17,
    new_connection_id = 0x18,
    retire_connection_id = 0x19,
    path_challenge = 0x1a,
    path_response = 0x1b,
    connection_close = 0x1c,
    connection_close_app = 0x1d,
    handshake_done = 0x1e,
    datagram = 0x30, // RFC 9221

    pub fn isStream(frame_type: u64) bool {
        return (frame_type & 0xf8) == 0x08;
    }
};

/// Stream frame flags (encoded in frame type byte)
pub const StreamFlags = packed struct(u3) {
    fin: bool = false,
    len: bool = false,
    off: bool = false,
};

/// Connection ID (variable length, 0-20 bytes)
pub const ConnectionId = struct {
    data: [20]u8 = undefined,
    len: u8 = 0,

    pub fn init(bytes: []const u8) ConnectionId {
        var cid = ConnectionId{};
        const copy_len = @min(bytes.len, 20);
        @memcpy(cid.data[0..copy_len], bytes[0..copy_len]);
        cid.len = @intCast(copy_len);
        return cid;
    }

    pub fn generate() !ConnectionId {
        var cid = ConnectionId{ .len = 8 };
        const io = std.Io.Threaded.global_single_threaded.io();
        try io.randomSecure(cid.data[0..8]);
        return cid;
    }

    pub fn slice(self: *const ConnectionId) []const u8 {
        return self.data[0..self.len];
    }

    pub fn eql(self: *const ConnectionId, other: *const ConnectionId) bool {
        if (self.len != other.len) return false;
        return std.mem.eql(u8, self.data[0..self.len], other.data[0..other.len]);
    }
};

/// Variable-length integer encoding (RFC 9000 Section 16)
pub const VarInt = struct {
    /// Maximum values for each encoding length
    pub const MAX_1BYTE: u64 = 63;
    pub const MAX_2BYTE: u64 = 16383;
    pub const MAX_4BYTE: u64 = 1073741823;
    pub const MAX_8BYTE: u64 = 4611686018427387903;

    /// Decode a variable-length integer
    pub fn decode(data: []const u8) !struct { value: u64, len: usize } {
        if (data.len == 0) return Error.InvalidPacket;

        const prefix = data[0] >> 6;
        // `prefix` is in the range 0..=3 (top two bits), but its u8 type is
        // too wide for a usize shift amount (which requires a u6). Narrow it.
        const len: usize = @as(usize, 1) << @as(u6, @intCast(prefix));

        if (data.len < len) return Error.InvalidPacket;

        var value: u64 = data[0] & 0x3f;
        for (1..len) |i| {
            value = (value << 8) | data[i];
        }

        return .{ .value = value, .len = len };
    }

    /// Encode a variable-length integer
    pub fn encode(value: u64, buffer: []u8) !usize {
        if (value <= MAX_1BYTE) {
            if (buffer.len < 1) return Error.FrameEncodingError;
            buffer[0] = @intCast(value);
            return 1;
        } else if (value <= MAX_2BYTE) {
            if (buffer.len < 2) return Error.FrameEncodingError;
            buffer[0] = @intCast((value >> 8) | 0x40);
            buffer[1] = @intCast(value & 0xff);
            return 2;
        } else if (value <= MAX_4BYTE) {
            if (buffer.len < 4) return Error.FrameEncodingError;
            buffer[0] = @intCast((value >> 24) | 0x80);
            buffer[1] = @intCast((value >> 16) & 0xff);
            buffer[2] = @intCast((value >> 8) & 0xff);
            buffer[3] = @intCast(value & 0xff);
            return 4;
        } else if (value <= MAX_8BYTE) {
            if (buffer.len < 8) return Error.FrameEncodingError;
            buffer[0] = @intCast((value >> 56) | 0xc0);
            buffer[1] = @intCast((value >> 48) & 0xff);
            buffer[2] = @intCast((value >> 40) & 0xff);
            buffer[3] = @intCast((value >> 32) & 0xff);
            buffer[4] = @intCast((value >> 24) & 0xff);
            buffer[5] = @intCast((value >> 16) & 0xff);
            buffer[6] = @intCast((value >> 8) & 0xff);
            buffer[7] = @intCast(value & 0xff);
            return 8;
        }
        return Error.FrameEncodingError;
    }

    /// Get the encoded length for a value
    pub fn encodedLength(value: u64) usize {
        if (value <= MAX_1BYTE) return 1;
        if (value <= MAX_2BYTE) return 2;
        if (value <= MAX_4BYTE) return 4;
        return 8;
    }
};

/// QUIC packet header (long form)
pub const LongHeader = struct {
    header_form: u1 = 1, // Always 1 for long header
    fixed_bit: u1 = 1, // Always 1
    packet_type: LongPacketType,
    reserved: u2 = 0,
    packet_number_length: u2, // Encoded as length - 1
    version: Version,
    dest_conn_id: ConnectionId,
    src_conn_id: ConnectionId,

    pub fn parse(data: []const u8) !struct { header: LongHeader, payload_offset: usize } {
        if (data.len < 7) return Error.InvalidPacket;

        const first_byte = data[0];
        if ((first_byte & 0x80) == 0) return Error.InvalidPacket; // Not a long header

        const packet_type = @as(LongPacketType, @enumFromInt((first_byte >> 4) & 0x03));
        const pn_length = @as(u2, @intCast(first_byte & 0x03));

        const version = @as(Version, @enumFromInt(std.mem.readInt(u32, data[1..5], .big)));

        const dcid_len = data[5];
        if (dcid_len > 20) return Error.InvalidPacket;
        if (data.len < 6 + dcid_len) return Error.InvalidPacket;

        var dcid = ConnectionId{ .len = dcid_len };
        @memcpy(dcid.data[0..dcid_len], data[6 .. 6 + dcid_len]);

        const scid_offset = 6 + dcid_len;
        if (data.len < scid_offset + 1) return Error.InvalidPacket;

        const scid_len = data[scid_offset];
        if (scid_len > 20) return Error.InvalidPacket;
        if (data.len < scid_offset + 1 + scid_len) return Error.InvalidPacket;

        var scid = ConnectionId{ .len = scid_len };
        @memcpy(scid.data[0..scid_len], data[scid_offset + 1 .. scid_offset + 1 + scid_len]);

        const payload_offset = scid_offset + 1 + scid_len;

        return .{
            .header = LongHeader{
                .packet_type = packet_type,
                .packet_number_length = pn_length,
                .version = version,
                .dest_conn_id = dcid,
                .src_conn_id = scid,
            },
            .payload_offset = payload_offset,
        };
    }

    pub fn write(self: *const LongHeader, buffer: []u8) !usize {
        const dcid_len = self.dest_conn_id.len;
        const scid_len = self.src_conn_id.len;
        const min_len = 7 + dcid_len + scid_len;

        if (buffer.len < min_len) return Error.FrameEncodingError;

        // First byte: form(1) | fixed(1) | type(2) | reserved(2) | pn_length(2)
        buffer[0] = 0xc0 | (@as(u8, @intFromEnum(self.packet_type)) << 4) | self.packet_number_length;

        // Version
        std.mem.writeInt(u32, buffer[1..5], @intFromEnum(self.version), .big);

        // DCID
        buffer[5] = dcid_len;
        @memcpy(buffer[6 .. 6 + dcid_len], self.dest_conn_id.data[0..dcid_len]);

        // SCID
        buffer[6 + dcid_len] = scid_len;
        @memcpy(buffer[7 + dcid_len .. 7 + dcid_len + scid_len], self.src_conn_id.data[0..scid_len]);

        return min_len;
    }
};

/// QUIC packet header (short form - used after handshake)
pub const ShortHeader = struct {
    header_form: u1 = 0, // Always 0 for short header
    fixed_bit: u1 = 1,
    spin_bit: bool = false,
    reserved: u2 = 0,
    key_phase: bool = false,
    packet_number_length: u2,
    dest_conn_id: ConnectionId,

    pub fn parse(data: []const u8, dcid_len: u8) !struct { header: ShortHeader, payload_offset: usize } {
        if (data.len < 1 + dcid_len) return Error.InvalidPacket;

        const first_byte = data[0];
        if ((first_byte & 0x80) != 0) return Error.InvalidPacket; // Not a short header

        var dcid = ConnectionId{ .len = dcid_len };
        @memcpy(dcid.data[0..dcid_len], data[1 .. 1 + dcid_len]);

        return .{
            .header = ShortHeader{
                .spin_bit = (first_byte & 0x20) != 0,
                .key_phase = (first_byte & 0x04) != 0,
                .packet_number_length = @intCast(first_byte & 0x03),
                .dest_conn_id = dcid,
            },
            .payload_offset = 1 + dcid_len,
        };
    }
};

/// Stream state
pub const StreamState = enum {
    idle,
    open,
    half_closed_local,
    half_closed_remote,
    closed,
};

/// QUIC stream
pub const Stream = struct {
    id: u64,
    state: StreamState = .idle,
    /// Send buffer
    send_buffer: std.ArrayList(u8),
    /// Receive buffer
    recv_buffer: std.ArrayList(u8),
    /// Next offset to send
    send_offset: u64 = 0,
    /// Next offset expected to receive
    recv_offset: u64 = 0,
    /// Flow control: max data we can send
    max_send_data: u64 = 0,
    /// Flow control: max data peer can send
    max_recv_data: u64 = 65536,
    /// Is bidirectional
    is_bidi: bool,
    /// Is locally initiated
    is_local: bool,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, id: u64, is_local: bool) Stream {
        const is_bidi = (id & 0x02) == 0;
        return Stream{
            .id = id,
            .send_buffer = std.ArrayList(u8).init(allocator),
            .recv_buffer = std.ArrayList(u8).init(allocator),
            .is_bidi = is_bidi,
            .is_local = is_local,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Stream) void {
        self.send_buffer.deinit();
        self.recv_buffer.deinit();
    }

    /// Write data to send buffer
    pub fn write(self: *Stream, data: []const u8) !usize {
        if (self.state == .closed or self.state == .half_closed_local) {
            return Error.StreamError;
        }
        try self.send_buffer.appendSlice(data);
        return data.len;
    }

    /// Read data from receive buffer
    pub fn read(self: *Stream, buffer: []u8) !usize {
        if (self.recv_buffer.items.len == 0) return 0;

        const len = @min(buffer.len, self.recv_buffer.items.len);
        @memcpy(buffer[0..len], self.recv_buffer.items[0..len]);

        // Remove read data from buffer
        std.mem.copyForwards(
            u8,
            self.recv_buffer.items[0 .. self.recv_buffer.items.len - len],
            self.recv_buffer.items[len..],
        );
        self.recv_buffer.shrinkRetainingCapacity(self.recv_buffer.items.len - len);

        return len;
    }

    /// Close the send side
    pub fn closeWrite(self: *Stream) void {
        if (self.state == .open) {
            self.state = .half_closed_local;
        } else if (self.state == .half_closed_remote) {
            self.state = .closed;
        }
    }

    /// Close the receive side
    pub fn closeRead(self: *Stream) void {
        if (self.state == .open) {
            self.state = .half_closed_remote;
        } else if (self.state == .half_closed_local) {
            self.state = .closed;
        }
    }
};

/// Transport parameters (RFC 9000 Section 18)
pub const TransportParams = struct {
    /// Maximum idle timeout (ms)
    max_idle_timeout: u64 = 30000,
    /// Maximum UDP payload size
    max_udp_payload_size: u64 = 65527,
    /// Initial max data
    initial_max_data: u64 = 1048576,
    /// Initial max stream data (bidi local)
    initial_max_stream_data_bidi_local: u64 = 65536,
    /// Initial max stream data (bidi remote)
    initial_max_stream_data_bidi_remote: u64 = 65536,
    /// Initial max stream data (uni)
    initial_max_stream_data_uni: u64 = 65536,
    /// Initial max streams (bidi)
    initial_max_streams_bidi: u64 = 100,
    /// Initial max streams (uni)
    initial_max_streams_uni: u64 = 100,
    /// ACK delay exponent
    ack_delay_exponent: u64 = 3,
    /// Max ACK delay (ms)
    max_ack_delay: u64 = 25,
    /// Disable active migration
    disable_active_migration: bool = false,
    /// Active connection ID limit
    active_connection_id_limit: u64 = 2,
};

/// QUIC connection state
pub const ConnectionState = enum {
    idle,
    handshaking,
    established,
    closing,
    draining,
    closed,
};

/// QUIC connection
pub const Connection = struct {
    /// Local connection IDs
    local_cids: std.ArrayList(ConnectionId),
    /// Remote connection IDs
    remote_cids: std.ArrayList(ConnectionId),
    /// Connection state
    state: ConnectionState = .idle,
    /// Is server
    is_server: bool,
    /// QUIC version
    version: Version = .v1,
    /// Streams
    streams: std.AutoHashMap(u64, *Stream),
    /// Next local stream ID (bidi)
    next_stream_id_bidi: u64,
    /// Next local stream ID (uni)
    next_stream_id_uni: u64,
    /// Transport parameters (local)
    local_params: TransportParams = .{},
    /// Transport parameters (remote)
    remote_params: ?TransportParams = null,
    /// Packet number space: Initial
    initial_pn: u64 = 0,
    /// Packet number space: Handshake
    handshake_pn: u64 = 0,
    /// Packet number space: Application
    app_pn: u64 = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, is_server: bool) !*Connection {
        const conn = try allocator.create(Connection);
        conn.* = Connection{
            .local_cids = std.ArrayList(ConnectionId).init(allocator),
            .remote_cids = std.ArrayList(ConnectionId).init(allocator),
            .is_server = is_server,
            .streams = std.AutoHashMap(u64, *Stream).init(allocator),
            // Stream IDs: client initiates even (0,2,4..), server odd (1,3,5..)
            .next_stream_id_bidi = if (is_server) 1 else 0,
            .next_stream_id_uni = if (is_server) 3 else 2,
            .allocator = allocator,
        };

        // Generate initial local connection ID
        const local_cid = try ConnectionId.generate();
        try conn.local_cids.append(local_cid);

        return conn;
    }

    pub fn deinit(self: *Connection) void {
        var stream_iter = self.streams.iterator();
        while (stream_iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.streams.deinit();
        self.local_cids.deinit();
        self.remote_cids.deinit();
        self.allocator.destroy(self);
    }

    /// Open a new bidirectional stream
    pub fn openBidiStream(self: *Connection) !*Stream {
        const stream_id = self.next_stream_id_bidi;
        self.next_stream_id_bidi += 4;

        const stream = try self.allocator.create(Stream);
        stream.* = Stream.init(self.allocator, stream_id, true);
        stream.state = .open;
        stream.max_send_data = self.remote_params orelse self.local_params.initial_max_stream_data_bidi_local;

        try self.streams.put(stream_id, stream);
        return stream;
    }

    /// Open a new unidirectional stream
    pub fn openUniStream(self: *Connection) !*Stream {
        const stream_id = self.next_stream_id_uni;
        self.next_stream_id_uni += 4;

        const stream = try self.allocator.create(Stream);
        stream.* = Stream.init(self.allocator, stream_id, true);
        stream.state = .open;
        stream.max_send_data = self.remote_params orelse self.local_params.initial_max_stream_data_uni;

        try self.streams.put(stream_id, stream);
        return stream;
    }

    /// Get or create a stream by ID
    pub fn getOrCreateStream(self: *Connection, stream_id: u64) !*Stream {
        if (self.streams.get(stream_id)) |stream| {
            return stream;
        }

        // Determine if this is a valid stream ID for the remote to create
        const is_server_initiated = (stream_id & 0x01) != 0;
        const is_remote = is_server_initiated != self.is_server;

        if (!is_remote) {
            return Error.StreamError;
        }

        const stream = try self.allocator.create(Stream);
        stream.* = Stream.init(self.allocator, stream_id, false);
        stream.state = .open;

        try self.streams.put(stream_id, stream);
        return stream;
    }

    /// Get the primary local connection ID
    pub fn getLocalCid(self: *const Connection) ?ConnectionId {
        if (self.local_cids.items.len > 0) {
            return self.local_cids.items[0];
        }
        return null;
    }

    /// Get the primary remote connection ID
    pub fn getRemoteCid(self: *const Connection) ?ConnectionId {
        if (self.remote_cids.items.len > 0) {
            return self.remote_cids.items[0];
        }
        return null;
    }

    /// Close the connection
    pub fn close(self: *Connection, error_code: u64, reason: []const u8) void {
        _ = error_code;
        _ = reason;
        self.state = .closing;
    }
};

/// QUIC endpoint (server or client)
pub const Endpoint = struct {
    /// UDP socket file descriptor
    socket_fd: std.posix.socket_t,
    /// Active connections by connection ID
    connections: std.AutoHashMap([20]u8, *Connection),
    /// Is server
    is_server: bool,
    allocator: std.mem.Allocator,

    pub fn initServer(allocator: std.mem.Allocator, host: []const u8, port: u16) !Endpoint {
        _ = host;
        // Create UDP socket
        const socket_fd = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);

        // Bind to address
        const addr = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, port);
        try std.posix.bind(socket_fd, &addr.any, addr.getOsSockLen());

        return Endpoint{
            .socket_fd = socket_fd,
            .connections = std.AutoHashMap([20]u8, *Connection).init(allocator),
            .is_server = true,
            .allocator = allocator,
        };
    }

    pub fn initClient(allocator: std.mem.Allocator) !Endpoint {
        const socket_fd = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);

        return Endpoint{
            .socket_fd = socket_fd,
            .connections = std.AutoHashMap([20]u8, *Connection).init(allocator),
            .is_server = false,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Endpoint) void {
        var conn_iter = self.connections.iterator();
        while (conn_iter.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        self.connections.deinit();
        std.posix.close(self.socket_fd);
    }

    /// Create a new connection (client-side)
    pub fn connect(self: *Endpoint, host: []const u8, port: u16) !*Connection {
        _ = host;
        _ = port;

        const conn = try Connection.init(self.allocator, false);
        const cid = conn.getLocalCid() orelse return Error.ConnectionError;

        var key: [20]u8 = undefined;
        @memcpy(key[0..cid.len], cid.data[0..cid.len]);
        @memset(key[cid.len..], 0);

        try self.connections.put(key, conn);
        return conn;
    }

    /// Accept a new connection (server-side)
    pub fn accept(self: *Endpoint) !*Connection {
        var buffer: [65535]u8 = undefined;
        var client_addr: std.posix.sockaddr = undefined;
        var addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);

        const n = try std.posix.recvfrom(self.socket_fd, &buffer, 0, &client_addr, &addr_len);
        if (n == 0) return Error.ConnectionError;

        // Parse packet header
        const result = try LongHeader.parse(buffer[0..n]);
        const dcid = result.header.dest_conn_id;

        // Check if connection already exists
        var key: [20]u8 = undefined;
        @memcpy(key[0..dcid.len], dcid.data[0..dcid.len]);
        @memset(key[dcid.len..], 0);

        if (self.connections.get(key)) |existing| {
            return existing;
        }

        // Create new connection
        const conn = try Connection.init(self.allocator, true);
        try conn.remote_cids.append(result.header.src_conn_id);

        const local_cid = conn.getLocalCid() orelse return Error.ConnectionError;
        @memcpy(key[0..local_cid.len], local_cid.data[0..local_cid.len]);
        @memset(key[local_cid.len..], 0);

        try self.connections.put(key, conn);
        return conn;
    }
};

// Tests
test "varint encoding" {
    var buffer: [8]u8 = undefined;

    // 1-byte encoding
    const len1 = try VarInt.encode(37, &buffer);
    try std.testing.expectEqual(@as(usize, 1), len1);
    try std.testing.expectEqual(@as(u8, 37), buffer[0]);

    // 2-byte encoding
    const len2 = try VarInt.encode(15293, &buffer);
    try std.testing.expectEqual(@as(usize, 2), len2);
}

test "varint decoding" {
    // 1-byte
    const data1 = [_]u8{0x25};
    const result1 = try VarInt.decode(&data1);
    try std.testing.expectEqual(@as(u64, 37), result1.value);
    try std.testing.expectEqual(@as(usize, 1), result1.len);

    // 2-byte
    const data2 = [_]u8{ 0x7b, 0xbd };
    const result2 = try VarInt.decode(&data2);
    try std.testing.expectEqual(@as(u64, 15293), result2.value);
    try std.testing.expectEqual(@as(usize, 2), result2.len);
}

test "varint decoding rejects truncated input" {
    // Empty input has no length prefix at all.
    try std.testing.expectError(Error.InvalidPacket, VarInt.decode(&[_]u8{}));

    // The 0x40 prefix promises a 2-byte varint but only 1 byte is present;
    // decoding must fail rather than read past the slice.
    try std.testing.expectError(Error.InvalidPacket, VarInt.decode(&[_]u8{0x40}));

    // 0xc0 promises an 8-byte varint; a 3-byte buffer is short.
    try std.testing.expectError(Error.InvalidPacket, VarInt.decode(&[_]u8{ 0xc0, 0x00, 0x00 }));
}

test "connection id" {
    const cid1 = try ConnectionId.generate();
    try std.testing.expectEqual(@as(u8, 8), cid1.len);

    const cid2 = ConnectionId.init("test1234");
    try std.testing.expectEqual(@as(u8, 8), cid2.len);
    try std.testing.expect(std.mem.eql(u8, "test1234", cid2.slice()));
}
