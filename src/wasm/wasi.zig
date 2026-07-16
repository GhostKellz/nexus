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

/// WASI clock identifiers
pub const ClockId = enum(u32) {
    REALTIME = 0,
    MONOTONIC = 1,
    PROCESS_CPUTIME_ID = 2,
    THREAD_CPUTIME_ID = 3,
};

/// WASI event types for poll_oneoff
pub const EventType = enum(u8) {
    CLOCK = 0,
    FD_READ = 1,
    FD_WRITE = 2,
};

/// WASI subscription clock flags
pub const SUBSCRIPTION_CLOCK_ABSTIME: u16 = 0x0001;

/// WASI event for poll results
pub const Event = extern struct {
    userdata: u64,
    @"error": u16,
    event_type: EventType,
    _pad: u8 = 0,
    fd_readwrite: EventFdReadwrite,
};

/// WASI event fd readwrite data
pub const EventFdReadwrite = extern struct {
    nbytes: u64,
    flags: u16,
    _pad: [6]u8 = @splat(0),
};

/// WASI subscription for poll_oneoff
pub const Subscription = extern struct {
    userdata: u64,
    u: SubscriptionU,
};

/// WASI subscription union wrapper
pub const SubscriptionU = extern struct {
    tag: EventType,
    _pad: [7]u8 = @splat(0),
    u: SubscriptionUnion,
};

/// WASI subscription union
pub const SubscriptionUnion = extern union {
    clock: SubscriptionClock,
    fd_read: SubscriptionFdReadwrite,
    fd_write: SubscriptionFdReadwrite,
};

/// WASI clock subscription
pub const SubscriptionClock = extern struct {
    id: ClockId,
    timeout: u64,
    precision: u64,
    flags: u16,
    _pad: [6]u8 = @splat(0),
};

