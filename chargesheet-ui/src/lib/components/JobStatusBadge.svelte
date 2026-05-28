<script lang="ts">
	import type { JobStatus } from '$lib/api/types';

	let { status, progress = 0 }: { status: JobStatus | null; progress?: number } = $props();

	const tone: Record<JobStatus, string> = {
		queued:    'bg-gray-100 text-gray-700',
		running:   'bg-blue-100 text-blue-700',
		completed: 'bg-green-100 text-green-700',
		failed:    'bg-red-100 text-red-700',
		canceled:  'bg-yellow-100 text-yellow-700',
	};

	const label: Record<JobStatus, string> = {
		queued:    'Queued',
		running:   'Running',
		completed: 'Done',
		failed:    'Failed',
		canceled:  'Canceled',
	};
</script>

{#if status}
	<span class="inline-flex items-center gap-1.5 rounded px-2 py-0.5 text-xs font-medium {tone[status]}">
		{label[status]}
		{#if status === 'running' && progress > 0}
			<span class="text-[10px] opacity-75">{Math.round(progress * 100)}%</span>
		{/if}
	</span>
{/if}
