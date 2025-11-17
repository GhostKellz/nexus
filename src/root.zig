// Nexus Runtime - Node.js reimagined in Zig + WASM
// 10x faster, 10x smaller, infinitely more powerful

const std = @import("std");

// Runtime core
pub const runtime = struct {
    pub const EventLoop = @import("runtime/event_loop.zig").EventLoop;
    pub const Timer = @import("runtime/event_loop.zig").Timer;
    pub const Task = @import("runtime/event_loop.zig").Task;
    pub const IoEvent = @import("runtime/event_loop.zig").IoEvent;
    pub const getEventLoop = @import("runtime/event_loop.zig").getEventLoop;
    pub const setEventLoop = @import("runtime/event_loop.zig").setEventLoop;
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

    // Policy
    pub const WasmPolicy = @import("wasm/policy.zig").WasmPolicy;
    pub const FsPolicy = @import("wasm/policy.zig").FsPolicy;
    pub const NetRule = @import("wasm/policy.zig").NetRule;
    pub const PolicyConfig = @import("wasm/policy.zig").PolicyConfig;

    /// Load and instantiate a WASM module
    pub fn load(allocator: std.mem.Allocator, path: []const u8) !*Module {
        var engine = Engine.init(allocator);
        return try engine.loadModule(path);
    }
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
};

// HTTP/2
pub const http2 = struct {
    pub const Server = @import("stdlib/net/http2.zig").Server;
    pub const Connection = @import("stdlib/net/http2.zig").Connection;
    pub const FrameType = @import("stdlib/net/http2.zig").FrameType;
    pub const FrameHeader = @import("stdlib/net/http2.zig").FrameHeader;
    pub const Stream = @import("stdlib/net/http2.zig").Stream;
    pub const Settings = @import("stdlib/net/http2.zig").Settings;
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

// gRPC
pub const grpc = struct {
    pub const Server = @import("stdlib/net/grpc.zig").Server;
    pub const Method = @import("stdlib/net/grpc.zig").Method;
    pub const MethodHandler = @import("stdlib/net/grpc.zig").MethodHandler;
    pub const ServiceConfig = @import("stdlib/net/grpc.zig").ServiceConfig;
    pub const Protobuf = @import("stdlib/net/grpc.zig").Protobuf;
};

// Middleware
pub const middleware = struct {
    pub const logger = @import("stdlib/net/middleware.zig").logger;
    pub const cors = @import("stdlib/net/middleware.zig").cors;
    pub const compression = @import("stdlib/net/middleware.zig").compression;
    pub const bodyParser = @import("stdlib/net/middleware.zig").bodyParser;
    pub const auth = @import("stdlib/net/middleware.zig").auth;
};

// Package management
pub const pkg = struct {
    pub const ZimClient = @import("stdlib/package/zim.zig").ZimClient;
    pub const PackageInfo = @import("stdlib/package/zim.zig").PackageInfo;
    pub const Manifest = @import("stdlib/package/zim.zig").Manifest;
};

// Database drivers
pub const db = struct {
    // PostgreSQL
    pub const PostgresConnection = @import("stdlib/db/postgres.zig").Connection;
    pub const PostgresPool = @import("stdlib/db/postgres.zig").Pool;
    pub const PostgresConfig = @import("stdlib/db/postgres.zig").ConnectionConfig;
    pub const PostgresQueryResult = @import("stdlib/db/postgres.zig").QueryResult;
    pub const PostgresRow = @import("stdlib/db/postgres.zig").Row;

    // Redis
    pub const RedisClient = @import("stdlib/db/redis.zig").Client;
    pub const RedisConfig = @import("stdlib/db/redis.zig").ConnectionConfig;
    pub const RedisValue = @import("stdlib/db/redis.zig").Value;
};

// Convenience re-exports for cleaner API
pub const EventLoop = runtime.EventLoop;
pub const Server = http.Server;
pub const File = fs.File;
pub const WebSocket = net.WebSocket;

test "nexus runtime" {
    std.testing.refAllDecls(@This());
}
