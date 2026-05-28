//! Minimal HTTP server for the daemon.
//!
//! Thread-per-connection accept loop. Handles three concerns:
//!   * GET /api/v1/health  -> 200 JSON {"status":"ok","version":"<v>"}
//!   * OPTIONS /api/*      -> 204 with CORS headers (preflight)
//!   * everything else     -> 404 JSON {"code":"NOT_FOUND",...}
//!
//! All responses carry CORS headers allowing the Vite dev origin
//! `http://localhost:5173`. Later phases will replace this with a richer
//! router but the wire shape established here is stable.

const std = @import("std");
const net = std.Io.net;
const http = std.http;
const mupdf = @import("mupdf");
const json = @import("json.zig");
const Db = @import("../db/db.zig").Db;
const router = @import("router.zig");
const handlers = @import("handlers.zig");
const handlers_ocr = @import("handlers_ocr.zig");
const handlers_prompts = @import("handlers_prompts.zig");
const handlers_jobs = @import("handlers_jobs.zig");
const sse = @import("sse.zig");
const static = @import("static.zig");
const slices_mod = @import("../db/slices.zig");
const extractions_mod = @import("../db/extractions.zig");
const prompt_outputs_mod = @import("../db/prompt_outputs.zig");
const Dispatcher = @import("../agents/dispatcher.zig").Dispatcher;

const cors_origin = "http://localhost:5173";

const cors_headers = [_]std.http.Header{
    .{ .name = "Access-Control-Allow-Origin", .value = cors_origin },
    .{ .name = "Access-Control-Allow-Methods", .value = "GET, POST, DELETE, OPTIONS" },
    .{ .name = "Access-Control-Allow-Headers", .value = "Content-Type" },
};

pub const ServeOptions = struct {
    port: u16,
    version: []const u8,
    data_dir: []const u8,
    ui_dir: []const u8,
    dispatcher: ?*Dispatcher = null,
};

/// Bind 0.0.0.0:port and serve connections forever. Returns only on fatal error.
///
/// Thread-per-connection: each accepted connection runs on its own detached OS
/// thread, so the accept loop never blocks waiting on one client. Connections
/// are keep-alive (the client closes them), so the server is not the active
/// closer and does not accumulate TIME_WAIT sockets that would block a quick
/// restart under reuse_address=false. A single mutex serializes request
/// *processing* (acquired only after `receiveHead`, released while a connection
/// idles), so the shared SQLite connection and allocator are never used
/// concurrently regardless of SQLite's compiled thread mode. Trade-off: a slow
/// request (e.g. a sync slice job) briefly serializes other requests — fine for
/// a single-user local tool.
pub fn serve(io: std.Io, gpa: std.mem.Allocator, db: *Db, req_mutex: *std.Io.Mutex, opts: ServeOptions) !void {
    const address = try net.IpAddress.parseIp4("0.0.0.0", opts.port);
    // reuse_address=false so a second daemon on the same port fails loudly with
    // AddressInUse. The lock file alone only guards same-data_dir collisions —
    // without this, SO_REUSEPORT would let two daemons bind the same port and
    // the kernel would silently load-balance traffic between them.
    var tcp_server = try address.listen(io, .{ .reuse_address = false });
    defer tcp_server.deinit(io);

    std.log.info("HTTP listening on http://0.0.0.0:{d}/", .{opts.port});

    while (true) {
        const stream = tcp_server.accept(io) catch |err| {
            std.log.err("accept failed: {t}", .{err});
            continue;
        };
        const thread = std.Thread.spawn(.{}, handleConnection, .{ io, gpa, db, stream, opts, req_mutex }) catch |err| {
            std.log.err("connection thread spawn failed: {t}", .{err});
            var copy = stream;
            copy.close(io);
            continue;
        };
        thread.detach();
    }
}

fn handleConnection(io: std.Io, gpa: std.mem.Allocator, db: *Db, stream: net.Stream, opts: ServeOptions, req_mutex: *std.Io.Mutex) void {
    defer {
        // net.Stream.close wants to overwrite stream with undefined, but
        // immutable parameter — copy first. (Same pattern as std/Build/WebServer.zig.)
        var copy = stream;
        copy.close(io);
    }
    var send_buffer: [4096]u8 = undefined;
    var recv_buffer: [4096]u8 = undefined;
    var connection_reader = stream.reader(io, &recv_buffer);
    var connection_writer = stream.writer(io, &send_buffer);
    var server: http.Server = .init(&connection_reader.interface, &connection_writer.interface);

    // Keep-alive loop: serve requests until the client closes the connection.
    // receiveHead blocks WITHOUT the mutex, so an idle connection never blocks
    // other connections' request processing.
    while (true) {
        var request = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => {
                std.log.err("receiveHead failed: {t}", .{err});
                return;
            },
        };
        req_mutex.lockUncancelable(io);
        defer req_mutex.unlock(io);
        serveRequest(io, gpa, db, &request, opts, req_mutex) catch |err| {
            std.log.err("serveRequest failed: {t}", .{err});
            return;
        };
    }
}

fn methodFromHttp(m: http.Method) ?router.Method {
    return switch (m) {
        .GET => .GET,
        .POST => .POST,
        .DELETE => .DELETE,
        .OPTIONS => .OPTIONS,
        else => null,
    };
}

