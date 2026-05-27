const std = @import("std");
const testing = std.testing;

/// One field from a multipart form. References byte slices in the original body.
pub const Field = struct {
    name: []const u8,
    filename: ?[]const u8,
    body: []const u8,
};

/// Parse `body` (the entire request body) into Fields. The `boundary` is the
/// value of the `boundary=...` parameter from the Content-Type header.
///
/// Returns owned slice; caller frees with `gpa.free(fields)`.
pub fn parse(gpa: std.mem.Allocator, boundary: []const u8, body: []const u8) ![]Field {
    var fields: std.ArrayList(Field) = .empty;
    errdefer fields.deinit(gpa);

    const delim = try std.fmt.allocPrint(gpa, "--{s}", .{boundary});
    defer gpa.free(delim);

    // Find the first delimiter
    var idx = std.mem.indexOf(u8, body, delim) orelse return error.InvalidMultipart;

    while (idx < body.len) {
        // After "--BOUND", expect either "\r\n" (next part) or "--" (end)
        const after = idx + delim.len;
        if (after + 2 > body.len) return error.InvalidMultipart;
        if (body[after] == '-' and body[after + 1] == '-') {
            // closing boundary "--BOUND--"
            return try fields.toOwnedSlice(gpa);
        }
        if (body[after] != '\r' or body[after + 1] != '\n') return error.InvalidMultipart;

        // Read headers until \r\n\r\n
        const headers_start = after + 2;
        const headers_end = std.mem.indexOfPos(u8, body, headers_start, "\r\n\r\n") orelse return error.InvalidMultipart;
        const headers = body[headers_start..headers_end];
        const body_start = headers_end + 4;

        // Find next delimiter
        const next_idx = std.mem.indexOfPos(u8, body, body_start, delim) orelse return error.InvalidMultipart;
        // Body is bytes from body_start up to but not including "\r\n--BOUND"
        if (next_idx < 2 or !std.mem.eql(u8, body[next_idx - 2 .. next_idx], "\r\n")) return error.InvalidMultipart;
        const body_end = next_idx - 2;
        const field_body = body[body_start..body_end];

        // Parse Content-Disposition for name= and filename=
        var name: ?[]const u8 = null;
        var filename: ?[]const u8 = null;
        var lit = std.mem.splitSequence(u8, headers, "\r\n");
        while (lit.next()) |line| {
            if (std.ascii.startsWithIgnoreCase(line, "Content-Disposition:")) {
                name = extractQuoted(line, "name=");
                filename = extractQuoted(line, "filename=");
            }
        }
        if (name == null) return error.InvalidMultipart;

        try fields.append(gpa, .{ .name = name.?, .filename = filename, .body = field_body });
        idx = next_idx;
    }

    return error.InvalidMultipart;
}

/// Find `key` in `line`, requiring that it is preceded by a non-alphabetic byte
/// (or start of line). This prevents `name=` from matching the tail of
/// `filename=`.
fn findKey(line: []const u8, key: []const u8) ?usize {
    var pos: usize = 0;
    while (pos < line.len) {
        const found = std.mem.indexOfPos(u8, line, pos, key) orelse return null;
        if (found == 0 or !std.ascii.isAlphabetic(line[found - 1])) return found;
        pos = found + 1;
    }
    return null;
}

fn extractQuoted(line: []const u8, key: []const u8) ?[]const u8 {
    const start = findKey(line, key) orelse return null;
    const after_key = start + key.len;
    if (after_key >= line.len or line[after_key] != '"') return null;
    const value_start = after_key + 1;
    const value_end = std.mem.indexOfScalarPos(u8, line, value_start, '"') orelse return null;
    return line[value_start..value_end];
}

const sample_body =
    "--BOUND\r\n" ++
    "Content-Disposition: form-data; name=\"name\"\r\n" ++
    "\r\n" ++
    "Case 42\r\n" ++
    "--BOUND\r\n" ++
    "Content-Disposition: form-data; name=\"description\"\r\n" ++
    "\r\n" ++
    "test desc\r\n" ++
    "--BOUND\r\n" ++
    "Content-Disposition: form-data; name=\"chargesheet\"; filename=\"a.pdf\"\r\n" ++
    "Content-Type: application/pdf\r\n" ++
    "\r\n" ++
    "%PDF-1.7\nfake body\r\n" ++
    "--BOUND--\r\n";

test "parse extracts three fields with correct names" {
    const gpa = testing.allocator;
    const fields = try parse(gpa, "BOUND", sample_body);
    defer gpa.free(fields);
    try testing.expectEqual(@as(usize, 3), fields.len);
    try testing.expectEqualStrings("name", fields[0].name);
    try testing.expectEqualStrings("description", fields[1].name);
    try testing.expectEqualStrings("chargesheet", fields[2].name);
}

test "parse extracts text bodies" {
    const gpa = testing.allocator;
    const fields = try parse(gpa, "BOUND", sample_body);
    defer gpa.free(fields);
    try testing.expectEqualStrings("Case 42", fields[0].body);
    try testing.expectEqualStrings("test desc", fields[1].body);
}

test "parse extracts file filename and binary body" {
    const gpa = testing.allocator;
    const fields = try parse(gpa, "BOUND", sample_body);
    defer gpa.free(fields);
    try testing.expectEqualStrings("a.pdf", fields[2].filename.?);
    try testing.expectEqualStrings("%PDF-1.7\nfake body", fields[2].body);
}

test "parse on a body missing the closing boundary returns an error" {
    const gpa = testing.allocator;
    const truncated = sample_body[0 .. sample_body.len - 10];
    try testing.expectError(error.InvalidMultipart, parse(gpa, "BOUND", truncated));
}
