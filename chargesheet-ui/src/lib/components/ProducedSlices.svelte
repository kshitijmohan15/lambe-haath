<script lang="ts">
	import { deleteSlice, listSlices, sliceUrl } from '$lib/api/slices';
	import type { SliceListingItem } from '$lib/api/types';
	import { toastsStore } from '$lib/stores/toasts.svelte';
	import { formatBytes, formatRelative } from '$lib/utils/format';
	import ConfirmDialog from './ConfirmDialog.svelte';

	interface Props {
		projectId: string;
		/** Bumped by the parent after a successful submission to trigger a reload. */
		reloadKey?: number;
	}

	let { projectId, reloadKey = 0 }: Props = $props();

	let items = $state<SliceListingItem[]>([]);
	let loading = $state(false);
	let error = $state<string | null>(null);
	let expanded = $state(false);
	let pendingDelete = $state<string | null>(null);
	let deleting = $state(false);

	$effect(() => {
		// re-run when projectId or reloadKey changes
		const _ = reloadKey;
		void load(projectId);
	});

	async function load(id: string) {
		loading = true;
		error = null;
		try {
			const r = await listSlices(id);
			items = r.slices;
		} catch (e) {
			error = e instanceof Error ? e.message : 'Failed to load slices';
		} finally {
			loading = false;
		}
	}

	async function performDelete() {
		if (pendingDelete === null) return;
		const filename = pendingDelete;
		deleting = true;
		try {
			await deleteSlice(projectId, filename);
			items = items.filter((s) => s.filename !== filename);
			toastsStore.success(`Deleted "${filename}"`);
		} catch (e) {
			toastsStore.error(e instanceof Error ? e.message : 'Failed to delete slice');
		} finally {
			deleting = false;
			pendingDelete = null;
		}
	}
</script>

<section class="border-t border-gray-200 bg-gray-50 px-4 py-3">
	<button
		type="button"
		class="flex w-full items-center justify-between text-sm font-semibold text-gray-700 hover:text-gray-900"
		onclick={() => (expanded = !expanded)}
		aria-expanded={expanded}
	>
		<span>
			Saved slices <span class="font-normal text-gray-400">({items.length})</span>
		</span>
		<svg
			class="h-4 w-4 transition-transform {expanded ? 'rotate-180' : ''}"
			viewBox="0 0 20 20"
			fill="currentColor"
			aria-hidden="true"
		>
			<path
				fill-rule="evenodd"
				d="M5.3 7.3a1 1 0 0 1 1.4 0L10 10.6l3.3-3.3a1 1 0 1 1 1.4 1.4l-4 4a1 1 0 0 1-1.4 0l-4-4a1 1 0 0 1 0-1.4Z"
				clip-rule="evenodd"
			/>
		</svg>
	</button>

	{#if expanded}
		<div class="mt-3 space-y-2">
			{#if loading && items.length === 0}
				<div class="text-xs text-gray-500">Loading…</div>
			{:else if error}
				<div class="text-xs text-red-600">{error}</div>
			{:else if items.length === 0}
				<div class="text-xs text-gray-500">No slices saved yet.</div>
			{:else}
				{#each items as item (item.filename)}
					<div class="flex items-center justify-between gap-2 rounded border border-gray-200 bg-white px-3 py-2 text-xs">
						<div class="min-w-0 flex-1">
							<div class="truncate font-medium text-gray-800">{item.filename}</div>
							<div class="text-gray-500">
								pp. {item.page_range[0]}–{item.page_range[1]} · {formatBytes(item.size_bytes)} · {formatRelative(
									item.created_at
								)}
							</div>
						</div>
						<a
							href={sliceUrl(projectId, item.filename)}
							target="_blank"
							rel="noopener"
							class="rounded border border-gray-300 px-2 py-1 text-gray-700 hover:bg-gray-50"
						>
							Open
						</a>
						<button
							type="button"
							aria-label="Delete slice"
							class="rounded p-1 text-gray-400 hover:bg-red-50 hover:text-red-600 disabled:opacity-40"
							disabled={deleting}
							onclick={() => (pendingDelete = item.filename)}
						>
							<svg class="h-4 w-4" viewBox="0 0 20 20" fill="currentColor" aria-hidden="true">
								<path
									fill-rule="evenodd"
									d="M8.75 1A1.75 1.75 0 0 0 7 2.75V3H4a1 1 0 0 0 0 2h12a1 1 0 1 0 0-2h-3v-.25A1.75 1.75 0 0 0 11.25 1h-2.5ZM6 7a1 1 0 0 1 1 1v8a1 1 0 1 1-2 0V8a1 1 0 0 1 1-1Zm4 0a1 1 0 0 1 1 1v8a1 1 0 1 1-2 0V8a1 1 0 0 1 1-1Zm4 0a1 1 0 0 1 1 1v8a1 1 0 1 1-2 0V8a1 1 0 0 1 1-1Z"
									clip-rule="evenodd"
								/>
							</svg>
						</button>
					</div>
				{/each}
			{/if}
		</div>
	{/if}
</section>

<ConfirmDialog
	open={pendingDelete !== null}
	title="Delete slice?"
	message={pendingDelete ? `"${pendingDelete}" will be permanently removed.` : ''}
	confirmText={deleting ? 'Deleting…' : 'Delete'}
	cancelText="Cancel"
	variant="danger"
	onConfirm={performDelete}
	onCancel={() => (pendingDelete = null)}
/>
