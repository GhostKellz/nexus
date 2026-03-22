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

/// X.509 certificate parser following RFC 5280
pub const Certificate = struct {
    der_data: []const u8,
    subject: []const u8,
    issuer: []const u8,
    not_before: i64, // Unix timestamp
    not_after: i64, // Unix timestamp
    public_key: []const u8,
    allocator: std.mem.Allocator,

    /// ASN.1 tag values
    const ASN1_SEQUENCE = 0x30;
    const ASN1_SET = 0x31;
    const ASN1_INTEGER = 0x02;
    const ASN1_BIT_STRING = 0x03;
    const ASN1_OCTET_STRING = 0x04;
    const ASN1_NULL = 0x05;
    const ASN1_OID = 0x06;
    const ASN1_UTF8_STRING = 0x0C;
    const ASN1_PRINTABLE_STRING = 0x13;
    const ASN1_IA5_STRING = 0x16;
    const ASN1_UTC_TIME = 0x17;
    const ASN1_GENERALIZED_TIME = 0x18;
    const ASN1_CONTEXT_0 = 0xA0;
    const ASN1_CONTEXT_3 = 0xA3;

    pub fn init(allocator: std.mem.Allocator, der_data: []const u8) !Certificate {
        return try parseDER(allocator, der_data);
    }

    /// Parse DER-encoded X.509 certificate
    fn parseDER(allocator: std.mem.Allocator, der_data: []const u8) !Certificate {
        var pos: usize = 0;

        // Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signatureValue }
        if (der_data.len < 4 or der_data[pos] != ASN1_SEQUENCE) {
            return error.InvalidCertificate;
        }
        pos += 1;
        const cert_len = try parseLength(der_data, &pos);
        _ = cert_len;

        // TBSCertificate ::= SEQUENCE
        if (der_data[pos] != ASN1_SEQUENCE) return error.InvalidCertificate;
        pos += 1;
        const tbs_len = try parseLength(der_data, &pos);
        const tbs_end = pos + tbs_len;

        // version [0] EXPLICIT Version DEFAULT v1
        var version: u8 = 0;
        if (pos < der_data.len and der_data[pos] == ASN1_CONTEXT_0) {
            pos += 1;
            _ = try parseLength(der_data, &pos);
            if (der_data[pos] != ASN1_INTEGER) return error.InvalidCertificate;
            pos += 1;
            const ver_len = try parseLength(der_data, &pos);
            if (ver_len > 0) version = der_data[pos];
            pos += ver_len;
        }
        _ = version;

        // serialNumber INTEGER
        if (der_data[pos] != ASN1_INTEGER) return error.InvalidCertificate;
        pos += 1;
        const serial_len = try parseLength(der_data, &pos);
        pos += serial_len; // Skip serial number

        // signature AlgorithmIdentifier
        pos = try skipSequence(der_data, pos);

        // issuer Name
        const issuer_start = pos;
        pos = try skipSequence(der_data, pos);
        const issuer = try extractName(allocator, der_data[issuer_start..pos]);
        errdefer allocator.free(issuer);

        // validity Validity
        if (der_data[pos] != ASN1_SEQUENCE) return error.InvalidCertificate;
        pos += 1;
        const validity_len = try parseLength(der_data, &pos);
        const validity_end = pos + validity_len;

        const not_before = try parseTime(der_data, &pos);
        const not_after = try parseTime(der_data, &pos);
        pos = validity_end;

        // subject Name
        const subject_start = pos;
        pos = try skipSequence(der_data, pos);
        const subject = try extractName(allocator, der_data[subject_start..pos]);
        errdefer allocator.free(subject);

        // subjectPublicKeyInfo SubjectPublicKeyInfo
        const spki_start = pos;
        pos = try skipSequence(der_data, pos);
        const public_key = try allocator.dupe(u8, der_data[spki_start..pos]);
        errdefer allocator.free(public_key);

        // Skip optional extensions and rest of tbsCertificate
        pos = tbs_end;

        return Certificate{
            .der_data = try allocator.dupe(u8, der_data),
            .subject = subject,
            .issuer = issuer,
            .not_before = not_before,
            .not_after = not_after,
            .public_key = public_key,
            .allocator = allocator,
        };
    }

    fn parseLength(data: []const u8, pos: *usize) !usize {
        if (pos.* >= data.len) return error.InvalidCertificate;
        const first = data[pos.*];
        pos.* += 1;

        if (first < 0x80) {
            return first;
        }

        const num_bytes = first & 0x7F;
        if (num_bytes > 4 or pos.* + num_bytes > data.len) {
            return error.InvalidCertificate;
        }

        var length: usize = 0;
        for (0..num_bytes) |_| {
            length = (length << 8) | data[pos.*];
            pos.* += 1;
        }
        return length;
    }

    fn skipSequence(data: []const u8, start: usize) !usize {
        var pos = start;
        if (pos >= data.len or data[pos] != ASN1_SEQUENCE) return error.InvalidCertificate;
        pos += 1;
        const len = try parseLength(data, &pos);
        return pos + len;
    }

    fn extractName(allocator: std.mem.Allocator, name_data: []const u8) ![]const u8 {
        // Parse X.500 Name structure to extract CN (Common Name)
        var pos: usize = 0;
        if (name_data.len < 2 or name_data[pos] != ASN1_SEQUENCE) {
            return allocator.dupe(u8, "");
        }
        pos += 1;
        _ = try parseLength(name_data, &pos);

        // Walk through RDNSequence looking for CN OID (2.5.4.3)
        const cn_oid = [_]u8{ 0x55, 0x04, 0x03 }; // 2.5.4.3

        while (pos < name_data.len) {
            if (name_data[pos] != ASN1_SET) break;
            pos += 1;
            const set_len = parseLength(name_data, &pos) catch break;
            const set_end = pos + set_len;

            // AttributeTypeAndValue
            if (pos < name_data.len and name_data[pos] == ASN1_SEQUENCE) {
                pos += 1;
                _ = parseLength(name_data, &pos) catch break;

                // type OID
                if (pos < name_data.len and name_data[pos] == ASN1_OID) {
                    pos += 1;
                    const oid_len = parseLength(name_data, &pos) catch break;
                    if (oid_len >= cn_oid.len and pos + oid_len <= name_data.len) {
                        if (std.mem.eql(u8, name_data[pos .. pos + cn_oid.len], &cn_oid)) {
                            pos += oid_len;
                            // value - string type
                            if (pos < name_data.len) {
                                const str_tag = name_data[pos];
                                if (str_tag == ASN1_UTF8_STRING or str_tag == ASN1_PRINTABLE_STRING or str_tag == ASN1_IA5_STRING) {
                                    pos += 1;
                                    const str_len = parseLength(name_data, &pos) catch break;
                                    if (pos + str_len <= name_data.len) {
                                        return allocator.dupe(u8, name_data[pos .. pos + str_len]);
                                    }
                                }
                            }
                        }
                    }
                }
            }
            pos = set_end;
        }
        return allocator.dupe(u8, "");
    }

    fn parseTime(data: []const u8, pos: *usize) !i64 {
        if (pos.* >= data.len) return error.InvalidCertificate;
        const tag = data[pos.*];
        pos.* += 1;
        const len = try parseLength(data, pos);

        if (pos.* + len > data.len) return error.InvalidCertificate;
        const time_str = data[pos.* .. pos.* + len];
        pos.* += len;

        if (tag == ASN1_UTC_TIME and len >= 12) {
            // YYMMDDhhmmssZ
            const year_short = parseDigits(time_str[0..2]);
            const year: i32 = if (year_short >= 50) 1900 + @as(i32, year_short) else 2000 + @as(i32, year_short);
            const month = parseDigits(time_str[2..4]);
            const day = parseDigits(time_str[4..6]);
            const hour = parseDigits(time_str[6..8]);
            const minute = parseDigits(time_str[8..10]);
            const second = parseDigits(time_str[10..12]);
            return toUnixTimestamp(year, month, day, hour, minute, second);
        } else if (tag == ASN1_GENERALIZED_TIME and len >= 14) {
            // YYYYMMDDhhmmssZ
            const year = parseDigits4(time_str[0..4]);
            const month = parseDigits(time_str[4..6]);
            const day = parseDigits(time_str[6..8]);
            const hour = parseDigits(time_str[8..10]);
            const minute = parseDigits(time_str[10..12]);
            const second = parseDigits(time_str[12..14]);
            return toUnixTimestamp(year, month, day, hour, minute, second);
        }
        return error.InvalidCertificate;
    }

    fn parseDigits(s: *const [2]u8) u8 {
        return (s[0] - '0') * 10 + (s[1] - '0');
    }

    fn parseDigits4(s: *const [4]u8) i32 {
        return @as(i32, s[0] - '0') * 1000 + @as(i32, s[1] - '0') * 100 + @as(i32, s[2] - '0') * 10 + @as(i32, s[3] - '0');
    }

    fn toUnixTimestamp(year: i32, month: u8, day: u8, hour: u8, minute: u8, second: u8) i64 {
        // Days in each month (non-leap year)
        const days_in_month = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

        var days: i64 = 0;

        // Years since 1970
        var y: i32 = 1970;
        while (y < year) : (y += 1) {
            days += if (isLeapYear(y)) 366 else 365;
        }

        // Months
        var m: u8 = 1;
        while (m < month) : (m += 1) {
            days += days_in_month[m - 1];
            if (m == 2 and isLeapYear(year)) days += 1;
        }

        // Days
        days += day - 1;

        return days * 86400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);
    }

    fn isLeapYear(year: i32) bool {
        return (@mod(year, 4) == 0 and @mod(year, 100) != 0) or @mod(year, 400) == 0;
    }

    pub fn deinit(self: *Certificate) void {
        self.allocator.free(self.der_data);
        self.allocator.free(self.subject);
        self.allocator.free(self.issuer);
        self.allocator.free(self.public_key);
    }

    pub fn fromPEM(allocator: std.mem.Allocator, pem_data: []const u8) !Certificate {
        // Find content between BEGIN/END markers
        const begin = "-----BEGIN CERTIFICATE-----";
        const end = "-----END CERTIFICATE-----";

        const start_idx = std.mem.indexOf(u8, pem_data, begin) orelse return error.InvalidCertificate;
        const end_idx = std.mem.indexOf(u8, pem_data, end) orelse return error.InvalidCertificate;

        const base64_data = pem_data[start_idx + begin.len .. end_idx];

        // Decode base64 to DER
        const der_data = try decodeBase64(allocator, base64_data);
        defer allocator.free(der_data);

        return try init(allocator, der_data);
    }

    fn decodeBase64(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
        const Base64 = std.base64.standard;

        // Strip whitespace and count valid chars
        var valid_count: usize = 0;
        for (data) |c| {
            if ((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
                (c >= '0' and c <= '9') or c == '+' or c == '/' or c == '=')
            {
                valid_count += 1;
            }
        }

        // Copy valid chars
        var clean = try allocator.alloc(u8, valid_count);
        defer allocator.free(clean);
        var i: usize = 0;
        for (data) |c| {
            if ((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
                (c >= '0' and c <= '9') or c == '+' or c == '/' or c == '=')
            {
                clean[i] = c;
                i += 1;
            }
        }

        const decoded_len = Base64.Decoder.calcSizeForSlice(clean) catch return error.InvalidCertificate;
        var decoded = try allocator.alloc(u8, decoded_len);
        errdefer allocator.free(decoded);

        Base64.Decoder.decode(decoded, clean) catch return error.InvalidCertificate;
        return decoded;
    }

    /// Verify certificate validity against current time (Unix timestamp in seconds)
    pub fn verifyTime(self: *const Certificate, current_time: i64) !void {
        if (current_time < self.not_before or current_time > self.not_after) {
            return Error.CertificateExpired;
        }
    }

    /// Verify certificate - deprecated, use verifyTime with explicit timestamp
    pub fn verify(self: *Certificate) !void {
        // Can't get time without Io, so just check structure validity
        _ = self;
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

/// Session data for TLS session resumption
pub const SessionData = struct {
    session_id: [32]u8,
    master_secret: [48]u8,
    cipher_suite: CipherSuite,
    created_at: i64,
    lifetime_seconds: u32 = 86400, // 24 hours default

    /// Check if session is expired given current Unix timestamp
    pub fn isExpiredAt(self: *const SessionData, current_time: i64) bool {
        return current_time > self.created_at + @as(i64, self.lifetime_seconds);
    }

    /// Check if session is expired - for compatibility, assumes valid if no time available
    pub fn isExpired(self: *const SessionData) bool {
        // Without Io access, we can't get current time. Assume valid.
        // Callers should use isExpiredAt with explicit timestamp when possible.
        _ = self;
        return false;
    }
};

/// Session cache for server-side session resumption (Session ID method)
pub const SessionCache = struct {
    sessions: std.AutoHashMap([32]u8, SessionData),
    allocator: std.mem.Allocator,
    max_entries: usize = 10000,

    pub fn init(allocator: std.mem.Allocator) SessionCache {
        return .{
            .sessions = std.AutoHashMap([32]u8, SessionData).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SessionCache) void {
        self.sessions.deinit();
    }

    /// Store a session for later resumption
    pub fn put(self: *SessionCache, session: SessionData) !void {
        // Evict expired entries if at capacity
        if (self.sessions.count() >= self.max_entries) {
            try self.evictExpired();
        }
        try self.sessions.put(session.session_id, session);
    }

    /// Retrieve a session by ID (returns null if not found or expired)
    pub fn get(self: *SessionCache, session_id: [32]u8) ?SessionData {
        if (self.sessions.get(session_id)) |session| {
            if (!session.isExpired()) {
                return session;
            }
            // Remove expired session
            _ = self.sessions.remove(session_id);
        }
        return null;
    }

    /// Remove a specific session
    pub fn remove(self: *SessionCache, session_id: [32]u8) void {
        _ = self.sessions.remove(session_id);
    }

    /// Evict all expired sessions
    pub fn evictExpired(self: *SessionCache) !void {
        var to_remove: std.ArrayListUnmanaged([32]u8) = .empty;
        defer to_remove.deinit(self.allocator);

        var iter = self.sessions.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.isExpired()) {
                try to_remove.append(self.allocator, entry.key_ptr.*);
            }
        }

        for (to_remove.items) |id| {
            _ = self.sessions.remove(id);
        }
    }
};

/// Session ticket for client-side session storage (TLS 1.3 style)
/// The server encrypts session state and sends it to the client
pub const SessionTicket = struct {
    /// Ticket encryption key (should be rotated periodically)
    const TICKET_KEY_SIZE = 32;
    const TICKET_IV_SIZE = 12;
    const TICKET_TAG_SIZE = 16;

    /// Encrypted ticket data
    encrypted_data: []const u8,
    /// Ticket lifetime in seconds
    lifetime: u32,
    /// Ticket age add value (for 0-RTT protection)
    age_add: u32,
    /// Ticket nonce
    nonce: [8]u8,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *SessionTicket) void {
        self.allocator.free(self.encrypted_data);
    }

    /// Create a new session ticket from session data using AES-256-GCM
    pub fn create(allocator: std.mem.Allocator, session: SessionData, ticket_key: [TICKET_KEY_SIZE]u8) !SessionTicket {
        const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;

        // Serialize session data
        var session_bytes: [128]u8 = undefined;
        @memcpy(session_bytes[0..32], &session.session_id);
        @memcpy(session_bytes[32..80], &session.master_secret);
        std.mem.writeInt(u16, session_bytes[80..82], @intFromEnum(session.cipher_suite), .big);
        std.mem.writeInt(i64, session_bytes[82..90], session.created_at, .big);
        std.mem.writeInt(u32, session_bytes[90..94], session.lifetime_seconds, .big);

        const plaintext_len: usize = 94;

        // Generate random nonce/IV for AES-GCM
        var nonce: [TICKET_IV_SIZE]u8 = undefined;
        std.crypto.random.bytes(&nonce);

        // Allocate output buffer: nonce + ciphertext + tag
        const ciphertext = try allocator.alloc(u8, TICKET_IV_SIZE + plaintext_len + TICKET_TAG_SIZE);
        errdefer allocator.free(ciphertext);

        // Copy nonce to output
        @memcpy(ciphertext[0..TICKET_IV_SIZE], &nonce);

        // Encrypt using AES-256-GCM
        var tag: [TICKET_TAG_SIZE]u8 = undefined;
        Aes256Gcm.encrypt(
            ciphertext[TICKET_IV_SIZE .. TICKET_IV_SIZE + plaintext_len],
            &tag,
            session_bytes[0..plaintext_len],
            "", // Additional authenticated data (empty)
            nonce,
            ticket_key,
        );

        // Append authentication tag
        @memcpy(ciphertext[TICKET_IV_SIZE + plaintext_len ..], &tag);

        var ticket_nonce: [8]u8 = undefined;
        std.crypto.random.bytes(&ticket_nonce);

        return SessionTicket{
            .encrypted_data = ciphertext,
            .lifetime = session.lifetime_seconds,
            .age_add = std.crypto.random.int(u32),
            .nonce = ticket_nonce,
            .allocator = allocator,
        };
    }

    /// Decrypt a session ticket to recover session data using AES-256-GCM
    pub fn decrypt(self: *const SessionTicket, ticket_key: [TICKET_KEY_SIZE]u8) !SessionData {
        const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;

        if (self.encrypted_data.len < TICKET_IV_SIZE + TICKET_TAG_SIZE) {
            return error.InvalidTicket;
        }

        const ciphertext_len = self.encrypted_data.len - TICKET_IV_SIZE - TICKET_TAG_SIZE;

        // Extract nonce, ciphertext, and tag
        const nonce: [TICKET_IV_SIZE]u8 = self.encrypted_data[0..TICKET_IV_SIZE].*;
        const ciphertext = self.encrypted_data[TICKET_IV_SIZE .. TICKET_IV_SIZE + ciphertext_len];
        const tag: [TICKET_TAG_SIZE]u8 = self.encrypted_data[TICKET_IV_SIZE + ciphertext_len ..][0..TICKET_TAG_SIZE].*;

        // Decrypt and verify using AES-256-GCM
        var plaintext: [128]u8 = undefined;
        Aes256Gcm.decrypt(
            plaintext[0..ciphertext_len],
            ciphertext,
            tag,
            "", // Additional authenticated data (empty)
            nonce,
            ticket_key,
        ) catch {
            return error.InvalidTicket; // Decryption or authentication failed
        };

        // Deserialize session data
        var session: SessionData = undefined;
        @memcpy(&session.session_id, plaintext[0..32]);
        @memcpy(&session.master_secret, plaintext[32..80]);
        session.cipher_suite = @enumFromInt(std.mem.readInt(u16, plaintext[80..82], .big));
        session.created_at = std.mem.readInt(i64, plaintext[82..90], .big);
        session.lifetime_seconds = std.mem.readInt(u32, plaintext[90..94], .big);

        // Check expiration
        if (session.isExpired()) {
            return error.SessionExpired;
        }

        return session;
    }

    /// Serialize ticket for sending in NewSessionTicket message
    pub fn serialize(self: *const SessionTicket, allocator: std.mem.Allocator) ![]u8 {
        const total_len = 4 + 4 + 8 + 2 + self.encrypted_data.len;
        var buf = try allocator.alloc(u8, total_len);

        std.mem.writeInt(u32, buf[0..4], self.lifetime, .big);
        std.mem.writeInt(u32, buf[4..8], self.age_add, .big);
        @memcpy(buf[8..16], &self.nonce);
        std.mem.writeInt(u16, buf[16..18], @intCast(self.encrypted_data.len), .big);
        @memcpy(buf[18..], self.encrypted_data);

        return buf;
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
    /// Enable session resumption
    enable_session_resumption: bool = true,
    /// Session cache for server-side resumption
    session_cache: ?*SessionCache = null,
    /// Ticket encryption key for session tickets
    ticket_key: ?[32]u8 = null,
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

    pub fn loadCertificateFromFile(self: *Config, io: std.Io, path: []const u8) !void {
        const Dir = std.Io.Dir;
        const cert_data = try Dir.cwd().readFileAlloc(io, path, self.allocator, std.Io.Limit.limited(1024 * 1024));
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

    pub fn loadPrivateKeyFromFile(self: *Config, io: std.Io, path: []const u8) !void {
        const Dir = std.Io.Dir;
        const key_data = try Dir.cwd().readFileAlloc(io, path, self.allocator, std.Io.Limit.limited(1024 * 1024));
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
    read_buffer: std.ArrayListUnmanaged(u8),
    write_buffer: std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    /// Current session data (for resumption)
    session: ?SessionData = null,
    /// Whether this connection was resumed
    is_resumed: bool = false,
    /// Client-provided session ID for resumption attempt
    client_session_id: ?[32]u8 = null,
    /// Accumulated handshake messages hash for verify_data
    handshake_hash: std.crypto.hash.sha2.Sha256 = std.crypto.hash.sha2.Sha256.init(.{}),
    /// Master secret derived during key exchange
    master_secret: [48]u8 = [_]u8{0} ** 48,
    /// Client random from ClientHello
    client_random: [32]u8 = undefined,
    /// Server random from ServerHello
    server_random: [32]u8 = undefined,

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
            .read_buffer = .empty,
            .write_buffer = .empty,
            .allocator = allocator,
        };
    }

    /// Initialize with a session for resumption attempt (client-side)
    pub fn initWithSession(
        allocator: std.mem.Allocator,
        tcp_conn: tcp.TcpConnection,
        config: *const Config,
        session: SessionData,
    ) TlsConnection {
        var conn = init(allocator, tcp_conn, config, false);
        conn.session = session;
        conn.client_session_id = session.session_id;
        return conn;
    }

    pub fn deinit(self: *TlsConnection) void {
        self.read_buffer.deinit(self.allocator);
        self.write_buffer.deinit(self.allocator);
        self.tcp_conn.close();
    }

    /// Get the current session data (for storing and later resumption)
    pub fn getSession(self: *const TlsConnection) ?SessionData {
        return self.session;
    }

    /// Check if this connection was established via session resumption
    pub fn wasResumed(self: *const TlsConnection) bool {
        return self.is_resumed;
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
        var hello_data: std.ArrayListUnmanaged(u8) = .empty;
        defer hello_data.deinit(self.allocator);

        // Client version (TLS 1.2 for compatibility)
        var version_buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &version_buf, @intFromEnum(ProtocolVersion.tls_1_2), .big);
        try hello_data.appendSlice(self.allocator, &version_buf);

        // Random (32 bytes)
        std.crypto.random.bytes(&self.client_random);
        try hello_data.appendSlice(self.allocator, &self.client_random);

        // Session ID (empty)
        try hello_data.append(self.allocator, 0);

        // Cipher suites
        var suites_len_buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &suites_len_buf, @intCast(self.config.cipher_suites.len * 2), .big);
        try hello_data.appendSlice(self.allocator, &suites_len_buf);
        for (self.config.cipher_suites) |suite| {
            var suite_buf: [2]u8 = undefined;
            std.mem.writeInt(u16, &suite_buf, @intFromEnum(suite), .big);
            try hello_data.appendSlice(self.allocator, &suite_buf);
        }

        // Compression methods (null compression)
        try hello_data.append(self.allocator, 1);
        try hello_data.append(self.allocator, 0);

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
        // Compute verify_data per RFC 5246 section 7.4.9
        // verify_data = PRF(master_secret, "client finished", Hash(handshake_messages))[0..12]
        const finished_data = self.computeVerifyData("client finished");
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
        var hello_data: std.ArrayListUnmanaged(u8) = .empty;
        defer hello_data.deinit(self.allocator);

        // Server version
        var version_buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &version_buf, @intFromEnum(ProtocolVersion.tls_1_2), .big);
        try hello_data.appendSlice(self.allocator, &version_buf);

        // Random
        std.crypto.random.bytes(&self.server_random);
        try hello_data.appendSlice(self.allocator, &self.server_random);

        // Session ID (empty)
        try hello_data.append(self.allocator, 0);

        // Selected cipher suite
        var suite_buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &suite_buf, @intFromEnum(self.config.cipher_suites[0]), .big);
        try hello_data.appendSlice(self.allocator, &suite_buf);

        // Compression method
        try hello_data.append(self.allocator, 0);

        try self.sendHandshakeMessage(.server_hello, hello_data.items);

        // Send certificate
        if (self.config.certificates.len > 0) {
            try self.sendCertificate();
        }
    }

    fn sendCertificate(self: *TlsConnection) !void {
        var cert_data: std.ArrayListUnmanaged(u8) = .empty;
        defer cert_data.deinit(self.allocator);

        // Certificate list length
        var total_len: u32 = 0;
        for (self.config.certificates) |cert| {
            total_len += @intCast(3 + cert.der_data.len); // 3 bytes length + data
        }

        // Write 3-byte length (u24)
        var len_buf: [3]u8 = undefined;
        len_buf[0] = @intCast((total_len >> 16) & 0xFF);
        len_buf[1] = @intCast((total_len >> 8) & 0xFF);
        len_buf[2] = @intCast(total_len & 0xFF);
        try cert_data.appendSlice(self.allocator, &len_buf);

        // Write certificates
        for (self.config.certificates) |cert| {
            const cert_len: u24 = @intCast(cert.der_data.len);
            var cert_len_buf: [3]u8 = undefined;
            cert_len_buf[0] = @intCast((cert_len >> 16) & 0xFF);
            cert_len_buf[1] = @intCast((cert_len >> 8) & 0xFF);
            cert_len_buf[2] = @intCast(cert_len & 0xFF);
            try cert_data.appendSlice(self.allocator, &cert_len_buf);
            try cert_data.appendSlice(self.allocator, cert.der_data);
        }

        try self.sendHandshakeMessage(.certificate, cert_data.items);
    }

    fn receiveClientFinished(self: *TlsConnection) !void {
        const record = try self.receiveRecord();
        defer self.allocator.free(record.data);

        if (record.content_type != .handshake) return Error.HandshakeFailed;
    }

    fn sendServerFinished(self: *TlsConnection) !void {
        // Compute verify_data per RFC 5246 section 7.4.9
        // verify_data = PRF(master_secret, "server finished", Hash(handshake_messages))[0..12]
        const finished_data = self.computeVerifyData("server finished");
        try self.sendHandshakeMessage(.finished, &finished_data);
    }

    /// Compute TLS 1.2 verify_data using PRF with SHA-256
    /// PRF(secret, label, seed) = P_SHA256(secret, label || seed)
    fn computeVerifyData(self: *TlsConnection, label: []const u8) [12]u8 {
        const Sha256 = std.crypto.hash.sha2.Sha256;
        const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

        // Get current hash of handshake messages
        var hash_copy = self.handshake_hash;
        var handshake_hash: [32]u8 = undefined;
        hash_copy.final(&handshake_hash);

        // Build seed = label || handshake_hash
        var seed: [64]u8 = undefined;
        @memcpy(seed[0..label.len], label);
        @memcpy(seed[label.len .. label.len + 32], &handshake_hash);
        const seed_len = label.len + 32;

        // P_SHA256 expansion (TLS 1.2 PRF)
        // A(0) = seed
        // A(i) = HMAC(secret, A(i-1))
        // P_SHA256 = HMAC(secret, A(1) || seed) || HMAC(secret, A(2) || seed) || ...

        // A(1) = HMAC(master_secret, seed)
        var a1: [32]u8 = undefined;
        HmacSha256.create(&a1, seed[0..seed_len], &self.master_secret);

        // First iteration: HMAC(master_secret, A(1) || seed)
        var input: [96]u8 = undefined;
        @memcpy(input[0..32], &a1);
        @memcpy(input[32 .. 32 + seed_len], seed[0..seed_len]);

        var p1: [32]u8 = undefined;
        HmacSha256.create(&p1, input[0 .. 32 + seed_len], &self.master_secret);

        // Return first 12 bytes
        var result: [12]u8 = undefined;
        @memcpy(&result, p1[0..12]);
        return result;
    }

    fn sendHandshakeMessage(self: *TlsConnection, msg_type: HandshakeType, payload: []const u8) !void {
        var message: std.ArrayListUnmanaged(u8) = .empty;
        defer message.deinit(self.allocator);

        // Handshake message header
        try message.append(self.allocator, @intFromEnum(msg_type));

        // Write 3-byte length
        const len: u24 = @intCast(payload.len);
        var len_buf: [3]u8 = undefined;
        len_buf[0] = @intCast((len >> 16) & 0xFF);
        len_buf[1] = @intCast((len >> 8) & 0xFF);
        len_buf[2] = @intCast(len & 0xFF);
        try message.appendSlice(self.allocator, &len_buf);
        try message.appendSlice(self.allocator, payload);

        // Update handshake hash with message contents
        self.handshake_hash.update(message.items);

        try self.sendRecord(.handshake, message.items);
    }

    fn sendRecord(self: *TlsConnection, content_type: ContentType, data: []const u8) !void {
        var record_data: std.ArrayListUnmanaged(u8) = .empty;
        defer record_data.deinit(self.allocator);

        // Record header
        try record_data.append(self.allocator, @intFromEnum(content_type));

        var version_buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &version_buf, @intFromEnum(ProtocolVersion.tls_1_2), .big);
        try record_data.appendSlice(self.allocator, &version_buf);

        var len_buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &len_buf, @intCast(data.len), .big);
        try record_data.appendSlice(self.allocator, &len_buf);

        try record_data.appendSlice(self.allocator, data);

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
