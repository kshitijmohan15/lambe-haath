const std = @import("std");
const AppConfig = @import("config.zig").AppConfig;
const lock = @import("lock.zig");
const Db = @import("db/db.zig").Db;

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

    var config = try AppConfig.load(gpa, init.environ_map);
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

    try stdout.print("daemon running: pid={d} port={d} data_dir={s}\n", .{ getpid(), port, config.data_dir });
    try stdout.print("(ctrl-C to exit)\n", .{});
    try stdout_writer.flush();

    const api_server = @import("api/server.zig");
    try api_server.serve(io, gpa, &db, .{ .port = port, .version = version, .data_dir = config.data_dir });
}

extern "c" fn getpid() i32;

test {
    _ = @import("db/db.zig");
    _ = @import("db/errors.zig");
    _ = @import("db/projects.zig");
    _ = @import("db/slices.zig");
    _ = @import("db/jobs.zig");
    _ = @import("api/json.zig");
    _ = @import("api/router.zig");
    _ = @import("api/multipart.zig");
    _ = @import("ids.zig");
    _ = @import("storage/project_dir.zig");
}
