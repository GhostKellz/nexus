const std = @import("std");
const http = @import("http.zig");

/// Native GraphQL Server Implementation
/// Specification: https://spec.graphql.org/

pub const Error = error{
    ParseError,
    ValidationError,
    ExecutionError,
    InvalidQuery,
    FieldNotFound,
    TypeMismatch,
    VariableNotFound,
    InvalidArgument,
    NotNullViolation,
};

/// GraphQL value types
pub const Value = union(enum) {
    null,
    int: i64,
    float: f64,
    string: []const u8,
    boolean: bool,
    list: []const Value,
    object: std.StringHashMap(Value),

    pub fn format(self: Value, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayList(u8).init(allocator);
        try self.formatInto(&buf);
        return buf.toOwnedSlice();
    }

    fn formatInto(self: Value, buf: *std.ArrayList(u8)) !void {
        switch (self) {
            .null => try buf.appendSlice("null"),
            .int => |i| try buf.writer().print("{d}", .{i}),
            .float => |f| try buf.writer().print("{d}", .{f}),
            .string => |s| {
                try buf.append('"');
                for (s) |c| {
                    switch (c) {
                        '"' => try buf.appendSlice("\\\""),
                        '\\' => try buf.appendSlice("\\\\"),
                        '\n' => try buf.appendSlice("\\n"),
                        '\r' => try buf.appendSlice("\\r"),
                        '\t' => try buf.appendSlice("\\t"),
                        else => try buf.append(c),
                    }
                }
                try buf.append('"');
            },
            .boolean => |b| try buf.appendSlice(if (b) "true" else "false"),
            .list => |items| {
                try buf.append('[');
                for (items, 0..) |item, i| {
                    if (i > 0) try buf.append(',');
                    try item.formatInto(buf);
                }
                try buf.append(']');
            },
            .object => |obj| {
                try buf.append('{');
                var iter = obj.iterator();
                var first = true;
                while (iter.next()) |entry| {
                    if (!first) try buf.append(',');
                    first = false;
                    try buf.append('"');
                    try buf.appendSlice(entry.key_ptr.*);
                    try buf.appendSlice("\":");
                    try entry.value_ptr.formatInto(buf);
                }
                try buf.append('}');
            },
        }
    }
};

/// GraphQL type kinds
pub const TypeKind = enum {
    scalar,
    object,
    interface,
    union_type,
    enum_type,
    input_object,
    list,
    non_null,
};

/// GraphQL scalar types
pub const ScalarType = enum {
    int,
    float,
    string,
    boolean,
    id,

    pub fn name(self: ScalarType) []const u8 {
        return switch (self) {
            .int => "Int",
            .float => "Float",
            .string => "String",
            .boolean => "Boolean",
            .id => "ID",
        };
    }
};

/// Field definition
pub const FieldDef = struct {
    name: []const u8,
    type_name: []const u8,
    is_list: bool = false,
    is_non_null: bool = false,
    args: []const ArgumentDef = &[_]ArgumentDef{},
    resolver: ?ResolverFn = null,
};

/// Argument definition
pub const ArgumentDef = struct {
    name: []const u8,
    type_name: []const u8,
    default_value: ?Value = null,
    is_non_null: bool = false,
};

/// Object type definition
pub const ObjectTypeDef = struct {
    name: []const u8,
    fields: []const FieldDef,
    interfaces: []const []const u8 = &[_][]const u8{},
};

/// Resolver function signature
pub const ResolverFn = *const fn (
    parent: ?Value,
    args: std.StringHashMap(Value),
    context: *Context,
) anyerror!Value;

/// Subscription handler
pub const SubscriptionHandler = *const fn (
    args: std.StringHashMap(Value),
    context: *Context,
    callback: *const fn (Value) void,
) anyerror!void;

/// Execution context
pub const Context = struct {
    request: ?*http.Request = null,
    response: ?*http.Response = null,
    user_data: ?*anyopaque = null,
    allocator: std.mem.Allocator,
};

/// GraphQL operation type
pub const OperationType = enum {
    query,
    mutation,
    subscription,
};

