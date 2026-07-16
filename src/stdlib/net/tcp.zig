const std = @import("std");
const Io = std.Io;
const net = std.Io.net;

/// Wait until `handle` is ready for `events` or `timeout_ms` elapses.
///
/// This is the sole enforcement point for per-connection deadlines.
/// `std.Io.Threaded` performs a *blocking* `readv`/`writev` and treats `EAGAIN`
/// as a programmer bug — it calls `std.debug.panic` in Debug/ReleaseSafe — so
/// `SO_RCVTIMEO`/`SO_SNDTIMEO` cannot be used to bound those calls: a firing
/// socket timeout would crash the process. Polling the raw fd before the
/// blocking I/O call is the mechanism that actually honours the deadline.
///
/// `timeout_ms` follows `poll(2)` semantics: negative blocks indefinitely, 0
/// returns immediately. Returns true when the fd is ready, false on timeout.
fn pollReady(handle: std.posix.fd_t, events: i16, timeout_ms: i32) std.posix.PollError!bool {
    var fds = [_]std.posix.pollfd{.{ .fd = handle, .events = events, .revents = 0 }};
    return (try std.posix.poll(&fds, timeout_ms)) != 0;
}

pub const TcpServer = struct {
    server: net.Server,
    io: *Io.Threaded,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, host: []const u8, port: u16) !TcpServer {
        // Parse address
        const address = try net.IpAddress.parse(host, port);

        // Create Io runtime
        const io = try allocator.create(Io.Threaded);
        errdefer allocator.destroy(io);
        io.* = Io.Threaded.init(allocator, .{ .environ = .empty });
        // If listen fails below, tear down the provider's internal state too;
        // destroying the pointer alone would leak whatever init allocated.
        errdefer io.deinit();

        // Listen on address. `reuse_address` sets SO_REUSEADDR (and SO_REUSEPORT
        // on POSIX) so a restarted server can rebind its fixed port immediately:
        // without it a listener still lingering in the kernel (a connection in
        // TIME_WAIT after a graceful shutdown) makes the next bind fail with
        // AddressInUse. This is the standard long-running-server behaviour and is
        // what makes graceful-restart deterministic.
        const server = try address.listen(io.io(), .{ .reuse_address = true });

        return TcpServer{
            .server = server,
            .io = io,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TcpServer) void {
        self.server.deinit(self.io.io());

        // Properly deinit Io.Threaded
        const io_ptr = self.io;
        io_ptr.deinit();
        self.allocator.destroy(io_ptr);
    }

    pub fn accept(self: *TcpServer) !TcpConnection {
        const stream = try self.server.accept(self.io.io());
        return TcpConnection{
            .stream = stream,
            .io = self.io,
            .allocator = self.allocator,
        };
    }

    /// Local port the listener is bound to. With `port = 0` the OS assigns an
    /// ephemeral port; this reports the resolved value (useful for tests that
    /// bind to any free port and then connect to it).
    pub fn boundPort(self: *const TcpServer) u16 {
        return self.server.socket.address.getPort();
    }

    /// Unblock threads parked in `accept` by shutting the listening socket down
    /// for receive. Blocked `accept` calls then return `error.SocketNotListening`
    /// — the std-sanctioned concurrent cancellation path (see `net.Server`'s
    /// `AcceptError`) — so a worker pool can observe a stop request without
    /// waiting for one more connection. The descriptor stays open; `deinit`
    /// still performs the actual close. Best-effort: a failed shutdown is
    /// ignored because the only recovery is the close `deinit` already does.
    pub fn shutdownListener(self: *TcpServer) void {
        const io = self.io.io();
        io.vtable.netShutdown(io.userdata, self.server.socket.handle, .both) catch {};
    }
};

pub const TcpConnection = struct {
    stream: net.Stream,
    io: *Io.Threaded,
    allocator: std.mem.Allocator,
    /// Deadline for a single `writeAll`, in milliseconds. 0 (or negative)
    /// disables the gate and blocks like an untimed write.
    write_timeout_ms: i32 = 0,

    pub fn close(self: *TcpConnection) void {
        self.stream.close(self.io.io());
    }

    /// Block until the connection is readable or `timeout_ms` elapses (negative
    /// blocks indefinitely). Returns `error.ReadTimeout` on expiry so a stalled
    /// peer cannot pin the accept loop. Call before `read` to bound the wait.
    pub fn waitReadable(self: *TcpConnection, timeout_ms: i32) !void {
        if (try pollReady(self.stream.socket.handle, std.posix.POLL.IN, timeout_ms)) return;
        return error.ReadTimeout;
    }

    pub fn read(self: *TcpConnection, buffer: []u8) !usize {
        var iovecs: [1][]u8 = .{buffer};
        return self.stream.read(self.io.io(), &iovecs);
    }

    pub fn writeAll(self: *TcpConnection, data: []const u8) !void {
        // Gate on writability so a peer that stops reading cannot pin this
        // thread indefinitely inside the blocking netWrite below.
        const timeout: i32 = if (self.write_timeout_ms <= 0) -1 else self.write_timeout_ms;
        if (!try pollReady(self.stream.socket.handle, std.posix.POLL.OUT, timeout)) {
            return error.WriteTimeout;
        }
        const iovecs: [1][]const u8 = .{data};
        // `netWrite` follows the std `Io.Writer.drain` contract: the final data
        // buffer is a splat pattern emitted `splat` times. To send `data` exactly
        // once the splat count must be 1 — a 0 here writes zero payload bytes.
        const n = try self.io.io().vtable.netWrite(self.io.io().userdata, self.stream.socket.handle, "", &iovecs, 1);
        if (n != data.len) return error.ShortWrite;
    }
};

