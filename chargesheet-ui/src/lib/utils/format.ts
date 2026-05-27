/** Format a byte count as "X B" / "X.X KB" / "X.X MB" / "X.X GB". */
export function formatBytes(n: number): string {
	if (!Number.isFinite(n) || n < 0) return '—';
	if (n < 1024) return `${n} B`;
	if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
	if (n < 1024 * 1024 * 1024) return `${(n / (1024 * 1024)).toFixed(1)} MB`;
	return `${(n / (1024 * 1024 * 1024)).toFixed(1)} GB`;
}

/**
 * Format an ISO-8601 timestamp as a relative phrase against the current time.
 * Returns "just now", "X minutes ago", "X hours ago", "X days ago", or the
 * raw date for older values.
 */
export function formatRelative(iso: string, now: Date = new Date()): string {
	const then = new Date(iso);
	if (Number.isNaN(then.getTime())) return iso;
	const diffMs = now.getTime() - then.getTime();
	if (diffMs < 0) return 'just now';
	const seconds = Math.floor(diffMs / 1000);
	if (seconds < 60) return 'just now';
	const minutes = Math.floor(seconds / 60);
	if (minutes < 60) return `${minutes} minute${minutes === 1 ? '' : 's'} ago`;
	const hours = Math.floor(minutes / 60);
	if (hours < 24) return `${hours} hour${hours === 1 ? '' : 's'} ago`;
	const days = Math.floor(hours / 24);
	if (days < 30) return `${days} day${days === 1 ? '' : 's'} ago`;
	return then.toLocaleDateString();
}
