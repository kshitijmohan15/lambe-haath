const std = @import("std");
const Allocator = std.mem.Allocator;
const Db = @import("../db/db.zig").Db;
const stats = @import("../db/stats.zig");

pub const Overview = struct {
    lifetime: stats.LifetimeTotals,
    per_model: []stats.ModelTotals,
    top_projects: []stats.ProjectTotals,

    pub fn deinit(self: *Overview, gpa: Allocator) void {
        stats.deinitModelList(self.per_model, gpa);
        stats.deinitProjectList(self.top_projects, gpa);
    }
};

pub fn getOverview(db: *Db, gpa: Allocator) !Overview {
    const lifetime = try stats.lifetimeTotals(db);
    const per_model = try stats.perModel(db, gpa);
    errdefer stats.deinitModelList(per_model, gpa);
    const top = try stats.topCostProjects(db, gpa, 10);
    errdefer stats.deinitProjectList(top, gpa);
    return .{ .lifetime = lifetime, .per_model = per_model, .top_projects = top };
}

pub fn getProject(db: *Db, gpa: Allocator, project_id: []const u8) !stats.ProjectTotals {
    return try stats.perProject(db, gpa, project_id);
}

pub fn getTimeseries(db: *Db, gpa: Allocator, from: []const u8, to: []const u8) ![]stats.DayBucket {
    return try stats.timeseries(db, gpa, from, to);
}

pub fn getSlow(db: *Db, gpa: Allocator, limit: u32) ![]stats.SlowJob {
    return try stats.slowJobs(db, gpa, limit);
}

test "handlers_stats compiles and getOverview returns empty for empty DB" {
    var db = try Db.open(":memory:");
    defer db.close();
    const gpa = std.testing.allocator;

    var ov = try getOverview(&db, gpa);
    defer ov.deinit(gpa);
    try std.testing.expectEqual(@as(i64, 0), ov.lifetime.ocr.runs);
    try std.testing.expectEqual(@as(usize, 0), ov.per_model.len);
    try std.testing.expectEqual(@as(usize, 0), ov.top_projects.len);
}
