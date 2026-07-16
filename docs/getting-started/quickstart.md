# Quickstart

This walks through building Nexus and running a first program. It assumes you
have the pinned Zig toolchain and a built CLI — see
[installation.md](installation.md).

> Nexus is experimental. The examples below use the API as it exists today; see
> each [guide](../guides/) and the [capability status](../README.md#capability-status)
> for what is stable versus placeholder.

## Run a file

The CLI dispatches by file extension:

```bash
nexus run app.zig      # compiles & runs via `zig run` (subprocess)
nexus run module.wasm  # fails closed (no parser): error.UnsupportedWasmExecution
nexus run module.wat   # fails closed (no wat2wasm): error.UnsupportedFileType
```

Only `.zig` files execute today; `.wasm`/`.wat` fail closed with a nonzero exit
because the engine has no binary/`.wat` parser (see
[wasm-modules.md](../guides/wasm-modules.md)).

Example programs live in [`examples/`](../../examples).

## A minimal HTTP server

`server.zig`:

```zig
const std = @import("std");
const nexus = @import("nexus");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var server = try nexus.http.Server.init(gpa.allocator(), .{
        .port = 3000,
        .host = "0.0.0.0",
    });
    defer server.deinit();

    try server.use(nexus.middleware.logger);
    try server.route("GET", "/", handleRoot);
    try server.route("GET", "/api/status", handleStatus);

    try server.listen();
}

fn handleRoot(req: *nexus.http.Request, res: *nexus.http.Response) !void {
    _ = req;
    try res.html("<h1>Hello from Nexus</h1>");
}

fn handleStatus(req: *nexus.http.Request, res: *nexus.http.Response) !void {
    _ = req;
    try res.json(.{ .status = "running" });
}
```

Key points that match the current implementation:

- `Server.init` takes an **allocator** and a `ServerConfig` (`port`, `host`).
- Routes are registered with `server.route("GET", path, handler)`. There is no
  `server.get()` helper yet, and paths are matched by **exact equality** — path
  parameters like `/users/:id` are not implemented.
- Responses expose `res.json`, `res.html`, `res.text`, `res.send`,
  `res.status`, `res.setHeader`, and `res.setCookie`.

See [guides/http-server.md](../guides/http-server.md) for the full request/response
surface.

## Try the built-in demo server

```bash
nexus serve
# Serves a demo page on http://localhost:3000 with GET / and GET /api/status
```

## Development loop

```bash
nexus dev            # watches src/ and examples/, rebuilds and restarts (port 3000)
nexus dev 8080       # same, on port 8080 (positional port argument)
```

## Next steps

- [configuration.md](configuration.md) — configuration and project layout.
- [guides/](../guides/) — HTTP, WebSocket, WASM.
- [reference/cli.md](../reference/cli.md) — full command reference.
