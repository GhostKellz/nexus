const std = @import("std");
const nexus = @import("nexus");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Welcome message
    nexus.console.info("⚡ Nexus Runtime v0.1.0", .{});
    nexus.console.info("Node.js reimagined in Zig + WASM - 10x better", .{});
    nexus.console.info("", .{});

    // Get command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "run")) {
        if (args.len < 3) {
            nexus.console.@"error"("Usage: nexus run <file.zig>", .{});
            return error.MissingArgument;
        }

        const file_path = args[2];
        nexus.console.info("Running: {s}", .{file_path});

        // For now, just acknowledge the command
        nexus.console.info("✓ File execution not yet implemented", .{});
        nexus.console.info("  This will compile and run Zig files with Nexus runtime", .{});
    } else if (std.mem.eql(u8, command, "serve")) {
        try runHttpServer(allocator);
    } else if (std.mem.eql(u8, command, "test")) {
        nexus.console.info("Running tests...", .{});
        nexus.console.info("✓ Test runner not yet implemented", .{});
    } else if (std.mem.eql(u8, command, "version") or std.mem.eql(u8, command, "--version")) {
        printVersion();
    } else if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help")) {
        printUsage();
    } else {
        nexus.console.@"error"("Unknown command: {s}", .{command});
        printUsage();
        return error.UnknownCommand;
    }
}

fn printUsage() void {
    nexus.console.println("", .{});
    nexus.console.println("Usage: nexus <command> [options]", .{});
    nexus.console.println("", .{});
    nexus.console.println("Commands:", .{});
    nexus.console.println("  run <file>     Run a Zig file with Nexus runtime", .{});
    nexus.console.println("  serve          Start a demo HTTP server", .{});
    nexus.console.println("  test           Run tests", .{});
    nexus.console.println("  version        Print version information", .{});
    nexus.console.println("  help           Print this help message", .{});
    nexus.console.println("", .{});
    nexus.console.println("Examples:", .{});
    nexus.console.println("  nexus run app.zig", .{});
    nexus.console.println("  nexus serve", .{});
    nexus.console.println("", .{});
}

fn printVersion() void {
    nexus.console.println("", .{});
    nexus.console.println("Nexus Runtime v0.1.0", .{});
    nexus.console.println("", .{});
    nexus.console.println("Features:", .{});
    nexus.console.println("  ✓ Event loop (epoll/kqueue/IOCP)", .{});
    nexus.console.println("  ✓ HTTP/1.1 server", .{});
    nexus.console.println("  ✓ WebSocket support", .{});
    nexus.console.println("  ✓ WASM runtime", .{});
    nexus.console.println("  ✓ WASI support", .{});
    nexus.console.println("  ✓ File system operations", .{});
    nexus.console.println("  ✓ TCP/UDP networking", .{});
    nexus.console.println("  ✓ Streams API", .{});
    nexus.console.println("  ✓ Module system", .{});
    nexus.console.println("  ✓ Security policies", .{});
    nexus.console.println("", .{});
    nexus.console.println("Performance (target):", .{});
    nexus.console.println("  HTTP req/s:  500k+ (10x vs Node.js)", .{});
    nexus.console.println("  Cold start:  <5ms (10x vs Node.js)", .{});
    nexus.console.println("  Memory:      ~5MB (10x vs Node.js)", .{});
    nexus.console.println("  Binary size: ~5MB (10x vs Node.js)", .{});
    nexus.console.println("", .{});
}

