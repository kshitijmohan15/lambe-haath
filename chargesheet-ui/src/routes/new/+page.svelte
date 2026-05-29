<script lang="ts">
	import { connectionStore } from '$lib/stores/connection.svelte';
	import ProjectCreateForm from '$lib/components/ProjectCreateForm.svelte';
</script>

<!-- Top bar (identical to Matters page) -->
<header class="flex h-[56px] items-center justify-between border-b border-line bg-panel px-[28px]">
	<!-- Brand mark: C tile + CHARGESHEET label -->
	<div class="flex items-center gap-2.5">
		<div
			class="grid h-[26px] w-[26px] flex-shrink-0 place-items-center rounded-[6px] bg-navy font-serif text-[13px] font-bold text-white"
			aria-hidden="true"
		>
			C
		</div>
		<span class="font-sans text-[12px] font-bold tracking-[1.4px] text-ink uppercase">
			CHARGESHEET
		</span>
	</div>

	<!-- Daemon connection indicator -->
	<div class="flex items-center gap-1.5">
		<span
			class="h-[7px] w-[7px] flex-shrink-0 rounded-full {connectionStore.online
				? 'bg-ok'
				: 'bg-err'}"
		></span>
		<span class="font-sans text-[11px] font-semibold text-ink-2">
			{connectionStore.online ? 'Daemon connected' : 'Daemon offline'}
		</span>
	</div>
</header>

<!-- Page content -->
<div class="px-[40px] pt-[28px] pb-[40px]">
	<!-- Heading row -->
	<div class="flex items-end justify-between gap-4">
		<div>
			<h1 class="font-serif text-[30px] font-semibold leading-tight text-ink">New matter</h1>
			<p class="mt-1 font-sans text-[13px] font-medium text-ink-2">
				Upload a chargesheet PDF. We'll slice it next.
			</p>
		</div>
		<a
			href="/"
			class="inline-flex flex-shrink-0 items-center justify-center gap-1.5 rounded-[8px] border border-line bg-card px-[15px] py-[9px] font-sans text-[12.5px] font-semibold whitespace-nowrap text-ink transition-colors hover:border-ink-2 focus:outline-none focus:ring-2 focus:ring-navy/30"
		>
			← Back
		</a>
	</div>

	<!-- Form card -->
	<div class="mx-auto mt-[24px] max-w-2xl">
		<div class="rounded-card border border-line bg-card p-8 shadow-[0_1px_2px_rgba(40,35,25,0.04)]">
			<ProjectCreateForm />
		</div>
	</div>
</div>
