const std = @import("std");
const nexus = @import("nexus");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    nexus.console.log("⚡ Nexus WASM Engine Demo");
    nexus.console.log("Node.js reimagined in Zig + WASM - 10x better\n");

    // Create WASM engine and instance
    var engine = nexus.wasm.Engine.init(allocator);
    defer engine.deinit();

    const module = try engine.createModule();
    const instance = try module.instantiate(&[_]u8{});

    nexus.console.info("✓ WASM instance created");

    // Example 1: Register a host function (add)
    const addFn = struct {
        fn add(params: []const nexus.wasm.Value, alloc: std.mem.Allocator) ![]nexus.wasm.Value {
            const result = try alloc.alloc(nexus.wasm.Value, 1);
            result[0] = nexus.wasm.Value{ .i32 = params[0].i32 + params[1].i32 };
            return result;
        }
    }.add;

    const add_param_types = [_]nexus.wasm.ValueType{ .i32, .i32 };
    const add_return_types = [_]nexus.wasm.ValueType{.i32};

    try instance.registerHostFunction("add", &add_param_types, &add_return_types, addFn);
    nexus.console.info("✓ Registered host function: add(i32, i32) -> i32");

    // Call the host function
    const add_params = [_]nexus.wasm.Value{
        nexus.wasm.Value{ .i32 = 10 },
        nexus.wasm.Value{ .i32 = 32 },
    };
    const add_results = try instance.call("add", &add_params);
    defer allocator.free(add_results);

    nexus.console.log("📊 add(10, 32) = {d}", .{add_results[0].i32});

    // Example 2: Register and execute WASM bytecode function
    // Bytecode for: fn multiply(a: i32, b: i32) -> i32 { return a * b; }
    const multiply_bytecode = [_]u8{
        0x20, 0x00, // local.get 0 (param a)
        0x20, 0x01, // local.get 1 (param b)
        0x6C, // i32.mul
        0x0F, // return
    };

    const mul_param_types = [_]nexus.wasm.ValueType{ .i32, .i32 };
    const mul_return_types = [_]nexus.wasm.ValueType{.i32};

    try instance.registerWasmFunction("multiply", &mul_param_types, &mul_return_types, &multiply_bytecode);
    nexus.console.info("✓ Registered WASM function: multiply(i32, i32) -> i32");

    // Call the WASM function
    const mul_params = [_]nexus.wasm.Value{
        nexus.wasm.Value{ .i32 = 6 },
        nexus.wasm.Value{ .i32 = 7 },
    };
    const mul_results = try instance.call("multiply", &mul_params);
    defer allocator.free(mul_results);

    nexus.console.log("📊 multiply(6, 7) = {d}", .{mul_results[0].i32});

    // Example 3: More complex bytecode - Fibonacci-style calculation
    // Bytecode for: fn calc(x: i32) -> i32 { return (x + 10) * 2; }
    const calc_bytecode = [_]u8{
        0x20, 0x00, // local.get 0 (param x)
        0x41, 0x0A, // i32.const 10
        0x6A, // i32.add
        0x41, 0x02, // i32.const 2
        0x6C, // i32.mul
        0x0F, // return
    };

    const calc_param_types = [_]nexus.wasm.ValueType{.i32};
    const calc_return_types = [_]nexus.wasm.ValueType{.i32};

    try instance.registerWasmFunction("calc", &calc_param_types, &calc_return_types, &calc_bytecode);
    nexus.console.info("✓ Registered WASM function: calc(i32) -> i32");

    // Call the complex WASM function
    const calc_params = [_]nexus.wasm.Value{
        nexus.wasm.Value{ .i32 = 16 },
    };
    const calc_results = try instance.call("calc", &calc_params);
    defer allocator.free(calc_results);

    nexus.console.log("📊 calc(16) = (16 + 10) * 2 = {d}", .{calc_results[0].i32});

    // Memory operations
    nexus.console.info("\n✓ Testing WASM memory operations");
    if (instance.getMemory()) |memory| {
        const test_str = "Hello, WASM!";
        try memory.write(0, test_str);
        nexus.console.log("📝 Wrote to memory: \"{s}\"", .{test_str});

        const read_data = try memory.read(0, test_str.len);
        nexus.console.log("📖 Read from memory: \"{s}\"", .{read_data});

        try memory.writeInt(u32, 100, 0xDEADBEEF);
        const value = try memory.readInt(u32, 100);
        nexus.console.log("🔢 Memory[100] = 0x{X}", .{value});
    }

    nexus.console.log("\n✅ WASM engine fully functional!");
    nexus.console.log("🚀 Ready to run polyglot workloads (Zig + WASM)");
}