/// Parsed field selection
pub const Selection = struct {
    name: []const u8,
    alias: ?[]const u8 = null,
    arguments: std.StringHashMap(Value),
    selections: std.ArrayList(Selection),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) Selection {
        return Selection{
            .name = name,
            .arguments = std.StringHashMap(Value).init(allocator),
            .selections = std.ArrayList(Selection).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Selection) void {
        self.arguments.deinit();
        for (self.selections.items) |*sel| {
            sel.deinit();
        }
        self.selections.deinit();
    }
};

/// Parsed operation
pub const Operation = struct {
    operation_type: OperationType = .query,
    name: ?[]const u8 = null,
    variables: std.StringHashMap(Value),
    selections: std.ArrayList(Selection),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Operation {
        return Operation{
            .variables = std.StringHashMap(Value).init(allocator),
            .selections = std.ArrayList(Selection).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Operation) void {
        self.variables.deinit();
        for (self.selections.items) |*sel| {
            sel.deinit();
        }
        self.selections.deinit();
    }
};

/// GraphQL Schema
pub const Schema = struct {
    query_type: ?ObjectTypeDef = null,
    mutation_type: ?ObjectTypeDef = null,
    subscription_type: ?ObjectTypeDef = null,
    types: std.StringHashMap(ObjectTypeDef),
    resolvers: std.StringHashMap(ResolverFn),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Schema {
        return Schema{
            .types = std.StringHashMap(ObjectTypeDef).init(allocator),
            .resolvers = std.StringHashMap(ResolverFn).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Schema) void {
        self.types.deinit();
        self.resolvers.deinit();
    }

    pub fn addType(self: *Schema, type_def: ObjectTypeDef) !void {
        try self.types.put(type_def.name, type_def);
    }

    pub fn setQueryType(self: *Schema, type_def: ObjectTypeDef) void {
        self.query_type = type_def;
    }

    pub fn setMutationType(self: *Schema, type_def: ObjectTypeDef) void {
        self.mutation_type = type_def;
    }

    pub fn setSubscriptionType(self: *Schema, type_def: ObjectTypeDef) void {
        self.subscription_type = type_def;
    }

    pub fn addResolver(self: *Schema, type_name: []const u8, field_name: []const u8, resolver: ResolverFn) !void {
        var key_buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}.{s}", .{ type_name, field_name }) catch return Error.InvalidArgument;
        try self.resolvers.put(key, resolver);
    }

    pub fn getResolver(self: *const Schema, type_name: []const u8, field_name: []const u8) ?ResolverFn {
        var key_buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}.{s}", .{ type_name, field_name }) catch return null;
        return self.resolvers.get(key);
    }
};

