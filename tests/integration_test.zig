const std = @import("std");
const testing = std.testing;

// Import all modules to test
const wasi = @import("../src/wasm/wasi.zig");
const engine = @import("../src/wasm/engine.zig");
const wasmer = @import("../src/wasm/wasmer.zig");
const policy = @import("../src/wasm/policy.zig");
const tls = @import("../src/stdlib/net/tls.zig");
const acme = @import("../src/stdlib/net/acme.zig");
const http2 = @import("../src/stdlib/net/http2.zig");

// =============================================================================
// WASI Tests
// =============================================================================

test "WASI: Context initialization" {
    const allocator = testing.allocator;

    const args = [_][]const u8{ "prog", "arg1", "arg2" };
    var context = try wasi.WasiContext.init(allocator, &args);
    defer context.deinit();

    try testing.expectEqual(@as(usize, 3), context.args.len);
    try testing.expectEqualStrings("prog", context.args[0]);
}

test "WASI: Environment variables" {
    const allocator = testing.allocator;

    const args = [_][]const u8{"prog"};
    var context = try wasi.WasiContext.init(allocator, &args);
    defer context.deinit();

    try context.setEnv("HOME", "/home/user");
    try context.setEnv("PATH", "/usr/bin");

    try testing.expectEqualStrings("/home/user", context.env.get("HOME").?);
    try testing.expectEqualStrings("/usr/bin", context.env.get("PATH").?);
}

test "WASI: Preopen directories" {
    const allocator = testing.allocator;

    const args = [_][]const u8{"prog"};
    var context = try wasi.WasiContext.init(allocator, &args);
    defer context.deinit();

    const rights = wasi.Rights{
        .fd_read = true,
        .path_open = true,
    };

    const fd = try context.addPreopen("/tmp", rights);
    try testing.expectEqual(@as(wasi.Fd, 3), fd);
}

test "WASI: Host functions - args_sizes_get" {
    const allocator = testing.allocator;

    const args = [_][]const u8{ "prog", "arg1", "arg2" };
    var context = try wasi.WasiContext.init(allocator, &args);
    defer context.deinit();

    var memory = try engine.Memory.init(allocator, 1, 10);
    defer memory.deinit();

    var host = wasi.WasiHost.init(allocator, &context, &memory);

    const errno = try host.argsSizesGet(0, 4);
    try testing.expectEqual(wasi.Errno.SUCCESS, errno);

    const argc = try memory.readInt(u32, 0);
    try testing.expectEqual(@as(u32, 3), argc);
}

test "WASI: File operations - fd_write" {
    const allocator = testing.allocator;

    const args = [_][]const u8{"prog"};
    var context = try wasi.WasiContext.init(allocator, &args);
    defer context.deinit();

    var memory = try engine.Memory.init(allocator, 1, 10);
    defer memory.deinit();

    // Write test data to memory
    const test_data = "Hello, WASI!";
    try memory.write(100, test_data);

    // Create iovec
    try memory.writeInt(u32, 0, 100); // buf_ptr
    try memory.writeInt(u32, 4, @intCast(test_data.len)); // buf_len

    var host = wasi.WasiHost.init(allocator, &context, &memory);

    // fd_write to stdout (fd=1)
    const errno = try host.fdWrite(1, 0, 1, 8);
    try testing.expectEqual(wasi.Errno.SUCCESS, errno);

    const nwritten = try memory.readInt(u32, 8);
    try testing.expectEqual(@as(u32, @intCast(test_data.len)), nwritten);
}

// =============================================================================
// WASM Engine Tests
// =============================================================================

test "WASM Engine: Memory operations" {
    const allocator = testing.allocator;

    var memory = try engine.Memory.init(allocator, 1, 10);
    defer memory.deinit();

    // Test write/read
    const data = "Test data";
    try memory.write(0, data);

    const read_data = try memory.read(0, @intCast(data.len));
    try testing.expectEqualStrings(data, read_data);
}

test "WASM Engine: Memory growth" {
    const allocator = testing.allocator;

    var memory = try engine.Memory.init(allocator, 1, 10);
    defer memory.deinit();

    const old_size = memory.size();
    const old_pages = try memory.grow(2);

    try testing.expectEqual(@as(u32, 1), old_pages);
    try testing.expectEqual(@as(u32, 3), memory.size());
}

test "WASM Engine: Zero-copy operations" {
    const allocator = testing.allocator;

    var memory = try engine.Memory.init(allocator, 1, 10);
    defer memory.deinit();

    // Zero-copy write
    const slice = try memory.writeZeroCopy(0, 100);
    @memset(slice, 42);

    // Zero-copy read
    const read_slice = try memory.readZeroCopy(0, 100);
    for (read_slice) |byte| {
        try testing.expectEqual(@as(u8, 42), byte);
    }
}

