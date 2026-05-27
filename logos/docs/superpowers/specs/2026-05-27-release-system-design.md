# Design: Release system (CI build → GitHub Releases → install scripts)

**Date:** 2026-05-27
**Status:** Approved (brainstorming) — ready for implementation plan
**Context:** Roadmap item #3 toward the single-CLI product. The daemon now serves
the UI from disk (`<exe_dir>/ui`, merged in PR #1). This system builds the daemon
+ UI for every target, runtime-tests them on native runners, and publishes
installable bundles so an end user installs nothing but the CLI.

Repo `github.com/kshitijmohan15/lambe-haath` is **public** as of 2026-05-27, so
Release assets and `raw.githubusercontent.com` install scripts are reachable
without auth.

---

## Goal

On a version tag, produce and publish per-platform bundles (daemon binary +
built UI) to a GitHub Release, each verified by running it on its native OS, plus
`curl | sh` / PowerShell install scripts. A user runs one install command, then
runs `logos` to start the daemon + UI on `http://localhost:7777`.

## Decisions (locked in brainstorming)

- **Targets (v1):** `macos-arm64`, `macos-x64`, `linux-x64`, `windows-x64`.
- **No code signing / notarization.** Ship unsigned; the bundle README documents
  the one-time Gatekeeper/SmartScreen bypass.
- **Install:** scripts (`curl|sh` + PowerShell) **and** raw archives on the Release.
- **Smoke tests:** every bundle MUST be executed on a matching **native** runner
  before release (first real runtime verification — prior research validated only
  compile+link).
- **Build orchestration:** Approach C (hybrid) — build only via validated paths:
  macOS arches built natively on macOS runners; Linux native + Windows
  cross-compiled on a Linux runner. No macOS-from-Linux, no `make`-on-Windows.
- **Command name:** `logos` (existing binary name; no rename).
- **Install location:** user-local, no sudo.
- **Build mode:** `ReleaseSafe` (retains bounds/UB checks for untrusted PDF input).
- **Version source of truth:** `logos/build.zig.zon` `.version`.

## Architecture

A single workflow `.github/workflows/release.yml` with a job DAG:

```
guard ──┐
ui ─────┤
        ├─> build (matrix) ─> package (matrix) ─> smoke (matrix, native) ─> release
        ┘
```

- **`guard`** — resolve the version. On a `vX.Y.Z` tag, assert the tag equals
  `build.zig.zon` `.version`; mismatch MUST fail the workflow (no release). On
  `workflow_dispatch`, derive a synthetic version (e.g. `0.0.0-dryrun+<sha>`) and
  skip the `release` job.
- **`ui`** (`ubuntu-latest`) — `cd chargesheet-ui && yarn install --frozen-lockfile
  && yarn build`; upload `chargesheet-ui/build/` as artifact `ui`.
- **`build`** (matrix) — install Zig 0.16.0, `zig build -Dtarget=<t>
  -Doptimize=ReleaseSafe` in `logos/`; upload the binary as `bin-<platform>`.
  Matrix:
  | runner | -Dtarget | platform | build kind |
  |---|---|---|---|
  | macos-14 | aarch64-macos | macos-arm64 | native |
  | macos-13 | x86_64-macos | macos-x64 | native |
  | ubuntu-latest | x86_64-linux-musl | linux-x64 | native |
  | ubuntu-latest | x86_64-windows-gnu | windows-x64 | cross (validated) |
  Cache `~/.cache/zig` and the MuPDF `make` output, keyed on the `mupdf-zig`
  source tree hash + target (the MuPDF-from-source build is slow). A cache miss
  MUST only cost time, never correctness (full rebuild).
- **`package`** (matrix, one per platform) — download `ui` + `bin-<platform>`,
  assemble `logos-vX.Y.Z-<platform>/` (binary + `ui/` + README + LICENSE), create
  the archive (`.tar.gz` for unix, `.zip` for windows), compute SHA256; upload the
  archive + `.sha256`.
- **`smoke`** (matrix, on the target's native runner — incl. `windows-latest`) —
  download + extract the archive, run `scripts/smoke.{sh,ps1}` against the
  unpacked bundle (see Testing). Linux/macOS jobs additionally run `install.sh`
  end-to-end and assert `logos -V`; the Windows job runs `install.ps1`.
- **`release`** (`ubuntu-latest`, only on `vX.Y.Z` tag, `needs:` all `smoke`) —
  create/update the GitHub Release for the tag, upload all archives + a single
  `SHA256SUMS`. Skipped on `workflow_dispatch`.

## Bundle layout & artifact names

```
logos-vX.Y.Z-<platform>/
  logos            (logos.exe on windows)
  ui/              SvelteKit build output; daemon's default ui_dir = <exe_dir>/ui
  README.md        quickstart + Gatekeeper/SmartScreen bypass note
  LICENSE
```

Release assets:
- `logos-vX.Y.Z-macos-arm64.tar.gz`
- `logos-vX.Y.Z-macos-x64.tar.gz`
- `logos-vX.Y.Z-linux-x64.tar.gz`
- `logos-vX.Y.Z-windows-x64.zip`
- `SHA256SUMS`

Because `ui/` sits beside the binary, the daemon resolves it with **no env var**;
the user just runs `logos`.

## Install scripts (user-local, no sudo)

Both live at repo root, support an optional explicit version (arg/env; default =
latest release), are idempotent, and verify SHA256 before installing.

- **`install.sh`** (POSIX sh; macOS + Linux):
  1. Detect OS via `uname -s` (Darwin/Linux) and arch via `uname -m`
     (`arm64`/`aarch64` → arm64; `x86_64` → x64). macOS+arm64, macOS+x64,
     Linux+x64 map to assets; any other combination MUST exit with a clear
     "unsupported platform" error.
  2. Resolve the release (latest or pinned), download the matching `.tar.gz` and
     its checksum from the public Release.
  3. Verify SHA256; mismatch MUST abort without installing.
  4. Extract to `~/.local/lib/lambe-haath/` (replacing any prior install),
     symlink `~/.local/bin/logos` → `~/.local/lib/lambe-haath/logos`.
  5. If `~/.local/bin` is not on `PATH`, print the exact line to add it.
  - Usage: `curl -fsSL https://raw.githubusercontent.com/kshitijmohan15/lambe-haath/main/install.sh | sh`
- **`install.ps1`** (Windows PowerShell):
  1. Detect arch; only x64 supported in v1 (else clear error).
  2. Download `logos-vX.Y.Z-windows-x64.zip` + checksum; verify SHA256.
  3. Extract to `%LOCALAPPDATA%\lambe-haath`; add that dir to the **user** PATH
     (persist via the registry/`setx`) so `logos` resolves in a new shell.
  - Usage: `irm https://raw.githubusercontent.com/kshitijmohan15/lambe-haath/main/install.ps1 | iex`

## Error handling / failure modes

- Tag ≠ `build.zig.zon` version → `guard` fails → no build, no release.
- Any `build`, `package`, or `smoke` failure → `release` does not run (it `needs:`
  all green) → no partial/broken release published.
- `workflow_dispatch` (no tag) → full build + package + smoke, `release` skipped —
  a safe dry run of the whole pipeline on a branch.
- Install scripts: unsupported platform → explicit error + exit; checksum mismatch
  → abort before writing; network failure → non-zero exit with message.
- `SHA256SUMS` on the Release lets users verify manually; scripts verify
  automatically.

## Testing

The smoke jobs ARE the system's tests; there is no unit test for CI YAML. Logic is
shared via `scripts/smoke.sh` (POSIX) and `scripts/smoke.ps1` (Windows), invoked
by the matching native runner. Against the unpacked bundle on a free port, each
MUST hold (job fails otherwise):

1. `GET /api/v1/health` → HTTP 200 with body containing `"status":"ok"`.
2. `GET /` → HTTP 200, body contains `<!doctype html` (UI served from `./ui`).
3. `GET /<a referenced /_app/*.mjs or .js>` → HTTP 200 with
   `Content-Type: text/javascript`.
4. `POST /api/v1/projects` (multipart: `name` + bundled `sample-10pages.pdf` as
   `chargesheet`) → HTTP 201, JSON `page_count` == 10.
5. `POST /api/v1/projects/<id>/jobs/slice` (a single-page slice) → the produced
   slice file exists and is smaller than the source.
6. The daemon process terminates on signal and frees the port.

Fixture: `mupdf-zig/tests/fixtures/sample-10pages.pdf` (already in the repo) is
copied into the bundle (or referenced) for the smoke test.

The dry-run (`workflow_dispatch`) MUST be run on the branch and pass all four
platforms' smoke jobs before the first real tag is pushed.

## File structure (created by the implementation)

```
.github/workflows/release.yml      the workflow (guard, ui, build, package, smoke, release)
install.sh                          POSIX installer (curl | sh)
install.ps1                         Windows installer (irm | iex)
scripts/smoke.sh                    shared POSIX smoke assertions
scripts/smoke.ps1                   Windows smoke assertions
packaging/README.md                 bundle quickstart + unsigned-binary bypass note (templated with version)
```

`logos/build.zig` and the daemon source are unchanged — the daemon already
defaults `ui_dir` to `<exe_dir>/ui`, which is exactly the bundle layout.

## Out of scope (YAGNI / later)

- Code signing / notarization (macOS) and Authenticode (Windows).
- Package managers (Homebrew tap, Scoop bucket).
- Auto-update; auto-open-browser on launch.
- Non-x64 Linux, ARM Windows, 32-bit.
- A hardening follow-up: add `.env`/secret patterns to `.gitignore` (no such files
  exist today, but the repo is now public).

## Acceptance criteria

- Pushing a tag `vX.Y.Z` (matching `build.zig.zon`) produces a GitHub Release with
  the four archives + `SHA256SUMS`, only after all four native smoke jobs pass.
- A version/tag mismatch fails the workflow before publishing.
- `workflow_dispatch` builds + smokes all four targets and publishes nothing.
- On a fresh machine of each OS, the documented install one-liner installs `logos`
  such that running `logos` serves the API + UI on `:7777` (Windows behaves as it
  does in dev today).
- Each smoke job exercises health, UI serving, upload (page_count==10), and slice
  on the real bundle for its OS.
