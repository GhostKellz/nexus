const std = @import("std");
const huffman = @import("huffman.zig");

/// HPACK - Header Compression for HTTP/2
/// RFC 7541 - HPACK: Header Compression for HTTP/2

pub const Error = error{
    InvalidIndex,
    IntegerOverflow,
    StringTooLong,
    TableSizeMismatch,
};

/// Static table entries (RFC 7541 Appendix A)
pub const StaticEntry = struct {
    name: []const u8,
    value: []const u8,
};

pub const STATIC_TABLE = [_]StaticEntry{
    .{ .name = ":authority", .value = "" },
    .{ .name = ":method", .value = "GET" },
    .{ .name = ":method", .value = "POST" },
    .{ .name = ":path", .value = "/" },
    .{ .name = ":path", .value = "/index.html" },
    .{ .name = ":scheme", .value = "http" },
    .{ .name = ":scheme", .value = "https" },
    .{ .name = ":status", .value = "200" },
    .{ .name = ":status", .value = "204" },
    .{ .name = ":status", .value = "206" },
    .{ .name = ":status", .value = "304" },
    .{ .name = ":status", .value = "400" },
    .{ .name = ":status", .value = "404" },
    .{ .name = ":status", .value = "500" },
    .{ .name = "accept-charset", .value = "" },
    .{ .name = "accept-encoding", .value = "gzip, deflate" },
    .{ .name = "accept-language", .value = "" },
    .{ .name = "accept-ranges", .value = "" },
    .{ .name = "accept", .value = "" },
    .{ .name = "access-control-allow-origin", .value = "" },
    .{ .name = "age", .value = "" },
    .{ .name = "allow", .value = "" },
    .{ .name = "authorization", .value = "" },
    .{ .name = "cache-control", .value = "" },
    .{ .name = "content-disposition", .value = "" },
    .{ .name = "content-encoding", .value = "" },
    .{ .name = "content-language", .value = "" },
    .{ .name = "content-length", .value = "" },
    .{ .name = "content-location", .value = "" },
    .{ .name = "content-range", .value = "" },
    .{ .name = "content-type", .value = "" },
    .{ .name = "cookie", .value = "" },
    .{ .name = "date", .value = "" },
    .{ .name = "etag", .value = "" },
    .{ .name = "expect", .value = "" },
    .{ .name = "expires", .value = "" },
    .{ .name = "from", .value = "" },
    .{ .name = "host", .value = "" },
    .{ .name = "if-match", .value = "" },
    .{ .name = "if-modified-since", .value = "" },
    .{ .name = "if-none-match", .value = "" },
    .{ .name = "if-range", .value = "" },
    .{ .name = "if-unmodified-since", .value = "" },
    .{ .name = "last-modified", .value = "" },
    .{ .name = "link", .value = "" },
    .{ .name = "location", .value = "" },
    .{ .name = "max-forwards", .value = "" },
    .{ .name = "proxy-authenticate", .value = "" },
    .{ .name = "proxy-authorization", .value = "" },
    .{ .name = "range", .value = "" },
    .{ .name = "referer", .value = "" },
    .{ .name = "refresh", .value = "" },
    .{ .name = "retry-after", .value = "" },
    .{ .name = "server", .value = "" },
    .{ .name = "set-cookie", .value = "" },
    .{ .name = "strict-transport-security", .value = "" },
    .{ .name = "transfer-encoding", .value = "" },
    .{ .name = "user-agent", .value = "" },
    .{ .name = "vary", .value = "" },
    .{ .name = "via", .value = "" },
    .{ .name = "www-authenticate", .value = "" },
};

/// Dynamic table entry
pub const DynamicEntry = struct {
    name: []const u8,
    value: []const u8,
    size: usize,

    pub fn calculateSize(name: []const u8, value: []const u8) usize {
        return 32 + name.len + value.len; // RFC 7541 section 4.1
    }
};

