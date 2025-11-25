const std = @import("std");
const nexus = @import("nexus");
const engine = nexus.wasm;
const event_loop = nexus.runtime;
const host = @import("host.zig");

/// ZigScript WASM module loader and executor
pub const ZigScriptLoader = struct {
    engine: *engine.Engine,
    event_loop: *event_loop.EventLoop,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        wasm_engine: *engine.Engine,
        loop: *event_loop.EventLoop,
    ) ZigScriptLoader {
        return .{
            .engine = wasm_engine,
            .event_loop = loop,
            .allocator = allocator,
        };
    }

    /// Load and execute a ZigScript WASM module
    pub fn load(self: *ZigScriptLoader, wasm_path: []const u8) !i32 {
        std.debug.print("🚀 Loading ZigScript module: {s}\n", .{wasm_path});

        // Load WASM module
        const module = try self.engine.loadModule(wasm_path);

        // Get the instance (first one created during load)
        if (module.instances.items.len == 0) return error.NoInstance;
        const instance = module.instances.items[0];

        // Register ZigScript host functions
        try host.registerHostFunctions(instance);

        std.debug.print("✅ Host functions registered\n", .{});

        // Create ZigScript context
        var ctx = try host.ZigScriptContext.init(
            self.allocator,
            instance,
            self.event_loop,
        );
        defer ctx.deinit();

        // Set global context for host functions
        host.setContext(&ctx);

        std.debug.print("🎯 Calling main() function\n", .{});

        // Call the main function
        const result = try instance.call("main", &[_]engine.Value{});
        defer self.allocator.free(result);

        if (result.len > 0) {
            const exit_code = result[0].toInt(i32);
            std.debug.print("✨ ZigScript module exited with code: {d}\n", .{exit_code});
            return exit_code;
        }

        return 0;
    }

    /// Load and run a ZigScript module with event loop
    pub fn run(self: *ZigScriptLoader, wasm_path: []const u8) !i32 {
        std.debug.print("🔄 Loading ZigScript module with event loop: {s}\n", .{wasm_path});

        // Load WASM module
        const module = try self.engine.loadModule(wasm_path);

        if (module.instances.items.len == 0) return error.NoInstance;
        const instance = module.instances.items[0];

        // Register host functions
        try host.registerHostFunctions(instance);

        // Create context
        var ctx = try host.ZigScriptContext.init(
            self.allocator,
            instance,
            self.event_loop,
        );
        defer ctx.deinit();

        host.setContext(&ctx);

        std.debug.print("🎯 Calling main() with async support\n", .{});

        // Spawn main as a task
        const MainTask = struct {
            instance: *engine.Instance,
            allocator: std.mem.Allocator,
            exit_code: *i32,

            fn execute(task: *event_loop.Task) !void {
                const task_self: *@This() = @ptrCast(@alignCast(task.context.?));

                const result = try task_self.instance.call("main", &[_]engine.Value{});
                defer task_self.allocator.free(result);

                if (result.len > 0) {
                    task_self.exit_code.* = result[0].toInt(i32);
                }
            }
        };

        var exit_code: i32 = 0;
        const main_task = try self.allocator.create(MainTask);
        defer self.allocator.destroy(main_task);

        main_task.* = .{
            .instance = instance,
            .allocator = self.allocator,
            .exit_code = &exit_code,
        };

        try self.event_loop.task_queue.enqueueWithContext(
            MainTask.execute,
            main_task,
        );

        std.debug.print("🔁 Running event loop\n", .{});

        // Run the event loop
        try self.event_loop.run();

        std.debug.print("✨ Event loop finished, exit code: {d}\n", .{exit_code});

        return exit_code;
    }

    /// Load a ZigScript module from source (.zs file)
    pub fn loadSource(self: *ZigScriptLoader, zs_path: []const u8) !i32 {
        std.debug.print("📝 Compiling ZigScript source: {s}\n", .{zs_path});

        // Compile .zs to .wasm
        const wasm_path = try self.compile(zs_path);
        defer self.allocator.free(wasm_path);

        // Load and run the compiled WASM
        return self.run(wasm_path);
    }

    /// Compile .zs source to .wasm
    fn compile(self: *ZigScriptLoader, zs_path: []const u8) ![]const u8 {
        // Construct output path
        const basename = std.fs.path.basename(zs_path);
        const name_no_ext = if (std.mem.lastIndexOf(u8, basename, ".")) |idx|
            basename[0..idx]
        else
            basename;

        const wat_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}.wat",
            .{name_no_ext},
        );
        defer self.allocator.free(wat_path);

        const wasm_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}.wasm",
            .{name_no_ext},
        );
        errdefer self.allocator.free(wasm_path);

        // Run ZigScript compiler
        var child = std.process.Child.init(
            &[_][]const u8{ "zs", "build", zs_path },
            self.allocator,
        );

        const result = try child.spawnAndWait();

        if (result != .Exited or result.Exited != 0) {
            return error.CompilationFailed;
        }

        std.debug.print("✅ Compiled to {s}\n", .{wat_path});

        // Convert WAT to WASM using wat2wasm
        var wat2wasm = std.process.Child.init(
            &[_][]const u8{ "wat2wasm", wat_path, "-o", wasm_path },
            self.allocator,
        );

        const wat2wasm_result = try wat2wasm.spawnAndWait();

        if (wat2wasm_result != .Exited or wat2wasm_result.Exited != 0) {
            return error.WatToWasmFailed;
        }

        std.debug.print("✅ Converted to {s}\n", .{wasm_path});

        return wasm_path;
    }
};

/// Convenience function to run a ZigScript module
pub fn run(allocator: std.mem.Allocator, path: []const u8) !i32 {
    var wasm_engine = engine.Engine.init(allocator);
    defer wasm_engine.deinit();

    var loop = try event_loop.EventLoop.init(allocator);
    defer loop.deinit();

    var loader = ZigScriptLoader.init(allocator, &wasm_engine, &loop);

    // Check file extension
    if (std.mem.endsWith(u8, path, ".zs")) {
        return loader.loadSource(path);
    } else if (std.mem.endsWith(u8, path, ".wasm")) {
        return loader.run(path);
    } else {
        return error.UnsupportedFileType;
    }
}
