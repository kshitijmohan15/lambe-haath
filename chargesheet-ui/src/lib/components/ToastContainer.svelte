<script lang="ts">
	import { toastsStore } from '$lib/stores/toasts.svelte';

	const TYPE_CLASSES: Record<'success' | 'error' | 'info', string> = {
		success: 'border-green-300 bg-green-50 text-green-900',
		error: 'border-red-300 bg-red-50 text-red-900',
		info: 'border-blue-300 bg-blue-50 text-blue-900'
	};
</script>

<div class="pointer-events-none fixed right-4 top-4 z-50 flex w-80 flex-col gap-2">
	{#each toastsStore.toasts as toast (toast.id)}
		<div
			class="pointer-events-auto flex items-start gap-2 rounded border px-3 py-2 text-sm shadow-md {TYPE_CLASSES[
				toast.type
			]}"
			role="status"
		>
			<div class="flex-1">{toast.message}</div>
			<button
				type="button"
				aria-label="Dismiss"
				class="rounded p-0.5 text-current opacity-60 hover:opacity-100"
				onclick={() => toastsStore.dismiss(toast.id)}
			>
				<svg class="h-4 w-4" viewBox="0 0 20 20" fill="currentColor" aria-hidden="true">
					<path
						d="M4 4a1 1 0 0 1 1.4 0L10 8.6l4.6-4.6a1 1 0 1 1 1.4 1.4L11.4 10l4.6 4.6a1 1 0 1 1-1.4 1.4L10 11.4l-4.6 4.6a1 1 0 1 1-1.4-1.4L8.6 10 4 5.4A1 1 0 0 1 4 4Z"
					/>
				</svg>
			</button>
		</div>
	{/each}
</div>
