<script lang="ts">
	let { value = 0 }: { value?: number } = $props();
	const clamped = $derived(Math.max(0, Math.min(1, value)));
</script>

<div class="h-1 w-full overflow-hidden rounded-full bg-gray-200">
	<div
		class="h-full bg-blue-500 transition-all duration-200"
		style="width: {clamped * 100}%"
	></div>
</div>
