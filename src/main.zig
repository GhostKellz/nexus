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

    if (std.mem.eql(u8, command, "init")) {
        const project_name = if (args.len >= 3) args[2] else "my-nexus-app";
        try initProject(allocator, project_name);
    } else if (std.mem.eql(u8, command, "run")) {
        if (args.len < 3) {
            nexus.console.@"error"("Usage: nexus run <file.zig>", .{});
            return error.MissingArgument;
        }

        const file_path = args[2];
        nexus.console.info("Running: {s}", .{file_path});

        // For now, just acknowledge the command
        nexus.console.info("✓ File execution not yet implemented", .{});
        nexus.console.info("  This will compile and run Zig files with Nexus runtime", .{});
    } else if (std.mem.eql(u8, command, "dev")) {
        const port: u16 = if (args.len >= 3) blk: {
            break :blk std.fmt.parseInt(u16, args[2], 10) catch 3000;
        } else 3000;
        try runDevServer(allocator, port);
    } else if (std.mem.eql(u8, command, "build")) {
        const release = for (args) |arg| {
            if (std.mem.eql(u8, arg, "--release")) break true;
        } else false;
        try buildProject(allocator, release);
    } else if (std.mem.eql(u8, command, "deploy")) {
        const target = if (args.len >= 3) args[2] else "production";
        try deployProject(allocator, target);
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
    nexus.console.println("  init [name]         Create a new Nexus project", .{});
    nexus.console.println("  dev [port]          Start development server with hot reload", .{});
    nexus.console.println("  build [--release]   Build project for production", .{});
    nexus.console.println("  deploy [target]     Deploy to production", .{});
    nexus.console.println("  run <file>          Run a Zig file with Nexus runtime", .{});
    nexus.console.println("  serve               Start a demo HTTP server", .{});
    nexus.console.println("  test                Run tests", .{});
    nexus.console.println("  version             Print version information", .{});
    nexus.console.println("  help                Print this help message", .{});
    nexus.console.println("", .{});
    nexus.console.println("Examples:", .{});
    nexus.console.println("  nexus init my-app      # Create new project", .{});
    nexus.console.println("  nexus dev --port 8080  # Dev server on port 8080", .{});
    nexus.console.println("  nexus build --release  # Production build", .{});
    nexus.console.println("  nexus deploy aws       # Deploy to AWS", .{});
    nexus.console.println("  nexus run app.zig      # Run a file", .{});
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

    // Add middleware
    try server.use(nexus.middleware.logger);
    try server.use(nexus.middleware.cors);

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

/// Initialize a new Nexus project
fn initProject(allocator: std.mem.Allocator, name: []const u8) !void {
    nexus.console.info("🚀 Creating new Nexus project: {s}", .{name});

    // Create project directory
    std.fs.cwd().makeDir(name) catch |err| {
        if (err != error.PathAlreadyExists) return err;
        nexus.console.warn("Directory '{s}' already exists", .{name});
    };

    // Create subdirectories
    const dirs = [_][]const u8{ "src", "static", "tests" };
    for (dirs) |dir| {
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ name, dir });
        defer allocator.free(full_path);
        std.fs.cwd().makeDir(full_path) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
    }

    // Create main.zig
    const main_zig_path = try std.fmt.allocPrint(allocator, "{s}/src/main.zig", .{name});
    defer allocator.free(main_zig_path);

    const main_content =
        \\const std = @import("std");
        \\const nexus = @import("nexus");
        \\
        \\pub fn main() !void {
        \\    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        \\    defer _ = gpa.deinit();
        \\    const allocator = gpa.allocator();
        \\
        \\    // Create HTTP server
        \\    var server = try nexus.http.Server.init(allocator, .{
        \\        .port = 3000,
        \\        .host = "0.0.0.0",
        \\    });
        \\    defer server.deinit();
        \\
        \\    // Add middleware
        \\    try server.use(nexus.middleware.logger);
        \\    try server.use(nexus.middleware.cors);
        \\
        \\    // Define routes
        \\    try server.get("/", handleHome);
        \\    try server.get("/api/hello", handleHello);
        \\
        \\    nexus.console.log("🚀 Server running on http://localhost:3000");
        \\    try server.listen();
        \\}
        \\
        \\fn handleHome(req: *nexus.http.Request, res: *nexus.http.Response) !void {
        \\    _ = req;
        \\    try res.html("<h1>Welcome to Nexus!</h1>");
        \\}
        \\
        \\fn handleHello(req: *nexus.http.Request, res: *nexus.http.Response) !void {
        \\    _ = req;
        \\    try res.json(.{ .message = "Hello from Nexus!" });
        \\}
        \\
    ;

    const main_file = try std.fs.cwd().createFile(main_zig_path, .{});
    defer main_file.close();
    try main_file.writeAll(main_content);

    // Create build.zig
    const build_path = try std.fmt.allocPrint(allocator, "{s}/build.zig", .{name});
    defer allocator.free(build_path);

    const build_content =
        \\const std = @import("std");
        \\
        \\pub fn build(b: *std.Build) void {
        \\    const target = b.standardTargetOptions(.{});
        \\    const optimize = b.standardOptimizeOption(.{});
        \\
        \\    const exe = b.addExecutable(.{
        \\        .name = "app",
        \\        .root_source_file = b.path("src/main.zig"),
        \\        .target = target,
        \\        .optimize = optimize,
        \\    });
        \\
        \\    // Add nexus module (adjust path to your nexus installation)
        \\    const nexus_mod = b.addModule("nexus", .{
        \\        .root_source_file = b.path("../nexus/src/root.zig"),
        \\    });
        \\    exe.root_module.addImport("nexus", nexus_mod);
        \\
        \\    b.installArtifact(exe);
        \\}
        \\
    ;

    const build_file = try std.fs.cwd().createFile(build_path, .{});
    defer build_file.close();
    try build_file.writeAll(build_content);

    // Create README
    const readme_path = try std.fmt.allocPrint(allocator, "{s}/README.md", .{name});
    defer allocator.free(readme_path);

    const readme_content = try std.fmt.allocPrint(allocator,
        \\# {s}
        \\
        \\A Nexus runtime application.
        \\
        \\## Getting Started
        \\
        \\```bash
        \\# Development server with hot reload
        \\nexus dev
        \\
        \\# Build for production
        \\nexus build --release
        \\
        \\# Run tests
        \\nexus test
        \\```
        \\
        \\## Project Structure
        \\
        \\```
        \\{s}/
        \\├── src/
        \\│   └── main.zig      # Application entry point
        \\├── static/           # Static assets
        \\├── tests/            # Test files
        \\├── build.zig         # Build configuration
        \\└── README.md         # This file
        \\```
        \\
        \\## Documentation
        \\
        \\- [Nexus Documentation](https://docs.nexus.dev)
        \\- [Zig Language](https://ziglang.org/documentation/master/)
        \\
    , .{ name, name });
    defer allocator.free(readme_content);

    const readme_file = try std.fs.cwd().createFile(readme_path, .{});
    defer readme_file.close();
    try readme_file.writeAll(readme_content);

    nexus.console.info("✓ Created {s}/src/main.zig", .{name});
    nexus.console.info("✓ Created {s}/build.zig", .{name});
    nexus.console.info("✓ Created {s}/README.md", .{name});
    nexus.console.info("", .{});
    nexus.console.info("🎉 Project initialized successfully!", .{});
    nexus.console.info("", .{});
    nexus.console.info("Next steps:", .{});
    nexus.console.info("  cd {s}", .{name});
    nexus.console.info("  nexus dev", .{});
    nexus.console.info("", .{});
}

/// Run development server with hot reload
fn runDevServer(allocator: std.mem.Allocator, port: u16) !void {
    nexus.console.info("🔥 Starting development server on port {d}...", .{port});
    nexus.console.info("⚡ Hot reload enabled", .{});
    nexus.console.info("", .{});

    // Initialize hot reload manager
    var hot_reload = try nexus.hot_reload.HotReloadManager.init(allocator, "zig build");
    defer hot_reload.deinit();

    // Set the run command (will be executed after rebuild)
    const run_cmd = try std.fmt.allocPrint(allocator, "zig-out/bin/nexus serve --port {d}", .{port});
    defer allocator.free(run_cmd);
    try hot_reload.setRunCommand(run_cmd);

    // Watch directories
    const watch_dirs = [_][]const u8{ "src", "examples" };

    // Start watching (this blocks)
    nexus.console.info("👀 Watching directories: src/, examples/", .{});
    nexus.console.info("🚀 Server will restart automatically on file changes", .{});
    nexus.console.info("   http://localhost:{d}", .{port});
    nexus.console.info("", .{});

    try hot_reload.start(&watch_dirs);
}

/// Build project for production
fn buildProject(allocator: std.mem.Allocator, release: bool) !void {
    nexus.console.info("🔨 Building project...", .{});
    nexus.console.info("   Mode: {s}", .{if (release) "Release" else "Debug"});
    nexus.console.info("", .{});

    // Run zig build
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = if (release)
            &[_][]const u8{ "zig", "build", "-Doptimize=ReleaseFast" }
        else
            &[_][]const u8{ "zig", "build" },
    }) catch |err| {
        nexus.console.@"error"("Build failed: {}", .{err});
        return err;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        nexus.console.@"error"("Build failed", .{});
        nexus.console.@"error"("{s}", .{result.stderr});
        return error.BuildFailed;
    }

    nexus.console.info("✓ Build successful!", .{});
    nexus.console.info("   Output: ./zig-out/bin/", .{});
    nexus.console.info("", .{});
}

