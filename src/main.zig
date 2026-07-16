const std = @import("std");
const nexus = @import("nexus");
const scaffold = @import("scaffold");
const Dir = std.Io.Dir;
const Io = std.Io;

/// Runtime start timestamp for uptime tracking
var runtime_start_time: u64 = 0;
var runtime_io: ?Io = null;

/// Get current timestamp in nanoseconds
fn getCurrentTimeNs(io: Io) u64 {
    const ts = Io.Clock.real.now(io);
    // ts.nanoseconds is i96, convert to u64 for uptime tracking
    if (ts.nanoseconds < 0) return 0;
    return @intCast(@min(ts.nanoseconds, std.math.maxInt(u64)));
}

/// Get uptime in seconds since runtime started
fn getUptimeSeconds(io: Io) u64 {
    if (runtime_start_time == 0) return 0;
    const now = getCurrentTimeNs(io);
    if (now < runtime_start_time) return 0;
    const diff = now - runtime_start_time;
    return diff / 1_000_000_000;
}

pub fn main(init: std.process.Init) !void {
    // Initialize uptime tracking
    runtime_io = init.io;
    runtime_start_time = getCurrentTimeNs(init.io);
    const allocator = init.gpa;

    // Welcome message
    nexus.console.info("⚡ Nexus Runtime v{s}", .{nexus.version});
    nexus.console.info("", .{});

    // Get command line arguments
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 2) {
        printUsage();
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "init")) {
        const project_name = if (args.len >= 3) args[2] else "my-nexus-app";
        try initProject(allocator, init.io, project_name);
    } else if (std.mem.eql(u8, command, "run")) {
        if (args.len < 3) {
            nexus.console.@"error"("Usage: nexus run <file.zig>", .{});
            return error.MissingArgument;
        }

        const file_path = args[2];
        nexus.console.info("Running: {s}", .{file_path});

        try runFile(allocator, init.io, file_path);
    } else if (std.mem.eql(u8, command, "dev")) {
        const port: u16 = if (args.len >= 3) blk: {
            break :blk std.fmt.parseInt(u16, args[2], 10) catch 3000;
        } else 3000;
        try runDevServer(allocator, init.io, port);
    } else if (std.mem.eql(u8, command, "build")) {
        const release = for (args) |arg| {
            if (std.mem.eql(u8, arg, "--release")) break true;
        } else false;
        try buildProject(allocator, init.io, release);
    } else if (std.mem.eql(u8, command, "deploy")) {
        const target = if (args.len >= 3) args[2] else "production";
        try deployProject(target);
    } else if (std.mem.eql(u8, command, "serve")) {
        try runHttpServer(allocator);
    } else if (std.mem.eql(u8, command, "test")) {
        // No test runner exists. The prior behaviour printed a green
        // "✓ Test runner not yet implemented" and exited 0, so scripts and CI
        // read a success where nothing ran. Report the truth and exit nonzero.
        nexus.console.@"error"("'nexus test' is not implemented; run `zig build test`", .{});
        return error.UnsupportedCommand;
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
    nexus.console.println("  dev [port]          Start the dev server with hot reload (default 3000)", .{});
    nexus.console.println("  build [--release]   Build the project with `zig build`", .{});
    nexus.console.println("  run <file.zig>      Run a Zig file (.wasm/.wat fail closed)", .{});
    nexus.console.println("  serve               Start a built-in demo HTTP server on port 3000", .{});
    nexus.console.println("  test                Not implemented; use `zig build test` (fails closed)", .{});
    nexus.console.println("  deploy              Not implemented; ship ./zig-out/bin/ yourself (fails closed)", .{});
    nexus.console.println("  version             Print version information", .{});
    nexus.console.println("  help                Print this help message", .{});
    nexus.console.println("", .{});
    nexus.console.println("Examples:", .{});
    nexus.console.println("  nexus init my-app       # Create new project", .{});
    nexus.console.println("  nexus dev 8080          # Dev server on port 8080", .{});
    nexus.console.println("  nexus build --release   # Production build", .{});
    nexus.console.println("  nexus run app.zig       # Run a Zig file", .{});
    nexus.console.println("", .{});
}

fn printVersion() void {
    nexus.console.println("", .{});
    nexus.console.println("Nexus Runtime v{s}", .{nexus.version});
    nexus.console.println("Linux-only, pre-1.0 and unstable.", .{});
    nexus.console.println("", .{});
    // Per-capability status is tracked in the docs so this output cannot drift
    // out of sync with what actually works.
    nexus.console.println("Capability status: docs/README.md#capability-status", .{});
    nexus.console.println("", .{});
}

