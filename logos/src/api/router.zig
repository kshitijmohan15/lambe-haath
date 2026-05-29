const std = @import("std");
const testing = std.testing;

pub const Method = enum { GET, POST, DELETE, OPTIONS };

pub const Route = enum {
    health,
    projects_list,
    projects_create,
    projects_get,
    projects_delete,
    projects_chargesheet,
    projects_jobs_slice,
    projects_jobs_get,
    projects_jobs_list,
    projects_jobs_ocr,
    projects_jobs_ocr_all,
    projects_slices_list,
    projects_slices_get,
    projects_slices_delete,
    projects_extractions_list,
    projects_extractions_get,
    projects_jobs_prompt,
    projects_jobs_prompt_all,
    projects_prompts_list,
    projects_prompts_get,
    projects_prompts_export,
    jobs_cancel,
    jobs_logs,
    jobs_stream,
    stats_overview,
    stats_project,
    stats_timeseries,
    stats_slow,
    not_found,
    cors_preflight,
};

pub const Match = struct {
    route: Route,
    /// First path parameter (e.g. project id).
    id: ?[]const u8 = null,
    /// Second path parameter (e.g. job_id or filename).
    child: ?[]const u8 = null,
};

pub fn match(method: Method, raw_path: []const u8) Match {
    // Strip query string so matchers work with or without ?key=val params.
    const q = std.mem.indexOfScalar(u8, raw_path, '?') orelse raw_path.len;
    const path = raw_path[0..q];

    if (method == .OPTIONS and std.mem.startsWith(u8, path, "/api/")) {
        return .{ .route = .cors_preflight };
    }
    if (method == .GET and std.mem.eql(u8, path, "/api/v1/health")) return .{ .route = .health };
    if (method == .GET and std.mem.eql(u8, path, "/api/v1/projects")) return .{ .route = .projects_list };
    if (method == .POST and std.mem.eql(u8, path, "/api/v1/projects")) return .{ .route = .projects_create };

    // /api/v1/jobs/:id/cancel  and  /api/v1/jobs/:id/logs
    const jobs_prefix = "/api/v1/jobs/";
    if (std.mem.startsWith(u8, path, jobs_prefix)) {
        const after_jobs = path[jobs_prefix.len..];
        // Find the slash separating job_id from the action suffix.
        if (std.mem.indexOfScalar(u8, after_jobs, '/')) |slash| {
            const job_id = after_jobs[0..slash];
            const action = after_jobs[slash + 1 ..];
            if (job_id.len > 0) {
                if (method == .POST and std.mem.eql(u8, action, "cancel")) {
                    return .{ .route = .jobs_cancel, .id = job_id };
                }
                if (method == .GET and std.mem.eql(u8, action, "logs")) {
                    return .{ .route = .jobs_logs, .id = job_id };
                }
                if (method == .GET and std.mem.eql(u8, action, "stream")) {
                    return .{ .route = .jobs_stream, .id = job_id };
                }
            }
        }
        return .{ .route = .not_found };
    }

    // /api/v1/stats routes — order matters: /slow and /timeseries before /project/:id
    if (method == .GET and std.mem.eql(u8, path, "/api/v1/stats")) {
        return .{ .route = .stats_overview };
    }
    if (method == .GET and std.mem.eql(u8, path, "/api/v1/stats/slow")) {
        return .{ .route = .stats_slow };
    }
    if (method == .GET and std.mem.eql(u8, path, "/api/v1/stats/timeseries")) {
        return .{ .route = .stats_timeseries };
    }
    const stats_project_prefix = "/api/v1/stats/project/";
    if (method == .GET and std.mem.startsWith(u8, path, stats_project_prefix)) {
        const id = path[stats_project_prefix.len..];
        if (id.len > 0 and std.mem.indexOfScalar(u8, id, '/') == null) {
            return .{ .route = .stats_project, .id = id };
        }
    }

    const prefix = "/api/v1/projects/";
    if (!std.mem.startsWith(u8, path, prefix)) return .{ .route = .not_found };

    const rest = path[prefix.len..];
    const first_slash = std.mem.indexOfScalar(u8, rest, '/');
    if (first_slash == null) {
        if (method == .GET) return .{ .route = .projects_get, .id = rest };
        if (method == .DELETE) return .{ .route = .projects_delete, .id = rest };
        return .{ .route = .not_found };
    }

    const id = rest[0..first_slash.?];
    const after_id = rest[first_slash.? + 1 ..];

    // /api/v1/projects/:id/chargesheet
    if (method == .GET and std.mem.eql(u8, after_id, "chargesheet")) {
        return .{ .route = .projects_chargesheet, .id = id };
    }

    // /api/v1/projects/:id/jobs   (list all jobs for project, optional ?status=...)
    if (method == .GET and std.mem.eql(u8, after_id, "jobs")) {
        return .{ .route = .projects_jobs_list, .id = id };
    }

    // /api/v1/projects/:id/jobs/...
    if (std.mem.startsWith(u8, after_id, "jobs/")) {
        const job_part = after_id["jobs/".len..];
        if (method == .POST and std.mem.eql(u8, job_part, "slice")) {
            return .{ .route = .projects_jobs_slice, .id = id };
        }
        if (method == .POST and std.mem.eql(u8, job_part, "ocr/all")) {
            return .{ .route = .projects_jobs_ocr_all, .id = id };
        }
        if (method == .POST and std.mem.eql(u8, job_part, "ocr")) {
            return .{ .route = .projects_jobs_ocr, .id = id };
        }
        if (method == .POST and std.mem.eql(u8, job_part, "prompt/all")) {
            return .{ .route = .projects_jobs_prompt_all, .id = id };
        }
        if (method == .POST and std.mem.eql(u8, job_part, "prompt")) {
            return .{ .route = .projects_jobs_prompt, .id = id };
        }
        // /api/v1/projects/:id/jobs/:job_id
        if (method == .GET and std.mem.indexOfScalar(u8, job_part, '/') == null and job_part.len > 0) {
            return .{ .route = .projects_jobs_get, .id = id, .child = job_part };
        }
    }

    // /api/v1/projects/:id/slices/...
    if (std.mem.eql(u8, after_id, "slices") and method == .GET) {
        return .{ .route = .projects_slices_list, .id = id };
    }
    if (std.mem.startsWith(u8, after_id, "slices/")) {
        const filename = after_id["slices/".len..];
        if (filename.len > 0 and std.mem.indexOfScalar(u8, filename, '/') == null) {
            if (method == .GET) return .{ .route = .projects_slices_get, .id = id, .child = filename };
            if (method == .DELETE) return .{ .route = .projects_slices_delete, .id = id, .child = filename };
        }
    }

    // /api/v1/projects/:id/extractions/...
    if (std.mem.eql(u8, after_id, "extractions") and method == .GET) {
        return .{ .route = .projects_extractions_list, .id = id };
    }
    if (std.mem.startsWith(u8, after_id, "extractions/")) {
        const filename = after_id["extractions/".len..];
        if (filename.len > 0 and std.mem.indexOfScalar(u8, filename, '/') == null) {
            if (method == .GET) return .{ .route = .projects_extractions_get, .id = id, .child = filename };
        }
    }

    // /api/v1/projects/:id/prompts/...
    if (std.mem.eql(u8, after_id, "prompts") and method == .GET) {
        return .{ .route = .projects_prompts_list, .id = id };
    }
    // /api/v1/projects/:id/prompts/export — must come BEFORE the catch-all
    // prompts/:prompt_name matcher below, otherwise "export" would be parsed
    // as a prompt name.
    if (method == .GET and std.mem.eql(u8, after_id, "prompts/export")) {
        return .{ .route = .projects_prompts_export, .id = id };
    }
    if (std.mem.startsWith(u8, after_id, "prompts/")) {
        const prompt_name = after_id["prompts/".len..];
        if (prompt_name.len > 0 and std.mem.indexOfScalar(u8, prompt_name, '/') == null) {
            if (method == .GET) return .{ .route = .projects_prompts_get, .id = id, .child = prompt_name };
        }
    }

    return .{ .route = .not_found };
}

