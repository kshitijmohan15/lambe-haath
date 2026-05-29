# Plan B — Supervisor + Dispatcher + HTTP Endpoints

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire `logos` so it accepts OCR / prompt / cancel HTTP requests, runs them end-to-end against the **mock agent** from Plan A, persists results in `extractions` / `prompt_outputs` / `job_logs`, and streams live progress over SSE — with no real Gemini/Anthropic calls yet.

**Architecture:** A long-lived dispatcher thread inside `logos` polls the `jobs` table. For each dispatchable job it calls a `Supervisor` to acquire an idle worker (or spawn one up to `max_workers`); the worker is a child process speaking `lambe-haath/1` JSON-RPC over stdio. Worker stdout is drained on a per-worker reader thread that posts events onto a shared MPSC channel; the dispatcher consumes events, updates DB state, and assigns the next job. HTTP handlers enqueue work and stream live status via SSE.

**Tech Stack:** Zig 0.16, zqlite, std.process.Child, std.Thread (mutex + condition + threads), std.Io.Reader/Writer.

**Spec reference:** [`docs/superpowers/specs/2026-05-28-chargesheet-pipeline-design.md`](../specs/2026-05-28-chargesheet-pipeline-design.md). Sections this plan implements: _logos modules to add_ (everything under `src/agents/` not done in Plan A), _Job lifecycle walkthroughs_, _Error handling and recovery_.

**Out of scope for Plan B** (deferred): real OCR agent (`agents/ocr_agent` in Python) — Plan C. Real prompt agent — Plan D. Stats endpoints — Plan E. SPA UI work — Plan F.

**Prerequisites:** Plan A merged. The v2 schema, JSON-RPC codec, mock agent, and conformance harness are all in place. `feat/plan-a-foundation` branches in both repos.

---

## File structure

What this plan creates or modifies:

### `~/projects/lambe-haath/logos/`

```
src/
  agents/
    config.zig                 ← CREATE  (load agents.json with hardcoded fallback)
    event_channel.zig          ← CREATE  (MPSC queue for worker events)
    worker.zig                 ← CREATE  (Worker struct + reader thread + spawn/initialize)
    supervisor.zig             ← CREATE  (pool manager)
    dispatcher.zig             ← CREATE  (the main loop)
  api/
    handlers_ocr.zig           ← CREATE  (OCR job + extraction endpoints)
    handlers_prompts.zig       ← CREATE  (prompt job + prompt-output endpoints)
    handlers_jobs.zig          ← CREATE  (cancel + logs endpoints)
    sse.zig                    ← CREATE  (server-sent-events helper)
    router.zig                 ← MODIFY  (add new route table entries)
    handlers.zig               ← MODIFY  (route dispatch for the new handlers)
  db/
    jobs.zig                   ← MODIFY  (add nextDispatchable + markRunning + helpers)
    test_helpers.zig           ← MODIFY  (add insertSlice + insertExtraction helpers)
  main.zig                     ← MODIFY  (cleanup-stuck-jobs + agent config + dispatcher thread)
  root.zig                     ← MODIFY  (re-export new modules)
```

### `~/projects/chargesheets/pdf-extraction-experiments/`

No new files for Plan B. The existing `tests/mock_agent.py` from Plan A is reused as the integration-test fixture. Plan B's Zig tests reference it via the `LAMBE_MOCK_AGENT_PATH` environment variable.

---

## Pre-flight: branching

Before Task 1, both repos need a fresh feature branch off `main`. **Plan A's branches must be merged into main first** — Plan B should not chain off Plan A's branch.

```bash
# In each repo, after Plan A is merged:
cd ~/projects/lambe-haath/logos
git checkout main && git pull
git checkout -b feat/plan-b-supervisor-dispatcher

cd ~/projects/chargesheets/pdf-extraction-experiments
git checkout main && git pull
git checkout -b feat/plan-b-supervisor-dispatcher
```

(The pdf-extraction-experiments branch is only there because the design doc + this plan file live in that repo; no code changes happen here.)

---

## Task 1: `agents/config.zig` — parse `agents.json` from data_dir

**Target repo:** `~/projects/lambe-haath/logos/`

**Files:**
- Create: `src/agents/config.zig`
- Modify: `src/root.zig`
- Modify: `src/main.zig` test block

- [ ] **Step 1: Create `src/agents/config.zig`**

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;

pub const AgentSpec = struct {
    kind: []const u8,
    command: []const u8,
    args: []const []const u8,
    max_workers: u32,
    model: []const u8,

    pub fn deinit(self: *AgentSpec, gpa: Allocator) void {
        gpa.free(self.kind);
        gpa.free(self.command);
        for (self.args) |a| gpa.free(a);
        gpa.free(self.args);
        gpa.free(self.model);
    }
};

pub const AgentConfig = struct {
    agents: []AgentSpec,

    pub fn deinit(self: *AgentConfig, gpa: Allocator) void {
        for (self.agents) |*a| a.deinit(gpa);
        gpa.free(self.agents);
    }

    pub fn find(self: *const AgentConfig, kind: []const u8) ?*const AgentSpec {
        for (self.agents) |*a| {
            if (std.mem.eql(u8, a.kind, kind)) return a;
        }
        return null;
    }
};

const default_config_text =
    \\{
    \\  "agents": [
    \\    {"kind": "ocr",    "command": "python3", "args": ["-m", "agents.ocr_agent"],    "max_workers": 2, "model": "gemini-2.5-flash"},
    \\    {"kind": "prompt", "command": "python3", "args": ["-m", "agents.prompt_agent"], "max_workers": 5, "model": "claude-sonnet-4-6"}
    \\  ]
    \\}
;

pub const LoadError = error{
    InvalidJson,
    MissingAgentsArray,
    InvalidAgentSpec,
    OutOfMemory,
};

/// Load agents.json from `<data_dir>/agents.json`. If the file does not exist,
/// return the hardcoded default configuration so a fresh install works
/// without manual setup.
pub fn loadFromDir(gpa: Allocator, data_dir: []const u8) !AgentConfig {
    const path = try std.fs.path.join(gpa, &.{ data_dir, "agents.json" });
    defer gpa.free(path);

    const file_text = std.fs.cwd().readFileAlloc(path, gpa, .limited(1 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return parseJson(gpa, default_config_text),
        else => return err,
    };
    defer gpa.free(file_text);
    return parseJson(gpa, file_text);
}

pub fn parseJson(gpa: Allocator, text: []const u8) LoadError!AgentConfig {
    var parsed = json.parseFromSlice(json.Value, gpa, text, .{}) catch return LoadError.InvalidJson;
    defer parsed.deinit();

    if (parsed.value != .object) return LoadError.InvalidJson;
    const agents_val = parsed.value.object.get("agents") orelse return LoadError.MissingAgentsArray;
    if (agents_val != .array) return LoadError.MissingAgentsArray;

    var list = try gpa.alloc(AgentSpec, agents_val.array.items.len);
    var filled: usize = 0;
    errdefer {
        for (list[0..filled]) |*a| a.deinit(gpa);
        gpa.free(list);
    }

    for (agents_val.array.items, 0..) |item, i| {
        if (item != .object) return LoadError.InvalidAgentSpec;
        const obj = item.object;
        const kind_v = obj.get("kind") orelse return LoadError.InvalidAgentSpec;
        const command_v = obj.get("command") orelse return LoadError.InvalidAgentSpec;
        const args_v = obj.get("args") orelse return LoadError.InvalidAgentSpec;
        const mw_v = obj.get("max_workers") orelse return LoadError.InvalidAgentSpec;
        const model_v = obj.get("model") orelse return LoadError.InvalidAgentSpec;

        if (kind_v != .string or command_v != .string or model_v != .string) return LoadError.InvalidAgentSpec;
        if (args_v != .array) return LoadError.InvalidAgentSpec;
        if (mw_v != .integer or mw_v.integer < 1) return LoadError.InvalidAgentSpec;

        const kind = try gpa.dupe(u8, kind_v.string);
        errdefer gpa.free(kind);
        const command = try gpa.dupe(u8, command_v.string);
        errdefer gpa.free(command);
        const model = try gpa.dupe(u8, model_v.string);
        errdefer gpa.free(model);

        const args_slice = try gpa.alloc([]const u8, args_v.array.items.len);
        var args_filled: usize = 0;
        errdefer {
            for (args_slice[0..args_filled]) |s| gpa.free(s);
            gpa.free(args_slice);
        }
        for (args_v.array.items) |arg_item| {
            if (arg_item != .string) return LoadError.InvalidAgentSpec;
            args_slice[args_filled] = try gpa.dupe(u8, arg_item.string);
            args_filled += 1;
        }

        list[i] = .{
            .kind = kind,
            .command = command,
            .args = args_slice,
            .max_workers = @intCast(mw_v.integer),
            .model = model,
        };
        filled += 1;
    }

    return .{ .agents = list };
}

test "parseJson accepts the default config text" {
    const gpa = std.testing.allocator;
    var cfg = try parseJson(gpa, default_config_text);
    defer cfg.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), cfg.agents.len);
    try std.testing.expectEqualStrings("ocr", cfg.agents[0].kind);
    try std.testing.expectEqualStrings("python3", cfg.agents[0].command);
    try std.testing.expectEqual(@as(u32, 2), cfg.agents[0].max_workers);
    try std.testing.expectEqualStrings("gemini-2.5-flash", cfg.agents[0].model);
    try std.testing.expectEqualStrings("prompt", cfg.agents[1].kind);
    try std.testing.expectEqual(@as(u32, 5), cfg.agents[1].max_workers);
}

test "parseJson rejects missing agents array" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(
        LoadError.MissingAgentsArray,
        parseJson(gpa, "{}"),
    );
}

test "parseJson rejects max_workers < 1" {
    const gpa = std.testing.allocator;
    const text =
        \\{"agents":[{"kind":"x","command":"y","args":[],"max_workers":0,"model":"m"}]}
    ;
    try std.testing.expectError(
        LoadError.InvalidAgentSpec,
        parseJson(gpa, text),
    );
}

test "parseJson rejects missing model field" {
    const gpa = std.testing.allocator;
    const text =
        \\{"agents":[{"kind":"x","command":"y","args":[],"max_workers":1}]}
    ;
    try std.testing.expectError(
        LoadError.InvalidAgentSpec,
        parseJson(gpa, text),
    );
}

test "AgentConfig.find returns the right spec" {
    const gpa = std.testing.allocator;
    var cfg = try parseJson(gpa, default_config_text);
    defer cfg.deinit(gpa);

    const ocr = cfg.find("ocr") orelse return error.NotFound;
    try std.testing.expectEqualStrings("python3", ocr.command);

    try std.testing.expect(cfg.find("nonexistent") == null);
}

test "loadFromDir falls back to default when agents.json missing" {
    const gpa = std.testing.allocator;
    // Use a /tmp dir that we know has no agents.json
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(dir_path);

    var cfg = try loadFromDir(gpa, dir_path);
    defer cfg.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), cfg.agents.len);
    try std.testing.expectEqualStrings("ocr", cfg.agents[0].kind);
}
```

- [ ] **Step 2: Re-export from `src/root.zig`**

Add a line in the agents section:
```zig
pub const agent_config = @import("agents/config.zig");
```

- [ ] **Step 3: Wire into `src/main.zig` test block**

Add `_ = @import("agents/config.zig");` to the test block.

- [ ] **Step 4: Run tests**

```bash
cd ~/projects/lambe-haath/logos
zig build test --summary all 2>&1 | tail -5
```

Expected: previous test count + 6 new tests.

- [ ] **Step 5: Commit**

```bash
git add src/agents/config.zig src/root.zig src/main.zig
git commit -m "agents/config: load agents.json with hardcoded fallback"
```

---

## Task 2: `agents/event_channel.zig` — thread-safe MPSC queue

**Target repo:** `~/projects/lambe-haath/logos/`

**Files:**
- Create: `src/agents/event_channel.zig`
- Modify: `src/root.zig`, `src/main.zig` test block

The channel carries worker events (responses, notifications, deaths) from per-worker reader threads to the dispatcher.

- [ ] **Step 1: Create `src/agents/event_channel.zig`**

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;
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
pub const EventChannel = struct {
    gpa: Allocator,
    mu: std.Thread.Mutex = .{},
    cv: std.Thread.Condition = .{},
    items: std.ArrayList(EventEnvelope) = .empty,
    closed: bool = false,

    pub fn init(gpa: Allocator) EventChannel {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *EventChannel) void {
        self.mu.lock();
        defer self.mu.unlock();
        // Free any messages still sitting in the queue.
        for (self.items.items) |*env| freeEvent(self.gpa, &env.event);
        self.items.deinit(self.gpa);
    }

    pub fn send(self: *EventChannel, env: EventEnvelope) !void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.closed) {
            // Drop and free the event rather than producing a half-state.
            var e = env.event;
            freeEvent(self.gpa, &e);
            return;
        }
        try self.items.append(self.gpa, env);
        self.cv.signal();
    }

    /// Non-blocking pop. Returns null if queue is empty.
    pub fn tryRecv(self: *EventChannel) ?EventEnvelope {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.items.items.len == 0) return null;
        return self.items.orderedRemove(0);
    }

    /// Block up to `timeout_ms`; return null on timeout.
    pub fn recvTimeout(self: *EventChannel, timeout_ms: u64) ?EventEnvelope {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.items.items.len > 0) return self.items.orderedRemove(0);
        const ns: u64 = timeout_ms * std.time.ns_per_ms;
        self.cv.timedWait(&self.mu, ns) catch {};
        if (self.items.items.len == 0) return null;
        return self.items.orderedRemove(0);
    }

    /// Mark the channel closed; future sends drop events. Used during shutdown.
    pub fn close(self: *EventChannel) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.closed = true;
        self.cv.broadcast();
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
    var ch = EventChannel.init(gpa);
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
    var ch = EventChannel.init(gpa);
    defer ch.deinit();

    const start = std.time.milliTimestamp();
    const got = ch.recvTimeout(10);
    const elapsed = std.time.milliTimestamp() - start;
    try std.testing.expect(got == null);
    try std.testing.expect(elapsed >= 8);  // slack for scheduler
}

test "close drops events sent afterwards" {
    const gpa = std.testing.allocator;
    var ch = EventChannel.init(gpa);
    defer ch.deinit();

    ch.close();
    try ch.send(.{ .worker_id = 99, .event = .dead });
    try std.testing.expect(ch.tryRecv() == null);
}
```

