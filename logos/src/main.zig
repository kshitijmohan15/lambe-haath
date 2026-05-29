const std = @import("std");
const AppConfig = @import("config.zig").AppConfig;
const lock = @import("lock.zig");
const Db = @import("db/db.zig").Db;
const db_mod = @import("db/db.zig");
const jobs_mod = @import("db/jobs.zig");
const agent_config_mod = @import("agents/config.zig");
const event_channel_mod = @import("agents/event_channel.zig");
const supervisor_mod = @import("agents/supervisor.zig");
const dispatcher_mod = @import("agents/dispatcher.zig");

const version = "0.1.0";
const default_port: u16 = 7777;

const help_body =
    \\
    \\Without flags, ensures the platform-appropriate data directory exists,
    \\acquires a lock at <data_dir>/daemon.lock, and runs as a daemon until
    \\stdin is closed.
    \\
    \\Options:
    \\  -h, --help        Print this help and exit
    \\  -V, --version     Print the version and exit
    \\  -p, --port PORT   TCP port recorded in the lock file (default 7777)
    \\
    \\Environment:
    \\  CHARGESHEET_DATA_DIR   Override the data directory on any platform.
    \\  LAMBE_AGENTS_DIR       Override the Python agents/ directory.
    \\                         Default resolution: $LAMBE_AGENTS_DIR →
    \\                           <binary_dir>/../agents →
    \\                           <binary_dir>/../../agents → ./agents
    \\
    \\Default data directory:
    \\  macOS    $HOME/Library/Application Support/ChargesheetTool
    \\  Linux    $XDG_DATA_HOME/chargesheet-tool  (else $HOME/.local/share/chargesheet-tool)
    \\  Windows  %LOCALAPPDATA%\ChargesheetTool
    \\
