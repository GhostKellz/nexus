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
    stdin: std.fs.File,
    stdout: std.fs.File,
    stderr: std.fs.File,
    file_table: std.AutoHashMap(Fd, std.fs.File),

    pub fn init(allocator: std.mem.Allocator, args: []const []const u8) !WasiContext {
        return WasiContext{
            .allocator = allocator,
            .preopens = std.ArrayList(Preopen).init(allocator),
            .args = args,
            .env = std.StringHashMap([]const u8).init(allocator),
            .stdin = std.io.getStdIn(),
            .stdout = std.io.getStdOut(),
            .stderr = std.io.getStdErr(),
            .file_table = std.AutoHashMap(Fd, std.fs.File).init(allocator),
        };
    }

    pub fn deinit(self: *WasiContext) void {
        for (self.preopens.items) |*preopen| {
            self.allocator.free(preopen.path);
        }
        self.preopens.deinit();

        var env_it = self.env.iterator();
        while (env_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.env.deinit();

        // Close all open file descriptors
        var file_it = self.file_table.valueIterator();
        while (file_it.next()) |file| {
            file.close();
        }
        self.file_table.deinit();
    }

    pub fn addPreopen(self: *WasiContext, path: []const u8, rights: Rights) !Fd {
        const fd: Fd = @intCast(self.preopens.items.len + 3); // 0, 1, 2 are stdio
        const path_duped = try self.allocator.dupe(u8, path);

        try self.preopens.append(Preopen{
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

    /// WASI: fd_close
    pub fn fdClose(self: *WasiHost, fd: Fd) !Errno {
        if (fd < 3) return .BADF; // Don't close stdio

        if (self.context.file_table.get(fd)) |file| {
            file.close();
            _ = self.context.file_table.remove(fd);
            return .SUCCESS;
        }

        return .BADF;
    }

    /// WASI: fd_seek
    pub fn fdSeek(self: *WasiHost, fd: Fd, offset: i64, whence: u8, newoffset_ptr: u32) !Errno {
        const file = self.context.file_table.get(fd) orelse return .BADF;

        // Translate WASI whence to std.io.SeekFrom
        // whence: 0 = SET (start), 1 = CUR (current), 2 = END (end)
        const new_offset: u64 = switch (whence) {
            0 => blk: {
                // SET: seek from beginning
                break :blk file.seekTo(@intCast(offset)) catch return .IO;
            },
            1 => blk: {
                // CUR: seek from current position
                const current = file.getPos() catch return .IO;
                const target = @as(i64, @intCast(current)) + offset;
                if (target < 0) return .INVAL;
                break :blk file.seekTo(@intCast(target)) catch return .IO;
            },
            2 => blk: {
                // END: seek from end
                const stat = file.stat() catch return .IO;
                const file_size = @as(i64, @intCast(stat.size));
                const target = file_size + offset;
                if (target < 0) return .INVAL;
                break :blk file.seekTo(@intCast(target)) catch return .IO;
            },
            else => return .INVAL,
        };

        try self.memory.writeInt(u64, newoffset_ptr, new_offset);

        return .SUCCESS;
    }

    /// WASI: path_open
    pub fn pathOpen(
        self: *WasiHost,
        dirfd: Fd,
        dirflags: u32,
        path_ptr: u32,
        path_len: u32,
        oflags: u16,
        fs_rights_base: u64,
        fs_rights_inheriting: u64,
        fdflags: u16,
        fd_ptr: u32,
    ) !Errno {
        _ = dirflags;
        _ = fs_rights_inheriting;
        _ = fdflags;

        const path_bytes = try self.memory.read(path_ptr, path_len);
        const path = std.fs.path.resolve(self.allocator, &.{path_bytes}) catch return .NOENT;
        defer self.allocator.free(path);

        // Check preopen permissions
        var allowed = false;
        for (self.context.preopens.items) |preopen| {
            if (preopen.fd == dirfd and std.mem.startsWith(u8, path, preopen.path)) {
                allowed = true;
                break;
            }
        }
        if (!allowed) return .PERM;

        // Determine open mode
        const read = (fs_rights_base & 0x02) != 0; // fd_read
        const write = (fs_rights_base & 0x40) != 0; // fd_write
        const create = (oflags & 0x01) != 0; // O_CREAT
        const truncate = (oflags & 0x04) != 0; // O_TRUNC

        const flags = std.fs.File.OpenFlags{
            .mode = if (read and write) .read_write else if (write) .write_only else .read_only,
        };

        const file = if (create)
            std.fs.cwd().createFile(path, flags) catch return .IO
        else if (truncate)
            std.fs.cwd().createFile(path, flags) catch return .IO
        else
            std.fs.cwd().openFile(path, flags) catch return .NOENT;

        // Allocate new FD
        const new_fd = @as(Fd, @intCast(self.context.file_table.count() + 3));
        try self.context.file_table.put(new_fd, file);
        try self.memory.writeInt(u32, fd_ptr, new_fd);

        return .SUCCESS;
    }

    /// WASI: path_filestat_get
    pub fn pathFilestatGet(self: *WasiHost, fd: Fd, flags: u32, path_ptr: u32, path_len: u32, buf_ptr: u32) !Errno {
        _ = flags;
        _ = fd;

        const path_bytes = try self.memory.read(path_ptr, path_len);
        const stat = std.fs.cwd().statFile(path_bytes) catch return .NOENT;

        // Write filestat structure (64 bytes total)
        try self.memory.writeInt(u64, buf_ptr + 0, 0); // dev
        try self.memory.writeInt(u64, buf_ptr + 8, 0); // ino
        try self.memory.writeInt(u8, buf_ptr + 16, @intFromEnum(stat.kind)); // filetype
        try self.memory.writeInt(u64, buf_ptr + 24, 1); // nlink
        try self.memory.writeInt(u64, buf_ptr + 32, stat.size); // size
        try self.memory.writeInt(u64, buf_ptr + 40, @intCast(stat.atime)); // atim
        try self.memory.writeInt(u64, buf_ptr + 48, @intCast(stat.mtime)); // mtim
        try self.memory.writeInt(u64, buf_ptr + 56, @intCast(stat.ctime)); // ctim

        return .SUCCESS;
    }

    /// WASI: path_create_directory
    pub fn pathCreateDirectory(self: *WasiHost, fd: Fd, path_ptr: u32, path_len: u32) !Errno {
        _ = fd;

        const path_bytes = try self.memory.read(path_ptr, path_len);
        std.fs.cwd().makeDir(path_bytes) catch return .IO;

        return .SUCCESS;
    }

    /// WASI: path_remove_directory
    pub fn pathRemoveDirectory(self: *WasiHost, fd: Fd, path_ptr: u32, path_len: u32) !Errno {
        _ = fd;

        const path_bytes = try self.memory.read(path_ptr, path_len);
        std.fs.cwd().deleteDir(path_bytes) catch return .IO;

        return .SUCCESS;
    }

    /// WASI: path_unlink_file
    pub fn pathUnlinkFile(self: *WasiHost, fd: Fd, path_ptr: u32, path_len: u32) !Errno {
        _ = fd;

        const path_bytes = try self.memory.read(path_ptr, path_len);
        std.fs.cwd().deleteFile(path_bytes) catch return .IO;

        return .SUCCESS;
    }

    /// WASI: fd_prestat_get
    pub fn fdPrestatGet(self: *WasiHost, fd: Fd, buf_ptr: u32) !Errno {
        for (self.context.preopens.items) |preopen| {
            if (preopen.fd == fd) {
                try self.memory.writeInt(u8, buf_ptr, 0); // tag: preopentype::dir
                try self.memory.writeInt(u32, buf_ptr + 4, @intCast(preopen.path.len));
                return .SUCCESS;
            }
        }

        return .BADF;
    }

    /// WASI: fd_prestat_dir_name
    pub fn fdPrestatDirName(self: *WasiHost, fd: Fd, path_ptr: u32, path_len: u32) !Errno {
        for (self.context.preopens.items) |preopen| {
            if (preopen.fd == fd) {
                if (path_len < preopen.path.len) return .INVAL;
                try self.memory.write(path_ptr, preopen.path);
                return .SUCCESS;
            }
        }

        return .BADF;
    }

    /// WASI: clock_time_get
    pub fn clockTimeGet(self: *WasiHost, clock_id: u32, precision: u64, time_ptr: u32) !Errno {
        _ = precision;

        const timestamp = switch (clock_id) {
            0, 1 => std.time.nanoTimestamp(), // realtime, monotonic
            else => return .INVAL,
        };

        try self.memory.writeInt(u64, time_ptr, @intCast(timestamp));
        return .SUCCESS;
    }

    /// WASI: random_get
    pub fn randomGet(self: *WasiHost, buf_ptr: u32, buf_len: u32) !Errno {
        const buffer = try self.allocator.alloc(u8, buf_len);
        defer self.allocator.free(buffer);

        std.crypto.random.bytes(buffer);
        try self.memory.write(buf_ptr, buffer);

        return .SUCCESS;
    }

    /// WASI: poll_oneoff
    pub fn pollOneoff(self: *WasiHost, in_ptr: u32, out_ptr: u32, nsubscriptions: u32, nevents_ptr: u32) !Errno {
        _ = in_ptr;
        _ = out_ptr;
        _ = nsubscriptions;

        // Simplified: just return 0 events
        try self.memory.writeInt(u32, nevents_ptr, 0);
        return .SUCCESS;
    }

    /// WASI: fd_fdstat_get
    pub fn fdFdstatGet(self: *WasiHost, fd: Fd, buf_ptr: u32) !Errno {
        const filetype: u8 = if (fd < 3) 2 else 4; // character_device or regular_file
        const flags: u16 = 0;
        const rights_base: u64 = 0xFFFFFFFF; // all rights
        const rights_inheriting: u64 = 0xFFFFFFFF;

        try self.memory.writeInt(u8, buf_ptr, filetype);
        try self.memory.writeInt(u16, buf_ptr + 2, flags);
        try self.memory.writeInt(u64, buf_ptr + 8, rights_base);
        try self.memory.writeInt(u64, buf_ptr + 16, rights_inheriting);

        return .SUCCESS;
    }

    /// WASI: fd_filestat_get
    pub fn fdFilestatGet(self: *WasiHost, fd: Fd, buf_ptr: u32) !Errno {
        const file = self.context.file_table.get(fd) orelse {
            // For stdio, return dummy filestat
            if (fd < 3) {
                try self.memory.writeInt(u64, buf_ptr + 0, 0); // dev
                try self.memory.writeInt(u64, buf_ptr + 8, 0); // ino
                try self.memory.writeInt(u8, buf_ptr + 16, 2); // character_device
                try self.memory.writeInt(u64, buf_ptr + 24, 1); // nlink
                try self.memory.writeInt(u64, buf_ptr + 32, 0); // size
                try self.memory.writeInt(u64, buf_ptr + 40, 0); // atim
                try self.memory.writeInt(u64, buf_ptr + 48, 0); // mtim
                try self.memory.writeInt(u64, buf_ptr + 56, 0); // ctim
                return .SUCCESS;
            }
            return .BADF;
        };

        const stat = file.stat() catch return .IO;

        try self.memory.writeInt(u64, buf_ptr + 0, 0); // dev
        try self.memory.writeInt(u64, buf_ptr + 8, 0); // ino
        try self.memory.writeInt(u8, buf_ptr + 16, @intFromEnum(stat.kind)); // filetype
        try self.memory.writeInt(u64, buf_ptr + 24, 1); // nlink
        try self.memory.writeInt(u64, buf_ptr + 32, stat.size); // size
        try self.memory.writeInt(u64, buf_ptr + 40, @intCast(stat.atime)); // atim
        try self.memory.writeInt(u64, buf_ptr + 48, @intCast(stat.mtime)); // mtim
        try self.memory.writeInt(u64, buf_ptr + 56, @intCast(stat.ctime)); // ctim

        return .SUCCESS;
    }

    /// Register all WASI functions to a WASM instance
    pub fn registerAll(_: *WasiHost, instance: *engine.Instance) !void {
        // This would involve creating wrapper functions for each WASI call
        // Each wrapper needs to extract parameters from WASM values and call the corresponding function

        // Example wrapper for args_sizes_get
        const argsSizesGetWrapper = struct {
            fn call(params: []const engine.Value, allocator: std.mem.Allocator) ![]engine.Value {
                _ = allocator;
                _ = params;
                // Implementation would extract params and call self.argsSizesGet()
                return &[_]engine.Value{};
            }
        }.call;

        const empty_params = [_]engine.ValueType{};
        const errno_return = [_]engine.ValueType{.i32};

        try instance.registerHostFunction("wasi_snapshot_preview1.args_sizes_get", &empty_params, &errno_return, argsSizesGetWrapper);

        // Register remaining ~60 WASI functions following the same pattern
        // Full implementation would create wrappers for:
        // - args_get, environ_sizes_get, environ_get
        // - fd_read, fd_write, fd_close, fd_seek, fd_tell
        // - path_open, path_create_directory, path_remove_directory
        // - path_unlink_file, path_rename, path_link, path_symlink
        // - path_filestat_get, fd_filestat_get, fd_fdstat_get
        // - fd_prestat_get, fd_prestat_dir_name
        // - clock_time_get, clock_res_get
        // - random_get, poll_oneoff
        // - sock_recv, sock_send, sock_shutdown
        // - sched_yield, proc_exit, proc_raise
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
