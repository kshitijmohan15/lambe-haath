import * as sliceApi from '$lib/api/slices';
import type { JobStatusResponse, LocalSlice } from '$lib/api/types';
import {
	dedupeFilenames,
	ensurePdfExtension,
	sanitizeFilename
} from '$lib/utils/filenames';
import { validateSlice } from '$lib/utils/validation';

const POLL_INTERVAL_MS = 500;
const DRAFT_KEY_PREFIX = 'chargesheet:drafts:';

function draftKey(projectId: string): string {
	return DRAFT_KEY_PREFIX + projectId;
}

function browser(): boolean {
	return typeof window !== 'undefined' && typeof localStorage !== 'undefined';
}

interface NewSliceInput {
	startPage: number;
	endPage: number;
	filename?: string;
}

class SlicesStore {
	slices = $state<LocalSlice[]>([]);
	projectId = $state<string | null>(null);
	/** Id of the slice most recently added or edited (drives keyboard shortcuts). */
	lastEditedId = $state<string | null>(null);

	/** Load the draft for `projectId` from localStorage and make it active. */
	loadDraft(projectId: string): void {
		this.projectId = projectId;
		if (!browser()) {
			this.slices = [];
			return;
		}
		const raw = localStorage.getItem(draftKey(projectId));
		if (!raw) {
			this.slices = [];
			return;
		}
		try {
			const parsed: unknown = JSON.parse(raw);
			if (Array.isArray(parsed)) {
				this.slices = parsed as LocalSlice[];
				return;
			}
		} catch {
			// fall through
		}
		this.slices = [];
	}

	private persist(): void {
		if (!browser() || this.projectId === null) return;
		try {
			localStorage.setItem(draftKey(this.projectId), JSON.stringify(this.slices));
		} catch {
			// quota or storage disabled — ignore
		}
	}

	/** Reset to an unloaded state (e.g. when leaving the workspace). */
	reset(): void {
		this.slices = [];
		this.projectId = null;
		this.lastEditedId = null;
	}

	add(input: NewSliceInput): LocalSlice {
		const slice: LocalSlice = {
			id: crypto.randomUUID(),
			startPage: input.startPage,
			endPage: input.endPage,
			filename: input.filename ?? '',
			status: 'draft',
			error: null
		};
		this.slices = [...this.slices, slice];
		this.lastEditedId = slice.id;
		this.persist();
		return slice;
	}

	update(id: string, patch: Partial<Pick<LocalSlice, 'startPage' | 'endPage' | 'filename'>>): void {
		this.slices = this.slices.map((s) => (s.id === id ? { ...s, ...patch } : s));
		this.lastEditedId = id;
		this.persist();
	}

	remove(id: string): void {
		this.slices = this.slices.filter((s) => s.id !== id);
		if (this.lastEditedId === id) this.lastEditedId = null;
		this.persist();
	}

	clear(): void {
		this.slices = [];
		this.persist();
	}

	/**
	 * Submit all draft slices as a single slicing job. Polls until the job
	 * finishes, updating per-slice status from the server's results. On full
	 * success the localStorage draft is cleared.
	 *
	 * Throws if validation fails before submission or if the job POST itself
	 * fails. Per-slice failures are reflected in `slice.status === 'failed'`
	 * and do not throw.
	 */
	async submitAll(projectId: string, pageCount: number): Promise<JobStatusResponse> {
		if (this.projectId !== projectId) {
			throw new Error('submitAll called for a project that is not active');
		}
		if (this.slices.length === 0) {
			throw new Error('No slices to submit');
		}
		// validation
		for (const s of this.slices) {
			const others = this.slices.filter((o) => o.id !== s.id);
			const errs = validateSlice(s, pageCount, others);
			if (Object.keys(errs).length > 0) {
				throw new Error(`Slice "${s.filename || '(no name)'}" has validation errors`);
			}
		}
		// canonicalise filenames before submission
		const canonicalised = dedupeFilenames(
			this.slices.map((s) => ({
				...s,
				filename: ensurePdfExtension(sanitizeFilename(s.filename))
			}))
		);
		this.slices = canonicalised.map((s) => ({
			...s,
			status: 'submitting',
			error: null
		}));
		this.persist();

		let job;
		try {
			job = await sliceApi.submitSliceJob(projectId, {
				slices: this.slices.map((s) => ({
					start_page: s.startPage,
					end_page: s.endPage,
					filename: s.filename
				}))
			});
		} catch (e) {
			const message = e instanceof Error ? e.message : 'Submission failed';
			this.slices = this.slices.map((s) => ({ ...s, status: 'failed', error: message }));
			this.persist();
			throw e;
		}

		// poll
		// eslint-disable-next-line no-constant-condition
		while (true) {
			const status = await sliceApi.getJobStatus(projectId, job.job_id);
			if (status.status === 'completed' || status.status === 'failed') {
				const byFilename = new Map(status.results.map((r) => [r.filename, r]));
				this.slices = this.slices.map((s) => {
					const r = byFilename.get(s.filename);
					if (!r) return s;
					return { ...s, status: r.status, error: r.error };
				});
				this.persist();
				if (this.slices.every((s) => s.status === 'completed')) {
					this.clear();
				}
				return status;
			}
			await new Promise((r) => setTimeout(r, POLL_INTERVAL_MS));
		}
	}
}

export const slicesStore = new SlicesStore();