/// Run a file based on its extension
fn runFile(allocator: std.mem.Allocator, io: Io, file_path: []const u8) !void {
    // Check file exists
    Dir.cwd().access(io, file_path, .{}) catch |err| {
        nexus.console.@"error"("Cannot access file: {s} ({s})", .{ file_path, @errorName(err) });
        return error.FileNotFound;
    };

    // Determine file type from extension
    const extension = Dir.path.extension(file_path);

    if (std.mem.eql(u8, extension, ".wasm")) {
        try runWasmFile(allocator, io, file_path);
    } else if (std.mem.eql(u8, extension, ".zig")) {
        try runZigFile(allocator, io, file_path);
    } else if (std.mem.eql(u8, extension, ".wat")) {
        try runWatFile(allocator, io, file_path);
    } else {
        nexus.console.@"error"("Unsupported file type: {s}", .{extension});
        nexus.console.info("Supported: .wasm, .wat, .zig", .{});
        return error.UnsupportedFileType;
    }
}

/// Run a WASM file
fn runWasmFile(allocator: std.mem.Allocator, io: Io, file_path: []const u8) !void {
    nexus.console.info("Loading WASM module...", .{});

    // Read WASM binary
    const wasm_bytes = Dir.cwd().readFileAlloc(io, file_path, allocator, Io.Limit.limited(50 * 1024 * 1024)) catch |err| {
        nexus.console.@"error"("Failed to read file: {s}", .{@errorName(err)});
        return err;
    };
    defer allocator.free(wasm_bytes);

    // Validate WASM magic
    if (wasm_bytes.len < 8 or !std.mem.eql(u8, wasm_bytes[0..4], "\x00asm")) {
        nexus.console.@"error"("Invalid WASM file", .{});
        return error.InvalidWasmFile;
    }

    // The bytes are a syntactically-plausible WASM module (magic + version),
    // but the engine has no binary parser: `Module.instantiate` ignores the
    // bytes and fabricates an empty instance with a hard-coded one-page memory,
    // so no functions, memories, or WASI imports from the module actually exist.
    // The prior code went on to print "Initializing WASI environment...",
    // probe an always-empty instance for `_start`/`main`, and exit with a
    // confusing `NoEntryPoint`, implying the module had merely lacked an entry
    // point rather than never being parsed at all. Fail closed with the real
    // reason: module execution is unsupported until the loader/interpreter can
    // parse and instantiate a module. (Phase 5 goal, item "nexus run".)
    nexus.console.@"error"("WASM execution is unsupported: the engine cannot yet parse and instantiate a module ({d} bytes read)", .{wasm_bytes.len});
    return error.UnsupportedWasmExecution;
}

/// Run a WAT (WebAssembly Text) file
fn runWatFile(allocator: std.mem.Allocator, io: Io, file_path: []const u8) !void {
    nexus.console.info("Loading WAT module...", .{});
    nexus.console.info("Note: WAT->WASM conversion requires external tools", .{});

    // Read WAT file
    const wat_source = Dir.cwd().readFileAlloc(io, file_path, allocator, Io.Limit.limited(10 * 1024 * 1024)) catch |err| {
        nexus.console.@"error"("Failed to read file: {s}", .{@errorName(err)});
        return err;
    };
    defer allocator.free(wat_source);

    // Reading the text is not running it: there is no in-tree WAT assembler, so
    // the module is never converted to WASM or executed. The prior code printed
    // a green "✓ WAT source loaded" and returned success, masking that nothing
    // ran. Fail closed with a precise, nonzero error instead.
    nexus.console.@"error"("WAT execution is unsupported: no in-tree wat2wasm assembler ({d} bytes read)", .{wat_source.len});
    return error.UnsupportedFileType;
}

