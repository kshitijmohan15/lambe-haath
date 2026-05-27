# Chargesheet Tool — Frontend

Web UI for a local chargesheet analysis tool. Served by a local daemon (Zig, not in this repo). v1 implements PDF splitting only.

## Prerequisites

- Node.js 20+ (developed against Node 22 / 25)
- yarn 1.x

## Setup

```bash
yarn install
cd mock-daemon && yarn install && cd ..
```

## Development

Run two terminals:

```bash
# Terminal 1: mock daemon on :7777
yarn run mock-daemon

# Terminal 2: Vite dev server on :5173 (proxies /api/* → :7777)
yarn run dev
```

Then open <http://localhost:5173>.

## Production build

```bash
yarn run build
```

Produces a static SPA in `build/` with `index.html` at the root. The real Zig
daemon serves this directory as the SPA shell while exposing `/api/v1/*` from
the same origin.

## Architecture

- **Same-origin design.** The frontend talks to `/api/v1/*` via relative URLs.
  In production the Zig daemon serves both the static bundle and the API. In
  development Vite proxies `/api/*` to the mock daemon on :7777.
- **No SSR.** SPA mode via `@sveltejs/adapter-static` with
  `fallback: 'index.html'`.
- **Schema validation.** Every JSON response is validated by a zod schema in
  `src/lib/api/schemas.ts`. Failures throw `DaemonError('INVALID_RESPONSE')`.

## API contract

See the contract section in `chargesheet-ui-plan.md`. All endpoints are under
`/api/v1`. Error responses have shape `{ code, message, details }`.

## Project structure

```
src/
  lib/
    api/         — typed HTTP client + zod schemas
    stores/      — Svelte 5 runes-based stores (.svelte.ts)
    components/  — UI components
    utils/       — pure helpers (filenames, validation, format)
  routes/
    +page.svelte           — project list
    new/+page.svelte       — new project form
    projects/[id]/         — workspace
mock-daemon/    — throwaway Node mock of the daemon API (Hono + pdf-lib)
```

## Adding a new endpoint

1. Add the request/response zod schema in `src/lib/api/schemas.ts`.
2. Add an inferred TS type in `src/lib/api/types.ts`.
3. Add a typed wrapper in `src/lib/api/{projects,slices,health}.ts` using
   `apiFetch(path, init, schema)`.
4. Implement it in the mock daemon at `mock-daemon/server.ts`.

## Scripts

| Command                | Purpose                            |
| ---------------------- | ---------------------------------- |
| `yarn run dev`         | Vite dev server                    |
| `yarn run build`       | Production SPA build to `build/`   |
| `yarn run preview`     | Serve the production build         |
| `yarn run check`       | `svelte-kit sync` + `svelte-check` |
| `yarn run test`        | vitest unit tests                  |
| `yarn run mock-daemon` | Start the mock daemon on :7777     |

## Known limitations

- Desktop-only design (min-width 1280px); no responsive layout.
- Light mode only.
- No drag-to-reorder of slices.
- One chargesheet per project; delete and recreate to change it.
