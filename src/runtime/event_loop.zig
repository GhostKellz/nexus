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

/// Timer callback function
pub const TimerCallback = *const fn (timer: *Timer) void;

/// Timer structure
pub const Timer = struct {
    id: u64,
    deadline: i64, // Unix timestamp in milliseconds
    callback: TimerCallback,
    repeat: ?u64 = null, // Repeat interval in ms (null for one-shot)
    data: ?*anyopaque = null,
    cancelled: bool = false,
};

/// Task callback function
pub const TaskCallback = *const fn (task: *Task) anyerror!void;

/// Async task
pub const Task = struct {
    callback: TaskCallback,
    context: ?*anyopaque = null,
};

/// Min-heap for timers
pub const TimerHeap = struct {
    timers: std.PriorityQueue(Timer, void, compareTimers),
    next_id: u64 = 1,
    allocator: std.mem.Allocator,
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) TimerHeap {
        return TimerHeap{
            .timers = std.PriorityQueue(Timer, void, compareTimers).init(allocator, {}),
            .allocator = allocator,
            .io = io,
        };
    }

    pub fn deinit(self: *TimerHeap) void {
        self.timers.deinit();
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

    pub fn setTimeout(self: *TimerHeap, delay_ms: u64, callback: TimerCallback) !u64 {
        const now_ms = self.getCurrentTimeMs();
        const timer = Timer{
            .id = self.next_id,
            .deadline = now_ms + @as(i64, @intCast(delay_ms)),
            .callback = callback,
            .repeat = null,
        };
        try self.timers.add(timer);
        self.next_id += 1;
        return timer.id;
    }

    pub fn setInterval(self: *TimerHeap, interval_ms: u64, callback: TimerCallback) !u64 {
        const now_ms = self.getCurrentTimeMs();
        const timer = Timer{
            .id = self.next_id,
            .deadline = now_ms + @as(i64, @intCast(interval_ms)),
            .callback = callback,
            .repeat = interval_ms,
        };
        try self.timers.add(timer);
        self.next_id += 1;
        return timer.id;
    }

    pub fn clearTimer(self: *TimerHeap, id: u64) void {
        // Mark timer as cancelled - will be skipped during processing
        for (self.timers.items) |*timer| {
            if (timer.id == id) {
                timer.cancelled = true;
                return;
            }
        }
    }

    pub fn processExpired(self: *TimerHeap) !void {
        const now = self.getCurrentTimeMs();

        while (self.timers.peek()) |timer| {
            if (timer.deadline > now) break;

            var expired = self.timers.remove();

            // Skip cancelled timers
            if (expired.cancelled) continue;

            // Execute callback
            expired.callback(&expired);

            // Re-add if repeating
            if (expired.repeat) |interval| {
                expired.deadline = now + @as(i64, @intCast(interval));
                try self.timers.add(expired);
            }
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
            .queue = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TaskQueue) void {
        self.queue.deinit(self.allocator);
    }

    pub fn enqueue(self: *TaskQueue, callback: TaskCallback) !void {
        try self.queue.append(self.allocator, Task{ .callback = callback });
    }

    pub fn enqueueWithContext(self: *TaskQueue, callback: TaskCallback, context: ?*anyopaque) !void {
        try self.queue.append(self.allocator, Task{ .callback = callback, .context = context });
    }

    pub fn process(self: *TaskQueue) !void {
        // Process all tasks, then clear
        for (self.queue.items) |*task| {
            try task.callback(task);
        }
        self.queue.clearRetainingCapacity();
    }

    pub fn isEmpty(self: *TaskQueue) bool {
        return self.queue.items.len == 0;
    }
};

/// Immediate queue (setImmediate)
pub const ImmediateQueue = TaskQueue;

/// Platform-specific I/O poller
pub const IoPoller = switch (builtin.os.tag) {
    .linux => EpollPoller,
    .macos, .freebsd, .netbsd, .openbsd => KqueuePoller,
    .windows => IocpPoller,
    else => @compileError("Unsupported platform for I/O polling"),
};

/// Linux epoll implementation
const EpollPoller = struct {
    epoll_fd: std.posix.fd_t,
    events: []std.os.linux.epoll_event,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !EpollPoller {
        const rc = std.os.linux.epoll_create1(std.os.linux.EPOLL.CLOEXEC);
        const err = std.os.linux.errno(rc);
        if (err != .SUCCESS) return error.EpollCreateFailed;
        const epoll_fd: std.posix.fd_t = @intCast(rc);
        const events = try allocator.alloc(std.os.linux.epoll_event, 1024);

        return EpollPoller{
            .epoll_fd = epoll_fd,
            .events = events,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *EpollPoller) void {
        std.posix.close(self.epoll_fd);
        self.allocator.free(self.events);
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

        // Convert epoll events to IoEvents
        var io_events = try self.allocator.alloc(IoEvent, count);
        for (self.events[0..count], 0..) |event, i| {
            io_events[i] = IoEvent{
                .fd = event.data.fd,
                .events = event.events,
            };
        }

        return io_events;
    }
};

/// macOS/BSD kqueue implementation
const KqueuePoller = struct {
    kqueue_fd: std.posix.fd_t,
    events: []std.posix.Kevent,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !KqueuePoller {
        const kqueue_fd = try std.posix.kqueue();
        const events = try allocator.alloc(std.posix.Kevent, 1024);

        return KqueuePoller{
            .kqueue_fd = kqueue_fd,
            .events = events,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *KqueuePoller) void {
        std.posix.close(self.kqueue_fd);
        self.allocator.free(self.events);
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

        var io_events = try self.allocator.alloc(IoEvent, count);
        for (self.events[0..count], 0..) |event, i| {
            var events_flags: u32 = 0;
            if (event.filter == std.posix.system.EVFILT_READ) events_flags |= IoEvent.READ;
            if (event.filter == std.posix.system.EVFILT_WRITE) events_flags |= IoEvent.WRITE;

            io_events[i] = IoEvent{
                .fd = @intCast(event.ident),
                .events = events_flags,
            };
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
        // Create I/O completion port with no initial file handle
        const iocp_handle = windows.kernel32.CreateIoCompletionPort(
            windows.INVALID_HANDLE_VALUE,
            null,
            0,
            0, // Use default number of concurrent threads
        );

        if (iocp_handle == null or iocp_handle == windows.INVALID_HANDLE_VALUE) {
            return error.IocpCreateFailed;
        }

        const completion_entries = try allocator.alloc(windows.OVERLAPPED_ENTRY, 1024);

        return IocpPoller{
            .iocp_handle = iocp_handle.?,
            .allocator = allocator,
            .registered_handles = std.AutoHashMap(windows.HANDLE, RegisteredHandle).init(allocator),
            .completion_entries = completion_entries,
        };
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

/// Main event loop
pub const EventLoop = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    io_poller: IoPoller,
    timer_heap: TimerHeap,
    task_queue: TaskQueue,
    immediate_queue: ImmediateQueue,
    is_running: bool = false,

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
        self.io_poller.deinit();
        self.timer_heap.deinit();
        self.task_queue.deinit();
        self.immediate_queue.deinit();
    }

    /// Run the event loop
    pub fn run(self: *EventLoop) !void {
        self.is_running = true;

        while (self.is_running) {
            // 1. Process immediate queue (setImmediate)
            try self.immediate_queue.process();

            // 2. Process expired timers
            try self.timer_heap.processExpired();

            // 3. Calculate timeout for I/O poll
            const timeout = self.calculateTimeout();

            // 4. Poll I/O events
            const timeout_ms: i32 = if (timeout) |t| @intCast(t) else -1;
            const events = try self.io_poller.poll(timeout_ms);
            defer self.allocator.free(events);

            // 5. Process I/O events
            try self.processIoEvents(events);

            // 6. Process task queue
            try self.task_queue.process();

            // 7. Check if should exit
            if (self.shouldExit()) break;
        }
    }

    pub fn stop(self: *EventLoop) void {
        self.is_running = false;
    }

    fn calculateTimeout(self: *EventLoop) ?u64 {
        // If immediate queue has tasks, don't block
        if (!self.immediate_queue.isEmpty()) return 0;

        // If task queue has tasks, don't block
        if (!self.task_queue.isEmpty()) return 0;

        // Otherwise, wait until next timer
        return self.timer_heap.nextTimeout();
    }

    fn processIoEvents(_: *EventLoop, events: []IoEvent) !void {
        for (events) |event| {
            // Handle I/O event
            // For now, just acknowledge the event
            _ = event;
            // In a real implementation, we'd call registered handlers
        }
    }

    fn shouldExit(self: *EventLoop) bool {
        // Exit if:
        // - Not running
        // - No timers, no tasks, no immediates
        if (!self.is_running) return true;

        const has_timers = self.timer_heap.timers.peek() != null;
        const has_tasks = !self.task_queue.isEmpty();
        const has_immediates = !self.immediate_queue.isEmpty();

        return !has_timers and !has_tasks and !has_immediates;
    }

    /// setTimeout - execute callback after delay
    pub fn setTimeout(self: *EventLoop, delay_ms: u64, callback: TimerCallback) !u64 {
        return self.timer_heap.setTimeout(delay_ms, callback);
    }

    /// setInterval - execute callback repeatedly
    pub fn setInterval(self: *EventLoop, interval_ms: u64, callback: TimerCallback) !u64 {
        return self.timer_heap.setInterval(interval_ms, callback);
    }

    /// clearTimeout/clearInterval
    pub fn clearTimer(self: *EventLoop, id: u64) void {
        self.timer_heap.clearTimer(id);
    }

    /// setImmediate - execute callback on next tick
    pub fn setImmediate(self: *EventLoop, callback: TaskCallback) !void {
        try self.immediate_queue.enqueue(callback);
    }

    /// Register file descriptor for I/O events
    pub fn registerFd(self: *EventLoop, fd: std.posix.fd_t, events: u32) !void {
        try self.io_poller.register(fd, events);
    }

    /// Unregister file descriptor
    pub fn unregisterFd(self: *EventLoop, fd: std.posix.fd_t) !void {
        try self.io_poller.unregister(fd);
    }
};

/// Global event loop instance
var global_event_loop: ?*EventLoop = null;

pub fn getEventLoop() *EventLoop {
    return global_event_loop orelse @panic("Event loop not initialized");
}

pub fn setEventLoop(loop: *EventLoop) void {
    global_event_loop = loop;
}
