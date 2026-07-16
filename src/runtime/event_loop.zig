const std = @import("std");
const builtin = @import("builtin");

/// Platform-specific I/O event types
pub const IoEvent = struct {
    fd: std.posix.fd_t,
    events: u32,
    data: ?*anyopaque = null,

    pub const READ = 0x01;
    pub const WRITE = 0x02;
    pub const ERROR = 0x04;
    pub const HANGUP = 0x08;
};

/// Invoked when a registered descriptor becomes ready. Receives the context the
/// loop holds for that descriptor (see `ContextCleanup` for the ownership
/// contract) and the readiness event. Returning an error does not tear down the
/// loop: the descriptor is unregistered (its context released) and the error is
/// handed to the loop's `io_error_handler`, so a persistently failing handler
/// cannot hot-loop the poller.
pub const IoCallback = *const fn (context: ?*anyopaque, event: IoEvent) anyerror!void;

/// Notified when an I/O callback fails. By the time this runs the descriptor has
/// already been removed from the readiness table and its context released, so
/// the handler must not reference either.
pub const IoErrorHandler = *const fn (fd: std.posix.fd_t, err: anyerror) void;

/// A descriptor's readiness handler plus the context the loop owns for it.
const IoRegistration = struct {
    callback: IoCallback,
    context: ?*anyopaque = null,
    cleanup: ?ContextCleanup = null,
};

/// Minimal spinlock guarding the cross-thread inbox hand-off. The critical
/// section is a single append or pointer swap, so a short spin is cheaper than
/// a futex round-trip and needs no `std.Io` handle. Not for long or contended
/// sections.
const Spinlock = struct {
    locked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn lock(self: *Spinlock) void {
        while (self.locked.swap(true, .acquire)) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *Spinlock) void {
        self.locked.store(false, .release);
    }
};

/// Release a descriptor's context if the loop owns it (non-null cleanup).
fn releaseIoContext(allocator: std.mem.Allocator, reg: IoRegistration) void {
    if (reg.cleanup) |cleanup| {
        if (reg.context) |ctx| cleanup(allocator, ctx);
    }
}

/// Releases a context/data pointer that the event loop owns.
///
/// Ownership contract for queued work (timers and tasks):
///   - A `null` cleanup means the pointer is *borrowed* — owned by the caller
///     (e.g. a loader that outlives the loop). The loop never frees it.
///   - A non-null cleanup means the loop *owns* the pointee and will invoke the
///     cleanup exactly once when the work is permanently removed: after a
///     one-shot fires, when it is cancelled, or when the loop is torn down with
///     work still queued. Repeating timers keep their data across re-arms and
///     are only cleaned up on cancellation or shutdown.
///
/// Callbacks must therefore never free their own context; the loop owns that
/// lifetime once cleanup is supplied.
pub const ContextCleanup = *const fn (allocator: std.mem.Allocator, context: *anyopaque) void;

/// Timer callback function
pub const TimerCallback = *const fn (timer: *Timer) void;

/// Timer structure
pub const Timer = struct {
    id: u64,
    deadline: i64, // Unix timestamp in milliseconds
    callback: TimerCallback,
    repeat: ?u64 = null, // Repeat interval in ms (null for one-shot)
    data: ?*anyopaque = null,
    data_cleanup: ?ContextCleanup = null,
    cancelled: bool = false,
};

/// Task callback function
pub const TaskCallback = *const fn (task: *Task) anyerror!void;

/// Async task
pub const Task = struct {
    callback: TaskCallback,
    context: ?*anyopaque = null,
    context_cleanup: ?ContextCleanup = null,
};

/// Min-heap for timers
pub const TimerHeap = struct {
    timers: std.PriorityQueue(Timer, void, compareTimers),
    next_id: u64 = 1,
    allocator: std.mem.Allocator,
    io: std.Io,
    /// Id of the timer whose callback is currently running (if any), so a
    /// callback can cancel itself via `clearTimer(ownId)` even though it has
    /// already been popped off the heap.
    firing_id: ?u64 = null,
    /// Set when the currently-firing timer cancels itself during its callback.
    firing_cancelled: bool = false,
    /// While a `processExpired` pass runs, points at that pass's local list of
    /// timers held aside for re-push (re-armed repeats + callback-added
    /// timers). Lets a callback cancel a timer that already fired earlier in
    /// the same pass. Null outside a pass.
    pass_deferred: ?*std.ArrayListUnmanaged(Timer) = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) TimerHeap {
        return TimerHeap{
            .timers = std.PriorityQueue(Timer, void, compareTimers).initContext({}),
            .allocator = allocator,
            .io = io,
        };
    }

    pub fn deinit(self: *TimerHeap) void {
        // Release data the loop owns for timers still queued at shutdown.
        while (self.timers.pop()) |timer| {
            releaseTimerData(self.allocator, timer);
        }
        self.timers.deinit(self.allocator);
    }

    /// Invoke a timer's cleanup exactly once if the loop owns its data.
    fn releaseTimerData(allocator: std.mem.Allocator, timer: Timer) void {
        if (timer.data_cleanup) |cleanup| {
            if (timer.data) |data| cleanup(allocator, data);
        }
    }

    fn compareTimers(_: void, a: Timer, b: Timer) std.math.Order {
        return std.math.order(a.deadline, b.deadline);
    }

    /// Get current time in milliseconds using monotonic clock
    fn getCurrentTimeMs(self: *TimerHeap) i64 {
        const ts = std.Io.Timestamp.now(self.io, .awake);
        // Convert nanoseconds to milliseconds
        return @intCast(@divFloor(ts.nanoseconds, std.time.ns_per_ms));
    }

    /// Schedule a one-shot timer. If `cleanup` is non-null the heap takes
    /// ownership of `data` on success and releases it after the timer fires or
    /// is cancelled. On error ownership stays with the caller.
    pub fn setTimeout(
        self: *TimerHeap,
        delay_ms: u64,
        callback: TimerCallback,
        data: ?*anyopaque,
        cleanup: ?ContextCleanup,
    ) !u64 {
        const now_ms = self.getCurrentTimeMs();
        // Saturate rather than overflow for absurd delays (u64 that exceeds i64,
        // or a deadline past i64 max): a far-future timer simply never fires.
        const delay: i64 = std.math.cast(i64, delay_ms) orelse std.math.maxInt(i64);
        const timer = Timer{
            .id = self.next_id,
            .deadline = now_ms +| delay,
            .callback = callback,
            .repeat = null,
            .data = data,
            .data_cleanup = cleanup,
        };
        try self.timers.push(self.allocator, timer);
        self.next_id += 1;
        return timer.id;
    }

    /// Schedule a repeating timer. Ownership of `data` transfers to the heap on
    /// success (kept across re-arms); released on cancellation or shutdown.
    pub fn setInterval(
        self: *TimerHeap,
        interval_ms: u64,
        callback: TimerCallback,
        data: ?*anyopaque,
        cleanup: ?ContextCleanup,
    ) !u64 {
        const now_ms = self.getCurrentTimeMs();
        // Saturate the first deadline the same way as setTimeout.
        const delay: i64 = std.math.cast(i64, interval_ms) orelse std.math.maxInt(i64);
        const timer = Timer{
            .id = self.next_id,
            .deadline = now_ms +| delay,
            .callback = callback,
            .repeat = interval_ms,
            .data = data,
            .data_cleanup = cleanup,
        };
        try self.timers.push(self.allocator, timer);
        self.next_id += 1;
        return timer.id;
    }

    pub fn clearTimer(self: *TimerHeap, id: u64) void {
        // The currently-firing timer has already been popped off the heap, so a
        // self-cancel (or a cancel targeting the timer whose callback is
        // running) is recorded via a flag and honored once the callback returns.
        if (self.firing_id) |fid| {
            if (fid == id) {
                self.firing_cancelled = true;
                return;
            }
        }
        // A timer that already fired earlier in this pass is held aside for
        // re-push; mark it there so it is dropped instead of re-armed.
        if (self.pass_deferred) |deferred| {
            for (deferred.items) |*timer| {
                if (timer.id == id) {
                    timer.cancelled = true;
                    return;
                }
            }
        }
        // Otherwise mark it cancelled in place; it is skipped/released when popped.
        for (self.timers.items) |*timer| {
            if (timer.id == id) {
                timer.cancelled = true;
                return;
            }
        }
    }

    /// Compute the next deadline for a repeating timer.
    ///
    ///   - `scheduled` is the deadline the timer just fired for.
    ///   - `now` is the current time.
    ///   - `interval_ms` is the repeat period.
    ///
    /// Advances from `scheduled` (not `now`) so an on-time timer does not
    /// accumulate drift, treats a zero interval as the smallest tick so it
    /// cannot stall, jumps a badly-overdue timer forward in one hop instead of
    /// backlogging one fire per missed interval, and saturates instead of
    /// overflowing i64. The result is always strictly greater than `now`.
    fn nextDeadline(scheduled: i64, now: i64, interval_ms: u64) i64 {
        const step: i64 = std.math.cast(i64, interval_ms) orelse std.math.maxInt(i64);
        const safe_step: i64 = if (step <= 0) 1 else step;

        var next = scheduled +| safe_step;
        if (next <= now) {
            // Overdue: advance past `now` in a single jump so we neither drift
            // nor fire once per missed interval.
            const behind = now -| scheduled; // >= 0 in this branch
            const steps = @divFloor(behind, safe_step) +| 1;
            const jump = std.math.mul(i64, steps, safe_step) catch std.math.maxInt(i64);
            next = scheduled +| jump;
            // Guarantee strictly greater than `now` even under saturation.
            if (next <= now) next = now +| safe_step;
        }
        return next;
    }

    pub fn processExpired(self: *TimerHeap) !void {
        const now = self.getCurrentTimeMs();
        // Any timer created after this point is scheduled *by a callback* during
        // this pass; defer it so a callback that schedules an already-expired
        // timer can't spin processExpired forever.
        const batch_boundary = self.next_id;

        // Timers to re-push after the pass: re-armed repeats and callback-added
        // timers held aside. Holding them here guarantees each timer fires at
        // most once per pass (prevents zero-interval / drift spin) and lets a
        // callback cancel a timer that already fired earlier in the pass.
        var deferred: std.ArrayListUnmanaged(Timer) = .empty;
        defer deferred.deinit(self.allocator);
        self.pass_deferred = &deferred;
        defer self.pass_deferred = null;

        while (self.timers.peek()) |timer| {
            if (timer.deadline > now) break;

            var expired = self.timers.pop().?;

            // Scheduled by a callback during this pass — defer it whole so it
            // is only eligible on the next pass.
            if (expired.id >= batch_boundary) {
                deferred.append(self.allocator, expired) catch |err| {
                    releaseTimerData(self.allocator, expired);
                    return err;
                };
                continue;
            }

            // Cancelled before firing — release owned data and drop.
            if (expired.cancelled) {
                releaseTimerData(self.allocator, expired);
                continue;
            }

            // Run the callback, tracking the firing id so it can cancel itself
            // (or another callback can cancel it) mid-flight.
            self.firing_id = expired.id;
            self.firing_cancelled = false;
            expired.callback(&expired);
            const cancelled_self = self.firing_cancelled;
            self.firing_id = null;
            self.firing_cancelled = false;

            if (cancelled_self or expired.cancelled) {
                releaseTimerData(self.allocator, expired);
                continue;
            }

            if (expired.repeat) |interval| {
                // Repeating: keep data across re-arm, drift/zero/overflow-safe,
                // deferred so it fires at most once this pass.
                expired.deadline = nextDeadline(expired.deadline, now, interval);
                deferred.append(self.allocator, expired) catch |err| {
                    releaseTimerData(self.allocator, expired);
                    return err;
                };
            } else {
                // One-shot fired: permanently removed, release owned data.
                releaseTimerData(self.allocator, expired);
            }
        }

        // Re-push everything held aside. A callback may have cancelled one of
        // these after it fired; drop those instead of re-arming them.
        var pushed: usize = 0;
        errdefer for (deferred.items[pushed..]) |timer| {
            releaseTimerData(self.allocator, timer);
        };
        while (pushed < deferred.items.len) : (pushed += 1) {
            const timer = deferred.items[pushed];
            if (timer.cancelled) {
                releaseTimerData(self.allocator, timer);
                continue;
            }
            try self.timers.push(self.allocator, timer);
        }
    }

    pub fn nextTimeout(self: *TimerHeap) ?u64 {
        if (self.timers.peek()) |timer| {
            const now = self.getCurrentTimeMs();
            const diff = timer.deadline - now;
            if (diff <= 0) return 0;
            return @intCast(diff);
        }
        return null;
    }
};