fn runHttpServer(allocator: std.mem.Allocator) !void {
    var server = try nexus.http.Server.init(allocator, .{
        .port = 3000,
        .host = "0.0.0.0",
    });
    defer server.deinit();

    try server.route("GET", "/", handleRoot);
    try server.route("GET", "/api/status", handleStatus);

    nexus.console.info("", .{});
    nexus.console.info("🚀 Nexus HTTP server running", .{});
    nexus.console.info("   http://localhost:3000", .{});
    nexus.console.info("", .{});
    nexus.console.info("Routes:", .{});
    nexus.console.info("  GET  /", .{});
    nexus.console.info("  GET  /api/status", .{});
    nexus.console.info("", .{});
    nexus.console.info("Press Ctrl+C to stop", .{});
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
        \\            max-width: 900px;
        \\            margin: 50px auto;
        \\            padding: 30px;
        \\            line-height: 1.6;
        \\            background: #f5f5f5;
        \\        }
        \\        .container {
        \\            background: white;
        \\            padding: 40px;
        \\            border-radius: 10px;
        \\            box-shadow: 0 2px 10px rgba(0,0,0,0.1);
        \\        }
        \\        h1 {
        \\            color: #ff6b35;
        \\            font-size: 3em;
        \\            margin: 0;
        \\        }
        \\        .tagline {
        \\            color: #666;
        \\            font-size: 1.3em;
        \\            margin: 10px 0 30px 0;
        \\        }
        \\        .stats {
        \\            background: #e3f2fd;
        \\            padding: 20px;
        \\            border-radius: 8px;
        \\            margin: 30px 0;
        \\        }
        \\        .feature-grid {
        \\            display: grid;
        \\            grid-template-columns: repeat(2, 1fr);
        \\            gap: 15px;
        \\            margin: 20px 0;
        \\        }
        \\        .feature {
        \\            background: #f9f9f9;
        \\            padding: 15px;
        \\            border-radius: 5px;
        \\            border-left: 3px solid #ff6b35;
        \\        }
        \\        code {
        \\            background: #f4f4f4;
        \\            padding: 2px 6px;
        \\            border-radius: 3px;
        \\            font-family: 'Monaco', 'Courier New', monospace;
        \\        }
        \\        pre {
        \\            background: #2d2d2d;
        \\            color: #f8f8f2;
        \\            padding: 20px;
        \\            border-radius: 8px;
        \\            overflow-x: auto;
        \\        }
        \\    </style>
        \\</head>
        \\<body>
        \\    <div class="container">
        \\        <h1>⚡ Nexus</h1>
        \\        <p class="tagline">Node.js reimagined in Zig + WASM</p>
        \\        <p><strong>10x faster • 10x smaller • Infinitely more powerful</strong></p>
        \\
        \\        <div class="stats">
        \\            <h3>🚀 Performance Targets</h3>
        \\            <ul>
        \\                <li><strong>500k+</strong> HTTP requests/sec (vs Node.js: 50k)</li>
        \\                <li><strong>&lt;5ms</strong> cold start (vs Node.js: 50ms)</li>
        \\                <li><strong>~5MB</strong> memory usage (vs Node.js: 50MB)</li>
        \\                <li><strong>~5MB</strong> binary size (vs Node.js: 50MB)</li>
        \\            </ul>
        \\        </div>
        \\
        \\        <h2>✨ Features</h2>
        \\        <div class="feature-grid">
        \\            <div class="feature">✓ Event loop (epoll/kqueue)</div>
        \\            <div class="feature">✓ HTTP/1.1 server</div>
        \\            <div class="feature">✓ WebSocket support</div>
        \\            <div class="feature">✓ WASM runtime</div>
        \\            <div class="feature">✓ WASI support</div>
        \\            <div class="feature">✓ File system ops</div>
        \\            <div class="feature">✓ TCP/UDP networking</div>
        \\            <div class="feature">✓ Streams API</div>
        \\            <div class="feature">✓ Module system</div>
        \\            <div class="feature">✓ Security policies</div>
        \\        </div>
        \\
        \\        <h2>📡 API Endpoints</h2>
        \\        <ul>
        \\            <li><code>GET /</code> - This page</li>
        \\            <li><code>GET /api/status</code> - Runtime status (JSON)</li>
        \\        </ul>
        \\
        \\        <h2>🔧 Try It</h2>
        \\        <pre>curl http://localhost:3000/api/status</pre>
        \\
        \\        <p>
        \\            <a href="https://github.com/ghostkellz/nexus">GitHub</a> •
        \\            <a href="/api/status">API Status</a> •
        \\            <a href="https://docs.nexus.dev">Documentation</a>
        \\        </p>
        \\    </div>
        \\</body>
        \\</html>
    ;

    try res.html(html);
}

fn handleStatus(req: *nexus.http.Request, res: *nexus.http.Response) !void {
    _ = req;

    try res.json(.{
        .runtime = "Nexus v0.1.0",
        .language = "Zig",
        .status = "running",
        .uptime = 0, // TODO: Track actual uptime
        .features = .{
            "event_loop",
            "http_server",
            "websocket",
            "wasm",
            "wasi",
            "streams",
            "tcp_udp",
            "file_system",
        },
        .performance = .{
            .target_req_per_sec = 500000,
            .target_cold_start_ms = 5,
            .target_memory_mb = 5,
        },
    });
}
