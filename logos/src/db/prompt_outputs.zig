const std = @import("std");
const Allocator = std.mem.Allocator;
const Db = @import("db.zig").Db;
const errors = @import("errors.zig");
const test_helpers = @import("test_helpers.zig");

pub const PromptOutput = struct {
    project_id: []const u8,
    prompt_name: []const u8,
    markdown_path: []const u8,
    model: []const u8,
    input_tokens: ?i64 = null,
    output_tokens: ?i64 = null,
    input_cost_usd: ?f64 = null,
    output_cost_usd: ?f64 = null,
    latency_s: f64,
    warnings_json: []const u8, // raw JSON array text; caller parses if needed
    created_at: []const u8,

    pub fn deinit(self: *PromptOutput, gpa: Allocator) void {
        gpa.free(self.project_id);
        gpa.free(self.prompt_name);
        gpa.free(self.markdown_path);
        gpa.free(self.model);
        gpa.free(self.warnings_json);
        gpa.free(self.created_at);
    }
};

pub fn deinitList(list: []PromptOutput, gpa: Allocator) void {
    for (list) |*p| p.deinit(gpa);
    gpa.free(list);
}

pub fn upsert(db: *Db, gpa: Allocator, p: PromptOutput) !void {
    _ = gpa;
    db.conn.exec(
        \\INSERT INTO prompt_outputs
        \\  (project_id, prompt_name, markdown_path, model,
        \\   input_tokens, output_tokens, input_cost_usd, output_cost_usd,
        \\   latency_s, warnings, created_at)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        \\ON CONFLICT(project_id, prompt_name) DO UPDATE SET
        \\  markdown_path   = excluded.markdown_path,
        \\  model           = excluded.model,
        \\  input_tokens    = excluded.input_tokens,
        \\  output_tokens   = excluded.output_tokens,
        \\  input_cost_usd  = excluded.input_cost_usd,
        \\  output_cost_usd = excluded.output_cost_usd,
        \\  latency_s       = excluded.latency_s,
        \\  warnings        = excluded.warnings,
        \\  created_at      = excluded.created_at
    , .{
        p.project_id,
        p.prompt_name,
        p.markdown_path,
        p.model,
        p.input_tokens,
        p.output_tokens,
        p.input_cost_usd,
        p.output_cost_usd,
        p.latency_s,
        p.warnings_json,
        p.created_at,
    }) catch |err| return errors.mapConstraintErr(err);
}

pub fn getByKey(
    db: *Db,
    gpa: Allocator,
    project_id: []const u8,
    prompt_name: []const u8,
) !?PromptOutput {
    const row = (try db.conn.row(
        \\SELECT project_id, prompt_name, markdown_path, model,
        \\       input_tokens, output_tokens, input_cost_usd, output_cost_usd,
        \\       latency_s, warnings, created_at
        \\FROM prompt_outputs WHERE project_id = ? AND prompt_name = ?
    , .{ project_id, prompt_name })) orelse return null;
    defer row.deinit();

    return try rowToPromptOutput(row, gpa);
}

pub fn listByProject(db: *Db, gpa: Allocator, project_id: []const u8) ![]PromptOutput {
    var list: std.ArrayList(PromptOutput) = .empty;
    errdefer {
        for (list.items) |*p| p.deinit(gpa);
        list.deinit(gpa);
    }
    var rows = try db.conn.rows(
        \\SELECT project_id, prompt_name, markdown_path, model,
        \\       input_tokens, output_tokens, input_cost_usd, output_cost_usd,
        \\       latency_s, warnings, created_at
        \\FROM prompt_outputs WHERE project_id = ? ORDER BY prompt_name ASC
    , .{project_id});
    defer rows.deinit();

    while (rows.next()) |row| {
        const p = try rowToPromptOutput(row, gpa);
        try list.append(gpa, p);
    }
    if (rows.err) |e| return e;
    return try list.toOwnedSlice(gpa);
}

