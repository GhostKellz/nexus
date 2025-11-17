#!/bin/bash

# HTTP Server Test Suite for Nexus
set -e

echo "🧪 Nexus HTTP Server Test Suite"
echo "================================"

# Build nexus
echo "📦 Building Nexus..."
zig build
echo "✅ Build successful"
echo ""

# Start server in background
echo "🚀 Starting Nexus server..."
./zig-out/bin/nexus serve > /tmp/nexus_test.log 2>&1 &
SERVER_PID=$!
sleep 2

# Function to cleanup
cleanup() {
    echo ""
    echo "🛑 Stopping server..."
    kill $SERVER_PID 2>/dev/null || true
    rm -f /tmp/nexus_test.log
}
trap cleanup EXIT

echo "Server PID: $SERVER_PID"
echo ""

# Test 1: GET / (HTML response)
echo "Test 1: GET / (HTML)"
RESPONSE=$(curl -s http://localhost:3000/)
if [[ $RESPONSE == *"Nexus Runtime"* ]]; then
    echo "✅ HTML response contains 'Nexus Runtime'"
else
    echo "❌ HTML response test failed"
    exit 1
fi
echo ""

# Test 2: GET /api/status (JSON response)
echo "Test 2: GET /api/status (JSON)"
JSON_RESPONSE=$(curl -s http://localhost:3000/api/status)
if [[ $JSON_RESPONSE == *'"runtime"'* ]] && [[ $JSON_RESPONSE == *'"Nexus'* ]]; then
    echo "✅ JSON response valid"
    echo "   Response: $JSON_RESPONSE"
else
    echo "❌ JSON response test failed"
    echo "   Got: $JSON_RESPONSE"
    exit 1
fi
echo ""

# Test 3: 404 handling
echo "Test 3: 404 Not Found"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:3000/nonexistent)
if [[ $HTTP_CODE == "404" ]]; then
    echo "✅ 404 response correct"
else
    echo "❌ Expected 404, got $HTTP_CODE"
    exit 1
fi
echo ""

# Test 4: Query parameters (once implemented)
echo "Test 4: Query Parameters"
QUERY_RESPONSE=$(curl -s "http://localhost:3000/?test=value&foo=bar")
echo "   Response received (query parsing to be validated)"
echo ""

# Test 5: Headers
echo "Test 5: Response Headers"
HEADERS=$(curl -s -D - http://localhost:3000/api/status | grep -i "content-type")
if [[ $HEADERS == *"application/json"* ]]; then
    echo "✅ Content-Type header correct"
else
    echo "❌ Headers test failed"
    echo "   Got: $HEADERS"
    exit 1
fi
echo ""

# Performance Test
echo "⚡ Performance Test (100 requests)"
START_TIME=$(date +%s%N)
for i in {1..100}; do
    curl -s http://localhost:3000/api/status > /dev/null
done
END_TIME=$(date +%s%N)
DURATION=$(( (END_TIME - START_TIME) / 1000000 ))
RPS=$(( 100000 / DURATION ))
echo "   100 requests in ${DURATION}ms"
echo "   ~$RPS req/s"
echo ""

echo "================================"
echo "✅ All tests passed!"
echo "================================"
