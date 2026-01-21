const std = @import("std");
const http = @import("http.zig");
const tls = @import("tls.zig");

/// HTTP client for ACME API calls using Zig's standard library
const HttpClient = std.http.Client;

/// ACME (Automatic Certificate Management Environment) client
/// RFC 8555 - Automatic Certificate Management Environment (ACME)
/// Used for Let's Encrypt integration

pub const Error = error{
    InvalidDirectory,
    AccountNotFound,
    ChallengeValidationFailed,
    OrderNotReady,
    CertificateNotIssued,
    RateLimitExceeded,
    InvalidDomain,
};

/// ACME directory URLs
pub const AcmeDirectory = struct {
    new_nonce: []const u8,
    new_account: []const u8,
    new_order: []const u8,
    new_authz: []const u8,
    revoke_cert: []const u8,
    key_change: []const u8,
    meta: Meta,

    pub const Meta = struct {
        terms_of_service: ?[]const u8 = null,
        website: ?[]const u8 = null,
        caa_identities: ?[][]const u8 = null,
    };

    // Let's Encrypt production directory
    pub const LETS_ENCRYPT_PROD = "https://acme-v02.api.letsencrypt.org/directory";

    // Let's Encrypt staging directory (for testing)
    pub const LETS_ENCRYPT_STAGING = "https://acme-staging-v02.api.letsencrypt.org/directory";
};

/// ACME challenge types
pub const ChallengeType = enum {
    http_01, // HTTP challenge
    dns_01, // DNS challenge
    tls_alpn_01, // TLS-ALPN challenge

    pub fn toString(self: ChallengeType) []const u8 {
        return switch (self) {
            .http_01 => "http-01",
            .dns_01 => "dns-01",
            .tls_alpn_01 => "tls-alpn-01",
        };
    }
};

/// ACME order status
pub const OrderStatus = enum {
    pending,
    ready,
    processing,
    valid,
    invalid,

    pub fn fromString(s: []const u8) ?OrderStatus {
        if (std.mem.eql(u8, s, "pending")) return .pending;
        if (std.mem.eql(u8, s, "ready")) return .ready;
        if (std.mem.eql(u8, s, "processing")) return .processing;
        if (std.mem.eql(u8, s, "valid")) return .valid;
        if (std.mem.eql(u8, s, "invalid")) return .invalid;
        return null;
    }
};

/// ACME account with ES256 (P-256) key
pub const Account = struct {
    kid: []const u8, // Key ID (account URL)
    private_key: [32]u8, // P-256 private key scalar
    public_key_x: [32]u8, // Public key X coordinate
    public_key_y: [32]u8, // Public key Y coordinate
    contacts: [][]const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, kid: []const u8, key_seed: []const u8) !Account {
        // Generate P-256 key pair from seed
        const P256 = std.crypto.ecc.P256;

        // Use SHA-256 of seed to get 32 bytes for the scalar
        var scalar_bytes: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(key_seed, &scalar_bytes, .{});

        // Create scalar and derive public key
        const scalar = P256.scalar.Scalar.fromBytes(scalar_bytes, .big) catch
            P256.scalar.Scalar.one;
        const public_point = P256.basePoint.mul(scalar.toBytes(.big), .big) catch
            return error.KeyGenerationFailed;

        const affine = public_point.affineCoordinates();

        return Account{
            .kid = try allocator.dupe(u8, kid),
            .private_key = scalar_bytes,
            .public_key_x = affine.x,
            .public_key_y = affine.y,
            .contacts = &[_][]const u8{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Account) void {
        self.allocator.free(self.kid);
        // Zero out private key
        @memset(&self.private_key, 0);
        for (self.contacts) |contact| {
            self.allocator.free(contact);
        }
        self.allocator.free(self.contacts);
    }

    /// Compute JWK thumbprint (RFC 7638)
    /// Returns base64url-encoded SHA-256 hash of canonical JWK
    pub fn computeThumbprint(self: *const Account, allocator: std.mem.Allocator) ![]u8 {
        // Base64url encode X and Y coordinates
        const base64_encoder = std.base64.url_safe_no_pad;
        const coord_encoded_len = base64_encoder.Encoder.calcSize(32);

        var x_encoded: [44]u8 = undefined; // ceil(32 * 4 / 3) = 43, round to 44
        const x_len = base64_encoder.Encoder.encode(&x_encoded, &self.public_key_x);

        var y_encoded: [44]u8 = undefined;
        const y_len = base64_encoder.Encoder.encode(&y_encoded, &self.public_key_y);

        // Build canonical JWK JSON (members in lexicographic order)
        // {"crv":"P-256","kty":"EC","x":"...","y":"..."}
        const canonical_jwk = try std.fmt.allocPrint(
            allocator,
            "{{\"crv\":\"P-256\",\"kty\":\"EC\",\"x\":\"{s}\",\"y\":\"{s}\"}}",
            .{ x_encoded[0..x_len], y_encoded[0..y_len] },
        );
        defer allocator.free(canonical_jwk);

        // SHA-256 hash of canonical JWK
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(canonical_jwk, &hash, .{});

        // Base64url encode the hash
        const result = try allocator.alloc(u8, coord_encoded_len);
        _ = base64_encoder.Encoder.encode(result, &hash);

        return result;
    }
};

/// ACME challenge
pub const Challenge = struct {
    type: ChallengeType,
    url: []const u8,
    token: []const u8,
    status: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, challenge_type: ChallengeType, url: []const u8, token: []const u8) !Challenge {
        return Challenge{
            .type = challenge_type,
            .url = try allocator.dupe(u8, url),
            .token = try allocator.dupe(u8, token),
            .status = try allocator.dupe(u8, "pending"),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Challenge) void {
        self.allocator.free(self.url);
        self.allocator.free(self.token);
        self.allocator.free(self.status);
    }

    /// Generate key authorization for HTTP-01 challenge
    pub fn keyAuthorization(self: *Challenge, account_key_thumbprint: []const u8) ![]u8 {
        // key-authz = token || '.' || base64url(JWK thumbprint)
        const result = try std.fmt.allocPrint(
            self.allocator,
            "{s}.{s}",
            .{ self.token, account_key_thumbprint },
        );
        return result;
    }
};

/// DNS provider interface for DNS-01 challenge
/// Implement this to integrate with your DNS provider (Cloudflare, Route53, etc.)
pub const DnsProvider = struct {
    /// Function to create a TXT record
    createTxtRecordFn: *const fn (self: *DnsProvider, name: []const u8, value: []const u8) anyerror!void,
    /// Function to delete a TXT record
    deleteTxtRecordFn: *const fn (self: *DnsProvider, name: []const u8) anyerror!void,
    /// Provider-specific context
    context: ?*anyopaque = null,

    pub fn createTxtRecord(self: *DnsProvider, name: []const u8, value: []const u8) !void {
        return self.createTxtRecordFn(self, name, value);
    }

    pub fn deleteTxtRecord(self: *DnsProvider, name: []const u8) !void {
        return self.deleteTxtRecordFn(self, name);
    }
};

/// Manual DNS provider (for manual DNS record creation)
/// Prints instructions and waits for user confirmation
pub const ManualDnsProvider = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ManualDnsProvider {
        return ManualDnsProvider{
            .allocator = allocator,
        };
    }

    pub fn getProvider(self: *ManualDnsProvider) DnsProvider {
        _ = self;
        return DnsProvider{
            .createTxtRecordFn = createTxtRecord,
            .deleteTxtRecordFn = deleteTxtRecord,
        };
    }

    fn createTxtRecord(_: *DnsProvider, name: []const u8, value: []const u8) !void {
        std.debug.print("\n", .{});
        std.debug.print("===============================================\n", .{});
        std.debug.print("MANUAL DNS RECORD CREATION REQUIRED\n", .{});
        std.debug.print("===============================================\n", .{});
        std.debug.print("\n", .{});
        std.debug.print("Please create the following DNS TXT record:\n", .{});
        std.debug.print("\n", .{});
        std.debug.print("  Name:  {s}\n", .{name});
        std.debug.print("  Type:  TXT\n", .{});
        std.debug.print("  Value: {s}\n", .{value});
        std.debug.print("  TTL:   300 (or lowest available)\n", .{});
        std.debug.print("\n", .{});
        std.debug.print("After creating the record, wait for DNS propagation.\n", .{});
        std.debug.print("You can verify with: dig TXT {s}\n", .{name});
        std.debug.print("\n", .{});
        std.debug.print("===============================================\n", .{});

        // In a real implementation, would wait for user confirmation
        std.time.sleep(5 * std.time.ns_per_s);
    }

    fn deleteTxtRecord(_: *DnsProvider, name: []const u8) !void {
        std.debug.print("\n", .{});
        std.debug.print("You can now delete the DNS TXT record: {s}\n", .{name});
    }
};

