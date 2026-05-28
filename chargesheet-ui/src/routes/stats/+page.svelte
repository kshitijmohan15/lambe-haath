<script lang="ts">
    import { onMount } from 'svelte';
    import { statsStore } from '$lib/stores/stats.svelte';
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
        return `$${v.toFixed(4)}`;
    }
    function fmtTok(v: number) {
        return v.toLocaleString('en-US');
    }

    const summaryCards: Array<[string, 'ocr' | 'prompt']> = [
        ['OCR', 'ocr'],
        ['Prompts', 'prompt'],
    ];
</script>

<div class="mx-auto max-w-6xl px-6 py-10 space-y-8">
    <div class="flex items-end justify-between">
        <div>
            <h1 class="text-2xl font-semibold text-gray-900">Stats</h1>
            <p class="text-sm text-gray-500">Tokens, cost, and latency across all projects.</p>
        </div>
        <a href="/" class="text-sm text-blue-600 hover:underline">← Projects</a>
    </div>

    {#if !overview}
        <div class="grid grid-cols-2 gap-4">
            {#each Array(2) as _, i (i)}
                <div class="h-32 animate-pulse rounded-lg border border-gray-200 bg-gray-100"></div>
            {/each}
        </div>
    {:else}
        <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
            {#each summaryCards as [name, key] (key)}
                <div class="rounded-lg border border-gray-200 bg-white p-4">
                    <div class="text-xs uppercase tracking-wide text-gray-500">{name}</div>
                    <div class="mt-1 text-3xl font-semibold text-gray-900">{fmtUsd(overview.lifetime[key].cost_usd)}</div>
                    <div class="mt-2 grid grid-cols-3 gap-2 text-xs text-gray-500">
                        <div>Runs<br><span class="text-gray-900">{overview.lifetime[key].runs}</span></div>
                        <div>In tok<br><span class="text-gray-900">{fmtTok(overview.lifetime[key].in_tokens)}</span></div>
                        <div>Out tok<br><span class="text-gray-900">{fmtTok(overview.lifetime[key].out_tokens)}</span></div>
                    </div>
                    <div class="mt-2 text-xs text-gray-500">Avg latency: {overview.lifetime[key].avg_latency_s.toFixed(2)}s</div>
                </div>
            {/each}
        </div>

        <section>
            <h2 class="mb-2 text-sm font-semibold text-gray-900">Per-model usage</h2>
            {#if overview.per_model.length === 0}
                <EmptyState title="No model usage yet" description="Run a pipeline to see model rollups." />
            {:else}
                <div class="overflow-hidden rounded-lg border border-gray-200">
                    <table class="min-w-full text-sm">
                        <thead class="bg-gray-50 text-xs uppercase tracking-wide text-gray-500">
                            <tr><th class="px-3 py-2 text-left">Model</th><th class="px-3 py-2 text-right">Runs</th><th class="px-3 py-2 text-right">In tok</th><th class="px-3 py-2 text-right">Out tok</th><th class="px-3 py-2 text-right">Cost</th></tr>
                        </thead>
                        <tbody class="divide-y divide-gray-100 bg-white">
                            {#each overview.per_model as m (m.model)}
                                <tr><td class="px-3 py-2 font-mono">{m.model}</td><td class="px-3 py-2 text-right">{m.runs}</td><td class="px-3 py-2 text-right">{fmtTok(m.in_tokens)}</td><td class="px-3 py-2 text-right">{fmtTok(m.out_tokens)}</td><td class="px-3 py-2 text-right">{fmtUsd(m.cost_usd)}</td></tr>
                            {/each}
                        </tbody>
                    </table>
                </div>
            {/if}
        </section>

        <section>
            <h2 class="mb-2 text-sm font-semibold text-gray-900">Cost &amp; tokens — last 30 days</h2>
            {#if series.length === 0}
                <EmptyState title="No activity in this range" description="Run a pipeline; data will appear here." />
            {:else}
                <LineChart
                    labels={series.map((d) => d.day)}
                    datasets={[
                        { label: 'Cost (USD)', data: series.map((d) => d.cost_usd), borderColor: '#2563eb', yAxisID: 'y' },
                        { label: 'Total tokens', data: series.map((d) => d.in_tokens + d.out_tokens), borderColor: '#16a34a', yAxisID: 'yRight' },
                    ]}
                />
            {/if}
        </section>

        <section>
            <h2 class="mb-2 text-sm font-semibold text-gray-900">Top-cost projects</h2>
            {#if overview.top_projects.length === 0}
                <EmptyState title="No project usage yet" description="" />
            {:else}
                <div class="overflow-hidden rounded-lg border border-gray-200">
                    <table class="min-w-full text-sm">
                        <thead class="bg-gray-50 text-xs uppercase tracking-wide text-gray-500">
                            <tr><th class="px-3 py-2 text-left">Project</th><th class="px-3 py-2 text-right">OCR cost</th><th class="px-3 py-2 text-right">Prompt cost</th><th class="px-3 py-2 text-right">Total tokens</th></tr>
                        </thead>
                        <tbody class="divide-y divide-gray-100 bg-white">
                            {#each overview.top_projects as p (p.project_id)}
                                <tr>
                                    <td class="px-3 py-2"><a class="text-blue-600 hover:underline" href="/projects/{p.project_id}">{p.project_id}</a></td>
                                    <td class="px-3 py-2 text-right">{fmtUsd(p.ocr_cost_usd)}</td>
                                    <td class="px-3 py-2 text-right">{fmtUsd(p.prompt_cost_usd)}</td>
                                    <td class="px-3 py-2 text-right">{fmtTok(p.total_in_tokens + p.total_out_tokens)}</td>
                                </tr>
                            {/each}
                        </tbody>
                    </table>
                </div>
            {/if}
        </section>
    {/if}

    <section>
        <h2 class="mb-2 text-sm font-semibold text-gray-900">Slowest jobs</h2>
        {#if slow.length === 0}
            <EmptyState title="No jobs to rank" description="" />
        {:else}
            <div class="overflow-hidden rounded-lg border border-gray-200">
                <table class="min-w-full text-sm">
                    <thead class="bg-gray-50 text-xs uppercase tracking-wide text-gray-500">
                        <tr><th class="px-3 py-2 text-left">Kind</th><th class="px-3 py-2 text-left">Project</th><th class="px-3 py-2 text-left">Subject</th><th class="px-3 py-2 text-left">Model</th><th class="px-3 py-2 text-right">Latency</th><th class="px-3 py-2 text-right">Tokens</th><th class="px-3 py-2 text-left">When</th></tr>
                    </thead>
                    <tbody class="divide-y divide-gray-100 bg-white">
                        {#each slow as s (s.created_at + s.subject)}
                            <tr>
                                <td class="px-3 py-2">{s.kind}</td>
                                <td class="px-3 py-2"><a class="text-blue-600 hover:underline" href="/projects/{s.project_id}">{s.project_id}</a></td>
                                <td class="px-3 py-2 font-mono text-xs">{s.subject}</td>
                                <td class="px-3 py-2 font-mono text-xs">{s.model}</td>
                                <td class="px-3 py-2 text-right">{s.latency_s.toFixed(2)}s</td>
                                <td class="px-3 py-2 text-right">{fmtTok(s.total_tokens)}</td>
                                <td class="px-3 py-2 text-xs text-gray-500">{s.created_at}</td>
                            </tr>
                        {/each}
                    </tbody>
                </table>
            </div>
        {/if}
    </section>
</div>
