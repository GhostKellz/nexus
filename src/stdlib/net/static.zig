const std = @import("std");
const http = @import("http.zig");
const fs = @import("../fs/file.zig");

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
    // Check If-None-Match (ETag)
    if (req.getHeader("if-none-match")) |client_etag| {
        if (std.mem.eql(u8, client_etag, etag)) {
            return true;
        }
    }

    // Check If-Modified-Since
    if (req.getHeader("if-modified-since")) |client_date| {
        _ = client_date;
        _ = last_modified;
        // TODO: Parse HTTP date and compare
        // For now, ETag is sufficient
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
