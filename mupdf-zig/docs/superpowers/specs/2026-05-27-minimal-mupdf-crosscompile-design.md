# Design: Minimal MuPDF, cross-compiled from vendored source

**Date:** 2026-05-27
**Status:** Approved (brainstorming) — ready for implementation plan
**Scope:** Feasibility spike. First sub-project of the lambe-haath single-CLI cross-platform product (see `logos/docs/superpowers/research/2026-05-27-zig-packaging-research.md`).

---

## Why

`lambe-haath` is to ship as one cross-platform installable CLI (macOS/Linux/**Windows**) — daemon + bundled web UI in one binary. The `mupdf-zig` library currently links **Homebrew's MuPDF dylib**, which is **macOS-only**. Cross-platform is therefore blocked on one unsolved problem: building MuPDF from source and cross-compiling it via `zig cc`. No maintained MuPDF-for-Zig package exists, and no public translation of MuPDF's build into `build.zig` exists.

Because Windows is a v1 requirement, this is the **critical path for the entire product** — nothing else (monorepo restructure, UI bundling, installer) can ship until MuPDF builds on Windows. This spike de-risks that single unknown cheaply, before any other product work is built around it.

## The bet (scope-reduction levers)

The slice path we actually use — `pdf_open_document`, `pdf_count_pages`, `pdf_needs_password`, `pdf_rearrange_pages`, `pdf_save_document` (with `do_garbage`/`do_clean`), plus `fz_new_context` / `fz_clone_context` / `fz_drop_context` — is **pure PDF object manipulation**. It does NOT rasterize pages, render fonts, decode images, or execute JavaScript.

Therefore we attempt a **minimal** MuPDF build:
- **Compile-time `FZ_ENABLE_*=0` agent toggles** — MuPDF's `mupdf/fitz/config.h` documents this exactly: *"To avoid building unwanted ones, define FZ_ENABLE_... to 0."* (Verified empirically 2026-05-27 against the Homebrew 1.27 headers.) We keep `FZ_ENABLE_PDF=1` and set `FZ_ENABLE_{XPS,SVG,CBZ,IMG,HTML,FB2,MOBI,EPUB,OFFICE,TXT}=0` plus `FZ_ENABLE_JS=0`. This removes those agents' source files (and their transitive deps — the HTML/EPUB engine, etc.) from the build, not just the runtime registry. This is the primary surface-reduction lever and it is a supported MuPDF configuration.
- No openjpeg (JPEG2000 decode), no jbig2dec (JBIG2 decode), no libjpeg — we don't decode image streams; `pdf_rearrange_pages` copies them as opaque objects.
- **Handler registration:** our bridge opens via `pdf_open_document` (PDF-specific), which bypasses the `fz_register_document_handler(s)` registry entirely (verified: the registry is only consulted by the generic `fz_open_document`). So `bridge.c`'s current `fz_register_document_handlers(ctx)` call in `mupdf_zig_bridge_new_context` is likely unnecessary for the slice path; the spike confirms whether it can be dropped or must register just the PDF handler via `fz_register_document_handler(ctx, &pdf_document_handler)`. (Correction from an earlier draft that referenced a non-existent `pdf_register_document_handler`.)
- **freetype is the open question.** MuPDF's core links freetype symbols even when not rasterizing (font object parsing). The spike determines empirically whether we can stub those symbols, or must vendor freetype (via `hexops/mach-freetype` or from source). This is the most likely source of difficulty.

If the minimal set won't link, we expand the vendored surface incrementally until it does, recording what each addition was needed for.

## Where the work happens

All in `~/projects/mupdf-zig/`. The library owns the MuPDF integration. `logos` consumes `mupdf-zig` as a path dependency and inherits cross-compilability for free once the library cross-compiles. No `logos` changes in this spike.

## Architecture

```
mupdf-zig/
├── build.zig              # MODIFIED: build vendored libmupdf static lib instead of linkSystemLibrary
├── vendor/
│   └── mupdf/             # NEW: vendored MuPDF 1.27.x source (matching our Homebrew dev version)
│       ├── source/        #   the .c files we compile
│       ├── include/       #   mupdf headers
│       └── (config)       #   pre-generated config headers (normally made by `make`)
└── src/
    ├── bridge/bridge.c    # MODIFIED: pdf_register_document_handler instead of fz_register_document_handlers
    └── ... (Context/Document/errors unchanged — the Zig API is stable)
```

- **`build.zig` change:** replace the `linkMupdf` helper's `addLibraryPath` + `linkSystemLibrary("mupdf", .{})` + `linkSystemLibrary("mupdf-third", .{})` with: a `b.addLibrary(.{ .linkage = .static })` that compiles the minimal `vendor/mupdf/source/**.c` set with the right `-D` flags + include paths, then `module.linkLibrary(that_lib)`. Sub-deps (freetype, zlib if needed) are additional static-lib artifacts linked in, following Ghostty's `pkg/<lib>/` vendoring pattern.
- **Config headers:** MuPDF's make generates some headers (e.g. thirdparty `ftconfig.h`). We pre-generate them once and commit them under `vendor/`, or hardcode via `b.addConfigHeader`. The plan will pin exactly which.
- **The Zig API surface (`Context`, `Document`, `Error`, slice/pageCount) does NOT change.** Only the linkage underneath. The existing 19 tests are the functional oracle.

## Validation targets

| Target | Bar | Why |
|---|---|---|
| native macOS (aarch64-macos) | **All 19 mupdf-zig tests pass** against the vendored lib | Functional proof the minimal build actually slices |
| `x86_64-linux-musl` | **compiles + links clean** (artifact produced, no unresolved symbols) | Proves the source set + flags are portable; musl = static binary path |
| `x86_64-windows-gnu` | **compiles + links clean** | The make-or-break platform; `-windows-gnu` (MinGW) is more forgiving than `-msvc` for POSIX-assuming C |

**Deferred (explicit non-goals for the spike):** runtime test execution on Linux/Windows (needs CI runners or VMs); `aarch64-linux` / `aarch64-windows` / `x86_64-macos` variants (add once the first three prove the approach); `-msvc` ABI (try only if `-windows-gnu` fails downstream).

## Deliverables

1. `vendor/mupdf/` — pinned MuPDF source + committed pre-generated config headers.
2. `build.zig` building a minimal static `libmupdf` from source, cross-compilable.
3. `bridge.c` registering only the PDF handler.
4. **A manifest doc** (`docs/.../mupdf-minimal-manifest.md`): the exact `source/**.c` list, `-D` flags, sub-deps, and config headers required — so the result is reproducible and reviewable.
5. Green: 19/19 tests on macOS-vendored; clean compile+link for linux-musl and windows-gnu.

## Risks & unknowns (Gate 5 honesty)

- **freetype link dependency** — highest-probability blocker. Mitigation: vendor freetype if stubbing fails; `mach-freetype` is a proven cross-compiling precedent.
- **Hidden mandatory thirdparty deps** — MuPDF core may hard-require zlib (FlateDecode — likely needed, PDFs use it heavily) and possibly others even on the write path. Expect to vendor zlib. We'll discover the true minimal set empirically.
- **Config-header generation** — MuPDF's make computes platform config; replicating statically is fiddly and a known cross-compile gotcha.
- **Windows POSIX assumptions** in MuPDF/thirdparty source — `-windows-gnu` mitigates; `-msvc` is the harder fallback.
- **If the spike fails** — escalate with real data to (a) full MuPDF vendoring (accept the larger surface) or (b) qpdf evaluation (C++, structure-focused, possibly smaller footprint for pure slicing).

## Success criteria

The spike succeeds if: (1) 19/19 tests pass on a macOS build that links the vendored minimal MuPDF (zero Homebrew dependency), AND (2) `zig build -Dtarget=x86_64-linux-musl` and `zig build -Dtarget=x86_64-windows-gnu` both produce linked artifacts with no unresolved symbols. At that point cross-platform is proven and the umbrella product work (monorepo, UI bundling, installer) is unblocked.
