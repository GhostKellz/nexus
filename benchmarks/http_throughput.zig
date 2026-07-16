/// HTTP load-test target server.
///
/// This is NOT a measuring driver: it does not time itself or emit any
/// throughput numbers. It stands up a small Nexus HTTP server with a few
/// representative endpoints (plaintext, JSON, CPU-bound JSON) so an external
/// load generator can drive it. Point wrk/ab/bombardier at it and read the
/// numbers off that tool — any figure you publish must come with the full
/// methodology (see docs), not from this program.
///
/// Build and run: zig build bench   (or) zig build-exe -OReleaseFast benchmarks/http_throughput.zig && ./http_throughput
///
/// Then drive it with, e.g.:
///   wrk -t4 -c100 -d30s http://localhost:3000/plaintext
///   ab -n 100000 -c 100 http://localhost:3000/plaintext
const std = @import("std");
const nexus = @import("nexus");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    nexus.console.info("Nexus HTTP load-test target — listening on http://localhost:3000", .{});
    nexus.console.info("", .{});
    nexus.console.info("Drive it from a separate load generator, e.g.:", .{});
    nexus.console.info("  wrk -t4 -c100 -d30s http://localhost:3000/plaintext", .{});
    nexus.console.info("  wrk -t4 -c100 -d30s http://localhost:3000/json", .{});
    nexus.console.info("  ab -n 100000 -c 100 http://localhost:3000/plaintext", .{});
    nexus.console.info("", .{});
    nexus.console.info("Read the throughput off that tool; this server reports no numbers.", .{});
    nexus.console.info("", .{});

    var server = try nexus.http.Server.init(allocator, .{
        .port = 3000,
        .host = "0.0.0.0",
    });
    defer server.deinit();

    // Plaintext response (minimal overhead)
    try server.route("GET", "/plaintext", struct {
        fn handler(req: *nexus.http.Request, res: *nexus.http.Response) !void {
            _ = req;
            try res.text("Hello, World!");
        }
    }.handler);

    // JSON response
    try server.route("GET", "/json", struct {
        fn handler(req: *nexus.http.Request, res: *nexus.http.Response) !void {
            _ = req;
            try res.json(.{
                .message = "Hello, World!",
                .version = "nexus-" ++ nexus.version,
            });
        }
    }.handler);

    // CPU-bound JSON endpoint: a fixed arithmetic loop plus JSON serialization,
    // representing a handler that does real per-request work. It touches no
    // database — it exists to measure compute + serialization overhead.
    try server.route("GET", "/compute", struct {
        fn handler(req: *nexus.http.Request, res: *nexus.http.Response) !void {
            _ = req;

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
    try server.route("GET", "/", struct {
        fn handler(req: *nexus.http.Request, res: *nexus.http.Response) !void {
            _ = req;
            try res.html(
                \\<!DOCTYPE html>
                \\<html>
                \\<head><title>Nexus HTTP Benchmark</title></head>
                \\<body style="font-family: monospace; max-width: 800px; margin: 50px auto;">
                \\    <h1>Nexus HTTP load-test target</h1>
                \\    <h2>Endpoints:</h2>
                \\    <ul>
                \\        <li><a href="/plaintext">/plaintext</a> - Minimal plaintext response</li>
                \\        <li><a href="/json">/json</a> - JSON serialization</li>
                \\        <li><a href="/compute">/compute</a> - CPU-bound work + JSON serialization</li>
                \\    </ul>
                \\    <h2>Drive it from a load generator:</h2>
                \\    <pre>
                \\# Using wrk (recommended)
                \\wrk -t4 -c100 -d30s http://localhost:3000/plaintext
                \\wrk -t4 -c100 -d30s http://localhost:3000/json
                \\
                \\# Using Apache Bench
                \\ab -n 100000 -c 100 http://localhost:3000/plaintext
                \\
                \\# Using bombardier
                \\bombardier -c 100 -d 30s http://localhost:3000/plaintext
                \\    </pre>
                \\    <p>This server publishes no throughput figures of its own. Read the
                \\    numbers off your load generator, and record the full methodology
                \\    (Zig revision, optimize mode, CPU/OS, command, concurrency, duration,
                \\    request count, errors, latency percentiles, throughput) alongside them.</p>
                \\</body>
                \\</html>
            );
        }
    }.handler);

    try server.listen();
}
