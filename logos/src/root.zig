//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;

/// This is a documentation comment to explain the `printAnotherMessage` function below.
///
/// Accepting an `Io.Writer` instance is a handy way to write reusable code.
pub fn printAnotherMessage(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("Run `zig build test` to run the tests.\n", .{});
}

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try std.testing.expect(add(3, 7) == 10);
}

pub const extractions = @import("db/extractions.zig");
pub const handlers_ocr = @import("api/handlers_ocr.zig");
pub const handlers_prompts = @import("api/handlers_prompts.zig");
pub const prompt_outputs = @import("db/prompt_outputs.zig");
pub const job_logs = @import("db/job_logs.zig");
pub const pricing = @import("agents/pricing.zig");
pub const jsonrpc = @import("agents/jsonrpc.zig");
pub const agent_config = @import("agents/config.zig");
pub const event_channel = @import("agents/event_channel.zig");
pub const worker = @import("agents/worker.zig");
pub const supervisor = @import("agents/supervisor.zig");
pub const dispatcher = @import("agents/dispatcher.zig");
pub const handlers_jobs = @import("api/handlers_jobs.zig");
