//! Project scaffolding for `nexus init`. Kept separate from the CLI so the
//! generated-project contract test can drive the exact same generator and point
//! the `nexus` dependency at a real package checkout instead of the default
//! sibling path.

const std = @import("std");
const build_options = @import("build_options");

const Dir = std.Io.Dir;
const Io = std.Io;

/// Generate a new Nexus application under `base_dir/name`.
///
/// `nexus_dependency_path` is written verbatim into the generated
/// `build.zig.zon` as the path to the `nexus` package. The CLI passes the
/// conventional sibling path (`../nexus`); the contract test passes an absolute
/// path to the package under test so the generated project actually builds.
pub fn create(
    base_dir: Dir,
    allocator: std.mem.Allocator,
    io: Io,
    name: []const u8,
    nexus_dependency_path: []const u8,
) !void {
    // Project root and the standard subdirectories.
    try makeDir(base_dir, io, name);
    inline for (.{ "src", "static", "tests" }) |sub| {
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ name, sub });
        defer allocator.free(path);
        try makeDir(base_dir, io, path);
    }

    // src/main.zig — a minimal server using only the supported public API
    // (`server.route`, `server.use`, `res.html`, `res.json`).
    try writeChild(base_dir, io, allocator, name, "src/main.zig", main_zig);

    // build.zig — current Zig build API; consumes `nexus` as a package
    // dependency so the module's own `build_options` (version, gates) come
    // along automatically.
    const build_zig = try std.fmt.allocPrint(allocator, build_zig_fmt, .{name});
    defer allocator.free(build_zig);
    try writeChild(base_dir, io, allocator, name, "build.zig", build_zig);

    // build.zig.zon — declares the nexus dependency and the package identity.
    const zon_name = try sanitizeName(allocator, name);
    defer allocator.free(zon_name);
    const build_zon = try std.fmt.allocPrint(allocator, build_zon_fmt, .{
        zon_name,
        try generateFingerprint(io, zon_name),
        build_options.min_zig_version,
        nexus_dependency_path,
    });
    defer allocator.free(build_zon);
    try writeChild(base_dir, io, allocator, name, "build.zig.zon", build_zon);

    // README.md — commands that match the shipping CLI and `zig build`.
    const readme = try std.fmt.allocPrint(allocator, readme_fmt, .{ name, name });
    defer allocator.free(readme);
    try writeChild(base_dir, io, allocator, name, "README.md", readme);
}

fn makeDir(base_dir: Dir, io: Io, path: []const u8) !void {
    base_dir.createDir(io, path, .default_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
}

fn writeChild(
    base_dir: Dir,
    io: Io,
    allocator: std.mem.Allocator,
    name: []const u8,
    rel: []const u8,
    data: []const u8,
) !void {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ name, rel });
    defer allocator.free(path);
    try base_dir.writeFile(io, .{ .sub_path = path, .data = data });
}

/// Reduce an arbitrary project name to a valid `build.zig.zon` enum-literal
/// identifier: ASCII alphanumerics and underscores, never leading with a digit.
fn sanitizeName(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '_';
        try out.append(allocator, if (ok) c else '_');
    }
    if (out.items.len == 0 or (out.items[0] >= '0' and out.items[0] <= '9')) {
        try out.insert(allocator, 0, '_');
    }
    return out.toOwnedSlice(allocator);
}

/// A per-package identity value matching Zig's `build.zig.zon` fingerprint
/// contract: the low 32 bits are a random package id (Zig reserves 0 and
/// 0xffffffff, so keep the id out of that range) and the high 32 bits are the
/// CRC32 of the package name, which the compiler recomputes and validates.
/// Randomness comes from the pinned `std.Io` model (`io.randomSecure`) like the
/// rest of the runtime rather than the global `std.crypto.random`.
fn generateFingerprint(io: Io, name: []const u8) !u64 {
    var raw: [4]u8 = undefined;
    try io.randomSecure(&raw);
    var id: u32 = std.mem.readInt(u32, &raw, .little);
    while (id == 0x0000_0000 or id == 0xffff_ffff) {
        try io.randomSecure(&raw);
        id = std.mem.readInt(u32, &raw, .little);
    }
    const checksum: u32 = std.hash.Crc32.hash(name);
    return (@as(u64, checksum) << 32) | id;
}

