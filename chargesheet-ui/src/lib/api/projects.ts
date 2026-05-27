import { apiFetch, apiFetchVoid, API_BASE_PATH } from './client';
import { ProjectListSchema, ProjectSchema } from './schemas';
import type { CreateProjectInput, Project, ProjectList } from './types';

/** List all projects, sorted by `last_opened_at` desc. */
export async function listProjects(): Promise<ProjectList> {
	return apiFetch('/projects', { method: 'GET' }, ProjectListSchema);
}

/** Fetch a single project. Server also updates `last_opened_at` as a side effect. */
export async function getProject(id: string): Promise<Project> {
	return apiFetch(
		`/projects/${encodeURIComponent(id)}`,
		{ method: 'GET' },
		ProjectSchema
	);
}

/** Create a new project with a chargesheet PDF (multipart/form-data). */
export async function createProject(input: CreateProjectInput): Promise<Project> {
	const form = new FormData();
	form.append('name', input.name);
	if (input.description) {
		form.append('description', input.description);
	}
	form.append('chargesheet', input.chargesheet);
	return apiFetch('/projects', { method: 'POST', body: form }, ProjectSchema);
}

/** Delete a project by id (204 on success). */
export async function deleteProject(id: string): Promise<void> {
	return apiFetchVoid(`/projects/${encodeURIComponent(id)}`, { method: 'DELETE' });
}

/** URL to stream a project's chargesheet PDF inline. */
export const chargesheetUrl = (id: string): string =>
	`${API_BASE_PATH}/projects/${encodeURIComponent(id)}/chargesheet`;
