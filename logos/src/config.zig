const std = @import("std");
const paths = @import("paths.zig");

pub const AppConfig = struct {
    data_dir: []u8,
    ui_dir: []u8,

    pub fn load(io: std.Io, gpa: std.mem.Allocator, env: *const std.process.Environ.Map) !AppConfig {
        const data_dir = try paths.getAppDataDir(gpa, env);
        errdefer gpa.free(data_dir);
        const ui_dir = try resolveUiDir(io, gpa, env);
        return .{ .data_dir = data_dir, .ui_dir = ui_dir };
    }

    pub fn deinit(self: *AppConfig, gpa: std.mem.Allocator) void {
        gpa.free(self.data_dir);
        gpa.free(self.ui_dir);
    }
};

/// CHARGESHEET_UI_DIR if set (non-empty), else the directory containing the
/// running executable + "/ui". Caller owns the returned slice.
fn resolveUiDir(io: std.Io, gpa: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
    if (env.get("CHARGESHEET_UI_DIR")) |v| {
        if (v.len > 0) return gpa.dupe(u8, v);
    }
    const exe_dir = try std.process.executableDirPathAlloc(io, gpa);
    defer gpa.free(exe_dir);
    return std.fs.path.join(gpa, &.{ exe_dir, "ui" });
}
