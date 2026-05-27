# MuPDF From-Source Cross-Compilable Build — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `mupdf-zig` build MuPDF from source via `zig cc` (replacing the macOS-only Homebrew dylib link), so the library — and everything downstream (logos) — cross-compiles to macOS, Linux, and Windows.

**Architecture:** MuPDF 1.27.2 source is fetched as a hash-pinned `build.zig.zon` dependency (no git bloat). `build.zig` drives MuPDF's own Makefile via a `Run` step with `CC/CXX/AR/RANLIB` overridden to `zig cc`/`zig c++`/`zig ar`/`zig ranlib` and the target triple + `-mcpu=x86_64_v2` derived from the resolved Zig target — producing `libmupdf.a` + `libmupdf-third.a`, which the `mupdf` module links. The Zig API surface (`Context`/`Document`/`Error`) is unchanged.

**Tech Stack:** Zig 0.16, MuPDF 1.27.2 (GNU-make build driven by `zig cc`), the existing `mupdf-zig` Zig wrapper + bridge.

**Decision — make-driven, not pure-build.zig (for v1):** The spike (`docs/superpowers/specs/2026-05-27-minimal-mupdf-crosscompile-design.md` + verification) proved MuPDF's Makefile builds cleanly under `zig cc` for all three targets with one CPU flag. Driving make is dramatically less work than hand-translating ~200 source files + 17 thirdparty libs into `build.zig`. End users never compile (they get the installer's prebuilt binary), and we **cross-compile to Windows from a unix host** (proven), so `make` only ever runs where it exists. Pure-`build.zig` translation (hermetic, no make dependency, smaller footprint via minimal file set) is a documented **future** cleanup — see "Deferred" at the end.

