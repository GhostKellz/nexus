const std = @import("std");
const http = @import("http.zig");
const fs = @import("../fs/file.zig");

/// HTTP date parsing for conditional requests
/// Supports RFC 1123, RFC 850, and ANSI C asctime() formats
pub const HttpDate = struct {
    /// Month name to number mapping
    const months = [_][]const u8{
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    };

    /// Parse month name to 1-indexed month number
    fn parseMonth(name: []const u8) ?u4 {
        for (months, 0..) |m, i| {
            if (std.mem.eql(u8, name, m)) {
                return @intCast(i + 1);
            }
        }
        return null;
    }

    /// Parse HTTP date string to Unix timestamp (seconds since epoch)
    /// Supports:
    /// - RFC 1123: "Sun, 06 Nov 1994 08:49:37 GMT"
    /// - RFC 850:  "Sunday, 06-Nov-94 08:49:37 GMT"
    /// - asctime:  "Sun Nov  6 08:49:37 1994"
    pub fn parse(date_str: []const u8) ?i64 {
        // Try RFC 1123 first (most common): "Sun, 06 Nov 1994 08:49:37 GMT"
        if (parseRfc1123(date_str)) |ts| return ts;

        // Try RFC 850: "Sunday, 06-Nov-94 08:49:37 GMT"
        if (parseRfc850(date_str)) |ts| return ts;

        // Try asctime: "Sun Nov  6 08:49:37 1994"
        if (parseAsctime(date_str)) |ts| return ts;

        return null;
    }

    /// Parse RFC 1123 date: "Sun, 06 Nov 1994 08:49:37 GMT"
    fn parseRfc1123(date_str: []const u8) ?i64 {
        // Skip day name and comma
        const after_comma = std.mem.indexOf(u8, date_str, ", ") orelse return null;
        const rest = date_str[after_comma + 2 ..];

        // Parse: "06 Nov 1994 08:49:37 GMT"
        if (rest.len < 20) return null;

        const day = std.fmt.parseInt(u5, rest[0..2], 10) catch return null;
        const month = parseMonth(rest[3..6]) orelse return null;
        const year = std.fmt.parseInt(u16, rest[7..11], 10) catch return null;
        const hour = std.fmt.parseInt(u5, rest[12..14], 10) catch return null;
        const minute = std.fmt.parseInt(u6, rest[15..17], 10) catch return null;
        const second = std.fmt.parseInt(u6, rest[18..20], 10) catch return null;

        return toUnixTimestamp(year, month, day, hour, minute, second);
    }

    /// Parse RFC 850 date: "Sunday, 06-Nov-94 08:49:37 GMT"
    fn parseRfc850(date_str: []const u8) ?i64 {
        // Skip day name and comma
        const after_comma = std.mem.indexOf(u8, date_str, ", ") orelse return null;
        const rest = date_str[after_comma + 2 ..];

        // Parse: "06-Nov-94 08:49:37 GMT"
        if (rest.len < 18) return null;

        const day = std.fmt.parseInt(u5, rest[0..2], 10) catch return null;
        const month = parseMonth(rest[3..6]) orelse return null;
        var year = std.fmt.parseInt(u16, rest[7..9], 10) catch return null;

        // Convert 2-digit year: 00-69 = 2000-2069, 70-99 = 1970-1999
        if (year < 70) {
            year += 2000;
        } else {
            year += 1900;
        }

        const hour = std.fmt.parseInt(u5, rest[10..12], 10) catch return null;
        const minute = std.fmt.parseInt(u6, rest[13..15], 10) catch return null;
        const second = std.fmt.parseInt(u6, rest[16..18], 10) catch return null;

        return toUnixTimestamp(year, month, day, hour, minute, second);
    }

    /// Parse asctime date: "Sun Nov  6 08:49:37 1994"
    fn parseAsctime(date_str: []const u8) ?i64 {
        if (date_str.len < 24) return null;

        const month = parseMonth(date_str[4..7]) orelse return null;

        // Day can be space-padded: " 6" or "06"
        const day_str = std.mem.trim(u8, date_str[8..10], " ");
        const day = std.fmt.parseInt(u5, day_str, 10) catch return null;

        const hour = std.fmt.parseInt(u5, date_str[11..13], 10) catch return null;
        const minute = std.fmt.parseInt(u6, date_str[14..16], 10) catch return null;
        const second = std.fmt.parseInt(u6, date_str[17..19], 10) catch return null;
        const year = std.fmt.parseInt(u16, date_str[20..24], 10) catch return null;

        return toUnixTimestamp(year, month, day, hour, minute, second);
    }

    /// Convert date components to Unix timestamp
    fn toUnixTimestamp(year: u16, month: u4, day: u5, hour: u5, minute: u6, second: u6) ?i64 {
        // Use Zig's epoch calculation
        const epoch_day = epochDay(year, month, day) catch return null;
        const day_seconds: i64 = @as(i64, epoch_day) * 86400;
        const time_seconds: i64 = @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);
        return day_seconds + time_seconds;
    }

    /// Calculate days since Unix epoch (1970-01-01)
    fn epochDay(year: u16, month: u4, day: u5) !i32 {
        var y: i32 = @intCast(year);
        var m: i32 = @intCast(month);
        const d: i32 = @intCast(day);

        // Adjust for months (March = 1)
        if (m <= 2) {
            y -= 1;
            m += 12;
        }
        m -= 3;

        // Calculate days
        const era: i32 = @divFloor(y, 400);
        const yoe: i32 = @mod(y, 400);
        const doy: i32 = @divFloor(153 * m + 2, 5) + d - 1;
        const doe: i32 = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;

        // Days since epoch (1970-01-01 is day 0)
        return era * 146097 + doe - 719468;
    }

    /// Format a Unix timestamp as RFC 1123 date
    pub fn format(timestamp: i64, buf: []u8) ![]const u8 {
        const day_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };

        // Calculate date components from timestamp
        const days_since_epoch: i64 = @divFloor(timestamp, 86400);
        const time_of_day: u32 = @intCast(@mod(timestamp, 86400));

        const hour: u8 = @intCast(time_of_day / 3600);
        const minute: u8 = @intCast((time_of_day % 3600) / 60);
        const second: u8 = @intCast(time_of_day % 60);

        // Day of week (1970-01-01 was Thursday = 4)
        const dow: usize = @intCast(@mod(days_since_epoch + 4, 7));

        // Calculate year, month, day from days since epoch
        const z: i64 = days_since_epoch + 719468;
        const era: i64 = @divFloor(z, 146097);
        const doe: i64 = @mod(z, 146097);
        const yoe: i64 = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
        const y: i64 = yoe + era * 400;
        const doy: i64 = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
        const mp: i64 = @divFloor(5 * doy + 2, 153);
        const d: u8 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
        const m_raw: i64 = if (mp < 10) mp + 3 else mp - 9;
        const m: usize = @intCast(m_raw);
        const year: u16 = @intCast(if (m <= 2) y + 1 else y);

        return std.fmt.bufPrint(buf, "{s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
            day_names[dow],
            d,
            months[m - 1],
            year,
            hour,
            minute,
            second,
        });
    }
};

