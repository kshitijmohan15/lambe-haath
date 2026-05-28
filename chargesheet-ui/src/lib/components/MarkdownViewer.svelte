<script lang="ts">
	import { marked } from 'marked';

	let { markdown, class: cls = '' }: { markdown: string; class?: string } = $props();

	const html = $derived(marked.parse(markdown) as string);
</script>

<article class="prose prose-sm max-w-none {cls}">
	{@html html}
</article>
