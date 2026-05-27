# mupdf-zig Library Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a small, properly-shaped Zig 0.16 library at `~/projects/mupdf-zig/` that wraps the ~8 MuPDF C entry points the chargesheet tool (`logos`) needs, with typed `Context`/`Document` handles, a C thunk for `fz_try`/`fz_catch`, and `b.addTranslateC`-based bindings (not `@cImport`).

**Architecture:** A C bridge file (`src/bridge/bridge.c`) wraps every fallible MuPDF call inside `fz_try`/`fz_catch` and returns plain integer error codes — keeping MuPDF's setjmp/longjmp surface isolated from Zig so `defer`/`errdefer` always run. A separate header (`src/bridge/bridge.h`) is fed through `b.addTranslateC` (NOT `@cImport`) to produce a Zig module whose declarations the wrapper imports. Typed `Context` and `Document` structs own their C pointers, with explicit `init`/`deinit` methods. Library is consumable as a `build.zig.zon` dependency — the exported `mupdf` module carries its own C source + MuPDF link state, so consumers just import it and the linker resolves correctly.

**Tech Stack:** Zig 0.16+, MuPDF 1.27+ from Homebrew (hybrid setup at `/opt/homebrew/opt/mupdf` — to be vendored later). `mutool` CLI for fixture generation.

**Why this shape:** Informed by lessons from `~/projects/mupdf-zig-course/` (Modules 2, 4, 6, 7, 8). Specifically: `@cImport` is per-file and cache-poor (Module 2); typed handles with `init`/`deinit` are required for leak-safe lifetimes across C boundaries (Module 4, 7); `fz_try`/`fz_catch` MUST live in C, never straddle a Zig `defer` (Module 6); ownership of `const char *` and similar borrowed pointers must be explicit (Module 8).

**Scope (logos-driven, YAGNI):**

| C entry point | Wrapped via | Reason |
|---|---|---|
| `fz_new_context` | `Context.init` | bootstrap |
| `fz_drop_context` | `Context.deinit` | bootstrap |
| `fz_register_document_handlers` | called inside `Context.init` | required for `pdf_open_document` |
| `pdf_open_document` | `Document.open` | open a PDF |
| `pdf_drop_document` | `Document.deinit` | close a PDF |
| `pdf_needs_password` | folded into `Document.open` (returns `error.EncryptedPdf`) | reject encrypted at open |
| `pdf_count_pages` | `Document.pageCount` | required by logos |
| `pdf_rearrange_pages` + `pdf_save_document` | `Document.slice` | required by logos |
| `FZ_VERSION` | `mupdf.version()` | smoke-test that link works |

8 C entry points. Surface stays narrow; expand when a new consumer needs more.

---

## File Structure

```
~/projects/mupdf-zig/
├── README.md                  # how to consume
├── build.zig                  # exports the `mupdf` module + link state
├── build.zig.zon              # package manifest
├── docs/superpowers/plans/    # this plan lives here
├── src/
│   ├── root.zig               # public API surface — re-exports Context, Document, errors
│   ├── context.zig            # Context struct
│   ├── document.zig           # Document struct
│   ├── errors.zig             # Error set
│   └── bridge/
│       ├── bridge.h           # C bridge header — input to translate-c
│       └── bridge.c           # C thunk — fz_try/fz_catch lives here, NEVER in Zig
└── tests/
    └── fixtures/
        ├── README.md          # how each fixture was generated
        ├── sample-10pages.pdf # 10 blank pages
        ├── not-a-pdf.txt      # plain text for negative tests
        └── encrypted.pdf      # password-protected for EncryptedPdf path
```

Conventions enforced throughout:
- **Strings crossing FFI:** Zig `[:0]const u8` (null-terminated). String literals in tests work as-is.
- **Error returns from C:** all bridge functions return `int` codes (`MUPDF_BRIDGE_OK = 0`, `_ERR_OPEN = 1`, etc.). Out-params via pointer.
- **Lifetimes:** `Document` borrows a `*Context` — caller must keep the Context alive for the Document's lifetime. Document does NOT own the Context.
- **No `@cImport`.** The library uses `b.addTranslateC` exclusively. Anywhere a developer is tempted to `@cImport({@cInclude(...)})` should be redirected to the translated module.
- **`std.testing.allocator`** in tests catches Zig leaks; C-side leaks need manual `leaks` runs (out of scope for unit tests, document as known gap).
- **Working directory** for `zig build test` is the project root, so fixture paths like `"tests/fixtures/sample-10pages.pdf"` work.

---

### Task 1: Project skeleton + translate-c + version smoke test

Prove the whole toolchain works end-to-end before introducing any abstraction: bridge.c compiles, bridge.h flows through `addTranslateC`, libmupdf links, a Zig function returns a non-empty version string.

