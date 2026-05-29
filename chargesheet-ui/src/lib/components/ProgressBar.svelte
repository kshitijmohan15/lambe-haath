<script lang="ts">
	let { value = 0, tone = 'navy' }: { value?: number; tone?: 'navy' | 'ok' } = $props();
	const clamped = $derived(Math.max(0, Math.min(1, value)));
</script>

<div class="h-[3px] w-full overflow-hidden rounded-full bg-line">
	<div
		class="h-full rounded-full transition-[width] duration-300 {tone === 'ok' ? 'bg-ok' : 'bg-navy'}"
		style="width: {clamped * 100}%"
	></div>
</div>