pub const StaticFileOptions = struct {
    index: ?[]const u8 = "index.html",
    dot_files: bool = false, // Allow serving hidden files
    cache_control: ?[]const u8 = "public, max-age=3600",
    enable_etag: bool = true,
    enable_range: bool = true,
};

/// Calculate ETag from file stats
fn calculateETag(stat: std.fs.File.Stat, allocator: std.mem.Allocator) ![]u8 {
    // Use size and mtime for ETag (weak validator)
    return try std.fmt.allocPrint(
        allocator,
        "W/\"{d}-{d}\"",
        .{ stat.size, stat.mtime.nanoseconds },
    );
}

/// Check if client's cached version is still valid
fn checkNotModified(req: *http.Request, etag: []const u8, last_modified: i64) bool {
    // Check If-None-Match (ETag) - takes precedence
    if (req.getHeader("if-none-match")) |client_etag| {
        if (std.mem.eql(u8, client_etag, etag)) {
            return true;
        }
    }

    // Check If-Modified-Since
    if (req.getHeader("if-modified-since")) |client_date| {
        if (HttpDate.parse(client_date)) |client_timestamp| {
            // Convert last_modified from nanoseconds to seconds
            const server_timestamp = @divFloor(last_modified, std.time.ns_per_s);
            // Not modified if client's date is >= server's last modified time
            if (client_timestamp >= server_timestamp) {
                return true;
            }
        }
    }

    return false;
}

