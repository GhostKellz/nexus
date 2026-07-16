const std = @import("std");

/// File system access policy
pub const FsPolicy = union(enum) {
    none: void,
    read_only: []const u8, // Directory path
    read_write: []const u8, // Directory path

    pub fn allows(self: FsPolicy, path: []const u8, write: bool) bool {
        return switch (self) {
            .none => false,
            .read_only => |dir| !write and pathConfined(dir, path),
            .read_write => |dir| pathConfined(dir, path),
        };
    }
};

/// Maximum path depth the sandbox confinement check will canonicalize. Real
/// paths are far shallower; anything deeper is rejected (fail-closed) rather
/// than risking unbounded work from a hostile path.
const max_path_components = 256;

/// Lexically normalize an absolute POSIX path into its surviving components,
/// resolving "." (dropped), ".." (pops the previous component), and collapsed
/// or trailing separators. Component slices are written into `out`; returns how
/// many survive, or null if the path is not absolute, tries to escape above the
/// filesystem root via "..", or exceeds `max_path_components`.
///
/// This is purely lexical — it never touches the filesystem and so does not
/// resolve symlinks. Symlink confinement is enforced separately at the
/// WASI/preopen layer; here we only defeat prefix-sibling matches
/// ("/allowed-evil" vs "/allowed"), "..", ".", and duplicate separators. On
/// POSIX only '/' separates, so a backslash is an ordinary filename byte and a
/// component containing it simply fails to match a legitimate directory name.
fn normalizeAbsolute(path: []const u8, out: *[max_path_components][]const u8) ?usize {
    if (path.len == 0 or path[0] != '/') return null; // must be absolute
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |comp| {
        if (std.mem.eql(u8, comp, ".")) continue;
        if (std.mem.eql(u8, comp, "..")) {
            if (n == 0) return null; // escapes above the root
            n -= 1;
            continue;
        }
        if (n >= max_path_components) return null;
        out[n] = comp;
        n += 1;
    }
    return n;
}

/// True if `path` is lexically confined within `dir`: after normalizing both,
/// the candidate must equal `dir` or lie beneath it on a component boundary.
/// A non-absolute path, an above-root escape, or an over-deep path all fail
/// closed (return false).
fn pathConfined(dir: []const u8, path: []const u8) bool {
    var dir_buf: [max_path_components][]const u8 = undefined;
    var path_buf: [max_path_components][]const u8 = undefined;

    const dir_n = normalizeAbsolute(dir, &dir_buf) orelse return false;
    const path_n = normalizeAbsolute(path, &path_buf) orelse return false;

    // The candidate must have at least as many components as the sandbox root
    // and share every one of the root's components in order.
    if (path_n < dir_n) return false;
    for (dir_buf[0..dir_n], path_buf[0..dir_n]) |d, p| {
        if (!std.mem.eql(u8, d, p)) return false;
    }
    return true;
}

/// Network access rule
pub const NetRule = struct {
    host: []const u8,
    port: ?u16 = null, // null means any port

    pub fn matches(self: NetRule, host: []const u8, port: u16) bool {
        if (!std.mem.eql(u8, self.host, host) and !std.mem.eql(u8, self.host, "*")) {
            return false;
        }

        if (self.port) |rule_port| {
            return rule_port == port;
        }

        return true;
    }
};

// ============================================================================
// SSRF classification
// ============================================================================
// A guest granted outbound network access — even through a broad "*" rule —
// must not be able to pivot to the host's own loopback, the cloud-metadata
// endpoint, or link-local / private / internal ranges. `hostIsInternalTarget`
// fails closed: it recognises those dangerous targets from the URL host so
// `checkNet` can refuse them unless an operator named the *exact* host in a
// rule. It is purely lexical (no DNS), so it closes literal-IP and localhost
// SSRF, including the inet_aton integer/octal/hex encodings the system resolver
// would otherwise accept. A hostname that *resolves* to an internal address
// (DNS rebinding) is a separate, resolution-time concern tracked in the Phase 3
// follow-up; it stays gated behind `allow_net` plus an explicit rule.

