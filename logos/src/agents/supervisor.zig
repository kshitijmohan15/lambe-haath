const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ArrayList = std.ArrayList;

const config = @import("config.zig");
const event_channel = @import("event_channel.zig");
const worker_mod = @import("worker.zig");

const Worker = worker_mod.Worker;
const AgentConfig = config.AgentConfig;
const AgentSpec = config.AgentSpec;
const EventChannel = event_channel.EventChannel;

pub const Supervisor = struct {
    gpa: Allocator,
    io: Io,
    cfg: *const AgentConfig,
    channel: *EventChannel,
    mu: Io.Mutex = .init,
    workers: ArrayList(*Worker) = .empty,
    next_id: u64 = 1,

    pub fn init(io: Io, gpa: Allocator, cfg: *const AgentConfig, channel: *EventChannel) Supervisor {
        return .{
            .gpa = gpa,
            .io = io,
            .cfg = cfg,
            .channel = channel,
        };
    }

    pub fn deinit(self: *Supervisor) void {
        // Free any remaining workers without attempting shutdown.
        for (self.workers.items) |w| {
            self.gpa.destroy(w);
        }
        self.workers.deinit(self.gpa);
    }

    /// Return an idle worker of `kind`, or spawn a fresh one if cap not reached,
    /// or null if cap reached and all busy. Returned worker is marked .busy.
    pub fn acquire(self: *Supervisor, kind: []const u8) !?*Worker {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);

        // First: look for an existing idle worker of matching kind.
        for (self.workers.items) |w| {
            if (std.mem.eql(u8, w.kind, kind) and w.state == .idle) {
                w.state = .busy;
                return w;
            }
        }

        // Count alive (non-.dead) workers of this kind.
        const spec = self.cfg.find(kind) orelse return error.UnknownAgentKind;
        var alive_count: u32 = 0;
        for (self.workers.items) |w| {
            if (std.mem.eql(u8, w.kind, kind) and w.state != .dead) {
                alive_count += 1;
            }
        }

        // Cap reached — all are alive and busy.
        if (alive_count >= spec.max_workers) return null;

        // Spawn a new worker.
        const id = self.next_id;
        self.next_id += 1;

        const w_ptr = try self.gpa.create(Worker);
        errdefer self.gpa.destroy(w_ptr);

        w_ptr.* = try worker_mod.spawn(self.io, self.gpa, id, spec, self.channel);
        w_ptr.state = .busy;

        try self.workers.append(self.gpa, w_ptr);

        return w_ptr;
    }

    /// Mark worker idle (after dispatcher received a response).
    pub fn release(self: *Supervisor, w: *Worker) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        if (w.state == .busy) {
            w.state = .idle;
            w.current_job_id = null;
        }
    }

    /// Worker is dead (reader posted .dead). Reap it: join reader thread,
    /// wait for child, free pointer.
    pub fn markDead(self: *Supervisor, worker_id: u64) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);

        for (self.workers.items, 0..) |w, i| {
            if (w.id == worker_id) {
                // Join reader thread if still running.
                if (w.reader_thread) |t| {
                    t.join();
                    w.reader_thread = null;
                }
                // Wait for child process.
                _ = w.child.wait(self.io) catch {};
                w.state = .dead;

                // Free any in-flight job_id before destroying the worker.
                if (w.current_job_id) |jid| self.gpa.free(jid);

                // Remove from list and free.
                _ = self.workers.orderedRemove(i);
                self.gpa.destroy(w);
                return;
            }
        }
    }

    pub fn findById(self: *Supervisor, worker_id: u64) ?*Worker {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        for (self.workers.items) |w| {
            if (w.id == worker_id) return w;
        }
        return null;
    }

    /// Find a worker whose `current_job_id` matches `job_id` (linear search).
    pub fn findByJob(self: *Supervisor, job_id: []const u8) ?*Worker {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        for (self.workers.items) |w| {
            if (w.current_job_id) |jid| {
                if (std.mem.eql(u8, jid, job_id)) return w;
            }
        }
        return null;
    }

    /// Gracefully close all workers (notifications/exit + stdin close + wait).
    /// Frees all worker pointers and empties the list.
    pub fn shutdownAll(self: *Supervisor) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);

        for (self.workers.items) |w| {
            w.close(self.gpa);
            if (w.current_job_id) |jid| self.gpa.free(jid);
            self.gpa.destroy(w);
        }
        self.workers.clearRetainingCapacity();
    }
};

