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

<div class="flex flex-col items-center justify-center py-12 px-6 text-center">
	<!-- icon: concentric circles glyph -->
	<div class="mb-5 flex h-10 w-10 items-center justify-center rounded-full border-2 border-line-2 text-ink-3">
		<div class="h-5 w-5 rounded-full border border-line text-ink-3"></div>
	</div>

	<h2 class="font-serif text-[18px] font-semibold leading-tight text-ink">{title}</h2>
	{#if description}
		<p class="mt-2 max-w-[40ch] font-sans text-[13px] text-ink-2">{description}</p>
	{/if}
	{#if action}
		<div class="mt-5">
			{#if 'href' in action}
				<a
					href={action.href}
					class="inline-flex items-center justify-center gap-1.5 rounded-ctl font-sans font-semibold text-[12.5px] whitespace-nowrap transition-colors bg-navy text-white border-none hover:bg-navy-dk focus:outline-none focus:ring-2 focus:ring-navy/30 px-[17px] py-[9px]"
				>
					{action.label}
				</a>
			{:else}
				<button
					type="button"
					onclick={action.onClick}
					class="inline-flex items-center justify-center gap-1.5 rounded-ctl font-sans font-semibold text-[12.5px] whitespace-nowrap transition-colors bg-navy text-white border-none hover:bg-navy-dk focus:outline-none focus:ring-2 focus:ring-navy/30 px-[17px] py-[9px]"
				>
					{action.label}
				</button>
			{/if}
		</div>
	{/if}
</div>
