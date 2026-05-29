# Plan F — Chargesheet UI: OCR + Prompts Tabs

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** Wire the existing Svelte SPA (`chargesheet-ui`) to drive the full OCR + prompts pipeline. From the project detail page, the user can trigger per-slice OCR runs, watch live job progress, view the extracted Markdown, then trigger any of the five defence-analysis prompts and view their Markdown outputs.

**Architecture:** Extend the existing SvelteKit app (Svelte 5 runes, TypeScript, Tailwind 4, vitest, zod-validated API). Add tabbed navigation to the project detail page (Slice | Extractions | Prompts), with new API client functions, stores, and components for each tab. Job progress is shown via simple polling (~500 ms tick); SSE upgrade is deferred to a follow-up. Markdown rendering uses `marked` (added as a dep).

**Tech Stack:** SvelteKit 2.57 + Svelte 5.55 + TypeScript + Tailwind 4 + zod + vitest. New dep: `marked` (markdown → HTML).

**Spec reference:** `~/projects/chargesheets/pdf-extraction-experiments/docs/superpowers/specs/2026-05-28-chargesheet-pipeline-design.md` — sections _logos modules to add_ (HTTP routes), _Database schema additions_ (`extractions`, `prompt_outputs`, `job_logs`), _Slicing convention_, _Output format: Markdown_.

**Prereqs:** Plans A–D merged. The daemon's HTTP API serves the full pipeline; OCR and prompt agents work end-to-end.

