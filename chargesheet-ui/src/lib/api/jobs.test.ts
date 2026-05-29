import { describe, it, expect, vi, beforeEach } from 'vitest';
import { getJob, getJobLogs, cancelJob, listProjectJobs } from './jobs';

beforeEach(() => {
	vi.unstubAllGlobals();
});

describe('jobs API', () => {
	it('getJob parses a valid job response', async () => {
		const mockResp = {
			job_id: 'job-abc',
			status: 'running',
			progress: 0.5,
			results: null,
			error: null,
		};
		vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify(mockResp), { status: 200 })));

		const result = await getJob('p1', 'job-abc');
		expect(result.job_id).toBe('job-abc');
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

	it('listProjectJobs filters by status', async () => {
		vi.stubGlobal(
			'fetch',
			vi.fn(async () => new Response('[]', { status: 200, headers: { 'Content-Type': 'application/json' } }))
		);
		await listProjectJobs('p_abc', 'running');
		expect(fetch).toHaveBeenCalledWith(
			expect.stringContaining('/api/v1/projects/p_abc/jobs?status=running'),
			expect.objectContaining({ method: 'GET' })
		);
	});
});
