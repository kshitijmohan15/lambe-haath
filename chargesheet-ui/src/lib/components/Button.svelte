<script lang="ts">
	import type { Snippet } from 'svelte';
	import type { HTMLButtonAttributes } from 'svelte/elements';

	type Variant = 'primary' | 'secondary' | 'danger' | 'ghost';
	type Size = 'sm' | 'md';

	interface Props extends Omit<HTMLButtonAttributes, 'class' | 'children'> {
		variant?: Variant;
		size?: Size;
		full?: boolean;
		class?: string;
		children: Snippet;
	}

	let {
		variant = 'primary',
		size = 'md',
		full = false,
		class: extraClass = '',
		type = 'button',
		disabled = false,
		children,
		...rest
	}: Props = $props();

	const VARIANT_CLASSES: Record<Variant, string> = {
		primary:
			'bg-navy text-white border-none hover:bg-navy-dk disabled:opacity-40 disabled:cursor-not-allowed',
		secondary:
			'bg-card text-ink border border-line hover:border-ink-2 disabled:opacity-40 disabled:cursor-not-allowed',
		danger:
			'bg-err text-white border-none hover:opacity-90 disabled:opacity-40 disabled:cursor-not-allowed',
		ghost:
			'bg-transparent text-ink-2 border-none hover:text-ink hover:bg-[rgba(40,35,25,0.06)] disabled:opacity-40 disabled:cursor-not-allowed'
	};

	// Size only adjusts padding for sm; md uses the Docket spec sizing directly.
	const SIZE_CLASSES: Record<Size, string> = {
		sm: 'px-[13px] py-[6px] text-[11.5px]',
		md: 'px-[17px] py-[9px] text-[12.5px]'
	};

	// Secondary size adjusts for border (1px less padding) to keep visual height consistent.
	const SECONDARY_SIZE_CLASSES: Record<Size, string> = {
		sm: 'px-[12px] py-[5px] text-[11.5px]',
		md: 'px-[15px] py-[9px] text-[12.5px]'
	};

	const sizeClass = variant === 'secondary' ? SECONDARY_SIZE_CLASSES[size] : SIZE_CLASSES[size];
</script>

<button
	{type}
	{disabled}
	class="inline-flex items-center justify-center gap-1.5 rounded-ctl font-sans font-semibold whitespace-nowrap transition-colors focus:outline-none focus:ring-2 focus:ring-navy/30 {VARIANT_CLASSES[variant]} {sizeClass} {full ? 'w-full' : ''} {extraClass}"
	{...rest}
>
	{@render children()}
</button>