/// Deploy project to target environment
fn deployProject(allocator: std.mem.Allocator, target: []const u8) !void {
    _ = allocator;

    nexus.console.info("🚀 Deploying to: {s}", .{target});
    nexus.console.info("", .{});

    if (std.mem.eql(u8, target, "aws")) {
        nexus.console.info("Deployment targets:", .{});
        nexus.console.info("  • AWS Lambda", .{});
        nexus.console.info("  • AWS ECS", .{});
        nexus.console.info("  • AWS EC2", .{});
    } else if (std.mem.eql(u8, target, "docker")) {
        nexus.console.info("Building Docker container...", .{});
        nexus.console.info("  FROM scratch", .{});
        nexus.console.info("  COPY zig-out/bin/app /app", .{});
        nexus.console.info("  ENTRYPOINT [\"/app\"]", .{});
    } else if (std.mem.eql(u8, target, "fly")) {
        nexus.console.info("Deploying to Fly.io...", .{});
    } else {
        nexus.console.info("Deploying to: {s}", .{target});
    }

    nexus.console.info("", .{});
    nexus.console.warn("⚠ Deployment not fully implemented yet", .{});
    nexus.console.info("", .{});
    nexus.console.info("Manual deployment:", .{});
    nexus.console.info("  1. Build with: nexus build --release", .{});
    nexus.console.info("  2. Upload binary from: ./zig-out/bin/", .{});
    nexus.console.info("  3. Run on server", .{});
    nexus.console.info("", .{});
}
