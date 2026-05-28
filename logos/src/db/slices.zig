const std = @import("std");
const Allocator = std.mem.Allocator;
const Db = @import("db.zig").Db;
const errors = @import("errors.zig");
const test_helpers = @import("test_helpers.zig");
const projects = @import("projects.zig");

pub const Slice = struct {
    project_id: []const u8,
    filename: []const u8,
    start_page: u32,
    end_page: u32,
    size_bytes: u64,
    kind: ?SliceKind = null,        // populated from filename parse; null = unknown/other
    kind_key: ?[]const u8 = null,   // 'i'/'ii'/'iii'/'iv' for annexures; '01'/'02'/... for RUDs
    created_at: []const u8,

    pub fn deinit(self: *Slice, gpa: Allocator) void {
        gpa.free(self.project_id);
        gpa.free(self.filename);
        gpa.free(self.created_at);
        if (self.kind_key) |kk| gpa.free(kk);
    }
};

pub const SliceKind = enum {
    annexure,
    rud,
    other,

    pub fn toText(self: SliceKind) []const u8 {
        return switch (self) {
            .annexure => "annexure",
            .rud => "rud",
            .other => "other",
        };
    }

    pub fn fromText(s: []const u8) ?SliceKind {
        if (std.mem.eql(u8, s, "annexure")) return .annexure;
        if (std.mem.eql(u8, s, "rud")) return .rud;
        if (std.mem.eql(u8, s, "other")) return .other;
        return null;
    }
};

pub fn deinitList(list: []Slice, gpa: Allocator) void {
    for (list) |*s| s.deinit(gpa);
    gpa.free(list);
}

/// ParsedKind holds the kind + (newly allocated) kind_key extracted from a filename.
/// Caller owns kind_key memory and must free with gpa.free.
pub const ParsedKind = struct { kind: SliceKind, kind_key: ?[]const u8 };

/// Parse a slice filename against the lambe-haath convention.
/// - "annexure-{i,ii,iii,iv}.pdf"  -> { .annexure, kind_key=<roman> }
/// - "rud-NN.pdf" (NN = two digits) -> { .rud,      kind_key=<NN>    }
/// - anything else                  -> { .other,    kind_key=null    }
pub fn parseKindFromFilename(gpa: Allocator, filename: []const u8) !ParsedKind {
    // strip ".pdf"
    if (!std.mem.endsWith(u8, filename, ".pdf")) return .{ .kind = .other, .kind_key = null };
    const stem = filename[0 .. filename.len - ".pdf".len];

    // annexure-{i,ii,iii,iv}
    inline for ([_][]const u8{ "i", "ii", "iii", "iv" }) |roman| {
        if (std.mem.eql(u8, stem, "annexure-" ++ roman)) {
            const owned = try gpa.dupe(u8, roman);
            return .{ .kind = .annexure, .kind_key = owned };
        }
    }

    // rud-NN (exactly two digits)
    const rud_prefix = "rud-";
    if (std.mem.startsWith(u8, stem, rud_prefix)) {
        const tail = stem[rud_prefix.len..];
        if (tail.len == 2 and std.ascii.isDigit(tail[0]) and std.ascii.isDigit(tail[1])) {
            const owned = try gpa.dupe(u8, tail);
            return .{ .kind = .rud, .kind_key = owned };
        }
    }

    return .{ .kind = .other, .kind_key = null };
}

pub fn insert(db: *Db, gpa: Allocator, slice: Slice) !void {
    _ = gpa;
    db.conn.exec(
        \\INSERT INTO slices
        \\  (project_id, filename, start_page, end_page, size_bytes,
        \\   kind, kind_key, created_at)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ,
        .{
            slice.project_id,
            slice.filename,
            @as(i64, @intCast(slice.start_page)),
            @as(i64, @intCast(slice.end_page)),
            @as(i64, @intCast(slice.size_bytes)),
            if (slice.kind) |k| k.toText() else null,
            slice.kind_key,
            slice.created_at,
        },
    ) catch |err| return errors.mapConstraintErr(err);
}

pub fn getByKey(db: *Db, gpa: Allocator, project_id: []const u8, filename: []const u8) !?Slice {
    const row = (try db.conn.row(
        \\SELECT project_id, filename, start_page, end_page, size_bytes,
        \\       kind, kind_key, created_at
        \\FROM slices WHERE project_id = ? AND filename = ?
    ,
        .{ project_id, filename },
    )) orelse return null;
    defer row.deinit();

    const pid = try gpa.dupe(u8, row.text(0));
    errdefer gpa.free(pid);
    const fname = try gpa.dupe(u8, row.text(1));
    errdefer gpa.free(fname);
    const kind_opt: ?SliceKind = if (row.nullableText(5)) |kt| SliceKind.fromText(kt) else null;
    const kk_raw: ?[]const u8 = row.nullableText(6);
    const kk_opt: ?[]const u8 = if (kk_raw) |kk| try gpa.dupe(u8, kk) else null;
    errdefer if (kk_opt) |kk| gpa.free(kk);
    const created = try gpa.dupe(u8, row.text(7));
    errdefer gpa.free(created);

    return .{
        .project_id = pid,
        .filename = fname,
        .start_page = @intCast(row.int(2)),
        .end_page = @intCast(row.int(3)),
        .size_bytes = @intCast(row.int(4)),
        .kind = kind_opt,
        .kind_key = kk_opt,
        .created_at = created,
    };
}

