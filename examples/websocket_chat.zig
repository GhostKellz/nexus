const std = @import("std");
const nexus = @import("nexus");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Print startup banner
    nexus.console.log("⚡ Nexus WebSocket Chat Server");
    nexus.console.log("Node.js reimagined in Zig + WASM - 10x better\n");

    // Create HTTP server
    const config = nexus.http.ServerConfig{
        .port = 3000,
        .host = "0.0.0.0",
    };

    var server = try nexus.http.Server.init(allocator, config);
    defer server.deinit();

    // Serve static HTML page
    try server.get("/", struct {
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

    // WebSocket endpoint
    try server.get("/ws", struct {
        fn handler(req: *nexus.http.Request, res: *nexus.http.Response) !void {
            // Upgrade to WebSocket
            const ws = try res.upgradeWebSocket(req);
            defer {
                ws.deinit();
                req.allocator.destroy(ws);
            }

            nexus.console.info("WebSocket client connected: {s}", .{ws.id});

            // Send welcome message
            try ws.sendText("Welcome to Nexus Chat!");

            // Echo loop
            while (true) {
                const msg = ws.receive() catch |err| {
                    nexus.console.warn("WebSocket error: {}", .{err});
                    break;
                };
                defer msg.deinit();

                if (msg.isClose()) {
                    nexus.console.info("Client {s} disconnected", .{ws.id});
                    break;
                }

                if (msg.isPing()) {
                    try ws.pong();
                    continue;
                }

                if (msg.isText()) {
                    const text = msg.getText() orelse "";
                    nexus.console.log("[{s}] {s}", .{ ws.id, text });

                    // Echo back
                    const echo = try std.fmt.allocPrint(req.allocator, "[{s}] {s}", .{ ws.id, text });
                    defer req.allocator.free(echo);
                    try ws.sendText(echo);
                }
            }
        }
    }.handler);

    // Start server
    nexus.console.log("🚀 Nexus HTTP + WebSocket server running");
    nexus.console.log("   http://localhost:3000");
    nexus.console.log("");
    nexus.console.log("Routes:");
    nexus.console.log("  GET  /     - Chat interface");
    nexus.console.log("  GET  /ws   - WebSocket endpoint");
    nexus.console.log("");
    nexus.console.log("Press Ctrl+C to stop\n");

    try server.listen();
}
