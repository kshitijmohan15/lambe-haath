import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { z } from 'zod';
import { apiFetch, DaemonError } from './client';

describe('apiFetch', () => {
	let originalFetch: typeof globalThis.fetch;

	beforeEach(() => {
		originalFetch = globalThis.fetch;
	});

	afterEach(() => {
		globalThis.fetch = originalFetch;
		vi.restoreAllMocks();
	});

	it('rejects with INVALID_RESPONSE when the response body does not match the schema', async () => {
		globalThis.fetch = vi.fn(
			async () =>
				new Response(JSON.stringify({ totally: 'wrong shape' }), {
					status: 200,
					headers: { 'Content-Type': 'application/json' }
				})
		) as unknown as typeof fetch;

		const schema = z.object({ id: z.string(), name: z.string() });

		await expect(apiFetch('/anything', { method: 'GET' }, schema)).rejects.toBeInstanceOf(
			DaemonError
		);
		await expect(apiFetch('/anything', { method: 'GET' }, schema)).rejects.toMatchObject({
			code: 'INVALID_RESPONSE'
		});
	});

	it('rejects with INVALID_RESPONSE when the response is not valid JSON', async () => {
		globalThis.fetch = vi.fn(
			async () =>
				new Response('this is not json{', {
					status: 200,
					headers: { 'Content-Type': 'application/json' }
				})
		) as unknown as typeof fetch;

		const schema = z.object({ id: z.string() });

		await expect(apiFetch('/anything', { method: 'GET' }, schema)).rejects.toMatchObject({
			name: 'DaemonError',
			code: 'INVALID_RESPONSE'
		});
	});

	it('rejects with the server-provided error code on non-2xx with a well-formed error body', async () => {
		globalThis.fetch = vi.fn(
			async () =>
				new Response(JSON.stringify({ code: 'NOT_FOUND', message: 'gone' }), {
					status: 404,
					headers: { 'Content-Type': 'application/json' }
				})
		) as unknown as typeof fetch;

		const schema = z.object({ id: z.string() });

		await expect(apiFetch('/missing', { method: 'GET' }, schema)).rejects.toMatchObject({
			code: 'NOT_FOUND',
			httpStatus: 404
		});
	});

	it('returns parsed data when the response matches the schema', async () => {
		globalThis.fetch = vi.fn(
			async () =>
				new Response(JSON.stringify({ id: 'abc', name: 'demo' }), {
					status: 200,
					headers: { 'Content-Type': 'application/json' }
				})
		) as unknown as typeof fetch;

		const schema = z.object({ id: z.string(), name: z.string() });
		const data = await apiFetch('/ok', { method: 'GET' }, schema);
		expect(data).toEqual({ id: 'abc', name: 'demo' });
	});

	it('rejects with NETWORK_ERROR when fetch itself throws', async () => {
		globalThis.fetch = vi.fn(async () => {
			throw new TypeError('failed to connect');
		}) as unknown as typeof fetch;

		const schema = z.object({ id: z.string() });

		await expect(apiFetch('/down', { method: 'GET' }, schema)).rejects.toMatchObject({
			code: 'NETWORK_ERROR'
		});
	});
});
