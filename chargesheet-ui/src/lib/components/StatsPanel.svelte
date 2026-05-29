<script lang="ts">
	import { onMount } from 'svelte';
	import { statsStore } from '$lib/stores/stats.svelte';
	import { listExtractions } from '$lib/api/extractions';
	import { listPromptOutputs } from '$lib/api/prompts';
	import EmptyState from './EmptyState.svelte';
	import Button from './Button.svelte';

	let { projectId }: { projectId: string } = $props();

	const stats = $derived(statsStore.perProject[projectId]);

	type RunRow = {
		kind: 'OCR' | 'PROMPT';
		subject: string;
		model: string;
		input_tokens: number | null;
		output_tokens: number | null;
		input_cost_usd: number | null;
		output_cost_usd: number | null;
		latency_s: number;
		created_at: string;
	};

	let runs = $state<RunRow[]>([]);
	let runsLoading = $state(false);

	async function loadRuns() {
		runsLoading = true;
		try {
			const [exs, prs] = await Promise.all([
				listExtractions(projectId),
				listPromptOutputs(projectId),
			]);
			const ocrRows: RunRow[] = exs.map((e) => ({
				kind: 'OCR',
				subject: e.slice_filename,
				model: e.model,
				input_tokens: e.input_tokens,
				output_tokens: e.output_tokens,
				input_cost_usd: e.input_cost_usd,
				output_cost_usd: e.output_cost_usd,
				latency_s: e.latency_s,
				created_at: e.created_at,
			}));
			const promptRows: RunRow[] = prs.map((p) => ({
				kind: 'PROMPT',
				subject: p.prompt_name,
				model: p.model,
				input_tokens: p.input_tokens,
				output_tokens: p.output_tokens,
				input_cost_usd: p.input_cost_usd,
				output_cost_usd: p.output_cost_usd,
				latency_s: p.latency_s,
				created_at: p.created_at,
			}));
			runs = [...ocrRows, ...promptRows].sort((a, b) =>
				b.created_at.localeCompare(a.created_at),
			);
		} catch {
			runs = [];
		} finally {
			runsLoading = false;
		}
	}

	onMount(() => {
		void statsStore.loadProject(projectId);
		void loadRuns();
	});

	function refresh() {
		void statsStore.loadProject(projectId);
		void loadRuns();
	}

	function fmtUsd(v: number): string {
		return `$${v.toFixed(4)}`;
	}

	function fmtUsdOrDash(v: number | null): string {
		return v === null ? '—' : `$${v.toFixed(4)}`;
	}

	function fmtTok(v: number): string {
		if (v >= 1_000_000) return (v / 1_000_000).toFixed(1) + 'M';
		if (v >= 1_000) return Math.round(v / 1_000) + 'k';
		return String(v);
	}

	function fmtTokOrDash(v: number | null): string {
		return v === null ? '—' : fmtTok(v);
	}

	function fmtTime(iso: string): string {
		const d = new Date(iso);
		const now = new Date();
		const diffMs = now.getTime() - d.getTime();
		const diffMin = Math.floor(diffMs / 60_000);
		if (diffMin < 1) return 'just now';
		if (diffMin < 60) return `${diffMin}m ago`;
		const diffH = Math.floor(diffMin / 60);
		if (diffH < 24) return `${diffH}h ago`;
		const diffD = Math.floor(diffH / 24);
		return `${diffD}d ago`;
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

			{#if runsLoading && runs.length === 0}
				<div class="px-[22px] py-8 text-center font-sans text-[12.5px] text-ink-3">
					Loading…
				</div>
			{:else if runs.length === 0}
				<div class="px-[22px] py-3">
					<EmptyState title="No runs yet" description="Run history will appear here once jobs complete." />
				</div>
			{:else}
				<div class="overflow-x-auto">
					<table class="w-full text-left">
						<thead class="bg-panel">
							<tr class="font-sans text-[10px] font-semibold uppercase tracking-[0.6px] text-ink-3">
								<th class="px-[22px] py-2.5">Kind</th>
								<th class="px-3 py-2.5">Subject</th>
								<th class="px-3 py-2.5">Model</th>
								<th class="px-3 py-2.5 text-right">Tokens</th>
								<th class="px-3 py-2.5 text-right">Cost</th>
								<th class="px-3 py-2.5 text-right">Latency</th>
								<th class="px-[22px] py-2.5 text-right">When</th>
							</tr>
						</thead>
						<tbody>
							{#each runs as r, i (i)}
								{@const totalCost =
									(r.input_cost_usd ?? 0) + (r.output_cost_usd ?? 0)}
								{@const totalTok =
									r.input_tokens === null && r.output_tokens === null
										? null
										: (r.input_tokens ?? 0) + (r.output_tokens ?? 0)}
								<tr class="border-t border-line-2">
									<td class="px-[22px] py-2.5">
										<span
											class="rounded-full px-2 py-px font-mono text-[10px] font-semibold"
											class:bg-navy-soft={r.kind === 'OCR'}
											class:text-navy={r.kind === 'OCR'}
											class:bg-warn-soft={r.kind === 'PROMPT'}
											class:text-warn={r.kind === 'PROMPT'}
											style={r.kind === 'PROMPT'
												? 'background: rgba(176,122,46,0.10);'
												: ''}
										>
											{r.kind}
										</span>
									</td>
									<td class="px-3 py-2.5 font-mono text-[12px] text-ink">
										{r.subject}
									</td>
									<td class="px-3 py-2.5 font-mono text-[11.5px] text-ink-2">
										{r.model}
									</td>
									<td class="px-3 py-2.5 text-right font-mono text-[12px] text-ink-2">
										{fmtTokOrDash(totalTok)}
									</td>
									<td class="px-3 py-2.5 text-right font-mono text-[12px] text-ink">
										{r.input_cost_usd === null && r.output_cost_usd === null
											? '—'
											: fmtUsd(totalCost)}
									</td>
									<td class="px-3 py-2.5 text-right font-mono text-[12px] text-ink-2">
										{r.latency_s.toFixed(1)}s
									</td>
									<td class="px-[22px] py-2.5 text-right font-mono text-[11px] text-ink-3 whitespace-nowrap">
										{fmtTime(r.created_at)}
									</td>
								</tr>
							{/each}
						</tbody>
					</table>
				</div>
			{/if}
		</div>

		<div class="mt-4 flex justify-end">
			<Button variant="secondary" size="sm" onclick={refresh}>Refresh</Button>
		</div>
	{:else}
		<EmptyState title="No stats yet" description="Run OCR or prompts to see usage statistics here." />
	{/if}
</div>
