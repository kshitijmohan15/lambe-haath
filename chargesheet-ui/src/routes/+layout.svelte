<script lang="ts">
	import '../app.css';
	import favicon from '$lib/assets/favicon.svg';
	import { page } from '$app/state';
	import ToastContainer from '$lib/components/ToastContainer.svelte';
	import ConnectionBanner from '$lib/components/ConnectionBanner.svelte';

	let { children } = $props();

	$effect(() => {
		if (typeof document === 'undefined') return;
		const id = page.route.id;
		let title = 'Chargesheet Tool';
		if (id === '/new') {
			title = 'New Project — Chargesheet Tool';
		} else if (id === '/projects/[id]') {
			const projectName: unknown =
				typeof page.data === 'object' && page.data !== null && 'project' in page.data
					? (page.data as { project?: { name?: unknown } }).project?.name
					: undefined;
			if (typeof projectName === 'string' && projectName.length > 0) {
				title = `${projectName} — Chargesheet Tool`;
			}
		}
		document.title = title;
	});
</script>

<svelte:head>
	<link rel="icon" href={favicon} />
</svelte:head>

<div class="min-h-screen bg-gray-50 text-gray-900 antialiased">
	<ConnectionBanner />
	{@render children()}
	<ToastContainer />
</div>
