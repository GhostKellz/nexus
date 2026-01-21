const std = @import("std");
const Io = std.Io;
const Dir = std.Io.Dir;
const IoFile = std.Io.File;

pub const OpenFlags = struct {
    read: bool = true,
    write: bool = false,
    create: bool = false,
    truncate: bool = false,
    append: bool = false,
    exclusive: bool = false,

    pub fn toIoOpenFlags(self: OpenFlags) IoFile.OpenFlags {
        return IoFile.OpenFlags{
            .mode = if (self.read and self.write)
                .read_write
            else if (self.write)
                .write_only
            else
                .read_only,
        };
    }

    pub fn toIoCreateFlags(self: OpenFlags) IoFile.CreateFlags {
        return IoFile.CreateFlags{
            .read = self.read,
            .truncate = self.truncate,
            .exclusive = self.exclusive,
        };
    }
};

pub const File = struct {
    file: IoFile,
    path: []const u8,
    allocator: std.mem.Allocator,
    io: Io,
    read_buffer: []u8,
    write_buffer: []u8,

    const DEFAULT_BUFFER_SIZE = 8192;

    pub fn open(allocator: std.mem.Allocator, io: Io, path: []const u8, flags: OpenFlags) !File {
        const file = if (flags.create)
            try Dir.cwd().createFile(io, path, flags.toIoCreateFlags())
        else
            try Dir.cwd().openFile(io, path, flags.toIoOpenFlags());

        return File{
            .file = file,
            .path = try allocator.dupe(u8, path),
            .allocator = allocator,
            .io = io,
            .read_buffer = try allocator.alloc(u8, DEFAULT_BUFFER_SIZE),
            .write_buffer = try allocator.alloc(u8, DEFAULT_BUFFER_SIZE),
        };
    }

    pub fn close(self: *File) void {
        self.file.close(self.io);
        self.allocator.free(self.path);
        self.allocator.free(self.read_buffer);
        self.allocator.free(self.write_buffer);
    }

    pub fn read(self: *File, buffer: []u8) !usize {
        var reader = self.file.reader(self.io, self.read_buffer);
        return try reader.read(buffer);
    }

    pub fn readAll(self: *File) ![]u8 {
        const file_stat = try self.file.stat(self.io);
        const size = file_stat.size;

        const buffer = try self.allocator.alloc(u8, size);
        errdefer self.allocator.free(buffer);

        // Use positional read for entire file
        const bytes_read = try self.file.readPositionalAll(self.io, buffer, 0);

        if (bytes_read < size) {
            // Shrink allocation to actual size read
            const resized = try self.allocator.realloc(buffer, bytes_read);
            return resized;
        }
        return buffer;
    }

    pub fn write(self: *File, data: []const u8) !usize {
        var writer = self.file.writer(self.io, self.write_buffer);
        return try writer.write(data);
    }

    pub fn writeAll(self: *File, data: []const u8) !void {
        try self.file.writeStreamingAll(self.io, data);
    }

    pub fn stat(self: *File) !IoFile.Stat {
        return try self.file.stat(self.io);
    }

    pub fn sync(self: *File) !void {
        try self.file.sync(self.io);
    }
};

/// Read entire file contents
pub fn readFile(allocator: std.mem.Allocator, io: Io, path: []const u8) ![]u8 {
    var file = try File.open(allocator, io, path, .{ .read = true });
    defer file.close();
    return try file.readAll();
}

/// Write data to file
pub fn writeFile(allocator: std.mem.Allocator, io: Io, path: []const u8, data: []const u8) !void {
    var file = try File.open(allocator, io, path, .{
        .write = true,
        .create = true,
        .truncate = true,
    });
    defer file.close();
    try file.writeAll(data);
}

/// Append data to file
pub fn appendFile(allocator: std.mem.Allocator, io: Io, path: []const u8, data: []const u8) !void {
    // Open file without truncation
    var file = try File.open(allocator, io, path, .{
        .write = true,
        .create = true,
        .truncate = false, // Don't truncate - we want to append
    });
    defer file.close();

    // Get current file size and write at the end
    const file_stat = try file.file.stat(io);
    try file.file.writePositionalAll(io, data, file_stat.size);
}

/// Check if file exists
pub fn exists(io: Io, path: []const u8) bool {
    Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// Delete file
pub fn deleteFile(io: Io, path: []const u8) !void {
    try Dir.cwd().deleteFile(io, path);
}

/// Copy file
pub fn copyFile(allocator: std.mem.Allocator, io: Io, src: []const u8, dest: []const u8) !void {
    const data = try readFile(allocator, io, src);
    defer allocator.free(data);
    try writeFile(allocator, io, dest, data);
}

/// Move/rename file
pub fn moveFile(io: Io, src: []const u8, dest: []const u8) !void {
    try Dir.cwd().rename(io, src, dest);
}

/// Get file stats
pub fn stat(io: Io, path: []const u8) !IoFile.Stat {
    const file = try Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    return try file.stat(io);
}

test "file operations" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const test_file = "/tmp/nexus_test_file.txt";
    const test_data = "Hello, Nexus!";

    // Clean up any existing test file
    deleteFile(io, test_file) catch {};

    // Test write
    try writeFile(allocator, io, test_file, test_data);

    // Test read
    const content = try readFile(allocator, io, test_file);
    defer allocator.free(content);
    try std.testing.expectEqualStrings(test_data, content);

    // Test exists
    try std.testing.expect(exists(io, test_file));

    // Test append
    try appendFile(allocator, io, test_file, " More data!");
    const appended = try readFile(allocator, io, test_file);
    defer allocator.free(appended);
    try std.testing.expectEqualStrings("Hello, Nexus! More data!", appended);

    // Clean up
    try deleteFile(io, test_file);
    try std.testing.expect(!exists(io, test_file));
}
