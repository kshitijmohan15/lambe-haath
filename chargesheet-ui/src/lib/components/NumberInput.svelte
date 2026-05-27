<script lang="ts">
	import type { HTMLInputAttributes } from 'svelte/elements';

	interface Props extends Omit<HTMLInputAttributes, 'class' | 'value' | 'type'> {
		value: number;
		error?: string | null;
		label?: string;
		min?: number;
		max?: number;
		class?: string;
	}

	let {
		value = $bindable(0),
		error = null,
		label,
		id,
		min,
		max,
		disabled = false,
		class: extraClass = '',
		...rest
	}: Props = $props();
</script>

<div class="w-full">
	{#if label}
		<label for={id} class="mb-1 block text-xs font-medium text-gray-700">{label}</label>
	{/if}
	<input
		{id}
		type="number"
		bind:value
		{min}
		{max}
		{disabled}
		class="block w-full rounded border px-2 py-1 text-sm tabular-nums focus:outline-none focus:ring-1 disabled:bg-gray-100 disabled:text-gray-500 {error
			? 'border-red-400 focus:border-red-500 focus:ring-red-500'
			: 'border-gray-300 focus:border-blue-500 focus:ring-blue-500'} {extraClass}"
		{...rest}
	/>
	{#if error}
		<p class="mt-0.5 text-xs text-red-600">{error}</p>
	{/if}
</div>
