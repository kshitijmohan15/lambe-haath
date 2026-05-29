<script lang="ts">
    import { onMount } from 'svelte';
    import { statsStore } from '$lib/stores/stats.svelte';
    import { connectionStore } from '$lib/stores/connection.svelte';
    import LineChart from '$lib/components/LineChart.svelte';
    import EmptyState from '$lib/components/EmptyState.svelte';

    function ymd(d: Date): string {
        return d.toISOString().slice(0, 10);
    }

    function loadAll() {
        const to = new Date();
        const from = new Date(to.getTime() - 30 * 24 * 60 * 60 * 1000);
        void statsStore.loadOverview();
        void statsStore.loadTimeseries(ymd(from), ymd(to));
        void statsStore.loadSlow(20);
    }

    onMount(loadAll);

    const overview = $derived(statsStore.overview);
    const series = $derived(statsStore.timeseries);
    const slow = $derived(statsStore.slow);

    function fmtUsd(v: number) {
        return v.toFixed(4);
    }
    function fmtTok(v: number) {
        return v.toLocaleString('en-US');
    }

    const summaryCards: Array<[string, 'ocr' | 'prompt']> = [
        ['OCR', 'ocr'],
        ['Prompts', 'prompt'],
    ];
</script>

<!-- Top bar (identical to Matters /) -->
<header class="flex h-[56px] items-center justify-between border-b border-line bg-panel px-[28px]">
    <!-- Brand mark: C tile + CHARGESHEET label -->
    <div class="flex items-center gap-2.5">
        <div
            class="grid h-[26px] w-[26px] flex-shrink-0 place-items-center rounded-[6px] bg-navy font-serif text-[13px] font-bold text-white"
            aria-hidden="true"
        >
            C
        </div>
        <span class="font-sans text-[12px] font-bold tracking-[1.4px] text-ink uppercase">
            CHARGESHEET
        </span>
    </div>

    <!-- Daemon connection indicator -->
    <div class="flex items-center gap-1.5">
        <span
            class="h-[7px] w-[7px] flex-shrink-0 rounded-full {connectionStore.online
                ? 'bg-ok'
                : 'bg-err'}"
        ></span>
        <span class="font-sans text-[11px] font-semibold text-ink-2">
            {connectionStore.online ? 'Daemon connected' : 'Daemon offline'}
        </span>
    </div>
</header>

