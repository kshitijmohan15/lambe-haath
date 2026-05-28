import { describe, it, expect, vi, beforeEach } from 'vitest';
import { listExtractions, enqueueOcr } from './extractions';

beforeEach(() => {
	vi.unstubAllGlobals();
});

describe('extractions API', () => {
	it('listExtractions parses a valid array response', async () => {
		const mockResp = [
			{
				project_id: 'p1',
				slice_filename: 'annexure-i.pdf',
				markdown_path: '/x.md',
				meta_path: '/x.meta.json',
				model: 'gemini-2.5-flash',
				pages: 5,
				page_markers_found: 5,
				input_tokens: 100,
				output_tokens: 500,
				input_cost_usd: 0.0001,
				output_cost_usd: 0.001,
				latency_s: 12.5,
				created_at: '2026-05-28T00:00:00Z',
			},
		];
		vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify(mockResp), { status: 200 })));

		const result = await listExtractions('p1');
		expect(result).toHaveLength(1);
		expect(result[0].slice_filename).toBe('annexure-i.pdf');
		expect(result[0].pages).toBe(5);
	});

	it('enqueueOcr returns job_id on 201', async () => {
		const mockResp = { job_id: 'job-abc', status: 'queued' };
		vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify(mockResp), { status: 201 })));

		const result = await enqueueOcr('p1', 'annexure-i.pdf');
		expect(result.job_id).toBe('job-abc');
		expect(result.status).toBe('queued');
	});
});
