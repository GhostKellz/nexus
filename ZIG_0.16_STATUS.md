# Zig 0.16.0 Migration Status

## ✅ Successfully Built!

The Nexus runtime now compiles with Zig 0.16.0-dev. However, several components need proper implementation using the new APIs.

## Key API Changes in Zig 0.16.0

### 1. ArrayList is Now Unmanaged by Default

**Old API (Zig 0.13):**
```zig
var list = std.ArrayList(T).init(allocator);
defer list.deinit();
try list.append(item);
```

**New API (Zig 0.16):**
```zig
var list: std.ArrayList(T) = .{};  // or .empty
defer list.deinit(allocator);
try list.append(allocator, item);
```

**Status:** ✅ Fixed in all files

### 2. I/O System Completely Redesigned

**Old API:**
```zig
const stdout = std.io.getStdOut().writer();
stdout.print("Hello\n", .{});
```

**New API:**
```zig
// Simple approach: use std.debug.print
std.debug.print("Hello\n", .{});

// Advanced approach: use std.Io with vtables
const io = try std.Io.Threaded.init(allocator);
const file = std.Io.File.stdout();
file.writeStreaming(io, &[_][]const u8{"Hello\n"});
```

**Status:** ⚠️ Simplified to use `std.debug.print` for now

### 3. Networking Moved to std.Io.net

**Old API:**
```zig
const server = std.net.Server.init(...);
const stream = std.net.Stream;
```

**New API:**
```zig
const socket_handle = std.Io.net.Socket.Handle;
// Requires std.Io object for async operations
```

**Status:** ⚠️ Stubbed out - needs complete rewrite

### 4. Time API Changed

**Old API:**
```zig
const timestamp = std.time.timestamp();
```

**New API:**
```zig
// Use Io.Clock for timestamps
const ts = try Io.Clock.now(.real, io);
```

**Status:** ⚠️ Removed timestamp from console logging for now

### 5. JSON API Changed

**Old API:**
```zig
const json_str = try std.json.stringifyAlloc(allocator, value, .{});
```

**New API:**
```zig
// Use Stringify with Writer
var out: std.Io.Writer.Allocating = .init(allocator);
var stringify: std.json.Stringify = .{ .writer = &out.writer };
try stringify.write(value);
```

**Status:** ⚠️ Stubbed out - needs implementation

## Components Status

### ✅ Fully Migrated

| Component | File | Status |
|-----------|------|--------|
| Module Loader | `src/module/loader.zig` | ArrayList API fixed |
| WASM Engine | `src/wasm/engine.zig` | ArrayList API fixed |
| WASM Policy | `src/wasm/policy.zig` | No changes needed |
| WASI Context | `src/wasm/wasi.zig` | ArrayList + File API fixed |
| Streams | `src/stdlib/stream/stream.zig` | ArrayList API fixed |

### ⚠️ Needs Proper Implementation

| Component | File | Issue | Priority |
|-----------|------|-------|----------|
| Console | `src/stdlib/console/console.zig` | Using `std.debug.print` instead of proper I/O | Medium |
| TCP | `src/stdlib/net/tcp.zig` | **Stubbed out** - needs complete rewrite for async I/O | **High** |
| HTTP | `src/stdlib/net/http.zig` | Response methods stubbed, needs I/O + JSON API | **High** |
| WebSocket | `src/stdlib/net/websocket.zig` | Socket handle type changed, needs I/O implementation | High |
| Event Loop | `src/runtime/event_loop.zig` | May need updates for new I/O model | Medium |

## Next Steps

### High Priority

1. **Implement TCP Networking** (`src/stdlib/net/tcp.zig`)
   - Study `std.Io.net` API
   - Implement TcpServer using `std.Io.net.Socket`
   - Requires `std.Io.Threaded` or custom Io implementation

2. **Implement HTTP Server** (`src/stdlib/net/http.zig`)
   - Update Response.send() to use proper I/O
   - Fix JSON serialization with new API
   - Integrate with new TCP implementation

### Medium Priority

3. **Improve Console Logging** (`src/stdlib/console/console.zig`)
   - Add timestamp back using `Io.Clock`
   - Use proper file I/O instead of debug.print
   - Consider buffered output

4. **Update Event Loop** (`src/runtime/event_loop.zig`)
   - Review compatibility with std.Io.Threaded
   - May be able to leverage built-in Zig async I/O
   - Consider using IoUring, Kqueue directly

### Low Priority

5. **WebSocket Implementation**
   - Update after TCP/HTTP are working
   - Integrate with async I/O model

## Architecture Decision Needed

The new Zig 0.16 I/O system is built around:
- **Io vtable interface**: All I/O operations go through `std.Io`
- **Async-first design**: IoUring, Kqueue, IOCP backends
- **Explicit allocator threading**: Unmanaged data structures

**Options:**

1. **Use std.Io.Threaded**: Leverage built-in async I/O runtime
   - Pros: Well-tested, cross-platform, integrates with stdlib
   - Cons: May conflict with custom event loop

2. **Custom Io Implementation**: Build our own Io vtable
   - Pros: Full control, can integrate with custom event loop
   - Cons: More work, need to handle platform differences

3. **Hybrid Approach**: Use std.Io.Threaded, wrap in Nexus API
   - Pros: Best of both worlds
   - Cons: Additional abstraction layer

**Recommendation:** Start with #3 (Hybrid), migrate to #1 long-term if custom event loop isn't needed.

## File-by-File TODO List

### `src/stdlib/net/tcp.zig`
```zig
// TODO: Rewrite for Zig 0.16 std.Io.net API
// 1. Create Io object (std.Io.Threaded.init)
// 2. Use std.Io.net.IpAddress for addressing
// 3. Use std.Io.net.Socket for server/client
// 4. Implement listen, accept, connect with Io parameter
```

### `src/stdlib/net/http.zig`
```zig
// TODO: Fix Response.send()
// - Use socket.writeStreaming(io, buffers)
// TODO: Fix Response.json()
// - Use std.json.Stringify with Writer
```

### `src/stdlib/console/console.zig`
```zig
// TODO: Add timestamp using Io.Clock.now(.real, io)
// TODO: Replace std.debug.print with proper File I/O
```

## References

- Zig 0.16.0 source: `/opt/zig-0.16.0-dev/lib/std/`
- New I/O docs: `/opt/zig-0.16.0-dev/lib/std/Io.zig`
- Network API: `/opt/zig-0.16.0-dev/lib/std/Io/net.zig`
- Threaded runtime: `/opt/zig-0.16.0-dev/lib/std/Io/Threaded.zig`
