const std = @import("std");
const c = @import("c");
const errors = @import("errors.zig");
const Context = @import("context.zig").Context;

pub const Document = struct {
    /// Borrowed Context — caller MUST keep the Context alive for the Document's
    /// lifetime, and MUST call Document.deinit before Context.deinit.
    ctx: *Context,
    /// Owned pdf_document pointer. Freed by Document.deinit via the bridge.
    ptr: *c.pdf_document,

    /// Open a PDF file. The Document borrows the Context — caller MUST keep
    /// the Context alive for the Document's lifetime.
    /// - `error.InvalidPdf`: file missing, not a PDF, or corrupt.
    /// - `error.EncryptedPdf`: file is password-protected.
    /// - `error.PdfBackendError`: any other MuPDF throw.
    pub fn open(ctx: *Context, path: [:0]const u8) errors.Error!Document {
        var raw: ?*c.pdf_document = null;
        const rc = c.mupdf_zig_bridge_open_document(ctx.ptr, path.ptr, &raw);
        return switch (rc) {
            // Bridge contract: raw is non-null when rc == MUPDF_BRIDGE_OK.
            c.MUPDF_BRIDGE_OK => .{ .ctx = ctx, .ptr = raw.? },
            c.MUPDF_BRIDGE_ERR_OPEN => error.InvalidPdf,
            c.MUPDF_BRIDGE_ERR_ENCRYPTED => error.EncryptedPdf,
            else => error.PdfBackendError,
        };
    }

    /// Drop the underlying pdf_document. MUST be called before the Context's deinit,
    /// since this calls back into the Context to release MuPDF state.
    pub fn deinit(self: *Document) void {
        c.mupdf_zig_bridge_drop_document(self.ctx.ptr, self.ptr);
        self.* = undefined;
    }

    /// Return the number of pages in this document. Returns error.PdfBackendError if MuPDF throws.
    pub fn pageCount(self: *const Document) errors.Error!u32 {
        var count: c_int = 0;
        const rc = c.mupdf_zig_bridge_count_pages(self.ctx.ptr, self.ptr, &count);
        return switch (rc) {
            c.MUPDF_BRIDGE_OK => @intCast(count),
            else => error.PdfBackendError,
        };
    }

    /// Write a copy of this document to `out_path` containing only pages
    /// [start_page, end_page] (1-based, inclusive). Returns the size in bytes
    /// of the resulting file.
    ///
    /// IMPORTANT: After a successful slice, this Document is in a degraded state
    /// (pdf_rearrange_pages mutates the in-memory representation). Callers SHOULD
    /// drop it and re-open if further operations are needed.
    ///
    /// On error, `out_path` may contain a partial or corrupted file. Callers SHOULD
    /// delete it before retrying.
    pub fn slice(
        self: *Document,
        out_path: [:0]const u8,
        start_page: u32,
        end_page: u32,
    ) errors.Error!u64 {
        var bytes: c_ulonglong = 0;
        const rc = c.mupdf_zig_bridge_slice(
            self.ctx.ptr,
            self.ptr,
            out_path.ptr,
            @intCast(start_page),
            @intCast(end_page),
            &bytes,
        );
        return switch (rc) {
            c.MUPDF_BRIDGE_OK => @intCast(bytes),
            c.MUPDF_BRIDGE_ERR_RANGE => error.InvalidPageRange,
            else => error.PdfBackendError,
        };
    }
};

const testing = std.testing;

test "Document.open succeeds on the 10-page sample" {
    var ctx = try Context.init();
    defer ctx.deinit();

    var doc = try Document.open(&ctx, "tests/fixtures/sample-10pages.pdf");
    defer doc.deinit();
}

test "Document.open returns InvalidPdf on a text file" {
    var ctx = try Context.init();
    defer ctx.deinit();

    try testing.expectError(error.InvalidPdf, Document.open(&ctx, "tests/fixtures/not-a-pdf.txt"));
}

test "Document.open returns InvalidPdf on a missing file" {
    var ctx = try Context.init();
    defer ctx.deinit();

    try testing.expectError(error.InvalidPdf, Document.open(&ctx, "tests/fixtures/does-not-exist.pdf"));
}

test "Document.open returns EncryptedPdf on a password-protected file" {
    var ctx = try Context.init();
    defer ctx.deinit();

    try testing.expectError(error.EncryptedPdf, Document.open(&ctx, "tests/fixtures/encrypted.pdf"));
}

test "Document.pageCount returns 10 on the sample fixture" {
    var ctx = try Context.init();
    defer ctx.deinit();
    var doc = try Document.open(&ctx, "tests/fixtures/sample-10pages.pdf");
    defer doc.deinit();
    try testing.expectEqual(@as(u32, 10), try doc.pageCount());
}

test "Document.slice 1..3 produces a 3-page PDF" {
    var ctx = try Context.init();
    defer ctx.deinit();

    const out = "tests/fixtures/.tmp-slice-1-3.pdf";
    defer std.Io.Dir.cwd().deleteFile(testing.io, out) catch {};

    {
        var src = try Document.open(&ctx, "tests/fixtures/sample-10pages.pdf");
        defer src.deinit();
        const bytes = try src.slice(out, 1, 3);
        try testing.expect(bytes > 0);
    }

    var sliced = try Document.open(&ctx, out);
    defer sliced.deinit();
    try testing.expectEqual(@as(u32, 3), try sliced.pageCount());
}

