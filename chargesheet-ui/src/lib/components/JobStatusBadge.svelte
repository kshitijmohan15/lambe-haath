<script lang="ts">
	import type { JobStatus } from '$lib/api/types';

	let { status, progress = 0 }: { status: JobStatus | null; progress?: number } = $props();

	// Each entry: [label, text-color class, background class, border class, dot-opacity]
	type ChipConfig = {
		label: string;
		textClass: string;
		bgStyle: string;
		border: boolean;
		dotOpacity: number;
	};

	const chipMap: Record<JobStatus, ChipConfig> = {
		completed: {
			label: 'Done',
			textClass: 'text-ok',
			bgStyle: 'rgba(79,122,82,0.10)',
			border: false,
			dotOpacity: 1
		},
		running: {
			label: 'Running',
			textClass: 'text-warn',
			bgStyle: 'rgba(176,122,46,0.10)',
			border: false,
			dotOpacity: 1
		},
		queued: {
			label: 'Queued',
			textClass: 'text-ink-2',
			bgStyle: 'rgba(40,35,25,0.06)',
			border: false,
			dotOpacity: 1
		},
		pending: {
			label: 'Pending',
			textClass: 'text-ink-3',
			bgStyle: 'transparent',
			border: true,
			dotOpacity: 0.4
		},
		failed: {
			label: 'Failed',
			textClass: 'text-err',
			bgStyle: 'rgba(162,59,46,0.10)',
			border: false,
			dotOpacity: 1
		},
		canceled: {
			label: 'Canceled',
			textClass: 'text-ink-3',
			bgStyle: 'rgba(40,35,25,0.06)',
			border: false,
			dotOpacity: 1
		}
	};

	const chip = $derived(status ? chipMap[status] : null);
</script>

{#if status && chip}
	<span
		class="inline-flex items-center gap-[6px] rounded-full px-[9px] py-[3px] font-sans font-semibold text-[11px] tracking-[0.2px] whitespace-nowrap {chip.textClass}"
		style="background:{chip.bgStyle};{chip.border ? 'border:1px solid rgba(40,35,25,0.11);' : ''}"
	>
		<span
			class="inline-block h-[6px] w-[6px] shrink-0 rounded-full bg-current"
			style="opacity:{chip.dotOpacity}"
		></span>
		{chip.label}
		{#if status === 'running' && progress > 0}
			<span class="font-normal opacity-75">{Math.round(progress * 100)}%</span>
		{/if}
	</span>
{/if}
