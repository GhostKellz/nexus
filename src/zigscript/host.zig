const std = @import("std");
const nexus = @import("nexus");
const engine = nexus.wasm;
const event_loop = nexus.runtime;
const http = nexus.http;

/// ZigScript host function implementations
/// These functions are imported by ZigScript WASM modules as "std" namespace

const Value = engine.Value;
const Memory = engine.Memory;
const Instance = engine.Instance;

/// Promise registry for async operations
pub const PromiseRegistry = struct {
    promises: std.AutoHashMap(u32, Promise),
    next_id: u32 = 1,
    allocator: std.mem.Allocator,

    const Promise = struct {
        state: State,
        result: ?[]const u8 = null,
        error_msg: ?[]const u8 = null,

        const State = enum {
            pending,
            resolved,
            rejected,
        };

        pub fn deinit(self: *Promise, allocator: std.mem.Allocator) void {
            if (self.result) |r| allocator.free(r);
            if (self.error_msg) |e| allocator.free(e);
        }
    };

    pub fn init(allocator: std.mem.Allocator) PromiseRegistry {
        return .{
            .promises = std.AutoHashMap(u32, Promise).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PromiseRegistry) void {
        var it = self.promises.iterator();
        while (it.next()) |entry| {
            var promise = entry.value_ptr.*;
            promise.deinit(self.allocator);
        }
        self.promises.deinit();
    }

    pub fn create(self: *PromiseRegistry) !u32 {
        const id = self.next_id;
        self.next_id += 1;

        try self.promises.put(id, .{ .state = .pending });
        return id;
    }

    pub fn resolve(self: *PromiseRegistry, id: u32, result: []const u8) !void {
        const gop = try self.promises.getOrPut(id);
        if (!gop.found_existing) return error.PromiseNotFound;

        const result_copy = try self.allocator.dupe(u8, result);
        gop.value_ptr.*.state = .resolved;
        gop.value_ptr.*.result = result_copy;
    }

    pub fn reject(self: *PromiseRegistry, id: u32, err_msg: []const u8) !void {
        const gop = try self.promises.getOrPut(id);
        if (!gop.found_existing) return error.PromiseNotFound;

        const error_copy = try self.allocator.dupe(u8, err_msg);
        gop.value_ptr.*.state = .rejected;
        gop.value_ptr.*.error_msg = error_copy;
    }

    pub fn getState(self: *PromiseRegistry, id: u32) ?Promise.State {
        const promise = self.promises.get(id) orelse return null;
        return promise.state;
    }

    pub fn getResult(self: *PromiseRegistry, id: u32) ?[]const u8 {
        const promise = self.promises.get(id) orelse return null;
        return promise.result;
    }
};

/// ZigScript runtime context
pub const ZigScriptContext = struct {
    instance: *Instance,
    memory: *Memory,
    promises: PromiseRegistry,
    event_loop: *event_loop.EventLoop,
    allocator: std.mem.Allocator,
    next_string_offset: u32 = 8192, // Start after reserved memory

    pub fn init(
        allocator: std.mem.Allocator,
        instance: *Instance,
        loop: *event_loop.EventLoop,
    ) !ZigScriptContext {
        const memory = instance.getMemory() orelse return error.NoMemory;

        return .{
            .instance = instance,
            .memory = memory,
            .promises = PromiseRegistry.init(allocator),
            .event_loop = loop,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ZigScriptContext) void {
        self.promises.deinit();
    }

    /// Read string from WASM memory (length-prefixed format)
    pub fn readString(self: *ZigScriptContext, ptr: u32) ![]const u8 {
        // Read length (4 bytes)
        const len = try self.memory.readInt(u32, ptr);

        // Read string data
        const str_data = try self.memory.read(ptr + 4, len);

        // Return a copy that we own
        return try self.allocator.dupe(u8, str_data);
    }

    /// Write string to WASM memory (length-prefixed format)
    pub fn writeString(self: *ZigScriptContext, str: []const u8) !u32 {
        const ptr = self.next_string_offset;

        // Write length
        try self.memory.writeInt(u32, ptr, @intCast(str.len));

        // Write string data
        try self.memory.write(ptr + 4, str);

        // Update offset for next allocation
        self.next_string_offset += 4 + @as(u32, @intCast(str.len));

        // Align to 4 bytes
        self.next_string_offset = (self.next_string_offset + 3) & ~@as(u32, 3);

        return ptr;
    }
};

/// Global context (set by the runtime before calling WASM)
var global_context: ?*ZigScriptContext = null;

pub fn setContext(ctx: *ZigScriptContext) void {
    global_context = ctx;
}

fn getContext() *ZigScriptContext {
    return global_context orelse @panic("ZigScript context not initialized");
}

// ============================================================================
// Host Functions - JSON
// ============================================================================

/// json_decode(json_ptr: i32, type_ptr: i32) -> i32
pub fn json_decode(params: []const Value, allocator: std.mem.Allocator) ![]Value {
    const ctx = getContext();

    const json_ptr = params[0].toInt(u32);
    // type_ptr is currently unused - would be used for type validation

    // Read JSON string from WASM memory
    const json_str = try ctx.readString(json_ptr);
    defer allocator.free(json_str);

    // Parse JSON using std.json
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        json_str,
        .{},
    );
    defer parsed.deinit();

    // For now, just write the JSON string back
    // In a full implementation, we'd convert to WASM struct
    const result_ptr = try ctx.writeString(json_str);

    const result = try allocator.alloc(Value, 1);
    result[0] = Value.fromZig(result_ptr);
    return result;
}

/// json_encode(value_ptr: i32) -> i32
pub fn json_encode(params: []const Value, allocator: std.mem.Allocator) ![]Value {
    const ctx = getContext();

    const value_ptr = params[0].toInt(u32);

    // For now, read a string value and encode it as JSON
    // In a full implementation, we'd read the struct and serialize it
    const value_str = try ctx.readString(value_ptr);
    defer allocator.free(value_str);

    // Simple JSON encoding (just wrap in quotes for string)
    const json_str = try std.fmt.allocPrint(allocator, "\"{s}\"", .{value_str});
    defer allocator.free(json_str);

    const result_ptr = try ctx.writeString(json_str);

    const result = try allocator.alloc(Value, 1);
    result[0] = Value.fromZig(result_ptr);
    return result;
}

// ============================================================================
// Host Functions - HTTP
// ============================================================================

/// http_get(url_ptr: i32, headers_ptr: i32) -> i32 (promise_id)
pub fn http_get(params: []const Value, allocator: std.mem.Allocator) ![]Value {
    const ctx = getContext();

    const url_ptr = params[0].toInt(u32);
    const url = try ctx.readString(url_ptr);
    defer allocator.free(url);

    // Create promise for async operation
    const promise_id = try ctx.promises.create();

    // Spawn async HTTP request task
    const HttpTask = struct {
        promise_id: u32,
        url: []const u8,
        ctx: *ZigScriptContext,

        fn execute(task: *event_loop.Task) !void {
            const self: *@This() = @ptrCast(@alignCast(task.context.?));

            // Make real HTTP request
            var client = http.Client.init(self.ctx.allocator) catch |err| {
                const err_msg = try std.fmt.allocPrint(
                    self.ctx.allocator,
                    "HTTP client init error: {any}",
                    .{err},
                );
                defer self.ctx.allocator.free(err_msg);
                try self.ctx.promises.reject(self.promise_id, err_msg);

                self.ctx.allocator.free(self.url);
                self.ctx.allocator.destroy(self);
                return;
            };
            defer client.deinit();

            const response_body = client.get(self.url) catch |err| {
                const err_msg = try std.fmt.allocPrint(
                    self.ctx.allocator,
                    "HTTP GET error: {any}",
                    .{err},
                );
                defer self.ctx.allocator.free(err_msg);
                try self.ctx.promises.reject(self.promise_id, err_msg);

                self.ctx.allocator.free(self.url);
                self.ctx.allocator.destroy(self);
                return;
            };
            defer self.ctx.allocator.free(response_body);

            try self.ctx.promises.resolve(self.promise_id, response_body);

            self.ctx.allocator.free(self.url);
            self.ctx.allocator.destroy(self);
        }
    };

    const task_data = try allocator.create(HttpTask);
    task_data.* = .{
        .promise_id = promise_id,
        .url = try allocator.dupe(u8, url),
        .ctx = ctx,
    };

    try ctx.event_loop.task_queue.enqueueWithContext(
        HttpTask.execute,
        task_data,
    );

    const result = try allocator.alloc(Value, 1);
    result[0] = Value.fromZig(promise_id);
    return result;
}

/// http_post(url_ptr: i32, headers_ptr: i32, body_ptr: i32, body_len: i32) -> i32 (promise_id)
pub fn http_post(params: []const Value, allocator: std.mem.Allocator) ![]Value {
    const ctx = getContext();

    const url_ptr = params[0].toInt(u32);
    const body_ptr = params[2].toInt(u32);

    const url = try ctx.readString(url_ptr);
    defer allocator.free(url);

    const body = try ctx.readString(body_ptr);
    defer allocator.free(body);

    // Create promise
    const promise_id = try ctx.promises.create();

    // Spawn async HTTP POST task
    const HttpPostTask = struct {
        promise_id: u32,
        url: []const u8,
        body: []const u8,
        ctx: *ZigScriptContext,

        fn execute(task: *event_loop.Task) !void {
            const self: *@This() = @ptrCast(@alignCast(task.context.?));

            // Make real HTTP POST request
            var client = http.Client.init(self.ctx.allocator) catch |err| {
                const err_msg = try std.fmt.allocPrint(
                    self.ctx.allocator,
                    "HTTP client init error: {any}",
                    .{err},
                );
                defer self.ctx.allocator.free(err_msg);
                try self.ctx.promises.reject(self.promise_id, err_msg);

                self.ctx.allocator.free(self.url);
                self.ctx.allocator.free(self.body);
                self.ctx.allocator.destroy(self);
                return;
            };
            defer client.deinit();

            const response_body = client.post(self.url, self.body, "application/json") catch |err| {
                const err_msg = try std.fmt.allocPrint(
                    self.ctx.allocator,
                    "HTTP POST error: {any}",
                    .{err},
                );
                defer self.ctx.allocator.free(err_msg);
                try self.ctx.promises.reject(self.promise_id, err_msg);

                self.ctx.allocator.free(self.url);
                self.ctx.allocator.free(self.body);
                self.ctx.allocator.destroy(self);
                return;
            };
            defer self.ctx.allocator.free(response_body);

            try self.ctx.promises.resolve(self.promise_id, response_body);

            self.ctx.allocator.free(self.url);
            self.ctx.allocator.free(self.body);
            self.ctx.allocator.destroy(self);
        }
    };

    const task_data = try allocator.create(HttpPostTask);
    task_data.* = .{
        .promise_id = promise_id,
        .url = try allocator.dupe(u8, url),
        .body = try allocator.dupe(u8, body),
        .ctx = ctx,
    };

    try ctx.event_loop.task_queue.enqueueWithContext(
        HttpPostTask.execute,
        task_data,
    );

    const result = try allocator.alloc(Value, 1);
    result[0] = Value.fromZig(promise_id);
    return result;
}

// ============================================================================
// Host Functions - File System
// ============================================================================

/// fs_read_file(path_ptr: i32, encoding_ptr: i32) -> i32 (promise_id)
pub fn fs_read_file(params: []const Value, allocator: std.mem.Allocator) ![]Value {
    const ctx = getContext();

    const path_ptr = params[0].toInt(u32);
    const path = try ctx.readString(path_ptr);
    defer allocator.free(path);

    // Create promise
    const promise_id = try ctx.promises.create();

    // Read file asynchronously
    const file_content = std.fs.cwd().readFileAlloc(
        path,
        allocator,
        std.Io.Limit.limited(10 * 1024 * 1024), // 10MB max
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(allocator, "File error: {}", .{err});
        defer allocator.free(err_msg);
        try ctx.promises.reject(promise_id, err_msg);

        const result = try allocator.alloc(Value, 1);
        result[0] = Value.fromZig(promise_id);
        return result;
    };

    try ctx.promises.resolve(promise_id, file_content);
    allocator.free(file_content);

    const result = try allocator.alloc(Value, 1);
    result[0] = Value.fromZig(promise_id);
    return result;
}

/// fs_write_file(path_ptr: i32, content_ptr: i32, encoding_ptr: i32, flags: i32) -> i32 (promise_id)
pub fn fs_write_file(params: []const Value, allocator: std.mem.Allocator) ![]Value {
    const ctx = getContext();

    const path_ptr = params[0].toInt(u32);
    const content_ptr = params[1].toInt(u32);

    const path = try ctx.readString(path_ptr);
    defer allocator.free(path);

    const content = try ctx.readString(content_ptr);
    defer allocator.free(content);

    // Create promise
    const promise_id = try ctx.promises.create();

    // Write file
    std.fs.cwd().writeFile(.{ .sub_path = path, .data = content }) catch |err| {
        const err_msg = try std.fmt.allocPrint(allocator, "Write error: {}", .{err});
        defer allocator.free(err_msg);
        try ctx.promises.reject(promise_id, err_msg);

        const result = try allocator.alloc(Value, 1);
        result[0] = Value.fromZig(promise_id);
        return result;
    };

    try ctx.promises.resolve(promise_id, "");

    const result = try allocator.alloc(Value, 1);
    result[0] = Value.fromZig(promise_id);
    return result;
}

// ============================================================================
// Host Functions - Timers
// ============================================================================

/// set_timeout(callback_index: i32, delay: i32) -> i32 (timer_id)
pub fn set_timeout(params: []const Value, allocator: std.mem.Allocator) ![]Value {
    const ctx = getContext();

    const callback_index = params[0].toInt(u32);
    const delay = params[1].toInt(u64);

    // Create timer callback
    const TimerData = struct {
        callback_index: u32,
        instance: *Instance,

        fn callback(timer: *event_loop.Timer) void {
            const self: *@This() = @ptrCast(@alignCast(timer.data.?));

            // Call WASM function from function table
            // TODO: Implement function table calls
            _ = self.callback_index;
            _ = self.instance;
        }
    };

    const timer_data = try allocator.create(TimerData);
    timer_data.* = .{
        .callback_index = callback_index,
        .instance = ctx.instance,
    };

    const timer_id = try ctx.event_loop.setTimeout(delay, TimerData.callback);

    const result = try allocator.alloc(Value, 1);
    result[0] = Value.fromZig(@as(u32, @intCast(timer_id)));
    return result;
}

/// clear_timeout(timeout_id: i32)
pub fn clear_timeout(params: []const Value, allocator: std.mem.Allocator) ![]Value {
    const ctx = getContext();

    const timeout_id = params[0].toInt(u64);
    ctx.event_loop.clearTimer(timeout_id);

    // No return value (void)
    return try allocator.alloc(Value, 0);
}

// ============================================================================
// Host Functions - Async/Promises
// ============================================================================

/// promise_await(promise_id: i32) -> i32 (result_ptr or 0 if pending)
pub fn promise_await(params: []const Value, allocator: std.mem.Allocator) ![]Value {
    const ctx = getContext();

    const promise_id = params[0].toInt(u32);

    const state = ctx.promises.getState(promise_id) orelse return error.PromiseNotFound;

    const result = try allocator.alloc(Value, 1);

    switch (state) {
        .pending => {
            // Not ready yet, return 0
            result[0] = Value.fromZig(@as(u32, 0));
        },
        .resolved => {
            // Get result and write to memory
            const promise_result = ctx.promises.getResult(promise_id) orelse "";
            const result_ptr = try ctx.writeString(promise_result);
            result[0] = Value.fromZig(result_ptr);
        },
        .rejected => {
            // Error - for now return 0, should propagate error
            result[0] = Value.fromZig(@as(u32, 0));
        },
    }

    return result;
}

// ============================================================================
// Host Function Registration
// ============================================================================

/// Register all ZigScript host functions with a WASM instance
pub fn registerHostFunctions(instance: *Instance) !void {
    const param_i32 = [_]engine.ValueType{.i32};
    const param_i32_i32 = [_]engine.ValueType{ .i32, .i32 };
    const param_i32_i32_i32_i32 = [_]engine.ValueType{ .i32, .i32, .i32, .i32 };
    const return_i32 = [_]engine.ValueType{.i32};
    const return_void = [_]engine.ValueType{};

    // JSON functions
    try instance.registerHostFunction(
        "json_decode",
        &param_i32_i32,
        &return_i32,
        json_decode,
    );

    try instance.registerHostFunction(
        "json_encode",
        &param_i32,
        &return_i32,
        json_encode,
    );

    // HTTP functions
    try instance.registerHostFunction(
        "http_get",
        &param_i32_i32,
        &return_i32,
        http_get,
    );

    try instance.registerHostFunction(
        "http_post",
        &param_i32_i32_i32_i32,
        &return_i32,
        http_post,
    );

    // File system functions
    try instance.registerHostFunction(
        "fs_read_file",
        &param_i32_i32,
        &return_i32,
        fs_read_file,
    );

    try instance.registerHostFunction(
        "fs_write_file",
        &param_i32_i32_i32_i32,
        &return_i32,
        fs_write_file,
    );

    // Timer functions
    try instance.registerHostFunction(
        "set_timeout",
        &param_i32_i32,
        &return_i32,
        set_timeout,
    );

    try instance.registerHostFunction(
        "clear_timeout",
        &param_i32,
        &return_void,
        clear_timeout,
    );

    // Promise functions
    try instance.registerHostFunction(
        "promise_await",
        &param_i32,
        &return_i32,
        promise_await,
    );
}
