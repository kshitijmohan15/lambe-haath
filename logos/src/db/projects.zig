const std = @import("std");
const Allocator = std.mem.Allocator;
const Db = @import("db.zig").Db;
const errors = @import("errors.zig");
const test_helpers = @import("test_helpers.zig");

pub const Project = struct {
    id: []const u8,
    name: []const u8,
    description: ?[]const u8,
    created_at: []const u8,
    last_opened_at: []const u8,
    chargesheet_filename: []const u8,
    chargesheet_page_count: u32,
    chargesheet_size_bytes: u64,

    pub fn deinit(self: *Project, gpa: Allocator) void {
        gpa.free(self.id);
        gpa.free(self.name);
        if (self.description) |d| gpa.free(d);
        gpa.free(self.created_at);
        gpa.free(self.last_opened_at);
        gpa.free(self.chargesheet_filename);
    }
};

pub fn deinitList(list: []Project, gpa: Allocator) void {
    for (list) |*p| p.deinit(gpa);
    gpa.free(list);
}

pub fn insert(db: *Db, gpa: Allocator, project: Project) !void {
    _ = gpa;
    db.conn.exec(
        \\INSERT INTO projects
        \\  (id, name, description, created_at, last_opened_at,
        \\   chargesheet_filename, chargesheet_page_count, chargesheet_size_bytes)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ,
        .{
            project.id,
            project.name,
            project.description,
            project.created_at,
            project.last_opened_at,
            project.chargesheet_filename,
            @as(i64, @intCast(project.chargesheet_page_count)),
            @as(i64, @intCast(project.chargesheet_size_bytes)),
        },
    ) catch |err| return errors.mapConstraintErr(err);
}

pub fn listAll(db: *Db, gpa: Allocator) ![]Project {
    var list: std.ArrayList(Project) = .empty;
    errdefer {
        for (list.items) |*p| p.deinit(gpa);
        list.deinit(gpa);
    }

    var rows = try db.conn.rows(
        \\SELECT id, name, description, created_at, last_opened_at,
        \\       chargesheet_filename, chargesheet_page_count, chargesheet_size_bytes
        \\FROM projects ORDER BY last_opened_at DESC
    , .{});
    defer rows.deinit();

    // zqlite 0.0.1 cursor protocol: `next()` returns `?Row` (not `!?Row`).
    // Errors during iteration are surfaced via `rows.err`, which we check after the loop.
    while (rows.next()) |row| {
        const description: ?[]const u8 = if (row.nullableText(2)) |s| try gpa.dupe(u8, s) else null;
        errdefer if (description) |d| gpa.free(d);

        const id_owned = try gpa.dupe(u8, row.text(0));
        errdefer gpa.free(id_owned);
        const name_owned = try gpa.dupe(u8, row.text(1));
        errdefer gpa.free(name_owned);
        const created_owned = try gpa.dupe(u8, row.text(3));
        errdefer gpa.free(created_owned);
        const opened_owned = try gpa.dupe(u8, row.text(4));
        errdefer gpa.free(opened_owned);
        const filename_owned = try gpa.dupe(u8, row.text(5));
        errdefer gpa.free(filename_owned);

        const project: Project = .{
            .id = id_owned,
            .name = name_owned,
            .description = description,
            .created_at = created_owned,
            .last_opened_at = opened_owned,
            .chargesheet_filename = filename_owned,
            .chargesheet_page_count = @intCast(row.int(6)),
            .chargesheet_size_bytes = @intCast(row.int(7)),
        };
        try list.append(gpa, project);
    }
    if (rows.err) |e| return e;

    return list.toOwnedSlice(gpa);
}

pub fn delete(db: *Db, id: []const u8) !void {
    try db.conn.exec("DELETE FROM projects WHERE id = ?", .{id});
    if (db.conn.changes() == 0) return error.NotFound;
}

pub fn touchLastOpened(db: *Db, id: []const u8) !void {
    const db_mod = @import("db.zig");
    // DEVIATION FROM PLAN: plan specified `[32]u8`, but Zig 0.16's `std.fmt.allocPrint`
    // calls `Writer.Allocating.initCapacity(gpa, fmt.len)` (fmt.len == 44 here) and
    // `toOwnedSlice` then `rawAlloc`s another 20 bytes for the trimmed result. The
    // FBA must therefore hold ~64 bytes plus alignment padding. 128 bytes is safe.
    var buf: [128]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const ts = try db_mod.nowIso8601(fba.allocator());
    try db.conn.exec("UPDATE projects SET last_opened_at = ? WHERE id = ?", .{ ts, id });
    if (db.conn.changes() == 0) return error.NotFound;
}