/// Task queue for async operations
pub const TaskQueue = struct {
    queue: std.ArrayListUnmanaged(Task),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TaskQueue {
        return TaskQueue{
            .queue = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TaskQueue) void {
        // Release contexts the loop owns for tasks still queued at shutdown.
        for (self.queue.items) |task| {
            releaseTaskContext(self.allocator, task);
        }
        self.queue.deinit(self.allocator);
    }

    /// Invoke a task's cleanup exactly once if the loop owns its context.
    fn releaseTaskContext(allocator: std.mem.Allocator, task: Task) void {
        if (task.context_cleanup) |cleanup| {
            if (task.context) |context| cleanup(allocator, context);
        }
    }

    pub fn enqueue(self: *TaskQueue, callback: TaskCallback) !void {
        try self.queue.append(self.allocator, Task{ .callback = callback });
    }

    /// Enqueue a task. If `cleanup` is non-null the queue takes ownership of
    /// `context` and releases it after the task runs (or at shutdown).
    pub fn enqueueWithContext(
        self: *TaskQueue,
        callback: TaskCallback,
        context: ?*anyopaque,
        cleanup: ?ContextCleanup,
    ) !void {
        try self.queue.append(self.allocator, Task{
            .callback = callback,
            .context = context,
            .context_cleanup = cleanup,
        });
    }

    pub fn process(self: *TaskQueue) !void {
        // Take the current batch so tasks enqueued during processing run on the
        // next tick, and so a mid-batch error cannot leave the queue dirty.
        var batch = self.queue;
        self.queue = .empty;
        defer batch.deinit(self.allocator);

        var next: usize = 0;
        // On a callback error, release every task the batch still owns.
        errdefer for (batch.items[next..]) |task| {
            releaseTaskContext(self.allocator, task);
        };

        while (next < batch.items.len) {
            const task = &batch.items[next];
            next += 1; // Mark consumed before running so errdefer skips it.
            defer releaseTaskContext(self.allocator, task.*);
            try task.callback(task);
        }
    }

    pub fn isEmpty(self: *TaskQueue) bool {
        return self.queue.items.len == 0;
    }
};

/// Immediate queue (setImmediate)
pub const ImmediateQueue = TaskQueue;

/// Verification status of the I/O backend selected for the current target.
///
///   - `.supported`   — implemented and exercised by the test suite.
///   - `.unverified`  — structurally complete but not exercised on this build
///                       host, so correctness is not proven for `v0.1.2`.
///   - `.unsupported` — no working backend; construction fails closed.
pub const PollerSupport = enum { supported, unverified, unsupported };

/// Honest per-platform backend status for `v0.1.2`.
///
///   - Linux/epoll is the only backend the test suite exercises → `.supported`.
///   - kqueue (macOS/BSD) is a real readiness poller built on the same model as
///     epoll, but it cannot be run on the Linux dev/CI host, so it ships
///     `.unverified` rather than claimed-working.
///   - IOCP (Windows) is completion-based, not readiness-based: a correct
///     backend must submit real async reads/writes and translate their
///     completions. The current code never does — `register` only associates a
///     handle — so it can never report I/O readiness. Rather than silently
///     accept registrations and drop every event, `IocpPoller.init` fails closed
///     and the platform is `.unsupported`.
pub const poller_support: PollerSupport = switch (builtin.os.tag) {
    .linux => .supported,
    .macos, .freebsd, .netbsd, .openbsd => .unverified,
    .windows => .unsupported,
    else => .unsupported,
};

/// Platform-specific I/O poller. See `poller_support` for the honesty contract:
/// only Linux/epoll is exercised; kqueue is present-but-unverified; the IOCP
/// placeholder fails closed instead of masquerading as a working poller.
pub const IoPoller = switch (builtin.os.tag) {
    .linux => EpollPoller,
    .macos, .freebsd, .netbsd, .openbsd => KqueuePoller,
    .windows => IocpPoller,
    else => @compileError("Unsupported platform for I/O polling"),
};

/// Linux epoll implementation
const EpollPoller = struct {
    epoll_fd: std.posix.fd_t,
    /// eventfd registered in the epoll set purely to interrupt a blocking
    /// `epoll_wait` from another thread (see `wake`). It is drained and hidden
    /// by `poll`, never surfaced as a user readiness event.
    wake_fd: std.posix.fd_t,
    events: []std.os.linux.epoll_event,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !EpollPoller {
        const rc = std.os.linux.epoll_create1(std.os.linux.EPOLL.CLOEXEC);
        if (std.os.linux.errno(rc) != .SUCCESS) return error.EpollCreateFailed;
        const epoll_fd: std.posix.fd_t = @intCast(rc);
        errdefer _ = std.os.linux.close(epoll_fd);

        // Cross-thread wakeup primitive. A counting eventfd made readable by
        // `wake`; epoll is level-triggered so the wait returns even if the write
        // races the entry into `epoll_wait` (no lost wakeups).
        const efd_rc = std.os.linux.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
        if (std.os.linux.errno(efd_rc) != .SUCCESS) return error.EventFdCreateFailed;
        const wake_fd: std.posix.fd_t = @intCast(efd_rc);
        errdefer _ = std.os.linux.close(wake_fd);

        var wake_event = std.os.linux.epoll_event{
            .events = std.os.linux.EPOLL.IN,
            .data = .{ .fd = wake_fd },
        };
        const ctl_rc = std.os.linux.epoll_ctl(epoll_fd, std.os.linux.EPOLL.CTL_ADD, wake_fd, &wake_event);
        if (std.os.linux.errno(ctl_rc) != .SUCCESS) return error.EpollCtlFailed;

        const events = try allocator.alloc(std.os.linux.epoll_event, 1024);

        return EpollPoller{
            .epoll_fd = epoll_fd,
            .wake_fd = wake_fd,
            .events = events,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *EpollPoller) void {
        _ = std.os.linux.close(self.wake_fd);
        _ = std.os.linux.close(self.epoll_fd);
        self.allocator.free(self.events);
    }

    /// Interrupt a blocking `poll` from any thread by making the wakeup eventfd
    /// readable. Safe to call concurrently with the loop thread; the counter
    /// saturates harmlessly if woken repeatedly before a drain.
    pub fn wake(self: *EpollPoller) !void {
        const one: u64 = 1;
        const rc = std.os.linux.write(self.wake_fd, std.mem.asBytes(&one), @sizeOf(u64));
        if (std.os.linux.errno(rc) != .SUCCESS) return error.EventFdWriteFailed;
    }

    pub fn register(self: *EpollPoller, fd: std.posix.fd_t, events: u32) !void {
        var event = std.os.linux.epoll_event{
            .events = events,
            .data = .{ .fd = fd },
        };
        const rc = std.os.linux.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_ADD, fd, &event);
        const err = std.os.linux.errno(rc);
        if (err != .SUCCESS) return error.EpollCtlFailed;
    }

    pub fn unregister(self: *EpollPoller, fd: std.posix.fd_t) !void {
        const rc = std.os.linux.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_DEL, fd, null);
        const err = std.os.linux.errno(rc);
        if (err != .SUCCESS) return error.EpollCtlFailed;
    }

    pub fn poll(self: *EpollPoller, timeout_ms: i32) ![]IoEvent {
        const rc = std.os.linux.epoll_wait(self.epoll_fd, self.events.ptr, @intCast(self.events.len), timeout_ms);
        const err = std.os.linux.errno(rc);
        if (err != .SUCCESS) return error.EpollWaitFailed;
        const count: usize = rc;

        // Drain the wakeup eventfd and exclude it from the reported events so a
        // cross-thread wake surfaces as "poll returned" without a phantom fd.
        var real: usize = 0;
        for (self.events[0..count]) |event| {
            if (event.data.fd == self.wake_fd) {
                var drain: u64 = undefined;
                _ = std.os.linux.read(self.wake_fd, std.mem.asBytes(&drain), @sizeOf(u64));
                continue;
            }
            real += 1;
        }

        // Convert epoll events to IoEvents
        var io_events = try self.allocator.alloc(IoEvent, real);
        var i: usize = 0;
        for (self.events[0..count]) |event| {
            if (event.data.fd == self.wake_fd) continue;
            io_events[i] = IoEvent{
                .fd = event.data.fd,
                .events = event.events,
            };
            i += 1;
        }

        return io_events;
    }
};

