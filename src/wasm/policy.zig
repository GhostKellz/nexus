const std = @import("std");

/// File system access policy
pub const FsPolicy = union(enum) {
    none: void,
    read_only: []const u8, // Directory path
    read_write: []const u8, // Directory path

    pub fn allows(self: FsPolicy, path: []const u8, write: bool) bool {
        return switch (self) {
            .none => false,
            .read_only => |dir| !write and std.mem.startsWith(u8, path, dir),
            .read_write => |dir| std.mem.startsWith(u8, path, dir),
        };
    }
};

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

/// WASM security policy
pub const WasmPolicy = struct {
    max_memory: usize = 100 * 1024 * 1024, // 100MB default
    max_cpu_time: u64 = 5000, // 5 seconds default
    max_stack_depth: u32 = 1024,
    allow_net: bool = false,
    allow_fs: FsPolicy = .none,
    allow_env: bool = false,
    allow_threads: bool = false,
    net_rules: []const NetRule = &[_]NetRule{},
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) WasmPolicy {
        return WasmPolicy{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *WasmPolicy) void {
        switch (self.allow_fs) {
            .none => {},
            .read_only => |path| self.allocator.free(path),
            .read_write => |path| self.allocator.free(path),
        }

        for (self.net_rules) |*rule| {
            self.allocator.free(rule.host);
        }
        self.allocator.free(self.net_rules);
    }

    /// Check if network access is allowed
    pub fn checkNet(self: *const WasmPolicy, host: []const u8, port: u16) !void {
        if (!self.allow_net) return error.PermissionDenied;

        for (self.net_rules) |rule| {
            if (rule.matches(host, port)) return;
        }

        return error.PermissionDenied;
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

    /// Create a permissive policy for development
    pub fn permissive(allocator: std.mem.Allocator) !WasmPolicy {
        return WasmPolicy{
            .allocator = allocator,
            .max_memory = 1024 * 1024 * 1024, // 1GB
            .max_cpu_time = 60000, // 60 seconds
            .max_stack_depth = 4096,
            .allow_net = true,
            .allow_fs = .{ .read_write = try allocator.dupe(u8, "/tmp") },
            .allow_env = true,
            .allow_threads = true,
            .net_rules = &[_]NetRule{NetRule{ .host = try allocator.dupe(u8, "*") }},
        };
    }

    /// Create a restrictive policy for production
    pub fn restrictive(allocator: std.mem.Allocator) WasmPolicy {
        return WasmPolicy{
            .allocator = allocator,
            .max_memory = 10 * 1024 * 1024, // 10MB
            .max_cpu_time = 1000, // 1 second
            .max_stack_depth = 256,
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
            .allow_net = config.allow_net,
            .allow_env = config.allow_env,
            .allow_threads = config.allow_threads,
        };

        // Set file system policy
        if (config.fs_path) |path| {
            const path_duped = try allocator.dupe(u8, path);
            policy.allow_fs = if (config.fs_write)
                .{ .read_write = path_duped }
            else
                .{ .read_only = path_duped };
        }

        // Set network rules
        if (config.net_hosts) |hosts| {
            var rules = try allocator.alloc(NetRule, hosts.len);
            for (hosts, 0..) |host, i| {
                rules[i] = NetRule{
                    .host = try allocator.dupe(u8, host),
                };
            }
            policy.net_rules = rules;
        }

        return policy;
    }
};

/// Policy configuration struct
pub const PolicyConfig = struct {
    max_memory: usize = 100 * 1024 * 1024,
    max_cpu_time: u64 = 5000,
    max_stack_depth: u32 = 1024,
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

    // Enable network with specific host
    policy.allow_net = true;
    const rules = [_]NetRule{NetRule{
        .host = try allocator.dupe(u8, "api.example.com"),
        .port = 443,
    }};
    policy.net_rules = &rules;

    // Should allow matching rule
    try policy.checkNet("api.example.com", 443);

    // Should deny non-matching host
    try std.testing.expectError(error.PermissionDenied, policy.checkNet("evil.com", 443));

    // Should deny non-matching port
    try std.testing.expectError(error.PermissionDenied, policy.checkNet("api.example.com", 80));

    // Clean up
    allocator.free(rules[0].host);
}

test "policy file system check" {
    const allocator = std.testing.allocator;

    var policy = WasmPolicy.init(allocator);
    defer policy.deinit();

    // FS disabled by default
    try std.testing.expectError(error.PermissionDenied, policy.checkFsRead("/tmp/test"));

    // Enable read-only access to /tmp
    policy.allow_fs = .{ .read_only = try allocator.dupe(u8, "/tmp") };

    // Should allow reading from /tmp
    try policy.checkFsRead("/tmp/test");

    // Should deny writing to /tmp (read-only)
    try std.testing.expectError(error.PermissionDenied, policy.checkFsWrite("/tmp/test"));

    // Should deny access outside /tmp
    try std.testing.expectError(error.PermissionDenied, policy.checkFsRead("/etc/passwd"));
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
