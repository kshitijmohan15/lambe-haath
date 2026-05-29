<script lang="ts">
	import { toastsStore } from '$lib/stores/toasts.svelte';

	/** Left-border accent per variant (plus base classes shared by all). */
	const VARIANT_ACCENT: Record<'success' | 'error' | 'info', string> = {
		success: 'border-l-4 border-l-ok',
		error:   'border-l-4 border-l-err',
		info:    'border-l-4 border-l-navy',
	};
</script>

<div class="pointer-events-none fixed bottom-6 right-6 z-50 flex flex-col gap-2">
	{#each toastsStore.toasts as toast (toast.id)}
		<div
			class="pointer-events-auto min-w-[280px] max-w-[420px] overflow-hidden rounded-[10px] border border-line bg-card shadow-[0_6px_20px_rgba(40,35,25,0.12)] {VARIANT_ACCENT[toast.type]}"
			role="status"
		>
			<div class="flex items-start gap-3 px-4 py-3">
				<div class="min-w-0 flex-1">
					<div class="font-sans text-[12.5px] text-ink-2">{toast.message}</div>
				</div>
				<button
					type="button"
					aria-label="Dismiss"
					class="flex-shrink-0 rounded p-0.5 text-ink-3 transition-colors hover:bg-panel hover:text-ink focus:outline-none focus:ring-2 focus:ring-navy/30"
					onclick={() => toastsStore.dismiss(toast.id)}
				>
					<svg class="h-4 w-4" viewBox="0 0 20 20" fill="currentColor" aria-hidden="true">
						<path
							d="M4 4a1 1 0 0 1 1.4 0L10 8.6l4.6-4.6a1 1 0 1 1 1.4 1.4L11.4 10l4.6 4.6a1 1 0 1 1-1.4 1.4L10 11.4l-4.6 4.6a1 1 0 1 1-1.4-1.4L8.6 10 4 5.4A1 1 0 0 1 4 4Z"
						/>
					</svg>
				</button>
			</div>
		</div>
	{/each}
</div>