/// HPACK dynamic table
pub const DynamicTable = struct {
    entries: std.ArrayList(DynamicEntry),
    size: usize = 0,
    max_size: usize = 4096, // Default from RFC 7541
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) DynamicTable {
        return DynamicTable{
            .entries = std.ArrayList(DynamicEntry).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DynamicTable) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.name);
            self.allocator.free(entry.value);
        }
        self.entries.deinit();
    }

    pub fn setMaxSize(self: *DynamicTable, max_size: usize) !void {
        self.max_size = max_size;
        try self.evict();
    }

    pub fn add(self: *DynamicTable, name: []const u8, value: []const u8) !void {
        const entry_size = DynamicEntry.calculateSize(name, value);

        // Evict entries if needed
        while (self.size + entry_size > self.max_size and self.entries.items.len > 0) {
            try self.evictOldest();
        }

        // If entry is larger than max size, don't add it
        if (entry_size > self.max_size) return;

        const entry = DynamicEntry{
            .name = try self.allocator.dupe(u8, name),
            .value = try self.allocator.dupe(u8, value),
            .size = entry_size,
        };

        // Add to front (most recent)
        try self.entries.insert(0, entry);
        self.size += entry_size;
    }

    pub fn get(self: *DynamicTable, index: usize) ?DynamicEntry {
        if (index >= self.entries.items.len) return null;
        return self.entries.items[index];
    }

    fn evictOldest(self: *DynamicTable) !void {
        if (self.entries.items.len == 0) return;

        const entry = self.entries.pop();
        self.size -= entry.size;
        self.allocator.free(entry.name);
        self.allocator.free(entry.value);
    }

    fn evict(self: *DynamicTable) !void {
        while (self.size > self.max_size and self.entries.items.len > 0) {
            try self.evictOldest();
        }
    }
};

/// HPACK encoder/decoder context
pub const Context = struct {
    dynamic_table: DynamicTable,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Context {
        return Context{
            .dynamic_table = DynamicTable.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Context) void {
        self.dynamic_table.deinit();
    }

    /// Get entry from table (static or dynamic)
    pub fn getEntry(self: *Context, index: usize) !struct { name: []const u8, value: []const u8 } {
        if (index == 0) return Error.InvalidIndex;

        // Static table: 1 to 61
        if (index <= STATIC_TABLE.len) {
            const entry = STATIC_TABLE[index - 1];
            return .{ .name = entry.name, .value = entry.value };
        }

        // Dynamic table
        const dynamic_index = index - STATIC_TABLE.len - 1;
        if (self.dynamic_table.get(dynamic_index)) |entry| {
            return .{ .name = entry.name, .value = entry.value };
        }

        return Error.InvalidIndex;
    }

    /// Find entry in tables (returns index, 0 if not found)
    pub fn findEntry(self: *Context, name: []const u8, value: []const u8) usize {
        // Search static table
        for (STATIC_TABLE, 1..) |entry, i| {
            if (std.mem.eql(u8, entry.name, name) and std.mem.eql(u8, entry.value, value)) {
                return i;
            }
        }

        // Search dynamic table
        for (self.dynamic_table.entries.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.name, name) and std.mem.eql(u8, entry.value, value)) {
                return STATIC_TABLE.len + 1 + i;
            }
        }

        return 0;
    }

    /// Find name in tables (returns index, 0 if not found)
    pub fn findName(self: *Context, name: []const u8) usize {
        // Search static table
        for (STATIC_TABLE, 1..) |entry, i| {
            if (std.mem.eql(u8, entry.name, name)) {
                return i;
            }
        }

        // Search dynamic table
        for (self.dynamic_table.entries.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.name, name)) {
                return STATIC_TABLE.len + 1 + i;
            }
        }

        return 0;
    }
};

/// Encode integer using HPACK integer representation (RFC 7541 section 5.1)
pub fn encodeInteger(buffer: []u8, value: usize, prefix_bits: u3) !usize {
    const max_prefix = (@as(usize, 1) << prefix_bits) - 1;
    var offset: usize = 0;

    if (value < max_prefix) {
        buffer[offset] = @intCast(value);
        return 1;
    }

    buffer[offset] = @intCast(max_prefix);
    offset += 1;

    var remaining = value - max_prefix;
    while (remaining >= 128) {
        if (offset >= buffer.len) return Error.IntegerOverflow;
        buffer[offset] = @intCast((remaining % 128) + 128);
        offset += 1;
        remaining /= 128;
    }

    if (offset >= buffer.len) return Error.IntegerOverflow;
    buffer[offset] = @intCast(remaining);
    offset += 1;

    return offset;
}

/// Decode integer from HPACK representation
pub fn decodeInteger(data: []const u8, prefix_bits: u3, offset: *usize) !usize {
    if (offset.* >= data.len) return Error.IntegerOverflow;

    const max_prefix = (@as(usize, 1) << prefix_bits) - 1;
    const mask = @as(u8, @intCast(max_prefix));

    var value = @as(usize, data[offset.*] & mask);
    offset.* += 1;

    if (value < max_prefix) {
        return value;
    }

    var multiplier: usize = 1;
    while (offset.* < data.len) {
        const byte = data[offset.*];
        offset.* += 1;

        value += (byte & 127) * multiplier;
        multiplier *= 128;

        if ((byte & 128) == 0) {
            return value;
        }
    }

    return Error.IntegerOverflow;
}

