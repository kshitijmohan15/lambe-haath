import { error } from '@sveltejs/kit';
import { getProject } from '$lib/api/projects';
import { DaemonError } from '$lib/api/client';
import { pdfStore } from '$lib/stores/pdf.svelte';
import { slicesStore } from '$lib/stores/slices.svelte';
import type { PageLoad } from './$types';

export const load: PageLoad = async ({ params }) => {
	try {
		const project = await getProject(params.id);
		pdfStore.reset();
		slicesStore.loadDraft(project.id);
		return { project };
	} catch (e) {
		if (e instanceof DaemonError && e.httpStatus === 404) {
			error(404, 'Project not found');
		}
		throw e;
	}
};