/// Client-side TCP connection.
///
/// Mirrors `TcpConnection`'s I/O and `TcpServer`'s owned `Io.Threaded`
/// runtime, but initiates an outbound connection instead of accepting one.
/// Like `TcpServer`, `host` must be an IP literal (see `net.IpAddress.parse`).
pub const TcpClient = struct {
    io: *Io.Threaded,
    allocator: std.mem.Allocator,
    stream: ?net.Stream = null,

    pub fn init(allocator: std.mem.Allocator) !TcpClient {
        const io = try allocator.create(Io.Threaded);
        errdefer allocator.destroy(io);
        io.* = Io.Threaded.init(allocator, .{ .environ = .empty });

        return TcpClient{
            .io = io,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TcpClient) void {
        self.disconnect();
        const io_ptr = self.io;
        io_ptr.deinit();
        self.allocator.destroy(io_ptr);
    }

    pub fn connect(self: *TcpClient, host: []const u8, port: u16) !void {
        const address = try net.IpAddress.parse(host, port);
        self.stream = try address.connect(self.io.io(), .{ .mode = .stream });
    }

    pub fn disconnect(self: *TcpClient) void {
        if (self.stream) |*stream| {
            stream.close(self.io.io());
            self.stream = null;
        }
    }

    pub fn read(self: *TcpClient, buffer: []u8) !usize {
        const stream = &(self.stream orelse return error.NotConnected);
        var iovecs: [1][]u8 = .{buffer};
        return stream.read(self.io.io(), &iovecs);
    }

    pub fn write(self: *TcpClient, data: []const u8) !void {
        const stream = self.stream orelse return error.NotConnected;
        const iovecs: [1][]const u8 = .{data};
        // Splat count 1: emit `data` once. See TcpConnection.writeAll for the
        // `netWrite` splat contract (a 0 here would send zero payload bytes).
        const n = try self.io.io().vtable.netWrite(self.io.io().userdata, stream.socket.handle, "", &iovecs, 1);
        if (n != data.len) return error.ShortWrite;
    }
};

test "pollReady enforces a real read deadline and detects readiness" {
    // A connected SOCK_STREAM pair mirrors the TCP read path exactly: the same
    // poll(2) gate that fronts every blocking netRead. This proves the deadline
    // actually fires (not a silent no-op) and that readiness is observed.
    var fds: [2]std.posix.fd_t = undefined;
    const rc = std.os.linux.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    try std.testing.expectEqual(@as(usize, 0), rc);
    defer _ = std.os.linux.close(fds[0]);
    defer _ = std.os.linux.close(fds[1]);

    // No bytes queued: a bounded poll on the read end must time out.
    try std.testing.expect(!try pollReady(fds[0], std.posix.POLL.IN, 20));

    // After the peer writes, the same gate reports readiness promptly.
    try std.testing.expectEqual(@as(usize, 1), std.os.linux.write(fds[1], "x", 1));
    try std.testing.expect(try pollReady(fds[0], std.posix.POLL.IN, 1000));
}

test "pollReady write gate is ready on a drainable socket" {
    // The write deadline uses the same primitive with POLL.OUT; a fresh pair
    // has send-buffer space, so the gate must report writable without blocking.
    var fds: [2]std.posix.fd_t = undefined;
    const rc = std.os.linux.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    try std.testing.expectEqual(@as(usize, 0), rc);
    defer _ = std.os.linux.close(fds[0]);
    defer _ = std.os.linux.close(fds[1]);

    try std.testing.expect(try pollReady(fds[0], std.posix.POLL.OUT, 20));
}

test "reuse_address lets a second server bind a port already in use" {
    // Regression guard for the port-reuse fix: `TcpServer.init` now sets
    // SO_REUSEADDR/SO_REUSEPORT, so a second listener may bind the *same*
    // concrete port while the first is still open. Without the option this
    // second bind fails with error.AddressInUse — so this test fails closed if
    // the socket option is ever dropped. It also does not depend on TIME_WAIT
    // timing, which makes it deterministic (unlike a close-then-rebind race).
    const allocator = std.testing.allocator;

    var first = try TcpServer.init(allocator, "127.0.0.1", 0);
    defer first.deinit();

    // Resolve the OS-assigned ephemeral port and bind a *second* listener to it.
    const port = first.boundPort();
    try std.testing.expect(port != 0);

    var second = try TcpServer.init(allocator, "127.0.0.1", port);
    defer second.deinit();

    try std.testing.expectEqual(port, second.boundPort());
}

test "a fixed port is rebindable after its listener is torn down" {
    // The graceful-restart path: bind a concrete port, tear the listener fully
    // down (as `deinit` does on shutdown), then bind the *same* port again. This
    // must succeed rather than reporting AddressInUse, so a server can restart on
    // its configured port without waiting out the kernel's TIME_WAIT window.
    const allocator = std.testing.allocator;

    const port = blk: {
        var server = try TcpServer.init(allocator, "127.0.0.1", 0);
        defer server.deinit();
        break :blk server.boundPort();
    };
    try std.testing.expect(port != 0);

    var restarted = try TcpServer.init(allocator, "127.0.0.1", port);
    defer restarted.deinit();
    try std.testing.expectEqual(port, restarted.boundPort());
}