fn serveRequest(io: std.Io, gpa: std.mem.Allocator, db: *Db, request: *http.Server.Request, opts: ServeOptions, req_mutex: *std.Io.Mutex) !void {
    const target = request.head.target;
    std.log.info("{t} {s}", .{ request.head.method, target });

    const method = methodFromHttp(request.head.method) orelse {
        return respondNotFound(gpa, request);
    };
    const m = router.match(method, target);

    return switch (m.route) {
        .health => respondHealth(gpa, request, opts.version),
        .cors_preflight => respondCors(request),
        .projects_list => respondProjectsList(gpa, db, request),
        .projects_create => respondProjectsCreate(io, gpa, db, request, opts),
        .projects_get => respondProjectsGet(gpa, db, request, m.id orelse return respondNotFound(gpa, request)),
        .projects_delete => respondProjectsDelete(io, gpa, db, request, opts, m.id orelse return respondNotFound(gpa, request)),
        .projects_chargesheet => respondProjectsChargesheet(io, gpa, db, request, opts, m.id orelse return respondNotFound(gpa, request)),
        .projects_jobs_slice => respondProjectsJobsSlice(io, gpa, db, request, opts, m.id orelse return respondNotFound(gpa, request)),
        .projects_jobs_get => respondProjectsJobsGet(gpa, db, request, m.id orelse return respondNotFound(gpa, request), m.child orelse return respondNotFound(gpa, request)),
        .projects_slices_list => respondProjectsSlicesList(gpa, db, request, m.id orelse return respondNotFound(gpa, request)),
        .projects_slices_get => respondProjectsSlicesGet(io, gpa, db, request, opts, m.id orelse return respondNotFound(gpa, request), m.child orelse return respondNotFound(gpa, request)),
        .projects_slices_delete => respondProjectsSlicesDelete(io, gpa, db, request, opts, m.id orelse return respondNotFound(gpa, request), m.child orelse return respondNotFound(gpa, request)),
        .projects_jobs_ocr => respondProjectsJobsOcr(io, gpa, db, request, m.id orelse return respondNotFound(gpa, request)),
        .projects_jobs_ocr_all => respondProjectsJobsOcrAll(io, gpa, db, request, m.id orelse return respondNotFound(gpa, request)),
        .projects_extractions_list => respondProjectsExtractionsList(gpa, db, request, m.id orelse return respondNotFound(gpa, request)),
        .projects_extractions_get => respondProjectsExtractionsGet(io, gpa, db, request, m.id orelse return respondNotFound(gpa, request), m.child orelse return respondNotFound(gpa, request)),
        .projects_jobs_prompt => respondProjectsJobsPrompt(io, gpa, db, request, m.id orelse return respondNotFound(gpa, request)),
        .projects_jobs_prompt_all => respondProjectsJobsPromptAll(io, gpa, db, request, m.id orelse return respondNotFound(gpa, request)),
        .projects_prompts_list => respondProjectsPromptsList(gpa, db, request, m.id orelse return respondNotFound(gpa, request)),
        .projects_prompts_get => respondProjectsPromptsGet(io, gpa, db, request, m.id orelse return respondNotFound(gpa, request), m.child orelse return respondNotFound(gpa, request)),
        .jobs_cancel => respondJobsCancel(gpa, request, opts.dispatcher, m.id orelse return respondNotFound(gpa, request)),
        .jobs_logs => respondJobsLogs(gpa, db, request, m.id orelse return respondNotFound(gpa, request)),
        .jobs_stream => respondJobsStream(io, db, request, req_mutex, m.id orelse return respondNotFound(gpa, request)),
        .not_found => {
            // Strip any `?query` before the on-disk lookup: SvelteKit/Vite assets
            // carry cache-busting params (e.g. app.js?v=2) that would otherwise
            // miss the file and fall through to the SPA index.html fallback.
            const ui_path = static.stripQuery(target);
            const served = static.resolve(io, gpa, opts.ui_dir, request.head.method == .GET, ui_path) catch
                return respondNotFound(gpa, request);
            switch (served) {
                .file => |f| {
                    defer gpa.free(f.abs_path);
                    try respondFile(io, gpa, request, f.abs_path, f.mime);
                },
                .placeholder => try respondUiPlaceholder(request, opts.ui_dir),
                .not_handled => try respondNotFound(gpa, request),
            }
        },
    };
}

fn respondFile(io: std.Io, gpa: std.mem.Allocator, request: *http.Server.Request, abs_path: []const u8, mime: []const u8) !void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, abs_path, gpa, .limited(100 * 1024 * 1024)) catch
        return respondNotFound(gpa, request);
    defer gpa.free(bytes);
    const headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = mime },
    } ++ cors_headers;
    try request.respond(bytes, .{ .status = .ok, .extra_headers = &headers });
}

fn respondUiPlaceholder(request: *http.Server.Request, ui_dir: []const u8) !void {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try w.print(
        "logos daemon is running, but no web UI was found at:\n  {s}\n\n" ++
            "Build it (cd chargesheet-ui && yarn build) and set CHARGESHEET_UI_DIR to that build/ dir,\n" ++
            "or run the dev UI: cd chargesheet-ui && yarn dev (http://localhost:5173).\n",
        .{ui_dir},
    );
    const headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "text/plain" },
    } ++ cors_headers;
    try request.respond(w.buffered(), .{ .status = .ok, .extra_headers = &headers });
}

