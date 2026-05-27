const std = @import("std");
const c = @import("c");
const errors = @import("errors.zig");

/// MuPDF context handle. Required for all document operations.
///
/// THREAD SAFETY: An `fz_context` is non-reentrant. Do NOT share a single Context
/// across threads. Construct one Context per thread, or use `Context.clone()` to
/// create a thread-local view of the same underlying state.
pub const Context = struct {
    ptr: *c.fz_context,

    /// Create a new MuPDF context with document handlers registered.
    /// Returns error.OutOfMemory if MuPDF cannot allocate a context.
    pub fn init() errors.Error!Context {
        if (c.mupdf_zig_bridge_new_context()) |raw| {
            return .{ .ptr = raw };
        } else {
            return error.OutOfMemory;
        }
    }

    /// Clone this Context for use on another thread. The clone shares MuPDF's
    /// underlying caches but has its own thread-local state. Caller must `deinit`
    /// the returned Context independently.
    pub fn clone(self: *const Context) errors.Error!Context {
        if (c.mupdf_zig_bridge_clone_context(self.ptr)) |raw| {
            return .{ .ptr = raw };
        } else {
            return error.OutOfMemory;
        }
    }

    /// Free the underlying fz_context. After deinit the Context is unusable.
    pub fn deinit(self: *Context) void {
        c.mupdf_zig_bridge_drop_context(self.ptr);
        self.* = undefined;
    }
};

test "Context init + deinit succeeds" {
    var ctx = try Context.init();
    defer ctx.deinit();
}

test "Context can be init/deinit many times without crashing" {
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        var ctx = try Context.init();
        ctx.deinit();
    }
}

test "Context.clone returns an independently-droppable Context" {
    var ctx = try Context.init();
    defer ctx.deinit();

    var clone = try ctx.clone();
    defer clone.deinit();

    // Both should be usable independently — the test of "usable" is that
    // the underlying pointer is non-null. Real concurrent use is out of unit scope.
    try std.testing.expect(@intFromPtr(ctx.ptr) != @intFromPtr(clone.ptr));
}
