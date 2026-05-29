const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const config = @import("config.zig");
const event_channel = @import("event_channel.zig");
const jsonrpc = @import("jsonrpc.zig");

pub const State = enum { spawning, idle, busy, draining, dead };

pub const Worker = struct {
    id: u64,
    kind: []const u8, // borrowed from AgentSpec — NOT owned
    io: Io,
    child: std.process.Child,
    state: State,
    current_job_id: ?[]const u8,
    next_request_id: u64,
    reader_thread: ?std.Thread,

    /// Encode + write a JSON-RPC request to child stdin. Returns the request id used.
    pub fn sendRequest(
        self: *Worker,
        gpa: Allocator,
        method: []const u8,
        params_json: ?[]const u8,
    ) !u64 {
        const id: i64 = @intCast(self.next_request_id);
        self.next_request_id += 1;

        const msg = jsonrpc.Message{ .request = .{
            .id = id,
            .method = method,
            .params_json = params_json,
        } };
        const line = try jsonrpc.encode(gpa, msg);
        defer gpa.free(line);

        const stdin_file = self.child.stdin orelse return error.StdinClosed;
        var write_buf: [4096]u8 = undefined;
        var writer = stdin_file.writer(self.io, &write_buf);
        try writer.interface.writeAll(line);
        try writer.interface.flush();

        return @intCast(id);
    }

    /// Encode + write a JSON-RPC notification to child stdin.
    pub fn sendNotification(
        self: *Worker,
        gpa: Allocator,
        method: []const u8,
        params_json: ?[]const u8,
    ) !void {
        const msg = jsonrpc.Message{ .notification = .{
            .method = method,
            .params_json = params_json,
        } };
        const line = try jsonrpc.encode(gpa, msg);
        defer gpa.free(line);

        const stdin_file = self.child.stdin orelse return error.StdinClosed;
        var write_buf: [4096]u8 = undefined;
        var writer = stdin_file.writer(self.io, &write_buf);
        try writer.interface.writeAll(line);
        try writer.interface.flush();
    }

    /// Graceful shutdown: send shutdown + notifications/exit, close stdin,
    /// wait for process exit, join reader thread. Sets state = .dead.
    pub fn close(self: *Worker, gpa: Allocator) void {
        _ = gpa;
        if (self.state == .dead) return;

        // Best-effort shutdown messages — ignore errors.
        const shutdown_req =
            \\{"jsonrpc":"2.0","id":999999,"method":"shutdown","params":null}
            \\
        ;
        const exit_notif =
            \\{"jsonrpc":"2.0","method":"notifications/exit"}
            \\
        ;
        if (self.child.stdin) |stdin_file| {
            var write_buf: [4096]u8 = undefined;
            var writer = stdin_file.writer(self.io, &write_buf);
            writer.interface.writeAll(shutdown_req) catch {};
            writer.interface.flush() catch {};
            writer.interface.writeAll(exit_notif) catch {};
            writer.interface.flush() catch {};

            // Close stdin — child will see EOF and should exit.
            stdin_file.close(self.io);
            self.child.stdin = null;
        }

        // Wait for the child to exit.
        _ = self.child.wait(self.io) catch {};

        // Join the reader thread.
        if (self.reader_thread) |t| {
            t.join();
            self.reader_thread = null;
        }

        self.state = .dead;
    }

    /// Force kill. Use after close() exceeds its deadline.
    pub fn kill(self: *Worker) void {
        self.child.kill(self.io);
        if (self.reader_thread) |t| {
            t.join();
            self.reader_thread = null;
        }
        self.state = .dead;
    }
};

/// Context passed to the reader thread (heap-allocated, freed at thread exit).
const ReaderContext = struct {
    gpa: Allocator,
    io: Io,
    worker_id: u64,
    stdout_file: Io.File,
    channel: *event_channel.EventChannel,
};

