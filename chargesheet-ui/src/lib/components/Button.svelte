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
			'bg-blue-600 text-white hover:bg-blue-700 focus-visible:outline-blue-600 disabled:bg-blue-300',
		secondary:
			'bg-white text-gray-800 border border-gray-300 hover:bg-gray-50 focus-visible:outline-gray-400 disabled:bg-gray-100 disabled:text-gray-400',
		danger:
			'bg-red-600 text-white hover:bg-red-700 focus-visible:outline-red-600 disabled:bg-red-300',
		ghost:
			'bg-transparent text-gray-700 hover:bg-gray-100 focus-visible:outline-gray-400 disabled:text-gray-400'
	};

	const SIZE_CLASSES: Record<Size, string> = {
		sm: 'px-2.5 py-1 text-sm',
		md: 'px-4 py-2 text-sm'
	};
</script>

<button
	{type}
	{disabled}
	class="inline-flex items-center justify-center gap-1.5 rounded font-medium transition-colors focus-visible:outline-2 focus-visible:outline-offset-2 disabled:cursor-not-allowed {VARIANT_CLASSES[
		variant
	]} {SIZE_CLASSES[size]} {full ? 'w-full' : ''} {extraClass}"
	{...rest}
>
	{@render children()}
</button>
