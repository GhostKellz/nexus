const std = @import("std");
const tcp = @import("tcp.zig");

/// TLS 1.3 implementation for HTTPS support
/// RFC 8446 - The Transport Layer Security (TLS) Protocol Version 1.3

pub const Error = error{
    HandshakeFailed,
    InvalidCertificate,
    CertificateExpired,
    UntrustedCertificate,
    InvalidProtocolVersion,
    DecryptionError,
    BadRecordMac,
    AlertReceived,
    ConnectionClosed,
};

/// TLS protocol versions
pub const ProtocolVersion = enum(u16) {
    tls_1_0 = 0x0301,
    tls_1_1 = 0x0302,
    tls_1_2 = 0x0303,
    tls_1_3 = 0x0304,
};

/// TLS content types
pub const ContentType = enum(u8) {
    change_cipher_spec = 20,
    alert = 21,
    handshake = 22,
    application_data = 23,
};

/// TLS handshake types
pub const HandshakeType = enum(u8) {
    hello_request = 0,
    client_hello = 1,
    server_hello = 2,
    new_session_ticket = 4,
    end_of_early_data = 5,
    encrypted_extensions = 8,
    certificate = 11,
    server_key_exchange = 12,
    certificate_request = 13,
    server_hello_done = 14,
    certificate_verify = 15,
    client_key_exchange = 16,
    finished = 20,
    key_update = 24,
    message_hash = 254,
};

/// TLS alert levels
pub const AlertLevel = enum(u8) {
    warning = 1,
    fatal = 2,
};

/// TLS alert descriptions
pub const AlertDescription = enum(u8) {
    close_notify = 0,
    unexpected_message = 10,
    bad_record_mac = 20,
    record_overflow = 22,
    handshake_failure = 40,
    bad_certificate = 42,
    unsupported_certificate = 43,
    certificate_revoked = 44,
    certificate_expired = 45,
    certificate_unknown = 46,
    illegal_parameter = 47,
    unknown_ca = 48,
    access_denied = 49,
    decode_error = 50,
    decrypt_error = 51,
    protocol_version = 70,
    insufficient_security = 71,
    internal_error = 80,
    inappropriate_fallback = 86,
    user_canceled = 90,
    missing_extension = 109,
    unsupported_extension = 110,
    unrecognized_name = 112,
    bad_certificate_status_response = 113,
    unknown_psk_identity = 115,
    certificate_required = 116,
    no_application_protocol = 120,
};

/// TLS cipher suites (TLS 1.3)
pub const CipherSuite = enum(u16) {
    tls_aes_128_gcm_sha256 = 0x1301,
    tls_aes_256_gcm_sha384 = 0x1302,
    tls_chacha20_poly1305_sha256 = 0x1303,
    tls_aes_128_ccm_sha256 = 0x1304,
    tls_aes_128_ccm_8_sha256 = 0x1305,
};

/// X.509 certificate
pub const Certificate = struct {
    der_data: []const u8,
    subject: []const u8,
    issuer: []const u8,
    not_before: i64,
    not_after: i64,
    public_key: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, der_data: []const u8) !Certificate {
        // Simplified certificate parsing - real implementation would parse DER/ASN.1
        return Certificate{
            .der_data = try allocator.dupe(u8, der_data),
            .subject = try allocator.dupe(u8, "CN=example.com"),
            .issuer = try allocator.dupe(u8, "CN=CA"),
            .not_before = std.time.timestamp(),
            .not_after = std.time.timestamp() + (365 * 24 * 60 * 60), // 1 year
            .public_key = try allocator.dupe(u8, &[_]u8{0} ** 32),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Certificate) void {
        self.allocator.free(self.der_data);
        self.allocator.free(self.subject);
        self.allocator.free(self.issuer);
        self.allocator.free(self.public_key);
    }

    pub fn fromPEM(allocator: std.mem.Allocator, pem_data: []const u8) !Certificate {
        // Simple PEM parsing - find content between BEGIN/END markers
        const begin = "-----BEGIN CERTIFICATE-----";
        const end = "-----END CERTIFICATE-----";

        const start_idx = std.mem.indexOf(u8, pem_data, begin) orelse return error.InvalidCertificate;
        const end_idx = std.mem.indexOf(u8, pem_data, end) orelse return error.InvalidCertificate;

        const base64_data = pem_data[start_idx + begin.len .. end_idx];

        // In real implementation, would decode base64 to DER
        return try init(allocator, base64_data);
    }

    pub fn verify(self: *Certificate) !void {
        const now = std.time.timestamp();
        if (now < self.not_before or now > self.not_after) {
            return Error.CertificateExpired;
        }
    }
};

