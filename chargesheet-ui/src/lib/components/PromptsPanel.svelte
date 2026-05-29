<script lang="ts">
	import { onMount } from 'svelte';
	import { promptOutputsStore } from '$lib/stores/promptOutputs.svelte';
	import { jobsStore } from '$lib/stores/jobs.svelte';
	import { toastsStore } from '$lib/stores/toasts.svelte';
	import { extractionsStore } from '$lib/stores/extractions.svelte';
	import { KNOWN_PROMPTS, getPromptMarkdown } from '$lib/api/prompts';
	import type { KnownPromptName } from '$lib/api/prompts';
	import { listProjectJobs } from '$lib/api/jobs';
	import Button from './Button.svelte';
	import JobStatusBadge from './JobStatusBadge.svelte';
	import ProgressBar from './ProgressBar.svelte';
	import MarkdownViewer from './MarkdownViewer.svelte';
	import EmptyState from './EmptyState.svelte';

	let { projectId }: { projectId: string } = $props();

	const PROMPT_LABELS: Record<KnownPromptName, string> = {
		charge_memo_analysis: 'Charge memorandum analysis',
		imputation_scrutiny:  'Imputation scrutiny (no new charge)',
		time_chart:           'Time chart & flow chart',
		evidence_audit:       'Evidence audit (RUDs + witnesses)',
		objection_brief:      'Objection brief (compact)',
	};

	const PROMPT_DESCRIPTIONS: Record<KnownPromptName, string> = {
		charge_memo_analysis: 'Analyses charges framed, counts alleged, and supporting sections.',
		imputation_scrutiny:  'Checks if any new charge is imputed beyond the original FIR.',
		time_chart:           'Constructs a chronological flow of events from the chargesheet.',
		evidence_audit:       'Audits RUDs cited, witnesses listed, and gaps in the record.',
		objection_brief:      'Drafts a compact objection brief for discharge arguments.',
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
		void hydrate();
		return () => {
			jobsStore.stopAll();
		};
	});

	async function hydrate() {
		await reload();
		// Re-attach polling for any running prompt jobs on the daemon (survives refresh).
		try {
			const running = await listProjectJobs(projectId, 'running');
			for (const j of running) {
				if (j.type !== 'prompt') continue;
				const payload = j.payload as { prompt_name?: string };
				const pn = payload?.prompt_name as KnownPromptName | undefined;
				if (!pn || !KNOWN_PROMPTS.includes(pn)) continue;
				// Only track if we don't already have a job for this prompt.
				if (jobByPrompt.has(pn)) continue;
				jobByPrompt.set(pn, j.job_id);
				jobsStore.track(projectId, j.job_id, () => {
					void promptOutputsStore.load(projectId);
					jobByPrompt.delete(pn);
					jobByPrompt = new Map(jobByPrompt);
				});
			}
			jobByPrompt = new Map(jobByPrompt);
		} catch (e) {
			// Non-fatal — UI still works without recovery; just no auto-resume.
			console.warn('jobs hydrate failed', e);
		}
	}

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
			// /jobs/prompt/all doesn't tell us which job_id is which prompt; track all
			// with a shared callback that just reloads the outputs list on each terminal.
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

<!-- Two-column grid: 0.92fr left (prompt list) / 1.18fr right (output viewer) -->
<div class="grid h-full overflow-hidden" style="grid-template-columns: 0.92fr 1.18fr; gap: 0;">

	<!-- Left column: prompt list -->
	<div class="overflow-y-auto border-r border-line bg-panel p-5">
		<div class="space-y-[10px]">
			{#each KNOWN_PROMPTS as name (name)}
				{@const output = findOutput(name)}
				{@const job = getJob(name)}
				{@const isViewing = viewerOpen === name}
				<div
					class="rounded-[11px] border bg-card p-4 transition-all duration-150
						{isViewing && output
							? 'border-navy bg-navy-soft/30 shadow-[0_2px_8px_rgba(30,58,95,0.08)]'
							: 'border-line hover:shadow-[0_6px_20px_rgba(40,35,25,0.10)] hover:-translate-y-px'}"
				>
					<div class="flex items-start gap-3">
						<!-- Title column -->
						<div class="min-w-0 flex-1">
							<div class="font-serif text-[16px] font-semibold text-ink leading-tight">
								{PROMPT_LABELS[name]}
							</div>
							<div class="mt-1 font-serif text-[13px] font-normal text-ink-2 leading-[1.4]">
								{PROMPT_DESCRIPTIONS[name]}
							</div>
						</div>

						<!-- Action area -->
						<div class="shrink-0">
							{#if job}
								<div>
									<JobStatusBadge status={job.status} progress={job.progress} />
									{#if job.status === 'running'}
										<div class="mt-2 w-24"><ProgressBar value={job.progress} tone="navy" /></div>
									{/if}
								</div>
							{:else if output}
								<Button
									variant={isViewing ? 'primary' : 'secondary'}
									size="sm"
									onclick={() => void viewMarkdown(name)}
								>{isViewing ? 'Viewing' : 'View'}</Button>
							{:else}
								<Button variant="primary" size="sm" onclick={() => void trigger(name)}>Run</Button>
							{/if}
						</div>
					</div>

					{#if output && !job}
						<div class="mt-2.5 font-sans text-[11px] text-ink-3">
							{output.latency_s.toFixed(1)}s · {output.model}
						</div>
					{/if}
				</div>
			{/each}
		</div>
	</div>

	<!-- Right column: output viewer -->
	<div class="overflow-y-auto bg-paper p-[26px]">
		{#if viewerOpen && (findOutput(viewerOpen) || viewerLoading)}
			<!-- Navy-soft callout header -->
			<div class="mb-4 rounded-r-[8px] border-l-4 border-navy bg-navy-soft px-4 py-3">
				<div class="font-sans text-[10px] font-semibold uppercase tracking-[0.6px] text-navy">
					Suggested Objection
				</div>
				<div class="mt-1 font-serif text-[18px] font-semibold text-ink leading-tight">
					{PROMPT_LABELS[viewerOpen]}
				</div>
			</div>

			<div class="rounded-[14px] border border-line bg-card p-6 shadow-[0_1px_2px_rgba(40,35,25,0.04)]">
				{#if viewerLoading}
					<div class="font-sans text-[13px] text-ink-2">Loading…</div>
				{:else}
					<div class="prose prose-sm max-w-none">
						<MarkdownViewer markdown={viewerMarkdown} />
					</div>
				{/if}
			</div>
		{:else}
			<div class="flex h-full flex-col items-center justify-center">
				<EmptyState
					title="Select a prompt"
					description="Click View on a completed prompt to read its analysis here."
				/>
			</div>
		{/if}
	</div>
</div>