/// macOS/BSD kqueue implementation
const KqueuePoller = struct {
    kqueue_fd: std.posix.fd_t,
    events: []std.posix.Kevent,
    allocator: std.mem.Allocator,

    /// Sentinel identifier for the cross-thread wakeup user event. Chosen well
    /// outside the descriptor space so it cannot collide with a real fd.
    const wake_ident: usize = std.math.maxInt(usize);

    pub fn init(allocator: std.mem.Allocator) !KqueuePoller {
        const kqueue_fd = try std.posix.kqueue();
        errdefer _ = std.posix.system.close(kqueue_fd);
        const events = try allocator.alloc(std.posix.Kevent, 1024);

        // Register the user-triggered wakeup event once; `wake` fires it and
        // `poll` filters it back out (see `wake`).
        const wake_reg = [_]std.posix.Kevent{.{
            .ident = wake_ident,
            .filter = std.posix.system.EVFILT_USER,
            .flags = std.posix.system.EV_ADD | std.posix.system.EV_CLEAR,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        }};
        _ = try std.posix.kevent(kqueue_fd, &wake_reg, &[_]std.posix.Kevent{}, null);

        return KqueuePoller{
            .kqueue_fd = kqueue_fd,
            .events = events,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *KqueuePoller) void {
        _ = std.posix.system.close(self.kqueue_fd);
        self.allocator.free(self.events);
    }

    /// Interrupt a blocking `poll` from any thread by triggering the registered
    /// EVFILT_USER event. `poll` drains it without surfacing a user event.
    pub fn wake(self: *KqueuePoller) !void {
        const trigger = [_]std.posix.Kevent{.{
            .ident = wake_ident,
            .filter = std.posix.system.EVFILT_USER,
            .flags = 0,
            .fflags = std.posix.system.NOTE_TRIGGER,
            .data = 0,
            .udata = 0,
        }};
        _ = try std.posix.kevent(self.kqueue_fd, &trigger, &[_]std.posix.Kevent{}, null);
    }

    pub fn register(self: *KqueuePoller, fd: std.posix.fd_t, events: u32) !void {
        var changes: [2]std.posix.Kevent = undefined;
        var change_count: usize = 0;

        if (events & IoEvent.READ != 0) {
            changes[change_count] = std.posix.Kevent{
                .ident = @intCast(fd),
                .filter = std.posix.system.EVFILT_READ,
                .flags = std.posix.system.EV_ADD | std.posix.system.EV_ENABLE,
                .fflags = 0,
                .data = 0,
                .udata = 0,
            };
            change_count += 1;
        }

        if (events & IoEvent.WRITE != 0) {
            changes[change_count] = std.posix.Kevent{
                .ident = @intCast(fd),
                .filter = std.posix.system.EVFILT_WRITE,
                .flags = std.posix.system.EV_ADD | std.posix.system.EV_ENABLE,
                .fflags = 0,
                .data = 0,
                .udata = 0,
            };
            change_count += 1;
        }

        _ = try std.posix.kevent(self.kqueue_fd, changes[0..change_count], &[_]std.posix.Kevent{}, null);
    }

    pub fn unregister(self: *KqueuePoller, fd: std.posix.fd_t) !void {
        const changes = [_]std.posix.Kevent{
            std.posix.Kevent{
                .ident = @intCast(fd),
                .filter = std.posix.system.EVFILT_READ,
                .flags = std.posix.system.EV_DELETE,
                .fflags = 0,
                .data = 0,
                .udata = 0,
            },
            std.posix.Kevent{
                .ident = @intCast(fd),
                .filter = std.posix.system.EVFILT_WRITE,
                .flags = std.posix.system.EV_DELETE,
                .fflags = 0,
                .data = 0,
                .udata = 0,
            },
        };
        _ = try std.posix.kevent(self.kqueue_fd, &changes, &[_]std.posix.Kevent{}, null);
    }

    pub fn poll(self: *KqueuePoller, timeout_ms: i32) ![]IoEvent {
        const timeout = if (timeout_ms < 0)
            null
        else
            &std.posix.timespec{
                .tv_sec = @divFloor(timeout_ms, 1000),
                .tv_nsec = @mod(timeout_ms, 1000) * 1_000_000,
            };

        const count = try std.posix.kevent(
            self.kqueue_fd,
            &[_]std.posix.Kevent{},
            self.events,
            timeout,
        );

        // Exclude the wakeup user event from the reported readiness set.
        var real: usize = 0;
        for (self.events[0..count]) |event| {
            if (event.filter == std.posix.system.EVFILT_USER) continue;
            real += 1;
        }

        var io_events = try self.allocator.alloc(IoEvent, real);
        var i: usize = 0;
        for (self.events[0..count]) |event| {
            if (event.filter == std.posix.system.EVFILT_USER) continue;
            var events_flags: u32 = 0;
            if (event.filter == std.posix.system.EVFILT_READ) events_flags |= IoEvent.READ;
            if (event.filter == std.posix.system.EVFILT_WRITE) events_flags |= IoEvent.WRITE;

            io_events[i] = IoEvent{
                .fd = @intCast(event.ident),
                .events = events_flags,
            };
            i += 1;
        }

        return io_events;
    }
};

/// Windows IOCP implementation
const IocpPoller = struct {
    const windows = std.os.windows;

    /// IOCP handle
    iocp_handle: windows.HANDLE,
    /// Allocator for events
    allocator: std.mem.Allocator,
    /// Registered handles with their associated data
    registered_handles: std.AutoHashMap(windows.HANDLE, RegisteredHandle),
    /// Completion entries buffer
    completion_entries: []windows.OVERLAPPED_ENTRY,

    const RegisteredHandle = struct {
        handle: windows.HANDLE,
        events: u32,
        overlapped_read: *windows.OVERLAPPED,
        overlapped_write: *windows.OVERLAPPED,
    };

    const INFINITE: windows.DWORD = 0xFFFFFFFF;

    pub fn init(allocator: std.mem.Allocator) !IocpPoller {
        _ = allocator;
        // Fail closed: IOCP is completion-based, but this backend never submits
        // the async reads/writes that would produce completions (`register` only
        // associates the handle). A constructed poller would therefore accept
        // registrations and silently report no I/O readiness ever — a false
        // claim of Windows support. Until a real completion-based backend exists
        // (translating submitted operations into readiness events), refuse to
        // build one. See `poller_support` (= `.unsupported` on Windows). The
        // register/poll/wake bodies below are retained as the design skeleton
        // for that future backend but are unreachable while init fails closed.
        return error.PlatformNotSupported;
    }

    pub fn deinit(self: *IocpPoller) void {
        // Clean up all registered handles
        var iter = self.registered_handles.iterator();
        while (iter.next()) |entry| {
            self.allocator.destroy(entry.value_ptr.overlapped_read);
            self.allocator.destroy(entry.value_ptr.overlapped_write);
        }
        self.registered_handles.deinit();

        self.allocator.free(self.completion_entries);

        if (self.iocp_handle != windows.INVALID_HANDLE_VALUE) {
            windows.CloseHandle(self.iocp_handle);
        }
    }

    pub fn register(self: *IocpPoller, fd: std.posix.fd_t, events: u32) !void {
        // On Windows, fd_t is a HANDLE
        const handle: windows.HANDLE = @ptrFromInt(@as(usize, @intCast(fd)));

        // Associate handle with IOCP
        const result = windows.kernel32.CreateIoCompletionPort(
            handle,
            self.iocp_handle,
            @intFromPtr(handle), // Use handle address as completion key
            0,
        );

        if (result == null) {
            return error.IocpAssociateFailed;
        }

        // Allocate OVERLAPPED structures for async operations
        const overlapped_read = try self.allocator.create(windows.OVERLAPPED);
        const overlapped_write = try self.allocator.create(windows.OVERLAPPED);
        overlapped_read.* = std.mem.zeroes(windows.OVERLAPPED);
        overlapped_write.* = std.mem.zeroes(windows.OVERLAPPED);

        try self.registered_handles.put(handle, RegisteredHandle{
            .handle = handle,
            .events = events,
            .overlapped_read = overlapped_read,
            .overlapped_write = overlapped_write,
        });
    }

    pub fn unregister(self: *IocpPoller, fd: std.posix.fd_t) !void {
        const handle: windows.HANDLE = @ptrFromInt(@as(usize, @intCast(fd)));

        if (self.registered_handles.fetchRemove(handle)) |kv| {
            self.allocator.destroy(kv.value.overlapped_read);
            self.allocator.destroy(kv.value.overlapped_write);
        }
        // Note: Cannot disassociate handle from IOCP - it's automatically
        // removed when the handle is closed
    }

    pub fn poll(self: *IocpPoller, timeout_ms: i32) ![]IoEvent {
        const timeout: windows.DWORD = if (timeout_ms < 0)
            INFINITE
        else
            @intCast(timeout_ms);

        var num_entries: windows.ULONG = 0;

        // Get queued completion status entries
        const success = windows.kernel32.GetQueuedCompletionStatusEx(
            self.iocp_handle,
            self.completion_entries.ptr,
            @intCast(self.completion_entries.len),
            &num_entries,
            timeout,
            windows.FALSE, // Not alertable
        );

        if (success == windows.FALSE) {
            const err = windows.kernel32.GetLastError();
            if (err == windows.Win32Error.WAIT_TIMEOUT) {
                // Timeout is not an error, just no events
                return try self.allocator.alloc(IoEvent, 0);
            }
            return error.IocpWaitFailed;
        }

        // Convert completion entries to IoEvents
        var io_events = try self.allocator.alloc(IoEvent, num_entries);
        var valid_count: usize = 0;

        for (self.completion_entries[0..num_entries]) |entry| {
            const handle: windows.HANDLE = @ptrFromInt(entry.lpCompletionKey);

            if (self.registered_handles.get(handle)) |reg| {
                var event_flags: u32 = 0;

                // Determine event type based on which OVERLAPPED was used
                if (entry.lpOverlapped == reg.overlapped_read) {
                    event_flags |= IoEvent.READ;
                } else if (entry.lpOverlapped == reg.overlapped_write) {
                    event_flags |= IoEvent.WRITE;
                }

                // Check for errors
                if (entry.dwNumberOfBytesTransferred == 0) {
                    event_flags |= IoEvent.HANGUP;
                }

                io_events[valid_count] = IoEvent{
                    .fd = @intCast(@intFromPtr(handle)),
                    .events = event_flags,
                    .data = @ptrFromInt(entry.lpCompletionKey),
                };
                valid_count += 1;
            }
        }

        // Resize to actual valid count
        if (valid_count < num_entries) {
            io_events = try self.allocator.realloc(io_events, valid_count);
        }

        return io_events;
    }

    /// Post a completion event manually (useful for waking up the loop)
    pub fn wake(self: *IocpPoller) !void {
        const success = windows.kernel32.PostQueuedCompletionStatus(
            self.iocp_handle,
            0,
            0,
            null,
        );
        if (success == windows.FALSE) {
            return error.IocpPostFailed;
        }
    }
};

/// Main event loop.
///
/// Execution model (decided, authoritative): the `EventLoop` is the single
/// reactor that runs application logic. All callbacks — timers, immediates,
/// I/O readiness handlers, and cross-thread tasks — execute on the one loop
/// thread, serially, so handlers never race each other and need no locking of
/// their own state. The loop is also the sole owner of callback contexts: the
/// `ContextCleanup` contract lives here and every owned context is freed
/// exactly once by the loop thread.
///
/// The work-stealing `scheduler.Scheduler` is NOT a second execution model. It
/// is a subordinate, CPU-offload pool for parallelizing pure/CPU-bound work off
/// the loop thread. Scheduler task contexts are borrowed (the submitter owns
/// them; the scheduler frees nothing), and scheduler workers must not touch
/// loop-owned state directly. The only sanctioned way for offloaded work to
/// re-enter the reactor — to deliver a result or run a continuation on the loop
/// thread — is `EventLoop.submit`, which is thread-safe, wakes a parked loop,
/// and re-enters the ownership contract. This keeps one authoritative model:
/// the loop runs your code; the scheduler is a compute helper that hands results
/// back through the loop's front door.
pub const EventLoop = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    io_poller: IoPoller,
    timer_heap: TimerHeap,
    task_queue: TaskQueue,
    immediate_queue: ImmediateQueue,
    is_running: bool = false,
    /// Maps a registered descriptor to its readiness handler. The loop owns any
    /// non-null context per the `ContextCleanup` contract and releases it when
    /// the descriptor is unregistered, rebound, or the loop is torn down.
    io_handlers: std.AutoHashMapUnmanaged(std.posix.fd_t, IoRegistration) = .empty,
    /// Optional sink for errors returned by I/O callbacks. A failing callback
    /// never kills the loop; the descriptor is unregistered and the error is
    /// routed here instead.
    io_error_handler: ?IoErrorHandler = null,
    /// Guards `inbox` so `submit` can be called from any thread while the loop
    /// thread drains it. Only the enqueue/drain hand-off is locked; task
    /// execution happens on the loop thread outside the lock.
    inbox_mutex: Spinlock = .{},
    /// Tasks submitted from other threads, drained into `task_queue` at the top
    /// of each tick. Owned contexts follow the `ContextCleanup` contract.
    inbox: std.ArrayListUnmanaged(Task) = .empty,
    /// Set by `requestStop` from any thread to break `runUntilStop`.
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !EventLoop {
        return EventLoop{
            .allocator = allocator,
            .io = io,
            .io_poller = try IoPoller.init(allocator),
            .timer_heap = TimerHeap.init(allocator, io),
            .task_queue = TaskQueue.init(allocator),
            .immediate_queue = ImmediateQueue.init(allocator),
        };
    }

    pub fn deinit(self: *EventLoop) void {
        // Release contexts the loop owns for descriptors still registered at
        // shutdown before dropping the table.
        var it = self.io_handlers.iterator();
        while (it.next()) |entry| {
            releaseIoContext(self.allocator, entry.value_ptr.*);
        }
        self.io_handlers.deinit(self.allocator);
        // Release contexts for cross-thread tasks that were submitted but never
        // drained into the task queue.
        for (self.inbox.items) |task| {
            TaskQueue.releaseTaskContext(self.allocator, task);
        }
        self.inbox.deinit(self.allocator);
        self.io_poller.deinit();
        self.timer_heap.deinit();
        self.task_queue.deinit();
        self.immediate_queue.deinit();
    }

    /// Run the event loop until `stop` is called or no work remains.
    pub fn run(self: *EventLoop) !void {
        self.is_running = true;

        while (self.is_running) {
            const timeout = self.calculateTimeout();
            const timeout_ms: i32 = if (timeout) |t| @intCast(t) else -1;
            try self.tick(timeout_ms);
            if (self.shouldExit()) break;
        }
    }

    /// Run exactly one iteration: drain immediates, fire expired timers, poll
    /// I/O for up to `timeout_ms` (negative blocks until a descriptor is ready),
    /// dispatch ready descriptors to their handlers, then drain the task queue.
    /// Returns after a single pass so an embedder can drive the loop manually or
    /// step it deterministically in tests without sleeping. `run` is this in a
    /// loop with a computed timeout.
    pub fn tick(self: *EventLoop, timeout_ms: i32) !void {
        try self.drainInbox();
        try self.immediate_queue.process();
        try self.timer_heap.processExpired();

        const events = try self.io_poller.poll(timeout_ms);
        defer self.allocator.free(events);
        try self.processIoEvents(events);

        try self.task_queue.process();
    }

    /// Move cross-thread submissions into the loop-thread task queue. Only the
    /// hand-off is locked; the tasks run later in the tick under no lock. A
    /// submit that raced past this drain stays visible via the wakeup eventfd,
    /// so the next tick picks it up (no lost wakeups).
    fn drainInbox(self: *EventLoop) !void {
        self.inbox_mutex.lock();
        var pending = self.inbox;
        self.inbox = .empty;
        self.inbox_mutex.unlock();
        defer pending.deinit(self.allocator);

        var moved: usize = 0;
        // If moving a task into the queue fails, release the contexts the loop
        // still owns for the tasks that were not transferred.
        errdefer for (pending.items[moved..]) |task| {
            TaskQueue.releaseTaskContext(self.allocator, task);
        };
        while (moved < pending.items.len) {
            try self.task_queue.queue.append(self.allocator, pending.items[moved]);
            moved += 1;
        }
    }

    pub fn stop(self: *EventLoop) void {
        self.is_running = false;
    }

    /// Server-style run: park in `poll` between iterations and keep running
    /// until `requestStop` is called from any thread. Unlike `run`, which exits
    /// as soon as no work remains, this stays alive waiting for cross-thread
    /// `submit`s. A blocking poll is interrupted immediately by the wakeup
    /// primitive, so stop and submission take effect without waiting out a
    /// timer.
    pub fn runUntilStop(self: *EventLoop) !void {
        // `stop_requested` is intentionally not reset here: a `requestStop` that
        // races ahead of this call must still stop the loop rather than be lost.
        // `requestStop` is therefore terminal for a given loop.
        self.is_running = true;
        defer self.is_running = false;

        while (self.is_running and !self.stop_requested.load(.seq_cst)) {
            const timeout = self.calculateTimeout();
            const timeout_ms: i32 = if (timeout) |t| @intCast(t) else -1;
            try self.tick(timeout_ms);
        }
    }

    /// Interrupt a blocking `poll` from any thread. Safe to call concurrently
    /// with the loop thread.
    pub fn wake(self: *EventLoop) !void {
        return self.io_poller.wake();
    }

    /// Submit a task from any thread. The task runs on the loop thread on its
    /// next tick, and the wakeup interrupts a blocking poll so it runs promptly.
    /// If `cleanup` is non-null the loop takes ownership of `context` and
    /// releases it after the task runs (or at shutdown); on enqueue failure
    /// ownership stays with the caller.
    ///
    /// This is the one sanctioned seam between the `scheduler.Scheduler` compute
    /// pool and the reactor: a scheduler worker that has finished CPU-bound work
    /// calls `loop.submit` to run its continuation (deliver the result, touch
    /// loop-owned state) back on the authoritative loop thread. Scheduler
    /// workers must not mutate loop state directly; they hand it back here.
    pub fn submit(
        self: *EventLoop,
        callback: TaskCallback,
        context: ?*anyopaque,
        cleanup: ?ContextCleanup,
    ) !void {
        {
            self.inbox_mutex.lock();
            defer self.inbox_mutex.unlock();
            try self.inbox.append(self.allocator, Task{
                .callback = callback,
                .context = context,
                .context_cleanup = cleanup,
            });
        }
        try self.io_poller.wake();
    }

    /// Request shutdown from any thread and interrupt a blocking poll so
    /// `runUntilStop` returns promptly. Wakeup is best-effort: if it fails the
    /// stop flag is still observed on the next tick.
    pub fn requestStop(self: *EventLoop) void {
        self.stop_requested.store(true, .seq_cst);
        self.io_poller.wake() catch {};
    }

    fn calculateTimeout(self: *EventLoop) ?u64 {
        // If immediate queue has tasks, don't block
        if (!self.immediate_queue.isEmpty()) return 0;

        // If task queue has tasks, don't block
        if (!self.task_queue.isEmpty()) return 0;

        // If another thread already left work in the inbox, don't block: the
        // next tick will drain it. This closes the window where the wakeup was
        // consumed by a prior poll but the task had not yet been transferred.
        if (!self.inboxIsEmpty()) return 0;

        // Otherwise, wait until next timer
        return self.timer_heap.nextTimeout();
    }

    /// Thread-safe check of whether any cross-thread submissions are pending.
    fn inboxIsEmpty(self: *EventLoop) bool {
        self.inbox_mutex.lock();
        defer self.inbox_mutex.unlock();
        return self.inbox.items.len == 0;
    }

    /// Dispatch each ready descriptor to its registered handler. A handler that
    /// returns an error is isolated: the descriptor is unregistered (releasing
    /// its context) and the error is routed to `io_error_handler`, so one broken
    /// callback can neither kill the loop nor hot-loop on a fd that keeps
    /// signalling readiness. Events for descriptors with no registration (e.g.
    /// just unregistered) are ignored.
    fn processIoEvents(self: *EventLoop, events: []IoEvent) !void {
        for (events) |event| {
            const reg = self.io_handlers.get(event.fd) orelse continue;
            reg.callback(reg.context, event) catch |err| {
                self.unregisterFd(event.fd) catch {};
                if (self.io_error_handler) |handler| handler(event.fd, err);
            };
        }
    }

    fn shouldExit(self: *EventLoop) bool {
        // Exit if:
        // - Not running, or
        // - No timers, tasks, immediates, and no registered descriptors. A
        //   server parked on a listening socket has an io handler registered, so
        //   it keeps running with no timers/tasks pending.
        if (!self.is_running) return true;

        const has_timers = self.timer_heap.timers.peek() != null;
        const has_tasks = !self.task_queue.isEmpty();
        const has_immediates = !self.immediate_queue.isEmpty();
        const has_io = self.io_handlers.count() > 0;

        return !has_timers and !has_tasks and !has_immediates and !has_io;
    }

    /// setTimeout - execute callback after delay. See `TimerHeap.setTimeout`
    /// for the `data`/`cleanup` ownership contract.
    pub fn setTimeout(
        self: *EventLoop,
        delay_ms: u64,
        callback: TimerCallback,
        data: ?*anyopaque,
        cleanup: ?ContextCleanup,
    ) !u64 {
        return self.timer_heap.setTimeout(delay_ms, callback, data, cleanup);
    }

    /// setInterval - execute callback repeatedly. See `TimerHeap.setInterval`
    /// for the `data`/`cleanup` ownership contract.
    pub fn setInterval(
        self: *EventLoop,
        interval_ms: u64,
        callback: TimerCallback,
        data: ?*anyopaque,
        cleanup: ?ContextCleanup,
    ) !u64 {
        return self.timer_heap.setInterval(interval_ms, callback, data, cleanup);
    }

    /// clearTimeout/clearInterval
    pub fn clearTimer(self: *EventLoop, id: u64) void {
        self.timer_heap.clearTimer(id);
    }

    /// setImmediate - execute callback on next tick
    pub fn setImmediate(self: *EventLoop, callback: TaskCallback) !void {
        try self.immediate_queue.enqueue(callback);
    }

    /// Register a descriptor for I/O readiness, binding a `callback` and its
    /// (optionally loop-owned) `context`. Re-registering a descriptor rebinds
    /// the handler and releases the prior context; changing the readiness
    /// `events` mask requires `unregisterFd` then `registerFd`, since the poller
    /// add is one-shot. See `ContextCleanup` for the ownership contract. If the
    /// poller rejects the registration, a loop-owned context is released before
    /// the error is returned, so a failed call strands nothing.
    pub fn registerFd(
        self: *EventLoop,
        fd: std.posix.fd_t,
        events: u32,
        callback: IoCallback,
        context: ?*anyopaque,
        cleanup: ?ContextCleanup,
    ) !void {
        const reg = IoRegistration{ .callback = callback, .context = context, .cleanup = cleanup };
        const gop = try self.io_handlers.getOrPut(self.allocator, fd);
        if (gop.found_existing) {
            // The fd is already in the poller; rebind and drop the old context.
            releaseIoContext(self.allocator, gop.value_ptr.*);
            gop.value_ptr.* = reg;
            return;
        }
        gop.value_ptr.* = reg;
        errdefer {
            _ = self.io_handlers.remove(fd);
            releaseIoContext(self.allocator, reg);
        }
        try self.io_poller.register(fd, events);
    }

    /// Unregister a descriptor: remove it from the poller and release any
    /// loop-owned context. Descriptors that are not registered are ignored.
    pub fn unregisterFd(self: *EventLoop, fd: std.posix.fd_t) !void {
        if (self.io_handlers.fetchRemove(fd)) |kv| {
            releaseIoContext(self.allocator, kv.value);
            try self.io_poller.unregister(fd);
        }
    }
};

