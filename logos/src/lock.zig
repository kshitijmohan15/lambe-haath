const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const lock_filename = "daemon.lock";

// Private extern: std.posix.kill takes an exhaustive SIG enum, which can't
// represent signal 0 (the "does this pid exist?" probe).
const libc = struct {
    extern "c" fn kill(pid: i32, sig: c_int) c_int;
    extern "c" fn getpid() i32;
};

pub const Conflict = struct {
    pid: i32,
    port: u16,
};

pub const Diagnostics = struct {
    conflict: ?Conflict = null,
};

pub const Error = error{ AnotherInstanceRunning, StaleLockButCannotClaim } ||
    Allocator.Error ||
    std.Io.File.OpenError ||
    std.Io.File.Writer.Error ||
    std.Io.File.Reader.Error ||
    std.fmt.ParseIntError;

pub const Lock = struct {
    gpa: Allocator,
    path: []u8,

    pub fn deinit(self: *Lock, io: std.Io) void {
        std.Io.Dir.cwd().deleteFile(io, self.path) catch {};
        self.gpa.free(self.path);
        self.* = undefined;
    }
};

pub fn acquire(
    io: std.Io,
    gpa: Allocator,
    data_dir: []const u8,
    port: u16,
    diag: ?*Diagnostics,
) !Lock {
    const path = try std.fs.path.join(gpa, &.{ data_dir, lock_filename });
    errdefer gpa.free(path);

    // Two attempts: if the first finds a stale lock, we delete it and retry.
    var attempt: u8 = 0;
    while (attempt < 2) : (attempt += 1) {
        const file = std.Io.Dir.cwd().createFile(io, path, .{
            .exclusive = true,
            .truncate = true,
        }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                const state = try inspectExisting(io, path, diag);
                switch (state) {
                    .stale => {
                        std.Io.Dir.cwd().deleteFile(io, path) catch {};
                        continue;
                    },
                    .alive => return error.AnotherInstanceRunning,
                }
            },
            else => return err,
        };
        defer file.close(io);

        var buf: [64]u8 = undefined;
        const payload = try std.fmt.bufPrint(&buf, "{d}:{d}\n", .{ libc.getpid(), port });
        try file.writeStreamingAll(io, payload);

        return .{ .gpa = gpa, .path = path };
    }
    return error.StaleLockButCannotClaim;
}

const ExistingState = enum { stale, alive };

fn inspectExisting(io: std.Io, path: []const u8, diag: ?*Diagnostics) !ExistingState {
    var file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch |err| switch (err) {
        // Race: someone else removed it between our createFile and openFile.
        // Treat as stale so we retry.
        error.FileNotFound => return .stale,
        else => return err,
    };
    defer file.close(io);

    var buf: [128]u8 = undefined;
    const n = try file.readPositionalAll(io, &buf, 0);
    const content = std.mem.trim(u8, buf[0..n], " \r\n\t");

    var it = std.mem.splitScalar(u8, content, ':');
    const pid_str = it.next() orelse return .stale;
    const port_str = it.next() orelse return .stale;

    const pid = std.fmt.parseInt(i32, pid_str, 10) catch return .stale;
    const port = std.fmt.parseInt(u16, port_str, 10) catch 0;

    if (isProcessAlive(pid)) {
        if (diag) |d| d.conflict = .{ .pid = pid, .port = port };
        return .alive;
    }
    return .stale;
}

fn isProcessAlive(pid: i32) bool {
    if (builtin.os.tag == .windows) {
        // TODO: implement via OpenProcess + GetExitCodeProcess.
        // Until then, assume any pid recorded in the lock file is live —
        // safer to error than to clobber a real running instance.
        return true;
    }
    const rc = libc.kill(pid, 0);
    if (rc == 0) return true;
    return switch (std.posix.errno(rc)) {
        .SRCH => false, // no such process
        .PERM => true, // exists, just not ours
        else => false,
    };
}
