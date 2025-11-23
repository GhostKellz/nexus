/// REST API Example: Todo List with PostgreSQL
/// Demonstrates a complete CRUD API with database integration
///
/// Run: zig build && ./zig-out/bin/nexus run examples/rest_api_todos.zig
///
/// Endpoints:
///   GET    /api/todos      - List all todos
///   GET    /api/todos/:id  - Get single todo
///   POST   /api/todos      - Create new todo
///   PUT    /api/todos/:id  - Update todo
///   DELETE /api/todos/:id  - Delete todo

const std = @import("std");
const nexus = @import("nexus");

// Todo model
const Todo = struct {
    id: i32,
    title: []const u8,
    completed: bool,
    created_at: i64,

    pub fn toJson(self: Todo, allocator: std.mem.Allocator) ![]u8 {
        return try std.fmt.allocPrint(
            allocator,
            "{{\"id\":{d},\"title\":\"{s}\",\"completed\":{},\"created_at\":{d}}}",
            .{ self.id, self.title, self.completed, self.created_at },
        );
    }
};

// Simple in-memory database for demo
// In production, use nexus.db.PostgresPool
var todos_db = std.ArrayList(Todo).init(std.heap.page_allocator);
var next_id: i32 = 1;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize with sample data
    try todos_db.append(allocator, Todo{
        .id = next_id,
        .title = "Learn Nexus Runtime",
        .completed = false,
        .created_at = std.time.timestamp(),
    });
    next_id += 1;

    try todos_db.append(allocator, Todo{
        .id = next_id,
        .title = "Build REST API",
        .completed = true,
        .created_at = std.time.timestamp(),
    });
    next_id += 1;

    nexus.console.info("🚀 Starting Todo API server on http://localhost:3000", .{});
    nexus.console.info("", .{});
    nexus.console.info("Endpoints:", .{});
    nexus.console.info("  GET    http://localhost:3000/api/todos", .{});
    nexus.console.info("  GET    http://localhost:3000/api/todos/1", .{});
    nexus.console.info("  POST   http://localhost:3000/api/todos", .{});
    nexus.console.info("  PUT    http://localhost:3000/api/todos/1", .{});
    nexus.console.info("  DELETE http://localhost:3000/api/todos/1", .{});
    nexus.console.info("", .{});

    var server = try nexus.http.Server.init(allocator, .{
        .port = 3000,
        .host = "0.0.0.0",
    });
    defer server.deinit();

    // Middleware
    try server.use(nexus.middleware.logger);
    try server.use(nexus.middleware.cors(.{}));

    // Routes
    try server.get("/api/todos", listTodos);
    try server.get("/api/todos/:id", getTodo);
    try server.post("/api/todos", createTodo);
    try server.put("/api/todos/:id", updateTodo);
    try server.delete("/api/todos/:id", deleteTodo);

    // Health check
    try server.get("/health", struct {
        fn handler(req: *nexus.http.Request, res: *nexus.http.Response) !void {
            _ = req;
            try res.json(.{ .status = "healthy", .todos_count = todos_db.items.len });
        }
    }.handler);

    try server.listen();
}

// GET /api/todos - List all todos
fn listTodos(req: *nexus.http.Request, res: *nexus.http.Response) !void {
    _ = req;

    // Build JSON array
    var json = std.ArrayList(u8).init(res.allocator);
    defer json.deinit();

    try json.append('[');

    for (todos_db.items, 0..) |todo, i| {
        const todo_json = try todo.toJson(res.allocator);
        defer res.allocator.free(todo_json);

        try json.appendSlice(todo_json);
        if (i < todos_db.items.len - 1) {
            try json.append(',');
        }
    }

    try json.append(']');

    _ = try res.setHeader("Content-Type", "application/json");
    try res.send(try json.toOwnedSlice());
}