/// Parse a single inet_aton field: a C-style unsigned integer that may be hex
/// ("0x1a"), octal (leading "0"), or decimal. Returns null on empty input, a
/// sign, invalid digits, or overflow past 32 bits.
fn parseInetField(s: []const u8) ?u32 {
    if (s.len == 0) return null;
    if (s[0] == '+' or s[0] == '-') return null;
    var radix: u8 = 10;
    var digits = s;
    if (s.len >= 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
        radix = 16;
        digits = s[2..];
        if (digits.len == 0) return null;
    } else if (s.len >= 2 and s[0] == '0') {
        radix = 8;
        digits = s[1..];
    }
    return std.fmt.parseInt(u32, digits, radix) catch null;
}

/// Parse an IPv4 address the permissive way libc's `inet_aton` does, returning
/// the address in host byte order. The system resolver accepts these forms, so
/// an SSRF filter that understood only dotted-quad would be trivially bypassed
/// with e.g. "2130706433", "0x7f000001", "0177.1", or "127.1" — all 127.0.0.1.
/// Returns null when `s` is not a valid inet_aton IPv4 literal.
fn parseIpv4Inet(s: []const u8) ?u32 {
    if (s.len == 0) return null;
    var parts: [4]u32 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, s, '.');
    while (it.next()) |part| {
        if (n >= 4) return null; // more than four parts
        parts[n] = parseInetField(part) orelse return null;
        n += 1;
    }
    switch (n) {
        1 => return parts[0],
        2 => {
            // a.b -> a<<24 | b (b spans the low 24 bits)
            if (parts[0] > 0xff or parts[1] > 0xff_ffff) return null;
            return (parts[0] << 24) | parts[1];
        },
        3 => {
            // a.b.c -> a<<24 | b<<16 | c (c spans the low 16 bits)
            if (parts[0] > 0xff or parts[1] > 0xff or parts[2] > 0xffff) return null;
            return (parts[0] << 24) | (parts[1] << 16) | parts[2];
        },
        4 => {
            if (parts[0] > 0xff or parts[1] > 0xff or parts[2] > 0xff or parts[3] > 0xff) return null;
            return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3];
        },
        else => return null,
    }
}

/// Classify a host-order IPv4 address: true if it belongs to a range outbound
/// requests must not reach (loopback, private, CGNAT, link-local/metadata,
/// unspecified, benchmarking, multicast, reserved, broadcast).
fn ipv4IsForbidden(addr: u32) bool {
    const a: u32 = (addr >> 24) & 0xff;
    const b: u32 = (addr >> 16) & 0xff;
    const c: u32 = (addr >> 8) & 0xff;
    if (a == 0) return true; // 0.0.0.0/8 "this network" / unspecified
    if (a == 10) return true; // 10.0.0.0/8 private
    if (a == 127) return true; // 127.0.0.0/8 loopback
    if (a == 100 and b >= 64 and b <= 127) return true; // 100.64.0.0/10 CGNAT
    if (a == 169 and b == 254) return true; // 169.254.0.0/16 link-local (metadata)
    if (a == 172 and b >= 16 and b <= 31) return true; // 172.16.0.0/12 private
    if (a == 192 and b == 168) return true; // 192.168.0.0/16 private
    if (a == 192 and b == 0 and c == 0) return true; // 192.0.0.0/24 IETF assignments
    if (a == 198 and (b == 18 or b == 19)) return true; // 198.18.0.0/15 benchmarking
    if (a >= 224) return true; // 224/4 multicast, 240/4 reserved, 255.255.255.255
    return false;
}

/// Classify a 16-byte (big-endian) IPv6 address, resolving the IPv4-embedding
/// forms (mapped / compatible / NAT64) to their inner IPv4 for classification.
fn ipv6IsForbidden(bytes: [16]u8) bool {
    var all_zero = true;
    for (bytes) |x| {
        if (x != 0) {
            all_zero = false;
            break;
        }
    }
    if (all_zero) return true; // :: unspecified

    // ::1 loopback
    var high_zero = true;
    for (bytes[0..15]) |x| {
        if (x != 0) {
            high_zero = false;
            break;
        }
    }
    if (high_zero and bytes[15] == 1) return true;

    if (bytes[0] == 0xfe and (bytes[1] & 0xc0) == 0x80) return true; // fe80::/10 link-local
    if ((bytes[0] & 0xfe) == 0xfc) return true; // fc00::/7 unique local
    if (bytes[0] == 0xff) return true; // ff00::/8 multicast

    // Embedded IPv4: ::ffff:a.b.c.d (mapped), ::a.b.c.d (compatible, first 12
    // bytes zero), and 64:ff9b::/96 (NAT64). Classify the inner IPv4.
    const embed_v4 = blk: {
        const mapped = std.mem.eql(u8, bytes[0..12], &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff });
        const compat = high_zero; // first 15 bytes zero already excludes loopback above
        const first12_zero = std.mem.eql(u8, bytes[0..12], &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 });
        const nat64 = std.mem.eql(u8, bytes[0..12], &[_]u8{ 0, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0 });
        if (mapped or compat or first12_zero or nat64) break :blk true;
        break :blk false;
    };
    if (embed_v4) {
        const v4 = (@as(u32, bytes[12]) << 24) | (@as(u32, bytes[13]) << 16) |
            (@as(u32, bytes[14]) << 8) | @as(u32, bytes[15]);
        return ipv4IsForbidden(v4);
    }

    return false;
}