fn respondCors(request: *http.Server.Request) !void {
    try request.respond("", .{
        .status = .no_content,
        .extra_headers = &cors_headers,
    });
}

fn respondHealth(gpa: std.mem.Allocator, request: *http.Server.Request, version: []const u8) !void {
    _ = gpa;
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try json.writeHealth(&w, version);
    const body = w.buffered();

    const headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
    } ++ cors_headers;

    try request.respond(body, .{
        .status = .ok,
        .extra_headers = &headers,
    });
}

fn respondProjectsList(gpa: std.mem.Allocator, db: *Db, request: *http.Server.Request) !void {
    var buf: [16 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try handlers.handleProjectsList(gpa, db, &w);
    const body = w.buffered();

    const headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
    } ++ cors_headers;

    try request.respond(body, .{
        .status = .ok,
        .extra_headers = &headers,
    });
}

fn respondProjectsCreate(
    io: std.Io,
    gpa: std.mem.Allocator,
    db: *Db,
    request: *http.Server.Request,
    opts: ServeOptions,
) !void {
    // Extract Content-Type / boundary BEFORE engaging the body reader — that call
    // invalidates the head's string fields. Copy boundary into a local owned slice
    // so we can keep using it after the reader is engaged.
    const ct_in = request.head.content_type orelse {
        return respondError(request, .bad_request, "INVALID_REQUEST", "Missing Content-Type");
    };
    const boundary_ref = extractBoundary(ct_in) orelse {
        return respondError(request, .bad_request, "INVALID_REQUEST", "Multipart boundary missing");
    };
    const boundary = try gpa.dupe(u8, boundary_ref);
    defer gpa.free(boundary);

    // Read entire request body into memory (capped at 100 MiB). Use
    // readerExpectContinue (not readerExpectNone) so clients that send
    // "Expect: 100-continue" (curl, many HTTP libraries) get the continuation
    // header instead of tripping readerExpectNone's `expect == null` assert,
    // which would panic and abort the whole daemon.
    var read_buf: [4096]u8 = undefined;
    const body_reader = request.readerExpectContinue(&read_buf) catch {
        return respondError(request, .bad_request, "INVALID_REQUEST", "Failed to read body");
    };
    const body = body_reader.allocRemaining(gpa, .limited(100 * 1024 * 1024)) catch |err| switch (err) {
        error.StreamTooLong => return respondError(request, .payload_too_large, "INVALID_PDF", "Upload too large"),
        else => return respondError(request, .bad_request, "INVALID_REQUEST", "Failed to read body"),
    };
    defer gpa.free(body);

    // Per-request mupdf context. Cheap; sync handler so no thread issues.
    var mupdf_ctx = mupdf.Context.init() catch {
        return respondError(request, .internal_server_error, "INTERNAL_ERROR", "Failed to init MuPDF");
    };
    defer mupdf_ctx.deinit();

    var project = handlers.handleProjectsCreate(io, gpa, db, opts.data_dir, &mupdf_ctx, boundary, body) catch |err| {
        return respondCreateError(request, err);
    };
    defer project.deinit(gpa);

    var resp_buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&resp_buf);
    try json.writeProject(&w, project);
    const resp_body = w.buffered();

    const headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
    } ++ cors_headers;

    try request.respond(resp_body, .{
        .status = .created,
        .extra_headers = &headers,
    });
}

/// Extract the `boundary` parameter from a multipart Content-Type header.
/// Handles both quoted (`boundary="xxx"`) and unquoted (`boundary=xxx`) forms.
fn extractBoundary(content_type: []const u8) ?[]const u8 {
    const key = "boundary=";
    const start = std.mem.indexOf(u8, content_type, key) orelse return null;
    const after = start + key.len;
    if (after >= content_type.len) return null;
    if (content_type[after] == '"') {
        const close = std.mem.indexOfScalarPos(u8, content_type, after + 1, '"') orelse return null;
        return content_type[after + 1 .. close];
    }
    var end = after;
    while (end < content_type.len and content_type[end] != ';' and content_type[end] != ' ') : (end += 1) {}
    return content_type[after..end];
}

fn respondError(
    request: *http.Server.Request,
    status: std.http.Status,
    code: []const u8,
    message: []const u8,
) !void {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try json.writeError(&w, code, message);
    const body = w.buffered();

    const headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
    } ++ cors_headers;

    try request.respond(body, .{ .status = status, .extra_headers = &headers });
}

fn respondCreateError(request: *http.Server.Request, err: handlers.CreateError) !void {
    const status: std.http.Status = switch (err) {
        error.InvalidName, error.InvalidDescription, error.InvalidPdf, error.InvalidRequest => .bad_request,
        error.NameConflict => .conflict,
        error.DbError, error.PdfError, error.IoError, error.OutOfMemory => .internal_server_error,
    };
    const code: []const u8 = switch (err) {
        error.InvalidName => "INVALID_NAME",
        error.InvalidDescription => "INVALID_DESCRIPTION",
        error.InvalidPdf => "INVALID_PDF",
        error.InvalidRequest => "INVALID_REQUEST",
        error.NameConflict => "NAME_CONFLICT",
        error.DbError, error.PdfError, error.IoError, error.OutOfMemory => "INTERNAL_ERROR",
    };
    const message: []const u8 = switch (err) {
        error.InvalidName => "Name is required (max 200 chars)",
        error.InvalidDescription => "Description must be <= 2000 chars",
        error.InvalidPdf => "Invalid PDF file",
        error.InvalidRequest => "Invalid request",
        error.NameConflict => "A project with this name already exists",
        error.DbError, error.PdfError, error.IoError, error.OutOfMemory => "Internal error",
    };
    try respondError(request, status, code, message);
}

