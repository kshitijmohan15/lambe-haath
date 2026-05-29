<script lang="ts">
	import { onMount } from 'svelte';
	import { extractionsStore } from '$lib/stores/extractions.svelte';
	import { jobsStore } from '$lib/stores/jobs.svelte';
	import { toastsStore } from '$lib/stores/toasts.svelte';
	import { listSlices } from '$lib/api/slices';
	import { getExtractionMarkdown } from '$lib/api/extractions';
	import { listProjectJobs } from '$lib/api/jobs';
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

	let viewerOpen = $state<string | null>(null);
	let viewerMarkdown = $state<string>('');
	let viewerLoading = $state(false);

	// slice filename → job_id for jobs we kicked off in this session
	let jobBySlice = $state<Map<string, string>>(new Map());

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
		await Promise.all([loadSlices(), extractionsStore.load(projectId)]);
	}

	onMount(() => {
		void hydrate();
		return () => {
			jobsStore.stopAll();
		};
	});

	async function hydrate() {
		await reloadAll();
		// Re-attach polling for any running OCR jobs on the daemon (survives refresh).
		try {
			const running = await listProjectJobs(projectId, 'running');
			for (const j of running) {
				if (j.type !== 'ocr') continue;
				const payload = j.payload as { slice_filename?: string };
				const sf = payload?.slice_filename;
				if (!sf) continue;
				// Only track if we don't already have a job for this slice.
				if (jobBySlice.has(sf)) continue;
				jobBySlice.set(sf, j.job_id);
				jobsStore.track(projectId, j.job_id, () => {
					void extractionsStore.load(projectId);
					jobBySlice.delete(sf);
					jobBySlice = new Map(jobBySlice);
				});
			}
			jobBySlice = new Map(jobBySlice);
		} catch (e) {
			// Non-fatal — UI still works without recovery; just no auto-resume.
			console.warn('jobs hydrate failed', e);
		}
	}

	async function triggerOcr(sliceFilename: string) {
		try {
			const jobId = await extractionsStore.enqueue(projectId, sliceFilename);
			jobBySlice.set(sliceFilename, jobId);
			jobBySlice = new Map(jobBySlice);
			jobsStore.track(projectId, jobId, () => {
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
			// Snapshot the pending list BEFORE enqueueing so order matches the
			// daemon's LEFT JOIN ordering (filename ASC). The daemon uses
			// ORDER BY filename ASC on `slices` to pair job_ids with slices.
			const pending = slices
				.filter((s) => !extractionsStore.findBySlice(s.filename))
				.slice()
				.sort((a, b) => a.filename.localeCompare(b.filename));

			const jobIds = await extractionsStore.enqueueAll(projectId);

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
			<Button variant="secondary" size="sm" onclick={() => void reloadAll()}>Refresh</Button>
			<Button variant="primary" size="sm" onclick={() => void triggerOcrAll()}>OCR all pending</Button>
		</div>
	</div>

	{#if slicesLoading}
		<div class="p-6 text-sm text-gray-500">Loading slices…</div>
	{:else if slicesError}
		<div class="p-6 text-sm text-red-600">{slicesError}</div>
	{:else if slices.length === 0}
		<EmptyState title="No slices yet" description="Use the Slice tab to create them." />
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
							<td class="px-6 py-2 text-xs text-gray-600">
								{slice.page_range[0]}–{slice.page_range[1]}
							</td>
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
									<Button
										variant="secondary"
										size="sm"
										onclick={() => void viewMarkdown(slice.filename)}
									>
										View
									</Button>
								{/if}
								{#if !extraction && !job}
									<Button
										variant="primary"
										size="sm"
										onclick={() => void triggerOcr(slice.filename)}
									>
										OCR
									</Button>
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
				<h3 class="font-mono text-sm text-gray-700">{viewerOpen}</h3>
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
