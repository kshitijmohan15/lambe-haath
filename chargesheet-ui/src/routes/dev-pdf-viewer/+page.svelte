<script lang="ts">
	import PdfViewer from '$lib/components/PdfViewer.svelte';

	let urlInput = $state('');
	let pdfUrl = $state<string | null>(null);
	let currentPage = $state(1);
	let pageCount = $state<number | null>(null);
	let loading = $state(false);
	let error = $state<string | null>(null);

	function load() {
		pdfUrl = urlInput.trim() || null;
	}

	function loadSample() {
		// Sample PDFs you can paste into the URL field:
		// - https://mozilla.github.io/pdf.js/web/compressed.tracemonkey-pldi-09.pdf  (14 pages)
		// - http://localhost:7777/api/v1/projects/{id}/chargesheet  (via mock daemon)
		urlInput = 'https://mozilla.github.io/pdf.js/web/compressed.tracemonkey-pldi-09.pdf';
		pdfUrl = urlInput;
	}

	function loadFile(e: Event) {
		const f = (e.target as HTMLInputElement).files?.[0];
		if (!f) return;
		pdfUrl = URL.createObjectURL(f);
	}
</script>

<div class="mx-auto max-w-5xl space-y-4 p-6">
	<h1 class="text-2xl font-semibold">PDF Viewer dev harness</h1>
	<p class="text-sm text-gray-600">
		Dev-only route. Loads a PDF by URL or file, exercises load/render lifecycle, and surfaces
		bound state.
	</p>

	<div class="flex flex-wrap items-center gap-2">
		<input
			type="text"
			class="min-w-64 flex-1 rounded border border-gray-300 px-3 py-1.5"
			placeholder="https://… PDF URL"
			bind:value={urlInput}
		/>
		<button
			type="button"
			class="rounded bg-blue-600 px-3 py-1.5 text-white hover:bg-blue-700"
			onclick={load}>Load URL</button
		>
		<button
			type="button"
			class="rounded border border-gray-300 px-3 py-1.5 hover:bg-gray-50"
			onclick={loadSample}>Sample (14 pages)</button
		>
		<input type="file" accept="application/pdf" onchange={loadFile} class="text-sm" />
		<button
			type="button"
			class="rounded border border-gray-300 px-3 py-1.5 hover:bg-gray-50"
			onclick={() => {
				pdfUrl = null;
			}}>Clear</button
		>
	</div>

	<div class="rounded border border-gray-200 bg-gray-50 px-3 py-2 font-mono text-xs">
		pdfUrl={pdfUrl ?? 'null'} · currentPage={currentPage} · pageCount={pageCount ?? 'null'}
		· loading={String(loading)} · error={error ?? 'null'}
	</div>

	<div class="min-h-[600px] rounded border border-gray-200 bg-gray-100 p-4">
		<PdfViewer
			{pdfUrl}
			bind:currentPage
			bind:pageCount
			bind:loading
			bind:error
		/>
	</div>
</div>