pub fn existsByName(db: *Db, name: []const u8) !bool {
    const row = (try db.conn.row(
        "SELECT 1 FROM projects WHERE name = ? LIMIT 1",
        .{name},
    )) orelse return false;
    defer row.deinit();
    return true;
}

pub fn getById(db: *Db, gpa: Allocator, id: []const u8) !?Project {
    const row = (try db.conn.row(
        \\SELECT id, name, description, created_at, last_opened_at,
        \\       chargesheet_filename, chargesheet_page_count, chargesheet_size_bytes
        \\FROM projects WHERE id = ?
    ,
        .{id},
    )) orelse return null;
    defer row.deinit();

    const description: ?[]const u8 = if (row.nullableText(2)) |s| try gpa.dupe(u8, s) else null;
    errdefer if (description) |d| gpa.free(d);

    const id_owned = try gpa.dupe(u8, row.text(0));
    errdefer gpa.free(id_owned);
    const name_owned = try gpa.dupe(u8, row.text(1));
    errdefer gpa.free(name_owned);
    const created_owned = try gpa.dupe(u8, row.text(3));
    errdefer gpa.free(created_owned);
    const opened_owned = try gpa.dupe(u8, row.text(4));
    errdefer gpa.free(opened_owned);
    const filename_owned = try gpa.dupe(u8, row.text(5));
    errdefer gpa.free(filename_owned);

    return .{
        .id = id_owned,
        .name = name_owned,
        .description = description,
        .created_at = created_owned,
        .last_opened_at = opened_owned,
        .chargesheet_filename = filename_owned,
        .chargesheet_page_count = @intCast(row.int(6)),
        .chargesheet_size_bytes = @intCast(row.int(7)),
    };
}

test "insert + getById round-trips a project" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();

    const fixture: Project = .{
        .id = "p1",
        .name = "Case 42",
        .description = "Mock case",
        .created_at = "2026-05-24T10:00:00Z",
        .last_opened_at = "2026-05-24T10:00:00Z",
        .chargesheet_filename = "case42.pdf",
        .chargesheet_page_count = 12,
        .chargesheet_size_bytes = 4096,
    };

    try insert(&db, gpa, fixture);

    var got = (try getById(&db, gpa, "p1")) orelse return error.TestUnexpectedNull;
    defer got.deinit(gpa);

    try std.testing.expectEqualStrings("p1", got.id);
    try std.testing.expectEqualStrings("Case 42", got.name);
    try std.testing.expectEqualStrings("Mock case", got.description.?);
    try std.testing.expectEqualStrings("case42.pdf", got.chargesheet_filename);
    try std.testing.expectEqual(@as(u32, 12), got.chargesheet_page_count);
    try std.testing.expectEqual(@as(u64, 4096), got.chargesheet_size_bytes);
}

test "getById returns null when project does not exist" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();

    const got = try getById(&db, gpa, "nope");
    try std.testing.expect(got == null);
}

test "insert with duplicate name returns UniqueViolation" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();

    const a: Project = .{
        .id = "a", .name = "Same", .description = null,
        .created_at = "2026-05-24T10:00:00Z", .last_opened_at = "2026-05-24T10:00:00Z",
        .chargesheet_filename = "a.pdf", .chargesheet_page_count = 1, .chargesheet_size_bytes = 1,
    };
    const b: Project = .{
        .id = "b", .name = "Same", .description = null,
        .created_at = "2026-05-24T10:00:01Z", .last_opened_at = "2026-05-24T10:00:01Z",
        .chargesheet_filename = "b.pdf", .chargesheet_page_count = 1, .chargesheet_size_bytes = 1,
    };
    try insert(&db, gpa, a);
    try std.testing.expectError(error.UniqueViolation, insert(&db, gpa, b));
}