/// Simple GraphQL query parser
pub const Parser = struct {
    source: []const u8,
    pos: usize = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Parser {
        return Parser{
            .source = source,
            .allocator = allocator,
        };
    }

    pub fn parse(self: *Parser) !Operation {
        self.skipWhitespace();

        var op = Operation.init(self.allocator);
        errdefer op.deinit();

        // Check for operation type keyword
        if (self.matchKeyword("query")) {
            op.operation_type = .query;
            self.skipWhitespace();
            op.name = self.parseName();
        } else if (self.matchKeyword("mutation")) {
            op.operation_type = .mutation;
            self.skipWhitespace();
            op.name = self.parseName();
        } else if (self.matchKeyword("subscription")) {
            op.operation_type = .subscription;
            self.skipWhitespace();
            op.name = self.parseName();
        }

        self.skipWhitespace();

        // Parse selection set
        if (self.peek() != '{') {
            return Error.ParseError;
        }
        self.advance(); // skip '{'

        try self.parseSelectionSet(&op.selections);

        return op;
    }

    fn parseSelectionSet(self: *Parser, selections: *std.ArrayList(Selection)) !void {
        while (true) {
            self.skipWhitespace();
            if (self.peek() == '}' or self.isAtEnd()) break;

            var sel = try self.parseSelection();
            try selections.append(sel);
        }

        if (self.peek() == '}') {
            self.advance();
        }
    }

    fn parseSelection(self: *Parser) !Selection {
        self.skipWhitespace();

        const name = self.parseName() orelse return Error.ParseError;
        var sel = Selection.init(self.allocator, name);

        self.skipWhitespace();

        // Check for alias
        if (self.peek() == ':') {
            self.advance();
            self.skipWhitespace();
            sel.alias = name;
            sel.name = self.parseName() orelse return Error.ParseError;
            self.skipWhitespace();
        }

        // Parse arguments
        if (self.peek() == '(') {
            self.advance();
            try self.parseArguments(&sel.arguments);
        }

        self.skipWhitespace();

        // Parse nested selection set
        if (self.peek() == '{') {
            self.advance();
            try self.parseSelectionSet(&sel.selections);
        }

        return sel;
    }

    fn parseArguments(self: *Parser, args: *std.StringHashMap(Value)) !void {
        while (true) {
            self.skipWhitespace();
            if (self.peek() == ')' or self.isAtEnd()) break;

            const arg_name = self.parseName() orelse return Error.ParseError;
            self.skipWhitespace();

            if (self.peek() != ':') return Error.ParseError;
            self.advance();
            self.skipWhitespace();

            const value = try self.parseValue();
            try args.put(arg_name, value);

            self.skipWhitespace();
            if (self.peek() == ',') self.advance();
        }

        if (self.peek() == ')') {
            self.advance();
        }
    }

    fn parseValue(self: *Parser) !Value {
        self.skipWhitespace();

        const c = self.peek();

        // String
        if (c == '"') {
            return Value{ .string = try self.parseString() };
        }

        // Number
        if (c == '-' or std.ascii.isDigit(c)) {
            return try self.parseNumber();
        }

        // Boolean or null
        if (self.matchKeyword("true")) return Value{ .boolean = true };
        if (self.matchKeyword("false")) return Value{ .boolean = false };
        if (self.matchKeyword("null")) return Value.null;

        // List
        if (c == '[') {
            self.advance();
            var items = std.ArrayList(Value).init(self.allocator);
            while (self.peek() != ']' and !self.isAtEnd()) {
                const item = try self.parseValue();
                try items.append(item);
                self.skipWhitespace();
                if (self.peek() == ',') self.advance();
            }
            if (self.peek() == ']') self.advance();
            return Value{ .list = try items.toOwnedSlice() };
        }

        // Object/Input
        if (c == '{') {
            self.advance();
            var obj = std.StringHashMap(Value).init(self.allocator);
            while (self.peek() != '}' and !self.isAtEnd()) {
                self.skipWhitespace();
                const key = self.parseName() orelse return Error.ParseError;
                self.skipWhitespace();
                if (self.peek() != ':') return Error.ParseError;
                self.advance();
                const val = try self.parseValue();
                try obj.put(key, val);
                self.skipWhitespace();
                if (self.peek() == ',') self.advance();
            }
            if (self.peek() == '}') self.advance();
            return Value{ .object = obj };
        }

        // Variable reference (starts with $)
        if (c == '$') {
            self.advance();
            const var_name = self.parseName() orelse return Error.ParseError;
            // Return as string for now - actual variable substitution happens during execution
            return Value{ .string = var_name };
        }

        return Error.ParseError;
    }

    fn parseString(self: *Parser) ![]const u8 {
        if (self.peek() != '"') return Error.ParseError;
        self.advance();

        const start = self.pos;
        while (self.peek() != '"' and !self.isAtEnd()) {
            if (self.peek() == '\\') self.advance(); // skip escape
            self.advance();
        }
        const end = self.pos;

        if (self.peek() == '"') self.advance();

        return self.source[start..end];
    }

    fn parseNumber(self: *Parser) !Value {
        const start = self.pos;
        var is_float = false;

        if (self.peek() == '-') self.advance();

        while (std.ascii.isDigit(self.peek())) self.advance();

        if (self.peek() == '.') {
            is_float = true;
            self.advance();
            while (std.ascii.isDigit(self.peek())) self.advance();
        }

        if (self.peek() == 'e' or self.peek() == 'E') {
            is_float = true;
            self.advance();
            if (self.peek() == '+' or self.peek() == '-') self.advance();
            while (std.ascii.isDigit(self.peek())) self.advance();
        }

        const num_str = self.source[start..self.pos];

        if (is_float) {
            const f = std.fmt.parseFloat(f64, num_str) catch return Error.ParseError;
            return Value{ .float = f };
        } else {
            const i = std.fmt.parseInt(i64, num_str, 10) catch return Error.ParseError;
            return Value{ .int = i };
        }
    }

    fn parseName(self: *Parser) ?[]const u8 {
        self.skipWhitespace();
        const start = self.pos;

        if (!std.ascii.isAlphabetic(self.peek()) and self.peek() != '_') {
            return null;
        }

        while (std.ascii.isAlphanumeric(self.peek()) or self.peek() == '_') {
            self.advance();
        }

        if (start == self.pos) return null;
        return self.source[start..self.pos];
    }

    fn matchKeyword(self: *Parser, keyword: []const u8) bool {
        if (self.pos + keyword.len > self.source.len) return false;

        if (std.mem.eql(u8, self.source[self.pos .. self.pos + keyword.len], keyword)) {
            // Make sure it's not part of a longer identifier
            if (self.pos + keyword.len < self.source.len) {
                const next = self.source[self.pos + keyword.len];
                if (std.ascii.isAlphanumeric(next) or next == '_') {
                    return false;
                }
            }
            self.pos += keyword.len;
            return true;
        }
        return false;
    }

    fn skipWhitespace(self: *Parser) void {
        while (!self.isAtEnd()) {
            const c = self.peek();
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.advance();
            } else if (c == '#') {
                // Skip comment until end of line
                while (!self.isAtEnd() and self.peek() != '\n') {
                    self.advance();
                }
            } else {
                break;
            }
        }
    }

    fn peek(self: *Parser) u8 {
        if (self.isAtEnd()) return 0;
        return self.source[self.pos];
    }

    fn advance(self: *Parser) void {
        if (!self.isAtEnd()) self.pos += 1;
    }

    fn isAtEnd(self: *Parser) bool {
        return self.pos >= self.source.len;
    }
};