/// Parse Range header (e.g., "bytes=0-499")
const RangeSpec = struct {
    start: usize,
    end: ?usize, // null means end of file
};

fn parseRange(range_header: []const u8, file_size: usize) ?RangeSpec {
    if (!std.mem.startsWith(u8, range_header, "bytes=")) return null;

    const range_part = range_header["bytes=".len..];
    const dash_pos = std.mem.indexOfScalar(u8, range_part, '-') orelse return null;

    const start_str = range_part[0..dash_pos];
    const end_str = range_part[dash_pos + 1 ..];

    const start = std.fmt.parseInt(usize, start_str, 10) catch return null;

    const end = if (end_str.len > 0)
        std.fmt.parseInt(usize, end_str, 10) catch return null
    else
        null;

    // Validate range
    if (start >= file_size) return null;
    if (end) |e| {
        if (e < start or e >= file_size) return null;
    }

    return RangeSpec{ .start = start, .end = end };
}

/// Serve a single file with full HTTP features
pub fn serveFile(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    req: *http.Request,
    res: *http.Response,
    options: StaticFileOptions,
) !void {
    // Check if file exists and get stats
    const file_stat = std.fs.cwd().statFile(file_path) catch {
        res.status_code = .NotFound;
        try res.text("File not found");
        return;
    };

    // Don't serve directories
    if (file_stat.kind == .directory) {
        res.status_code = .Forbidden;
        try res.text("Cannot serve directory");
        return;
    }

    // Check for dot files
    if (!options.dot_files) {
        const basename = std.fs.path.basename(file_path);
        if (basename.len > 0 and basename[0] == '.') {
            res.status_code = .Forbidden;
            try res.text("Hidden files not allowed");
            return;
        }
    }

    // Calculate ETag
    var etag: ?[]u8 = null;
    defer if (etag) |e| allocator.free(e);

    if (options.enable_etag) {
        etag = try calculateETag(file_stat, allocator);

        // Check if client's cached version is valid
        if (checkNotModified(req, etag.?, file_stat.mtime.nanoseconds)) {
            res.status_code = .NotModified;
            _ = try res.setHeader("ETag", etag.?);
            try res.send("");
            return;
        }
    }

    // Set MIME type
    const mime_type = getMimeType(file_path);
    _ = try res.setHeader("Content-Type", mime_type);

    // Set caching headers
    if (options.cache_control) |cc| {
        _ = try res.setHeader("Cache-Control", cc);
    }

    if (etag) |e| {
        _ = try res.setHeader("ETag", e);
    }

    // Format Last-Modified header
    // Using simple timestamp format for now
    var last_modified_buf: [64]u8 = undefined;
    const last_modified = try std.fmt.bufPrint(
        &last_modified_buf,
        "{d}",
        .{file_stat.mtime.nanoseconds},
    );
    _ = try res.setHeader("Last-Modified", last_modified);

    // Handle Range requests
    if (options.enable_range) {
        if (req.getHeader("range")) |range_header| {
            if (parseRange(range_header, file_stat.size)) |range_spec| {
                return try serveRange(allocator, file_path, req, res, range_spec, file_stat.size);
            }
        }

        // Advertise range support
        _ = try res.setHeader("Accept-Ranges", "bytes");
    }

    // Read and serve entire file
    const content = try fs.readFile(allocator, file_path);
    defer allocator.free(content);

    try res.send(content);
}

