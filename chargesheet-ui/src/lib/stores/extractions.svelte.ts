import * as api from '$lib/api/extractions';
import type { ExtractionRow } from '$lib/api/types';

class ExtractionsStore {
	rows = $state<ExtractionRow[]>([]);
	loading = $state(false);
	error = $state<string | null>(null);

	async load(projectId: string): Promise<void> {
		this.loading = true;
		this.error = null;
		try {
			this.rows = await api.listExtractions(projectId);
		} catch (e) {
			this.error = e instanceof Error ? e.message : 'Failed to load extractions';
		} finally {
			this.loading = false;
		}
	}

	async enqueue(projectId: string, sliceFilename: string): Promise<string> {
		const resp = await api.enqueueOcr(projectId, sliceFilename);
		return resp.job_id;
	}

	async enqueueAll(projectId: string): Promise<string[]> {
		const resp = await api.enqueueOcrAll(projectId);
		return resp.job_ids;
	}

	findBySlice(sliceFilename: string): ExtractionRow | null {
		return this.rows.find((r) => r.slice_filename === sliceFilename) ?? null;
	}

	clear() {
		this.rows = [];
		this.error = null;
	}
}

export const extractionsStore = new ExtractionsStore();
