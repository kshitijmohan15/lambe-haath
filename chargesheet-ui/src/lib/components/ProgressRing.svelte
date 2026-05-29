<script lang="ts">
	let { percent = 0, size = 36, stroke = 3 }: { percent?: number; size?: number; stroke?: number } =
		$props();
	const r = $derived((size - stroke) / 2);
	const c = $derived(2 * Math.PI * r);
	const offset = $derived(c * (1 - Math.max(0, Math.min(1, percent))));
</script>

<div class="relative flex-shrink-0" style="width: {size}px; height: {size}px;">
	<svg viewBox="0 0 {size} {size}" class="-rotate-90" width={size} height={size}>
		<circle
			cx={size / 2}
			cy={size / 2}
			r={r}
			fill="none"
			stroke="currentColor"
			stroke-width={stroke}
			class="text-line"
		/>
		<circle
			cx={size / 2}
			cy={size / 2}
			r={r}
			fill="none"
			stroke="currentColor"
			stroke-width={stroke}
			class="text-navy transition-[stroke-dashoffset] duration-300"
			stroke-dasharray={c}
			stroke-dashoffset={offset}
			stroke-linecap="round"
		/>
	</svg>
	<div
		class="absolute inset-0 flex items-center justify-center font-sans text-[9.5px] font-semibold text-ink-2"
	>
		{Math.round(percent * 100)}%
	</div>
</div>
