const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;

/// JSON-RPC 2.0 message types over newline-delimited stdio.
/// All `params` / `result` / `error.data` values are stored as raw JSON strings
/// (the caller parses them based on the method name).
pub const Message = union(enum) {
    request: Request,
    response: Response,
    notification: Notification,

    pub fn deinit(self: *Message, gpa: Allocator) void {
        switch (self.*) {
            .request => |*r| r.deinit(gpa),
            .response => |*r| r.deinit(gpa),
            .notification => |*n| n.deinit(gpa),
        }
    }
};

pub const Request = struct {
    id: i64,                    // we use integer ids exclusively; string ids rejected
    method: []const u8,
    params_json: ?[]const u8,   // raw JSON for params object/array; null if absent

    pub fn deinit(self: *Request, gpa: Allocator) void {
        gpa.free(self.method);
        if (self.params_json) |p| gpa.free(p);
    }
};

pub const Response = struct {
    id: i64,
    body: ResponseBody,

    pub fn deinit(self: *Response, gpa: Allocator) void {
        switch (self.body) {
            .result => |*r| gpa.free(r.*),
            .err => |*e| e.deinit(gpa),
        }
    }
};

pub const ResponseBody = union(enum) {
    result: []const u8,      // raw JSON for the result value
    err: ErrorObject,
};

pub const ErrorObject = struct {
    code: i64,
    message: []const u8,
    data_json: ?[]const u8,  // raw JSON for `data`; null if absent

    pub fn deinit(self: *ErrorObject, gpa: Allocator) void {
        gpa.free(self.message);
        if (self.data_json) |d| gpa.free(d);
    }
};

pub const Notification = struct {
    method: []const u8,
    params_json: ?[]const u8,

    pub fn deinit(self: *Notification, gpa: Allocator) void {
        gpa.free(self.method);
        if (self.params_json) |p| gpa.free(p);
    }
};

pub const DecodeError = error{
    InvalidJson,
    MissingJsonrpcField,
    UnsupportedJsonrpcVersion,
    InvalidMessageShape,    // doesn't match request/response/notification
    InvalidIdType,          // we accept integer ids only
    BothResultAndError,
    NeitherResultNorError,
    OutOfMemory,
};

