const std = @import("std");
const net = @import("../net/tcp.zig");

/// Redis client implementation using RESP (REdis Serialization Protocol)
/// Supports Redis 6.0+ protocol

pub const Error = error{
    ConnectionFailed,
    AuthenticationFailed,
    CommandFailed,
    InvalidResponse,
    Timeout,
    NullValue,
};

pub const ConnectionConfig = struct {
    host: []const u8 = "localhost",
    port: u16 = 6379,
    password: ?[]const u8 = null,
    database: u8 = 0,
    connect_timeout_ms: u32 = 5000,
};

/// RESP value types
pub const Value = union(enum) {
    simple_string: []const u8,
    error_msg: []const u8,
    integer: i64,
    bulk_string: ?[]const u8,
    array: []Value,
    null_value: void,

    pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .simple_string => |s| allocator.free(s),
            .error_msg => |s| allocator.free(s),
            .bulk_string => |s| if (s) |str| allocator.free(str),
            .array => |arr| {
                for (arr) |*val| {
                    val.deinit(allocator);
                }
                allocator.free(arr);
            },
            else => {},
        }
    }

    pub fn toString(self: Value) ?[]const u8 {
        return switch (self) {
            .simple_string => |s| s,
            .bulk_string => |s| s,
            else => null,
        };
    }

    pub fn toInt(self: Value) ?i64 {
        return switch (self) {
            .integer => |i| i,
            else => null,
        };
    }
};