/// Encode string (RFC 7541 section 5.2)
pub fn encodeString(buffer: []u8, string: []const u8, use_huffman: bool) !usize {
    var offset: usize = 0;

    // Length prefix (with Huffman bit)
    const length_prefix: u8 = if (use_huffman) 0x80 else 0x00;

    if (use_huffman) {
        // Encode with Huffman
        var huffman_buffer: [4096]u8 = undefined;
        const huffman_len = huffman.encode(&huffman_buffer, string) catch {
            // Fall back to literal if encoding fails
            const len_bytes = try encodeInteger(buffer, string.len, 7);
            offset += len_bytes;
            if (offset + string.len > buffer.len) return Error.StringTooLong;
            @memcpy(buffer[offset .. offset + string.len], string);
            offset += string.len;
            return offset;
        };

        // Write Huffman-encoded length with H=1 bit
        const len_bytes = try encodeInteger(buffer, huffman_len, 7);
        buffer[0] |= 0x80; // Set Huffman bit
        offset += len_bytes;

        // Copy Huffman-encoded data
        if (offset + huffman_len > buffer.len) return Error.StringTooLong;
        @memcpy(buffer[offset .. offset + huffman_len], huffman_buffer[0..huffman_len]);
        offset += huffman_len;
    } else {
        const len_bytes = try encodeInteger(buffer, string.len, 7);
        buffer[0] |= length_prefix;
        offset += len_bytes;

        if (offset + string.len > buffer.len) return Error.StringTooLong;
        @memcpy(buffer[offset .. offset + string.len], string);
        offset += string.len;
    }

    return offset;
}

/// Thread-local Huffman decode tree (built once per thread)
threadlocal var huffman_decode_tree: ?[]const huffman.DecodeNode = null;
threadlocal var huffman_tree_allocator: ?std.mem.Allocator = null;

/// Get or build Huffman decode tree
fn getHuffmanTree(allocator: std.mem.Allocator) ![]const huffman.DecodeNode {
    if (huffman_decode_tree == null) {
        huffman_decode_tree = try huffman.buildDecodeTree(allocator);
        huffman_tree_allocator = allocator;
    }
    return huffman_decode_tree.?;
}

/// Decode string from HPACK representation
pub fn decodeString(data: []const u8, offset: *usize, allocator: std.mem.Allocator) ![]u8 {
    if (offset.* >= data.len) return Error.StringTooLong;

    const is_huffman = (data[offset.*] & 0x80) != 0;
    const length = try decodeInteger(data, 7, offset);

    if (offset.* + length > data.len) return Error.StringTooLong;

    const string_data = data[offset.* .. offset.* + length];
    offset.* += length;

    if (is_huffman) {
        // Decode Huffman-encoded string
        const tree = try getHuffmanTree(allocator);
        var decoded_buffer = try allocator.alloc(u8, length * 2); // Max expansion
        errdefer allocator.free(decoded_buffer);

        const decoded_len = huffman.decode(decoded_buffer, string_data, tree) catch {
            // If Huffman decode fails, treat as literal
            allocator.free(decoded_buffer);
            return try allocator.dupe(u8, string_data);
        };

        // Resize to actual decoded length
        decoded_buffer = try allocator.realloc(decoded_buffer, decoded_len);
        return decoded_buffer;
    } else {
        return try allocator.dupe(u8, string_data);
    }
}

