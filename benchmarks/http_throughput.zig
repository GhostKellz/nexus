/// HTTP Throughput Benchmark
/// Measures requests per second for simple HTTP responses
///
/// Run: zig build-exe -OReleaseFast benchmarks/http_throughput.zig && ./http_throughput
///
/// Then test with:
///   wrk -t4 -c100 -d30s http://localhost:3000/
///   ab -n 100000 -c 100 http://localhost:3000/

const std = @import("std");
const nexus = @import("nexus");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    nexus.console.info("🔥 HTTP Throughput Benchmark Server", .{});
    nexus.console.info("", .{});
    nexus.console.info("Server running on http://localhost:3000", .{});
    nexus.console.info("", .{});
    nexus.console.info("Test with:", .{});
    nexus.console.info("  wrk -t4 -c100 -d30s http://localhost:3000/plaintext", .{});
    nexus.console.info("  wrk -t4 -c100 -d30s http://localhost:3000/json", .{});
    nexus.console.info("  ab -n 100000 -c 100 http://localhost:3000/plaintext", .{});
    nexus.console.info("", .{});
    nexus.console.info("Compare against Node.js/Deno/Bun for same endpoints!", .{});
    nexus.console.info("", .{});

    var server = try nexus.http.Server.init(allocator, .{
        .port = 3000,
        .host = "0.0.0.0",
    });
    defer server.deinit();

    // Plaintext response (minimal overhead)
    try server.get("/plaintext", struct {
        fn handler(req: *nexus.http.Request, res: *nexus.http.Response) !void {
            _ = req;
            try res.text("Hello, World!");
        }
    }.handler);

    // JSON response
    try server.get("/json", struct {
        fn handler(req: *nexus.http.Request, res: *nexus.http.Response) !void {
            _ = req;
            try res.json(.{
                .message = "Hello, World!",
                .timestamp = std.time.timestamp(),
                .version = "nexus-0.3.0",
            });
        }
    }.handler);

    // Database simulation (no actual DB, just CPU work)
    try server.get("/db", struct {
        fn handler(req: *nexus.http.Request, res: *nexus.http.Response) !void {
            _ = req;

            // Simulate DB query with some CPU work
            var sum: u64 = 0;
            var i: u64 = 0;
            while (i < 1000) : (i += 1) {
                sum += i * i;
            }

            try res.json(.{
                .id = 42,
                .name = "Benchmark User",
                .email = "benchmark@nexus.runtime",
                .result = sum,
            });
        }
    }.handler);

    // Info endpoint showing benchmark tips
    try server.get("/", struct {
        fn handler(req: *nexus.http.Request, res: *nexus.http.Response) !void {
            _ = req;
            try res.html(
                \\<!DOCTYPE html>
                \\<html>
                \\<head><title>Nexus HTTP Benchmark</title></head>
                \\<body style="font-family: monospace; max-width: 800px; margin: 50px auto;">
                \\    <h1>🔥 Nexus HTTP Throughput Benchmark</h1>
                \\    <h2>Endpoints:</h2>
                \\    <ul>
                \\        <li><a href="/plaintext">/plaintext</a> - Minimal plaintext response</li>
                \\        <li><a href="/json">/json</a> - JSON serialization</li>
                \\        <li><a href="/db">/db</a> - Simulated database query</li>
                \\    </ul>
                \\    <h2>Benchmark Commands:</h2>
                \\    <pre>
                \\# Using wrk (recommended)
                \\wrk -t4 -c100 -d30s http://localhost:3000/plaintext
                \\wrk -t4 -c100 -d30s http://localhost:3000/json
                \\
                \\# Using Apache Bench
                \\ab -n 100000 -c 100 http://localhost:3000/plaintext
                \\
                \\# Using bombardier (very fast)
                \\bombardier -c 100 -d 30s http://localhost:3000/plaintext
                \\    </pre>
                \\    <h2>Expected Results:</h2>
                \\    <p><strong>Nexus should achieve:</strong></p>
                \\    <ul>
                \\        <li>150,000+ req/s for /plaintext (single-threaded)</li>
                \\        <li>100,000+ req/s for /json</li>
                \\        <li>80,000+ req/s for /db</li>
                \\    </ul>
                \\    <p><em>Compare these numbers against Node.js, Deno, and Bun!</em></p>
                \\</body>
                \\</html>
            );
        }
    }.handler);

    try server.listen();
}
