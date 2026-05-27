import { error } from '@sveltejs/kit';

export const ssr = false;
export const prerender = false;

export function load(): void {
	if (!import.meta.env.DEV) {
		error(404, 'Not found');
	}
}