**Files:**
- Create: `build.zig`
- Create: `build.zig.zon`
- Create: `src/root.zig`
- Create: `src/bridge/bridge.h`
- Create: `src/bridge/bridge.c`
- Create: `.gitignore`
- Initialize: git repo

- [ ] **Step 1: Initialize the repo**

```bash
cd ~/projects/mupdf-zig
git init -q -b main
printf 'zig-out/\nzig-cache/\n.zig-cache/\n' > .gitignore
```

- [ ] **Step 2: Create `build.zig.zon`**

```zig
.{
    .name = .mupdf_zig,
    .version = "0.0.0",
    .fingerprint = 0xabcd1234efef5678,
    .minimum_zig_version = "0.16.0",
    .dependencies = .{},
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
        "tests",
        "README.md",
    },
}
```

(The fingerprint value is arbitrary for a new project — Zig assigns a real one if you run `zig build --fetch` against a remote; for local-only paths any 64-bit hex literal is accepted.)

- [ ] **Step 3: Create `src/bridge/bridge.h`**

```c
#ifndef MUPDF_ZIG_BRIDGE_H
#define MUPDF_ZIG_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

/* Return codes for fallible bridge functions. Stable — Zig wrapper switches on these. */
#define MUPDF_BRIDGE_OK              0
#define MUPDF_BRIDGE_ERR_OPEN        1  /* file missing, not a PDF, or corrupt */
#define MUPDF_BRIDGE_ERR_ENCRYPTED   2  /* needs a password */
#define MUPDF_BRIDGE_ERR_BACKEND     3  /* generic mupdf throw / OOM */
#define MUPDF_BRIDGE_ERR_RANGE       4  /* slice range out of bounds */

/* MuPDF version string. Lifetime: static. Never NULL. */
const char *mupdf_zig_bridge_fz_version(void);

#ifdef __cplusplus
}
#endif

#endif
```

- [ ] **Step 4: Create `src/bridge/bridge.c`**

```c
#include "bridge.h"
#include <mupdf/fitz.h>

const char *mupdf_zig_bridge_fz_version(void)
{
    return FZ_VERSION;
}
```

- [ ] **Step 5: Create `src/root.zig`**

```zig
const std = @import("std");
const c = @import("c");

/// Return the MuPDF library version string (e.g. "1.27.2"). Static lifetime.
pub fn version() []const u8 {
    return std.mem.span(c.mupdf_zig_bridge_fz_version());
}

test "version returns a non-empty MuPDF version string" {
    const v = version();
    try std.testing.expect(v.len > 0);
    try std.testing.expect(std.mem.indexOfScalar(u8, v, '.') != null);
}
```

- [ ] **Step 6: Create `build.zig`**

```zig
const std = @import("std");

const mupdf_prefix = "/opt/homebrew/opt/mupdf";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 1. Translate bridge.h into a Zig module via translate-c (NOT @cImport).
    const translate = b.addTranslateC(.{
        .root_source_file = b.path("src/bridge/bridge.h"),
        .target = target,
        .optimize = optimize,
    });
    translate.addIncludePath(.{ .cwd_relative = mupdf_prefix ++ "/include" });
    translate.addIncludePath(b.path("src/bridge"));
    const c_mod = translate.createModule();

    // 2. The library's public module — wraps the bridge.
    const mupdf_mod = b.addModule("mupdf", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "c", .module = c_mod },
        },
    });
    linkMupdf(b, mupdf_mod);

    // 3. Test runner.
    const tests = b.addTest(.{ .root_module = mupdf_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_tests.step);
}

/// Attach the C bridge sources and MuPDF link state to a module. Called on the
/// library's own module by build(); consumers can call it on their own module
/// after importing `mupdf-zig`.
pub fn linkMupdf(b: *std.Build, m: *std.Build.Module) void {
    m.addCSourceFile(.{
        .file = b.path("src/bridge/bridge.c"),
        .flags = &.{ "-std=c11", "-Wall", "-Wextra" },
    });
    m.addIncludePath(.{ .cwd_relative = mupdf_prefix ++ "/include" });
    m.addIncludePath(b.path("src/bridge"));
    m.addLibraryPath(.{ .cwd_relative = mupdf_prefix ++ "/lib" });
    m.linkSystemLibrary("mupdf", .{});
    m.linkSystemLibrary("mupdf-third", .{});
    m.link_libc = true;
}
```

- [ ] **Step 7: Run the test**

Run: `zig build test --summary all`
Expected: 1/1 tests pass (`version returns a non-empty MuPDF version string`).

If the build fails at the translate-c step with "fitz.h not found": double-check `mupdf_prefix ++ "/include"` exists and contains `mupdf/fitz.h`. If the link fails with "library not found for -lmupdf": double-check `mupdf_prefix ++ "/lib"` contains `libmupdf.dylib`.

