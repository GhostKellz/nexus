const std = @import("std");
const builtin = @import("builtin");

/// Hot reload system for development
/// Watches files for changes and triggers recompilation

pub const Error = error{
    WatcherInitFailed,
    InvalidPath,
    CompilationFailed,
};

/// File watcher using platform-specific APIs
pub const FileWatcher = struct {
    watch_paths: std.ArrayList([]const u8),
    last_modified: std.StringHashMap(std.Io.Timestamp),
    poll_interval_ms: u64 = 1000,
    allocator: std.mem.Allocator,
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) FileWatcher {
        return FileWatcher{
            .watch_paths = .empty,
            .last_modified = std.StringHashMap(std.Io.Timestamp).init(allocator),
            .allocator = allocator,
            .io = io,
        };
    }

    pub fn deinit(self: *FileWatcher) void {
        for (self.watch_paths.items) |path| {
            self.allocator.free(path);
        }
        self.watch_paths.deinit(self.allocator);

        var it = self.last_modified.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.last_modified.deinit();
    }

    /// Add path to watch list
    pub fn addPath(self: *FileWatcher, path: []const u8) !void {
        const path_copy = try self.allocator.dupe(u8, path);
        try self.watch_paths.append(self.allocator, path_copy);

        // Record initial modification time
        const cwd = std.Io.Dir.cwd();
        const stat = try cwd.statFile(self.io, path, .{});
        const mtime = stat.mtime;
        try self.last_modified.put(path_copy, mtime);
    }

    /// Add directory recursively
    pub fn addDirectory(self: *FileWatcher, dir_path: []const u8, pattern: []const u8) !void {
        const cwd = std.Io.Dir.cwd();
        var dir = try cwd.openDir(self.io, dir_path, .{ .iterate = true });
        defer dir.close(self.io);

        var dir_reader_buf: [2048]u8 align(@alignOf(usize)) = undefined;
        var dir_reader = std.Io.Dir.Reader.init(dir, &dir_reader_buf);
        while (try dir_reader.next(self.io)) |entry| {
            if (entry.kind == .file) {
                // Check if file matches pattern (e.g., "*.zig")
                if (matchesPattern(entry.name, pattern)) {
                    const full_path = try std.fs.path.join(self.allocator, &.{ dir_path, entry.name });
                    defer self.allocator.free(full_path);

                    try self.addPath(full_path);
                }
            } else if (entry.kind == .directory) {
                // Recursively add subdirectories
                const subdir_path = try std.fs.path.join(self.allocator, &.{ dir_path, entry.name });
                defer self.allocator.free(subdir_path);

                try self.addDirectory(subdir_path, pattern);
            }
        }
    }

    /// Check for file changes
    pub fn checkChanges(self: *FileWatcher) ![]const []const u8 {
        var changed_files: std.ArrayList([]const u8) = .empty;
        errdefer changed_files.deinit(self.allocator);

        const cwd = std.Io.Dir.cwd();
        for (self.watch_paths.items) |path| {
            const stat = cwd.statFile(self.io, path, .{}) catch continue;
            const mtime = stat.mtime;

            if (self.last_modified.get(path)) |last_mtime| {
                // Compare timestamps: check if mtime is newer
                if (mtime.nanoseconds > last_mtime.nanoseconds) {
                    try changed_files.append(self.allocator, path);
                    try self.last_modified.put(path, mtime);
                }
            }
        }

        return changed_files.toOwnedSlice(self.allocator);
    }

    /// Run watch loop
    pub fn watch(self: *FileWatcher, callback: *const fn ([]const []const u8) void) !void {
        std.debug.print("🔍 Watching for file changes...\n", .{});

        while (true) {
            const changed = try self.checkChanges();
            defer self.allocator.free(changed);

            if (changed.len > 0) {
                std.debug.print("📝 Detected changes in {d} file(s)\n", .{changed.len});
                callback(changed);
            }

            const ns_total = self.poll_interval_ms * std.time.ns_per_ms;
            const seconds = ns_total / std.time.ns_per_s;
            const nanoseconds = ns_total % std.time.ns_per_s;
            std.posix.nanosleep(seconds, nanoseconds);
        }
    }
};

/// Simple pattern matching for filenames
fn matchesPattern(filename: []const u8, pattern: []const u8) bool {
    // Support for simple wildcard patterns like "*.zig"
    if (std.mem.startsWith(u8, pattern, "*")) {
        const extension = pattern[1..];
        return std.mem.endsWith(u8, filename, extension);
    }

    return std.mem.eql(u8, filename, pattern);
}

