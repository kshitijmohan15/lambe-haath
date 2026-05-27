# Handoff — 2026-05-27

## Where we are

Monorepo `~/projects/lambe-haath/` (git). Building **lambe-haath**: a self-contained PDF
chargesheet slicing tool that ships as a single cross-platform CLI — the installer drops a
CLI that starts the daemon AND serves the web UI on one port (`:7777`); the user installs
nothing else.

- `main` is pushed to **github.com/kshitijmohan15/lambe-haath** (personal account), tagged
  `v0.1.0`. Push via the `ssh://` URL workaround — see memory `reference_personal_github_push.md`.
- Current branch: **`feat/daemon-serves-ui`** (NOT yet pushed / no PR).

### Components (all in the monorepo)
- `logos/` — the daemon (Zig 0.16). Full HTTP API (`/api/v1/*`) + SQLite + PDF slicing.
  **75/75 tests pass.** Cross-compiles+links for `x86_64-windows-gnu` and `x86_64-linux-musl`
  from macOS (compile+link only — NOT runtime-tested on those targets yet).
- `chargesheet-ui/` — SvelteKit SPA (`adapter-static`, `fallback: index.html`). `yarn build` → `build/`.
- `mupdf-zig/` — standalone Zig wrapper over MuPDF C API, builds MuPDF from vendored source via
  `zig cc`. Slice GC fix lives in `src/bridge/bridge.c` (`do_garbage=2, do_clean=1`).

## What's DONE this session
Phases 6 (DB domain layer), 7 (mupdf-zig library + integration), 8a/8b (full HTTP API, sync
slicing, slice-size GC fix), monorepo consolidation + first personal-GitHub push, and the
**daemon-serves-UI design** (pivoted embed → **disk-serve**).

## NEXT TASK — execute the disk-serve plan (#2)

Everything is designed and planned; nothing implemented yet. The branch `feat/daemon-serves-ui`
has the committed spec + plan (commit `08043f9` supersedes the earlier embed commits `1a7d3f5`/`c9c3494`):
- Spec: `logos/docs/superpowers/specs/2026-05-27-daemon-serves-ui-design.md`
- Plan: `logos/docs/superpowers/plans/2026-05-27-daemon-serves-ui.md`

**The plan is the source of truth — read it.** Two tasks:
1. **Task 1 (code, TDD):** `config.ui_dir` (from `CHARGESHEET_UI_DIR` or `<exe_dir>/ui`); new
   `src/api/static.zig` (`resolve`/`mimeForPath`/path-traversal guard) unit-tested against a
   `std.testing.tmpDir` fixture; `server.zig` dispatches the `.not_found` arm through static
   (`respondFile` + `respondUiPlaceholder`); `main.zig` wires `ui_dir`. Target: **78/78 tests**,
   node-free, `build.zig` UNCHANGED.
2. **Task 2 (verify):** `cd chargesheet-ui && yarn build`; run daemon with
   `CHARGESHEET_UI_DIR=.../chargesheet-ui/build`; curl `/`, an `_app/*.js`, a deep link, `/api/v1/health`,
   and a traversal path; open in a browser and drive the API with NO `yarn dev`.

**How to execute:** confirm approach with the user (subagent-driven recommended, per
superpowers:subagent-driven-development — fresh implementer subagent per task + spec-review then
code-quality review). The 0.16 stdlib calls in the plan are flagged "mirror the existing pattern
in `src/storage/project_dir.zig` / `src/lock.zig` / the chargesheet handler" — those are the
in-repo precedents to copy, not gaps.

When done: branch + PR (never push to main); then #3 is the CI matrix build + GitHub Releases +
cross-platform installer that builds the UI and places it at `<exe_dir>/ui`.

## Hard constraints (from CLAUDE.md + session)
- **NEVER push to `main`** — always branch + PR. No exceptions.
- **No `Co-Authored-By` / Claude attribution** in commits.
- Personal repo ops use the **SSH-URL path** (`ssh://git@github.com/kshitijmohan15/...` +
  repo-local `core.sshCommand` w/ `~/.ssh/id_ed25519_git_personal`). `gh` is authed as the WORK
  account `kshitij4myfi` — do NOT use it for personal-repo ops.
- IST timezone for any times. Apply the Conjecture Review Framework to non-trivial changes.
- Path-traversal guard in `static.zig` is a security requirement (never serve outside `ui_dir`).

## Toolchain notes
- Zig 0.16.0 at `/Users/user/.zvm/0.16.0/`. Post-`std.Io`-refactor APIs (`std.Io.Dir.cwd()`,
  `readFileAlloc(io, path, gpa, .limited(N))`, `std.ArrayList(T) = .empty`, etc.).
- Pre-monorepo history of the 3 original repos: `~/projects/_lambe-backups/{logos,chargesheet-ui,mupdf-zig}.bundle`.
