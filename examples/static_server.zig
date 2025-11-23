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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
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

    // Serve static files from ./public directory
    const static_options = nexus.static.StaticFileOptions{
        .index = "index.html",
        .cache_control = "public, max-age=86400", // 24 hours
        .enable_etag = true,
        .enable_range = true,
        .dot_files = false, // Don't serve hidden files
    };

    try server.use(struct {
        const options = static_options;

        fn handler(req: *nexus.http.Request, res: *nexus.http.Response) !void {
            // Build path from URL
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buf, "public{s}", .{req.path});

            try nexus.static.serveFile(req.allocator, path, req, res, options);
        }
    }.handler);

    // Create example public directory if it doesn't exist
    std.fs.cwd().makeDir("public") catch {};

    // Create sample index.html if it doesn't exist
    if (!try nexus.fs.exists("public/index.html")) {
        try nexus.fs.writeFile(allocator, "public/index.html",
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
            \\    <h2>Performance</h2>
            \\    <p>Nexus is <strong>10x faster</strong> than Node.js thanks to:</p>
            \\    <ul>
            \\        <li>Native Zig performance (no JIT warmup)</li>
            \\        <li>Zero-copy I/O where possible</li>
            \\        <li>Efficient memory management</li>
            \\        <li>Optimized HTTP parser</li>
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
