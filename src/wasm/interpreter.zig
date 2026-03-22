const std = @import("std");
const engine = @import("engine.zig");

/// WASM opcodes (subset - core instructions)
pub const Opcode = enum(u8) {
    // Control flow
    unreachable_ = 0x00,
    nop = 0x01,
    block = 0x02,
    loop = 0x03,
    if_ = 0x04,
    else_ = 0x05,
    end = 0x0B,
    br = 0x0C,
    br_if = 0x0D,
    br_table = 0x0E,
    return_ = 0x0F,
    call = 0x10,
    call_indirect = 0x11,

    // Parametric
    drop = 0x1A,
    select = 0x1B,

    // Variable access
    local_get = 0x20,
    local_set = 0x21,
    local_tee = 0x22,
    global_get = 0x23,
    global_set = 0x24,

    // Memory
    i32_load = 0x28,
    i64_load = 0x29,
    f32_load = 0x2A,
    f64_load = 0x2B,
    i32_load8_s = 0x2C,
    i32_load8_u = 0x2D,
    i32_load16_s = 0x2E,
    i32_load16_u = 0x2F,
    i64_load8_s = 0x30,
    i64_load8_u = 0x31,
    i64_load16_s = 0x32,
    i64_load16_u = 0x33,
    i64_load32_s = 0x34,
    i64_load32_u = 0x35,
    i32_store = 0x36,
    i64_store = 0x37,
    f32_store = 0x38,
    f64_store = 0x39,
    i32_store8 = 0x3A,
    i32_store16 = 0x3B,
    i64_store8 = 0x3C,
    i64_store16 = 0x3D,
    i64_store32 = 0x3E,
    memory_size = 0x3F,
    memory_grow = 0x40,

    // Constants
    i32_const = 0x41,
    i64_const = 0x42,
    f32_const = 0x43,
    f64_const = 0x44,

    // i32 operations
    i32_eqz = 0x45,
    i32_eq = 0x46,
    i32_ne = 0x47,
    i32_lt_s = 0x48,
    i32_lt_u = 0x49,
    i32_gt_s = 0x4A,
    i32_gt_u = 0x4B,
    i32_le_s = 0x4C,
    i32_le_u = 0x4D,
    i32_ge_s = 0x4E,
    i32_ge_u = 0x4F,

    // i64 comparisons
    i64_eqz = 0x50,

    // i32 arithmetic
    i32_clz = 0x67,
    i32_ctz = 0x68,
    i32_popcnt = 0x69,
    i32_add = 0x6A,
    i32_sub = 0x6B,
    i32_mul = 0x6C,
    i32_div_s = 0x6D,
    i32_div_u = 0x6E,
    i32_rem_s = 0x6F,
    i32_rem_u = 0x70,
    i32_and = 0x71,
    i32_or = 0x72,
    i32_xor = 0x73,
    i32_shl = 0x74,
    i32_shr_s = 0x75,
    i32_shr_u = 0x76,
    i32_rotl = 0x77,
    i32_rotr = 0x78,

    // i64 arithmetic
    i64_add = 0x7C,
    i64_sub = 0x7D,
    i64_mul = 0x7E,

    _,
};

/// Stack for WASM execution
pub const Stack = struct {
    values: std.ArrayListUnmanaged(engine.Value),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Stack {
        return Stack{
            .values = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Stack) void {
        self.values.deinit(self.allocator);
    }

    pub fn push(self: *Stack, value: engine.Value) !void {
        try self.values.append(self.allocator, value);
    }

    pub fn pop(self: *Stack) !engine.Value {
        return self.values.pop() orelse return error.StackUnderflow;
    }

    pub fn peek(self: *Stack) !engine.Value {
        if (self.values.items.len == 0) return error.StackUnderflow;
        return self.values.items[self.values.items.len - 1];
    }

    pub fn isEmpty(self: *Stack) bool {
        return self.values.items.len == 0;
    }

    pub fn size(self: *Stack) usize {
        return self.values.items.len;
    }
};

/// Local variables frame
pub const LocalsFrame = struct {
    values: std.ArrayListUnmanaged(engine.Value),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, count: usize) !LocalsFrame {
        var frame = LocalsFrame{
            .values = .empty,
            .allocator = allocator,
        };

        // Initialize locals to zero
        var i: usize = 0;
        while (i < count) : (i += 1) {
            try frame.values.append(allocator, engine.Value{ .i32 = 0 });
        }

        return frame;
    }

    pub fn deinit(self: *LocalsFrame) void {
        self.values.deinit(self.allocator);
    }

    pub fn get(self: *LocalsFrame, index: u32) !engine.Value {
        if (index >= self.values.items.len) return error.InvalidLocalIndex;
        return self.values.items[index];
    }

    pub fn set(self: *LocalsFrame, index: u32, value: engine.Value) !void {
        if (index >= self.values.items.len) return error.InvalidLocalIndex;
        self.values.items[index] = value;
    }
};

