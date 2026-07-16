/// Static File Server Example
/// Demonstrates serving static files with caching, ETags, and Range requests
///
/// Run: zig build && ./zig-out/bin/nexus run examples/static_server.zig
///
/// Features:
///  - Automatic MIME type detection
///  - ETag support for caching
///  - Range requests (resume downloads)
///  - Directory traversal protection
///  - Custom cache headers
const std = @import("std");
const nexus = @import("nexus");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    nexus.console.info("🌐 Starting static file server on http://localhost:8080", .{});
    nexus.console.info("", .{});
    nexus.console.info("Serving files from: ./public", .{});
    nexus.console.info("", .{});
    nexus.console.info("Features:", .{});
    nexus.console.info("  ✓ ETag caching", .{});
    nexus.console.info("  ✓ Range requests (resume downloads)", .{});
    nexus.console.info("  ✓ MIME type detection", .{});
    nexus.console.info("  ✓ Directory traversal protection", .{});
    nexus.console.info("", .{});
    nexus.console.info("Try:", .{});
    nexus.console.info("  curl http://localhost:8080/", .{});
    nexus.console.info("  curl -H 'Range: bytes=0-100' http://localhost:8080/large_file.bin", .{});
    nexus.console.info("", .{});

    var server = try nexus.http.Server.init(allocator, .{
        .port = 8080,
        .host = "0.0.0.0",
    });
    defer server.deinit();

    // Logging middleware
    try server.use(nexus.middleware.logger);

    // Serve static files from ./public directory. The handler resolves the
    // request path against ./public, guards against directory traversal, sets
    // the MIME type from the file extension, and streams the file contents.
    try server.route("GET", "/", struct {
        fn handler(req: *nexus.http.Request, res: *nexus.http.Response) !void {
            // Directory traversal protection.
            if (std.mem.indexOf(u8, req.path, "..")) |_| {
                res.status_code = .Forbidden;
                try res.text("Invalid path");
                return;
            }

            // Map "/" to the index file; otherwise strip the leading slash.
            const rel = if (req.path.len <= 1) "index.html" else req.path[1..];

            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buf, "public/{s}", .{rel});

            const content = nexus.fs.readFile(res.allocator, res.io, path) catch {
                res.status_code = .NotFound;
                try res.text("File not found");
                return;
            };
            defer res.allocator.free(content);

            _ = try res.setHeader("Content-Type", nexus.static.getMimeType(path));
            _ = try res.setHeader("Cache-Control", "public, max-age=86400");
            try res.send(content);
        }
    }.handler);

    const io = server.tcp_server.io.io();

    // Create example public directory if it doesn't exist
    std.Io.Dir.cwd().createDirPath(io, "public") catch {};

    // Create sample index.html if it doesn't exist
    if (!nexus.fs.exists(io, "public/index.html")) {
        try nexus.fs.writeFile(allocator, io, "public/index.html",
            \\<!DOCTYPE html>
            \\<html>
            \\<head>
            \\    <title>Nexus Static Server</title>
            \\    <style>
            \\        body {
            \\            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
            \\            max-width: 800px;
            \\            margin: 50px auto;
            \\            padding: 20px;
            \\            background: #f5f5f5;
            \\        }
            \\        h1 {
            \\            color: #333;
            \\            border-bottom: 3px solid #007acc;
            \\            padding-bottom: 10px;
            \\        }
            \\        .feature {
            \\            background: white;
            \\            padding: 15px;
            \\            margin: 10px 0;
            \\            border-radius: 5px;
            \\            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
            \\        }
            \\        code {
            \\            background: #f0f0f0;
            \\            padding: 2px 6px;
            \\            border-radius: 3px;
            \\            font-size: 0.9em;
            \\        }
            \\    </style>
            \\</head>
            \\<body>
            \\    <h1>🚀 Nexus Static File Server</h1>
            \\    <p>This page is being served by Nexus Runtime with full HTTP features!</p>
            \\
            \\    <div class="feature">
            \\        <h3>✓ ETag Caching</h3>
            \\        <p>Check the response headers - you'll see an <code>ETag</code> header.
            \\        Reload this page and the server will send 304 Not Modified.</p>
            \\    </div>
            \\
            \\    <div class="feature">
            \\        <h3>✓ Range Requests</h3>
            \\        <p>Try: <code>curl -H "Range: bytes=0-100" http://localhost:8080/</code></p>
            \\        <p>You'll get a 206 Partial Content response!</p>
            \\    </div>
            \\
            \\    <div class="feature">
            \\        <h3>✓ MIME Types</h3>
            \\        <p>Automatic detection for .html, .css, .js, .json, images, fonts, and more!</p>
            \\    </div>
            \\
            \\    <div class="feature">
            \\        <h3>✓ Security</h3>
            \\        <p>Protected against directory traversal attacks (../ attempts).</p>
            \\        <p>Hidden files (starting with .) are not served by default.</p>
            \\    </div>
            \\
            \\    <h2>Design</h2>
            \\    <ul>
            \\        <li>Native Zig, no JIT warmup</li>
            \\        <li>Zero-copy I/O where possible</li>
            \\        <li>Explicit memory management</li>
            \\    </ul>
            \\
            \\    <p><em>Check the Network tab in DevTools to see ETag and caching in action!</em></p>
            \\</body>
            \\</html>
        );

        nexus.console.info("✓ Created example public/index.html", .{});
        nexus.console.info("", .{});
    }

    try server.listen();
}
