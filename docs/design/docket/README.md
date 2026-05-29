# Handoff: Chargesheet Tool — "Docket" redesign

## Overview
This package re-skins the existing **chargesheet-ui** SvelteKit app with the **Docket** design
direction: a warm paper-toned, ink-accented, editorial look (sans UI + serif content), and —
most importantly — it replaces the flat top **Tabs** (`Slice / Extractions / Prompts / Stats`)
with a persistent **vertical pipeline rail** (`Slice → Extract → Analyze → Review`) plus a
**project switcher**, so the four stages read as one sequential workflow with visible progress.

It is a **visual + IA redesign, not a feature change.** All data flows, API calls, stores, job
polling, and keyboard shortcuts stay exactly as they are. You are restyling and re-organizing the
shell, not rewriting the engine.

## About the design files
The files in `reference/` are **HTML/React prototypes** built only to show the intended look and
behavior. **Do not copy them into the app.** They use React + inline styles; your app is **Svelte 5
+ Tailwind v4**. The task is to **recreate the Docket look inside the existing Svelte codebase**,
reusing its components, stores, and patterns. Treat the prototype as the source of truth for
*appearance and layout*; treat your codebase as the source of truth for *structure and behavior*.

- `reference/Chargesheet Tool (Prototype).html` — the clickable prototype (open it; click through
  Matters → a matter → the rail stages). This is the target.
- `reference/proto/ui.jsx` — theme tokens + the **Rail**, **Header**, **StatusChip** (the new chrome).
- `reference/proto/views.jsx` — the per-stage screens (Matters, Slice, Extract, Analyze, Review).
- `reference/shared.jsx` — mock data shapes + the greeked document / Ring / Spark helpers.
- `reference/Chargesheet Redesign.html` + `reference/docket.jsx` — static, polished frames of the
  same direction (good for pixel reference of the Matters cards, slice list, prompt output).

## Fidelity
**High-fidelity.** Colors, typography, spacing, and radii below are final. Match them. Where the
prototype shows greeked text blocks (the PDF page), that is a placeholder for your real
`PdfViewer.svelte` output — keep your viewer, just restyle its chrome.

---

## Design tokens

Drop `tokens.css` (in this folder) into `src/app.css`. It is written for **Tailwind v4** using
`@theme`, so every token becomes a utility (`bg-paper`, `text-ink`, `border-line`, `font-serif`,
`text-navy`, etc.). Exact values:

### Color
| Token | Hex / value | Use |
|---|---|---|
| `paper`     | `#f3efe5` | App background (warm ivory) |
| `panel`     | `#fbf9f3` | Rail / secondary surfaces |
| `card`      | `#ffffff` | Cards, tables, content surfaces |
| `ink`       | `#22201b` | Primary text |
| `ink-2`     | `#6c675c` | Secondary text |
| `ink-3`     | `#9c968a` | Tertiary / meta text |
| `line`      | `rgba(40,35,25,0.11)` | Borders, dividers |
| `line-2`    | `rgba(40,35,25,0.07)` | Hairline dividers inside cards |
| `navy`      | `#1e3a5f` | **Accent** — primary buttons, active stage, links |
| `navy-dk`   | `#152a44` | Accent hover |
| `navy-soft` | `#eaeff5` | Accent-tinted fills (active rail item, chips, callouts) |
| `ok`        | `#4f7a52` | Completed / done status |
| `warn`      | `#b07a2e` | Running / in-progress status |
| `err`       | `#a23b2e` | Failed status |

The accent is themeable (the prototype offers Ink navy / Burgundy `#6e2433` / Forest `#1f5c4d` /
Slate `#3a4150`). Ship **Ink navy** as default; the others are optional.

### Typography
- **Sans (UI):** `Public Sans` — weights 400/500/600/700. All labels, buttons, table headers, meta.
- **Serif (content):** `Spectral` — weights 400/500/600. Matter names, screen titles, prompt
  titles, and the analysis/extraction body copy. This serif-for-content contrast is the signature
  of the look — use it for headings and document text, never for UI controls.
