# lambe-haath

A self-contained PDF chargesheet slicing tool: a local daemon (HTTP API + PDF slicing) bundled with a web UI, intended to ship as a single cross-platform CLI.

## Components

| Dir | What it is |
|---|---|
| `logos/` | The daemon — Zig 0.16. HTTP API on `:7777` (projects, chargesheet upload, slice jobs), SQLite storage, PDF slicing via `mupdf-zig`. |
| `chargesheet-ui/` | The frontend — SvelteKit (`adapter-static`). Talks to the daemon's `/api/v1/*`. |
| `mupdf-zig/` | A small Zig wrapper over MuPDF's C API (open / page count / slice), built from vendored source via `zig cc` — cross-compiles to macOS, Linux, and Windows. |

## Status (v0.1.0)

- Daemon serves the full project + slicing API; UI drives it end-to-end (currently via `yarn dev` + Vite proxy).
- `logos` (daemon + SQLite + MuPDF) cross-compiles + links for `x86_64-windows-gnu` and `x86_64-linux-musl` from a macOS host (compile+link verified; cross-binaries not yet runtime-tested on those targets).

## Roadmap toward the single-CLI product

1. Daemon serves the built UI's static assets (one binary serves API + UI on one port).
2. Cross-platform installer that drops the CLI on the user's machine.

## Building

```bash
# daemon (runs its test suite)
cd logos && zig build test

# mupdf-zig library
cd mupdf-zig && zig build test

# UI dev server (proxies /api to the daemon on :7777)
cd chargesheet-ui && yarn && yarn dev
```