/// GraphQL executor
pub const Executor = struct {
    schema: *Schema,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, schema: *Schema) Executor {
        return Executor{
            .schema = schema,
            .allocator = allocator,
        };
    }

    pub fn execute(self: *Executor, query: []const u8, variables: ?std.StringHashMap(Value), ctx: *Context) !Value {
        var parser = Parser.init(self.allocator, query);
        var operation = try parser.parse();
        defer operation.deinit();

        // Merge variables
        if (variables) |vars| {
            var iter = vars.iterator();
            while (iter.next()) |entry| {
                try operation.variables.put(entry.key_ptr.*, entry.value_ptr.*);
            }
        }

        // Get root type based on operation
        const root_type = switch (operation.operation_type) {
            .query => self.schema.query_type,
            .mutation => self.schema.mutation_type,
            .subscription => self.schema.subscription_type,
        } orelse return Error.ExecutionError;

        // Execute selections
        return try self.executeSelections(root_type.name, Value.null, operation.selections.items, ctx);
    }

    fn executeSelections(
        self: *Executor,
        type_name: []const u8,
        parent: Value,
        selections: []Selection,
        ctx: *Context,
    ) !Value {
        var result = std.StringHashMap(Value).init(self.allocator);

        for (selections) |*sel| {
            const field_name = sel.alias orelse sel.name;
            const value = try self.resolveField(type_name, parent, sel, ctx);
            try result.put(field_name, value);
        }

        return Value{ .object = result };
    }

    fn resolveField(
        self: *Executor,
        type_name: []const u8,
        parent: Value,
        selection: *Selection,
        ctx: *Context,
    ) !Value {
        // Look up resolver
        if (self.schema.getResolver(type_name, selection.name)) |resolver| {
            const value = try resolver(parent, selection.arguments, ctx);

            // If there are nested selections, execute them
            if (selection.selections.items.len > 0) {
                // Determine the type of the resolved value
                // For simplicity, use the field name as type hint
                return try self.executeSelections(selection.name, value, selection.selections.items, ctx);
            }

            return value;
        }

        // No resolver - try to get from parent object
        if (parent == .object) {
            if (parent.object.get(selection.name)) |value| {
                return value;
            }
        }

        return Value.null;
    }
};