test "match returns health for GET /api/v1/health" {
    const m = match(.GET, "/api/v1/health");
    try testing.expectEqual(Route.health, m.route);
    try testing.expect(m.id == null);
}

test "match returns projects_list for GET /api/v1/projects" {
    const m = match(.GET, "/api/v1/projects");
    try testing.expectEqual(Route.projects_list, m.route);
}

test "match extracts id from GET /api/v1/projects/:id" {
    const m = match(.GET, "/api/v1/projects/proj_abc123");
    try testing.expectEqual(Route.projects_get, m.route);
    try testing.expectEqualStrings("proj_abc123", m.id.?);
}

test "match extracts id from DELETE /api/v1/projects/:id" {
    const m = match(.DELETE, "/api/v1/projects/proj_xyz");
    try testing.expectEqual(Route.projects_delete, m.route);
    try testing.expectEqualStrings("proj_xyz", m.id.?);
}

test "match extracts id from GET /api/v1/projects/:id/chargesheet" {
    const m = match(.GET, "/api/v1/projects/proj_abc/chargesheet");
    try testing.expectEqual(Route.projects_chargesheet, m.route);
    try testing.expectEqualStrings("proj_abc", m.id.?);
}

test "match returns cors_preflight for OPTIONS /api/v1/anything" {
    const m = match(.OPTIONS, "/api/v1/anything");
    try testing.expectEqual(Route.cors_preflight, m.route);
}