// ============================================================================
// Tests — ownership contract for queued work
// ============================================================================

const TaskTestCtx = struct {
    ran: *bool,
    freed: *usize,
    fail: bool = false,

    fn run(task: *Task) !void {
        const self: *TaskTestCtx = @ptrCast(@alignCast(task.context.?));
        self.ran.* = true;
        if (self.fail) return error.TaskFailed;
    }

    fn cleanup(allocator: std.mem.Allocator, context: *anyopaque) void {
        const self: *TaskTestCtx = @ptrCast(@alignCast(context));
        self.freed.* += 1;
        allocator.destroy(self);
    }
};

const TimerTestCtx = struct {
    fired: *usize,
    freed: *usize,

    fn onFire(timer: *Timer) void {
        const self: *TimerTestCtx = @ptrCast(@alignCast(timer.data.?));
        self.fired.* += 1;
    }

    fn cleanup(allocator: std.mem.Allocator, context: *anyopaque) void {
        const self: *TimerTestCtx = @ptrCast(@alignCast(context));
        self.freed.* += 1;
        allocator.destroy(self);
    }
};

test "task queue releases owned context exactly once after processing" {
    const allocator = std.testing.allocator;
    var q = TaskQueue.init(allocator);
    defer q.deinit();

    var ran = false;
    var freed: usize = 0;
    const ctx = try allocator.create(TaskTestCtx);
    ctx.* = .{ .ran = &ran, .freed = &freed };

    try q.enqueueWithContext(TaskTestCtx.run, ctx, TaskTestCtx.cleanup);
    try q.process();

    try std.testing.expect(ran);
    try std.testing.expectEqual(@as(usize, 1), freed);
}

