<script lang="ts">
	import { onMount } from 'svelte';
	import { statsStore } from '$lib/stores/stats.svelte';
	import EmptyState from './EmptyState.svelte';
	import Button from './Button.svelte';

	let { projectId }: { projectId: string } = $props();

	const stats = $derived(statsStore.perProject[projectId]);

	onMount(() => {
		void statsStore.loadProject(projectId);
	});

	function fmtUsd(v: number): string {
		return `$${v.toFixed(4)}`;
	}
	function fmtTok(v: number): string {
		return v.toLocaleString('en-US');
	}
</script>

<div class="space-y-4">
	{#if statsStore.loading && !stats}
		<div class="grid grid-cols-3 gap-3">
			{#each Array(3) as _, i (i)}
				<div class="h-20 animate-pulse rounded-lg border border-gray-200 bg-gray-100"></div>
			{/each}
		</div>
	{:else if statsStore.error && !stats}
		<EmptyState title="Couldn't load stats" description={statsStore.error} />
	{:else if stats}
		<div class="grid grid-cols-1 gap-3 sm:grid-cols-3">
			<div class="rounded-lg border border-gray-200 bg-white p-4">
				<div class="text-xs uppercase tracking-wide text-gray-500">Total cost</div>
				<div class="mt-1 text-2xl font-semibold text-gray-900">
					{fmtUsd(stats.ocr_cost_usd + stats.prompt_cost_usd)}
				</div>
				<div class="mt-2 text-xs text-gray-500">
					OCR {fmtUsd(stats.ocr_cost_usd)} · Prompts {fmtUsd(stats.prompt_cost_usd)}
				</div>
			</div>
			<div class="rounded-lg border border-gray-200 bg-white p-4">
				<div class="text-xs uppercase tracking-wide text-gray-500">Tokens</div>
				<div class="mt-1 text-2xl font-semibold text-gray-900">
					{fmtTok(stats.total_in_tokens + stats.total_out_tokens)}
				</div>
				<div class="mt-2 text-xs text-gray-500">
					In {fmtTok(stats.total_in_tokens)} · Out {fmtTok(stats.total_out_tokens)}
				</div>
			</div>
			<div class="rounded-lg border border-gray-200 bg-white p-4">
				<div class="text-xs uppercase tracking-wide text-gray-500">Runs</div>
				<div class="mt-1 text-2xl font-semibold text-gray-900">
					{stats.ocr_runs + stats.prompt_runs}
				</div>
				<div class="mt-2 text-xs text-gray-500">
					OCR {stats.ocr_runs} · Prompts {stats.prompt_runs}
				</div>
			</div>
		</div>
		<div class="flex justify-end">
			<Button variant="secondary" onclick={() => void statsStore.loadProject(projectId)}>Refresh</Button>
		</div>
	{/if}
</div>
