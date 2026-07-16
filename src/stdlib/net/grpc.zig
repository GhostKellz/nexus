const std = @import("std");
const tcp = @import("tcp.zig");

/// Minimal byte sink over an unmanaged `std.ArrayList(u8)`.
///
/// `std.ArrayList` is now unmanaged and no longer provides a `.writer()`
/// method, so this adapter supplies the `writeByte`/`writeAll` surface the
/// generic Protobuf encoders (which take `writer: anytype`) expect, appending
/// straight into the backing list.
const ArrayListWriter = struct {
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,

    fn writeByte(self: ArrayListWriter, byte: u8) !void {
        try self.list.append(self.allocator, byte);
    }

    fn writeAll(self: ArrayListWriter, bytes: []const u8) !void {
        try self.list.appendSlice(self.allocator, bytes);
    }
};

/// gRPC service method handler
pub const MethodHandler = *const fn (request: []const u8, allocator: std.mem.Allocator) anyerror![]u8;

/// gRPC method definition
pub const Method = struct {
    name: []const u8,
    handler: MethodHandler,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Method) void {
        self.allocator.free(self.name);
    }
};

/// gRPC service configuration
pub const ServiceConfig = struct {
    port: u16,
    host: []const u8 = "0.0.0.0",
};

/// gRPC server
pub const Server = struct {
    config: ServiceConfig,
    tcp_server: tcp.TcpServer,
    methods: std.ArrayList(Method),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: ServiceConfig) !Server {
        const tcp_server = try tcp.TcpServer.init(allocator, config.host, config.port);

        return Server{
            .config = config,
            .tcp_server = tcp_server,
            .methods = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Server) void {
        self.tcp_server.deinit();
        for (self.methods.items) |*method| {
            method.deinit();
        }
        self.methods.deinit(self.allocator);
    }

    /// Register a gRPC method
    pub fn registerMethod(self: *Server, name: []const u8, handler: MethodHandler) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        // If the append below fails, ownership of name_copy never transfers to
        // the methods list, so free it here rather than leaking it.
        errdefer self.allocator.free(name_copy);

        const method = Method{
            .name = name_copy,
            .handler = handler,
            .allocator = self.allocator,
        };

        try self.methods.append(self.allocator, method);
    }

    /// Start serving gRPC requests
    pub fn serve(self: *Server) !void {
        std.debug.print("gRPC server listening on {s}:{d}\n", .{ self.config.host, self.config.port });

        while (true) {
            var conn = try self.tcp_server.accept();
            defer conn.close();

            self.handleConnection(&conn) catch |err| {
                std.debug.print("Error handling gRPC connection: {}\n", .{err});
            };
        }
    }

    fn handleConnection(self: *Server, conn: *tcp.TcpConnection) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        // Read gRPC request (simplified - real gRPC uses HTTP/2)
        var buffer: [8192]u8 = undefined;
        const n = try conn.read(&buffer);
        if (n == 0) return;

        // Parse gRPC message
        const request_data = buffer[0..n];

        // Simple gRPC frame format:
        // - 1 byte: compressed flag (0 = not compressed)
        // - 4 bytes: message length (big-endian)
        // - N bytes: message data

        if (request_data.len < 5) return error.InvalidGrpcFrame;

        const compressed = request_data[0];
        _ = compressed; // For now, we don't support compression

        const message_len = std.mem.readInt(u32, request_data[1..5], .big);
        if (5 + message_len > request_data.len) return error.IncompleteMessage;

        const message_data = request_data[5 .. 5 + message_len];

        // Find method from path (simplified - would parse from HTTP/2 headers)
        // For demo, we'll use the first method
        if (self.methods.items.len == 0) return error.NoMethodsRegistered;

        const method = &self.methods.items[0];
        const response_data = try method.handler(message_data, arena_allocator);

        // Build gRPC response frame
        var response_frame: std.ArrayList(u8) = .empty;
        defer response_frame.deinit(arena_allocator);

        // Compressed flag (0 = not compressed)
        try response_frame.append(arena_allocator, 0);

        // Message length (big-endian u32)
        const len_bytes = std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(response_data.len)));
        try response_frame.appendSlice(arena_allocator, &len_bytes);

        // Message data
        try response_frame.appendSlice(arena_allocator, response_data);

        // Send gRPC response
        try conn.writeAll(response_frame.items);
    }
};

