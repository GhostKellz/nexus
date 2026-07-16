# WebSocket

> **Status: 🟠 experimental.** The handshake and frame codec are present but
> validation is incomplete. Do not use for untrusted traffic. See the
> [capability status](../README.md#capability-status).

WebSocket support lives in the `net` module (`nexus.net.WebSocket`,
`nexus.net.WebSocketServer`).

## Upgrading a connection

An HTTP handler upgrades a request to a WebSocket via
`res.upgradeWebSocket(req)`:

```zig
fn handleWs(req: *nexus.http.Request, res: *nexus.http.Response) !void {
    const ws = try res.upgradeWebSocket(req);
    try ws.sendText("hello");
    // ... receive loop ...
}
```

## Connection API

`WebSocket` exposes:

| Method | Purpose |
|--------|---------|
| `sendText(bytes)` / `sendBinary(bytes)` | Send a text or binary frame |
| `send(message)` | Send a pre-built `Message` |
| `receive()` | Read the next `Message` |
| `ping()` / `pong()` | Liveness frames |
| `join(room)` / `leave(room)` | Room membership |
| `close()` | Close the connection |

A received `Message` can be inspected with `isText()`, `isBinary()`,
`isClose()`, `isPing()`, `isPong()`, and `getText()`.

## Rooms and broadcast

`WebSocketServer` (constructed with an allocator, host, and port) tracks
clients and rooms:

| Method | Purpose |
|--------|---------|
| `accept()` | Accept a new client |
| `broadcast(msg)` | Send to all clients |
| `broadcastToRoom(room, msg)` | Send to a room |
| `broadcastExcept(client, msg)` | Send to all but one client |
| `clientCount()` | Current client count |
| `removeClient(client)` | Drop a client |

> Frame masking, fragmentation, and close-handshake handling are incomplete.
> Treat this module as a demo surface until it is hardened.

## Related

- [http-server.md](http-server.md) — the HTTP layer that performs the upgrade.
