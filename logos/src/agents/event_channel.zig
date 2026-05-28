const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const jsonrpc = @import("jsonrpc.zig");

/// What a reader thread produces for the dispatcher to consume.
pub const WorkerEvent = union(enum) {
    /// JSON-RPC message decoded from worker stdout (response or notification).
    message: jsonrpc.Message,
    /// Worker pipe closed (EOF) or process exited unexpectedly.
    dead: void,
    /// Stdout produced a malformed line; payload is the offending line so the
    /// dispatcher can log it. Does NOT terminate the worker (per spec: log+continue).
    parse_error: []const u8,
};

pub const EventEnvelope = struct {
    worker_id: u64,
    event: WorkerEvent,
};

/// Single-consumer, multi-producer queue. Reader threads push; the dispatcher
/// pops. Internally an ArrayList behind a mutex; condition variable so the
/// dispatcher can block-with-timeout when idle.
///
/// NOTE: In Zig 0.16 std.Io.Mutex and std.Io.Condition require an `Io`
/// context (the async-aware I/O scheduler). The channel stores `io` and
/// uses uncancelable variants throughout so it can be called from plain
/// kernel threads without a scheduler.
pub const EventChannel = struct {
    gpa: Allocator,
    io: Io,
    mu: Io.Mutex = .init,
    cv: Io.Condition = .init,
    items: std.ArrayList(EventEnvelope) = .empty,
    closed: bool = false,

    pub fn init(gpa: Allocator, io: Io) EventChannel {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(self: *EventChannel) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        // Free any messages still sitting in the queue.
        for (self.items.items) |*env| freeEvent(self.gpa, &env.event);
        self.items.deinit(self.gpa);
    }

    pub fn send(self: *EventChannel, env: EventEnvelope) !void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        if (self.closed) {
            // Drop and free the event rather than producing a half-state.
            var e = env.event;
            freeEvent(self.gpa, &e);
            return;
        }
        try self.items.append(self.gpa, env);
        self.cv.signal(self.io);
    }

    /// Non-blocking pop. Returns null if queue is empty.
    pub fn tryRecv(self: *EventChannel) ?EventEnvelope {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        if (self.items.items.len == 0) return null;
        return self.items.orderedRemove(0);
    }

    /// Block up to `timeout_ms` milliseconds; return null on timeout.
    ///
    /// Adaptation note: Zig 0.16 has no std.Thread.Condition.timedWait.
    /// We wait on the condition variable uncancelably, then check if items
    /// arrived. A timed wakeup is achieved by waiting on the condition's
    /// epoch field via futexWaitTimeout with a duration timeout.
    pub fn recvTimeout(self: *EventChannel, timeout_ms: u64) ?EventEnvelope {
        self.mu.lockUncancelable(self.io);
        if (self.items.items.len > 0) {
            defer self.mu.unlock(self.io);
            return self.items.orderedRemove(0);
        }

        // Capture epoch before unlocking so we don't miss a signal.
        const epoch_before = self.cv.epoch.load(.acquire);

        self.mu.unlock(self.io);

        // Wait on the condition epoch with a deadline timeout.
        // Io.Timeout.duration expects an Io.Clock.Duration (wraps Io.Duration + clock).
        const raw_duration = Io.Duration.fromMilliseconds(@intCast(timeout_ms));
        const clock_duration = Io.Clock.Duration{ .raw = raw_duration, .clock = .awake };
        const timeout = Io.Timeout{ .duration = clock_duration };
        // futexWaitTimeout returns error.Canceled on timeout/cancel; ignore.
        Io.futexWaitTimeout(self.io, u32, &self.cv.epoch.raw, epoch_before, timeout) catch {};

        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        if (self.items.items.len == 0) return null;
        return self.items.orderedRemove(0);
    }

    /// Mark the channel closed; future sends drop events. Used during shutdown.
    pub fn close(self: *EventChannel) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        self.closed = true;
        self.cv.broadcast(self.io);
    }
};

/// Free a WorkerEvent's owned memory.
pub fn freeEvent(gpa: Allocator, ev: *WorkerEvent) void {
    switch (ev.*) {
        .message => |*m| m.deinit(gpa),
        .parse_error => |line| gpa.free(line),
        .dead => {},
    }
}

test "send + tryRecv FIFO order" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var ch = EventChannel.init(gpa, io);
    defer ch.deinit();

    try ch.send(.{ .worker_id = 1, .event = .dead });
    try ch.send(.{ .worker_id = 2, .event = .dead });

    const a = ch.tryRecv() orelse return error.NoEvent;
    const b = ch.tryRecv() orelse return error.NoEvent;
    try std.testing.expectEqual(@as(u64, 1), a.worker_id);
    try std.testing.expectEqual(@as(u64, 2), b.worker_id);
    try std.testing.expect(ch.tryRecv() == null);
}

test "recvTimeout returns null when empty" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var ch = EventChannel.init(gpa, io);
    defer ch.deinit();

    const before = Io.Timestamp.now(io, .awake);
    const got = ch.recvTimeout(10);
    const after = Io.Timestamp.now(io, .awake);
    const elapsed_ms = before.durationTo(after).toMilliseconds();
    try std.testing.expect(got == null);
    try std.testing.expect(elapsed_ms >= 8); // slack for scheduler
}

test "close drops events sent afterwards" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var ch = EventChannel.init(gpa, io);
    defer ch.deinit();

    ch.close();
    try ch.send(.{ .worker_id = 99, .event = .dead });
    try std.testing.expect(ch.tryRecv() == null);
}
