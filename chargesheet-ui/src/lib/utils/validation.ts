import type { LocalSlice } from '$lib/api/types';

export interface SliceFieldErrors {
	startPage?: string;
	endPage?: string;
	filename?: string;
}

/**
 * Field-level validation for a single slice against the project's page count
 * and the other slices in the list (for filename uniqueness).
 */
export function validateSlice(
	slice: Pick<LocalSlice, 'startPage' | 'endPage' | 'filename'>,
	pageCount: number,
	otherSlices: Array<Pick<LocalSlice, 'filename'>>
): SliceFieldErrors {
	const errors: SliceFieldErrors = {};

	if (!Number.isInteger(slice.startPage) || slice.startPage < 1) {
		errors.startPage = 'Start page must be a positive integer';
	} else if (slice.startPage > pageCount) {
		errors.startPage = `Start page exceeds page count (${pageCount})`;
	}

	if (!Number.isInteger(slice.endPage) || slice.endPage < 1) {
		errors.endPage = 'End page must be a positive integer';
	} else if (slice.endPage > pageCount) {
		errors.endPage = `End page exceeds page count (${pageCount})`;
	} else if (errors.startPage === undefined && slice.startPage > slice.endPage) {
		errors.endPage = 'End page must be ≥ start page';
	}

	const trimmed = slice.filename.trim();
	if (trimmed.length === 0) {
		errors.filename = 'Filename is required';
	} else if (trimmed.length > 255) {
		errors.filename = 'Filename is too long';
	} else if (otherSlices.some((o) => o.filename.trim() === trimmed)) {
		errors.filename = 'Another slice has this filename';
	}

	return errors;
}

/** True if there is at least one slice and all of them validate cleanly. */
export function canSubmitAll(slices: LocalSlice[], pageCount: number): boolean {
	if (slices.length === 0) return false;
	if (pageCount <= 0) return false;
	for (let i = 0; i < slices.length; i++) {
		const others = slices.filter((_, j) => j !== i);
		const slice = slices[i];
		if (!slice) return false;
		const errs = validateSlice(slice, pageCount, others);
		if (Object.keys(errs).length > 0) return false;
	}
	return true;
}
