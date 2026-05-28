const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;

pub const AgentSpec = struct {
    kind: []const u8,
    command: []const u8,
    args: []const []const u8,
    max_workers: u32,
    model: []const u8,

    pub fn deinit(self: *AgentSpec, gpa: Allocator) void {
        gpa.free(self.kind);
        gpa.free(self.command);
        for (self.args) |a| gpa.free(a);
        gpa.free(self.args);
        gpa.free(self.model);
    }
};

pub const AgentConfig = struct {
    agents: []AgentSpec,

    pub fn deinit(self: *AgentConfig, gpa: Allocator) void {
        for (self.agents) |*a| a.deinit(gpa);
        gpa.free(self.agents);
    }

    pub fn find(self: *const AgentConfig, kind: []const u8) ?*const AgentSpec {
        for (self.agents) |*a| {
            if (std.mem.eql(u8, a.kind, kind)) return a;
        }
        return null;
    }
};

const default_config_text =
    \\{
    \\  "agents": [
    \\    {"kind": "ocr",    "command": "python3", "args": ["-m", "agents.ocr_agent"],    "max_workers": 2, "model": "gemini-2.5-flash"},
    \\    {"kind": "prompt", "command": "python3", "args": ["-m", "agents.prompt_agent"], "max_workers": 5, "model": "claude-sonnet-4-6"}
    \\  ]
    \\}
;

pub const LoadError = error{
    InvalidJson,
    MissingAgentsArray,
    InvalidAgentSpec,
    OutOfMemory,
};

/// Load agents.json from `<data_dir>/agents.json`. If the file does not exist,
/// return the hardcoded default configuration so a fresh install works
/// without manual setup.
pub fn loadFromDir(io: std.Io, gpa: Allocator, data_dir: []const u8) !AgentConfig {
    const path = try std.fs.path.join(gpa, &.{ data_dir, "agents.json" });
    defer gpa.free(path);

    const file_text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return parseJson(gpa, default_config_text),
        else => return err,
    };
    defer gpa.free(file_text);
    return parseJson(gpa, file_text);
}

pub fn parseJson(gpa: Allocator, text: []const u8) LoadError!AgentConfig {
    var parsed = json.parseFromSlice(json.Value, gpa, text, .{}) catch return LoadError.InvalidJson;
    defer parsed.deinit();

    if (parsed.value != .object) return LoadError.InvalidJson;
    const agents_val = parsed.value.object.get("agents") orelse return LoadError.MissingAgentsArray;
    if (agents_val != .array) return LoadError.MissingAgentsArray;

    var list = try gpa.alloc(AgentSpec, agents_val.array.items.len);
    var filled: usize = 0;
    errdefer {
        for (list[0..filled]) |*a| a.deinit(gpa);
        gpa.free(list);
    }

    for (agents_val.array.items, 0..) |item, i| {
        if (item != .object) return LoadError.InvalidAgentSpec;
        const obj = item.object;
        const kind_v = obj.get("kind") orelse return LoadError.InvalidAgentSpec;
        const command_v = obj.get("command") orelse return LoadError.InvalidAgentSpec;
        const args_v = obj.get("args") orelse return LoadError.InvalidAgentSpec;
        const mw_v = obj.get("max_workers") orelse return LoadError.InvalidAgentSpec;
        const model_v = obj.get("model") orelse return LoadError.InvalidAgentSpec;

        if (kind_v != .string or command_v != .string or model_v != .string) return LoadError.InvalidAgentSpec;
        if (args_v != .array) return LoadError.InvalidAgentSpec;
        if (mw_v != .integer or mw_v.integer < 1) return LoadError.InvalidAgentSpec;

        const kind = try gpa.dupe(u8, kind_v.string);
        errdefer gpa.free(kind);
        const command = try gpa.dupe(u8, command_v.string);
        errdefer gpa.free(command);
        const model = try gpa.dupe(u8, model_v.string);
        errdefer gpa.free(model);

        const args_slice = try gpa.alloc([]const u8, args_v.array.items.len);
        var args_filled: usize = 0;
        errdefer {
            for (args_slice[0..args_filled]) |s| gpa.free(s);
            gpa.free(args_slice);
        }
        for (args_v.array.items) |arg_item| {
            if (arg_item != .string) return LoadError.InvalidAgentSpec;
            args_slice[args_filled] = try gpa.dupe(u8, arg_item.string);
            args_filled += 1;
        }

        list[i] = .{
            .kind = kind,
            .command = command,
            .args = args_slice,
            .max_workers = @intCast(mw_v.integer),
            .model = model,
        };
        filled += 1;
    }

    return .{ .agents = list };
}

test "parseJson accepts the default config text" {
    const gpa = std.testing.allocator;
    var cfg = try parseJson(gpa, default_config_text);
    defer cfg.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), cfg.agents.len);
    try std.testing.expectEqualStrings("ocr", cfg.agents[0].kind);
    try std.testing.expectEqualStrings("python3", cfg.agents[0].command);
    try std.testing.expectEqual(@as(u32, 2), cfg.agents[0].max_workers);
    try std.testing.expectEqualStrings("gemini-2.5-flash", cfg.agents[0].model);
    try std.testing.expectEqualStrings("prompt", cfg.agents[1].kind);
    try std.testing.expectEqual(@as(u32, 5), cfg.agents[1].max_workers);
}

test "parseJson rejects missing agents array" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(
        LoadError.MissingAgentsArray,
        parseJson(gpa, "{}"),
    );
}

test "parseJson rejects max_workers < 1" {
    const gpa = std.testing.allocator;
    const text =
        \\{"agents":[{"kind":"x","command":"y","args":[],"max_workers":0,"model":"m"}]}
    ;
    try std.testing.expectError(
        LoadError.InvalidAgentSpec,
        parseJson(gpa, text),
    );
}

test "parseJson rejects missing model field" {
    const gpa = std.testing.allocator;
    const text =
        \\{"agents":[{"kind":"x","command":"y","args":[],"max_workers":1}]}
    ;
    try std.testing.expectError(
        LoadError.InvalidAgentSpec,
        parseJson(gpa, text),
    );
}

test "AgentConfig.find returns the right spec" {
    const gpa = std.testing.allocator;
    var cfg = try parseJson(gpa, default_config_text);
    defer cfg.deinit(gpa);

    const ocr = cfg.find("ocr") orelse return error.NotFound;
    try std.testing.expectEqualStrings("python3", ocr.command);

    try std.testing.expect(cfg.find("nonexistent") == null);
}

test "loadFromDir falls back to default when agents.json missing" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Zig 0.16: tmpDir creates dirs at .zig-cache/tmp/<sub_path> relative to cwd.
    // Use cwd-relative path — matches project_dir.zig test pattern.
    const dir_path = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(dir_path);

    var cfg = try loadFromDir(io, gpa, dir_path);
    defer cfg.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), cfg.agents.len);
    try std.testing.expectEqualStrings("ocr", cfg.agents[0].kind);
}
