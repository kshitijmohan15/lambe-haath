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

	function fmtUsdSplit(v: number): { sign: string; value: string } {
		const s = v.toFixed(4);
		return { sign: '$', value: s };
	}

	function fmtTok(v: number): string {
		if (v >= 1_000_000) return (v / 1_000_000).toFixed(1) + 'M';
		if (v >= 1_000) return Math.round(v / 1_000) + 'k';
		return String(v);
	}
</script>

<div class="h-full overflow-y-auto bg-paper p-[26px]">
	{#if statsStore.loading && !stats}
		<div class="grid grid-cols-3 gap-4">
			{#each Array(3) as _, i (i)}
				<div class="h-24 animate-pulse rounded-[14px] border border-line bg-card"></div>
			{/each}
		</div>
	{:else if statsStore.error && !stats}
		<EmptyState title="Couldn't load stats" description={statsStore.error} />
	{:else if stats}
		<!-- KPI cards -->
		<div class="mb-5 grid grid-cols-3 gap-4">
			<!-- Total cost card -->
			<div class="rounded-[14px] border border-line bg-card p-5 shadow-[0_1px_2px_rgba(40,35,25,0.04)]">
				<div class="font-sans text-[10px] font-semibold uppercase tracking-[0.6px] text-ink-3 mb-2">
					Total cost
				</div>
				<div class="flex items-baseline gap-0.5 font-serif text-[28px] font-semibold text-ink">
					<span class="text-[18px] text-ink-3">$</span>{(stats.ocr_cost_usd + stats.prompt_cost_usd).toFixed(4)}
				</div>
				<div class="mt-1.5 font-sans text-[11px] text-ink-3">
					OCR: {fmtUsd(stats.ocr_cost_usd)} · Prompts: {fmtUsd(stats.prompt_cost_usd)}
				</div>
			</div>

			<!-- Tokens card -->
			<div class="rounded-[14px] border border-line bg-card p-5 shadow-[0_1px_2px_rgba(40,35,25,0.04)]">
				<div class="font-sans text-[10px] font-semibold uppercase tracking-[0.6px] text-ink-3 mb-2">
					Tokens
				</div>
				<div class="font-serif text-[28px] font-semibold text-ink">
					{fmtTok(stats.total_in_tokens + stats.total_out_tokens)}
				</div>
				<div class="mt-1.5 font-sans text-[11px] text-ink-3">
					In: {fmtTok(stats.total_in_tokens)} · Out: {fmtTok(stats.total_out_tokens)}
				</div>
			</div>

			<!-- Runs card -->
			<div class="rounded-[14px] border border-line bg-card p-5 shadow-[0_1px_2px_rgba(40,35,25,0.04)]">
				<div class="font-sans text-[10px] font-semibold uppercase tracking-[0.6px] text-ink-3 mb-2">
					Runs
				</div>
				<div class="font-serif text-[28px] font-semibold text-ink">
					{stats.ocr_runs + stats.prompt_runs}
				</div>
				<div class="mt-1.5 font-sans text-[11px] text-ink-3">
					OCR: {stats.ocr_runs} · Prompts: {stats.prompt_runs}
				</div>
			</div>
		</div>

		<!-- Run history table -->
		<div class="rounded-[14px] border border-line bg-card overflow-hidden shadow-[0_1px_2px_rgba(40,35,25,0.04)]">
			<div class="border-b border-line px-[22px] py-[13px]">
				<div class="font-sans text-[10px] font-semibold uppercase tracking-[0.6px] text-ink-3">
					Run history
				</div>
			</div>

			<!-- StatsPanel doesn't fetch run-history rows today; leaving table empty -->
			<div class="px-[22px] py-3">
				<EmptyState title="No runs yet" description="Run history will appear here once jobs complete." />
			</div>
		</div>

		<div class="mt-4 flex justify-end">
			<Button variant="secondary" size="sm" onclick={() => void statsStore.loadProject(projectId)}>
				Refresh
			</Button>
		</div>
	{:else}
		<EmptyState title="No stats yet" description="Run OCR or prompts to see usage statistics here." />
	{/if}
</div>
