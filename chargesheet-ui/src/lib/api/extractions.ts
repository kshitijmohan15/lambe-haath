import { z } from 'zod';
import { apiFetch, apiFetchText } from './client';
import {
	ExtractionsListResponseSchema,
	JobCreatedResponseSchema,
} from './schemas';
import type {
	ExtractionsListResponse,
	JobCreatedResponse,
} from './types';

const JobIdsResponseSchema = z.object({ job_ids: z.array(z.string()) });

/** List all extraction rows for a project. */
export async function listExtractions(projectId: string): Promise<ExtractionsListResponse> {
	return apiFetch(
		`/projects/${encodeURIComponent(projectId)}/extractions`,
		{ method: 'GET' },
		ExtractionsListResponseSchema
	);
}

/** Enqueue an OCR job for a single slice. */
export async function enqueueOcr(
	projectId: string,
	sliceFilename: string
): Promise<JobCreatedResponse> {
	return apiFetch(
		`/projects/${encodeURIComponent(projectId)}/jobs/ocr`,
		{
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({ slice_filename: sliceFilename }),
		},
		JobCreatedResponseSchema
	);
}

/** Enqueue an OCR job for every slice that doesn't yet have an extraction. */
export async function enqueueOcrAll(projectId: string): Promise<{ job_ids: string[] }> {
	return apiFetch(
		`/projects/${encodeURIComponent(projectId)}/jobs/ocr/all`,
		{ method: 'POST' },
		JobIdsResponseSchema
	);
}

/** Fetch the rendered Markdown for an extraction. */
export async function getExtractionMarkdown(
	projectId: string,
	sliceFilename: string
): Promise<string> {
	return apiFetchText(
		`/projects/${encodeURIComponent(projectId)}/extractions/${encodeURIComponent(sliceFilename)}`,
		{ method: 'GET' }
	);
}