pub const Client = struct {
    tcp_client: net.TcpClient,
    config: ConnectionConfig,
    allocator: std.mem.Allocator,
    connected: bool = false,

    pub fn init(allocator: std.mem.Allocator, config: ConnectionConfig) !Client {
        return Client{
            .tcp_client = try net.TcpClient.init(allocator),
            .config = config,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Client) void {
        if (self.connected) {
            self.disconnect() catch {};
        }
        self.tcp_client.deinit();
    }

    /// Connect to Redis server
    pub fn connect(self: *Client) !void {
        std.debug.print("🔴 Connecting to Redis at {s}:{d}\n", .{
            self.config.host,
            self.config.port,
        });

        try self.tcp_client.connect(self.config.host, self.config.port);

        // Authenticate if password is provided
        if (self.config.password) |password| {
            var result = try self.command(&[_][]const u8{ "AUTH", password });
            defer result.deinit(self.allocator);

            switch (result) {
                .simple_string => |s| {
                    if (!std.mem.eql(u8, s, "OK")) {
                        return Error.AuthenticationFailed;
                    }
                },
                .error_msg => return Error.AuthenticationFailed,
                else => return Error.InvalidResponse,
            }

            std.debug.print("✓ Authenticated\n", .{});
        }

        // Select database
        if (self.config.database != 0) {
            const db_str = try std.fmt.allocPrint(self.allocator, "{d}", .{self.config.database});
            defer self.allocator.free(db_str);

            var result = try self.command(&[_][]const u8{ "SELECT", db_str });
            defer result.deinit(self.allocator);
        }

        self.connected = true;
        std.debug.print("✓ Connected to Redis\n", .{});
    }

    /// Disconnect from Redis
    pub fn disconnect(self: *Client) !void {
        if (!self.connected) return;

        var result = try self.command(&[_][]const u8{"QUIT"});
        defer result.deinit(self.allocator);

        self.tcp_client.disconnect();
        self.connected = false;
        std.debug.print("✓ Disconnected from Redis\n", .{});
    }

    /// Execute a Redis command
    pub fn command(self: *Client, args: []const []const u8) !Value {
        if (!self.connected) return Error.ConnectionFailed;

        // Build RESP array command
        var cmd: std.ArrayList(u8) = .{};
        defer cmd.deinit(self.allocator);

        // Array header
        try cmd.writer(self.allocator).print("*{d}\r\n", .{args.len});

        // Arguments
        for (args) |arg| {
            try cmd.writer(self.allocator).print("${d}\r\n{s}\r\n", .{ arg.len, arg });
        }

        // Send command
        try self.tcp_client.write(cmd.items);

        // Read response
        return try self.readValue();
    }

    // String commands

    pub fn get(self: *Client, key: []const u8) !?[]const u8 {
        var result = try self.command(&[_][]const u8{ "GET", key });
        defer result.deinit(self.allocator);

        return switch (result) {
            .bulk_string => |s| if (s) |str| try self.allocator.dupe(u8, str) else null,
            .null_value => null,
            else => Error.InvalidResponse,
        };
    }

    pub fn set(self: *Client, key: []const u8, value: []const u8) !void {
        var result = try self.command(&[_][]const u8{ "SET", key, value });
        defer result.deinit(self.allocator);

        switch (result) {
            .simple_string => |s| {
                if (!std.mem.eql(u8, s, "OK")) return Error.CommandFailed;
            },
            else => return Error.InvalidResponse,
        }
    }

    pub fn setEx(self: *Client, key: []const u8, value: []const u8, seconds: u32) !void {
        const ttl = try std.fmt.allocPrint(self.allocator, "{d}", .{seconds});
        defer self.allocator.free(ttl);

        var result = try self.command(&[_][]const u8{ "SETEX", key, ttl, value });
        defer result.deinit(self.allocator);
    }

    pub fn del(self: *Client, keys: []const []const u8) !usize {
        var args = try self.allocator.alloc([]const u8, keys.len + 1);
        defer self.allocator.free(args);

        args[0] = "DEL";
        for (keys, 0..) |key, i| {
            args[i + 1] = key;
        }

        var result = try self.command(args);
        defer result.deinit(self.allocator);

        return switch (result) {
            .integer => |i| @intCast(i),
            else => Error.InvalidResponse,
        };
    }

    pub fn exists(self: *Client, key: []const u8) !bool {
        var result = try self.command(&[_][]const u8{ "EXISTS", key });
        defer result.deinit(self.allocator);

        return switch (result) {
            .integer => |i| i > 0,
            else => Error.InvalidResponse,
        };
    }

    // Hash commands

    pub fn hset(self: *Client, key: []const u8, field: []const u8, value: []const u8) !void {
        var result = try self.command(&[_][]const u8{ "HSET", key, field, value });
        defer result.deinit(self.allocator);
    }

    pub fn hget(self: *Client, key: []const u8, field: []const u8) !?[]const u8 {
        var result = try self.command(&[_][]const u8{ "HGET", key, field });
        defer result.deinit(self.allocator);

        return switch (result) {
            .bulk_string => |s| if (s) |str| try self.allocator.dupe(u8, str) else null,
            .null_value => null,
            else => Error.InvalidResponse,
        };
    }

    pub fn hgetall(self: *Client, key: []const u8) !std.StringHashMap([]const u8) {
        var result = try self.command(&[_][]const u8{ "HGETALL", key });
        defer result.deinit(self.allocator);

        var map = std.StringHashMap([]const u8).init(self.allocator);
        errdefer map.deinit();

        switch (result) {
            .array => |arr| {
                var i: usize = 0;
                while (i < arr.len) : (i += 2) {
                    const field = arr[i].toString() orelse continue;
                    const value = if (i + 1 < arr.len) arr[i + 1].toString() else null;

                    if (value) |v| {
                        const field_copy = try self.allocator.dupe(u8, field);
                        const value_copy = try self.allocator.dupe(u8, v);
                        try map.put(field_copy, value_copy);
                    }
                }
            },
            else => return Error.InvalidResponse,
        }

        return map;
    }

    // List commands

    pub fn lpush(self: *Client, key: []const u8, values: []const []const u8) !usize {
        var args = try self.allocator.alloc([]const u8, values.len + 2);
        defer self.allocator.free(args);

        args[0] = "LPUSH";
        args[1] = key;
        for (values, 0..) |val, i| {
            args[i + 2] = val;
        }

        var result = try self.command(args);
        defer result.deinit(self.allocator);

        return switch (result) {
            .integer => |i| @intCast(i),
            else => Error.InvalidResponse,
        };
    }

    pub fn rpush(self: *Client, key: []const u8, values: []const []const u8) !usize {
        var args = try self.allocator.alloc([]const u8, values.len + 2);
        defer self.allocator.free(args);

        args[0] = "RPUSH";
        args[1] = key;
        for (values, 0..) |val, i| {
            args[i + 2] = val;
        }

        var result = try self.command(args);
        defer result.deinit(self.allocator);

        return switch (result) {
            .integer => |i| @intCast(i),
            else => Error.InvalidResponse,
        };
    }

    pub fn lrange(self: *Client, key: []const u8, start: i64, stop: i64) ![][]const u8 {
        const start_str = try std.fmt.allocPrint(self.allocator, "{d}", .{start});
        defer self.allocator.free(start_str);
        const stop_str = try std.fmt.allocPrint(self.allocator, "{d}", .{stop});
        defer self.allocator.free(stop_str);

        var result = try self.command(&[_][]const u8{ "LRANGE", key, start_str, stop_str });
        defer result.deinit(self.allocator);

        switch (result) {
            .array => |arr| {
                var list = try self.allocator.alloc([]const u8, arr.len);
                for (arr, 0..) |val, i| {
                    if (val.toString()) |s| {
                        list[i] = try self.allocator.dupe(u8, s);
                    }
                }
                return list;
            },
            else => return Error.InvalidResponse,
        }
    }

    // Set commands

    pub fn sadd(self: *Client, key: []const u8, members: []const []const u8) !usize {
        var args = try self.allocator.alloc([]const u8, members.len + 2);
        defer self.allocator.free(args);

        args[0] = "SADD";
        args[1] = key;
        for (members, 0..) |member, i| {
            args[i + 2] = member;
        }

        var result = try self.command(args);
        defer result.deinit(self.allocator);

        return switch (result) {
            .integer => |i| @intCast(i),
            else => Error.InvalidResponse,
        };
    }

    pub fn smembers(self: *Client, key: []const u8) ![][]const u8 {
        var result = try self.command(&[_][]const u8{ "SMEMBERS", key });
        defer result.deinit(self.allocator);

        switch (result) {
            .array => |arr| {
                var list = try self.allocator.alloc([]const u8, arr.len);
                for (arr, 0..) |val, i| {
                    if (val.toString()) |s| {
                        list[i] = try self.allocator.dupe(u8, s);
                    }
                }
                return list;
            },
            else => return Error.InvalidResponse,
        }
    }

    // Sorted set commands

    pub fn zadd(self: *Client, key: []const u8, score: f64, member: []const u8) !void {
        const score_str = try std.fmt.allocPrint(self.allocator, "{d}", .{score});
        defer self.allocator.free(score_str);

        var result = try self.command(&[_][]const u8{ "ZADD", key, score_str, member });
        defer result.deinit(self.allocator);
    }

    // Pub/Sub commands

    pub fn publish(self: *Client, channel: []const u8, message: []const u8) !usize {
        var result = try self.command(&[_][]const u8{ "PUBLISH", channel, message });
        defer result.deinit(self.allocator);

        return switch (result) {
            .integer => |i| @intCast(i),
            else => Error.InvalidResponse,
        };
    }

    // Utility commands

    pub fn ping(self: *Client) !bool {
        var result = try self.command(&[_][]const u8{"PING"});
        defer result.deinit(self.allocator);

        return switch (result) {
            .simple_string => |s| std.mem.eql(u8, s, "PONG"),
            else => false,
        };
    }

    pub fn flushDb(self: *Client) !void {
        var result = try self.command(&[_][]const u8{"FLUSHDB"});
        defer result.deinit(self.allocator);
    }

    // Internal RESP parser

    fn readValue(self: *Client) !Value {
        var buf: [8192]u8 = undefined;
        const n = try self.tcp_client.read(&buf);

        if (n == 0) return Error.InvalidResponse;

        const type_byte = buf[0];
        const data = buf[1..n];

        return switch (type_byte) {
            '+' => try self.parseSimpleString(data),
            '-' => try self.parseError(data),
            ':' => try self.parseInt(data),
            '$' => try self.parseBulkString(data),
            '*' => try self.parseArray(data),
            else => Error.InvalidResponse,
        };
    }

    fn parseSimpleString(self: *Client, data: []const u8) !Value {
        const end = std.mem.indexOf(u8, data, "\r\n") orelse return Error.InvalidResponse;
        const str = try self.allocator.dupe(u8, data[0..end]);
        return Value{ .simple_string = str };
    }

    fn parseError(self: *Client, data: []const u8) !Value {
        const end = std.mem.indexOf(u8, data, "\r\n") orelse return Error.InvalidResponse;
        const str = try self.allocator.dupe(u8, data[0..end]);
        return Value{ .error_msg = str };
    }

    fn parseInt(self: *Client, data: []const u8) !Value {
        _ = self;
        const end = std.mem.indexOf(u8, data, "\r\n") orelse return Error.InvalidResponse;
        const int = try std.fmt.parseInt(i64, data[0..end], 10);
        return Value{ .integer = int };
    }

    fn parseBulkString(self: *Client, data: []const u8) !Value {
        const end = std.mem.indexOf(u8, data, "\r\n") orelse return Error.InvalidResponse;
        const len = try std.fmt.parseInt(i64, data[0..end], 10);

        if (len == -1) {
            return Value{ .null_value = {} };
        }

        const start = end + 2;
        const str_end = start + @as(usize, @intCast(len));

        if (str_end > data.len) return Error.InvalidResponse;

        const str = try self.allocator.dupe(u8, data[start..str_end]);
        return Value{ .bulk_string = str };
    }

    fn parseArray(self: *Client, data: []const u8) !Value {
        const end = std.mem.indexOf(u8, data, "\r\n") orelse return Error.InvalidResponse;
        const count = try std.fmt.parseInt(i64, data[0..end], 10);

        if (count == -1) {
            return Value{ .null_value = {} };
        }

        // Simplified - would need to recursively parse array elements
        const arr = try self.allocator.alloc(Value, @intCast(count));
        return Value{ .array = arr };
    }
};

test "redis client init" {
    const allocator = std.testing.allocator;

    const config = ConnectionConfig{
        .host = "localhost",
        .port = 6379,
    };

    var client = try Client.init(allocator, config);
    defer client.deinit();

    try std.testing.expect(!client.connected);
}