;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args_it.deinit();

    const argv0 = args_it.next() orelse "chargesheet";
    const prog = std.fs.path.basename(argv0);

    var port: u16 = default_port;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try stdout.print("Usage: {s} [OPTIONS]\n{s}", .{ prog, help_body });
            try stdout_writer.flush();
            return;
        }
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
            try stdout.print("{s}\n", .{version});
            try stdout_writer.flush();
            return;
        }
        if (std.mem.eql(u8, arg, "--port") or std.mem.eql(u8, arg, "-p")) {
            const value = args_it.next() orelse {
                try stderr.print("{s}: --port requires a value\n", .{prog});
                try stderr_writer.flush();
                std.process.exit(2);
            };
            port = std.fmt.parseInt(u16, value, 10) catch {
                try stderr.print("{s}: invalid port: {s}\n", .{ prog, value });
                try stderr_writer.flush();
                std.process.exit(2);
            };
            continue;
        }

        try stderr.print("{s}: unknown argument: {s}\nTry `{s} --help`.\n", .{ prog, arg, prog });
        try stderr_writer.flush();
        std.process.exit(2);
    }

    var config = try AppConfig.load(io, gpa, init.environ_map);
    defer config.deinit(gpa);

    try std.Io.Dir.cwd().createDirPath(io, config.data_dir);

    var diag: lock.Diagnostics = .{};
    var held = lock.acquire(io, gpa, config.data_dir, port, &diag) catch |err| switch (err) {
        error.AnotherInstanceRunning => {
            const c = diag.conflict.?;
            try stderr.print(
                "{s}: another instance is already running (pid {d}, port {d}) using {s}\n",
                .{ prog, c.pid, c.port, config.data_dir },
            );
            try stderr_writer.flush();
            std.process.exit(1);
        },
        else => return err,
    };
    defer held.deinit(io);

    const db_path = try std.fs.path.joinZ(gpa, &.{ config.data_dir, "data.db" });
    defer gpa.free(db_path);

    var db = try Db.open(db_path);
    defer db.close();

    // 1. Daemon-restart cleanup: mark in-flight jobs from a previous run as failed.
    const now_str = try db_mod.nowIso8601(gpa);
    defer gpa.free(now_str);
    try jobs_mod.markStuckJobsFailed(&db, now_str);

    // 2. Load the agent config (with hardcoded fallback if agents.json is missing).
    var agent_cfg = try agent_config_mod.loadFromDir(io, gpa, config.data_dir);
    defer agent_cfg.deinit(gpa);

    // Derive the parent of the agents/ directory (used as subprocess cwd).
    const agents_parent_dir = std.fs.path.dirname(config.agents_dir) orelse ".";

    // 3. Initialize the shared DB mutex, event channel, and supervisor.
    //    req_mutex serializes DB access across the HTTP threads AND the dispatcher thread.
    var req_mutex: std.Io.Mutex = .init;

    var event_ch = event_channel_mod.EventChannel.init(gpa, io);
    defer event_ch.deinit();

    var sup = supervisor_mod.Supervisor.init(io, gpa, &agent_cfg, &event_ch, agents_parent_dir);

    // 4. Initialize the dispatcher.
    var disp = dispatcher_mod.Dispatcher.init(io, gpa, &db, &req_mutex, &sup, &event_ch, config.data_dir);
    defer disp.deinit();

    // 5. Spawn the dispatcher thread.
    const disp_thread = try std.Thread.spawn(.{}, dispatcher_mod.Dispatcher.run, .{&disp});

    // 6. Graceful shutdown when the HTTP loop exits (Ctrl+C / SIGINT).
    defer {
        disp.requestStop();
        disp_thread.join();
        sup.shutdownAll();
    }

    try stdout.print("daemon running: pid={d} port={d} data_dir={s} agents_dir={s}\n", .{ getpid(), port, config.data_dir, config.agents_dir });
    try stdout.print("(ctrl-C to exit)\n", .{});
    try stdout_writer.flush();

    const api_server = @import("api/server.zig");
    api_server.serve(io, gpa, &db, &req_mutex, .{ .port = port, .version = version, .data_dir = config.data_dir, .ui_dir = config.ui_dir, .agents_dir = config.agents_dir, .dispatcher = &disp }) catch |err| switch (err) {
        error.AddressInUse => {
            // We hold the lock for THIS data_dir, but the port is taken by some
            // other process (e.g. a daemon left running on another data_dir, or
            // an unrelated program). Release our lock and explain, instead of
            // dumping a raw bind() stack trace.
            held.deinit(io);
            try stderr.print(
                "{s}: port {d} is already in use — another daemon may still be running.\n" ++
                    "Find and stop it, then retry:\n" ++
                    "  lsof -nP -iTCP:{d} -sTCP:LISTEN\n" ++
                    "  kill <pid>\n" ++
                    "Or start on a different port:  {s} -p <port>\n",
                .{ prog, port, port, prog },
            );
            try stderr_writer.flush();
            std.process.exit(1);
        },
        else => return err,
    };
}

extern "c" fn getpid() i32;

test {
    _ = @import("paths.zig");
    _ = @import("db/db.zig");
    _ = @import("db/errors.zig");
    _ = @import("db/projects.zig");
    _ = @import("db/slices.zig");
    _ = @import("db/jobs.zig");
    _ = @import("db/extractions.zig");
    _ = @import("db/prompt_outputs.zig");
    _ = @import("db/stats.zig");
    _ = @import("db/job_logs.zig");
    _ = @import("agents/pricing.zig");
    _ = @import("agents/jsonrpc.zig");
    _ = @import("agents/config.zig");
    _ = @import("agents/event_channel.zig");
    _ = @import("agents/worker.zig");
    _ = @import("agents/supervisor.zig");
    _ = @import("agents/dispatcher.zig");
    _ = @import("agents/agent_params.zig");
    _ = @import("agents/integration_test.zig");
    _ = @import("api/json.zig");
    _ = @import("api/router.zig");
    _ = @import("api/multipart.zig");
    _ = @import("api/static.zig");
    _ = @import("api/handlers_ocr.zig");
    _ = @import("api/handlers_prompts.zig");
    _ = @import("api/handlers_jobs.zig");
    _ = @import("api/handlers_stats.zig");
    _ = @import("api/sse.zig");
    _ = @import("ids.zig");
    _ = @import("storage/project_dir.zig");
}
