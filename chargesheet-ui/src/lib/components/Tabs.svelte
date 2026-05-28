<script lang="ts">
	interface Tab {
		key: string;
		label: string;
		badge?: number | string;
	}

	let {
		tabs,
		active = $bindable(),
	}: {
		tabs: Tab[];
		active: string;
	} = $props();
</script>

<div class="border-b border-gray-200">
	<nav class="flex gap-6 px-6" aria-label="Tabs">
		{#each tabs as tab (tab.key)}
			<button
				type="button"
				class="border-b-2 px-1 py-2.5 text-sm font-medium {active === tab.key
					? 'border-blue-500 text-blue-600'
					: 'border-transparent text-gray-500 hover:border-gray-300 hover:text-gray-700'}"
				onclick={() => (active = tab.key)}
			>
				{tab.label}
				{#if tab.badge !== undefined}
					<span class="ml-1 rounded bg-gray-100 px-1.5 py-0.5 text-xs text-gray-700">
						{tab.badge}
					</span>
				{/if}
			</button>
		{/each}
	</nav>
</div>