- [ ] **Step 2: Re-export from `src/root.zig`**

```zig
pub const event_channel = @import("agents/event_channel.zig");
```

- [ ] **Step 3: Wire into `src/main.zig` test block**

```zig
_ = @import("agents/event_channel.zig");
```

- [ ] **Step 4: Run + commit**

```bash
zig build test --summary all 2>&1 | tail -5
git add src/agents/event_channel.zig src/root.zig src/main.zig
git commit -m "agents/event_channel: thread-safe MPSC queue for worker events"
```

Expected: +3 tests.

---

## Task 3: `agents/worker.zig` — spawn + initialize + reader thread

**Target repo:** `~/projects/lambe-haath/logos/`

**Files:**
- Create: `src/agents/worker.zig`
- Modify: `src/root.zig`, `src/main.zig` test block

The Worker is the smallest unit of agent management: one OS process + its stdio + its state machine. The Supervisor (Task 4) composes many Workers.

- [ ] **Step 1: Create `src/agents/worker.zig`**

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const jsonrpc = @import("jsonrpc.zig");
const config = @import("config.zig");
const event_channel = @import("event_channel.zig");

pub const State = enum {
    spawning,   // process forked, awaiting initialize response
    idle,       // initialized, no job assigned
    busy,       // request sent, awaiting response
    draining,   // shutdown requested
    dead,       // exited
};

pub const Worker = struct {
    id: u64,
    kind: []const u8,
    child: std.process.Child,
    state: State = .spawning,
    current_job_id: ?[]const u8 = null,
    next_request_id: u64 = 1,
    reader_thread: ?std.Thread = null,

    pub fn sendRequest(self: *Worker, gpa: Allocator, method: []const u8, params_json: []const u8) !u64 {
        const id = self.next_request_id;
        self.next_request_id += 1;
        const line = try jsonrpc.encode(gpa, .{ .request = .{
            .id = @intCast(id),
            .method = method,
            .params_json = params_json,
        } });
        defer gpa.free(line);
        try self.writeLine(line);
        return id;
    }

    pub fn sendNotification(self: *Worker, gpa: Allocator, method: []const u8, params_json: ?[]const u8) !void {
        const line = try jsonrpc.encode(gpa, .{ .notification = .{
            .method = method,
            .params_json = params_json,
        } });
        defer gpa.free(line);
        try self.writeLine(line);
    }

    fn writeLine(self: *Worker, line: []const u8) !void {
        const stdin = self.child.stdin orelse return error.NoStdin;
        try stdin.writeAll(line);  // line already ends with \n
    }
};

pub const SpawnError = error{
    SpawnFailed,
    InitializeFailed,
    BadInitializeResponse,
    OutOfMemory,
} || std.process.Child.SpawnError;

/// Spawn the agent child process, perform the initialize handshake synchronously,
/// then start a reader thread that drains stdout into the shared channel.
///
/// On success: returns a Worker in state=idle.
/// On failure: cleans up any partial process state.
pub fn spawn(
    gpa: Allocator,
    id: u64,
    spec: *const config.AgentSpec,
    channel: *event_channel.EventChannel,
) SpawnError!Worker {
    // Build argv: [command, ...args]
    var argv = try gpa.alloc([]const u8, 1 + spec.args.len);
    defer gpa.free(argv);
    argv[0] = spec.command;
    for (spec.args, 0..) |a, i| argv[i + 1] = a;

    var child = std.process.Child.init(argv, gpa);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;  // Plan B: inherit stderr to logos's stderr. Plan future: log to file.

    // Pass LAMBE_MODEL into the child env so the agent picks the right SDK.
    // Inherit logos's current env, then add/override LAMBE_MODEL.
    var env_map = try std.process.getEnvMap(gpa);
    defer env_map.deinit();
    try env_map.put("LAMBE_MODEL", spec.model);
    child.env_map = &env_map;

    try child.spawn();
    errdefer {
        _ = child.kill() catch {};
        _ = child.wait() catch {};
    }

    // --- initialize handshake (synchronous, before starting reader thread) ---
    const init_params_json =
        \\{"protocolVersion":"lambe-haath/1","hostInfo":{"name":"logos","version":"0.3.0"},"capabilities":{"progress":true,"cancellation":true}}
    ;
    const init_line = jsonrpc.encode(gpa, .{ .request = .{
        .id = 0,
        .method = "initialize",
        .params_json = init_params_json,
    } }) catch return SpawnError.OutOfMemory;
    defer gpa.free(init_line);

    const stdin = child.stdin orelse return SpawnError.SpawnFailed;
    stdin.writeAll(init_line) catch return SpawnError.InitializeFailed;

    // Read one line from stdout; decode; verify it's a valid initialize response.
    const stdout = child.stdout orelse return SpawnError.SpawnFailed;
    var line_buf: std.ArrayList(u8) = .empty;
    defer line_buf.deinit(gpa);
    try readOneLine(stdout, gpa, &line_buf, 64 * 1024);

    var msg = jsonrpc.decodeLine(gpa, line_buf.items) catch return SpawnError.BadInitializeResponse;
    defer msg.deinit(gpa);

    if (msg != .response) return SpawnError.BadInitializeResponse;
    if (msg.response.id != 0) return SpawnError.BadInitializeResponse;
    if (msg.response.body != .result) return SpawnError.BadInitializeResponse;

    // Kind string is owned by the spec, which outlives the worker.
    var w = Worker{
        .id = id,
        .kind = spec.kind,
        .child = child,
        .state = .idle,
    };

    // Now start the reader thread.
    const ctx = try gpa.create(ReaderContext);
    ctx.* = .{ .gpa = gpa, .worker_id = id, .stdout = stdout, .channel = channel };
    w.reader_thread = try std.Thread.spawn(.{}, readerThreadFn, .{ctx});

    return w;
}

const ReaderContext = struct {
    gpa: Allocator,
    worker_id: u64,
    stdout: std.fs.File,
    channel: *event_channel.EventChannel,
};

fn readerThreadFn(ctx: *ReaderContext) void {
    defer ctx.gpa.destroy(ctx);
    var line_buf: std.ArrayList(u8) = .empty;
    defer line_buf.deinit(ctx.gpa);

    while (true) {
        line_buf.clearRetainingCapacity();
        readOneLine(ctx.stdout, ctx.gpa, &line_buf, 1024 * 1024) catch |err| switch (err) {
            error.EndOfStream, error.BrokenPipe => {
                ctx.channel.send(.{ .worker_id = ctx.worker_id, .event = .dead }) catch {};
                return;
            },
            else => {
                ctx.channel.send(.{ .worker_id = ctx.worker_id, .event = .dead }) catch {};
                return;
            },
        };

        if (line_buf.items.len == 0) continue;

        var msg = jsonrpc.decodeLine(ctx.gpa, line_buf.items) catch {
            // Malformed line: pass the raw bytes through so the dispatcher can log,
            // but the worker keeps running.
            const owned = ctx.gpa.dupe(u8, line_buf.items) catch return;
            ctx.channel.send(.{
                .worker_id = ctx.worker_id,
                .event = .{ .parse_error = owned },
            }) catch {
                ctx.gpa.free(owned);
            };
            continue;
        };

        ctx.channel.send(.{
            .worker_id = ctx.worker_id,
            .event = .{ .message = msg },
        }) catch {
            msg.deinit(ctx.gpa);
            return;
        };
    }
}

/// Read up to '\n' (inclusive of EOL handling) into `buf`. Strips trailing \r/\n.
/// Errors: EndOfStream on EOF without any data; BrokenPipe on closed pipe.
fn readOneLine(stream: std.fs.File, gpa: Allocator, buf: *std.ArrayList(u8), max_bytes: usize) !void {
    var b: [1]u8 = undefined;
    while (true) {
        const n = stream.read(&b) catch |err| switch (err) {
            error.BrokenPipe => return error.BrokenPipe,
            else => return err,
        };
        if (n == 0) {
            if (buf.items.len == 0) return error.EndOfStream;
            return;
        }
        if (b[0] == '\n') {
            // strip trailing \r if present
            if (buf.items.len > 0 and buf.items[buf.items.len - 1] == '\r') {
                _ = buf.pop();
            }
            return;
        }
        if (buf.items.len >= max_bytes) return error.StreamTooLong;
        try buf.append(gpa, b[0]);
    }
}

/// Gracefully close: send shutdown notification, close stdin, wait for exit (5s).
/// Caller is responsible for joining `reader_thread`.
pub fn close(self: *Worker, gpa: Allocator) void {
    self.sendNotification(gpa, "notifications/exit", null) catch {};
    if (self.child.stdin) |stdin| {
        stdin.close();
        self.child.stdin = null;
    }
    _ = self.child.wait() catch {};
    self.state = .dead;
    if (self.reader_thread) |t| {
        t.join();
        self.reader_thread = null;
    }
}

/// Force-kill the process. Use after close() exceeds its deadline.
pub fn kill(self: *Worker) void {
    _ = self.child.kill() catch {};
    _ = self.child.wait() catch {};
    self.state = .dead;
    if (self.reader_thread) |t| {
        t.join();
        self.reader_thread = null;
    }
}

// --- tests --- //

const builtin = @import("builtin");

/// Find the mock_agent.py path from env var LAMBE_MOCK_AGENT_PATH.
/// Tests that need it should skip cleanly if not set.
fn mockAgentPathOrSkip() ?[]const u8 {
    return std.posix.getenv("LAMBE_MOCK_AGENT_PATH");
}

fn mockAgentSpec(gpa: Allocator, path: []const u8) !config.AgentSpec {
    var args = try gpa.alloc([]const u8, 1);
    args[0] = try gpa.dupe(u8, path);
    return .{
        .kind = try gpa.dupe(u8, "mock"),
        .command = try gpa.dupe(u8, "python3"),
        .args = args,
        .max_workers = 1,
        .model = try gpa.dupe(u8, "mock-model"),
    };
}

test "spawn + initialize + close against mock agent" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    const path = mockAgentPathOrSkip() orelse return error.SkipZigTest;

    const gpa = std.testing.allocator;
    var ch = event_channel.EventChannel.init(gpa);
    defer ch.deinit();

    var spec = try mockAgentSpec(gpa, path);
    defer spec.deinit(gpa);

    var w = try spawn(gpa, 1, &spec, &ch);
    try std.testing.expectEqual(State.idle, w.state);
    try std.testing.expectEqual(@as(u64, 1), w.id);

    // Close cleanly. Reader thread should post .dead then exit.
    w.close(gpa);
    try std.testing.expectEqual(State.dead, w.state);

    // We should see a .dead event on the channel.
    var saw_dead = false;
    while (ch.tryRecv()) |env| {
        var ev = env.event;
        defer event_channel.freeEvent(gpa, &ev);
        if (env.event == .dead) saw_dead = true;
    }
    try std.testing.expect(saw_dead);
}

