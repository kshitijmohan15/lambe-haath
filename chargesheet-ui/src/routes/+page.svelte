<script lang="ts">
	import { onMount } from 'svelte';
	import { projectsStore } from '$lib/stores/projects.svelte';
	import { connectionStore } from '$lib/stores/connection.svelte';
	import ProjectCard from '$lib/components/ProjectCard.svelte';
	import EmptyState from '$lib/components/EmptyState.svelte';
	import Button from '$lib/components/Button.svelte';

	onMount(() => {
		void projectsStore.load();
	});

	function retry() {
		void projectsStore.load();
	}
</script>

<!-- Top bar -->
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
			<h1 class="font-serif text-[30px] font-semibold leading-tight text-ink">Matters</h1>
			<p class="mt-1 font-sans text-[13px] font-medium text-ink-2">
				{projectsStore.projects.length} active · one chargesheet per matter
			</p>
		</div>
		<a
			href="/new"
			class="inline-flex flex-shrink-0 items-center justify-center gap-1.5 rounded-ctl bg-navy px-[17px] py-[9px] font-sans text-[12.5px] font-semibold whitespace-nowrap text-white transition-colors hover:bg-navy-dk focus:outline-none focus:ring-2 focus:ring-navy/30"
		>
			+ New matter
		</a>
	</div>

	<!-- States -->
	{#if projectsStore.loading && projectsStore.projects.length === 0}
		<!-- Loading skeletons -->
		<div
			class="mt-[24px] grid gap-4"
			style="grid-template-columns: repeat(auto-fill, minmax(380px, 1fr));"
		>
			{#each Array(3) as _, i (i)}
				<div class="h-40 animate-pulse rounded-card border border-line bg-panel"></div>
			{/each}
		</div>
	{:else if projectsStore.error}
		<!-- Error callout -->
		<div
			class="mt-[24px] rounded-ctl border border-err bg-[rgba(162,59,46,0.06)] p-6 text-sm"
		>
			<div class="mb-2 font-sans font-semibold text-err">Couldn't load matters.</div>
			<div class="mb-4 font-sans text-[13px] text-err">{projectsStore.error}</div>
			<Button variant="secondary" onclick={retry}>Retry</Button>
		</div>
	{:else if projectsStore.projects.length === 0}
		<!-- Empty state -->
		<div class="mt-[24px]">
			<EmptyState
				title="No matters yet"
				description="Create your first matter to begin slicing a chargesheet."
				action={{ label: '+ New matter', href: '/new' }}
			/>
		</div>
	{:else}
		<!-- Matters grid -->
		<div
			class="mt-[24px] grid gap-4"
			style="grid-template-columns: repeat(auto-fill, minmax(380px, 1fr));"
		>
			{#each projectsStore.projects as project (project.id)}
				<ProjectCard {project} />
			{/each}
		</div>
	{/if}
</div>