**Spike-proven facts this plan rests on (verified 2026-05-27):**
- Source tarball: `https://mupdf.com/downloads/archive/mupdf-1.27.2-source.tar.gz` (67 MB, bundles all thirdparty).
- Native macOS (arm64): `make libs build=release CC="zig cc" CXX="zig c++" HAVE_GLUT=no HAVE_X11=no` → `build/release/libmupdf.a` + `libmupdf-third.a`. ✅ 672 objects, 0 errors.
- `x86_64-windows-gnu`: same command with `CC="zig cc -target x86_64-windows-gnu -mcpu=x86_64_v2"` (+CXX, +`AR="zig ar" RANLIB="zig ranlib"`, +`OUT=build/win`) → genuine COFF `.a` libs, 0 errors. The `-mcpu=x86_64_v2` is REQUIRED (MuPDF's `deskew_sse.h` uses SSE4.1/SSSE3 intrinsics).
- `x86_64-linux-musl`: same with `-target x86_64-linux-musl -mcpu=x86_64_v2` → ELF `.a` libs, 0 errors.

---

## File Structure

```
mupdf-zig/
├── build.zig             # MODIFIED: replace linkMupdfModule's Homebrew link with from-source build via make
├── build.zig.zon         # MODIFIED: add mupdf_src as a hash-pinned lazy URL dependency
├── src/
│   └── bridge/bridge.{c,h}  # UNCHANGED this phase (minimal-trim is deferred); still calls fz_register_document_handlers
└── (vendor/ NOT used — source comes from the package cache, not git)
```

The whole change is concentrated in `build.zig` + `build.zig.zon`. The `mupdf` module's public Zig API and the C bridge are untouched — the 19 existing tests are the functional oracle proving the swap didn't break anything.

Conventions:
- The Homebrew prefix (`/opt/homebrew/opt/mupdf`) and `linkSystemLibrary("mupdf"...)` are REMOVED from `build.zig`. After this phase, the build has zero dependency on a system MuPDF.
- `-mcpu=x86_64_v2` is applied only for x86-64 targets (arm64 native doesn't need it and doesn't have those intrinsics). Derive from `target.result.cpu.arch`.
- The make build output goes to a Zig-cache-managed path, never into the read-only package cache source dir.

---

### Task 1: Fetch MuPDF source as a pinned dependency

Add the source tarball to `build.zig.zon` so `zig` fetches + caches + hash-pins it (no 180 MB in git).

**Files:**
- Modify: `build.zig.zon`

- [ ] **Step 1: Add the dependency entry**

Run this to fetch + auto-write the hash:

```bash
cd /Users/user/projects/mupdf-zig
zig fetch --save=mupdf_src "https://mupdf.com/downloads/archive/mupdf-1.27.2-source.tar.gz"
```

This downloads the tarball, computes its hash, and adds an entry like the following to `build.zig.zon`'s `.dependencies`:

```zig
.mupdf_src = .{
    .url = "https://mupdf.com/downloads/archive/mupdf-1.27.2-source.tar.gz",
    .hash = "<zig-fills-this-in>",
    .lazy = true,
},
```

After it runs, manually add `.lazy = true,` to that entry if `zig fetch` didn't (we only need the source when actually building MuPDF). Confirm the `.paths` in `build.zig.zon` still lists `build.zig`, `build.zig.zon`, `src`, `tests`, `README.md`.

- [ ] **Step 2: Verify the fetch + tree shape**

```bash
zig build --help 2>&1 | head -1   # forces dependency resolution; should not error
# Find where zig cached it and confirm the Makefile is at the root:
find ~/.cache/zig/p -maxdepth 2 -name Makefile 2>/dev/null | grep -i mupdf | head -1
```

Expected: a path like `~/.cache/zig/p/<hash>/Makefile` exists (the tarball extracts with `Makefile`, `source/`, `thirdparty/`, `include/`, `generated/` at its root — verified in the spike).

- [ ] **Step 3: Commit**

```bash
git add build.zig.zon
git commit -m "build: add MuPDF 1.27.2 source as pinned dependency"
```

---

### Task 2: Build MuPDF from source via make, link it (native macOS first)

Replace the Homebrew link with a `Run` step that drives MuPDF's Makefile through `zig cc`, then link the produced `.a` libs. Prove it on the native target by getting the 19 tests green.

**Files:**
- Modify: `build.zig`

- [ ] **Step 1: Read the current `linkMupdfModule` and the build graph**

The current `build.zig` has `linkMupdfModule(b, m, mupdf_prefix)` doing `addCSourceFile(bridge.c)` + `addIncludePath(Homebrew/include)` + `addLibraryPath(Homebrew/lib)` + `linkSystemLibrary("mupdf")` + `linkSystemLibrary("mupdf-third")`. We keep the bridge.c compilation and the include path for MuPDF headers, but replace the Homebrew lib link with from-source `.a` libs.

- [ ] **Step 2: Write a `buildMupdfLibs` helper in `build.zig`**

Add this function. It returns the directory (`LazyPath`) containing the two `.a` files, built by make.

```zig
/// Build libmupdf.a + libmupdf-third.a from the pinned MuPDF source via `zig cc`.
/// Returns the LazyPath of the OUT directory containing both archives.
fn buildMupdfLibs(b: *std.Build, target: std.Build.ResolvedTarget) std.Build.LazyPath {
    const src = b.dependency("mupdf_src", .{});
    const src_root = src.path(""); // root of the extracted MuPDF source tree

    // Compose the zig cc/c++ target+cpu flags from the resolved target.
    const t = target.result;
    const triple = t.zigTriple(b.allocator) catch @panic("OOM");
    // x86-64 needs SSE4.1/SSSE3 (MuPDF deskew SIMD); arm64 does not.
    const mcpu_flag: []const u8 = if (t.cpu.arch == .x86_64) " -mcpu=x86_64_v2" else "";
    const cc = b.fmt("zig cc -target {s}{s}", .{ triple, mcpu_flag });
    const cxx = b.fmt("zig c++ -target {s}{s}", .{ triple, mcpu_flag });

    // Out dir under the build cache, unique per target so cross-builds don't collide.
    const out_dir = b.fmt("zig-mupdf-{s}", .{triple});

    const make = b.addSystemCommand(&.{"make"});
    make.setCwd(src_root);
    make.addArgs(&.{
        "libs",
        "build=release",
        b.fmt("OUT={s}", .{out_dir}),
        b.fmt("CC={s}", .{cc}),
        b.fmt("CXX={s}", .{cxx}),
        "AR=zig ar",
        "RANLIB=zig ranlib",
        "HAVE_GLUT=no",
        "HAVE_X11=no",
        "-j8",
    });
    // The OUT path is relative to src_root; return it as a LazyPath.
    return src_root.path(b, out_dir);
}
```

Notes for the implementer:
- `src.path("")` gives a `LazyPath` to the cached, read-only source root. **MuPDF's make writes its `OUT` dir INSIDE the source tree.** The package cache is read-only, so this will fail. **Resolve this:** copy the source into a writable location first using `b.addWriteFiles().addCopyDirectory(src_root, ".", .{})`, run make there, and return that copy's `OUT` path. Adjust `buildMupdfLibs` accordingly — the spike ran make in a writable `/tmp` checkout, so this copy step is the one piece the spike didn't exercise inside `zig build`. If `addCopyDirectory` of the full ~180 MB tree is too slow, fall back to a `addSystemCommand` `cp -R`/`rsync` into `b.makeTempPath()`.
- `make.setCwd` / `make.addArgs` / `b.addSystemCommand` signatures are Zig 0.16 — verify against `lib/std/Build.zig` and adapt (e.g. `Step.Run` field names).
- If wiring make into the build graph proves too fiddly in one sitting, the **fallback** is a `scripts/build-mupdf.sh <zig-triple>` that runs the exact spike command and writes the `.a`s to `mupdf-zig/.mupdf/<triple>/` (gitignored); `build.zig` then links those prebuilt libs and documents the script as a prebuild step. Report which path you took.

- [ ] **Step 3: Rewrite `linkMupdfModule` to link the from-source libs**

```zig
pub fn linkMupdfModule(b: *std.Build, m: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    const src = b.dependency("mupdf_src", .{});

    // The C bridge wrapping fz_try/fz_catch (unchanged).
    m.addCSourceFile(.{
        .file = b.path("src/bridge/bridge.c"),
        .flags = &.{ "-std=c11", "-Wall", "-Wextra" },
    });
    // MuPDF headers come from the source tree now, not Homebrew.
    m.addIncludePath(src.path("include"));
    m.addIncludePath(b.path("src/bridge"));

    // Link the from-source static libs.
    const libs_dir = buildMupdfLibs(b, target);
    m.addObjectFile(libs_dir.path(b, "libmupdf.a"));
    m.addObjectFile(libs_dir.path(b, "libmupdf-third.a"));
    m.link_libc = true;
}
```

Update the call site (the `pdf` module creation in `build`) to pass `target` instead of `mupdf_prefix`, and delete the `mupdf_prefix` constant.

Note: `m.addObjectFile(LazyPath)` is the idiom for linking a prebuilt `.a` into a module in 0.16; if it expects a different call (`m.linkLibrary` needs a `*Compile`, not a path), use `addObjectFile` for the `.a` archives — verify in `lib/std/Build/Module.zig`.

- [ ] **Step 4: Build + run the 19 tests on native macOS**

```bash
cd /Users/user/projects/mupdf-zig
zig build test --summary all 2>&1 | tail -20
```

Expected: the make step compiles MuPDF (first run is slow, ~1-2 min; cached after), then **19/19 tests pass** against the from-source libs. This proves the library now works with ZERO Homebrew dependency.

Verify no Homebrew leakage:
```bash
grep -rn "homebrew\|/opt/homebrew" build.zig && echo "LEAK — remove it" || echo "clean"
otool -L zig-out/... 2>/dev/null # (if an artifact exists) should NOT reference /opt/homebrew/opt/mupdf
```

- [ ] **Step 5: Commit**

```bash
git add build.zig build.zig.zon .gitignore
git commit -m "build: compile MuPDF from source via zig cc; drop Homebrew dependency"
```

---

### Task 3: Cross-compile validation (Windows + Linux)

Prove the library cross-compiles to the two non-native targets — the whole point of the phase.

**Files:**
- Modify: `build.zig` (only if cross-target handling needs adjustment)

- [ ] **Step 1: Cross-compile to Windows**

```bash
cd /Users/user/projects/mupdf-zig
zig build -Dtarget=x86_64-windows-gnu 2>&1 | tail -20
```

Expected: the make step builds MuPDF with the windows triple + `-mcpu=x86_64_v2` (auto-applied by `buildMupdfLibs`), and the build produces a Windows artifact with no unresolved symbols. (Running it requires Windows/Wine — deferred; clean compile+link is the bar, matching the spec.)

If it fails on the SSE flag, confirm `buildMupdfLibs` actually appended `-mcpu=x86_64_v2` for `x86_64` — that's the spike's required fix.

- [ ] **Step 2: Cross-compile to Linux**

```bash
zig build -Dtarget=x86_64-linux-musl 2>&1 | tail -20
```

Expected: clean compile+link, ELF artifact.

- [ ] **Step 3: Confirm artifacts are the right object format**

```bash
# Locate the per-target mupdf libs the build produced and confirm their format:
find ~/.cache/zig -path "*zig-mupdf-x86_64-windows*/libmupdf.a" 2>/dev/null | head -1 | xargs -I{} sh -c 'ar t {} >/dev/null 2>&1 && echo "windows .a OK"'
```

(Adapt the path to wherever Task 2's writable-copy step placed OUT.) The spike already confirmed COFF (windows) + ELF (linux) object output; this step is a sanity re-check inside the build system.

- [ ] **Step 4: Commit (if any build.zig changes were needed)**

```bash
git add build.zig
git commit -m "build: verify MuPDF cross-compiles to windows-gnu + linux-musl"
```

If no changes were needed (cross-compile worked off Task 2's code), skip the commit and note that in the report.

---

### Task 4: logos inherits cross-compilability

`logos` consumes `mupdf-zig` as a path dependency. Confirm logos now cross-compiles too — the end-to-end payoff.

**Files:**
- (likely none in logos; this is a validation task)

- [ ] **Step 1: Build logos for the native target**

```bash
cd /Users/user/projects/lambe-haath/logos
zig build test --summary all 2>&1 | tail -8
```

Expected: logos's 75 tests still pass (mupdf-zig now builds from source transitively; nothing in logos changed).

- [ ] **Step 2: Cross-compile logos to Windows + Linux**

```bash
zig build -Dtarget=x86_64-windows-gnu 2>&1 | tail -15
zig build -Dtarget=x86_64-linux-musl 2>&1 | tail -15
```

Expected: both produce linked artifacts. logos links zqlite (SQLite, C) + mupdf-zig (MuPDF, C) — this proves the daemon's full native-dependency stack cross-compiles. If zqlite/SQLite has its own cross-compile snag, document it (it's a separate C dep; SQLite is famously portable so this is low-risk, but it's the first time we've cross-compiled logos).

- [ ] **Step 3: Document the result**

Write a short note in `logos/docs/superpowers/research/` (append to the packaging research or a new file) recording: which targets logos cross-compiles to, the exact `zig build -Dtarget=` commands, and any per-target flags needed. This becomes the input to the future installer/packaging phase.

- [ ] **Step 4: Commit (if logos needed any change)**

```bash
cd /Users/user/projects/lambe-haath/logos
git add -A && git commit -m "build: confirm logos cross-compiles with from-source MuPDF"
```

If logos needed no changes, just commit the doc note.

---

## Acceptance Criteria

- `mupdf-zig` builds MuPDF from source via `zig cc` with **zero Homebrew/system-MuPDF dependency** (`grep` for `/opt/homebrew` in build.zig returns nothing).
- 19/19 mupdf-zig tests pass on native macOS against the from-source libs.
- `zig build -Dtarget=x86_64-windows-gnu` and `-Dtarget=x86_64-linux-musl` produce linked artifacts for BOTH mupdf-zig and logos with no unresolved symbols.
- The MuPDF source is a hash-pinned `build.zig.zon` dependency (reproducible, not vendored into git).
- logos's 75 tests still pass.

## Self-Review

**1. Spec coverage:** The design spec's goal (minimal MuPDF, cross-compiled from source, replacing Homebrew) is covered: Task 1 (source), Task 2 (from-source build + native proof), Task 3 (cross-compile proof), Task 4 (logos payoff). The spec's "minimal trim" (FZ_ENABLE_*=0, drop image codecs) is intentionally DEFERRED — see below — because the spike proved the FULL build cross-compiles, so trimming is an optimization, not a feasibility requirement. The spec's bridge.c handler-registration change is also deferred for the same reason (full build works as-is).

**2. Placeholder scan:** No "TBD"/"implement later". The one genuinely unproven mechanic — running make inside `zig build` against a writable source copy — is called out explicitly in Task 2 Step 2 with a concrete approach (`addWriteFiles().addCopyDirectory`) AND a fallback (`scripts/build-mupdf.sh`). That's a flagged integration risk with two routes, not a placeholder.

**3. Type/command consistency:** `buildMupdfLibs(b, target)` and `linkMupdfModule(b, m, target)` signatures are consistent between Task 2 steps. The make command matches the spike-verified invocation exactly (`build=release`, `HAVE_GLUT=no`, `HAVE_X11=no`, `AR/RANLIB=zig`, `-mcpu=x86_64_v2` for x86). Target triples (`x86_64-windows-gnu`, `x86_64-linux-musl`) are consistent across Tasks 3-4.

## Deferred (explicit future work, NOT this phase)

- **Minimal-trim build** — `FZ_ENABLE_{XPS,SVG,CBZ,IMG,HTML,FB2,MOBI,EPUB,OFFICE,TXT,JS}=0`, drop openjpeg/jbig2dec/libjpeg/harfbuzz, register only the PDF handler. Shrinks binary + build time. The spike confirmed the disable mechanism exists; do this once the full build is integrated and we want to slim the artifact.
- **Pure-`build.zig` translation** — replace the make invocation with native `addCSourceFiles` over the minimal file list (Ghostty `pkg/<lib>` style). Removes the `make` build-time dependency entirely (hermetic builds, cleaner for downstream). Worth it before shipping if the make-from-build.zig integration proves fragile across environments.
- **`-msvc` Windows ABI** — only if `-windows-gnu` causes downstream linking issues with the installer.
- **aarch64 variants** (linux/windows) and **x86_64-macos** — add once the primary three are solid.
- **Tarball mirror** — Ghostty self-hosts its dep tarballs so they never 404. If `mupdf.com` archive availability is a concern, mirror the source tarball and point the `build.zig.zon` URL at the mirror.
