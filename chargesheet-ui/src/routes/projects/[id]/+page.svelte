<script lang="ts">
	import { chargesheetUrl } from '$lib/api/projects';
	import PdfViewer from '$lib/components/PdfViewer.svelte';
	import SliceList from '$lib/components/SliceList.svelte';
	import ProducedSlices from '$lib/components/ProducedSlices.svelte';
	import Tabs from '$lib/components/Tabs.svelte';
	import ExtractionsPanel from '$lib/components/ExtractionsPanel.svelte';
	import PromptsPanel from '$lib/components/PromptsPanel.svelte';
	import { pdfStore } from '$lib/stores/pdf.svelte';
	import { slicesStore } from '$lib/stores/slices.svelte';
	import { toastsStore } from '$lib/stores/toasts.svelte';
	import { canSubmitAll } from '$lib/utils/validation';
	import type { PageData } from './$types';

	let { data }: { data: PageData } = $props();
	const project = $derived(data.project);

	let submitting = $state(false);
	let producedReloadKey = $state(0);
	let activeTab = $state<'slice' | 'extractions' | 'prompts'>('slice');

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
		if (activeTab !== 'slice') return;
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
</script>

<svelte:window onkeydown={onKeydown} />

<div class="flex h-screen flex-col">
	<header class="flex items-baseline justify-between border-b border-gray-200 bg-white px-6 py-3">
		<div class="flex items-baseline gap-4">
			<a href="/" class="text-sm text-blue-600 hover:underline">← Projects</a>
			<h1 class="text-lg font-semibold text-gray-900">{project.name}</h1>
			{#if project.description}
				<p class="line-clamp-1 max-w-md text-sm text-gray-500">{project.description}</p>
			{/if}
		</div>
		<div class="text-xs text-gray-500">
			{project.chargesheet.filename} · {project.chargesheet.page_count} pages ·
			<span class="text-gray-400">[/] set range · n add · ⌘↩ submit</span>
		</div>
	</header>

	<Tabs
		tabs={[
			{ key: 'slice', label: 'Slice' },
			{ key: 'extractions', label: 'Extractions' },
			{ key: 'prompts', label: 'Prompts' },
		]}
		bind:active={activeTab}
	/>

	<div class="min-h-0 flex-1">
		{#if activeTab === 'slice'}
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
				<div class="flex min-h-0 flex-col border-l border-gray-200 bg-white">
					<div class="flex min-h-0 flex-1 flex-col">
						<SliceList onSubmit={trySubmit} {submitting} />
					</div>
					<ProducedSlices projectId={project.id} reloadKey={producedReloadKey} />
				</div>
			</div>
		{:else if activeTab === 'extractions'}
			<ExtractionsPanel projectId={project.id} />
		{:else if activeTab === 'prompts'}
			<PromptsPanel projectId={project.id} />
		{/if}
	</div>
</div>
