//! Serve the web UI's static files from a directory on disk, with MIME by
//! extension, SPA fallback to index.html, and a path-traversal guard.
const std = @import("std");

pub const Served = union(enum) {
    /// Serve this file: read abs_path, respond 200 with `mime`. Caller frees abs_path.
    file: struct { abs_path: []u8, mime: []const u8 },
    /// No UI present (ui_dir missing / no index.html) — serve the dev placeholder.
    placeholder,
    /// Not a static concern (/api/* or non-GET) — caller decides (404 / API).
    not_handled,
};

pub fn mimeForPath(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    if (std.mem.eql(u8, ext, ".html")) return "text/html";
    if (std.mem.eql(u8, ext, ".js")) return "text/javascript";
    if (std.mem.eql(u8, ext, ".css")) return "text/css";
    if (std.mem.eql(u8, ext, ".json")) return "application/json";
    if (std.mem.eql(u8, ext, ".svg")) return "image/svg+xml";
    if (std.mem.eql(u8, ext, ".png")) return "image/png";
    if (std.mem.eql(u8, ext, ".ico")) return "image/x-icon";
    if (std.mem.eql(u8, ext, ".woff2")) return "font/woff2";
    if (std.mem.eql(u8, ext, ".webmanifest")) return "application/manifest+json";
    if (std.mem.eql(u8, ext, ".txt")) return "text/plain";
    return "application/octet-stream";
}

/// A URL path is safe iff none of its '/'-separated components is "", ".", or
/// "..", and it contains no '\' or NUL. Leading '/' is expected and ignored.
fn isSafeUrlPath(path: []const u8) bool {
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return false;
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return false;
    }
    return true;
}

/// Does `<dir>/<rel>` exist as a regular file? Returns the joined abs path
/// (caller owns) on success, null if it does not exist / cannot be opened.
fn fileExists(io: std.Io, dir: []const u8, rel: []const u8, gpa: std.mem.Allocator) !?[]u8 {
    const abs = try std.fs.path.join(gpa, &.{ dir, rel });
    errdefer gpa.free(abs);
    const f = std.Io.Dir.cwd().openFile(io, abs, .{ .mode = .read_only }) catch {
        gpa.free(abs);
        return null;
    };
    f.close(io);
    return abs; // caller owns
}

/// Strip the query string (everything from the first '?') off a request target,
/// returning just the path portion. Static file lookups must use the on-disk
/// path, not the cache-busting `?v=...` params SvelteKit/Vite attach to assets.
pub fn stripQuery(target: []const u8) []const u8 {
    return target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
}

/// Resolve a request to a static file under `ui_dir`, with SPA fallback.
pub fn resolve(
    io: std.Io,
    gpa: std.mem.Allocator,
    ui_dir: []const u8,
    method_is_get: bool,
    path: []const u8,
) !Served {
    if (!method_is_get) return .not_handled;
    if (std.mem.startsWith(u8, path, "/api/")) return .not_handled;

    // ui_dir present?
    var d = std.Io.Dir.cwd().openDir(io, ui_dir, .{}) catch return .placeholder;
    d.close(io);

    // Try the exact (safe) file.
    if (isSafeUrlPath(path)) {
        const rel = if (std.mem.eql(u8, path, "/")) "index.html" else std.mem.trimStart(u8, path, "/");
        if (try fileExists(io, ui_dir, rel, gpa)) |abs| {
            return .{ .file = .{ .abs_path = abs, .mime = mimeForPath(rel) } };
        }
    }

    // SPA fallback (also covers unsafe paths → never serves outside ui_dir).
    if (try fileExists(io, ui_dir, "index.html", gpa)) |abs| {
        return .{ .file = .{ .abs_path = abs, .mime = "text/html" } };
    }
    return .placeholder;
}

const testing = std.testing;

fn writeFixture(io: std.Io, dir: std.Io.Dir, rel: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(rel)) |sub| try dir.createDirPath(io, sub);
    var f = try dir.createFile(io, rel, .{ .truncate = true });
    defer f.close(io);
    try f.writeStreamingAll(io, bytes);
}

test "static.resolve against a fixture ui dir" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Build the cwd-relative path to the tmp dir (matches project_dir.zig test pattern).
    const ui_dir = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(ui_dir);

    try writeFixture(io, tmp.dir, "index.html", "<!doctype html>app");
    try writeFixture(io, tmp.dir, "_app/immutable/app.js", "console.log(1)");
    try writeFixture(io, tmp.dir, "styles.css", "body{}");

    // exact hit
    {
        const r = try resolve(io, gpa, ui_dir, true, "/_app/immutable/app.js");
        try testing.expect(r == .file);
        defer gpa.free(r.file.abs_path);
        try testing.expectEqualStrings("text/javascript", r.file.mime);
    }
    // root → index.html
    {
        const r = try resolve(io, gpa, ui_dir, true, "/");
        try testing.expect(r == .file);
        defer gpa.free(r.file.abs_path);
        try testing.expectEqualStrings("text/html", r.file.mime);
    }
    // unknown → SPA fallback to index.html
    {
        const r = try resolve(io, gpa, ui_dir, true, "/projects/abc");
        try testing.expect(r == .file);
        defer gpa.free(r.file.abs_path);
        try testing.expect(std.mem.endsWith(u8, r.file.abs_path, "index.html"));
    }
    // /api → not_handled
    try testing.expect((try resolve(io, gpa, ui_dir, true, "/api/v1/health")) == .not_handled);
    // non-GET → not_handled
    try testing.expect((try resolve(io, gpa, ui_dir, false, "/")) == .not_handled);
    // traversal → never escapes ui_dir (falls back to index.html within ui_dir)
    {
        const r = try resolve(io, gpa, ui_dir, true, "/../../../etc/passwd");
        try testing.expect(r == .file);
        defer gpa.free(r.file.abs_path);
        try testing.expect(std.mem.endsWith(u8, r.file.abs_path, "index.html"));
        try testing.expect(std.mem.indexOf(u8, r.file.abs_path, "etc/passwd") == null);
    }
}

test "static.resolve with missing ui dir → placeholder" {
    const gpa = testing.allocator;
    try testing.expect((try resolve(testing.io, gpa, "/nonexistent/ui/dir/xyz", true, "/")) == .placeholder);
}

test "stripQuery removes cache-busting params" {
    try testing.expectEqualStrings("/x.js", stripQuery("/x.js?v=2"));
    try testing.expectEqualStrings("/x.js", stripQuery("/x.js"));
    try testing.expectEqualStrings("/", stripQuery("/"));
    try testing.expectEqualStrings("/a", stripQuery("/a?b?c"));
}

test "mimeForPath coverage" {
    try testing.expectEqualStrings("text/javascript", mimeForPath("/x.js"));
    try testing.expectEqualStrings("image/png", mimeForPath("/favicon.png"));
    try testing.expectEqualStrings("application/octet-stream", mimeForPath("/weird.xyz"));
}
