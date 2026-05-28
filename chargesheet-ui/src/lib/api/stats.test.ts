import { describe, it, expect, vi, beforeEach } from 'vitest';
import * as stats from './stats';

beforeEach(() => {
	vi.unstubAllGlobals();
});

function ok(body: unknown) {
	return new Response(JSON.stringify(body), {
		status: 200,
		headers: { 'Content-Type': 'application/json' },
	});
}

describe('stats API', () => {
	it('getOverview parses lifetime + per_model + top_projects', async () => {
		vi.stubGlobal(
			'fetch',
			vi.fn(async () =>
				ok({
					lifetime: {
						ocr: { kind: 'ocr', runs: 1, in_tokens: 100, out_tokens: 200, cost_usd: 0.01, avg_latency_s: 1.5 },
						prompt: { kind: 'prompt', runs: 0, in_tokens: 0, out_tokens: 0, cost_usd: 0, avg_latency_s: 0 },
					},
					per_model: [{ model: 'g', runs: 1, in_tokens: 100, out_tokens: 200, cost_usd: 0.01 }],
					top_projects: [],
				})
			)
		);
		const ov = await stats.getOverview();
		expect(ov.lifetime.ocr.runs).toBe(1);
		expect(ov.per_model).toHaveLength(1);
	});

	it('getProjectStats encodes project id', async () => {
		const fetchMock = vi.fn(async () =>
			ok({
				project_id: 'p_abc',
				ocr_cost_usd: 0,
				prompt_cost_usd: 0,
				total_in_tokens: 0,
				total_out_tokens: 0,
				ocr_runs: 0,
				prompt_runs: 0,
			})
		);
		vi.stubGlobal('fetch', fetchMock);
		await stats.getProjectStats('p abc');
		expect(fetchMock).toHaveBeenCalledWith(
			expect.stringContaining('/stats/project/p%20abc'),
			expect.objectContaining({ method: 'GET' })
		);
	});

	it('getSlowJobs respects limit', async () => {
		const fetchMock = vi.fn(async () => ok([]));
		vi.stubGlobal('fetch', fetchMock);
		await stats.getSlowJobs(5);
		expect(fetchMock).toHaveBeenCalledWith(
			expect.stringContaining('limit=5'),
			expect.objectContaining({ method: 'GET' })
		);
	});

	it('getTimeseries builds query string', async () => {
		const fetchMock = vi.fn(async () => ok([]));
		vi.stubGlobal('fetch', fetchMock);
		await stats.getTimeseries('2026-05-01', '2026-05-29');
		expect(fetchMock).toHaveBeenCalledWith(
			expect.stringContaining('from=2026-05-01'),
			expect.objectContaining({ method: 'GET' })
		);
	});
});
