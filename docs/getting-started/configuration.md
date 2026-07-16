# Configuration

Nexus has a small configuration surface today. This page documents what is
actually wired up in the current tree.

## HTTP server configuration

`http.Server.init` takes an allocator and a `ServerConfig`:

```zig
pub const ServerConfig = struct {
    port: u16,
    host: []const u8 = "0.0.0.0",
};
```

| Field | Type | Default | Notes |
|-------|------|---------|-------|
| `port` | `u16` | — (required) | TCP port to bind |
| `host` | `[]const u8` | `"0.0.0.0"` | Bind address |

TLS, HTTP/2, and keep-alive tuning are **not** exposed through `ServerConfig`
yet. The old README's `.tls = .{ … }` / `.http2 = true` options do not exist in
the current code.

## CLI ports

- `nexus serve` binds port `3000`.
- `nexus dev [port]` uses a positional port argument (default `3000`), e.g.
  `nexus dev 8080`.

## Project layout (`nexus init`)

`nexus init [name]` scaffolds a project:

```
<name>/
├── src/
│   └── main.zig      # generated HTTP server entry point
├── static/           # static assets
├── tests/            # test files
├── build.zig         # generated build file
└── README.md
```

> The generated `main.zig`/`build.zig` currently target an older API shape (for
> example `server.get(...)`, which does not exist yet). Treat `nexus init`
> output as a starting scaffold and adapt it to the current API in
> [reference/api.md](../reference/api.md).

## WASM capability policy

WASM execution is governed by `wasm.WasmPolicy` rather than config files. A
policy controls filesystem, network, environment, memory, and CPU-time access.
Build one with `WasmPolicy.restrictive(...)` (deny by default),
`WasmPolicy.permissive(...)`, or `WasmPolicy.fromConfig(...)`. See
[guides/wasm-modules.md](../guides/wasm-modules.md) and
[internals/wasm-runtime.md](../internals/wasm-runtime.md).

> The policy engine is **experimental**; its path-confinement checks do not yet
> resist traversal/symlink escapes. Do not rely on it to sandbox untrusted
> modules. See [advisories/accepted.md](../advisories/accepted.md).

## Toolchain

The one hard requirement is the pinned Zig version in
[`build.zig.zon`](../../build.zig.zon) (`minimum_zig_version`). This is the
single source of truth — no other file should restate the version.
