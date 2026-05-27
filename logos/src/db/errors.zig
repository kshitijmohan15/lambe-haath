const std = @import("std");

pub const DbError = error{
    NotFound,
    UniqueViolation,
    ForeignKeyViolation,
    CheckViolation,
    NotNullViolation,
};

/// Translate a zqlite constraint error into a DbError. Non-constraint errors
/// pass through unchanged.
pub fn mapConstraintErr(err: anyerror) anyerror {
    return switch (err) {
        error.ConstraintUnique => error.UniqueViolation,
        error.ConstraintForeignKey => error.ForeignKeyViolation,
        error.ConstraintCheck => error.CheckViolation,
        error.ConstraintNotNull => error.NotNullViolation,
        error.ConstraintPrimaryKey => error.UniqueViolation,
        else => err,
    };
}

test "mapConstraintErr translates known constraint codes" {
    try std.testing.expectEqual(error.UniqueViolation,     mapConstraintErr(error.ConstraintUnique));
    try std.testing.expectEqual(error.ForeignKeyViolation, mapConstraintErr(error.ConstraintForeignKey));
    try std.testing.expectEqual(error.CheckViolation,      mapConstraintErr(error.ConstraintCheck));
    try std.testing.expectEqual(error.NotNullViolation,    mapConstraintErr(error.ConstraintNotNull));
    try std.testing.expectEqual(error.UniqueViolation,     mapConstraintErr(error.ConstraintPrimaryKey));
    try std.testing.expectEqual(error.OutOfMemory,         mapConstraintErr(error.OutOfMemory));
}
