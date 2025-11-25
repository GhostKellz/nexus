const std = @import("std");

/// Wrapper for ArrayList to provide a writer interface
const ArrayListWriter = struct {
    list: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    writer_obj: std.Io.Writer,
    buffer_storage: [0]u8 = .{},

    pub fn init(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) ArrayListWriter {
        return .{
            .list = list,
            .allocator = allocator,
            .writer_obj = .{
                .vtable = &vtable,
                .buffer = &.{},
            },
        };
    }

    pub fn writer(self: *ArrayListWriter) *std.Io.Writer {
        return &self.writer_obj;
    }

    const vtable = std.Io.Writer.VTable{
        .drain = drain,
    };

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *ArrayListWriter = @fieldParentPtr("writer_obj", w);
        var total: usize = 0;
        for (data) |slice| {
            self.list.appendSlice(self.allocator, slice) catch return error.WriteFailed;
            total += slice.len;
        }
        _ = splat;
        return total;
    }
};

/// HTTP client for making requests
pub const Client = struct {
    allocator: std.mem.Allocator,
    client: std.http.Client,

    pub fn init(allocator: std.mem.Allocator) !Client {
        const io_ptr = try allocator.create(std.Io.Threaded);
        errdefer allocator.destroy(io_ptr);
        io_ptr.* = std.Io.Threaded.init(allocator);

        return .{
            .allocator = allocator,
            .client = .{
                .allocator = allocator,
                .io = io_ptr.io(),
            },
        };
    }

    pub fn deinit(self: *Client) void {
        self.client.deinit();
    }

    /// Make a GET request and return the response body
    pub fn get(self: *Client, url: []const u8) ![]const u8 {
        var response_body: std.ArrayListUnmanaged(u8) = .{};
        errdefer response_body.deinit(self.allocator);

        var writer_inst = ArrayListWriter.init(&response_body, self.allocator);
        const writer = writer_inst.writer();

        const result = try self.client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .response_writer = writer,
        });

        _ = result; // Result contains status code if needed

        return try response_body.toOwnedSlice(self.allocator);
    }

    /// Make a POST request with a body and return the response
    pub fn post(self: *Client, url: []const u8, body: []const u8, content_type: []const u8) ![]const u8 {
        var response_body: std.ArrayListUnmanaged(u8) = .{};
        errdefer response_body.deinit(self.allocator);

        var writer_inst = ArrayListWriter.init(&response_body, self.allocator);
        const writer = writer_inst.writer();

        const headers = [_]std.http.Header{
            .{ .name = "content-type", .value = content_type },
        };

        const result = try self.client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = body,
            .extra_headers = &headers,
            .response_writer = writer,
        });

        _ = result; // Result contains status code if needed

        return try response_body.toOwnedSlice(self.allocator);
    }

    /// Make a generic HTTP request
    pub const RequestOptions = struct {
        method: std.http.Method = .GET,
        body: ?[]const u8 = null,
        headers: []const std.http.Header = &.{},
    };

    pub fn request(self: *Client, url: []const u8, options: RequestOptions) ![]const u8 {
        var response_body: std.ArrayListUnmanaged(u8) = .{};
        errdefer response_body.deinit(self.allocator);

        var writer_inst = ArrayListWriter.init(&response_body, self.allocator);
        const writer = writer_inst.writer();

        const result = try self.client.fetch(.{
            .location = .{ .url = url },
            .method = options.method,
            .payload = options.body,
            .extra_headers = options.headers,
            .response_writer = writer,
        });

        _ = result;

        return try response_body.toOwnedSlice(self.allocator);
    }
};

test "http client basic" {
    const allocator = std.testing.allocator;

    var client = try Client.init(allocator);
    defer client.deinit();

    // This test would require actual HTTP server
    // Skip for now
}