/// Serve a range of a file (for partial content / resume downloads)
fn serveRange(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    req: *http.Request,
    res: *http.Response,
    range: RangeSpec,
    file_size: usize,
) !void {
    _ = req;

    const end = range.end orelse (file_size - 1);
    const content_length = end - range.start + 1;

    // Open file and seek to start
    var file = try fs.File.open(allocator, file_path, .{ .read = true });
    defer file.close();

    try file.file.seekTo(range.start);

    // Read requested range
    const content = try allocator.alloc(u8, content_length);
    defer allocator.free(content);

    _ = try file.file.readAll(content);

    // Set 206 Partial Content status
    res.status_code = .PartialContent;

    // Set Content-Range header
    var content_range_buf: [128]u8 = undefined;
    const content_range = try std.fmt.bufPrint(
        &content_range_buf,
        "bytes {d}-{d}/{d}",
        .{ range.start, end, file_size },
    );
    _ = try res.setHeader("Content-Range", content_range);

    try res.send(content);
}

/// Serve static files from a directory
pub fn serveStatic(
    base_path: []const u8,
    options: StaticFileOptions,
) http.RouteHandler {
    return struct {
        const base_path_const = base_path;
        const options_const = options;

        fn handler(req: *http.Request, res: *http.Response) !void {
            var requested_path = req.path;

            // Security: Prevent directory traversal
            if (std.mem.indexOf(u8, requested_path, "..")) |_| {
                res.status_code = .Forbidden;
                try res.text("Invalid path");
                return;
            }

            // Remove leading slash
            if (requested_path.len > 0 and requested_path[0] == '/') {
                requested_path = requested_path[1..];
            }

            // If empty or ends with /, try serving index file
            if (requested_path.len == 0 or requested_path[requested_path.len - 1] == '/') {
                if (options_const.index) |index_file| {
                    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
                    const full_path = try std.fmt.bufPrint(
                        &path_buf,
                        "{s}/{s}{s}",
                        .{ base_path_const, requested_path, index_file },
                    );

                    return try serveFile(req.allocator, full_path, req, res, options_const);
                }
            }

            // Build full file path
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const full_path = try std.fmt.bufPrint(
                &path_buf,
                "{s}/{s}",
                .{ base_path_const, requested_path },
            );

            // Serve the file
            try serveFile(req.allocator, full_path, req, res, options_const);
        }
    }.handler;
}