/// Decode one line of newline-delimited JSON into a Message.
/// `line` is the full line content; trailing '\n' and '\r' are tolerated.
/// On success, caller owns the returned Message (call deinit).
pub fn decodeLine(gpa: Allocator, line: []const u8) DecodeError!Message {
    var trimmed = line;
    while (trimmed.len > 0 and (trimmed[trimmed.len - 1] == '\n' or trimmed[trimmed.len - 1] == '\r')) {
        trimmed = trimmed[0 .. trimmed.len - 1];
    }
    if (trimmed.len == 0) return DecodeError.InvalidJson;

    var parsed = json.parseFromSlice(json.Value, gpa, trimmed, .{}) catch return DecodeError.InvalidJson;
    defer parsed.deinit();

    if (parsed.value != .object) return DecodeError.InvalidMessageShape;
    const obj = parsed.value.object;

    const jr = obj.get("jsonrpc") orelse return DecodeError.MissingJsonrpcField;
    if (jr != .string or !std.mem.eql(u8, jr.string, "2.0")) return DecodeError.UnsupportedJsonrpcVersion;

    const has_id = obj.contains("id");
    const has_method = obj.contains("method");
    const has_result = obj.contains("result");
    const has_error = obj.contains("error");

    if (has_method and has_id) {
        const id = try extractIntId(obj.get("id").?);
        const method_val = obj.get("method").?;
        if (method_val != .string) return DecodeError.InvalidMessageShape;
        const method = try gpa.dupe(u8, method_val.string);
        errdefer gpa.free(method);
        const params = if (obj.get("params")) |p| try stringifyAlloc(gpa, p) else null;

        return Message{ .request = .{
            .id = id,
            .method = method,
            .params_json = params,
        } };
    } else if (has_method and !has_id) {
        const method_val = obj.get("method").?;
        if (method_val != .string) return DecodeError.InvalidMessageShape;
        const method = try gpa.dupe(u8, method_val.string);
        errdefer gpa.free(method);
        const params = if (obj.get("params")) |p| try stringifyAlloc(gpa, p) else null;

        return Message{ .notification = .{
            .method = method,
            .params_json = params,
        } };
    } else if (has_id and (has_result or has_error)) {
        const id = try extractIntId(obj.get("id").?);
        if (has_result and has_error) return DecodeError.BothResultAndError;

        if (has_result) {
            const result_json = try stringifyAlloc(gpa, obj.get("result").?);
            return Message{ .response = .{
                .id = id,
                .body = .{ .result = result_json },
            } };
        } else {
            const err_val = obj.get("error").?;
            if (err_val != .object) return DecodeError.InvalidMessageShape;
            const code_val = err_val.object.get("code") orelse return DecodeError.InvalidMessageShape;
            if (code_val != .integer) return DecodeError.InvalidMessageShape;
            const msg_val = err_val.object.get("message") orelse return DecodeError.InvalidMessageShape;
            if (msg_val != .string) return DecodeError.InvalidMessageShape;
            const msg = try gpa.dupe(u8, msg_val.string);
            errdefer gpa.free(msg);
            const data_json = if (err_val.object.get("data")) |d| try stringifyAlloc(gpa, d) else null;

            return Message{ .response = .{
                .id = id,
                .body = .{ .err = .{
                    .code = code_val.integer,
                    .message = msg,
                    .data_json = data_json,
                } },
            } };
        }
    } else if (has_id and !has_result and !has_error) {
        return DecodeError.NeitherResultNorError;
    } else {
        return DecodeError.InvalidMessageShape;
    }
}

fn extractIntId(v: json.Value) DecodeError!i64 {
    return switch (v) {
        .integer => |i| i,
        else => DecodeError.InvalidIdType,
    };
}

fn stringifyAlloc(gpa: Allocator, v: json.Value) DecodeError![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    json.Stringify.value(v, .{}, &aw.writer) catch return DecodeError.InvalidJson;
    return aw.toOwnedSlice() catch return DecodeError.OutOfMemory;
}

// --- encode --- //

/// Encode a Message to a newline-terminated line of JSON.
/// Caller owns the returned []u8 (free with gpa.free).
pub fn encode(gpa: Allocator, msg: Message) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;

    switch (msg) {
        .request => |r| {
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":", .{r.id});
            try writeJsonString(w, r.method);
            if (r.params_json) |p| {
                try w.writeAll(",\"params\":");
                try w.writeAll(p);
            }
            try w.writeAll("}\n");
        },
        .response => |r| {
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},", .{r.id});
            switch (r.body) {
                .result => |res| {
                    try w.writeAll("\"result\":");
                    try w.writeAll(res);
                },
                .err => |e| {
                    try w.print("\"error\":{{\"code\":{d},\"message\":", .{e.code});
                    try writeJsonString(w, e.message);
                    if (e.data_json) |d| {
                        try w.writeAll(",\"data\":");
                        try w.writeAll(d);
                    }
                    try w.writeAll("}");
                },
            }
            try w.writeAll("}\n");
        },
        .notification => |n| {
            try w.writeAll("{\"jsonrpc\":\"2.0\",\"method\":");
            try writeJsonString(w, n.method);
            if (n.params_json) |p| {
                try w.writeAll(",\"params\":");
                try w.writeAll(p);
            }
            try w.writeAll("}\n");
        },
    }
    return try aw.toOwnedSlice();
}

fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeAll("\"");
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0...8, 11, 12, 14...31 => try w.print("\\u{x:0>4}", .{c}),
            else => try w.writeByte(c),
        }
    }
    try w.writeAll("\"");
}

// --- tests --- //