test "match returns not_found for unknown paths" {
    const m = match(.GET, "/api/v1/unknown");
    try testing.expectEqual(Route.not_found, m.route);
}

test "match POST /api/v1/projects/:id/jobs/slice" {
    const m = match(.POST, "/api/v1/projects/proj_abc/jobs/slice");
    try testing.expectEqual(Route.projects_jobs_slice, m.route);
    try testing.expectEqualStrings("proj_abc", m.id.?);
    try testing.expect(m.child == null);
}

test "match GET /api/v1/projects/:id/jobs/:job_id" {
    const m = match(.GET, "/api/v1/projects/proj_abc/jobs/job_xyz");
    try testing.expectEqual(Route.projects_jobs_get, m.route);
    try testing.expectEqualStrings("proj_abc", m.id.?);
    try testing.expectEqualStrings("job_xyz", m.child.?);
}

test "router matches GET /api/v1/projects/:id/jobs" {
    const m = match(.GET, "/api/v1/projects/proj_abc/jobs");
    try testing.expectEqual(Route.projects_jobs_list, m.route);
    try testing.expectEqualStrings("proj_abc", m.id.?);
    try testing.expect(m.child == null);
}

test "router matches GET /api/v1/projects/:id/jobs with query string" {
    const m = match(.GET, "/api/v1/projects/proj_abc/jobs?status=running");
    try testing.expectEqual(Route.projects_jobs_list, m.route);
    try testing.expectEqualStrings("proj_abc", m.id.?);
}

test "match GET /api/v1/projects/:id/slices" {
    const m = match(.GET, "/api/v1/projects/proj_abc/slices");
    try testing.expectEqual(Route.projects_slices_list, m.route);
    try testing.expectEqualStrings("proj_abc", m.id.?);
    try testing.expect(m.child == null);
}

test "match GET /api/v1/projects/:id/slices/:filename" {
    const m = match(.GET, "/api/v1/projects/proj_abc/slices/intro.pdf");
    try testing.expectEqual(Route.projects_slices_get, m.route);
    try testing.expectEqualStrings("proj_abc", m.id.?);
    try testing.expectEqualStrings("intro.pdf", m.child.?);
}