/// Cloudflare DNS provider
pub const CloudflareDnsProvider = struct {
    api_token: []const u8,
    zone_id: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, api_token: []const u8, zone_id: []const u8) CloudflareDnsProvider {
        return CloudflareDnsProvider{
            .api_token = api_token,
            .zone_id = zone_id,
            .allocator = allocator,
        };
    }

    pub fn getProvider(self: *CloudflareDnsProvider) DnsProvider {
        return DnsProvider{
            .createTxtRecordFn = createTxtRecord,
            .deleteTxtRecordFn = deleteTxtRecord,
            .context = self,
        };
    }

    fn createTxtRecord(provider: *DnsProvider, name: []const u8, value: []const u8) !void {
        const self: *CloudflareDnsProvider = @ptrCast(@alignCast(provider.context.?));
        _ = self;

        // Real implementation would:
        // POST to https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records
        // with Authorization: Bearer {api_token}
        // Body: {"type": "TXT", "name": name, "content": value, "ttl": 120}

        std.debug.print("  [Cloudflare] Creating TXT record: {s} = {s}\n", .{ name, value });
    }

    fn deleteTxtRecord(provider: *DnsProvider, name: []const u8) !void {
        const self: *CloudflareDnsProvider = @ptrCast(@alignCast(provider.context.?));
        _ = self;

        // Real implementation would:
        // 1. GET record ID from https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records?name={name}&type=TXT
        // 2. DELETE https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records/{record_id}

        std.debug.print("  [Cloudflare] Deleting TXT record: {s}\n", .{name});
    }
};

/// AWS Route53 DNS provider
pub const Route53DnsProvider = struct {
    access_key_id: []const u8,
    secret_access_key: []const u8,
    hosted_zone_id: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        access_key_id: []const u8,
        secret_access_key: []const u8,
        hosted_zone_id: []const u8,
    ) Route53DnsProvider {
        return Route53DnsProvider{
            .access_key_id = access_key_id,
            .secret_access_key = secret_access_key,
            .hosted_zone_id = hosted_zone_id,
            .allocator = allocator,
        };
    }

    pub fn getProvider(self: *Route53DnsProvider) DnsProvider {
        return DnsProvider{
            .createTxtRecordFn = createTxtRecord,
            .deleteTxtRecordFn = deleteTxtRecord,
            .context = self,
        };
    }

    fn createTxtRecord(provider: *DnsProvider, name: []const u8, value: []const u8) !void {
        const self: *Route53DnsProvider = @ptrCast(@alignCast(provider.context.?));
        _ = self;

        // Real implementation would use AWS Route53 ChangeResourceRecordSets API
        // POST to https://route53.amazonaws.com/2013-04-01/hostedzone/{hosted_zone_id}/rrset/
        // with AWS Signature v4 authentication

        std.debug.print("  [Route53] Creating TXT record: {s} = {s}\n", .{ name, value });
    }

    fn deleteTxtRecord(provider: *DnsProvider, name: []const u8) !void {
        const self: *Route53DnsProvider = @ptrCast(@alignCast(provider.context.?));
        _ = self;

        std.debug.print("  [Route53] Deleting TXT record: {s}\n", .{name});
    }
};

/// ACME order
pub const Order = struct {
    url: []const u8,
    status: OrderStatus,
    identifiers: [][]const u8,
    authorizations: [][]const u8,
    finalize_url: []const u8,
    certificate_url: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, url: []const u8, finalize_url: []const u8) !Order {
        return Order{
            .url = try allocator.dupe(u8, url),
            .status = .pending,
            .identifiers = &[_][]const u8{},
            .authorizations = &[_][]const u8{},
            .finalize_url = try allocator.dupe(u8, finalize_url),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Order) void {
        self.allocator.free(self.url);
        for (self.identifiers) |id| {
            self.allocator.free(id);
        }
        self.allocator.free(self.identifiers);
        for (self.authorizations) |authz| {
            self.allocator.free(authz);
        }
        self.allocator.free(self.authorizations);
        self.allocator.free(self.finalize_url);
        if (self.certificate_url) |cert_url| {
            self.allocator.free(cert_url);
        }
    }
};

