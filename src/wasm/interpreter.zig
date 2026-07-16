const std = @import("std");
const engine = @import("engine.zig");
const policy_mod = @import("policy.zig");

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
        // Cap operand-stack depth: untrusted code that pushes in a loop must
        // fail closed with StackOverflow rather than exhausting memory.
        if (self.values.items.len >= limits.max_value_stack) return error.StackOverflow;
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

/// Execution resource ceilings applied while running untrusted WASM. Every
/// bound is driven by attacker-controlled bytecode (operand stack pushes,
/// nested blocks, `br_table` targets, global indices, and loop iterations), so
/// each must be finite and fail closed rather than growing without limit or
/// spinning forever. The values are generous for legitimate modules but cap
/// the blast radius of a hostile one.
pub const limits = struct {
    /// Maximum operand stack depth (slots).
    pub const max_value_stack: usize = 64 * 1024;
    /// Maximum nesting of block/loop/if control frames.
    pub const max_control_depth: usize = 4 * 1024;
    /// Maximum `br_table` target entries decoded from one instruction.
    pub const max_br_table_targets: u32 = 64 * 1024;
    /// Maximum interpreter global slots addressable by `global_set`.
    pub const max_globals: u32 = 64 * 1024;
    /// Instruction budget ("fuel") consumed per `execute` call; a module that
    /// exceeds it (e.g. an unbounded `loop`/`br`) is aborted.
    pub const max_instructions: u64 = 100_000_000;
};