- **Mono:** `IBM Plex Mono` — filenames, page ranges, token counts, model names.

Load via Google Fonts (already how the app could pull them) or self-host. Type scale used:
| Role | Size / weight / family |
|---|---|
| Screen title | 26–30px / 600 / serif |
| Matter name (card) | 18px / 600 / serif, `line-height:1.2` |
| Section / table header | 10px / 600 / sans, `letter-spacing:0.6px`, uppercase, `ink-3` |
| Body / control | 12.5–13px / 500–600 / sans |
| Document & analysis body | 14px / 400 / serif, `line-height:1.7` |
| Meta / mono | 11px / 500 / mono, `ink-3` |

### Spacing, radius, shadow
- Radius: cards `14px`, inner panels/inputs `8–11px`, pills `100px`.
- Card shadow (rest): `0 1px 2px rgba(40,35,25,0.04)`; (hover): `0 6px 20px rgba(40,35,25,0.10)`
  with `translateY(-1px)`.
- Rail width `256px`. Header padding `16px 28px`. Content padding `26–40px`.
- Density is a tweak: multiply paddings by `0.82` (compact) / `1` (regular) / `1.16` (comfy).

---

## Screens & component mapping

> Map each piece to an **existing file** where one exists. New files are marked **NEW**.

### 1. Matters (route `/` → `src/routes/+page.svelte`)
Replace the current `Projects` header + grid with the Docket version.
- **Top bar:** brand mark ("C" tile in `navy` + `CHARGESHEET` in tracked sans caps) on the left,
  "Daemon connected" dot (reuse `ConnectionBanner` logic) on the right. ~56px, `bg-panel`,
  `border-b border-line`.
- **Heading:** "Matters" 30px serif, sub "{n} active · one chargesheet per matter". `+ New matter`
  primary button (links to `/new`).
- **Grid:** `repeat(auto-fill, minmax(380px, 1fr))`, gap 16.
- **`ProjectCard.svelte`** — restyle to the Docket card: serif matter name + `navy` citation line +
  serif description; a **progress ring** top-right (derive % from job/extraction completion); footer
  row with pages / slices stats and a `navy-soft` pill `{stage} · {updated}`.
  - ⚠️ **Layout gotcha:** the name+citation column must be `flex: 1; min-width: 0` inside the
    header flex row, or long matter names collapse onto the citation. (This bit us in the prototype.)

### 2. Workspace shell (route `src/routes/projects/[id]/+page.svelte`)
This is the biggest change. **Remove `Tabs.svelte`** from this route and introduce the rail.
- **NEW `PipelineRail.svelte`** (replaces `Tabs`): fixed 256px left column, full height.
  - Brand mark (top).
  - **Project switcher** — button showing current matter; on click, a dropdown listing all matters
    (name + citation + page count) and a "← All matters" link back to `/`. Feeds from
    `projectsStore`.
  - **Stepper** — the four stages as a vertical numbered list joined by a connector line. Active
    stage = `navy` filled circle + `navy-soft` row background; completed (lower index than active) =
    `ok` filled circle with ✓; each shows a thin per-stage progress bar.
  - Footer: "Daemon connected" indicator.
  - Stage state replaces the current `activeTab` `$state` — keep it as a `'slice'|'extract'|'analyze'|'review'`
    rune in the page; clicking a stage sets it. (Rename `Extractions→Extract`, `Prompts→Analyze`,
    `Stats→Review` in labels only; keep the panels.)
- **NEW `StageHeader.svelte`** (or inline): per-stage title (serif) + subline + right-aligned
  primary action. Map actions to existing handlers:
  - Slice → "Save & extract →" = your existing submit (`trySubmit`).
  - Extract → "OCR all pending" = `extractionsStore.enqueueAll` (your `triggerOcrAll`).
  - Analyze → "Run all" = `promptOutputsStore.enqueueAll` (your `triggerAll`).
  - Review → "Export brief" (stub / future).
- **`StatusChip` + `ProgressBar.svelte` + `JobStatusBadge.svelte`:** the prototype's chips map
  directly onto your existing `JobStatusBadge` / `ProgressBar`. Restyle colors to `ok/warn/err`,
  keep their props and the job-polling that drives them.