fn respondProjectsGet(
    gpa: std.mem.Allocator,
    db: *Db,
    request: *http.Server.Request,
    id: []const u8,
) !void {
    var project = handlers.handleProjectsGet(gpa, db, id) catch |err| {
        return respondGetError(request, err);
    };
    defer project.deinit(gpa);

    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try json.writeProject(&w, project);
    const body = w.buffered();

    const headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
    } ++ cors_headers;

    try request.respond(body, .{
        .status = .ok,
        .extra_headers = &headers,
    });
}

fn respondProjectsDelete(
    io: std.Io,
    gpa: std.mem.Allocator,
    db: *Db,
    request: *http.Server.Request,
    opts: ServeOptions,
    id: []const u8,
) !void {
    handlers.handleProjectsDelete(io, gpa, db, opts.data_dir, id) catch |err| {
        return respondDeleteError(request, err);
    };
    // 204 No Content, empty body, with CORS.
    try request.respond("", .{
        .status = .no_content,
        .extra_headers = &cors_headers,
    });
}

fn respondGetError(request: *http.Server.Request, err: handlers.GetError) !void {
    const status: std.http.Status = switch (err) {
        error.NotFound => .not_found,
        error.OutOfMemory, error.DbError => .internal_server_error,
    };
    const code: []const u8 = switch (err) {
        error.NotFound => "NOT_FOUND",
        else => "INTERNAL_ERROR",
    };
    const message: []const u8 = switch (err) {
        error.NotFound => "Project not found",
        else => "Internal error",
    };
    try respondError(request, status, code, message);
}

fn respondProjectsChargesheet(
    io: std.Io,
    gpa: std.mem.Allocator,
    db: *Db,
    request: *http.Server.Request,
    opts: ServeOptions,
    id: []const u8,
) !void {
    const result = handlers.handleProjectsChargesheet(io, gpa, db, opts.data_dir, id) catch |err| {
        return respondChargesheetError(request, err);
    };
    defer result.deinit(gpa);

    // Build the Content-Disposition header. RFC 6266 says we may quote the
    // filename, but `"`, `\`, and CTLs must not appear unescaped inside
    // quotes. We sanitize defensively by replacing any such bytes with `_`.
    // The filename came from a multipart upload, so it is untrusted input.
    var cd_buf: [512]u8 = undefined;
    var cd_w = std.Io.Writer.fixed(&cd_buf);
    try cd_w.writeAll("inline; filename=\"");
    for (result.filename) |c| {
        if (c == '"' or c == '\\' or c < 0x20) {
            try cd_w.writeByte('_');
        } else {
            try cd_w.writeByte(c);
        }
    }
    try cd_w.writeAll("\"");
    const cd_value = cd_w.buffered();

    const headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/pdf" },
        .{ .name = "Content-Disposition", .value = cd_value },
    } ++ cors_headers;

    try request.respond(result.bytes, .{
        .status = .ok,
        .extra_headers = &headers,
    });
}

fn respondChargesheetError(request: *http.Server.Request, err: handlers.ChargesheetError) !void {
    const status: std.http.Status = switch (err) {
        error.NotFound => .not_found,
        error.IoError, error.OutOfMemory, error.DbError => .internal_server_error,
    };
    const code: []const u8 = switch (err) {
        error.NotFound => "NOT_FOUND",
        else => "INTERNAL_ERROR",
    };
    const message: []const u8 = switch (err) {
        error.NotFound => "Project or chargesheet not found",
        else => "Internal error",
    };
    try respondError(request, status, code, message);
}

fn respondDeleteError(request: *http.Server.Request, err: handlers.DeleteError) !void {
    const status: std.http.Status = switch (err) {
        error.NotFound => .not_found,
        error.DbError, error.IoError => .internal_server_error,
    };
    const code: []const u8 = switch (err) {
        error.NotFound => "NOT_FOUND",
        else => "INTERNAL_ERROR",
    };
    const message: []const u8 = switch (err) {
        error.NotFound => "Project not found",
        else => "Internal error",
    };
    try respondError(request, status, code, message);
}

fn respondProjectsJobsSlice(
    io: std.Io,
    gpa: std.mem.Allocator,
    db: *Db,
    request: *http.Server.Request,
    opts: ServeOptions,
    project_id: []const u8,
) !void {
    var read_buf: [4096]u8 = undefined;
    const body_reader = request.readerExpectNone(&read_buf);
    const body = body_reader.allocRemaining(gpa, .limited(10 * 1024 * 1024)) catch {
        return respondError(request, .bad_request, "INVALID_REQUEST", "Body too large or unreadable");
    };
    defer gpa.free(body);

    var result = handlers.handleProjectsJobsSlice(io, gpa, db, opts.data_dir, project_id, body) catch |err| {
        return respondSliceJobError(request, err);
    };
    defer result.deinit(gpa);

    var resp_buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&resp_buf);
    try json.writeJobCreated(&w, result.job_id);
    const resp_body = w.buffered();

    const headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
    } ++ cors_headers;

    try request.respond(resp_body, .{
        .status = .accepted, // 202
        .extra_headers = &headers,
    });
}