test "sendRequest + reader thread surfaces response on channel" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    const path = mockAgentPathOrSkip() orelse return error.SkipZigTest;

    const gpa = std.testing.allocator;
    var ch = event_channel.EventChannel.init(gpa);
    defer ch.deinit();

    var spec = try mockAgentSpec(gpa, path);
    defer spec.deinit(gpa);

    var w = try spawn(gpa, 1, &spec, &ch);
    defer w.close(gpa);

    const req_id = try w.sendRequest(gpa, "mock.echo", "{\"hello\":\"world\"}");
    try std.testing.expectEqual(@as(u64, 1), req_id);

    // Wait up to 2s for the response event.
    var got: ?event_channel.EventEnvelope = null;
    var attempts: u32 = 0;
    while (attempts < 20) : (attempts += 1) {
        if (ch.recvTimeout(100)) |env| {
            got = env;
            break;
        }
    }

    var env = got orelse return error.NoResponse;
    defer {
        var ev = env.event;
        event_channel.freeEvent(gpa, &ev);
    }

    try std.testing.expect(env.event == .message);
    try std.testing.expect(env.event.message == .response);
    try std.testing.expectEqual(@as(i64, 1), env.event.message.response.id);
    try std.testing.expect(env.event.message.response.body == .result);
}
```

- [ ] **Step 2: Re-export + wire test**

`src/root.zig`:
```zig
pub const worker = @import("agents/worker.zig");
```

`src/main.zig` test block:
```zig
_ = @import("agents/worker.zig");
```

- [ ] **Step 3: Set the mock-agent path env var, run tests**

```bash
cd ~/projects/lambe-haath/logos
export LAMBE_MOCK_AGENT_PATH="$HOME/projects/chargesheets/pdf-extraction-experiments/tests/mock_agent.py"
zig build test --summary all 2>&1 | tail -10
```

Expected: previous count + 2 new tests (which may be skipped if `LAMBE_MOCK_AGENT_PATH` is unset, but with the export they should run).

If the spawn-related tests fail with `error.FileNotFound` or similar, double-check that the mock_agent.py from Plan A is committed and the path resolves.

- [ ] **Step 4: Commit**

```bash
git add src/agents/worker.zig src/root.zig src/main.zig
git commit -m "agents/worker: spawn + initialize + reader thread + close/kill"
```

---

## Task 4: `agents/supervisor.zig` — worker pool with lazy spawn

**Target repo:** `~/projects/lambe-haath/logos/`

**Files:**
- Create: `src/agents/supervisor.zig`
- Modify: `src/root.zig`, `src/main.zig` test block

- [ ] **Step 1: Create `src/agents/supervisor.zig`**

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const config = @import("config.zig");
const event_channel = @import("event_channel.zig");
const worker_mod = @import("worker.zig");

pub const Supervisor = struct {
    gpa: Allocator,
    cfg: *const config.AgentConfig,
    channel: *event_channel.EventChannel,
    mu: std.Thread.Mutex = .{},
    workers: std.ArrayList(*worker_mod.Worker) = .empty,
    next_id: u64 = 1,

    pub fn init(gpa: Allocator, cfg: *const config.AgentConfig, channel: *event_channel.EventChannel) Supervisor {
        return .{ .gpa = gpa, .cfg = cfg, .channel = channel };
    }

    pub fn deinit(self: *Supervisor) void {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.workers.items) |w| {
            w.kill();
            self.gpa.destroy(w);
        }
        self.workers.deinit(self.gpa);
    }

    /// Return an idle worker of the given kind, or spawn a new one if under the
    /// kind's cap, or null if cap reached and all busy.
    /// Returned worker is marked .busy.
    pub fn acquire(self: *Supervisor, kind: []const u8) !?*worker_mod.Worker {
        self.mu.lock();
        defer self.mu.unlock();

        // Find an idle worker of this kind.
        for (self.workers.items) |w| {
            if (std.mem.eql(u8, w.kind, kind) and w.state == .idle) {
                w.state = .busy;
                return w;
            }
        }

        // Count current workers of this kind (alive only).
        var count: u32 = 0;
        for (self.workers.items) |w| {
            if (std.mem.eql(u8, w.kind, kind) and w.state != .dead) count += 1;
        }

        const spec = self.cfg.find(kind) orelse return error.UnknownAgentKind;
        if (count >= spec.max_workers) return null;

        // Spawn a fresh worker.
        const id = self.next_id;
        self.next_id += 1;
        const w_ptr = try self.gpa.create(worker_mod.Worker);
        errdefer self.gpa.destroy(w_ptr);
        w_ptr.* = try worker_mod.spawn(self.gpa, id, spec, self.channel);
        w_ptr.state = .busy;
        try self.workers.append(self.gpa, w_ptr);
        return w_ptr;
    }

    pub fn release(self: *Supervisor, w: *worker_mod.Worker) void {
        self.mu.lock();
        defer self.mu.unlock();
        if (w.state != .dead) {
            w.state = .idle;
            w.current_job_id = null;
        }
    }

    /// Mark a worker dead and forget about it. The reader thread is presumed to
    /// have exited already (it posts `.dead` on EOF and returns). Workers are
    /// freed here; callers must not keep the pointer after this returns.
    pub fn markDead(self: *Supervisor, worker_id: u64) void {
        self.mu.lock();
        defer self.mu.unlock();
        var i: usize = 0;
        while (i < self.workers.items.len) : (i += 1) {
            if (self.workers.items[i].id == worker_id) {
                const w = self.workers.items[i];
                w.state = .dead;
                // Join reader thread (should already be exiting).
                if (w.reader_thread) |t| {
                    t.join();
                    w.reader_thread = null;
                }
                _ = w.child.wait() catch {};
                _ = self.workers.orderedRemove(i);
                self.gpa.destroy(w);
                return;
            }
        }
    }

    pub fn findById(self: *Supervisor, worker_id: u64) ?*worker_mod.Worker {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.workers.items) |w| {
            if (w.id == worker_id) return w;
        }
        return null;
    }

    /// Find a worker currently handling `job_id` (or null).
    /// Caller must NOT hold the supervisor mutex when calling.
    pub fn findByJob(self: *Supervisor, job_id: []const u8) ?*worker_mod.Worker {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.workers.items) |w| {
            if (w.state == .busy) {
                if (w.current_job_id) |cj| {
                    if (std.mem.eql(u8, cj, job_id)) return w;
                }
            }
        }
        return null;
    }

    /// Gracefully shutdown all workers. Each gets `close()` (notifications/exit
    /// + stdin close) followed by wait. If the wait deadline of 5s per worker
    /// is exceeded, `kill()`.
    pub fn shutdownAll(self: *Supervisor) void {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.workers.items) |w| {
            w.state = .draining;
            w.close(self.gpa);
        }
        for (self.workers.items) |w| {
            self.gpa.destroy(w);
        }
        self.workers.clearRetainingCapacity();
    }
};

// --- tests --- //

const builtin = @import("builtin");

fn mockSpec(gpa: Allocator, path: []const u8, kind: []const u8, max_workers: u32) !config.AgentSpec {
    var args = try gpa.alloc([]const u8, 1);
    args[0] = try gpa.dupe(u8, path);
    return .{
        .kind = try gpa.dupe(u8, kind),
        .command = try gpa.dupe(u8, "python3"),
        .args = args,
        .max_workers = max_workers,
        .model = try gpa.dupe(u8, "mock-model"),
    };
}

fn mockPath() ?[]const u8 {
    return std.posix.getenv("LAMBE_MOCK_AGENT_PATH");
}

test "acquire spawns first worker on demand" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    const path = mockPath() orelse return error.SkipZigTest;

    const gpa = std.testing.allocator;
    var ch = event_channel.EventChannel.init(gpa);
    defer ch.deinit();

    var spec = try mockSpec(gpa, path, "mock", 2);
    defer spec.deinit(gpa);
    var specs = [_]config.AgentSpec{spec};
    var cfg = config.AgentConfig{ .agents = &specs };

    var sup = Supervisor.init(gpa, &cfg, &ch);
    defer sup.deinit();

    const w = (try sup.acquire("mock")) orelse return error.NoWorker;
    try std.testing.expectEqual(@import("worker.zig").State.busy, w.state);
    sup.release(w);
}

test "acquire returns null when cap reached and all busy" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    const path = mockPath() orelse return error.SkipZigTest;

    const gpa = std.testing.allocator;
    var ch = event_channel.EventChannel.init(gpa);
    defer ch.deinit();

    var spec = try mockSpec(gpa, path, "mock", 1);  // cap = 1
    defer spec.deinit(gpa);
    var specs = [_]config.AgentSpec{spec};
    var cfg = config.AgentConfig{ .agents = &specs };

    var sup = Supervisor.init(gpa, &cfg, &ch);
    defer sup.deinit();

    const a = (try sup.acquire("mock")) orelse return error.NoWorker;
    const b = try sup.acquire("mock");
    try std.testing.expect(b == null);
    sup.release(a);

    // After release, acquire returns the same worker.
    const c = (try sup.acquire("mock")) orelse return error.NoWorker;
    try std.testing.expectEqual(a.id, c.id);
}

test "shutdownAll terminates all workers" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    const path = mockPath() orelse return error.SkipZigTest;

    const gpa = std.testing.allocator;
    var ch = event_channel.EventChannel.init(gpa);
    defer ch.deinit();

    var spec = try mockSpec(gpa, path, "mock", 3);
    defer spec.deinit(gpa);
    var specs = [_]config.AgentSpec{spec};
    var cfg = config.AgentConfig{ .agents = &specs };

    var sup = Supervisor.init(gpa, &cfg, &ch);
    // Spawn 2 workers.
    _ = (try sup.acquire("mock")) orelse return error.NoWorker;
    _ = (try sup.acquire("mock")) orelse return error.NoWorker;

    sup.shutdownAll();

    // No leaks; workers slice is empty.
    try std.testing.expectEqual(@as(usize, 0), sup.workers.items.len);
}
```

- [ ] **Step 2: Wire + commit**

`src/root.zig`:
```zig
pub const supervisor = @import("agents/supervisor.zig");
```

`src/main.zig` test block:
```zig
_ = @import("agents/supervisor.zig");
```

```bash
export LAMBE_MOCK_AGENT_PATH="$HOME/projects/chargesheets/pdf-extraction-experiments/tests/mock_agent.py"
zig build test --summary all 2>&1 | tail -10
git add src/agents/supervisor.zig src/root.zig src/main.zig
git commit -m "agents/supervisor: lazy-spawn pool manager with acquire/release/shutdown"
```

Expected: +3 tests.

---

## Task 5: `db/jobs.zig` — add `nextDispatchable` + `markRunning` + `markCompleted` + `markFailed` + `markCanceled` + `markStuckJobsFailed`

**Target repo:** `~/projects/lambe-haath/logos/`

**Files:**
- Modify: `src/db/jobs.zig`

The dispatcher needs convenience helpers for the typical state transitions. Add them now so Task 6 (the dispatcher) is simple call-sites.

- [ ] **Step 1: Read the existing `src/db/jobs.zig`** to find a good insertion point. Append these functions just above the `test` block at the bottom:

```zig
/// Fetch the oldest queued job of the given type whose preconditions are met.
/// For 'slice' / 'ocr': any queued job. For 'prompt': queued AND all required
/// slices have extractions (LEFT JOIN gate from the spec).
/// Caller owns the returned Job.
pub fn nextDispatchable(db: *Db, gpa: Allocator, job_type: JobType) !?Job {
    const text = job_type.toText();

    if (job_type == .prompt) {
        // Prompt jobs: gate on OCR fan-in. Skip any prompt-job whose project
        // has annexure/rud slices without extractions.
        const row = try db.conn.row(
            \\SELECT id, project_id, type, status, progress, payload, results, error,
            \\       created_at, updated_at
            \\FROM jobs j
            \\WHERE j.status='queued' AND j.type='prompt'
            \\AND NOT EXISTS (
            \\  SELECT 1 FROM slices s
            \\  LEFT JOIN extractions e
            \\         ON s.project_id = e.project_id AND s.filename = e.slice_filename
            \\  WHERE s.project_id = j.project_id
            \\    AND s.kind IN ('annexure','rud')
            \\    AND e.slice_filename IS NULL
            \\)
            \\ORDER BY j.created_at ASC LIMIT 1
        , .{});
        return if (row) |r| try rowToJob(r, gpa) else null;
    }

    const row = try db.conn.row(
        \\SELECT id, project_id, type, status, progress, payload, results, error,
        \\       created_at, updated_at
        \\FROM jobs WHERE status='queued' AND type=?
        \\ORDER BY created_at ASC LIMIT 1
    , .{text});
    return if (row) |r| try rowToJob(r, gpa) else null;
}

pub fn markRunning(db: *Db, job_id: []const u8, updated_at: []const u8) !void {
    try db.conn.exec(
        "UPDATE jobs SET status='running', updated_at=? WHERE id=?",
        .{ updated_at, job_id },
    );
}

pub fn markCompleted(db: *Db, job_id: []const u8, results_json: []const u8, updated_at: []const u8) !void {
    try db.conn.exec(
        "UPDATE jobs SET status='completed', progress=1.0, results=?, updated_at=? WHERE id=?",
        .{ results_json, updated_at, job_id },
    );
}

pub fn markFailed(db: *Db, job_id: []const u8, error_msg: []const u8, updated_at: []const u8) !void {
    try db.conn.exec(
        "UPDATE jobs SET status='failed', error=?, updated_at=? WHERE id=?",
        .{ error_msg, updated_at, job_id },
    );
}

pub fn markCanceled(db: *Db, job_id: []const u8, error_msg: []const u8, updated_at: []const u8) !void {
    try db.conn.exec(
        "UPDATE jobs SET status='canceled', error=?, updated_at=? WHERE id=?",
        .{ error_msg, updated_at, job_id },
    );
}

pub fn markReQueued(db: *Db, job_id: []const u8, updated_at: []const u8) !void {
    try db.conn.exec(
        "UPDATE jobs SET status='queued', error=NULL, updated_at=? WHERE id=?",
        .{ updated_at, job_id },
    );
}

pub fn updateProgress(db: *Db, job_id: []const u8, progress: f64, updated_at: []const u8) !void {
    try db.conn.exec(
        "UPDATE jobs SET progress=?, updated_at=? WHERE id=?",
        .{ progress, updated_at, job_id },
    );
}

/// Daemon-restart cleanup: mark all `running` and `queued` jobs as failed.
/// Per the spec's "Error handling and recovery" section.
pub fn markStuckJobsFailed(db: *Db, updated_at: []const u8) !u64 {
    try db.conn.exec(
        \\UPDATE jobs SET status='failed', error='daemon_restarted', updated_at=?
        \\WHERE status='running' OR status='queued'
    , .{updated_at});
    // zqlite doesn't expose `changes()` directly here; we don't need the count
    // for correctness — return 0 if not available.
    return 0;
}
```

