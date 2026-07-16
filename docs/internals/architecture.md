# Architecture

This describes how Nexus is structured today. It documents the **real** code
paths, including where a subsystem is scaffolding rather than a finished
implementation (see the [capability status](../README.md#capability-status)).

## System overview

Three pillars: the runtime (event loop + scheduler), the module system
(resolves/caches `.zig` and `.wasm`), and the standard library (HTTP, net, db,
etc.), all driven by the CLI.

```mermaid
flowchart LR
    CLI["nexus CLI<br/>(src/main.zig)"] --> RT["Event loop<br/>(runtime/event_loop.zig)"]
    RT --> MOD["Module system<br/>(module/loader.zig)"]
    MOD -->|.zig| NATIVE["zig run<br/>(subprocess)"]
    MOD -->|.wasm / .wat| WASM["WASM engine<br/>+ WASI + policy"]
    RT --> STD["Standard library<br/>(src/stdlib)"]
    STD --> NET["net · http · http2 · static"]
    STD --> DATA["db · stream · fs"]
    STD --> OBS["console · middleware · pkg · grpc"]
    WASM --> POLICY["WasmPolicy<br/>(fs / net / mem / cpu)"]
```

## CLI dispatch

`nexus <command>` routes to a handler in [`src/main.zig`](../../src/main.zig).
`run` dispatches by file extension.

```mermaid
flowchart TD
    START(["nexus &lt;command&gt;"]) --> CMD{command}
    CMD -->|run| RUN{extension?}
    CMD -->|dev| DEV["watch src/ + examples/<br/>rebuild + restart"]
    CMD -->|serve| SERVE["built-in demo server<br/>port 3000"]
    CMD -->|init| INIT["scaffold project dir"]
    CMD -->|build| BUILD["build step (partial)"]
    CMD -->|deploy| DEPLOY["stub"]
    CMD -->|test| TEST["fails closed (nonzero):<br/>UnsupportedCommand"]
    RUN -->|.zig| ZIG["zig run (subprocess)"]
    RUN -->|.wasm| WENGINE["fails closed:<br/>UnsupportedWasmExecution"]
    RUN -->|.wat| WAT["fails closed:<br/>UnsupportedFileType"]
```

## HTTP request lifecycle

The HTTP server accepts a TCP connection, reads a single buffered request, runs
the middleware chain, matches a route by exact path, and writes the response.

```mermaid
sequenceDiagram
    participant C as Client
    participant S as http.Server
    participant M as Middleware chain
    participant H as Route handler
    C->>S: TCP connect + request bytes
    S->>S: parse request (single 8 KiB buffer)
    S->>M: run use()-registered middleware
    Note over M: next() advances a cursor,<br/>runs each once, short-circuits
    M->>H: exact-path route match
    H->>S: res.json / html / text / send
    S->>C: response bytes
```

> Known gaps in this flow: request framing beyond one buffer and path-parameter
> routing (exact-path only). The middleware `next()` now chains reliably (NX-005,
> [resolved](../advisories/resolved.md)). See
> [advisories/accepted.md](../advisories/accepted.md).

## Module resolution and execution

```mermaid
flowchart LR
    REQ["load(path)"] --> RESOLVE["ModuleResolver<br/>search paths"]
    RESOLVE --> CACHE{"ModuleCache<br/>hit?"}
    CACHE -->|yes| RETURN["cached Module"]
    CACHE -->|no| TYPE{ModuleType}
    TYPE -->|zig| ZIGRUN["native / subprocess"]
    TYPE -->|wasm| ENGINE["wasm.Engine<br/>validate + instantiate"]
    ENGINE --> STORE["store in cache"]
    ZIGRUN --> STORE
    STORE --> RETURN
```

See [module-system.md](module-system.md) and [wasm-runtime.md](wasm-runtime.md).

## Source layout

| Path | Contents |
|------|----------|
| `src/main.zig` | CLI entry + command dispatch |
| `src/root.zig` | Public library API surface |
| `src/runtime/` | Event loop, timers, scheduler, hot reload |
| `src/module/` | Module resolution + cache |
| `src/wasm/` | Engine, interpreter, WASI, policy |
| `src/stdlib/net/` | http, http2, static, websocket, grpc, middleware, tcp |
| `src/stdlib/db/` | PostgreSQL, Redis (gated out of the surface/build/tests; do not compile — NX-011) |
| `src/stdlib/fs/` | File I/O (mid `std.Io` migration) |
| `src/stdlib/stream/` | Readable/Writable/Transform |
| `src/stdlib/console/` | Logging helpers |
| `src/stdlib/package/` | ZIM package client (operations fail closed pending a real pipeline) |

## Related

- [event-loop.md](event-loop.md) — the runtime core.
- [module-system.md](module-system.md) — resolution/caching.
- [wasm-runtime.md](wasm-runtime.md) — WASM engine, WASI, policy.