/// WASI fd read/write subscription
pub const SubscriptionFdReadwrite = extern struct {
    fd: i32,
    _pad: [4]u8 = @splat(0),
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

/// An open file descriptor together with its current logical offset. The Zig
/// 0.17 `Io.File` API is positional and stateless, so the WASI layer owns the
/// seek cursor instead of relying on a kernel-tracked file position.
const OpenFile = struct {
    file: std.Io.File,
    offset: u64 = 0,
    /// Rights granted to this descriptor at open time (a subset of the owning
    /// preopen's rights). Persisted so `fd_fdstat_get` reports the real
    /// capability set instead of claiming all rights, and so future operations
    /// can reject escalation.
    rights: Rights = .{},
};

/// Convert an `Io.Timestamp` (or an optional one, as `Stat.atime` is) to the
/// unsigned nanosecond count WASI's `filestat` expects. Missing or negative
/// timestamps clamp to 0.
fn timestampNanos(ts: anytype) u64 {
    const value = switch (@typeInfo(@TypeOf(ts))) {
        .optional => if (ts) |t| t.nanoseconds else return 0,
        else => ts.nanoseconds,
    };
    return @intCast(@max(value, 0));
}

/// WASI context
pub const WasiContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    preopens: std.ArrayList(Preopen),
    args: []const []const u8,
    env: std.StringHashMap([]const u8),
    stdin: std.Io.File,
    stdout: std.Io.File,
    stderr: std.Io.File,
    file_table: std.AutoHashMap(Fd, OpenFile),

    pub fn init(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !WasiContext {
        return WasiContext{
            .allocator = allocator,
            .io = io,
            .preopens = .empty,
            .args = args,
            .env = std.StringHashMap([]const u8).init(allocator),
            .stdin = std.Io.File.stdin(),
            .stdout = std.Io.File.stdout(),
            .stderr = std.Io.File.stderr(),
            .file_table = std.AutoHashMap(Fd, OpenFile).init(allocator),
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

        // Close all open file descriptors
        var file_it = self.file_table.valueIterator();
        while (file_it.next()) |entry| {
            entry.file.close(self.io);
        }
        self.file_table.deinit();
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

/// Maximum path components accepted while confining a WASI path. Real sandbox
/// trees are far shallower; a deeper path fails closed rather than doing
/// unbounded work for a hostile guest.
const max_wasi_path_components = 256;

const WasiPathError = error{ PathTraversal, PathTooLong };

/// Confine an untrusted guest `rel` path within the preopened directory
/// `base_dir`, writing the resolved absolute path to `out`. WASI paths are
/// interpreted relative to the preopen, so components are normalized lexically:
/// "." is dropped, ".." pops one component, and a ".." that would escape above
/// `base_dir` fails closed with `PathTraversal`. Leading slashes are treated as
/// separators (they cannot break out of the sandbox), and confinement is on a
/// component boundary — a prefix sibling like `/sandbox-evil` can never be
/// reached from base `/sandbox`. This replaces the old
/// `startsWith(resolved, preopen.path)` test, which accepted prefix siblings,
/// and the unchecked ops that touched the process CWD directly.
///
/// Purely lexical: symlink escapes are a separate concern handled at open time
/// (realpath) once the WASI file I/O is reworked onto directory handles.
fn confineWasiPath(base_dir: []const u8, rel: []const u8, out: []u8) WasiPathError![]const u8 {
    var comps: [max_wasi_path_components][]const u8 = undefined;
    var depth: usize = 0;
    var it = std.mem.tokenizeScalar(u8, rel, '/');
    while (it.next()) |c| {
        if (std.mem.eql(u8, c, ".")) continue;
        if (std.mem.eql(u8, c, "..")) {
            if (depth == 0) return error.PathTraversal;
            depth -= 1;
            continue;
        }
        if (depth >= max_wasi_path_components) return error.PathTooLong;
        comps[depth] = c;
        depth += 1;
    }

    if (base_dir.len > out.len) return error.PathTooLong;
    @memcpy(out[0..base_dir.len], base_dir);
    var len = base_dir.len;
    if (len > 0 and out[len - 1] == '/') len -= 1; // avoid a doubled separator
    for (comps[0..depth]) |c| {
        if (len + 1 + c.len > out.len) return error.PathTooLong;
        out[len] = '/';
        len += 1;
        @memcpy(out[len..][0..c.len], c);
        len += c.len;
    }
    return out[0..len];
}

/// WASI host functions
pub const WasiHost = struct {
    context: *WasiContext,
    memory: *engine.Memory,
    allocator: std.mem.Allocator,
    /// Exit code recorded by a guest `proc_exit`. The host reads this after the
    /// guest unwinds via `error.ProcExit` instead of the guest being able to
    /// terminate the whole runtime process.
    exit_code: ?u32 = null,

    pub fn init(allocator: std.mem.Allocator, context: *WasiContext, memory: *engine.Memory) WasiHost {
        return WasiHost{
            .context = context,
            .memory = memory,
            .allocator = allocator,
        };
    }

    /// Result of resolving an untrusted guest path against a preopen: either the
    /// confined absolute path (owned by the caller — free it) plus the rights the
    /// preopen delegated, or a WASI errno describing why the request was denied.
    const ResolvedPath = union(enum) {
        ok: struct { path: []u8, rights: Rights },
        deny: Errno,
    };

    /// Resolve the untrusted guest path in `[path_ptr, path_ptr+path_len)` against
    /// the preopen named by `dirfd`, confining it within that preopen's directory.
    /// This is the single choke point every filesystem path operation flows
    /// through, replacing the old per-op code that resolved against the process
    /// CWD and only did a `startsWith` prefix test (which accepted prefix
    /// siblings). Reading memory can fail (`OutOfBounds`); every other failure is
    /// surfaced as a `deny` errno so callers uniformly translate it to the guest.
    fn resolvePreopenPath(self: *WasiHost, dirfd: Fd, path_ptr: u32, path_len: u32) !ResolvedPath {
        const rel = try self.memory.read(path_ptr, path_len);
        // An embedded NUL means the guest is trying to smuggle a shorter path
        // past a length-based check on the host side; reject it outright.
        if (std.mem.indexOfScalar(u8, rel, 0) != null) return .{ .deny = .INVAL };

        const preopen = for (self.context.preopens.items) |p| {
            if (p.fd == dirfd) break p;
        } else return .{ .deny = .BADF };

        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const confined = confineWasiPath(preopen.path, rel, &buf) catch return .{ .deny = .PERM };

        const owned = try self.allocator.dupe(u8, confined);
        return .{ .ok = .{ .path = owned, .rights = preopen.rights } };
    }

    /// Allocate the lowest free descriptor at or above 3, skipping any number
    /// already claimed by a preopen or an open file. The old scheme
    /// (`file_table.count() + 3`) aliased the first opened file onto preopen
    /// fd 3 and reused numbers after a close, letting a guest confuse one
    /// capability for another.
    fn allocFd(self: *WasiHost) Fd {
        var candidate: Fd = 3;
        outer: while (true) : (candidate += 1) {
            if (self.context.file_table.contains(candidate)) continue;
            for (self.context.preopens.items) |p| {
                if (p.fd == candidate) continue :outer;
            }
            return candidate;
        }
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
            file.writeStreamingAll(self.context.io, data) catch return .IO;
            total_written += @intCast(data.len);
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

            const read_count = file.readStreaming(self.context.io, &.{buffer}) catch return .IO;
            try self.memory.write(buf_ptr, buffer[0..read_count]);

            total_read += @intCast(read_count);
            if (read_count < buf_len) break; // EOF or short read
        }

        try self.memory.writeInt(u32, nread_ptr, total_read);
        return .SUCCESS;
    }

    /// WASI: proc_exit
    ///
    /// A sandboxed guest must not be able to terminate the host runtime. The
    /// previous implementation called `std.process.exit`, which killed the whole
    /// process (and every other in-flight instance) on a single guest's request.
    /// Instead, record the requested code and unwind the guest via
    /// `error.ProcExit`; the embedder reads `exit_code` to learn the guest's
    /// status without a process-global side effect.
    pub fn procExit(self: *WasiHost, exit_code: u32) !Errno {
        self.exit_code = exit_code;
        return error.ProcExit;
    }

    /// WASI: fd_close
    pub fn fdClose(self: *WasiHost, fd: Fd) !Errno {
        if (fd < 3) return .BADF; // Don't close stdio

        if (self.context.file_table.get(fd)) |entry| {
            entry.file.close(self.context.io);
            _ = self.context.file_table.remove(fd);
            return .SUCCESS;
        }

        return .BADF;
    }

    /// WASI: fd_seek
    pub fn fdSeek(self: *WasiHost, fd: Fd, offset: i64, whence: u8, newoffset_ptr: u32) !Errno {
        const entry = self.context.file_table.getPtr(fd) orelse return .BADF;

        // `Io.File` is positional and stateless, so the cursor lives in
        // `OpenFile.offset`. Resolve WASI whence to an absolute offset.
        // whence: 0 = SET (start), 1 = CUR (current), 2 = END (end)
        const new_offset: u64 = switch (whence) {
            0 => blk: {
                // SET: seek from beginning
                if (offset < 0) return .INVAL;
                break :blk @intCast(offset);
            },
            1 => blk: {
                // CUR: seek from current position
                const target = @as(i64, @intCast(entry.offset)) + offset;
                if (target < 0) return .INVAL;
                break :blk @intCast(target);
            },
            2 => blk: {
                // END: seek from end
                const stat = entry.file.stat(self.context.io) catch return .IO;
                const target = @as(i64, @intCast(stat.size)) + offset;
                if (target < 0) return .INVAL;
                break :blk @intCast(target);
            },
            else => return .INVAL,
        };

        entry.offset = new_offset;
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

        const resolved = switch (try self.resolvePreopenPath(dirfd, path_ptr, path_len)) {
            .deny => |errno| return errno,
            .ok => |ok| ok,
        };
        const path = resolved.path;
        defer self.allocator.free(path);

        const granted: u64 = @bitCast(resolved.rights);

        // The directory handle must itself carry path_open, and the requested
        // base rights must be a subset of what the preopen delegated — a guest
        // cannot mint a capability the host never granted.
        if (!resolved.rights.path_open) return .PERM;
        if ((fs_rights_base & ~granted) != 0) return .PERM;

        const io = self.context.io;
        const cwd = std.Io.Dir.cwd();

        // Determine open mode from the (already validated) requested rights.
        const read = (fs_rights_base & 0x02) != 0; // fd_read
        const write = (fs_rights_base & 0x40) != 0; // fd_write
        const create = (oflags & 0x01) != 0; // O_CREAT
        const truncate = (oflags & 0x04) != 0; // O_TRUNC

        const file = if (create or truncate)
            cwd.createFile(io, path, .{
                .read = read,
                .truncate = truncate,
            }) catch return .IO
        else
            cwd.openFile(io, path, .{
                .mode = if (read and write) .read_write else if (write) .write_only else .read_only,
            }) catch return .NOENT;

        // Persist the intersection of requested and granted rights so the new
        // descriptor can never exceed what the guest asked for or the preopen
        // allowed, and so fd_fdstat_get reports its true capability set.
        const new_fd = self.allocFd();
        try self.context.file_table.put(new_fd, .{
            .file = file,
            .rights = @bitCast(fs_rights_base & granted),
        });
        try self.memory.writeInt(u32, fd_ptr, new_fd);

        return .SUCCESS;
    }

    /// WASI: path_filestat_get
    pub fn pathFilestatGet(self: *WasiHost, fd: Fd, flags: u32, path_ptr: u32, path_len: u32, buf_ptr: u32) !Errno {
        _ = flags;

        const resolved = switch (try self.resolvePreopenPath(fd, path_ptr, path_len)) {
            .deny => |errno| return errno,
            .ok => |ok| ok,
        };
        defer self.allocator.free(resolved.path);
        if (!resolved.rights.path_filestat_get) return .PERM;

        const stat = std.Io.Dir.cwd().statFile(self.context.io, resolved.path, .{}) catch return .NOENT;

        // Write filestat structure (64 bytes total)
        try self.memory.writeInt(u64, buf_ptr + 0, 0); // dev
        try self.memory.writeInt(u64, buf_ptr + 8, 0); // ino
        try self.memory.writeInt(u8, buf_ptr + 16, @intFromEnum(stat.kind)); // filetype
        try self.memory.writeInt(u64, buf_ptr + 24, 1); // nlink
        try self.memory.writeInt(u64, buf_ptr + 32, stat.size); // size
        try self.memory.writeInt(u64, buf_ptr + 40, timestampNanos(stat.atime)); // atim
        try self.memory.writeInt(u64, buf_ptr + 48, timestampNanos(stat.mtime)); // mtim
        try self.memory.writeInt(u64, buf_ptr + 56, timestampNanos(stat.ctime)); // ctim

        return .SUCCESS;
    }

    /// WASI: path_create_directory
    pub fn pathCreateDirectory(self: *WasiHost, fd: Fd, path_ptr: u32, path_len: u32) !Errno {
        const resolved = switch (try self.resolvePreopenPath(fd, path_ptr, path_len)) {
            .deny => |errno| return errno,
            .ok => |ok| ok,
        };
        defer self.allocator.free(resolved.path);
        if (!resolved.rights.path_create_directory) return .PERM;

        std.Io.Dir.cwd().createDir(self.context.io, resolved.path, .default_dir) catch return .IO;

        return .SUCCESS;
    }

    /// WASI: path_remove_directory
    pub fn pathRemoveDirectory(self: *WasiHost, fd: Fd, path_ptr: u32, path_len: u32) !Errno {
        const resolved = switch (try self.resolvePreopenPath(fd, path_ptr, path_len)) {
            .deny => |errno| return errno,
            .ok => |ok| ok,
        };
        defer self.allocator.free(resolved.path);
        if (!resolved.rights.path_remove_directory) return .PERM;

        std.Io.Dir.cwd().deleteDir(self.context.io, resolved.path) catch return .IO;

        return .SUCCESS;
    }

    /// WASI: path_unlink_file
    pub fn pathUnlinkFile(self: *WasiHost, fd: Fd, path_ptr: u32, path_len: u32) !Errno {
        const resolved = switch (try self.resolvePreopenPath(fd, path_ptr, path_len)) {
            .deny => |errno| return errno,
            .ok => |ok| ok,
        };
        defer self.allocator.free(resolved.path);
        if (!resolved.rights.path_unlink_file) return .PERM;

        std.Io.Dir.cwd().deleteFile(self.context.io, resolved.path) catch return .IO;

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
            0 => std.Io.Clock.real.now(self.context.io).nanoseconds, // realtime
            1 => std.Io.Clock.awake.now(self.context.io).nanoseconds, // monotonic
            else => return .INVAL,
        };

        try self.memory.writeInt(u64, time_ptr, @intCast(timestamp));
        return .SUCCESS;
    }

    /// WASI: random_get
    pub fn randomGet(self: *WasiHost, buf_ptr: u32, buf_len: u32) !Errno {
        const buffer = try self.allocator.alloc(u8, buf_len);
        defer self.allocator.free(buffer);

        self.context.io.random(buffer);
        try self.memory.write(buf_ptr, buffer);

        return .SUCCESS;
    }

    /// WASI: poll_oneoff - poll for events on subscriptions
    pub fn pollOneoff(self: *WasiHost, in_ptr: u32, out_ptr: u32, nsubscriptions: u32, nevents_ptr: u32) !Errno {
        if (nsubscriptions == 0) {
            try self.memory.writeInt(u32, nevents_ptr, 0);
            return .SUCCESS;
        }

        // Size of subscription struct (48 bytes: 8 userdata + 8 tag/padding + 32 union)
        const subscription_size: u32 = 48;
        const event_size: u32 = 32;

        var nevents: u32 = 0;
        var min_timeout_ns: ?u64 = null;
        var has_fd_subscriptions = false;

        // First pass: find minimum timeout and check for FD subscriptions
        for (0..nsubscriptions) |i| {
            const sub_offset = in_ptr + @as(u32, @intCast(i)) * subscription_size;

            // Read subscription tag (event type) at offset 8
            const tag_byte = try self.memory.readInt(u8, sub_offset + 8);
            const tag: EventType = @enumFromInt(tag_byte);

            switch (tag) {
                .CLOCK => {
                    // Clock subscription: read timeout
                    // Clock data starts at offset 16: id(4) + timeout(8) + precision(8) + flags(2)
                    const timeout = try self.memory.readInt(u64, sub_offset + 16 + 4);
                    const flags = try self.memory.readInt(u16, sub_offset + 16 + 4 + 8 + 8);

                    var effective_timeout = timeout;

                    // If ABSTIME flag is set, convert absolute time to relative
                    if ((flags & SUBSCRIPTION_CLOCK_ABSTIME) != 0) {
                        const now = @as(u64, @intCast(std.Io.Clock.real.now(self.context.io).nanoseconds));
                        if (timeout > now) {
                            effective_timeout = timeout - now;
                        } else {
                            effective_timeout = 0;
                        }
                    }

                    if (min_timeout_ns == null or effective_timeout < min_timeout_ns.?) {
                        min_timeout_ns = effective_timeout;
                    }
                },
                .FD_READ, .FD_WRITE => {
                    has_fd_subscriptions = true;
                },
            }
        }

        // If we have FD subscriptions, we need to poll them
        // For now, implement a simpler version that handles the common case:
        // - Clock subscriptions trigger immediately after timeout
        // - FD subscriptions for stdio are handled specially

        if (has_fd_subscriptions) {
            // Build poll file descriptors
            var poll_fds: [64]std.posix.pollfd = undefined;
            var poll_count: usize = 0;
            var fd_to_sub: [64]u32 = undefined;

            for (0..nsubscriptions) |i| {
                const sub_offset = in_ptr + @as(u32, @intCast(i)) * subscription_size;
                const tag_byte = try self.memory.readInt(u8, sub_offset + 8);
                const tag: EventType = @enumFromInt(tag_byte);

                if (tag == .FD_READ or tag == .FD_WRITE) {
                    // FD is at offset 16 in the union
                    const wasi_fd = try self.memory.readInt(i32, sub_offset + 16);

                    // Map WASI fd to host fd
                    const host_fd: std.posix.fd_t = switch (wasi_fd) {
                        0 => std.Io.File.stdin().handle,
                        1 => std.Io.File.stdout().handle,
                        2 => std.Io.File.stderr().handle,
                        else => blk: {
                            if (self.context.file_table.get(@intCast(wasi_fd))) |entry| {
                                break :blk entry.file.handle;
                            }
                            continue; // Skip invalid FDs
                        },
                    };

                    if (poll_count < poll_fds.len) {
                        poll_fds[poll_count] = .{
                            .fd = host_fd,
                            .events = if (tag == .FD_READ) std.posix.POLL.IN else std.posix.POLL.OUT,
                            .revents = 0,
                        };
                        fd_to_sub[poll_count] = @intCast(i);
                        poll_count += 1;
                    }
                }
            }

            // Calculate poll timeout in milliseconds
            const timeout_ms: i32 = if (min_timeout_ns) |ns|
                @intCast(@min(ns / 1_000_000, std.math.maxInt(i32)))
            else
                -1; // Infinite timeout

            // Perform the poll
            if (poll_count > 0) {
                const poll_result = try std.posix.poll(poll_fds[0..poll_count], timeout_ms);

                // Process poll results
                for (0..poll_count) |pi| {
                    const revents = poll_fds[pi].revents;
                    if (revents != 0) {
                        const sub_idx = fd_to_sub[pi];
                        const sub_offset = in_ptr + sub_idx * subscription_size;
                        const userdata = try self.memory.readInt(u64, sub_offset);
                        const tag_byte = try self.memory.readInt(u8, sub_offset + 8);

                        // Write event
                        const event_offset = out_ptr + nevents * event_size;
                        try self.memory.writeInt(u64, event_offset, userdata);
                        try self.memory.writeInt(u16, event_offset + 8, 0); // error = SUCCESS
                        try self.memory.writeInt(u8, event_offset + 10, tag_byte); // type
                        try self.memory.writeInt(u8, event_offset + 11, 0); // padding

                        // fd_readwrite data
                        try self.memory.writeInt(u64, event_offset + 16, 0); // nbytes (unknown)
                        const hangup: u16 = if ((revents & std.posix.POLL.HUP) != 0) 1 else 0;
                        try self.memory.writeInt(u16, event_offset + 24, hangup);

                        nevents += 1;
                    }
                }

                // If poll returned due to timeout and we have clock subscriptions, fire them
                if (poll_result == 0 and min_timeout_ns != null) {
                    for (0..nsubscriptions) |i| {
                        const sub_offset = in_ptr + @as(u32, @intCast(i)) * subscription_size;
                        const tag_byte = try self.memory.readInt(u8, sub_offset + 8);

                        if (tag_byte == @intFromEnum(EventType.CLOCK)) {
                            const userdata = try self.memory.readInt(u64, sub_offset);

                            const event_offset = out_ptr + nevents * event_size;
                            try self.memory.writeInt(u64, event_offset, userdata);
                            try self.memory.writeInt(u16, event_offset + 8, 0); // error
                            try self.memory.writeInt(u8, event_offset + 10, @intFromEnum(EventType.CLOCK));
                            try self.memory.writeInt(u8, event_offset + 11, 0);
                            // Zero out fd_readwrite for clock events
                            try self.memory.writeInt(u64, event_offset + 16, 0);
                            try self.memory.writeInt(u16, event_offset + 24, 0);

                            nevents += 1;
                            break; // Only fire one clock event
                        }
                    }
                }
            }
        } else if (min_timeout_ns) |timeout_ns| {
            // Only clock subscriptions - wait via the pinned std.Io provider and
            // fire them. Using the runtime's io (not legacy std.time.sleep) keeps
            // the wait on the same scheduler the rest of the runtime cooperates
            // with, so a clock-only poll_oneoff yields instead of parking the OS
            // thread out from under the event loop.
            if (timeout_ns > 0) {
                const timeout = std.Io.Timeout{ .duration = .{
                    .raw = std.Io.Duration.fromNanoseconds(@intCast(timeout_ns)),
                    .clock = .awake,
                } };
                timeout.sleep(self.context.io) catch {};
            }

            // Fire all clock events
            for (0..nsubscriptions) |i| {
                const sub_offset = in_ptr + @as(u32, @intCast(i)) * subscription_size;
                const tag_byte = try self.memory.readInt(u8, sub_offset + 8);

                if (tag_byte == @intFromEnum(EventType.CLOCK)) {
                    const userdata = try self.memory.readInt(u64, sub_offset);

                    const event_offset = out_ptr + nevents * event_size;
                    try self.memory.writeInt(u64, event_offset, userdata);
                    try self.memory.writeInt(u16, event_offset + 8, 0); // error = SUCCESS
                    try self.memory.writeInt(u8, event_offset + 10, @intFromEnum(EventType.CLOCK));
                    try self.memory.writeInt(u8, event_offset + 11, 0); // padding
                    try self.memory.writeInt(u64, event_offset + 16, 0); // nbytes
                    try self.memory.writeInt(u16, event_offset + 24, 0); // flags

                    nevents += 1;
                }
            }
        }

        try self.memory.writeInt(u32, nevents_ptr, nevents);
        return .SUCCESS;
    }

    /// WASI: fd_fdstat_get
    pub fn fdFdstatGet(self: *WasiHost, fd: Fd, buf_ptr: u32) !Errno {
        // Report the descriptor's real capability set. Claiming all rights
        // (the old `0xFFFFFFFF`) told guests they could perform operations the
        // host would then reject — or, worse, masked a missing check.
        var filetype: u8 = 4; // regular_file
        var rights: Rights = .{};

        if (fd < 3) {
            filetype = 2; // character_device
            rights = switch (fd) {
                0 => .{ .fd_read = true },
                else => .{ .fd_write = true },
            };
        } else if (self.context.file_table.get(fd)) |entry| {
            rights = entry.rights;
        } else {
            // A preopened directory handle, if any matches.
            for (self.context.preopens.items) |preopen| {
                if (preopen.fd == fd) {
                    filetype = 3; // directory
                    rights = preopen.rights;
                    break;
                }
            } else return .BADF;
        }

        const flags: u16 = 0;
        const rights_bits: u64 = @bitCast(rights);

        try self.memory.writeInt(u8, buf_ptr, filetype);
        try self.memory.writeInt(u16, buf_ptr + 2, flags);
        try self.memory.writeInt(u64, buf_ptr + 8, rights_bits);
        try self.memory.writeInt(u64, buf_ptr + 16, rights_bits);

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

        const stat = file.file.stat(self.context.io) catch return .IO;

        try self.memory.writeInt(u64, buf_ptr + 0, 0); // dev
        try self.memory.writeInt(u64, buf_ptr + 8, 0); // ino
        try self.memory.writeInt(u8, buf_ptr + 16, @intFromEnum(stat.kind)); // filetype
        try self.memory.writeInt(u64, buf_ptr + 24, 1); // nlink
        try self.memory.writeInt(u64, buf_ptr + 32, stat.size); // size
        try self.memory.writeInt(u64, buf_ptr + 40, timestampNanos(stat.atime)); // atim
        try self.memory.writeInt(u64, buf_ptr + 48, timestampNanos(stat.mtime)); // mtim
        try self.memory.writeInt(u64, buf_ptr + 56, timestampNanos(stat.ctime)); // ctim

        return .SUCCESS;
    }

    /// Register all WASI functions to a WASM instance.
    ///
    /// Fail closed: the individual WASI preview1 syscalls above are fully
    /// implemented, but wiring them onto a guest instance needs a wrapper per
    /// function that marshals guest values in/out — and that marshalling only
    /// works once the interpreter can actually invoke host functions from guest
    /// code (call/call_indirect are themselves unsupported, see interpreter.zig).
    /// The previous version registered a single no-op wrapper for
    /// `args_sizes_get` that ignored its params and returned an empty result,
    /// so a guest calling it would silently observe "0 args" — a false success.
    /// Rather than register fake wrappers, refuse until the calling machinery
    /// exists, so a caller cannot mistake a stubbed import table for a working
    /// WASI environment.
    pub fn registerAll(_: *WasiHost, _: *engine.Instance) !void {
        return error.WasiRegistrationUnsupported;
    }
};

test "wasi context" {
    const allocator = std.testing.allocator;

    const io = std.Io.Threaded.global_single_threaded.io();
    const args = [_][]const u8{ "prog", "arg1", "arg2" };
    var context = try WasiContext.init(allocator, io, &args);
    defer context.deinit();

    try context.setEnv("PATH", "/usr/bin");
    try std.testing.expectEqualStrings("/usr/bin", context.env.get("PATH").?);

    const read_rights = Rights{
        .fd_read = true,
        .path_open = true,
        .fd_seek = true,
    };
    const fd = try context.addPreopen("/sandbox", read_rights);
    try std.testing.expectEqual(@as(Fd, 3), fd);
}

test "registerAll fails closed instead of wiring fake WASI imports" {
    const allocator = std.testing.allocator;

    const io = std.Io.Threaded.global_single_threaded.io();
    const args = [_][]const u8{"prog"};
    var context = try WasiContext.init(allocator, io, &args);
    defer context.deinit();

    var memory = try engine.Memory.init(allocator, 1, 1);
    defer memory.deinit();

    var host = WasiHost.init(allocator, &context, &memory);

    var instance = engine.Instance.init(allocator);
    defer instance.deinit();

    // The import table must not be populated with no-op wrappers that report
    // false success; registration refuses until real call machinery exists.
    try std.testing.expectError(error.WasiRegistrationUnsupported, host.registerAll(&instance));
    try std.testing.expectEqual(@as(usize, 0), instance.functions.count());
}

test "proc_exit records the code and unwinds instead of killing the host" {
    const allocator = std.testing.allocator;

    const io = std.Io.Threaded.global_single_threaded.io();
    const args = [_][]const u8{"prog"};
    var context = try WasiContext.init(allocator, io, &args);
    defer context.deinit();

    var memory = try engine.Memory.init(allocator, 1, 1);
    defer memory.deinit();

    var host = WasiHost.init(allocator, &context, &memory);

    // Reaching this assertion at all proves proc_exit did not terminate the
    // test process; the exit code is surfaced to the embedder instead.
    try std.testing.expectError(error.ProcExit, host.procExit(42));
    try std.testing.expectEqual(@as(?u32, 42), host.exit_code);
}

test "confineWasiPath confines relative paths within the preopen" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("/sandbox/a/b", try confineWasiPath("/sandbox", "a/b", &buf));
    try std.testing.expectEqualStrings("/sandbox/a", try confineWasiPath("/sandbox", "a/./b/..", &buf));
    try std.testing.expectEqualStrings("/sandbox", try confineWasiPath("/sandbox", ".", &buf));
    try std.testing.expectEqualStrings("/sandbox/a", try confineWasiPath("/sandbox", "//a//", &buf));
    // Parent traversal that stays inside the tree is fine.
    try std.testing.expectEqualStrings("/sandbox/c", try confineWasiPath("/sandbox", "a/b/../../c", &buf));
    // A trailing slash on the base must not produce a doubled separator.
    try std.testing.expectEqualStrings("/sandbox/a", try confineWasiPath("/sandbox/", "a", &buf));
    // A leading slash in the guest path is just a separator, never an escape.
    try std.testing.expectEqualStrings("/sandbox/etc/passwd", try confineWasiPath("/sandbox", "/etc/passwd", &buf));
}

test "confineWasiPath rejects escapes and prefix siblings" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectError(error.PathTraversal, confineWasiPath("/sandbox", "..", &buf));
    try std.testing.expectError(error.PathTraversal, confineWasiPath("/sandbox", "a/../../etc/passwd", &buf));
    // The old startsWith test accepted this sibling because "/sandbox-evil"
    // has the "/sandbox" prefix; component confinement rejects it.
    try std.testing.expectError(error.PathTraversal, confineWasiPath("/sandbox", "../sandbox-evil/key", &buf));
}