fn respondSliceJobError(request: *http.Server.Request, err: handlers.SliceJobError) !void {
    const status: std.http.Status = switch (err) {
        error.InvalidRequest, error.InvalidRange, error.InvalidFilename, error.DuplicateFilenames => .bad_request,
        error.ProjectNotFound => .not_found,
        error.OutOfMemory, error.DbError, error.PdfError, error.IoError => .internal_server_error,
    };
    const code: []const u8 = switch (err) {
        error.InvalidRequest => "INVALID_REQUEST",
        error.InvalidRange => "INVALID_RANGE",
        error.InvalidFilename => "INVALID_FILENAME",
        error.DuplicateFilenames => "DUPLICATE_FILENAMES",
        error.ProjectNotFound => "NOT_FOUND",
        else => "INTERNAL_ERROR",
    };
    const message: []const u8 = switch (err) {
        error.InvalidRequest => "Invalid request body",
        error.InvalidRange => "Page range out of bounds",
        error.InvalidFilename => "Filename is invalid",
        error.DuplicateFilenames => "Duplicate filenames in the same request",
        error.ProjectNotFound => "Project not found",
        else => "Internal error",
    };
    try respondError(request, status, code, message);
}

fn respondProjectsJobsGet(
    gpa: std.mem.Allocator,
    db: *Db,
    request: *http.Server.Request,
    project_id: []const u8,
    job_id: []const u8,
) !void {
    var job = handlers.handleProjectsJobsGet(gpa, db, project_id, job_id) catch |err| {
        return switch (err) {
            error.NotFound => respondError(request, .not_found, "NOT_FOUND", "Job not found"),
            else => respondError(request, .internal_server_error, "INTERNAL_ERROR", "Internal error"),
        };
    };
    defer job.deinit(gpa);

    var buf: [16 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try json.writeJob(
        &w,
        job.id,
        @tagName(job.status),
        job.progress,
        job.results,
        job.error_msg,
    );
    const body = w.buffered();

    const headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
    } ++ cors_headers;

    try request.respond(body, .{
        .status = .ok,
        .extra_headers = &headers,
    });
}

fn respondProjectsSlicesList(
    gpa: std.mem.Allocator,
    db: *Db,
    request: *http.Server.Request,
    project_id: []const u8,
) !void {
    const list = handlers.handleProjectsSlicesList(gpa, db, project_id) catch |err| {
        return switch (err) {
            error.NotFound => respondError(request, .not_found, "NOT_FOUND", "Project not found"),
            else => respondError(request, .internal_server_error, "INTERNAL_ERROR", "Internal error"),
        };
    };
    defer slices_mod.deinitList(list, gpa);

    var buf: [16 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try json.writeSliceListingArrayOpen(&w);
    for (list, 0..) |s, i| {
        if (i > 0) try w.writeAll(",");
        try json.writeSliceListingItem(&w, s.filename, s.start_page, s.end_page, s.size_bytes, s.created_at);
    }
    try json.writeSliceListingArrayClose(&w);
    const body = w.buffered();

    const headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
    } ++ cors_headers;

    try request.respond(body, .{
        .status = .ok,
        .extra_headers = &headers,
    });
}

fn respondProjectsSlicesGet(
    io: std.Io,
    gpa: std.mem.Allocator,
    db: *Db,
    request: *http.Server.Request,
    opts: ServeOptions,
    project_id: []const u8,
    filename: []const u8,
) !void {
    const result = handlers.handleProjectsSlicesGet(io, gpa, db, opts.data_dir, project_id, filename) catch |err| {
        const status: std.http.Status = switch (err) {
            error.NotFound => .not_found,
            error.InvalidFilename => .bad_request,
            else => .internal_server_error,
        };
        const code: []const u8 = switch (err) {
            error.NotFound => "NOT_FOUND",
            error.InvalidFilename => "INVALID_FILENAME",
            else => "INTERNAL_ERROR",
        };
        return respondError(request, status, code, "Slice not available");
    };
    defer result.deinit(gpa);

    // Sanitize filename for Content-Disposition (same pattern as chargesheet handler).
    var cd_buf: [512]u8 = undefined;
    var cd_w = std.Io.Writer.fixed(&cd_buf);
    try cd_w.writeAll("inline; filename=\"");
    for (result.filename) |c| {
        if (c == '"' or c == '\\' or c < 0x20) {
            try cd_w.writeByte('_');
        } else {
            try cd_w.writeByte(c);
        }
    }
    try cd_w.writeAll("\"");
    const cd_value = cd_w.buffered();

    const headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/pdf" },
        .{ .name = "Content-Disposition", .value = cd_value },
    } ++ cors_headers;

    try request.respond(result.bytes, .{ .status = .ok, .extra_headers = &headers });
}

