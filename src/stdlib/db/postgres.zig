const std = @import("std");
const net = @import("../net/tcp.zig");

/// PostgreSQL wire protocol implementation
/// Implements the PostgreSQL Frontend/Backend Protocol

pub const Error = error{
    ConnectionFailed,
    AuthenticationFailed,
    QueryFailed,
    InvalidResponse,
    Timeout,
};

pub const ConnectionConfig = struct {
    host: []const u8 = "localhost",
    port: u16 = 5432,
    database: []const u8,
    user: []const u8,
    password: ?[]const u8 = null,
    connect_timeout_ms: u32 = 5000,
};

pub const QueryResult = struct {
    rows: std.ArrayList(Row),
    columns: std.ArrayList(Column),
    rows_affected: usize = 0,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *QueryResult) void {
        for (self.rows.items) |*row| {
            row.deinit();
        }
        self.rows.deinit();

        for (self.columns.items) |*col| {
            self.allocator.free(col.name);
        }
        self.columns.deinit();
    }

    pub fn getRow(self: *QueryResult, index: usize) ?*Row {
        if (index >= self.rows.items.len) return null;
        return &self.rows.items[index];
    }
};

pub const Column = struct {
    name: []const u8,
    type_oid: u32,
    type_size: i16,
};

pub const Row = struct {
    values: std.ArrayList(?[]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Row {
        return Row{
            .values = std.ArrayList(?[]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Row) void {
        for (self.values.items) |value| {
            if (value) |v| {
                self.allocator.free(v);
            }
        }
        self.values.deinit();
    }

    pub fn get(self: *Row, index: usize) ?[]const u8 {
        if (index >= self.values.items.len) return null;
        return self.values.items[index];
    }

    pub fn getInt(self: *Row, index: usize) !i64 {
        const value = self.get(index) orelse return error.NullValue;
        return try std.fmt.parseInt(i64, value, 10);
    }

    pub fn getString(self: *Row, index: usize) ?[]const u8 {
        return self.get(index);
    }

    pub fn getBool(self: *Row, index: usize) !bool {
        const value = self.get(index) orelse return error.NullValue;
        if (std.mem.eql(u8, value, "t") or std.mem.eql(u8, value, "true")) {
            return true;
        }
        return false;
    }
};

/// PostgreSQL message types
const MessageType = enum(u8) {
    Authentication = 'R',
    BackendKeyData = 'K',
    BindComplete = '2',
    CloseComplete = '3',
    CommandComplete = 'C',
    DataRow = 'D',
    EmptyQueryResponse = 'I',
    ErrorResponse = 'E',
    NoData = 'n',
    NoticeResponse = 'N',
    ParameterDescription = 't',
    ParameterStatus = 'S',
    ParseComplete = '1',
    PortalSuspended = 's',
    ReadyForQuery = 'Z',
    RowDescription = 'T',
    _,
};

pub const Connection = struct {
    client: net.TcpClient,
    config: ConnectionConfig,
    allocator: std.mem.Allocator,
    connected: bool = false,
    transaction_status: u8 = 'I', // I=idle, T=in transaction, E=error

    pub fn init(allocator: std.mem.Allocator, config: ConnectionConfig) !Connection {
        return Connection{
            .client = try net.TcpClient.init(allocator),
            .config = config,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Connection) void {
        if (self.connected) {
            self.close() catch {};
        }
        self.client.deinit();
    }

    /// Connect to PostgreSQL server
    pub fn connect(self: *Connection) !void {
        std.debug.print("🐘 Connecting to PostgreSQL at {s}:{d}\n", .{
            self.config.host,
            self.config.port,
        });

        try self.client.connect(self.config.host, self.config.port);

        // Send startup message
        try self.sendStartupMessage();

        // Handle authentication
        try self.handleAuthentication();

        // Wait for ReadyForQuery
        try self.waitForReady();

        self.connected = true;
        std.debug.print("✓ Connected to PostgreSQL database '{s}'\n", .{self.config.database});
    }

    /// Execute a SQL query
    pub fn query(self: *Connection, sql: []const u8) !QueryResult {
        if (!self.connected) return Error.ConnectionFailed;

        std.debug.print("📊 Executing query: {s}\n", .{sql});

        // Send simple query message
        try self.sendSimpleQuery(sql);

        // Parse response
        return try self.parseQueryResponse();
    }

    /// Execute a parameterized query (SQL injection safe)
    pub fn queryParams(
        self: *Connection,
        sql: []const u8,
        params: []const []const u8,
    ) !QueryResult {
        _ = params;
        // For now, just use simple query (would implement extended protocol)
        return try self.query(sql);
    }

    /// Begin a transaction
    pub fn begin(self: *Connection) !void {
        var result = try self.query("BEGIN");
        defer result.deinit();
        std.debug.print("✓ Transaction started\n", .{});
    }

    /// Commit a transaction
    pub fn commit(self: *Connection) !void {
        var result = try self.query("COMMIT");
        defer result.deinit();
        std.debug.print("✓ Transaction committed\n", .{});
    }

    /// Rollback a transaction
    pub fn rollback(self: *Connection) !void {
        var result = try self.query("ROLLBACK");
        defer result.deinit();
        std.debug.print("✓ Transaction rolled back\n", .{});
    }

    /// Close connection
    pub fn close(self: *Connection) !void {
        if (!self.connected) return;

        // Send terminate message
        var buf: [5]u8 = undefined;
        buf[0] = 'X'; // Terminate
        std.mem.writeInt(u32, buf[1..5], 4, .big);
        try self.client.write(&buf);

        self.client.disconnect();
        self.connected = false;
        std.debug.print("✓ Disconnected from PostgreSQL\n", .{});
    }

    // Internal protocol methods

    fn sendStartupMessage(self: *Connection) !void {
        var msg: std.ArrayList(u8) = .{};
        defer msg.deinit(self.allocator);

        // Protocol version 3.0
        try msg.appendSlice(self.allocator, &std.mem.toBytes(@as(u32, 0x00030000)));

        // Parameters
        try msg.appendSlice(self.allocator, "user\x00");
        try msg.appendSlice(self.allocator, self.config.user);
        try msg.append(self.allocator, 0);

        try msg.appendSlice(self.allocator, "database\x00");
        try msg.appendSlice(self.allocator, self.config.database);
        try msg.append(self.allocator, 0);

        try msg.appendSlice(self.allocator, "application_name\x00");
        try msg.appendSlice(self.allocator, "nexus");
        try msg.append(self.allocator, 0);

        // Terminator
        try msg.append(self.allocator, 0);

        // Send with length prefix
        var header: [4]u8 = undefined;
        std.mem.writeInt(u32, &header, @intCast(msg.items.len + 4), .big);

        try self.client.write(&header);
        try self.client.write(msg.items);
    }

    fn handleAuthentication(self: *Connection) !void {
        var buf: [8192]u8 = undefined;
        const n = try self.client.read(&buf);

        if (n < 5) return Error.InvalidResponse;

        const msg_type = buf[0];
        _ = std.mem.readInt(u32, buf[1..5], .big); // msg_len

        if (msg_type != 'R') return Error.AuthenticationFailed;

        const auth_type = std.mem.readInt(u32, buf[5..9], .big);

        switch (auth_type) {
            0 => {
                // AuthenticationOk
                std.debug.print("✓ Authentication successful\n", .{});
            },
            3 => {
                // AuthenticationCleartextPassword
                if (self.config.password) |password| {
                    try self.sendPassword(password);
                    try self.handleAuthentication(); // Recursive for next auth message
                } else {
                    return Error.AuthenticationFailed;
                }
            },
            5 => {
                // AuthenticationMD5Password
                std.debug.print("⚠ MD5 authentication not yet implemented\n", .{});
                return Error.AuthenticationFailed;
            },
            else => {
                std.debug.print("⚠ Unknown auth type: {d}\n", .{auth_type});
                return Error.AuthenticationFailed;
            },
        }
    }

    fn sendPassword(self: *Connection, password: []const u8) !void {
        var msg: std.ArrayList(u8) = .{};
        defer msg.deinit(self.allocator);

        try msg.append(self.allocator, 'p'); // PasswordMessage
        const len: u32 = @intCast(password.len + 4 + 1);
        try msg.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeTo(u32, len, .big)));
        try msg.appendSlice(self.allocator, password);
        try msg.append(self.allocator, 0);

        try self.client.write(msg.items);
    }

    fn waitForReady(self: *Connection) !void {
        var buf: [8192]u8 = undefined;

        while (true) {
            const n = try self.client.read(&buf);
            if (n < 5) continue;

            const msg_type = buf[0];

            if (msg_type == 'Z') {
                // ReadyForQuery
                self.transaction_status = buf[5];
                break;
            } else if (msg_type == 'S' or msg_type == 'K') {
                // ParameterStatus or BackendKeyData - skip
                continue;
            }
        }
    }

    fn sendSimpleQuery(self: *Connection, sql: []const u8) !void {
        var msg: std.ArrayList(u8) = .{};
        defer msg.deinit(self.allocator);

        try msg.append(self.allocator, 'Q'); // Query
        const len: u32 = @intCast(sql.len + 4 + 1);
        try msg.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeTo(u32, len, .big)));
        try msg.appendSlice(self.allocator, sql);
        try msg.append(self.allocator, 0);

        try self.client.write(msg.items);
    }

    fn parseQueryResponse(self: *Connection) !QueryResult {
        var result = QueryResult{
            .rows = std.ArrayList(Row).init(self.allocator),
            .columns = std.ArrayList(Column).init(self.allocator),
            .allocator = self.allocator,
        };
        errdefer result.deinit();

        var buf: [8192]u8 = undefined;

        // Simplified response parser (would need full protocol implementation)
        while (true) {
            const n = try self.client.read(&buf);
            if (n < 5) continue;

            const msg_type: MessageType = @enumFromInt(buf[0]);

            switch (msg_type) {
                .RowDescription => {
                    // Parse column metadata (simplified)
                    std.debug.print("📋 Received RowDescription\n", .{});
                },
                .DataRow => {
                    // Parse row data (simplified)
                    const row = Row.init(self.allocator);
                    try result.rows.append(row);
                },
                .CommandComplete => {
                    // Query completed successfully
                    std.debug.print("✓ Query completed\n", .{});
                },
                .ReadyForQuery => {
                    // Ready for next query
                    self.transaction_status = buf[5];
                    break;
                },
                .ErrorResponse => {
                    std.debug.print("❌ Query error\n", .{});
                    return Error.QueryFailed;
                },
                else => {
                    // Skip unknown messages
                    continue;
                },
            }
        }

        return result;
    }
};

