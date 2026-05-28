const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const config_mod = @import("config.zig");
const event_channel_mod = @import("event_channel.zig");
const supervisor_mod = @import("supervisor.zig");
const jsonrpc = @import("jsonrpc.zig");

const db_mod = @import("../db/db.zig");
const jobs_mod = @import("../db/jobs.zig");
const job_logs_mod = @import("../db/job_logs.zig");

const Db = db_mod.Db;
const EventChannel = event_channel_mod.EventChannel;
const Supervisor = supervisor_mod.Supervisor;
const JobType = jobs_mod.JobType;

/// Cancellation-code that a worker sends back when it aborts a job.
const CANCEL_CODE: i64 = -32099;

/// Maximum length of an error message stored in the DB.
const MAX_ERR_LEN: usize = 200;

pub const Dispatcher = struct {
    gpa: Allocator,
    io: Io,
    db: *Db,
    db_mu: *Io.Mutex,
    sup: *Supervisor,
    channel: *EventChannel,
    stop: std.atomic.Value(bool),
    retry_attempts: std.StringHashMap(u8),
    cancel_requests: std.StringHashMap(void),

    pub fn init(
        io: Io,
        gpa: Allocator,
        db: *Db,
        db_mu: *Io.Mutex,
        sup: *Supervisor,
        channel: *EventChannel,
    ) Dispatcher {
        return .{
            .gpa = gpa,
            .io = io,
            .db = db,
            .db_mu = db_mu,
            .sup = sup,
            .channel = channel,
            .stop = std.atomic.Value(bool).init(false),
            .retry_attempts = std.StringHashMap(u8).init(gpa),
            .cancel_requests = std.StringHashMap(void).init(gpa),
        };
    }

    pub fn deinit(self: *Dispatcher) void {
        // Free all keys owned by the hash maps.
        var it1 = self.retry_attempts.keyIterator();
        while (it1.next()) |k| self.gpa.free(k.*);
        self.retry_attempts.deinit();

        var it2 = self.cancel_requests.keyIterator();
        while (it2.next()) |k| self.gpa.free(k.*);
        self.cancel_requests.deinit();
    }

    /// Signal the loop to exit on its next iteration.
    pub fn requestStop(self: *Dispatcher) void {
        self.stop.store(true, .release);
        self.channel.close();
    }

    /// Called by HTTP handlers to request cancellation of a running job.
    /// The main loop will flush pending cancels on the next tick.
    pub fn cancelJob(self: *Dispatcher, job_id: []const u8) !void {
        // Avoid duplicate entries.
        if (self.cancel_requests.contains(job_id)) return;
        const owned = try self.gpa.dupe(u8, job_id);
        errdefer self.gpa.free(owned);
        try self.cancel_requests.put(owned, {});
    }

    // -----------------------------------------------------------------------
    // Main loop
    // -----------------------------------------------------------------------

    pub fn run(self: *Dispatcher) void {
        while (!self.stop.load(.acquire)) {
            // 1. Drain all pending events from the channel.
            self.drainEvents();

            // 2. Process pending cancellations.
            self.flushPendingCancels();

            // 3. Dispatch new jobs for each kind we support.
            self.maybeDispatch("ocr") catch {};
            self.maybeDispatch("prompt") catch {};

            // 4. Sleep / wait for next event (50ms timeout).
            _ = self.channel.recvTimeout(50);
        }
    }

    // -----------------------------------------------------------------------
    // Event draining
    // -----------------------------------------------------------------------

    fn drainEvents(self: *Dispatcher) void {
        while (self.channel.tryRecv()) |env| {
            self.handleEnvelope(env);
        }
    }

    fn handleEnvelope(self: *Dispatcher, env: event_channel_mod.EventEnvelope) void {
        switch (env.event) {
            .message => |msg| {
                var m = msg;
                self.handleMessage(env.worker_id, &m);
            },
            .dead => {
                self.handleWorkerDead(env.worker_id);
            },
            .parse_error => |line| {
                // Log and discard — the worker stays alive per spec.
                self.gpa.free(line);
            },
        }
    }

    fn handleMessage(self: *Dispatcher, worker_id: u64, msg: *jsonrpc.Message) void {
        defer msg.deinit(self.gpa);

        switch (msg.*) {
            .response => |*resp| self.handleResponse(worker_id, resp),
            .notification => |*notif| self.handleNotification(worker_id, notif),
            .request => {}, // servers don't send requests to us — ignore
        }
    }

    // -----------------------------------------------------------------------
    // Response handling
    // -----------------------------------------------------------------------

    fn handleResponse(self: *Dispatcher, worker_id: u64, resp: *jsonrpc.Response) void {
        // Find the worker so we can get the job_id and release it.
        const worker = self.sup.findById(worker_id) orelse return;
        const job_id = worker.current_job_id orelse return;

        const now = db_mod.nowIso8601(self.gpa) catch return;
        defer self.gpa.free(now);

        self.db_mu.lockUncancelable(self.io);
        switch (resp.body) {
            .result => |result_json| {
                jobs_mod.markCompletedAt(self.db, job_id, result_json, now) catch {};
            },
            .err => |*err_obj| {
                if (err_obj.code == CANCEL_CODE) {
                    jobs_mod.markCanceled(self.db, job_id, "user_requested", now) catch {};
                } else {
                    const truncated = truncateStr(err_obj.message, MAX_ERR_LEN);
                    jobs_mod.markFailedAt(self.db, job_id, truncated, now) catch {};
                }
            },
        }
        self.db_mu.unlock(self.io);

        // Remove from retry tracking.
        if (self.retry_attempts.getKey(job_id)) |k| {
            _ = self.retry_attempts.remove(k);
            self.gpa.free(k);
        }

        // Free current_job_id before releasing the worker (release clears it).
        const job_id_copy = worker.current_job_id;
        self.sup.release(worker);
        if (job_id_copy) |jid| self.gpa.free(jid);
    }

    // -----------------------------------------------------------------------
    // Notification handling
    // -----------------------------------------------------------------------

    fn handleNotification(self: *Dispatcher, worker_id: u64, notif: *jsonrpc.Notification) void {
        const worker = self.sup.findById(worker_id) orelse return;
        const job_id = worker.current_job_id orelse return;

        const now = db_mod.nowIso8601(self.gpa) catch return;
        defer self.gpa.free(now);

        if (std.mem.eql(u8, notif.method, "notifications/progress")) {
            const params = notif.params_json orelse return;
            const progress = extractFloatField(params, "progress") orelse return;

            self.db_mu.lockUncancelable(self.io);
            jobs_mod.updateProgressAt(self.db, job_id, progress, now) catch {};
            self.db_mu.unlock(self.io);
        } else if (std.mem.eql(u8, notif.method, "notifications/log")) {
            const params = notif.params_json orelse return;
            self.handleLogNotification(job_id, now, params);
        }
        // All other notifications are silently ignored.
    }

    fn handleLogNotification(
        self: *Dispatcher,
        job_id: []const u8,
        now: []const u8,
        params: []const u8,
    ) void {
        const parsed = std.json.parseFromSlice(std.json.Value, self.gpa, params, .{}) catch return;
        defer parsed.deinit();

        const obj = if (parsed.value == .object) parsed.value.object else return;

        const level_str = if (obj.get("level")) |v| switch (v) {
            .string => |s| s,
            else => "info",
        } else "info";

        const logger_str = if (obj.get("logger")) |v| switch (v) {
            .string => |s| s,
            else => "",
        } else "";

        const msg_str = if (obj.get("message")) |v| switch (v) {
            .string => |s| s,
            else => "",
        } else "";

        const level = job_logs_mod.Level.fromText(level_str) orelse .info;

        self.db_mu.lockUncancelable(self.io);
        job_logs_mod.insert(self.db, job_id, now, level, logger_str, msg_str) catch {};
        self.db_mu.unlock(self.io);
    }

    // -----------------------------------------------------------------------
    // Dead worker / crash-retry
    // -----------------------------------------------------------------------

    fn handleWorkerDead(self: *Dispatcher, worker_id: u64) void {
        // Cache job_id before markDead frees the worker.
        const job_id_opt: ?[]const u8 = blk: {
            const w = self.sup.findById(worker_id) orelse break :blk null;
            // Dupe so we still own it after markDead.
            const jid = w.current_job_id orelse break :blk null;
            break :blk self.gpa.dupe(u8, jid) catch null;
        };

        self.sup.markDead(worker_id);

        const job_id = job_id_opt orelse return;
        defer self.gpa.free(job_id);

        const now = db_mod.nowIso8601(self.gpa) catch return;
        defer self.gpa.free(now);

        const attempts = self.retry_attempts.get(job_id) orelse 0;

        self.db_mu.lockUncancelable(self.io);
        if (attempts == 0) {
            jobs_mod.markReQueued(self.db, job_id, now) catch {};
        } else {
            jobs_mod.markFailedAt(self.db, job_id, "worker_died: 2 attempts", now) catch {};
        }
        self.db_mu.unlock(self.io);

        if (attempts == 0) {
            // Record that we've retried once.
            const owned_key = self.gpa.dupe(u8, job_id) catch return;
            // Remove stale entry (if any) before putting the new one.
            if (self.retry_attempts.getKey(job_id)) |old_k| {
                _ = self.retry_attempts.remove(old_k);
                self.gpa.free(old_k);
            }
            self.retry_attempts.put(owned_key, 1) catch {
                self.gpa.free(owned_key);
            };
        } else {
            // Second failure — clean up retry tracking.
            if (self.retry_attempts.getKey(job_id)) |old_k| {
                _ = self.retry_attempts.remove(old_k);
                self.gpa.free(old_k);
            }
        }
    }

    // -----------------------------------------------------------------------
    // Cancellation flush
    // -----------------------------------------------------------------------

    fn flushPendingCancels(self: *Dispatcher) void {
        var it = self.cancel_requests.iterator();
        while (it.next()) |entry| {
            const job_id = entry.key_ptr.*;
            const worker = self.sup.findByJob(job_id) orelse continue;
            worker.sendNotification(
                self.gpa,
                "notifications/cancelled",
                "{\"requestId\":0,\"reason\":\"user_requested\"}",
            ) catch {};
            // Worker will reply with error code -32099; the response handler
            // marks the job canceled.
        }

        // Clear all cancel requests, freeing their keys.
        var kit = self.cancel_requests.keyIterator();
        var keys_to_free = std.ArrayList([]const u8).init(self.gpa);
        defer keys_to_free.deinit();
        while (kit.next()) |k| {
            keys_to_free.append(k.*) catch {};
        }
        self.cancel_requests.clearRetainingCapacity();
        for (keys_to_free.items) |k| self.gpa.free(k);
    }

    // -----------------------------------------------------------------------
    // Job dispatch
    // -----------------------------------------------------------------------

    fn maybeDispatch(self: *Dispatcher, kind: []const u8) !void {
        const job_type = JobType.fromText(kind) catch return;

        // Query for the next dispatchable job of this type.
        self.db_mu.lockUncancelable(self.io);
        const maybe_job = jobs_mod.nextDispatchable(self.db, self.gpa, job_type) catch {
            self.db_mu.unlock(self.io);
            return;
        };
        self.db_mu.unlock(self.io);

        var job = maybe_job orelse return;
        defer job.deinit(self.gpa);

        // Try to acquire a worker.
        const worker = (try self.sup.acquire(kind)) orelse return;

        // Build params JSON.
        const params = try std.fmt.allocPrint(
            self.gpa,
            "{{\"job_id\":\"{s}\",\"payload\":{s},\"_meta\":{{\"progressToken\":\"{s}\"}}}}",
            .{ job.id, job.payload, job.id },
        );
        defer self.gpa.free(params);

        // Assign job to worker (owned copy).
        const job_id_owned = try self.gpa.dupe(u8, job.id);
        worker.current_job_id = job_id_owned;

        // Mark the job running in the DB.
        const now = try db_mod.nowIso8601(self.gpa);
        defer self.gpa.free(now);

        self.db_mu.lockUncancelable(self.io);
        jobs_mod.markRunning(self.db, job.id, now) catch {};
        self.db_mu.unlock(self.io);

        // Determine method name.
        const method = switch (job_type) {
            .ocr => "ocr.extract",
            .prompt => "prompt.run",
            .slice => "slice.run", // not dispatched in Plan B but keep it safe
        };

        // Send the request; on failure, release the worker and re-queue.
        _ = worker.sendRequest(self.gpa, method, params) catch {
            self.gpa.free(job_id_owned);
            worker.current_job_id = null;
            self.sup.release(worker);

            const now2 = db_mod.nowIso8601(self.gpa) catch return;
            defer self.gpa.free(now2);
            self.db_mu.lockUncancelable(self.io);
            jobs_mod.markFailedAt(self.db, job.id, "send_request_failed", now2) catch {};
            self.db_mu.unlock(self.io);
            return;
        };
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    /// Truncate a string to at most `max_len` bytes.
    fn truncateStr(s: []const u8, max_len: usize) []const u8 {
        if (s.len <= max_len) return s;
        return s[0..max_len];
    }
};

/// Parse a JSON object string and extract a top-level float field by name.
/// Returns null on any parse/lookup failure.
pub fn extractFloatField(json_str: []const u8, field: []const u8) ?f64 {
    // Use a small arena so we don't need a gpa for this helper.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, gpa, json_str, .{}) catch return null;
    // No need to call parsed.deinit() — arena owns everything.

    if (parsed.value != .object) return null;
    const val = parsed.value.object.get(field) orelse return null;
    return switch (val) {
        .float => |f| f,
        .integer => |i| @as(f64, @floatFromInt(i)),
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Dispatcher.init / requestStop / deinit don't leak" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var db = try Db.open(":memory:");
    defer db.close();

    var mu: Io.Mutex = .init;

    var specs = [_]config_mod.AgentSpec{};
    var cfg = config_mod.AgentConfig{ .agents = &specs };
    var ch = EventChannel.init(gpa, io);
    defer ch.deinit();
    var sup = Supervisor.init(io, gpa, &cfg, &ch);
    defer sup.deinit();

    var d = Dispatcher.init(io, gpa, &db, &mu, &sup, &ch);
    defer d.deinit();

    d.requestStop();
    try std.testing.expect(d.stop.load(.acquire));
}

test "extractFloatField parses progress from notification params" {
    const progress = extractFloatField("{\"progress\":0.75}", "progress");
    try std.testing.expect(progress != null);
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), progress.?, 1e-9);

    // Integer value should also work.
    const p2 = extractFloatField("{\"progress\":1}", "progress");
    try std.testing.expect(p2 != null);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), p2.?, 1e-9);

    // Missing field.
    const p3 = extractFloatField("{\"other\":0.5}", "progress");
    try std.testing.expect(p3 == null);

    // Malformed JSON.
    const p4 = extractFloatField("not json", "progress");
    try std.testing.expect(p4 == null);
}
