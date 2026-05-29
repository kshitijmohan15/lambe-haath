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
		<label
			for={id}
			class="mb-2 block font-sans text-[10px] font-semibold uppercase tracking-[0.6px] text-ink-3"
		>
			{label}
		</label>
	{/if}
	<input
		{id}
		type="number"
		bind:value
		{min}
		{max}
		{disabled}
		class="w-full rounded-[9px] border bg-card px-3 py-[10px] font-sans text-[13px] tabular-nums text-ink placeholder:text-ink-3 focus:outline-none focus:ring-2 disabled:cursor-not-allowed disabled:bg-panel disabled:text-ink-3 {error
			? 'border-err focus:border-err focus:ring-err/20'
			: 'border-line focus:border-navy focus:ring-navy/20'} {extraClass}"
		{...rest}
	/>
	{#if error}
		<p class="mt-1.5 font-sans text-[12px] text-err">{error}</p>
	{/if}
</div>
