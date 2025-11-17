const std = @import("std");
const http = @import("http.zig");
const fs = @import("../fs/file.zig");

pub const StaticFileOptions = struct {
    index: ?[]const u8 = "index.html",
    dot_files: bool = false, // Allow serving hidden files
};

/// Serve static files from a directory
pub fn serveStatic(base_path: []const u8, options: StaticFileOptions) http.RouteHandler {
    _ = base_path;
    _ = options;

    return struct {
        fn handler(req: *http.Request, res: *http.Response) !void {
            _ = req;
            _ = res;
            // Placeholder - will be implemented with actual file serving
        }
    }.handler;
}

/// Get MIME type from file extension
pub fn getMimeType(file_path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, file_path, '.')) |dot_pos| {
        const ext = file_path[dot_pos + 1 ..];

        if (std.mem.eql(u8, ext, "html")) return "text/html; charset=utf-8";
        if (std.mem.eql(u8, ext, "htm")) return "text/html; charset=utf-8";
        if (std.mem.eql(u8, ext, "css")) return "text/css; charset=utf-8";
        if (std.mem.eql(u8, ext, "js")) return "application/javascript; charset=utf-8";
        if (std.mem.eql(u8, ext, "json")) return "application/json; charset=utf-8";
        if (std.mem.eql(u8, ext, "xml")) return "application/xml; charset=utf-8";
        if (std.mem.eql(u8, ext, "txt")) return "text/plain; charset=utf-8";

        // Images
        if (std.mem.eql(u8, ext, "png")) return "image/png";
        if (std.mem.eql(u8, ext, "jpg")) return "image/jpeg";
        if (std.mem.eql(u8, ext, "jpeg")) return "image/jpeg";
        if (std.mem.eql(u8, ext, "gif")) return "image/gif";
        if (std.mem.eql(u8, ext, "svg")) return "image/svg+xml";
        if (std.mem.eql(u8, ext, "ico")) return "image/x-icon";
        if (std.mem.eql(u8, ext, "webp")) return "image/webp";

        // Fonts
        if (std.mem.eql(u8, ext, "woff")) return "font/woff";
        if (std.mem.eql(u8, ext, "woff2")) return "font/woff2";
        if (std.mem.eql(u8, ext, "ttf")) return "font/ttf";
        if (std.mem.eql(u8, ext, "otf")) return "font/otf";

        // Other
        if (std.mem.eql(u8, ext, "pdf")) return "application/pdf";
        if (std.mem.eql(u8, ext, "zip")) return "application/zip";
        if (std.mem.eql(u8, ext, "wasm")) return "application/wasm";
    }

    return "application/octet-stream";
}

/// Serve a single file
pub fn serveFile(allocator: std.mem.Allocator, file_path: []const u8, res: *http.Response) !void {
    // Check if file exists
    const file_exists = try fs.exists(file_path);
    if (!file_exists) {
        res.status_code = .NotFound;
        try res.text("File not found");
        return;
    }

    // Read file
    const content = try fs.readFile(allocator, file_path);
    defer allocator.free(content);

    // Set content type
    const mime_type = getMimeType(file_path);
    _ = try res.setHeader("Content-Type", mime_type);

    // Send file
    try res.send(content);
}

/// Create a static file handler for a specific directory
pub fn staticHandler(comptime base_dir: []const u8, comptime url_prefix: []const u8) http.RouteHandler {
    return struct {
        fn handler(req: *http.Request, res: *http.Response) !void {
            // Remove URL prefix from path
            const requested_path = if (std.mem.startsWith(u8, req.path, url_prefix))
                req.path[url_prefix.len..]
            else
                req.path;

            // Build full file path
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const full_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ base_dir, requested_path });

            // Serve the file
            try serveFile(req.allocator, full_path, res);
        }
    }.handler;
}