/// True if `host` (a URL authority host, already de-bracketed for IPv6) names a
/// target outbound requests must not reach unless an operator allow-listed that
/// exact host: a localhost name, or an IP literal — in any inet_aton or IPv6
/// encoding — inside loopback, link-local/metadata, private, CGNAT, reserved,
/// multicast, or broadcast space. An empty host fails closed.
pub fn hostIsInternalTarget(host: []const u8) bool {
    if (host.len == 0) return true;

    // localhost / *.localhost (case-insensitive, tolerate a trailing dot).
    var name = host;
    if (name[name.len - 1] == '.') name = name[0 .. name.len - 1];
    if (std.ascii.eqlIgnoreCase(name, "localhost")) return true;
    if (name.len > ".localhost".len and std.ascii.endsWithIgnoreCase(name, ".localhost")) return true;

    // IPv4 literal in any inet_aton encoding.
    if (parseIpv4Inet(host)) |v4| return ipv4IsForbidden(v4);

    // IPv6 literal (strip any "%zone" scope id first).
    var v6text = host;
    if (std.mem.indexOfScalar(u8, v6text, '%')) |idx| v6text = v6text[0..idx];
    switch (std.Io.net.Ip6Address.Unresolved.parse(v6text)) {
        .success => |u| return ipv6IsForbidden(u.bytes),
        else => {},
    }

    return false;
}

