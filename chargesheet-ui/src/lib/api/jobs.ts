import { apiFetch, apiFetchVoid } from './client';
import { JobLogsResponseSchema, JobSchema } from './schemas';
import type { Job, JobLogsResponse } from './types';

/** Get the full status of a job. */
export async function getJob(projectId: string, jobId: string): Promise<Job> {
	return apiFetch(
		`/projects/${encodeURIComponent(projectId)}/jobs/${encodeURIComponent(jobId)}`,
		{ method: 'GET' },
		JobSchema
	);
}

/** Fetch all log lines for a job. */
export async function getJobLogs(jobId: string): Promise<JobLogsResponse> {
	return apiFetch(
		`/jobs/${encodeURIComponent(jobId)}/logs`,
		{ method: 'GET' },
		JobLogsResponseSchema
	);
}

/** Request cancellation of a running job. Returns immediately; the actual
 * transition to 'canceled' status happens when the agent acknowledges. */
export async function cancelJob(jobId: string): Promise<void> {
	return apiFetchVoid(
		`/jobs/${encodeURIComponent(jobId)}/cancel`,
		{ method: 'POST' }
	);
}