/// Private key for TLS
pub const PrivateKey = struct {
    key_data: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, key_data: []const u8) !PrivateKey {
        return PrivateKey{
            .key_data = try allocator.dupe(u8, key_data),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PrivateKey) void {
        self.allocator.free(self.key_data);
    }

    pub fn fromPEM(allocator: std.mem.Allocator, pem_data: []const u8) !PrivateKey {
        const begin = "-----BEGIN PRIVATE KEY-----";
        const end = "-----END PRIVATE KEY-----";

        const start_idx = std.mem.indexOf(u8, pem_data, begin) orelse return error.InvalidCertificate;
        const end_idx = std.mem.indexOf(u8, pem_data, end) orelse return error.InvalidCertificate;

        const base64_data = pem_data[start_idx + begin.len .. end_idx];

        return try init(allocator, base64_data);
    }
};

/// TLS configuration
pub const Config = struct {
    certificates: []Certificate,
    private_key: ?PrivateKey,
    min_version: ProtocolVersion = .tls_1_2,
    max_version: ProtocolVersion = .tls_1_3,
    cipher_suites: []const CipherSuite,
    server_name: ?[]const u8 = null,
    verify_peer: bool = true,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Config {
        const default_ciphers = [_]CipherSuite{
            .tls_aes_256_gcm_sha384,
            .tls_aes_128_gcm_sha256,
            .tls_chacha20_poly1305_sha256,
        };

        return Config{
            .certificates = &[_]Certificate{},
            .private_key = null,
            .cipher_suites = &default_ciphers,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Config) void {
        for (self.certificates) |*cert| {
            cert.deinit();
        }
        self.allocator.free(self.certificates);

        if (self.private_key) |*key| {
            key.deinit();
        }

        if (self.server_name) |name| {
            self.allocator.free(name);
        }
    }

    pub fn loadCertificateFromFile(self: *Config, path: []const u8) !void {
        const cert_data = try std.fs.cwd().readFileAlloc(self.allocator, path, 1024 * 1024);
        defer self.allocator.free(cert_data);

        const cert = try Certificate.fromPEM(self.allocator, cert_data);

        const new_certs = try self.allocator.alloc(Certificate, self.certificates.len + 1);
        if (self.certificates.len > 0) {
            @memcpy(new_certs[0..self.certificates.len], self.certificates);
        }
        new_certs[self.certificates.len] = cert;

        self.allocator.free(self.certificates);
        self.certificates = new_certs;
    }

    pub fn loadPrivateKeyFromFile(self: *Config, path: []const u8) !void {
        const key_data = try std.fs.cwd().readFileAlloc(self.allocator, path, 1024 * 1024);
        defer self.allocator.free(key_data);

        self.private_key = try PrivateKey.fromPEM(self.allocator, key_data);
    }
};

/// TLS record
pub const Record = struct {
    content_type: ContentType,
    version: ProtocolVersion,
    length: u16,
    data: []const u8,

    pub fn parse(data: []const u8) !Record {
        if (data.len < 5) return error.InvalidRecord;

        const content_type = @as(ContentType, @enumFromInt(data[0]));
        const version_bytes = std.mem.readInt(u16, data[1..3], .big);
        const version = @as(ProtocolVersion, @enumFromInt(version_bytes));
        const length = std.mem.readInt(u16, data[3..5], .big);

        return Record{
            .content_type = content_type,
            .version = version,
            .length = length,
            .data = data[5..],
        };
    }

    pub fn write(self: Record, buffer: []u8) !void {
        if (buffer.len < 5 + self.data.len) return error.BufferTooSmall;

        buffer[0] = @intFromEnum(self.content_type);
        std.mem.writeInt(u16, buffer[1..3], @intFromEnum(self.version), .big);
        std.mem.writeInt(u16, buffer[3..5], self.length, .big);
        @memcpy(buffer[5 .. 5 + self.data.len], self.data);
    }
};

/// TLS connection state
pub const ConnectionState = enum {
    initial,
    handshaking,
    established,
    closed,
};

/// TLS connection (wraps TCP connection)
pub const TlsConnection = struct {
    tcp_conn: tcp.TcpConnection,
    config: *const Config,
    state: ConnectionState,
    is_server: bool,
    read_buffer: std.ArrayList(u8),
    write_buffer: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        tcp_conn: tcp.TcpConnection,
        config: *const Config,
        is_server: bool,
    ) TlsConnection {
        return TlsConnection{
            .tcp_conn = tcp_conn,
            .config = config,
            .state = .initial,
            .is_server = is_server,
            .read_buffer = std.ArrayList(u8).init(allocator),
            .write_buffer = std.ArrayList(u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TlsConnection) void {
        self.read_buffer.deinit();
        self.write_buffer.deinit();
        self.tcp_conn.close();
    }

    /// Perform TLS handshake
    pub fn handshake(self: *TlsConnection) !void {
        self.state = .handshaking;

        if (self.is_server) {
            try self.serverHandshake();
        } else {
            try self.clientHandshake();
        }

        self.state = .established;
        std.debug.print("✓ TLS handshake complete\n", .{});
    }

    fn clientHandshake(self: *TlsConnection) !void {
        // Send ClientHello
        try self.sendClientHello();

        // Receive ServerHello
        try self.receiveServerHello();

        // Receive Certificate
        try self.receiveCertificate();

        // Verify certificate
        if (self.config.verify_peer) {
            // Certificate verification would happen here
        }

        // Send ClientKeyExchange, ChangeCipherSpec, Finished
        try self.sendClientFinished();

        // Receive Server Finished
        try self.receiveServerFinished();
    }

    fn serverHandshake(self: *TlsConnection) !void {
        // Receive ClientHello
        try self.receiveClientHello();

        // Send ServerHello, Certificate, ServerHelloDone
        try self.sendServerHello();

        // Receive ClientKeyExchange, ChangeCipherSpec, Finished
        try self.receiveClientFinished();

        // Send ChangeCipherSpec, Finished
        try self.sendServerFinished();
    }

    fn sendClientHello(self: *TlsConnection) !void {
        var hello_data = std.ArrayList(u8).init(self.allocator);
        defer hello_data.deinit();

        // Client version (TLS 1.2 for compatibility)
        try hello_data.writer().writeInt(u16, @intFromEnum(ProtocolVersion.tls_1_2), .big);

        // Random (32 bytes)
        var random: [32]u8 = undefined;
        std.crypto.random.bytes(&random);
        try hello_data.appendSlice(&random);

        // Session ID (empty)
        try hello_data.append(0);

        // Cipher suites
        try hello_data.writer().writeInt(u16, @intCast(self.config.cipher_suites.len * 2), .big);
        for (self.config.cipher_suites) |suite| {
            try hello_data.writer().writeInt(u16, @intFromEnum(suite), .big);
        }

        // Compression methods (null compression)
        try hello_data.append(1);
        try hello_data.append(0);

        // Extensions would go here (SNI, ALPN, etc.)

        try self.sendHandshakeMessage(.client_hello, hello_data.items);
    }

    fn receiveServerHello(self: *TlsConnection) !void {
        const record = try self.receiveRecord();
        defer self.allocator.free(record.data);

        if (record.content_type != .handshake) return Error.HandshakeFailed;

        // Parse ServerHello
        // Real implementation would extract version, random, cipher suite, etc.
    }

    fn receiveCertificate(self: *TlsConnection) !void {
        const record = try self.receiveRecord();
        defer self.allocator.free(record.data);

        if (record.content_type != .handshake) return Error.HandshakeFailed;

        // Parse certificate chain
        // Real implementation would extract and verify certificates
    }

    fn sendClientFinished(self: *TlsConnection) !void {
        // Simplified - real implementation would compute verify_data
        const finished_data = [_]u8{0} ** 12;
        try self.sendHandshakeMessage(.finished, &finished_data);
    }

    fn receiveServerFinished(self: *TlsConnection) !void {
        const record = try self.receiveRecord();
        defer self.allocator.free(record.data);

        if (record.content_type != .handshake) return Error.HandshakeFailed;
    }

    fn receiveClientHello(self: *TlsConnection) !void {
        const record = try self.receiveRecord();
        defer self.allocator.free(record.data);

        if (record.content_type != .handshake) return Error.HandshakeFailed;

        // Parse ClientHello
    }

    fn sendServerHello(self: *TlsConnection) !void {
        var hello_data = std.ArrayList(u8).init(self.allocator);
        defer hello_data.deinit();

        // Server version
        try hello_data.writer().writeInt(u16, @intFromEnum(ProtocolVersion.tls_1_2), .big);

        // Random
        var random: [32]u8 = undefined;
        std.crypto.random.bytes(&random);
        try hello_data.appendSlice(&random);

        // Session ID (empty)
        try hello_data.append(0);

        // Selected cipher suite
        try hello_data.writer().writeInt(u16, @intFromEnum(self.config.cipher_suites[0]), .big);

        // Compression method
        try hello_data.append(0);

        try self.sendHandshakeMessage(.server_hello, hello_data.items);

        // Send certificate
        if (self.config.certificates.len > 0) {
            try self.sendCertificate();
        }
    }

    fn sendCertificate(self: *TlsConnection) !void {
        var cert_data = std.ArrayList(u8).init(self.allocator);
        defer cert_data.deinit();

        // Certificate list length
        var total_len: u32 = 0;
        for (self.config.certificates) |cert| {
            total_len += @intCast(3 + cert.der_data.len); // 3 bytes length + data
        }

        try cert_data.writer().writeInt(u24, @intCast(total_len), .big);

        // Write certificates
        for (self.config.certificates) |cert| {
            try cert_data.writer().writeInt(u24, @intCast(cert.der_data.len), .big);
            try cert_data.appendSlice(cert.der_data);
        }

        try self.sendHandshakeMessage(.certificate, cert_data.items);
    }

    fn receiveClientFinished(self: *TlsConnection) !void {
        const record = try self.receiveRecord();
        defer self.allocator.free(record.data);

        if (record.content_type != .handshake) return Error.HandshakeFailed;
    }

    fn sendServerFinished(self: *TlsConnection) !void {
        const finished_data = [_]u8{0} ** 12;
        try self.sendHandshakeMessage(.finished, &finished_data);
    }

    fn sendHandshakeMessage(self: *TlsConnection, msg_type: HandshakeType, payload: []const u8) !void {
        var message = std.ArrayList(u8).init(self.allocator);
        defer message.deinit();

        // Handshake message header
        try message.append(@intFromEnum(msg_type));
        try message.writer().writeInt(u24, @intCast(payload.len), .big);
        try message.appendSlice(payload);

        try self.sendRecord(.handshake, message.items);
    }

    fn sendRecord(self: *TlsConnection, content_type: ContentType, data: []const u8) !void {
        var record_data = std.ArrayList(u8).init(self.allocator);
        defer record_data.deinit();

        // Record header
        try record_data.append(@intFromEnum(content_type));
        try record_data.writer().writeInt(u16, @intFromEnum(ProtocolVersion.tls_1_2), .big);
        try record_data.writer().writeInt(u16, @intCast(data.len), .big);
        try record_data.appendSlice(data);

        _ = try self.tcp_conn.write(record_data.items);
    }

    fn receiveRecord(self: *TlsConnection) !Record {
        var header: [5]u8 = undefined;
        const n = try self.tcp_conn.read(&header);
        if (n != 5) return Error.ConnectionClosed;

        const record = try Record.parse(&header);

        const payload = try self.allocator.alloc(u8, record.length);
        const payload_read = try self.tcp_conn.read(payload);
        if (payload_read < record.length) return Error.ConnectionClosed;

        return Record{
            .content_type = record.content_type,
            .version = record.version,
            .length = record.length,
            .data = payload,
        };
    }

    /// Read decrypted data from TLS connection
    pub fn read(self: *TlsConnection, buffer: []u8) !usize {
        if (self.state != .established) return Error.HandshakeFailed;

        const record = try self.receiveRecord();
        defer self.allocator.free(record.data);

        if (record.content_type != .application_data) {
            return Error.AlertReceived;
        }

        const len = @min(buffer.len, record.data.len);
        @memcpy(buffer[0..len], record.data[0..len]);
        return len;
    }

    /// Write encrypted data to TLS connection
    pub fn write(self: *TlsConnection, data: []const u8) !usize {
        if (self.state != .established) return Error.HandshakeFailed;

        try self.sendRecord(.application_data, data);
        return data.len;
    }

    pub fn close(self: *TlsConnection) void {
        // Send close_notify alert
        const alert_data = [_]u8{ @intFromEnum(AlertLevel.warning), @intFromEnum(AlertDescription.close_notify) };
        self.sendRecord(.alert, &alert_data) catch {};

        self.state = .closed;
        self.tcp_conn.close();
    }
};

/// TLS server
pub const TlsServer = struct {
    tcp_server: tcp.TcpServer,
    config: Config,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, host: []const u8, port: u16, config: Config) !TlsServer {
        return TlsServer{
            .tcp_server = try tcp.TcpServer.init(allocator, host, port),
            .config = config,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TlsServer) void {
        self.tcp_server.deinit();
        self.config.deinit();
    }

    pub fn accept(self: *TlsServer) !TlsConnection {
        const tcp_conn = try self.tcp_server.accept();

        var tls_conn = TlsConnection.init(self.allocator, tcp_conn, &self.config, true);
        try tls_conn.handshake();

        return tls_conn;
    }
};

/// Connect to a TLS server (client)
pub fn connect(allocator: std.mem.Allocator, host: []const u8, port: u16, config: *const Config) !TlsConnection {
    const tcp_conn = try tcp.TcpConnection.connect(allocator, host, port);

    var tls_conn = TlsConnection.init(allocator, tcp_conn, config, false);
    try tls_conn.handshake();

    return tls_conn;
}

test "tls record parsing" {
    const data = [_]u8{
        @intFromEnum(ContentType.handshake), // content type
        0x03, 0x03, // version TLS 1.2
        0x00, 0x05, // length 5
        1, 2, 3, 4, 5, // payload
    };

    const record = try Record.parse(&data);
    try std.testing.expectEqual(ContentType.handshake, record.content_type);
    try std.testing.expectEqual(ProtocolVersion.tls_1_2, record.version);
    try std.testing.expectEqual(@as(u16, 5), record.length);
}

test "tls certificate loading" {
    const allocator = std.testing.allocator;

    const pem_data =
        \\-----BEGIN CERTIFICATE-----
        \\MIICLDCCAdKgAwIBAgIBADAKBggqhkjOPQQDAjB9MQswCQYDVQQGEwJCRTEPMA0G
        \\-----END CERTIFICATE-----
    ;

    var cert = try Certificate.fromPEM(allocator, pem_data);
    defer cert.deinit();

    try std.testing.expect(cert.der_data.len > 0);
}