/// WASM security policy
///
/// Ownership contract: every heap-allocated field the policy holds — the
/// `allow_fs` directory path and each `net_rules` host string — is owned by
/// the policy and must be installed through the mutating helpers
/// (`setFsReadOnly`, `setFsReadWrite`, `setFsNone`, `addNetRule`). Those
/// helpers duplicate their inputs so the caller keeps ownership of the strings
/// it passes in. `deinit` frees exactly what the policy owns. Never assign
/// borrowed, stack-backed, or static slices to `allow_fs`/`net_rules`
/// directly: doing so would make `deinit` free memory it does not own.
pub const WasmPolicy = struct {
    max_memory: usize = 100 * 1024 * 1024, // 100MB default
    max_cpu_time: u64 = 5000, // 5 seconds default
    max_stack_depth: u32 = 1024,
    /// Instruction ("fuel") budget the interpreter must not exceed while running
    /// a module. Enforced structurally in the execute loop when the policy is
    /// bound, so an unbounded loop aborts instead of spinning. A wall-clock
    /// `max_cpu_time` cannot be enforced without a clock in the hot loop; this
    /// deterministic instruction budget is its in-loop equivalent.
    max_instructions: u64 = 100_000_000,
    allow_net: bool = false,
    allow_fs: FsPolicy = .none,
    allow_env: bool = false,
    allow_threads: bool = false,
    net_rules: std.ArrayListUnmanaged(NetRule) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) WasmPolicy {
        return WasmPolicy{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *WasmPolicy) void {
        self.freeFsPath();
        for (self.net_rules.items) |rule| {
            self.allocator.free(rule.host);
        }
        self.net_rules.deinit(self.allocator);
    }

    fn freeFsPath(self: *WasmPolicy) void {
        switch (self.allow_fs) {
            .none => {},
            .read_only, .read_write => |path| self.allocator.free(path),
        }
        self.allow_fs = .none;
    }

    /// Clear filesystem access, freeing any owned directory path.
    pub fn setFsNone(self: *WasmPolicy) void {
        self.freeFsPath();
    }

    /// Grant read-only access to `dir`, taking an owned copy of the path.
    pub fn setFsReadOnly(self: *WasmPolicy, dir: []const u8) !void {
        const duped = try self.allocator.dupe(u8, dir);
        self.freeFsPath();
        self.allow_fs = .{ .read_only = duped };
    }

    /// Grant read-write access to `dir`, taking an owned copy of the path.
    pub fn setFsReadWrite(self: *WasmPolicy, dir: []const u8) !void {
        const duped = try self.allocator.dupe(u8, dir);
        self.freeFsPath();
        self.allow_fs = .{ .read_write = duped };
    }

    /// Append a network rule, taking an owned copy of `host`.
    pub fn addNetRule(self: *WasmPolicy, host: []const u8, port: ?u16) !void {
        const duped = try self.allocator.dupe(u8, host);
        errdefer self.allocator.free(duped);
        try self.net_rules.append(self.allocator, .{ .host = duped, .port = port });
    }

    /// Check if network access is allowed
    pub fn checkNet(self: *const WasmPolicy, host: []const u8, port: u16) !void {
        if (!self.allow_net) return error.PermissionDenied;

        // Track whether a rule matched, and whether any match named the exact
        // host (rather than the "*" wildcard). Internal/SSRF targets require an
        // exact-host rule: a broad "*" grants public egress but must never open
        // a pivot to the host's own loopback/metadata/private surface.
        var matched = false;
        var matched_exact = false;
        for (self.net_rules.items) |rule| {
            if (rule.matches(host, port)) {
                matched = true;
                if (!std.mem.eql(u8, rule.host, "*")) matched_exact = true;
            }
        }
        if (!matched) return error.PermissionDenied;

        if (hostIsInternalTarget(host) and !matched_exact) return error.PermissionDenied;
    }

    /// Check if file system read is allowed
    pub fn checkFsRead(self: *const WasmPolicy, path: []const u8) !void {
        if (!self.allow_fs.allows(path, false)) {
            return error.PermissionDenied;
        }
    }

    /// Check if file system write is allowed
    pub fn checkFsWrite(self: *const WasmPolicy, path: []const u8) !void {
        if (!self.allow_fs.allows(path, true)) {
            return error.PermissionDenied;
        }
    }

    /// Check if environment variable access is allowed
    pub fn checkEnv(self: *const WasmPolicy) !void {
        if (!self.allow_env) return error.PermissionDenied;
    }

    /// Check if memory allocation is within limits
    pub fn checkMemory(self: *const WasmPolicy, size: usize) !void {
        if (size > self.max_memory) return error.MemoryLimitExceeded;
    }

    /// Check if CPU time is within limits
    pub fn checkCpuTime(self: *const WasmPolicy, elapsed_ms: u64) !void {
        if (elapsed_ms > self.max_cpu_time) return error.CpuTimeLimitExceeded;
    }

    /// The linear-memory page ceiling this policy's byte budget permits (WASM
    /// pages are 64 KiB). Callers clamp a module's declared maximum to this so a
    /// guest can never grow past the policy budget. Centralizing the derivation
    /// here keeps the memory-pages limit a structural bound rather than a
    /// bypassable standalone check.
    pub fn maxWasmPages(self: *const WasmPolicy) u32 {
        const wasm_page_size: usize = 65536;
        return @intCast(@min(self.max_memory / wasm_page_size, std.math.maxInt(u32)));
    }

    /// Create a permissive policy for development
    pub fn permissive(allocator: std.mem.Allocator) !WasmPolicy {
        var policy = WasmPolicy{
            .allocator = allocator,
            .max_memory = 1024 * 1024 * 1024, // 1GB
            .max_cpu_time = 60000, // 60 seconds
            .max_stack_depth = 4096,
            .max_instructions = 1_000_000_000,
            .allow_net = true,
            .allow_env = true,
            .allow_threads = true,
        };
        errdefer policy.deinit();
        try policy.setFsReadWrite("/tmp");
        try policy.addNetRule("*", null);
        return policy;
    }

    /// Create a restrictive policy for production
    pub fn restrictive(allocator: std.mem.Allocator) WasmPolicy {
        return WasmPolicy{
            .allocator = allocator,
            .max_memory = 10 * 1024 * 1024, // 10MB
            .max_cpu_time = 1000, // 1 second
            .max_stack_depth = 256,
            .max_instructions = 10_000_000,
            .allow_net = false,
            .allow_fs = .none,
            .allow_env = false,
            .allow_threads = false,
        };
    }

    /// Create policy from configuration
    pub fn fromConfig(allocator: std.mem.Allocator, config: PolicyConfig) !WasmPolicy {
        var policy = WasmPolicy{
            .allocator = allocator,
            .max_memory = config.max_memory,
            .max_cpu_time = config.max_cpu_time,
            .max_stack_depth = config.max_stack_depth,
            .max_instructions = config.max_instructions,
            .allow_net = config.allow_net,
            .allow_env = config.allow_env,
            .allow_threads = config.allow_threads,
        };
        errdefer policy.deinit();

        // Set file system policy
        if (config.fs_path) |path| {
            if (config.fs_write) {
                try policy.setFsReadWrite(path);
            } else {
                try policy.setFsReadOnly(path);
            }
        }

        // Set network rules
        if (config.net_hosts) |hosts| {
            try policy.net_rules.ensureTotalCapacity(allocator, hosts.len);
            for (hosts) |host| {
                try policy.addNetRule(host, null);
            }
        }

        return policy;
    }
};