/// Hot reload manager
pub const HotReloadManager = struct {
    watcher: FileWatcher,
    build_command: []const u8,
    run_command: ?[]const u8,
    process: ?std.process.Child = null,
    allocator: std.mem.Allocator,
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, build_command: []const u8) !HotReloadManager {
        return HotReloadManager{
            .watcher = FileWatcher.init(allocator, io),
            .build_command = try allocator.dupe(u8, build_command),
            .run_command = null,
            .allocator = allocator,
            .io = io,
        };
    }

    pub fn deinit(self: *HotReloadManager) void {
        self.watcher.deinit();
        self.allocator.free(self.build_command);
        if (self.run_command) |cmd| {
            self.allocator.free(cmd);
        }

        if (self.process) |*proc| {
            proc.kill(self.io);
        }
    }

    /// Set command to run after successful build
    pub fn setRunCommand(self: *HotReloadManager, command: []const u8) !void {
        if (self.run_command) |old_cmd| {
            self.allocator.free(old_cmd);
        }
        self.run_command = try self.allocator.dupe(u8, command);
    }

    /// Rebuild project
    pub fn rebuild(self: *HotReloadManager) !void {
        std.debug.print("🔨 Building...\n", .{});

        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(self.allocator);

        // Split build command by spaces
        var it = std.mem.splitScalar(u8, self.build_command, ' ');
        while (it.next()) |arg| {
            try args.append(self.allocator, arg);
        }

        var child = try std.process.spawn(self.io, .{
            .argv = args.items,
            .stdout = .inherit,
            .stderr = .inherit,
        });

        const result = try child.wait(self.io);

        switch (result) {
            .exited => |code| {
                if (code == 0) {
                    std.debug.print("✅ Build successful\n", .{});
                    try self.restart();
                } else {
                    std.debug.print("❌ Build failed with code {d}\n", .{code});
                    return Error.CompilationFailed;
                }
            },
            else => {
                std.debug.print("❌ Build process terminated abnormally\n", .{});
                return Error.CompilationFailed;
            },
        }
    }

    /// Restart running process
    fn restart(self: *HotReloadManager) !void {
        // Kill existing process
        if (self.process) |*proc| {
            std.debug.print("🛑 Stopping previous instance...\n", .{});
            proc.kill(self.io);
            self.process = null;
        }

        // Start new process if run command is set
        if (self.run_command) |cmd| {
            std.debug.print("🚀 Starting: {s}\n", .{cmd});

            var args: std.ArrayList([]const u8) = .empty;
            defer args.deinit(self.allocator);

            var it = std.mem.splitScalar(u8, cmd, ' ');
            while (it.next()) |arg| {
                try args.append(self.allocator, arg);
            }

            const child = try std.process.spawn(self.io, .{
                .argv = args.items,
                .stdout = .inherit,
                .stderr = .inherit,
            });
            self.process = child;

            std.debug.print("✨ Server restarted\n", .{});
        }
    }

    /// Start watching and auto-rebuilding
    pub fn start(self: *HotReloadManager, watch_dirs: []const []const u8) !void {
        // Add watch directories
        for (watch_dirs) |dir| {
            try self.watcher.addDirectory(dir, "*.zig");
        }

        // Initial build
        try self.rebuild();

        // Watch loop - check for changes and rebuild
        std.debug.print("🔍 Watching for file changes...\n", .{});

        while (true) {
            const changed = try self.watcher.checkChanges();
            defer self.allocator.free(changed);

            if (changed.len > 0) {
                std.debug.print("📝 Detected changes in {d} file(s)\n", .{changed.len});
                for (changed) |file| {
                    std.debug.print("  • {s}\n", .{file});
                }

                // Rebuild on any change
                self.rebuild() catch |err| {
                    std.debug.print("Rebuild error: {}\n", .{err});
                };
            }

            const duration = std.Io.Duration.fromMilliseconds(@intCast(self.watcher.poll_interval_ms));
            const timeout = std.Io.Timeout{ .duration = .{ .raw = duration, .clock = .awake } };
            timeout.sleep(self.io) catch {};
        }
    }
};

test "hot reload file watcher" {
    const allocator = std.testing.allocator;

    var watcher = FileWatcher.init(allocator);
    defer watcher.deinit();

    // Test would add actual files in real scenario
    // For now, just test initialization
    try std.testing.expect(watcher.watch_paths.items.len == 0);
}

test "hot reload pattern matching" {
    try std.testing.expect(matchesPattern("file.zig", "*.zig"));
    try std.testing.expect(!matchesPattern("file.txt", "*.zig"));
    try std.testing.expect(matchesPattern("exact.txt", "exact.txt"));
}
