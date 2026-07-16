const std = @import("std");
const interpreter = @import("interpreter.zig");
const policy_mod = @import("policy.zig");

/// WASM value types
pub const ValueType = enum {
    i32,
    i64,
    f32,
    f64,

    pub fn fromByte(byte: u8) !ValueType {
        return switch (byte) {
            0x7F => .i32,
            0x7E => .i64,
            0x7D => .f32,
            0x7C => .f64,
            else => error.InvalidValueType,
        };
    }
};

/// WASM value
pub const Value = union(ValueType) {
    i32: i32,
    i64: i64,
    f32: f32,
    f64: f64,

    pub fn fromZig(value: anytype) Value {
        const T = @TypeOf(value);
        return switch (@typeInfo(T)) {
            .int => |int_info| {
                if (int_info.bits <= 32) {
                    return Value{ .i32 = @intCast(value) };
                } else {
                    return Value{ .i64 = @intCast(value) };
                }
            },
            .float => |float_info| {
                if (float_info.bits <= 32) {
                    return Value{ .f32 = @floatCast(value) };
                } else {
                    return Value{ .f64 = @floatCast(value) };
                }
            },
            else => @compileError("Unsupported type for WASM value"),
        };
    }

    pub fn toInt(self: Value, comptime T: type) T {
        return switch (self) {
            .i32 => |v| @intCast(v),
            .i64 => |v| @intCast(v),
            .f32 => |v| @intFromFloat(v),
            .f64 => |v| @intFromFloat(v),
        };
    }

    pub fn toFloat(self: Value, comptime T: type) T {
        return switch (self) {
            .i32 => |v| @floatFromInt(v),
            .i64 => |v| @floatFromInt(v),
            .f32 => |v| @floatCast(v),
            .f64 => |v| @floatCast(v),
        };
    }
};

