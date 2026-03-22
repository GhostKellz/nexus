const std = @import("std");
const interpreter = @import("interpreter.zig");

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

    pub fn read(self: *Memory, offset: u32, len: u32) ![]const u8 {
        if (offset + len > self.data.len) return error.OutOfBounds;
        return self.data[offset .. offset + len];
    }

    pub fn write(self: *Memory, offset: u32, data: []const u8) !void {
        if (offset + data.len > self.data.len) return error.OutOfBounds;
        @memcpy(self.data[offset .. offset + data.len], data);
    }

    /// Zero-copy read: returns direct pointer into WASM memory
    /// SAFETY: Pointer is only valid until next memory operation
    pub fn readZeroCopy(self: *Memory, offset: u32, len: u32) ![]const u8 {
        if (offset + len > self.data.len) return error.OutOfBounds;
        return self.data[offset .. offset + len];
    }

    /// Zero-copy write: returns mutable slice into WASM memory
    /// SAFETY: Slice is only valid until next memory operation
    pub fn writeZeroCopy(self: *Memory, offset: u32, len: u32) ![]u8 {
        if (offset + len > self.data.len) return error.OutOfBounds;
        return self.data[offset .. offset + len];
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
        const type_size = @sizeOf(T);
        if (offset + type_size > self.data.len) return error.OutOfBounds;

        var value: T = undefined;
        @memcpy(std.mem.asBytes(&value), self.data[offset .. offset + type_size]);
        return value;
    }

    pub fn writeInt(self: *Memory, comptime T: type, offset: u32, value: T) !void {
        const type_size = @sizeOf(T);
        if (offset + type_size > self.data.len) return error.OutOfBounds;

        @memcpy(self.data[offset .. offset + type_size], std.mem.asBytes(&value));
    }
};

/// Host function signature
pub const HostFunction = *const fn (params: []const Value, allocator: std.mem.Allocator) anyerror![]Value;

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
            .host => |host_fn| try host_fn(params, self.allocator),
            .wasm => |bytecode| {
                var interp = try interpreter.Interpreter.init(self.allocator, self, params.len);
                defer interp.deinit();

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
            .host => |host_fn| try host_fn(params, self.allocator),
            .wasm => |bytecode| {
                // Create interpreter with locals = params.len + extra locals
                var interp = try interpreter.Interpreter.init(self.allocator, self, params.len);
                defer interp.deinit();

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

        func.* = Function{
            .name = try self.allocator.dupe(u8, name),
            .param_types = try self.allocator.dupe(ValueType, param_types),
            .return_types = try self.allocator.dupe(ValueType, return_types),
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

        func.* = Function{
            .name = try self.allocator.dupe(u8, name),
            .param_types = try self.allocator.dupe(ValueType, param_types),
            .return_types = try self.allocator.dupe(ValueType, return_types),
            .code = .{ .wasm = try self.allocator.dupe(u8, bytecode) },
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
        _ = wasm_bytes; // Will be used for actual WASM parsing

        const instance = try self.allocator.create(Instance);
        errdefer self.allocator.destroy(instance);

        instance.* = Instance.init(self.allocator);

        // Create default memory (1 page = 64KB)
        const memory = try self.allocator.create(Memory);
        errdefer self.allocator.destroy(memory);
        memory.* = try Memory.init(self.allocator, 1, 256);
        instance.memory = memory;

        try self.instances.append(self.allocator, instance);

        return instance;
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

test "wasm instance" {
    const allocator = std.testing.allocator;

    var instance = Instance.init(allocator);
    defer instance.deinit();

    // Register a simple host function
    const addFn = struct {
        fn add(params: []const Value, alloc: std.mem.Allocator) ![]Value {
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
