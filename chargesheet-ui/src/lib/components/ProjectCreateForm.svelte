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

<form class="space-y-6" onsubmit={onSubmit}>
	<!-- Matter name -->
	<div>
		<label
			for="proj-name"
			class="mb-2 block font-sans text-[10px] font-semibold uppercase tracking-[0.6px] text-ink-3"
		>
			Matter name <span class="text-err">*</span>
		</label>
		<input
			id="proj-name"
			type="text"
			required
			maxlength={200}
			bind:value={name}
			placeholder="e.g. Case 2024/CR/123 — Suresh K."
			class="w-full rounded-[9px] border border-line bg-card px-3 py-[10px] font-sans text-[13px] text-ink placeholder:text-ink-3 focus:border-navy focus:outline-none focus:ring-2 focus:ring-navy/20 disabled:cursor-not-allowed disabled:bg-panel disabled:text-ink-3"
			disabled={submitting}
		/>
	</div>

	<!-- Description -->
	<div>
		<label
			for="proj-desc"
			class="mb-2 block font-sans text-[10px] font-semibold uppercase tracking-[0.6px] text-ink-3"
		>
			Description <span class="font-normal normal-case tracking-normal text-ink-3">(optional)</span>
		</label>
		<textarea
			id="proj-desc"
			rows="3"
			maxlength={2000}
			bind:value={description}
			placeholder="Notes for your own reference."
			class="w-full rounded-[9px] border border-line bg-card px-3 py-[10px] font-sans text-[13px] text-ink placeholder:text-ink-3 focus:border-navy focus:outline-none focus:ring-2 focus:ring-navy/20 disabled:cursor-not-allowed disabled:bg-panel disabled:text-ink-3"
			disabled={submitting}
		></textarea>
	</div>

	<!-- Chargesheet PDF -->
	<div>
		<span class="mb-2 block font-sans text-[10px] font-semibold uppercase tracking-[0.6px] text-ink-3">
			Chargesheet PDF <span class="text-err">*</span>
		</span>
		<label
			for="proj-file"
			class="block cursor-pointer rounded-[11px] border border-dashed px-4 py-8 text-center transition-colors {dragging
				? 'border-navy bg-navy-soft/30'
				: 'border-line bg-paper hover:border-navy hover:bg-navy-soft/30'}"
			ondragover={onDragOver}
			ondragleave={onDragLeave}
			ondrop={onDrop}
		>
			{#if file}
				<div class="font-serif text-[14px] font-medium text-ink">{file.name}</div>
				<div class="mt-1 font-mono text-[11px] text-ink-3">{formatBytes(file.size)} · Click or drop another to replace</div>
			{:else}
				<div class="font-serif text-[14px] font-medium text-ink">Drop a PDF here or click to choose</div>
				<div class="mt-1 font-mono text-[11px] text-ink-3">Only .pdf files are accepted</div>
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
			<p class="mt-1.5 font-sans text-[12px] text-err">{fileError}</p>
		{/if}
	</div>

	<!-- Actions -->
	<div class="mt-6 flex justify-end gap-3 border-t border-line pt-6">
		<Button variant="secondary" onclick={onCancel} disabled={submitting}>Cancel</Button>
		<Button type="submit" variant="primary" disabled={!canSubmit}>
			{submitting ? 'Creating…' : 'Create matter →'}
		</Button>
	</div>
</form>