/// Get MIME type from file extension
pub fn getMimeType(file_path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, file_path, '.')) |dot_pos| {
        const ext = file_path[dot_pos + 1 ..];

        // Text
        if (std.mem.eql(u8, ext, "html")) return "text/html; charset=utf-8";
        if (std.mem.eql(u8, ext, "htm")) return "text/html; charset=utf-8";
        if (std.mem.eql(u8, ext, "css")) return "text/css; charset=utf-8";
        if (std.mem.eql(u8, ext, "js")) return "application/javascript; charset=utf-8";
        if (std.mem.eql(u8, ext, "mjs")) return "application/javascript; charset=utf-8";
        if (std.mem.eql(u8, ext, "json")) return "application/json; charset=utf-8";
        if (std.mem.eql(u8, ext, "xml")) return "application/xml; charset=utf-8";
        if (std.mem.eql(u8, ext, "txt")) return "text/plain; charset=utf-8";
        if (std.mem.eql(u8, ext, "md")) return "text/markdown; charset=utf-8";
        if (std.mem.eql(u8, ext, "csv")) return "text/csv; charset=utf-8";

        // Images
        if (std.mem.eql(u8, ext, "png")) return "image/png";
        if (std.mem.eql(u8, ext, "jpg")) return "image/jpeg";
        if (std.mem.eql(u8, ext, "jpeg")) return "image/jpeg";
        if (std.mem.eql(u8, ext, "gif")) return "image/gif";
        if (std.mem.eql(u8, ext, "svg")) return "image/svg+xml";
        if (std.mem.eql(u8, ext, "ico")) return "image/x-icon";
        if (std.mem.eql(u8, ext, "webp")) return "image/webp";
        if (std.mem.eql(u8, ext, "avif")) return "image/avif";
        if (std.mem.eql(u8, ext, "bmp")) return "image/bmp";

        // Fonts
        if (std.mem.eql(u8, ext, "woff")) return "font/woff";
        if (std.mem.eql(u8, ext, "woff2")) return "font/woff2";
        if (std.mem.eql(u8, ext, "ttf")) return "font/ttf";
        if (std.mem.eql(u8, ext, "otf")) return "font/otf";
        if (std.mem.eql(u8, ext, "eot")) return "application/vnd.ms-fontobject";

        // Audio/Video
        if (std.mem.eql(u8, ext, "mp3")) return "audio/mpeg";
        if (std.mem.eql(u8, ext, "mp4")) return "video/mp4";
        if (std.mem.eql(u8, ext, "webm")) return "video/webm";
        if (std.mem.eql(u8, ext, "ogg")) return "audio/ogg";
        if (std.mem.eql(u8, ext, "wav")) return "audio/wav";

        // Archives
        if (std.mem.eql(u8, ext, "pdf")) return "application/pdf";
        if (std.mem.eql(u8, ext, "zip")) return "application/zip";
        if (std.mem.eql(u8, ext, "tar")) return "application/x-tar";
        if (std.mem.eql(u8, ext, "gz")) return "application/gzip";
        if (std.mem.eql(u8, ext, "7z")) return "application/x-7z-compressed";

        // Special
        if (std.mem.eql(u8, ext, "wasm")) return "application/wasm";
        if (std.mem.eql(u8, ext, "manifest")) return "application/manifest+json";
    }

    return "application/octet-stream";
}

/// Create a static file handler for a specific directory
pub fn staticHandler(
    comptime base_dir: []const u8,
    comptime url_prefix: []const u8,
) http.RouteHandler {
    return struct {
        fn handler(req: *http.Request, res: *http.Response) !void {
            // Remove URL prefix from path
            const requested_path = if (std.mem.startsWith(u8, req.path, url_prefix))
                req.path[url_prefix.len..]
            else
                req.path;

            // Security: Prevent directory traversal
            if (std.mem.indexOf(u8, requested_path, "..")) |_| {
                res.status_code = .Forbidden;
                try res.text("Invalid path");
                return;
            }

            // Build full file path
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const full_path = try std.fmt.bufPrint(
                &path_buf,
                "{s}/{s}",
                .{ base_dir, requested_path },
            );

            // Serve the file with default options
            const options = StaticFileOptions{};
            try serveFile(req.allocator, full_path, req, res, options);
        }
    }.handler;
}

test "mime type detection" {
    try std.testing.expectEqualStrings("text/html; charset=utf-8", getMimeType("index.html"));
    try std.testing.expectEqualStrings("application/javascript; charset=utf-8", getMimeType("app.js"));
    try std.testing.expectEqualStrings("image/png", getMimeType("logo.png"));
    try std.testing.expectEqualStrings("application/json; charset=utf-8", getMimeType("data.json"));
    try std.testing.expectEqualStrings("application/wasm", getMimeType("module.wasm"));
    try std.testing.expectEqualStrings("application/octet-stream", getMimeType("unknown.xyz"));
}

test "range parsing" {
    const range1 = parseRange("bytes=0-499", 1000);
    try std.testing.expect(range1 != null);
    try std.testing.expectEqual(@as(usize, 0), range1.?.start);
    try std.testing.expectEqual(@as(?usize, 499), range1.?.end);

    const range2 = parseRange("bytes=500-", 1000);
    try std.testing.expect(range2 != null);
    try std.testing.expectEqual(@as(usize, 500), range2.?.start);
    try std.testing.expectEqual(@as(?usize, null), range2.?.end);

    const range3 = parseRange("bytes=2000-3000", 1000); // Invalid - beyond file
    try std.testing.expect(range3 == null);

    const range4 = parseRange("invalid", 1000);
    try std.testing.expect(range4 == null);
}
