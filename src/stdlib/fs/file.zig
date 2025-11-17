const std = @import("std");

pub const OpenFlags = struct {
    read: bool = true,
    write: bool = false,
    create: bool = false,
    truncate: bool = false,
    append: bool = false,
    exclusive: bool = false,

    pub fn toStdFlags(self: OpenFlags) std.fs.File.OpenFlags {
        return std.fs.File.OpenFlags{
            .mode = if (self.read and self.write)
                .read_write
            else if (self.write)
                .write_only
            else
                .read_only,
        };
    }

    pub fn toStdCreateFlags(self: OpenFlags) std.fs.File.CreateFlags {
        return std.fs.File.CreateFlags{
            .read = self.read,
            .truncate = self.truncate,
            .exclusive = self.exclusive,
        };
    }
};

pub const File = struct {
    file: std.fs.File,
    path: []const u8,
    allocator: std.mem.Allocator,

    pub fn open(allocator: std.mem.Allocator, path: []const u8, flags: OpenFlags) !File {
        const file = if (flags.create)
            try std.fs.cwd().createFile(path, flags.toStdCreateFlags())
        else
            try std.fs.cwd().openFile(path, flags.toStdFlags());

        return File{
            .file = file,
            .path = try allocator.dupe(u8, path),
            .allocator = allocator,
        };
    }

    pub fn close(self: *File) void {
        self.file.close();
        self.allocator.free(self.path);
    }

    pub fn read(self: *File, buffer: []u8) !usize {
        return try self.file.read(buffer);
    }

    pub fn readAll(self: *File) ![]u8 {
        const file_stat = try self.file.stat();
        const size = file_stat.size;

        const buffer = try self.allocator.alloc(u8, size);
        errdefer self.allocator.free(buffer);

        const bytes_read = try self.file.readAll(buffer);
        return buffer[0..bytes_read];
    }

    pub fn write(self: *File, data: []const u8) !usize {
        return try self.file.write(data);
    }

    pub fn writeAll(self: *File, data: []const u8) !void {
        try self.file.writeAll(data);
    }

    pub fn seek(self: *File, offset: i64, _: std.fs.File.SeekableStream.SeekFrom) !u64 {
        return try self.file.seekableStream().seekTo(@intCast(offset));
    }

    pub fn stat(self: *File) !std.fs.File.Stat {
        return try self.file.stat();
    }

    pub fn sync(self: *File) !void {
        try self.file.sync();
    }
};

/// Read entire file contents
pub fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try File.open(allocator, path, .{ .read = true });
    defer file.close();
    return try file.readAll();
}

/// Write data to file
pub fn writeFile(allocator: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    var file = try File.open(allocator, path, .{
        .write = true,
        .create = true,
        .truncate = true,
    });
    defer file.close();
    try file.writeAll(data);
}

/// Append data to file
pub fn appendFile(allocator: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    var file = try File.open(allocator, path, .{
        .write = true,
        .create = true,
        .append = true,
    });
    defer file.close();
    try file.writeAll(data);
}

/// Check if file exists
pub fn exists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

/// Delete file
pub fn deleteFile(path: []const u8) !void {
    try std.fs.cwd().deleteFile(path);
}

/// Copy file
pub fn copyFile(allocator: std.mem.Allocator, src: []const u8, dest: []const u8) !void {
    const data = try readFile(allocator, src);
    defer allocator.free(data);
    try writeFile(allocator, dest, data);
}

/// Move/rename file
pub fn moveFile(src: []const u8, dest: []const u8) !void {
    try std.fs.cwd().rename(src, dest);
}

/// Get file stats
pub fn stat(path: []const u8) !std.fs.File.Stat {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return try file.stat();
}

test "file operations" {
    const allocator = std.testing.allocator;
    const test_file = "/tmp/nexus_test_file.txt";
    const test_data = "Hello, Nexus!";

    // Clean up any existing test file
    deleteFile(test_file) catch {};

    // Test write
    try writeFile(allocator, test_file, test_data);

    // Test read
    const content = try readFile(allocator, test_file);
    defer allocator.free(content);
    try std.testing.expectEqualStrings(test_data, content);

    // Test exists
    try std.testing.expect(exists(test_file));

    // Test append
    try appendFile(allocator, test_file, " More data!");
    const appended = try readFile(allocator, test_file);
    defer allocator.free(appended);
    try std.testing.expectEqualStrings("Hello, Nexus! More data!", appended);

    // Clean up
    try deleteFile(test_file);
    try std.testing.expect(!exists(test_file));
}
