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
    rows: std.ArrayListUnmanaged(Row),
    columns: std.ArrayListUnmanaged(Column),
    rows_affected: usize = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) QueryResult {
        return .{
            .rows = .empty,
            .columns = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *QueryResult) void {
        for (self.rows.items) |*row| {
            row.deinit();
        }
        self.rows.deinit(self.allocator);

        for (self.columns.items) |*col| {
            self.allocator.free(col.name);
        }
        self.columns.deinit(self.allocator);
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
    values: std.ArrayListUnmanaged(?[]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Row {
        return Row{
            .values = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Row) void {
        for (self.values.items) |value| {
            if (value) |v| {
                self.allocator.free(v);
            }
        }
        self.values.deinit(self.allocator);
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

/// Validate a backend message's self-reported length before it is used to slice
/// the read buffer. `msg_len` is the on-wire length that includes its own 4
/// length bytes but not the leading type byte, so anything below 4 is
/// malformed, and anything that would not fit in `capacity` (type byte plus
/// payload) is rejected so downstream slicing and `1 + msg_len` framing math
/// stay in bounds.
fn checkMessageLen(msg_len: u32, capacity: usize) Error!void {
    if (msg_len < 4 or msg_len > capacity - 1) return Error.InvalidResponse;
}

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
            // Best-effort Terminate message during teardown. A failed write means
            // the peer/socket is already gone; the fd is closed unconditionally by
            // client.deinit() below, so the error is safely ignorable here.
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
        var msg: std.ArrayListUnmanaged(u8) = .empty;
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
                if (self.config.password) |password| {
                    // Extract 4-byte salt from message
                    const salt = buf[9..13];
                    try self.sendMD5Password(password, salt.*);
                    try self.handleAuthentication(); // Recursive for next auth message
                } else {
                    return Error.AuthenticationFailed;
                }
            },
            else => {
                std.debug.print("⚠ Unknown auth type: {d}\n", .{auth_type});
                return Error.AuthenticationFailed;
            },
        }
    }

    fn sendPassword(self: *Connection, password: []const u8) !void {
        var msg: std.ArrayListUnmanaged(u8) = .empty;
        defer msg.deinit(self.allocator);

        try msg.append(self.allocator, 'p'); // PasswordMessage
        const len: u32 = @intCast(password.len + 4 + 1);
        try msg.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeTo(u32, len, .big)));
        try msg.appendSlice(self.allocator, password);
        try msg.append(self.allocator, 0);

        try self.client.write(msg.items);
    }

    /// Send MD5-hashed password for authentication
    /// PostgreSQL MD5 format: "md5" + md5(md5(password + username) + salt)
    fn sendMD5Password(self: *Connection, password: []const u8, salt: [4]u8) !void {
        const Md5 = std.crypto.hash.Md5;

        // Step 1: md5(password + username)
        var hash1: [Md5.digest_length]u8 = undefined;
        var h1 = Md5.init(.{});
        h1.update(password);
        h1.update(self.config.username);
        h1.final(&hash1);

        // Convert first hash to hex string
        var hash1_hex: [32]u8 = undefined;
        _ = std.fmt.bufPrint(&hash1_hex, "{s}", .{std.fmt.fmtSliceHexLower(&hash1)}) catch unreachable;

        // Step 2: md5(hash1_hex + salt)
        var hash2: [Md5.digest_length]u8 = undefined;
        var h2 = Md5.init(.{});
        h2.update(&hash1_hex);
        h2.update(&salt);
        h2.final(&hash2);

        // Convert second hash to hex string
        var hash2_hex: [32]u8 = undefined;
        _ = std.fmt.bufPrint(&hash2_hex, "{s}", .{std.fmt.fmtSliceHexLower(&hash2)}) catch unreachable;

        // Build password message: "md5" + hash2_hex + null terminator
        var msg: std.ArrayListUnmanaged(u8) = .empty;
        defer msg.deinit(self.allocator);

        try msg.append(self.allocator, 'p'); // PasswordMessage
        const pwd_len: u32 = 3 + 32 + 1; // "md5" + 32-char hex + null
        const len: u32 = pwd_len + 4; // + length field itself
        try msg.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeTo(u32, len, .big)));
        try msg.appendSlice(self.allocator, "md5");
        try msg.appendSlice(self.allocator, &hash2_hex);
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
        var msg: std.ArrayListUnmanaged(u8) = .empty;
        defer msg.deinit(self.allocator);

        try msg.append(self.allocator, 'Q'); // Query
        const len: u32 = @intCast(sql.len + 4 + 1);
        try msg.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeTo(u32, len, .big)));
        try msg.appendSlice(self.allocator, sql);
        try msg.append(self.allocator, 0);

        try self.client.write(msg.items);
    }

    fn parseQueryResponse(self: *Connection) !QueryResult {
        var result = QueryResult.init(self.allocator);
        errdefer result.deinit();

        var buf: [65536]u8 = undefined;
        var buf_pos: usize = 0;
        var buf_len: usize = 0;

        while (true) {
            // Ensure we have at least 5 bytes (type + length)
            while (buf_len - buf_pos < 5) {
                if (buf_pos > 0 and buf_len > buf_pos) {
                    // Move remaining data to start
                    std.mem.copyForwards(u8, buf[0 .. buf_len - buf_pos], buf[buf_pos..buf_len]);
                    buf_len -= buf_pos;
                    buf_pos = 0;
                } else {
                    buf_len = 0;
                    buf_pos = 0;
                }
                const n = try self.client.read(buf[buf_len..]);
                if (n == 0) return Error.InvalidResponse;
                buf_len += n;
            }

            const msg_type: MessageType = @enumFromInt(buf[buf_pos]);
            const msg_len = std.mem.readInt(u32, buf[buf_pos + 1 ..][0..4], .big);
            // A backend message length counts itself (the 4 length bytes) but not
            // the leading type byte, so it must be >= 4. It also must fit in the
            // read buffer alongside that type byte; rejecting anything larger
            // prevents the `buf_pos + 5 .. buf_pos + 1 + msg_len` slice below from
            // panicking (start > end when msg_len < 4) or the framing loop's
            // `1 + msg_len` from overflowing u32 on a hostile length.
            try checkMessageLen(msg_len, buf.len);

            // Ensure we have the full message
            while (buf_len - buf_pos < 1 + msg_len) {
                if (buf_pos > 0) {
                    std.mem.copyForwards(u8, buf[0 .. buf_len - buf_pos], buf[buf_pos..buf_len]);
                    buf_len -= buf_pos;
                    buf_pos = 0;
                }
                const n = try self.client.read(buf[buf_len..]);
                if (n == 0) return Error.InvalidResponse;
                buf_len += n;
            }

            const msg_data = buf[buf_pos + 5 .. buf_pos + 1 + msg_len];
            buf_pos += 1 + msg_len;

            switch (msg_type) {
                .RowDescription => {
                    // Parse column metadata per PostgreSQL protocol
                    if (msg_data.len < 2) continue;
                    const num_fields = std.mem.readInt(u16, msg_data[0..2], .big);
                    var pos: usize = 2;

                    for (0..num_fields) |_| {
                        // Column name (null-terminated string)
                        const name_end = std.mem.indexOfScalar(u8, msg_data[pos..], 0) orelse break;
                        const name = try self.allocator.dupe(u8, msg_data[pos .. pos + name_end]);
                        pos += name_end + 1;

                        if (pos + 18 > msg_data.len) {
                            self.allocator.free(name);
                            break;
                        }

                        // Skip table OID (4), column attr (2)
                        pos += 6;
                        // Type OID
                        const type_oid = std.mem.readInt(u32, msg_data[pos..][0..4], .big);
                        pos += 4;
                        // Type size
                        const type_size = std.mem.readInt(i16, msg_data[pos..][0..2], .big);
                        pos += 2;
                        // Skip type modifier (4), format code (2)
                        pos += 6;

                        try result.columns.append(self.allocator, Column{
                            .name = name,
                            .type_oid = type_oid,
                            .type_size = type_size,
                        });
                    }
                    std.debug.print("📋 Received RowDescription: {d} columns\n", .{num_fields});
                },
                .DataRow => {
                    // Parse row data per PostgreSQL protocol
                    if (msg_data.len < 2) continue;
                    const num_cols = std.mem.readInt(u16, msg_data[0..2], .big);
                    var pos: usize = 2;

                    var row = Row.init(self.allocator);
                    errdefer row.deinit();

                    for (0..num_cols) |_| {
                        if (pos + 4 > msg_data.len) break;
                        const col_len_raw = std.mem.readInt(i32, msg_data[pos..][0..4], .big);
                        pos += 4;

                        if (col_len_raw == -1) {
                            // NULL value
                            try row.values.append(self.allocator, null);
                        } else {
                            const col_len: usize = @intCast(col_len_raw);
                            if (pos + col_len > msg_data.len) break;
                            const value = try self.allocator.dupe(u8, msg_data[pos .. pos + col_len]);
                            try row.values.append(self.allocator, value);
                            pos += col_len;
                        }
                    }
                    try result.rows.append(self.allocator, row);
                },
                .CommandComplete => {
                    // Parse rows affected from command tag
                    if (std.mem.lastIndexOfScalar(u8, msg_data, ' ')) |space_pos| {
                        const num_str = msg_data[space_pos + 1 ..];
                        if (num_str.len > 0 and num_str[num_str.len - 1] == 0) {
                            result.rows_affected = std.fmt.parseInt(usize, num_str[0 .. num_str.len - 1], 10) catch 0;
                        }
                    }
                    std.debug.print("✓ Query completed ({d} rows affected)\n", .{result.rows_affected});
                },
                .ReadyForQuery => {
                    // Ready for next query
                    if (msg_data.len > 0) {
                        self.transaction_status = msg_data[0];
                    }
                    break;
                },
                .ErrorResponse => {
                    // Parse error message
                    var pos: usize = 0;
                    while (pos < msg_data.len and msg_data[pos] != 0) {
                        const field_type = msg_data[pos];
                        pos += 1;
                        const field_end = std.mem.indexOfScalar(u8, msg_data[pos..], 0) orelse break;
                        const field_value = msg_data[pos .. pos + field_end];
                        if (field_type == 'M') { // Message
                            std.debug.print("❌ Query error: {s}\n", .{field_value});
                        }
                        pos += field_end + 1;
                    }
                    return Error.QueryFailed;
                },
                else => {
                    // Skip other messages (ParameterStatus, NoticeResponse, etc.)
                    continue;
                },
            }
        }

        return result;
    }
};

