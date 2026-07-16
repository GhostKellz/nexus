const std = @import("std");
const nexus = @import("nexus");

// WASM engine status demo for v0.1.2.
//
// The WASM subsystem is exported but intentionally incomplete: there is no
// binary parser yet, so module instantiation fails closed rather than
// fabricating an instance that shares nothing with the module on disk. This
// example demonstrates that real, current contract — it constructs the engine
// and shows instantiation returning `error.WasmParsingUnsupported` cleanly,
// instead of pretending to execute bytecode. See docs/internals/wasm-runtime.md.

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    nexus.console.log("⚡ Nexus WASM Engine Demo", .{});
    nexus.console.log("An application runtime written in Zig\n", .{});

    var engine = nexus.wasm.Engine.init(allocator);
    defer engine.deinit();

    const module = try engine.createModule();
    nexus.console.info("✓ Engine and empty module constructed", .{});

    // Instantiation is the boundary where a real parser would turn module bytes
    // into memories, tables, globals, and functions. Until that parser exists,
    // it fails closed — assert that so this example documents the contract.
    if (module.instantiate(&[_]u8{})) |_| {
        nexus.console.@"error"("unexpected: instantiate() succeeded without a parser", .{});
        return error.UnexpectedSuccess;
    } else |err| switch (err) {
        error.WasmParsingUnsupported => {
            nexus.console.info("✓ instantiate() failed closed with WasmParsingUnsupported (expected in v0.1.2)", .{});
        },
    }

    nexus.console.log("\nWASM module execution is not available in v0.1.2.", .{});
    nexus.console.log("The engine, WASI, and policy types are exported so callers can", .{});
    nexus.console.log("build against a stable surface once the parser lands.", .{});
}