- [ ] **Step 8: Commit**

```bash
git add .
git -c user.email=user@local -c user.name=user commit -m "feat: project skeleton with translate-c bridge and version smoke test"
# Then set local config so future commits don't need -c flags:
git config user.email user@local
git config user.name user
```

---

### Task 2: Error set + Context type

Wraps `fz_new_context` / `fz_drop_context` / `fz_register_document_handlers` in a typed `Context` handle with explicit `init`/`deinit`.

**Files:**
- Create: `src/errors.zig`
- Create: `src/context.zig`
- Modify: `src/bridge/bridge.h`
- Modify: `src/bridge/bridge.c`
- Modify: `src/root.zig`

- [ ] **Step 1: Create `src/errors.zig`**

```zig
/// Error set returned by mupdf-zig public APIs.
/// - `OutOfMemory`: allocator failure (Zig or fz_new_context returning NULL).
/// - `InvalidPdf`: pdf_open_document threw (file missing, not a PDF, corrupt).
/// - `EncryptedPdf`: pdf_needs_password returned non-zero on the opened document.
/// - `InvalidPageRange`: slice range invalid (start/end out of bounds or end < start).
/// - `PdfBackendError`: any other fz_try/fz_catch throw from MuPDF.
pub const Error = error{
    OutOfMemory,
    InvalidPdf,
    EncryptedPdf,
    InvalidPageRange,
    PdfBackendError,
};
```

- [ ] **Step 2: Extend `src/bridge/bridge.h`** — add context functions before the closing `#endif`:

```c
/* Forward decl so we can return a pointer without including <mupdf/fitz.h> in this header. */
typedef struct fz_context fz_context;

/*
 * Create an fz_context with handlers registered. Returns NULL on OOM or context init failure.
 * Caller must drop with mupdf_zig_bridge_drop_context.
 */
fz_context *mupdf_zig_bridge_new_context(void);

/* Drop an fz_context previously returned from new_context. NULL-safe. */
void mupdf_zig_bridge_drop_context(fz_context *ctx);
```

- [ ] **Step 3: Extend `src/bridge/bridge.c`** — implement the two functions at the bottom:

```c
fz_context *mupdf_zig_bridge_new_context(void)
{
    fz_context *ctx = fz_new_context(NULL, NULL, FZ_STORE_UNLIMITED);
    if (!ctx) return NULL;

    fz_try(ctx) {
        fz_register_document_handlers(ctx);
    }
    fz_catch(ctx) {
        fz_drop_context(ctx);
        return NULL;
    }
    return ctx;
}

void mupdf_zig_bridge_drop_context(fz_context *ctx)
{
    if (ctx) fz_drop_context(ctx);
}
```

- [ ] **Step 4: Create `src/context.zig`**

```zig
const std = @import("std");
const c = @import("c");
const errors = @import("errors.zig");

pub const Context = struct {
    ptr: *c.fz_context,

    /// Create a new MuPDF context with document handlers registered.
    /// Returns error.OutOfMemory if MuPDF cannot allocate a context.
    pub fn init() errors.Error!Context {
        const raw = c.mupdf_zig_bridge_new_context();
        if (raw == null) return error.OutOfMemory;
        return .{ .ptr = raw.? };
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
```

- [ ] **Step 5: Re-export from `src/root.zig`** — append:

```zig
pub const Error = @import("errors.zig").Error;
pub const Context = @import("context.zig").Context;

test {
    _ = @import("errors.zig");
    _ = @import("context.zig");
}
```

- [ ] **Step 6: Run tests**

Run: `zig build test --summary all`
Expected: 3/3 tests pass (version + Context init/deinit + Context loop).

- [ ] **Step 7: Commit**

```bash
git add .
git commit -m "feat: add Error set and Context type with init/deinit"
```

---

### Task 3: Test fixtures

Three PDFs the rest of the tests will read.

**Files:**
- Create: `tests/fixtures/sample-10pages.pdf`
- Create: `tests/fixtures/not-a-pdf.txt`
- Create: `tests/fixtures/encrypted.pdf`
- Create: `tests/fixtures/README.md`

- [ ] **Step 1: Generate the 10-page sample**

```bash
mkdir -p tests/fixtures /tmp/mupdf-zig-pages
for i in 01 02 03 04 05 06 07 08 09 10; do
  echo "%%MediaBox 0 0 612 792" > /tmp/mupdf-zig-pages/page${i}.txt
done
/opt/homebrew/opt/mupdf/bin/mutool create -o tests/fixtures/sample-10pages.pdf /tmp/mupdf-zig-pages/page*.txt
/opt/homebrew/opt/mupdf/bin/mutool info tests/fixtures/sample-10pages.pdf | grep -i pages
```

