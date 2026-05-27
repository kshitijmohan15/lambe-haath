import * as api from '$lib/api/projects';
import type { CreateProjectInput, Project } from '$lib/api/types';

class ProjectsStore {
	projects = $state<Project[]>([]);
	loading = $state(false);
	error = $state<string | null>(null);

	/** Reload the project list from the daemon. Surfaces errors on `error`. */
	async load(): Promise<void> {
		this.loading = true;
		this.error = null;
		try {
			this.projects = await api.listProjects();
		} catch (e) {
			this.error = e instanceof Error ? e.message : 'Failed to load projects';
		} finally {
			this.loading = false;
		}
	}

	/** Create a new project; prepends the result to the in-memory list. */
	async create(input: CreateProjectInput): Promise<Project> {
		const project = await api.createProject(input);
		this.projects = [project, ...this.projects];
		return project;
	}

	/** Delete a project on the daemon and remove it from the in-memory list. */
	async remove(id: string): Promise<void> {
		await api.deleteProject(id);
		this.projects = this.projects.filter((p) => p.id !== id);
	}
}

export const projectsStore = new ProjectsStore();
