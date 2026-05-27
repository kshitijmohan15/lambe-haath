# Research: How mature Zig projects handle packaging / distribution / cross-platform C deps

Date: 2026-05-27. Gathered to inform the lambe-haath single-CLI cross-platform product design.

## Source projects
- **Ghostty** (github.com/ghostty-org/ghostty) — large cross-platform Zig app, many vendored C deps, bundles build-time assets, dist tooling.
- General Zig 0.14–0.16 ecosystem (asset embedding libs, MuPDF/PDF package search).
- (TigerBeetle/ZLS research agent was cancelled; not included.)

---

## 1. Monorepo structure (Ghostty model)
- **One root `build.zig`**, thin, delegating to `src/build/main.zig` (`buildpkg`) with **one struct-per-artifact file**: `GhosttyExe.zig`, `GhosttyLib.zig`, `GhosttyResources.zig`, `GhosttyDist.zig`, `SharedDeps.zig` (deps shared across artifacts), `Config.zig` (all `-D` options).
- Code is NOT scattered with nested `build.zig` files. **Nested `build.zig` exists ONLY under `pkg/<lib>/`** — the vendored C-library wrappers, which are true separate Zig packages.
- Single monorepo, one root orchestrates many artifacts.

## 2. C dependency handling — the key MuPDF-relevant pattern
- Vendored-source-built-by-build.zig. One wrapper package per C lib in `./pkg/<name>/`.
- `build.zig.zon` references them as local path deps: `.freetype = .{ .path = "./pkg/freetype", .lazy = true }`.
- Each `pkg/<lib>/` is its own Zig package; its `.zon` pulls the upstream C tarball (Ghostty self-hosts a mirror `deps.files.ghostty.org` so deps never 404) as `.lazy = true`; its `build.zig` compiles it.
- Copyable recipe:
  ```zig
  const lib = b.addLibrary(.{ .name = "z", .linkage = .static, .root_module = b.createModule(.{ .target = target, .optimize = optimize }) });
  lib.linkLibC();
  if (b.lazyDependency("zlib", .{})) |upstream| {
      lib.addIncludePath(upstream.path(""));
      lib.addCSourceFiles(.{ .root = upstream.path(""), .files = srcs, .flags = flags.items });
      lib.installHeadersDirectory(upstream.path(""), "", .{ .include_extensions = &.{".h"} });
  }
  b.installArtifact(lib);
  ```
- **Per-lib system-vs-vendored toggle**: `b.systemIntegrationOption("freetype", .{})` → either `linkSystemLibrary2(...)` (`.preferred_link_mode = .dynamic`) or build from source. Distro packagers flip on; default vendored.
- Sub-deps link each other: `lib.linkLibrary(dep.artifact(...))` (e.g. freetype links zlib).
- Libs needing generated `config.h`: `b.addConfigHeader(.{ .style = .{ .cmake = upstream.path("src/config.h.cmake.in") } }, .{ ...values... })`, values computed per-target via `t.cTypeByteSize(.int)`, `is_windows`, etc.

## 3. Cross-platform C builds
- All C compiled by Zig's bundled clang (`zig cc`) → cross-compilation is the default mechanism.
- Per-platform handling is **inline branching on `target.result.os.tag`** (not separate files). Idioms: Windows/MSVC → `-D_CRT_SECURE_NO_DEPRECATE`, `query.abi = .msvc`; non-Windows → `-DHAVE_UNISTD_H`; musl/freebsd → `-fPIC`.
- macOS SDK: shared `pkg/apple-sdk` helper, `apple_sdk.addPaths(b, lib)`, uses `xcrun` on Darwin host, **falls back to Zig's bundled Darwin headers when cross-compiling**.
- Windows is supported but least-exercised for native deps. `*-windows-gnu` (MinGW) more forgiving than `-msvc` for POSIX-assuming C.

## 4. Embedding web/static assets into the binary
- **`@embedFile` embeds ONE file**, string-literal path, must be inside the module. **Cannot embed a directory directly.**
- Idiom: a build step enumerates files → generates a Zig module → code `@embedFile`s each + builds a comptime route map.
- **Ghostty pattern (`GhosttyFrameData.zig`):** build step generates a `.zig` that `@embedFile`s a build-time-produced blob:
  ```zig
  const wf = b.addWriteFiles();
  _ = wf.addCopyFile(dist.framedata.path(b), "framedata.compressed");
  const zig_file = wf.add("framedata.zig", "pub const compressed = @embedFile(\"framedata.compressed\");");
  step.root_module.addAnonymousImport("framedata", .{ .root_source_file = self.output });
  ```
  Blob produced by running a generator artifact at build time (`b.addRunArtifact(exe)` → `addOutputFileArg` yields a `LazyPath`).
