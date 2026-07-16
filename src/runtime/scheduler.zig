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
            const cur_size = b - t;

            if (cur_size >= @as(i64, @intCast(self.buffer.len))) {
                return Error.QueueFull;
            }

            const index: usize = @intCast(@mod(b, @as(i64, @intCast(self.buffer.len))));
            self.buffer[index] = task;

            // Publish the task with a release store: the release ordering
            // guarantees the preceding buffer write is visible to any thief
            // that acquire-loads `bottom`. (std.atomic.fence was removed;
            // the release store carries the same publication guarantee.)
            self.bottom.store(b + 1, .release);
        }

        /// Pop a task from the bottom (owner only)
        pub fn pop(self: *Self) ?T {
            var b = self.bottom.load(.seq_cst);
            b -= 1;
            // A seq_cst read-modify-write provides the StoreLoad barrier that
            // the removed std.atomic.fence(.seq_cst) used to supply between
            // publishing the decremented `bottom` and loading `top`.
            _ = self.bottom.swap(b, .seq_cst);

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
            // Both loads use seq_cst so they participate in the single total
            // order that the removed std.atomic.fence(.seq_cst) established
            // between reading `top` and `bottom`.
            const t = self.top.load(.seq_cst);
            const b = self.bottom.load(.seq_cst);

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
        var idle_iters: u32 = 0;
        while (self.is_running.load(.acquire)) {
            // Try to get work from local queue first
            if (self.local_queue.pop()) |task| {
                self.executeTask(task);
                idle_iters = 0;
                continue;
            }

            // Try to steal from other workers
            if (self.trySteal()) |task| {
                _ = self.tasks_stolen.fetchAdd(1, .monotonic);
                self.executeTask(task);
                idle_iters = 0;
                continue;
            }

            // Try the global injection queue. Workers are thieves here: many
            // may consume concurrently, so this must be steal() (multi-consumer
            // safe via the top cmpxchg), never pop() (single-owner only).
            if (self.scheduler.globalQueue.steal()) |task| {
                self.executeTask(task);
                idle_iters = 0;
                continue;
            }

            // No work found — back off progressively so an idle worker does not
            // peg a core. Brief spins stay responsive to a sudden burst; then a
            // few yields; then park on a bounded sleep. The 1ms cap keeps
            // shutdown latency small (a parked worker observes is_running within
            // one sleep interval after stop()).
            idle_iters +|= 1;
            if (idle_iters < 64) {
                std.atomic.spinLoopHint();
            } else if (idle_iters < 128) {
                // yield() is a scheduling hint; a declined yield just falls
                // through to re-check the queues, so the error is ignorable.
                std.Thread.yield() catch {};
            } else {
                const duration = std.Io.Duration.fromMilliseconds(1);
                const timeout = std.Io.Timeout{ .duration = .{ .raw = duration, .clock = .awake } };
                // A cancelled/failed park only makes the next queue check happen
                // sooner, which is harmless.
                timeout.sleep(self.scheduler.io) catch {};
            }
        }
    }

    /// Try to steal work from another worker
    fn trySteal(self: *Worker) ?Task {
        const num_workers = self.scheduler.workers.len;
        if (num_workers <= 1) return null;

        // Start from a random worker to avoid contention
        const io = std.Io.Threaded.global_single_threaded.io();
        var seed_bytes: [8]u8 = undefined;
        io.randomSecure(&seed_bytes) catch {
            // Entropy unavailable: fall back to worker id for a deterministic
            // but still-spread starting offset rather than aborting a steal.
            @memset(&seed_bytes, @truncate(self.id));
        };
        const seed = std.mem.readInt(u64, &seed_bytes, .little);
        var prng = std.Random.DefaultPrng.init(seed);
        const start_idx: usize = prng.random().int(usize) % num_workers;

        var i: usize = 0;
        while (i < num_workers) : (i += 1) {
            const victim_id = (start_idx + i) % num_workers;
            if (victim_id == self.id) continue;

            if (self.scheduler.workers[victim_id].local_queue.steal()) |task| {
                return task;
            }
        }

        return null;
    }

    fn executeTask(self: *Worker, task: Task) void {
        task.func(task.context);
        _ = self.tasks_executed.fetchAdd(1, .monotonic);
    }
};

