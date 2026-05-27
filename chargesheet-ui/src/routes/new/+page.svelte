<script lang="ts">
	import ProjectCreateForm from '$lib/components/ProjectCreateForm.svelte';
</script>

<div class="mx-auto max-w-2xl px-6 py-10">
	<div class="mb-6">
		<a href="/" class="text-sm text-blue-600 hover:underline">← Back to projects</a>
		<h1 class="mt-2 text-2xl font-semibold text-gray-900">New project</h1>
		<p class="text-sm text-gray-500">Upload a chargesheet PDF to start.</p>
	</div>
	<ProjectCreateForm />
</div>