test "task queue does not free a borrowed context" {
    const allocator = std.testing.allocator;
    var q = TaskQueue.init(allocator);
    defer q.deinit();

    var ran = false;
    var freed: usize = 0;
    var ctx = TaskTestCtx{ .ran = &ran, .freed = &freed };

    try q.enqueueWithContext(TaskTestCtx.run, &ctx, null);
    try q.process();

    try std.testing.expect(ran);
    try std.testing.expectEqual(@as(usize, 0), freed);
}

test "task queue releases owned context on shutdown drain" {
    const allocator = std.testing.allocator;
    var q = TaskQueue.init(allocator);

    var ran = false;
    var freed: usize = 0;
    const ctx = try allocator.create(TaskTestCtx);
    ctx.* = .{ .ran = &ran, .freed = &freed };

    try q.enqueueWithContext(TaskTestCtx.run, ctx, TaskTestCtx.cleanup);

    // Never processed — deinit must drain and free the owned context.
    q.deinit();

    try std.testing.expect(!ran);
    try std.testing.expectEqual(@as(usize, 1), freed);
}

test "task queue error mid-batch still releases every owned context once" {
    const allocator = std.testing.allocator;
    var q = TaskQueue.init(allocator);
    defer q.deinit();

    var ran_a = false;
    var freed_a: usize = 0;
    var ran_b = false;
    var freed_b: usize = 0;

    const a = try allocator.create(TaskTestCtx);
    a.* = .{ .ran = &ran_a, .freed = &freed_a, .fail = true };
    const b = try allocator.create(TaskTestCtx);
    b.* = .{ .ran = &ran_b, .freed = &freed_b };

    try q.enqueueWithContext(TaskTestCtx.run, a, TaskTestCtx.cleanup);
    try q.enqueueWithContext(TaskTestCtx.run, b, TaskTestCtx.cleanup);

    try std.testing.expectError(error.TaskFailed, q.process());

    // The failing task released its own context; the not-yet-run task's context
    // was released by the error sweep — each exactly once.
    try std.testing.expect(ran_a);
    try std.testing.expect(!ran_b);
    try std.testing.expectEqual(@as(usize, 1), freed_a);
    try std.testing.expectEqual(@as(usize, 1), freed_b);
}

