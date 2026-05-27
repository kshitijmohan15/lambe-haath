import { apiFetch } from './client';
import { HealthResponseSchema } from './schemas';
import type { HealthResponse } from './types';

/** Ping the daemon's health endpoint. */
export async function health(): Promise<HealthResponse> {
	return apiFetch('/health', { method: 'GET' }, HealthResponseSchema);
}
