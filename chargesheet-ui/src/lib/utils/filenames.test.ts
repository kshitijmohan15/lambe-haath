import { describe, expect, it } from 'vitest';
import type { LocalSlice } from '$lib/api/types';
import { dedupeFilenames, ensurePdfExtension, sanitizeFilename } from './filenames';

const slice = (filename: string, id = filename): LocalSlice => ({
	id,
	startPage: 1,
	endPage: 1,
	filename,
	status: 'draft',
	error: null
});

describe('sanitizeFilename', () => {
	it('strips forbidden filesystem characters', () => {
		expect(sanitizeFilename('a/b\\c:d*e?f"g<h>i|j.pdf')).toBe('abcdefghij.pdf');
	});
	it('collapses runs of whitespace and trims', () => {
		expect(sanitizeFilename('   foo   bar  .pdf  ')).toBe('foo bar .pdf');
	});
	it('returns empty string for an all-forbidden input', () => {
		expect(sanitizeFilename('///')).toBe('');
	});
});

describe('ensurePdfExtension', () => {
	it('adds .pdf if absent', () => {
		expect(ensurePdfExtension('foo')).toBe('foo.pdf');
	});
	it('keeps .pdf if present (case-insensitive)', () => {
		expect(ensurePdfExtension('foo.pdf')).toBe('foo.pdf');
		expect(ensurePdfExtension('foo.PDF')).toBe('foo.PDF');
	});
	it('does not double-add', () => {
		expect(ensurePdfExtension('foo.PdF')).toBe('foo.PdF');
	});
});

describe('dedupeFilenames', () => {
	it('passes through a unique list unchanged', () => {
		const input = [slice('a.pdf', '1'), slice('b.pdf', '2')];
		const out = dedupeFilenames(input);
		expect(out.map((s) => s.filename)).toEqual(['a.pdf', 'b.pdf']);
	});
	it('appends _2, _3, ... in order', () => {
		const input = [slice('a.pdf', '1'), slice('a.pdf', '2'), slice('a.pdf', '3')];
		const out = dedupeFilenames(input);
		expect(out.map((s) => s.filename)).toEqual(['a.pdf', 'a_2.pdf', 'a_3.pdf']);
	});
	it('skips already-taken suffixes', () => {
		const input = [slice('a.pdf', '1'), slice('a_2.pdf', '2'), slice('a.pdf', '3')];
		const out = dedupeFilenames(input);
		expect(out.map((s) => s.filename)).toEqual(['a.pdf', 'a_2.pdf', 'a_3.pdf']);
	});
	it('preserves slice identity (returns same id for each entry)', () => {
		const input = [slice('a.pdf', '1'), slice('a.pdf', '2')];
		const out = dedupeFilenames(input);
		expect(out[0]?.id).toBe('1');
		expect(out[1]?.id).toBe('2');
	});
	it('handles files with no extension', () => {
		const input = [slice('foo', '1'), slice('foo', '2')];
		const out = dedupeFilenames(input);
		expect(out.map((s) => s.filename)).toEqual(['foo', 'foo_2']);
	});
});
