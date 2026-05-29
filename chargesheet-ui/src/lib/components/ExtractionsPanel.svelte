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

	/** Humanize a slice filename to an uppercase label, e.g. "annexure-i.pdf" → "ANNEXURE-I" */
	function humanizeSlice(filename: string): string {
		return filename.replace(/\.pdf$/i, '').replace(/[-_]/g, ' ').toUpperCase();
	}

	const doneCount = $derived(extractionsStore.rows.length);
	const runningCount = $derived(
		slices.filter((s) => {
			const job = getJobStatus(s.filename);
			return job?.status === 'running' || job?.status === 'queued';
		}).length
	);
</script>

<div class="flex h-full flex-col bg-card">
	{#if slicesLoading}
		<div class="p-6 font-sans text-[13px] text-ink-2">Loading slices…</div>
	{:else if slicesError}
		<div class="p-6 font-sans text-[13px] text-err">{slicesError}</div>
	{:else if slices.length === 0}
		<EmptyState title="No slices yet" description="Use the Slice stage to create them." />
	{:else}
		<div class="flex-1 overflow-y-auto">
			<table class="min-w-full border-collapse">
				<thead class="sticky top-0 z-10 bg-panel">
					<tr>
						<th class="border-b border-line px-6 py-[11px] text-left font-sans text-[10px] font-semibold uppercase tracking-[0.6px] text-ink-3">Slice</th>
						<th class="border-b border-line px-6 py-[11px] text-left font-sans text-[10px] font-semibold uppercase tracking-[0.6px] text-ink-3">Pages</th>
						<th class="border-b border-line px-6 py-[11px] text-left font-sans text-[10px] font-semibold uppercase tracking-[0.6px] text-ink-3">Status</th>
						<th class="border-b border-line px-6 py-[11px] text-right font-sans text-[10px] font-semibold uppercase tracking-[0.6px] text-ink-3"></th>
					</tr>
				</thead>
				<tbody>
					{#each slices as slice (slice.filename)}
						{@const extraction = extractionsStore.findBySlice(slice.filename)}
						{@const job = getJobStatus(slice.filename)}
						<tr class="border-t border-line-2 bg-card">
							<td class="px-6 py-[13px]">
								<div class="min-w-0">
									<div class="truncate font-serif text-[14px] font-medium text-ink">
										{humanizeSlice(slice.filename)}
									</div>
									<div class="truncate font-mono text-[11px] text-ink-3">{slice.filename}</div>
								</div>
							</td>
							<td class="px-6 py-[13px] font-mono text-[12px] text-ink-2">
								{slice.page_range[0]}–{slice.page_range[1]}
							</td>
							<td class="px-6 py-[13px]">
								{#if job}
									<JobStatusBadge status={job.status} progress={job.progress} />
									{#if job.status === 'running'}
										<div class="mt-1.5 w-32"><ProgressBar value={job.progress} tone="navy" /></div>
									{/if}
								{:else if extraction}
									<div class="font-mono text-[11px] text-ink-3">
										{extraction.pages}p · {extraction.latency_s.toFixed(1)}s · {extraction.model}
									</div>
								{:else}
									<span class="font-sans text-[11px] text-ink-3">—</span>
								{/if}
							</td>
							<td class="px-6 py-[13px] text-right">
								{#if extraction}
									<Button
										variant="secondary"
										size="sm"
										onclick={() => void viewMarkdown(slice.filename)}
									>View text</Button>
								{/if}
								{#if !extraction && !job}
									<Button
										variant="primary"
										size="sm"
										onclick={() => void triggerOcr(slice.filename)}
									>Run OCR</Button>
								{/if}
							</td>
						</tr>
					{/each}
				</tbody>
			</table>
		</div>

		<div class="border-t border-line bg-panel px-6 py-[11px] font-sans font-medium text-[11.5px] text-ink-2">
			{doneCount} of {slices.length} extracted{runningCount > 0 ? ` · ${runningCount} running` : ''}
		</div>
	{/if}
</div>

{#if viewerOpen}
	<!-- Backdrop -->
	<div
		class="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-ink/40 backdrop-blur-sm"
		onclick={closeViewer}
		onkeydown={(e) => e.key === 'Escape' && closeViewer()}
		role="dialog"
		aria-modal="true"
		tabindex="-1"
	>
		<!-- Modal panel -->
		<div
			class="relative mx-auto my-12 flex max-h-[80vh] w-full max-w-3xl flex-col rounded-[14px] border border-line bg-card shadow-[0_30px_60px_rgba(40,35,25,0.25)]"
			onclick={(e) => e.stopPropagation()}
			role="document"
		>
			<!-- Header -->
			<div class="flex flex-shrink-0 items-center justify-between border-b border-line px-6 py-4">
				<h3 class="font-serif text-[18px] font-semibold text-ink">{viewerOpen}</h3>
				<button
					type="button"
					onclick={closeViewer}
					aria-label="Close"
					class="rounded px-2 py-1 text-[20px] leading-none text-ink-3 transition-colors hover:bg-panel hover:text-ink focus:outline-none focus:ring-2 focus:ring-navy/30"
				>×</button>
			</div>
			<!-- Content -->
			<div class="flex-1 overflow-y-auto px-8 py-6">
				{#if viewerLoading}
					<div class="font-sans text-[13px] text-ink-2">Loading…</div>
				{:else}
					<MarkdownViewer markdown={viewerMarkdown} class="prose-a:text-navy prose-code:rounded prose-code:bg-panel prose-code:px-1 prose-code:font-mono prose-code:text-[12px]" />
				{/if}
			</div>
		</div>
	</div>
{/if}
