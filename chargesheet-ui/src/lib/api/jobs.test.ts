import { describe, it, expect, vi, beforeEach } from 'vitest';
import { getJob, getJobLogs, cancelJob } from './jobs';

beforeEach(() => {
	vi.unstubAllGlobals();
});

describe('jobs API', () => {
	it('getJob parses a valid job response', async () => {
		const mockResp = {
			id: 'job-abc',
			project_id: 'p1',
			type: 'ocr',
			status: 'running',
			progress: 0.5,
			payload: '{"slice_filename":"annexure-i.pdf"}',
			results: null,
			error: null,
			created_at: '2026-05-28T00:00:00Z',
			updated_at: '2026-05-28T00:01:00Z',
		};
		vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify(mockResp), { status: 200 })));

		const result = await getJob('p1', 'job-abc');
		expect(result.id).toBe('job-abc');
		expect(result.status).toBe('running');
		expect(result.progress).toBe(0.5);
	});

	it('getJobLogs parses an array of log entries', async () => {
		const mockResp = [
			{ ts: '2026-05-28T00:00:01Z', level: 'info', logger: 'ocr_agent', message: 'starting' },
			{ ts: '2026-05-28T00:00:05Z', level: 'warning', logger: 'ocr_agent', message: 'slow chunk' },
		];
		vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify(mockResp), { status: 200 })));

		const logs = await getJobLogs('job-abc');
		expect(logs).toHaveLength(2);
		expect(logs[1].level).toBe('warning');
	});

	it('cancelJob returns void on 202', async () => {
		vi.stubGlobal('fetch', vi.fn(async () => new Response('', { status: 202 })));

		await expect(cancelJob('job-abc')).resolves.toBeUndefined();
	});
});
