const std = @import("std");

/// Generate `<prefix>_<uuid-v4-with-dashes>`. Allocates `prefix.len + 1 + 36` bytes.
/// Caller owns the returned slice.
fn generateIdWithPrefix(io: std.Io, gpa: std.mem.Allocator, prefix: []const u8) ![]u8 {
    var bytes: [16]u8 = undefined;
    io.random(&bytes);
    // RFC 4122 v4 fixed bits
    bytes[6] = (bytes[6] & 0x0F) | 0x40;
    bytes[8] = (bytes[8] & 0x3F) | 0x80;

    const total_len = prefix.len + 1 + 36;
    const buf = try gpa.alloc(u8, total_len);
    errdefer gpa.free(buf);

    _ = try std.fmt.bufPrint(buf,
        "{s}_{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{ prefix,
           bytes[0], bytes[1], bytes[2], bytes[3],
           bytes[4], bytes[5], bytes[6], bytes[7],
           bytes[8], bytes[9], bytes[10], bytes[11],
           bytes[12], bytes[13], bytes[14], bytes[15] });
    return buf;
}

pub fn generateProjectId(io: std.Io, gpa: std.mem.Allocator) ![]u8 {
    return generateIdWithPrefix(io, gpa, "proj");
}

pub fn generateJobId(io: std.Io, gpa: std.mem.Allocator) ![]u8 {
    return generateIdWithPrefix(io, gpa, "job");
}

test "generateProjectId returns a 41-char proj_<uuid>" {
    const gpa = std.testing.allocator;
    const id = try generateProjectId(std.testing.io, gpa);
    defer gpa.free(id);
    try std.testing.expectEqual(@as(usize, 41), id.len);
    try std.testing.expectEqualStrings("proj_", id[0..5]);
    try std.testing.expectEqual(@as(u8, '-'), id[13]);
    try std.testing.expectEqual(@as(u8, '-'), id[18]);
    try std.testing.expectEqual(@as(u8, '-'), id[23]);
    try std.testing.expectEqual(@as(u8, '-'), id[28]);
}

test "generateJobId returns a 40-char job_<uuid>" {
    const gpa = std.testing.allocator;
    const id = try generateJobId(std.testing.io, gpa);
    defer gpa.free(id);
    try std.testing.expectEqual(@as(usize, 40), id.len);
    try std.testing.expectEqualStrings("job_", id[0..4]);
}

test "two ids are different" {
    const gpa = std.testing.allocator;
    const a = try generateProjectId(std.testing.io, gpa);
    defer gpa.free(a);
    const b = try generateProjectId(std.testing.io, gpa);
    defer gpa.free(b);
    try std.testing.expect(!std.mem.eql(u8, a, b));
}