test "resolvePreopenPath confines paths and fails closed on bad input" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const args = [_][]const u8{};
    var context = try WasiContext.init(allocator, io, &args);
    defer context.deinit();

    const dirfd = try context.addPreopen("/sandbox", .{ .path_open = true, .fd_read = true });

    var memory = try engine.Memory.init(allocator, 1, null);
    defer memory.deinit();

    var host = WasiHost.init(allocator, &context, &memory);

    // A legitimate relative path resolves under the preopen and carries its rights.
    const good = "a/b";
    try memory.write(0, good);
    switch (try host.resolvePreopenPath(dirfd, 0, good.len)) {
        .ok => |ok| {
            defer allocator.free(ok.path);
            try std.testing.expectEqualStrings("/sandbox/a/b", ok.path);
            try std.testing.expect(ok.rights.path_open);
        },
        .deny => return error.TestUnexpectedDeny,
    }

    // Unknown dirfd → BADF.
    switch (try host.resolvePreopenPath(99, 0, good.len)) {
        .ok => |ok| {
            allocator.free(ok.path);
            return error.TestExpectedDeny;
        },
        .deny => |e| try std.testing.expectEqual(Errno.BADF, e),
    }

    // Traversal above the preopen → PERM.
    const evil = "../../etc/passwd";
    try memory.write(0, evil);
    switch (try host.resolvePreopenPath(dirfd, 0, evil.len)) {
        .ok => |ok| {
            allocator.free(ok.path);
            return error.TestExpectedDeny;
        },
        .deny => |e| try std.testing.expectEqual(Errno.PERM, e),
    }

    // Embedded NUL → INVAL (guest trying to truncate a host-side check).
    const with_nul = "a\x00b";
    try memory.write(0, with_nul);
    switch (try host.resolvePreopenPath(dirfd, 0, with_nul.len)) {
        .ok => |ok| {
            allocator.free(ok.path);
            return error.TestExpectedDeny;
        },
        .deny => |e| try std.testing.expectEqual(Errno.INVAL, e),
    }
}