fn readerThreadFn(ctx_ptr: *ReaderContext) void {
    const ctx = ctx_ptr.*;
    defer ctx_ptr.gpa.destroy(ctx_ptr);

    const gpa = ctx.gpa;
    const io = ctx.io;

    var read_buf: [16384]u8 = undefined;
    var reader = ctx.stdout_file.reader(io, &read_buf);

    while (true) {
        // takeDelimiter('\n') returns ?[]u8 — null on EOF.
        const maybe_line = reader.interface.takeDelimiter('\n') catch {
            // Read error — treat as EOF / dead.
            ctx.channel.send(.{
                .worker_id = ctx.worker_id,
                .event = .dead,
            }) catch {};
            return;
        };

        const line = maybe_line orelse {
            // EOF.
            ctx.channel.send(.{
                .worker_id = ctx.worker_id,
                .event = .dead,
            }) catch {};
            return;
        };

        if (line.len == 0) continue;

        const msg = jsonrpc.decodeLine(gpa, line) catch {
            // Parse error — copy the line and send a parse_error event; continue.
            const copy = gpa.dupe(u8, line) catch continue;
            ctx.channel.send(.{
                .worker_id = ctx.worker_id,
                .event = .{ .parse_error = copy },
            }) catch {
                gpa.free(copy);
            };
            continue;
        };

        ctx.channel.send(.{
            .worker_id = ctx.worker_id,
            .event = .{ .message = msg },
        }) catch {
            var m = msg;
            m.deinit(gpa);
        };
    }
}

/// Spawn the agent child process, complete the initialize handshake synchronously,
/// then start the reader thread. On success, state = .idle.
///
/// `io` is needed for process spawning and file I/O. It is stored in the returned
/// Worker so callers don't need to re-supply it for sendRequest / close / kill.
///
/// `agents_parent_dir` is the parent of the `agents/` Python package directory.
/// The subprocess is spawned with this as its working directory so that
/// `python3 -m agents.<name>` can resolve the package regardless of where
/// the daemon binary was launched from.
pub fn spawn(
    io: Io,
    gpa: Allocator,
    id: u64,
    agent_spec: *const config.AgentSpec,
    channel: *event_channel.EventChannel,
    agents_parent_dir: []const u8,
) !Worker {
    // Build argv: [command, args...]
    var argv = try gpa.alloc([]const u8, 1 + agent_spec.args.len);
    defer gpa.free(argv);
    argv[0] = agent_spec.command;
    for (agent_spec.args, 0..) |arg, i| argv[1 + i] = arg;

    // Build environment: inherit parent env, add LAMBE_MODEL.
    // On POSIX, use std.c.environ to get the current process environment.
    var env_map = blk: {
        const c_environ: [*:null]?[*:0]const u8 = @ptrCast(std.c.environ);
        const env_slice: [:null]const ?[*:0]const u8 = std.mem.span(c_environ);
        const environ: std.process.Environ = .{ .block = .{ .slice = env_slice } };
        break :blk try std.process.Environ.createMap(environ, gpa);
    };
    defer env_map.deinit();

    // Set LAMBE_MODEL.
    try env_map.put("LAMBE_MODEL", agent_spec.model);

    // Spawn with the agents parent directory as cwd so Python finds the
    // agents package via `-m agents.<name>` regardless of daemon launch dir.
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
        .environ_map = &env_map,
        .cwd = .{ .path = agents_parent_dir },
    });
    errdefer child.kill(io);

    // --- Initialize handshake ---
    // Send initialize request (id=0).
    const init_req =
        \\{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"lambe-haath/1","hostInfo":{"name":"logos","version":"0.1.0"},"capabilities":{"progress":true,"cancellation":true}}}
        \\
    ;
    {
        const stdin_file = child.stdin orelse return error.StdinClosed;
        var write_buf: [4096]u8 = undefined;
        var writer = stdin_file.writer(io, &write_buf);
        try writer.interface.writeAll(init_req);
        try writer.interface.flush();
    }

    // Read the response line synchronously from stdout.
    const stdout_file = child.stdout orelse return error.StdoutClosed;
    var read_buf: [16384]u8 = undefined;
    var reader = stdout_file.reader(io, &read_buf);

    const resp_line = (reader.interface.takeDelimiter('\n') catch return error.InitializeFailed) orelse
        return error.InitializeFailed;

    const resp_msg = jsonrpc.decodeLine(gpa, resp_line) catch return error.InitializeProtocolError;
    defer {
        var m = resp_msg;
        m.deinit(gpa);
    }

    // Verify it's a response to id=0 with a result body.
    if (resp_msg != .response) return error.InitializeProtocolError;
    if (resp_msg.response.id != 0) return error.InitializeProtocolError;
    if (resp_msg.response.body != .result) return error.InitializeProtocolError;

    // Send initialized notification.
    {
        const notif =
            \\{"jsonrpc":"2.0","method":"notifications/initialized"}
            \\
        ;
        const stdin_file = child.stdin orelse return error.StdinClosed;
        var write_buf: [4096]u8 = undefined;
        var writer = stdin_file.writer(io, &write_buf);
        try writer.interface.writeAll(notif);
        try writer.interface.flush();
    }

    // Start reader thread. Context is heap-allocated so the thread owns it.
    const ctx = try gpa.create(ReaderContext);
    errdefer gpa.destroy(ctx);
    ctx.* = .{
        .gpa = gpa,
        .io = io,
        .worker_id = id,
        .stdout_file = stdout_file,
        .channel = channel,
    };

    const thread = try std.Thread.spawn(.{}, readerThreadFn, .{ctx});

    return Worker{
        .id = id,
        .kind = agent_spec.kind,
        .io = io,
        .child = child,
        .state = .idle,
        .current_job_id = null,
        .next_request_id = 1, // 0 was used for initialize
        .reader_thread = thread,
    };
}

