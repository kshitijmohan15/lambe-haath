<script lang="ts">
	import type { LocalSlice } from '$lib/api/types';
	import { slicesStore } from '$lib/stores/slices.svelte';
	import { pdfStore } from '$lib/stores/pdf.svelte';
	import type { SliceFieldErrors } from '$lib/utils/validation';
	import TextInput from './TextInput.svelte';
	import NumberInput from './NumberInput.svelte';

	interface Props {
		slice: LocalSlice;
		errors: SliceFieldErrors;
		disabled: boolean;
	}

	let { slice, errors, disabled }: Props = $props();

	const submitting = $derived(slice.status === 'submitting');
	const done = $derived(slice.status === 'completed');
	const failed = $derived(slice.status === 'failed');
	const locked = $derived(disabled || submitting || done);

	function setStartPage(e: Event) {
		const n = Number((e.currentTarget as HTMLInputElement).value);
		if (Number.isFinite(n)) slicesStore.update(slice.id, { startPage: n });
	}
	function setEndPage(e: Event) {
		const n = Number((e.currentTarget as HTMLInputElement).value);
		if (Number.isFinite(n)) slicesStore.update(slice.id, { endPage: n });
	}
	function setFilename(e: Event) {
		const v = (e.currentTarget as HTMLInputElement).value;
		slicesStore.update(slice.id, { filename: v });
	}

	function useCurrentForStart() {
		slicesStore.update(slice.id, { startPage: pdfStore.currentPage });
	}
	function useCurrentForEnd() {
		slicesStore.update(slice.id, { endPage: pdfStore.currentPage });
	}

	function removeMe() {
		slicesStore.remove(slice.id);
	}
</script>

<div
	class="rounded-[10px] border px-3 py-2.5 transition-colors cursor-default
		{done
			? 'border-ok/40 bg-[rgba(79,122,82,0.06)]'
			: failed
				? 'border-err/40 bg-[rgba(162,59,46,0.06)]'
				: 'border-line-2 bg-card hover:bg-panel'}"
>
	<!-- Status icon + form fields row -->
	<div class="flex items-start gap-2">
		<!-- Status icon -->
		<div class="mt-1.5 w-5 flex-shrink-0" aria-hidden="true">
			{#if submitting}
				<svg class="h-4 w-4 animate-spin text-ink-3" viewBox="0 0 24 24" fill="none">
					<circle cx="12" cy="12" r="9" stroke="currentColor" stroke-width="2" opacity="0.25" />
					<path d="M21 12a9 9 0 0 1-9 9" stroke="currentColor" stroke-width="2" />
				</svg>
			{:else if done}
				<svg class="h-4 w-4 text-ok" viewBox="0 0 20 20" fill="currentColor">
					<path
						fill-rule="evenodd"
						d="M16.7 5.3a1 1 0 0 1 0 1.4l-7 7a1 1 0 0 1-1.4 0l-3-3a1 1 0 1 1 1.4-1.4L9 11.6l6.3-6.3a1 1 0 0 1 1.4 0Z"
						clip-rule="evenodd"
					/>
				</svg>
			{:else if failed}
				<span title={slice.error ?? 'Failed'} class="text-err">
					<svg class="h-4 w-4" viewBox="0 0 20 20" fill="currentColor">
						<path
							fill-rule="evenodd"
							d="M10 18a8 8 0 1 1 0-16 8 8 0 0 1 0 16ZM8.7 7.3a1 1 0 0 0-1.4 1.4L8.6 10l-1.3 1.3a1 1 0 0 0 1.4 1.4L10 11.4l1.3 1.3a1 1 0 0 0 1.4-1.4L11.4 10l1.3-1.3a1 1 0 0 0-1.4-1.4L10 8.6 8.7 7.3Z"
							clip-rule="evenodd"
						/>
					</svg>
				</span>
			{/if}
		</div>

		<!-- Fields -->
		<div class="grid flex-1 grid-cols-[1fr_auto_1fr_auto] items-end gap-1.5">
			<div class="col-span-1">
				<NumberInput
					label="Start"
					value={slice.startPage}
					min={1}
					disabled={locked}
					error={errors.startPage}
					oninput={setStartPage}
				/>
			</div>
			<button
				type="button"
				class="self-end rounded-[6px] border border-line px-2 py-1 font-sans text-xs text-ink-2 hover:bg-panel disabled:opacity-40 transition-colors"
				onclick={useCurrentForStart}
				disabled={locked}
				title="Use current PDF page"
			>
				↧
			</button>
			<div class="col-span-1">
				<NumberInput
					label="End"
					value={slice.endPage}
					min={1}
					disabled={locked}
					error={errors.endPage}
					oninput={setEndPage}
				/>
			</div>
			<button
				type="button"
				class="self-end rounded-[6px] border border-line px-2 py-1 font-sans text-xs text-ink-2 hover:bg-panel disabled:opacity-40 transition-colors"
				onclick={useCurrentForEnd}
				disabled={locked}
				title="Use current PDF page"
			>
				↧
			</button>

			<div class="col-span-4">
				<TextInput
					label="Filename"
					value={slice.filename}
					placeholder="e.g. cover.pdf"
					disabled={locked}
					error={errors.filename}
					oninput={setFilename}
				/>
			</div>
		</div>

		<!-- Remove button -->
		<button
			type="button"
			class="mt-1.5 rounded-[6px] p-1 text-ink-3 hover:bg-[rgba(162,59,46,0.08)] hover:text-err disabled:opacity-40 transition-colors"
			aria-label="Remove slice"
			onclick={removeMe}
			disabled={disabled || submitting}
		>
			<svg class="h-4 w-4" viewBox="0 0 20 20" fill="currentColor">
				<path
					d="M4 4a1 1 0 0 1 1.4 0L10 8.6l4.6-4.6a1 1 0 1 1 1.4 1.4L11.4 10l4.6 4.6a1 1 0 1 1-1.4 1.4L10 11.4l-4.6 4.6a1 1 0 1 1-1.4-1.4L8.6 10 4 5.4A1 1 0 0 1 4 4Z"
				/>
			</svg>
		</button>
	</div>

	<!-- Page range summary + filename meta (shown when filled in) -->
	{#if slice.filename || (slice.startPage && slice.endPage)}
		<div class="mt-2 flex items-center justify-between px-7">
			{#if slice.filename}
				<span class="truncate font-mono text-[10.5px] text-ink-3">{slice.filename}</span>
			{:else}
				<span></span>
			{/if}
			{#if slice.startPage && slice.endPage}
				<span class="whitespace-nowrap font-mono text-[11px] text-ink-2">
					pp. {slice.startPage}–{slice.endPage}
				</span>
			{/if}
		</div>
	{/if}
</div>