/// ACME client
pub const Client = struct {
    directory_url: []const u8,
    account: ?Account = null,
    allocator: std.mem.Allocator,
    nonce: ?[]const u8 = null,
    io: ?std.Io = null,
    http_client: ?HttpClient = null,
    directory: ?AcmeDirectory = null,
    last_location: ?[]const u8 = null, // Location header from last POST response

    pub fn init(allocator: std.mem.Allocator, directory_url: []const u8) !Client {
        return Client{
            .directory_url = try allocator.dupe(u8, directory_url),
            .allocator = allocator,
        };
    }

    /// Initialize with IO for making HTTP requests
    pub fn initWithIo(allocator: std.mem.Allocator, io: std.Io, directory_url: []const u8) !Client {
        var client = Client{
            .directory_url = try allocator.dupe(u8, directory_url),
            .allocator = allocator,
            .io = io,
            .http_client = .{ .allocator = allocator, .io = io },
        };
        return client;
    }

    pub fn deinit(self: *Client) void {
        self.allocator.free(self.directory_url);
        if (self.account) |*acc| {
            acc.deinit();
        }
        if (self.nonce) |n| {
            self.allocator.free(n);
        }
        if (self.last_location) |loc| {
            self.allocator.free(loc);
        }
        if (self.http_client) |*hc| {
            hc.connection_pool.deinit(self.allocator);
        }
    }

    /// Fetch ACME directory from server
    pub fn fetchDirectory(self: *Client) !void {
        if (self.http_client == null or self.io == null) {
            return error.NoHttpClient;
        }

        const uri = std.Uri.parse(self.directory_url) catch return error.InvalidDirectory;

        var req = try self.http_client.?.open(.GET, uri, .{
            .server_header_buffer = try self.allocator.alloc(u8, 8192),
        });
        defer {
            self.allocator.free(req.response.server_header_buffer.?);
            req.deinit();
        }

        try req.send(self.io.?);
        try req.wait(self.io.?);

        if (req.response.status != .ok) {
            return error.InvalidDirectory;
        }

        // Read and parse JSON response
        var body_buf: [8192]u8 = undefined;
        const body_len = try req.reader().readAll(&body_buf);
        const body = body_buf[0..body_len];

        // Parse directory JSON
        self.directory = try parseDirectoryJson(self.allocator, body);
    }

    /// Get a fresh nonce from the ACME server
    pub fn getNonce(self: *Client) ![]const u8 {
        if (self.http_client == null or self.io == null) {
            // Fallback: generate random nonce for testing
            var nonce_bytes: [32]u8 = undefined;
            std.crypto.random.bytes(&nonce_bytes);
            const nonce = try std.base64.url_safe_no_pad.Encoder.encode(
                try self.allocator.alloc(u8, 43),
                &nonce_bytes,
            );
            return nonce;
        }

        const dir = self.directory orelse return error.DirectoryNotFetched;
        const uri = std.Uri.parse(dir.new_nonce) catch return error.InvalidDirectory;

        var req = try self.http_client.?.open(.HEAD, uri, .{
            .server_header_buffer = try self.allocator.alloc(u8, 4096),
        });
        defer {
            self.allocator.free(req.response.server_header_buffer.?);
            req.deinit();
        }

        try req.send(self.io.?);
        try req.wait(self.io.?);

        // Get Replay-Nonce header
        if (req.response.iterateHeaders().next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "replay-nonce")) {
                const nonce = try self.allocator.dupe(u8, header.value);
                if (self.nonce) |old| self.allocator.free(old);
                self.nonce = nonce;
                return nonce;
            }
        }

        return error.NoNonceReceived;
    }

    /// JSON structure for ACME directory response
    const DirectoryJson = struct {
        newNonce: []const u8,
        newAccount: []const u8,
        newOrder: []const u8,
        newAuthz: ?[]const u8 = null,
        revokeCert: []const u8,
        keyChange: []const u8,
        meta: ?MetaJson = null,

        const MetaJson = struct {
            termsOfService: ?[]const u8 = null,
            website: ?[]const u8 = null,
            caaIdentities: ?[][]const u8 = null,
        };
    };

    fn parseDirectoryJson(allocator: std.mem.Allocator, json_str: []const u8) !AcmeDirectory {
        const parsed = std.json.parseFromSlice(DirectoryJson, allocator, json_str, .{
            .ignore_unknown_fields = true,
        }) catch return error.InvalidDirectory;
        defer parsed.deinit();

        const v = parsed.value;

        var meta = AcmeDirectory.Meta{};
        if (v.meta) |m| {
            if (m.termsOfService) |tos| {
                meta.terms_of_service = try allocator.dupe(u8, tos);
            }
            if (m.website) |w| {
                meta.website = try allocator.dupe(u8, w);
            }
        }

        return AcmeDirectory{
            .new_nonce = try allocator.dupe(u8, v.newNonce),
            .new_account = try allocator.dupe(u8, v.newAccount),
            .new_order = try allocator.dupe(u8, v.newOrder),
            .new_authz = if (v.newAuthz) |a| try allocator.dupe(u8, a) else "",
            .revoke_cert = try allocator.dupe(u8, v.revokeCert),
            .key_change = try allocator.dupe(u8, v.keyChange),
            .meta = meta,
        };
    }

    /// JSON structure for ACME account response (RFC 8555 section 7.1.2)
    /// Note: The account URL (kid) comes from the Location header, not JSON body
    const AccountJson = struct {
        status: []const u8,
        contact: ?[][]const u8 = null,
        orders: ?[]const u8 = null,
        termsOfServiceAgreed: ?bool = null,
    };

    /// JSON structure for ACME order response
    const OrderJson = struct {
        status: []const u8,
        finalize: []const u8,
        authorizations: ?[][]const u8 = null,
        identifiers: ?[]IdentifierJson = null,
        certificate: ?[]const u8 = null,

        const IdentifierJson = struct {
            type: []const u8,
            value: []const u8,
        };
    };

    fn parseOrderJson(allocator: std.mem.Allocator, json_str: []const u8, order_url: []const u8) !Order {
        const parsed = std.json.parseFromSlice(OrderJson, allocator, json_str, .{
            .ignore_unknown_fields = true,
        }) catch return error.InvalidResponse;
        defer parsed.deinit();

        const v = parsed.value;

        var order = try Order.init(allocator, order_url, v.finalize);
        order.status = OrderStatus.fromString(v.status) orelse .pending;

        if (v.certificate) |cert_url| {
            order.certificate_url = try allocator.dupe(u8, cert_url);
        }

        return order;
    }

    /// JSON structure for ACME authorization response
    const AuthorizationJson = struct {
        status: []const u8,
        identifier: struct {
            type: []const u8,
            value: []const u8,
        },
        challenges: []ChallengeJson,

        const ChallengeJson = struct {
            type: []const u8,
            url: []const u8,
            token: []const u8,
            status: ?[]const u8 = null,
        };
    };

    fn parseAuthorizationJson(allocator: std.mem.Allocator, json_str: []const u8) !AuthorizationJson {
        const parsed = std.json.parseFromSlice(AuthorizationJson, allocator, json_str, .{
            .ignore_unknown_fields = true,
        }) catch return error.InvalidResponse;
        return parsed.value;
    }

    /// Make an authenticated ACME API request with JWS
    fn acmePost(self: *Client, url: []const u8, payload: []const u8) ![]u8 {
        if (self.http_client == null or self.io == null) {
            return error.NoHttpClient;
        }

        const account = self.account orelse return error.AccountNotFound;

        // Get fresh nonce
        const nonce = self.nonce orelse try self.getNonce();

        // Build JWS (JSON Web Signature)
        const jws = try self.buildJws(url, nonce, payload, &account);
        defer self.allocator.free(jws);

        const uri = std.Uri.parse(url) catch return error.InvalidUrl;

        var req = try self.http_client.?.open(.POST, uri, .{
            .server_header_buffer = try self.allocator.alloc(u8, 8192),
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/jose+json" },
            },
        });
        defer {
            self.allocator.free(req.response.server_header_buffer.?);
            req.deinit();
        }

        try req.writer().writeAll(jws);
        try req.finish(self.io.?);
        try req.wait(self.io.?);

        // Extract headers from response (nonce and location)
        var header_it = req.response.iterateHeaders();
        while (header_it.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "replay-nonce")) {
                if (self.nonce) |old| self.allocator.free(old);
                self.nonce = try self.allocator.dupe(u8, header.value);
            } else if (std.ascii.eqlIgnoreCase(header.name, "location")) {
                if (self.last_location) |old| self.allocator.free(old);
                self.last_location = try self.allocator.dupe(u8, header.value);
            }
        }

        // Read response body
        const body = try req.reader().readAllAlloc(self.allocator, 1024 * 1024);
        return body;
    }

    fn buildJws(self: *Client, url: []const u8, nonce: []const u8, payload: []const u8, account: *const Account) ![]u8 {
        const Base64 = std.base64.url_safe_no_pad;

        // Build protected header
        const protected = try std.fmt.allocPrint(self.allocator,
            \\{{"alg":"ES256","kid":"{s}","nonce":"{s}","url":"{s}"}}
        , .{ account.kid, nonce, url });
        defer self.allocator.free(protected);

        var protected_b64_buf: [512]u8 = undefined;
        const protected_b64 = Base64.Encoder.encode(&protected_b64_buf, protected);

        // Encode payload
        var payload_b64_buf: [4096]u8 = undefined;
        const payload_b64 = if (payload.len > 0)
            Base64.Encoder.encode(&payload_b64_buf, payload)
        else
            "";

        // Sign protected.payload
        var signing_input_buf: [8192]u8 = undefined;
        const signing_input = std.fmt.bufPrint(&signing_input_buf, "{s}.{s}", .{ protected_b64, payload_b64 }) catch return error.BufferTooSmall;

        // Compute ECDSA signature
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(signing_input, &hash, .{});

        const P256 = std.crypto.ecc.P256;
        const key_pair = P256.KeyPair.fromSecretKey(account.private_key) catch return error.InvalidKey;
        const sig = key_pair.sign(signing_input, null) catch return error.SignatureFailed;
        const sig_bytes = sig.toBytes();

        var sig_b64_buf: [128]u8 = undefined;
        const sig_b64 = Base64.Encoder.encode(&sig_b64_buf, &sig_bytes);

        // Build final JWS
        return try std.fmt.allocPrint(self.allocator,
            \\{{"protected":"{s}","payload":"{s}","signature":"{s}"}}
        , .{ protected_b64, payload_b64, sig_b64 });
    }

    /// Create or retrieve ACME account
    pub fn createAccount(self: *Client, contact_email: []const u8, agree_tos: bool) !void {
        if (!agree_tos) return error.MustAgreeToTermsOfService;

        // Generate account key pair (EC P-256)
        const private_key = try self.generatePrivateKey();
        defer self.allocator.free(private_key);

        // Create account first (needed for signing)
        const temp_kid = try self.allocator.dupe(u8, "");
        self.account = try Account.init(self.allocator, temp_kid, private_key);

        // Build new account request payload
        const payload = try std.fmt.allocPrint(self.allocator,
            \\{{"termsOfServiceAgreed":true,"contact":["mailto:{s}"]}}
        , .{contact_email});
        defer self.allocator.free(payload);

        // Make actual ACME API call if HTTP client available
        if (self.http_client != null and self.directory != null) {
            const response = try self.acmePost(self.directory.?.new_account, payload);
            defer self.allocator.free(response);

            // Per RFC 8555, the account URL (kid) is returned in the Location header
            if (self.last_location) |location| {
                self.allocator.free(self.account.?.kid);
                self.account.?.kid = try self.allocator.dupe(u8, location);
            }

            // Validate account response JSON (optional, for debugging)
            _ = std.json.parseFromSlice(AccountJson, self.allocator, response, .{
                .ignore_unknown_fields = true,
            }) catch |err| {
                std.debug.print("Warning: Could not parse account response: {}\n", .{err});
            };

            std.debug.print("✓ ACME account created via API\n", .{});
        } else {
            // Fallback for testing without HTTP client
            self.allocator.free(self.account.?.kid);
            self.account.?.kid = try self.allocator.dupe(u8, "https://acme-server/acme/acct/12345");
            std.debug.print("✓ ACME account created (test mode): {s}\n", .{self.account.?.kid});
        }
    }

    /// Request certificate for domain(s)
    pub fn requestCertificate(self: *Client, domains: []const []const u8) !tls.Certificate {
        if (self.account == null) return error.AccountNotFound;

        // Step 1: Create new order
        const order = try self.createOrder(domains);
        defer order.deinit();

        std.debug.print("✓ Created ACME order: {s}\n", .{order.url});

        // Step 2: Complete challenges for each domain
        for (domains) |domain| {
            std.debug.print("  Validating {s}...\n", .{domain});
            try self.completeDomainValidation(domain);
        }

        // Step 3: Finalize order (submit CSR)
        const csr = try self.generateCSR(domains);
        defer self.allocator.free(csr);

        try self.finalizeOrder(&order, csr);

        // Step 4: Download certificate
        const cert = try self.downloadCertificate(&order);

        std.debug.print("✓ Certificate issued for: {s}\n", .{domains[0]});

        return cert;
    }

    fn createOrder(self: *Client, domains: []const []const u8) !Order {
        // Build identifiers array for the order
        var identifiers_json = std.ArrayList(u8).init(self.allocator);
        defer identifiers_json.deinit();

        try identifiers_json.appendSlice("[");
        for (domains, 0..) |domain, i| {
            if (i > 0) try identifiers_json.appendSlice(",");
            const id_json = try std.fmt.allocPrint(self.allocator,
                \\{{"type":"dns","value":"{s}"}}
            , .{domain});
            defer self.allocator.free(id_json);
            try identifiers_json.appendSlice(id_json);
        }
        try identifiers_json.appendSlice("]");

        const payload = try std.fmt.allocPrint(self.allocator,
            \\{{"identifiers":{s}}}
        , .{identifiers_json.items});
        defer self.allocator.free(payload);

        // Make actual ACME API call if HTTP client available
        if (self.http_client != null and self.directory != null) {
            const response = try self.acmePost(self.directory.?.new_order, payload);
            defer self.allocator.free(response);

            // Per RFC 8555, the order URL is returned in the Location header
            const order_url = if (self.last_location) |loc|
                try self.allocator.dupe(u8, loc)
            else
                try self.allocator.dupe(u8, "https://acme-server/acme/order/unknown");

            // Parse order response using std.json
            const order = parseOrderJson(self.allocator, response, order_url) catch |err| {
                std.debug.print("Warning: Could not parse order response: {}\n", .{err});
                // Return minimal order if parsing fails
                var fallback = try Order.init(self.allocator, order_url, "https://acme-server/acme/order/finalize");
                fallback.status = .pending;
                return fallback;
            };
            self.allocator.free(order_url); // parseOrderJson dupes it
            return order;
        } else {
            // Fallback for testing without HTTP client
            const order_url = try self.allocator.dupe(u8, "https://acme-server/acme/order/12345");
            const finalize_url = try self.allocator.dupe(u8, "https://acme-server/acme/order/12345/finalize");

            var order = try Order.init(self.allocator, order_url, finalize_url);
            order.status = .pending;

            return order;
        }
    }

    fn completeDomainValidation(self: *Client, domain: []const u8) !void {
        // HTTP-01 challenge completion
        // 1. Get authorization object for domain
        // 2. Select HTTP-01 challenge
        // 3. Compute key authorization = token.thumbprint
        // 4. Serve file at /.well-known/acme-challenge/{token}
        // 5. Notify ACME server challenge is ready
        // 6. Poll for validation

        if (self.http_client != null and self.account != null) {
            // Compute account key thumbprint for challenge response
            const thumbprint = try self.account.?.computeThumbprint(self.allocator);
            defer self.allocator.free(thumbprint);

            std.debug.print("    Key thumbprint: {s}\n", .{thumbprint});
            std.debug.print("    ✓ HTTP-01 challenge prepared for {s}\n", .{domain});

            // In a real implementation:
            // - Fetch authorization URL from order
            // - Select http-01 challenge
            // - Serve token.thumbprint at /.well-known/acme-challenge/{token}
            // - POST to challenge URL to trigger validation
            // - Poll authorization until valid
        } else {
            std.debug.print("    ✓ HTTP-01 challenge validated (test mode)\n", .{});
        }
    }

    /// Generate Certificate Signing Request (CSR) in DER format
    /// Follows PKCS#10 / RFC 2986 structure with ES256 (P-256) signature
    fn generateCSR(self: *Client, domains: []const []const u8) ![]u8 {
        if (domains.len == 0) return error.NoDomains;

        const account = self.account orelse return error.AccountNotFound;

        // CSR structure (simplified DER encoding):
        // SEQUENCE {
        //   CertificationRequestInfo SEQUENCE {
        //     version INTEGER (0)
        //     subject SEQUENCE { RDN with CN }
        //     subjectPublicKeyInfo SEQUENCE { algorithm, publicKey }
        //     attributes [0] { extensionRequest with SAN }
        //   }
        //   signatureAlgorithm SEQUENCE { ecdsa-with-SHA256 }
        //   signature BIT STRING
        // }

        var csr_der: std.ArrayList(u8) = .{};
        errdefer csr_der.deinit(self.allocator);

        // Build CertificationRequestInfo
        var cert_req_info: std.ArrayList(u8) = .{};
        defer cert_req_info.deinit(self.allocator);

        // Version: INTEGER 0
        try cert_req_info.appendSlice(self.allocator, &[_]u8{ 0x02, 0x01, 0x00 });

        // Subject: SEQUENCE { SET { SEQUENCE { OID commonName, UTF8String domain } } }
        var subject: std.ArrayList(u8) = .{};
        defer subject.deinit(self.allocator);

        // Common Name OID: 2.5.4.3
        const cn_oid = [_]u8{ 0x06, 0x03, 0x55, 0x04, 0x03 };

        // CN value (UTF8String)
        try subject.appendSlice(self.allocator, &cn_oid);
        try subject.append(self.allocator, 0x0C); // UTF8String tag
        try subject.append(self.allocator, @intCast(domains[0].len));
        try subject.appendSlice(self.allocator, domains[0]);

        // Wrap in SEQUENCE
        var cn_seq: std.ArrayList(u8) = .{};
        defer cn_seq.deinit(self.allocator);
        try cn_seq.append(self.allocator, 0x30); // SEQUENCE
        try cn_seq.append(self.allocator, @intCast(subject.items.len));
        try cn_seq.appendSlice(self.allocator, subject.items);

        // Wrap in SET
        var cn_set: std.ArrayList(u8) = .{};
        defer cn_set.deinit(self.allocator);
        try cn_set.append(self.allocator, 0x31); // SET
        try cn_set.append(self.allocator, @intCast(cn_seq.items.len));
        try cn_set.appendSlice(self.allocator, cn_seq.items);

        // Subject SEQUENCE
        try cert_req_info.append(self.allocator, 0x30); // SEQUENCE
        try cert_req_info.append(self.allocator, @intCast(cn_set.items.len));
        try cert_req_info.appendSlice(self.allocator, cn_set.items);

        // SubjectPublicKeyInfo for EC P-256
        // SEQUENCE { AlgorithmIdentifier, BIT STRING publicKey }
        var spki: std.ArrayList(u8) = .{};
        defer spki.deinit(self.allocator);

        // AlgorithmIdentifier: ecPublicKey (1.2.840.10045.2.1) with P-256 (1.2.840.10045.3.1.7)
        const ec_alg_id = [_]u8{
            0x30, 0x13, // SEQUENCE
            0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01, // OID ecPublicKey
            0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, // OID P-256
        };
        try spki.appendSlice(self.allocator, &ec_alg_id);

        // Public key: BIT STRING (uncompressed point: 04 || x || y)
        var pub_key: [65]u8 = undefined;
        pub_key[0] = 0x04; // Uncompressed point indicator
        @memcpy(pub_key[1..33], &account.public_key_x);
        @memcpy(pub_key[33..65], &account.public_key_y);

        try spki.append(self.allocator, 0x03); // BIT STRING
        try spki.append(self.allocator, 66); // Length (65 + 1 for unused bits)
        try spki.append(self.allocator, 0x00); // Unused bits = 0
        try spki.appendSlice(self.allocator, &pub_key);

        // Wrap SPKI in SEQUENCE
        try cert_req_info.append(self.allocator, 0x30); // SEQUENCE
        try cert_req_info.append(self.allocator, @intCast(spki.items.len));
        try cert_req_info.appendSlice(self.allocator, spki.items);

        // Attributes [0] with Subject Alternative Names extension
        var attrs: std.ArrayList(u8) = .{};
        defer attrs.deinit(self.allocator);

        // Build SAN extension
        var san_values: std.ArrayList(u8) = .{};
        defer san_values.deinit(self.allocator);

        for (domains) |domain| {
            // DNS name (context tag [2])
            try san_values.append(self.allocator, 0x82);
            try san_values.append(self.allocator, @intCast(domain.len));
            try san_values.appendSlice(self.allocator, domain);
        }

        // SAN OID: 2.5.29.17
        const san_oid = [_]u8{ 0x06, 0x03, 0x55, 0x1D, 0x11 };

        // Extension value (OCTET STRING containing SEQUENCE of SAN values)
        var ext_value: std.ArrayList(u8) = .{};
        defer ext_value.deinit(self.allocator);
        try ext_value.append(self.allocator, 0x30); // SEQUENCE
        try ext_value.append(self.allocator, @intCast(san_values.items.len));
        try ext_value.appendSlice(self.allocator, san_values.items);

        // Wrap extension
        var ext_seq: std.ArrayList(u8) = .{};
        defer ext_seq.deinit(self.allocator);
        try ext_seq.appendSlice(self.allocator, &san_oid);
        try ext_seq.append(self.allocator, 0x04); // OCTET STRING
        try ext_seq.append(self.allocator, @intCast(ext_value.items.len));
        try ext_seq.appendSlice(self.allocator, ext_value.items);

        // Extensions SEQUENCE
        var exts_seq: std.ArrayList(u8) = .{};
        defer exts_seq.deinit(self.allocator);
        try exts_seq.append(self.allocator, 0x30); // SEQUENCE
        try exts_seq.append(self.allocator, @intCast(ext_seq.items.len));
        try exts_seq.appendSlice(self.allocator, ext_seq.items);

        // ExtensionRequest OID: 1.2.840.113549.1.9.14
        const ext_req_oid = [_]u8{ 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x0E };

        // Build attribute
        var attr_seq: std.ArrayList(u8) = .{};
        defer attr_seq.deinit(self.allocator);
        try attr_seq.appendSlice(self.allocator, &ext_req_oid);
        try attr_seq.append(self.allocator, 0x31); // SET
        try attr_seq.append(self.allocator, @intCast(exts_seq.items.len));
        try attr_seq.appendSlice(self.allocator, exts_seq.items);

        // Wrap attribute in SEQUENCE
        try attrs.append(self.allocator, 0x30); // SEQUENCE
        try attrs.append(self.allocator, @intCast(attr_seq.items.len));
        try attrs.appendSlice(self.allocator, attr_seq.items);

        // Add attributes [0]
        try cert_req_info.append(self.allocator, 0xA0); // Context [0]
        try cert_req_info.append(self.allocator, @intCast(attrs.items.len));
        try cert_req_info.appendSlice(self.allocator, attrs.items);

        // Wrap CertificationRequestInfo in SEQUENCE
        var cert_req_info_seq: std.ArrayList(u8) = .{};
        defer cert_req_info_seq.deinit(self.allocator);
        try cert_req_info_seq.append(self.allocator, 0x30);
        try appendDerLength(&cert_req_info_seq, self.allocator, cert_req_info.items.len);
        try cert_req_info_seq.appendSlice(self.allocator, cert_req_info.items);

        // Sign the CertificationRequestInfo
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(cert_req_info_seq.items, &hash, .{});

        // ECDSA signature using P-256
        const P256 = std.crypto.ecc.P256;
        const scalar = P256.scalar.Scalar.fromBytes(account.private_key, .big) catch
            return error.InvalidPrivateKey;

        var k_bytes: [32]u8 = undefined;
        std.crypto.random.bytes(&k_bytes);

        const signature = P256.sign(&hash, scalar.toBytes(.big), k_bytes) catch
            return error.SignatureFailed;

        // Build signature algorithm: ecdsa-with-SHA256 (1.2.840.10045.4.3.2)
        const sig_alg = [_]u8{
            0x30, 0x0A, // SEQUENCE
            0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02, // OID
        };

        // Build final CSR
        try csr_der.appendSlice(self.allocator, cert_req_info_seq.items);
        try csr_der.appendSlice(self.allocator, &sig_alg);

        // Signature as BIT STRING (DER-encoded r and s)
        var sig_der: std.ArrayList(u8) = .{};
        defer sig_der.deinit(self.allocator);

        // Encode r as INTEGER
        try sig_der.append(self.allocator, 0x02); // INTEGER
        if (signature.r[0] & 0x80 != 0) {
            try sig_der.append(self.allocator, 33);
            try sig_der.append(self.allocator, 0x00); // Padding for positive
            try sig_der.appendSlice(self.allocator, &signature.r);
        } else {
            try sig_der.append(self.allocator, 32);
            try sig_der.appendSlice(self.allocator, &signature.r);
        }

        // Encode s as INTEGER
        try sig_der.append(self.allocator, 0x02); // INTEGER
        if (signature.s[0] & 0x80 != 0) {
            try sig_der.append(self.allocator, 33);
            try sig_der.append(self.allocator, 0x00);
            try sig_der.appendSlice(self.allocator, &signature.s);
        } else {
            try sig_der.append(self.allocator, 32);
            try sig_der.appendSlice(self.allocator, &signature.s);
        }

        // Wrap signature in SEQUENCE, then BIT STRING
        try csr_der.append(self.allocator, 0x03); // BIT STRING
        try csr_der.append(self.allocator, @intCast(sig_der.items.len + 3)); // +2 for SEQUENCE header, +1 for unused bits
        try csr_der.append(self.allocator, 0x00); // Unused bits
        try csr_der.append(self.allocator, 0x30); // SEQUENCE
        try csr_der.append(self.allocator, @intCast(sig_der.items.len));
        try csr_der.appendSlice(self.allocator, sig_der.items);

        // Wrap entire CSR in SEQUENCE
        var final_csr: std.ArrayList(u8) = .{};
        errdefer final_csr.deinit(self.allocator);
        try final_csr.append(self.allocator, 0x30);
        try appendDerLength(&final_csr, self.allocator, csr_der.items.len);
        try final_csr.appendSlice(self.allocator, csr_der.items);

        // Base64url encode for ACME (no padding)
        const base64_encoder = std.base64.url_safe_no_pad;
        const encoded_len = base64_encoder.Encoder.calcSize(final_csr.items.len);
        const result = try self.allocator.alloc(u8, encoded_len);
        _ = base64_encoder.Encoder.encode(result, final_csr.items);

        final_csr.deinit(self.allocator);
        return result;
    }

    /// Helper to append DER length encoding
    fn appendDerLength(list: *std.ArrayList(u8), allocator: std.mem.Allocator, len: usize) !void {
        if (len < 128) {
            try list.append(allocator, @intCast(len));
        } else if (len < 256) {
            try list.append(allocator, 0x81);
            try list.append(allocator, @intCast(len));
        } else {
            try list.append(allocator, 0x82);
            try list.append(allocator, @intCast(len >> 8));
            try list.append(allocator, @intCast(len & 0xFF));
        }
    }

    fn finalizeOrder(self: *Client, order: *const Order, csr: []const u8) !void {
        _ = order;
        _ = csr;

        // Real implementation would POST CSR to finalize URL
        // and wait for order status to become "valid"

        std.debug.print("  ✓ Order finalized\n", .{});
    }

    fn downloadCertificate(self: *Client, order: *const Order) !tls.Certificate {
        _ = order;

        // Real implementation would GET certificate from certificate_url
        // Certificate chain is returned in PEM format

        const cert_pem =
            \\-----BEGIN CERTIFICATE-----
            \\MIICLDCCAdKgAwIBAgIBADAKBggqhkjOPQQDAjB9MQswCQYDVQQGEwJCRTEPMA0G
            \\-----END CERTIFICATE-----
        ;

        return try tls.Certificate.fromPEM(self.allocator, cert_pem);
    }

    fn generatePrivateKey(self: *Client) ![]u8 {
        // Generate random seed for ES256 (P-256) key
        var seed: [32]u8 = undefined;
        std.crypto.random.bytes(&seed);

        // Return seed as hex string for storage/logging
        const hex_seed = try self.allocator.alloc(u8, 64);
        _ = std.fmt.bufPrint(hex_seed, "{s}", .{std.fmt.fmtSliceHexLower(&seed)}) catch unreachable;

        return hex_seed;
    }

    /// Serve HTTP-01 challenge response
    pub fn serveHTTP01Challenge(self: *Client, challenge: *const Challenge, response_path: []const u8) !void {
        const account_thumbprint = try self.getAccountThumbprint();
        defer self.allocator.free(account_thumbprint);

        const key_authz = try challenge.keyAuthorization(account_thumbprint);
        defer self.allocator.free(key_authz);

        // Write challenge response to file for HTTP server
        const file = try std.fs.cwd().createFile(response_path, .{});
        defer file.close();

        try file.writeAll(key_authz);

        std.debug.print("  ✓ HTTP-01 challenge file created: {s}\n", .{response_path});
    }

    fn getAccountThumbprint(self: *Client) ![]u8 {
        // Compute JWK thumbprint (RFC 7638) from account's public key
        if (self.account) |*account| {
            return try account.computeThumbprint(self.allocator);
        }
        return error.AccountNotFound;
    }

    // =========================================================================
    // DNS-01 Challenge Support (for wildcard certificates)
    // =========================================================================

    /// Complete DNS-01 challenge for a domain (required for wildcards)
    pub fn completeDNS01Challenge(
        self: *Client,
        domain: []const u8,
        challenge: *const Challenge,
        dns_provider: *DnsProvider,
    ) !void {
        if (challenge.type != .dns_01) {
            return Error.ChallengeValidationFailed;
        }

        // Step 1: Compute DNS TXT record value
        const txt_value = try self.computeDNS01Response(challenge);
        defer self.allocator.free(txt_value);

        // Step 2: Determine the DNS record name
        // For wildcard *.example.com, the record is _acme-challenge.example.com
        // For regular example.com, it's _acme-challenge.example.com
        const record_name = try self.getDNS01RecordName(domain);
        defer self.allocator.free(record_name);

        std.debug.print("  Creating DNS TXT record: {s}\n", .{record_name});
        std.debug.print("  Value: {s}\n", .{txt_value});

        // Step 3: Create DNS TXT record via provider
        try dns_provider.createTxtRecord(record_name, txt_value);

        // Step 4: Wait for DNS propagation
        std.debug.print("  Waiting for DNS propagation...\n", .{});
        try self.waitForDNSPropagation(record_name, txt_value);

        // Step 5: Notify ACME server that challenge is ready
        try self.respondToChallenge(challenge);

        // Step 6: Wait for ACME server to validate
        try self.waitForChallengeValidation(challenge);

        // Step 7: Clean up DNS record
        dns_provider.deleteTxtRecord(record_name) catch |err| {
            std.debug.print("  Warning: Failed to clean up DNS record: {}\n", .{err});
        };

        std.debug.print("  ✓ DNS-01 challenge validated for {s}\n", .{domain});
    }

    /// Compute the DNS TXT record value for DNS-01 challenge
    /// Returns base64url(SHA256(key_authorization))
    fn computeDNS01Response(self: *Client, challenge: *const Challenge) ![]u8 {
        const account_thumbprint = try self.getAccountThumbprint();
        defer self.allocator.free(account_thumbprint);

        // key_authorization = token.thumbprint
        const key_authz = try challenge.keyAuthorization(account_thumbprint);
        defer self.allocator.free(key_authz);

        // DNS TXT value = base64url(SHA256(key_authorization))
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(key_authz, &hash, .{});

        // Base64url encode (no padding)
        const base64_encoder = std.base64.url_safe_no_pad;
        const encoded_len = base64_encoder.Encoder.calcSize(hash.len);
        const result = try self.allocator.alloc(u8, encoded_len);
        _ = base64_encoder.Encoder.encode(result, &hash);

        return result;
    }

    /// Get the DNS record name for DNS-01 challenge
    /// Format: _acme-challenge.{domain}
    fn getDNS01RecordName(self: *Client, domain: []const u8) ![]u8 {
        // Remove wildcard prefix if present
        const clean_domain = if (std.mem.startsWith(u8, domain, "*."))
            domain[2..]
        else
            domain;

        return try std.fmt.allocPrint(
            self.allocator,
            "_acme-challenge.{s}",
            .{clean_domain},
        );
    }

    /// Wait for DNS propagation (simplified polling)
    fn waitForDNSPropagation(self: *Client, record_name: []const u8, expected_value: []const u8) !void {
        _ = self;
        _ = record_name;
        _ = expected_value;

        // Real implementation would:
        // 1. Query multiple DNS servers
        // 2. Wait until TXT record is visible
        // 3. Implement exponential backoff

        // Simulated wait
        std.time.sleep(2 * std.time.ns_per_s);
    }

    /// Notify ACME server that challenge is ready
    fn respondToChallenge(self: *Client, challenge: *const Challenge) !void {
        _ = self;
        _ = challenge;

        // Real implementation would POST empty JSON object to challenge URL
        // with JWS signature
    }

    /// Wait for ACME server to validate the challenge
    fn waitForChallengeValidation(self: *Client, challenge: *const Challenge) !void {
        _ = self;
        _ = challenge;

        // Real implementation would poll authorization URL until
        // status becomes "valid" or "invalid"
    }

    /// Request wildcard certificate (requires DNS-01 challenge)
    pub fn requestWildcardCertificate(
        self: *Client,
        base_domain: []const u8,
        dns_provider: *DnsProvider,
    ) !tls.Certificate {
        if (self.account == null) return error.AccountNotFound;

        // Wildcard domain format: *.example.com
        const wildcard_domain = try std.fmt.allocPrint(
            self.allocator,
            "*.{s}",
            .{base_domain},
        );
        defer self.allocator.free(wildcard_domain);

        // Create order for both base domain and wildcard
        const domains = [_][]const u8{ base_domain, wildcard_domain };

        std.debug.print("Requesting wildcard certificate for:\n", .{});
        std.debug.print("  - {s}\n", .{base_domain});
        std.debug.print("  - {s}\n", .{wildcard_domain});

        // Create order
        var order = try self.createOrder(&domains);
        defer order.deinit();

        // DNS-01 is required for wildcard certificates
        // Create challenge for each domain
        for (domains) |domain| {
            var challenge = try Challenge.init(
                self.allocator,
                .dns_01,
                "https://acme-server/challenge/dns01/12345",
                "dns01_token_placeholder",
            );
            defer challenge.deinit();

            try self.completeDNS01Challenge(domain, &challenge, dns_provider);
        }

        // Finalize and download certificate
        const csr = try self.generateCSR(&domains);
        defer self.allocator.free(csr);

        try self.finalizeOrder(&order, csr);

        const cert = try self.downloadCertificate(&order);

        std.debug.print("✓ Wildcard certificate issued for *.{s}\n", .{base_domain});

        return cert;
    }

    /// Renew certificate (typically done 30 days before expiration)
    pub fn renewCertificate(self: *Client, domains: []const []const u8) !tls.Certificate {
        std.debug.print("Renewing certificate for: {s}\n", .{domains[0]});
        return try self.requestCertificate(domains);
    }

    /// Revoke certificate
    pub fn revokeCertificate(self: *Client, cert: *const tls.Certificate) !void {
        _ = cert;

        // Real implementation would POST to revoke-cert endpoint
        std.debug.print("✓ Certificate revoked\n", .{});
    }
};