test "one-shot timer releases owned data after firing" {
    const allocator = std.testing.allocator;
    var heap = TimerHeap.init(allocator, std.testing.io);
    defer heap.deinit();

    var fired: usize = 0;
    var freed: usize = 0;
    const ctx = try allocator.create(TimerTestCtx);
    ctx.* = .{ .fired = &fired, .freed = &freed };

    _ = try heap.setTimeout(0, TimerTestCtx.onFire, ctx, TimerTestCtx.cleanup);
    try heap.processExpired();

    try std.testing.expectEqual(@as(usize, 1), fired);
    try std.testing.expectEqual(@as(usize, 1), freed);
}

test "cancelled timer releases owned data without firing" {
    const allocator = std.testing.allocator;
    var heap = TimerHeap.init(allocator, std.testing.io);
    defer heap.deinit();

    var fired: usize = 0;
    var freed: usize = 0;
    const ctx = try allocator.create(TimerTestCtx);
    ctx.* = .{ .fired = &fired, .freed = &freed };

    const id = try heap.setTimeout(0, TimerTestCtx.onFire, ctx, TimerTestCtx.cleanup);
    heap.clearTimer(id);
    try heap.processExpired();

    try std.testing.expectEqual(@as(usize, 0), fired);
    try std.testing.expectEqual(@as(usize, 1), freed);
}

test "timer heap does not free borrowed data" {
    const allocator = std.testing.allocator;
    var heap = TimerHeap.init(allocator, std.testing.io);
    defer heap.deinit();

    var fired: usize = 0;
    var freed: usize = 0;
    var ctx = TimerTestCtx{ .fired = &fired, .freed = &freed };

    _ = try heap.setTimeout(0, TimerTestCtx.onFire, &ctx, null);
    try heap.processExpired();

    try std.testing.expectEqual(@as(usize, 1), fired);
    try std.testing.expectEqual(@as(usize, 0), freed);
}

test "timer heap frees owned data for timers still queued at shutdown" {
    const allocator = std.testing.allocator;
    var heap = TimerHeap.init(allocator, std.testing.io);

    var fired: usize = 0;
    var freed: usize = 0;
    const ctx = try allocator.create(TimerTestCtx);
    ctx.* = .{ .fired = &fired, .freed = &freed };

    // Far in the future so it never fires before shutdown.
    _ = try heap.setTimeout(3_600_000, TimerTestCtx.onFire, ctx, TimerTestCtx.cleanup);
    heap.deinit();

    try std.testing.expectEqual(@as(usize, 0), fired);
    try std.testing.expectEqual(@as(usize, 1), freed);
}

test "repeating timer keeps its data across re-arm and frees once on shutdown" {
    const allocator = std.testing.allocator;
    var heap = TimerHeap.init(allocator, std.testing.io);

    var fired: usize = 0;
    var freed: usize = 0;
    const ctx = try allocator.create(TimerTestCtx);
    ctx.* = .{ .fired = &fired, .freed = &freed };

    // Past deadline so it fires immediately; a large repeat interval re-arms it
    // into the future so processExpired fires it exactly once.
    try heap.timers.push(allocator, Timer{
        .id = 1,
        .deadline = 0,
        .callback = TimerTestCtx.onFire,
        .repeat = 3_600_000,
        .data = ctx,
        .data_cleanup = TimerTestCtx.cleanup,
    });
    // Keep the id allocator ahead of manually-pushed ids: processExpired treats
    // any id >= next_id as scheduled by a callback mid-pass.
    heap.next_id = 2;

    try heap.processExpired();
    // Data survives the re-arm — not freed yet.
    try std.testing.expectEqual(@as(usize, 1), fired);
    try std.testing.expectEqual(@as(usize, 0), freed);

    // Shutdown drains the still-armed repeating timer and frees its data once.
    heap.deinit();
    try std.testing.expectEqual(@as(usize, 1), freed);
}

// ============================================================================
// Tests — timer hardening: drift, zero interval, overflow, cancellation
// ============================================================================

test "nextDeadline advances from the scheduled deadline and stays ahead of now" {
    // On time: advances from the scheduled deadline (no drift), not from now.
    try std.testing.expectEqual(@as(i64, 1100), TimerHeap.nextDeadline(1000, 1000, 100));
    // Slightly late: still lands on the scheduled cadence, not now+interval.
    try std.testing.expectEqual(@as(i64, 1100), TimerHeap.nextDeadline(1000, 1050, 100));
    // Badly overdue: jumps forward in one hop to strictly after now.
    try std.testing.expectEqual(@as(i64, 5100), TimerHeap.nextDeadline(1000, 5000, 100));
    // Zero interval never stalls: it becomes the smallest tick past now.
    try std.testing.expectEqual(@as(i64, 1001), TimerHeap.nextDeadline(1000, 1000, 0));
    try std.testing.expect(TimerHeap.nextDeadline(0, 1000, 0) > 1000);
    // Overflow saturates instead of trapping.
    try std.testing.expectEqual(
        @as(i64, std.math.maxInt(i64)),
        TimerHeap.nextDeadline(std.math.maxInt(i64), 0, 1000),
    );
    try std.testing.expect(TimerHeap.nextDeadline(0, 0, std.math.maxInt(u64)) > 0);
}

test "an enormous delay saturates instead of overflowing i64" {
    const allocator = std.testing.allocator;
    var heap = TimerHeap.init(allocator, std.testing.io);
    defer heap.deinit();

    var fired: usize = 0;
    var freed: usize = 0;
    const ctx = try allocator.create(TimerTestCtx);
    ctx.* = .{ .fired = &fired, .freed = &freed };

    // u64 max exceeds i64: must saturate, not overflow, and never fire now.
    _ = try heap.setTimeout(std.math.maxInt(u64), TimerTestCtx.onFire, ctx, TimerTestCtx.cleanup);
    try heap.processExpired();
    try std.testing.expectEqual(@as(usize, 0), fired);
    try std.testing.expectEqual(@as(usize, 0), freed);
}

// Control context able to schedule/cancel timers from inside a callback.
const TimerCtl = struct {
    heap: *TimerHeap,
    fired: *usize,
    freed: *usize,
    action: enum { none, cancel_self, cancel_other, schedule } = .none,
    other_id: u64 = 0,
    sched_fired: ?*usize = null,

    fn onFire(timer: *Timer) void {
        const self: *TimerCtl = @ptrCast(@alignCast(timer.data.?));
        self.fired.* += 1;
        switch (self.action) {
            .none => {},
            .cancel_self => self.heap.clearTimer(timer.id),
            .cancel_other => self.heap.clearTimer(self.other_id),
            .schedule => _ = self.heap.setTimeout(
                0,
                TimerCtl.onScheduled,
                self.sched_fired,
                null,
            ) catch {},
        }
    }

    fn onScheduled(timer: *Timer) void {
        const counter: *usize = @ptrCast(@alignCast(timer.data.?));
        counter.* += 1;
    }

    fn cleanup(allocator: std.mem.Allocator, context: *anyopaque) void {
        const self: *TimerCtl = @ptrCast(@alignCast(context));
        self.freed.* += 1;
        allocator.destroy(self);
    }
};

test "zero-interval repeating timer fires once per pass without spinning" {
    const allocator = std.testing.allocator;
    var heap = TimerHeap.init(allocator, std.testing.io);

    var fired: usize = 0;
    var freed: usize = 0;
    const ctx = try allocator.create(TimerTestCtx);
    ctx.* = .{ .fired = &fired, .freed = &freed };

    try heap.timers.push(allocator, Timer{
        .id = 1,
        .deadline = 0,
        .callback = TimerTestCtx.onFire,
        .repeat = 0, // zero interval must not livelock the pass
        .data = ctx,
        .data_cleanup = TimerTestCtx.cleanup,
    });
    heap.next_id = 2;

    try heap.processExpired();
    // Fired exactly once and re-armed strictly in the future (no 0 timeout spin).
    try std.testing.expectEqual(@as(usize, 1), fired);
    try std.testing.expect(heap.nextTimeout() != null);
    try std.testing.expect(heap.nextTimeout().? > 0);

    heap.deinit();
    try std.testing.expectEqual(@as(usize, 1), freed);
}