// --- Tests ---

fn mockAgentPathOrSkip() ?[]const u8 {
    const result = std.c.getenv("LAMBE_MOCK_AGENT_PATH") orelse return null;
    return std.mem.span(result);
}

fn buildSpec(gpa: Allocator, path: []const u8) !config.AgentSpec {
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
    const io = std.testing.io;

    var ch = event_channel.EventChannel.init(gpa, io);
    defer ch.deinit();

    var spec = try buildSpec(gpa, path);
    defer spec.deinit(gpa);

    var w = try spawn(io, gpa, 1, &spec, &ch, ".");
    try std.testing.expectEqual(State.idle, w.state);
    try std.testing.expectEqual(@as(u64, 1), w.id);

    w.close(gpa);
    try std.testing.expectEqual(State.dead, w.state);

    // We should see at least one .dead event on the channel.
    var saw_dead = false;
    while (ch.tryRecv()) |env| {
        var ev = env.event;
        defer event_channel.freeEvent(gpa, &ev);
        if (ev == .dead) saw_dead = true;
    }
    try std.testing.expect(saw_dead);
}

test "sendRequest + reader thread surfaces response on channel" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    const path = mockAgentPathOrSkip() orelse return error.SkipZigTest;

    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var ch = event_channel.EventChannel.init(gpa, io);
    defer ch.deinit();

    var spec = try buildSpec(gpa, path);
    defer spec.deinit(gpa);

    var w = try spawn(io, gpa, 1, &spec, &ch, ".");
    defer w.close(gpa);

    const req_id = try w.sendRequest(gpa, "mock.echo", "{\"hello\":\"world\"}");
    try std.testing.expectEqual(@as(u64, 1), req_id);

    // Poll the channel for up to ~2 seconds for the response.
    var got: ?event_channel.EventEnvelope = null;
    var attempts: u32 = 0;
    while (attempts < 20) : (attempts += 1) {
        if (ch.recvTimeout(100)) |env| {
            if (env.event == .message and env.event.message == .response) {
                got = env;
                break;
            } else {
                var ev = env.event;
                event_channel.freeEvent(gpa, &ev);
            }
        }
    }

    const env = got orelse return error.NoResponse;
    defer {
        var ev = env.event;
        event_channel.freeEvent(gpa, &ev);
    }

    try std.testing.expect(env.event == .message);
    try std.testing.expect(env.event.message == .response);
    try std.testing.expectEqual(@as(i64, 1), env.event.message.response.id);
    try std.testing.expect(env.event.message.response.body == .result);
}
