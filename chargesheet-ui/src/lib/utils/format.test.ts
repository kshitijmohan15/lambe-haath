import { describe, expect, it } from 'vitest';
import { formatBytes, formatRelative } from './format';

describe('formatBytes', () => {
	it('handles bytes', () => {
		expect(formatBytes(0)).toBe('0 B');
		expect(formatBytes(1023)).toBe('1023 B');
	});
	it('handles kilobytes', () => {
		expect(formatBytes(1024)).toBe('1.0 KB');
		expect(formatBytes(2048)).toBe('2.0 KB');
	});
	it('handles megabytes', () => {
		expect(formatBytes(1024 * 1024)).toBe('1.0 MB');
		expect(formatBytes(2.5 * 1024 * 1024)).toBe('2.5 MB');
	});
	it('handles gigabytes', () => {
		expect(formatBytes(1024 * 1024 * 1024)).toBe('1.0 GB');
	});
	it('handles negative or non-finite gracefully', () => {
		expect(formatBytes(-1)).toBe('—');
		expect(formatBytes(Number.NaN)).toBe('—');
	});
});

describe('formatRelative', () => {
	const now = new Date('2026-05-22T10:00:00Z');
	it('shows "just now" for very recent timestamps', () => {
		expect(formatRelative('2026-05-22T09:59:55Z', now)).toBe('just now');
	});
	it('shows minutes', () => {
		expect(formatRelative('2026-05-22T09:55:00Z', now)).toBe('5 minutes ago');
		expect(formatRelative('2026-05-22T09:59:00Z', now)).toBe('1 minute ago');
	});
	it('shows hours', () => {
		expect(formatRelative('2026-05-22T08:00:00Z', now)).toBe('2 hours ago');
		expect(formatRelative('2026-05-22T09:00:00Z', now)).toBe('1 hour ago');
	});
	it('shows days', () => {
		expect(formatRelative('2026-05-20T10:00:00Z', now)).toBe('2 days ago');
	});
	it('falls back to a date string for old values', () => {
		const result = formatRelative('2025-01-01T00:00:00Z', now);
		expect(result).not.toMatch(/ago/);
		expect(result).not.toMatch(/just now/);
	});
	it('returns "just now" for future timestamps', () => {
		expect(formatRelative('2026-05-22T11:00:00Z', now)).toBe('just now');
	});
});