test "path_open denies rights escalation before touching the filesystem" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const args = [_][]const u8{};
    var context = try WasiContext.init(allocator, io, &args);
    defer context.deinit();

    // Preopen grants only path_open + fd_read, never fd_write.
    const dirfd = try context.addPreopen("/sandbox", .{ .path_open = true, .fd_read = true });

    var memory = try engine.Memory.init(allocator, 1, null);
    defer memory.deinit();

    var host = WasiHost.init(allocator, &context, &memory);

    const p = "file";
    try memory.write(64, p);

    // Requesting fd_write (0x40) — a right the preopen never delegated — is
    // denied with PERM, and because the check precedes any filesystem access
    // it holds even though /sandbox does not exist on the test host.
    const escalated = try host.pathOpen(dirfd, 0, 64, p.len, 0, 0x40, 0, 0, 0);
    try std.testing.expectEqual(Errno.PERM, escalated);
    try std.testing.expectEqual(@as(u32, 0), host.context.file_table.count());
}

test "path_open requires the directory handle to carry path_open" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const args = [_][]const u8{};
    var context = try WasiContext.init(allocator, io, &args);
    defer context.deinit();

    // A preopen without path_open cannot be used to open anything.
    const dirfd = try context.addPreopen("/sandbox", .{ .fd_read = true });

    var memory = try engine.Memory.init(allocator, 1, null);
    defer memory.deinit();

    var host = WasiHost.init(allocator, &context, &memory);

    const p = "file";
    try memory.write(64, p);
    const denied = try host.pathOpen(dirfd, 0, 64, p.len, 0, 0x02, 0, 0, 0);
    try std.testing.expectEqual(Errno.PERM, denied);
}

