import * as api from '$lib/api/stats';
import type { Overview, DayBucket, SlowJob, ProjectTotals } from '$lib/api/types';

class StatsStore {
	overview = $state<Overview | null>(null);
	timeseries = $state<DayBucket[]>([]);
	slow = $state<SlowJob[]>([]);
	perProject = $state<Record<string, ProjectTotals>>({});
	loading = $state(false);
	error = $state<string | null>(null);

	async loadOverview(): Promise<void> {
		this.loading = true;
		this.error = null;
		try {
			this.overview = await api.getOverview();
		} catch (e) {
			this.error = e instanceof Error ? e.message : 'Failed to load stats';
		} finally {
			this.loading = false;
		}
	}

	async loadTimeseries(from: string, to: string): Promise<void> {
		try {
			this.timeseries = await api.getTimeseries(from, to);
		} catch (e) {
			this.error = e instanceof Error ? e.message : 'Failed to load timeseries';
		}
	}

	async loadSlow(limit = 20): Promise<void> {
		try {
			this.slow = await api.getSlowJobs(limit);
		} catch (e) {
			this.error = e instanceof Error ? e.message : 'Failed to load slow jobs';
		}
	}

	async loadProject(projectId: string): Promise<void> {
		try {
			const pt = await api.getProjectStats(projectId);
			this.perProject = { ...this.perProject, [projectId]: pt };
		} catch (e) {
			this.error = e instanceof Error ? e.message : 'Failed to load project stats';
		}
	}

	clear(): void {
		this.overview = null;
		this.timeseries = [];
		this.slow = [];
		this.perProject = {};
		this.error = null;
	}
}

export const statsStore = new StatsStore();
