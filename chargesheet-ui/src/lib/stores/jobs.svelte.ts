import * as api from '$lib/api/jobs';
import type { Job, JobStatus } from '$lib/api/types';

const TERMINAL: ReadonlySet<JobStatus> = new Set(['completed', 'failed', 'canceled']);

class JobsStore {
	/** Map job_id → most recent Job snapshot. Reactive via Svelte 5 runes. */
	live = $state<Map<string, Job>>(new Map());

	/** Active polling intervals, keyed by job_id (private; not reactive). */
	private timers = new Map<string, ReturnType<typeof setInterval>>();

	/** Start tracking a job. Calls `onTerminal` once when the job reaches a
	 * terminal status (passing the final Job snapshot). Subsequent ticks are no-ops. */
	track(projectId: string, jobId: string, onTerminal?: (job: Job) => void): void {
		if (this.timers.has(jobId)) return; // already tracking

		const tick = async () => {
			try {
				const job = await api.getJob(projectId, jobId);
				this.live.set(jobId, job);
				this.live = new Map(this.live); // trigger Svelte reactivity
				if (TERMINAL.has(job.status)) {
					this.stop(jobId);
					if (onTerminal) onTerminal(job);
				}
			} catch (e) {
				// Network blip — keep polling; the next tick may succeed.
				console.warn(`job poll ${jobId} failed`, e);
			}
		};
		void tick();
		this.timers.set(jobId, setInterval(tick, 500));
	}

	/** Stop tracking a job (but keep its last snapshot in `live`). */
	stop(jobId: string): void {
		const t = this.timers.get(jobId);
		if (t !== undefined) {
			clearInterval(t);
			this.timers.delete(jobId);
		}
	}

	/** Cancel a job via the daemon. The polling loop will pick up the
	 * 'canceled' status on its next tick and stop. */
	async cancel(jobId: string): Promise<void> {
		await api.cancelJob(jobId);
	}

	/** Stop tracking all jobs (e.g., on route change). */
	stopAll(): void {
		for (const t of this.timers.values()) clearInterval(t);
		this.timers.clear();
	}

	get(jobId: string): Job | undefined {
		return this.live.get(jobId);
	}
}

export const jobsStore = new JobsStore();