<!-- Page content -->
<div class="px-[40px] pt-[28px] pb-[40px]">
    <!-- Heading row -->
    <div class="flex items-end justify-between gap-4">
        <div>
            <h1 class="font-serif text-[30px] font-semibold leading-tight text-ink">Stats</h1>
            <p class="mt-1 font-sans text-[13px] font-medium text-ink-2">
                Tokens, cost, and latency across all matters.
            </p>
        </div>
        <a
            href="/"
            class="inline-flex flex-shrink-0 items-center justify-center gap-1.5 rounded-ctl border border-line bg-card px-[15px] py-[9px] font-sans text-[12.5px] font-semibold whitespace-nowrap text-ink transition-colors hover:border-ink-2 focus:outline-none focus:ring-2 focus:ring-navy/30"
        >
            ← Matters
        </a>
    </div>

    {#if !overview}
        <!-- Loading skeletons -->
        <div class="mt-6 grid grid-cols-2 gap-4">
            {#each Array(2) as _, i (i)}
                <div class="h-36 animate-pulse rounded-card border border-line bg-panel"></div>
            {/each}
        </div>
    {:else}
        <!-- Lifetime summary cards -->
        <div class="mt-6 grid grid-cols-2 gap-4">
            {#each summaryCards as [name, key] (key)}
                <div class="rounded-card border border-line bg-card p-5">
                    <!-- Label header -->
                    <div class="font-sans text-[10px] font-semibold tracking-[0.6px] uppercase text-ink-3">
                        {name}
                    </div>
                    <!-- Big cost number -->
                    <div class="mt-1 font-serif text-[32px] font-semibold leading-none text-ink">
                        <span class="text-ink-3">$</span>{fmtUsd(overview.lifetime[key].cost_usd)}
                    </div>
                    <!-- Breakdown row: Runs / In tok / Out tok -->
                    <div class="mt-3 grid grid-cols-3 gap-2">
                        <div>
                            <div class="font-sans text-[11px] text-ink-3">Runs</div>
                            <div class="font-sans text-[13px] font-semibold text-ink">
                                {overview.lifetime[key].runs}
                            </div>
                        </div>
                        <div>
                            <div class="font-sans text-[11px] text-ink-3">In tok</div>
                            <div class="font-sans text-[13px] font-semibold text-ink">
                                {fmtTok(overview.lifetime[key].in_tokens)}
                            </div>
                        </div>
                        <div>
                            <div class="font-sans text-[11px] text-ink-3">Out tok</div>
                            <div class="font-sans text-[13px] font-semibold text-ink">
                                {fmtTok(overview.lifetime[key].out_tokens)}
                            </div>
                        </div>
                    </div>
                    <!-- Avg latency -->
                    <div class="mt-2 font-mono text-[11px] text-ink-3">
                        avg {overview.lifetime[key].avg_latency_s.toFixed(2)}s
                    </div>
                </div>
            {/each}
        </div>

        <!-- Per-model usage -->
        <section class="mt-8">
            <div class="mb-2 font-sans text-[10px] font-semibold tracking-[0.6px] uppercase text-ink-3">
                Per-model usage
            </div>
            {#if overview.per_model.length === 0}
                <EmptyState title="No model usage yet" description="Run a pipeline to see model rollups." />
            {:else}
                <div class="overflow-hidden rounded-card border border-line bg-card">
                    <table class="min-w-full">
                        <thead class="bg-panel">
                            <tr>
                                <th class="px-4 py-2.5 text-left font-sans text-[10px] font-semibold tracking-[0.6px] uppercase text-ink-3">Model</th>
                                <th class="px-4 py-2.5 text-right font-sans text-[10px] font-semibold tracking-[0.6px] uppercase text-ink-3">Runs</th>
                                <th class="px-4 py-2.5 text-right font-sans text-[10px] font-semibold tracking-[0.6px] uppercase text-ink-3">In tok</th>
                                <th class="px-4 py-2.5 text-right font-sans text-[10px] font-semibold tracking-[0.6px] uppercase text-ink-3">Out tok</th>
                                <th class="px-4 py-2.5 text-right font-sans text-[10px] font-semibold tracking-[0.6px] uppercase text-ink-3">Cost</th>
                            </tr>
                        </thead>
                        <tbody>
                            {#each overview.per_model as m (m.model)}
                                <tr class="border-t border-line-2">
                                    <td class="px-4 py-2.5 font-mono text-[12px] text-ink">{m.model}</td>
                                    <td class="px-4 py-2.5 text-right font-mono text-[12px] text-ink-2">{m.runs}</td>
                                    <td class="px-4 py-2.5 text-right font-mono text-[12px] text-ink-2">{fmtTok(m.in_tokens)}</td>
                                    <td class="px-4 py-2.5 text-right font-mono text-[12px] text-ink-2">{fmtTok(m.out_tokens)}</td>
                                    <td class="px-4 py-2.5 text-right font-mono text-[12px] font-semibold text-ink">${fmtUsd(m.cost_usd)}</td>
                                </tr>
                            {/each}
                        </tbody>
                    </table>
                </div>
            {/if}
        </section>

        <!-- Daily chart — last 30 days -->
        <section class="mt-8">
            <div class="mb-2 font-sans text-[10px] font-semibold tracking-[0.6px] uppercase text-ink-3">
                Cost &amp; tokens — last 30 days
            </div>
            {#if series.length === 0}
                <EmptyState title="No activity in this range" description="Run a pipeline; data will appear here." />
            {:else}
                <div class="rounded-card border border-line bg-card p-5">
                    <LineChart
                        labels={series.map((d) => d.day)}
                        datasets={[
                            { label: 'Cost (USD)', data: series.map((d) => d.cost_usd), borderColor: '#1e3a5f', yAxisID: 'y' },
                            { label: 'Total tokens', data: series.map((d) => d.in_tokens + d.out_tokens), borderColor: '#4f7a52', yAxisID: 'yRight' },
                        ]}
                    />
                </div>
            {/if}
        </section>

        <!-- Top-cost projects -->
        <section class="mt-8">
            <div class="mb-2 font-sans text-[10px] font-semibold tracking-[0.6px] uppercase text-ink-3">
                Top-cost projects
            </div>
            {#if overview.top_projects.length === 0}
                <EmptyState title="No project usage yet" description="" />
            {:else}
                <div class="overflow-hidden rounded-card border border-line bg-card">
                    <table class="min-w-full">
                        <thead class="bg-panel">
                            <tr>
                                <th class="px-4 py-2.5 text-left font-sans text-[10px] font-semibold tracking-[0.6px] uppercase text-ink-3">Project</th>
                                <th class="px-4 py-2.5 text-right font-sans text-[10px] font-semibold tracking-[0.6px] uppercase text-ink-3">OCR cost</th>
                                <th class="px-4 py-2.5 text-right font-sans text-[10px] font-semibold tracking-[0.6px] uppercase text-ink-3">Prompt cost</th>
                                <th class="px-4 py-2.5 text-right font-sans text-[10px] font-semibold tracking-[0.6px] uppercase text-ink-3">Total tokens</th>
                            </tr>
                        </thead>
                        <tbody>
                            {#each overview.top_projects as p (p.project_id)}
                                <tr class="border-t border-line-2">
                                    <td class="px-4 py-2.5">
                                        <a
                                            href="/projects/{p.project_id}"
                                            class="font-serif text-[14px] font-medium text-navy hover:underline"
                                        >{p.project_id}</a>
                                    </td>
                                    <td class="px-4 py-2.5 text-right font-mono text-[12px] text-ink-2">${fmtUsd(p.ocr_cost_usd)}</td>
                                    <td class="px-4 py-2.5 text-right font-mono text-[12px] text-ink-2">${fmtUsd(p.prompt_cost_usd)}</td>
                                    <td class="px-4 py-2.5 text-right font-mono text-[12px] text-ink-2">{fmtTok(p.total_in_tokens + p.total_out_tokens)}</td>
                                </tr>
                            {/each}
                        </tbody>
                    </table>
                </div>
            {/if}
        </section>
    {/if}

    <!-- Slowest jobs (outside overview guard — uses its own store slice) -->
    <section class="mt-8">
        <div class="mb-2 font-sans text-[10px] font-semibold tracking-[0.6px] uppercase text-ink-3">
            Slowest jobs
        </div>
        {#if slow.length === 0}
            <EmptyState title="No jobs to rank" description="" />
        {:else}
            <div class="overflow-hidden rounded-card border border-line bg-card">
                <table class="min-w-full">
                    <thead class="bg-panel">
                        <tr>
                            <th class="px-4 py-2.5 text-left font-sans text-[10px] font-semibold tracking-[0.6px] uppercase text-ink-3">Kind</th>
                            <th class="px-4 py-2.5 text-left font-sans text-[10px] font-semibold tracking-[0.6px] uppercase text-ink-3">Project</th>
                            <th class="px-4 py-2.5 text-left font-sans text-[10px] font-semibold tracking-[0.6px] uppercase text-ink-3">Subject</th>
                            <th class="px-4 py-2.5 text-left font-sans text-[10px] font-semibold tracking-[0.6px] uppercase text-ink-3">Model</th>
                            <th class="px-4 py-2.5 text-right font-sans text-[10px] font-semibold tracking-[0.6px] uppercase text-ink-3">Latency</th>
                            <th class="px-4 py-2.5 text-right font-sans text-[10px] font-semibold tracking-[0.6px] uppercase text-ink-3">Tokens</th>
                            <th class="px-4 py-2.5 text-left font-sans text-[10px] font-semibold tracking-[0.6px] uppercase text-ink-3">When</th>
                        </tr>
                    </thead>
                    <tbody>
                        {#each slow as s (s.created_at + s.subject)}
                            <tr class="border-t border-line-2">
                                <td class="px-4 py-2.5">
                                    {#if s.kind === 'ocr'}
                                        <span class="rounded-full bg-navy-soft px-2 py-px font-mono text-[10px] text-navy">OCR</span>
                                    {:else}
                                        <span class="rounded-full bg-[rgba(176,122,46,0.10)] px-2 py-px font-mono text-[10px] text-warn">PROMPT</span>
                                    {/if}
                                </td>
                                <td class="px-4 py-2.5">
                                    <a
                                        href="/projects/{s.project_id}"
                                        class="font-mono text-[12px] text-navy hover:underline"
                                    >{s.project_id}</a>
                                </td>
                                <td class="px-4 py-2.5 font-mono text-[12px] text-ink">{s.subject}</td>
                                <td class="px-4 py-2.5 font-mono text-[12px] text-ink-2">{s.model}</td>
                                <td class="px-4 py-2.5 text-right font-mono text-[12px] text-ink-2">{s.latency_s.toFixed(2)}s</td>
                                <td class="px-4 py-2.5 text-right font-mono text-[12px] text-ink-2">{fmtTok(s.total_tokens)}</td>
                                <td class="px-4 py-2.5 font-mono text-[11px] text-ink-3">{s.created_at}</td>
                            </tr>
                        {/each}
                    </tbody>
                </table>
            </div>
        {/if}
    </section>
</div>
