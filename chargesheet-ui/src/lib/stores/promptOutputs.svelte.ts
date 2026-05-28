import * as api from '$lib/api/prompts';
import type { KnownPromptName } from '$lib/api/prompts';
import type { PromptOutputRow } from '$lib/api/types';

class PromptOutputsStore {
	rows = $state<PromptOutputRow[]>([]);
	loading = $state(false);
	error = $state<string | null>(null);

	async load(projectId: string): Promise<void> {
		this.loading = true;
		this.error = null;
		try {
			this.rows = await api.listPromptOutputs(projectId);
		} catch (e) {
			this.error = e instanceof Error ? e.message : 'Failed to load prompt outputs';
		} finally {
			this.loading = false;
		}
	}

	async enqueue(projectId: string, promptName: KnownPromptName): Promise<string> {
		const resp = await api.enqueuePrompt(projectId, promptName);
		return resp.job_id;
	}

	async enqueueAll(projectId: string): Promise<string[]> {
		const resp = await api.enqueuePromptAll(projectId);
		return resp.job_ids;
	}

	findByName(promptName: string): PromptOutputRow | null {
		return this.rows.find((r) => r.prompt_name === promptName) ?? null;
	}

	clear() {
		this.rows = [];
		this.error = null;
	}
}

export const promptOutputsStore = new PromptOutputsStore();
