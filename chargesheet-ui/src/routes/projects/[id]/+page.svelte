<script lang="ts">
	import { chargesheetUrl } from '$lib/api/projects';
	import PdfViewer from '$lib/components/PdfViewer.svelte';
	import SliceList from '$lib/components/SliceList.svelte';
	import ProducedSlices from '$lib/components/ProducedSlices.svelte';
	import PipelineRail from '$lib/components/PipelineRail.svelte';
	import StageHeader from '$lib/components/StageHeader.svelte';
	import ExtractionsPanel from '$lib/components/ExtractionsPanel.svelte';
	import PromptsPanel from '$lib/components/PromptsPanel.svelte';
	import StatsPanel from '$lib/components/StatsPanel.svelte';
	import { pdfStore } from '$lib/stores/pdf.svelte';
	import { slicesStore } from '$lib/stores/slices.svelte';
	import { extractionsStore } from '$lib/stores/extractions.svelte';
	import { promptOutputsStore } from '$lib/stores/promptOutputs.svelte';
	import { toastsStore } from '$lib/stores/toasts.svelte';
	import { canSubmitAll } from '$lib/utils/validation';
	import type { PageData } from './$types';

	type Stage = 'slice' | 'extract' | 'analyze' | 'review';

	// Known prompt count — there are 5 known prompts in KNOWN_PROMPTS (PromptsPanel)
	const KNOWN_PROMPT_COUNT = 5;

	let { data }: { data: PageData } = $props();
	const project = $derived(data.project);

	let submitting = $state(false);
	let producedReloadKey = $state(0);
	let activeStage = $state<Stage>('slice');

	async function trySubmit() {
		if (submitting || pdfStore.pageCount === null) return;
		if (!canSubmitAll(slicesStore.slices, pdfStore.pageCount)) return;
		submitting = true;
		try {
			await slicesStore.submitAll(project.id, pdfStore.pageCount);
			const failed = slicesStore.slices.filter((s) => s.status === 'failed');
			if (failed.length === 0) {
				toastsStore.success('All slices saved');
			} else {
				toastsStore.error(`${failed.length} slice(s) failed`);
			}
			producedReloadKey += 1;
		} catch (e) {
			toastsStore.error(e instanceof Error ? e.message : 'Submission failed');
		} finally {
			submitting = false;
		}
	}

	function onKeydown(e: KeyboardEvent) {
		if (activeStage !== 'slice') return;
		const tgt = e.target as HTMLElement | null;
		if (tgt) {
			const tag = tgt.tagName;
			if (tag === 'INPUT' || tag === 'TEXTAREA' || tgt.isContentEditable) return;
		}
		if (e.key === '[') {
			if (slicesStore.lastEditedId !== null) {
				slicesStore.update(slicesStore.lastEditedId, { startPage: pdfStore.currentPage });
			}
		} else if (e.key === ']') {
			if (slicesStore.lastEditedId !== null) {
				slicesStore.update(slicesStore.lastEditedId, { endPage: pdfStore.currentPage });
			}
		} else if (e.key === 'n' && !e.metaKey && !e.ctrlKey && !e.altKey) {
			const p = pdfStore.currentPage;
			slicesStore.add({ startPage: p, endPage: p, filename: '' });
		} else if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
			e.preventDefault();
			void trySubmit();
		}
	}

	// Stage progress — pragmatic V1 fractions derived from store data
	const stageProgress = $derived.by((): Record<Stage, number> => {
		const sliceCount = slicesStore.slices.length;
		const extractCount = extractionsStore.rows.length;

		const sliceProg = sliceCount > 0 ? 1 : 0;
		const extractProg =
			sliceCount > 0
				? Math.min(1, extractCount / sliceCount)
				: 0;
		const analyzeProg = Math.min(1, promptOutputsStore.rows.length / KNOWN_PROMPT_COUNT);

		return {
			slice: sliceProg,
			extract: extractProg,
			analyze: analyzeProg,
			review: 0,
		};
	});

	// Stage header props — maps active stage to title/sub/actions
	const stageHeaderProps = $derived.by(() => {
		switch (activeStage) {
			case 'slice':
				return {
					title: 'Slice',
					sub: 'Identify annexures and RUDs. Save to start OCR.',
					primaryLabel: 'Save & extract →',
					onPrimary: trySubmit,
					primaryDisabled: submitting || !canSubmitAll(slicesStore.slices, pdfStore.pageCount ?? 0),
				};
			case 'extract':
				return {
					title: 'Extract',
					sub: 'Run Gemini OCR on each sliced PDF to produce structured markdown.',
					primaryLabel: 'OCR all pending',
					onPrimary: () => void extractionsStore.enqueueAll(project.id),
				};
			case 'analyze':
				return {
					title: 'Analyze',
					sub: 'Run five defence-analysis prompts against the extracted text.',
					primaryLabel: 'Run all',
					onPrimary: () => void promptOutputsStore.enqueueAll(project.id),
				};
			case 'review':
				return {
					title: 'Review',
					sub: 'Tokens, cost, and latency across this matter.',
					primaryLabel: 'Export brief',
					onPrimary: () => {},
					primaryDisabled: true,
				};
		}
	});
</script>

<svelte:window onkeydown={onKeydown} />

<div class="flex h-screen w-screen overflow-hidden bg-paper">
	<PipelineRail
		{project}
		stage={activeStage}
		onStage={(s) => (activeStage = s)}
		{stageProgress}
	/>

	<div class="flex min-w-0 flex-1 flex-col overflow-hidden">
		<StageHeader {...stageHeaderProps} />

		<div class="flex-1 overflow-auto">
			{#if activeStage === 'slice'}
				<div class="grid h-full min-h-0" style="grid-template-columns: 3fr 2fr;">
					<div class="min-h-0">
						<PdfViewer
							pdfUrl={chargesheetUrl(project.id)}
							bind:currentPage={pdfStore.currentPage}
							bind:pageCount={pdfStore.pageCount}
							bind:loading={pdfStore.loading}
							bind:error={pdfStore.error}
						/>
					</div>
					<div class="flex min-h-0 flex-col border-l border-line bg-card">
						<div class="flex min-h-0 flex-1 flex-col">
							<SliceList onSubmit={trySubmit} {submitting} />
						</div>
						<ProducedSlices projectId={project.id} reloadKey={producedReloadKey} />
					</div>
				</div>
			{:else if activeStage === 'extract'}
				<div class="px-[40px] py-[26px]">
					<ExtractionsPanel projectId={project.id} />
				</div>
			{:else if activeStage === 'analyze'}
				<div class="h-full">
					<PromptsPanel projectId={project.id} />
				</div>
			{:else if activeStage === 'review'}
				<div class="px-[40px] py-[26px]">
					<StatsPanel projectId={project.id} />
				</div>
			{/if}
		</div>
	</div>
</div>