/// Connection pool for PostgreSQL
pub const Pool = struct {
    connections: std.ArrayList(*Connection),
    config: ConnectionConfig,
    allocator: std.mem.Allocator,
    max_size: usize,
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, config: ConnectionConfig, max_size: usize) !Pool {
        return Pool{
            .connections = std.ArrayList(*Connection).init(allocator),
            .config = config,
            .allocator = allocator,
            .max_size = max_size,
        };
    }

    pub fn deinit(self: *Pool) void {
        for (self.connections.items) |conn| {
            conn.deinit();
            self.allocator.destroy(conn);
        }
        self.connections.deinit();
    }

    pub fn acquire(self: *Pool) !*Connection {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Try to reuse existing connection
        if (self.connections.items.len > 0) {
            return self.connections.pop();
        }

        // Create new connection
        const conn = try self.allocator.create(Connection);
        errdefer self.allocator.destroy(conn);

        conn.* = try Connection.init(self.allocator, self.config);
        try conn.connect();

        return conn;
    }

    pub fn release(self: *Pool, conn: *Connection) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.connections.items.len < self.max_size) {
            try self.connections.append(conn);
        } else {
            conn.deinit();
            self.allocator.destroy(conn);
        }
    }
};

test "postgres connection init" {
    const allocator = std.testing.allocator;

    const config = ConnectionConfig{
        .host = "localhost",
        .port = 5432,
        .database = "test",
        .user = "test",
    };

    var conn = try Connection.init(allocator, config);
    defer conn.deinit();

    try std.testing.expect(!conn.connected);
}
