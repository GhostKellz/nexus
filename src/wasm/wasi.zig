const std = @import("std");
const engine = @import("engine.zig");

/// WASI error codes
pub const Errno = enum(u16) {
    SUCCESS = 0,
    ACCES = 2,
    AGAIN = 6,
    BADF = 8,
    EXIST = 20,
    INVAL = 28,
    IO = 29,
    ISDIR = 31,
    NOENT = 44,
    NOTDIR = 54,
    PERM = 63,
};

/// WASI file descriptor
pub const Fd = u32;

/// WASI file rights
pub const Rights = packed struct {
    fd_datasync: bool = false,
    fd_read: bool = false,
    fd_seek: bool = false,
    fd_fdstat_set_flags: bool = false,
    fd_sync: bool = false,
    fd_tell: bool = false,
    fd_write: bool = false,
    fd_advise: bool = false,
    fd_allocate: bool = false,
    path_create_directory: bool = false,
    path_create_file: bool = false,
    path_link_source: bool = false,
    path_link_target: bool = false,
    path_open: bool = false,
    fd_readdir: bool = false,
    path_readlink: bool = false,
    path_rename_source: bool = false,
    path_rename_target: bool = false,
    path_filestat_get: bool = false,
    path_filestat_set_size: bool = false,
    path_filestat_set_times: bool = false,
    fd_filestat_get: bool = false,
    fd_filestat_set_size: bool = false,
    fd_filestat_set_times: bool = false,
    path_symlink: bool = false,
    path_remove_directory: bool = false,
    path_unlink_file: bool = false,
    poll_fd_readwrite: bool = false,
    sock_shutdown: bool = false,
    _padding: u35 = 0,
};

/// WASI preopen descriptor
pub const Preopen = struct {
    fd: Fd,
    path: []const u8,
    rights: Rights,
};

/// WASI context
pub const WasiContext = struct {
    allocator: std.mem.Allocator,
    preopens: std.ArrayList(Preopen),
    args: []const []const u8,
    env: std.StringHashMap([]const u8),
    stdin: std.Io.File,
    stdout: std.Io.File,
    stderr: std.Io.File,

    pub fn init(allocator: std.mem.Allocator, args: []const []const u8) !WasiContext {
        return WasiContext{
            .allocator = allocator,
            .preopens = .{},
            .args = args,
            .env = std.StringHashMap([]const u8).init(allocator),
            .stdin = std.Io.File.stdin(),
            .stdout = std.Io.File.stdout(),
            .stderr = std.Io.File.stderr(),
        };
    }

    pub fn deinit(self: *WasiContext) void {
        for (self.preopens.items) |*preopen| {
            self.allocator.free(preopen.path);
        }
        self.preopens.deinit(self.allocator);

        var env_it = self.env.iterator();
        while (env_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.env.deinit();
    }

    pub fn addPreopen(self: *WasiContext, path: []const u8, rights: Rights) !Fd {
        const fd: Fd = @intCast(self.preopens.items.len + 3); // 0, 1, 2 are stdio
        const path_duped = try self.allocator.dupe(u8, path);

        try self.preopens.append(self.allocator, Preopen{
            .fd = fd,
            .path = path_duped,
            .rights = rights,
        });

        return fd;
    }

    pub fn setEnv(self: *WasiContext, key: []const u8, value: []const u8) !void {
        const key_duped = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_duped);
        const value_duped = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_duped);

        try self.env.put(key_duped, value_duped);
    }
};

