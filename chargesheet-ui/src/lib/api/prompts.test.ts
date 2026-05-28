import { describe, it, expect, vi, beforeEach } from 'vitest';
import { listPromptOutputs, enqueuePromptAll, KNOWN_PROMPTS } from './prompts';

beforeEach(() => {
	vi.unstubAllGlobals();
});

describe('prompts API', () => {
	it('KNOWN_PROMPTS contains exactly the 5 spec-correct names', () => {
		expect(KNOWN_PROMPTS).toEqual([
			'charge_memo_analysis',
			'imputation_scrutiny',
			'time_chart',
			'evidence_audit',
			'objection_brief',
		]);
	});

	it('listPromptOutputs parses a valid response', async () => {
		const mockResp = [
			{
				project_id: 'p1',
				prompt_name: 'imputation_scrutiny',
				markdown_path: '/x.md',
				model: 'gemini-2.5-flash',
				input_tokens: 100,
				output_tokens: 500,
				input_cost_usd: 0.0001,
				output_cost_usd: 0.001,
				latency_s: 12.5,
				warnings: [],
				created_at: '2026-05-28T00:00:00Z',
			},
		];
		vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify(mockResp), { status: 200 })));

		const result = await listPromptOutputs('p1');
		expect(result[0].prompt_name).toBe('imputation_scrutiny');
		expect(result[0].warnings).toEqual([]);
	});

	it('enqueuePromptAll returns job_ids array', async () => {
		const mockResp = { job_ids: ['j1', 'j2', 'j3', 'j4', 'j5'] };
		vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify(mockResp), { status: 201 })));

		const result = await enqueuePromptAll('p1');
		expect(result.job_ids).toHaveLength(5);
	});
});