// GET /api/todos/:id - Get single todo
fn getTodo(req: *nexus.http.Request, res: *nexus.http.Response) !void {
    const id_str = req.getParam("id") orelse {
        res.status_code = .BadRequest;
        try res.json(.{ .@"error" = "Missing id parameter" });
        return;
    };

    const id = std.fmt.parseInt(i32, id_str, 10) catch {
        res.status_code = .BadRequest;
        try res.json(.{ .@"error" = "Invalid id format" });
        return;
    };

    // Find todo
    for (todos_db.items) |todo| {
        if (todo.id == id) {
            const todo_json = try todo.toJson(res.allocator);
            defer res.allocator.free(todo_json);

            _ = try res.setHeader("Content-Type", "application/json");
            try res.send(todo_json);
            return;
        }
    }

    res.status_code = .NotFound;
    try res.json(.{ .@"error" = "Todo not found" });
}

// POST /api/todos - Create new todo
fn createTodo(req: *nexus.http.Request, res: *nexus.http.Response) !void {
    // Parse JSON body
    // In production, use proper JSON parser
    const body = req.body;

    // Extract title (simple string search for demo)
    const title_start = std.mem.indexOf(u8, body, "\"title\":\"") orelse {
        res.status_code = .BadRequest;
        try res.json(.{ .@"error" = "Missing title field" });
        return;
    };

    const title_value_start = title_start + "\"title\":\"".len;
    const title_end = std.mem.indexOfPos(u8, body, title_value_start, "\"") orelse {
        res.status_code = .BadRequest;
        try res.json(.{ .@"error" = "Invalid title format" });
        return;
    };

    const title = body[title_value_start..title_end];

    // Create new todo
    const new_todo = Todo{
        .id = next_id,
        .title = try res.allocator.dupe(u8, title),
        .completed = false,
        .created_at = std.time.timestamp(),
    };
    next_id += 1;

    try todos_db.append(res.allocator, new_todo);

    res.status_code = .Created;
    const todo_json = try new_todo.toJson(res.allocator);
    defer res.allocator.free(todo_json);

    _ = try res.setHeader("Content-Type", "application/json");
    try res.send(todo_json);
}

// PUT /api/todos/:id - Update todo
fn updateTodo(req: *nexus.http.Request, res: *nexus.http.Response) !void {
    const id_str = req.getParam("id") orelse {
        res.status_code = .BadRequest;
        try res.json(.{ .@"error" = "Missing id parameter" });
        return;
    };

    const id = std.fmt.parseInt(i32, id_str, 10) catch {
        res.status_code = .BadRequest;
        try res.json(.{ .@"error" = "Invalid id format" });
        return;
    };

    // Find and update todo
    for (todos_db.items) |*todo| {
        if (todo.id == id) {
            // Check for completed field in body
            if (std.mem.indexOf(u8, req.body, "\"completed\":true")) |_| {
                todo.completed = true;
            } else if (std.mem.indexOf(u8, req.body, "\"completed\":false")) |_| {
                todo.completed = false;
            }

            // Check for title update
            if (std.mem.indexOf(u8, req.body, "\"title\":\"")) |title_start| {
                const title_value_start = title_start + "\"title\":\"".len;
                if (std.mem.indexOfPos(u8, req.body, title_value_start, "\"")) |title_end| {
                    const new_title = req.body[title_value_start..title_end];
                    // In production, free old title first
                    todo.title = try res.allocator.dupe(u8, new_title);
                }
            }

            const todo_json = try todo.toJson(res.allocator);
            defer res.allocator.free(todo_json);

            _ = try res.setHeader("Content-Type", "application/json");
            try res.send(todo_json);
            return;
        }
    }

    res.status_code = .NotFound;
    try res.json(.{ .@"error" = "Todo not found" });
}

// DELETE /api/todos/:id - Delete todo
fn deleteTodo(req: *nexus.http.Request, res: *nexus.http.Response) !void {
    const id_str = req.getParam("id") orelse {
        res.status_code = .BadRequest;
        try res.json(.{ .@"error" = "Missing id parameter" });
        return;
    };

    const id = std.fmt.parseInt(i32, id_str, 10) catch {
        res.status_code = .BadRequest;
        try res.json(.{ .@"error" = "Invalid id format" });
        return;
    };

    // Find and delete todo
    var i: usize = 0;
    while (i < todos_db.items.len) : (i += 1) {
        if (todos_db.items[i].id == id) {
            _ = todos_db.orderedRemove(i);

            res.status_code = .NoContent;
            try res.send("");
            return;
        }
    }

    res.status_code = .NotFound;
    try res.json(.{ .@"error" = "Todo not found" });
}
