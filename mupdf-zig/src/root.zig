const std = @import("std");
const c = @import("c");

/// Return the MuPDF library version string (e.g. "1.27.2"). Static lifetime.
pub fn version() []const u8 {
    return std.mem.span(c.mupdf_zig_bridge_fz_version());
}

test "version returns a non-empty MuPDF version string" {
    const v = version();
    try std.testing.expect(v.len > 0);
    try std.testing.expect(std.mem.indexOfScalar(u8, v, '.') != null);
}

pub const Error = @import("errors.zig").Error;
pub const Context = @import("context.zig").Context;
pub const Document = @import("document.zig").Document;

test {
    _ = @import("errors.zig");
    _ = @import("context.zig");
    _ = @import("document.zig");
}