test "match DELETE /api/v1/projects/:id/slices/:filename" {
    const m = match(.DELETE, "/api/v1/projects/proj_abc/slices/intro.pdf");
    try testing.expectEqual(Route.projects_slices_delete, m.route);
    try testing.expectEqualStrings("proj_abc", m.id.?);
    try testing.expectEqualStrings("intro.pdf", m.child.?);
}

test "match rejects nested filename slashes" {
    const m = match(.GET, "/api/v1/projects/proj_abc/slices/sub/dir.pdf");
    try testing.expectEqual(Route.not_found, m.route);
}

test "match POST /api/v1/jobs/:id/cancel" {
    const m = match(.POST, "/api/v1/jobs/job_abc123/cancel");
    try testing.expectEqual(Route.jobs_cancel, m.route);
    try testing.expectEqualStrings("job_abc123", m.id.?);
    try testing.expect(m.child == null);
}

test "match GET /api/v1/jobs/:id/logs" {
    const m = match(.GET, "/api/v1/jobs/job_abc123/logs");
    try testing.expectEqual(Route.jobs_logs, m.route);
    try testing.expectEqualStrings("job_abc123", m.id.?);
    try testing.expect(m.child == null);
}

test "match GET /api/v1/jobs/:id/stream" {
    const m = match(.GET, "/api/v1/jobs/job_abc123/stream");
    try testing.expectEqual(Route.jobs_stream, m.route);
    try testing.expectEqualStrings("job_abc123", m.id.?);
    try testing.expect(m.child == null);
}

test "match GET /api/v1/jobs/:id/cancel is not_found (wrong method)" {
    const m = match(.GET, "/api/v1/jobs/job_abc123/cancel");
    try testing.expectEqual(Route.not_found, m.route);
}

test "match /api/v1/jobs/ with no id is not_found" {
    const m = match(.POST, "/api/v1/jobs/");
    try testing.expectEqual(Route.not_found, m.route);
}

test "router matches GET /api/v1/stats" {
    const m = match(.GET, "/api/v1/stats");
    try testing.expectEqual(Route.stats_overview, m.route);
}

test "router matches GET /api/v1/stats/project/:id" {
    const m = match(.GET, "/api/v1/stats/project/p_abc");
    try testing.expectEqual(Route.stats_project, m.route);
    try testing.expectEqualStrings("p_abc", m.id.?);
}

test "router matches GET /api/v1/stats/timeseries" {
    const m = match(.GET, "/api/v1/stats/timeseries");
    try testing.expectEqual(Route.stats_timeseries, m.route);
}

test "router matches GET /api/v1/stats/timeseries with query string" {
    const m = match(.GET, "/api/v1/stats/timeseries?from=2026-05-01&to=2026-05-29");
    try testing.expectEqual(Route.stats_timeseries, m.route);
}

test "router matches GET /api/v1/stats/slow" {
    const m = match(.GET, "/api/v1/stats/slow");
    try testing.expectEqual(Route.stats_slow, m.route);
}

test "router matches GET /api/v1/stats/slow with query string" {
    const m = match(.GET, "/api/v1/stats/slow?limit=5");
    try testing.expectEqual(Route.stats_slow, m.route);
}

test "router matches GET /api/v1/projects/:id/prompts/export with format param" {
    const m = match(.GET, "/api/v1/projects/proj_abc/prompts/export?format=docx");
    try testing.expectEqual(Route.projects_prompts_export, m.route);
    try testing.expectEqualStrings("proj_abc", m.id.?);
}

test "router matches GET /api/v1/projects/:id/prompts/export without query" {
    const m = match(.GET, "/api/v1/projects/proj_abc/prompts/export");
    try testing.expectEqual(Route.projects_prompts_export, m.route);
    try testing.expectEqualStrings("proj_abc", m.id.?);
}

test "router still matches prompts/:name after adding export route" {
    const m = match(.GET, "/api/v1/projects/proj_abc/prompts/charge_memo_analysis");
    try testing.expectEqual(Route.projects_prompts_get, m.route);
    try testing.expectEqualStrings("proj_abc", m.id.?);
    try testing.expectEqualStrings("charge_memo_analysis", m.child.?);
}
