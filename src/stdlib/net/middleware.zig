const std = @import("std");
const http = @import("http.zig");

/// Middleware function type
pub const MiddlewareFn = *const fn (
    req: *http.Request,
    res: *http.Response,
    next: *const fn () anyerror!void,
) anyerror!void;

/// Middleware handler
pub const Middleware = struct {
    handler: MiddlewareFn,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, handler: MiddlewareFn) Middleware {
        return Middleware{
            .handler = handler,
            .allocator = allocator,
        };
    }
};

/// Logger middleware - logs all requests
pub fn logger(req: *http.Request, res: *http.Response, next: *const fn () anyerror!void) anyerror!void {
    const start = std.time.Instant.now() catch |err| {
        std.debug.print("Warning: Could not get timestamp: {}\n", .{err});
        return next();
    };

    // Log request
    std.debug.print("[{s}] {s}\n", .{ req.method.toString(), req.path });

    // Call next middleware
    try next();

    // Log response time
    const end = std.time.Instant.now() catch start;
    const duration_ns = end.since(start);
    const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;
    std.debug.print("  -> {d} {s} ({d:.2}ms)\n", .{
        res.status_code.toInt(),
        res.status_code.toString(),
        duration_ms,
    });
}

/// CORS middleware - adds CORS headers
pub fn cors(req: *http.Request, res: *http.Response, next: *const fn () anyerror!void) anyerror!void {
    _ = req;

    // Add CORS headers
    _ = try res.setHeader("Access-Control-Allow-Origin", "*");
    _ = try res.setHeader("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS");
    _ = try res.setHeader("Access-Control-Allow-Headers", "Content-Type, Authorization");

    try next();
}

/// Compression middleware (simplified - just sets header)
pub fn compression(req: *http.Request, res: *http.Response, next: *const fn () anyerror!void) anyerror!void {
    const accept_encoding = req.getHeader("accept-encoding") orelse "";

    if (std.mem.indexOf(u8, accept_encoding, "gzip") != null) {
        _ = try res.setHeader("Content-Encoding", "gzip");
    }

    try next();
}

/// Body parser middleware - parses JSON body
pub fn bodyParser(req: *http.Request, res: *http.Response, next: *const fn () anyerror!void) anyerror!void {
    _ = res;
    const content_type = req.getHeader("content-type") orelse "";

    if (std.mem.indexOf(u8, content_type, "application/json") != null) {
        // Body is already parsed in req.body
        // Could validate JSON here
        _ = req.body;
    }

    try next();
}

/// Authentication middleware example
pub fn auth(req: *http.Request, res: *http.Response, next: *const fn () anyerror!void) anyerror!void {
    const auth_header = req.getHeader("authorization");

    if (auth_header == null) {
        res.status_code = .Unauthorized;
        try res.text("Unauthorized");
        return;
    }

    // Validate token (simplified)
    if (!std.mem.startsWith(u8, auth_header.?, "Bearer ")) {
        res.status_code = .Unauthorized;
        try res.text("Invalid authorization header");
        return;
    }

    try next();
}