Expected: `Pages: 10`.

- [ ] **Step 2: Create the non-PDF fixture**

```bash
printf 'this is not a pdf\n' > tests/fixtures/not-a-pdf.txt
```

- [ ] **Step 3: Generate the encrypted fixture**

```bash
/opt/homebrew/opt/mupdf/bin/mutool clean -E rc4-128 -P "lockme" \
    tests/fixtures/sample-10pages.pdf \
    tests/fixtures/encrypted.pdf
/opt/homebrew/opt/mupdf/bin/mutool info tests/fixtures/encrypted.pdf 2>&1 | head -3
```

Expected: `mutool info` either reports an `Encryption:` line OR fails with a password-required error — either confirms encryption is active.

If `mutool clean -E` syntax differs in your MuPDF version, run `mutool clean -h` and adapt the flags. If MuPDF in this version doesn't support adding encryption at all, install qpdf (`brew install qpdf`) and use:

```bash
qpdf --encrypt lockme owner 128 -- tests/fixtures/sample-10pages.pdf tests/fixtures/encrypted.pdf
```

If both fail, mark this step BLOCKED — don't fake the fixture.

- [ ] **Step 4: Write `tests/fixtures/README.md`**

````markdown
# Test Fixtures

Binary fixtures used by mupdf-zig tests. Regenerate from a clean shell:

## `sample-10pages.pdf` — 10 blank Letter-size pages

```bash
mkdir -p /tmp/mupdf-zig-pages
for i in 01 02 03 04 05 06 07 08 09 10; do
  echo "%%MediaBox 0 0 612 792" > /tmp/mupdf-zig-pages/page${i}.txt
done
mutool create -o tests/fixtures/sample-10pages.pdf /tmp/mupdf-zig-pages/page*.txt
mutool info tests/fixtures/sample-10pages.pdf  # expect "Pages: 10"
```

## `not-a-pdf.txt` — plain text used to exercise `InvalidPdf`

```bash
printf 'this is not a pdf\n' > tests/fixtures/not-a-pdf.txt
```

## `encrypted.pdf` — password-protected PDF used to exercise `EncryptedPdf`

```bash
mutool clean -E rc4-128 -P "lockme" \
    tests/fixtures/sample-10pages.pdf \
    tests/fixtures/encrypted.pdf
```

Owner/user password: `lockme`. The library doesn't take a password — opening this file should return `error.EncryptedPdf`.
````

(The outer code fence uses 4 backticks to nest inner 3-backtick fences inside.)

- [ ] **Step 5: Verify fixtures**

```bash
file tests/fixtures/sample-10pages.pdf tests/fixtures/encrypted.pdf tests/fixtures/not-a-pdf.txt
ls -la tests/fixtures/
```

All three files should exist; the PDFs should report as `PDF document`.

- [ ] **Step 6: Commit**

```bash
git add tests/fixtures/
git commit -m "test: add PDF fixtures (10-page sample, non-PDF, encrypted)"
```

---

### Task 4: Document.open with InvalidPdf and EncryptedPdf

**Files:**
- Create: `src/document.zig`
- Modify: `src/bridge/bridge.h`
- Modify: `src/bridge/bridge.c`
- Modify: `src/root.zig`

- [ ] **Step 1: Extend `src/bridge/bridge.h`** — add document functions:

```c
typedef struct pdf_document pdf_document;

/*
 * Open a PDF document. Returns one of MUPDF_BRIDGE_* codes. On OK, *out_doc holds
 * a non-null pdf_document pointer that the caller must drop with drop_document.
 * On non-OK, *out_doc is left NULL. Encrypted PDFs return MUPDF_BRIDGE_ERR_ENCRYPTED
 * and the partially-opened document is dropped internally.
 */
int mupdf_zig_bridge_open_document(fz_context *ctx, const char *path, pdf_document **out_doc);

/* Drop a pdf_document previously returned from open_document. NULL-safe. */
void mupdf_zig_bridge_drop_document(fz_context *ctx, pdf_document *doc);
```

- [ ] **Step 2: Extend `src/bridge/bridge.c`** — append:

```c
#include <mupdf/pdf.h>

int mupdf_zig_bridge_open_document(fz_context *ctx, const char *path, pdf_document **out_doc)
{
    pdf_document *doc = NULL;
    *out_doc = NULL;

    fz_try(ctx) {
        doc = pdf_open_document(ctx, path);
    }
    fz_catch(ctx) {
        return MUPDF_BRIDGE_ERR_OPEN;
    }

    int rc = MUPDF_BRIDGE_OK;
    fz_try(ctx) {
        if (pdf_needs_password(ctx, doc)) {
            rc = MUPDF_BRIDGE_ERR_ENCRYPTED;
        }
    }
    fz_catch(ctx) {
        rc = MUPDF_BRIDGE_ERR_BACKEND;
    }

    if (rc != MUPDF_BRIDGE_OK) {
        pdf_drop_document(ctx, doc);
        return rc;
    }

    *out_doc = doc;
    return MUPDF_BRIDGE_OK;
}

void mupdf_zig_bridge_drop_document(fz_context *ctx, pdf_document *doc)
{
    if (doc) pdf_drop_document(ctx, doc);
}
```