test "a repeating timer can cancel itself from its own callback" {
    const allocator = std.testing.allocator;
    var heap = TimerHeap.init(allocator, std.testing.io);
    defer heap.deinit();

    var fired: usize = 0;
    var freed: usize = 0;
    const ctx = try allocator.create(TimerCtl);
    ctx.* = .{ .heap = &heap, .fired = &fired, .freed = &freed, .action = .cancel_self };

    try heap.timers.push(allocator, Timer{
        .id = 1,
        .deadline = 0,
        .callback = TimerCtl.onFire,
        .repeat = 1000,
        .data = ctx,
        .data_cleanup = TimerCtl.cleanup,
    });
    heap.next_id = 2;

    try heap.processExpired();
    // Fired once, then dropped (not re-armed) and its data freed exactly once.
    try std.testing.expectEqual(@as(usize, 1), fired);
    try std.testing.expectEqual(@as(usize, 1), freed);
    try std.testing.expect(heap.nextTimeout() == null);
}

test "a callback can cancel a timer that already fired earlier in the same pass" {
    const allocator = std.testing.allocator;
    var heap = TimerHeap.init(allocator, std.testing.io);

    var a_fired: usize = 0;
    var a_freed: usize = 0;
    const a = try allocator.create(TimerCtl);
    a.* = .{ .heap = &heap, .fired = &a_fired, .freed = &a_freed, .action = .none };

    var b_fired: usize = 0;
    var b_freed: usize = 0;
    const b = try allocator.create(TimerCtl);
    b.* = .{ .heap = &heap, .fired = &b_fired, .freed = &b_freed, .action = .cancel_other, .other_id = 1 };

    // A fires first (earlier deadline) and re-arms into the pass's held-aside
    // list; B fires next and cancels A while it is sitting there.
    try heap.timers.push(allocator, Timer{
        .id = 1,
        .deadline = 0,
        .callback = TimerCtl.onFire,
        .repeat = 1000,
        .data = a,
        .data_cleanup = TimerCtl.cleanup,
    });
    try heap.timers.push(allocator, Timer{
        .id = 2,
        .deadline = 1,
        .callback = TimerCtl.onFire,
        .repeat = 1000,
        .data = b,
        .data_cleanup = TimerCtl.cleanup,
    });
    heap.next_id = 3;

    try heap.processExpired();
    // Both fired once; A was cancelled after firing → dropped and freed. B stays armed.
    try std.testing.expectEqual(@as(usize, 1), a_fired);
    try std.testing.expectEqual(@as(usize, 1), a_freed);
    try std.testing.expectEqual(@as(usize, 1), b_fired);
    try std.testing.expectEqual(@as(usize, 0), b_freed);

    heap.deinit();
    try std.testing.expectEqual(@as(usize, 1), b_freed);
}

test "a timer scheduled from a callback fires on the next pass, not the current one" {
    const allocator = std.testing.allocator;
    var heap = TimerHeap.init(allocator, std.testing.io);
    defer heap.deinit();

    var fired: usize = 0;
    var freed: usize = 0;
    var sched_fired: usize = 0;
    const ctx = try allocator.create(TimerCtl);
    ctx.* = .{
        .heap = &heap,
        .fired = &fired,
        .freed = &freed,
        .action = .schedule,
        .sched_fired = &sched_fired,
    };

    _ = try heap.setTimeout(0, TimerCtl.onFire, ctx, TimerCtl.cleanup);

    // Pass 1: the original fires and schedules an already-expired timer, which
    // must be deferred rather than fired in the same pass.
    try heap.processExpired();
    try std.testing.expectEqual(@as(usize, 1), fired);
    try std.testing.expectEqual(@as(usize, 0), sched_fired);

    // Pass 2: the deferred timer becomes eligible and fires.
    try heap.processExpired();
    try std.testing.expectEqual(@as(usize, 1), sched_fired);
}

// ============================================================================
// Tests — I/O readiness registration table and dispatch
// ============================================================================

const IoTestCtx = struct {
    fired: *usize,
    got_read: *bool,
    freed: *usize,
    fail: bool = false,

    fn onReady(context: ?*anyopaque, event: IoEvent) anyerror!void {
        const self: *IoTestCtx = @ptrCast(@alignCast(context.?));
        self.fired.* += 1;
        if (event.events & IoEvent.READ != 0) self.got_read.* = true;
        if (self.fail) return error.Boom;
    }

    fn cleanup(allocator: std.mem.Allocator, context: *anyopaque) void {
        const self: *IoTestCtx = @ptrCast(@alignCast(context));
        self.freed.* += 1;
        allocator.destroy(self);
    }
};

// These exercise the readiness registration/dispatch table on a real pipe. The
// dispatch logic lives in EventLoop (platform-independent); the pipe/write/close
// primitives below use the Linux syscall layer, so the tests are gated to Linux.
const io_dispatch_supported = builtin.os.tag == .linux;

fn testPipe() ![2]std.posix.fd_t {
    var fds: [2]std.posix.fd_t = undefined;
    const rc = std.os.linux.pipe(&fds);
    if (std.os.linux.errno(rc) != .SUCCESS) return error.PipeFailed;
    return fds;
}

fn testWrite(fd: std.posix.fd_t, bytes: []const u8) void {
    _ = std.os.linux.write(fd, bytes.ptr, bytes.len);
}

fn testClose(fd: std.posix.fd_t) void {
    _ = std.os.linux.close(fd);
}

test "event loop dispatches readiness to the registered handler with its context" {
    if (!io_dispatch_supported) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var loop = try EventLoop.init(allocator, std.testing.io);
    defer loop.deinit();

    const fds = try testPipe();
    defer testClose(fds[1]);
    // Make the read end ready before we poll, so tick(0) never blocks.
    testWrite(fds[1], "x");

    var fired: usize = 0;
    var got_read = false;
    var freed: usize = 0;
    var ctx = IoTestCtx{ .fired = &fired, .got_read = &got_read, .freed = &freed };

    try loop.registerFd(fds[0], IoEvent.READ, IoTestCtx.onReady, &ctx, null);
    // Borrowed context (cleanup=null): unregister on the way out, no free.
    defer loop.unregisterFd(fds[0]) catch {};

    try loop.tick(0);

    try std.testing.expectEqual(@as(usize, 1), fired);
    try std.testing.expect(got_read);
    try std.testing.expectEqual(@as(usize, 0), freed);
}

test "a failing io handler is isolated: unregistered, routed to the error sink, loop survives" {
    if (!io_dispatch_supported) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    const ErrSink = struct {
        var seen_fd: std.posix.fd_t = -1;
        var seen_err: ?anyerror = null;
        fn handle(fd: std.posix.fd_t, err: anyerror) void {
            seen_fd = fd;
            seen_err = err;
        }
    };
    ErrSink.seen_fd = -1;
    ErrSink.seen_err = null;

    var loop = try EventLoop.init(allocator, std.testing.io);
    defer loop.deinit();
    loop.io_error_handler = ErrSink.handle;

    const fds = try testPipe();
    defer testClose(fds[0]);
    defer testClose(fds[1]);
    testWrite(fds[1], "x");

    var fired: usize = 0;
    var got_read = false;
    var freed: usize = 0;
    // Owned context (cleanup set) so we also prove the failure path releases it.
    const ctx = try allocator.create(IoTestCtx);
    ctx.* = .{ .fired = &fired, .got_read = &got_read, .freed = &freed, .fail = true };

    try loop.registerFd(fds[0], IoEvent.READ, IoTestCtx.onReady, ctx, IoTestCtx.cleanup);

    // The handler errors; the loop must not propagate it out of tick.
    try loop.tick(0);

    try std.testing.expectEqual(@as(usize, 1), fired);
    // Descriptor was unregistered and its owned context freed exactly once.
    try std.testing.expectEqual(@as(usize, 0), loop.io_handlers.count());
    try std.testing.expectEqual(@as(usize, 1), freed);
    // The error was routed to the sink, not swallowed.
    try std.testing.expectEqual(fds[0], ErrSink.seen_fd);
    try std.testing.expectEqual(@as(?anyerror, error.Boom), ErrSink.seen_err);

    // A second tick with the fd gone is a no-op (the data is still buffered but
    // no handler remains), proving the loop is healthy afterward.
    try loop.tick(0);
    try std.testing.expectEqual(@as(usize, 1), fired);
}

test "unregisterFd releases a loop-owned context exactly once" {
    if (!io_dispatch_supported) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var loop = try EventLoop.init(allocator, std.testing.io);
    defer loop.deinit();

    const fds = try testPipe();
    defer testClose(fds[0]);
    defer testClose(fds[1]);

    var fired: usize = 0;
    var got_read = false;
    var freed: usize = 0;
    const ctx = try allocator.create(IoTestCtx);
    ctx.* = .{ .fired = &fired, .got_read = &got_read, .freed = &freed };

    try loop.registerFd(fds[0], IoEvent.READ, IoTestCtx.onReady, ctx, IoTestCtx.cleanup);
    try std.testing.expectEqual(@as(usize, 1), loop.io_handlers.count());

    try loop.unregisterFd(fds[0]);
    try std.testing.expectEqual(@as(usize, 0), loop.io_handlers.count());
    try std.testing.expectEqual(@as(usize, 1), freed);

    // Unregistering an unknown fd is a no-op, not an error.
    try loop.unregisterFd(fds[0]);
    try std.testing.expectEqual(@as(usize, 1), freed);
}

