# Nexus Runtime Architecture

**System design for the next-generation Zig + WASM application runtime**

---

## Table of Contents

1. [System Overview](#1-system-overview)
2. [Core Components](#2-core-components)
3. [Event Loop Architecture](#3-event-loop-architecture)
4. [Module System](#4-module-system)
5. [WASM Integration](#5-wasm-integration)
6. [Memory Management](#6-memory-management)
7. [Standard Library Design](#7-standard-library-design)
8. [Security Architecture](#8-security-architecture)
9. [Performance Optimizations](#9-performance-optimizations)
10. [Implementation Plan](#10-implementation-plan)

---

## 1. System Overview

### 1.1 High-Level Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     User Application Code                    │
│                  (Zig modules + WASM modules)                │
└───────────────────────────┬─────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│                    Nexus Standard Library                    │
│  ┌──────────┬──────────┬──────────┬──────────┬──────────┐   │
│  │ Runtime  │   FS     │   Net    │  Stream  │  Crypto  │   │
│  │  Timer   │  Console │   WASM   │   HTTP   │   etc.   │   │
│  └──────────┴──────────┴──────────┴──────────┴──────────┘   │
└───────────────────────────┬─────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│                      Nexus Runtime Core                      │
│  ┌──────────────────┬───────────────────┬────────────────┐  │
│  │   Event Loop     │  Module Loader    │  WASM Engine   │  │
│  │  (epoll/kqueue)  │  (Native + WASM)  │ (Wasmer/time)  │  │
│  └──────────────────┴───────────────────┴────────────────┘  │
└───────────────────────────┬─────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│                     Operating System                         │
│            (Linux, macOS, Windows, FreeBSD)                  │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 Design Philosophy

**Principles:**
1. **Zero-Cost Abstractions** — No runtime overhead unless features are used
2. **Explicit Over Implicit** — No hidden magic, clear control flow
3. **Composability** — Small, focused modules that compose well
4. **Safety** — Memory safety, type safety, sandboxed execution
5. **Performance** — Native speed, minimal allocations, cache-friendly

**Trade-offs:**
- **Speed vs Ergonomics** → Favor speed, but provide ergonomic wrappers
- **Binary Size vs Features** → Tree-shaking to eliminate unused code
- **Security vs Flexibility** → Secure by default, opt-in for flexibility

---

## 2. Core Components

### 2.1 Component Directory Structure

```
nexus/
├── src/
│   ├── main.zig              # CLI entry point
│   ├── root.zig              # Library entry point
│   │
│   ├── runtime/              # Core runtime
│   │   ├── event_loop.zig    # Event loop implementation
│   │   ├── scheduler.zig     # Task scheduler
│   │   ├── timer.zig         # Timer heap
│   │   ├── signal.zig        # Signal handling
│   │   └── process.zig       # Process management
│   │
│   ├── module/               # Module system
│   │   ├── loader.zig        # Module loader
│   │   ├── resolver.zig      # Module resolution
│   │   ├── cache.zig         # Module cache
│   │   └── native.zig        # Native module support
│   │
│   ├── wasm/                 # WASM subsystem
│   │   ├── engine.zig        # WASM engine wrapper
│   │   ├── instance.zig      # WASM instance management
│   │   ├── host.zig          # Host functions
│   │   ├── memory.zig        # WASM memory management
│   │   └── policy.zig        # Security policy
│   │
│   ├── stdlib/               # Standard library
│   │   ├── fs/               # File system
│   │   │   ├── file.zig
│   │   │   ├── dir.zig
│   │   │   └── watch.zig
│   │   ├── net/              # Networking
│   │   │   ├── tcp.zig
│   │   │   ├── udp.zig
│   │   │   ├── http.zig
│   │   │   └── websocket.zig
│   │   ├── stream/           # Streams
│   │   │   ├── readable.zig
│   │   │   ├── writable.zig
│   │   │   └── transform.zig
│   │   ├── crypto/           # Cryptography
│   │   │   ├── hash.zig
│   │   │   ├── cipher.zig
│   │   │   └── random.zig
│   │   └── console/          # Console I/O
│   │       └── logger.zig
│   │
│   ├── cli/                  # CLI tool
│   │   ├── commands/
│   │   │   ├── run.zig
│   │   │   ├── build.zig
│   │   │   ├── init.zig
│   │   │   └── install.zig
│   │   └── cli.zig
│   │
│   └── util/                 # Utilities
│       ├── arena.zig         # Arena allocator
│       ├── buffer.zig        # Buffer utilities
│       └── error.zig         # Error handling
│
├── tests/                    # Test suite
│   ├── unit/
│   ├── integration/
│   └── benchmarks/
│
├── examples/                 # Example projects
│   ├── hello-world/
│   ├── http-server/
│   ├── wasm-compute/
│   └── edge-function/
│
└── docs/                     # Documentation
    ├── API.md
    ├── SPEC.md
    └── guides/
```

### 2.2 Component Dependencies

```
┌──────────────┐
│   CLI Tool   │
└──────┬───────┘
       │
       ▼
┌──────────────┐      ┌──────────────┐      ┌──────────────┐
│   Runtime    │◄─────│    Stdlib    │◄─────│  User Code   │
│  Event Loop  │      │   Modules    │      │   (App)      │
└──────┬───────┘      └──────┬───────┘      └──────┬───────┘
       │                     │                     │
       ▼                     ▼                     ▼
┌──────────────┐      ┌──────────────┐      ┌──────────────┐
│    Module    │      │     WASM     │      │   Package    │
│    Loader    │◄─────│    Engine    │      │   Manager    │
└──────────────┘      └──────────────┘      └──────────────┘
```

---

## 3. Event Loop Architecture

### 3.1 Event Loop Design

**Inspiration:** libuv (Node.js), Tokio (Rust), Go runtime

**Core Concept:** Single-threaded event loop with non-blocking I/O

```zig
pub const EventLoop = struct {
    allocator: std.mem.Allocator,
    io_poller: IoPoller,           // epoll/kqueue/IOCP
    timer_heap: TimerHeap,         // Min-heap of timers
    task_queue: TaskQueue,         // Pending tasks
    immediate_queue: ImmediateQueue, // setImmediate tasks
    is_running: bool,

    pub fn init(allocator: std.mem.Allocator) !EventLoop {
        return EventLoop{
            .allocator = allocator,
            .io_poller = try IoPoller.init(),
            .timer_heap = TimerHeap.init(allocator),
            .task_queue = TaskQueue.init(allocator),
            .immediate_queue = ImmediateQueue.init(allocator),
            .is_running = false,
        };
    }

    pub fn run(self: *EventLoop) !void {
        self.is_running = true;

        while (self.is_running) {
            // 1. Process immediate queue
            try self.processImmediates();

            // 2. Process expired timers
            try self.processTimers();

            // 3. Poll I/O events (with timeout)
            const timeout = self.calculateTimeout();
            const events = try self.io_poller.poll(timeout);

            // 4. Process I/O events
            try self.processIoEvents(events);

            // 5. Process task queue
            try self.processTasks();

            // 6. Check if should exit
            if (self.shouldExit()) break;
        }
    }

    fn calculateTimeout(self: *EventLoop) u64 {
        // Calculate timeout until next timer
        if (self.timer_heap.peek()) |timer| {
            const now = std.time.milliTimestamp();
            const diff = timer.deadline - now;
            return @max(0, diff);
        }
        return std.math.maxInt(u64); // Block indefinitely
    }
};
```

### 3.2 I/O Poller Abstraction

**Platform-specific implementations:**

```zig
pub const IoPoller = switch (builtin.os.tag) {
    .linux => EpollPoller,
    .macos, .freebsd => KqueuePoller,
    .windows => IocpPoller,
    else => @compileError("Unsupported platform"),
};

// Linux: epoll
const EpollPoller = struct {
    epoll_fd: i32,
    events: []std.os.linux.epoll_event,

    pub fn init() !EpollPoller {
        const epoll_fd = try std.os.epoll_create1(std.os.linux.EPOLL.CLOEXEC);
        return EpollPoller{
            .epoll_fd = epoll_fd,
            .events = try allocator.alloc(std.os.linux.epoll_event, 1024),
        };
    }

    pub fn poll(self: *EpollPoller, timeout_ms: u64) ![]IoEvent {
        const count = try std.os.epoll_wait(
            self.epoll_fd,
            self.events,
            @intCast(timeout_ms),
        );
        return self.eventsToIoEvents(self.events[0..count]);
    }

    pub fn register(self: *EpollPoller, fd: i32, events: u32) !void {
        var event = std.os.linux.epoll_event{
            .events = events,
            .data = .{ .fd = fd },
        };
        try std.os.epoll_ctl(
            self.epoll_fd,
            std.os.linux.EPOLL.CTL_ADD,
            fd,
            &event,
        );
    }
};

// macOS/BSD: kqueue
const KqueuePoller = struct {
    kqueue_fd: i32,
    events: []std.os.Kevent,

    // Similar implementation with kqueue...
};

// Windows: IOCP
const IocpPoller = struct {
    iocp_handle: std.os.windows.HANDLE,

    // Similar implementation with IOCP...
};
```

### 3.3 Timer Implementation

**Min-heap based timer queue:**

```zig
pub const TimerHeap = struct {
    timers: std.PriorityQueue(Timer, void, compareTimers),

    const Timer = struct {
        id: u64,
        deadline: i64, // Unix timestamp in ms
        callback: *const fn (*Timer) void,
        repeat: ?u64,  // Repeat interval (null for one-shot)
    };

    fn compareTimers(_: void, a: Timer, b: Timer) std.math.Order {
        return std.math.order(a.deadline, b.deadline);
    }

    pub fn setTimeout(self: *TimerHeap, delay_ms: u64, callback: *const fn (*Timer) void) !u64 {
        const timer = Timer{
            .id = self.generateId(),
            .deadline = std.time.milliTimestamp() + @as(i64, delay_ms),
            .callback = callback,
            .repeat = null,
        };
        try self.timers.add(timer);
        return timer.id;
    }

    pub fn setInterval(self: *TimerHeap, interval_ms: u64, callback: *const fn (*Timer) void) !u64 {
        const timer = Timer{
            .id = self.generateId(),
            .deadline = std.time.milliTimestamp() + @as(i64, interval_ms),
            .callback = callback,
            .repeat = interval_ms,
        };
        try self.timers.add(timer);
        return timer.id;
    }

    pub fn processExpired(self: *TimerHeap) !void {
        const now = std.time.milliTimestamp();

        while (self.timers.peek()) |timer| {
            if (timer.deadline > now) break;

            const expired = self.timers.remove();
            expired.callback(&expired);

            // Re-add if repeating
            if (expired.repeat) |interval| {
                var new_timer = expired;
                new_timer.deadline = now + @as(i64, interval);
                try self.timers.add(new_timer);
            }
        }
    }
};
```

### 3.4 Async Task Queue

```zig
pub const TaskQueue = struct {
    queue: std.DoublyLinkedList(Task),
    allocator: std.mem.Allocator,

    const Task = struct {
        callback: *const fn (*Task) anyerror!void,
        context: ?*anyopaque,
    };

    pub fn enqueue(self: *TaskQueue, callback: *const fn (*Task) anyerror!void) !void {
        const node = try self.allocator.create(std.DoublyLinkedList(Task).Node);
        node.data = Task{ .callback = callback, .context = null };
        self.queue.append(node);
    }

    pub fn process(self: *TaskQueue) !void {
        while (self.queue.popFirst()) |node| {
            defer self.allocator.destroy(node);
            try node.data.callback(&node.data);
        }
    }
};
```

---

## 4. Module System

### 4.1 Module Resolution

**Resolution algorithm (Node.js-compatible):**

```zig
pub const ModuleResolver = struct {
    cache: ModuleCache,
    search_paths: [][]const u8,

    pub fn resolve(self: *ModuleResolver, specifier: []const u8, parent: ?[]const u8) ![]const u8 {
        // 1. Built-in modules (nexus:*)
        if (std.mem.startsWith(u8, specifier, "nexus:")) {
            return self.resolveBuiltin(specifier);
        }

        // 2. Relative paths (./foo, ../bar)
        if (std.mem.startsWith(u8, specifier, "./") or
            std.mem.startsWith(u8, specifier, "../")) {
            return self.resolveRelative(specifier, parent);
        }

        // 3. Absolute paths
        if (std.fs.path.isAbsolute(specifier)) {
            return try self.allocator.dupe(u8, specifier);
        }

        // 4. WASM modules (.wasm extension)
        if (std.mem.endsWith(u8, specifier, ".wasm")) {
            return self.resolveWasm(specifier, parent);
        }

        // 5. Package resolution (node_modules style)
        return self.resolvePackage(specifier, parent);
    }

    fn resolveRelative(self: *ModuleResolver, specifier: []const u8, parent: ?[]const u8) ![]const u8 {
        const parent_dir = if (parent) |p|
            std.fs.path.dirname(p) orelse "."
        else
            ".";

        const resolved = try std.fs.path.join(self.allocator, &.{ parent_dir, specifier });

        // Try .zig extension
        if (try self.fileExists(resolved)) return resolved;

        const zig_path = try std.fmt.allocPrint(self.allocator, "{s}.zig", .{resolved});
        if (try self.fileExists(zig_path)) return zig_path;

        return error.ModuleNotFound;
    }

    fn resolvePackage(self: *ModuleResolver, specifier: []const u8, parent: ?[]const u8) ![]const u8 {
        // Search node_modules-style directories
        var current_dir = if (parent) |p| std.fs.path.dirname(p) orelse "." else ".";

        while (true) {
            const node_modules = try std.fs.path.join(
                self.allocator,
                &.{ current_dir, "node_modules", specifier }
            );

            if (try self.fileExists(node_modules)) return node_modules;

            // Move up directory tree
            const parent_dir = std.fs.path.dirname(current_dir);
            if (parent_dir == null or std.mem.eql(u8, parent_dir.?, current_dir)) {
                break;
            }
            current_dir = parent_dir.?;
        }

        return error.ModuleNotFound;
    }
};
```

### 4.2 Module Loader

```zig
pub const ModuleLoader = struct {
    resolver: ModuleResolver,
    cache: ModuleCache,
    wasm_engine: *WasmEngine,

    pub const Module = union(enum) {
        native: NativeModule,
        wasm: WasmModule,
    };

    pub fn load(self: *ModuleLoader, specifier: []const u8, parent: ?[]const u8) !*Module {
        // Check cache first
        if (self.cache.get(specifier)) |cached| {
            return cached;
        }

        const resolved_path = try self.resolver.resolve(specifier, parent);

        const module = if (std.mem.endsWith(u8, resolved_path, ".wasm"))
            try self.loadWasm(resolved_path)
        else
            try self.loadNative(resolved_path);

        try self.cache.put(specifier, module);
        return module;
    }

    fn loadNative(self: *ModuleLoader, path: []const u8) !*Module {
        // For Zig modules, we rely on compile-time @import
        // At runtime, we can use dynamic library loading for .so/.dylib/.dll
        const lib = try std.DynLib.open(path);
        return NativeModule{ .lib = lib };
    }

    fn loadWasm(self: *ModuleLoader, path: []const u8) !*Module {
        const wasm_bytes = try std.fs.cwd().readFileAlloc(
            self.allocator,
            path,
            std.math.maxInt(usize),
        );
        defer self.allocator.free(wasm_bytes);

        const wasm_instance = try self.wasm_engine.instantiate(wasm_bytes);
        return WasmModule{ .instance = wasm_instance };
    }
};
```

### 4.3 Module Cache

**Content-addressed caching (like ZIM):**

```zig
pub const ModuleCache = struct {
    cache_dir: []const u8,
    memory_cache: std.StringHashMap(*Module),

    pub fn get(self: *ModuleCache, specifier: []const u8) ?*Module {
        // Check memory cache first
        if (self.memory_cache.get(specifier)) |module| {
            return module;
        }

        // Check disk cache
        const cache_key = self.computeHash(specifier);
        const cache_path = try std.fs.path.join(
            self.allocator,
            &.{ self.cache_dir, cache_key },
        );

        if (std.fs.cwd().openFile(cache_path, .{})) |file| {
            defer file.close();
            // Load from cache...
        } else |_| {
            return null;
        }
    }

    fn computeHash(self: *ModuleCache, data: []const u8) []const u8 {
        var hasher = std.crypto.hash.Blake3.init(.{});
        hasher.update(data);
        var hash: [32]u8 = undefined;
        hasher.final(&hash);
        return std.fmt.bytesToHex(&hash, .lower);
    }
};
```

---

## 5. WASM Integration

### 5.1 WASM Engine Wrapper

**Abstraction over Wasmer/Wasmtime:**

```zig
pub const WasmEngine = struct {
    engine: Engine,  // Wasmer or Wasmtime engine
    store: Store,

    pub fn init(allocator: std.mem.Allocator) !WasmEngine {
        // Initialize WASM engine (Wasmer or Wasmtime)
        const engine = try Engine.init();
        const store = try Store.init(engine);

        return WasmEngine{
            .engine = engine,
            .store = store,
        };
    }

    pub fn instantiate(self: *WasmEngine, wasm_bytes: []const u8) !*WasmInstance {
        const module = try self.engine.compile(wasm_bytes);

        // Create imports (host functions)
        const imports = try self.createImports();

        const instance = try module.instantiate(self.store, imports);

        return WasmInstance{
            .instance = instance,
            .allocator = self.allocator,
        };
    }

    fn createImports(self: *WasmEngine) !Imports {
        var imports = Imports.init(self.allocator);

        // Register host functions
        try imports.register("nexus", "log", hostLog);
        try imports.register("nexus", "http_fetch", hostHttpFetch);
        try imports.register("nexus", "fs_read", hostFsRead);

        return imports;
    }
};
```

### 5.2 WASM Instance

```zig
pub const WasmInstance = struct {
    instance: Instance,
    allocator: std.mem.Allocator,

    pub fn call(self: *WasmInstance, function_name: []const u8, args: anytype) !Value {
        const func = try self.instance.getFunction(function_name);

        // Convert Zig args to WASM values
        const wasm_args = try self.convertArgs(args);
        defer self.allocator.free(wasm_args);

        const results = try func.call(wasm_args);

        // Convert WASM results back to Zig
        return try self.convertResult(results[0]);
    }

    pub fn getMemory(self: *WasmInstance, name: []const u8) !*WasmMemory {
        const memory = try self.instance.getMemory(name);
        return WasmMemory{ .memory = memory };
    }

    fn convertArgs(self: *WasmInstance, args: anytype) ![]Value {
        // Convert Zig tuple to WASM values
        const ArgsTuple = @TypeOf(args);
        const fields = @typeInfo(ArgsTuple).Struct.fields;

        var values = try self.allocator.alloc(Value, fields.len);
        inline for (fields, 0..) |field, i| {
            values[i] = try valueFromZig(@field(args, field.name));
        }
        return values;
    }
};
```

### 5.3 Host Functions

**Expose Nexus APIs to WASM:**

```zig
// Host function: nexus.log
fn hostLog(caller: *Caller, ptr: i32, len: i32) !void {
    const memory = try caller.getMemory("memory");
    const data = memory.data();
    const message = data[@intCast(ptr)..@intCast(ptr + len)];

    std.debug.print("[WASM] {s}\n", .{message});
}

// Host function: nexus.http_fetch
fn hostHttpFetch(caller: *Caller, url_ptr: i32, url_len: i32) !i32 {
    const memory = try caller.getMemory("memory");
    const data = memory.data();
    const url = data[@intCast(url_ptr)..@intCast(url_ptr + url_len)];

    // Perform HTTP fetch
    const response = try nexus.http.fetch(url);

    // Allocate response in WASM memory
    const alloc_fn = try caller.getFunction("alloc");
    const response_ptr = try alloc_fn.call(&[_]Value{
        Value.i32(@intCast(response.len))
    });

    // Copy response to WASM memory
    const dest = data[@intCast(response_ptr.i32())..];
    @memcpy(dest[0..response.len], response);

    return response_ptr.i32();
}
```

### 5.4 Security Policy

```zig
pub const WasmPolicy = struct {
    max_memory: usize,        // Max WASM memory (bytes)
    max_cpu_time: u64,        // Max CPU time (ms)
    allow_net: bool,          // Network access
    allow_fs: ?FsPolicy,      // File system access
    allow_env: bool,          // Environment variables

    pub const FsPolicy = union(enum) {
        none: void,
        read_only: []const u8,  // Directory path
        read_write: []const u8, // Directory path
    };

    pub fn check(self: *const WasmPolicy, operation: Operation) !void {
        switch (operation) {
            .network => if (!self.allow_net) return error.PermissionDenied,
            .fs_read => |path| {
                if (self.allow_fs) |fs| {
                    switch (fs) {
                        .none => return error.PermissionDenied,
                        .read_only, .read_write => |allowed_dir| {
                            if (!std.mem.startsWith(u8, path, allowed_dir)) {
                                return error.PermissionDenied;
                            }
                        },
                    }
                } else return error.PermissionDenied;
            },
            .fs_write => |path| {
                if (self.allow_fs) |fs| {
                    switch (fs) {
                        .none, .read_only => return error.PermissionDenied,
                        .read_write => |allowed_dir| {
                            if (!std.mem.startsWith(u8, path, allowed_dir)) {
                                return error.PermissionDenied;
                            }
                        },
                    }
                } else return error.PermissionDenied;
            },
        }
    }
};
```

---

## 6. Memory Management

### 6.1 Allocation Strategy

**Allocator hierarchy:**
```
Page Allocator (OS)
       │
       ▼
Arena Allocator (Per-request)
       │
       ▼
Pool Allocator (Small objects)
       │
       ▼
Stack Allocator (Temp buffers)
```

**Example:**
```zig
pub const Runtime = struct {
    page_allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,

    pub fn handleRequest(self: *Runtime, req: *Request) !void {
        // Per-request arena
        var request_arena = std.heap.ArenaAllocator.init(self.page_allocator);
        defer request_arena.deinit(); // Free all at once

        const allocator = request_arena.allocator();

        // All request allocations use arena
        const body = try req.readBody(allocator);
        const parsed = try json.parse(allocator, body);

        // ... process request

        // Arena freed automatically on return
    }
};
```

### 6.2 Memory Pools

**Object pooling for hot paths:**
```zig
pub fn ObjectPool(comptime T: type) type {
    return struct {
        const Self = @This();

        pool: std.ArrayList(*T),
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .pool = std.ArrayList(*T).init(allocator),
                .allocator = allocator,
            };
        }

        pub fn acquire(self: *Self) !*T {
            if (self.pool.popOrNull()) |obj| {
                return obj;
            }
            return try self.allocator.create(T);
        }

        pub fn release(self: *Self, obj: *T) !void {
            // Reset object state
            obj.* = std.mem.zeroes(T);
            try self.pool.append(obj);
        }
    };
}

// Usage
var buffer_pool = ObjectPool([4096]u8).init(allocator);
const buffer = try buffer_pool.acquire();
defer buffer_pool.release(buffer) catch {};
```

---

## 7. Standard Library Design

### 7.1 Module Structure

Each stdlib module follows this pattern:
```zig
// nexus:fs/file.zig
pub const File = struct {
    fd: std.os.fd_t,
    path: []const u8,
    allocator: std.mem.Allocator,

    pub fn open(allocator: std.mem.Allocator, path: []const u8, flags: Flags) !File {
        const fd = try std.os.open(path, flags.toOsFlags(), 0o666);
        return File{
            .fd = fd,
            .path = try allocator.dupe(u8, path),
            .allocator = allocator,
        };
    }

    pub fn read(self: *File, buffer: []u8) !usize {
        return std.os.read(self.fd, buffer);
    }

    pub fn readAll(self: *File) ![]u8 {
        const stat = try std.os.fstat(self.fd);
        const size = @as(usize, @intCast(stat.size));

        const buffer = try self.allocator.alloc(u8, size);
        errdefer self.allocator.free(buffer);

        const bytes_read = try self.read(buffer);
        return buffer[0..bytes_read];
    }

    pub fn close(self: *File) void {
        std.os.close(self.fd);
        self.allocator.free(self.path);
    }
};
```

### 7.2 Async I/O Pattern

**Non-blocking I/O with event loop integration:**
```zig
pub fn readFileAsync(path: []const u8, callback: *const fn ([]const u8) void) !void {
    const event_loop = getEventLoop();

    // Register async task
    try event_loop.enqueueTask(struct {
        fn run(task: *Task) !void {
            const file = try std.fs.cwd().openFile(path, .{});
            defer file.close();

            const content = try file.readToEndAlloc(task.allocator, std.math.maxInt(usize));
            callback(content);
        }
    }.run);
}
```

---

## 8. Security Architecture

### 8.1 Permission System

**Capability-based permissions:**
```zig
pub const Permissions = struct {
    fs_read: ?[]const []const u8,   // Allowed read directories
    fs_write: ?[]const []const u8,  // Allowed write directories
    net: ?[]const NetRule,          // Allowed network destinations
    env: bool,                      // Environment variable access
    ffi: bool,                      // Native library loading

    pub fn checkFsRead(self: *const Permissions, path: []const u8) !void {
        if (self.fs_read) |allowed| {
            for (allowed) |dir| {
                if (std.mem.startsWith(u8, path, dir)) return;
            }
        }
        return error.PermissionDenied;
    }

    pub fn checkNet(self: *const Permissions, host: []const u8, port: u16) !void {
        if (self.net) |rules| {
            for (rules) |rule| {
                if (rule.matches(host, port)) return;
            }
        }
        return error.PermissionDenied;
    }
};
```

### 8.2 Sandboxing

**WASM sandbox + OS-level sandbox:**
```
┌──────────────────────────────────────┐
│        User Application Code         │
│  ┌────────────┐    ┌──────────────┐  │
│  │ Zig Module │    │ WASM Module  │  │
│  │  (Native)  │    │ (Sandboxed)  │  │
│  └──────┬─────┘    └──────┬───────┘  │
│         │                 │          │
│         ▼                 ▼          │
│  ┌────────────────────────────────┐  │
│  │    Nexus Permission Layer      │  │
│  └────────────┬───────────────────┘  │
│               │                      │
│               ▼                      │
│  ┌────────────────────────────────┐  │
│  │      Operating System          │  │
│  └────────────────────────────────┘  │
└──────────────────────────────────────┘
```

---

## 9. Performance Optimizations

### 9.1 Zero-Copy I/O

```zig
// Use sendfile for efficient file transfers
pub fn sendFile(socket: Socket, file: File) !void {
    const stat = try std.os.fstat(file.fd);
    var offset: u64 = 0;
    const size = @as(usize, @intCast(stat.size));

    while (offset < size) {
        const sent = try std.os.sendfile(
            socket.fd,
            file.fd,
            offset,
            size - offset,
        );
        offset += sent;
    }
}
```

### 9.2 Object Pooling

**Reuse expensive objects:**
```zig
var http_response_pool = ObjectPool(HttpResponse).init(allocator);
var buffer_pool = ObjectPool([8192]u8).init(allocator);
```

### 9.3 Cache-Friendly Data Structures

**Minimize cache misses:**
```zig
// Struct-of-Arrays instead of Array-of-Structs
pub const TaskList = struct {
    ids: []u64,
    callbacks: []Callback,
    states: []State,

    // Better cache locality when iterating
};
```

---

## 10. Implementation Plan

### Phase 1: Foundation (Months 1-3)
**Goal:** Working event loop + basic stdlib

**Week 1-2:** Project setup
- [ ] Directory structure
- [ ] Build system
- [ ] CI/CD pipeline

**Week 3-6:** Event loop
- [ ] I/O poller (epoll/kqueue/IOCP)
- [ ] Timer heap
- [ ] Task queue
- [ ] Event loop runner

**Week 7-10:** Module system
- [ ] Module resolver
- [ ] Module loader (Zig only)
- [ ] Module cache

**Week 11-12:** Basic stdlib
- [ ] nexus:fs (read/write)
- [ ] nexus:net (TCP sockets)
- [ ] nexus:timer (setTimeout/setInterval)
- [ ] nexus:console (logging)

### Phase 2: WASM (Months 4-6)
**Goal:** WASM execution with WASI

**Week 13-16:** WASM runtime
- [ ] Evaluate Wasmer vs Wasmtime
- [ ] Engine wrapper
- [ ] Module loading
- [ ] Host function bindings

**Week 17-20:** WASI support
- [ ] WASI preview 2
- [ ] File system mapping
- [ ] Network access
- [ ] Environment variables

**Week 21-24:** Security
- [ ] Permission system
- [ ] WASM policy engine
- [ ] Capability-based access control

### Phase 3: Production (Months 7-12)
**Goal:** Production-ready runtime

**Features:**
- [ ] HTTP/2, HTTP/3
- [ ] WebSocket
- [ ] Streams API
- [ ] Worker threads
- [ ] Performance tuning
- [ ] Documentation

---

**Document Version:** 0.1.0
**Last Updated:** 2025-11-16
**Status:** Draft
**Authors:** Ghost Stack Team