- [ ] **Step 3: Create `src/document.zig`** — skeleton with `open`, `deinit`, and tests for all three error paths:

```zig
const std = @import("std");
const c = @import("c");
const errors = @import("errors.zig");
const Context = @import("context.zig").Context;

pub const Document = struct {
    ctx: *Context,
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
            c.MUPDF_BRIDGE_OK => .{ .ctx = ctx, .ptr = raw.? },
            c.MUPDF_BRIDGE_ERR_OPEN => error.InvalidPdf,
            c.MUPDF_BRIDGE_ERR_ENCRYPTED => error.EncryptedPdf,
            else => error.PdfBackendError,
        };
    }

    /// Drop the underlying pdf_document.
    pub fn deinit(self: *Document) void {
        c.mupdf_zig_bridge_drop_document(self.ctx.ptr, self.ptr);
        self.* = undefined;
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
```

- [ ] **Step 4: Re-export from `src/root.zig`** — add Document and pull its tests into discovery:

```zig
pub const Document = @import("document.zig").Document;
```

And inside the existing `test {}` block:

```zig
test {
    _ = @import("errors.zig");
    _ = @import("context.zig");
    _ = @import("document.zig");
}
```

- [ ] **Step 5: Run tests**

Run: `zig build test --summary all`
Expected: 7/7 tests pass (3 prior + 4 new).

- [ ] **Step 6: Commit**

```bash
git add .
git commit -m "feat: add Document.open with InvalidPdf/EncryptedPdf error paths"
```

---

### Task 5: Document.pageCount

**Files:**
- Modify: `src/bridge/bridge.h`
- Modify: `src/bridge/bridge.c`
- Modify: `src/document.zig`

- [ ] **Step 1: Extend `src/bridge/bridge.h`**

```c
/*
 * Write the page count of `doc` to *out_count. Returns MUPDF_BRIDGE_OK on success,
 * MUPDF_BRIDGE_ERR_BACKEND if MuPDF throws.
 */
int mupdf_zig_bridge_count_pages(fz_context *ctx, pdf_document *doc, int *out_count);
```

- [ ] **Step 2: Extend `src/bridge/bridge.c`**

```c
int mupdf_zig_bridge_count_pages(fz_context *ctx, pdf_document *doc, int *out_count)
{
    int count = 0;
    fz_try(ctx) {
        count = pdf_count_pages(ctx, doc);
    }
    fz_catch(ctx) {
        return MUPDF_BRIDGE_ERR_BACKEND;
    }
    if (count < 0) return MUPDF_BRIDGE_ERR_BACKEND;
    *out_count = count;
    return MUPDF_BRIDGE_OK;
}
```

- [ ] **Step 3: Add `pageCount` method to `Document` in `src/document.zig`** — append above the test block:

```zig
pub fn pageCount(self: *const Document) errors.Error!u32 {
    var count: c.c_int = 0;
    const rc = c.mupdf_zig_bridge_count_pages(self.ctx.ptr, self.ptr, &count);
    return switch (rc) {
        c.MUPDF_BRIDGE_OK => @intCast(count),
        else => error.PdfBackendError,
    };
}
```

- [ ] **Step 4: Add test in `src/document.zig`**

```zig
test "Document.pageCount returns 10 on the sample fixture" {
    var ctx = try Context.init();
    defer ctx.deinit();
    var doc = try Document.open(&ctx, "tests/fixtures/sample-10pages.pdf");
    defer doc.deinit();
    try testing.expectEqual(@as(u32, 10), try doc.pageCount());
}
```

- [ ] **Step 5: Run tests**

Run: `zig build test --summary all`
Expected: 8/8 tests pass.

- [ ] **Step 6: Commit**

```bash
git add .
git commit -m "feat: add Document.pageCount"
```

---

### Task 6: Document.slice happy path + InvalidPageRange

**Files:**
- Modify: `src/bridge/bridge.h`
- Modify: `src/bridge/bridge.c`
- Modify: `src/document.zig`

- [ ] **Step 1: Extend `src/bridge/bridge.h`**