fn respondProjectsSlicesDelete(
    io: std.Io,
    gpa: std.mem.Allocator,
    db: *Db,
    request: *http.Server.Request,
    opts: ServeOptions,
    project_id: []const u8,
    filename: []const u8,
) !void {
    handlers.handleProjectsSlicesDelete(io, gpa, db, opts.data_dir, project_id, filename) catch |err| {
        const status: std.http.Status = switch (err) {
            error.NotFound => .not_found,
            error.InvalidFilename => .bad_request,
            else => .internal_server_error,
        };
        const code: []const u8 = switch (err) {
            error.NotFound => "NOT_FOUND",
            error.InvalidFilename => "INVALID_FILENAME",
            else => "INTERNAL_ERROR",
        };
        return respondError(request, status, code, "Slice not deleted");
    };
    try request.respond("", .{ .status = .no_content, .extra_headers = &cors_headers });
}

fn respondProjectsJobsOcr(
    io: std.Io,
    gpa: std.mem.Allocator,
    db: *Db,
    request: *http.Server.Request,
    project_id: []const u8,
) !void {
    var read_buf: [4096]u8 = undefined;
    const body_reader = request.readerExpectNone(&read_buf);
    const body = body_reader.allocRemaining(gpa, .limited(1 * 1024 * 1024)) catch {
        return respondError(request, .bad_request, "INVALID_REQUEST", "Body too large or unreadable");
    };
    defer gpa.free(body);

    var result = handlers_ocr.handleEnqueueOcr(io, gpa, db, project_id, body) catch |err| {
        const status: std.http.Status = switch (err) {
            error.InvalidRequest => .bad_request,
            error.ProjectNotFound, error.SliceNotFound => .not_found,
            else => .internal_server_error,
        };
        const code: []const u8 = switch (err) {
            error.InvalidRequest => "INVALID_REQUEST",
            error.ProjectNotFound => "NOT_FOUND",
            error.SliceNotFound => "NOT_FOUND",
            else => "INTERNAL_ERROR",
        };
        const message: []const u8 = switch (err) {
            error.InvalidRequest => "Invalid request body",
            error.ProjectNotFound => "Project not found",
            error.SliceNotFound => "Slice not found",
            else => "Internal error",
        };
        return respondError(request, status, code, message);
    };
    defer result.deinit(gpa);

    var resp_buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&resp_buf);
    try json.writeJobCreated(&w, result.job_id);
    const resp_body = w.buffered();

    const headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
    } ++ cors_headers;

    try request.respond(resp_body, .{ .status = .created, .extra_headers = &headers });
}

fn respondProjectsJobsOcrAll(
    io: std.Io,
    gpa: std.mem.Allocator,
    db: *Db,
    request: *http.Server.Request,
    project_id: []const u8,
) !void {
    var result = handlers_ocr.handleEnqueueOcrAll(io, gpa, db, project_id) catch |err| {
        const status: std.http.Status = switch (err) {
            error.ProjectNotFound => .not_found,
            else => .internal_server_error,
        };
        const code: []const u8 = switch (err) {
            error.ProjectNotFound => "NOT_FOUND",
            else => "INTERNAL_ERROR",
        };
        const message: []const u8 = switch (err) {
            error.ProjectNotFound => "Project not found",
            else => "Internal error",
        };
        return respondError(request, status, code, message);
    };
    defer result.deinit(gpa);

    // Build {"job_ids":["id1","id2",...]}
    var buf: [16 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try w.writeAll("{\"job_ids\":[");
    for (result.job_ids, 0..) |jid, i| {
        if (i > 0) try w.writeAll(",");
        try json.writeJsonString(&w, jid);
    }
    try w.writeAll("]}");
    const resp_body = w.buffered();

    const headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
    } ++ cors_headers;

    try request.respond(resp_body, .{ .status = .created, .extra_headers = &headers });
}

fn respondProjectsExtractionsList(
    gpa: std.mem.Allocator,
    db: *Db,
    request: *http.Server.Request,
    project_id: []const u8,
) !void {
    const list = handlers_ocr.handleListExtractions(gpa, db, project_id) catch |err| {
        const status: std.http.Status = switch (err) {
            error.ProjectNotFound => .not_found,
            else => .internal_server_error,
        };
        const code: []const u8 = switch (err) {
            error.ProjectNotFound => "NOT_FOUND",
            else => "INTERNAL_ERROR",
        };
        return respondError(request, status, code, "Extractions unavailable");
    };
    defer extractions_mod.deinitList(list, gpa);

    var buf: [256 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try w.writeAll("[");
    for (list, 0..) |e, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"project_id\":");
        try json.writeJsonString(&w, e.project_id);
        try w.writeAll(",\"slice_filename\":");
        try json.writeJsonString(&w, e.slice_filename);
        try w.writeAll(",\"markdown_path\":");
        try json.writeJsonString(&w, e.markdown_path);
        try w.writeAll(",\"meta_path\":");
        try json.writeJsonString(&w, e.meta_path);
        try w.writeAll(",\"model\":");
        try json.writeJsonString(&w, e.model);
        try w.print(",\"pages\":{d},\"page_markers_found\":{d}", .{ e.pages, e.page_markers_found });
        try w.writeAll(",\"input_tokens\":");
        if (e.input_tokens) |v| try w.print("{d}", .{v}) else try w.writeAll("null");
        try w.writeAll(",\"output_tokens\":");
        if (e.output_tokens) |v| try w.print("{d}", .{v}) else try w.writeAll("null");
        try w.writeAll(",\"input_cost_usd\":");
        if (e.input_cost_usd) |v| try w.print("{d}", .{v}) else try w.writeAll("null");
        try w.writeAll(",\"output_cost_usd\":");
        if (e.output_cost_usd) |v| try w.print("{d}", .{v}) else try w.writeAll("null");
        try w.print(",\"latency_s\":{d}", .{e.latency_s});
        try w.writeAll(",\"created_at\":");
        try json.writeJsonString(&w, e.created_at);
        try w.writeAll("}");
    }
    try w.writeAll("]");
    const resp_body = w.buffered();

    const headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
    } ++ cors_headers;

    try request.respond(resp_body, .{ .status = .ok, .extra_headers = &headers });
}

