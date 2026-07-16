// Nexus — a Zig runtime library. This file is the public API surface for
// `@import("nexus")`. Pre-1.0, unstable, and Linux-only. Experimental or
// unfinished subsystems (HTTP/2, HTTP/3, QUIC, gRPC, GraphQL, ACME, the custom
// TLS transport, the ZIM package client, and the Wasmer-style layer) are
// intentionally NOT exported here; they remain in-tree and unit-tested but are
// not part of the supported surface. See docs/README.md#capability-status.

const std = @import("std");

/// Release version, sourced from `build.zig.zon` through `build_options` so the
/// library, CLI, and package metadata always report the same string.
pub const version = @import("build_options").version;

// Runtime core
pub const runtime = struct {
    pub const EventLoop = @import("runtime/event_loop.zig").EventLoop;
    pub const Timer = @import("runtime/event_loop.zig").Timer;
    pub const Task = @import("runtime/event_loop.zig").Task;
    pub const IoEvent = @import("runtime/event_loop.zig").IoEvent;
};

// Hot reload for development
pub const hot_reload = struct {
    pub const FileWatcher = @import("runtime/hot_reload.zig").FileWatcher;
    pub const HotReloadManager = @import("runtime/hot_reload.zig").HotReloadManager;
};

// Module system
pub const module = struct {
    pub const ModuleLoader = @import("module/loader.zig").ModuleLoader;
    pub const ModuleResolver = @import("module/loader.zig").ModuleResolver;
    pub const ModuleCache = @import("module/loader.zig").ModuleCache;
    pub const Module = @import("module/loader.zig").Module;
    pub const ModuleType = @import("module/loader.zig").ModuleType;
};

// WASM subsystem
pub const wasm = struct {
    pub const Engine = @import("wasm/engine.zig").Engine;
    pub const Module = @import("wasm/engine.zig").Module;
    pub const Instance = @import("wasm/engine.zig").Instance;
    pub const Memory = @import("wasm/engine.zig").Memory;
    pub const Value = @import("wasm/engine.zig").Value;
    pub const ValueType = @import("wasm/engine.zig").ValueType;
    pub const Function = @import("wasm/engine.zig").Function;

    // WASI
    pub const WasiContext = @import("wasm/wasi.zig").WasiContext;
    pub const WasiHost = @import("wasm/wasi.zig").WasiHost;
    pub const Errno = @import("wasm/wasi.zig").Errno;
    pub const Rights = @import("wasm/wasi.zig").Rights;
    pub const Fd = @import("wasm/wasi.zig").Fd;

    // Policy
    pub const WasmPolicy = @import("wasm/policy.zig").WasmPolicy;
    pub const FsPolicy = @import("wasm/policy.zig").FsPolicy;
    pub const NetRule = @import("wasm/policy.zig").NetRule;
    pub const PolicyConfig = @import("wasm/policy.zig").PolicyConfig;

    // Note: there is no `load()` convenience wrapper. A `Module` is owned by the
    // `Engine` that created it, so construct an `Engine`, call
    // `engine.loadModule(io, path)`, and `engine.deinit()` when done. (The
    // parser is unimplemented, so `loadModule` fails closed today — see
    // docs/internals/wasm-runtime.md.)
};

// File system
pub const fs = struct {
    pub const File = @import("stdlib/fs/file.zig").File;
    pub const OpenFlags = @import("stdlib/fs/file.zig").OpenFlags;
    pub const readFile = @import("stdlib/fs/file.zig").readFile;
    pub const writeFile = @import("stdlib/fs/file.zig").writeFile;
    pub const appendFile = @import("stdlib/fs/file.zig").appendFile;
    pub const exists = @import("stdlib/fs/file.zig").exists;
    pub const deleteFile = @import("stdlib/fs/file.zig").deleteFile;
    pub const copyFile = @import("stdlib/fs/file.zig").copyFile;
    pub const moveFile = @import("stdlib/fs/file.zig").moveFile;
    pub const stat = @import("stdlib/fs/file.zig").stat;
};

