import { apiFetch, apiFetchVoid, API_BASE_PATH } from './client';
import {
	JobCreatedResponseSchema,
	JobStatusResponseSchema,
	SliceListResponseSchema
} from './schemas';
import type {
	JobCreatedResponse,
	JobStatusResponse,
	SliceJobRequest,
	SliceListResponse
} from './types';

/** Submit a slicing job for a project. Returns `{ job_id, status: 'queued' }`. */
export async function submitSliceJob(
	projectId: string,
	body: SliceJobRequest
): Promise<JobCreatedResponse> {
	return apiFetch(
		`/projects/${encodeURIComponent(projectId)}/jobs/slice`,
		{
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify(body)
		},
		JobCreatedResponseSchema
	);
}

/** Get the status of a slicing job. */
export async function getJobStatus(
	projectId: string,
	jobId: string
): Promise<JobStatusResponse> {
	return apiFetch(
		`/projects/${encodeURIComponent(projectId)}/jobs/${encodeURIComponent(jobId)}`,
		{ method: 'GET' },
		JobStatusResponseSchema
	);
}

/** List slices already produced for a project. */
export async function listSlices(projectId: string): Promise<SliceListResponse> {
	return apiFetch(
		`/projects/${encodeURIComponent(projectId)}/slices`,
		{ method: 'GET' },
		SliceListResponseSchema
	);
}

/** URL to stream a single produced slice PDF inline. */
export const sliceUrl = (projectId: string, filename: string): string =>
	`${API_BASE_PATH}/projects/${encodeURIComponent(projectId)}/slices/${encodeURIComponent(filename)}`;

/** Delete a single saved slice from a project (204 on success). */
export async function deleteSlice(projectId: string, filename: string): Promise<void> {
	return apiFetchVoid(
		`/projects/${encodeURIComponent(projectId)}/slices/${encodeURIComponent(filename)}`,
		{ method: 'DELETE' }
	);
}