/// Policy configuration struct
pub const PolicyConfig = struct {
    max_memory: usize = 100 * 1024 * 1024,
    max_cpu_time: u64 = 5000,
    max_stack_depth: u32 = 1024,
    max_instructions: u64 = 100_000_000,
    allow_net: bool = false,
    allow_env: bool = false,
    allow_threads: bool = false,
    fs_path: ?[]const u8 = null,
    fs_write: bool = false,
    net_hosts: ?[]const []const u8 = null,
};

test "policy network check" {
    const allocator = std.testing.allocator;

    var policy = WasmPolicy.init(allocator);
    defer policy.deinit();

    // Network disabled by default
    try std.testing.expectError(error.PermissionDenied, policy.checkNet("example.com", 80));

    // Enable network with specific host (policy owns the duplicated host).
    policy.allow_net = true;
    try policy.addNetRule("api.example.com", 443);

    // Should allow matching rule
    try policy.checkNet("api.example.com", 443);

    // Should deny non-matching host
    try std.testing.expectError(error.PermissionDenied, policy.checkNet("evil.com", 443));

    // Should deny non-matching port
    try std.testing.expectError(error.PermissionDenied, policy.checkNet("api.example.com", 80));
}

test "ssrf classifier flags internal targets and permits public ones" {
    // Loopback in every encoding libc's resolver would accept.
    try std.testing.expect(hostIsInternalTarget("127.0.0.1"));
    try std.testing.expect(hostIsInternalTarget("127.1")); // inet_aton short form
    try std.testing.expect(hostIsInternalTarget("2130706433")); // decimal 0x7f000001
    try std.testing.expect(hostIsInternalTarget("0x7f000001")); // hex
    try std.testing.expect(hostIsInternalTarget("017700000001")); // octal
    try std.testing.expect(hostIsInternalTarget("localhost"));
    try std.testing.expect(hostIsInternalTarget("api.localhost"));
    try std.testing.expect(hostIsInternalTarget("LOCALHOST."));
    // Cloud metadata + link-local, private, CGNAT, unspecified, broadcast.
    try std.testing.expect(hostIsInternalTarget("169.254.169.254"));
    try std.testing.expect(hostIsInternalTarget("10.0.0.5"));
    try std.testing.expect(hostIsInternalTarget("172.16.0.1"));
    try std.testing.expect(hostIsInternalTarget("172.31.255.255"));
    try std.testing.expect(hostIsInternalTarget("192.168.1.1"));
    try std.testing.expect(hostIsInternalTarget("100.64.0.1"));
    try std.testing.expect(hostIsInternalTarget("0.0.0.0"));
    try std.testing.expect(hostIsInternalTarget("255.255.255.255"));
    // IPv6 loopback/link-local/ULA and IPv4-mapped loopback.
    try std.testing.expect(hostIsInternalTarget("::1"));
    try std.testing.expect(hostIsInternalTarget("fe80::1"));
    try std.testing.expect(hostIsInternalTarget("fc00::1"));
    try std.testing.expect(hostIsInternalTarget("::ffff:127.0.0.1"));
    try std.testing.expect(hostIsInternalTarget("::ffff:169.254.169.254"));

    // Genuinely public destinations must not be flagged.
    try std.testing.expect(!hostIsInternalTarget("example.com"));
    try std.testing.expect(!hostIsInternalTarget("93.184.216.34"));
    try std.testing.expect(!hostIsInternalTarget("8.8.8.8"));
    try std.testing.expect(!hostIsInternalTarget("172.32.0.1")); // just outside 172.16/12
    try std.testing.expect(!hostIsInternalTarget("100.128.0.1")); // just outside 100.64/10
    try std.testing.expect(!hostIsInternalTarget("2606:4700:4700::1111")); // public IPv6
}