/// Work-Stealing Scheduler.
///
/// Role in the execution model: this is a subordinate CPU-offload pool, not an
/// independent runtime. The authoritative execution model is `EventLoop` (see
/// `runtime/event_loop.zig`), which runs all application logic on one loop
/// thread and owns callback-context lifetimes. This scheduler exists only to
/// parallelize pure/CPU-bound work across worker threads.
///
/// Ownership boundary: task contexts submitted here are BORROWED — the
/// submitter owns them, the scheduler frees nothing, and `shutdown` cancels
/// (does not drain) pending tasks. Worker threads must not mutate
/// event-loop-owned state directly; the only sanctioned way to return a result
/// to the reactor is to call `EventLoop.submit`, which re-runs the continuation
/// on the loop thread under the loop's ownership contract. That single seam
/// keeps the loop authoritative and the scheduler a stateless compute helper.
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
    allocator: std.mem.Allocator,
    /// I/O handle used to park idle workers on a bounded sleep. Workers are raw
    /// OS threads, so this degrades to a per-thread `clock_nanosleep`.
    io: std.Io,
    /// Producer serialization for the global queue. `push` is a single-owner
    /// operation on the Chase–Lev deque, but `submit` may be called from many
    /// threads; this test-and-set spinlock guarantees at most one producer
    /// pushes at a time. Workers only `steal` the global queue (never `push`
    /// or `pop`), and steal-vs-push is the deque's lock-free owner/thief case,
    /// so consumers never take this lock.
    global_producer_lock: std.atomic.Value(bool),

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
            .allocator = allocator,
            .io = std.Io.Threaded.global_single_threaded.io(),
            .global_producer_lock = std.atomic.Value(bool).init(false),
        };
        // globalQueue is live now; release it if worker setup below fails.
        errdefer scheduler.globalQueue.deinit();

        // Create workers. If any Worker.init fails partway, tear down the ones
        // already created and free the array before unwinding.
        scheduler.workers = try allocator.alloc(Worker, actual_workers);
        errdefer allocator.free(scheduler.workers);

        var initialized: usize = 0;
        errdefer for (scheduler.workers[0..initialized]) |*worker| {
            worker.deinit();
        };

        for (scheduler.workers, 0..) |*worker, i| {
            worker.* = try Worker.init(allocator, i, scheduler);
            initialized += 1;
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

    /// Start all worker threads.
    ///
    /// If spawning a worker fails partway, the workers already started are
    /// signalled to stop and joined before the error unwinds, so no thread
    /// outlives a failed `start()` (no orphaned/detached workers).
    pub fn start(self: *Scheduler) !void {
        self.is_running.store(true, .release);
        var started: usize = 0;
        errdefer {
            // Partial startup: cancel and join only the workers we spawned.
            // Un-started workers have a null thread, so their stop() is a no-op.
            self.is_running.store(false, .release);
            for (self.workers[0..started]) |*worker| {
                worker.stop();
            }
        }
        for (self.workers) |*worker| {
            try worker.start();
            started += 1;
        }
    }

    /// Shutdown the scheduler.
    ///
    /// Cancel semantics: this clears the running flag and joins every worker,
    /// so each worker finishes the task it is currently executing and then
    /// exits. Tasks still queued (local, global) are NOT drained — they are
    /// cancelled. Task contexts are borrowed (the submitter owns them; the
    /// scheduler never frees them), so dropping pending tasks leaks nothing the
    /// scheduler owns. Idempotent: safe to call more than once and from
    /// `deinit`, since a stopped worker has a null thread and re-stops as a
    /// no-op.
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
            .id = self.next_task_id.fetchAdd(1, .monotonic),
        };

        // All work is injected through the global queue. Pushing a worker's
        // local deque from here would make the submitting thread a second owner
        // of that deque (the worker already pushes/pops it), which the Chase–Lev
        // algorithm forbids and which double-executes tasks under contention.
        // push() is single-owner, so serialize concurrent submitters with the
        // producer spinlock; workers consume via steal() and never take it.
        while (self.global_producer_lock.cmpxchgWeak(false, true, .acquire, .monotonic)) |_| {
            std.atomic.spinLoopHint();
        }
        defer self.global_producer_lock.store(false, .release);

        try self.globalQueue.push(task);
        _ = self.tasks_submitted.fetchAdd(1, .monotonic);
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
            total_executed += worker.tasks_executed.load(.monotonic);
            total_stolen += worker.tasks_stolen.load(.monotonic);
            total_pending += worker.local_queue.size();
        }

        total_pending += self.globalQueue.size();

        return Stats{
            .tasks_submitted = self.tasks_submitted.load(.monotonic),
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

/// Parallel for-each helper.
///
/// Runs `func(item, context)` for every item across the scheduler's workers and
/// blocks until all of them have finished. The scheduler must be started before
/// this is called (an un-started scheduler rejects the submit and this returns
/// `Error.SchedulerShutdown` without waiting). The per-item task contexts live
/// in a single allocation owned by this call; it waits for every submitted task
/// to complete before freeing that allocation, so a worker never dereferences
/// freed memory.
pub fn parallelForEach(
    scheduler: *Scheduler,
    comptime T: type,
    items: []const T,
    context: anytype,
    comptime func: fn (item: T, ctx: @TypeOf(context)) void,
) !void {
    if (items.len == 0) return;

    const Context = struct {
        item: T,
        user_ctx: @TypeOf(context),
        remaining: *std.atomic.Value(usize),

        fn execute(self_ptr: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(self_ptr.?));
            func(self.item, self.user_ctx);
            // Signal completion last: the waiter frees `contexts` once this
            // reaches zero, so no field may be touched after this store.
            _ = self.remaining.fetchSub(1, .acq_rel);
        }
    };

    var remaining = std.atomic.Value(usize).init(items.len);
    var contexts = try scheduler.allocator.alloc(Context, items.len);
    defer scheduler.allocator.free(contexts);

    var submitted: usize = 0;
    // Whether we exit normally or via a submit error, wait until every task
    // that was actually submitted has finished before the deferred free runs;
    // otherwise a still-running worker would read the freed `contexts`. Only
    // submitted slots ever decrement `remaining`, so it settles at
    // `items.len - submitted`.
    errdefer while (remaining.load(.acquire) != items.len - submitted) {
        std.Thread.yield() catch std.atomic.spinLoopHint();
    };

    for (items, 0..) |item, i| {
        contexts[i] = Context{ .item = item, .user_ctx = context, .remaining = &remaining };
        while (true) {
            scheduler.submit(Context.execute, &contexts[i]) catch |err| switch (err) {
                Error.QueueFull => {
                    std.atomic.spinLoopHint();
                    continue;
                },
                else => return err,
            };
            break;
        }
        submitted += 1;
    }

    while (remaining.load(.acquire) != 0) {
        std.Thread.yield() catch std.atomic.spinLoopHint();
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
                // Spin-wait scheduling hint; a declined yield just tightens the
                // spin for one iteration and is safely ignorable.
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

test "work stealing deque reports QueueFull at capacity and recovers after drain" {
    const allocator = std.testing.allocator;

    var deque = try WorkStealingDeque(u64).init(allocator);
    defer deque.deinit();

    const capacity = deque.buffer.len;

    // Fill to exactly capacity — every push must succeed.
    var i: u64 = 0;
    while (i < capacity) : (i += 1) {
        try deque.push(i);
    }
    try std.testing.expectEqual(capacity, deque.size());

    // The next push has no room and must surface backpressure, not overwrite.
    try std.testing.expectError(Error.QueueFull, deque.push(capacity));

    // Draining one slot frees room for exactly one more push.
    const first = deque.steal();
    try std.testing.expect(first != null);
    try deque.push(capacity);
    try std.testing.expectError(Error.QueueFull, deque.push(capacity + 1));
}

test "work stealing deque consumes every item exactly once under concurrent stealers" {
    const allocator = std.testing.allocator;

    // Enough items to force many wrap-arounds and full/empty transitions of the
    // 1024-slot buffer, so the push/steal interleaving is exercised heavily.
    const total_items: u64 = 50_000;
    const num_thieves = 4;

    var deque = try WorkStealingDeque(u64).init(allocator);
    defer deque.deinit();

    const seen = try allocator.alloc(std.atomic.Value(u8), total_items);
    defer allocator.free(seen);
    for (seen) |*s| s.* = std.atomic.Value(u8).init(0);

    const Shared = struct {
        deque: *WorkStealingDeque(u64),
        seen: []std.atomic.Value(u8),
        consumed: std.atomic.Value(u64),
        total: u64,

        fn thief(self: *@This()) void {
            while (self.consumed.load(.monotonic) < self.total) {
                if (self.deque.steal()) |v| {
                    // Record this value's consumption; a second consumer of the
                    // same value would push the counter past 1 and fail the test.
                    _ = self.seen[@intCast(v)].fetchAdd(1, .monotonic);
                    _ = self.consumed.fetchAdd(1, .monotonic);
                } else {
                    std.atomic.spinLoopHint();
                }
            }
        }
    };

    var shared = Shared{
        .deque = &deque,
        .seen = seen,
        .consumed = std.atomic.Value(u64).init(0),
        .total = total_items,
    };

    var thieves: [num_thieves]std.Thread = undefined;
    var spawned: usize = 0;
    errdefer for (thieves[0..spawned]) |t| t.join();
    while (spawned < num_thieves) : (spawned += 1) {
        thieves[spawned] = try std.Thread.spawn(.{}, Shared.thief, .{&shared});
    }

    // Owner produces every item, spinning while the buffer is full so the
    // thieves get a chance to drain it (bounded backpressure, never a drop).
    var produced: u64 = 0;
    while (produced < total_items) {
        deque.push(produced) catch |err| switch (err) {
            Error.QueueFull => {
                std.atomic.spinLoopHint();
                continue;
            },
            else => return err,
        };
        produced += 1;
    }

    for (thieves) |t| t.join();
    spawned = 0;

    // Every value must have been consumed exactly once — no loss, no dup.
    try std.testing.expectEqual(total_items, shared.consumed.load(.monotonic));
    for (seen) |*s| {
        try std.testing.expectEqual(@as(u8, 1), s.load(.monotonic));
    }
    try std.testing.expect(deque.isEmpty());
}

test "work stealing deque resolves single-element pop/steal race to one winner" {
    const allocator = std.testing.allocator;

    // Each round places exactly one element, then owner-pop and thief-steal
    // contend for it. Exactly one side must win every round; the last-element
    // cmpxchg in pop()/steal() is what makes that safe.
    const rounds: usize = 50_000;

    var deque = try WorkStealingDeque(u64).init(allocator);
    defer deque.deinit();

    const Shared = struct {
        deque: *WorkStealingDeque(u64),
        rounds: usize,
        // Round r is announced by storing r+1 so 0 means "no round yet".
        round_ready: std.atomic.Value(usize),
        thief_done: std.atomic.Value(usize),
        thief_got: std.atomic.Value(u8),
        thief_wins: std.atomic.Value(usize),

        fn thief(self: *@This()) void {
            var r: usize = 0;
            while (r < self.rounds) : (r += 1) {
                // Wait for the owner to publish this round's element.
                while (self.round_ready.load(.acquire) != r + 1) {
                    std.atomic.spinLoopHint();
                }
                const got: u8 = if (self.deque.steal() != null) 1 else 0;
                if (got == 1) _ = self.thief_wins.fetchAdd(1, .monotonic);
                // Publish the per-round result before the done marker so the
                // owner's acquire-load of thief_done sees a settled thief_got.
                self.thief_got.store(got, .monotonic);
                self.thief_done.store(r + 1, .release);
            }
        }
    };

    var shared = Shared{
        .deque = &deque,
        .rounds = rounds,
        .round_ready = std.atomic.Value(usize).init(0),
        .thief_done = std.atomic.Value(usize).init(0),
        .thief_got = std.atomic.Value(u8).init(0),
        .thief_wins = std.atomic.Value(usize).init(0),
    };

    var thief_thread = try std.Thread.spawn(.{}, Shared.thief, .{&shared});
    defer thief_thread.join();

    var owner_wins: usize = 0;
    var r: usize = 0;
    while (r < rounds) : (r += 1) {
        try deque.push(@as(u64, r));
        // Announce the round, then immediately contend with the thief.
        shared.round_ready.store(r + 1, .release);
        const owner_got: u8 = if (deque.pop() != null) 1 else 0;
        owner_wins += owner_got;

        // Rendezvous: wait for the thief to finish its single steal attempt.
        while (shared.thief_done.load(.acquire) != r + 1) {
            std.atomic.spinLoopHint();
        }
        const thief_got = shared.thief_got.load(.monotonic);

        // The element existed and cannot be consumed twice nor vanish.
        try std.testing.expectEqual(@as(u8, 1), owner_got + thief_got);
        // The deque must be empty again before the next round pushes.
        try std.testing.expect(deque.isEmpty());
    }

    // Cross-check: every round had exactly one winner, split across the sides.
    try std.testing.expectEqual(rounds, owner_wins + shared.thief_wins.load(.monotonic));
}

test "scheduler starts, runs submitted work, and joins all workers on shutdown" {
    const allocator = std.testing.allocator;

    const scheduler = try Scheduler.init(allocator, 4);
    defer scheduler.deinit();

    const Counter = struct {
        value: std.atomic.Value(u64),
        fn bump(context: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            _ = self.value.fetchAdd(1, .monotonic);
        }
    };
    var counter = Counter{ .value = std.atomic.Value(u64).init(0) };

    try scheduler.start();

    const total: u64 = 2000;
    var submitted: u64 = 0;
    while (submitted < total) : (submitted += 1) {
        // Retry on transient backpressure so every task is actually enqueued.
        while (true) {
            scheduler.submit(Counter.bump, &counter) catch |err| switch (err) {
                Error.QueueFull => {
                    std.atomic.spinLoopHint();
                    continue;
                },
                else => return err,
            };
            break;
        }
    }

    // Wait until every submitted task has run, so shutdown is exercised on a
    // drained scheduler rather than racing the workers. A bounded spin keeps the
    // test from hanging if a task were dropped (it would fail via the count).
    var spins: usize = 0;
    while (counter.value.load(.monotonic) < total and spins < 100_000_000) : (spins += 1) {
        std.atomic.spinLoopHint();
    }

    try std.testing.expectEqual(total, counter.value.load(.monotonic));

    // shutdown() must join all worker threads and leave the scheduler stopped;
    // if any thread failed to join this call would hang the test.
    scheduler.shutdown();
    try std.testing.expect(!scheduler.is_running.load(.acquire));
    for (scheduler.workers) |*worker| {
        try std.testing.expect(worker.thread == null);
    }

    // Submitting after shutdown is rejected, not silently dropped.
    try std.testing.expectError(Error.SchedulerShutdown, scheduler.submit(Counter.bump, &counter));
}

test "parallelForEach runs every item once and waits before freeing contexts" {
    const allocator = std.testing.allocator;

    const scheduler = try Scheduler.init(allocator, 4);
    defer scheduler.deinit();
    try scheduler.start();

    const n = 1000;
    const results = try allocator.alloc(std.atomic.Value(u32), n);
    defer allocator.free(results);
    for (results) |*r| r.* = std.atomic.Value(u32).init(0);

    const items = try allocator.alloc(usize, n);
    defer allocator.free(items);
    for (items, 0..) |*it, i| it.* = i;

    const Ops = struct {
        fn mark(item: usize, ctx: []std.atomic.Value(u32)) void {
            _ = ctx[item].fetchAdd(1, .monotonic);
        }
    };

    // Returns only after every task has completed; if it freed contexts early a
    // worker would fault or the counts would be wrong.
    try parallelForEach(scheduler, usize, items, results, Ops.mark);

    for (results) |*r| {
        try std.testing.expectEqual(@as(u32, 1), r.load(.monotonic));
    }
}
