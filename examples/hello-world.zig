const std = @import("std");
const nexus = @import("nexus");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create HTTP server
    var server = try nexus.http.Server.init(allocator, .{
        .port = 3000,
        .host = "0.0.0.0",
    });
    defer server.deinit();

    // Register routes
    try server.route("GET", "/", handleRoot);
    try server.route("GET", "/api/hello", handleHello);
    try server.route("POST", "/api/echo", handleEcho);

    // Start server
    nexus.console.info("🚀 Nexus server starting on http://localhost:3000", .{});
    nexus.console.info("", .{});
    nexus.console.info("Routes:", .{});
    nexus.console.info("  GET  /", .{});
    nexus.console.info("  GET  /api/hello", .{});
    nexus.console.info("  POST /api/echo", .{});
    nexus.console.info("", .{});

    try server.listen();
}

fn handleRoot(req: *nexus.http.Request, res: *nexus.http.Response) !void {
    _ = req;

    const html =
        \\<!DOCTYPE html>
        \\<html>
        \\<head>
        \\    <title>Nexus Runtime</title>
        \\    <style>
        \\        body {
        \\            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
        \\            max-width: 800px;
        \\            margin: 50px auto;
        \\            padding: 20px;
        \\            line-height: 1.6;
        \\        }
        \\        h1 { color: #ff6b35; }
        \\        code {
        \\            background: #f4f4f4;
        \\            padding: 2px 5px;
        \\            border-radius: 3px;
        \\        }
        \\        pre {
        \\            background: #2d2d2d;
        \\            color: #f8f8f2;
        \\            padding: 15px;
        \\            border-radius: 5px;
        \\            overflow-x: auto;
        \\        }
        \\        .stats {
        \\            background: #e3f2fd;
        \\            padding: 15px;
        \\            border-radius: 5px;
        \\            margin: 20px 0;
        \\        }
        \\    </style>
        \\</head>
        \\<body>
        \\    <h1>⚡ Nexus Runtime</h1>
        \\    <p><strong>An application runtime written in Zig.</strong></p>
        \\
        \\    <h2>API Endpoints</h2>
        \\    <ul>
        \\        <li><code>GET /</code> - This page</li>
        \\        <li><code>GET /api/hello</code> - Hello World JSON</li>
        \\        <li><code>POST /api/echo</code> - Echo request body</li>
        \\    </ul>
        \\
        \\    <h2>Example Request</h2>
        \\    <pre>curl http://localhost:3000/api/hello</pre>
        \\
        \\    <h2>What this example uses</h2>
        \\    <ul>
        \\        <li>HTTP/1.1 server with routing</li>
        \\        <li>JSON responses</li>
        \\        <li>Request body handling</li>
        \\    </ul>
        \\
        \\    <p><a href="https://github.com/ghostkellz/nexus">GitHub</a> | <a href="/api/hello">API Demo</a></p>
        \\</body>
        \\</html>
    ;

    try res.html(html);
}

fn handleHello(req: *nexus.http.Request, res: *nexus.http.Response) !void {
    _ = req;

    try res.json(.{
        .message = "Hello from Nexus!",
        .runtime = "Nexus v" ++ nexus.version,
        .language = "Zig",
        .features = .{
            "Event Loop",
            "HTTP/WebSocket",
        },
    });
}

fn handleEcho(req: *nexus.http.Request, res: *nexus.http.Response) !void {
    const body = try req.readBody();

    try res.json(.{
        .echo = body,
        .length = body.len,
        .method = "POST",
    });
}
