# Nexus Runtime Specification v0.1.0

**Node.js reimagined in Zig + WASM — 10x better performance, native systems access, polyglot execution**

---

## 1. Executive Summary

**Nexus** is a next-generation application runtime that combines the developer experience of Node.js with the performance and safety of Zig, enhanced by first-class WebAssembly support. It targets the gap between high-level runtimes (Node.js, Deno, Bun) and low-level systems programming.

### Mission
To provide the fastest, most secure, and most versatile application runtime for modern cloud-native, edge, and embedded systems.

### Core Principles
1. **Native Performance** — Compiled Zig code, no JIT/GC overhead
2. **WASM-First** — WebAssembly as a first-class execution target
3. **Polyglot by Design** — Run code from any language via WASM
4. **Secure by Default** — Capability-based security, sandboxed execution
5. **Developer Joy** — Ergonomic APIs, excellent tooling, fast iteration

---

## 2. Technical Requirements

### 2.1 Runtime Core

#### Event Loop
- **Architecture**: Single-threaded event loop with async I/O
- **Implementation**: Built on Zig's async/await or custom epoll/kqueue/IOCP abstraction
- **Concurrency Model**: Event-driven non-blocking I/O (Node.js-style)
- **Threading**: Optional worker threads for CPU-intensive tasks
- **Timers**: High-precision timers with `setTimeout`, `setInterval`, `setImmediate` equivalents

**Performance Targets:**
- Event loop latency: <100μs (p99)
- Timer precision: ±1ms
- Context switch overhead: <5μs

#### Module System
- **Native Modules**: Zig source files (`.zig`)
- **WASM Modules**: WebAssembly binaries (`.wasm`)
- **Resolution Algorithm**: Node.js-compatible module resolution
- **Caching**: Bytecode/JIT cache for repeated loads
- **Formats Supported**:
  - Zig native modules
  - WASM with WASI
  - Dynamic libraries (`.so`, `.dylib`, `.dll`)

**Example:**
```zig
const http = @import("nexus:http");        // Built-in module
const mylib = @import("./mylib.zig");      // Local Zig module
const wasm_compute = @import("./compute.wasm");  // WASM module
```

### 2.2 WebAssembly Integration

#### WASM Runtime
- **Engine**: Wasmer or Wasmtime (evaluate both)
- **Standards**: WASI preview 2, Component Model
- **Memory Model**: Linear memory with bounds checking
- **Execution**: JIT + AOT compilation support
- **Sandboxing**: Full WASM sandbox with capability grants

#### WASM-Zig Bridge
- **Host Functions**: Expose Nexus APIs as WASM imports
- **Memory Sharing**: Zero-copy data transfer where possible
- **Type Safety**: Automatic marshaling between Zig and WASM types
- **Error Handling**: Consistent error propagation across boundary

**Example:**
```zig
// Zig host function exposed to WASM
export fn nexus_http_fetch(url_ptr: [*]const u8, url_len: usize) i32 {
    const url = url_ptr[0..url_len];
    // ... perform HTTP request
    return 0;
}
```

### 2.3 Standard Library

#### Core Modules

**`nexus:runtime`**
- Event loop control
- Process management
- Signal handling
- Exit codes

**`nexus:fs`**
- File operations (read, write, stat, watch)
- Directory traversal
- Permissions and metadata
- Async file I/O

**`nexus:net`**
- TCP/UDP sockets
- HTTP/1.1, HTTP/2, HTTP/3
- WebSocket support
- TLS 1.3

**`nexus:stream`**
- Readable/Writable/Transform streams
- Backpressure handling
- Pipe composition

**`nexus:crypto`**
- Hashing (SHA-256, SHA-512, BLAKE3)
- Encryption (AES-GCM, ChaCha20-Poly1305)
- Key derivation (PBKDF2, Argon2)
- Random number generation

**`nexus:timer`**
- `setTimeout`, `clearTimeout`
- `setInterval`, `clearInterval`
- `setImmediate`
- High-resolution timer

**`nexus:wasm`**
- Load and instantiate WASM modules
- Inspect WASM exports/imports
- Memory management
- Component Model support