test "WASM Engine: Instance and functions" {
    const allocator = testing.allocator;

    var instance = engine.Instance.init(allocator);
    defer instance.deinit();

    // Register host function
    const testFn = struct {
        fn add(params: []const engine.Value, alloc: std.mem.Allocator) ![]engine.Value {
            const result = try alloc.alloc(engine.Value, 1);
            result[0] = engine.Value{ .i32 = params[0].i32 + params[1].i32 };
            return result;
        }
    }.add;

    const param_types = [_]engine.ValueType{ .i32, .i32 };
    const return_types = [_]engine.ValueType{.i32};

    try instance.registerHostFunction("add", &param_types, &return_types, testFn);

    // Call function
    const params = [_]engine.Value{ engine.Value{ .i32 = 10 }, engine.Value{ .i32 = 32 } };
    const results = try instance.call("add", &params);
    defer allocator.free(results);

    try testing.expectEqual(@as(i32, 42), results[0].i32);
}

// =============================================================================
// Wasmer Integration Tests
// =============================================================================

test "Wasmer: Compilation modes" {
    const allocator = testing.allocator;

    const wasm_bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, // magic
        0x01, 0x00, 0x00, 0x00, // version
    };

    var config = wasmer.RuntimeConfig.init(allocator);

    // Test JIT compilation
    config.compilation_mode = .jit;
    var jit_module = try wasmer.CompiledModule.init(allocator, &wasm_bytes, config);
    defer jit_module.deinit();

    const info = jit_module.getCompilationInfo();
    try testing.expect(info.is_compiled);
    try testing.expectEqual(wasmer.CompilationMode.jit, info.compilation_mode);
}

test "Wasmer: Module cache" {
    const allocator = testing.allocator;

    var cache = try wasmer.ModuleCache.init(allocator, "/tmp/nexus-test-cache");
    defer cache.deinit();

    try cache.clear();
}

// =============================================================================
// Security Policy Tests
// =============================================================================

test "Policy: Network access control" {
    const allocator = testing.allocator;

    var policy = policy.WasmPolicy.init(allocator);
    defer policy.deinit();

    // Network disabled by default
    try testing.expectError(error.PermissionDenied, policy.checkNet("example.com", 80));

    // Enable network
    policy.allow_net = true;
    const rule = policy.NetRule{
        .host = try allocator.dupe(u8, "api.example.com"),
        .port = 443,
    };
    const rules = [_]policy.NetRule{rule};
    policy.net_rules = &rules;

    // Should allow matching rule
    try policy.checkNet("api.example.com", 443);

    // Should deny non-matching host
    try testing.expectError(error.PermissionDenied, policy.checkNet("evil.com", 443));

    // Cleanup
    allocator.free(rule.host);
}

test "Policy: File system permissions" {
    const allocator = testing.allocator;

    var policy_inst = policy.WasmPolicy.init(allocator);
    defer policy_inst.deinit();

    // FS disabled by default
    try testing.expectError(error.PermissionDenied, policy_inst.checkFsRead("/tmp/test"));

    // Enable read-only access
    policy_inst.allow_fs = .{ .read_only = try allocator.dupe(u8, "/tmp") };

    try policy_inst.checkFsRead("/tmp/test");
    try testing.expectError(error.PermissionDenied, policy_inst.checkFsWrite("/tmp/test"));
}

test "Policy: Resource limits" {
    const allocator = testing.allocator;

    var policy_inst = policy.WasmPolicy.init(allocator);
    defer policy_inst.deinit();

    try policy_inst.checkMemory(50 * 1024 * 1024);
    try testing.expectError(error.MemoryLimitExceeded, policy_inst.checkMemory(200 * 1024 * 1024));

    try policy_inst.checkCpuTime(2000);
    try testing.expectError(error.CpuTimeLimitExceeded, policy_inst.checkCpuTime(10000));
}

// =============================================================================
// TLS/HTTPS Tests
// =============================================================================

test "TLS: Certificate parsing" {
    const allocator = testing.allocator;

    const pem_data =
        \\-----BEGIN CERTIFICATE-----
        \\MIICLDCCAdKgAwIBAgIBADAKBggqhkjOPQQDAjB9MQswCQYDVQQGEwJCRTEPMA0G
        \\-----END CERTIFICATE-----
    ;

    var cert = try tls.Certificate.fromPEM(allocator, pem_data);
    defer cert.deinit();

    try testing.expect(cert.der_data.len > 0);
    try cert.verify();
}

test "TLS: Configuration" {
    const allocator = testing.allocator;

    var config = tls.Config.init(allocator);
    defer config.deinit();

    try testing.expectEqual(tls.ProtocolVersion.tls_1_2, config.min_version);
    try testing.expectEqual(tls.ProtocolVersion.tls_1_3, config.max_version);
    try testing.expect(config.cipher_suites.len > 0);
}

