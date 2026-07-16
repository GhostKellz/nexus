const std = @import("std");
const nexus = @import("nexus");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Print startup banner
    nexus.console.log("⚡ Nexus WebSocket Chat Server", .{});
    nexus.console.log("An application runtime written in Zig\n", .{});

    // Create HTTP server
    const config = nexus.http.ServerConfig{
        .port = 3000,
        .host = "0.0.0.0",
    };

    var server = try nexus.http.Server.init(allocator, config);
    defer server.deinit();

    // Serve static HTML page
    try server.route("GET", "/", struct {
        fn handler(req: *nexus.http.Request, res: *nexus.http.Response) !void {
            _ = req;
            const html =
                \\<!DOCTYPE html>
                \\<html>
                \\<head>
                \\    <title>Nexus WebSocket Chat</title>
                \\    <style>
                \\        body { font-family: Arial, sans-serif; max-width: 600px; margin: 50px auto; }
                \\        #messages { border: 1px solid #ccc; height: 300px; overflow-y: scroll; padding: 10px; }
                \\        .message { margin: 5px 0; }
                \\        #input { width: 80%; padding: 10px; }
                \\        #send { padding: 10px 20px; }
                \\    </style>
                \\</head>
                \\<body>
                \\    <h1>⚡ Nexus WebSocket Chat</h1>
                \\    <div id="status">Connecting...</div>
                \\    <div id="messages"></div>
                \\    <input type="text" id="input" placeholder="Type a message...">
                \\    <button id="send">Send</button>
                \\    <script>
                \\        const ws = new WebSocket('ws://localhost:3000/ws');
                \\        const messages = document.getElementById('messages');
                \\        const input = document.getElementById('input');
                \\        const status = document.getElementById('status');
                \\
                \\        ws.onopen = () => {
                \\            status.textContent = 'Connected!';
                \\            status.style.color = 'green';
                \\        };
                \\
                \\        ws.onmessage = (event) => {
                \\            const msg = document.createElement('div');
                \\            msg.className = 'message';
                \\            msg.textContent = event.data;
                \\            messages.appendChild(msg);
                \\            messages.scrollTop = messages.scrollHeight;
                \\        };
                \\
                \\        ws.onclose = () => {
                \\            status.textContent = 'Disconnected';
                \\            status.style.color = 'red';
                \\        };
                \\
                \\        function send() {
                \\            if (input.value) {
                \\                ws.send(input.value);
                \\                input.value = '';
                \\            }
                \\        }
                \\
                \\        document.getElementById('send').onclick = send;
                \\        input.addEventListener('keypress', (e) => {
                \\            if (e.key === 'Enter') send();
                \\        });
                \\    </script>
                \\</body>
                \\</html>
            ;
            try res.html(html);
        }
    }.handler);

    // WebSocket endpoint.
    //
    // The HTTP -> WebSocket upgrade helper (Response.upgradeWebSocket) is being
    // reworked against the current std.Io networking API, so this route reports
    // that the endpoint is not yet available rather than performing a handshake.
    // The chat page above still loads and attempts to connect, demonstrating the
    // client side of the flow.
    try server.route("GET", "/ws", struct {
        fn handler(req: *nexus.http.Request, res: *nexus.http.Response) !void {
            _ = req;
            nexus.console.info("WebSocket upgrade requested on /ws", .{});
            res.status_code = .InternalServerError;
            try res.text("WebSocket upgrade is not available in this build");
        }
    }.handler);

    // Start server
    nexus.console.log("🚀 Nexus HTTP + WebSocket server running", .{});
    nexus.console.log("   http://localhost:3000", .{});
    nexus.console.log("", .{});
    nexus.console.log("Routes:", .{});
    nexus.console.log("  GET  /     - Chat interface", .{});
    nexus.console.log("  GET  /ws   - WebSocket endpoint", .{});
    nexus.console.log("", .{});
    nexus.console.log("Press Ctrl+C to stop\n", .{});

    try server.listen();
}