fn rowToPromptOutput(row: anytype, gpa: Allocator) !PromptOutput {
    const pid = try gpa.dupe(u8, row.text(0));
    errdefer gpa.free(pid);
    const pn = try gpa.dupe(u8, row.text(1));
    errdefer gpa.free(pn);
    const md = try gpa.dupe(u8, row.text(2));
    errdefer gpa.free(md);
    const mdl = try gpa.dupe(u8, row.text(3));
    errdefer gpa.free(mdl);
    const warnings = try gpa.dupe(u8, row.text(9));
    errdefer gpa.free(warnings);
    const created = try gpa.dupe(u8, row.text(10));
    errdefer gpa.free(created);

    return .{
        .project_id = pid,
        .prompt_name = pn,
        .markdown_path = md,
        .model = mdl,
        .input_tokens = row.nullableInt(4),
        .output_tokens = row.nullableInt(5),
        .input_cost_usd = row.nullableFloat(6),
        .output_cost_usd = row.nullableFloat(7),
        .latency_s = row.float(8),
        .warnings_json = warnings,
        .created_at = created,
    };
}

test "upsert + getByKey round-trip" {
    var db = try Db.open(":memory:");
    defer db.close();
    const gpa = std.testing.allocator;
    try test_helpers.insertProject(&db, "p1");

    try upsert(&db, gpa, .{
        .project_id = "p1",
        .prompt_name = "evidence_audit",
        .markdown_path = "/tmp/ea.md",
        .model = "claude-sonnet-4-6",
        .input_tokens = 50000,
        .output_tokens = 10000,
        .input_cost_usd = 0.15,
        .output_cost_usd = 0.15,
        .latency_s = 42.0,
        .warnings_json = "[]",
        .created_at = "2026-05-28T00:00:00Z",
    });

    var got = (try getByKey(&db, gpa, "p1", "evidence_audit")).?;
    defer got.deinit(gpa);
    try std.testing.expectEqualStrings("/tmp/ea.md", got.markdown_path);
    try std.testing.expectEqualStrings("claude-sonnet-4-6", got.model);
    try std.testing.expectEqualStrings("[]", got.warnings_json);
}

test "upsert overwrites and warnings can be updated" {
    var db = try Db.open(":memory:");
    defer db.close();
    const gpa = std.testing.allocator;
    try test_helpers.insertProject(&db, "p1");

    const base = PromptOutput{
        .project_id = "p1",
        .prompt_name = "evidence_audit",
        .markdown_path = "/v1.md",
        .model = "gemini-2.5-flash",
        .latency_s = 5.0,
        .warnings_json = "[]",
        .created_at = "2026-05-28T00:00:00Z",
    };
    try upsert(&db, gpa, base);

    var updated = base;
    updated.markdown_path = "/v2.md";
    updated.warnings_json = "[\"empty_output\"]";
    try upsert(&db, gpa, updated);

    var got = (try getByKey(&db, gpa, "p1", "evidence_audit")).?;
    defer got.deinit(gpa);
    try std.testing.expectEqualStrings("/v2.md", got.markdown_path);
    try std.testing.expectEqualStrings("[\"empty_output\"]", got.warnings_json);
}

test "deleting a project cascades to prompt_outputs" {
    var db = try Db.open(":memory:");
    defer db.close();
    const gpa = std.testing.allocator;
    try test_helpers.insertProject(&db, "p1");

    try upsert(&db, gpa, .{
        .project_id = "p1",
        .prompt_name = "evidence_audit",
        .markdown_path = "/x.md",
        .model = "claude-sonnet-4-6",
        .latency_s = 1.0,
        .warnings_json = "[]",
        .created_at = "2026-05-28T00:00:00Z",
    });

    // Verify the row is present BEFORE delete (otherwise the cascade assertion is meaningless)
    {
        const pre = try getByKey(&db, gpa, "p1", "evidence_audit");
        try std.testing.expect(pre != null);
        var mp = pre.?;
        mp.deinit(gpa);
    }

    try db.conn.exec("DELETE FROM projects WHERE id=?", .{"p1"});

    try std.testing.expect((try getByKey(&db, gpa, "p1", "evidence_audit")) == null);
}