/// GraphQL HTTP handler
pub const Handler = struct {
    executor: Executor,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, schema: *Schema) Handler {
        return Handler{
            .executor = Executor.init(allocator, schema),
            .allocator = allocator,
        };
    }

    pub fn handle(self: *Handler, req: *http.Request, res: *http.Response) !void {
        // Parse request body as JSON
        const body = req.body orelse {
            res.status_code = .BadRequest;
            try res.json(.{ .errors = .{.{ .message = "Missing request body" }} });
            return;
        };

        // Simple JSON parsing for query and variables
        const query = extractJsonField(body, "query") orelse {
            res.status_code = .BadRequest;
            try res.json(.{ .errors = .{.{ .message = "Missing query field" }} });
            return;
        };

        var ctx = Context{
            .request = req,
            .response = res,
            .allocator = self.allocator,
        };

        // Execute query
        const result = self.executor.execute(query, null, &ctx) catch |err| {
            res.status_code = .InternalServerError;
            try res.json(.{ .errors = .{.{ .message = @errorName(err) }} });
            return;
        };

        // Format response
        const data_json = try result.format(self.allocator);
        defer self.allocator.free(data_json);

        var response_buf = std.ArrayList(u8).init(self.allocator);
        defer response_buf.deinit();

        try response_buf.appendSlice("{\"data\":");
        try response_buf.appendSlice(data_json);
        try response_buf.append('}');

        res.setHeader("Content-Type", "application/json");
        try res.text(response_buf.items);
    }

    fn extractJsonField(json: []const u8, field: []const u8) ?[]const u8 {
        // Simple field extraction (doesn't handle all JSON cases)
        var search_buf: [64]u8 = undefined;
        const search = std.fmt.bufPrint(&search_buf, "\"{s}\":", .{field}) catch return null;

        const start_idx = std.mem.indexOf(u8, json, search) orelse return null;
        const value_start = start_idx + search.len;

        // Skip whitespace
        var pos = value_start;
        while (pos < json.len and (json[pos] == ' ' or json[pos] == '\t')) {
            pos += 1;
        }

        if (pos >= json.len) return null;

        // Extract string value
        if (json[pos] == '"') {
            pos += 1;
            const str_start = pos;
            while (pos < json.len and json[pos] != '"') {
                if (json[pos] == '\\') pos += 1;
                pos += 1;
            }
            return json[str_start..pos];
        }

        return null;
    }
};

// Tests
test "parse simple query" {
    const allocator = std.testing.allocator;

    const query = "{ user { id name } }";
    var parser = Parser.init(allocator, query);

    var op = try parser.parse();
    defer op.deinit();

    try std.testing.expectEqual(OperationType.query, op.operation_type);
    try std.testing.expectEqual(@as(usize, 1), op.selections.items.len);
    try std.testing.expectEqualStrings("user", op.selections.items[0].name);
}

test "parse query with arguments" {
    const allocator = std.testing.allocator;

    const query =
        \\query GetUser {
        \\  user(id: 123) {
        \\    name
        \\    email
        \\  }
        \\}
    ;

    var parser = Parser.init(allocator, query);
    var op = try parser.parse();
    defer op.deinit();

    try std.testing.expectEqual(OperationType.query, op.operation_type);
    try std.testing.expectEqualStrings("GetUser", op.name.?);
}

test "value formatting" {
    const allocator = std.testing.allocator;

    const str_val = Value{ .string = "hello" };
    const formatted = try str_val.format(allocator);
    defer allocator.free(formatted);

    try std.testing.expectEqualStrings("\"hello\"", formatted);
}
