<script lang="ts">
	let {
		title,
		sub,
		primaryLabel,
		onPrimary,
		secondaryLabel,
		onSecondary,
		primaryDisabled = false,
	}: {
		title: string;
		sub?: string;
		primaryLabel?: string;
		onPrimary?: () => void;
		secondaryLabel?: string;
		onSecondary?: () => void;
		primaryDisabled?: boolean;
	} = $props();
</script>

<div
	class="flex flex-shrink-0 items-end justify-between gap-4 border-b border-line bg-card px-[28px] py-4"
>
	<div class="min-w-0 flex-1">
		<div class="font-serif text-[26px] font-semibold leading-[1.15] tracking-[-0.2px] text-ink">
			{title}
		</div>
		{#if sub}
			<div class="mt-1 font-sans text-[12.5px] font-medium text-ink-2">{sub}</div>
		{/if}
	</div>
	<div class="flex flex-shrink-0 gap-[10px]">
		{#if secondaryLabel}
			<button
				onclick={onSecondary}
				class="whitespace-nowrap rounded-[8px] border border-line bg-card px-[15px] py-[9px] font-sans text-[12.5px] font-semibold text-ink transition-colors hover:border-ink-2"
			>
				{secondaryLabel}
			</button>
		{/if}
		{#if primaryLabel}
			<button
				onclick={onPrimary}
				disabled={primaryDisabled}
				class="whitespace-nowrap rounded-[8px] bg-navy px-[17px] py-[9px] font-sans text-[12.5px] font-semibold text-white transition-colors hover:bg-navy-dk disabled:cursor-not-allowed disabled:opacity-40"
			>
				{primaryLabel}
			</button>
		{/if}
	</div>
</div>