**Out of scope for Plan F** (deferred): SSE live updates (this plan uses polling). Mermaid diagram rendering inside Markdown (the time_chart prompt's mermaid blocks render as code fences for now). Stats page (Plan E). UI for editing prompts (per spec non-goals).

---

## File structure

### `~/projects/lambe-haath/chargesheet-ui/`

```
src/
  lib/
    api/
      schemas.ts                 ← MODIFY (extend JobStatus enum + add extraction/prompt schemas)
      types.ts                   ← MODIFY (add inferred types)
      extractions.ts             ← CREATE (API functions for /extractions endpoints)
      prompts.ts                 ← CREATE (API functions for /prompts endpoints)
      jobs.ts                    ← CREATE (API functions for /jobs/:id/logs + cancel)
    stores/
      extractions.svelte.ts      ← CREATE
      promptOutputs.svelte.ts    ← CREATE
      jobs.svelte.ts             ← CREATE (polling-based status tracker)
    components/
      Tabs.svelte                ← CREATE (simple tab navigation)
      ExtractionsPanel.svelte    ← CREATE (slice list + per-slice OCR trigger + view)
      PromptsPanel.svelte        ← CREATE (5 prompts + trigger + view)
      JobStatusBadge.svelte      ← CREATE
      MarkdownViewer.svelte      ← CREATE (uses `marked` for rendering)
      ProgressBar.svelte         ← CREATE
  routes/
    projects/[id]/
      +page.svelte               ← MODIFY (wrap existing content in a Slice tab; add Extractions + Prompts tabs)
  app.css                        ← MODIFY (add `.markdown-body` prose styles if needed)
tests/
  (existing test setup; new tests colocated near sources as `*.test.ts`)
package.json                     ← MODIFY (add `marked` dep)
```

---

## Pre-flight: branching

```bash
cd ~/projects/lambe-haath
git checkout main && git checkout -b feat/plan-f-chargesheet-ui
```

(Plan F is all UI work; nothing in `pdf-extraction-experiments` changes.)

---

## Task 1: API schemas + types

**Target repo:** `~/projects/lambe-haath/chargesheet-ui/`

**Files:**
- Modify: `src/lib/api/schemas.ts`
- Modify: `src/lib/api/types.ts`

The existing `JobStatusSchema` is `['queued', 'running', 'completed', 'failed']`. Plan B added `'canceled'`. Extend the schema and add new schemas for extractions, prompt outputs, and job logs.

- [ ] **Step 1: Add `'canceled'` to JobStatusSchema in `src/lib/api/schemas.ts`**

Change:
```typescript
export const JobStatusSchema = z.enum(['queued', 'running', 'completed', 'failed']);
```
to:
```typescript
export const JobStatusSchema = z.enum(['queued', 'running', 'completed', 'failed', 'canceled']);
```

- [ ] **Step 2: Add new schemas at the end of `src/lib/api/schemas.ts`**

```typescript
// --- Extractions ---

export const ExtractionRowSchema = z.object({
	project_id: z.string(),
	slice_filename: z.string(),
	markdown_path: z.string(),
	meta_path: z.string(),
	model: z.string(),
	pages: z.number().int().positive(),
	page_markers_found: z.number().int().nonnegative(),
	input_tokens: z.number().int().nullable(),
	output_tokens: z.number().int().nullable(),
	input_cost_usd: z.number().nullable(),
	output_cost_usd: z.number().nullable(),
	latency_s: z.number(),
	created_at: z.string(),
});

export const ExtractionsListResponseSchema = z.array(ExtractionRowSchema);

// --- Prompt outputs ---

export const PromptOutputRowSchema = z.object({
	project_id: z.string(),
	prompt_name: z.string(),
	markdown_path: z.string(),
	model: z.string(),
	input_tokens: z.number().int().nullable(),
	output_tokens: z.number().int().nullable(),
	input_cost_usd: z.number().nullable(),
	output_cost_usd: z.number().nullable(),
	latency_s: z.number(),
	warnings: z.array(z.string()),
	created_at: z.string(),
});

export const PromptOutputsListResponseSchema = z.array(PromptOutputRowSchema);

// --- Job logs ---

export const LogLevelSchema = z.enum(['debug', 'info', 'warning', 'error']);

export const JobLogEntrySchema = z.object({
	ts: z.string(),
	level: LogLevelSchema,
	logger: z.string(),
	message: z.string(),
});

export const JobLogsResponseSchema = z.array(JobLogEntrySchema);

// --- Job (full status) ---
// (Job rows returned by GET /api/v1/projects/:id/jobs/:job_id.)
export const JobSchema = z.object({
	id: z.string(),
	project_id: z.string(),
	type: z.enum(['slice', 'ocr', 'prompt']),
	status: JobStatusSchema,
	progress: z.number().min(0).max(1),
	payload: z.string(),
	results: z.string().nullable(),
	error: z.string().nullable(),
	created_at: z.string(),
	updated_at: z.string(),
});
```

- [ ] **Step 3: Add the inferred types to `src/lib/api/types.ts`**

Append:
```typescript
export type ExtractionRow = z.infer<typeof s.ExtractionRowSchema>;
export type ExtractionsListResponse = z.infer<typeof s.ExtractionsListResponseSchema>;
export type PromptOutputRow = z.infer<typeof s.PromptOutputRowSchema>;
export type PromptOutputsListResponse = z.infer<typeof s.PromptOutputsListResponseSchema>;
export type LogLevel = z.infer<typeof s.LogLevelSchema>;
export type JobLogEntry = z.infer<typeof s.JobLogEntrySchema>;
export type JobLogsResponse = z.infer<typeof s.JobLogsResponseSchema>;
export type Job = z.infer<typeof s.JobSchema>;
```

- [ ] **Step 4: Run typecheck + commit**

```bash
cd ~/projects/lambe-haath/chargesheet-ui
yarn check 2>&1 | tail -10
```

Expected: no new errors.

```bash
git add src/lib/api/schemas.ts src/lib/api/types.ts
git commit -m "chargesheet-ui/api: schemas+types for extractions, prompt_outputs, job_logs, jobs"
```

---

## Task 2: Extractions, Prompts, and Jobs API client functions

**Target repo:** `~/projects/lambe-haath/chargesheet-ui/`

**Files:**
- Create: `src/lib/api/extractions.ts`
- Create: `src/lib/api/prompts.ts`
- Create: `src/lib/api/jobs.ts`

Mirror the existing `src/lib/api/slices.ts` pattern (use `apiFetch` from `./client`, zod-validate responses).

- [ ] **Step 1: Create `src/lib/api/extractions.ts`**

```typescript
import { apiFetch, apiFetchText } from './client';
import {
	ExtractionsListResponseSchema,
	JobCreatedResponseSchema,
} from './schemas';
import type {
	ExtractionsListResponse,
	JobCreatedResponse,
} from './types';

/** List all extraction rows for a project. */
export async function listExtractions(projectId: string): Promise<ExtractionsListResponse> {
	return apiFetch(
		`/projects/${encodeURIComponent(projectId)}/extractions`,
		{ method: 'GET' },
		ExtractionsListResponseSchema
	);
}

/** Enqueue an OCR job for a single slice. */
export async function enqueueOcr(
	projectId: string,
	sliceFilename: string
): Promise<JobCreatedResponse> {
	return apiFetch(
		`/projects/${encodeURIComponent(projectId)}/jobs/ocr`,
		{
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({ slice_filename: sliceFilename }),
		},
		JobCreatedResponseSchema
	);
}

/** Enqueue an OCR job for every slice that doesn't yet have an extraction. */
export async function enqueueOcrAll(
	projectId: string
): Promise<{ job_ids: string[] }> {
	const resp = await apiFetch(
		`/projects/${encodeURIComponent(projectId)}/jobs/ocr/all`,
		{ method: 'POST' },
		// The daemon returns {job_ids: ["..."]}; use a small inline schema.
		(await import('zod')).z.object({ job_ids: (await import('zod')).z.array((await import('zod')).z.string()) })
	);
	return resp;
}

/** Fetch the rendered Markdown for an extraction. */
export async function getExtractionMarkdown(
	projectId: string,
	sliceFilename: string
): Promise<string> {
	return apiFetchText(
		`/projects/${encodeURIComponent(projectId)}/extractions/${encodeURIComponent(sliceFilename)}`,
		{ method: 'GET' }
	);
}
```

Note: the `enqueueOcrAll` inline-import-zod pattern is awkward. Simpler — define a top-level schema near the top of the file:

```typescript
import { z } from 'zod';

const JobIdsResponseSchema = z.object({ job_ids: z.array(z.string()) });
```

And use `JobIdsResponseSchema` in `enqueueOcrAll`.

- [ ] **Step 2: Add `apiFetchText` helper to `src/lib/api/client.ts`**

The existing `client.ts` only has `apiFetch` (which expects JSON + zod). We need a text variant for downloading the `.md` files. Find `apiFetch` in the file and add a sibling:

```typescript
/** Fetch a text response (e.g., raw Markdown). Throws DaemonError on non-2xx. */
export async function apiFetchText(path: string, init: RequestInit): Promise<string> {
	const response = await executeRequest(path, init);
	return await response.text();
}
```

(`executeRequest` is the existing private helper; it already handles the non-2xx error wrap.)

- [ ] **Step 3: Create `src/lib/api/prompts.ts`**

```typescript
import { z } from 'zod';
import { apiFetch, apiFetchText } from './client';
import {
	JobCreatedResponseSchema,
	PromptOutputsListResponseSchema,
} from './schemas';
import type {
	JobCreatedResponse,
	PromptOutputsListResponse,
} from './types';

const JobIdsResponseSchema = z.object({ job_ids: z.array(z.string()) });

/** The 5 known prompt names this UI exposes. Keep in sync with logos's
 * src/api/handlers_prompts.zig KNOWN_PROMPTS. */
export const KNOWN_PROMPTS = [
	'charge_memo_analysis',
	'imputation_scrutiny',
	'time_chart',
	'evidence_audit',
	'objection_brief',
] as const;
export type KnownPromptName = (typeof KNOWN_PROMPTS)[number];

/** List all prompt-output rows for a project. */
export async function listPromptOutputs(projectId: string): Promise<PromptOutputsListResponse> {
	return apiFetch(
		`/projects/${encodeURIComponent(projectId)}/prompts`,
		{ method: 'GET' },
		PromptOutputsListResponseSchema
	);
}

/** Enqueue a single prompt run. */
export async function enqueuePrompt(
	projectId: string,
	promptName: KnownPromptName
): Promise<JobCreatedResponse> {
	return apiFetch(
		`/projects/${encodeURIComponent(projectId)}/jobs/prompt`,
		{
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({ prompt_name: promptName }),
		},
		JobCreatedResponseSchema
	);
}

/** Enqueue all 5 prompts at once. */
export async function enqueuePromptAll(projectId: string): Promise<{ job_ids: string[] }> {
	return apiFetch(
		`/projects/${encodeURIComponent(projectId)}/jobs/prompt/all`,
		{ method: 'POST' },
		JobIdsResponseSchema
	);
}

/** Fetch the rendered Markdown for a prompt output. */
export async function getPromptMarkdown(
	projectId: string,
	promptName: KnownPromptName
): Promise<string> {
	return apiFetchText(
		`/projects/${encodeURIComponent(projectId)}/prompts/${encodeURIComponent(promptName)}`,
		{ method: 'GET' }
	);
}
```

- [ ] **Step 4: Create `src/lib/api/jobs.ts`**

```typescript
import { apiFetch, apiFetchVoid } from './client';
import { JobLogsResponseSchema, JobSchema } from './schemas';
import type { Job, JobLogsResponse } from './types';

/** Get the status of any job. (logos already has /api/v1/projects/:id/jobs/:job_id,
 * but for cross-project lookups Plan B added a per-job endpoint shape.
 * If only the per-project route exists, we accept projectId here. Adjust if the
 * actual route shape differs.) */
export async function getJob(projectId: string, jobId: string): Promise<Job> {
	return apiFetch(
		`/projects/${encodeURIComponent(projectId)}/jobs/${encodeURIComponent(jobId)}`,
		{ method: 'GET' },
		JobSchema
	);
}

/** Fetch all log lines for a job. */
export async function getJobLogs(jobId: string): Promise<JobLogsResponse> {
	return apiFetch(
		`/jobs/${encodeURIComponent(jobId)}/logs`,
		{ method: 'GET' },
		JobLogsResponseSchema
	);
}

/** Request cancellation of a running job. Returns 202 Accepted on success;
 * the actual transition to canceled status happens when the agent acknowledges. */
export async function cancelJob(jobId: string): Promise<void> {
	return apiFetchVoid(
		`/jobs/${encodeURIComponent(jobId)}/cancel`,
		{ method: 'POST' }
	);
}
```

`apiFetchVoid` is an existing helper in `client.ts` (it's already used by `slices.ts`).

- [ ] **Step 5: Add tests for the new API clients**

Create `src/lib/api/extractions.test.ts`, `prompts.test.ts`, `jobs.test.ts`. Mirror the existing `client.test.ts` pattern — mock `fetch`, exercise happy + error paths.

Minimum two tests per file: one happy-path round-trip, one schema-rejection (e.g., bad payload shape from daemon).

Example for `extractions.test.ts`:

```typescript
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { listExtractions, enqueueOcr } from './extractions';

beforeEach(() => {
	vi.unstubAllGlobals();
});

describe('extractions API', () => {
	it('listExtractions parses a valid array response', async () => {
		const mockResp = [
			{
				project_id: 'p1',
				slice_filename: 'annexure-i.pdf',
				markdown_path: '/x.md',
				meta_path: '/x.meta.json',
				model: 'gemini-2.5-flash',
				pages: 5,
				page_markers_found: 5,
				input_tokens: 100,
				output_tokens: 500,
				input_cost_usd: 0.0001,
				output_cost_usd: 0.001,
				latency_s: 12.5,
				created_at: '2026-05-28T00:00:00Z',
			},
		];
		vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify(mockResp), { status: 200 })));

		const result = await listExtractions('p1');
		expect(result).toHaveLength(1);
		expect(result[0].slice_filename).toBe('annexure-i.pdf');
	});

	it('enqueueOcr returns job_id on 201', async () => {
		const mockResp = { job_id: 'job-abc', status: 'queued' };
		vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify(mockResp), { status: 201 })));

		const result = await enqueueOcr('p1', 'annexure-i.pdf');
		expect(result.job_id).toBe('job-abc');
		expect(result.status).toBe('queued');
	});
});
```

Write similar tests for `prompts.test.ts` and `jobs.test.ts`.

- [ ] **Step 6: Run + commit**

```bash
cd ~/projects/lambe-haath/chargesheet-ui
yarn test 2>&1 | tail -15
```

Expected: existing tests still pass + ~6 new tests added.

```bash
git add src/lib/api/extractions.ts src/lib/api/prompts.ts src/lib/api/jobs.ts src/lib/api/client.ts \
        src/lib/api/extractions.test.ts src/lib/api/prompts.test.ts src/lib/api/jobs.test.ts
git commit -m "chargesheet-ui/api: extractions + prompts + jobs client functions"
```

---

## Task 3: Stores — extractions, promptOutputs, jobs (polling)

**Target repo:** `~/projects/lambe-haath/chargesheet-ui/`

**Files:**
- Create: `src/lib/stores/extractions.svelte.ts`
- Create: `src/lib/stores/promptOutputs.svelte.ts`
- Create: `src/lib/stores/jobs.svelte.ts`

Mirror the existing `projects.svelte.ts` pattern (class with `$state` runes, `load`/`loading`/`error` fields, async methods).

- [ ] **Step 1: Create `src/lib/stores/extractions.svelte.ts`**

```typescript
import * as api from '$lib/api/extractions';
import type { ExtractionRow } from '$lib/api/types';

class ExtractionsStore {
	rows = $state<ExtractionRow[]>([]);
	loading = $state(false);
	error = $state<string | null>(null);

	/** Load all extractions for the given project. */
	async load(projectId: string): Promise<void> {
		this.loading = true;
		this.error = null;
		try {
			this.rows = await api.listExtractions(projectId);
		} catch (e) {
			this.error = e instanceof Error ? e.message : 'Failed to load extractions';
		} finally {
			this.loading = false;
		}
	}

	/** Trigger an OCR job for one slice. Returns the new job_id. */
	async enqueue(projectId: string, sliceFilename: string): Promise<string> {
		const resp = await api.enqueueOcr(projectId, sliceFilename);
		return resp.job_id;
	}

	/** Trigger OCR for every slice without an extraction. */
	async enqueueAll(projectId: string): Promise<string[]> {
		const resp = await api.enqueueOcrAll(projectId);
		return resp.job_ids;
	}

	/** Find a row by slice filename, if it exists. */
	findBySlice(sliceFilename: string): ExtractionRow | null {
		return this.rows.find((r) => r.slice_filename === sliceFilename) ?? null;
	}

	clear() {
		this.rows = [];
		this.error = null;
	}
}

export const extractionsStore = new ExtractionsStore();
```

- [ ] **Step 2: Create `src/lib/stores/promptOutputs.svelte.ts`**

```typescript
import * as api from '$lib/api/prompts';
import type { KnownPromptName } from '$lib/api/prompts';
import type { PromptOutputRow } from '$lib/api/types';

class PromptOutputsStore {
	rows = $state<PromptOutputRow[]>([]);
	loading = $state(false);
	error = $state<string | null>(null);

	async load(projectId: string): Promise<void> {
		this.loading = true;
		this.error = null;
		try {
			this.rows = await api.listPromptOutputs(projectId);
		} catch (e) {
			this.error = e instanceof Error ? e.message : 'Failed to load prompt outputs';
		} finally {
			this.loading = false;
		}
	}

	async enqueue(projectId: string, promptName: KnownPromptName): Promise<string> {
		const resp = await api.enqueuePrompt(projectId, promptName);
		return resp.job_id;
	}

	async enqueueAll(projectId: string): Promise<string[]> {
		const resp = await api.enqueuePromptAll(projectId);
		return resp.job_ids;
	}

	findByName(promptName: string): PromptOutputRow | null {
		return this.rows.find((r) => r.prompt_name === promptName) ?? null;
	}

	clear() {
		this.rows = [];
		this.error = null;
	}
}

export const promptOutputsStore = new PromptOutputsStore();
```

- [ ] **Step 3: Create `src/lib/stores/jobs.svelte.ts`**

This store tracks "live" jobs — jobs the user just kicked off. It polls each one every 500ms until it reaches a terminal status (`completed`, `failed`, `canceled`). On terminal status, it stops polling that job and triggers a callback so the UI can reload its extractions/prompts list.

```typescript
import * as api from '$lib/api/jobs';
import * as projectsApi from '$lib/api/projects';
import type { Job, JobStatus } from '$lib/api/types';

const TERMINAL: ReadonlySet<JobStatus> = new Set(['completed', 'failed', 'canceled']);

class JobsStore {
	/** Map job_id → most recent Job snapshot (or null if errored on fetch). */
	live = $state<Map<string, Job>>(new Map());
	/** Active polling intervals, keyed by job_id. */
	private timers = new Map<string, ReturnType<typeof setInterval>>();

	/** Start tracking a job. Calls `onTerminal` once when the job reaches a
	 * terminal status (passing the final Job snapshot). */
	track(projectId: string, jobId: string, onTerminal?: (job: Job) => void): void {
		if (this.timers.has(jobId)) return; // already tracking

		const tick = async () => {
			try {
				const job = await api.getJob(projectId, jobId);
				this.live.set(jobId, job);
				this.live = new Map(this.live); // trigger reactivity
				if (TERMINAL.has(job.status)) {
					this.stop(jobId);
					if (onTerminal) onTerminal(job);
				}
			} catch (e) {
				// Network blip — keep polling; the next tick may succeed.
				console.warn(`job poll ${jobId} failed`, e);
			}
		};
		void tick();
		this.timers.set(jobId, setInterval(tick, 500));
	}

	/** Stop tracking a job (but keep its last snapshot in `live`). */
	stop(jobId: string): void {
		const t = this.timers.get(jobId);
		if (t !== undefined) {
			clearInterval(t);
			this.timers.delete(jobId);
		}
	}

	/** Cancel a job via the daemon. The polling loop will pick up the
	 * `canceled` status on its next tick and stop. */
	async cancel(jobId: string): Promise<void> {
		await api.cancelJob(jobId);
	}

	/** Stop tracking all jobs (e.g., on route change). */
	stopAll(): void {
		for (const t of this.timers.values()) clearInterval(t);
		this.timers.clear();
	}

	get(jobId: string): Job | undefined {
		return this.live.get(jobId);
	}
}

export const jobsStore = new JobsStore();
```

- [ ] **Step 4: Run typecheck + commit**

```bash
cd ~/projects/lambe-haath/chargesheet-ui
yarn check 2>&1 | tail -10
```

Expected: clean.

```bash
git add src/lib/stores/extractions.svelte.ts src/lib/stores/promptOutputs.svelte.ts src/lib/stores/jobs.svelte.ts
git commit -m "chargesheet-ui/stores: extractions, promptOutputs, jobs (polling-based status tracker)"
```

---

## Task 4: Components — JobStatusBadge, ProgressBar, MarkdownViewer, Tabs

**Target repo:** `~/projects/lambe-haath/chargesheet-ui/`

**Files:**
- Create: `src/lib/components/JobStatusBadge.svelte`
- Create: `src/lib/components/ProgressBar.svelte`
- Create: `src/lib/components/MarkdownViewer.svelte`
- Create: `src/lib/components/Tabs.svelte`
- Modify: `package.json` (add `marked` dep)

Read one of the existing simple components (e.g., `Button.svelte`, `EmptyState.svelte`) first to match the project's style conventions.

- [ ] **Step 1: Add `marked` dep**

```bash
cd ~/projects/lambe-haath/chargesheet-ui
yarn add marked
```

This updates `package.json` and `yarn.lock`.

- [ ] **Step 2: `JobStatusBadge.svelte`**

```svelte
<script lang="ts">
	import type { JobStatus } from '$lib/api/types';

	let { status, progress = 0 }: { status: JobStatus | null; progress?: number } = $props();

	const tone: Record<JobStatus, string> = {
		queued:    'bg-gray-100 text-gray-700',
		running:   'bg-blue-100 text-blue-700',
		completed: 'bg-green-100 text-green-700',
		failed:    'bg-red-100 text-red-700',
		canceled:  'bg-yellow-100 text-yellow-700',
	};

	const label: Record<JobStatus, string> = {
		queued:    'Queued',
		running:   'Running',
		completed: 'Done',
		failed:    'Failed',
		canceled:  'Canceled',
	};
</script>

{#if status}
	<span class="inline-flex items-center gap-1.5 rounded px-2 py-0.5 text-xs font-medium {tone[status]}">
		{label[status]}
		{#if status === 'running' && progress > 0}
			<span class="text-[10px] opacity-75">{Math.round(progress * 100)}%</span>
		{/if}
	</span>
{/if}
```

- [ ] **Step 3: `ProgressBar.svelte`**

```svelte
<script lang="ts">
	let { value = 0 }: { value?: number } = $props();
	const clamped = $derived(Math.max(0, Math.min(1, value)));
</script>

<div class="h-1 w-full overflow-hidden rounded-full bg-gray-200">
	<div
		class="h-full bg-blue-500 transition-all duration-200"
		style="width: {clamped * 100}%"
	></div>
</div>
```

- [ ] **Step 4: `MarkdownViewer.svelte`**

```svelte
<script lang="ts">
	import { marked } from 'marked';

	let { markdown, class: cls = '' }: { markdown: string; class?: string } = $props();

	// `marked` is synchronous when given a string and no async extensions.
	const html = $derived(marked.parse(markdown) as string);
</script>

<article class="prose prose-sm max-w-none {cls}">
	{@html html}
</article>
```

(Tailwind 4 provides the `prose` utility via the typography plugin. If it's not already enabled, the existing Tailwind config needs `@plugin "@tailwindcss/typography"`. Check `src/app.css` for the existing `@import "tailwindcss"` line and add `@plugin "@tailwindcss/typography";` after it. If the typography plugin isn't installed, `yarn add -D @tailwindcss/typography` first.)

- [ ] **Step 5: `Tabs.svelte`**

```svelte
<script lang="ts">
	type TabKey = string;
	interface Tab {
		key: TabKey;
		label: string;
		badge?: number | string;
	}

	let {
		tabs,
		active = $bindable(),
	}: {
		tabs: Tab[];
		active: TabKey;
	} = $props();
</script>

<div class="border-b border-gray-200">
	<nav class="flex gap-6 px-6" aria-label="Tabs">
		{#each tabs as tab (tab.key)}
			<button
				type="button"
				class="border-b-2 px-1 py-2.5 text-sm font-medium {active === tab.key
					? 'border-blue-500 text-blue-600'
					: 'border-transparent text-gray-500 hover:border-gray-300 hover:text-gray-700'}"
				onclick={() => (active = tab.key)}
			>
				{tab.label}
				{#if tab.badge !== undefined}
					<span class="ml-1 rounded bg-gray-100 px-1.5 py-0.5 text-xs text-gray-700">
						{tab.badge}
					</span>
				{/if}
			</button>
		{/each}
	</nav>
</div>
```

- [ ] **Step 6: Run typecheck + commit**

```bash
yarn check 2>&1 | tail -10
```

```bash
git add src/lib/components/JobStatusBadge.svelte src/lib/components/ProgressBar.svelte src/lib/components/MarkdownViewer.svelte src/lib/components/Tabs.svelte package.json yarn.lock src/app.css
git commit -m "chargesheet-ui/components: JobStatusBadge, ProgressBar, MarkdownViewer, Tabs"
```

---

## Task 5: `ExtractionsPanel.svelte`

**Target repo:** `~/projects/lambe-haath/chargesheet-ui/`

**Files:**
- Create: `src/lib/components/ExtractionsPanel.svelte`

This panel lists every slice for the project, shows OCR status per slice (job badge if active, completed badge if extraction exists), and has actions to trigger OCR or view the rendered Markdown.

- [ ] **Step 1: Create `src/lib/components/ExtractionsPanel.svelte`**

```svelte
<script lang="ts">
	import { onMount } from 'svelte';
	import { extractionsStore } from '$lib/stores/extractions.svelte';
	import { jobsStore } from '$lib/stores/jobs.svelte';
	import { toastsStore } from '$lib/stores/toasts.svelte';
	import { listSlices } from '$lib/api/slices';
	import { getExtractionMarkdown } from '$lib/api/extractions';
	import type { SliceListingItem } from '$lib/api/types';
	import Button from './Button.svelte';
	import EmptyState from './EmptyState.svelte';
	import JobStatusBadge from './JobStatusBadge.svelte';
	import ProgressBar from './ProgressBar.svelte';
	import MarkdownViewer from './MarkdownViewer.svelte';

	let { projectId }: { projectId: string } = $props();

	let slices = $state<SliceListingItem[]>([]);
	let slicesLoading = $state(false);
	let slicesError = $state<string | null>(null);
	let viewerOpen = $state<string | null>(null); // slice_filename of the open viewer
	let viewerMarkdown = $state<string>('');
	let viewerLoading = $state(false);

	/** job_id → slice_filename mapping for the active jobs we kicked off. */
	let jobBySlice = $state<Map<string, string>>(new Map()); // slice_filename → job_id

	async function loadSlices() {
		slicesLoading = true;
		slicesError = null;
		try {
			const resp = await listSlices(projectId);
			slices = resp.slices;
		} catch (e) {
			slicesError = e instanceof Error ? e.message : 'Failed to load slices';
		} finally {
			slicesLoading = false;
		}
	}

	async function reloadAll() {
		await loadSlices();
		await extractionsStore.load(projectId);
	}

	onMount(() => {
		void reloadAll();
		return () => {
			jobsStore.stopAll();
		};
	});

	async function triggerOcr(sliceFilename: string) {
		try {
			const jobId = await extractionsStore.enqueue(projectId, sliceFilename);
			jobBySlice.set(sliceFilename, jobId);
			jobBySlice = new Map(jobBySlice);
			jobsStore.track(projectId, jobId, () => {
				// On terminal: reload extractions list to pick up the new row.
				void extractionsStore.load(projectId);
				jobBySlice.delete(sliceFilename);
				jobBySlice = new Map(jobBySlice);
			});
		} catch (e) {
			toastsStore.error(e instanceof Error ? e.message : 'Failed to start OCR');
		}
	}

	async function triggerOcrAll() {
		try {
			const jobIds = await extractionsStore.enqueueAll(projectId);
			// Pair each job_id with its slice by matching the slices-without-extractions list.
			const pending = slices.filter(
				(s) => !extractionsStore.findBySlice(s.filename)
			);
			for (let i = 0; i < Math.min(jobIds.length, pending.length); i++) {
				const sliceFn = pending[i].filename;
				const jobId = jobIds[i];
				jobBySlice.set(sliceFn, jobId);
				jobsStore.track(projectId, jobId, () => {
					void extractionsStore.load(projectId);
					jobBySlice.delete(sliceFn);
					jobBySlice = new Map(jobBySlice);
				});
			}
			jobBySlice = new Map(jobBySlice);
			toastsStore.info(`Started ${jobIds.length} OCR job(s)`);
		} catch (e) {
			toastsStore.error(e instanceof Error ? e.message : 'Failed to start OCR (all)');
		}
	}

	async function viewMarkdown(sliceFilename: string) {
		viewerOpen = sliceFilename;
		viewerMarkdown = '';
		viewerLoading = true;
		try {
			viewerMarkdown = await getExtractionMarkdown(projectId, sliceFilename);
		} catch (e) {
			toastsStore.error(e instanceof Error ? e.message : 'Failed to load extraction');
			viewerOpen = null;
		} finally {
			viewerLoading = false;
		}
	}

	function closeViewer() {
		viewerOpen = null;
		viewerMarkdown = '';
	}

	function getJobStatus(sliceFilename: string) {
		const jobId = jobBySlice.get(sliceFilename);
		if (!jobId) return null;
		return jobsStore.get(jobId) ?? null;
	}
</script>

<div class="flex h-full flex-col">
	<div class="flex items-center justify-between border-b border-gray-200 px-6 py-3">
		<div>
			<h2 class="text-sm font-semibold text-gray-900">Extractions</h2>
			<p class="text-xs text-gray-500">
				{extractionsStore.rows.length} of {slices.length} slice(s) extracted
			</p>
		</div>
		<div class="flex gap-2">
			<Button onclick={() => void reloadAll()} variant="secondary">Refresh</Button>
			<Button onclick={() => void triggerOcrAll()}>OCR all pending</Button>
		</div>
	</div>

	{#if slicesLoading}
		<div class="p-6 text-sm text-gray-500">Loading slices…</div>
	{:else if slicesError}
		<div class="p-6 text-sm text-red-600">{slicesError}</div>
	{:else if slices.length === 0}
		<EmptyState message="No slices yet. Use the Slice tab to create them." />
	{:else}
		<div class="overflow-y-auto">
			<table class="min-w-full text-sm">
				<thead class="bg-gray-50">
					<tr>
						<th class="px-6 py-2 text-left font-medium text-gray-700">Slice</th>
						<th class="px-6 py-2 text-left font-medium text-gray-700">Pages</th>
						<th class="px-6 py-2 text-left font-medium text-gray-700">Status</th>
						<th class="px-6 py-2 text-right font-medium text-gray-700">Actions</th>
					</tr>
				</thead>
				<tbody class="divide-y divide-gray-100">
					{#each slices as slice (slice.filename)}
						{@const extraction = extractionsStore.findBySlice(slice.filename)}
						{@const job = getJobStatus(slice.filename)}
						<tr>
							<td class="px-6 py-2 font-mono text-xs">{slice.filename}</td>
							<td class="px-6 py-2 text-xs text-gray-600">{slice.page_range.join('–')}</td>
							<td class="px-6 py-2">
								{#if job}
									<JobStatusBadge status={job.status} progress={job.progress} />
									{#if job.status === 'running'}
										<div class="mt-1 w-32"><ProgressBar value={job.progress} /></div>
									{/if}
								{:else if extraction}
									<JobStatusBadge status="completed" />
									<div class="mt-0.5 text-[10px] text-gray-500">
										{extraction.pages}p · {extraction.latency_s.toFixed(1)}s · {extraction.model}
									</div>
								{:else}
									<span class="text-xs text-gray-400">—</span>
								{/if}
							</td>
							<td class="px-6 py-2 text-right">
								{#if extraction}
									<Button variant="secondary" onclick={() => void viewMarkdown(slice.filename)}>
										View
									</Button>
								{/if}
								{#if !extraction && !job}
									<Button onclick={() => void triggerOcr(slice.filename)}>OCR</Button>
								{/if}
							</td>
						</tr>
					{/each}
				</tbody>
			</table>
		</div>
	{/if}
</div>

{#if viewerOpen}
	<div
		class="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4"
		onclick={closeViewer}
		role="dialog"
	>
		<div
			class="max-h-[90vh] w-full max-w-4xl overflow-y-auto rounded-lg bg-white p-6 shadow-xl"
			onclick={(e) => e.stopPropagation()}
			role="document"
		>
			<div class="mb-4 flex items-center justify-between">
				<h3 class="font-mono text-sm text-gray-700">{viewerOpen}</h3>
				<Button variant="secondary" onclick={closeViewer}>Close</Button>
			</div>
			{#if viewerLoading}
				<div class="text-sm text-gray-500">Loading…</div>
			{:else}
				<MarkdownViewer markdown={viewerMarkdown} />
			{/if}
		</div>
	</div>
{/if}
```

- [ ] **Step 2: Verify it typechecks**

```bash
yarn check 2>&1 | tail -10
```

If the `Button` component's props don't quite match (e.g., its `variant` prop is named differently), adapt to its actual API. Same for `EmptyState`.

- [ ] **Step 3: Commit**

```bash
git add src/lib/components/ExtractionsPanel.svelte
git commit -m "chargesheet-ui/components: ExtractionsPanel (list + OCR triggers + markdown viewer)"
```

---

## Task 6: `PromptsPanel.svelte`

**Target repo:** `~/projects/lambe-haath/chargesheet-ui/`

**Files:**
- Create: `src/lib/components/PromptsPanel.svelte`

Mirror `ExtractionsPanel`'s structure but for the 5 prompts. Each row is one of the 5 known prompts; status comes from `promptOutputsStore` (if a row exists) or from `jobsStore` (if we kicked off a job for it).

- [ ] **Step 1: Create `src/lib/components/PromptsPanel.svelte`**

```svelte
<script lang="ts">
	import { onMount } from 'svelte';
	import { promptOutputsStore } from '$lib/stores/promptOutputs.svelte';
	import { jobsStore } from '$lib/stores/jobs.svelte';
	import { toastsStore } from '$lib/stores/toasts.svelte';
	import { extractionsStore } from '$lib/stores/extractions.svelte';
	import { KNOWN_PROMPTS, getPromptMarkdown } from '$lib/api/prompts';
	import type { KnownPromptName } from '$lib/api/prompts';
	import Button from './Button.svelte';
	import JobStatusBadge from './JobStatusBadge.svelte';
	import ProgressBar from './ProgressBar.svelte';
	import MarkdownViewer from './MarkdownViewer.svelte';

	let { projectId }: { projectId: string } = $props();

	const PROMPT_LABELS: Record<KnownPromptName, string> = {
		charge_memo_analysis: 'Charge memorandum analysis',
		imputation_scrutiny: 'Imputation scrutiny (no new charge)',
		time_chart: 'Time chart & flow chart',
		evidence_audit: 'Evidence audit (RUDs + witnesses)',
		objection_brief: 'Objection brief (compact)',
	};

	let viewerOpen = $state<KnownPromptName | null>(null);
	let viewerMarkdown = $state<string>('');
	let viewerLoading = $state(false);

	let jobByPrompt = $state<Map<KnownPromptName, string>>(new Map());

	async function reload() {
		await Promise.all([
			promptOutputsStore.load(projectId),
			extractionsStore.load(projectId),
		]);
	}

	onMount(() => {
		void reload();
	});

	function findOutput(name: KnownPromptName) {
		return promptOutputsStore.findByName(name);
	}

	function getJob(name: KnownPromptName) {
		const jid = jobByPrompt.get(name);
		if (!jid) return null;
		return jobsStore.get(jid) ?? null;
	}

	async function trigger(name: KnownPromptName) {
		try {
			const jobId = await promptOutputsStore.enqueue(projectId, name);
			jobByPrompt.set(name, jobId);
			jobByPrompt = new Map(jobByPrompt);
			jobsStore.track(projectId, jobId, () => {
				void promptOutputsStore.load(projectId);
				jobByPrompt.delete(name);
				jobByPrompt = new Map(jobByPrompt);
			});
		} catch (e) {
			toastsStore.error(e instanceof Error ? e.message : `Failed to start ${name}`);
		}
	}

	async function triggerAll() {
		try {
			const jobIds = await promptOutputsStore.enqueueAll(projectId);
			// We don't know which job_id maps to which prompt from /all; refresh
			// the list when each terminates by tracking all of them with a shared callback.
			for (const jobId of jobIds) {
				jobsStore.track(projectId, jobId, () => {
					void promptOutputsStore.load(projectId);
				});
			}
			toastsStore.info(`Started ${jobIds.length} prompt(s)`);
		} catch (e) {
			toastsStore.error(e instanceof Error ? e.message : 'Failed to start all prompts');
		}
	}

	async function viewMarkdown(name: KnownPromptName) {
		viewerOpen = name;
		viewerMarkdown = '';
		viewerLoading = true;
		try {
			viewerMarkdown = await getPromptMarkdown(projectId, name);
		} catch (e) {
			toastsStore.error(e instanceof Error ? e.message : 'Failed to load output');
			viewerOpen = null;
		} finally {
			viewerLoading = false;
		}
	}

	function closeViewer() {
		viewerOpen = null;
		viewerMarkdown = '';
	}
</script>

<div class="flex h-full flex-col">
	<div class="flex items-center justify-between border-b border-gray-200 px-6 py-3">
		<div>
			<h2 class="text-sm font-semibold text-gray-900">Defence Prompts</h2>
			<p class="text-xs text-gray-500">
				{promptOutputsStore.rows.length} of 5 prompts complete
			</p>
		</div>
		<div class="flex gap-2">
			<Button onclick={() => void reload()} variant="secondary">Refresh</Button>
			<Button onclick={() => void triggerAll()}>Run all</Button>
		</div>
	</div>

	<div class="overflow-y-auto">
		<table class="min-w-full text-sm">
			<thead class="bg-gray-50">
				<tr>
					<th class="px-6 py-2 text-left font-medium text-gray-700">Prompt</th>
					<th class="px-6 py-2 text-left font-medium text-gray-700">Status</th>
					<th class="px-6 py-2 text-right font-medium text-gray-700">Actions</th>
				</tr>
			</thead>
			<tbody class="divide-y divide-gray-100">
				{#each KNOWN_PROMPTS as name (name)}
					{@const output = findOutput(name)}
					{@const job = getJob(name)}
					<tr>
						<td class="px-6 py-2">
							<div class="font-medium text-gray-900">{PROMPT_LABELS[name]}</div>
							<div class="font-mono text-xs text-gray-500">{name}</div>
						</td>
						<td class="px-6 py-2">
							{#if job}
								<JobStatusBadge status={job.status} progress={job.progress} />
								{#if job.status === 'running'}
									<div class="mt-1 w-32"><ProgressBar value={job.progress} /></div>
								{/if}
							{:else if output}
								<JobStatusBadge status="completed" />
								<div class="mt-0.5 text-[10px] text-gray-500">
									{output.latency_s.toFixed(1)}s · {output.model}
								</div>
							{:else}
								<span class="text-xs text-gray-400">—</span>
							{/if}
						</td>
						<td class="px-6 py-2 text-right">
							{#if output}
								<Button variant="secondary" onclick={() => void viewMarkdown(name)}>View</Button>
							{/if}
							{#if !output && !job}
								<Button onclick={() => void trigger(name)}>Run</Button>
							{/if}
						</td>
					</tr>
				{/each}
			</tbody>
		</table>
	</div>
</div>

{#if viewerOpen}
	<div
		class="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4"
		onclick={closeViewer}
		role="dialog"
	>
		<div
			class="max-h-[90vh] w-full max-w-4xl overflow-y-auto rounded-lg bg-white p-6 shadow-xl"
			onclick={(e) => e.stopPropagation()}
			role="document"
		>
			<div class="mb-4 flex items-center justify-between">
				<h3 class="text-sm font-semibold text-gray-700">{PROMPT_LABELS[viewerOpen]}</h3>
				<Button variant="secondary" onclick={closeViewer}>Close</Button>
			</div>
			{#if viewerLoading}
				<div class="text-sm text-gray-500">Loading…</div>
			{:else}
				<MarkdownViewer markdown={viewerMarkdown} />
			{/if}
		</div>
	</div>
{/if}
```

- [ ] **Step 2: Commit**

```bash
yarn check 2>&1 | tail -10
git add src/lib/components/PromptsPanel.svelte
git commit -m "chargesheet-ui/components: PromptsPanel (5 prompts + run + view)"
```

---

## Task 7: Integrate tabs into project detail page

**Target repo:** `~/projects/lambe-haath/chargesheet-ui/`

**Files:**
- Modify: `src/routes/projects/[id]/+page.svelte`

Wrap the existing slicing UI in a "Slice" tab; add "Extractions" and "Prompts" tabs that mount the new panels.

- [ ] **Step 1: Read the current `+page.svelte`** to confirm where to inject tabs.

- [ ] **Step 2: Restructure as tabbed view**

Pseudocode of the new structure (keeping the existing `<script>` block intact for the slice keybindings):

```svelte
<script lang="ts">
	// ... existing imports (PdfViewer, SliceList, etc.) ...
	import Tabs from '$lib/components/Tabs.svelte';
	import ExtractionsPanel from '$lib/components/ExtractionsPanel.svelte';
	import PromptsPanel from '$lib/components/PromptsPanel.svelte';

	let { data }: { data: PageData } = $props();
	const project = $derived(data.project);

	let activeTab = $state<'slice' | 'extractions' | 'prompts'>('slice');

	// ... existing state + functions (trySubmit, onKeydown) ...
</script>

<svelte:window onkeydown={onKeydown} />

<div class="flex h-screen flex-col">
	<header class="..."> <!-- existing header --> </header>

	<Tabs
		tabs={[
			{ key: 'slice',       label: 'Slice' },
			{ key: 'extractions', label: 'Extractions' },
			{ key: 'prompts',     label: 'Prompts' },
		]}
		bind:active={activeTab}
	/>

	<div class="min-h-0 flex-1">
		{#if activeTab === 'slice'}
			<div class="grid h-full min-h-0" style="grid-template-columns: 3fr 2fr;">
				<!-- existing PDF viewer column -->
				<!-- existing slice list column -->
			</div>
		{:else if activeTab === 'extractions'}
			<ExtractionsPanel projectId={project.id} />
		{:else if activeTab === 'prompts'}
			<PromptsPanel projectId={project.id} />
		{/if}
	</div>
</div>
```

The existing slice keybindings (`onKeydown`) should still work when the Slice tab is active. Optionally guard them: `if (activeTab !== 'slice') return;` at the top of `onKeydown` so `[`/`]`/`n` don't fire on other tabs.

- [ ] **Step 3: Verify dev server still works**

```bash
cd ~/projects/lambe-haath/chargesheet-ui
yarn dev &
sleep 3
curl -s http://localhost:5173/ | head -5
kill %1 2>/dev/null
```

The output should contain `<!doctype html>` (SvelteKit's default shell) — confirms the build is intact.

- [ ] **Step 4: Commit**

```bash
yarn check 2>&1 | tail -10
git add src/routes/projects/[id]/+page.svelte
git commit -m "chargesheet-ui/projects/[id]: add tabbed UI (Slice | Extractions | Prompts)"
```

---

## Task 8: Manual end-to-end verification (with logos + agents running)

**Target repos:** all three (logos + agents + UI)

This is a smoke test that the whole stack works. No new code — just verification.

- [ ] **Step 1: Start the daemon with the real agents wired**

```bash
# Build logos
cd ~/projects/lambe-haath/logos
zig build

# Run from inside pdf-extraction-experiments so `python -m agents.*` resolves
cd ~/projects/chargesheets/pdf-extraction-experiments
set -a && source .env && set +a

# Use a clean temp data dir so we don't trash existing state
export CHARGESHEET_DATA_DIR="/tmp/lambe-smoke-$$"
mkdir -p "$CHARGESHEET_DATA_DIR"

~/projects/lambe-haath/logos/zig-out/bin/logos -p 7777 &
LOGOS_PID=$!
sleep 2

# Health check
curl -s http://localhost:7777/api/v1/health
```

- [ ] **Step 2: In another terminal, start the UI dev server**

```bash
cd ~/projects/lambe-haath/chargesheet-ui
yarn dev
# UI runs at http://localhost:5173/ and proxies /api → :7777
```

- [ ] **Step 3: Exercise the flow in the browser**

1. Open `http://localhost:5173/`
2. Create a new project, upload the Sandeep Goel Memo PDF (or any test PDF)
3. Open the project; on the Slice tab, create 4-6 slices (e.g., annexure-i.pdf with pages 1-3, annexure-ii.pdf with pages 4-10, etc. — names must match the convention so the prompt-agent gate works)
4. Submit slices
5. Switch to Extractions tab — click "OCR" on one slice, watch the badge change from "queued" → "running" → "completed" via polling
6. Click "View" — verify the rendered Markdown appears in the modal
7. Click "OCR all pending" — verify all remaining slices process
8. Switch to Prompts tab — click "Run" on `imputation_scrutiny` (needs only annexure-i + annexure-ii; smallest prompt)
9. Wait ~15-30 seconds for Gemini to produce output; "View" the result
10. Done.

If any step fails, note what failed and report DONE_WITH_CONCERNS with details. The full E2E flow needs:
- Real `GEMINI_API_KEY` in env
- All 4 prior plans merged
- The UI to be served by the logos daemon (or via vite dev proxy)

- [ ] **Step 4: Stop services + cleanup**

```bash
kill $LOGOS_PID 2>/dev/null
wait $LOGOS_PID 2>/dev/null || true
rm -rf "$CHARGESHEET_DATA_DIR"
```

- [ ] **Step 5: Document any issues** in the implementation report.

(No commit for this task — it's verification only. If you find issues that need code fixes, do them as new commits in subsequent steps.)

---

## Task 9: Final verification + cross-task review

- [ ] **Step 1: All tests green**

```bash
cd ~/projects/lambe-haath/chargesheet-ui
yarn test 2>&1 | tail -10
yarn check 2>&1 | tail -5
```

- [ ] **Step 2: Branch ready**

```bash
cd ~/projects/lambe-haath
git log --oneline main..feat/plan-f-chargesheet-ui
```

Expected commits: api schemas/types, api clients, stores, components (Tabs/Badge/Progress/Markdown), ExtractionsPanel, PromptsPanel, route integration. ~7-8 commits.

---

## What's next (deferred)

- **Plan F2**: SSE upgrade (replace polling with the existing `/api/v1/jobs/:id/stream` endpoint from Plan B). Cleaner UX, less daemon load.
- **Plan F3**: Mermaid rendering inside Markdown (for the `time_chart` prompt's flowchart blocks).
- **Plan E**: Stats endpoints + UI (the cost dashboard).
