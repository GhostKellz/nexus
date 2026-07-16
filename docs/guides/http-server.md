# HTTP server

> **Status: 🟡 partial.** HTTP/1.1 request/response works for simple handlers.
> Framing, routing, and the middleware chain are still being hardened — see the
> [capability status](../README.md#capability-status) and
> [advisories/accepted.md](../advisories/accepted.md).

The HTTP server lives in the `http` module (`nexus.http`), exported from
[`src/root.zig`](../../src/root.zig).

## Creating a server

`Server.init` takes an allocator and a `ServerConfig`:

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

    try server.route("GET", "/", handleRoot);
    try server.listen();
}
```

## Routing

Routes are registered with `server.route(method, path, handler)`:

```zig
try server.route("GET", "/", handleRoot);
try server.route("GET", "/api/status", handleStatus);
try server.route("POST", "/api/echo", handleEcho);
```

- There is **no** `server.get()` / `server.post()` helper — use `route` with an
  explicit method string.
- Paths are matched by **exact string equality**. Path parameters such as
  `/users/:id` and wildcard/prefix matching are **not implemented**.

A handler has the signature `fn (req: *Request, res: *Response) !void`:

```zig
fn handleStatus(req: *nexus.http.Request, res: *nexus.http.Response) !void {
    _ = req;
    try res.json(.{ .status = "running" });
}
```

## Requests

`Request` exposes:

| Method | Purpose |
|--------|---------|
| `readBody()` | Read the request body as bytes |
| `getHeader(key)` | Header value or `null` |
| `getQuery(key)` | Query-string parameter or `null` |
| `getCookie(name)` | Cookie value or `null` |
| `jsonBody(T)` | Parse the body as JSON into `T` |

## Responses

`Response` is chainable for `status`/`setHeader`/`setCookie` and terminal for
the body writers:

| Method | Purpose |
|--------|---------|
| `status(code)` | Set the status code (returns `*Response`) |
| `setHeader(key, value)` | Set a header (returns `*Response`) |
| `setCookie(name, value, options)` | Set a cookie (returns `*Response`) |
| `send(bytes)` | Write a raw body |
| `text(bytes)` | Write `text/plain` |
| `html(bytes)` | Write `text/html` |
| `json(value)` | Serialize `value` as JSON |
| `upgradeWebSocket(req)` | Upgrade the connection (see [websocket.md](websocket.md)) |

```zig
fn handleRoot(req: *nexus.http.Request, res: *nexus.http.Response) !void {
    _ = req;
    try res.html("<h1>Hello from Nexus</h1>");
}
```

## Middleware

Register middleware with `server.use(...)` before routing. See
[static-and-middleware.md](static-and-middleware.md) for the chain semantics
(a real `next()` that runs each middleware once and short-circuits) and the
built-in middleware.

## Related

- [reference/api.md](../reference/api.md) — full exported surface.
- [internals/architecture.md](../internals/architecture.md) — request lifecycle.
