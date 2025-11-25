const std = @import("std");
const loader = @import("loader.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage();
        return error.MissingArguments;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "run")) {
        if (args.len < 3) {
            std.debug.print("❌ Error: Missing file path\n", .{});
            std.debug.print("Usage: nexus-zs run <file.zs|file.wasm>\n", .{});
            return error.MissingFilePath;
        }

        const file_path = args[2];
        const exit_code = try loader.run(allocator, file_path);
        std.process.exit(@intCast(exit_code));
    } else if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        try printUsage();
    } else if (std.mem.eql(u8, command, "version") or std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "-v")) {
        try printVersion();
    } else {
        std.debug.print("❌ Unknown command: {s}\n\n", .{command});
        try printUsage();
        return error.UnknownCommand;
    }
}

fn printUsage() !void {
    const usage =
        \\
        \\╔══════════════════════════════════════════════════════════════╗
        \\║             Nexus ZigScript Runtime                          ║
        \\╚══════════════════════════════════════════════════════════════╝
        \\
        \\USAGE:
        \\    nexus-zs <command> [options]
        \\
        \\COMMANDS:
        \\    run <file>      Run a ZigScript (.zs) or WASM (.wasm) file
        \\    help            Show this help message
        \\    version         Show version information
        \\
        \\EXAMPLES:
        \\    # Run a ZigScript source file
        \\    nexus-zs run my_app.zs
        \\
        \\    # Run a compiled WASM module
        \\    nexus-zs run my_app.wasm
        \\
        \\FEATURES:
        \\    ✨ Full ZigScript runtime support
        \\    🚀 Native Zig performance
        \\    ⚡ Async/await with event loop
        \\    🌐 HTTP client operations
        \\    📁 File system I/O
        \\    ⏱️  Timers and scheduling
        \\    📦 JSON encode/decode
        \\
        \\For more information, visit: https://github.com/you/zigscript
        \\
    ;

    std.debug.print("{s}\n", .{usage});
}

fn printVersion() !void {
    std.debug.print(
        \\Nexus ZigScript Runtime v0.1.0
        \\ZigScript: 0.1.0
        \\Nexus: 0.1.0
        \\Zig: {any}
        \\
    , .{@import("builtin").zig_version});
}