/// WASM memory
pub const Memory = struct {
    data: []u8,
    min_pages: u32,
    max_pages: ?u32,
    allocator: std.mem.Allocator,

    const PAGE_SIZE = 65536; // 64KB

    pub fn init(allocator: std.mem.Allocator, min_pages: u32, max_pages: ?u32) !Memory {
        const mem_size = min_pages * PAGE_SIZE;
        const data = try allocator.alloc(u8, mem_size);
        @memset(data, 0);

        return Memory{
            .data = data,
            .min_pages = min_pages,
            .max_pages = max_pages,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Memory) void {
        self.allocator.free(self.data);
    }

    pub fn grow(self: *Memory, pages: u32) !u32 {
        const old_pages = @as(u32, @intCast(self.data.len / PAGE_SIZE));
        const new_pages = old_pages + pages;

        if (self.max_pages) |max| {
            if (new_pages > max) return error.MemoryGrowFailed;
        }

        const new_size = new_pages * PAGE_SIZE;
        const new_data = try self.allocator.realloc(self.data, new_size);
        @memset(new_data[self.data.len..], 0);
        self.data = new_data;

        return old_pages;
    }

    pub fn size(self: *Memory) u32 {
        return @intCast(self.data.len / PAGE_SIZE);
    }

    /// Compute the exclusive end index of a `[offset, offset+len)` span and
    /// verify it lies within the current memory. The addition is performed in
    /// `usize` with overflow detection, so a hostile `offset`/`len` pair is
    /// rejected as `OutOfBounds` identically in every build mode: it can
    /// neither trap on `u32` overflow in a safe build nor wrap past the bound
    /// in a fast build (the classic unchecked-`offset + len` bypass).
    fn boundsEnd(self: *Memory, offset: u32, len: usize) !usize {
        const end = std.math.add(usize, offset, len) catch return error.OutOfBounds;
        if (end > self.data.len) return error.OutOfBounds;
        return end;
    }

    pub fn read(self: *Memory, offset: u32, len: u32) ![]const u8 {
        const end = try self.boundsEnd(offset, len);
        return self.data[offset..end];
    }

    pub fn write(self: *Memory, offset: u32, data: []const u8) !void {
        const end = try self.boundsEnd(offset, data.len);
        @memcpy(self.data[offset..end], data);
    }

    /// Zero-copy read: returns direct pointer into WASM memory
    /// SAFETY: Pointer is only valid until next memory operation
    pub fn readZeroCopy(self: *Memory, offset: u32, len: u32) ![]const u8 {
        const end = try self.boundsEnd(offset, len);
        return self.data[offset..end];
    }

    /// Zero-copy write: returns mutable slice into WASM memory
    /// SAFETY: Slice is only valid until next memory operation
    pub fn writeZeroCopy(self: *Memory, offset: u32, len: u32) ![]u8 {
        const end = try self.boundsEnd(offset, len);
        return self.data[offset..end];
    }

    /// Map host buffer into WASM memory without copying
    /// Returns offset where buffer was mapped
    pub fn mapBuffer(self: *Memory, host_buffer: []const u8) !u32 {
        // Find free space in memory
        const offset = @as(u32, @intCast(self.data.len));

        // Grow memory if needed
        const pages_needed = (host_buffer.len + PAGE_SIZE - 1) / PAGE_SIZE;
        if (pages_needed > 0) {
            _ = try self.grow(@intCast(pages_needed));
        }

        // Write buffer (in real zero-copy implementation, would use mmap)
        @memcpy(self.data[offset .. offset + host_buffer.len], host_buffer);

        return offset;
    }

    /// Get direct pointer to memory for external engines (Wasmer/Wasmtime)
    pub fn getDataPtr(self: *Memory) [*]u8 {
        return self.data.ptr;
    }

    /// Get memory size for external engines
    pub fn getDataLen(self: *Memory) usize {
        return self.data.len;
    }

    pub fn readInt(self: *Memory, comptime T: type, offset: u32) !T {
        const end = try self.boundsEnd(offset, @sizeOf(T));

        var value: T = undefined;
        @memcpy(std.mem.asBytes(&value), self.data[offset..end]);
        return value;
    }

    pub fn writeInt(self: *Memory, comptime T: type, offset: u32, value: T) !void {
        const end = try self.boundsEnd(offset, @sizeOf(T));

        @memcpy(self.data[offset..end], std.mem.asBytes(&value));
    }
};

/// Host function signature.
///
/// The invoking `*Instance` is passed so a host implementation can reach its
/// own per-instance state via `instance.user_context` instead of a process
/// global. This mirrors the "caller" handle in mainstream WASM runtimes and
/// keeps host calls instance-scoped: no cross-instance clobbering, and no
/// dangling pointer once the owning context is torn down.
pub const HostFunction = *const fn (instance: *Instance, params: []const Value, allocator: std.mem.Allocator) anyerror![]Value;

/// WASM function
pub const Function = struct {
    name: []const u8,
    param_types: []const ValueType,
    return_types: []const ValueType,
    code: union(enum) {
        host: HostFunction,
        wasm: []const u8,
    },
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Function) void {
        self.allocator.free(self.name);
        self.allocator.free(self.param_types);
        self.allocator.free(self.return_types);
        if (self.code == .wasm) {
            self.allocator.free(self.code.wasm);
        }
    }
};