**`nexus:console`**
- Formatted output
- ANSI colors
- Logging levels
- Debugger integration

### 2.4 Package Management

**Integration with ZIM** (Zig Infrastructure Manager):
- `nexus install <package>` → Delegates to `zim deps add`
- `nexus.toml` → Package manifest (compatible with `zim.toml`)
- `nexus.lock` → Lockfile (compatible with `zim.lock`)
- Content-addressed caching via ZIM
- Semantic versioning
- Git, tarball, registry sources

**Example `nexus.toml`:**
```toml
[project]
name = "my-app"
version = "1.0.0"
runtime = "nexus@0.1.0"

[dependencies]
http-server = { git = "https://github.com/nexus/http-server", tag = "v1.0.0" }
db-driver = { registry = "nexus.dev", version = "^2.3.0" }

[wasm-dependencies]
image-resize = { url = "https://cdn.example.com/image-resize.wasm", hash = "sha256:..." }
```

---

## 3. API Specification

### 3.1 HTTP Server API

```zig
const nexus = @import("nexus");

pub fn main() !void {
    const server = try nexus.http.Server.init(.{
        .port = 3000,
        .host = "0.0.0.0",
    });
    defer server.deinit();

    try server.route("GET", "/", handleRoot);
    try server.route("POST", "/api/data", handleData);

    try server.listen();
}

fn handleRoot(req: *nexus.http.Request, res: *nexus.http.Response) !void {
    try res.json(.{ .message = "Hello from Nexus!" });
}

fn handleData(req: *nexus.http.Request, res: *nexus.http.Response) !void {
    const body = try req.readBody();
    // Process data...
    try res.status(201).send("Created");
}
```

### 3.2 File System API

```zig
const nexus = @import("nexus");

pub fn main() !void {
    // Async file reading
    const content = try nexus.fs.readFile("config.json");
    defer nexus.allocator.free(content);

    // File watching
    var watcher = try nexus.fs.watch("./src", .{
        .recursive = true,
        .events = .{ .create = true, .modify = true },
    });
    defer watcher.deinit();

    while (try watcher.next()) |event| {
        std.debug.print("File {s}: {s}\n", .{ @tagName(event.kind), event.path });
    }
}
```

### 3.3 WASM Module Loading

```zig
const nexus = @import("nexus");

pub fn main() !void {
    // Load WASM module
    const module = try nexus.wasm.loadModule("./compute.wasm");
    defer module.deinit();

    // Call exported function
    const result = try module.call("fibonacci", .{@as(i32, 10)});
    std.debug.print("Result: {}\n", .{result});

    // Access exported memory
    const memory = try module.getMemory("memory");
    const data = memory.data();
}
```

### 3.4 Streams API

```zig
const nexus = @import("nexus");

pub fn main() !void {
    const source = try nexus.fs.createReadStream("input.txt");
    defer source.deinit();

    const transform = nexus.stream.Transform.init(.{
        .transform = uppercase,
    });

    const dest = try nexus.fs.createWriteStream("output.txt");
    defer dest.deinit();

    // Pipeline: read -> transform -> write
    try source.pipe(&transform).pipe(&dest);
}

fn uppercase(chunk: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const result = try allocator.alloc(u8, chunk.len);
    _ = std.ascii.upperString(result, chunk);
    return result;
}
```

---

## 4. Security Model

### 4.1 Capability-Based Security

**Permissions System:**
- File system access (read/write per directory)
- Network access (per host/port)
- Environment variables
- Process spawning
- Native library loading

**Example:**
```bash
# Explicit permission grants
nexus run app.zig --allow-read=/data --allow-net=api.example.com

# Unrestricted (development only)
nexus run app.zig --allow-all
```

### 4.2 WASM Sandboxing

**Isolation Guarantees:**
- Memory isolation (linear memory only)
- No direct system calls
- All I/O via WASI or host functions
- Resource limits (CPU, memory, file descriptors)

**WASM Policy:**
```zig
const policy = nexus.wasm.Policy{
    .max_memory = 100 * 1024 * 1024, // 100MB
    .max_cpu_time = 5000, // 5 seconds
    .allow_net = false,
    .allow_fs = .{ .read_only = "/data" },
};
const module = try nexus.wasm.loadModuleWithPolicy("untrusted.wasm", policy);
```