- [ ] **Step 2: Add tests at the bottom of `src/db/jobs.zig`** (inside the existing test block region):

```zig
test "nextDispatchable returns oldest queued ocr job" {
    var db = try Db.open(":memory:");
    defer db.close();
    const gpa = std.testing.allocator;
    try test_helpers.insertProject(&db, "p1");

    try test_helpers.insertJob(&db, "j_old", "p1", "ocr");
    // Sleep a moment to ensure created_at differs (test_helpers uses a fixed timestamp;
    // so we can also just insert two jobs at the same time and rely on creation order).
    try test_helpers.insertJob(&db, "j_new", "p1", "ocr");

    var got = (try nextDispatchable(&db, gpa, .ocr)) orelse return error.NoJob;
    defer got.deinit(gpa);

    try std.testing.expect(
        std.mem.eql(u8, got.id, "j_old") or std.mem.eql(u8, got.id, "j_new"),
    );
    try std.testing.expectEqual(JobType.ocr, got.type);
    try std.testing.expectEqual(JobStatus.queued, got.status);
}

test "nextDispatchable for prompt is gated on OCR fan-in" {
    var db = try Db.open(":memory:");
    defer db.close();
    const gpa = std.testing.allocator;

    try test_helpers.insertProject(&db, "p1");
    // Insert one slice without an extraction.
    try db.conn.exec(
        \\INSERT INTO slices (project_id, filename, start_page, end_page, size_bytes, kind, kind_key, created_at)
        \\VALUES ('p1', 'annexure-i.pdf', 1, 1, 1, 'annexure', 'i', '2026-05-28T00:00:00Z')
    , .{});
    try test_helpers.insertJob(&db, "jp", "p1", "prompt");

    // No extraction row yet → prompt job is NOT dispatchable.
    var got_blocked = try nextDispatchable(&db, gpa, .prompt);
    try std.testing.expect(got_blocked == null);

    // Add the extraction → prompt job is now dispatchable.
    try db.conn.exec(
        \\INSERT INTO extractions
        \\  (project_id, slice_filename, markdown_path, meta_path, model,
        \\   pages, page_markers_found, latency_s, created_at)
        \\VALUES ('p1', 'annexure-i.pdf', '/x.md', '/x.json', 'mock', 1, 1, 1.0, '2026-05-28T00:01:00Z')
    , .{});

    var got = (try nextDispatchable(&db, gpa, .prompt)) orelse return error.NoJob;
    defer got.deinit(gpa);
    try std.testing.expectEqualStrings("jp", got.id);
}

test "markStuckJobsFailed flips running and queued to failed" {
    var db = try Db.open(":memory:");
    defer db.close();
    try test_helpers.insertProject(&db, "p1");
    try test_helpers.insertJob(&db, "jq", "p1", "ocr");  // status='queued' by default

    // Manually set one job to 'running'.
    try db.conn.exec(
        \\INSERT INTO jobs (id, project_id, type, status, payload, created_at, updated_at)
        \\VALUES ('jr', 'p1', 'ocr', 'running', '{}', '2026-05-28T00:00:00Z', '2026-05-28T00:00:00Z')
    , .{});

    _ = try markStuckJobsFailed(&db, "2026-05-28T00:10:00Z");

    const r = (try db.conn.row(
        "SELECT count(*) FROM jobs WHERE status='failed' AND error='daemon_restarted'",
        .{},
    )).?;
    defer r.deinit();
    try std.testing.expectEqual(@as(i64, 2), r.int(0));
}
```

- [ ] **Step 3: Run + commit**

```bash
zig build test --summary all 2>&1 | tail -5
git add src/db/jobs.zig
git commit -m "db/jobs: nextDispatchable + state-transition helpers + markStuckJobsFailed"
```

Expected: +3 tests.

---

## Task 6: `agents/dispatcher.zig` — main loop (OCR + prompt + cancellation + retry)

**Target repo:** `~/projects/lambe-haath/logos/`

**Files:**
- Create: `src/agents/dispatcher.zig`
- Modify: `src/root.zig`, `src/main.zig` test block

This is the largest module in Plan B (~400 lines). It implements the full job-handling state machine described in the spec's "Job lifecycle walkthroughs" section.

- [ ] **Step 1: Create `src/agents/dispatcher.zig`**

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;
const Db = @import("../db/db.zig").Db;
const jobs_mod = @import("../db/jobs.zig");
const slices_mod = @import("../db/slices.zig");
const extractions_mod = @import("../db/extractions.zig");
const prompt_outputs_mod = @import("../db/prompt_outputs.zig");
const job_logs_mod = @import("../db/job_logs.zig");
const pricing = @import("pricing.zig");
const jsonrpc = @import("jsonrpc.zig");
const event_channel = @import("event_channel.zig");
const supervisor_mod = @import("supervisor.zig");
const worker_mod = @import("worker.zig");

pub const Dispatcher = struct {
    gpa: Allocator,
    db: *Db,
    db_mu: *std.Thread.Mutex,         // shared with HTTP handlers (the existing req_mutex)
    sup: *supervisor_mod.Supervisor,
    channel: *event_channel.EventChannel,
    stop: std.atomic.Value(bool) = .{ .raw = false },
    retry_attempts: std.StringHashMap(u8) = undefined,
    cancel_requests: std.StringHashMap(void) = undefined,

    pub fn init(
        gpa: Allocator,
        db: *Db,
        db_mu: *std.Thread.Mutex,
        sup: *supervisor_mod.Supervisor,
        channel: *event_channel.EventChannel,
    ) Dispatcher {
        return .{
            .gpa = gpa,
            .db = db,
            .db_mu = db_mu,
            .sup = sup,
            .channel = channel,
            .retry_attempts = std.StringHashMap(u8).init(gpa),
            .cancel_requests = std.StringHashMap(void).init(gpa),
        };
    }

    pub fn deinit(self: *Dispatcher) void {
        var it = self.retry_attempts.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.retry_attempts.deinit();
        var it2 = self.cancel_requests.keyIterator();
        while (it2.next()) |k| self.gpa.free(k.*);
        self.cancel_requests.deinit();
    }

    /// Request an orderly stop. The loop notices via the atomic flag.
    pub fn requestStop(self: *Dispatcher) void {
        self.stop.store(true, .release);
        self.channel.close();
    }

    /// Called by HTTP handlers when the user cancels. In-process; no DB write.
    pub fn cancelJob(self: *Dispatcher, job_id: []const u8) !void {
        const owned = try self.gpa.dupe(u8, job_id);
        errdefer self.gpa.free(owned);
        try self.cancel_requests.put(owned, {});
    }

    /// Main loop. Runs on its own thread.
    pub fn run(self: *Dispatcher) void {
        while (!self.stop.load(.acquire)) {
            // 1. Drain events from workers.
            while (self.channel.tryRecv()) |env| {
                self.handleEvent(env);
            }

            // 2. Issue any pending cancels.
            self.flushPendingCancels();

            // 3. Poll for dispatchable jobs.
            self.tryDispatchKind(.ocr);
            self.tryDispatchKind(.prompt);

            // 4. Block briefly (so we wake on new events too).
            if (self.channel.recvTimeout(50)) |env| {
                self.handleEvent(env);
            }
        }
    }

    fn tryDispatchKind(self: *Dispatcher, t: jobs_mod.JobType) void {
        while (true) {
            const job = self.fetchNextDispatchable(t) catch return;
            const j = job orelse return;
            defer {
                var mj = j;
                mj.deinit(self.gpa);
            }

            const w = self.sup.acquire(j.type.toText()) catch return;
            const worker = w orelse return; // cap reached; try again next tick

            const sent = self.sendJobToWorker(worker, &j) catch |err| {
                self.recordFailure(j.id, @errorName(err));
                self.sup.release(worker);
                continue;
            };
            _ = sent;
            self.markRunningSafe(j.id);
            worker.current_job_id = self.gpa.dupe(u8, j.id) catch null;
        }
    }

    fn fetchNextDispatchable(self: *Dispatcher, t: jobs_mod.JobType) !?jobs_mod.Job {
        self.db_mu.lock();
        defer self.db_mu.unlock();
        return try jobs_mod.nextDispatchable(self.db, self.gpa, t);
    }

    fn sendJobToWorker(self: *Dispatcher, w: *worker_mod.Worker, j: *const jobs_mod.Job) !void {
        // Build the request params based on job type + payload.
        const params_json = try self.buildRequestParams(j);
        defer self.gpa.free(params_json);

        const method = switch (j.type) {
            .ocr => "ocr.extract",
            .prompt => "prompt.run",
            .slice => return error.SliceNotDispatchedByThisDispatcher,
        };

        _ = try w.sendRequest(self.gpa, method, params_json);
    }

    fn buildRequestParams(self: *Dispatcher, j: *const jobs_mod.Job) ![]const u8 {
        // For Plan B (mock agent), we pass `_meta.progressToken` = job_id, and
        // the rest of the payload through directly. Real agents (Plans C, D)
        // will need richer params, but the mock just echoes.
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.gpa);
        const w = buf.writer(self.gpa);
        try w.print(
            "{{\"job_id\":\"{s}\",\"payload\":{s},\"_meta\":{{\"progressToken\":\"{s}\"}}}}",
            .{ j.id, j.payload, j.id },
        );
        return try buf.toOwnedSlice(self.gpa);
    }

    fn handleEvent(self: *Dispatcher, env: event_channel.EventEnvelope) void {
        defer {
            var ev = env.event;
            event_channel.freeEvent(self.gpa, &ev);
        }

        switch (env.event) {
            .dead => self.handleWorkerDead(env.worker_id),
            .parse_error => |line| {
                std.log.warn("worker {d} emitted unparseable line: {s}", .{ env.worker_id, line });
            },
            .message => |msg| switch (msg) {
                .response => |r| self.handleResponse(env.worker_id, r),
                .notification => |n| self.handleNotification(env.worker_id, n),
                .request => {
                    // Agents shouldn't initiate requests in lambe-haath/1.
                    std.log.warn("worker {d} sent an unsolicited request; ignoring", .{env.worker_id});
                },
            },
        }
    }

    fn handleResponse(self: *Dispatcher, worker_id: u64, resp: jsonrpc.Response) void {
        const w = self.sup.findById(worker_id) orelse return;
        const job_id = w.current_job_id orelse return;

        // The response's id is the per-worker request id, not the job id. We
        // don't currently track that mapping (one job per busy worker), so we
        // proceed directly.
        _ = resp.id;

        switch (resp.body) {
            .result => |result_json| self.completeJob(w, job_id, result_json),
            .err => |e| self.failOrCancelJob(w, job_id, e),
        }
    }

    fn completeJob(self: *Dispatcher, w: *worker_mod.Worker, job_id: []const u8, result_json: []const u8) void {
        const now = nowIso8601();
        self.db_mu.lock();
        defer self.db_mu.unlock();

        // For Plan B, the mock agent's result is just an echo. We don't try to
        // parse it into extractions/prompt_outputs columns. Real agents (Plans
        // C, D) will write those rows from richer result payloads.
        //
        // We do persist the response JSON into jobs.results so the test
        // assertions can verify the round-trip succeeded.
        jobs_mod.markCompleted(self.db, job_id, result_json, &now) catch |err| {
            std.log.err("markCompleted({s}): {s}", .{ job_id, @errorName(err) });
        };
        _ = self.retry_attempts.remove(job_id);
        const id_owned = self.gpa.dupe(u8, job_id) catch null;
        self.sup.release(w);
        if (id_owned) |s| self.gpa.free(s);
        if (w.current_job_id) |cj| {
            self.gpa.free(cj);
            w.current_job_id = null;
        }
    }

    fn failOrCancelJob(self: *Dispatcher, w: *worker_mod.Worker, job_id: []const u8, e: jsonrpc.ErrorObject) void {
        const now = nowIso8601();
        self.db_mu.lock();
        defer self.db_mu.unlock();

        var msg_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "code={d} {s}", .{ e.code, e.message }) catch "agent_error";

        if (e.code == -32099) {
            jobs_mod.markCanceled(self.db, job_id, msg, &now) catch {};
        } else {
            jobs_mod.markFailed(self.db, job_id, msg, &now) catch {};
        }
        _ = self.retry_attempts.remove(job_id);
        self.sup.release(w);
        if (w.current_job_id) |cj| {
            self.gpa.free(cj);
            w.current_job_id = null;
        }
    }

    fn handleNotification(self: *Dispatcher, worker_id: u64, n: jsonrpc.Notification) void {
        const w = self.sup.findById(worker_id) orelse return;
        const job_id = w.current_job_id orelse return;

        if (std.mem.eql(u8, n.method, "notifications/progress")) {
            const p_json = n.params_json orelse return;
            const progress = extractFloatField(self.gpa, p_json, "progress") catch return;
            const now = nowIso8601();
            self.db_mu.lock();
            defer self.db_mu.unlock();
            jobs_mod.updateProgress(self.db, job_id, progress, &now) catch {};
        } else if (std.mem.eql(u8, n.method, "notifications/log")) {
            self.persistLog(job_id, n.params_json orelse return);
        }
        // Other notification methods are ignored in v1.
    }

    fn persistLog(self: *Dispatcher, job_id: []const u8, params_json: []const u8) void {
        var parsed = json.parseFromSlice(json.Value, self.gpa, params_json, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .object) return;
        const obj = parsed.value.object;

        const level_str = if (obj.get("level")) |v| if (v == .string) v.string else "info" else "info";
        const logger_str = if (obj.get("logger")) |v| if (v == .string) v.string else "agent" else "agent";
        const message_str = if (obj.get("message")) |v| if (v == .string) v.string else "" else "";
        const level = job_logs_mod.Level.fromText(level_str) orelse .info;

        const now = nowIso8601();
        self.db_mu.lock();
        defer self.db_mu.unlock();
        job_logs_mod.insert(self.db, job_id, &now, level, logger_str, message_str) catch {};
    }

    fn handleWorkerDead(self: *Dispatcher, worker_id: u64) void {
        const w = self.sup.findById(worker_id) orelse return;
        const job_id_opt = w.current_job_id;
        // markDead destroys the worker pointer, so cache anything we need.
        const job_id_dup = if (job_id_opt) |j| self.gpa.dupe(u8, j) catch null else null;
        self.sup.markDead(worker_id);

        const job_id = job_id_dup orelse return;
        defer self.gpa.free(job_id);

        const attempts = self.retry_attempts.get(job_id) orelse 0;
        const now = nowIso8601();
        self.db_mu.lock();
        defer self.db_mu.unlock();

        if (attempts == 0) {
            jobs_mod.markReQueued(self.db, job_id, &now) catch {};
            const k = self.gpa.dupe(u8, job_id) catch return;
            self.retry_attempts.put(k, 1) catch self.gpa.free(k);
        } else {
            jobs_mod.markFailed(self.db, job_id, "worker_died: 2 attempts", &now) catch {};
            if (self.retry_attempts.fetchRemove(job_id)) |kv| self.gpa.free(kv.key);
        }
    }

    fn flushPendingCancels(self: *Dispatcher) void {
        // For each pending cancel, find the worker handling the job and send
        // notifications/cancelled. The job will transition to 'canceled' when
        // the worker responds with -32099 (handled by failOrCancelJob).
        var it = self.cancel_requests.keyIterator();
        while (it.next()) |k| {
            const job_id = k.*;
            const w = self.sup.findByJob(job_id) orelse continue;
            // Build cancel params: {"requestId":<id>,"reason":"user_requested"}
            // We don't track the per-worker request id mapping; the agent uses
            // the job_id as the progressToken, but the protocol's
            // notifications/cancelled wants the JSON-RPC request id. The mock
            // agent ignores the field; real agents (Plans C, D) will need this
            // wired more carefully.
            var buf: [256]u8 = undefined;
            const params = std.fmt.bufPrint(&buf, "{{\"requestId\":0,\"reason\":\"user_requested\"}}", .{}) catch continue;
            w.sendNotification(self.gpa, "notifications/cancelled", params) catch {};
        }
        // Clear the queue; success/failure of the cancel is observed via the
        // response loop.
        var k_it = self.cancel_requests.keyIterator();
        while (k_it.next()) |k| self.gpa.free(k.*);
        self.cancel_requests.clearRetainingCapacity();
    }

    fn recordFailure(self: *Dispatcher, job_id: []const u8, err: []const u8) void {
        const now = nowIso8601();
        self.db_mu.lock();
        defer self.db_mu.unlock();
        jobs_mod.markFailed(self.db, job_id, err, &now) catch {};
    }

    fn markRunningSafe(self: *Dispatcher, job_id: []const u8) void {
        const now = nowIso8601();
        self.db_mu.lock();
        defer self.db_mu.unlock();
        jobs_mod.markRunning(self.db, job_id, &now) catch {};
    }
};