fn respondProjectsExtractionsGet(
    io: std.Io,
    gpa: std.mem.Allocator,
    db: *Db,
    request: *http.Server.Request,
    project_id: []const u8,
    slice_filename: []const u8,
) !void {
    const result = handlers_ocr.handleGetExtractionMarkdown(io, gpa, db, project_id, slice_filename) catch |err| {
        const status: std.http.Status = switch (err) {
            error.ProjectNotFound, error.ExtractionNotFound => .not_found,
            else => .internal_server_error,
        };
        const code: []const u8 = switch (err) {
            error.ProjectNotFound, error.ExtractionNotFound => "NOT_FOUND",
            else => "INTERNAL_ERROR",
        };
        return respondError(request, status, code, "Extraction not available");
    };
    defer result.deinit(gpa);

    const headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "text/plain; charset=utf-8" },
    } ++ cors_headers;

    try request.respond(result.markdown_bytes, .{ .status = .ok, .extra_headers = &headers });
}

fn respondProjectsJobsPrompt(
    io: std.Io,
    gpa: std.mem.Allocator,
    db: *Db,
    request: *http.Server.Request,
    project_id: []const u8,
) !void {
    var read_buf: [4096]u8 = undefined;
    const body_reader = request.readerExpectNone(&read_buf);
    const body = body_reader.allocRemaining(gpa, .limited(1 * 1024 * 1024)) catch {
        return respondError(request, .bad_request, "INVALID_REQUEST", "Body too large or unreadable");
    };
    defer gpa.free(body);

    var result = handlers_prompts.handleEnqueuePrompt(io, gpa, db, project_id, body) catch |err| {
        const status: std.http.Status = switch (err) {
            error.InvalidRequest => .bad_request,
            error.ProjectNotFound => .not_found,
            else => .internal_server_error,
        };
        const code: []const u8 = switch (err) {
            error.InvalidRequest => "INVALID_REQUEST",
            error.ProjectNotFound => "NOT_FOUND",
            else => "INTERNAL_ERROR",
        };
        const message: []const u8 = switch (err) {
            error.InvalidRequest => "Invalid or unknown prompt_name",
            error.ProjectNotFound => "Project not found",
            else => "Internal error",
        };
        return respondError(request, status, code, message);
    };
    defer result.deinit(gpa);

    var resp_buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&resp_buf);
    try json.writeJobCreated(&w, result.job_id);
    const resp_body = w.buffered();

    const headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
    } ++ cors_headers;

    try request.respond(resp_body, .{ .status = .created, .extra_headers = &headers });
}

fn respondProjectsJobsPromptAll(
    io: std.Io,
    gpa: std.mem.Allocator,
    db: *Db,
    request: *http.Server.Request,
    project_id: []const u8,
) !void {
    var result = handlers_prompts.handleEnqueuePromptAll(io, gpa, db, project_id) catch |err| {
        const status: std.http.Status = switch (err) {
            error.ProjectNotFound => .not_found,
            else => .internal_server_error,
        };
        const code: []const u8 = switch (err) {
            error.ProjectNotFound => "NOT_FOUND",
            else => "INTERNAL_ERROR",
        };
        const message: []const u8 = switch (err) {
            error.ProjectNotFound => "Project not found",
            else => "Internal error",
        };
        return respondError(request, status, code, message);
    };
    defer result.deinit(gpa);

    // Build {"job_ids":["id1","id2",...]}
    var buf: [16 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try w.writeAll("{\"job_ids\":[");
    for (result.job_ids, 0..) |jid, i| {
        if (i > 0) try w.writeAll(",");
        try json.writeJsonString(&w, jid);
    }
    try w.writeAll("]}");
    const resp_body = w.buffered();

    const headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
    } ++ cors_headers;

    try request.respond(resp_body, .{ .status = .created, .extra_headers = &headers });
}

