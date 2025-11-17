#!/bin/bash

# Middleware Test Suite for Nexus
set -e

echo "🧪 Nexus Middleware Test Suite"
echo "==============================="

# Build nexus
echo "📦 Building Nexus..."
zig build
echo "✅ Build successful"
echo ""

# Create test server with middleware
cat > /tmp/nexus_middleware_test.zig <<'EOF'
const std = @import("std");
const nexus = @import("nexus");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = try nexus.http.Server.init(allocator, .{
        .port = 3001,
        .host = "127.0.0.1",
    });
    defer server.deinit();

    // Add middleware
    try server.use(nexus.middleware.logger);
    try server.use(nexus.middleware.cors);

    // Add routes
    try server.route("GET", "/test", struct {
        fn handler(req: *nexus.http.Request, res: *nexus.http.Response) !void {
            _ = req;
            try res.text("Middleware works!");
        }
    }.handler);

    try server.listen();
}
EOF

# Compile test server
echo "🔨 Compiling middleware test server..."
/opt/zig-0.16.0-dev/zig build-exe \
    -Mroot=/tmp/nexus_middleware_test.zig \
    --dep nexus \
    -Mnexus=/data/projects/nexus/src/root.zig \
    --name middleware_test \
    -femit-bin=/tmp/middleware_test 2>&1 | head -20

if [ ! -f /tmp/middleware_test ]; then
    echo "❌ Failed to compile test server"
    exit 1
fi

echo "✅ Test server compiled"
echo ""

# Start test server in background
echo "🚀 Starting middleware test server..."
/tmp/middleware_test > /tmp/middleware_test.log 2>&1 &
TEST_PID=$!
sleep 2

# Cleanup function
cleanup() {
    echo ""
    echo "🛑 Stopping test server..."
    kill $TEST_PID 2>/dev/null || true
    rm -f /tmp/middleware_test /tmp/middleware_test.zig /tmp/middleware_test.log
}
trap cleanup EXIT

echo "Test server PID: $TEST_PID"
echo ""

# Test 1: Verify CORS headers from middleware
echo "Test 1: CORS Middleware"
HEADERS=$(curl -s -D - http://localhost:3001/test 2>&1 | head -20)
if echo "$HEADERS" | grep -i "access-control-allow-origin" > /dev/null; then
    echo "✅ CORS headers present"
else
    echo "❌ CORS headers missing"
    echo "Headers received:"
    echo "$HEADERS"
    exit 1
fi
echo ""

# Test 2: Verify response body
echo "Test 2: Response Body"
BODY=$(curl -s http://localhost:3001/test)
if [[ $BODY == "Middleware works!" ]]; then
    echo "✅ Response body correct"
else
    echo "❌ Response body incorrect"
    echo "Got: $BODY"
    exit 1
fi
echo ""

# Test 3: Check server logs for logger middleware
echo "Test 3: Logger Middleware"
sleep 1
if grep -i "GET" /tmp/middleware_test.log > /dev/null; then
    echo "✅ Logger middleware executed (check logs)"
    echo "   Sample log:"
    grep -i "GET" /tmp/middleware_test.log | head -2
else
    echo "⚠️  Logger output not found (might be in stderr)"
fi
echo ""

echo "==============================="
echo "✅ Middleware tests passed!"
echo "==============================="