test "Document.slice with start == end yields a 1-page PDF" {
    var ctx = try Context.init();
    defer ctx.deinit();

    const out = "tests/fixtures/.tmp-slice-5-5.pdf";
    defer std.Io.Dir.cwd().deleteFile(testing.io, out) catch {};

    {
        var src = try Document.open(&ctx, "tests/fixtures/sample-10pages.pdf");
        defer src.deinit();
        _ = try src.slice(out, 5, 5);
    }

    var sliced = try Document.open(&ctx, out);
    defer sliced.deinit();
    try testing.expectEqual(@as(u32, 1), try sliced.pageCount());
}

test "Document.slice from page 1 keeps page 1" {
    var ctx = try Context.init();
    defer ctx.deinit();

    const out = "tests/fixtures/.tmp-slice-1-2.pdf";
    defer std.Io.Dir.cwd().deleteFile(testing.io, out) catch {};

    {
        var src = try Document.open(&ctx, "tests/fixtures/sample-10pages.pdf");
        defer src.deinit();
        _ = try src.slice(out, 1, 2);
    }

    var sliced = try Document.open(&ctx, out);
    defer sliced.deinit();
    try testing.expectEqual(@as(u32, 2), try sliced.pageCount());
}

test "Document.slice through the last page keeps the last page" {
    var ctx = try Context.init();
    defer ctx.deinit();

    const out = "tests/fixtures/.tmp-slice-9-10.pdf";
    defer std.Io.Dir.cwd().deleteFile(testing.io, out) catch {};

    {
        var src = try Document.open(&ctx, "tests/fixtures/sample-10pages.pdf");
        defer src.deinit();
        _ = try src.slice(out, 9, 10);
    }

    var sliced = try Document.open(&ctx, out);
    defer sliced.deinit();
    try testing.expectEqual(@as(u32, 2), try sliced.pageCount());
}

test "Document.slice with end < start returns InvalidPageRange" {
    var ctx = try Context.init();
    defer ctx.deinit();
    var src = try Document.open(&ctx, "tests/fixtures/sample-10pages.pdf");
    defer src.deinit();
    try testing.expectError(error.InvalidPageRange, src.slice("tests/fixtures/.tmp-should-not-exist.pdf", 5, 3));
}

test "Document.slice with start == 0 returns InvalidPageRange" {
    var ctx = try Context.init();
    defer ctx.deinit();
    var src = try Document.open(&ctx, "tests/fixtures/sample-10pages.pdf");
    defer src.deinit();
    try testing.expectError(error.InvalidPageRange, src.slice("tests/fixtures/.tmp-should-not-exist.pdf", 0, 1));
}

test "Document.slice with end > page_count returns InvalidPageRange" {
    var ctx = try Context.init();
    defer ctx.deinit();
    var src = try Document.open(&ctx, "tests/fixtures/sample-10pages.pdf");
    defer src.deinit();
    try testing.expectError(error.InvalidPageRange, src.slice("tests/fixtures/.tmp-should-not-exist.pdf", 1, 11));
}

test "Document.slice output begins with the PDF header bytes" {
    var ctx = try Context.init();
    defer ctx.deinit();

    const out = "tests/fixtures/.tmp-slice-magic.pdf";
    defer std.Io.Dir.cwd().deleteFile(testing.io, out) catch {};

    {
        var src = try Document.open(&ctx, "tests/fixtures/sample-10pages.pdf");
        defer src.deinit();
        _ = try src.slice(out, 1, 1);
    }

    var file = try std.Io.Dir.cwd().openFile(testing.io, out, .{ .mode = .read_only });
    defer file.close(testing.io);
    var buf: [5]u8 = undefined;
    const n = try file.readPositionalAll(testing.io, &buf, 0);
    try testing.expectEqual(@as(usize, 5), n);
    try testing.expectEqualStrings("%PDF-", &buf);
}

test "Document.slice of a sliced document still produces a valid PDF" {
    var ctx = try Context.init();
    defer ctx.deinit();

    const tmp1 = "tests/fixtures/.tmp-rt-1.pdf";
    const tmp2 = "tests/fixtures/.tmp-rt-2.pdf";
    defer std.Io.Dir.cwd().deleteFile(testing.io, tmp1) catch {};
    defer std.Io.Dir.cwd().deleteFile(testing.io, tmp2) catch {};

    {
        var src = try Document.open(&ctx, "tests/fixtures/sample-10pages.pdf");
        defer src.deinit();
        _ = try src.slice(tmp1, 3, 7); // 5 pages
    }
    {
        var mid = try Document.open(&ctx, tmp1);
        defer mid.deinit();
        _ = try mid.slice(tmp2, 2, 4); // 3 of those
    }

    var final = try Document.open(&ctx, tmp2);
    defer final.deinit();
    try testing.expectEqual(@as(u32, 3), try final.pageCount());
}
