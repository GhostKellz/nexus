const std = @import("std");

/// Work-Stealing Scheduler for Multi-threaded Task Execution
///
/// Implements a work-stealing algorithm where idle workers can steal tasks
/// from busy workers' queues, ensuring efficient load balancing across threads.

pub const Error = error{
    SchedulerShutdown,
    QueueFull,
    NoWorkAvailable,
    WorkerSpawnFailed,
};

/// Task priority levels
pub const Priority = enum(u8) {
    low = 0,
    normal = 1,
    high = 2,
    critical = 3,
};

/// Task function signature
pub const TaskFn = *const fn (context: ?*anyopaque) void;

/// A unit of work to be executed
pub const Task = struct {
    func: TaskFn,
    context: ?*anyopaque = null,
    priority: Priority = .normal,
    /// For tracking/debugging
    id: u64 = 0,
};

/// Lock-free work-stealing deque (double-ended queue)
/// Based on Chase-Lev work-stealing deque algorithm
pub fn WorkStealingDeque(comptime T: type) type {
    return struct {
        const Self = @This();
        const INITIAL_CAPACITY = 1024;

        /// Circular buffer
        buffer: []T,
        /// Bottom index (where owner pushes/pops)
        bottom: std.atomic.Value(i64),
        /// Top index (where thieves steal from)
        top: std.atomic.Value(i64),
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) !Self {
            const buffer = try allocator.alloc(T, INITIAL_CAPACITY);
            return Self{
                .buffer = buffer,
                .bottom = std.atomic.Value(i64).init(0),
                .top = std.atomic.Value(i64).init(0),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buffer);
        }

        /// Push a task to the bottom (owner only)
        pub fn push(self: *Self, task: T) !void {
            const b = self.bottom.load(.seq_cst);
            const t = self.top.load(.acquire);
            const size = b - t;

            if (size >= @as(i64, @intCast(self.buffer.len))) {
                return Error.QueueFull;
            }

            const index: usize = @intCast(@mod(b, @as(i64, @intCast(self.buffer.len))));
            self.buffer[index] = task;

            std.atomic.fence(.release);
            self.bottom.store(b + 1, .release);
        }

        /// Pop a task from the bottom (owner only)
        pub fn pop(self: *Self) ?T {
            var b = self.bottom.load(.seq_cst);
            b -= 1;
            self.bottom.store(b, .seq_cst);

            std.atomic.fence(.seq_cst);

            const t = self.top.load(.seq_cst);

            if (t <= b) {
                // Non-empty
                const index: usize = @intCast(@mod(b, @as(i64, @intCast(self.buffer.len))));
                const task = self.buffer[index];

                if (t == b) {
                    // Last element - race with steal
                    if (self.top.cmpxchgWeak(t, t + 1, .seq_cst, .seq_cst)) |_| {
                        // Lost race
                        self.bottom.store(t + 1, .seq_cst);
                        return null;
                    }
                    self.bottom.store(t + 1, .seq_cst);
                }
                return task;
            }

            // Empty
            self.bottom.store(t, .seq_cst);
            return null;
        }

        /// Steal a task from the top (other workers)
        pub fn steal(self: *Self) ?T {
            const t = self.top.load(.acquire);

            std.atomic.fence(.seq_cst);

            const b = self.bottom.load(.acquire);

            if (t >= b) {
                return null; // Empty
            }

            const index: usize = @intCast(@mod(t, @as(i64, @intCast(self.buffer.len))));
            const task = self.buffer[index];

            if (self.top.cmpxchgWeak(t, t + 1, .seq_cst, .seq_cst)) |_| {
                // Lost race with another thief
                return null;
            }

            return task;
        }

        /// Check if the deque is empty
        pub fn isEmpty(self: *Self) bool {
            const t = self.top.load(.acquire);
            const b = self.bottom.load(.acquire);
            return t >= b;
        }

        /// Get approximate size
        pub fn size(self: *Self) usize {
            const t = self.top.load(.acquire);
            const b = self.bottom.load(.acquire);
            if (b > t) {
                return @intCast(b - t);
            }
            return 0;
        }
    };
}

