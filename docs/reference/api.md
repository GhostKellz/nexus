# API reference

The public API is everything exported from [`src/root.zig`](../../src/root.zig).
Import it as `@import("nexus")`. This page lists the exported surface; per-module
behavior and stability are covered in the [guides](../README.md#guides).

> **Stability:** pre-1.0 and unstable. Pin to a specific commit. Many modules are
> experimental — see the [capability status](../README.md#capability-status).

## `runtime`

| Symbol | Kind | Notes |
|--------|------|-------|
| `runtime.EventLoop` | type | epoll/kqueue/IOCP event loop (also re-exported as `nexus.EventLoop`) |
| `runtime.Timer` | type | Timer handle |
| `runtime.Task` | type | Scheduled task |
| `runtime.IoEvent` | type | I/O readiness event |

See [internals/event-loop.md](../internals/event-loop.md).

## `hot_reload`

`FileWatcher`, `HotReloadManager` — power `nexus dev`.

## `module`

`ModuleLoader`, `ModuleResolver`, `ModuleCache`, `Module`, `ModuleType`. See
[internals/module-system.md](../internals/module-system.md).

## `wasm`

| Symbol | Notes |
|--------|-------|
| `Engine`, `Module`, `Instance`, `Memory`, `Value`, `ValueType`, `Function` | Engine + values. **No binary parser**: `Module.instantiate` fails closed with `error.WasmParsingUnsupported`. |
| `WasiContext`, `WasiHost`, `Errno`, `Rights` | WASI preview1. Registration fails closed (`error.WasiRegistrationUnsupported`); host-side argv/env/fd logic implemented but not guest-reachable. |
| `WasmPolicy`, `FsPolicy`, `NetRule`, `PolicyConfig` | Capability policy (component-wise path normalization; not a sandbox for hostile code). |
| `Engine.loadModule(io, path)` | Engine-owned: reads a file and builds a `Module` (freed by `Engine.deinit`); instantiation fails closed until a parser exists. |

See [guides/wasm-modules.md](../guides/wasm-modules.md) and
[internals/wasm-runtime.md](../internals/wasm-runtime.md).

## `fs`

`File`, `OpenFlags`, and helpers `readFile`, `writeFile`, `appendFile`, `exists`,
`deleteFile`, `copyFile`, `moveFile`, `stat`. Mid-migration to the pinned
`std.Io` model.

## `net`

`TcpServer`, `TcpClient`, `TcpConnection`; WebSocket types `WebSocket`,
`WebSocketServer`, `WebSocketMessage`, `WebSocketOpcode`, `WebSocketFrameHeader`.
See [guides/websocket.md](../guides/websocket.md).

## `http`

| Symbol | Notes |
|--------|-------|
| `Server`, `ServerConfig` | `init(allocator, config)`, `route`, `use`, `listen`, `deinit` |
| `Request`, `Response` | Handler arguments |
| `Method`, `StatusCode`, `Headers`, `CookieOptions` | Supporting types |
| `Client` | Small-body HTTP client |

`Server` is also re-exported as `nexus.Server`. See
[guides/http-server.md](../guides/http-server.md).

## `static`

`serveFile`, `staticHandler`, `getMimeType`. See
[guides/static-and-middleware.md](../guides/static-and-middleware.md).

## `stream`

`Readable`, `Writable`, `Transform`, `createReadStream`, `createWriteStream` —
callbacks take an explicit caller-owned `context` pointer; writable streams can
own and free heap context on `deinit`. Concurrent pipes are isolated (NX-010,
[resolved](../advisories/resolved.md)).

## `console`

`log`, `debug`, `info`, `warn`, `error`, `print`, `println`, `printError`,
`clear`. 🟢 working.

## `middleware`

`logger`, `cors`, `compression`, `bodyParser`, `auth`. See the `next()` caveat in
[guides/static-and-middleware.md](../guides/static-and-middleware.md).

## `db` — not exported

The PostgreSQL and Redis drivers are **gated out** of the public surface, the
build, and the test tree. They contain multiple removed-std-API calls and do
not compile under the pinned toolchain, so exporting them would be fiction.
`root.zig` asserts their absence. See [guides/databases.md](../guides/databases.md)
and NX-011 in [../advisories/accepted.md](../advisories/accepted.md).

## Convenience re-exports

| Alias | Points to |
|-------|-----------|
| `nexus.EventLoop` | `runtime.EventLoop` |
| `nexus.Server` | `http.Server` |
| `nexus.File` | `fs.File` |
| `nexus.WebSocket` | `net.WebSocket` |

> Not exported from `root.zig` (internal/experimental): HTTP/2, gRPC, the ZIM
> package client (`pkg`), HTTP/3, QUIC, GraphQL, OpenTelemetry, TLS, and ACME.
> They exist in the tree and are unit-tested, but are not part of the stable
> public surface — importing them means reaching into internal files. The
> `db` drivers are gated even more strongly: removed from the public surface,
> the build, and the test tree because they do not compile (NX-011).