fn respondProjectsPromptsList(
    gpa: std.mem.Allocator,
    db: *Db,
    request: *http.Server.Request,
    project_id: []const u8,
) !void {
    const list = handlers_prompts.handleListPrompts(gpa, db, project_id) catch |err| {
        const status: std.http.Status = switch (err) {
            error.ProjectNotFound => .not_found,
            else => .internal_server_error,
        };
        const code: []const u8 = switch (err) {
            error.ProjectNotFound => "NOT_FOUND",
            else => "INTERNAL_ERROR",
        };
        return respondError(request, status, code, "Prompts unavailable");
    };
    defer prompt_outputs_mod.deinitList(list, gpa);

    var buf: [256 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try w.writeAll("[");
    for (list, 0..) |p, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"project_id\":");
        try json.writeJsonString(&w, p.project_id);
        try w.writeAll(",\"prompt_name\":");
        try json.writeJsonString(&w, p.prompt_name);
        try w.writeAll(",\"markdown_path\":");
        try json.writeJsonString(&w, p.markdown_path);
        try w.writeAll(",\"model\":");
        try json.writeJsonString(&w, p.model);
        try w.writeAll(",\"input_tokens\":");
        if (p.input_tokens) |v| try w.print("{d}", .{v}) else try w.writeAll("null");
        try w.writeAll(",\"output_tokens\":");
        if (p.output_tokens) |v| try w.print("{d}", .{v}) else try w.writeAll("null");
        try w.writeAll(",\"input_cost_usd\":");
        if (p.input_cost_usd) |v| try w.print("{d}", .{v}) else try w.writeAll("null");
        try w.writeAll(",\"output_cost_usd\":");
        if (p.output_cost_usd) |v| try w.print("{d}", .{v}) else try w.writeAll("null");
        try w.print(",\"latency_s\":{d}", .{p.latency_s});
        try w.writeAll(",\"warnings\":");
        try w.writeAll(p.warnings_json);
        try w.writeAll(",\"created_at\":");
        try json.writeJsonString(&w, p.created_at);
        try w.writeAll("}");
    }
    try w.writeAll("]");
    const resp_body = w.buffered();

    const headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
    } ++ cors_headers;

    try request.respond(resp_body, .{ .status = .ok, .extra_headers = &headers });
}

fn respondProjectsPromptsGet(
    io: std.Io,
    gpa: std.mem.Allocator,
    db: *Db,
    request: *http.Server.Request,
    project_id: []const u8,
    prompt_name: []const u8,
) !void {
    const result = handlers_prompts.handleGetPromptMarkdown(io, gpa, db, project_id, prompt_name) catch |err| {
        const status: std.http.Status = switch (err) {
            error.ProjectNotFound, error.PromptNotFound => .not_found,
            else => .internal_server_error,
        };
        const code: []const u8 = switch (err) {
            error.ProjectNotFound, error.PromptNotFound => "NOT_FOUND",
            else => "INTERNAL_ERROR",
        };
        return respondError(request, status, code, "Prompt output not available");
    };
    defer result.deinit(gpa);

    const headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "text/plain; charset=utf-8" },
    } ++ cors_headers;

    try request.respond(result.markdown_bytes, .{ .status = .ok, .extra_headers = &headers });
}

fn respondJobsCancel(
    gpa: std.mem.Allocator,
    request: *http.Server.Request,
    dispatcher: ?*@import("../agents/dispatcher.zig").Dispatcher,
    job_id: []const u8,
) !void {
    _ = gpa;
    const status_code = handlers_jobs.handleCancelJob(dispatcher, job_id) catch {
        return respondError(request, .internal_server_error, "INTERNAL_ERROR", "Internal error");
    };
    if (status_code == 202) {
        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
        } ++ cors_headers;
        try request.respond("{\"status\":\"canceling\"}", .{
            .status = .accepted,
            .extra_headers = &headers,
        });
    } else {
        // 503: dispatcher not yet wired. Return a descriptive error.
        return respondError(request, .service_unavailable, "SERVICE_UNAVAILABLE", "Dispatcher not available");
    }
}

fn respondJobsLogs(
    gpa: std.mem.Allocator,
    db: *Db,
    request: *http.Server.Request,
    job_id: []const u8,
) !void {
    const result = handlers_jobs.handleGetLogs(gpa, db, job_id) catch {
        return respondError(request, .internal_server_error, "INTERNAL_ERROR", "Internal error");
    };
    defer result.deinit(gpa);

    const headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
    } ++ cors_headers;

    try request.respond(result.json_body, .{
        .status = .ok,
        .extra_headers = &headers,
    });
}

fn respondJobsStream(
    io: std.Io,
    db: *Db,
    request: *http.Server.Request,
    req_mutex: *std.Io.Mutex,
    job_id: []const u8,
) !void {
    const sse_headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "text/event-stream" },
        .{ .name = "Cache-Control", .value = "no-cache" },
        .{ .name = "Connection", .value = "keep-alive" },
    } ++ cors_headers;

    // respondStreaming uses chunked transfer encoding by default (no content-length).
    // Provide a 4 KiB write buffer.
    var body_buf: [4096]u8 = undefined;
    var body_writer = try request.respondStreaming(&body_buf, .{
        .respond_options = .{
            .status = .ok,
            .extra_headers = &sse_headers,
        },
    });

    // streamJob manages the mutex: it holds it for DB queries and releases it
    // during each 500 ms sleep. It always unlocks before returning.
    sse.streamJob(db, req_mutex, io, job_id, &body_writer.writer);

    // Re-acquire the mutex so the `defer req_mutex.unlock(io)` in
    // handleConnection can perform its paired unlock cleanly.
    req_mutex.lockUncancelable(io);

    // Finalize the chunked stream (writes the terminal zero-length chunk).
    body_writer.end() catch {};
}

fn respondNotFound(gpa: std.mem.Allocator, request: *http.Server.Request) !void {
    _ = gpa;
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try json.writeError(&w, "NOT_FOUND", "Endpoint not found");
    const body = w.buffered();

    const headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
    } ++ cors_headers;

    try request.respond(body, .{
        .status = .not_found,
        .extra_headers = &headers,
    });
}