/// Worker thread state
pub const Worker = struct {
    id: usize,
    thread: ?std.Thread = null,
    local_queue: WorkStealingDeque(Task),
    scheduler: *Scheduler,
    is_running: std.atomic.Value(bool),
    tasks_executed: std.atomic.Value(u64),
    tasks_stolen: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator, id: usize, scheduler: *Scheduler) !Worker {
        return Worker{
            .id = id,
            .local_queue = try WorkStealingDeque(Task).init(allocator),
            .scheduler = scheduler,
            .is_running = std.atomic.Value(bool).init(false),
            .tasks_executed = std.atomic.Value(u64).init(0),
            .tasks_stolen = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *Worker) void {
        self.local_queue.deinit();
    }

    /// Start the worker thread
    pub fn start(self: *Worker) !void {
        self.is_running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, workerLoop, .{self});
    }

    /// Stop the worker thread
    pub fn stop(self: *Worker) void {
        self.is_running.store(false, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    /// Main worker loop
    fn workerLoop(self: *Worker) void {
        while (self.is_running.load(.acquire)) {
            // Try to get work from local queue first
            if (self.local_queue.pop()) |task| {
                self.executeTask(task);
                continue;
            }

            // Try to steal from other workers
            if (self.trySteal()) |task| {
                _ = self.tasks_stolen.fetchAdd(1, .relaxed);
                self.executeTask(task);
                continue;
            }

            // Try global queue
            if (self.scheduler.globalQueue.pop()) |task| {
                self.executeTask(task);
                continue;
            }

            // No work available, yield
            std.Thread.yield() catch {};
        }
    }

    /// Try to steal work from another worker
    fn trySteal(self: *Worker) ?Task {
        const num_workers = self.scheduler.workers.len;
        if (num_workers <= 1) return null;

        // Start from a random worker to avoid contention
        var prng = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
        const start: usize = prng.random().int(usize) % num_workers;

        var i: usize = 0;
        while (i < num_workers) : (i += 1) {
            const victim_id = (start + i) % num_workers;
            if (victim_id == self.id) continue;

            if (self.scheduler.workers[victim_id].local_queue.steal()) |task| {
                return task;
            }
        }

        return null;
    }

    fn executeTask(self: *Worker, task: Task) void {
        task.func(task.context);
        _ = self.tasks_executed.fetchAdd(1, .relaxed);
    }
};

/// Work-Stealing Scheduler
pub const Scheduler = struct {
    workers: []Worker,
    /// Global queue for tasks not assigned to specific workers
    globalQueue: WorkStealingDeque(Task),
    /// Number of worker threads
    num_workers: usize,
    /// Total tasks submitted
    tasks_submitted: std.atomic.Value(u64),
    /// Next task ID
    next_task_id: std.atomic.Value(u64),
    /// Is the scheduler running
    is_running: std.atomic.Value(bool),
    /// Round-robin counter for task distribution
    next_worker: std.atomic.Value(usize),
    allocator: std.mem.Allocator,

    /// Initialize scheduler with specified number of workers
    /// If num_workers is 0, uses the number of CPU cores
    pub fn init(allocator: std.mem.Allocator, num_workers: usize) !*Scheduler {
        const actual_workers = if (num_workers == 0) std.Thread.getCpuCount() catch 4 else num_workers;

        const scheduler = try allocator.create(Scheduler);
        errdefer allocator.destroy(scheduler);

        scheduler.* = Scheduler{
            .workers = undefined,
            .globalQueue = try WorkStealingDeque(Task).init(allocator),
            .num_workers = actual_workers,
            .tasks_submitted = std.atomic.Value(u64).init(0),
            .next_task_id = std.atomic.Value(u64).init(1),
            .is_running = std.atomic.Value(bool).init(false),
            .next_worker = std.atomic.Value(usize).init(0),
            .allocator = allocator,
        };

        // Create workers
        scheduler.workers = try allocator.alloc(Worker, actual_workers);
        for (scheduler.workers, 0..) |*worker, i| {
            worker.* = try Worker.init(allocator, i, scheduler);
        }

        return scheduler;
    }

    pub fn deinit(self: *Scheduler) void {
        self.shutdown();
        for (self.workers) |*worker| {
            worker.deinit();
        }
        self.allocator.free(self.workers);
        self.globalQueue.deinit();
        self.allocator.destroy(self);
    }

    /// Start all worker threads
    pub fn start(self: *Scheduler) !void {
        self.is_running.store(true, .release);
        for (self.workers) |*worker| {
            try worker.start();
        }
    }

    /// Shutdown the scheduler
    pub fn shutdown(self: *Scheduler) void {
        self.is_running.store(false, .release);
        for (self.workers) |*worker| {
            worker.stop();
        }
    }

    /// Submit a task to the scheduler
    pub fn submit(self: *Scheduler, func: TaskFn, context: ?*anyopaque) !void {
        try self.submitWithPriority(func, context, .normal);
    }

    /// Submit a task with specific priority
    pub fn submitWithPriority(self: *Scheduler, func: TaskFn, context: ?*anyopaque, priority: Priority) !void {
        if (!self.is_running.load(.acquire)) {
            return Error.SchedulerShutdown;
        }

        const task = Task{
            .func = func,
            .context = context,
            .priority = priority,
            .id = self.next_task_id.fetchAdd(1, .relaxed),
        };

        // High priority tasks go to global queue for faster pickup
        if (priority == .critical or priority == .high) {
            try self.globalQueue.push(task);
        } else {
            // Distribute to workers using round-robin
            const worker_id = self.next_worker.fetchAdd(1, .relaxed) % self.num_workers;
            try self.workers[worker_id].local_queue.push(task);
        }

        _ = self.tasks_submitted.fetchAdd(1, .relaxed);
    }

    /// Submit a batch of tasks
    pub fn submitBatch(self: *Scheduler, tasks: []const struct { func: TaskFn, context: ?*anyopaque }) !void {
        for (tasks) |t| {
            try self.submit(t.func, t.context);
        }
    }

    /// Get statistics about the scheduler
    pub fn getStats(self: *Scheduler) Stats {
        var total_executed: u64 = 0;
        var total_stolen: u64 = 0;
        var total_pending: usize = 0;

        for (self.workers) |*worker| {
            total_executed += worker.tasks_executed.load(.relaxed);
            total_stolen += worker.tasks_stolen.load(.relaxed);
            total_pending += worker.local_queue.size();
        }

        total_pending += self.globalQueue.size();

        return Stats{
            .tasks_submitted = self.tasks_submitted.load(.relaxed),
            .tasks_executed = total_executed,
            .tasks_stolen = total_stolen,
            .tasks_pending = total_pending,
            .num_workers = self.num_workers,
        };
    }

    pub const Stats = struct {
        tasks_submitted: u64,
        tasks_executed: u64,
        tasks_stolen: u64,
        tasks_pending: usize,
        num_workers: usize,
    };
};

/// Parallel for-each helper
pub fn parallelForEach(
    scheduler: *Scheduler,
    comptime T: type,
    items: []const T,
    context: anytype,
    comptime func: fn (item: T, ctx: @TypeOf(context)) void,
) !void {
    const Context = struct {
        item: T,
        user_ctx: @TypeOf(context),

        fn execute(self_ptr: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(self_ptr.?));
            func(self.item, self.user_ctx);
        }
    };

    var contexts = try scheduler.allocator.alloc(Context, items.len);
    defer scheduler.allocator.free(contexts);

    for (items, 0..) |item, i| {
        contexts[i] = Context{ .item = item, .user_ctx = context };
        try scheduler.submit(Context.execute, &contexts[i]);
    }
}

