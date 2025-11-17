const std = @import("std");
const Io = std.Io;
const net = std.Io.net;

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
        io.* = Io.Threaded.init(allocator);

        // Listen on address
        const server = try address.listen(io.io(), .{});

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
};

pub const TcpConnection = struct {
    stream: net.Stream,
    io: *Io.Threaded,
    allocator: std.mem.Allocator,

    pub fn close(self: *TcpConnection) void {
        self.stream.close(self.io.io());
    }

    pub fn read(self: *TcpConnection, buffer: []u8) !usize {
        // Use netRead directly
        var iovecs: [1][]u8 = .{buffer};
        return self.io.io().vtable.netRead(self.io.io().userdata, self.stream.socket.handle, &iovecs);
    }

    pub fn writeAll(self: *TcpConnection, data: []const u8) !void {
        // Use netWrite directly
        const iovecs: [1][]const u8 = .{data};
        const n = try self.io.io().vtable.netWrite(self.io.io().userdata, self.stream.socket.handle, "", &iovecs, 0);
        if (n != data.len) return error.ShortWrite;
    }
};
