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

<div class="flex h-full flex-col bg-card rounded-[14px] border border-line overflow-hidden">
	<!-- Header row -->
	<div class="flex items-center justify-between border-b border-line bg-panel px-4 py-[13px]">
		<div class="flex items-center gap-2">
			<span class="font-sans text-[10px] font-semibold uppercase tracking-[0.6px] text-ink-3">
				Slices
			</span>
			<span class="font-mono text-[11px] text-ink-3">· {slicesStore.slices.length}</span>
		</div>
		<Button variant="secondary" size="sm" onclick={addSlice} disabled={submitting}>
			+ Add slice
		</Button>
	</div>

	<!-- Slice rows -->
	<div class="flex-1 overflow-y-auto p-3">
		{#if slicesStore.slices.length === 0}
			<div class="rounded-[10px] border border-dashed border-line px-4 py-8 text-center font-sans text-[12.5px] font-medium text-ink-3">
				No slices yet. Press <span class="font-semibold text-navy">n</span> or click
				<span class="font-semibold text-navy">+ Add slice</span> to start.
			</div>
		{:else}
			<div class="space-y-2">
				{#each slicesStore.slices as slice (slice.id)}
					<SliceListItem {slice} errors={errorsBySlice[slice.id] ?? {}} disabled={submitting} />
				{/each}
			</div>
		{/if}
	</div>

	<!-- Save button footer -->
	<div class="border-t border-line px-[18px] py-[14px]">
		<button
			type="button"
			class="w-full rounded-[8px] bg-navy py-3 font-sans text-[12.5px] font-semibold text-white transition-colors hover:bg-navy-dk disabled:cursor-not-allowed disabled:opacity-40"
			onclick={onSubmit}
			disabled={!submittable}
		>
			{submitting
				? 'Submitting…'
				: slicesStore.slices.length > 0
					? `Save ${slicesStore.slices.length} slice${slicesStore.slices.length === 1 ? '' : 's'} & extract →`
					: 'Save slices'}
		</button>
	</div>
</div>
