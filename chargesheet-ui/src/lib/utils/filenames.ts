import type { LocalSlice } from '$lib/api/types';

const FORBIDDEN_CHARS = /[/\\:*?"<>|]/g;
const WHITESPACE_RUN = /\s+/g;

/** Strip path/filesystem-unsafe characters and collapse whitespace. */
export function sanitizeFilename(name: string): string {
	return name.replace(FORBIDDEN_CHARS, '').replace(WHITESPACE_RUN, ' ').trim();
}

/** Ensure the filename ends with `.pdf` (case-insensitive). */
export function ensurePdfExtension(name: string): string {
	if (name.toLowerCase().endsWith('.pdf')) return name;
	return name + '.pdf';
}

function splitExtension(name: string): { base: string; ext: string } {
	const dot = name.lastIndexOf('.');
	if (dot <= 0) return { base: name, ext: '' };
	return { base: name.slice(0, dot), ext: name.slice(dot) };
}

/**
 * Deduplicate filenames within a list of slices by appending `_2`, `_3`, … to
 * the base name (before the extension) of any later occurrence. Original
 * ordering is preserved.
 *
 * ["a.pdf","a.pdf","b.pdf"] -> ["a.pdf","a_2.pdf","b.pdf"]
 */
export function dedupeFilenames(slices: LocalSlice[]): LocalSlice[] {
	const used = new Set<string>();
	return slices.map((s) => {
		if (!used.has(s.filename)) {
			used.add(s.filename);
			return s;
		}
		const { base, ext } = splitExtension(s.filename);
		let n = 2;
		let candidate = `${base}_${n}${ext}`;
		while (used.has(candidate)) {
			n += 1;
			candidate = `${base}_${n}${ext}`;
		}
		used.add(candidate);
		return { ...s, filename: candidate };
	});
}