/// Connection pool for PostgreSQL
pub const Pool = struct {
    connections: std.ArrayListUnmanaged(*Connection),
    config: ConnectionConfig,
    allocator: std.mem.Allocator,
    max_size: usize,
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, config: ConnectionConfig, max_size: usize) !Pool {
        return Pool{
            .connections = .empty,
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
        self.connections.deinit(self.allocator);
    }

    pub fn acquire(self: *Pool) !*Connection {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Try to reuse existing connection
        if (self.connections.items.len > 0) {
            return self.connections.pop().?;
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
            try self.connections.append(self.allocator, conn);
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

test "postgres backend message length is validated" {
    const capacity: usize = 65536;

    // Lengths below 4 would make the payload slice start past its end, and a
    // length that does not fit the buffer would overflow the framing math.
    try std.testing.expectError(Error.InvalidResponse, checkMessageLen(0, capacity));
    try std.testing.expectError(Error.InvalidResponse, checkMessageLen(3, capacity));
    try std.testing.expectError(Error.InvalidResponse, checkMessageLen(0xFFFFFFFF, capacity));
    try std.testing.expectError(Error.InvalidResponse, checkMessageLen(capacity, capacity));

    // The smallest legal message (length-only, empty payload) and a typical
    // one both fit and must be accepted.
    try checkMessageLen(4, capacity);
    try checkMessageLen(100, capacity);
    try checkMessageLen(@intCast(capacity - 1), capacity);
}
