const std = @import("std");
const http = @import("http.zig");

/// Middleware function type. Canonical definition lives in `http.zig`; the
/// `next` parameter is the running `Chain`, and a middleware advances the
/// pipeline by calling `next.next()` (see `http.Chain`).
pub const MiddlewareFn = http.MiddlewareFn;

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
pub fn logger(req: *http.Request, res: *http.Response, next: *http.Chain) anyerror!void {
    // Use monotonic clock for timing (suitable for measuring elapsed time)
    const start = std.Io.Timestamp.now(res.io, .awake);

    // Log request
    std.debug.print("[{s}] {s}\n", .{ req.method.toString(), req.path });

    // Call next middleware
    try next.next();

    // Log response time
    const end = std.Io.Timestamp.now(res.io, .awake);
    const duration = start.durationTo(end);
    const duration_ms = @as(f64, @floatFromInt(duration.nanoseconds)) / 1_000_000.0;
    std.debug.print("  -> {d} {s} ({d:.2}ms)\n", .{
        res.status_code.toInt(),
        res.status_code.toString(),
        duration_ms,
    });
}

/// CORS middleware - adds CORS headers
pub fn cors(req: *http.Request, res: *http.Response, next: *http.Chain) anyerror!void {
    _ = req;

    // Add CORS headers
    _ = try res.setHeader("Access-Control-Allow-Origin", "*");
    _ = try res.setHeader("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS");
    _ = try res.setHeader("Access-Control-Allow-Headers", "Content-Type, Authorization");

    try next.next();
}

/// Largest JSON request body `bodyParser` will admit. A request that exceeds it
/// is rejected with 413 before any parse work, bounding the memory a single
/// request can force the server to touch.
pub const max_json_body = 1 << 20; // 1 MiB

/// Application-supplied bearer-token verifier for `auth`. It receives the raw
/// token (the text after `Bearer `) and returns true to admit the request.
///
/// It is deliberately null by default so `auth` fails closed: with no verifier
/// installed every request is rejected rather than silently admitted. An app
/// opts in by assigning a predicate, e.g. `middleware.token_verifier = &check;`.
pub var token_verifier: ?*const fn (token: []const u8) bool = null;

/// Compression middleware — request gzip for the response body.
///
/// This only records intent (`res.wants_gzip`); the actual compression happens
/// in `Response.send`, where the body bytes exist. `send` compresses and sets
/// `Content-Encoding: gzip` only when the payload is genuinely gzipped, so this
/// middleware can never leave the header claiming an encoding that was not
/// applied.
pub fn compression(req: *http.Request, res: *http.Response, next: *http.Chain) anyerror!void {
    const accept_encoding = req.getHeader("accept-encoding") orelse "";

    if (std.mem.indexOf(u8, accept_encoding, "gzip") != null) {
        res.wants_gzip = true;
    }

    try next.next();
}

/// Body parser middleware — enforce a size cap and validate JSON bodies.
///
/// For `Content-Type: application/json` it rejects an oversized body with 413
/// and a syntactically invalid body with 400, short-circuiting the chain in
/// both cases so downstream handlers only ever see well-formed, bounded JSON.
/// Non-JSON requests pass straight through.
pub fn bodyParser(req: *http.Request, res: *http.Response, next: *http.Chain) anyerror!void {
    const content_type = req.getHeader("content-type") orelse "";

    if (std.mem.indexOf(u8, content_type, "application/json") != null) {
        if (req.body.len > max_json_body) {
            res.status_code = .PayloadTooLarge;
            try res.text("Payload Too Large");
            return;
        }

        // Reject malformed JSON up front rather than letting each handler
        // rediscover the parse error. `validate` scans without materialising a
        // value, so it costs no lasting allocation.
        if (!try std.json.validate(req.allocator, req.body)) {
            res.status_code = .BadRequest;
            try res.text("Invalid JSON body");
            return;
        }
    }

    try next.next();
}

/// Authentication middleware — require a bearer token accepted by the
/// application-supplied `token_verifier`.
///
/// Fails closed: a missing/malformed `Authorization` header, an unconfigured
/// verifier, or a token the verifier rejects all yield 401 and stop the chain.
/// Only a token the application explicitly accepts admits the request.
pub fn auth(req: *http.Request, res: *http.Response, next: *http.Chain) anyerror!void {
    const auth_header = req.getHeader("authorization") orelse {
        res.status_code = .Unauthorized;
        try res.text("Unauthorized");
        return;
    };

    if (!std.mem.startsWith(u8, auth_header, "Bearer ")) {
        res.status_code = .Unauthorized;
        try res.text("Invalid authorization header");
        return;
    }
    const token = auth_header["Bearer ".len..];

    // No verifier installed → nothing can be authenticated → reject. Admitting
    // requests here would turn "auth" into a no-op that only looks protective.
    const verify = token_verifier orelse {
        res.status_code = .Unauthorized;
        try res.text("Unauthorized");
        return;
    };

    if (!verify(token)) {
        res.status_code = .Unauthorized;
        try res.text("Unauthorized");
        return;
    }

    try next.next();
}
