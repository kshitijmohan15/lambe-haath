import { z } from 'zod';
import { apiFetch, apiFetchText } from './client';
import {
	JobCreatedResponseSchema,
	PromptOutputsListResponseSchema,
} from './schemas';
import type {
	JobCreatedResponse,
	PromptOutputsListResponse,
} from './types';

const JobIdsResponseSchema = z.object({ job_ids: z.array(z.string()) });

/** The 5 known prompt names this UI exposes. Keep in sync with logos's
 * src/api/handlers_prompts.zig KNOWN_PROMPTS. */
export const KNOWN_PROMPTS = [
	'charge_memo_analysis',
	'imputation_scrutiny',
	'time_chart',
	'evidence_audit',
	'objection_brief',
] as const;
export type KnownPromptName = (typeof KNOWN_PROMPTS)[number];

/** List all prompt-output rows for a project. */
export async function listPromptOutputs(projectId: string): Promise<PromptOutputsListResponse> {
	return apiFetch(
		`/projects/${encodeURIComponent(projectId)}/prompts`,
		{ method: 'GET' },
		PromptOutputsListResponseSchema
	);
}

/** Enqueue a single prompt run. */
export async function enqueuePrompt(
	projectId: string,
	promptName: KnownPromptName
): Promise<JobCreatedResponse> {
	return apiFetch(
		`/projects/${encodeURIComponent(projectId)}/jobs/prompt`,
		{
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({ prompt_name: promptName }),
		},
		JobCreatedResponseSchema
	);
}

/** Enqueue all 5 prompts at once. */
export async function enqueuePromptAll(projectId: string): Promise<{ job_ids: string[] }> {
	return apiFetch(
		`/projects/${encodeURIComponent(projectId)}/jobs/prompt/all`,
		{ method: 'POST' },
		JobIdsResponseSchema
	);
}

/** Fetch the rendered Markdown for a prompt output. */
export async function getPromptMarkdown(
	projectId: string,
	promptName: KnownPromptName
): Promise<string> {
	return apiFetchText(
		`/projects/${encodeURIComponent(projectId)}/prompts/${encodeURIComponent(promptName)}`,
		{ method: 'GET' }
	);
}

export type ExportFormat = 'md' | 'docx';

/**
 * Build the URL the browser should navigate to in order to download an
 * export. The endpoint sets Content-Disposition: attachment so the browser
 * saves the response to the user's configured Downloads folder.
 *
 * If `names` has exactly one entry, the response is a single .md / .docx file.
 * Otherwise (or if `names` is undefined → all prompts), it's a .zip bundle.
 */
export function buildPromptsExportUrl(
	projectId: string,
	format: ExportFormat,
	names?: readonly KnownPromptName[]
): string {
	const params = new URLSearchParams({ format });
	if (names && names.length > 0) params.set('names', names.join(','));
	return `/api/v1/projects/${encodeURIComponent(projectId)}/prompts/export?${params.toString()}`;
}

/**
 * Trigger a download by creating a hidden <a download> and clicking it.
 * The browser handles writing to the OS's Downloads folder.
 */
export function triggerExportDownload(
	projectId: string,
	format: ExportFormat,
	names?: readonly KnownPromptName[]
): void {
	const a = document.createElement('a');
	a.href = buildPromptsExportUrl(projectId, format, names);
	a.rel = 'noopener';
	// Letting the server's Content-Disposition decide the filename — leaving
	// `download` as the empty string is enough to opt into download behavior
	// without overriding the server's suggested name.
	a.download = '';
	document.body.appendChild(a);
	a.click();
	a.remove();
}
