<script lang="ts">
	import type { Project } from '$lib/api/types';
	import { goto } from '$app/navigation';
	import { formatRelative } from '$lib/utils/format';
	import { projectsStore } from '$lib/stores/projects.svelte';
	import { toastsStore } from '$lib/stores/toasts.svelte';
	import ConfirmDialog from './ConfirmDialog.svelte';
	import ProgressRing from './ProgressRing.svelte';

	interface Props {
		project: Project;
	}

	let { project }: Props = $props();
	let confirmOpen = $state(false);
	let deleting = $state(false);

	const stages: Record<string, string> = {
		slice: 'Slice',
		extract: 'Extract',
		analyze: 'Analyze',
		review: 'Review'
	};

	const stage = $derived(stages[project.current_stage] ?? 'Slice');

	// Completion across the whole pipeline: each of (slice exists, extractions, prompts) contributes 1/3.
	const completionPercent = $derived.by(() => {
		const sliceFrac = project.slice_count > 0 ? 1 : 0;
		const extractFrac =
			project.slice_count > 0 ? Math.min(1, project.extraction_count / project.slice_count) : 0;
		const promptFrac = Math.min(1, project.prompt_count / 5);
		return (sliceFrac + extractFrac + promptFrac) / 3;
	});

	// relativeUpdated: use last_opened_at (the most recently-touched timestamp available)
	const relativeUpdated = $derived(formatRelative(project.last_opened_at));

	// pageCount from chargesheet metadata
	const pageCount = $derived(project.chargesheet.page_count);

	// Secondary (citation) line: chargesheet filename in mono/navy — the most
	// meaningful identifier available. No dedicated "citation" field on the schema.
	const citation = $derived(project.chargesheet.filename);

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

<a
	href={`/projects/${project.id}`}
	class="group relative block rounded-card border border-line bg-card p-5 transition-all duration-150 hover:-translate-y-px hover:shadow-[0_6px_20px_rgba(40,35,25,0.10)] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-navy/40"
	style="box-shadow: 0 1px 2px rgba(40,35,25,0.04);"
>
	<!-- Header: matter name + filename column (flex-1 min-w-0 critical), delete slot, progress ring.
	     The delete button reserves its space always (so no layout shift on hover) and uses opacity
	     to toggle visibility. This keeps it left of the ring instead of overlapping it. -->
	<div class="flex items-start gap-2">
		<div class="min-w-0 flex-1">
			<div class="truncate font-serif text-[18px] font-semibold leading-tight text-ink">
				{project.name}
			</div>
			<div class="mt-1 truncate font-mono text-[11px] font-medium text-navy">
				{citation}
			</div>
		</div>
		<button
			type="button"
			class="flex h-8 w-8 shrink-0 items-center justify-center rounded text-ink-3 opacity-0 transition-opacity hover:bg-[rgba(162,59,46,0.08)] hover:text-err focus-visible:opacity-100 group-hover:opacity-100"
			aria-label="Delete matter"
			onclick={(e) => {
				e.preventDefault();
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
		<ProgressRing percent={completionPercent} />
	</div>

	<!-- Description (serif, ink-2) — only if present -->
	{#if project.description}
		<div class="mt-3 line-clamp-3 font-serif text-[14px] font-normal leading-[1.7] text-ink-2">
			{project.description}
		</div>
	{/if}

	<!-- Divider -->
	<div class="mt-4 border-t border-line-2 pt-3"></div>

	<!-- Footer: page count + stage/updated pill -->
	<div class="flex items-center justify-between gap-3">
		<div class="flex items-center gap-3 font-mono text-[11px] font-medium text-ink-3">
			<span>{pageCount}p</span> · <span>{project.slice_count} slices</span>
		</div>
		<span
			class="whitespace-nowrap rounded-full bg-navy-soft px-2.5 py-1 font-sans text-[11px] font-semibold text-navy"
		>
			{stage} · {relativeUpdated}
		</span>
	</div>

</a>

<ConfirmDialog
	bind:open={confirmOpen}
	title="Delete matter?"
	message={`"${project.name}" and all its slices will be removed. This cannot be undone.`}
	confirmText={deleting ? 'Deleting…' : 'Delete'}
	cancelText="Cancel"
	variant="danger"
	onConfirm={performDelete}
	onCancel={() => {}}
/>
