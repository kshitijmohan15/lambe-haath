<script lang="ts">
	import Button from './Button.svelte';

	interface Props {
		open: boolean;
		title: string;
		message: string;
		confirmText?: string;
		cancelText?: string;
		variant?: 'default' | 'danger';
		onConfirm: () => void;
		onCancel: () => void;
	}

	let {
		open = $bindable(),
		title,
		message,
		confirmText = 'Confirm',
		cancelText = 'Cancel',
		variant = 'default',
		onConfirm,
		onCancel
	}: Props = $props();

	function cancel() {
		open = false;
		onCancel();
	}

	function confirm() {
		open = false;
		onConfirm();
	}

	function onBackdropClick(e: MouseEvent) {
		if (e.target === e.currentTarget) cancel();
	}

	function onBackdropKey(e: KeyboardEvent) {
		if (e.key === 'Escape') cancel();
	}
</script>

{#if open}
	<!-- svelte-ignore a11y_click_events_have_key_events -->
	<div
		class="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4"
		role="presentation"
		onclick={onBackdropClick}
		onkeydown={onBackdropKey}
	>
		<div
			class="w-full max-w-sm rounded-lg bg-white shadow-xl"
			role="dialog"
			aria-modal="true"
			aria-labelledby="confirm-title"
		>
			<div class="space-y-2 px-5 py-4">
				<h2 id="confirm-title" class="text-base font-semibold text-gray-900">{title}</h2>
				<p class="text-sm text-gray-600">{message}</p>
			</div>
			<div class="flex justify-end gap-2 border-t border-gray-100 px-5 py-3">
				<Button variant="secondary" size="sm" onclick={cancel}>{cancelText}</Button>
				<Button variant={variant === 'danger' ? 'danger' : 'primary'} size="sm" onclick={confirm}>
					{confirmText}
				</Button>
			</div>
		</div>
	</div>
{/if}