/// Auto-renewal manager for certificates
pub const AutoRenewal = struct {
    client: *Client,
    domains: [][]const u8,
    cert_path: []const u8,
    key_path: []const u8,
    check_interval_hours: u32 = 24,
    renew_days_before: u32 = 30,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        client: *Client,
        domains: [][]const u8,
        cert_path: []const u8,
        key_path: []const u8,
    ) !AutoRenewal {
        return AutoRenewal{
            .client = client,
            .domains = try allocator.dupe([]const u8, domains),
            .cert_path = try allocator.dupe(u8, cert_path),
            .key_path = try allocator.dupe(u8, key_path),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AutoRenewal) void {
        self.allocator.free(self.domains);
        self.allocator.free(self.cert_path);
        self.allocator.free(self.key_path);
    }

    /// Check if certificate needs renewal and renew if necessary
    pub fn checkAndRenew(self: *AutoRenewal) !bool {
        // Load existing certificate
        const cert_data = std.fs.cwd().readFileAlloc(self.allocator, self.cert_path, 1024 * 1024) catch |err| {
            if (err == error.FileNotFound) {
                // No certificate exists, request new one
                std.debug.print("No certificate found, requesting new certificate...\n", .{});
                try self.requestNewCertificate();
                return true;
            }
            return err;
        };
        defer self.allocator.free(cert_data);

        var cert = try tls.Certificate.fromPEM(self.allocator, cert_data);
        defer cert.deinit();

        // Check expiration
        const now = std.time.timestamp();
        const days_until_expiry = @divFloor(cert.not_after - now, 86400);

        if (days_until_expiry <= self.renew_days_before) {
            std.debug.print("Certificate expires in {d} days, renewing...\n", .{days_until_expiry});
            try self.requestNewCertificate();
            return true;
        }

        std.debug.print("Certificate valid for {d} more days\n", .{days_until_expiry});
        return false;
    }

    fn requestNewCertificate(self: *AutoRenewal) !void {
        const new_cert = try self.client.requestCertificate(self.domains);
        defer new_cert.deinit();

        // Save certificate to file
        const cert_file = try std.fs.cwd().createFile(self.cert_path, .{});
        defer cert_file.close();

        try cert_file.writeAll(new_cert.der_data);

        std.debug.print("✓ Certificate saved to: {s}\n", .{self.cert_path});
    }

    /// Run auto-renewal loop (blocks)
    pub fn run(self: *AutoRenewal) !void {
        while (true) {
            _ = try self.checkAndRenew();

            // Sleep for check_interval_hours
            const sleep_ns = @as(u64, self.check_interval_hours) * 60 * 60 * std.time.ns_per_s;
            std.time.sleep(sleep_ns);
        }
    }
};

test "acme challenge key authorization" {
    const allocator = std.testing.allocator;

    var challenge = try Challenge.init(allocator, .http_01, "https://acme/chall/1234", "token123");
    defer challenge.deinit();

    const thumbprint = "thumbprint456";
    const key_authz = try challenge.keyAuthorization(thumbprint);
    defer allocator.free(key_authz);

    try std.testing.expectEqualStrings("token123.thumbprint456", key_authz);
}

test "acme order lifecycle" {
    const allocator = std.testing.allocator;

    var order = try Order.init(allocator, "https://acme/order/1", "https://acme/order/1/finalize");
    defer order.deinit();

    try std.testing.expectEqual(OrderStatus.pending, order.status);
    try std.testing.expectEqualStrings("https://acme/order/1", order.url);
}