test "fd_fdstat_get reports the descriptor's real rights, not all rights" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const args = [_][]const u8{};
    var context = try WasiContext.init(allocator, io, &args);
    defer context.deinit();

    const rights = Rights{ .path_open = true, .fd_read = true, .path_filestat_get = true };
    const dirfd = try context.addPreopen("/sandbox", rights);

    var memory = try engine.Memory.init(allocator, 1, null);
    defer memory.deinit();

    var host = WasiHost.init(allocator, &context, &memory);

    try std.testing.expectEqual(Errno.SUCCESS, try host.fdFdstatGet(dirfd, 0));
    const reported = try memory.readInt(u64, 8);
    const expected: u64 = @bitCast(rights);
    try std.testing.expectEqual(expected, reported);
    // The old implementation reported 0xFFFFFFFF (every right) for every fd.
    try std.testing.expect(reported != 0xFFFFFFFF);
    // filetype directory (3) for a preopen handle.
    try std.testing.expectEqual(@as(u8, 3), try memory.readInt(u8, 0));
}

test "Rights bitcast matches the WASI ABI bit layout" {
    // The path_open mode detection in pathOpen masks fs_rights_base with these
    // literals, so the packed-struct layout must line up with the ABI.
    try std.testing.expectEqual(@as(u64, 0x02), @as(u64, @bitCast(Rights{ .fd_read = true })));
    try std.testing.expectEqual(@as(u64, 0x40), @as(u64, @bitCast(Rights{ .fd_write = true })));
    try std.testing.expectEqual(@as(u64, 0x2000), @as(u64, @bitCast(Rights{ .path_open = true })));
}

