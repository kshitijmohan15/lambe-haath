const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Db = @import("../db/db.zig").Db;
const test_helpers = @import("../db/test_helpers.zig");
const config_mod = @import("config.zig");
const event_channel_mod = @import("event_channel.zig");
const supervisor_mod = @import("supervisor.zig");
const dispatcher_mod = @import("dispatcher.zig");

fn mockPath() ?[]const u8 {
    // std.c.getenv is the POSIX-safe way in Zig 0.16; std.posix.getenv doesn't exist.
    const v = std.c.getenv("LAMBE_MOCK_AGENT_PATH") orelse return null;
    return std.mem.span(v);
}

fn buildMockConfig(gpa: std.mem.Allocator, path: []const u8, kind: []const u8, max_workers: u32) !config_mod.AgentConfig {
    const args = try gpa.alloc([]const u8, 1);
    args[0] = try gpa.dupe(u8, path);
    const specs = try gpa.alloc(config_mod.AgentSpec, 1);
    specs[0] = .{
        .kind = try gpa.dupe(u8, kind),
        .command = try gpa.dupe(u8, "python3"),
        .args = args,
        .max_workers = max_workers,
        .model = try gpa.dupe(u8, "mock-model"),
    };
    return .{ .agents = specs };
}

test "OCR job runs end-to-end through dispatcher + mock agent" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    const path = mockPath() orelse return error.SkipZigTest;

    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var db = try Db.open(":memory:");
    defer db.close();

    var mu: Io.Mutex = .init;

    // The agent kind we dispatch is 'ocr'; tell config our mock plays that role.
    var cfg = try buildMockConfig(gpa, path, "ocr", 1);
    defer cfg.deinit(gpa);

    var ch = event_channel_mod.EventChannel.init(gpa, io);
    defer ch.deinit();

    var sup = supervisor_mod.Supervisor.init(io, gpa, &cfg, &ch);
    defer sup.deinit();

    var disp = dispatcher_mod.Dispatcher.init(io, gpa, &db, &mu, &sup, &ch);
    defer disp.deinit();

    // Seed: project + slice + queued OCR job.
    {
        mu.lockUncancelable(io);
        defer mu.unlock(io);

        try test_helpers.insertProject(&db, "p1");

        try db.conn.exec(
            \\INSERT INTO slices
            \\  (project_id, filename, start_page, end_page, size_bytes, kind, kind_key, created_at)
            \\VALUES ('p1', 'annexure-i.pdf', 1, 1, 1, 'annexure', 'i', '2026-05-28T00:00:00Z')
        , .{});

        try test_helpers.insertJob(&db, "job1", "p1", "ocr");
    }

    // Run the dispatcher loop in a background thread.
    const t = try std.Thread.spawn(.{}, dispatcher_mod.Dispatcher.run, .{&disp});

    // Poll the DB for up to 10 s for job1 to reach 'completed'.
    var completed = false;
    var elapsed_ms: u32 = 0;
    while (elapsed_ms < 10_000) : (elapsed_ms += 100) {
        const ts = std.c.timespec{ .sec = 0, .nsec = @as(c_long, 100 * std.time.ns_per_ms) };
        _ = std.c.nanosleep(&ts, null);

        mu.lockUncancelable(io);
        const maybe_row = db.conn.row("SELECT status FROM jobs WHERE id=?", .{"job1"}) catch null;
        if (maybe_row) |r| {
            const status_text = r.text(0);
            const is_completed = std.mem.eql(u8, status_text, "completed");
            r.deinit();
            mu.unlock(io);
            if (is_completed) {
                completed = true;
                break;
            }
        } else {
            mu.unlock(io);
        }
    }

    // Signal stop and wait for the dispatcher thread to exit.
    disp.requestStop();
    t.join();

    // Shut down the spawned worker process.
    sup.shutdownAll();

    try std.testing.expect(completed);
}
