const std = @import("std");
const builtin = @import("builtin");

const env_override = "CHARGESHEET_DATA_DIR";
const agents_dir_env = "LAMBE_AGENTS_DIR";

/// Locate the `agents/` directory containing the Python entrypoints.
/// Returns an owned slice (caller frees) or error.AgentsDirNotFound if no
/// candidate directory exists.
///
/// Resolution order:
///   1. LAMBE_AGENTS_DIR env var — if set and the directory exists, use it.
///   2. <binary_dir>/../agents — canonical install layout (bin/ lives next to agents/).
///   3. <binary_dir>/../../agents — dev layout (zig-out/bin/logos → repo root/agents).
///   4. ./agents relative to CWD — backward compat when launching from source.
pub fn resolveAgentsDir(io: std.Io, gpa: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
    // 1. Env var override.
    if (env.get(agents_dir_env)) |dir| {
        const owned = try gpa.dupe(u8, dir);
        errdefer gpa.free(owned);
        var d = std.Io.Dir.cwd().openDir(io, owned, .{}) catch return error.AgentsDirNotFound;
        d.close(io);
        return owned;
    }

    // 2 & 3. Binary-relative candidates.
    if (std.process.executableDirPathAlloc(io, gpa)) |exe_dir| {
        defer gpa.free(exe_dir);

        // <binary_dir>/../agents
        const c1 = try std.fs.path.join(gpa, &.{ exe_dir, "..", "agents" });
        if (dirExistsIo(io, c1)) return c1;
        gpa.free(c1);

        // <binary_dir>/../../agents
        const c2 = try std.fs.path.join(gpa, &.{ exe_dir, "..", "..", "agents" });
        if (dirExistsIo(io, c2)) return c2;
        gpa.free(c2);
    } else |_| {}

    // 4. CWD-relative fallback.
    const cwd_rel = try gpa.dupe(u8, "agents");
    if (dirExistsIo(io, cwd_rel)) return cwd_rel;
    gpa.free(cwd_rel);

    return error.AgentsDirNotFound;
}

fn dirExistsIo(io: std.Io, path: []const u8) bool {
    var d = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    d.close(io);
    return true;
}

// --- Tests ---

test "resolveAgentsDir: LAMBE_AGENTS_DIR set + directory exists → returns it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Create a real tmp dir to serve as the "agents" directory.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(dir_path);

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put(agents_dir_env, dir_path);

    const result = try resolveAgentsDir(io, gpa, &env);
    defer gpa.free(result);
    try std.testing.expectEqualStrings(dir_path, result);
}

test "resolveAgentsDir: LAMBE_AGENTS_DIR set + missing → AgentsDirNotFound" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    // Point to a path that definitely doesn't exist.
    try env.put(agents_dir_env, "/tmp/lambe-haath-test-agents-should-not-exist-xyzzy");

    try std.testing.expectError(
        error.AgentsDirNotFound,
        resolveAgentsDir(io, gpa, &env),
    );
}

test "resolveAgentsDir: no env + binary-relative or cwd fallback resolves when agents/ exists" {
    // This test only verifies that resolveAgentsDir doesn't crash and returns
    // a path when at least one candidate exists.  In the test runner environment
    // the binary lives at zig-out/bin/test-binary, so <binary_dir>/../../agents
    // (i.e. repo_root/agents) should resolve if the codebase has been migrated.
    // If no candidate exists (CI without agents/) the function must return
    // error.AgentsDirNotFound — either result is acceptable here; we just
    // verify there's no memory leak or panic.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    if (resolveAgentsDir(io, gpa, &env)) |path| {
        defer gpa.free(path);
        // Must be non-empty if resolution succeeded.
        try std.testing.expect(path.len > 0);
    } else |err| {
        // AgentsDirNotFound is the only acceptable error.
        try std.testing.expectEqual(error.AgentsDirNotFound, err);
    }
}

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