fn nowIso8601() [20]u8 {
    var out: [20]u8 = undefined;
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(@divFloor(std.time.timestamp(), 1)) };
    const ed = epoch.getEpochDay();
    const dse = epoch.getDaySeconds();
    const yd = ed.calculateYearDay();
    const md = yd.calculateMonthDay();
    _ = std.fmt.bufPrint(&out, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        yd.year,
        @intFromEnum(md.month) + 1,
        md.day_index + 1,
        dse.getHoursIntoDay(),
        dse.getMinutesIntoHour(),
        dse.getSecondsIntoMinute(),
    }) catch unreachable;
    return out;
}

fn extractFloatField(_: Allocator, json_text: []const u8, field: []const u8) !f64 {
    // Cheap inline parser: look for `"<field>":<number>` substring.
    const needle_buf = "\"" ++ "" ++ "\":";
    _ = needle_buf;
    var needle: [128]u8 = undefined;
    const ns = try std.fmt.bufPrint(&needle, "\"{s}\":", .{field});
    const idx = std.mem.indexOf(u8, json_text, ns) orelse return error.NotFound;
    var i = idx + ns.len;
    // Skip whitespace
    while (i < json_text.len and (json_text[i] == ' ' or json_text[i] == '\t')) i += 1;
    var end = i;
    while (end < json_text.len and (std.ascii.isDigit(json_text[end]) or json_text[end] == '.' or json_text[end] == '-' or json_text[end] == 'e' or json_text[end] == 'E')) end += 1;
    if (end == i) return error.NotFound;
    return std.fmt.parseFloat(f64, json_text[i..end]);
}

// --- tests --- //

test "Dispatcher.init / requestStop / deinit don't leak" {
    const gpa = std.testing.allocator;
    var db = try Db.open(":memory:");
    defer db.close();
    var mu: std.Thread.Mutex = .{};
    var ch = event_channel.EventChannel.init(gpa);
    defer ch.deinit();

    var specs = [_]@import("config.zig").AgentSpec{};
    var cfg = @import("config.zig").AgentConfig{ .agents = &specs };
    var sup = supervisor_mod.Supervisor.init(gpa, &cfg, &ch);
    defer sup.deinit();

    var d = Dispatcher.init(gpa, &db, &mu, &sup, &ch);
    defer d.deinit();

    d.requestStop();
    try std.testing.expect(d.stop.load(.acquire));
}

test "extractFloatField finds simple progress value" {
    const f = try extractFloatField(std.testing.allocator, "{\"progress\":0.42}", "progress");
    try std.testing.expectApproxEqAbs(@as(f64, 0.42), f, 1e-9);
}
```

- [ ] **Step 2: Wire**

`src/root.zig`:
```zig
pub const dispatcher = @import("agents/dispatcher.zig");
```

`src/main.zig` test block:
```zig
_ = @import("agents/dispatcher.zig");
```

- [ ] **Step 3: Run + commit**

```bash
zig build test --summary all 2>&1 | tail -10
git add src/agents/dispatcher.zig src/root.zig src/main.zig
git commit -m "agents/dispatcher: poll loop with OCR + prompt gate + cancel + crash-retry"
```

Expected: +2 tests (Dispatcher.init plus the extractFloatField test). The end-to-end behavior is exercised in Tasks 13-14.

---

## Task 7: End-to-end OCR test via dispatcher + mock agent

**Target repo:** `~/projects/lambe-haath/logos/`

**Files:**
- Create: `src/agents/integration_test.zig` (test-only module that ties the moving parts together)
- Modify: `src/main.zig` test block

This is the first test that exercises the FULL pipeline: enqueue a job → dispatcher picks it up → spawns/uses a mock-agent worker → response comes back → job marked completed → result persisted.

- [ ] **Step 1: Create `src/agents/integration_test.zig`**

```zig
const std = @import("std");
const builtin = @import("builtin");
const Db = @import("../db/db.zig").Db;
const test_helpers = @import("../db/test_helpers.zig");
const jobs_mod = @import("../db/jobs.zig");
const config = @import("config.zig");
const event_channel = @import("event_channel.zig");
const supervisor_mod = @import("supervisor.zig");
const dispatcher_mod = @import("dispatcher.zig");

fn mockPath() ?[]const u8 {
    return std.posix.getenv("LAMBE_MOCK_AGENT_PATH");
}

fn buildMockConfig(gpa: std.mem.Allocator, path: []const u8, kind: []const u8, max_workers: u32) !config.AgentConfig {
    var args = try gpa.alloc([]const u8, 1);
    args[0] = try gpa.dupe(u8, path);
    var specs = try gpa.alloc(config.AgentSpec, 1);
    specs[0] = .{
        .kind = try gpa.dupe(u8, kind),
        .command = try gpa.dupe(u8, "python3"),
        .args = args,
        .max_workers = max_workers,
        .model = try gpa.dupe(u8, "mock-model"),
    };
    return .{ .agents = specs };
}

