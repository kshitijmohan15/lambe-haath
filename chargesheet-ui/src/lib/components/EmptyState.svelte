<script lang="ts">
	interface ActionHref {
		label: string;
		href: string;
	}
	interface ActionClick {
		label: string;
		onClick: () => void;
	}
	type Action = ActionHref | ActionClick;

	interface Props {
		title: string;
		description?: string;
		action?: Action;
	}

	let { title, description, action }: Props = $props();
</script>

<div class="flex flex-col items-center justify-center gap-3 py-16 text-center">
	<h2 class="text-xl font-semibold text-gray-800">{title}</h2>
	{#if description}
		<p class="max-w-md text-sm text-gray-500">{description}</p>
	{/if}
	{#if action}
		{#if 'href' in action}
			<a
				href={action.href}
				class="mt-2 inline-flex items-center rounded bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700"
			>
				{action.label}
			</a>
		{:else}
			<button
				type="button"
				onclick={action.onClick}
				class="mt-2 inline-flex items-center rounded bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700"
			>
				{action.label}
			</button>
		{/if}
	{/if}
</div>
