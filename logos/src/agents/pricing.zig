const std = @import("std");

/// Per-million-token rates in USD. Append rows when introducing a new model;
/// never modify an existing row (historical jobs reference these rates via
/// stored *_cost_usd columns).
pub const ModelRate = struct {
    model: []const u8,
    input_per_million_usd: f64,
    output_per_million_usd: f64,
};

pub const PRICING: []const ModelRate = &.{
    .{ .model = "gemini-2.5-flash",        .input_per_million_usd = 0.30, .output_per_million_usd = 2.50 },
    .{ .model = "gemini-2.5-pro",          .input_per_million_usd = 1.25, .output_per_million_usd = 10.00 },
    .{ .model = "claude-sonnet-4-6",       .input_per_million_usd = 3.00, .output_per_million_usd = 15.00 },
    .{ .model = "gemini-3.5-flash",        .input_per_million_usd = 1.50, .output_per_million_usd = 9.00 },
    .{ .model = "gemini-3.1-pro-preview",  .input_per_million_usd = 1.25, .output_per_million_usd = 10.00 },
};

pub fn lookup(model: []const u8) ?ModelRate {
    for (PRICING) |row| {
        if (std.mem.eql(u8, row.model, model)) return row;
    }
    return null;
}

/// Compute (input_cost_usd, output_cost_usd) for the given model and token counts.
/// Returns null if the model isn't in the pricing table; callers should leave the
/// corresponding DB columns NULL ("uncosted").
pub const CostUsd = struct { input: f64, output: f64 };

pub fn cost(model: []const u8, input_tokens: i64, output_tokens: i64) ?CostUsd {
    const rate = lookup(model) orelse return null;
    const in_f: f64 = @floatFromInt(input_tokens);
    const out_f: f64 = @floatFromInt(output_tokens);
    return .{
        .input = in_f * rate.input_per_million_usd / 1_000_000.0,
        .output = out_f * rate.output_per_million_usd / 1_000_000.0,
    };
}

test "lookup returns known models" {
    const r = lookup("gemini-2.5-flash") orelse return error.NotFound;
    try std.testing.expectApproxEqAbs(@as(f64, 0.30), r.input_per_million_usd, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 2.50), r.output_per_million_usd, 0.0001);
}

test "lookup returns null for unknown models" {
    try std.testing.expect(lookup("nope-model") == null);
}

test "cost computation for known model" {
    const c = cost("gemini-2.5-flash", 46_154, 136_477) orelse return error.NotFound;
    // 46154 * 0.30 / 1e6 = 0.01384620
    try std.testing.expectApproxEqAbs(@as(f64, 0.01384620), c.input, 1e-6);
    // 136477 * 2.50 / 1e6 = 0.34119250
    try std.testing.expectApproxEqAbs(@as(f64, 0.34119250), c.output, 1e-6);
}

test "cost returns null for uncosted model" {
    try std.testing.expect(cost("unknown-llm", 1000, 5000) == null);
}