const main_zig =
    \\const std = @import("std");
    \\const nexus = @import("nexus");
    \\
    \\pub fn main(init: std.process.Init) !void {
    \\    const allocator = init.gpa;
    \\
    \\    // Optional first argument overrides the listen port (default 3000).
    \\    const args = try init.minimal.args.toSlice(init.arena.allocator());
    \\    const port: u16 = if (args.len >= 2)
    \\        std.fmt.parseInt(u16, args[1], 10) catch 3000
    \\    else
    \\        3000;
    \\
    \\    // Create the HTTP server.
    \\    var server = try nexus.http.Server.init(allocator, .{
    \\        .port = port,
    \\        .host = "0.0.0.0",
    \\    });
    \\    defer server.deinit();
    \\
    \\    // Middleware runs before matching routes.
    \\    try server.use(nexus.middleware.logger);
    \\
    \\    // Routes take an HTTP method, a path, and a handler.
    \\    try server.route("GET", "/", handleHome);
    \\    try server.route("GET", "/api/hello", handleHello);
    \\
    \\    nexus.console.log("Server running on http://localhost:{d}", .{port});
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

const build_zig_fmt =
    \\const std = @import("std");
    \\
    \\pub fn build(b: *std.Build) void {{
    \\    const target = b.standardTargetOptions(.{{}});
    \\    const optimize = b.standardOptimizeOption(.{{}});
    \\
    \\    // The `nexus` package is resolved from build.zig.zon.
    \\    const nexus_dep = b.dependency("nexus", .{{
    \\        .target = target,
    \\        .optimize = optimize,
    \\    }});
    \\
    \\    const exe = b.addExecutable(.{{
    \\        .name = "{s}",
    \\        .root_module = b.createModule(.{{
    \\            .root_source_file = b.path("src/main.zig"),
    \\            .target = target,
    \\            .optimize = optimize,
    \\            .imports = &.{{
    \\                .{{ .name = "nexus", .module = nexus_dep.module("nexus") }},
    \\            }},
    \\        }}),
    \\    }});
    \\    b.installArtifact(exe);
    \\
    \\    const run_cmd = b.addRunArtifact(exe);
    \\    run_cmd.step.dependOn(b.getInstallStep());
    \\    run_cmd.addPassthruArgs();
    \\
    \\    const run_step = b.step("run", "Run the app");
    \\    run_step.dependOn(&run_cmd.step);
    \\}}
    \\
;

const build_zon_fmt =
    \\.{{
    \\    .name = .{s},
    \\    .version = "0.0.0",
    \\    .fingerprint = 0x{x}, // Generated once; do not change.
    \\    .minimum_zig_version = "{s}",
    \\    .dependencies = .{{
    \\        .nexus = .{{ .path = "{s}" }},
    \\    }},
    \\    .paths = .{{
    \\        "build.zig",
    \\        "build.zig.zon",
    \\        "src",
    \\    }},
    \\}}
    \\
;

const readme_fmt =
    \\# {s}
    \\
    \\A Nexus runtime application.
    \\
    \\## Requirements
    \\
    \\This project depends on the `nexus` package. Edit `build.zig.zon` so the
    \\`.nexus` dependency `.path` points at your Nexus checkout (the default
    \\assumes a sibling `../nexus` directory).
    \\
    \\## Commands
    \\
    \\```bash
    \\# Build the app
    \\zig build
    \\
    \\# Build and run it (serves on http://localhost:3000)
    \\zig build run
    \\
    \\# Run tests
    \\zig build test
    \\```
    \\
    \\## Project structure
    \\
    \\```
    \\{s}/
    \\├── src/
    \\│   └── main.zig      # Application entry point
    \\├── static/           # Static assets
    \\├── tests/            # Test files
    \\├── build.zig         # Build configuration
    \\├── build.zig.zon     # Package manifest and dependencies
    \\└── README.md         # This file
    \\```
    \\
;