test "args_sizes_get and args_get serialize argv into guest memory" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const args = [_][]const u8{ "prog", "arg1", "ab" };
    var context = try WasiContext.init(allocator, io, &args);
    defer context.deinit();

    var memory = try engine.Memory.init(allocator, 1, null);
    defer memory.deinit();

    var host = WasiHost.init(allocator, &context, &memory);

    // args_sizes_get reports the count and the total NUL-terminated byte length.
    try std.testing.expectEqual(Errno.SUCCESS, try host.argsSizesGet(0, 4));
    try std.testing.expectEqual(@as(u32, 3), try memory.readInt(u32, 0));
    // ("prog\0"=5) + ("arg1\0"=5) + ("ab\0"=3) = 13
    try std.testing.expectEqual(@as(u32, 13), try memory.readInt(u32, 4));

    // args_get lays out the pointer vector, then the packed NUL-terminated
    // strings, with each pointer aimed at its string in the buffer.
    try std.testing.expectEqual(Errno.SUCCESS, try host.argsGet(16, 64));
    const p0 = try memory.readInt(u32, 16);
    const p1 = try memory.readInt(u32, 20);
    const p2 = try memory.readInt(u32, 24);
    try std.testing.expectEqual(@as(u32, 64), p0);
    try std.testing.expectEqual(@as(u32, 69), p1); // 64 + len("prog\0")
    try std.testing.expectEqual(@as(u32, 74), p2); // 69 + len("arg1\0")
    try std.testing.expectEqualStrings("prog", try memory.read(p0, 4));
    try std.testing.expectEqual(@as(u8, 0), try memory.readInt(u8, p0 + 4));
    try std.testing.expectEqualStrings("arg1", try memory.read(p1, 4));
    try std.testing.expectEqual(@as(u8, 0), try memory.readInt(u8, p1 + 4));
    try std.testing.expectEqualStrings("ab", try memory.read(p2, 2));
    try std.testing.expectEqual(@as(u8, 0), try memory.readInt(u8, p2 + 2));
}