pub fn listByProject(db: *Db, gpa: Allocator, project_id: []const u8) ![]Slice {
    var list: std.ArrayList(Slice) = .empty;
    errdefer {
        for (list.items) |*s| s.deinit(gpa);
        list.deinit(gpa);
    }

    var rows = try db.conn.rows(
        \\SELECT project_id, filename, start_page, end_page, size_bytes,
        \\       kind, kind_key, created_at
        \\FROM slices WHERE project_id = ? ORDER BY created_at ASC
    ,
        .{project_id},
    );
    defer rows.deinit();

    // zqlite 0.0.1 cursor protocol: `next()` returns `?Row` (not `!?Row`).
    // Errors during iteration are surfaced via `rows.err`, which we check after the loop.
    while (rows.next()) |row| {
        const pid = try gpa.dupe(u8, row.text(0));
        errdefer gpa.free(pid);
        const fname = try gpa.dupe(u8, row.text(1));
        errdefer gpa.free(fname);
        const kind_opt: ?SliceKind = if (row.nullableText(5)) |kt| SliceKind.fromText(kt) else null;
        const kk_raw: ?[]const u8 = row.nullableText(6);
        const kk_opt: ?[]const u8 = if (kk_raw) |kk| try gpa.dupe(u8, kk) else null;
        errdefer if (kk_opt) |kk| gpa.free(kk);
        const created = try gpa.dupe(u8, row.text(7));
        errdefer gpa.free(created);

        const slice: Slice = .{
            .project_id = pid,
            .filename = fname,
            .start_page = @intCast(row.int(2)),
            .end_page = @intCast(row.int(3)),
            .size_bytes = @intCast(row.int(4)),
            .kind = kind_opt,
            .kind_key = kk_opt,
            .created_at = created,
        };
        try list.append(gpa, slice);
    }
    if (rows.err) |e| return e;

    return list.toOwnedSlice(gpa);
}

pub fn delete(db: *Db, project_id: []const u8, filename: []const u8) !void {
    try db.conn.exec("DELETE FROM slices WHERE project_id = ? AND filename = ?", .{ project_id, filename });
    if (db.conn.changes() == 0) return error.NotFound;
}

fn seedProject(db: *Db, gpa: Allocator, id: []const u8) !void {
    try projects.insert(db, gpa, .{
        .id = id,
        .name = id,
        .description = null,
        .created_at = "2026-05-24T10:00:00Z",
        .last_opened_at = "2026-05-24T10:00:00Z",
        .chargesheet_filename = "src.pdf",
        .chargesheet_page_count = 100,
        .chargesheet_size_bytes = 1024,
    });
}

test "insert + getByKey round-trips a slice" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();
    try seedProject(&db, gpa, "p1");

    try insert(&db, gpa, .{
        .project_id = "p1",
        .filename = "pages-1-3.pdf",
        .start_page = 1,
        .end_page = 3,
        .size_bytes = 2048,
        .created_at = "2026-05-24T11:00:00Z",
    });

    var got = (try getByKey(&db, gpa, "p1", "pages-1-3.pdf")) orelse return error.TestUnexpectedNull;
    defer got.deinit(gpa);

    try std.testing.expectEqualStrings("p1", got.project_id);
    try std.testing.expectEqualStrings("pages-1-3.pdf", got.filename);
    try std.testing.expectEqual(@as(u32, 1), got.start_page);
    try std.testing.expectEqual(@as(u32, 3), got.end_page);
    try std.testing.expectEqual(@as(u64, 2048), got.size_bytes);
}

test "insert with unknown project_id returns ForeignKeyViolation" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();

    try std.testing.expectError(error.ForeignKeyViolation, insert(&db, gpa, .{
        .project_id = "ghost",
        .filename = "x.pdf",
        .start_page = 1,
        .end_page = 2,
        .size_bytes = 1,
        .created_at = "t",
    }));
}

test "insert with duplicate (project_id, filename) returns UniqueViolation" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();
    try seedProject(&db, gpa, "p1");

    try insert(&db, gpa, .{
        .project_id = "p1",
        .filename = "a.pdf",
        .start_page = 1,
        .end_page = 2,
        .size_bytes = 1,
        .created_at = "t",
    });
    try std.testing.expectError(error.UniqueViolation, insert(&db, gpa, .{
        .project_id = "p1",
        .filename = "a.pdf",
        .start_page = 3,
        .end_page = 4,
        .size_bytes = 1,
        .created_at = "t",
    }));
}

test "insert with end_page < start_page returns CheckViolation" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();
    try seedProject(&db, gpa, "p1");

    try std.testing.expectError(error.CheckViolation, insert(&db, gpa, .{
        .project_id = "p1",
        .filename = "bad.pdf",
        .start_page = 5,
        .end_page = 3,
        .size_bytes = 1,
        .created_at = "t",
    }));
}