/// Simple Protocol Buffers encoder/decoder
pub const Protobuf = struct {
    /// Wire types
    pub const WireType = enum(u3) {
        varint = 0,
        fixed64 = 1,
        length_delimited = 2,
        start_group = 3, // Deprecated
        end_group = 4, // Deprecated
        fixed32 = 5,
    };

    /// Encode a varint
    pub fn encodeVarint(value: u64, writer: anytype) !void {
        var val = value;
        while (val >= 0x80) {
            try writer.writeByte(@as(u8, @intCast((val & 0x7F) | 0x80)));
            val >>= 7;
        }
        try writer.writeByte(@intCast(val & 0x7F));
    }

    /// Decode a varint
    pub fn decodeVarint(data: []const u8, offset: *usize) !u64 {
        var result: u64 = 0;
        // Track the shift in a wide type: a u6 (the shift width for a u64) tops
        // out at 63, so `shift += 7` past the 9th continuation byte would
        // overflow and panic before the `shift >= 64` guard could reject the
        // oversized varint. Keeping the counter in a u32 lets the guard fire.
        var shift: u32 = 0;

        while (offset.* < data.len) {
            const byte = data[offset.*];
            offset.* += 1;

            result |= @as(u64, byte & 0x7F) << @intCast(shift);

            if ((byte & 0x80) == 0) {
                return result;
            }

            shift += 7;
            if (shift >= 64) return error.VarintTooLarge;
        }

        return error.UnexpectedEof;
    }

    /// Encode a string field
    pub fn encodeString(field_number: u32, value: []const u8, writer: anytype) !void {
        // Tag = (field_number << 3) | wire_type
        const tag = (field_number << 3) | @intFromEnum(WireType.length_delimited);
        try encodeVarint(tag, writer);
        try encodeVarint(value.len, writer);
        try writer.writeAll(value);
    }

    /// Encode an int32 field
    pub fn encodeInt32(field_number: u32, value: i32, writer: anytype) !void {
        const tag = (field_number << 3) | @intFromEnum(WireType.varint);
        try encodeVarint(tag, writer);
        try encodeVarint(@bitCast(@as(i64, value)), writer);
    }

    /// Simple message builder
    pub fn buildMessage(allocator: std.mem.Allocator, fields: anytype) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);

        const writer = ArrayListWriter{ .list = &buf, .allocator = allocator };

        // Get field information from the struct. The pinned std exposes struct
        // reflection as parallel `field_names`/`field_types` arrays rather than
        // a single `fields` array of `{ name, type }`.
        const struct_info = @typeInfo(@TypeOf(fields)).@"struct";
        inline for (struct_info.field_names, struct_info.field_types, 1..) |field_name, field_type_t, field_num| {
            const field_value = @field(fields, field_name);
            const field_type = @typeInfo(field_type_t);

            switch (field_type) {
                .pointer => |ptr| {
                    if (ptr.child == u8) {
                        // Slice string field ([]const u8)
                        try encodeString(@intCast(field_num), field_value, writer);
                    } else if (@typeInfo(ptr.child) == .array and
                        @typeInfo(ptr.child).array.child == u8)
                    {
                        // String literal: *const [N:0]u8 — coerce to a slice.
                        const slice: []const u8 = field_value;
                        try encodeString(@intCast(field_num), slice, writer);
                    }
                },
                .array => |arr| {
                    if (arr.child == u8) {
                        const slice: []const u8 = &field_value;
                        try encodeString(@intCast(field_num), slice, writer);
                    }
                },
                .int, .comptime_int => {
                    // Integer field
                    try encodeInt32(@intCast(field_num), @intCast(field_value), writer);
                },
                else => {},
            }
        }

        return try allocator.dupe(u8, buf.items);
    }
};

test "protobuf varint encoding" {
    const allocator = std.testing.allocator;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try Protobuf.encodeVarint(150, ArrayListWriter{ .list = &buf, .allocator = allocator });

    // 150 = 0b10010110 = 0x96
    // Varint: 10010110 00000001 = 0x96 0x01
    try std.testing.expectEqual(@as(u8, 0x96), buf.items[0]);
    try std.testing.expectEqual(@as(u8, 0x01), buf.items[1]);
}

test "protobuf message building" {
    const allocator = std.testing.allocator;

    const message = try Protobuf.buildMessage(allocator, .{
        .name = "test",
        .value = 42,
    });
    defer allocator.free(message);

    // Should have encoded field 1 (string "test") and field 2 (int 42)
    try std.testing.expect(message.len > 0);
}

test "protobuf decodeVarint rejects truncated input" {
    // A byte with the continuation bit set but no following byte must not read
    // past the buffer.
    var offset: usize = 0;
    try std.testing.expectError(error.UnexpectedEof, Protobuf.decodeVarint(&[_]u8{0x80}, &offset));
}

test "protobuf decodeVarint rejects oversized varint" {
    // Ten continuation bytes exceed the 64-bit range. This must return
    // VarintTooLarge rather than overflowing the shift counter and panicking.
    var offset: usize = 0;
    const oversized = [_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80 };
    try std.testing.expectError(error.VarintTooLarge, Protobuf.decodeVarint(&oversized, &offset));
}