### 3. Slice stage → reuse `SliceList.svelte` + `SliceListItem.svelte` + `PdfViewer.svelte`
Two-column grid `1.35fr / 1fr` (PDF left, slices right). Restyle only:
- PDF toolbar: page nav buttons + "Page n / total" + the `[ ] n` shortcut hint in `ink-3`.
- Slice rows: selected row = `navy` border + `navy-soft` bg; serif label, mono filename, right-aligned
  `pp. a–b` (set `white-space: nowrap`) + size. Bottom "Save n slices & extract →" full-width `navy`.
- **Keep all keyboard shortcuts and validation** (`[`/`]`/`n`/`⌘↩`, `canSubmitAll`) verbatim.

### 4. Extract stage → reuse `ExtractionsPanel.svelte`
Table: Slice (serif label + mono filename) · Pages (mono) · Status (`StatusChip` + `ProgressBar`
when running + "{pages}p · {latency}s · {model}" when done) · action (`Run OCR` / `View text`).
"View text" opens your existing markdown viewer (`MarkdownViewer.svelte`) in a modal styled per
prototype. Sticky `bg-panel` table header; `border-line-2` row dividers; footer "{done} of {n}
extracted · {running} running". **Action buttons need `white-space: nowrap`.**

### 5. Analyze stage → reuse `PromptsPanel.svelte`
Two columns `0.92fr / 1.18fr`. Left = the 5 prompt cards (serif title + serif sub, Run/Running+bar/
View states; keep `KNOWN_PROMPTS` + `PROMPT_LABELS`). Right = output panel: selected prompt rendered
through `MarkdownViewer.svelte` inside a `card` with the `navy-soft` left-border "SUGGESTED OBJECTION"
callout. **Prompt-card title column also needs `flex:1; min-width:0`.**

### 6. Review stage → reuse `StatsPanel.svelte`
Three KPI cards (Total cost / Tokens / Runs — your existing stats), the first with a `Spark` line
(reuse `LineChart.svelte`). Below, a "Run history" table (OCR + prompt runs) with mono columns and
`OCR`/`PROMPT` type pills.

---

## Interactions & behavior (all already exist — preserve)
- Stage switching is local UI state (was `activeTab`). Project switcher navigates / sets active project.
- Job lifecycle (queue → running progress → done/failed), polling, and refresh-resume logic in
  `jobs.svelte.ts` / `extractions.svelte.ts` / `promptOutputs.svelte.ts` stay as-is.
- Card progress ring %, rail stage progress, and "x of y" counts derive from the same store data
  that currently feeds the badges — just compute fractions.
- Hover: cards lift (shadow + `-1px`); buttons darken to `navy-dk`.
- Transitions: progress bars `width .3s`; stage circle `all .15s`; switcher chevron rotate `.15s`.

## State management
No new stores. The only new client state is the **stage selector** (replacing `activeTab`) and the
**switcher open/closed** boolean — both local `$state` in the workspace page/`PipelineRail`. Theme
tokens are static CSS; the optional accent/density tweaks can be a tiny `theme.svelte.ts` store +
`data-` attribute on `<html>` if you want them user-switchable (not required for v1).

## Assets
None binary. Brand mark is a CSS tile (letter "C"). Document pages come from your real `PdfViewer`.
Fonts: Public Sans, Spectral, IBM Plex Mono (Google Fonts or self-hosted).

## Suggested order of work
1. Paste `tokens.css`, load the three fonts, confirm utilities resolve.
2. Restyle the small shared pieces: `Button`, `JobStatusBadge`, `ProgressBar`, `EmptyState`.
3. Redesign `ProjectCard` + the `/` Matters page.
4. Build `PipelineRail.svelte`, swap it in for `Tabs` in the workspace route, wire stage state.
5. Restyle the four panels (Slice, Extractions, Prompts, Stats) in place.
6. Polish: hover/focus states, the markdown modal, the optional accent/density tweaks.