// Networking
pub const net = struct {
    pub const TcpServer = @import("stdlib/net/tcp.zig").TcpServer;
    pub const TcpClient = @import("stdlib/net/tcp.zig").TcpClient;
    pub const TcpConnection = @import("stdlib/net/tcp.zig").TcpConnection;

    // WebSocket
    pub const WebSocket = @import("stdlib/net/websocket.zig").WebSocket;
    pub const WebSocketServer = @import("stdlib/net/websocket.zig").WebSocketServer;
    pub const WebSocketMessage = @import("stdlib/net/websocket.zig").Message;
    pub const WebSocketOpcode = @import("stdlib/net/websocket.zig").Opcode;
    pub const WebSocketFrameHeader = @import("stdlib/net/websocket.zig").FrameHeader;
};

// HTTP
pub const http = struct {
    pub const Server = @import("stdlib/net/http.zig").Server;
    pub const ServerConfig = @import("stdlib/net/http.zig").ServerConfig;
    pub const Request = @import("stdlib/net/http.zig").Request;
    pub const Response = @import("stdlib/net/http.zig").Response;
    pub const Method = @import("stdlib/net/http.zig").Method;
    pub const StatusCode = @import("stdlib/net/http.zig").StatusCode;
    pub const Headers = @import("stdlib/net/http.zig").Headers;
    pub const CookieOptions = @import("stdlib/net/http.zig").CookieOptions;

    // HTTP Client
    pub const Client = @import("stdlib/net/http_client.zig").Client;
};

// Static files
pub const static = struct {
    pub const serveFile = @import("stdlib/net/static.zig").serveFile;
    pub const staticHandler = @import("stdlib/net/static.zig").staticHandler;
    pub const getMimeType = @import("stdlib/net/static.zig").getMimeType;
};

// Streams
pub const stream = struct {
    pub const Readable = @import("stdlib/stream/stream.zig").Readable;
    pub const Writable = @import("stdlib/stream/stream.zig").Writable;
    pub const Transform = @import("stdlib/stream/stream.zig").Transform;
    pub const createReadStream = @import("stdlib/stream/stream.zig").createReadStream;
    pub const createWriteStream = @import("stdlib/stream/stream.zig").createWriteStream;
};

// Console
pub const console = struct {
    pub const log = @import("stdlib/console/console.zig").log;
    pub const debug = @import("stdlib/console/console.zig").debug;
    pub const info = @import("stdlib/console/console.zig").info;
    pub const warn = @import("stdlib/console/console.zig").warn;
    pub const @"error" = @import("stdlib/console/console.zig").@"error";
    pub const print = @import("stdlib/console/console.zig").print;
    pub const println = @import("stdlib/console/console.zig").println;
    pub const printError = @import("stdlib/console/console.zig").printError;
    pub const clear = @import("stdlib/console/console.zig").clear;
};

// Middleware
pub const middleware = struct {
    pub const logger = @import("stdlib/net/middleware.zig").logger;
    pub const cors = @import("stdlib/net/middleware.zig").cors;
    pub const compression = @import("stdlib/net/middleware.zig").compression;
    pub const bodyParser = @import("stdlib/net/middleware.zig").bodyParser;
    pub const auth = @import("stdlib/net/middleware.zig").auth;
};

// Database drivers (PostgreSQL, Redis) are intentionally NOT exported. They are
// experimental scaffolding with multiple removed-std-API calls under the pinned
// toolchain, so they are gated out of the public surface, the build, and the
// test tree until the ≥v0.2 migration lands. See NX-011 in
// docs/advisories/accepted.md and the absence test below.

// Convenience re-exports for cleaner API
pub const EventLoop = runtime.EventLoop;
pub const Server = http.Server;
pub const File = fs.File;
pub const WebSocket = net.WebSocket;