test "insert with zero page count returns CheckViolation" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();

    const bad: Project = .{
        .id = "x", .name = "Bad", .description = null,
        .created_at = "2026-05-24T10:00:00Z", .last_opened_at = "2026-05-24T10:00:00Z",
        .chargesheet_filename = "x.pdf", .chargesheet_page_count = 0, .chargesheet_size_bytes = 1,
    };
    try std.testing.expectError(error.CheckViolation, insert(&db, gpa, bad));
}

test "insert + getById round-trips a project with null description" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();

    const fixture: Project = .{
        .id = "p2",
        .name = "Null-desc case",
        .description = null,
        .created_at = "2026-05-24T10:00:00Z",
        .last_opened_at = "2026-05-24T10:00:00Z",
        .chargesheet_filename = "p2.pdf",
        .chargesheet_page_count = 5,
        .chargesheet_size_bytes = 1024,
    };

    try insert(&db, gpa, fixture);

    var got = (try getById(&db, gpa, "p2")) orelse return error.TestUnexpectedNull;
    defer got.deinit(gpa);

    try std.testing.expect(got.description == null);
    try std.testing.expectEqualStrings("Null-desc case", got.name);
}

test "listAll returns projects ordered by last_opened_at DESC" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();

    try insert(&db, gpa, .{
        .id = "p1", .name = "First", .description = null,
        .created_at = "2026-05-24T10:00:00Z", .last_opened_at = "2026-05-24T10:00:00Z",
        .chargesheet_filename = "1.pdf", .chargesheet_page_count = 1, .chargesheet_size_bytes = 1,
    });
    try insert(&db, gpa, .{
        .id = "p2", .name = "Second", .description = null,
        .created_at = "2026-05-24T11:00:00Z", .last_opened_at = "2026-05-24T11:00:00Z",
        .chargesheet_filename = "2.pdf", .chargesheet_page_count = 1, .chargesheet_size_bytes = 1,
    });

    const list = try listAll(&db, gpa);
    defer deinitList(list, gpa);

    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqualStrings("p2", list[0].id);
    try std.testing.expectEqualStrings("p1", list[1].id);
}

test "delete removes a project" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();

    try insert(&db, gpa, .{
        .id = "p1", .name = "X", .description = null,
        .created_at = "t", .last_opened_at = "t",
        .chargesheet_filename = "f", .chargesheet_page_count = 1, .chargesheet_size_bytes = 1,
    });
    try delete(&db, "p1");
    const got = try getById(&db, gpa, "p1");
    try std.testing.expect(got == null);
}

test "delete on missing id returns NotFound" {
    var db = try test_helpers.openTestDb();
    defer db.close();
    try std.testing.expectError(error.NotFound, delete(&db, "ghost"));
}

test "touchLastOpened updates the timestamp" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();

    try insert(&db, gpa, .{
        .id = "p1", .name = "X", .description = null,
        .created_at = "2026-05-24T10:00:00Z",
        .last_opened_at = "2026-05-24T10:00:00Z",
        .chargesheet_filename = "f", .chargesheet_page_count = 1, .chargesheet_size_bytes = 1,
    });

    try touchLastOpened(&db, "p1");

    var got = (try getById(&db, gpa, "p1")) orelse return error.TestUnexpectedNull;
    defer got.deinit(gpa);
    try std.testing.expect(!std.mem.eql(u8, got.last_opened_at, "2026-05-24T10:00:00Z"));
    try std.testing.expectEqual(@as(usize, 20), got.last_opened_at.len);
    try std.testing.expectEqual(@as(u8, 'Z'), got.last_opened_at[19]);
}

test "touchLastOpened on missing id returns NotFound" {
    var db = try test_helpers.openTestDb();
    defer db.close();
    try std.testing.expectError(error.NotFound, touchLastOpened(&db, "ghost"));
}

test "existsByName returns true/false correctly" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();

    try std.testing.expect(!try existsByName(&db, "Anything"));

    try insert(&db, gpa, .{
        .id = "p1", .name = "Anything", .description = null,
        .created_at = "t", .last_opened_at = "t",
        .chargesheet_filename = "f", .chargesheet_page_count = 1, .chargesheet_size_bytes = 1,
    });

    try std.testing.expect(try existsByName(&db, "Anything"));
    try std.testing.expect(!try existsByName(&db, "anything")); // case-sensitive
}