/// WASI host functions
pub const WasiHost = struct {
    context: *WasiContext,
    memory: *engine.Memory,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, context: *WasiContext, memory: *engine.Memory) WasiHost {
        return WasiHost{
            .context = context,
            .memory = memory,
            .allocator = allocator,
        };
    }

    /// WASI: args_sizes_get
    pub fn argsSizesGet(self: *WasiHost, argc_ptr: u32, argv_buf_size_ptr: u32) !Errno {
        var total_size: u32 = 0;
        for (self.context.args) |arg| {
            total_size += @intCast(arg.len + 1); // +1 for null terminator
        }

        try self.memory.writeInt(u32, argc_ptr, @intCast(self.context.args.len));
        try self.memory.writeInt(u32, argv_buf_size_ptr, total_size);

        return .SUCCESS;
    }

    /// WASI: args_get
    pub fn argsGet(self: *WasiHost, argv_ptr: u32, argv_buf_ptr: u32) !Errno {
        var buf_offset = argv_buf_ptr;

        for (self.context.args, 0..) |arg, i| {
            // Write pointer to arg string
            const ptr_offset = argv_ptr + @as(u32, @intCast(i * 4));
            try self.memory.writeInt(u32, ptr_offset, buf_offset);

            // Write arg string
            try self.memory.write(buf_offset, arg);
            buf_offset += @intCast(arg.len);

            // Write null terminator
            try self.memory.writeInt(u8, buf_offset, 0);
            buf_offset += 1;
        }

        return .SUCCESS;
    }

    /// WASI: environ_sizes_get
    pub fn environSizesGet(self: *WasiHost, environ_count_ptr: u32, environ_buf_size_ptr: u32) !Errno {
        var total_size: u32 = 0;
        var count: u32 = 0;

        var it = self.context.env.iterator();
        while (it.next()) |entry| {
            // Format: KEY=VALUE\0
            total_size += @intCast(entry.key_ptr.*.len + 1 + entry.value_ptr.*.len + 1);
            count += 1;
        }

        try self.memory.writeInt(u32, environ_count_ptr, count);
        try self.memory.writeInt(u32, environ_buf_size_ptr, total_size);

        return .SUCCESS;
    }

    /// WASI: fd_write
    pub fn fdWrite(self: *WasiHost, fd: Fd, iovs_ptr: u32, iovs_len: u32, nwritten_ptr: u32) !Errno {
        var total_written: u32 = 0;

        const file = switch (fd) {
            1 => self.context.stdout,
            2 => self.context.stderr,
            else => return .BADF,
        };

        // Read iovecs
        for (0..iovs_len) |i| {
            const iov_offset = iovs_ptr + @as(u32, @intCast(i * 8));
            const buf_ptr = try self.memory.readInt(u32, iov_offset);
            const buf_len = try self.memory.readInt(u32, iov_offset + 4);

            const data = try self.memory.read(buf_ptr, buf_len);
            const written = file.write(data) catch return .IO;
            total_written += @intCast(written);
        }

        try self.memory.writeInt(u32, nwritten_ptr, total_written);
        return .SUCCESS;
    }

    /// WASI: fd_read
    pub fn fdRead(self: *WasiHost, fd: Fd, iovs_ptr: u32, iovs_len: u32, nread_ptr: u32) !Errno {
        var total_read: u32 = 0;

        const file = switch (fd) {
            0 => self.context.stdin,
            else => return .BADF,
        };

        // Read iovecs
        for (0..iovs_len) |i| {
            const iov_offset = iovs_ptr + @as(u32, @intCast(i * 8));
            const buf_ptr = try self.memory.readInt(u32, iov_offset);
            const buf_len = try self.memory.readInt(u32, iov_offset + 4);

            // Read from file into buffer
            var buffer = try self.allocator.alloc(u8, buf_len);
            defer self.allocator.free(buffer);

            const read_count = file.read(buffer) catch return .IO;
            try self.memory.write(buf_ptr, buffer[0..read_count]);

            total_read += @intCast(read_count);
            if (read_count < buf_len) break; // EOF or short read
        }

        try self.memory.writeInt(u32, nread_ptr, total_read);
        return .SUCCESS;
    }

    /// WASI: proc_exit
    pub fn procExit(self: *WasiHost, exit_code: u32) !Errno {
        _ = self;
        std.process.exit(@intCast(exit_code));
    }

    /// Register all WASI functions to a WASM instance
    pub fn registerAll(self: *WasiHost, instance: *engine.Instance) !void {
        _ = self;
        _ = instance;
        // TODO: Register all WASI functions as host functions
        // This would involve creating wrapper functions for each WASI call
    }
};

test "wasi context" {
    const allocator = std.testing.allocator;

    const args = [_][]const u8{ "prog", "arg1", "arg2" };
    var context = try WasiContext.init(allocator, &args);
    defer context.deinit();

    try context.setEnv("PATH", "/usr/bin");
    try std.testing.expectEqualStrings("/usr/bin", context.env.get("PATH").?);

    const read_rights = Rights{
        .fd_read = true,
        .path_open = true,
        .fd_seek = true,
    };
    const fd = try context.addPreopen("/tmp", read_rights);
    try std.testing.expectEqual(@as(Fd, 3), fd);
}