// Recursively reference every declaration reachable from a container so that
// the *bodies* of public methods are semantically analyzed, not just the type
// aliases. `std.testing.refAllDecls` is shallow — it references each top-level
// decl but never descends into a namespace/struct's own methods — so a
// removed-std-API regression in an otherwise-unreached public method (e.g.
// `ModuleLoader.loadWasm`, `WebSocketServer.accept`, `WasiHost.clockTimeGet`)
// slips through a green build. Descending forces the whole public surface to
// compile. (Zig memoizes comptime calls per type, so self-referential types
// terminate.)
fn refAllDeclsRecursive(comptime T: type) void {
    if (!@import("builtin").is_test) return;
    inline for (comptime std.meta.declarations(T)) |decl_name| {
        const decl = @field(T, decl_name);
        if (@TypeOf(decl) == type) {
            switch (@typeInfo(decl)) {
                .@"struct", .@"enum", .@"union", .@"opaque" => refAllDeclsRecursive(decl),
                else => {},
            }
        }
        _ = &@field(T, decl_name);
    }
}

test "nexus runtime - public surface compiles" {
    refAllDeclsRecursive(@This());
}

// Contract test: the experimental/unfinished subsystems listed in the file
// header must stay OUT of the default public surface. They remain in-tree and
// unit-tested (see the `test {}` aggregate below), but exporting them would be
// a support promise this release does not make. Assert their absence directly
// so a future accidental re-export fails the test suite instead of shipping.
test "experimental subsystems are not part of the default public surface" {
    const S = @This();
    inline for (.{
        "http2", "http3", "quic",    "tls",
        "acme",  "grpc",  "graphql", "pkg",
        "otel",  "db",
    }) |name| {
        try std.testing.expect(!@hasDecl(S, name));
    }
    // The Wasmer-style layer and the ownership-broken `load` wrapper are gone
    // from the `wasm` namespace; only the Engine/WASI/policy surface remains.
    try std.testing.expect(!@hasDecl(wasm, "wasmer"));
    try std.testing.expect(!@hasDecl(wasm, "load"));
}

// Aggregate every internal source file so `zig build test` compiles and runs
// the complete unit-test tree. `refAllDecls` above only references the aliased
// types re-exported here, which does not pull in the `test` blocks that live in
// the underlying files. Importing each file as a container does. Files that
// depend on the public `nexus` module (e.g. src/main.zig) are excluded because
// this module cannot import itself; they are covered by their own test
// executables.
test {
    // Runtime core
    _ = @import("runtime/event_loop.zig");
    _ = @import("runtime/scheduler.zig");
    _ = @import("runtime/hot_reload.zig");

    // Module system
    _ = @import("module/loader.zig");

    // WASM subsystem
    _ = @import("wasm/engine.zig");
    _ = @import("wasm/interpreter.zig");
    _ = @import("wasm/wasi.zig");
    _ = @import("wasm/wasmer.zig");
    _ = @import("wasm/policy.zig");

    // File system
    _ = @import("stdlib/fs/file.zig");

    // Networking + protocols
    _ = @import("stdlib/net/tcp.zig");
    _ = @import("stdlib/net/websocket.zig");
    _ = @import("stdlib/net/http.zig");
    _ = @import("stdlib/net/http_client.zig");
    _ = @import("stdlib/net/http_parser.zig");
    _ = @import("stdlib/net/http2.zig");
    _ = @import("stdlib/net/http3.zig");
    _ = @import("stdlib/net/hpack.zig");
    _ = @import("stdlib/net/huffman.zig");
    _ = @import("stdlib/net/quic.zig");
    _ = @import("stdlib/net/tls.zig");
    _ = @import("stdlib/net/acme.zig");
    _ = @import("stdlib/net/static.zig");
    _ = @import("stdlib/net/middleware.zig");
    _ = @import("stdlib/net/grpc.zig");
    _ = @import("stdlib/net/graphql.zig");

    // Streams, console, telemetry
    _ = @import("stdlib/stream/stream.zig");
    _ = @import("stdlib/console/console.zig");
    _ = @import("stdlib/telemetry/otel.zig");

    // Package management
    _ = @import("stdlib/package/zim.zig");

    // Database drivers (postgres.zig, redis.zig) are deliberately excluded: they
    // do not compile against the pinned toolchain and are gated out of the
    // release (NX-011). Re-add them here once the ≥v0.2 migration restores them.
}