/// WASM module instance
pub const Instance = struct {
    memory: ?*Memory = null,
    functions: std.StringHashMap(*Function),
    globals: std.StringHashMap(Value),
    /// Function table for indirect calls (call_indirect instruction)
    function_table: std.ArrayList(*Function),
    allocator: std.mem.Allocator,
    /// Opaque per-instance state a host embedder binds before running the
    /// module. Host functions receive the
    /// instance and read this instead of a shared global, so concurrent or
    /// sequential instances never clobber one another. The embedder owns the
    /// pointee and must clear it on teardown.
    user_context: ?*anyopaque = null,
    /// Optional execution policy. When set, every interpreter this instance
    /// spawns is bound to it (see `Interpreter.bindPolicy`), so the policy's
    /// stack-depth, instruction, and memory-page budgets are enforced during
    /// execution instead of relying on callers to invoke standalone checks.
    /// The embedder owns the pointee and must outlive any in-flight call.
    policy: ?*const policy_mod.WasmPolicy = null,

    pub fn init(allocator: std.mem.Allocator) Instance {
        return Instance{
            .functions = std.StringHashMap(*Function).init(allocator),
            .globals = std.StringHashMap(Value).init(allocator),
            .function_table = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Instance) void {
        if (self.memory) |mem| {
            mem.deinit();
            self.allocator.destroy(mem);
        }

        var func_it = self.functions.iterator();
        while (func_it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.functions.deinit();

        self.globals.deinit();
        self.function_table.deinit(self.allocator);
    }

    /// Add a function to the function table for indirect calls
    pub fn addToTable(self: *Instance, func: *Function) !u32 {
        const index: u32 = @intCast(self.function_table.items.len);
        try self.function_table.append(self.allocator, func);
        return index;
    }

    /// Get a function from the table by index
    pub fn getTableFunction(self: *Instance, index: u32) ?*Function {
        if (index >= self.function_table.items.len) return null;
        return self.function_table.items[index];
    }

    /// Call a function indirectly by table index (for call_indirect instruction)
    pub fn callIndirect(self: *Instance, table_index: u32, params: []const Value) ![]Value {
        const func = self.getTableFunction(table_index) orelse return error.TableIndexOutOfBounds;

        // Validate parameters
        if (params.len != func.param_types.len) {
            return error.InvalidParameterCount;
        }

        return switch (func.code) {
            .host => |host_fn| try host_fn(self, params, self.allocator),
            .wasm => |bytecode| {
                var interp = try interpreter.Interpreter.init(self.allocator, self, params.len);
                defer interp.deinit();
                if (self.policy) |p| interp.bindPolicy(p);

                for (params, 0..) |param, i| {
                    try interp.locals.set(@intCast(i), param);
                }

                return try interp.execute(bytecode);
            },
        };
    }

    pub fn getFunction(self: *Instance, name: []const u8) ?*Function {
        return self.functions.get(name);
    }

    pub fn getMemory(self: *Instance) ?*Memory {
        return self.memory;
    }

    pub fn getGlobal(self: *Instance, name: []const u8) ?Value {
        return self.globals.get(name);
    }

    pub fn setGlobal(self: *Instance, name: []const u8, value: Value) !void {
        try self.globals.put(name, value);
    }

    pub fn call(self: *Instance, name: []const u8, params: []const Value) ![]Value {
        const func = self.getFunction(name) orelse return error.FunctionNotFound;

        // Validate parameters
        if (params.len != func.param_types.len) {
            return error.InvalidParameterCount;
        }

        return switch (func.code) {
            .host => |host_fn| try host_fn(self, params, self.allocator),
            .wasm => |bytecode| {
                // Create interpreter with locals = params.len + extra locals
                var interp = try interpreter.Interpreter.init(self.allocator, self, params.len);
                defer interp.deinit();
                if (self.policy) |p| interp.bindPolicy(p);

                // Initialize parameters as locals
                for (params, 0..) |param, i| {
                    try interp.locals.set(@intCast(i), param);
                }

                // Execute bytecode
                return try interp.execute(bytecode);
            },
        };
    }

    pub fn registerHostFunction(
        self: *Instance,
        name: []const u8,
        param_types: []const ValueType,
        return_types: []const ValueType,
        host_fn: HostFunction,
    ) !void {
        const func = try self.allocator.create(Function);
        errdefer self.allocator.destroy(func);

        // Dupe each owned field into a local guarded by its own errdefer so a
        // partial failure (a later dupe, or the final `put`) frees only what was
        // actually allocated. Destroying `func` alone would leak these dupes,
        // because the struct is not yet reachable for `deinit`.
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);

        const param_copy = try self.allocator.dupe(ValueType, param_types);
        errdefer self.allocator.free(param_copy);

        const return_copy = try self.allocator.dupe(ValueType, return_types);
        errdefer self.allocator.free(return_copy);

        func.* = Function{
            .name = name_copy,
            .param_types = param_copy,
            .return_types = return_copy,
            .code = .{ .host = host_fn },
            .allocator = self.allocator,
        };

        try self.functions.put(name, func);
    }

    pub fn registerWasmFunction(
        self: *Instance,
        name: []const u8,
        param_types: []const ValueType,
        return_types: []const ValueType,
        bytecode: []const u8,
    ) !void {
        const func = try self.allocator.create(Function);
        errdefer self.allocator.destroy(func);

        // Same ownership discipline as registerHostFunction: each dupe is guarded
        // by its own errdefer so a later dupe or the final `put` failing frees
        // exactly the allocations made so far rather than leaking them.
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);

        const param_copy = try self.allocator.dupe(ValueType, param_types);
        errdefer self.allocator.free(param_copy);

        const return_copy = try self.allocator.dupe(ValueType, return_types);
        errdefer self.allocator.free(return_copy);

        const bytecode_copy = try self.allocator.dupe(u8, bytecode);
        errdefer self.allocator.free(bytecode_copy);

        func.* = Function{
            .name = name_copy,
            .param_types = param_copy,
            .return_types = return_copy,
            .code = .{ .wasm = bytecode_copy },
            .allocator = self.allocator,
        };

        try self.functions.put(name, func);
    }
};

