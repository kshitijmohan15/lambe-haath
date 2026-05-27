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
zig build test      # run the test suite (18 tests against checked-in PDF fixtures)
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

- **Thread safety.** A single `Context` is NOT safe to share across threads. Construct
  one per thread, or use `Context.clone()` to create per-thread views.

## License

TBD.