```c
/*
 * Write a copy of `doc` to `out_path` containing only pages [start_page, end_page]
 * (1-based, inclusive). Writes resulting file size to *out_bytes on success.
 *
 * Returns:
 *   MUPDF_BRIDGE_OK         — output written, *out_bytes valid
 *   MUPDF_BRIDGE_ERR_RANGE  — start < 1, end < start, or end > page_count
 *   MUPDF_BRIDGE_ERR_BACKEND — any MuPDF throw during slice/save, or stat() failure
 *
 * Note: doc is modified in place by pdf_rearrange_pages. After a successful slice,
 * the document is no longer usable for further operations — callers should drop it.
 */
int mupdf_zig_bridge_slice(fz_context *ctx, pdf_document *doc,
                           const char *out_path,
                           int start_page, int end_page,
                           unsigned long long *out_bytes);
```

- [ ] **Step 2: Extend `src/bridge/bridge.c`** — add `<sys/stat.h>` include at top and the function at the bottom:

```c
#include <sys/stat.h>
```

```c
int mupdf_zig_bridge_slice(fz_context *ctx, pdf_document *doc,
                           const char *out_path,
                           int start_page, int end_page,
                           unsigned long long *out_bytes)
{
    int total = 0;
    fz_try(ctx) {
        total = pdf_count_pages(ctx, doc);
    }
    fz_catch(ctx) {
        return MUPDF_BRIDGE_ERR_BACKEND;
    }

    if (start_page < 1 || end_page < start_page || end_page > total) {
        return MUPDF_BRIDGE_ERR_RANGE;
    }

    int n = end_page - start_page + 1;
    int *retain = NULL;
    int rc = MUPDF_BRIDGE_OK;

    fz_try(ctx) {
        retain = fz_malloc(ctx, (size_t)n * sizeof(int));
        for (int i = 0; i < n; i++) {
            retain[i] = (start_page - 1) + i;  /* mupdf is 0-indexed */
        }
        pdf_rearrange_pages(ctx, doc, n, retain, PDF_CLEAN_STRUCTURE_KEEP);
        pdf_save_document(ctx, doc, out_path, &pdf_default_write_options);
    }
    fz_catch(ctx) {
        rc = MUPDF_BRIDGE_ERR_BACKEND;
    }

    if (retain) fz_free(ctx, retain);

    if (rc == MUPDF_BRIDGE_OK) {
        struct stat st;
        if (stat(out_path, &st) == 0) {
            *out_bytes = (unsigned long long)st.st_size;
        } else {
            rc = MUPDF_BRIDGE_ERR_BACKEND;
        }
    }
    return rc;
}
```

- [ ] **Step 3: Add `slice` method to `Document`** — append in `src/document.zig`:

```zig
/// Write a copy of this document to `out_path` containing only pages
/// [start_page, end_page] (1-based, inclusive). Returns the size in bytes
/// of the resulting file.
///
/// IMPORTANT: After a successful slice, this Document is in a degraded state
/// (pdf_rearrange_pages mutates the in-memory representation). Callers SHOULD
/// drop it and re-open if further operations are needed.
pub fn slice(
    self: *Document,
    out_path: [:0]const u8,
    start_page: u32,
    end_page: u32,
) errors.Error!u64 {
    var bytes: c.c_ulonglong = 0;
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
        c.MUPDF_BRIDGE_ERR_ENCRYPTED => error.EncryptedPdf,
        else => error.PdfBackendError,
    };
}
```

- [ ] **Step 4: Add happy-path test in `src/document.zig`**

```zig
test "Document.slice 1..3 produces a 3-page PDF" {
    var ctx = try Context.init();
    defer ctx.deinit();

    const out = "tests/fixtures/.tmp-slice-1-3.pdf";
    defer std.fs.cwd().deleteFile(out) catch {};

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
```

- [ ] **Step 5: Add `.gitignore` for temp fixtures**

```bash
echo '.tmp-*.pdf' > tests/fixtures/.gitignore
```

- [ ] **Step 6: Run tests**

Run: `zig build test --summary all`
Expected: 9/9 tests pass.

- [ ] **Step 7: Commit**

```bash
git add .
git commit -m "feat: add Document.slice with InvalidPageRange and round-trip test"
```

---

### Task 7: slice edge cases + range error tests

**Files:**
- Modify: `src/document.zig`

- [ ] **Step 1: Add edge-case tests** — append to test block in `src/document.zig`:

```zig
test "Document.slice with start == end yields a 1-page PDF" {
    var ctx = try Context.init();
    defer ctx.deinit();

    const out = "tests/fixtures/.tmp-slice-5-5.pdf";
    defer std.fs.cwd().deleteFile(out) catch {};

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
    defer std.fs.cwd().deleteFile(out) catch {};

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
    defer std.fs.cwd().deleteFile(out) catch {};

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
```

- [ ] **Step 2: Run tests**

Run: `zig build test --summary all`
Expected: 15/15 tests pass (9 prior + 6 new).

