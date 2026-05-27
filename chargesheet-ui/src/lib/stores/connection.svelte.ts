import { health } from '$lib/api/health';

const POLL_INTERVAL_MS = 5000;

class ConnectionStore {
	online = $state(true);
	private timer: ReturnType<typeof setInterval> | null = null;

	constructor() {
		if (typeof window !== 'undefined') {
			void this.poll();
			this.timer = setInterval(() => {
				void this.poll();
			}, POLL_INTERVAL_MS);
		}
	}

	async poll(): Promise<void> {
		try {
			await health();
			this.online = true;
		} catch {
			this.online = false;
		}
	}

	stop(): void {
		if (this.timer !== null) {
			clearInterval(this.timer);
			this.timer = null;
		}
	}
}

export const connectionStore = new ConnectionStore();
