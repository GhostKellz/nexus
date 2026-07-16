const std = @import("std");
const testing = std.testing;

// Every source file may only belong to one module, and `nexus` already pulls
// in this whole tree, so all internal types are reached through the public
// `nexus` module. The aliases below preserve the original namespaced names.
const nexus = @import("nexus");
const wasm = nexus.wasm;
const engine = wasm;
const wasi = wasm;
const policy = wasm;

// =============================================================================
// WASI Tests
// =============================================================================

test "WASI: Context initialization" {
    const allocator = testing.allocator;

    const args = [_][]const u8{ "prog", "arg1", "arg2" };
    var context = try wasi.WasiContext.init(allocator, std.Io.Threaded.global_single_threaded.io(), &args);
    defer context.deinit();

    try testing.expectEqual(@as(usize, 3), context.args.len);
    try testing.expectEqualStrings("prog", context.args[0]);
}

test "WASI: Environment variables" {
    const allocator = testing.allocator;

    const args = [_][]const u8{"prog"};
    var context = try wasi.WasiContext.init(allocator, std.Io.Threaded.global_single_threaded.io(), &args);
    defer context.deinit();

    try context.setEnv("HOME", "/home/user");
    try context.setEnv("PATH", "/usr/bin");

    try testing.expectEqualStrings("/home/user", context.env.get("HOME").?);
    try testing.expectEqualStrings("/usr/bin", context.env.get("PATH").?);
}

test "WASI: Preopen directories" {
    const allocator = testing.allocator;

    const args = [_][]const u8{"prog"};
    var context = try wasi.WasiContext.init(allocator, std.Io.Threaded.global_single_threaded.io(), &args);
    defer context.deinit();

    const rights = wasi.Rights{
        .fd_read = true,
        .path_open = true,
    };

    const fd = try context.addPreopen("/sandbox", rights);
    try testing.expectEqual(@as(wasi.Fd, 3), fd);
}

test "WASI: Host functions - args_sizes_get" {
    const allocator = testing.allocator;

    const args = [_][]const u8{ "prog", "arg1", "arg2" };
    var context = try wasi.WasiContext.init(allocator, std.Io.Threaded.global_single_threaded.io(), &args);
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
    var context = try wasi.WasiContext.init(allocator, std.Io.Threaded.global_single_threaded.io(), &args);
    defer context.deinit();

    // Route the guest's stdout to the host's stderr for this test. The default
    // is the inherited fd 1, but under `zig build test` fd 1 is the runner's
    // --listen IPC channel; letting the guest write raw bytes there desyncs the
    // protocol and deadlocks the build. fd 2 is not part of that protocol.
    context.stdout = std.Io.File.stderr();

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
        fn add(_: *engine.Instance, params: []const engine.Value, alloc: std.mem.Allocator) ![]engine.Value {
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
// Security Policy Tests
// =============================================================================

test "Policy: Network access control" {
    const allocator = testing.allocator;

    var pol = wasm.WasmPolicy.init(allocator);
    defer pol.deinit();

    // Network disabled by default
    try testing.expectError(error.PermissionDenied, pol.checkNet("example.com", 80));

    // Enable network (policy owns the duplicated host string).
    pol.allow_net = true;
    try pol.addNetRule("api.example.com", 443);

    // Should allow matching rule
    try pol.checkNet("api.example.com", 443);

    // Should deny non-matching host
    try testing.expectError(error.PermissionDenied, pol.checkNet("evil.com", 443));
}

test "Policy: File system permissions" {
    const allocator = testing.allocator;

    var policy_inst = policy.WasmPolicy.init(allocator);
    defer policy_inst.deinit();

    // Lexical policy strings, never touched on disk; a neutral fictional root
    // keeps them from reading like real filesystem artifacts.

    // FS disabled by default
    try testing.expectError(error.PermissionDenied, policy_inst.checkFsRead("/sandbox/test"));

    // Enable read-only access
    try policy_inst.setFsReadOnly("/sandbox");

    try policy_inst.checkFsRead("/sandbox/test");
    try testing.expectError(error.PermissionDenied, policy_inst.checkFsWrite("/sandbox/test"));
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
// Integration Tests
// =============================================================================

test "Integration: WASM + WASI + Security" {
    const allocator = testing.allocator;

    // Setup WASI context
    const args = [_][]const u8{"test_prog"};
    var wasi_context = try wasi.WasiContext.init(allocator, std.Io.Threaded.global_single_threaded.io(), &args);
    defer wasi_context.deinit();

    // Setup security policy
    var sec_policy = policy.WasmPolicy.init(allocator);
    defer sec_policy.deinit();

    // Setup WASM instance
    var instance = engine.Instance.init(allocator);
    defer instance.deinit();

    // Ownership of `memory` transfers to the instance once assigned:
    // Instance.deinit() calls mem.deinit() and destroys the pointer, so the
    // test must not free it a second time.
    const memory = try allocator.create(engine.Memory);
    memory.* = engine.Memory.init(allocator, 1, 10) catch |err| {
        allocator.destroy(memory);
        return err;
    };
    instance.memory = memory;

    // Initialize WASI host
    const wasi_host = wasi.WasiHost.init(allocator, &wasi_context, memory);
    _ = wasi_host;

    // Verify policy limits
    try sec_policy.checkMemory(memory.getDataLen());
}
