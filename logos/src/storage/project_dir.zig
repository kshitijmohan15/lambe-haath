//! Filesystem layout for per-project data.
//!
//!   data_dir/<project_id>/chargesheet.pdf  -- uploaded source PDF
//!   data_dir/<project_id>/slices/<name>    -- output PDFs (Phase 8b)

const std = @import("std");

/// Create the project directory tree. Idempotent — succeeds if the dirs already exist.
pub fn createProjectTree(io: std.Io, data_dir: []const u8, project_id: []const u8, gpa: std.mem.Allocator) !void {
    const proj_dir = try std.fs.path.join(gpa, &.{ data_dir, project_id });
    defer gpa.free(proj_dir);
    const slices_dir = try std.fs.path.join(gpa, &.{ proj_dir, "slices" });
    defer gpa.free(slices_dir);
    try std.Io.Dir.cwd().createDirPath(io, proj_dir);
    try std.Io.Dir.cwd().createDirPath(io, slices_dir);
}

/// Write the chargesheet PDF bytes to `<data_dir>/<project_id>/chargesheet.pdf`.
pub fn writeChargesheet(io: std.Io, data_dir: []const u8, project_id: []const u8, bytes: []const u8, gpa: std.mem.Allocator) !void {
    const path = try chargesheetPath(gpa, data_dir, project_id);
    defer gpa.free(path);
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}

/// Compute the chargesheet path. Caller frees.
pub fn chargesheetPath(gpa: std.mem.Allocator, data_dir: []const u8, project_id: []const u8) ![]u8 {
    return std.fs.path.join(gpa, &.{ data_dir, project_id, "chargesheet.pdf" });
}

/// Remove a project's entire directory tree (chargesheet + slices). Used on DELETE.
pub fn removeProjectTree(io: std.Io, data_dir: []const u8, project_id: []const u8, gpa: std.mem.Allocator) !void {
    const proj_dir = try std.fs.path.join(gpa, &.{ data_dir, project_id });
    defer gpa.free(proj_dir);
    try std.Io.Dir.cwd().deleteTree(io, proj_dir);
}

// --- Tests ---
//
// We can't use `tmp.dir.realpathAlloc(...)` (does not exist in Zig 0.16's Io.Dir).
// Instead, we rely on the documented layout of `std.testing.tmpDir`, which creates
// the tmp dir at `.zig-cache/tmp/<sub_path>` relative to cwd. Our helpers all take
// a `data_dir: []const u8` and feed it into `std.Io.Dir.cwd()` operations, so a
// cwd-relative path works just as well as an absolute one.

fn tmpDataDir(gpa: std.mem.Allocator, sub_path: []const u8) ![]u8 {
    return std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", sub_path });
}

test "createProjectTree + writeChargesheet + chargesheetPath round-trips" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(gpa, &tmp.sub_path);
    defer gpa.free(data_dir);

    try createProjectTree(io, data_dir, "proj_test", gpa);
    try writeChargesheet(io, data_dir, "proj_test", "%PDF-1.7 dummy", gpa);

    const path = try chargesheetPath(gpa, data_dir, "proj_test");
    defer gpa.free(path);

    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);
    var buf: [20]u8 = undefined;
    const n = try file.readPositionalAll(io, &buf, 0);
    try std.testing.expectEqualStrings("%PDF-1.7 dummy", buf[0..n]);
}

test "removeProjectTree cleans up" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(gpa, &tmp.sub_path);
    defer gpa.free(data_dir);

    try createProjectTree(io, data_dir, "proj_doomed", gpa);
    try writeChargesheet(io, data_dir, "proj_doomed", "x", gpa);
    try removeProjectTree(io, data_dir, "proj_doomed", gpa);

    const path = try chargesheetPath(gpa, data_dir, "proj_doomed");
    defer gpa.free(path);
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }),
    );
}

/// Return true if `name` is safe to use as a slice filename — no path separators,
/// not `.` or `..`, length 1..255. Mirrors the mock-daemon's `isSafeFilename`.
pub fn isSafeFilename(name: []const u8) bool {
    if (name.len == 0 or name.len > 255) return false;
    if (std.mem.indexOfScalar(u8, name, '/') != null) return false;
    if (std.mem.indexOfScalar(u8, name, '\\') != null) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    return true;
}

/// Compute the slice path. Caller frees.
pub fn slicePath(gpa: std.mem.Allocator, data_dir: []const u8, project_id: []const u8, filename: []const u8) ![]u8 {
    return std.fs.path.join(gpa, &.{ data_dir, project_id, "slices", filename });
}

/// Remove a single slice file. Returns error.FileNotFound if absent.
pub fn removeSlice(io: std.Io, gpa: std.mem.Allocator, data_dir: []const u8, project_id: []const u8, filename: []const u8) !void {
    const path = try slicePath(gpa, data_dir, project_id, filename);
    defer gpa.free(path);
    try std.Io.Dir.cwd().deleteFile(io, path);
}

test "isSafeFilename rejects path traversal" {
    try std.testing.expect(!isSafeFilename(""));
    try std.testing.expect(!isSafeFilename("."));
    try std.testing.expect(!isSafeFilename(".."));
    try std.testing.expect(!isSafeFilename("a/b"));
    try std.testing.expect(!isSafeFilename("a\\b"));
    try std.testing.expect(isSafeFilename("foo.pdf"));
    try std.testing.expect(isSafeFilename("intro-pages-1-3.pdf"));
}

test "isSafeFilename enforces length bounds" {
    try std.testing.expect(!isSafeFilename(""));
    var buf: [255]u8 = undefined;
    @memset(&buf, 'a');
    try std.testing.expect(isSafeFilename(&buf));
    var buf2: [256]u8 = undefined;
    @memset(&buf2, 'a');
    try std.testing.expect(!isSafeFilename(&buf2));
}