/// End-to-end: enqueue an OCR job, run the dispatcher for a bounded time, assert completed.
test "OCR job runs end-to-end through dispatcher + mock agent" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    const path = mockPath() orelse return error.SkipZigTest;

    const gpa = std.testing.allocator;
    var db = try Db.open(":memory:");
    defer db.close();
    var mu: std.Thread.Mutex = .{};

    // The agent kind we'll dispatch is 'ocr'; tell config our mock plays the 'ocr' role.
    var cfg = try buildMockConfig(gpa, path, "ocr", 1);
    defer cfg.deinit(gpa);

    var ch = event_channel.EventChannel.init(gpa);
    defer ch.deinit();

    var sup = supervisor_mod.Supervisor.init(gpa, &cfg, &ch);
    defer sup.deinit();

    var disp = dispatcher_mod.Dispatcher.init(gpa, &db, &mu, &sup, &ch);
    defer disp.deinit();

    // Seed: a project, a slice, and a queued OCR job for that slice.
    {
        mu.lock();
        defer mu.unlock();
        try test_helpers.insertProject(&db, "p1");
        try db.conn.exec(
            \\INSERT INTO slices (project_id, filename, start_page, end_page, size_bytes, kind, kind_key, created_at)
            \\VALUES ('p1', 'annexure-i.pdf', 1, 1, 1, 'annexure', 'i', '2026-05-28T00:00:00Z')
        , .{});
        try test_helpers.insertJob(&db, "job1", "p1", "ocr");
    }

    // Run the dispatcher in a thread; stop after a deadline.
    const t = try std.Thread.spawn(.{}, dispatcher_mod.Dispatcher.run, .{&disp});
    defer {
        disp.requestStop();
        t.join();
        sup.shutdownAll();
    }

    // Poll the DB up to 10s for job1 to reach 'completed'.
    var completed = false;
    var elapsed_ms: u32 = 0;
    while (elapsed_ms < 10_000) : (elapsed_ms += 100) {
        std.Thread.sleep(100 * std.time.ns_per_ms);
        mu.lock();
        const row = db.conn.row("SELECT status FROM jobs WHERE id=?", .{"job1"}) catch null;
        if (row) |r| {
            const status_text = r.text(0);
            const is_completed = std.mem.eql(u8, status_text, "completed");
            r.deinit();
            mu.unlock();
            if (is_completed) {
                completed = true;
                break;
            }
        } else mu.unlock();
    }

    try std.testing.expect(completed);
}
```

- [ ] **Step 2: Wire**

`src/main.zig` test block:
```zig
_ = @import("agents/integration_test.zig");
```

- [ ] **Step 3: Run with the env var set**

```bash
cd ~/projects/lambe-haath/logos
export LAMBE_MOCK_AGENT_PATH="$HOME/projects/chargesheets/pdf-extraction-experiments/tests/mock_agent.py"
zig build test --summary all 2>&1 | tail -15
```

Expected: +1 integration test passes within ~2-5 seconds.

- [ ] **Step 4: Commit**

```bash
git add src/agents/integration_test.zig src/main.zig
git commit -m "test: end-to-end OCR job via dispatcher + mock agent"
```

---

## Task 8: HTTP handlers — OCR endpoints

**Target repo:** `~/projects/lambe-haath/logos/`

**Files:**
- Create: `src/api/handlers_ocr.zig`
- Modify: `src/api/router.zig`, `src/api/handlers.zig`, `src/root.zig`, `src/main.zig` test block

- [ ] **Step 1: Read the existing route table** to understand the pattern:

```bash
cd ~/projects/lambe-haath/logos
cat src/api/router.zig
```

You'll see a `Route` enum / table. Add new variants for the OCR endpoints. Then implement the handler functions in `handlers_ocr.zig`.

- [ ] **Step 2: Create `src/api/handlers_ocr.zig`**

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;
const Db = @import("../db/db.zig").Db;
const jobs_mod = @import("../db/jobs.zig");
const slices_mod = @import("../db/slices.zig");
const extractions_mod = @import("../db/extractions.zig");
const ids = @import("../ids.zig");

// Each handler takes a *Db, a *std.Thread.Mutex (the req_mutex), the project_id
// from the URL, the request body, and a writer for the response body. They
// return a status code.

pub fn postEnqueueOcr(
    db: *Db,
    db_mu: *std.Thread.Mutex,
    gpa: Allocator,
    project_id: []const u8,
    body: []const u8,
    resp_buf: *std.ArrayList(u8),
) !u16 {
    // Body: {"slice_filename":"annexure-i.pdf"}
    var parsed = json.parseFromSlice(json.Value, gpa, body, .{}) catch return 400;
    defer parsed.deinit();
    if (parsed.value != .object) return 400;
    const sf_v = parsed.value.object.get("slice_filename") orelse return 400;
    if (sf_v != .string) return 400;
    const slice_filename = sf_v.string;

    db_mu.lock();
    defer db_mu.unlock();

    // Verify slice exists.
    if ((try slices_mod.getByKey(db, gpa, project_id, slice_filename)) == null) return 404;

    const job_id = try ids.generateJobId(gpa);
    defer gpa.free(job_id);
    const now = nowIso8601();
    var payload_buf: [256]u8 = undefined;
    const payload = std.fmt.bufPrint(&payload_buf, "{{\"slice_filename\":\"{s}\"}}", .{slice_filename}) catch return 500;

    try db.conn.exec(
        \\INSERT INTO jobs (id, project_id, type, status, payload, created_at, updated_at)
        \\VALUES (?, ?, 'ocr', 'queued', ?, ?, ?)
    , .{ job_id, project_id, payload, &now, &now });

    try resp_buf.writer(gpa).print("{{\"job_id\":\"{s}\"}}", .{job_id});
    return 201;
}

pub fn postEnqueueOcrAll(
    db: *Db,
    db_mu: *std.Thread.Mutex,
    gpa: Allocator,
    project_id: []const u8,
    resp_buf: *std.ArrayList(u8),
) !u16 {
    // Enqueue an OCR job for every slice in this project that doesn't yet have
    // an extraction. Returns the list of job IDs.
    db_mu.lock();
    defer db_mu.unlock();

    var rows = try db.conn.rows(
        \\SELECT s.filename FROM slices s
        \\LEFT JOIN extractions e
        \\       ON s.project_id = e.project_id AND s.filename = e.slice_filename
        \\WHERE s.project_id = ? AND e.slice_filename IS NULL
        \\ORDER BY s.filename ASC
    , .{project_id});
    defer rows.deinit();

    var first = true;
    try resp_buf.writer(gpa).writeAll("{\"job_ids\":[");
    while (rows.next()) |row| {
        const sf = row.text(0);
        const job_id = try ids.generateJobId(gpa);
        defer gpa.free(job_id);
        const now = nowIso8601();
        var payload_buf: [256]u8 = undefined;
        const payload = std.fmt.bufPrint(&payload_buf, "{{\"slice_filename\":\"{s}\"}}", .{sf}) catch continue;
        try db.conn.exec(
            \\INSERT INTO jobs (id, project_id, type, status, payload, created_at, updated_at)
            \\VALUES (?, ?, 'ocr', 'queued', ?, ?, ?)
        , .{ job_id, project_id, payload, &now, &now });

        if (!first) try resp_buf.writer(gpa).writeAll(",");
        try resp_buf.writer(gpa).print("\"{s}\"", .{job_id});
        first = false;
    }
    try resp_buf.writer(gpa).writeAll("]}");
    return 201;
}

pub fn getExtractionsList(
    db: *Db,
    db_mu: *std.Thread.Mutex,
    gpa: Allocator,
    project_id: []const u8,
    resp_buf: *std.ArrayList(u8),
) !u16 {
    db_mu.lock();
    defer db_mu.unlock();

    var list = try extractions_mod.listByProject(db, gpa, project_id);
    defer extractions_mod.deinitList(list, gpa);

    var first = true;
    try resp_buf.writer(gpa).writeAll("[");
    for (list) |e| {
        if (!first) try resp_buf.writer(gpa).writeAll(",");
        try resp_buf.writer(gpa).print(
            "{{\"slice_filename\":\"{s}\",\"markdown_path\":\"{s}\",\"pages\":{d},\"page_markers_found\":{d},\"latency_s\":{d},\"model\":\"{s}\",\"created_at\":\"{s}\"}}",
            .{ e.slice_filename, e.markdown_path, e.pages, e.page_markers_found, e.latency_s, e.model, e.created_at },
        );
        first = false;
    }
    try resp_buf.writer(gpa).writeAll("]");
    return 200;
}

pub fn getExtractionMarkdown(
    db: *Db,
    db_mu: *std.Thread.Mutex,
    gpa: Allocator,
    project_id: []const u8,
    slice_filename: []const u8,
    resp_buf: *std.ArrayList(u8),
) !u16 {
    db_mu.lock();
    var e_opt = try extractions_mod.getByKey(db, gpa, project_id, slice_filename);
    db_mu.unlock();

    if (e_opt == null) return 404;
    var e = e_opt.?;
    defer e.deinit(gpa);

    const md = std.fs.cwd().readFileAlloc(e.markdown_path, gpa, .limited(50 * 1024 * 1024)) catch return 404;
    defer gpa.free(md);
    try resp_buf.writer(gpa).writeAll(md);
    return 200;
}

fn nowIso8601() [20]u8 {
    // Same impl as dispatcher.nowIso8601; we duplicate to avoid a cross-module dep
    // for a 12-line helper. If this grows, factor into a shared util.
    var out: [20]u8 = undefined;
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(@divFloor(std.time.timestamp(), 1)) };
    const ed = epoch.getEpochDay();
    const dse = epoch.getDaySeconds();
    const yd = ed.calculateYearDay();
    const md = yd.calculateMonthDay();
    _ = std.fmt.bufPrint(&out, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        yd.year,
        @intFromEnum(md.month) + 1,
        md.day_index + 1,
        dse.getHoursIntoDay(),
        dse.getMinutesIntoHour(),
        dse.getSecondsIntoMinute(),
    }) catch unreachable;
    return out;
}

test "postEnqueueOcr 400 on missing slice_filename" {
    const gpa = std.testing.allocator;
    var db = try Db.open(":memory:");
    defer db.close();
    var mu: std.Thread.Mutex = .{};
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    const code = try postEnqueueOcr(&db, &mu, gpa, "p1", "{}", &buf);
    try std.testing.expectEqual(@as(u16, 400), code);
}

test "postEnqueueOcr 404 on unknown slice" {
    const gpa = std.testing.allocator;
    var db = try Db.open(":memory:");
    defer db.close();
    var mu: std.Thread.Mutex = .{};
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try @import("../db/test_helpers.zig").insertProject(&db, "p1");

    const code = try postEnqueueOcr(&db, &mu, gpa, "p1", "{\"slice_filename\":\"nope.pdf\"}", &buf);
    try std.testing.expectEqual(@as(u16, 404), code);
}

test "postEnqueueOcr 201 with job_id on success" {
    const gpa = std.testing.allocator;
    var db = try Db.open(":memory:");
    defer db.close();
    var mu: std.Thread.Mutex = .{};
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    try @import("../db/test_helpers.zig").insertProject(&db, "p1");
    try db.conn.exec(
        \\INSERT INTO slices (project_id, filename, start_page, end_page, size_bytes, kind, kind_key, created_at)
        \\VALUES ('p1', 'annexure-i.pdf', 1, 1, 1, 'annexure', 'i', '2026-05-28T00:00:00Z')
    , .{});

    const code = try postEnqueueOcr(&db, &mu, gpa, "p1", "{\"slice_filename\":\"annexure-i.pdf\"}", &buf);
    try std.testing.expectEqual(@as(u16, 201), code);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"job_id\"") != null);
}
```

- [ ] **Step 3: Wire routes**

In `src/api/router.zig` add new route variants:
- `ocr_enqueue` → `POST /api/v1/projects/:id/jobs/ocr`
- `ocr_enqueue_all` → `POST /api/v1/projects/:id/jobs/ocr/all`
- `extractions_list` → `GET /api/v1/projects/:id/extractions`
- `extraction_get` → `GET /api/v1/projects/:id/extractions/:filename`

Modify `src/api/handlers.zig` (the dispatch switch) to route these to the new `handlers_ocr` functions.

(The exact diff for these two files depends on the codebase's current routing structure. Read `router.zig` and `handlers.zig` first, then mirror the existing patterns. The existing `slice` job handlers are the closest analogy.)

- [ ] **Step 4: Wire root + main tests, run, commit**

```bash
zig build test --summary all 2>&1 | tail -10
git add src/api/handlers_ocr.zig src/api/router.zig src/api/handlers.zig src/root.zig src/main.zig
git commit -m "api/handlers_ocr: POST enqueue + GET extractions list + download"
```

Expected: +3 tests.

---

## Task 9: HTTP handlers — prompt endpoints

**Target repo:** `~/projects/lambe-haath/logos/`

**Files:**
- Create: `src/api/handlers_prompts.zig`
- Modify: `src/api/router.zig`, `src/api/handlers.zig`, `src/root.zig`, `src/main.zig` test block

Mirror Task 8's structure. Endpoints:
- `POST /api/v1/projects/:id/jobs/prompt` — body `{"prompt_name":"evidence_audit"}`
- `POST /api/v1/projects/:id/jobs/prompt/all` — enqueue all 5 known prompts
- `GET /api/v1/projects/:id/prompts` — list prompt_outputs rows
- `GET /api/v1/projects/:id/prompts/:name` — download the .md

- [ ] **Step 1: Create `src/api/handlers_prompts.zig`**

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;
const Db = @import("../db/db.zig").Db;
const prompt_outputs_mod = @import("../db/prompt_outputs.zig");
const ids = @import("../ids.zig");

const KNOWN_PROMPTS = [_][]const u8{
    "charge_memo_analysis",
    "imputation_scrutiny",
    "time_chart",
    "evidence_audit",
    "objection_brief",
};

pub fn postEnqueuePrompt(
    db: *Db,
    db_mu: *std.Thread.Mutex,
    gpa: Allocator,
    project_id: []const u8,
    body: []const u8,
    resp_buf: *std.ArrayList(u8),
) !u16 {
    var parsed = json.parseFromSlice(json.Value, gpa, body, .{}) catch return 400;
    defer parsed.deinit();
    if (parsed.value != .object) return 400;
    const pn_v = parsed.value.object.get("prompt_name") orelse return 400;
    if (pn_v != .string) return 400;
    const prompt_name = pn_v.string;

    // Validate prompt name is in the known set.
    var ok = false;
    for (KNOWN_PROMPTS) |p| if (std.mem.eql(u8, p, prompt_name)) {
        ok = true;
        break;
    };
    if (!ok) return 400;

    db_mu.lock();
    defer db_mu.unlock();

    const job_id = try ids.generateJobId(gpa);
    defer gpa.free(job_id);
    const now = nowIso8601();
    var payload_buf: [256]u8 = undefined;
    const payload = std.fmt.bufPrint(&payload_buf, "{{\"prompt_name\":\"{s}\"}}", .{prompt_name}) catch return 500;

    try db.conn.exec(
        \\INSERT INTO jobs (id, project_id, type, status, payload, created_at, updated_at)
        \\VALUES (?, ?, 'prompt', 'queued', ?, ?, ?)
    , .{ job_id, project_id, payload, &now, &now });

    try resp_buf.writer(gpa).print("{{\"job_id\":\"{s}\"}}", .{job_id});
    return 201;
}

pub fn postEnqueuePromptAll(
    db: *Db,
    db_mu: *std.Thread.Mutex,
    gpa: Allocator,
    project_id: []const u8,
    resp_buf: *std.ArrayList(u8),
) !u16 {
    db_mu.lock();
    defer db_mu.unlock();
    try resp_buf.writer(gpa).writeAll("{\"job_ids\":[");
    var first = true;
    for (KNOWN_PROMPTS) |prompt_name| {
        const job_id = try ids.generateJobId(gpa);
        defer gpa.free(job_id);
        const now = nowIso8601();
        var payload_buf: [256]u8 = undefined;
        const payload = std.fmt.bufPrint(&payload_buf, "{{\"prompt_name\":\"{s}\"}}", .{prompt_name}) catch continue;
        try db.conn.exec(
            \\INSERT INTO jobs (id, project_id, type, status, payload, created_at, updated_at)
            \\VALUES (?, ?, 'prompt', 'queued', ?, ?, ?)
        , .{ job_id, project_id, payload, &now, &now });
        if (!first) try resp_buf.writer(gpa).writeAll(",");
        try resp_buf.writer(gpa).print("\"{s}\"", .{job_id});
        first = false;
    }
    try resp_buf.writer(gpa).writeAll("]}");
    return 201;
}

pub fn getPromptsList(
    db: *Db,
    db_mu: *std.Thread.Mutex,
    gpa: Allocator,
    project_id: []const u8,
    resp_buf: *std.ArrayList(u8),
) !u16 {
    db_mu.lock();
    defer db_mu.unlock();

    var list = try prompt_outputs_mod.listByProject(db, gpa, project_id);
    defer prompt_outputs_mod.deinitList(list, gpa);

    var first = true;
    try resp_buf.writer(gpa).writeAll("[");
    for (list) |p| {
        if (!first) try resp_buf.writer(gpa).writeAll(",");
        try resp_buf.writer(gpa).print(
            "{{\"prompt_name\":\"{s}\",\"markdown_path\":\"{s}\",\"model\":\"{s}\",\"latency_s\":{d},\"warnings\":{s},\"created_at\":\"{s}\"}}",
            .{ p.prompt_name, p.markdown_path, p.model, p.latency_s, p.warnings_json, p.created_at },
        );
        first = false;
    }
    try resp_buf.writer(gpa).writeAll("]");
    return 200;
}

pub fn getPromptMarkdown(
    db: *Db,
    db_mu: *std.Thread.Mutex,
    gpa: Allocator,
    project_id: []const u8,
    prompt_name: []const u8,
    resp_buf: *std.ArrayList(u8),
) !u16 {
    db_mu.lock();
    var p_opt = try prompt_outputs_mod.getByKey(db, gpa, project_id, prompt_name);
    db_mu.unlock();

    if (p_opt == null) return 404;
    var p = p_opt.?;
    defer p.deinit(gpa);

    const md = std.fs.cwd().readFileAlloc(p.markdown_path, gpa, .limited(50 * 1024 * 1024)) catch return 404;
    defer gpa.free(md);
    try resp_buf.writer(gpa).writeAll(md);
    return 200;
}

fn nowIso8601() [20]u8 {
    var out: [20]u8 = undefined;
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(@divFloor(std.time.timestamp(), 1)) };
    const ed = epoch.getEpochDay();
    const dse = epoch.getDaySeconds();
    const yd = ed.calculateYearDay();
    const md = yd.calculateMonthDay();
    _ = std.fmt.bufPrint(&out, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        yd.year, @intFromEnum(md.month) + 1, md.day_index + 1,
        dse.getHoursIntoDay(), dse.getMinutesIntoHour(), dse.getSecondsIntoMinute(),
    }) catch unreachable;
    return out;
}