/// Create a future/promise for async task execution
pub fn Future(comptime T: type) type {
    return struct {
        const Self = @This();

        value: ?T = null,
        completed: std.atomic.Value(bool),
        err: ?anyerror = null,

        pub fn init() Self {
            return Self{
                .completed = std.atomic.Value(bool).init(false),
            };
        }

        pub fn complete(self: *Self, value: T) void {
            self.value = value;
            self.completed.store(true, .release);
        }

        pub fn fail(self: *Self, err: anyerror) void {
            self.err = err;
            self.completed.store(true, .release);
        }

        pub fn isComplete(self: *Self) bool {
            return self.completed.load(.acquire);
        }

        pub fn wait(self: *Self) !T {
            while (!self.isComplete()) {
                std.Thread.yield() catch {};
            }
            if (self.err) |err| return err;
            return self.value.?;
        }

        pub fn tryGet(self: *Self) ?T {
            if (self.isComplete()) {
                return self.value;
            }
            return null;
        }
    };
}

// Tests
test "work stealing deque basic operations" {
    const allocator = std.testing.allocator;

    var deque = try WorkStealingDeque(Task).init(allocator);
    defer deque.deinit();

    const task1 = Task{ .func = undefined, .id = 1 };
    const task2 = Task{ .func = undefined, .id = 2 };

    try deque.push(task1);
    try deque.push(task2);

    try std.testing.expectEqual(@as(usize, 2), deque.size());

    const popped = deque.pop();
    try std.testing.expect(popped != null);
    try std.testing.expectEqual(@as(u64, 2), popped.?.id);

    const stolen = deque.steal();
    try std.testing.expect(stolen != null);
    try std.testing.expectEqual(@as(u64, 1), stolen.?.id);

    try std.testing.expect(deque.isEmpty());
}

test "scheduler creation" {
    const allocator = std.testing.allocator;

    const scheduler = try Scheduler.init(allocator, 2);
    defer scheduler.deinit();

    try std.testing.expectEqual(@as(usize, 2), scheduler.num_workers);
}