---

## 5. Performance Specifications

### 5.1 Benchmarks vs Node.js

**Target Performance Metrics:**

| Metric | Node.js 20 | Nexus Target | Multiplier |
|--------|-----------|--------------|------------|
| HTTP req/sec | 50k | 500k+ | **10x** |
| Cold start | 50ms | 5ms | **10x** |
| Memory (idle) | 50MB | 5MB | **10x** |
| File I/O (MB/s) | 500 | 5000+ | **10x** |
| WASM call overhead | 100ns | 10ns | **10x** |
| Binary size | 50MB | 5MB | **10x** |

### 5.2 Resource Limits

**Default Limits (configurable):**
- Max open file descriptors: 65,536
- Max memory per process: System limit
- Max event loop iterations: Unlimited
- Max concurrent async operations: 10,000

---

## 6. Deployment Targets

### 6.1 Supported Platforms

**Operating Systems:**
- Linux (x86_64, aarch64, riscv64)
- macOS (x86_64, aarch64)
- Windows (x86_64)
- FreeBSD (x86_64)

**Container Platforms:**
- Docker
- Kubernetes
- Podman

**Edge Platforms:**
- Cloudflare Workers (WASM target)
- Fastly Compute@Edge
- AWS Lambda (custom runtime)
- Fly.io

**Embedded:**
- Raspberry Pi (Linux ARM)
- ESP32 (future)

### 6.2 Cross-Compilation

Nexus supports cross-compilation to all targets:
```bash
# Compile for WASM
nexus build --target=wasm32-wasi

# Compile for ARM Linux
nexus build --target=aarch64-linux-gnu

# Compile for Windows
nexus build --target=x86_64-windows
```

---

## 7. Roadmap

### Phase 1: Foundation (v0.1.0) — 3 months
- [ ] Event loop implementation (epoll/kqueue/IOCP)
- [ ] Module loader (Zig modules only)
- [ ] Basic stdlib (fs, net, timer, console)
- [ ] HTTP server (HTTP/1.1)
- [ ] CLI tool
- [ ] Integration with ZIM

### Phase 2: WASM (v0.2.0) — 3 months
- [ ] WASM runtime integration (Wasmer/Wasmtime)
- [ ] WASM module loading
- [ ] WASI support
- [ ] Host function bindings
- [ ] WASM policy engine

### Phase 3: Production (v0.3.0) — 6 months
- [ ] HTTP/2 and HTTP/3 support
- [ ] WebSocket support
- [ ] Streams API
- [ ] Worker threads
- [ ] Performance optimization
- [ ] Production hardening

### Phase 4: Ecosystem (v1.0.0) — 12 months
- [ ] Package registry (nexus.dev)
- [ ] Web framework
- [ ] Database drivers
- [ ] Testing framework
- [ ] Debugging tools
- [ ] Documentation + tutorials

---

## 8. Non-Goals

**What Nexus Will NOT Do:**
- JavaScript/TypeScript runtime (use Deno/Bun instead)
- Garbage collection (manual memory management only)
- Dynamic typing (static types via Zig)
- Browser compatibility (server/edge only)
- Backward compatibility with Node.js APIs (inspired, not compatible)

---

## 9. Success Criteria

**v1.0.0 Release Criteria:**
1. 10x performance improvement over Node.js in benchmarks
2. 100+ packages in ecosystem
3. Production deployments at 10+ companies
4. Full WASI compliance
5. <5MB binary size
6. <5ms cold start
7. Zero known security vulnerabilities

---

## 10. References

- [Node.js Architecture](https://nodejs.org/en/docs/guides/)
- [WASI Specification](https://github.com/WebAssembly/WASI)
- [Zig Language Reference](https://ziglang.org/documentation/master/)
- [ZIM Package Manager](https://github.com/ghostkellz/zim)
- [Cloudflare Workers Runtime](https://developers.cloudflare.com/workers/)

---

**Document Version:** 0.1.0
**Last Updated:** 2025-11-16
**Status:** Draft
**Authors:** Ghost Stack Team