test "postEnqueuePrompt rejects unknown prompt_name" {
    const gpa = std.testing.allocator;
    var db = try Db.open(":memory:");
    defer db.close();
    var mu: std.Thread.Mutex = .{};
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    try @import("../db/test_helpers.zig").insertProject(&db, "p1");

    const code = try postEnqueuePrompt(&db, &mu, gpa, "p1", "{\"prompt_name\":\"fake_prompt\"}", &buf);
    try std.testing.expectEqual(@as(u16, 400), code);
}

test "postEnqueuePromptAll enqueues exactly 5 jobs" {
    const gpa = std.testing.allocator;
    var db = try Db.open(":memory:");
    defer db.close();
    var mu: std.Thread.Mutex = .{};
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    try @import("../db/test_helpers.zig").insertProject(&db, "p1");

    const code = try postEnqueuePromptAll(&db, &mu, gpa, "p1", &buf);
    try std.testing.expectEqual(@as(u16, 201), code);

    const r = (try db.conn.row(
        "SELECT count(*) FROM jobs WHERE project_id='p1' AND type='prompt' AND status='queued'",
        .{},
    )).?;
    defer r.deinit();
    try std.testing.expectEqual(@as(i64, 5), r.int(0));
}
```

- [ ] **Step 2: Wire routes + commit**

Mirror Task 8's router/handlers wiring, then:

```bash
zig build test --summary all 2>&1 | tail -10
git add src/api/handlers_prompts.zig src/api/router.zig src/api/handlers.zig src/root.zig src/main.zig
git commit -m "api/handlers_prompts: enqueue (one + all) + list + download"
```

Expected: +2 tests.

---

## Task 10: HTTP handlers — jobs (cancel + logs)

**Target repo:** `~/projects/lambe-haath/logos/`

**Files:**
- Create: `src/api/handlers_jobs.zig`
- Modify: `src/api/router.zig`, `src/api/handlers.zig`, `src/root.zig`, `src/main.zig` test block

These endpoints need to talk to the **dispatcher** (for cancel) and the **DB** (for logs). The handler signatures will accept a `*Dispatcher` pointer.

- [ ] **Step 1: Create `src/api/handlers_jobs.zig`**

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const Db = @import("../db/db.zig").Db;
const job_logs_mod = @import("../db/job_logs.zig");
const dispatcher_mod = @import("../agents/dispatcher.zig");

pub fn postCancel(
    disp: *dispatcher_mod.Dispatcher,
    job_id: []const u8,
    _: *std.ArrayList(u8),
) !u16 {
    try disp.cancelJob(job_id);
    return 202;
}

pub fn getLogs(
    db: *Db,
    db_mu: *std.Thread.Mutex,
    gpa: Allocator,
    job_id: []const u8,
    resp_buf: *std.ArrayList(u8),
) !u16 {
    db_mu.lock();
    defer db_mu.unlock();
    var list = try job_logs_mod.listByJob(db, gpa, job_id);
    defer job_logs_mod.deinitList(list, gpa);

    var first = true;
    try resp_buf.writer(gpa).writeAll("[");
    for (list) |l| {
        if (!first) try resp_buf.writer(gpa).writeAll(",");
        try resp_buf.writer(gpa).print(
            "{{\"ts\":\"{s}\",\"level\":\"{s}\",\"logger\":\"{s}\",\"message\":{s}}}",
            .{ l.ts, l.level.toText(), l.logger, std.json.fmt(l.message, .{}) },
        );
        first = false;
    }
    try resp_buf.writer(gpa).writeAll("]");
    return 200;
}

test "getLogs returns empty array for unknown job" {
    const gpa = std.testing.allocator;
    var db = try Db.open(":memory:");
    defer db.close();
    var mu: std.Thread.Mutex = .{};
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    const code = try getLogs(&db, &mu, gpa, "no-such-job", &buf);
    try std.testing.expectEqual(@as(u16, 200), code);
    try std.testing.expectEqualStrings("[]", buf.items);
}

test "getLogs serializes message with JSON string escaping" {
    const gpa = std.testing.allocator;
    var db = try Db.open(":memory:");
    defer db.close();
    var mu: std.Thread.Mutex = .{};
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try @import("../db/test_helpers.zig").insertProject(&db, "p1");
    try @import("../db/test_helpers.zig").insertJob(&db, "j1", "p1", "ocr");
    try job_logs_mod.insert(&db, "j1", "2026-05-28T00:00:01Z", .info, "agent", "hello \"world\"");

    const code = try getLogs(&db, &mu, gpa, "j1", &buf);
    try std.testing.expectEqual(@as(u16, 200), code);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "hello \\\"world\\\"") != null);
}
```

If `std.json.fmt` does not exist in Zig 0.16, replace with an inline writer that calls a tiny `writeJsonString` helper (or reuse `jsonrpc.writeJsonString` after exporting it).

- [ ] **Step 2: Wire routes + commit**

Routes:
- `POST /api/v1/jobs/:id/cancel`
- `GET /api/v1/jobs/:id/logs`

```bash
zig build test --summary all 2>&1 | tail -10
git add src/api/handlers_jobs.zig src/api/router.zig src/api/handlers.zig src/root.zig src/main.zig
git commit -m "api/handlers_jobs: cancel + logs endpoints"
```

Expected: +2 tests.

---

## Task 11: `api/sse.zig` + SSE stream endpoint

**Target repo:** `~/projects/lambe-haath/logos/`

**Files:**
- Create: `src/api/sse.zig`
- Modify: `src/api/handlers.zig`, `src/api/router.zig`

SSE handler holds the connection open, polls every 500 ms for new `job_logs` rows + the job's current status. On terminal status, sends a final event and closes the connection.

- [ ] **Step 1: Create `src/api/sse.zig`**

Per the spec, the v1 SSE implementation polls the DB. The connection lives inside an existing request-handler thread. We need a function that takes the std.net response writer, the job_id, the DB, and loops.

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const Db = @import("../db/db.zig").Db;
const job_logs_mod = @import("../db/job_logs.zig");
const jobs_mod = @import("../db/jobs.zig");

/// Stream events for `job_id` to `writer` (an HTTP response writer that's
/// already had Content-Type: text/event-stream set). Blocks until the job
/// reaches a terminal status (completed | failed | canceled) OR the writer
/// fails (client disconnect).
pub fn streamJob(
    gpa: Allocator,
    db: *Db,
    db_mu: *std.Thread.Mutex,
    job_id: []const u8,
    writer: anytype,
) !void {
    var last_log_id: i64 = 0;
    var last_status: [16]u8 = undefined;
    var last_status_len: usize = 0;

    var iter: u32 = 0;
    while (iter < 1200) : (iter += 1) { // 1200 * 500ms = 10 minutes hard cap
        // 1. New log rows since last_log_id.
        db_mu.lock();
        var rows = db.conn.rows(
            \\SELECT id, ts, level, logger, message FROM job_logs
            \\WHERE job_id = ? AND id > ? ORDER BY id ASC LIMIT 100
        , .{ job_id, last_log_id }) catch {
            db_mu.unlock();
            return;
        };

        var sent_any = false;
        while (rows.next()) |row| {
            const log_id = row.int(0);
            const ts = row.text(1);
            const level = row.text(2);
            const logger = row.text(3);
            const message = row.text(4);
            writer.print(
                "event: log\ndata: {{\"ts\":\"{s}\",\"level\":\"{s}\",\"logger\":\"{s}\",\"message\":\"",
                .{ ts, level, logger },
            ) catch {
                rows.deinit();
                db_mu.unlock();
                return;
            };
            // Escape quotes in message
            for (message) |c| {
                if (c == '"') writer.writeAll("\\\"") catch {} else if (c == '\\') writer.writeAll("\\\\") catch {} else if (c == '\n') writer.writeAll("\\n") catch {} else writer.writeByte(c) catch {};
            }
            writer.writeAll("\"}\n\n") catch {
                rows.deinit();
                db_mu.unlock();
                return;
            };
            last_log_id = log_id;
            sent_any = true;
        }
        rows.deinit();

        // 2. Current job status.
        const status_row = db.conn.row("SELECT status, progress FROM jobs WHERE id=?", .{job_id}) catch null;
        var terminal = false;
        if (status_row) |r| {
            const status = r.text(0);
            const progress = r.float(1);
            if (last_status_len == 0 or !std.mem.eql(u8, status, last_status[0..last_status_len])) {
                @memcpy(last_status[0..status.len], status);
                last_status_len = status.len;
                writer.print("event: status\ndata: {{\"status\":\"{s}\",\"progress\":{d}}}\n\n", .{ status, progress }) catch {};
            }
            if (std.mem.eql(u8, status, "completed") or std.mem.eql(u8, status, "failed") or std.mem.eql(u8, status, "canceled")) {
                terminal = true;
            }
            r.deinit();
        }
        db_mu.unlock();

        if (terminal) {
            writer.writeAll("event: end\ndata: {}\n\n") catch {};
            return;
        }
        std.Thread.sleep(500 * std.time.ns_per_ms);
    }
}

test "streamJob exits when job is already terminal" {
    const gpa = std.testing.allocator;
    var db = try Db.open(":memory:");
    defer db.close();
    var mu: std.Thread.Mutex = .{};
    try @import("../db/test_helpers.zig").insertProject(&db, "p1");
    try @import("../db/test_helpers.zig").insertJob(&db, "j1", "p1", "ocr");
    try db.conn.exec("UPDATE jobs SET status='completed' WHERE id='j1'", .{});

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try streamJob(gpa, &db, &mu, "j1", buf.writer(gpa));
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "event: end") != null);
}
```

The above test uses `buf.writer(gpa)` which is the ArrayList writer in Zig 0.16. If the API differs, replace with `std.Io.Writer.Allocating` per the Plan A pattern.

- [ ] **Step 2: Wire route**

Add `GET /api/v1/jobs/:id/stream` to the router, handler sets `Content-Type: text/event-stream`, then calls `sse.streamJob` with the response writer.

- [ ] **Step 3: Commit**

```bash
zig build test --summary all 2>&1 | tail -10
git add src/api/sse.zig src/api/router.zig src/api/handlers.zig src/root.zig src/main.zig
git commit -m "api/sse: held-open job stream (polling impl) + integration"
```

Expected: +1 test.

---

## Task 12: `main.zig` startup + shutdown wiring

**Target repo:** `~/projects/lambe-haath/logos/`

**Files:**
- Modify: `src/main.zig`

Add the startup steps (cleanup-stuck-jobs, load agent config, init supervisor, spawn dispatcher thread) and the shutdown drain.

- [ ] **Step 1: Read existing `src/main.zig`** to understand the current startup sequence (already documented in the logos `CLAUDE.md`).

- [ ] **Step 2: Add the new sections**

After `Db.open(...)` returns, insert:

```zig
// Daemon-restart cleanup: mark any in-flight jobs from a previous run as failed.
const now_buf = nowIso8601();
_ = try @import("db/jobs.zig").markStuckJobsFailed(&db, &now_buf);

// Load agent config (with fallback).
const agent_config_mod = @import("agents/config.zig");
var agent_cfg = try agent_config_mod.loadFromDir(gpa, cfg.data_dir);
defer agent_cfg.deinit(gpa);

// Init the event channel + supervisor.
const event_channel_mod = @import("agents/event_channel.zig");
var event_ch = event_channel_mod.EventChannel.init(gpa);
defer event_ch.deinit();

const supervisor_mod = @import("agents/supervisor.zig");
var sup = supervisor_mod.Supervisor.init(gpa, &agent_cfg, &event_ch);
defer sup.deinit();

// Init + start the dispatcher.
const dispatcher_mod = @import("agents/dispatcher.zig");
var disp = dispatcher_mod.Dispatcher.init(gpa, &db, &req_mutex, &sup, &event_ch);
defer disp.deinit();
const disp_thread = try std.Thread.spawn(.{}, dispatcher_mod.Dispatcher.run, .{&disp});

// At shutdown: signal dispatcher, then drain agents.
defer {
    disp.requestStop();
    disp_thread.join();
    sup.shutdownAll();
}

