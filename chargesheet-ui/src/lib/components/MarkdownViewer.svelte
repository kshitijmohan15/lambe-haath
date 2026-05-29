<script lang="ts">
	import { marked } from 'marked';

	let { markdown, class: cls = '' }: { markdown: string; class?: string } = $props();

	// Convert OCR page markers (<!-- page: N -->) into visible page dividers.
	// The marker is emitted by the OCR agent at every PDF page boundary.
	function withPageDividers(src: string): string {
		return src.replace(
			/<!--\s*page:\s*(\d+)\s*-->/g,
			(_, n) =>
				`\n\n<div class="not-prose my-6 flex items-center gap-3" role="separator" aria-label="Page ${n}">` +
				`<div class="h-px flex-1 bg-line"></div>` +
				`<span class="font-mono text-[10.5px] font-semibold tracking-[1.2px] uppercase text-ink-3">Page ${n}</span>` +
				`<div class="h-px flex-1 bg-line"></div>` +
				`</div>\n\n`,
		);
	}

	const html = $derived(marked.parse(withPageDividers(markdown)) as string);
</script>

<article class="prose prose-sm max-w-none {cls}">
	{@html html}
</article>
