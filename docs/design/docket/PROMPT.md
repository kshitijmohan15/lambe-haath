# Prompt to give your coding agent (Claude Code, etc.)

Copy everything below into your agent, with this `design_handoff_docket/` folder present at the
repo root (or adjust the path). It assumes the agent can read the repo and this folder.

---

We're re-skinning the **chargesheet-ui** SvelteKit app with a new design direction called
**"Docket"**. Read `design_handoff_docket/README.md` in full first — it is the spec. Then open
`design_handoff_docket/reference/Chargesheet Tool (Prototype).html` in a browser to see the target
behavior, and use `reference/proto/ui.jsx` + `reference/proto/views.jsx` + `reference/docket.jsx`
for exact styling.

Hard rules:
- This is a **visual + information-architecture redesign only.** Do **not** change any API calls,
  zod schemas, stores (`*.svelte.ts`), job-polling, validation, or keyboard shortcuts. Reuse the
  existing components and wiring; restyle them in place.
- The reference files are **React/inline-style prototypes — never copy them.** Reimplement in our
  stack: **Svelte 5 (runes) + Tailwind v4**. Match colors/type/spacing from the README's token
  tables exactly.
- Keep everything light-mode and desktop-first (min ~1280px), consistent with the current app.

Do it in this order, pausing after each step so I can review:
1. Append `design_handoff_docket/tokens.css` to `src/app.css`; load Public Sans, Spectral, IBM Plex
   Mono. Verify the new utilities (`bg-paper`, `text-navy`, `font-serif`, …) work.
2. Restyle the shared primitives: `Button.svelte`, `JobStatusBadge.svelte`, `ProgressBar.svelte`,
   `EmptyState.svelte` to the new tokens.
3. Redesign `ProjectCard.svelte` and `src/routes/+page.svelte` (the Matters list) per README §1.
   Watch the flex `min-width:0; flex:1` note so long matter names don't collapse onto the citation.
4. The big one: create `PipelineRail.svelte` and replace `Tabs.svelte` in
   `src/routes/projects/[id]/+page.svelte`. Convert `activeTab` to a
   `'slice'|'extract'|'analyze'|'review'` stage rune, add the project switcher, and add a
   per-stage `StageHeader`. Labels rename Extractions→Extract, Prompts→Analyze, Stats→Review; the
   panels themselves stay.
5. Restyle the four panels in place: `SliceList`/`SliceListItem`/`PdfViewer`, `ExtractionsPanel`,
   `PromptsPanel`, `StatsPanel` — per README §3–6. Keep their props, handlers, and stores.
6. Polish: hover/focus states, the markdown viewer modal, and (optional) the accent/density tweaks
   via a small `data-accent` switch.

When unsure whether something is "behavior" vs "styling", treat it as behavior and leave it alone —
ask me.
