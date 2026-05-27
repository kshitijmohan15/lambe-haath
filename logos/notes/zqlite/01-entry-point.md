# 01 — The Entry Point

A line-by-line walk through `src/zqlite.zig`, the file a consumer hits first when they write `@import("zqlite")`.

> Source: `zig-pkg/zqlite-0.0.1-.../src/zqlite.zig` (the upstream is `github.com/karlseguin/zqlite.zig`).

## What "entry point" means here

This is a **library**, not an executable. There is no `main()`. The entry point is the file that a consumer imports.

`build.zig` declares it:

```zig
const mod_zqlite = b.addModule("zqlite", .{
    .root_source_file = b.path("src/zqlite.zig"),  // ← entry point
    ...
});
```

When a consumer writes `const zqlite = @import("zqlite")`, they receive whatever `src/zqlite.zig` exports as `pub`. That file is the front door.

---

## `src/zqlite.zig` line by line

### Lines 1-2 — imports

```zig
const std = @import("std");
pub const c = @import("c");
```

**Line 1** pulls in Zig's standard library. Standard in every Zig file.

**Line 2** pulls in the C bindings module and re-exports it as `pub const c`. The name `"c"` is not a Zig builtin — it is the name `build.zig` gave the module when wiring up `translate-c`:

```zig
.imports = &.{
    .{ .name = "c", .module = translate_c.createModule() }
}
```

So `@import("c")` here resolves to "the module produced by running `translate-c` on `lib/sqlite3.h`." That module contains every `sqlite3_*` function and every `SQLITE_*` constant, rewritten as Zig declarations.

The `pub` matters: a consumer can write `zqlite.c.sqlite3_some_function(...)` to bypass the wrapper and call SQLite directly. Most consumers won't, but the escape hatch is there.

### Lines 4-11 — re-exports

```zig
pub const Pool = @import("pool.zig").Pool;

const conn = @import("conn.zig");
pub const Conn = conn.Conn;
pub const Row = conn.Row;
pub const Rows = conn.Rows;
pub const Stmt = conn.Stmt;
pub const ColumnType = conn.ColumnType;
```

Pure re-exports. The actual code lives in `pool.zig` and `conn.zig`; this file makes those types reachable as `zqlite.Conn`, `zqlite.Row`, etc.

Why re-export instead of letting consumers import the internal files directly?

1. **Stable surface.** The consumer-facing name is `zqlite.Conn` regardless of which internal file holds the definition. You can move things between files without breaking callers.
2. **Discoverability.** Reading `zqlite.zig` top-to-bottom tells you what the library offers.

Note the style asymmetry:
- Line 4: `pub const Pool = @import("pool.zig").Pool;` — one-liner, no local binding.
- Line 6: `const conn = @import("conn.zig");` — binds the whole module to a local, then re-exports five things from it.

Both work. The author used whichever was shorter for the number of re-exports.

### Lines 13-15 — `open()`, the function consumers call first

```zig
pub fn open(path: [*:0]const u8, flags: c_int) !Conn {
    return Conn.init(path, flags);
}
```

A one-line shim that forwards to `Conn.init`.

Why have a shim instead of telling consumers to call `Conn.init` directly? Style. `zqlite.open(...)` reads like idiomatic top-level usage; `zqlite.Conn.init(...)` reads like object construction.

The signature is worth pausing on:

- **`path: [*:0]const u8`** — a pointer to a null-terminated string of bytes. Not `[]const u8` (a slice). SQLite's C function needs a `const char *`, which is null-terminated. Zig has a dedicated type for that: `[*:0]const u8` reads as "many-item pointer, sentinel-terminated by `0`, immutable `u8`s." If a consumer passes a non-null-terminated string, the compiler refuses.

- **`flags: c_int`** — the SQLite open flags as a C `int`. Matches what `sqlite3_open_v2` expects.

- **`!Conn`** — Zig error union. Either returns a `Conn` or returns one of the errors in the `Error` enum defined later in this file.

`Conn.init` itself is in the next walkthrough.

### Lines 17-25 — the `Blob` marker

```zig
// a marker type so we can tell if the provided []const u8 should be treated as
// a text or a blob
pub const Blob = struct {
    value: []const u8,
};

pub fn blob(value: []const u8) Blob {
    return .{ .value = value };
}
```

This is the cleverest bit in the file.

When you write `conn.exec("insert into t values (?1)", .{some_bytes})`, what should SQLite do — store `some_bytes` as TEXT or as BLOB?

In Zig, there is no way to tell. Both are `[]const u8`. A UTF-8 string and a binary blob have the exact same type.

The wrapper's solution: **default `[]const u8` to TEXT.** If you want BLOB, wrap it in this `Blob` struct:

```zig
conn.exec("insert into t values (?1)", .{ zqlite.blob(some_bytes) });
```

Now the argument is a `Blob`, not a `[]const u8`. The bind code in `conn.zig` switches on the type and calls `sqlite3_bind_blob` instead of `sqlite3_bind_text`.

The `Blob` struct does nothing at runtime — it just holds the same slice. It is a **type-level tag**, used purely so the compiler can dispatch differently. The `blob()` function is sugar so consumers write `zqlite.blob(x)` instead of `zqlite.Blob{ .value = x }`.

### Lines 27-29 — `isUnique`

```zig
pub fn isUnique(err: Error) bool {
    return err == error.ConstraintUnique;
}
```

A convenience helper. "Did this error come from a UNIQUE constraint violation?" The most common thing app code wants to ask after a failed INSERT. Saves the consumer from importing the `Error` enum just to compare one tag.

This is the **only** convenience helper in the file. Every other error check is on the consumer.

---

## What's covered so far

Everything above line 31:

- Module imports (`std`, `c`)
- Type re-exports (`Pool`, `Conn`, `Row`, `Rows`, `Stmt`, `ColumnType`)
- The `open()` entry function (forwards to `Conn.init`)
- The `Blob` marker type and `blob()` helper
- The `isUnique` error helper

## What comes next

- Lines 31-54: `OpenFlags` — namespaced wrapper over SQLite's `SQLITE_OPEN_*` constants.
- Lines 56-159: the `Error` enum — every SQLite result code mapped to a Zig error tag.
- Then `Conn.init` in `src/conn.zig`, where we actually call into SQLite.