- **Libraries that do dir-embedding for you:**
  - `robbielyman/EmbedFile.zig` — best fit, supports whole directories + extension filter: `ef.addDirectory(b.path("frontend/build"), .{}, "assets", null)`.
  - `ringtailsoftware/zig-embeddir` — copyable pattern, build.zig iterates dir, passes filename list via `b.addOptions`, main.zig `@embedFile`s each into a `std.StaticStringMap`.
- Route map: `std.StaticStringMap([]const u8)` (NOT the removed `ComptimeStringMap`). MIME: switch on `std.fs.path.extension(path)` → hardcode the ~6 types SvelteKit emits.

## 5. THE BIG FINDING — MuPDF cross-platform
- **No maintained MuPDF-for-Zig package exists.** No Zig package for MuPDF, pdfium, poppler, or qpdf. Only `Lulzx/zpdf` (pure-Zig text extraction, not a renderer).
- We currently link **Homebrew's MuPDF dylib → macOS-only.**
- For cross-platform we must **vendor MuPDF + its bundled deps** (freetype, jbig2dec, openjpeg, libjpeg, zlib, harfbuzz, gumbo, mujs) and translate its GNU-make build into build.zig. **Nobody has done this publicly.**
- Realistic options (in order):
  1. Manually translate MuPDF's makefile to build.zig — each `source/**.c` + each `thirdparty/**` lib as separate `addLibrary` targets, replicating `-D` flags. Only fully-cross-compilable route. Largest upfront effort.
  2. Reuse `hexops/mach-freetype` (ziggified, cross-compiling) for the freetype sub-dep.
  3. **Disable optional deps via MuPDF `-D` flags** to shrink surface: `FZ_ENABLE_JS=0` drops mujs; can drop openjpeg/jbig2dec if those codecs aren't needed.
- **KEY INSIGHT for our use case:** our slicing path (`pdf_open_document`, `pdf_count_pages`, `pdf_rearrange_pages`, `pdf_save_document`) is pure PDF object manipulation — **no rasterization, no font rendering, no image decoding, no JS**. So a MINIMAL MuPDF build with most thirdparty deps disabled is likely feasible. Must validate exactly which `source/**.c` files the pdf-write path pulls in.
- Reference for which files/defines map to which features: `microsoft/vcpkg` `libmupdf` port + `FabriceSalvaire/mupdf-cmake` (translate from these, not raw makefile).
- Cross-platform/Windows gotchas: deps that probe via autoconf/CMake at build time won't run under build.zig — must hardcode config (pre-generated `ftconfig.h` etc.); Windows needs `gdi32`/`user32` only if using MuPDF's platform layer (avoid — link only libmupdf core); `-windows-gnu` more forgiving than `-msvc`.

## 6. Single-binary + static linking
- True static (no dynamic libc): target **musl** on Linux (`.abi = .musl` → libc statically linked automatically). glibc can't fully static-link reliably. macOS/Windows: "static libc" differs; just avoid extra dynamic deps.
- `linkage = .static` for explicit static libs.

## 7. Versioning
- Source of truth: **`.version` in `build.zig.zon`**.
- **Zig 0.16:** read directly at comptime — `@import("build.zig.zon").version`. Single source of truth, no build option needed.
- Zig 0.14/0.15: needs `b.addOptions()` build option (parse `@embedFile("build.zig.zon")`).
- Ghostty resolves effective version: (1) `-Dversion-string=` flag, (2) `VERSION` file in source root (in dist tarballs), (3) git detection (`git describe --exact-match --tags`, branch, short-hash, dirty). Tagged release must match zon version (`@panic` otherwise); no git → `X.Y.Z-dev+0000000`. Resolved version passed into `b.addOptions()` `build_options` module for runtime access.

## 8. Distribution / installers
- Ghostty: `zig build dist` → signed source tarball via `git archive`, injects `VERSION` + pre-built dist resources. `zig build distcheck` extracts + tests. Canonical packager input.
- macOS: real Xcode project → `.app`/`.dmg`/Homebrew cask (NOT `zig build`).
- Linux: templated `.desktop`/AppStream/systemd files; distro packages + Flatpak + Snap.
- Windows: only resource files (`.ico`/`.manifest`/`.rc`), no full installer pipeline. Weakest story.
- **There is no bespoke cross-platform installer generator in `zig build` itself** — it's per-platform work. `zig build` emits a relocatable exe + installs companion resources to `share/`.

---