test "checkNet blocks SSRF pivots under a wildcard rule but honors explicit allow" {
    const allocator = std.testing.allocator;

    var policy = WasmPolicy.init(allocator);
    defer policy.deinit();
    policy.allow_net = true;
    try policy.addNetRule("*", null); // broad public-egress grant

    // Public hosts remain reachable through the wildcard.
    try policy.checkNet("example.com", 443);
    try policy.checkNet("93.184.216.34", 80);

    // The wildcard must not open the host's internal surface.
    try std.testing.expectError(error.PermissionDenied, policy.checkNet("127.0.0.1", 80));
    try std.testing.expectError(error.PermissionDenied, policy.checkNet("169.254.169.254", 80));
    try std.testing.expectError(error.PermissionDenied, policy.checkNet("10.0.0.1", 8080));
    try std.testing.expectError(error.PermissionDenied, policy.checkNet("localhost", 80));
    try std.testing.expectError(error.PermissionDenied, policy.checkNet("::1", 80));
    try std.testing.expectError(error.PermissionDenied, policy.checkNet("2130706433", 80));

    // An operator who names the exact internal host may reach it.
    try policy.addNetRule("127.0.0.1", null);
    try policy.checkNet("127.0.0.1", 80);
    // A different internal host is still denied.
    try std.testing.expectError(error.PermissionDenied, policy.checkNet("127.0.0.2", 80));
}

test "policy file system check" {
    const allocator = std.testing.allocator;

    var policy = WasmPolicy.init(allocator);
    defer policy.deinit();

    // These are lexical policy strings, never touched on disk, so a neutral
    // fictional sandbox root keeps them from reading like real artifacts.

    // FS disabled by default
    try std.testing.expectError(error.PermissionDenied, policy.checkFsRead("/sandbox/test"));

    // Enable read-only access to the sandbox root
    try policy.setFsReadOnly("/sandbox");

    // Should allow reading from within the sandbox
    try policy.checkFsRead("/sandbox/test");

    // Should deny writing to the sandbox (read-only)
    try std.testing.expectError(error.PermissionDenied, policy.checkFsWrite("/sandbox/test"));

    // Should deny access outside the sandbox
    try std.testing.expectError(error.PermissionDenied, policy.checkFsRead("/etc/passwd"));
}

test "policy fs replacement and permissive round-trip are free-safe" {
    // Regression guard for the earlier double free / leak: repeatedly replacing
    // the owned fs path and tearing down a fully-populated policy must free each
    // owned slice exactly once under the leak-detecting allocator.
    const allocator = std.testing.allocator;

    var policy = WasmPolicy.init(allocator);
    // Replace the owned path several times; each install frees the prior one.
    try policy.setFsReadOnly("/srv/data");
    try policy.setFsReadWrite("/srv/data");
    try policy.setFsReadOnly("/var/www");
    policy.setFsNone(); // frees the last owned path, resets to .none
    policy.deinit(); // second free of the (already cleared) path must be a no-op

    // permissive() installs an owned fs path plus a net rule; deinit frees both.
    var perm = try WasmPolicy.permissive(allocator);
    perm.deinit();
}