/// Encode header field
pub fn encodeHeader(
    buffer: []u8,
    context: *Context,
    name: []const u8,
    value: []const u8,
    index_mode: enum { indexed, literal_with_indexing, literal_without_indexing, literal_never_indexed },
) !usize {
    var offset: usize = 0;

    switch (index_mode) {
        .indexed => {
            // Indexed header field (RFC 7541 section 6.1)
            const index = context.findEntry(name, value);
            if (index > 0) {
                buffer[offset] = 0x80; // 1xxxxxxx pattern
                const len = try encodeInteger(buffer[offset..], index, 7);
                offset += len;
            } else {
                return Error.InvalidIndex;
            }
        },
        .literal_with_indexing => {
            // Literal header field with incremental indexing (RFC 7541 section 6.2.1)
            const name_index = context.findName(name);

            if (name_index > 0) {
                buffer[offset] = 0x40; // 01xxxxxx pattern
                const len = try encodeInteger(buffer[offset..], name_index, 6);
                offset += len;
            } else {
                buffer[offset] = 0x40;
                offset += 1;
                const name_len = try encodeString(buffer[offset..], name, false);
                offset += name_len;
            }

            const value_len = try encodeString(buffer[offset..], value, false);
            offset += value_len;

            try context.dynamic_table.add(name, value);
        },
        .literal_without_indexing => {
            // Literal header field without indexing (RFC 7541 section 6.2.2)
            const name_index = context.findName(name);

            if (name_index > 0) {
                buffer[offset] = 0x00; // 0000xxxx pattern
                const len = try encodeInteger(buffer[offset..], name_index, 4);
                offset += len;
            } else {
                buffer[offset] = 0x00;
                offset += 1;
                const name_len = try encodeString(buffer[offset..], name, false);
                offset += name_len;
            }

            const value_len = try encodeString(buffer[offset..], value, false);
            offset += value_len;
        },
        .literal_never_indexed => {
            // Literal header field never indexed (RFC 7541 section 6.2.3)
            const name_index = context.findName(name);

            if (name_index > 0) {
                buffer[offset] = 0x10; // 0001xxxx pattern
                const len = try encodeInteger(buffer[offset..], name_index, 4);
                offset += len;
            } else {
                buffer[offset] = 0x10;
                offset += 1;
                const name_len = try encodeString(buffer[offset..], name, false);
                offset += name_len;
            }

            const value_len = try encodeString(buffer[offset..], value, false);
            offset += value_len;
        },
    }

    return offset;
}

/// Decode header block
pub fn decodeHeaderBlock(
    data: []const u8,
    context: *Context,
    allocator: std.mem.Allocator,
) !std.ArrayList(struct { name: []u8, value: []u8 }) {
    var headers = std.ArrayList(struct { name: []u8, value: []u8 }).init(allocator);
    errdefer headers.deinit();

    var offset: usize = 0;

    while (offset < data.len) {
        const byte = data[offset];

        if ((byte & 0x80) != 0) {
            // Indexed header field
            const index = try decodeInteger(data, 7, &offset);
            const entry = try context.getEntry(index);
            try headers.append(.{
                .name = try allocator.dupe(u8, entry.name),
                .value = try allocator.dupe(u8, entry.value),
            });
        } else if ((byte & 0x40) != 0) {
            // Literal with incremental indexing
            offset += 1;
            const name_index_or_string = try decodeInteger(data[0..], 6, &offset);

            var name: []u8 = undefined;
            if (name_index_or_string == 0) {
                name = try decodeString(data, &offset, allocator);
            } else {
                const entry = try context.getEntry(name_index_or_string);
                name = try allocator.dupe(u8, entry.name);
            }

            const value = try decodeString(data, &offset, allocator);

            try context.dynamic_table.add(name, value);
            try headers.append(.{ .name = name, .value = value });
        } else {
            // Literal without indexing or never indexed
            offset += 1;
            const name_index_or_string = try decodeInteger(data[0..], 4, &offset);

            var name: []u8 = undefined;
            if (name_index_or_string == 0) {
                name = try decodeString(data, &offset, allocator);
            } else {
                const entry = try context.getEntry(name_index_or_string);
                name = try allocator.dupe(u8, entry.name);
            }

            const value = try decodeString(data, &offset, allocator);
            try headers.append(.{ .name = name, .value = value });
        }
    }

    return headers;
}

test "hpack integer encoding" {
    var buffer: [10]u8 = undefined;

    // Test small value
    const len1 = try encodeInteger(&buffer, 10, 5);
    try std.testing.expectEqual(@as(usize, 1), len1);
    try std.testing.expectEqual(@as(u8, 10), buffer[0]);

    // Test value requiring multiple bytes
    const len2 = try encodeInteger(&buffer, 1337, 5);
    try std.testing.expect(len2 > 1);
}

test "hpack integer decoding" {
    const data = [_]u8{ 0x1F, 0x9A, 0x0A }; // 1337 encoded with 5-bit prefix
    var offset: usize = 0;
    const value = try decodeInteger(&data, 5, &offset);
    try std.testing.expectEqual(@as(usize, 1337), value);
}

test "hpack dynamic table" {
    const allocator = std.testing.allocator;

    var table = DynamicTable.init(allocator);
    defer table.deinit();

    try table.add("custom-header", "custom-value");
    try std.testing.expectEqual(@as(usize, 1), table.entries.items.len);

    const entry = table.get(0).?;
    try std.testing.expectEqualStrings("custom-header", entry.name);
    try std.testing.expectEqualStrings("custom-value", entry.value);
}
