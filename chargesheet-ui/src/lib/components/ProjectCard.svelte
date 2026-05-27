<script lang="ts">
	import type { Project } from '$lib/api/types';
	import { goto } from '$app/navigation';
	import { formatBytes, formatRelative } from '$lib/utils/format';
	import { projectsStore } from '$lib/stores/projects.svelte';
	import { toastsStore } from '$lib/stores/toasts.svelte';
	import Button from './Button.svelte';
	import ConfirmDialog from './ConfirmDialog.svelte';

	interface Props {
		project: Project;
	}

	let { project }: Props = $props();
	let confirmOpen = $state(false);
	let deleting = $state(false);

	function open() {
		void goto(`/projects/${project.id}`);
	}

	function onKey(e: KeyboardEvent) {
		if (e.key === 'Enter' || e.key === ' ') {
			e.preventDefault();
			open();
		}
	}

	async function performDelete() {
		deleting = true;
		try {
			await projectsStore.remove(project.id);
			toastsStore.success(`Deleted "${project.name}"`);
		} catch (e) {
			toastsStore.error(e instanceof Error ? e.message : 'Failed to delete project');
		} finally {
			deleting = false;
		}
	}
</script>

<div
	role="link"
	tabindex="0"
	class="group relative flex flex-col gap-2 rounded-lg border border-gray-200 bg-white p-4 transition-shadow hover:shadow-md focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-600 cursor-pointer"
	onclick={open}
	onkeydown={onKey}
>
	<div class="flex items-start justify-between gap-2">
		<h3 class="line-clamp-1 text-base font-semibold text-gray-900">{project.name}</h3>
		<button
			type="button"
			class="invisible rounded p-1 text-gray-400 hover:bg-red-50 hover:text-red-600 group-hover:visible focus-visible:visible"
			aria-label="Delete project"
			onclick={(e) => {
				e.stopPropagation();
				confirmOpen = true;
			}}
		>
			<svg viewBox="0 0 20 20" class="h-4 w-4" fill="currentColor">
				<path
					fill-rule="evenodd"
					d="M8.75 1A1.75 1.75 0 0 0 7 2.75V3H4a1 1 0 0 0 0 2h12a1 1 0 1 0 0-2h-3v-.25A1.75 1.75 0 0 0 11.25 1h-2.5ZM6 7a1 1 0 0 1 1 1v8a1 1 0 1 1-2 0V8a1 1 0 0 1 1-1Zm4 0a1 1 0 0 1 1 1v8a1 1 0 1 1-2 0V8a1 1 0 0 1 1-1Zm4 0a1 1 0 0 1 1 1v8a1 1 0 1 1-2 0V8a1 1 0 0 1 1-1Z"
					clip-rule="evenodd"
				/>
			</svg>
		</button>
	</div>
	{#if project.description}
		<p class="line-clamp-2 text-sm text-gray-600">{project.description}</p>
	{/if}
	<div class="mt-auto space-y-0.5 text-xs text-gray-500">
		<div class="line-clamp-1">{project.chargesheet.filename}</div>
		<div>
			{project.chargesheet.page_count} pages · {formatBytes(project.chargesheet.size_bytes)}
		</div>
		<div>Opened {formatRelative(project.last_opened_at)}</div>
	</div>
</div>

<ConfirmDialog
	bind:open={confirmOpen}
	title="Delete project?"
	message={`"${project.name}" and all its slices will be removed. This cannot be undone.`}
	confirmText={deleting ? 'Deleting…' : 'Delete'}
	cancelText="Cancel"
	variant="danger"
	onConfirm={performDelete}
	onCancel={() => {}}
/>