## Implications for lambe-haath (Windows = must-have for v1)
- The MuPDF-from-source vendoring (§5) is the dominant cost and the critical-path risk. The minimal-build insight (slicing doesn't rasterize) is the lever that could make it tractable.
- Asset bundling (§4) and versioning (§7) are easy/solved.
- Monorepo structure (§1) and per-lib vendoring wrappers (§2) give us a proven layout to copy.
- A single cross-platform installer is NOT free from `zig build` — per-platform packaging work remains even after the binary builds everywhere.

---

## Cross-compile validation results (2026-05-27)

Validation of Tasks 3+4 of the "MuPDF From-Source Build" plan: prove both
`mupdf-zig` and `logos` cross-compile to Windows and Linux from an
`aarch64-macos` host. Bar = **compile + link cleanly** (produce artifacts, no
unresolved symbols). Cross-compiled binaries **cannot be executed** on macOS,
so a test-run failing with "host system is unable to execute binaries from the
target" is a PASS (compile + link succeeded; only exec is impossible).

Toolchain: Zig 0.16.0. mupdf-zig at commit `5b81d5f`. MuPDF 1.27.2 built from
source via `make` driven by `zig cc`.

### Results matrix

| Project   | Target                 | Command                                            | Result |
|-----------|------------------------|----------------------------------------------------|--------|
| mupdf-zig | x86_64-windows-gnu     | `zig build test -Dtarget=x86_64-windows-gnu`       | PASS (compile+link+make OK; only exec phase failed: host can't run target) |
| mupdf-zig | x86_64-linux-musl      | `zig build test -Dtarget=x86_64-linux-musl`        | PASS (compile+link+make OK; only exec phase failed: host can't run target) |
| logos     | x86_64-windows-gnu     | `zig build -Dtarget=x86_64-windows-gnu`            | PASS (installs `logos.exe`, no run step) |
| logos     | x86_64-linux-musl      | `zig build -Dtarget=x86_64-linux-musl`             | PASS (installs `logos`, no run step) |

`mupdf-zig` is a library; its only runnable target is the `test` step, which
tries to execute the test binary. The compile + link of that test binary (and
the `make` step that builds the MuPDF `.a` files) succeed for both targets; the
build only fails at the exec phase — expected and a PASS for cross-compile.

`logos` exposes `b.installArtifact(exe)`, so the default `zig build` step
builds + installs the daemon exe **without running it** — the clean
cross-compile invocation.

### Object / artifact formats confirmed

build.zig drove the correct target for each (libs from
`~/.cache/zig`/`.zig-cache` `mupdf-libs/libmupdf.a`, extracted with `zig ar`):

| Target             | MuPDF `.a` object | logos artifact |
|--------------------|-------------------|----------------|
| x86_64-windows-gnu | Intel amd64 COFF  | `logos.exe` — PE32+ executable (console) x86-64 |
| x86_64-linux-musl  | ELF 64-bit x86-64 | `logos` — ELF 64-bit x86-64, statically linked (musl) |
| arm64-macos (native) | Mach-O arm64    | native exe; 75/75 tests pass |

### Per-target flags / fixes needed

1. **`-mcpu=x86_64_v2`** (already in `mupdf-zig/build.zig`): required for x86_64
   targets because MuPDF's deskew SIMD uses SSE4.1/SSSE3. build.zig appends it
   to `CC`/`CXX` for any `x86_64` resolved target. No change needed here.

2. **`logos` portable wall-clock fix** (NEW — `src/db/db.zig`): the original
   `nowIso8601()` called `std.c.clock_gettime`, whose extern declaration **fails
   to compile for Windows targets** (a `void`-param + winapi calling-convention
   combination in Zig 0.16 std). This was a `logos`-source issue, NOT a C-dep
   link problem — MuPDF and SQLite both compiled + linked fine for Windows.
   Fixed by branching at comptime in a new `nowUnixSeconds()` helper:
   - Windows: `std.os.windows.ntdll.RtlGetSystemTimePrecise()` (100-ns ticks
     since 1601-01-01) translated to the Unix epoch.
   - POSIX (macOS/Linux): `std.c.clock_gettime(CLOCK.REALTIME, ...)` (never
     referenced on Windows, so the broken extern is never instantiated).
   `nowIso8601(gpa)` signature unchanged — no ripple through the DB layer (which
   does not carry an `std.Io` handle). Native tests remain 75/75.

3. **SQLite / zqlite on Windows: NO extra system libs needed.** The anticipated
   snag (e.g. `linkSystemLibrary("bcrypt")`/`ws2_32`) did NOT materialize — the
   zqlite-vendored SQLite cross-compiled and linked cleanly for windows-gnu with
   no `build.zig` changes. (The Zig windows-gnu sysroot resolves the SQLite OS
   shims without an explicit system-lib add.)

### Confirmation for the installer / packaging phase

- Both `mupdf-zig` and `logos` cross-compile + link cleanly to
  `x86_64-windows-gnu` (COFF/PE32+) and `x86_64-linux-musl` (ELF, static).
- The **daemon exe links for Windows and Linux** — artifacts at
  `zig-out/bin/logos.exe` and `zig-out/bin/logos`.
- logos's full native-dependency stack (MuPDF C + SQLite C) cross-compiles in
  one `zig build -Dtarget=` invocation; no per-target system-lib wiring required
  so far.
- Caveat: validation bar was compile + link only — **cross-compiled binaries
  were not executed** (impossible on a macOS host). Runtime behavior on Windows
  / Linux is unverified and should be smoke-tested on real targets (or under an
  emulator/CI runner) before release.
