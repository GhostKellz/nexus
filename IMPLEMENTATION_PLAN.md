# Nexus Implementation Roadmap

## ✅ COMPLETED (Phase 1)

- [x] HTTP/1.1 server with routing
- [x] gRPC server with Protocol Buffers
- [x] TCP networking (std.Io.Threaded)
- [x] HTTP request parsing (headers, query, body)
- [x] JSON serialization/deserialization
- [x] Memory leak fixes
- [x] Test suite (350 req/s baseline)
- [x] Event loop foundation
- [x] WASM/WASI scaffolding
- [x] Module loader
- [x] Security policies

## 🔥 IN PROGRESS (Phase 2 - Critical)

### 1. Middleware System [2 hours]
```zig
server.use(logger);
server.use(cors);
server.use(compression);
```
**Files:** `src/stdlib/net/middleware.zig`, update `http.zig`

### 2. Cookie Support [1 hour]
```zig
req.getCookie("session_id")
res.setCookie("user", value, .{ .httpOnly = true })
```
**Files:** Update `http.zig` Request/Response

### 3. Static File Serving [1 hour]
```zig
server.static("/public", "./assets");
```
**Files:** `src/stdlib/net/static.zig`

### 4. CLI Commands [2 hours]
```bash
nexus init my-project
nexus dev --port 3000
nexus build --release
```
**Files:** Update `src/main.zig`

## 🎯 HIGH PRIORITY (Phase 3)

### 5. Real WASM Execution [4 hours]
- Integrate wasm3 or wasmtime-zig
- Execute .wasm modules
- WASI syscalls
**Files:** `src/wasm/engine.zig`, `src/wasm/runtime.zig`

### 6. WebSocket Complete [3 hours]
- Handshake (HTTP Upgrade)
- Frame encode/decode (done)
- Broadcast, rooms
**Files:** `src/stdlib/net/websocket.zig`

### 7. Database Drivers [6 hours]
- PostgreSQL: libpq bindings
- Redis: RESP protocol
- SQLite: embedded
**Files:** `src/stdlib/db/{postgres,redis,sqlite}.zig`

## 📦 MEDIUM PRIORITY (Phase 4)

### 8. ZIM Integration [3 hours]
- `nexus.toml` config
- Dependency resolution from /data/projects/zim
- Package downloading

### 9. Hot Reload Dev Server [2 hours]
- File watching
- Auto-restart on changes
- WebSocket live reload

### 10. Template Engine [2 hours]
- Simple {{variable}} syntax
- Loops, conditionals
- Partials/includes

### 11. Logging & Observability [3 hours]
- Structured JSON logging
- OpenTelemetry tracing
- Prometheus metrics

## 🚀 ADVANCED (Phase 5)

### 12. HTTP/2 & HTTP/3 [8 hours]
- h2 for gRPC
- QUIC for h3
- Server push

### 13. Cluster Mode [4 hours]
- Multi-process like Node cluster
- Load balancing
- IPC

### 14. Performance Optimization [ongoing]
- Target: 500k+ req/s (from 350)
- Connection pooling
- Zero-copy where possible
- Custom allocators

### 15. Edge Runtime Features [6 hours]
- Compile Nexus to WASM
- V8 Isolates-style sandboxing
- <1ms cold starts

## 📊 METRICS & TARGETS

| Metric | Current | Target | Status |
|--------|---------|--------|--------|
| HTTP req/s | 350 | 500,000+ | 🔴 |
| Binary size | 11MB | 5MB | 🟡 |
| Memory usage | TBD | 5MB | ⚪ |
| Cold start | TBD | <5ms | ⚪ |

## 🧪 TESTING STRATEGY

- [x] HTTP integration tests
- [ ] Unit tests for all modules
- [ ] Benchmark suite
- [ ] Memory leak detection
- [ ] Fuzzing for parsers
- [ ] Load testing (wrk, autocannon)

## 📝 NEXT ACTIONS (This Session)

1. ✅ HTTP parser - DONE
2. ✅ Test suite - DONE
3. 🔄 Middleware system - IN PROGRESS
4. Cookie support
5. Static file serving
6. CLI improvements

**Estimated Time to MVP:** 20-30 hours
**Estimated Time to Production:** 50-80 hours