/// Control frame for blocks/loops/ifs
pub const ControlFrame = struct {
    opcode: Opcode, // block, loop, or if_
    start_pc: usize, // Start of block (for loops)
    end_pc: usize, // End of block
    stack_height: usize, // Stack height when entering block
    else_pc: ?usize, // Location of else branch (for if)
};

/// WASM bytecode interpreter
pub const Interpreter = struct {
    stack: Stack,
    locals: LocalsFrame,
    control_stack: std.ArrayListUnmanaged(ControlFrame),
    instance: *engine.Instance,
    allocator: std.mem.Allocator,
    globals: std.ArrayListUnmanaged(engine.Value),

    pub fn init(allocator: std.mem.Allocator, instance: *engine.Instance, local_count: usize) !Interpreter {
        return Interpreter{
            .stack = Stack.init(allocator),
            .locals = try LocalsFrame.init(allocator, local_count),
            .control_stack = .empty,
            .instance = instance,
            .allocator = allocator,
            .globals = .empty,
        };
    }

    pub fn deinit(self: *Interpreter) void {
        self.stack.deinit();
        self.locals.deinit();
        self.control_stack.deinit(self.allocator);
        self.globals.deinit(self.allocator);
    }

    pub fn setGlobal(self: *Interpreter, index: u32, value: engine.Value) !void {
        while (self.globals.items.len <= index) {
            try self.globals.append(self.allocator, engine.Value{ .i32 = 0 });
        }
        self.globals.items[index] = value;
    }

    pub fn getGlobal(self: *Interpreter, index: u32) !engine.Value {
        if (index >= self.globals.items.len) return error.InvalidGlobalIndex;
        return self.globals.items[index];
    }

    /// Find the end of a block/loop/if structure
    fn findBlockEnd(code: []const u8, start: usize) !usize {
        var pc = start;
        var depth: usize = 1;
        while (pc < code.len and depth > 0) {
            const op = code[pc];
            pc += 1;
            switch (op) {
                0x02, 0x03, 0x04 => { // block, loop, if
                    _ = try readLEB128(i32, code, &pc); // block type
                    depth += 1;
                },
                0x05 => {}, // else - same depth
                0x0B => depth -= 1, // end
                0x0C, 0x0D => _ = try readLEB128(u32, code, &pc), // br, br_if
                0x0E => { // br_table
                    const count = try readLEB128(u32, code, &pc);
                    var i: u32 = 0;
                    while (i <= count) : (i += 1) {
                        _ = try readLEB128(u32, code, &pc);
                    }
                },
                0x10, 0x11 => _ = try readLEB128(u32, code, &pc), // call, call_indirect
                0x20, 0x21, 0x22, 0x23, 0x24 => _ = try readLEB128(u32, code, &pc), // local/global ops
                0x28...0x3E => { // memory ops
                    _ = try readLEB128(u32, code, &pc);
                    _ = try readLEB128(u32, code, &pc);
                },
                0x3F, 0x40 => _ = try readLEB128(u32, code, &pc), // memory.size, memory.grow
                0x41 => _ = try readLEB128(i32, code, &pc), // i32.const
                0x42 => _ = try readLEB128(i64, code, &pc), // i64.const
                0x43 => pc += 4, // f32.const
                0x44 => pc += 8, // f64.const
                else => {},
            }
        }
        return pc;
    }

    /// Execute WASM bytecode
    pub fn execute(self: *Interpreter, code: []const u8) ![]engine.Value {
        var pc: usize = 0; // Program counter

        while (pc < code.len) {
            const opcode = @as(Opcode, @enumFromInt(code[pc]));
            pc += 1;

            switch (opcode) {
                // Control flow basics
                .unreachable_ => return error.Unreachable,
                .nop => {},

                // Structured control flow
                .block => {
                    _ = try readLEB128(i32, code, &pc); // block type
                    const end_pc = try findBlockEnd(code, pc);
                    try self.control_stack.append(self.allocator, ControlFrame{
                        .opcode = .block,
                        .start_pc = pc,
                        .end_pc = end_pc,
                        .stack_height = self.stack.size(),
                        .else_pc = null,
                    });
                },
                .loop => {
                    _ = try readLEB128(i32, code, &pc); // block type
                    const start_pc = pc;
                    const end_pc = try findBlockEnd(code, pc);
                    try self.control_stack.append(self.allocator, ControlFrame{
                        .opcode = .loop,
                        .start_pc = start_pc,
                        .end_pc = end_pc,
                        .stack_height = self.stack.size(),
                        .else_pc = null,
                    });
                },
                .if_ => {
                    _ = try readLEB128(i32, code, &pc); // block type
                    const condition = try self.stack.pop();
                    const end_pc = try findBlockEnd(code, pc);

                    if (condition.i32 != 0) {
                        // Execute if branch
                        try self.control_stack.append(self.allocator, ControlFrame{
                            .opcode = .if_,
                            .start_pc = pc,
                            .end_pc = end_pc,
                            .stack_height = self.stack.size(),
                            .else_pc = null,
                        });
                    } else {
                        // Skip to else or end
                        var depth: usize = 1;
                        while (pc < code.len and depth > 0) {
                            const op = code[pc];
                            pc += 1;
                            if (op == 0x04) { // if
                                _ = try readLEB128(i32, code, &pc);
                                depth += 1;
                            } else if (op == 0x05 and depth == 1) { // else at our level
                                try self.control_stack.append(self.allocator, ControlFrame{
                                    .opcode = .if_,
                                    .start_pc = pc,
                                    .end_pc = end_pc,
                                    .stack_height = self.stack.size(),
                                    .else_pc = null,
                                });
                                break;
                            } else if (op == 0x0B) { // end
                                depth -= 1;
                            }
                        }
                    }
                },
                .else_ => {
                    // Skip to end of if block
                    if (self.control_stack.items.len > 0) {
                        const frame = self.control_stack.pop().?;
                        pc = frame.end_pc;
                    }
                },
                .end => {
                    if (self.control_stack.items.len > 0) {
                        _ = self.control_stack.pop();
                    } else {
                        break; // End of function
                    }
                },
                .br => {
                    const depth = try readLEB128(u32, code, &pc);
                    if (depth >= self.control_stack.items.len) {
                        break; // Branch out of function
                    }
                    const target_idx = self.control_stack.items.len - 1 - depth;
                    const frame = self.control_stack.items[target_idx];
                    if (frame.opcode == .loop) {
                        pc = frame.start_pc; // Jump to loop start
                    } else {
                        pc = frame.end_pc; // Jump to block end
                        // Pop frames up to and including target
                        self.control_stack.shrinkRetainingCapacity(target_idx);
                    }
                },
                .br_if => {
                    const depth = try readLEB128(u32, code, &pc);
                    const condition = try self.stack.pop();
                    if (condition.i32 != 0) {
                        if (depth >= self.control_stack.items.len) {
                            break;
                        }
                        const target_idx = self.control_stack.items.len - 1 - depth;
                        const frame = self.control_stack.items[target_idx];
                        if (frame.opcode == .loop) {
                            pc = frame.start_pc;
                        } else {
                            pc = frame.end_pc;
                            self.control_stack.shrinkRetainingCapacity(target_idx);
                        }
                    }
                },
                .br_table => {
                    const count = try readLEB128(u32, code, &pc);
                    var targets: std.ArrayList(u32) = .empty;
                    defer targets.deinit(self.allocator);
                    var i: u32 = 0;
                    while (i <= count) : (i += 1) {
                        try targets.append(self.allocator, try readLEB128(u32, code, &pc));
                    }
                    const index = try self.stack.pop();
                    const depth = if (@as(u32, @bitCast(index.i32)) < count)
                        targets.items[@intCast(@as(u32, @bitCast(index.i32)))]
                    else
                        targets.items[count]; // default

                    if (depth >= self.control_stack.items.len) {
                        break;
                    }
                    const target_idx = self.control_stack.items.len - 1 - depth;
                    const frame = self.control_stack.items[target_idx];
                    if (frame.opcode == .loop) {
                        pc = frame.start_pc;
                    } else {
                        pc = frame.end_pc;
                        self.control_stack.shrinkRetainingCapacity(target_idx);
                    }
                },
                .return_ => break,
                .call => {
                    const func_idx = try readLEB128(u32, code, &pc);
                    // Function calls would require full function table support
                    // For now, log the call
                    std.debug.print("WASM call to function {d}\n", .{func_idx});
                },
                .call_indirect => {
                    const type_idx = try readLEB128(u32, code, &pc);
                    const table_idx = try readLEB128(u32, code, &pc);
                    const func_idx = try self.stack.pop();
                    std.debug.print("WASM call_indirect type={d} table={d} func={d}\n", .{ type_idx, table_idx, func_idx.i32 });
                },

                // Global variables
                .global_get => {
                    const index = try readLEB128(u32, code, &pc);
                    const value = try self.getGlobal(index);
                    try self.stack.push(value);
                },
                .global_set => {
                    const index = try readLEB128(u32, code, &pc);
                    const value = try self.stack.pop();
                    try self.setGlobal(index, value);
                },

                // Constants
                .i32_const => {
                    const value = try readLEB128(i32, code, &pc);
                    try self.stack.push(engine.Value{ .i32 = value });
                },
                .i64_const => {
                    const value = try readLEB128(i64, code, &pc);
                    try self.stack.push(engine.Value{ .i64 = value });
                },
                .f32_const => {
                    if (pc + 4 > code.len) return error.UnexpectedEnd;
                    const bits = std.mem.readInt(u32, code[pc..][0..4], .little);
                    pc += 4;
                    try self.stack.push(engine.Value{ .f32 = @bitCast(bits) });
                },
                .f64_const => {
                    if (pc + 8 > code.len) return error.UnexpectedEnd;
                    const bits = std.mem.readInt(u64, code[pc..][0..8], .little);
                    pc += 8;
                    try self.stack.push(engine.Value{ .f64 = @bitCast(bits) });
                },

                // Local variables
                .local_get => {
                    const index = try readLEB128(u32, code, &pc);
                    const value = try self.locals.get(index);
                    try self.stack.push(value);
                },
                .local_set => {
                    const index = try readLEB128(u32, code, &pc);
                    const value = try self.stack.pop();
                    try self.locals.set(index, value);
                },
                .local_tee => {
                    const index = try readLEB128(u32, code, &pc);
                    const value = try self.stack.peek();
                    try self.locals.set(index, value);
                },

                // i32 arithmetic
                .i32_add => {
                    const b = try self.stack.pop();
                    const a = try self.stack.pop();
                    try self.stack.push(engine.Value{ .i32 = a.i32 +% b.i32 });
                },
                .i32_sub => {
                    const b = try self.stack.pop();
                    const a = try self.stack.pop();
                    try self.stack.push(engine.Value{ .i32 = a.i32 -% b.i32 });
                },
                .i32_mul => {
                    const b = try self.stack.pop();
                    const a = try self.stack.pop();
                    try self.stack.push(engine.Value{ .i32 = a.i32 *% b.i32 });
                },
                .i32_div_s => {
                    const b = try self.stack.pop();
                    const a = try self.stack.pop();
                    if (b.i32 == 0) return error.DivisionByZero;
                    try self.stack.push(engine.Value{ .i32 = @divTrunc(a.i32, b.i32) });
                },
                .i32_div_u => {
                    const b = try self.stack.pop();
                    const a = try self.stack.pop();
                    const au = @as(u32, @bitCast(a.i32));
                    const bu = @as(u32, @bitCast(b.i32));
                    if (bu == 0) return error.DivisionByZero;
                    const result = @divTrunc(au, bu);
                    try self.stack.push(engine.Value{ .i32 = @bitCast(result) });
                },
                .i32_rem_s => {
                    const b = try self.stack.pop();
                    const a = try self.stack.pop();
                    if (b.i32 == 0) return error.DivisionByZero;
                    try self.stack.push(engine.Value{ .i32 = @rem(a.i32, b.i32) });
                },
                .i32_rem_u => {
                    const b = try self.stack.pop();
                    const a = try self.stack.pop();
                    const au = @as(u32, @bitCast(a.i32));
                    const bu = @as(u32, @bitCast(b.i32));
                    if (bu == 0) return error.DivisionByZero;
                    try self.stack.push(engine.Value{ .i32 = @bitCast(au % bu) });
                },

                // i32 bitwise
                .i32_and => {
                    const b = try self.stack.pop();
                    const a = try self.stack.pop();
                    try self.stack.push(engine.Value{ .i32 = a.i32 & b.i32 });
                },
                .i32_or => {
                    const b = try self.stack.pop();
                    const a = try self.stack.pop();
                    try self.stack.push(engine.Value{ .i32 = a.i32 | b.i32 });
                },
                .i32_xor => {
                    const b = try self.stack.pop();
                    const a = try self.stack.pop();
                    try self.stack.push(engine.Value{ .i32 = a.i32 ^ b.i32 });
                },
                .i32_shl => {
                    const b = try self.stack.pop();
                    const a = try self.stack.pop();
                    const shift = @as(u5, @intCast(@as(u32, @bitCast(b.i32)) % 32));
                    try self.stack.push(engine.Value{ .i32 = a.i32 << shift });
                },
                .i32_shr_s => {
                    const b = try self.stack.pop();
                    const a = try self.stack.pop();
                    const shift = @as(u5, @intCast(@as(u32, @bitCast(b.i32)) % 32));
                    try self.stack.push(engine.Value{ .i32 = a.i32 >> shift });
                },
                .i32_shr_u => {
                    const b = try self.stack.pop();
                    const a = try self.stack.pop();
                    const au = @as(u32, @bitCast(a.i32));
                    const shift = @as(u5, @intCast(@as(u32, @bitCast(b.i32)) % 32));
                    try self.stack.push(engine.Value{ .i32 = @bitCast(au >> shift) });
                },
                .i32_rotl => {
                    const b = try self.stack.pop();
                    const a = try self.stack.pop();
                    const au = @as(u32, @bitCast(a.i32));
                    const rotation = @as(u5, @intCast(@as(u32, @bitCast(b.i32)) % 32));
                    try self.stack.push(engine.Value{ .i32 = @bitCast(std.math.rotl(u32, au, rotation)) });
                },
                .i32_rotr => {
                    const b = try self.stack.pop();
                    const a = try self.stack.pop();
                    const au = @as(u32, @bitCast(a.i32));
                    const rotation = @as(u5, @intCast(@as(u32, @bitCast(b.i32)) % 32));
                    try self.stack.push(engine.Value{ .i32 = @bitCast(std.math.rotr(u32, au, rotation)) });
                },
                .i32_clz => {
                    const a = try self.stack.pop();
                    const au = @as(u32, @bitCast(a.i32));
                    try self.stack.push(engine.Value{ .i32 = @intCast(@clz(au)) });
                },
                .i32_ctz => {
                    const a = try self.stack.pop();
                    const au = @as(u32, @bitCast(a.i32));
                    try self.stack.push(engine.Value{ .i32 = @intCast(@ctz(au)) });
                },
                .i32_popcnt => {
                    const a = try self.stack.pop();
                    const au = @as(u32, @bitCast(a.i32));
                    try self.stack.push(engine.Value{ .i32 = @intCast(@popCount(au)) });
                },

                // i32 comparisons
                .i32_eqz => {
                    const a = try self.stack.pop();
                    try self.stack.push(engine.Value{ .i32 = if (a.i32 == 0) 1 else 0 });
                },
                .i32_eq => {
                    const b = try self.stack.pop();
                    const a = try self.stack.pop();
                    try self.stack.push(engine.Value{ .i32 = if (a.i32 == b.i32) 1 else 0 });
                },
                .i32_ne => {
                    const b = try self.stack.pop();
                    const a = try self.stack.pop();
                    try self.stack.push(engine.Value{ .i32 = if (a.i32 != b.i32) 1 else 0 });
                },
                .i32_lt_s => {
                    const b = try self.stack.pop();
                    const a = try self.stack.pop();
                    try self.stack.push(engine.Value{ .i32 = if (a.i32 < b.i32) 1 else 0 });
                },
                .i32_lt_u => {
                    const b = try self.stack.pop();
                    const a = try self.stack.pop();
                    const au = @as(u32, @bitCast(a.i32));
                    const bu = @as(u32, @bitCast(b.i32));
                    try self.stack.push(engine.Value{ .i32 = if (au < bu) 1 else 0 });
                },
                .i32_gt_s => {
                    const b = try self.stack.pop();
                    const a = try self.stack.pop();
                    try self.stack.push(engine.Value{ .i32 = if (a.i32 > b.i32) 1 else 0 });
                },
                .i32_gt_u => {
                    const b = try self.stack.pop();
                    const a = try self.stack.pop();
                    const au = @as(u32, @bitCast(a.i32));
                    const bu = @as(u32, @bitCast(b.i32));
                    try self.stack.push(engine.Value{ .i32 = if (au > bu) 1 else 0 });
                },
                .i32_le_s => {
                    const b = try self.stack.pop();
                    const a = try self.stack.pop();
                    try self.stack.push(engine.Value{ .i32 = if (a.i32 <= b.i32) 1 else 0 });
                },
                .i32_le_u => {
                    const b = try self.stack.pop();
                    const a = try self.stack.pop();
                    const au = @as(u32, @bitCast(a.i32));
                    const bu = @as(u32, @bitCast(b.i32));
                    try self.stack.push(engine.Value{ .i32 = if (au <= bu) 1 else 0 });
                },
                .i32_ge_s => {
                    const b = try self.stack.pop();
                    const a = try self.stack.pop();
                    try self.stack.push(engine.Value{ .i32 = if (a.i32 >= b.i32) 1 else 0 });
                },
                .i32_ge_u => {
                    const b = try self.stack.pop();
                    const a = try self.stack.pop();
                    const au = @as(u32, @bitCast(a.i32));
                    const bu = @as(u32, @bitCast(b.i32));
                    try self.stack.push(engine.Value{ .i32 = if (au >= bu) 1 else 0 });
                },

                // i64 comparisons
                .i64_eqz => {
                    const a = try self.stack.pop();
                    try self.stack.push(engine.Value{ .i32 = if (a.i64 == 0) 1 else 0 });
                },

                // i64 operations
                .i64_add => {
                    const b = try self.stack.pop();
                    const a = try self.stack.pop();
                    try self.stack.push(engine.Value{ .i64 = a.i64 +% b.i64 });
                },
                .i64_sub => {
                    const b = try self.stack.pop();
                    const a = try self.stack.pop();
                    try self.stack.push(engine.Value{ .i64 = a.i64 -% b.i64 });
                },
                .i64_mul => {
                    const b = try self.stack.pop();
                    const a = try self.stack.pop();
                    try self.stack.push(engine.Value{ .i64 = a.i64 *% b.i64 });
                },

                // Memory operations
                .i32_load => {
                    const memory = self.instance.getMemory() orelse return error.NoMemory;
                    _ = try readLEB128(u32, code, &pc); // alignment
                    const offset = try readLEB128(u32, code, &pc);
                    const addr = try self.stack.pop();
                    const value = try memory.readInt(i32, @intCast(addr.i32 + @as(i32, @intCast(offset))));
                    try self.stack.push(engine.Value{ .i32 = value });
                },
                .i64_load => {
                    const memory = self.instance.getMemory() orelse return error.NoMemory;
                    _ = try readLEB128(u32, code, &pc); // alignment
                    const offset = try readLEB128(u32, code, &pc);
                    const addr = try self.stack.pop();
                    const value = try memory.readInt(i64, @intCast(addr.i32 + @as(i32, @intCast(offset))));
                    try self.stack.push(engine.Value{ .i64 = value });
                },
                .f32_load => {
                    const memory = self.instance.getMemory() orelse return error.NoMemory;
                    _ = try readLEB128(u32, code, &pc); // alignment
                    const offset = try readLEB128(u32, code, &pc);
                    const addr = try self.stack.pop();
                    const bits = try memory.readInt(u32, @intCast(addr.i32 + @as(i32, @intCast(offset))));
                    try self.stack.push(engine.Value{ .f32 = @bitCast(bits) });
                },
                .f64_load => {
                    const memory = self.instance.getMemory() orelse return error.NoMemory;
                    _ = try readLEB128(u32, code, &pc); // alignment
                    const offset = try readLEB128(u32, code, &pc);
                    const addr = try self.stack.pop();
                    const bits = try memory.readInt(u64, @intCast(addr.i32 + @as(i32, @intCast(offset))));
                    try self.stack.push(engine.Value{ .f64 = @bitCast(bits) });
                },
                .i32_load8_s => {
                    const memory = self.instance.getMemory() orelse return error.NoMemory;
                    _ = try readLEB128(u32, code, &pc); // alignment
                    const offset = try readLEB128(u32, code, &pc);
                    const addr = try self.stack.pop();
                    const value = try memory.readInt(i8, @intCast(addr.i32 + @as(i32, @intCast(offset))));
                    try self.stack.push(engine.Value{ .i32 = @as(i32, value) });
                },
                .i32_load8_u => {
                    const memory = self.instance.getMemory() orelse return error.NoMemory;
                    _ = try readLEB128(u32, code, &pc); // alignment
                    const offset = try readLEB128(u32, code, &pc);
                    const addr = try self.stack.pop();
                    const value = try memory.readInt(u8, @intCast(addr.i32 + @as(i32, @intCast(offset))));
                    try self.stack.push(engine.Value{ .i32 = @as(i32, value) });
                },
                .i32_load16_s => {
                    const memory = self.instance.getMemory() orelse return error.NoMemory;
                    _ = try readLEB128(u32, code, &pc); // alignment
                    const offset = try readLEB128(u32, code, &pc);
                    const addr = try self.stack.pop();
                    const value = try memory.readInt(i16, @intCast(addr.i32 + @as(i32, @intCast(offset))));
                    try self.stack.push(engine.Value{ .i32 = @as(i32, value) });
                },
                .i32_load16_u => {
                    const memory = self.instance.getMemory() orelse return error.NoMemory;
                    _ = try readLEB128(u32, code, &pc); // alignment
                    const offset = try readLEB128(u32, code, &pc);
                    const addr = try self.stack.pop();
                    const value = try memory.readInt(u16, @intCast(addr.i32 + @as(i32, @intCast(offset))));
                    try self.stack.push(engine.Value{ .i32 = @as(i32, value) });
                },
                .i64_load8_s => {
                    const memory = self.instance.getMemory() orelse return error.NoMemory;
                    _ = try readLEB128(u32, code, &pc); // alignment
                    const offset = try readLEB128(u32, code, &pc);
                    const addr = try self.stack.pop();
                    const value = try memory.readInt(i8, @intCast(addr.i32 + @as(i32, @intCast(offset))));
                    try self.stack.push(engine.Value{ .i64 = @as(i64, value) });
                },
                .i64_load8_u => {
                    const memory = self.instance.getMemory() orelse return error.NoMemory;
                    _ = try readLEB128(u32, code, &pc); // alignment
                    const offset = try readLEB128(u32, code, &pc);
                    const addr = try self.stack.pop();
                    const value = try memory.readInt(u8, @intCast(addr.i32 + @as(i32, @intCast(offset))));
                    try self.stack.push(engine.Value{ .i64 = @as(i64, value) });
                },
                .i64_load16_s => {
                    const memory = self.instance.getMemory() orelse return error.NoMemory;
                    _ = try readLEB128(u32, code, &pc); // alignment
                    const offset = try readLEB128(u32, code, &pc);
                    const addr = try self.stack.pop();
                    const value = try memory.readInt(i16, @intCast(addr.i32 + @as(i32, @intCast(offset))));
                    try self.stack.push(engine.Value{ .i64 = @as(i64, value) });
                },
                .i64_load16_u => {
                    const memory = self.instance.getMemory() orelse return error.NoMemory;
                    _ = try readLEB128(u32, code, &pc); // alignment
                    const offset = try readLEB128(u32, code, &pc);
                    const addr = try self.stack.pop();
                    const value = try memory.readInt(u16, @intCast(addr.i32 + @as(i32, @intCast(offset))));
                    try self.stack.push(engine.Value{ .i64 = @as(i64, value) });
                },
                .i64_load32_s => {
                    const memory = self.instance.getMemory() orelse return error.NoMemory;
                    _ = try readLEB128(u32, code, &pc); // alignment
                    const offset = try readLEB128(u32, code, &pc);
                    const addr = try self.stack.pop();
                    const value = try memory.readInt(i32, @intCast(addr.i32 + @as(i32, @intCast(offset))));
                    try self.stack.push(engine.Value{ .i64 = @as(i64, value) });
                },
                .i64_load32_u => {
                    const memory = self.instance.getMemory() orelse return error.NoMemory;
                    _ = try readLEB128(u32, code, &pc); // alignment
                    const offset = try readLEB128(u32, code, &pc);
                    const addr = try self.stack.pop();
                    const value = try memory.readInt(u32, @intCast(addr.i32 + @as(i32, @intCast(offset))));
                    try self.stack.push(engine.Value{ .i64 = @as(i64, value) });
                },
                .i32_store => {
                    const memory = self.instance.getMemory() orelse return error.NoMemory;
                    _ = try readLEB128(u32, code, &pc); // alignment
                    const offset = try readLEB128(u32, code, &pc);
                    const value = try self.stack.pop();
                    const addr = try self.stack.pop();
                    try memory.writeInt(i32, @intCast(addr.i32 + @as(i32, @intCast(offset))), value.i32);
                },
                .i64_store => {
                    const memory = self.instance.getMemory() orelse return error.NoMemory;
                    _ = try readLEB128(u32, code, &pc); // alignment
                    const offset = try readLEB128(u32, code, &pc);
                    const value = try self.stack.pop();
                    const addr = try self.stack.pop();
                    try memory.writeInt(i64, @intCast(addr.i32 + @as(i32, @intCast(offset))), value.i64);
                },
                .f32_store => {
                    const memory = self.instance.getMemory() orelse return error.NoMemory;
                    _ = try readLEB128(u32, code, &pc); // alignment
                    const offset = try readLEB128(u32, code, &pc);
                    const value = try self.stack.pop();
                    try memory.writeInt(u32, @intCast((try self.stack.pop()).i32 + @as(i32, @intCast(offset))), @bitCast(value.f32));
                },
                .f64_store => {
                    const memory = self.instance.getMemory() orelse return error.NoMemory;
                    _ = try readLEB128(u32, code, &pc); // alignment
                    const offset = try readLEB128(u32, code, &pc);
                    const value = try self.stack.pop();
                    try memory.writeInt(u64, @intCast((try self.stack.pop()).i32 + @as(i32, @intCast(offset))), @bitCast(value.f64));
                },
                .i32_store8 => {
                    const memory = self.instance.getMemory() orelse return error.NoMemory;
                    _ = try readLEB128(u32, code, &pc); // alignment
                    const offset = try readLEB128(u32, code, &pc);
                    const value = try self.stack.pop();
                    const addr = try self.stack.pop();
                    try memory.writeInt(u8, @intCast(addr.i32 + @as(i32, @intCast(offset))), @truncate(@as(u32, @bitCast(value.i32))));
                },
                .i32_store16 => {
                    const memory = self.instance.getMemory() orelse return error.NoMemory;
                    _ = try readLEB128(u32, code, &pc); // alignment
                    const offset = try readLEB128(u32, code, &pc);
                    const value = try self.stack.pop();
                    const addr = try self.stack.pop();
                    try memory.writeInt(u16, @intCast(addr.i32 + @as(i32, @intCast(offset))), @truncate(@as(u32, @bitCast(value.i32))));
                },
                .i64_store8 => {
                    const memory = self.instance.getMemory() orelse return error.NoMemory;
                    _ = try readLEB128(u32, code, &pc); // alignment
                    const offset = try readLEB128(u32, code, &pc);
                    const value = try self.stack.pop();
                    const addr = try self.stack.pop();
                    try memory.writeInt(u8, @intCast(addr.i32 + @as(i32, @intCast(offset))), @truncate(@as(u64, @bitCast(value.i64))));
                },
                .i64_store16 => {
                    const memory = self.instance.getMemory() orelse return error.NoMemory;
                    _ = try readLEB128(u32, code, &pc); // alignment
                    const offset = try readLEB128(u32, code, &pc);
                    const value = try self.stack.pop();
                    const addr = try self.stack.pop();
                    try memory.writeInt(u16, @intCast(addr.i32 + @as(i32, @intCast(offset))), @truncate(@as(u64, @bitCast(value.i64))));
                },
                .i64_store32 => {
                    const memory = self.instance.getMemory() orelse return error.NoMemory;
                    _ = try readLEB128(u32, code, &pc); // alignment
                    const offset = try readLEB128(u32, code, &pc);
                    const value = try self.stack.pop();
                    const addr = try self.stack.pop();
                    try memory.writeInt(u32, @intCast(addr.i32 + @as(i32, @intCast(offset))), @truncate(@as(u64, @bitCast(value.i64))));
                },
                .memory_size => {
                    const memory = self.instance.getMemory() orelse return error.NoMemory;
                    _ = try readLEB128(u32, code, &pc); // reserved byte (always 0x00)
                    try self.stack.push(engine.Value{ .i32 = @intCast(memory.size() / 65536) });
                },
                .memory_grow => {
                    const memory = self.instance.getMemory() orelse return error.NoMemory;
                    _ = try readLEB128(u32, code, &pc); // reserved byte
                    const pages = try self.stack.pop();
                    const old_pages = memory.grow(@intCast(@as(u32, @bitCast(pages.i32)))) catch {
                        // Memory grow failed, return -1
                        try self.stack.push(engine.Value{ .i32 = -1 });
                        continue;
                    };
                    try self.stack.push(engine.Value{ .i32 = @intCast(old_pages) });
                },

                // Stack operations
                .drop => {
                    _ = try self.stack.pop();
                },
                .select => {
                    const c = try self.stack.pop();
                    const val2 = try self.stack.pop();
                    const val1 = try self.stack.pop();
                    try self.stack.push(if (c.i32 != 0) val1 else val2);
                },

                else => {
                    std.debug.print("Unimplemented opcode: 0x{x:0>2}\n", .{@intFromEnum(opcode)});
                    return error.UnimplementedOpcode;
                },
            }
        }

        // Collect return values from stack
        if (self.stack.isEmpty()) {
            return &[_]engine.Value{};
        }

        // For now, return all remaining stack values
        const result = try self.allocator.alloc(engine.Value, self.stack.size());
        for (result, 0..) |*val, i| {
            val.* = self.stack.values.items[i];
        }

        return result;
    }
};