test "environ_sizes_get reports the entry count and packed byte length" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const args = [_][]const u8{};
    var context = try WasiContext.init(allocator, io, &args);
    defer context.deinit();

    try context.setEnv("KEY", "VALUE");
    try context.setEnv("A", "B");

    var memory = try engine.Memory.init(allocator, 1, null);
    defer memory.deinit();

    var host = WasiHost.init(allocator, &context, &memory);

    try std.testing.expectEqual(Errno.SUCCESS, try host.environSizesGet(0, 4));
    try std.testing.expectEqual(@as(u32, 2), try memory.readInt(u32, 0));
    // "KEY=VALUE\0" (10) + "A=B\0" (4) = 14. The reported size is a sum, so it
    // is independent of hash-map iteration order.
    try std.testing.expectEqual(@as(u32, 14), try memory.readInt(u32, 4));
}

test "allocFd never aliases a live descriptor and reuses only freed numbers" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const args = [_][]const u8{};
    var context = try WasiContext.init(allocator, io, &args);
    defer context.deinit();

    // Two preopens occupy fds 3 and 4.
    try std.testing.expectEqual(@as(Fd, 3), try context.addPreopen("/a", .{}));
    try std.testing.expectEqual(@as(Fd, 4), try context.addPreopen("/b", .{}));

    var memory = try engine.Memory.init(allocator, 1, null);
    defer memory.deinit();

    var host = WasiHost.init(allocator, &context, &memory);

    // The lowest free fd skips both preopens.
    try std.testing.expectEqual(@as(Fd, 5), host.allocFd());

    // Placeholder open files occupy 5, 6, 7 so the next allocation must move
    // past every live descriptor. allocFd only tests membership and never
    // dereferences the entry; stdin is an inert stand-in, removed before deinit
    // so it is never actually closed.
    const placeholder = OpenFile{ .file = std.Io.File.stdin() };
    try context.file_table.put(5, placeholder);
    try context.file_table.put(6, placeholder);
    try context.file_table.put(7, placeholder);
    try std.testing.expectEqual(@as(Fd, 8), host.allocFd());

    // Closing fd 6 frees that number. Reuse of a fully-closed descriptor is the
    // correct POSIX behavior — the invariant is "never aliases a LIVE fd", not
    // "monotonic, never-reuse" — so allocFd hands 6 back only once it is no
    // longer live.
    _ = context.file_table.remove(6);
    try std.testing.expectEqual(@as(Fd, 6), host.allocFd());

    // Drop the manual entries so the context deinit does not close the inert
    // stdin placeholder.
    _ = context.file_table.remove(5);
    _ = context.file_table.remove(7);
}
