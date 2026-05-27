export type ToastType = 'success' | 'error' | 'info';

export interface Toast {
	id: string;
	type: ToastType;
	message: string;
}

const DURATION_BY_TYPE: Record<ToastType, number> = {
	success: 4000,
	error: 6000,
	info: 4000
};

class ToastsStore {
	toasts = $state<Toast[]>([]);

	/** Show a toast. Returns the toast id; auto-dismisses after `duration` ms. */
	show(type: ToastType, message: string, duration?: number): string {
		const id = crypto.randomUUID();
		const ms = duration ?? DURATION_BY_TYPE[type];
		this.toasts = [...this.toasts, { id, type, message }];
		if (typeof window !== 'undefined') {
			setTimeout(() => this.dismiss(id), ms);
		}
		return id;
	}

	success(message: string): string {
		return this.show('success', message);
	}
	error(message: string): string {
		return this.show('error', message);
	}
	info(message: string): string {
		return this.show('info', message);
	}

	dismiss(id: string): void {
		this.toasts = this.toasts.filter((t) => t.id !== id);
	}
}

export const toastsStore = new ToastsStore();
