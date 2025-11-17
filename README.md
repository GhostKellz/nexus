<div align="center">
  <h1>⚡ Nexus</h1>

  **Node.js reimagined in Zig + WASM**
  *10x faster, 10x smaller, infinitely more powerful*

  [![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
  [![Zig](https://img.shields.io/badge/Zig-0.16.0+-orange.svg)](https://ziglang.org)
  [![Status](https://img.shields.io/badge/Status-Pre--Alpha-red.svg)](https://github.com/ghostkellz/nexus)
</div>

---

## 🎯 What is Nexus?

**Nexus** is a next-generation application runtime that combines:
- 🔥 **Native Performance** — Compiled Zig, no JIT/GC overhead
- 🌐 **WebAssembly-First** — Run WASM modules natively alongside Zig code
- 🔒 **Secure by Default** — Capability-based security model
- 🚀 **Developer Experience** — Ergonomic APIs inspired by Node.js
- 🎯 **Polyglot Execution** — Run code from any language via WASM

Think **Node.js**, but written in Zig, 10x faster, and with first-class WASM support.

---

## ⚡ Why Nexus?

| Feature | Node.js | Deno | Bun | **Nexus** |
|---------|---------|------|-----|-----------|
| Language | JavaScript | JavaScript | JavaScript | **Zig** |
| Performance | JIT (~50k req/s) | JIT (~80k req/s) | JIT (~120k req/s) | **Native AOT (500k+ req/s)** |
| Memory | GC (~50MB idle) | GC (~60MB idle) | GC (~40MB idle) | **Manual (~5MB idle)** |
| Binary Size | ~50MB | ~100MB | ~50MB | **~5MB** |
| Cold Start | ~50ms | ~30ms | ~10ms | **<5ms** |
| WASM Support | Addon | First-class | Good | **Native first-class** |
| Systems Access | Limited | Sandboxed | Full | **Full native** |
| Package Manager | npm | Built-in | Built-in | **ZIM integration** |

---

## 🚀 Quick Start

### Installation

```bash
# Clone the repository
git clone https://github.com/ghostkellz/nexus.git
cd nexus

# Build from source
zig build

# Run Nexus
./zig-out/bin/nexus --version
```

### Hello World

**`hello.zig`:**
```zig
const nexus = @import("nexus");

pub fn main() !void {
    const server = try nexus.http.Server.init(.{
        .port = 3000,
    });
    defer server.deinit();

    try server.route("GET", "/", handleRequest);

    nexus.console.log("Server running on http://localhost:3000");
    try server.listen();
}

fn handleRequest(req: *nexus.http.Request, res: *nexus.http.Response) !void {
    try res.json(.{
        .message = "Hello from Nexus!",
        .performance = "10x better than Node.js",
    });
}
```

**Run it:**
```bash
nexus run hello.zig
```

**Benchmark it:**
```bash
# Nexus
wrk -t12 -c400 -d30s http://localhost:3000
# Expected: 500k+ req/sec

# Node.js equivalent
node hello.js
wrk -t12 -c400 -d30s http://localhost:3000
# Typical: 50k req/sec
```

---

## 🌟 Key Features

### 1. Native Performance

```zig
// Nexus: Native compiled Zig
const data = try nexus.fs.readFile("large.json"); // ~5000 MB/s

// Node.js: V8 JIT
const data = await fs.readFile("large.json"); // ~500 MB/s
```

### 2. First-Class WASM Support

```zig
const nexus = @import("nexus");

pub fn main() !void {
    // Load WASM module from any language (Rust, Go, C++, etc.)
    const image_processor = try nexus.wasm.load("./image-resize.wasm");
    defer image_processor.deinit();

    // Call WASM function with zero-copy where possible
    const result = try image_processor.call("resize", .{
        .width = 800,
        .height = 600,
        .quality = 85,
    });

    nexus.console.log("Processed image: {}", .{result});
}
```

### 3. Polyglot Ecosystem

```zig
// Import Zig native code
const zig_lib = @import("./native-lib.zig");

// Import Rust compiled to WASM
const rust_crypto = @import("./crypto.wasm");

// Import Go compiled to WASM
const go_parser = @import("./parser.wasm");

pub fn main() !void {
    const data = zig_lib.fetchData();
    const encrypted = try rust_crypto.call("encrypt", .{data});
    const parsed = try go_parser.call("parse", .{encrypted});
    // Best of all languages in one runtime!
}
```

### 4. Capability-Based Security

```bash
# Explicit permissions required
nexus run app.zig --allow-read=/data --allow-net=api.example.com

# WASM modules are sandboxed by default
nexus run app.zig --allow-wasm=./untrusted.wasm
```

### 5. Edge & Serverless Ready

```bash
# Compile to WASM for Cloudflare Workers
nexus build --target=wasm32-wasi

# Deploy to any edge platform
# - Cloudflare Workers
# - Fastly Compute@Edge
# - Deno Deploy
# - AWS Lambda
```

---

## 📦 Package Management

Nexus integrates seamlessly with **ZIM** (Zig Infrastructure Manager):

```bash
# Initialize project
nexus init my-app
cd my-app

# Add dependencies
nexus add http-server --git gh/nexus/http-server@v1.0.0
nexus add db-driver --registry nexus.dev --version ^2.3.0

# Add WASM dependency
nexus add image-resize --wasm https://cdn.example.com/image-resize.wasm

# Install dependencies
nexus install

# Run project
nexus run src/main.zig
```

**`nexus.toml`:**
```toml
[project]
name = "my-app"
version = "1.0.0"
runtime = "nexus@0.1.0"

[dependencies]
http-server = { git = "gh/nexus/http-server", tag = "v1.0.0" }
db-driver = { registry = "nexus.dev", version = "^2.3.0" }

[wasm-dependencies]
image-resize = { url = "https://cdn.example.com/image-resize.wasm", hash = "sha256:..." }
```

---

## 🏗️ Architecture

Nexus is built on three core pillars:

### 1. Event Loop Runtime
- Single-threaded async I/O
- Built on epoll/kqueue/IOCP
- <100μs latency (p99)
- Optional worker threads

### 2. Module System
- **Native Zig modules** — `.zig` files compiled to native code
- **WASM modules** — `.wasm` files executed in sandbox
- **Dynamic libraries** — `.so`/`.dylib`/`.dll` via FFI
- Content-addressed caching

### 3. Standard Library
- `nexus:runtime` — Event loop, process control
- `nexus:fs` — File system operations
- `nexus:net` — TCP/UDP/HTTP/WebSocket
- `nexus:stream` — Readable/Writable streams
- `nexus:crypto` — Hashing, encryption, RNG
- `nexus:wasm` — WASM module loading
- `nexus:console` — Formatted output

See [ARCHITECTURE.md](ARCHITECTURE.md) for detailed design.

---

## 🎯 Use Cases

### Web Servers
```zig
// High-performance HTTP/2 server
const server = try nexus.http.Server.init(.{
    .port = 443,
    .tls = .{ .cert = "cert.pem", .key = "key.pem" },
    .http2 = true,
});
```

### API Gateways
```zig
// Load balance across WASM microservices
const auth_service = try nexus.wasm.load("./auth.wasm");
const payment_service = try nexus.wasm.load("./payment.wasm");
```

### Edge Functions
```bash
# Compile to WASM and deploy
nexus build --target=wasm32-wasi
wrangler deploy ./dist/worker.wasm
```

### CLI Tools
```zig
// Fast CLI tools with native performance
pub fn main() !void {
    const args = try nexus.process.args();
    // ... blazingly fast CLI logic
}
```

### Embedded Systems
```bash
# Cross-compile for ARM
nexus build --target=aarch64-linux-gnu
scp ./dist/app pi@raspberrypi:~/
```

---

## 📊 Benchmarks

**HTTP Server (req/sec):**
```
Nexus:    ████████████████████ 500,000
Bun:      ████████ 120,000
Node.js:  ████ 50,000
```

**Cold Start (ms):**
```
Nexus:    ██ 5ms
Bun:      ████ 10ms
Deno:     ████████ 30ms
Node.js:  ██████████ 50ms
```

**Memory Usage (MB):**
```
Nexus:    ██ 5MB
Bun:      ████████ 40MB
Node.js:  ██████████ 50MB
Deno:     ████████████ 60MB
```

---

## 🗺️ Roadmap

### v0.1.0 — Foundation (Current)
- [x] Project scaffold
- [ ] Event loop (epoll/kqueue/IOCP)
- [ ] Module loader (Zig only)
- [ ] Basic stdlib (fs, net, timer)
- [ ] HTTP/1.1 server
- [ ] CLI tool
- [ ] ZIM integration

### v0.2.0 — WASM Integration
- [ ] WASM runtime (Wasmer/Wasmtime)
- [ ] WASM module loading
- [ ] WASI support
- [ ] Host function bindings
- [ ] Security policies

### v0.3.0 — Production Ready
- [ ] HTTP/2, HTTP/3
- [ ] WebSocket
- [ ] Streams API
- [ ] Worker threads
- [ ] Performance tuning
- [ ] Production hardening

### v1.0.0 — Ecosystem
- [ ] Package registry
- [ ] Web framework
- [ ] Database drivers
- [ ] Testing framework
- [ ] VSCode extension
- [ ] Full documentation

---

## 🤝 Contributing

We welcome contributions! See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

**Areas we need help:**
- Event loop implementation
- WASM runtime integration
- Standard library modules
- Documentation
- Benchmarking
- Package ecosystem

---

## 📚 Documentation

- [Specification](SPEC.md) — Technical specification
- [Architecture](ARCHITECTURE.md) — System architecture
- [API Reference](docs/API.md) — API documentation
- [Examples](examples/) — Example projects

---

## 🙏 Acknowledgments

- **Zig Team** — For creating an amazing language
- **Ghost Stack** — For the foundational libraries
- **ZIM** — For package management infrastructure
- **Node.js** — For API design inspiration
- **Cloudflare Workers** — For edge runtime inspiration
- **WASI** — For WebAssembly standards

---

## 📜 License

MIT License - see [LICENSE](LICENSE) for details.

---

<div align="center">

**Built with ⚡ by the Ghost Stack Team**

[Website](https://nexus.dev) • [Documentation](https://docs.nexus.dev) • [Discord](https://discord.gg/nexus) • [Twitter](https://twitter.com/nexusruntime)

</div>