test "decode initialize request" {
    const gpa = std.testing.allocator;
    const line = "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"lambe-haath/1\"}}";
    var msg = try decodeLine(gpa, line);
    defer msg.deinit(gpa);

    try std.testing.expect(msg == .request);
    try std.testing.expectEqual(@as(i64, 0), msg.request.id);
    try std.testing.expectEqualStrings("initialize", msg.request.method);
    try std.testing.expect(msg.request.params_json != null);
}

test "decode response with result" {
    const gpa = std.testing.allocator;
    const line = "{\"jsonrpc\":\"2.0\",\"id\":17,\"result\":{\"markdown_path\":\"/x.md\",\"pages\":5}}";
    var msg = try decodeLine(gpa, line);
    defer msg.deinit(gpa);

    try std.testing.expect(msg == .response);
    try std.testing.expectEqual(@as(i64, 17), msg.response.id);
    try std.testing.expect(msg.response.body == .result);
}

test "decode response with error + data" {
    const gpa = std.testing.allocator;
    const line = "{\"jsonrpc\":\"2.0\",\"id\":42,\"error\":{\"code\":-32099,\"message\":\"canceled\",\"data\":{\"reason\":\"user\"}}}";
    var msg = try decodeLine(gpa, line);
    defer msg.deinit(gpa);

    try std.testing.expect(msg == .response);
    try std.testing.expect(msg.response.body == .err);
    try std.testing.expectEqual(@as(i64, -32099), msg.response.body.err.code);
    try std.testing.expectEqualStrings("canceled", msg.response.body.err.message);
    try std.testing.expect(msg.response.body.err.data_json != null);
}

test "decode notification (no id)" {
    const gpa = std.testing.allocator;
    const line = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{\"progress\":0.5}}";
    var msg = try decodeLine(gpa, line);
    defer msg.deinit(gpa);

    try std.testing.expect(msg == .notification);
    try std.testing.expectEqualStrings("notifications/progress", msg.notification.method);
}

test "reject missing jsonrpc field" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(
        DecodeError.MissingJsonrpcField,
        decodeLine(gpa, "{\"id\":1,\"method\":\"x\"}"),
    );
}

test "reject wrong jsonrpc version" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(
        DecodeError.UnsupportedJsonrpcVersion,
        decodeLine(gpa, "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"x\"}"),
    );
}

test "reject malformed JSON" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(
        DecodeError.InvalidJson,
        decodeLine(gpa, "this is not json"),
    );
}

test "reject empty line" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(
        DecodeError.InvalidJson,
        decodeLine(gpa, ""),
    );
}

test "encode request round-trip" {
    const gpa = std.testing.allocator;
    const msg = Message{ .request = .{
        .id = 1,
        .method = "test",
        .params_json = "{\"foo\":42}",
    } };
    const line = try encode(gpa, msg);
    defer gpa.free(line);

    var decoded = try decodeLine(gpa, line);
    defer decoded.deinit(gpa);
    try std.testing.expect(decoded == .request);
    try std.testing.expectEqual(@as(i64, 1), decoded.request.id);
    try std.testing.expectEqualStrings("test", decoded.request.method);
}

test "encode notification round-trip" {
    const gpa = std.testing.allocator;
    const msg = Message{ .notification = .{
        .method = "notifications/progress",
        .params_json = "{\"progress\":0.5}",
    } };
    const line = try encode(gpa, msg);
    defer gpa.free(line);

    var decoded = try decodeLine(gpa, line);
    defer decoded.deinit(gpa);
    try std.testing.expect(decoded == .notification);
}

test "encode escapes string special chars" {
    const gpa = std.testing.allocator;
    const msg = Message{ .notification = .{
        .method = "log",
        .params_json = "{\"message\":\"line1\\nline2\\twith \\\"quotes\\\"\"}",
    } };
    const line = try encode(gpa, msg);
    defer gpa.free(line);
    var newline_count: usize = 0;
    for (line) |c| if (c == '\n') {
        newline_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), newline_count);
    try std.testing.expectEqual(@as(u8, '\n'), line[line.len - 1]);
}