test "TLS: Record parsing" {
    const data = [_]u8{
        @intFromEnum(tls.ContentType.handshake),
        0x03, 0x03, // TLS 1.2
        0x00, 0x05, // length 5
        1, 2, 3, 4, 5,
    };

    const record = try tls.Record.parse(&data);
    try testing.expectEqual(tls.ContentType.handshake, record.content_type);
    try testing.expectEqual(tls.ProtocolVersion.tls_1_2, record.version);
    try testing.expectEqual(@as(u16, 5), record.length);
}

// =============================================================================
// ACME Tests
// =============================================================================

test "ACME: Challenge key authorization" {
    const allocator = testing.allocator;

    var challenge = try acme.Challenge.init(allocator, .http_01, "https://acme/chall", "token123");
    defer challenge.deinit();

    const thumbprint = "thumbprint456";
    const key_authz = try challenge.keyAuthorization(thumbprint);
    defer allocator.free(key_authz);

    try testing.expectEqualStrings("token123.thumbprint456", key_authz);
}

test "ACME: Order lifecycle" {
    const allocator = testing.allocator;

    var order = try acme.Order.init(allocator, "https://acme/order/1", "https://acme/order/1/finalize");
    defer order.deinit();

    try testing.expectEqual(acme.OrderStatus.pending, order.status);
}

test "ACME: Client initialization" {
    const allocator = testing.allocator;

    var client = try acme.Client.init(allocator, acme.AcmeDirectory.LETS_ENCRYPT_STAGING);
    defer client.deinit();

    try testing.expectEqualStrings(acme.AcmeDirectory.LETS_ENCRYPT_STAGING, client.directory_url);
}

// =============================================================================
// HTTP/2 Tests
// =============================================================================

test "HTTP/2: Frame header parsing" {
    var buf: [9]u8 = undefined;

    const header = http2.FrameHeader{
        .length = 100,
        .type = .headers,
        .flags = 0x04,
        .stream_id = 1,
    };

    try header.write(&buf);
    const parsed = try http2.FrameHeader.parse(&buf);

    try testing.expectEqual(header.length, parsed.length);
    try testing.expectEqual(header.type, parsed.type);
    try testing.expectEqual(header.flags, parsed.flags);
    try testing.expectEqual(header.stream_id, parsed.stream_id);
}

test "HTTP/2: Stream priority" {
    const allocator = testing.allocator;

    const priority = http2.Priority{
        .stream_dependency = 5,
        .weight = 20,
        .exclusive = true,
    };

    var buffer: [5]u8 = undefined;
    try priority.write(&buffer);

    const parsed = try http2.Priority.parse(&buffer);

    try testing.expectEqual(priority.stream_dependency, parsed.stream_dependency);
    try testing.expectEqual(priority.weight, parsed.weight);
    try testing.expectEqual(priority.exclusive, parsed.exclusive);
}

test "HTTP/2: Stream state machine" {
    const allocator = testing.allocator;

    var stream = http2.Stream.init(allocator, 1);
    defer stream.deinit();

    try testing.expectEqual(http2.Stream.State.idle, stream.state);

    stream.state = .open;
    try testing.expectEqual(http2.Stream.State.open, stream.state);

    const priority = http2.Priority{ .weight = 30 };
    stream.updatePriority(priority);
    try testing.expectEqual(@as(u8, 30), stream.priority.weight);
}

// =============================================================================
// Integration Tests
// =============================================================================

test "Integration: WASM + WASI + Security" {
    const allocator = testing.allocator;

    // Setup WASI context
    const args = [_][]const u8{"test_prog"};
    var wasi_context = try wasi.WasiContext.init(allocator, &args);
    defer wasi_context.deinit();

    // Setup security policy
    var sec_policy = policy.WasmPolicy.init(allocator);
    defer sec_policy.deinit();

    // Setup WASM instance
    var instance = engine.Instance.init(allocator);
    defer instance.deinit();

    var memory = try allocator.create(engine.Memory);
    defer allocator.destroy(memory);
    memory.* = try engine.Memory.init(allocator, 1, 10);
    defer memory.deinit();
    instance.memory = memory;

    // Initialize WASI host
    var wasi_host = wasi.WasiHost.init(allocator, &wasi_context, memory);
    _ = wasi_host;

    // Verify policy limits
    try sec_policy.checkMemory(memory.getDataLen());
}

test "Integration: HTTP/2 + TLS" {
    const allocator = testing.allocator;

    // Setup TLS config
    var tls_config = tls.Config.init(allocator);
    defer tls_config.deinit();

    // Setup HTTP/2 settings
    const h2_settings = http2.Settings{
        .max_concurrent_streams = 100,
        .initial_window_size = 65535,
    };

    try testing.expectEqual(@as(u32, 100), h2_settings.max_concurrent_streams);
}