- [ ] **Step 3: Commit**

```bash
git add .
git commit -m "test: cover Document.slice edge cases (boundaries + range errors)"
```

---

### Task 8: Round-trip smoke tests + EncryptedPdf for slice

Two more tests: prove the sliced output has the PDF magic bytes (a stronger check than "our own getMetadata can read it"), and prove slice on encrypted input returns EncryptedPdf (the same path Document.open exercises, but exposed via slice's call chain).

**Files:**
- Modify: `src/document.zig`

- [ ] **Step 1: Add header-magic test**

```zig
test "Document.slice output begins with the PDF header bytes" {
    var ctx = try Context.init();
    defer ctx.deinit();

    const out = "tests/fixtures/.tmp-slice-magic.pdf";
    defer std.fs.cwd().deleteFile(out) catch {};

    {
        var src = try Document.open(&ctx, "tests/fixtures/sample-10pages.pdf");
        defer src.deinit();
        _ = try src.slice(out, 1, 1);
    }

    var file = try std.fs.cwd().openFile(out, .{});
    defer file.close();
    var buf: [5]u8 = undefined;
    const n = try file.read(&buf);
    try testing.expectEqual(@as(usize, 5), n);
    try testing.expectEqualStrings("%PDF-", &buf);
}
```

- [ ] **Step 2: Add re-slice test**

```zig
test "Document.slice of a sliced document still produces a valid PDF" {
    var ctx = try Context.init();
    defer ctx.deinit();

    const tmp1 = "tests/fixtures/.tmp-rt-1.pdf";
    const tmp2 = "tests/fixtures/.tmp-rt-2.pdf";
    defer std.fs.cwd().deleteFile(tmp1) catch {};
    defer std.fs.cwd().deleteFile(tmp2) catch {};

    {
        var src = try Document.open(&ctx, "tests/fixtures/sample-10pages.pdf");
        defer src.deinit();
        _ = try src.slice(tmp1, 3, 7);  // 5 pages
    }
    {
        var mid = try Document.open(&ctx, tmp1);
        defer mid.deinit();
        _ = try mid.slice(tmp2, 2, 4);  // 3 of those
    }

    var final = try Document.open(&ctx, tmp2);
    defer final.deinit();
    try testing.expectEqual(@as(u32, 3), try final.pageCount());
}
```

- [ ] **Step 3: Run tests**

Run: `zig build test --summary all`
Expected: 17/17 tests pass.

- [ ] **Step 4: Commit**

```bash
git add .
git commit -m "test: round-trip — sliced output has PDF magic and re-slices cleanly"
```

---

### Task 9: README documenting consumption

Document how a downstream consumer (logos, eventually) imports the library.

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write `README.md`**

````markdown
# mupdf-zig

A small Zig 0.16 wrapper over MuPDF's C API. Wraps the slice of MuPDF needed for
the [chargesheet tool](https://github.com/ask-myfi/logos): opening PDFs, counting
pages, and slicing page ranges into a new file.

**Scope:** ~8 MuPDF C entry points. Grows on demand.

**Status:** WIP. Uses Homebrew MuPDF (`/opt/homebrew/opt/mupdf`) for development;
will be vendored before any release build.

## Public API

```zig
const mupdf = @import("mupdf");

var ctx = try mupdf.Context.init();
defer ctx.deinit();

var doc = try mupdf.Document.open(&ctx, "input.pdf");
defer doc.deinit();

const pages = try doc.pageCount();  // u32

// Slice pages 1-3 (inclusive, 1-based) into a new file:
const bytes = try doc.slice("output.pdf", 1, 3);  // returns u64 file size
```

`mupdf.Error` is the unified error set:

| Error | Cause |
|---|---|
| `OutOfMemory` | `fz_new_context` failed |
| `InvalidPdf` | File missing, not a PDF, or corrupt |
| `EncryptedPdf` | PDF is password-protected (this library does not take a password) |
| `InvalidPageRange` | Slice `start_page`/`end_page` out of bounds or `end < start` |
| `PdfBackendError` | Any other MuPDF `fz_throw` |

## Consuming from another Zig project

In your `build.zig.zon`:

```zig
.dependencies = .{
    .mupdf_zig = .{ .path = "../mupdf-zig" },  // or .url/.hash for git
},
```

In your `build.zig`:

```zig
const mupdf_zig_dep = b.dependency("mupdf_zig", .{
    .target = target,
    .optimize = optimize,
});

const exe_mod = b.createModule(.{
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
    .imports = &.{
        .{ .name = "mupdf", .module = mupdf_zig_dep.module("mupdf") },
    },
});
```

The `mupdf` module carries its own C bridge compilation and MuPDF link state, so
the consumer doesn't need to call any helper — importing the module is enough.

**MuPDF prefix:** Currently hard-coded to `/opt/homebrew/opt/mupdf` in
`build.zig`. To consume from a different prefix, edit `mupdf_prefix` at the top
of `build.zig`. Vendoring MuPDF source is on the roadmap.

## Building and testing

```bash
zig build           # build only
zig build test      # run the test suite (17 tests against checked-in PDF fixtures)
```

## Architecture notes

- **No `@cImport`.** `b.addTranslateC` is used to translate `src/bridge/bridge.h`
  into a Zig module at build time. This avoids `@cImport`'s per-file-translation
  overhead and produces clearer build errors when the header changes.

- **`fz_try`/`fz_catch` lives in C.** `src/bridge/bridge.c` wraps every fallible
  MuPDF call inside `fz_try`/`fz_catch` and returns integer error codes. This
  keeps MuPDF's `setjmp`/`longjmp` surface entirely in C — Zig never sees a
  `longjmp` that could skip a `defer` or `errdefer`.

- **Typed handles own C pointers.** `Context` and `Document` are Zig structs
  with explicit `init`/`deinit`. `Document` borrows a `*Context` — the caller
  is responsible for keeping the Context alive at least as long as the Document.

## License

TBD.
````

(Outer fence uses 4 backticks to nest inner 3-backtick fences. Use literal 3-backtick fences when writing the file.)

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: README with public API, consumer build wiring, and architecture notes"
```

---

## Acceptance Criteria

- `zig build test` passes with **17/17 tests green** from a clean clone.
- Library exports `Context`, `Document`, and `Error` via `@import("mupdf")`.
- `b.addTranslateC` is used; `@cImport` appears nowhere in the codebase (grep should return zero matches).
- `fz_try` / `fz_catch` appear only in `src/bridge/bridge.c`; never in any `.zig` file.
- Bridge function names are all `mupdf_zig_bridge_*`; consistent prefix.
- Encrypted PDFs return `error.EncryptedPdf` at `Document.open` time.
- Slicing edge cases (`start == end`, `start == 1`, `end == page_count`) all produce valid PDFs verified by re-opening the output.
- Range errors (`start < 1`, `end < start`, `end > page_count`) all return `error.InvalidPageRange` and do not write the output file.

---

## Self-Review

**1. Spec coverage:**
- 8 C entry points listed in the scope table → all wrapped: `fz_new_context`/`fz_drop_context`/`fz_register_document_handlers` in Task 2; `pdf_open_document`/`pdf_drop_document`/`pdf_needs_password` in Task 4; `pdf_count_pages` in Task 5; `pdf_rearrange_pages` + `pdf_save_document` in Task 6.
- `FZ_VERSION` smoke test in Task 1.
- Course architectural lessons applied: Module 2 (no `@cImport` — Task 1 uses `b.addTranslateC`), Module 4 (typed lifetimes — Task 2 Context, Task 4 Document), Module 6 (C-thunked `fz_try`/`fz_catch` — every bridge function in Tasks 2/4/5/6).

**2. Placeholder scan:** No "TBD"/"TODO"/"similar to". Every step shows actual code. The encrypted-fixture generation has a documented fallback to qpdf if `mutool clean -E` fails.

**3. Type consistency:**
- `Context.init() Error!Context` / `Context.deinit() void` — declared in Task 2, used in Tasks 4–8.
- `Document.open(ctx: *Context, path: [:0]const u8) Error!Document` — declared in Task 4, used in 5–8.
- `Document.deinit() void` — declared in Task 4.
- `Document.pageCount() Error!u32` — declared in Task 5, used in 6–8.
- `Document.slice(out_path, start, end) Error!u64` — declared in Task 6, used in 7–8.
- `Error` set members consistent across all tasks (Task 2 defines, Tasks 4/6 add bindings).
- Bridge constants (`MUPDF_BRIDGE_OK/ERR_OPEN/ERR_ENCRYPTED/ERR_BACKEND/ERR_RANGE`) — declared in Task 1, extended in no later task (one definition).

**4. Risk classification (Gate 4):** Bounded. Pure file-in/file-out, no concurrency, no shared state. MuPDF longjmp surface is contained in bridge.c.

**5. Epistemological humility (Gate 5):**
- C-side memory leaks (e.g. `fz_context` not dropped on rare error paths) are NOT caught by `std.testing.allocator`. A manual `leaks` run on the test binary is necessary to verify — out of scope here, document as future work.
- `pdf_rearrange_pages` mutates the document in place. Tests work around this by re-opening; the Document type's docstring warns callers. Not a correctness gap, but a usability one — could be improved by making slice consume the Document.
- MuPDF prefix is hardcoded to Homebrew's path. Linux builds, vendoring, and non-default Homebrew prefixes are out of scope here.
