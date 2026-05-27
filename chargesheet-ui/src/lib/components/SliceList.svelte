<script lang="ts">
	import { slicesStore } from '$lib/stores/slices.svelte';
	import { pdfStore } from '$lib/stores/pdf.svelte';
	import { canSubmitAll, validateSlice, type SliceFieldErrors } from '$lib/utils/validation';
	import Button from './Button.svelte';
	import SliceListItem from './SliceListItem.svelte';

	interface Props {
		onSubmit: () => void;
		submitting: boolean;
	}

	let { onSubmit, submitting }: Props = $props();

	const errorsBySlice = $derived.by((): Record<string, SliceFieldErrors> => {
		const pageCount = pdfStore.pageCount ?? 0;
		const out: Record<string, SliceFieldErrors> = {};
		for (const s of slicesStore.slices) {
			const others = slicesStore.slices.filter((o) => o.id !== s.id);
			out[s.id] = pageCount > 0 ? validateSlice(s, pageCount, others) : {};
		}
		return out;
	});

	const submittable = $derived(
		!submitting &&
			pdfStore.pageCount !== null &&
			canSubmitAll(slicesStore.slices, pdfStore.pageCount)
	);

	function addSlice() {
		const page = pdfStore.currentPage;
		slicesStore.add({ startPage: page, endPage: page, filename: '' });
	}
</script>

<div class="flex h-full flex-col">
	<div class="flex items-baseline justify-between border-b border-gray-200 px-4 py-3">
		<h2 class="text-sm font-semibold text-gray-800">
			Slices <span class="text-gray-400">({slicesStore.slices.length})</span>
		</h2>
		<Button variant="secondary" size="sm" onclick={addSlice} disabled={submitting}>
			+ Add slice
		</Button>
	</div>

	<div class="flex-1 space-y-2 overflow-y-auto px-4 py-3">
		{#if slicesStore.slices.length === 0}
			<div class="rounded border border-dashed border-gray-300 px-4 py-8 text-center text-sm text-gray-500">
				No slices yet. Press <span class="font-medium">n</span> or click
				<span class="font-medium">+ Add slice</span> to start.
			</div>
		{:else}
			{#each slicesStore.slices as slice (slice.id)}
				<SliceListItem {slice} errors={errorsBySlice[slice.id] ?? {}} disabled={submitting} />
			{/each}
		{/if}
	</div>

	<div class="border-t border-gray-200 px-4 py-3">
		<Button variant="primary" full onclick={onSubmit} disabled={!submittable}>
			{submitting
				? 'Submitting…'
				: slicesStore.slices.length > 0
					? `Save ${slicesStore.slices.length} slice${slicesStore.slices.length === 1 ? '' : 's'}`
					: 'Save slices'}
		</Button>
	</div>
</div>
