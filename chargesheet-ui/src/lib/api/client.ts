import type { z } from 'zod';
import { ApiErrorSchema } from './schemas';

export const API_BASE_PATH = '/api/v1';

export class DaemonError extends Error {
	constructor(
		public code: string,
		message: string,
		public httpStatus: number | null = null,
		public details: unknown = null
	) {
		super(message);
		this.name = 'DaemonError';
	}
}

async function executeRequest(path: string, init: RequestInit): Promise<Response> {
	let response: Response;
	try {
		response = await fetch(`${API_BASE_PATH}${path}`, init);
	} catch (e) {
		throw new DaemonError(
			'NETWORK_ERROR',
			e instanceof Error ? e.message : 'Network request failed'
		);
	}

	if (!response.ok) {
		let parsed: unknown = null;
		try {
			parsed = await response.json();
		} catch {
			// non-JSON or empty error body — fall through with parsed = null
		}
		const errBody = ApiErrorSchema.safeParse(parsed);
		if (errBody.success) {
			throw new DaemonError(
				errBody.data.code,
				errBody.data.message,
				response.status,
				errBody.data.details ?? null
			);
		}
		throw new DaemonError(
			'HTTP_ERROR',
			`HTTP ${response.status} ${response.statusText}`,
			response.status,
			parsed
		);
	}

	return response;
}

async function parseJsonBody<T>(response: Response, schema: z.ZodType<T>): Promise<T> {
	let body: unknown;
	try {
		body = await response.json();
	} catch (e) {
		throw new DaemonError(
			'INVALID_RESPONSE',
			'Response body is not valid JSON',
			response.status,
			e instanceof Error ? e.message : null
		);
	}
	const validated = schema.safeParse(body);
	if (!validated.success) {
		throw new DaemonError(
			'INVALID_RESPONSE',
			'Response shape does not match the expected schema',
			response.status,
			validated.error.issues
		);
	}
	return validated.data;
}

/**
 * Fetch a JSON endpoint from the daemon and validate the response body against `schema`.
 * Throws `DaemonError` for network failures, non-2xx responses, or schema violations.
 */
export async function apiFetch<T>(
	path: string,
	init: RequestInit,
	schema: z.ZodType<T>
): Promise<T> {
	const response = await executeRequest(path, init);
	return parseJsonBody(response, schema);
}

/**
 * Fetch an endpoint that returns no body on success (e.g. 204 No Content).
 * Throws `DaemonError` on network failures or non-2xx responses.
 */
export async function apiFetchVoid(path: string, init: RequestInit): Promise<void> {
	await executeRequest(path, init);
}