test "event loop shutdown releases owned contexts for descriptors still registered" {
    if (!io_dispatch_supported) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    const fds = try testPipe();
    defer testClose(fds[0]);
    defer testClose(fds[1]);

    var fired: usize = 0;
    var got_read = false;
    var freed: usize = 0;
    const ctx = try allocator.create(IoTestCtx);
    ctx.* = .{ .fired = &fired, .got_read = &got_read, .freed = &freed };

    var loop = try EventLoop.init(allocator, std.testing.io);
    try loop.registerFd(fds[0], IoEvent.READ, IoTestCtx.onReady, ctx, IoTestCtx.cleanup);

    // Tear down with the descriptor still registered: deinit must drain it.
    loop.deinit();
    try std.testing.expectEqual(@as(usize, 1), freed);
}

test "rebinding a descriptor releases the prior owned context" {
    if (!io_dispatch_supported) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var loop = try EventLoop.init(allocator, std.testing.io);
    defer loop.deinit();

    const fds = try testPipe();
    defer testClose(fds[0]);
    defer testClose(fds[1]);

    var fired: usize = 0;
    var got_read = false;
    var freed_a: usize = 0;
    var freed_b: usize = 0;
    const ctx_a = try allocator.create(IoTestCtx);
    ctx_a.* = .{ .fired = &fired, .got_read = &got_read, .freed = &freed_a };
    const ctx_b = try allocator.create(IoTestCtx);
    ctx_b.* = .{ .fired = &fired, .got_read = &got_read, .freed = &freed_b };

    try loop.registerFd(fds[0], IoEvent.READ, IoTestCtx.onReady, ctx_a, IoTestCtx.cleanup);
    // Rebinding the same fd must free ctx_a and keep exactly one registration.
    try loop.registerFd(fds[0], IoEvent.READ, IoTestCtx.onReady, ctx_b, IoTestCtx.cleanup);

    try std.testing.expectEqual(@as(usize, 1), freed_a);
    try std.testing.expectEqual(@as(usize, 0), freed_b);
    try std.testing.expectEqual(@as(usize, 1), loop.io_handlers.count());

    try loop.unregisterFd(fds[0]);
    try std.testing.expectEqual(@as(usize, 1), freed_b);
}

// ============================================================================
// Tests — cross-thread wakeup, submission, and shutdown
// ============================================================================

test "a pending wake makes a blocking poll return immediately" {
    if (!io_dispatch_supported) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var loop = try EventLoop.init(allocator, std.testing.io);
    defer loop.deinit();

    // Pre-signal the wakeup, then a poll with an infinite timeout must still
    // return at once because the wakeup descriptor is level-triggered and
    // already readable. Reaching the assertion (no hang) proves the interrupt;
    // the wake is drained and never surfaces as a user readiness event.
    try loop.wake();
    try loop.tick(-1);
    try std.testing.expectEqual(@as(usize, 0), loop.io_handlers.count());
}

const StopCtx = struct {
    loop: *EventLoop,
    ran: *bool,

    fn run(task: *Task) !void {
        const self: *StopCtx = @ptrCast(@alignCast(task.context.?));
        self.ran.* = true;
        // Runs on the loop thread: end the server loop from within.
        self.loop.requestStop();
    }
};

fn submitFromThread(loop: *EventLoop, ctx: *StopCtx) void {
    loop.submit(StopCtx.run, ctx, null) catch {};
}

test "cross-thread submit runs on the loop thread and stops the server loop" {
    if (!io_dispatch_supported) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var loop = try EventLoop.init(allocator, std.testing.io);
    defer loop.deinit();

    var ran = false;
    var ctx = StopCtx{ .loop = &loop, .ran = &ran };

    const t = try std.Thread.spawn(.{}, submitFromThread, .{ &loop, &ctx });
    // `runUntilStop` parks in a blocking poll until the cross-thread submit
    // wakes it; the submitted task then requests stop, ending the loop. If the
    // wakeup path were broken this would hang forever, so a clean return is the
    // proof that submission interrupts a blocking poll.
    try loop.runUntilStop();
    t.join();

    try std.testing.expect(ran);
}

fn stopFromThread(loop: *EventLoop) void {
    loop.requestStop();
}

test "cross-thread requestStop interrupts a blocking server loop" {
    if (!io_dispatch_supported) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var loop = try EventLoop.init(allocator, std.testing.io);
    defer loop.deinit();

    const t = try std.Thread.spawn(.{}, stopFromThread, .{&loop});
    // Shutdown from another thread must interrupt the blocking poll promptly
    // rather than wait out a timer. A clean return proves the wakeup fired.
    try loop.runUntilStop();
    t.join();

    try std.testing.expect(loop.stop_requested.load(.seq_cst));
}

test "submit hands the loop an owned context and it is released after running" {
    if (!io_dispatch_supported) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var loop = try EventLoop.init(allocator, std.testing.io);
    defer loop.deinit();

    var ran = false;
    var freed: usize = 0;
    const ctx = try allocator.create(TaskTestCtx);
    ctx.* = .{ .ran = &ran, .freed = &freed };

    // Submit an owned context from the current thread, then step the loop once.
    // drainInbox moves it into the task queue and the wake keeps poll from
    // blocking; the task runs and its owned context is freed exactly once.
    try loop.submit(TaskTestCtx.run, ctx, TaskTestCtx.cleanup);
    try loop.tick(-1);

    try std.testing.expect(ran);
    try std.testing.expectEqual(@as(usize, 1), freed);
}

test "submitted-but-undrained context is released on shutdown" {
    if (!io_dispatch_supported) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var loop = try EventLoop.init(allocator, std.testing.io);

    var ran = false;
    var freed: usize = 0;
    const ctx = try allocator.create(TaskTestCtx);
    ctx.* = .{ .ran = &ran, .freed = &freed };

    // Never ticked: the task stays in the inbox and deinit must drain and free
    // its owned context exactly once.
    try loop.submit(TaskTestCtx.run, ctx, TaskTestCtx.cleanup);
    loop.deinit();

    try std.testing.expect(!ran);
    try std.testing.expectEqual(@as(usize, 1), freed);
}

// ============================================================================
// Tests — platform backend honesty (poller_support contract)
// ============================================================================

test "poller_support honestly reflects the selected backend" {
    // Nothing may over-claim support. Linux/epoll is the only exercised backend;
    // kqueue is present-but-unverified; the IOCP placeholder must fail closed
    // rather than hand back a poller that silently drops all I/O readiness.
    switch (builtin.os.tag) {
        .linux => {
            try std.testing.expectEqual(PollerSupport.supported, poller_support);
            try std.testing.expect(IoPoller == EpollPoller);
        },
        .macos, .freebsd, .netbsd, .openbsd => {
            try std.testing.expectEqual(PollerSupport.unverified, poller_support);
            try std.testing.expect(IoPoller == KqueuePoller);
        },
        .windows => {
            try std.testing.expectEqual(PollerSupport.unsupported, poller_support);
            try std.testing.expectError(
                error.PlatformNotSupported,
                IoPoller.init(std.testing.allocator),
            );
        },
        else => try std.testing.expectEqual(PollerSupport.unsupported, poller_support),
    }
}

// ============================================================================
// Tests — execution-model boundary (scheduler offload → loop hand-back)
// ============================================================================

const scheduler_mod = @import("scheduler.zig");

// Proves the decided execution model end to end: the work-stealing scheduler is
// a subordinate compute pool, and the ONLY way its workers touch the reactor is
// `EventLoop.submit`. Worker threads run `compute` (off the loop thread) and
// hand their result back via `loop.submit`; the loop thread runs `deliver`,
// which is the only code that mutates loop-visible state. The shared context is
// borrowed by both sides (cleanup=null; owned by this test frame), matching the
// scheduler's borrowed-context contract.
const SchedBridge = struct {
    loop: *EventLoop,
    // Mutated only inside `deliver`, which runs on the loop thread; plain usize
    // is safe because there is no concurrent writer.
    collected: usize = 0,
    target: usize,

    // Scheduler worker thread: stands in for CPU-bound offloaded work, then
    // re-enters the reactor through the sanctioned seam. It must not touch
    // `collected` itself.
    fn compute(context: ?*anyopaque) void {
        const self: *SchedBridge = @ptrCast(@alignCast(context.?));
        self.loop.submit(deliver, self, null) catch {};
    }

    // Loop thread: safe to mutate loop-visible state here. Stop once every
    // offloaded result has been handed back.
    fn deliver(task: *Task) !void {
        const self: *SchedBridge = @ptrCast(@alignCast(task.context.?));
        self.collected += 1;
        if (self.collected == self.target) self.loop.requestStop();
    }
};

test "scheduler offload hands results back to the loop only via submit, both shut down clean" {
    if (!io_dispatch_supported) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var loop = try EventLoop.init(allocator, std.testing.io);
    defer loop.deinit();

    const sched = try scheduler_mod.Scheduler.init(allocator, 4);
    defer sched.deinit();
    try sched.start();

    const target: usize = 200;
    var bridge = SchedBridge{ .loop = &loop, .target = target };

    // Inject CPU work onto the pool. Each worker hands its result back through
    // `loop.submit`; retry on a transiently full global queue.
    var submitted: usize = 0;
    while (submitted < target) : (submitted += 1) {
        while (true) {
            sched.submit(SchedBridge.compute, &bridge) catch |err| switch (err) {
                error.QueueFull => {
                    std.atomic.spinLoopHint();
                    continue;
                },
                else => return err,
            };
            break;
        }
    }

    // Park the loop until all offloaded results have been delivered on the loop
    // thread. Each of `target` compute() calls submits exactly one deliver(), so
    // reaching `collected == target` proves every worker completed its hand-back
    // before the Nth delivery requested stop — the pool is idle and joins clean.
    try loop.runUntilStop();

    try std.testing.expectEqual(target, bridge.collected);
}