/// WASM bytecode interpreter
pub const Interpreter = struct {
    stack: Stack,
    locals: LocalsFrame,
    control_stack: std.ArrayListUnmanaged(ControlFrame),
    instance: *engine.Instance,
    allocator: std.mem.Allocator,
    globals: std.ArrayListUnmanaged(engine.Value),
    /// Instruction budget for a single `execute` call. Defaults to
    /// `limits.max_instructions`; an embedder may lower it to tighten the
    /// ceiling for particularly untrusted modules.
    fuel_limit: u64 = limits.max_instructions,
    /// Control-frame nesting ceiling for this run. Defaults to the hardcoded
    /// `limits.max_control_depth` blast-radius cap; `bindPolicy` may only lower
    /// it so a restrictive policy's stack-depth budget is actually enforced.
    control_depth_limit: usize = limits.max_control_depth,

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

    /// Bind an execution policy so its limits are enforced structurally by this
    /// interpreter rather than living as standalone `check*` methods a caller
    /// could forget to invoke. Each budget is *tightened* (never loosened): the
    /// control-depth ceiling and instruction fuel drop to the policy's values
    /// when stricter, and the instance's linear-memory page cap is clamped to
    /// the policy's byte budget so `memory.grow` fails closed past it.
    pub fn bindPolicy(self: *Interpreter, p: *const policy_mod.WasmPolicy) void {
        self.control_depth_limit = @min(self.control_depth_limit, p.max_stack_depth);
        self.fuel_limit = @min(self.fuel_limit, p.max_instructions);

        const policy_pages = p.maxWasmPages();
        if (self.instance.getMemory()) |mem| {
            mem.max_pages = if (mem.max_pages) |declared|
                @min(declared, policy_pages)
            else
                policy_pages;
        }
    }

    /// Append a control frame, rejecting excessive nesting. Untrusted bytecode
    /// can nest blocks/loops/ifs arbitrarily; without a ceiling the control
    /// stack grows until allocation fails. The ceiling is the policy-tightened
    /// `control_depth_limit` (defaults to `limits.max_control_depth`).
    fn pushControl(self: *Interpreter, frame: ControlFrame) !void {
        if (self.control_stack.items.len >= self.control_depth_limit) {
            return error.CallStackExhausted;
        }
        try self.control_stack.append(self.allocator, frame);
    }

    pub fn setGlobal(self: *Interpreter, index: u32, value: engine.Value) !void {
        // A hostile `global_set` index would otherwise drive an unbounded
        // append loop (up to 4 billion zero entries) — reject it up front.
        if (index >= limits.max_globals) return error.InvalidGlobalIndex;
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
        var fuel: u64 = self.fuel_limit;

        while (pc < code.len) {
            // Instruction budget: an unbounded loop (e.g. `loop … br 0 … end`)
            // would otherwise spin forever. Charge one unit per instruction and
            // abort when exhausted.
            if (fuel == 0) return error.InstructionBudgetExceeded;
            fuel -= 1;

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
                    try self.pushControl(ControlFrame{
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
                    try self.pushControl(ControlFrame{
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
                        try self.pushControl(ControlFrame{
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
                                try self.pushControl(ControlFrame{
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
                    // `count` is attacker-controlled; without a ceiling the
                    // following loop allocates up to ~4 billion entries.
                    if (count > limits.max_br_table_targets) return error.TooManyBranchTargets;
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
                    // This interpreter has no call-frame machinery: it executes a
                    // single function body with one locals frame and no function
                    // index space to dispatch into. The previous behaviour decoded
                    // the callee index, printed it, and fell through — silently
                    // leaving the operand stack in the pre-call shape (no arguments
                    // consumed, no results pushed) so every instruction afterward
                    // ran against corrupt data. Fail closed instead: a module that
                    // performs a call is rejected, never mis-executed. Real direct
                    // calls (type-checked frames, locals, results, traps) are a
                    // separate, unshipped feature.
                    _ = try readLEB128(u32, code, &pc);
                    return error.UnsupportedCall;
                },
                .call_indirect => {
                    // Same rationale as `.call`: without a function table bound to
                    // executable bodies and a frame stack, an indirect call cannot
                    // be performed. Decode the immediates so the refusal is
                    // unambiguous about which opcode it saw, then fail closed
                    // rather than pop the index and drift on.
                    _ = try readLEB128(u32, code, &pc); // type index
                    _ = try readLEB128(u32, code, &pc); // table index
                    return error.UnsupportedIndirectCall;
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
                    const value = try memory.readInt(i32, try effAddr(addr.i32, offset));
                    try self.stack.push(engine.Value{ .i32 = value });
                },
                .i64_load => {
                    const memory = self.instance.getMemory() orelse return error.NoMemory;
                    _ = try readLEB128(u32, code, &pc); // alignment
                    const offset = try readLEB128(u32, code, &pc);
                    const addr = try self.stack.pop();
                    const value = try memory.readInt(i64, try effAddr(addr.i32, offset));
                    try self.stack.push(engine.Value{ .i64 = value });
                },
                .f32_load => {
                    const memory = self.instance.getMemory() orelse return error.NoMemory;
                    _ = try readLEB128(u32, code, &pc); // alignment
                    const offset = try readLEB128(u32, code, &pc);
                    const addr = try self.stack.pop();
                    const bits = try memory.readInt(u32, try effAddr(addr.i32, offset));
                    try self.stack.push(engine.Value{ .f32 = @bitCast(bits) });
                },
                .f64_load => {
                    const memory = self.instance.getMemory() orelse return error.NoMemory;
                    _ = try readLEB128(u32, code, &pc); // alignment
                    const offset = try readLEB128(u32, code, &pc);
                    const addr = try self.stack.pop();
                    const bits = try memory.readInt(u64, try effAddr(addr.i32, offset));
                    try self.stack.push(engine.Value{ .f64 = @bitCast(bits) });
                },
                .i32_load8_s => {
                    const memory = self.instance.getMemory() orelse return error.NoMemory;
                    _ = try readLEB128(u32, code, &pc); // alignment
                    const offset = try readLEB128(u32, code, &pc);
                    const addr = try self.stack.pop();
                    const value = try memory.readInt(i8, try effAddr(addr.i32, offset));
                    try self.stack.push(engine.Value{ .i32 = @as(i32, value) });
                },
                .i32_load8_u => {
                    const memory = self.instance.getMemory() orelse return error.NoMemory;
                    _ = try readLEB128(u32, code, &pc); // alignment
                    const offset = try readLEB128(u32, code, &pc);
                    const addr = try self.stack.pop();
                    const value = try memory.readInt(u8, try effAddr(addr.i32, offset));
                    try self.stack.push(engine.Value{ .i32 = @as(i32, value) });
                },
                .i32_load16_s => {
                    const memory = self.instance.getMemory() orelse return error.NoMemory;
                    _ = try readLEB128(u32, code, &pc); // alignment
                    const offset = try readLEB128(u32, code, &pc);
                    const addr = try self.stack.pop();
                    const value = try memory.readInt(i16, try effAddr(addr.i32, offset));
                    try self.stack.push(engine.Value{ .i32 = @as(i32, value) });
                },
                .i32_load16_u => {
                    const memory = self.instance.getMemory() orelse return error.NoMemory;
                    _ = try readLEB128(u32, code, &pc); // alignment
                    const offset = try readLEB128(u32, code, &pc);
                    const addr = try self.stack.pop();
                    const value = try memory.readInt(u16, try effAddr(addr.i32, offset));
                    try self.stack.push(engine.Value{ .i32 = @as(i32, value) });
                },
                .i64_load8_s => {
                    const memory = self.instance.getMemory() orelse return error.NoMemory;
                    _ = try readLEB128(u32, code, &pc); // alignment
                    const offset = try readLEB128(u32, code, &pc);
                    const addr = try self.stack.pop();
                    const value = try memory.readInt(i8, try effAddr(addr.i32, offset));
                    try self.stack.push(engine.Value{ .i64 = @as(i64, value) });
                },
                .i64_load8_u => {
                    const memory = self.instance.getMemory() orelse return error.NoMemory;
                    _ = try readLEB128(u32, code, &pc); // alignment
                    const offset = try readLEB128(u32, code, &pc);
                    const addr = try self.stack.pop();
                    const value = try memory.readInt(u8, try effAddr(addr.i32, offset));
                    try self.stack.push(engine.Value{ .i64 = @as(i64, value) });
                },
                .i64_load16_s => {
                    const memory = self.instance.getMemory() orelse return error.NoMemory;
                    _ = try readLEB128(u32, code, &pc); // alignment
                    const offset = try readLEB128(u32, code, &pc);
                    const addr = try self.stack.pop();
                    const value = try memory.readInt(i16, try effAddr(addr.i32, offset));
                    try self.stack.push(engine.Value{ .i64 = @as(i64, value) });
                },
                .i64_load16_u => {
                    const memory = self.instance.getMemory() orelse return error.NoMemory;
                    _ = try readLEB128(u32, code, &pc); // alignment
                    const offset = try readLEB128(u32, code, &pc);
                    const addr = try self.stack.pop();
                    const value = try memory.readInt(u16, try effAddr(addr.i32, offset));
                    try self.stack.push(engine.Value{ .i64 = @as(i64, value) });
                },
                .i64_load32_s => {
                    const memory = self.instance.getMemory() orelse return error.NoMemory;
                    _ = try readLEB128(u32, code, &pc); // alignment
                    const offset = try readLEB128(u32, code, &pc);
                    const addr = try self.stack.pop();
                    const value = try memory.readInt(i32, try effAddr(addr.i32, offset));
                    try self.stack.push(engine.Value{ .i64 = @as(i64, value) });
                },
                .i64_load32_u => {
                    const memory = self.instance.getMemory() orelse return error.NoMemory;
                    _ = try readLEB128(u32, code, &pc); // alignment
                    const offset = try readLEB128(u32, code, &pc);
                    const addr = try self.stack.pop();
                    const value = try memory.readInt(u32, try effAddr(addr.i32, offset));
                    try self.stack.push(engine.Value{ .i64 = @as(i64, value) });
                },
                .i32_store => {
                    const memory = self.instance.getMemory() orelse return error.NoMemory;
                    _ = try readLEB128(u32, code, &pc); // alignment
                    const offset = try readLEB128(u32, code, &pc);
                    const value = try self.stack.pop();
                    const addr = try self.stack.pop();
                    try memory.writeInt(i32, try effAddr(addr.i32, offset), value.i32);
                },
                .i64_store => {
                    const memory = self.instance.getMemory() orelse return error.NoMemory;
                    _ = try readLEB128(u32, code, &pc); // alignment
                    const offset = try readLEB128(u32, code, &pc);
                    const value = try self.stack.pop();
                    const addr = try self.stack.pop();
                    try memory.writeInt(i64, try effAddr(addr.i32, offset), value.i64);
                },
                .f32_store => {
                    const memory = self.instance.getMemory() orelse return error.NoMemory;
                    _ = try readLEB128(u32, code, &pc); // alignment
                    const offset = try readLEB128(u32, code, &pc);
                    const value = try self.stack.pop();
                    try memory.writeInt(u32, try effAddr((try self.stack.pop()).i32, offset), @bitCast(value.f32));
                },
                .f64_store => {
                    const memory = self.instance.getMemory() orelse return error.NoMemory;
                    _ = try readLEB128(u32, code, &pc); // alignment
                    const offset = try readLEB128(u32, code, &pc);
                    const value = try self.stack.pop();
                    try memory.writeInt(u64, try effAddr((try self.stack.pop()).i32, offset), @bitCast(value.f64));
                },
                .i32_store8 => {
                    const memory = self.instance.getMemory() orelse return error.NoMemory;
                    _ = try readLEB128(u32, code, &pc); // alignment
                    const offset = try readLEB128(u32, code, &pc);
                    const value = try self.stack.pop();
                    const addr = try self.stack.pop();
                    try memory.writeInt(u8, try effAddr(addr.i32, offset), @truncate(@as(u32, @bitCast(value.i32))));
                },
                .i32_store16 => {
                    const memory = self.instance.getMemory() orelse return error.NoMemory;
                    _ = try readLEB128(u32, code, &pc); // alignment
                    const offset = try readLEB128(u32, code, &pc);
                    const value = try self.stack.pop();
                    const addr = try self.stack.pop();
                    try memory.writeInt(u16, try effAddr(addr.i32, offset), @truncate(@as(u32, @bitCast(value.i32))));
                },
                .i64_store8 => {
                    const memory = self.instance.getMemory() orelse return error.NoMemory;
                    _ = try readLEB128(u32, code, &pc); // alignment
                    const offset = try readLEB128(u32, code, &pc);
                    const value = try self.stack.pop();
                    const addr = try self.stack.pop();
                    try memory.writeInt(u8, try effAddr(addr.i32, offset), @truncate(@as(u64, @bitCast(value.i64))));
                },
                .i64_store16 => {
                    const memory = self.instance.getMemory() orelse return error.NoMemory;
                    _ = try readLEB128(u32, code, &pc); // alignment
                    const offset = try readLEB128(u32, code, &pc);
                    const value = try self.stack.pop();
                    const addr = try self.stack.pop();
                    try memory.writeInt(u16, try effAddr(addr.i32, offset), @truncate(@as(u64, @bitCast(value.i64))));
                },
                .i64_store32 => {
                    const memory = self.instance.getMemory() orelse return error.NoMemory;
                    _ = try readLEB128(u32, code, &pc); // alignment
                    const offset = try readLEB128(u32, code, &pc);
                    const value = try self.stack.pop();
                    const addr = try self.stack.pop();
                    try memory.writeInt(u32, try effAddr(addr.i32, offset), @truncate(@as(u64, @bitCast(value.i64))));
                },
                .memory_size => {
                    const memory = self.instance.getMemory() orelse return error.NoMemory;
                    _ = try readLEB128(u32, code, &pc); // reserved byte (always 0x00)
                    // `Memory.size()` already returns the count in 64 KiB WASM
                    // pages, which is exactly what `memory.size` yields per the
                    // spec — do not divide by the page size again.
                    try self.stack.push(engine.Value{ .i32 = @intCast(memory.size()) });
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
                    // Any opcode outside the implemented MVP subset (floats,
                    // most i64 ops, table/bulk-memory, SIMD, …) fails closed
                    // rather than being silently skipped: a module is never
                    // partially executed with instructions quietly dropped.
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

/// Compute a WASM linear-memory effective address: the popped base operand
/// (reinterpreted as u32 per the spec) plus the static `offset` immediate.
/// The addition is checked in u32 with `@addWithOverflow`, so a hostile
/// base/offset pair yields `error.OutOfBounds` in every build mode rather than
/// panicking on i32 overflow or on `@intCast` of a negative address — both of
/// which the old `@intCast(base + @intCast(offset))` form did in safe builds.
fn effAddr(base: i32, offset: u32) !u32 {
    const b: u32 = @bitCast(base);
    return std.math.add(u32, b, offset) catch return error.OutOfBounds;
}

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

test "a direct call fails closed instead of silently mis-executing" {
    // Regression guard for the removed log-only `.call`: the interpreter has no
    // call-frame machinery, so a module that performs a call must be rejected
    // (error.UnsupportedCall) rather than printing the index and running on with
    // a corrupt operand stack. The push before the call proves the pre-call
    // stack state is irrelevant — the call itself refuses.
    const allocator = std.testing.allocator;
    var instance = engine.Instance.init(allocator);
    defer instance.deinit();
    var interp = try Interpreter.init(allocator, &instance, 0);
    defer interp.deinit();

    const bytecode = [_]u8{
        @intFromEnum(Opcode.i32_const), 7, // i32.const 7
        @intFromEnum(Opcode.call), 0, // call 0
        @intFromEnum(Opcode.end),
    };
    try std.testing.expectError(error.UnsupportedCall, interp.execute(&bytecode));
}

test "an indirect call fails closed instead of silently mis-executing" {
    // Companion to the direct-call guard: `.call_indirect` likewise refuses.
    const allocator = std.testing.allocator;
    var instance = engine.Instance.init(allocator);
    defer instance.deinit();
    var interp = try Interpreter.init(allocator, &instance, 0);
    defer interp.deinit();

    const bytecode = [_]u8{
        @intFromEnum(Opcode.i32_const), 0, // table slot
        @intFromEnum(Opcode.call_indirect), 0, 0, // type idx, table idx
        @intFromEnum(Opcode.end),
    };
    try std.testing.expectError(error.UnsupportedIndirectCall, interp.execute(&bytecode));
}

test "an unimplemented opcode fails closed rather than being skipped" {
    // A module using an opcode outside the implemented MVP subset (here f32.add,
    // 0x92) must abort with error.UnimplementedOpcode, not silently advance and
    // partially execute. Guards item "reject unsupported opcodes; do not
    // partially execute a module while silently skipping instructions".
    const allocator = std.testing.allocator;
    var instance = engine.Instance.init(allocator);
    defer instance.deinit();
    var interp = try Interpreter.init(allocator, &instance, 0);
    defer interp.deinit();

    const bytecode = [_]u8{
        0x92, // f32.add — recognized WASM opcode, not implemented here
        @intFromEnum(Opcode.end),
    };
    try std.testing.expectError(error.UnimplementedOpcode, interp.execute(&bytecode));
}

test "operand stack depth is bounded" {
    const allocator = std.testing.allocator;
    var stack = Stack.init(allocator);
    defer stack.deinit();

    var i: usize = 0;
    while (i < limits.max_value_stack) : (i += 1) {
        try stack.push(engine.Value{ .i32 = 0 });
    }
    // One past the ceiling must fail closed rather than growing memory.
    try std.testing.expectError(error.StackOverflow, stack.push(engine.Value{ .i32 = 0 }));
}

test "control nesting depth is bounded" {
    const allocator = std.testing.allocator;
    var instance = engine.Instance.init(allocator);
    defer instance.deinit();
    var interp = try Interpreter.init(allocator, &instance, 0);
    defer interp.deinit();

    const frame = ControlFrame{
        .opcode = .block,
        .start_pc = 0,
        .end_pc = 0,
        .stack_height = 0,
        .else_pc = null,
    };
    var i: usize = 0;
    while (i < limits.max_control_depth) : (i += 1) {
        try interp.pushControl(frame);
    }
    try std.testing.expectError(error.CallStackExhausted, interp.pushControl(frame));
}

test "setGlobal rejects an out-of-range index instead of mass-allocating" {
    const allocator = std.testing.allocator;
    var instance = engine.Instance.init(allocator);
    defer instance.deinit();
    var interp = try Interpreter.init(allocator, &instance, 0);
    defer interp.deinit();

    // A hostile index would otherwise append billions of zero globals.
    try std.testing.expectError(
        error.InvalidGlobalIndex,
        interp.setGlobal(0xFFFF_FFFF, engine.Value{ .i32 = 1 }),
    );
}

test "br_table target count is bounded" {
    const allocator = std.testing.allocator;
    var instance = engine.Instance.init(allocator);
    defer instance.deinit();
    var interp = try Interpreter.init(allocator, &instance, 0);
    defer interp.deinit();

    // br_table with a u32-max LEB128 count (0xFFFFFFFF) must be rejected
    // before the target-decoding loop allocates.
    const bytecode = [_]u8{
        @intFromEnum(Opcode.br_table),
        0xFF, 0xFF, 0xFF, 0xFF, 0x0F, // LEB128 0xFFFF_FFFF
    };
    try std.testing.expectError(error.TooManyBranchTargets, interp.execute(&bytecode));
}

test "load effective address overflow fails closed" {
    const allocator = std.testing.allocator;
    var instance = engine.Instance.init(allocator);
    defer instance.deinit();

    // Give the instance a small memory so a valid load path exists.
    const mem = try allocator.create(engine.Memory);
    mem.* = try engine.Memory.init(allocator, 1, 1);
    instance.memory = mem;

    var interp = try Interpreter.init(allocator, &instance, 0);
    defer interp.deinit();

    // i32.const 0xFFFFFFFF; i32.load align=0 offset=16  -> base+offset wraps u32
    // Old code: @intCast(negative i32) panics in safe builds. Now: OutOfBounds.
    const bytecode = [_]u8{
        @intFromEnum(Opcode.i32_const), 0xFF, 0xFF, 0xFF, 0xFF, 0x0F, // -1
        @intFromEnum(Opcode.i32_load), 0x00, 0x10, // align=0, offset=16
        @intFromEnum(Opcode.end),
    };
    try std.testing.expectError(error.OutOfBounds, interp.execute(&bytecode));
}

test "effAddr rejects u32 overflow but resolves valid addresses" {
    try std.testing.expectEqual(@as(u32, 132), try effAddr(100, 32));
    try std.testing.expectError(error.OutOfBounds, effAddr(-1, 1)); // 0xFFFFFFFF + 1
    try std.testing.expectError(error.OutOfBounds, effAddr(@bitCast(@as(u32, 0xFFFF_FFF0)), 0x20));
}

test "instruction budget aborts an unbounded loop" {
    const allocator = std.testing.allocator;
    var instance = engine.Instance.init(allocator);
    defer instance.deinit();
    var interp = try Interpreter.init(allocator, &instance, 0);
    defer interp.deinit();
    interp.fuel_limit = 10_000; // tighten so the test is fast

    // loop { br 0 } — an infinite loop that must be aborted by fuel, not hang.
    const bytecode = [_]u8{
        @intFromEnum(Opcode.loop), 0x40, // loop, empty block type
        @intFromEnum(Opcode.br),  0x00, // br 0 -> back to loop start
        @intFromEnum(Opcode.end),
    };
    try std.testing.expectError(error.InstructionBudgetExceeded, interp.execute(&bytecode));
}

test "a bound policy tightens the interpreter's control-depth ceiling" {
    // A restrictive policy's max_stack_depth must actually cap control-frame
    // nesting during execution, not merely exist as a standalone check. With
    // the policy bound, the (much larger) hardcoded limits.max_control_depth is
    // superseded: the 9th push past a depth-8 policy fails closed.
    const allocator = std.testing.allocator;
    var instance = engine.Instance.init(allocator);
    defer instance.deinit();

    var policy = policy_mod.WasmPolicy.init(allocator);
    defer policy.deinit();
    policy.max_stack_depth = 8;

    var interp = try Interpreter.init(allocator, &instance, 0);
    defer interp.deinit();
    interp.bindPolicy(&policy);
    try std.testing.expectEqual(@as(usize, 8), interp.control_depth_limit);

    const frame = ControlFrame{
        .opcode = .block,
        .start_pc = 0,
        .end_pc = 0,
        .stack_height = 0,
        .else_pc = null,
    };
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        try interp.pushControl(frame);
    }
    try std.testing.expectError(error.CallStackExhausted, interp.pushControl(frame));
}

test "a bound policy lowers the interpreter's instruction budget" {
    // The policy's max_instructions must tighten (never raise) the fuel budget,
    // and the lowered budget must actually abort a runaway loop.
    const allocator = std.testing.allocator;
    var instance = engine.Instance.init(allocator);
    defer instance.deinit();

    var policy = policy_mod.WasmPolicy.init(allocator);
    defer policy.deinit();
    policy.max_instructions = 100;

    var interp = try Interpreter.init(allocator, &instance, 0);
    defer interp.deinit();
    interp.bindPolicy(&policy);
    try std.testing.expectEqual(@as(u64, 100), interp.fuel_limit);

    const bytecode = [_]u8{
        @intFromEnum(Opcode.loop), 0x40, // loop, empty block type
        @intFromEnum(Opcode.br),  0x00, // br 0 -> spin
        @intFromEnum(Opcode.end),
    };
    try std.testing.expectError(error.InstructionBudgetExceeded, interp.execute(&bytecode));
}

test "a bound policy clamps the instance memory page ceiling" {
    // A restrictive policy (10 MB = 160 pages) must clamp linear-memory growth
    // even when the module declared a larger maximum. Growth up to the policy
    // cap succeeds; one page past it fails closed via memory.grow.
    const allocator = std.testing.allocator;
    var instance = engine.Instance.init(allocator);
    defer instance.deinit();

    // Module declares 1 min / 1024 max pages — far above the policy budget.
    const mem = try allocator.create(engine.Memory);
    mem.* = try engine.Memory.init(allocator, 1, 1024);
    instance.memory = mem;

    var policy = policy_mod.WasmPolicy.restrictive(allocator);
    defer policy.deinit();

    var interp = try Interpreter.init(allocator, &instance, 0);
    defer interp.deinit();
    interp.bindPolicy(&policy);

    try std.testing.expectEqual(@as(?u32, 160), mem.max_pages);
    _ = try mem.grow(159); // 1 -> 160 pages, exactly the policy ceiling
    try std.testing.expectError(error.MemoryGrowFailed, mem.grow(1));
}

// ---------------------------------------------------------------------------
// MVP behavioral conformance battery (item 1481).
//
// These tests pin the *observable semantics* of the interpreter's supported
// bytecode subset (arithmetic/bitwise/shift/rotate, comparisons, i64 ops,
// locals, globals, control flow, and linear-memory load/store) plus its
// fail-closed reaction to malformed and adversarial bytecode. They are written
// against raw bytecode because the engine has no binary module parser yet, so
// the official `.wast` conformance corpus cannot be driven end-to-end; that
// remains deferred to the binary-parser work (item 1407). What CAN be locked
// in is that every opcode this interpreter claims to implement produces the
// spec result, and that anything outside the subset — or any truncated/overlong
// immediate — is rejected rather than silently mis-executed.

/// Run a self-contained program with no locals/memory and return its single
/// i32 result. Errors propagate so `expectError` can assert fail-closed cases.
fn execI32(allocator: std.mem.Allocator, code: []const u8) !i32 {
    var instance = engine.Instance.init(allocator);
    defer instance.deinit();
    var interp = try Interpreter.init(allocator, &instance, 0);
    defer interp.deinit();
    const results = try interp.execute(code);
    defer allocator.free(results);
    return results[0].i32;
}

/// i64 counterpart of `execI32`.
fn execI64(allocator: std.mem.Allocator, code: []const u8) !i64 {
    var instance = engine.Instance.init(allocator);
    defer instance.deinit();
    var interp = try Interpreter.init(allocator, &instance, 0);
    defer interp.deinit();
    const results = try interp.execute(code);
    defer allocator.free(results);
    return results[0].i64;
}

/// Run a program against a fresh linear memory. Caller frees the result slice.
fn execMem(allocator: std.mem.Allocator, min_pages: u32, max_pages: ?u32, code: []const u8) ![]engine.Value {
    var instance = engine.Instance.init(allocator);
    defer instance.deinit();
    const mem = try allocator.create(engine.Memory);
    mem.* = try engine.Memory.init(allocator, min_pages, max_pages);
    instance.memory = mem;
    var interp = try Interpreter.init(allocator, &instance, 0);
    defer interp.deinit();
    return interp.execute(code);
}

test "i32 arithmetic opcodes compute spec results" {
    const a = std.testing.allocator;
    const O = Opcode;
    // sub: 40 - 2 = 38
    try std.testing.expectEqual(@as(i32, 38), try execI32(a, &[_]u8{
        @intFromEnum(O.i32_const), 40, @intFromEnum(O.i32_const), 2, @intFromEnum(O.i32_sub), @intFromEnum(O.end),
    }));
    // mul: 6 * 7 = 42
    try std.testing.expectEqual(@as(i32, 42), try execI32(a, &[_]u8{
        @intFromEnum(O.i32_const), 6, @intFromEnum(O.i32_const), 7, @intFromEnum(O.i32_mul), @intFromEnum(O.end),
    }));
    // div_s: 42 / 6 = 7 (signed truncating)
    try std.testing.expectEqual(@as(i32, 7), try execI32(a, &[_]u8{
        @intFromEnum(O.i32_const), 42, @intFromEnum(O.i32_const), 6, @intFromEnum(O.i32_div_s), @intFromEnum(O.end),
    }));
    // div_u: (-2 as u32 = 0xFFFF_FFFE) / 2 = 0x7FFF_FFFF, distinct from div_s.
    try std.testing.expectEqual(@as(i32, 2147483647), try execI32(a, &[_]u8{
        @intFromEnum(O.i32_const), 0x7E, @intFromEnum(O.i32_const), 2, @intFromEnum(O.i32_div_u), @intFromEnum(O.end),
    }));
    // rem_s: 43 % 5 = 3
    try std.testing.expectEqual(@as(i32, 3), try execI32(a, &[_]u8{
        @intFromEnum(O.i32_const), 43, @intFromEnum(O.i32_const), 5, @intFromEnum(O.i32_rem_s), @intFromEnum(O.end),
    }));
}

test "i32 bitwise and shift opcodes compute spec results" {
    const a = std.testing.allocator;
    const O = Opcode;
    // and: 6 & 3 = 2
    try std.testing.expectEqual(@as(i32, 2), try execI32(a, &[_]u8{
        @intFromEnum(O.i32_const), 6, @intFromEnum(O.i32_const), 3, @intFromEnum(O.i32_and), @intFromEnum(O.end),
    }));
    // or: 4 | 1 = 5
    try std.testing.expectEqual(@as(i32, 5), try execI32(a, &[_]u8{
        @intFromEnum(O.i32_const), 4, @intFromEnum(O.i32_const), 1, @intFromEnum(O.i32_or), @intFromEnum(O.end),
    }));
    // xor: 5 ^ 3 = 6
    try std.testing.expectEqual(@as(i32, 6), try execI32(a, &[_]u8{
        @intFromEnum(O.i32_const), 5, @intFromEnum(O.i32_const), 3, @intFromEnum(O.i32_xor), @intFromEnum(O.end),
    }));
    // shl with a shift count of 33: the spec masks the count mod 32, so
    // 1 << 33 behaves as 1 << 1 = 2 rather than shifting out to 0.
    try std.testing.expectEqual(@as(i32, 2), try execI32(a, &[_]u8{
        @intFromEnum(O.i32_const), 1, @intFromEnum(O.i32_const), 33, @intFromEnum(O.i32_shl), @intFromEnum(O.end),
    }));
    // shr_u: 8 >> 2 = 2
    try std.testing.expectEqual(@as(i32, 2), try execI32(a, &[_]u8{
        @intFromEnum(O.i32_const), 8, @intFromEnum(O.i32_const), 2, @intFromEnum(O.i32_shr_u), @intFromEnum(O.end),
    }));
}

test "i32 bit-count and eqz opcodes compute spec results" {
    const a = std.testing.allocator;
    const O = Opcode;
    // clz(1) = 31
    try std.testing.expectEqual(@as(i32, 31), try execI32(a, &[_]u8{
        @intFromEnum(O.i32_const), 1, @intFromEnum(O.i32_clz), @intFromEnum(O.end),
    }));
    // ctz(8) = 3
    try std.testing.expectEqual(@as(i32, 3), try execI32(a, &[_]u8{
        @intFromEnum(O.i32_const), 8, @intFromEnum(O.i32_ctz), @intFromEnum(O.end),
    }));
    // popcnt(7) = 3
    try std.testing.expectEqual(@as(i32, 3), try execI32(a, &[_]u8{
        @intFromEnum(O.i32_const), 7, @intFromEnum(O.i32_popcnt), @intFromEnum(O.end),
    }));
    // eqz(0) = 1
    try std.testing.expectEqual(@as(i32, 1), try execI32(a, &[_]u8{
        @intFromEnum(O.i32_const), 0, @intFromEnum(O.i32_eqz), @intFromEnum(O.end),
    }));
}

test "i32 comparisons distinguish signed and unsigned operands" {
    const a = std.testing.allocator;
    const O = Opcode;
    // lt_s(-1, 1) = 1 : signed, -1 < 1.
    try std.testing.expectEqual(@as(i32, 1), try execI32(a, &[_]u8{
        @intFromEnum(O.i32_const), 0x7F, @intFromEnum(O.i32_const), 1, @intFromEnum(O.i32_lt_s), @intFromEnum(O.end),
    }));
    // lt_u(0xFFFF_FFFF, 1) = 0 : unsigned, 0xFFFF_FFFF is the largest value.
    try std.testing.expectEqual(@as(i32, 0), try execI32(a, &[_]u8{
        @intFromEnum(O.i32_const), 0x7F, @intFromEnum(O.i32_const), 1, @intFromEnum(O.i32_lt_u), @intFromEnum(O.end),
    }));
    // gt_u(0xFFFF_FFFF, 1) = 1
    try std.testing.expectEqual(@as(i32, 1), try execI32(a, &[_]u8{
        @intFromEnum(O.i32_const), 0x7F, @intFromEnum(O.i32_const), 1, @intFromEnum(O.i32_gt_u), @intFromEnum(O.end),
    }));
    // eq(5, 5) = 1 ; ne(5, 4) = 1
    try std.testing.expectEqual(@as(i32, 1), try execI32(a, &[_]u8{
        @intFromEnum(O.i32_const), 5, @intFromEnum(O.i32_const), 5, @intFromEnum(O.i32_eq), @intFromEnum(O.end),
    }));
    try std.testing.expectEqual(@as(i32, 1), try execI32(a, &[_]u8{
        @intFromEnum(O.i32_const), 5, @intFromEnum(O.i32_const), 4, @intFromEnum(O.i32_ne), @intFromEnum(O.end),
    }));
}

test "i64 arithmetic and eqz compute spec results" {
    const a = std.testing.allocator;
    const O = Opcode;
    // add/sub/mul all land on 42.
    try std.testing.expectEqual(@as(i64, 42), try execI64(a, &[_]u8{
        @intFromEnum(O.i64_const), 40, @intFromEnum(O.i64_const), 2, @intFromEnum(O.i64_add), @intFromEnum(O.end),
    }));
    try std.testing.expectEqual(@as(i64, 42), try execI64(a, &[_]u8{
        @intFromEnum(O.i64_const), 50, @intFromEnum(O.i64_const), 8, @intFromEnum(O.i64_sub), @intFromEnum(O.end),
    }));
    try std.testing.expectEqual(@as(i64, 42), try execI64(a, &[_]u8{
        @intFromEnum(O.i64_const), 6, @intFromEnum(O.i64_const), 7, @intFromEnum(O.i64_mul), @intFromEnum(O.end),
    }));
    // i64.eqz pushes an i32 boolean.
    try std.testing.expectEqual(@as(i32, 1), try execI32(a, &[_]u8{
        @intFromEnum(O.i64_const), 0, @intFromEnum(O.i64_eqz), @intFromEnum(O.end),
    }));
}

test "local get/set/tee round-trip through the locals frame" {
    const allocator = std.testing.allocator;
    const O = Opcode;
    var instance = engine.Instance.init(allocator);
    defer instance.deinit();
    var interp = try Interpreter.init(allocator, &instance, 1); // one local
    defer interp.deinit();

    // local0 = 42; push 7; local.tee 0 (writes local0=7, leaves 7 on stack);
    // local.get 0 pushes the freshly written 7 -> stack [7, 7]. Proves set
    // overwrote the initial 42 and tee both wrote-through and preserved the top.
    const code = [_]u8{
        @intFromEnum(O.i32_const), 42, @intFromEnum(O.local_set), 0,
        @intFromEnum(O.i32_const), 7,  @intFromEnum(O.local_tee), 0,
        @intFromEnum(O.local_get), 0,  @intFromEnum(O.end),
    };
    const results = try interp.execute(&code);
    defer allocator.free(results);
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqual(@as(i32, 7), results[0].i32);
    try std.testing.expectEqual(@as(i32, 7), results[1].i32);
}

test "global set/get round-trip" {
    const a = std.testing.allocator;
    const O = Opcode;
    // global0 = 30; global.get 0 -> 30.
    try std.testing.expectEqual(@as(i32, 30), try execI32(a, &[_]u8{
        @intFromEnum(O.i32_const),  30, @intFromEnum(O.global_set), 0,
        @intFromEnum(O.global_get), 0,  @intFromEnum(O.end),
    }));
}

test "if/else selects the correct arm on the condition" {
    const a = std.testing.allocator;
    const O = Opcode;
    // condition true -> then-arm (10)
    try std.testing.expectEqual(@as(i32, 10), try execI32(a, &[_]u8{
        @intFromEnum(O.i32_const), 1,                   @intFromEnum(O.if_),   0x40,
        @intFromEnum(O.i32_const), 10,                  @intFromEnum(O.else_), @intFromEnum(O.i32_const),
        20,                        @intFromEnum(O.end),
    }));
    // condition false -> else-arm (20)
    try std.testing.expectEqual(@as(i32, 20), try execI32(a, &[_]u8{
        @intFromEnum(O.i32_const), 0,                   @intFromEnum(O.if_),   0x40,
        @intFromEnum(O.i32_const), 10,                  @intFromEnum(O.else_), @intFromEnum(O.i32_const),
        20,                        @intFromEnum(O.end),
    }));
}

test "a terminating loop with br_if runs the expected iterations" {
    const allocator = std.testing.allocator;
    const O = Opcode;
    var instance = engine.Instance.init(allocator);
    defer instance.deinit();
    var interp = try Interpreter.init(allocator, &instance, 1); // counter local
    defer interp.deinit();

    // local0 = 3 (counter); global0 = 0 (accumulator)
    // loop: global0 += 1; local0 -= 1; br_if 0 while local0 != 0
    // after loop: global.get 0 -> 3 (loop body ran exactly 3 times, terminating).
    const code = [_]u8{
        @intFromEnum(O.i32_const), 3,                         @intFromEnum(O.local_set),  0,
        @intFromEnum(O.i32_const), 0,                         @intFromEnum(O.global_set), 0,
        @intFromEnum(O.loop),      0x40,                      @intFromEnum(O.global_get), 0,
        @intFromEnum(O.i32_const), 1,                         @intFromEnum(O.i32_add),    @intFromEnum(O.global_set),
        0,                         @intFromEnum(O.local_get), 0,                          @intFromEnum(O.i32_const),
        1,                         @intFromEnum(O.i32_sub),   @intFromEnum(O.local_tee),  0,
        @intFromEnum(O.br_if),     0,                         @intFromEnum(O.end),        @intFromEnum(O.global_get),
        0,
    };
    const results = try interp.execute(&code);
    defer allocator.free(results);
    try std.testing.expectEqual(@as(i32, 3), results[results.len - 1].i32);
}

test "i32 load/store round-trips through linear memory" {
    const allocator = std.testing.allocator;
    const O = Opcode;
    // store 42 at address 0, then load it back.
    const code = [_]u8{
        @intFromEnum(O.i32_const), 0, @intFromEnum(O.i32_const), 42,   @intFromEnum(O.i32_store), 0x00,                0x00,
        @intFromEnum(O.i32_const), 0, @intFromEnum(O.i32_load),  0x00, 0x00,                      @intFromEnum(O.end),
    };
    const results = try execMem(allocator, 1, 4, &code);
    defer allocator.free(results);
    try std.testing.expectEqual(@as(i32, 42), results[0].i32);
}

test "sub-word store truncates and load sign-extends" {
    const allocator = std.testing.allocator;
    const O = Opcode;
    // store byte 128 (0x80) at address 0, then read it back both ways:
    // load8_u -> 128 (zero-extended), load8_s -> -128 (sign-extended).
    const code = [_]u8{
        @intFromEnum(O.i32_const), 0,    @intFromEnum(O.i32_const),   0x80, 0x01, @intFromEnum(O.i32_store8), 0x00, 0x00,
        @intFromEnum(O.i32_const), 0,    @intFromEnum(O.i32_load8_u), 0x00, 0x00, @intFromEnum(O.i32_const),  0,    @intFromEnum(O.i32_load8_s),
        0x00,                      0x00, @intFromEnum(O.end),
    };
    const results = try execMem(allocator, 1, 4, &code);
    defer allocator.free(results);
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqual(@as(i32, 128), results[0].i32);
    try std.testing.expectEqual(@as(i32, -128), results[1].i32);
}

test "memory.size reports pages and memory.grow returns the old page count" {
    const allocator = std.testing.allocator;
    const O = Opcode;
    // memory.size on a 1-page memory must report 1 page — regression guard for
    // the double `/ 65536` that made a 1-page memory report 0.
    const size_code = [_]u8{ @intFromEnum(O.memory_size), 0x00, @intFromEnum(O.end) };
    const size_results = try execMem(allocator, 1, 4, &size_code);
    defer allocator.free(size_results);
    try std.testing.expectEqual(@as(i32, 1), size_results[0].i32);

    // grow by 2 pages: memory.grow returns the old size (1), memory.size is now 3.
    const grow_code = [_]u8{
        @intFromEnum(O.i32_const),   2,    @intFromEnum(O.memory_grow), 0x00,
        @intFromEnum(O.memory_size), 0x00, @intFromEnum(O.end),
    };
    const grow_results = try execMem(allocator, 1, 4, &grow_code);
    defer allocator.free(grow_results);
    try std.testing.expectEqual(@as(usize, 2), grow_results.len);
    try std.testing.expectEqual(@as(i32, 1), grow_results[0].i32); // old page count
    try std.testing.expectEqual(@as(i32, 3), grow_results[1].i32); // new page count
}

test "memory.grow past the maximum returns -1 without trapping" {
    const allocator = std.testing.allocator;
    const O = Opcode;
    // Growing a 1-page/1-page-max memory by 5 must fail per spec by pushing -1,
    // not by trapping or actually allocating.
    const code = [_]u8{
        @intFromEnum(O.i32_const), 5, @intFromEnum(O.memory_grow), 0x00, @intFromEnum(O.end),
    };
    const results = try execMem(allocator, 1, 1, &code);
    defer allocator.free(results);
    try std.testing.expectEqual(@as(i32, -1), results[0].i32);
}

test "a truncated LEB128 immediate fails closed" {
    // i32.const with a continuation byte but no following byte: the decoder must
    // stop with UnexpectedEnd rather than reading past the code slice.
    const a = std.testing.allocator;
    try std.testing.expectError(error.UnexpectedEnd, execI32(a, &[_]u8{
        @intFromEnum(Opcode.i32_const), 0x80,
    }));
}

test "an overlong LEB128 immediate fails closed" {
    // Five continuation bytes for an i32 immediate exceed the maximum encoding
    // length and must be rejected as InvalidLEB128, not decoded to a garbage
    // value.
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidLEB128, execI32(a, &[_]u8{
        @intFromEnum(Opcode.i32_const), 0x80, 0x80, 0x80, 0x80, 0x80,
    }));
}

test "a truncated f32.const immediate fails closed" {
    const a = std.testing.allocator;
    // f32.const needs 4 little-endian bytes; only 2 are present.
    try std.testing.expectError(error.UnexpectedEnd, execI32(a, &[_]u8{
        @intFromEnum(Opcode.f32_const), 0x00, 0x00,
    }));
}

test "a truncated f64.const immediate fails closed" {
    const a = std.testing.allocator;
    // f64.const needs 8 little-endian bytes; only 1 is present.
    try std.testing.expectError(error.UnexpectedEnd, execI32(a, &[_]u8{
        @intFromEnum(Opcode.f64_const), 0x00,
    }));
}

test "popping an empty operand stack fails closed" {
    const a = std.testing.allocator;
    // i32.add with nothing on the stack must underflow, not read stale memory.
    try std.testing.expectError(error.StackUnderflow, execI32(a, &[_]u8{
        @intFromEnum(Opcode.i32_add), @intFromEnum(Opcode.end),
    }));
}

test "integer division and remainder by zero trap" {
    const a = std.testing.allocator;
    const O = Opcode;
    try std.testing.expectError(error.DivisionByZero, execI32(a, &[_]u8{
        @intFromEnum(O.i32_const), 5, @intFromEnum(O.i32_const), 0, @intFromEnum(O.i32_div_s), @intFromEnum(O.end),
    }));
    try std.testing.expectError(error.DivisionByZero, execI32(a, &[_]u8{
        @intFromEnum(O.i32_const), 5, @intFromEnum(O.i32_const), 0, @intFromEnum(O.i32_rem_s), @intFromEnum(O.end),
    }));
}

test "the unreachable opcode traps" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.Unreachable, execI32(a, &[_]u8{
        @intFromEnum(Opcode.unreachable_), @intFromEnum(Opcode.end),
    }));
}

test "an out-of-range local index fails closed" {
    const a = std.testing.allocator;
    // local.get 0 with zero locals declared must be rejected, not read OOB.
    try std.testing.expectError(error.InvalidLocalIndex, execI32(a, &[_]u8{
        @intFromEnum(Opcode.local_get), 0, @intFromEnum(Opcode.end),
    }));
}