test "policy fs confinement rejects prefix-sibling and traversal escapes" {
    // Negative security test for the canonical confinement replacing the old
    // std.mem.startsWith prefix check. An "/allowed" read-only policy must admit
    // only paths genuinely beneath /allowed and reject sibling-prefix, "..", and
    // relative escapes that the naive prefix match let through.
    const allocator = std.testing.allocator;
    var policy = WasmPolicy.init(allocator);
    defer policy.deinit();
    try policy.setFsReadOnly("/allowed");

    // Legitimate access inside the sandbox root is still permitted.
    try policy.checkFsRead("/allowed"); // the root itself
    try policy.checkFsRead("/allowed/file");
    try policy.checkFsRead("/allowed/sub/dir/file");
    try policy.checkFsRead("/allowed/./file"); // "." is harmless
    try policy.checkFsRead("/allowed//file"); // collapsed separators
    try policy.checkFsRead("/allowed/sub/../file"); // ".." that stays inside

    // Prefix-sibling directories must NOT pass an "/allowed" policy.
    try std.testing.expectError(error.PermissionDenied, policy.checkFsRead("/allowed-evil/secret"));
    try std.testing.expectError(error.PermissionDenied, policy.checkFsRead("/allowedX"));

    // ".." traversal out of the sandbox is rejected despite the "/allowed" prefix.
    try std.testing.expectError(error.PermissionDenied, policy.checkFsRead("/allowed/../etc/passwd"));
    try std.testing.expectError(error.PermissionDenied, policy.checkFsRead("/allowed/../../etc/passwd"));
    try std.testing.expectError(error.PermissionDenied, policy.checkFsRead("/allowed/sub/../../etc"));

    // Relative paths are ambiguous at this layer and fail closed.
    try std.testing.expectError(error.PermissionDenied, policy.checkFsRead("allowed/file"));
    try std.testing.expectError(error.PermissionDenied, policy.checkFsRead("../etc/passwd"));

    // Escaping above the filesystem root is rejected outright.
    try std.testing.expectError(error.PermissionDenied, policy.checkFsRead("/.."));

    // A backslash is an ordinary byte on POSIX, so it cannot smuggle traversal.
    try std.testing.expectError(error.PermissionDenied, policy.checkFsRead("/allowed\\..\\..\\etc"));
}

test "policy resource limits" {
    const allocator = std.testing.allocator;

    var policy = WasmPolicy.init(allocator);
    defer policy.deinit();

    // Should allow within limits
    try policy.checkMemory(50 * 1024 * 1024); // 50MB
    try policy.checkCpuTime(2000); // 2 seconds

    // Should deny exceeding limits
    try std.testing.expectError(error.MemoryLimitExceeded, policy.checkMemory(200 * 1024 * 1024));
    try std.testing.expectError(error.CpuTimeLimitExceeded, policy.checkCpuTime(10000));
}

test "maxWasmPages derives the page budget from the byte ceiling" {
    // The interpreter and host clamp a module's declared max_pages to this value,
    // so the derivation (bytes / 64 KiB, saturated to u32) must match the policy
    // byte budgets exactly. 10 MB / 64 KiB = 160 pages; 1 GB / 64 KiB = 16384.
    const allocator = std.testing.allocator;

    var restrictive = WasmPolicy.restrictive(allocator);
    defer restrictive.deinit();
    try std.testing.expectEqual(@as(u32, 160), restrictive.maxWasmPages());

    var permissive = try WasmPolicy.permissive(allocator);
    defer permissive.deinit();
    try std.testing.expectEqual(@as(u32, 16384), permissive.maxWasmPages());
}

test "repeated policy create/populate/destroy cycles are leak-free" {
    // Phase 2 exit gate: a fully populated policy (owned fs path + several owned
    // net-rule hosts) built and torn down many times. The leak-detecting
    // allocator proves deinit frees every owned slice exactly once per cycle and
    // that fs-path replacement never leaks or double frees across cycles.
    const allocator = std.testing.allocator;

    var cycle: usize = 0;
    while (cycle < 256) : (cycle += 1) {
        var policy = WasmPolicy.init(allocator);
        defer policy.deinit();

        policy.allow_net = true;
        try policy.addNetRule("api.example.com", 443);
        try policy.addNetRule("cdn.example.com", 80);
        try policy.addNetRule("*", null);

        // Replace the single owned fs path mid-cycle to exercise freeFsPath.
        try policy.setFsReadOnly("/srv/data");
        try policy.setFsReadWrite("/var/www");

        try policy.checkNet("api.example.com", 443);
        try policy.checkFsRead("/var/www/index.html");
        try policy.checkFsWrite("/var/www/upload.tmp");
    }
}
