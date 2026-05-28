<script lang="ts">
    import { onMount, onDestroy } from 'svelte';
    import { Chart, registerables, type ChartConfiguration } from 'chart.js';

    Chart.register(...registerables);

    let {
        labels,
        datasets,
        height = 240,
    }: {
        labels: string[];
        datasets: Array<{ label: string; data: number[]; borderColor?: string; backgroundColor?: string; yAxisID?: string }>;
        height?: number;
    } = $props();

    let canvas = $state<HTMLCanvasElement | undefined>();
    let chart: Chart | null = null;

    function build() {
        if (!canvas) return;
        const ctx = canvas.getContext('2d');
        if (!ctx) return;
        const cfg: ChartConfiguration<'line'> = {
            type: 'line',
            data: {
                labels,
                datasets: datasets.map((d) => ({
                    label: d.label,
                    data: d.data,
                    borderColor: d.borderColor ?? '#2563eb',
                    backgroundColor: d.backgroundColor ?? 'rgba(37, 99, 235, 0.1)',
                    yAxisID: d.yAxisID,
                    tension: 0.25,
                    fill: false,
                })),
            },
            options: {
                responsive: true,
                maintainAspectRatio: false,
                interaction: { mode: 'index', intersect: false },
                plugins: { legend: { position: 'top' } },
                scales: {
                    x: { ticks: { maxTicksLimit: 12 } },
                    y: { type: 'linear', position: 'left' },
                    yRight: { type: 'linear', position: 'right', grid: { drawOnChartArea: false } },
                },
            },
        };
        chart = new Chart(ctx, cfg);
    }

    onMount(() => {
        build();
    });

    $effect(() => {
        // Track these reactive deps explicitly so the effect runs on changes:
        labels;
        datasets;
        // Only update if the chart already exists (build runs in onMount, after the canvas is bound).
        if (!chart) return;
        chart.data.labels = labels;
        chart.data.datasets.forEach((ds, i) => {
            ds.data = datasets[i]?.data ?? [];
        });
        chart.update();
    });

    onDestroy(() => {
        chart?.destroy();
        chart = null;
    });
</script>

<div style="height: {height}px;">
    <canvas bind:this={canvas}></canvas>
</div>
