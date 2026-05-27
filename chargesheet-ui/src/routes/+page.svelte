<script lang="ts">
	import { onMount } from 'svelte';
	import { projectsStore } from '$lib/stores/projects.svelte';
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

<div class="mx-auto max-w-6xl px-6 py-10">
	<div class="mb-6 flex items-end justify-between">
		<div>
			<h1 class="text-2xl font-semibold text-gray-900">Projects</h1>
			<p class="text-sm text-gray-500">One chargesheet per project.</p>
		</div>
		<a
			href="/new"
			class="inline-flex items-center rounded bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700"
		>
			+ New project
		</a>
	</div>

	{#if projectsStore.loading && projectsStore.projects.length === 0}
		<div class="grid gap-4" style="grid-template-columns: repeat(auto-fill, minmax(300px, 1fr));">
			{#each Array(3) as _, i (i)}
				<div class="h-32 animate-pulse rounded-lg border border-gray-200 bg-gray-100"></div>
			{/each}
		</div>
	{:else if projectsStore.error}
		<div class="rounded border border-red-200 bg-red-50 p-6 text-sm text-red-700">
			<div class="mb-3 font-medium">Couldn't load projects.</div>
			<div class="mb-3 text-red-600">{projectsStore.error}</div>
			<Button variant="secondary" onclick={retry}>Retry</Button>
		</div>
	{:else if projectsStore.projects.length === 0}
		<EmptyState
			title="No projects yet"
			description="Create your first project to begin splitting a chargesheet PDF."
			action={{ label: 'Create your first project', href: '/new' }}
		/>
	{:else}
		<div
			class="grid gap-4"
			style="grid-template-columns: repeat(auto-fill, minmax(300px, 1fr));"
		>
			{#each projectsStore.projects as project (project.id)}
				<ProjectCard {project} />
			{/each}
			<a
				href="/new"
				class="flex min-h-[8rem] items-center justify-center rounded-lg border-2 border-dashed border-gray-300 text-sm font-medium text-gray-500 hover:border-blue-400 hover:text-blue-600"
			>
				+ New project
			</a>
		</div>
	{/if}
</div>
