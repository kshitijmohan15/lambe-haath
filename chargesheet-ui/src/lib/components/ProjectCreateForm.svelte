<script lang="ts">
	import { goto } from '$app/navigation';
	import { projectsStore } from '$lib/stores/projects.svelte';
	import { toastsStore } from '$lib/stores/toasts.svelte';
	import { formatBytes } from '$lib/utils/format';
	import Button from './Button.svelte';

	let name = $state('');
	let description = $state('');
	let file = $state<File | null>(null);
	let dragging = $state(false);
	let submitting = $state(false);
	let fileError = $state<string | null>(null);

	let canSubmit = $derived(name.trim().length > 0 && file !== null && !submitting);

	function setFile(f: File | null) {
		fileError = null;
		if (!f) {
			file = null;
			return;
		}
		const isPdfMime = f.type === 'application/pdf';
		const isPdfName = f.name.toLowerCase().endsWith('.pdf');
		if (!isPdfMime && !isPdfName) {
			fileError = 'File must be a PDF';
			file = null;
			return;
		}
		file = f;
	}

	function onFileChange(e: Event) {
		const f = (e.target as HTMLInputElement).files?.[0] ?? null;
		setFile(f);
	}

	function onDragOver(e: DragEvent) {
		e.preventDefault();
		dragging = true;
	}
	function onDragLeave() {
		dragging = false;
	}
	function onDrop(e: DragEvent) {
		e.preventDefault();
		dragging = false;
		const f = e.dataTransfer?.files?.[0] ?? null;
		setFile(f);
	}

	async function onSubmit(e: Event) {
		e.preventDefault();
		if (!canSubmit || !file) return;
		submitting = true;
		try {
			const project = await projectsStore.create({
				name: name.trim(),
				description: description.trim(),
				chargesheet: file
			});
			toastsStore.success(`Created "${project.name}"`);
			await goto(`/projects/${project.id}`);
		} catch (e) {
			toastsStore.error(e instanceof Error ? e.message : 'Failed to create project');
			submitting = false;
		}
	}

	function onCancel() {
		void goto('/');
	}
</script>

<form class="mx-auto max-w-xl space-y-6" onsubmit={onSubmit}>
	<div class="space-y-1">
		<label for="proj-name" class="block text-sm font-medium text-gray-700">
			Project name <span class="text-red-500">*</span>
		</label>
		<input
			id="proj-name"
			type="text"
			required
			maxlength={200}
			bind:value={name}
			placeholder="e.g. Case 2024/CR/123 — Suresh K."
			class="block w-full rounded border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
			disabled={submitting}
		/>
	</div>

	<div class="space-y-1">
		<label for="proj-desc" class="block text-sm font-medium text-gray-700">
			Description <span class="text-gray-400">(optional)</span>
		</label>
		<textarea
			id="proj-desc"
			rows="3"
			maxlength={2000}
			bind:value={description}
			placeholder="Notes for your own reference."
			class="block w-full rounded border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
			disabled={submitting}
		></textarea>
	</div>

	<div class="space-y-1">
		<span class="block text-sm font-medium text-gray-700">
			Chargesheet PDF <span class="text-red-500">*</span>
		</span>
		<label
			for="proj-file"
			class="flex cursor-pointer flex-col items-center justify-center gap-2 rounded border-2 border-dashed px-6 py-10 text-center text-sm transition-colors {dragging
				? 'border-blue-500 bg-blue-50 text-blue-700'
				: 'border-gray-300 bg-gray-50 text-gray-600 hover:bg-gray-100'}"
			ondragover={onDragOver}
			ondragleave={onDragLeave}
			ondrop={onDrop}
		>
			{#if file}
				<div class="font-medium text-gray-900">{file.name}</div>
				<div class="text-xs text-gray-500">{formatBytes(file.size)}</div>
				<div class="text-xs text-blue-600 underline">Click or drop another to replace</div>
			{:else}
				<div class="font-medium">Drop a PDF here, or click to browse</div>
				<div class="text-xs">Only .pdf files are accepted</div>
			{/if}
			<input
				id="proj-file"
				type="file"
				accept="application/pdf,.pdf"
				class="hidden"
				onchange={onFileChange}
				disabled={submitting}
			/>
		</label>
		{#if fileError}
			<p class="text-sm text-red-600">{fileError}</p>
		{/if}
	</div>

	<div class="flex items-center justify-end gap-2">
		<Button variant="secondary" onclick={onCancel} disabled={submitting}>Cancel</Button>
		<Button type="submit" variant="primary" disabled={!canSubmit}>
			{submitting ? 'Creating…' : 'Create project'}
		</Button>
	</div>
</form>
