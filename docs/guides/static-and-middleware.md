# Static files and middleware

> **Status: 🟡 partial.** Static serving and middleware dispatch work: the
> middleware chain threads a real `next()` and static path confinement is
> normalized (traversal rejected). Remaining gaps are feature breadth (e.g.
> exact-path routing, compression/auth placeholders), not the security holes
> that were closed in v0.1.2. See [advisories/resolved.md](../advisories/resolved.md)
> (NX-004, NX-005).

## Middleware

Middleware functions live in the `middleware` module and have the signature:

```zig
fn (req: *http.Request, res: *http.Response, next: *const fn () anyerror!void) anyerror!void
```

Register them with `server.use(...)` before routes:

```zig
try server.use(nexus.middleware.logger);
try server.use(nexus.middleware.cors);
```

Built-in middleware:

| Name | Purpose |
|------|---------|
| `logger` | Logs method + path per request |
| `cors` | Adds permissive CORS headers |
| `compression` | Placeholder for response compression |
| `bodyParser` | Reads/normalizes the request body |
| `auth` | Placeholder auth gate |

> The dispatch chain threads a real `next()`: `Chain.next()` advances a cursor
> through the registered middleware, runs each once, and short-circuits reliably
> when a middleware returns without calling `next` (NX-005,
> [resolved](../advisories/resolved.md)).

## Static files

The `static` module serves files from a directory. The main entry points are
`serveStatic`, `serveFile`, and `staticHandler`, with `StaticFileOptions`
controlling caching headers and index behavior. `getMimeType` maps extensions to
content types.

```zig
// Conceptual — see src/stdlib/net/static.zig for the current signatures.
try nexus.static.serveStatic(res, "./static", req.path, .{});
```

> **Path confinement:** `resolveStaticPath` normalizes the request path lexically
> and rejects traversal above the served root, including percent-encoded
> (`%2e%2e`) attempts; a regression test pins this (NX-004,
> [resolved](../advisories/resolved.md)). Confinement is lexical, not
> `realpath`-based, so symlinks inside the root are not resolved — keep that in
> mind before serving a directory that contains untrusted symlinks.

## Related

- [http-server.md](http-server.md) — routing and responses.
- [advisories/accepted.md](../advisories/accepted.md) — the accepted risks above.
