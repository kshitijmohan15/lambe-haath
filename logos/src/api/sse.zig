//! Server-Sent Events helper for the job stream endpoint.
//!
//! GET /api/v1/jobs/:id/stream — holds the connection open as
//! `text/event-stream`, polling the database every ~500 ms for new log rows
//! and status changes, and emitting SSE events to the client.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Db = @import("../db/db.zig").Db;

/// Stream SSE events for `job_id` by writing to `w`.
///
/// The caller MUST hold `db_mu` before calling this function.
/// `streamJob` will unlock it around sleep intervals so other requests are not
/// blocked for the full polling duration.
///
/// Exits when any of the following are true:
///   - The job reaches a terminal status (completed / failed / canceled).
///   - A write to `w` fails (client disconnect).
///   - 1200 iterations × 500 ms ≈ 10 minutes have elapsed.
pub fn streamJob(
    db: *Db,
    db_mu: *std.Io.Mutex,
    io: std.Io,
    job_id: []const u8,
    w: *std.Io.Writer,
) void {
    var last_log_id: i64 = 0;
    var last_status_buf: [16]u8 = undefined;
    var last_status_len: usize = 0;

    var iter: u32 = 0;
    while (iter < 1200) : (iter += 1) {
        // --- poll new log rows (mutex already held on first entry; re-acquired
        //     after each sleep) ---
        var rows = db.conn.rows(
            \\SELECT id, ts, level, logger, message FROM job_logs
            \\WHERE job_id = ? AND id > ? ORDER BY id ASC LIMIT 100
        , .{ job_id, last_log_id }) catch {
            db_mu.unlock(io);
            return;
        };

        while (rows.next()) |row| {
            const log_id = row.int(0);
            const ts = row.text(1);
            const level = row.text(2);
            const logger = row.text(3);
            const message = row.text(4);

            w.writeAll("event: log\ndata: {\"ts\":\"") catch {
                rows.deinit();
                db_mu.unlock(io);
                return;
            };
            w.writeAll(ts) catch {
                rows.deinit();
                db_mu.unlock(io);
                return;
            };
            w.writeAll("\",\"level\":\"") catch {
                rows.deinit();
                db_mu.unlock(io);
                return;
            };
            w.writeAll(level) catch {
                rows.deinit();
                db_mu.unlock(io);
                return;
            };
            w.writeAll("\",\"logger\":\"") catch {
                rows.deinit();
                db_mu.unlock(io);
                return;
            };
            writeJsonStringEscaped(w, logger) catch {
                rows.deinit();
                db_mu.unlock(io);
                return;
            };
            w.writeAll("\",\"message\":\"") catch {
                rows.deinit();
                db_mu.unlock(io);
                return;
            };
            writeJsonStringEscaped(w, message) catch {
                rows.deinit();
                db_mu.unlock(io);
                return;
            };
            w.writeAll("\"}\n\n") catch {
                rows.deinit();
                db_mu.unlock(io);
                return;
            };
            w.flush() catch {
                rows.deinit();
                db_mu.unlock(io);
                return;
            };

            last_log_id = log_id;
        }
        rows.deinit();

        // --- poll status + progress ---
        const maybe_row = db.conn.row(
            "SELECT status, progress FROM jobs WHERE id=?",
            .{job_id},
        ) catch null;

        var terminal = false;
        if (maybe_row) |r| {
            defer r.deinit();
            const status = r.text(0);
            const progress = r.float(1);

            const same_status = last_status_len > 0 and
                std.mem.eql(u8, status, last_status_buf[0..last_status_len]);
            if (!same_status) {
                const copy_len = @min(status.len, last_status_buf.len);
                @memcpy(last_status_buf[0..copy_len], status[0..copy_len]);
                last_status_len = copy_len;

                w.print(
                    "event: status\ndata: {{\"status\":\"{s}\",\"progress\":{d}}}\n\n",
                    .{ status, progress },
                ) catch {
                    db_mu.unlock(io);
                    return;
                };
                w.flush() catch {
                    db_mu.unlock(io);
                    return;
                };
            }

            if (std.mem.eql(u8, status, "completed") or
                std.mem.eql(u8, status, "failed") or
                std.mem.eql(u8, status, "canceled"))
            {
                terminal = true;
            }
        }

        if (terminal) {
            w.writeAll("event: end\ndata: {}\n\n") catch {};
            w.flush() catch {};
            db_mu.unlock(io);
            return;
        }

        // Release the mutex while sleeping so other requests aren't blocked.
        // io.sleep is cross-platform; the prior std.c.nanosleep version did
        // not compile for x86_64-windows-gnu.
        db_mu.unlock(io);
        io.sleep(.fromMilliseconds(500), .awake) catch {};
        db_mu.lockUncancelable(io);
    }

    // Hard cap reached: send an end event and release the mutex.
    w.writeAll("event: end\ndata: {}\n\n") catch {};
    w.flush() catch {};
    db_mu.unlock(io);
}

/// Write each byte of `s` with JSON string escaping (no surrounding quotes).
fn writeJsonStringEscaped(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0...8, 11, 12, 14...31 => try w.print("\\u{x:0>4}", .{c}),
            else => try w.writeByte(c),
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "streamJob exits immediately when job is already terminal" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var db = try Db.open(":memory:");
    defer db.close();

    var mu: std.Io.Mutex = .init;

    const test_helpers = @import("../db/test_helpers.zig");
    try test_helpers.insertProject(&db, "p1");
    try test_helpers.insertJob(&db, "j1", "p1", "ocr");
    try db.conn.exec("UPDATE jobs SET status='completed' WHERE id='j1'", .{});

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    // streamJob expects db_mu to already be locked on entry.
    mu.lockUncancelable(io);
    streamJob(&db, &mu, io, "j1", &aw.writer);
    // streamJob unlocks mu before returning; do NOT double-unlock.

    const output = aw.written();
    // Must contain at least one "event: end" line.
    try std.testing.expect(std.mem.indexOf(u8, output, "event: end") != null);
}