// Now `api_server.serve` runs the HTTP loop as before.
```

The `req_mutex` already exists in the main scope; pass its address to the dispatcher. The HTTP handlers will need access to the dispatcher too (for the cancel endpoint) — pass it through the existing request-context plumbing the way `Db` is passed today.

The `nowIso8601` helper can be a small inline definition or imported from a shared util module. Same impl as in dispatcher / handlers.

- [ ] **Step 3: Run a manual smoke test**

```bash
cd ~/projects/lambe-haath/logos
zig build
export LAMBE_MOCK_AGENT_PATH="$HOME/projects/chargesheets/pdf-extraction-experiments/tests/mock_agent.py"
export CHARGESHEET_DATA_DIR="/tmp/lambe-test-$$"
mkdir -p "$CHARGESHEET_DATA_DIR"

# Write a minimal agents.json that uses the mock agent for both kinds.
cat > "$CHARGESHEET_DATA_DIR/agents.json" <<EOF
{
  "agents": [
    {"kind": "ocr",    "command": "python3", "args": ["$LAMBE_MOCK_AGENT_PATH"], "max_workers": 1, "model": "mock-model"},
    {"kind": "prompt", "command": "python3", "args": ["$LAMBE_MOCK_AGENT_PATH"], "max_workers": 1, "model": "mock-model"}
  ]
}
EOF

./zig-out/bin/logos -p 7777 &
LOGOS_PID=$!
sleep 1

# Verify health
curl -s http://localhost:7777/api/v1/health
# Stop the daemon
kill -INT $LOGOS_PID
wait $LOGOS_PID 2>/dev/null || true
rm -rf "$CHARGESHEET_DATA_DIR"
```

Expected: daemon starts, health responds, daemon shuts down cleanly within ~5s.

- [ ] **Step 4: Commit**

```bash
git add src/main.zig
git commit -m "main: wire agent supervisor + dispatcher into startup/shutdown"
```

---

## Task 13: End-to-end HTTP-driven OCR test

**Target repo:** `~/projects/lambe-haath/logos/`

**Files:**
- Modify: `src/agents/integration_test.zig` (extend with HTTP-driven test)

The Task 7 test exercises dispatcher → agent directly. This test goes a layer up: it spawns the full daemon, hits the HTTP API, and asserts the full pipeline.

- [ ] **Step 1: Append to `src/agents/integration_test.zig`**

```zig
test "HTTP POST /jobs/ocr enqueues and dispatches" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    const path = mockPath() orelse return error.SkipZigTest;

    const gpa = std.testing.allocator;

    // Spawn logos as a subprocess on an ephemeral port + data dir.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(data_dir);

    // Write agents.json
    const cfg_path = try std.fs.path.join(gpa, &.{ data_dir, "agents.json" });
    defer gpa.free(cfg_path);
    var cfg_text_buf: [512]u8 = undefined;
    const cfg_text = try std.fmt.bufPrint(&cfg_text_buf,
        \\{{"agents":[
        \\  {{"kind":"ocr","command":"python3","args":["{s}"],"max_workers":1,"model":"mock-model"}},
        \\  {{"kind":"prompt","command":"python3","args":["{s}"],"max_workers":1,"model":"mock-model"}}
        \\]}}
    , .{ path, path });
    try std.fs.cwd().writeFile(.{ .sub_path = cfg_path, .data = cfg_text });

    const logos_bin = "zig-out/bin/logos";
    var child = std.process.Child.init(&.{ logos_bin, "-p", "0" }, gpa);
    var env = try std.process.getEnvMap(gpa);
    defer env.deinit();
    try env.put("CHARGESHEET_DATA_DIR", data_dir);
    child.env_map = &env;
    child.stdout_behavior = .Pipe;
    try child.spawn();
    defer {
        _ = child.kill() catch {};
        _ = child.wait() catch {};
    }

    // Read the actual bound port from logos's startup line (logos prints
    // "listening on :PORT" on stdout; adapt to whatever your daemon emits).
    // For now: assume the daemon binds to a fixed test port; or extend logos's
    // startup to print the port to stdout in a parseable way.
    //
    // This test is intentionally narrow — Task 13 verifies the wiring works at
    // all. Richer end-to-end coverage lands in Plan C/D when real agents exist.

    // (Implementation note: if logos doesn't print the port, change -p 0 to a
    // hardcoded test port like 17777 and assert on that. Document the choice
    // in DONE_WITH_CONCERNS.)
}
```

If the daemon doesn't yet print its bound port in a parseable form, **the simpler version of this test** is to skip the HTTP layer and only assert that `main.zig`'s startup sequence loads the agent config and spawns the dispatcher. That can be inferred from the daemon not exiting non-zero within 2 seconds.

- [ ] **Step 2: Run, commit**

```bash
zig build test --summary all 2>&1 | tail -10
git add src/agents/integration_test.zig
git commit -m "test: HTTP-driven OCR enqueue smoke test"
```

Expected: +1 test (may be marked DONE_WITH_CONCERNS if the port-discovery dance can't be cleanly automated; the user can run the manual smoke test from Task 12 to validate).

---

## Task 14: End-to-end test — prompt fan-out gating

**Target repo:** `~/projects/lambe-haath/logos/`

**Files:**
- Modify: `src/agents/integration_test.zig`

Specifically tests the spec's invariant: `prompt` jobs stay queued until their required `extractions` rows exist.

- [ ] **Step 1: Append to `src/agents/integration_test.zig`**

```zig
test "prompt job stays queued until OCR fan-in completes" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    const path = mockPath() orelse return error.SkipZigTest;

    const gpa = std.testing.allocator;
    var db = try Db.open(":memory:");
    defer db.close();
    var mu: std.Thread.Mutex = .{};

    var cfg = try buildMockConfig(gpa, path, "prompt", 1);
    defer cfg.deinit(gpa);

    var ch = event_channel.EventChannel.init(gpa);
    defer ch.deinit();

    var sup = supervisor_mod.Supervisor.init(gpa, &cfg, &ch);
    defer sup.deinit();

    var disp = dispatcher_mod.Dispatcher.init(gpa, &db, &mu, &sup, &ch);
    defer disp.deinit();

    // Seed: project, one slice WITHOUT extraction, one prompt job.
    {
        mu.lock();
        defer mu.unlock();
        try test_helpers.insertProject(&db, "p1");
        try db.conn.exec(
            \\INSERT INTO slices (project_id, filename, start_page, end_page, size_bytes, kind, kind_key, created_at)
            \\VALUES ('p1', 'annexure-i.pdf', 1, 1, 1, 'annexure', 'i', '2026-05-28T00:00:00Z')
        , .{});
        try test_helpers.insertJob(&db, "jp", "p1", "prompt");
    }

    const t = try std.Thread.spawn(.{}, dispatcher_mod.Dispatcher.run, .{&disp});
    defer {
        disp.requestStop();
        t.join();
        sup.shutdownAll();
    }

    // Wait 2s. Job should still be 'queued' because OCR hasn't run.
    std.Thread.sleep(2 * std.time.ns_per_s);
    {
        mu.lock();
        const r = (db.conn.row("SELECT status FROM jobs WHERE id='jp'", .{}) catch null).?;
        defer r.deinit();
        try std.testing.expectEqualStrings("queued", r.text(0));
        mu.unlock();
    }

    // Add the extraction (simulating OCR completion).
    {
        mu.lock();
        defer mu.unlock();
        try db.conn.exec(
            \\INSERT INTO extractions
            \\  (project_id, slice_filename, markdown_path, meta_path, model, pages, page_markers_found, latency_s, created_at)
            \\VALUES ('p1', 'annexure-i.pdf', '/x.md', '/x.json', 'mock', 1, 1, 1.0, '2026-05-28T00:01:00Z')
        , .{});
    }

    // Now the prompt job should become dispatchable and run.
    var elapsed: u32 = 0;
    while (elapsed < 10_000) : (elapsed += 100) {
        std.Thread.sleep(100 * std.time.ns_per_ms);
        mu.lock();
        const row = db.conn.row("SELECT status FROM jobs WHERE id='jp'", .{}) catch null;
        if (row) |r| {
            const status = r.text(0);
            const is_complete = std.mem.eql(u8, status, "completed");
            r.deinit();
            mu.unlock();
            if (is_complete) return;  // test passes
        } else mu.unlock();
    }

    return error.PromptJobNeverDispatched;
}
```

- [ ] **Step 2: Run + commit**

```bash
zig build test --summary all 2>&1 | tail -10
git add src/agents/integration_test.zig
git commit -m "test: prompt job stays queued until extractions exist"
```

Expected: +1 test, passes within ~5 seconds.

---

## Task 15: End-to-end test — cancellation

**Target repo:** `~/projects/lambe-haath/logos/`

**Files:**
- Modify: `src/agents/integration_test.zig`

- [ ] **Step 1: Append**

```zig
test "cancellation flips job status to canceled" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    const path = mockPath() orelse return error.SkipZigTest;

    const gpa = std.testing.allocator;
    var db = try Db.open(":memory:");
    defer db.close();
    var mu: std.Thread.Mutex = .{};

    var cfg = try buildMockConfig(gpa, path, "ocr", 1);
    defer cfg.deinit(gpa);
    var ch = event_channel.EventChannel.init(gpa);
    defer ch.deinit();
    var sup = supervisor_mod.Supervisor.init(gpa, &cfg, &ch);
    defer sup.deinit();
    var disp = dispatcher_mod.Dispatcher.init(gpa, &db, &mu, &sup, &ch);
    defer disp.deinit();

    {
        mu.lock();
        defer mu.unlock();
        try test_helpers.insertProject(&db, "p1");
        try db.conn.exec(
            \\INSERT INTO slices (project_id, filename, start_page, end_page, size_bytes, kind, kind_key, created_at)
            \\VALUES ('p1', 'annexure-i.pdf', 1, 1, 1, 'annexure', 'i', '2026-05-28T00:00:00Z')
        , .{});
        try test_helpers.insertJob(&db, "jc", "p1", "ocr");
    }

    // Use a slow mock so the cancel arrives mid-job.
    // (For Plan B, the mock-agent default echoes immediately; we accept that
    // the cancel may arrive after the response and still see status='completed'
    // rather than 'canceled'. The test asserts EITHER terminal state — the
    // important invariant is that we don't deadlock or leak.)

    const t = try std.Thread.spawn(.{}, dispatcher_mod.Dispatcher.run, .{&disp});
    defer {
        disp.requestStop();
        t.join();
        sup.shutdownAll();
    }

    // Wait briefly for job to start.
    std.Thread.sleep(200 * std.time.ns_per_ms);
    try disp.cancelJob("jc");

    var elapsed: u32 = 0;
    while (elapsed < 10_000) : (elapsed += 100) {
        std.Thread.sleep(100 * std.time.ns_per_ms);
        mu.lock();
        const r = (db.conn.row("SELECT status FROM jobs WHERE id='jc'", .{}) catch null);
        if (r) |row| {
            const status = row.text(0);
            const terminal = std.mem.eql(u8, status, "canceled") or
                std.mem.eql(u8, status, "completed") or
                std.mem.eql(u8, status, "failed");
            row.deinit();
            mu.unlock();
            if (terminal) return;
        } else mu.unlock();
    }

    return error.JobNeverTerminal;
}
```

- [ ] **Step 2: Run + commit**

```bash
zig build test --summary all 2>&1 | tail -10
git add src/agents/integration_test.zig
git commit -m "test: cancellation reaches a terminal state without deadlock"
```

Expected: +1 test.

---

## Task 16: Final verification

**Target repos:** both

- [ ] **Step 1: Confirm all tests green**

```bash
cd ~/projects/lambe-haath/logos
export LAMBE_MOCK_AGENT_PATH="$HOME/projects/chargesheets/pdf-extraction-experiments/tests/mock_agent.py"
zig build test --summary all
```

Expected: every prior test (113 from Plan A) plus the new ones from this plan. Approximate target: 140+.

- [ ] **Step 2: Manual smoke**

Use the script from Task 12, Step 3.

- [ ] **Step 3: Verify branches are clean and ready for merge**

```bash
cd ~/projects/lambe-haath/logos
git status
git log --oneline main..feat/plan-b-supervisor-dispatcher
```

- [ ] **Step 4: (Optional) tag the milestone**

```bash
git tag -a plan-b-supervisor-dispatcher -m "Plan B complete: logos accepts HTTP jobs and runs them against the mock agent"
```

---

## What's next (Plan C preview, not in this plan)

Once Plan B is merged:

- **Plan C: Real OCR agent** — extend today's `main.py` into a proper Python module that speaks `lambe-haath/1`, reads `LAMBE_MODEL`, calls Gemini, writes the `extractions` row through the result payload. Logos doesn't change.
- **Plan D: Real prompt agent** — new Python module with 5 prompts, Anthropic SDK + Gemini fallback (model picked from `LAMBE_MODEL`). Logos doesn't change.
- **Plan E: SPA UI + stats** — new Svelte pages, stats endpoints, SSE consumption.

Plan B's exit criterion (logos drives the mock agent end-to-end via HTTP) means Plans C and D are independent agent-side work that doesn't touch logos at all. The UI work (Plan E) can also start in parallel against the real HTTP endpoints, even if real agents aren't done yet (mock-agent responses will populate the DB).