// --- Tests ---

fn mockAgentPathOrSkip() ?[]const u8 {
    const result = std.c.getenv("LAMBE_MOCK_AGENT_PATH") orelse return null;
    return std.mem.span(result);
}

fn buildSpec(gpa: Allocator, path: []const u8, max_workers: u32) !AgentSpec {
    var args = try gpa.alloc([]const u8, 1);
    args[0] = try gpa.dupe(u8, path);
    return .{
        .kind = try gpa.dupe(u8, "mock"),
        .command = try gpa.dupe(u8, "python3"),
        .args = args,
        .max_workers = max_workers,
        .model = try gpa.dupe(u8, "mock-model"),
    };
}

fn buildConfig(gpa: Allocator, spec: AgentSpec) !AgentConfig {
    const agents = try gpa.alloc(AgentSpec, 1);
    agents[0] = spec;
    return .{ .agents = agents };
}

test "acquire spawns first worker on demand" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    const path = mockAgentPathOrSkip() orelse return error.SkipZigTest;

    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const spec = try buildSpec(gpa, path, 2);
    var cfg = try buildConfig(gpa, spec);
    defer cfg.deinit(gpa);
    // spec is now owned by cfg — do not call spec.deinit separately.

    var ch = EventChannel.init(gpa, io);
    defer ch.deinit();

    var sv = Supervisor.init(io, gpa, &cfg, &ch);
    defer sv.deinit();

    // First acquire spawns a new worker.
    const w1 = (try sv.acquire("mock")) orelse return error.NoWorker;
    try std.testing.expectEqual(worker_mod.State.busy, w1.state);

    const first_id = w1.id;

    // Release it → idle.
    sv.release(w1);
    try std.testing.expectEqual(worker_mod.State.idle, w1.state);

    // Second acquire should return the SAME (warm) worker.
    const w2 = (try sv.acquire("mock")) orelse return error.NoWorker;
    try std.testing.expectEqual(first_id, w2.id);
    try std.testing.expectEqual(worker_mod.State.busy, w2.state);

    sv.shutdownAll();
}

test "acquire returns null when cap reached and all busy" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    const path = mockAgentPathOrSkip() orelse return error.SkipZigTest;

    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const spec = try buildSpec(gpa, path, 1);
    var cfg = try buildConfig(gpa, spec);
    defer cfg.deinit(gpa);

    var ch = EventChannel.init(gpa, io);
    defer ch.deinit();

    var sv = Supervisor.init(io, gpa, &cfg, &ch);
    defer sv.deinit();

    // First acquire: spawns a worker (now busy).
    const w1 = (try sv.acquire("mock")) orelse return error.NoWorker;
    const first_id = w1.id;

    // Second acquire: cap=1, worker busy → should return null.
    const w2 = try sv.acquire("mock");
    try std.testing.expect(w2 == null);

    // Release the first worker → idle.
    sv.release(w1);

    // Third acquire: should return the same worker (warm).
    const w3 = (try sv.acquire("mock")) orelse return error.NoWorker;
    try std.testing.expectEqual(first_id, w3.id);

    sv.shutdownAll();
}

test "shutdownAll terminates all workers" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    const path = mockAgentPathOrSkip() orelse return error.SkipZigTest;

    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const spec = try buildSpec(gpa, path, 3);
    var cfg = try buildConfig(gpa, spec);
    defer cfg.deinit(gpa);

    var ch = EventChannel.init(gpa, io);
    defer ch.deinit();

    var sv = Supervisor.init(io, gpa, &cfg, &ch);
    defer sv.deinit();

    // Acquire two workers (leaves one slot unused).
    _ = (try sv.acquire("mock")) orelse return error.NoWorker;
    _ = (try sv.acquire("mock")) orelse return error.NoWorker;
    try std.testing.expectEqual(@as(usize, 2), sv.workers.items.len);

    sv.shutdownAll();

    try std.testing.expectEqual(@as(usize, 0), sv.workers.items.len);
}
