import { apiFetch } from './client';
import {
	OverviewSchema,
	ProjectTotalsSchema,
	TimeseriesResponseSchema,
	SlowJobsResponseSchema,
} from './schemas';

export async function getOverview() {
	return apiFetch('/stats', { method: 'GET' }, OverviewSchema);
}

export async function getProjectStats(projectId: string) {
	return apiFetch(
		`/stats/project/${encodeURIComponent(projectId)}`,
		{ method: 'GET' },
		ProjectTotalsSchema
	);
}

export async function getTimeseries(fromIso: string, toIso: string) {
	const qs = new URLSearchParams({ from: fromIso, to: toIso }).toString();
	return apiFetch(`/stats/timeseries?${qs}`, { method: 'GET' }, TimeseriesResponseSchema);
}

export async function getSlowJobs(limit = 20) {
	return apiFetch(`/stats/slow?limit=${limit}`, { method: 'GET' }, SlowJobsResponseSchema);
}
