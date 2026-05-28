const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // MuPDF source dependency (lazy). Unpacked into a read-only package cache;
    // its include dir is used for headers, and the .a files are built from it.
    // When the dep is not yet fetched, lazyDependency returns null and the
    // build system re-runs after fetching it — so we bail out gracefully.
    const mupdf_src = b.lazyDependency("mupdf_src", .{}) orelse return;

    // 1. Translate bridge.h into a Zig module via translate-c (NOT @cImport).
    const translate = b.addTranslateC(.{
        .root_source_file = b.path("src/bridge/bridge.h"),
        .target = target,
        .optimize = optimize,
    });
    translate.addIncludePath(mupdf_src.path("include"));
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
    linkMupdf(b, mupdf_mod, mupdf_src, target);

    // 3. Test runner. The test artifact links the MuPDF static libs via the
    //    module's object-file LazyPaths, which now carry the make-step
    //    dependency themselves — no manual dependOn needed.
    const tests = b.addTest(.{ .root_module = mupdf_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_tests.step);
}

/// Attach the C bridge sources and MuPDF link state to a module. Builds the
/// MuPDF static libraries from source (via `zig cc`) and links them. Called on
/// the library's own module by build(); consumers can call it on their own
/// module after importing `mupdf-zig`.
///
/// The MuPDF libs are emitted into a zig-managed output directory (passed to
/// make as `OUT=<dir>`); the resulting `.a` LazyPaths carry a dependency on the
/// make Run step. Any Compile/Test artifact that links this module therefore
/// transitively depends on make running first — including external consumers —
/// so no manual `dependOn` wiring is required.
pub fn linkMupdf(b: *std.Build, m: *std.Build.Module, mupdf_src: *std.Build.Dependency, target: std.Build.ResolvedTarget) void {
    // The MuPDF Makefile writes its OUT dir *inside* the source tree, but the
    // package cache is read-only. So copy the source to a writable WriteFile
    // output dir, then run `make` inside that copy.
    const wf = b.addWriteFiles();
    const writable_src = wf.addCopyDirectory(mupdf_src.path(""), ".", .{});

    // Compose CC/CXX. zig cc accepts the native triple too, so we always pass
    // -target for uniformity; -mcpu is only needed for x86_64 cross targets
    // (the v2 baseline keeps generated code portable). Native arm64-macos
    // needs neither, but passing -target is harmless.
    const triple = target.result.zigTriple(b.allocator) catch @panic("OOM");
    const cc = if (target.result.cpu.arch == .x86_64)
        b.fmt("zig cc -target {s} -mcpu=x86_64_v2", .{triple})
    else
        b.fmt("zig cc -target {s}", .{triple});
    const cxx = if (target.result.cpu.arch == .x86_64)
        b.fmt("zig c++ -target {s} -mcpu=x86_64_v2", .{triple})
    else
        b.fmt("zig c++ -target {s}", .{triple});

    const make = b.addSystemCommand(&.{
        "make",
        "libs",
        "build=release",
        b.fmt("CC={s}", .{cc}),
        b.fmt("CXX={s}", .{cxx}),
        "AR=zig ar",
        "RANLIB=zig ranlib",
        "HAVE_GLUT=no",
        "HAVE_X11=no",
        // Embed fonts via the hexdump->C path (compiled by our target CC) rather
        // than `ld -r -b binary`, which MuPDF auto-selects when objcopy is present
        // (e.g. on Linux). That binary-embed produces HOST-format objects: cross-
        // compiling to Windows from a Linux host yields ELF font objects that
        // lld-link rejects ("unknown file type: Noto*.otf.o"). Forcing this off
        // makes font objects target-correct on every host (matches the macOS-host
        // behavior that the cross-compile validation relied on).
        "HAVE_OBJCOPY=no",
        "-j8",
    });
    // Direct MuPDF to write its objects + static libs into a zig-managed output
    // directory via `OUT=<dir>`. The returned LazyPath carries a dependency on
    // this make Run step, so anything linking the .a files below waits for make.
    // With a custom OUT, MuPDF places the libs directly in <OUT>/ (NOT a
    // release/ subdir — verified by the cross-compile spike with OUT=build/win).
    const out_dir = make.addPrefixedOutputDirectoryArg("OUT=", "mupdf-libs");
    make.setCwd(writable_src);
    make.step.dependOn(&wf.step);

    // Link core before third-party (dependent-before-dependency) for
    // static-archive resolution; lld is order-tolerant but this is conventional.
    // These LazyPaths depend on the make step, so any module/exe that links them
    // (mupdf-zig's own tests AND external consumers) transitively waits for make.
    m.addObjectFile(out_dir.path(b, "libmupdf.a"));
    m.addObjectFile(out_dir.path(b, "libmupdf-third.a"));

    m.addCSourceFile(.{
        .file = b.path("src/bridge/bridge.c"),
        .flags = &.{ "-std=c11", "-Wall", "-Wextra" },
    });
    m.addIncludePath(mupdf_src.path("include"));
    m.addIncludePath(b.path("src/bridge"));
    m.link_libc = true;
}