test "listByProject returns slices for a project in created_at order" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();
    try seedProject(&db, gpa, "p1");
    try seedProject(&db, gpa, "p2");

    try insert(&db, gpa, .{
        .project_id = "p1",
        .filename = "a.pdf",
        .start_page = 1,
        .end_page = 2,
        .size_bytes = 1,
        .created_at = "2026-05-24T10:00:00Z",
    });
    try insert(&db, gpa, .{
        .project_id = "p1",
        .filename = "b.pdf",
        .start_page = 3,
        .end_page = 4,
        .size_bytes = 1,
        .created_at = "2026-05-24T11:00:00Z",
    });
    try insert(&db, gpa, .{
        .project_id = "p2",
        .filename = "c.pdf",
        .start_page = 1,
        .end_page = 1,
        .size_bytes = 1,
        .created_at = "2026-05-24T12:00:00Z",
    });

    const list = try listByProject(&db, gpa, "p1");
    defer deinitList(list, gpa);

    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqualStrings("a.pdf", list[0].filename);
    try std.testing.expectEqualStrings("b.pdf", list[1].filename);
}

test "delete removes a single slice" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();
    try seedProject(&db, gpa, "p1");

    try insert(&db, gpa, .{
        .project_id = "p1",
        .filename = "a.pdf",
        .start_page = 1,
        .end_page = 2,
        .size_bytes = 1,
        .created_at = "t",
    });
    try delete(&db, "p1", "a.pdf");
    try std.testing.expect(try getByKey(&db, gpa, "p1", "a.pdf") == null);
}

test "delete on missing slice returns NotFound" {
    var db = try test_helpers.openTestDb();
    defer db.close();
    try std.testing.expectError(error.NotFound, delete(&db, "p1", "ghost.pdf"));
}

test "deleting a project cascades to its slices" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();
    try seedProject(&db, gpa, "p1");
    try insert(&db, gpa, .{
        .project_id = "p1",
        .filename = "a.pdf",
        .start_page = 1,
        .end_page = 2,
        .size_bytes = 1,
        .created_at = "t",
    });

    try projects.delete(&db, "p1");
    const list = try listByProject(&db, gpa, "p1");
    defer deinitList(list, gpa);
    try std.testing.expectEqual(@as(usize, 0), list.len);
}

test "parseKindFromFilename: annexure variants" {
    const gpa = std.testing.allocator;

    inline for ([_][]const u8{ "i", "ii", "iii", "iv" }) |roman| {
        const pk = try parseKindFromFilename(gpa, "annexure-" ++ roman ++ ".pdf");
        defer if (pk.kind_key) |kk| gpa.free(kk);
        try std.testing.expectEqual(SliceKind.annexure, pk.kind);
        try std.testing.expectEqualStrings(roman, pk.kind_key.?);
    }
}

test "parseKindFromFilename: rud variants" {
    const gpa = std.testing.allocator;

    const pk1 = try parseKindFromFilename(gpa, "rud-01.pdf");
    defer if (pk1.kind_key) |kk| gpa.free(kk);
    try std.testing.expectEqual(SliceKind.rud, pk1.kind);
    try std.testing.expectEqualStrings("01", pk1.kind_key.?);

    const pk2 = try parseKindFromFilename(gpa, "rud-42.pdf");
    defer if (pk2.kind_key) |kk| gpa.free(kk);
    try std.testing.expectEqual(SliceKind.rud, pk2.kind);
    try std.testing.expectEqualStrings("42", pk2.kind_key.?);
}

test "parseKindFromFilename: non-conforming names are other" {
    const gpa = std.testing.allocator;

    inline for ([_][]const u8{
        "supplement.pdf",          // not annexure / rud
        "annexure-v.pdf",          // Roman not in {i, ii, iii, iv}
        "rud-1.pdf",               // one digit, not two
        "rud-001.pdf",             // three digits, not two
        "annexure-i.txt",          // not .pdf
        "annexure-ii.PDF",         // case-sensitive: must be lowercase
    }) |name| {
        const pk = try parseKindFromFilename(gpa, name);
        defer if (pk.kind_key) |kk| gpa.free(kk);
        try std.testing.expectEqual(SliceKind.other, pk.kind);
        try std.testing.expect(pk.kind_key == null);
    }
}

test "insert + getByKey round-trips kind and kind_key" {
    var db = try Db.open(":memory:");
    defer db.close();
    const gpa = std.testing.allocator;

    try test_helpers.insertProject(&db, "p1");

    try insert(&db, gpa, .{
        .project_id = "p1",
        .filename = "annexure-ii.pdf",
        .start_page = 5,
        .end_page = 10,
        .size_bytes = 1024,
        .kind = .annexure,
        .kind_key = "ii",
        .created_at = "2026-05-28T00:00:00Z",
    });

    var got = (try getByKey(&db, gpa, "p1", "annexure-ii.pdf")).?;
    defer got.deinit(gpa);
    try std.testing.expectEqual(SliceKind.annexure, got.kind.?);
    try std.testing.expectEqualStrings("ii", got.kind_key.?);
}
