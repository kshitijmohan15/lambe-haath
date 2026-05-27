const std = @import("std");
const paths = @import("paths.zig");

pub const AppConfig = struct {
    data_dir: []u8,

    pub fn load(gpa: std.mem.Allocator, env: *const std.process.Environ.Map) !AppConfig {
        return .{
            .data_dir = try paths.getAppDataDir(gpa, env),
        };
    }

    pub fn deinit(self: *AppConfig, gpa: std.mem.Allocator) void {
        gpa.free(self.data_dir);
    }
};