/// Simple WASM module loader
pub const Module = struct {
    instances: std.ArrayList(*Instance),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Module {
        return Module{
            .instances = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Module) void {
        for (self.instances.items) |instance| {
            instance.deinit();
            self.allocator.destroy(instance);
        }
        self.instances.deinit(self.allocator);
    }

    pub fn instantiate(self: *Module, wasm_bytes: []const u8) !*Instance {
        _ = self;
        _ = wasm_bytes;
        // There is no WASM binary parser yet, so the module's declared memories,
        // tables, globals, imports, and functions cannot be honored. The prior
        // behaviour ignored the bytes entirely and fabricated an instance with a
        // hard-coded one-page memory and no functions — an object that looks
        // instantiated but shares nothing with the module on disk, so callers
        // silently ran against a fiction. Fail closed instead: instantiation is
        // unsupported until a parser exists. (Removes the "hard-coded one-page
        // memory regardless of module contents" defect.)
        return error.WasmParsingUnsupported;
    }

    pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Module {
        const cwd = std.Io.Dir.cwd();
        const wasm_bytes = try cwd.readFileAlloc(
            io,
            path,
            allocator,
            std.Io.Limit.limited(10 * 1024 * 1024), // 10MB max
        );
        defer allocator.free(wasm_bytes);

        var module = Module.init(allocator);
        _ = try module.instantiate(wasm_bytes);

        return module;
    }
};

/// WASM engine
pub const Engine = struct {
    modules: std.ArrayList(*Module),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Engine {
        return Engine{
            .modules = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Engine) void {
        for (self.modules.items) |module| {
            module.deinit();
            self.allocator.destroy(module);
        }
        self.modules.deinit(self.allocator);
    }

    pub fn loadModule(self: *Engine, io: std.Io, path: []const u8) !*Module {
        const module_ptr = try self.allocator.create(Module);
        errdefer self.allocator.destroy(module_ptr);

        module_ptr.* = try Module.load(self.allocator, io, path);
        try self.modules.append(self.allocator, module_ptr);

        return module_ptr;
    }

    pub fn createModule(self: *Engine) !*Module {
        const module_ptr = try self.allocator.create(Module);
        errdefer self.allocator.destroy(module_ptr);

        module_ptr.* = Module.init(self.allocator);
        try self.modules.append(self.allocator, module_ptr);

        return module_ptr;
    }
};

test "wasm value conversion" {
    const val_i32 = Value.fromZig(@as(i32, 42));
    try std.testing.expectEqual(@as(i32, 42), val_i32.i32);

    const val_f64 = Value.fromZig(@as(f64, 3.14));
    try std.testing.expectEqual(@as(f64, 3.14), val_f64.f64);
}

test "wasm memory" {
    const allocator = std.testing.allocator;

    var memory = try Memory.init(allocator, 1, 10);
    defer memory.deinit();

    // Test write/read
    const data = "Hello, WASM!";
    try memory.write(0, data);

    const read_data = try memory.read(0, @intCast(data.len));
    try std.testing.expectEqualStrings(data, read_data);

    // Test int read/write
    try memory.writeInt(u32, 100, 0xDEADBEEF);
    const value = try memory.readInt(u32, 100);
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), value);

    // Test memory growth
    const old_pages = try memory.grow(1);
    try std.testing.expectEqual(@as(u32, 1), old_pages);
    try std.testing.expectEqual(@as(u32, 2), memory.size());
}

