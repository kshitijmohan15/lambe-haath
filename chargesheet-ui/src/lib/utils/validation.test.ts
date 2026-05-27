import { describe, expect, it } from 'vitest';
import type { LocalSlice } from '$lib/api/types';
import { canSubmitAll, validateSlice } from './validation';

const slice = (
	startPage: number,
	endPage: number,
	filename: string,
	id = `${startPage}-${endPage}-${filename}`
): LocalSlice => ({ id, startPage, endPage, filename, status: 'draft', error: null });

describe('validateSlice', () => {
	it('returns no errors for a valid slice', () => {
		expect(validateSlice({ startPage: 1, endPage: 3, filename: 'a.pdf' }, 10, [])).toEqual({});
	});
	it('flags startPage out of range', () => {
		expect(validateSlice({ startPage: 0, endPage: 1, filename: 'a' }, 10, []).startPage).toMatch(
			/positive/
		);
		expect(
			validateSlice({ startPage: 11, endPage: 11, filename: 'a' }, 10, []).startPage
		).toMatch(/exceeds/);
	});
	it('flags endPage out of range', () => {
		expect(validateSlice({ startPage: 1, endPage: 11, filename: 'a' }, 10, []).endPage).toMatch(
			/exceeds/
		);
	});
	it('flags start > end', () => {
		expect(validateSlice({ startPage: 5, endPage: 3, filename: 'a' }, 10, []).endPage).toMatch(
			/≥ start/
		);
	});
	it('flags empty filename', () => {
		expect(validateSlice({ startPage: 1, endPage: 1, filename: '   ' }, 10, []).filename).toMatch(
			/required/
		);
	});
	it('flags duplicate filenames within siblings', () => {
		const errs = validateSlice({ startPage: 1, endPage: 1, filename: 'a.pdf' }, 10, [
			{ filename: 'a.pdf' }
		]);
		expect(errs.filename).toMatch(/filename/);
	});
});

describe('canSubmitAll', () => {
	it('returns false on empty list', () => {
		expect(canSubmitAll([], 10)).toBe(false);
	});
	it('returns false if any slice is invalid', () => {
		expect(canSubmitAll([slice(1, 5, 'a.pdf'), slice(11, 12, 'b.pdf')], 10)).toBe(false);
	});
	it('returns true when all slices are valid and unique', () => {
		expect(canSubmitAll([slice(1, 3, 'a.pdf'), slice(4, 6, 'b.pdf')], 10)).toBe(true);
	});
	it('returns false when filenames collide', () => {
		expect(canSubmitAll([slice(1, 3, 'a.pdf'), slice(4, 6, 'a.pdf')], 10)).toBe(false);
	});
	it('returns false when pageCount is zero', () => {
		expect(canSubmitAll([slice(1, 1, 'a.pdf')], 0)).toBe(false);
	});
});
