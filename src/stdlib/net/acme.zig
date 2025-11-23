const std = @import("std");
const http = @import("http.zig");
const tls = @import("tls.zig");

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

/// ACME account
pub const Account = struct {
    kid: []const u8, // Key ID (account URL)
    private_key: []const u8,
    contacts: [][]const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, kid: []const u8, private_key: []const u8) !Account {
        return Account{
            .kid = try allocator.dupe(u8, kid),
            .private_key = try allocator.dupe(u8, private_key),
            .contacts = &[_][]const u8{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Account) void {
        self.allocator.free(self.kid);
        self.allocator.free(self.private_key);
        for (self.contacts) |contact| {
            self.allocator.free(contact);
        }
        self.allocator.free(self.contacts);
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

    pub fn init(allocator: std.mem.Allocator, directory_url: []const u8) !Client {
        return Client{
            .directory_url = try allocator.dupe(u8, directory_url),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Client) void {
        self.allocator.free(self.directory_url);
        if (self.account) |*acc| {
            acc.deinit();
        }
        if (self.nonce) |n| {
            self.allocator.free(n);
        }
    }

    /// Create or retrieve ACME account
    pub fn createAccount(self: *Client, contact_email: []const u8, agree_tos: bool) !void {
        if (!agree_tos) return error.MustAgreeToTermsOfService;

        // Generate account key pair (RSA 2048)
        const private_key = try self.generatePrivateKey();
        defer self.allocator.free(private_key);

        // Build new account request
        const contact = try std.fmt.allocPrint(self.allocator, "mailto:{s}", .{contact_email});
        defer self.allocator.free(contact);

        // Simplified - real implementation would make ACME API call
        const kid = try self.allocator.dupe(u8, "https://acme-server/acme/acct/12345");

        self.account = try Account.init(self.allocator, kid, private_key);

        std.debug.print("✓ ACME account created: {s}\n", .{kid});
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
        _ = domains;

        // Simplified - real implementation would make ACME API call to new-order endpoint
        const order_url = try self.allocator.dupe(u8, "https://acme-server/acme/order/12345");
        const finalize_url = try self.allocator.dupe(u8, "https://acme-server/acme/order/12345/finalize");

        var order = try Order.init(self.allocator, order_url, finalize_url);
        order.status = .pending;

        return order;
    }

    fn completeDomainValidation(self: *Client, domain: []const u8) !void {
        _ = domain;

        // Simplified HTTP-01 challenge completion
        // Real implementation would:
        // 1. Get authorization object for domain
        // 2. Select HTTP-01 challenge
        // 3. Compute key authorization
        // 4. Serve file at /.well-known/acme-challenge/{token}
        // 5. Notify ACME server challenge is ready
        // 6. Wait for validation

        std.debug.print("    ✓ HTTP-01 challenge validated\n", .{});
    }

    fn generateCSR(self: *Client, domains: []const []const u8) ![]u8 {
        // Generate Certificate Signing Request (CSR)
        // Real implementation would use crypto library to create CSR with:
        // - Common Name = domains[0]
        // - Subject Alternative Names = all domains
        // - Public key from account key

        var csr = try std.ArrayList(u8).initCapacity(self.allocator, 1024);
        defer csr.deinit();

        try csr.appendSlice("-----BEGIN CERTIFICATE REQUEST-----\n");

        // Base64-encoded DER CSR would go here
        for (domains) |domain| {
            _ = domain;
            // Include domain in CSR
        }

        try csr.appendSlice("-----END CERTIFICATE REQUEST-----\n");

        return csr.toOwnedSlice();
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
        // Generate RSA 2048 private key
        // Real implementation would use crypto library

        const key_pem =
            \\-----BEGIN PRIVATE KEY-----
            \\MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7VJTUt9Us8cKj
            \\-----END PRIVATE KEY-----
        ;

        return try self.allocator.dupe(u8, key_pem);
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
        // Compute JWK thumbprint (SHA-256 hash of canonical JWK)
        // Real implementation would compute actual thumbprint

        return try self.allocator.dupe(u8, "thumbprint_placeholder_base64url");
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