/// Read LEB128 encoded integer
fn readLEB128(comptime T: type, data: []const u8, pc: *usize) !T {
    var result: T = 0;
    var shift: u7 = 0;
    var i: usize = 0;

    while (i < @sizeOf(T) + 1) : (i += 1) {
        if (pc.* >= data.len) return error.UnexpectedEnd;

        const byte = data[pc.*];
        pc.* += 1;

        const value = @as(T, byte & 0x7F);
        result |= value << @intCast(shift);

        if ((byte & 0x80) == 0) {
            // Sign extend for signed types
            if (@typeInfo(T).int.signedness == .signed and shift < @bitSizeOf(T) and (byte & 0x40) != 0) {
                result |= @as(T, -1) << @intCast(shift);
            }
            return result;
        }

        shift += 7;
    }

    return error.InvalidLEB128;
}

test "interpreter basic arithmetic" {
    const allocator = std.testing.allocator;

    var instance = engine.Instance.init(allocator);
    defer instance.deinit();

    var interp = try Interpreter.init(allocator, &instance, 0);
    defer interp.deinit();

    // Simple bytecode: 40 + 2 = 42
    const bytecode = [_]u8{
        @intFromEnum(Opcode.i32_const), 40, // i32.const 40
        @intFromEnum(Opcode.i32_const), 2, // i32.const 2
        @intFromEnum(Opcode.i32_add), // i32.add
        @intFromEnum(Opcode.end), // end
    };

    const results = try interp.execute(&bytecode);
    defer allocator.free(results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqual(@as(i32, 42), results[0].i32);
}
