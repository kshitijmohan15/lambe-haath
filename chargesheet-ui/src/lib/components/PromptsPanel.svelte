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
		imputation_scrutiny:  'Imputation scrutiny (no new charge)',
		time_chart:           'Time chart & flow chart',
		evidence_audit:       'Evidence audit (RUDs + witnesses)',
		objection_brief:      'Objection brief (compact)',
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
		return () => {
			jobsStore.stopAll();
		};
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

<div class="flex h-full flex-col">
	<div class="flex items-center justify-between border-b border-gray-200 px-6 py-3">
		<div>
			<h2 class="text-sm font-semibold text-gray-900">Defence Prompts</h2>
			<p class="text-xs text-gray-500">
				{promptOutputsStore.rows.length} of 5 prompts complete
			</p>
		</div>
		<div class="flex gap-2">
			<Button variant="secondary" size="sm" onclick={() => void reload()}>Refresh</Button>
			<Button variant="primary" size="sm" onclick={() => void triggerAll()}>Run all</Button>
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
								<Button variant="secondary" size="sm" onclick={() => void viewMarkdown(name)}>View</Button>
							{/if}
							{#if !output && !job}
								<Button variant="primary" size="sm" onclick={() => void trigger(name)}>Run</Button>
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
		onkeydown={(e) => e.key === 'Escape' && closeViewer()}
		role="dialog"
		aria-modal="true"
		tabindex="-1"
	>
		<div
			class="max-h-[90vh] w-full max-w-4xl overflow-y-auto rounded-lg bg-white p-6 shadow-xl"
			onclick={(e) => e.stopPropagation()}
			role="document"
		>
			<div class="mb-4 flex items-center justify-between">
				<h3 class="text-sm font-semibold text-gray-700">{PROMPT_LABELS[viewerOpen]}</h3>
				<Button variant="secondary" size="sm" onclick={closeViewer}>Close</Button>
			</div>
			{#if viewerLoading}
				<div class="text-sm text-gray-500">Loading…</div>
			{:else}
				<MarkdownViewer markdown={viewerMarkdown} />
			{/if}
		</div>
	</div>
{/if}