/// Run a Zig file (compile and execute)
fn runZigFile(allocator: std.mem.Allocator, io: Io, file_path: []const u8) !void {
    _ = allocator;
    nexus.console.info("Compiling Zig file...", .{});

    // Use zig run to compile and execute
    var child = std.process.spawn(io, .{
        .argv = &[_][]const u8{
            "zig", "run", file_path,
        },
    }) catch |err| {
        nexus.console.@"error"("Failed to spawn compiler: {s}", .{@errorName(err)});
        nexus.console.info("Make sure 'zig' is in your PATH", .{});
        return err;
    };

    const result = child.wait(io) catch |err| {
        nexus.console.@"error"("Compilation failed: {s}", .{@errorName(err)});
        return err;
    };

    switch (result) {
        .exited => |code| {
            if (code != 0) {
                nexus.console.@"error"("Process exited with code {d}", .{code});
                return error.ExecutionFailed;
            }
        },
        .signal => |sig| {
            nexus.console.@"error"("Process killed by signal {d}", .{@intFromEnum(sig)});
            return error.ExecutionFailed;
        },
        else => {
            nexus.console.@"error"("Process terminated abnormally", .{});
            return error.ExecutionFailed;
        },
    }

    nexus.console.info("✓ Execution complete", .{});
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
        \\        <p class="tagline">A Zig runtime for HTTP services (pre-1.0, Linux-only).</p>
        \\
        \\        <h2>✨ Features</h2>
        \\        <div class="feature-grid">
        \\            <div class="feature">Event loop (epoll)</div>
        \\            <div class="feature">HTTP/1.1 server</div>
        \\            <div class="feature">WebSocket support</div>
        \\            <div class="feature">File system ops</div>
        \\            <div class="feature">TCP networking</div>
        \\            <div class="feature">Streams API</div>
        \\            <div class="feature">Module system</div>
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
        \\            <a href="/api/status">API Status</a>
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
        .runtime = "Nexus v" ++ nexus.version,
        .language = "Zig",
        .status = "running",
        .uptime = if (runtime_io) |io| getUptimeSeconds(io) else 0,
        .features = .{
            "event_loop",
            "http_server",
            "websocket",
            "streams",
            "tcp",
            "file_system",
            "module_system",
        },
    });
}

/// Initialize a new Nexus project.
///
/// The project files are produced by the shared `scaffold` generator so that
/// the `nexus init` output and the generated-project contract test stay byte
/// identical. The CLI wires the conventional sibling dependency path
/// (`../nexus`); the generated `build.zig.zon` documents how to adjust it.
fn initProject(allocator: std.mem.Allocator, io: std.Io, name: []const u8) !void {
    nexus.console.info("🚀 Creating new Nexus project: {s}", .{name});

    try scaffold.create(std.Io.Dir.cwd(), allocator, io, name, "../nexus");

    nexus.console.info("✓ Created {s}/src/main.zig", .{name});
    nexus.console.info("✓ Created {s}/build.zig", .{name});
    nexus.console.info("✓ Created {s}/build.zig.zon", .{name});
    nexus.console.info("✓ Created {s}/README.md", .{name});
    nexus.console.info("", .{});
    nexus.console.info("🎉 Project initialized successfully!", .{});
    nexus.console.info("", .{});
    nexus.console.info("Next steps:", .{});
    nexus.console.info("  cd {s}", .{name});
    nexus.console.info("  # edit build.zig.zon so .nexus .path points at your Nexus checkout", .{});
    nexus.console.info("  zig build run", .{});
    nexus.console.info("", .{});
}

/// Run development server with hot reload
fn runDevServer(allocator: std.mem.Allocator, io: std.Io, port: u16) !void {
    nexus.console.info("🔥 Starting development server on port {d}...", .{port});
    nexus.console.info("⚡ Hot reload enabled", .{});
    nexus.console.info("", .{});

    // Initialize hot reload manager
    var hot_reload = try nexus.hot_reload.HotReloadManager.init(allocator, io, "zig build");
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
fn buildProject(allocator: std.mem.Allocator, io: std.Io, release: bool) !void {
    nexus.console.info("🔨 Building project...", .{});
    nexus.console.info("   Mode: {s}", .{if (release) "Release" else "Debug"});
    nexus.console.info("", .{});

    // Run zig build
    const result = std.process.run(allocator, io, .{
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

    if (result.term != .exited or result.term.exited != 0) {
        nexus.console.@"error"("Build failed", .{});
        nexus.console.@"error"("{s}", .{result.stderr});
        return error.BuildFailed;
    }

    nexus.console.info("✓ Build successful!", .{});
    nexus.console.info("   Output: ./zig-out/bin/", .{});
    nexus.console.info("", .{});
}

/// Deployment automation is not implemented. The prior body printed a fake
/// target menu (AWS/Docker/Fly) and a success message while doing nothing, so a
/// caller reading the exit code saw a deploy that never happened as success.
/// Fail closed and point at the real manual path instead.
fn deployProject(target: []const u8) !void {
    nexus.console.@"error"("'nexus deploy' is not implemented (target: {s})", .{target});
    nexus.console.info("Build with `nexus build --release`, then ship ./zig-out/bin/ yourself.", .{});
    return error.UnsupportedCommand;
}
