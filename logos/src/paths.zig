const std = @import("std");
const builtin = @import("builtin");

const env_override = "CHARGESHEET_DATA_DIR";

pub fn getAppDataDir(gpa: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
    if (env.get(env_override)) |dir| {
        return gpa.dupe(u8, dir);
    }

    switch (builtin.os.tag) {
        .macos => {
            const home = env.get("HOME") orelse return error.HomeNotFound;
            return std.fs.path.join(gpa, &.{ home, "Library", "Application Support", "ChargesheetTool" });
        },
        .linux => {
            if (env.get("XDG_DATA_HOME")) |xdg| {
                return std.fs.path.join(gpa, &.{ xdg, "chargesheet-tool" });
            }
            const home = env.get("HOME") orelse return error.HomeNotFound;
            return std.fs.path.join(gpa, &.{ home, ".local", "share", "chargesheet-tool" });
        },
        .windows => {
            const local = env.get("LOCALAPPDATA") orelse return error.LocalAppDataNotFound;
            return std.fs.path.join(gpa, &.{ local, "ChargesheetTool" });
        },
        else => return error.UnsupportedPlatform,
    }
}