test "wasm memory bounds reject overflowing offset+len" {
    const allocator = std.testing.allocator;

    var memory = try Memory.init(allocator, 1, 10);
    defer memory.deinit();
    const cap: u32 = @intCast(memory.data.len);

    // A plainly out-of-range span is rejected.
    try std.testing.expectError(error.OutOfBounds, memory.read(cap, 1));
    try std.testing.expectError(error.OutOfBounds, memory.read(0, cap + 1));

    // The critical case: offset + len overflows u32. With the old
    // `offset + len` check this either traps (safe builds) or wraps to a
    // small value that passes the bound (fast builds), permitting an
    // out-of-bounds slice. It must fail closed as OutOfBounds instead.
    try std.testing.expectError(error.OutOfBounds, memory.read(0xFFFF_FFFF, 2));
    try std.testing.expectError(error.OutOfBounds, memory.read(0xFFFF_F000, 0xFFFF));
    try std.testing.expectError(error.OutOfBounds, memory.readZeroCopy(0xFFFF_FFFF, 16));
    try std.testing.expectError(error.OutOfBounds, memory.writeZeroCopy(0xFFFF_FFF0, 0x20));
    try std.testing.expectError(error.OutOfBounds, memory.write(0xFFFF_FFFF, "xx"));

    // readInt/writeInt use the same guard against a wrapped end index.
    try std.testing.expectError(error.OutOfBounds, memory.readInt(u32, 0xFFFF_FFFF));
    try std.testing.expectError(error.OutOfBounds, memory.writeInt(u64, 0xFFFF_FFFE, 0));

    // A valid span at the very end still succeeds — the guard is exact,
    // not merely conservative.
    try memory.writeInt(u32, cap - 4, 0x1234_5678);
    try std.testing.expectEqual(@as(u32, 0x1234_5678), try memory.readInt(u32, cap - 4));
}

test "wasm instance" {
    const allocator = std.testing.allocator;

    var instance = Instance.init(allocator);
    defer instance.deinit();

    // Register a simple host function
    const addFn = struct {
        fn add(_: *Instance, params: []const Value, alloc: std.mem.Allocator) ![]Value {
            const result = try alloc.alloc(Value, 1);
            result[0] = Value{ .i32 = params[0].i32 + params[1].i32 };
            return result;
        }
    }.add;

    const param_types = [_]ValueType{ .i32, .i32 };
    const return_types = [_]ValueType{.i32};

    try instance.registerHostFunction("add", &param_types, &return_types, addFn);

    // Call the function
    const params = [_]Value{ Value{ .i32 = 10 }, Value{ .i32 = 32 } };
    const results = try instance.call("add", &params);
    defer allocator.free(results);

    try std.testing.expectEqual(@as(i32, 42), results[0].i32);
}

test "module instantiate fails closed instead of fabricating a fake instance" {
    // Guards the removed "hard-coded one-page memory regardless of module
    // contents" defect: with no binary parser, instantiate must refuse rather
    // than return an instance that shares nothing with the module bytes. A
    // syntactically-plausible header (magic + version) still yields no fiction.
    const allocator = std.testing.allocator;
    var module = Module.init(allocator);
    defer module.deinit();

    const header = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    try std.testing.expectError(error.WasmParsingUnsupported, module.instantiate(&header));
    // Nothing was appended, so deinit has no fabricated instance to free.
    try std.testing.expectEqual(@as(usize, 0), module.instances.items.len);
}

test "repeated instance create/register/call/destroy cycles are leak-free" {
    // Phase 2 exit gate: drive the module-loader lifecycle end to end many
    // times so std.testing.allocator catches any per-cycle leak or double free
    // in registerHostFunction/registerWasmFunction (each dupes name + param /
    // return type slices + wasm body) and Instance.deinit (which frees them).
    const allocator = std.testing.allocator;

    const addFn = struct {
        fn add(_: *Instance, params: []const Value, alloc: std.mem.Allocator) ![]Value {
            const result = try alloc.alloc(Value, 1);
            result[0] = Value{ .i32 = params[0].i32 + params[1].i32 };
            return result;
        }
    }.add;

    const param_types = [_]ValueType{ .i32, .i32 };
    const return_types = [_]ValueType{.i32};

    var cycle: usize = 0;
    while (cycle < 256) : (cycle += 1) {
        var instance = Instance.init(allocator);
        defer instance.deinit();

        try instance.registerHostFunction("add", &param_types, &return_types, addFn);
        try instance.registerWasmFunction("body", &param_types, &return_types, &[_]u8{ 0x00, 0x0b });

        const params = [_]Value{ Value{ .i32 = 10 }, Value{ .i32 = 32 } };
        const results = try instance.call("add", &params);
        defer allocator.free(results);
        try std.testing.expectEqual(@as(i32, 42), results[0].i32);
    }
}
