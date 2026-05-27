<script lang="ts">
	import { onDestroy, untrack } from 'svelte';
	import type { PDFDocumentProxy, RenderTask } from 'pdfjs-dist';
	import type { PDFDocumentLoadingTask } from 'pdfjs-dist/types/src/display/api.js';
	import { pdfjsLib } from '$lib/utils/pdfjs-setup';

	interface Props {
		pdfUrl: string | null;
		currentPage?: number;
		pageCount?: number | null;
		loading?: boolean;
		error?: string | null;
	}

	let {
		pdfUrl,
		currentPage = $bindable(1),
		pageCount = $bindable<number | null>(null),
		loading = $bindable(false),
		error = $bindable<string | null>(null)
	}: Props = $props();

	let canvas: HTMLCanvasElement | null = $state(null);
	let scrollEl: HTMLDivElement | null = $state(null);
	let pageInputValue = $state(1);

	let pdfDoc = $state.raw<PDFDocumentProxy | null>(null);
	let loadingTask: PDFDocumentLoadingTask | null = null;
	let renderTask: RenderTask | null = null;
	let token = 0;

	$effect(() => {
		const url = pdfUrl;
		const myToken = ++token;
		teardown();
		if (url === null) {
			pageCount = null;
			currentPage = 1;
			loading = false;
			error = null;
			return;
		}
		void loadPdf(url, myToken);
	});

	$effect(() => {
		if (pdfDoc === null) return;
		const page = currentPage;
		const myToken = token;
		void renderPage(pdfDoc, page, myToken);
	});

	$effect(() => {
		pageInputValue = currentPage;
	});

	// Re-render the current page on container resize (so fit-to-width tracks
	// window resizes / pane changes).
	$effect(() => {
		if (typeof window === 'undefined' || scrollEl === null) return;
		const el = scrollEl;
		const observer = new ResizeObserver(() => {
			if (pdfDoc === null) return;
			void renderPage(pdfDoc, currentPage, token);
		});
		observer.observe(el);
		return () => observer.disconnect();
	});

	async function loadPdf(url: string, myToken: number): Promise<void> {
		loading = true;
		error = null;
		pageCount = null;
		try {
			loadingTask = pdfjsLib.getDocument({
				url,
				disableRange: true,
				disableStream: true,
				disableAutoFetch: true
			});
			const doc = await loadingTask.promise;
			if (myToken !== token) {
				await doc.destroy();
				return;
			}
			pdfDoc = doc;
			pageCount = doc.numPages;
			if (currentPage > doc.numPages) currentPage = doc.numPages;
			if (currentPage < 1) currentPage = 1;
			loading = false;
		} catch (e: unknown) {
			if (myToken !== token) return;
			loading = false;
			error = describeLoadError(e);
		}
	}

	async function renderPage(
		doc: PDFDocumentProxy,
		pageNum: number,
		myToken: number
	): Promise<void> {
		if (canvas === null) return;
		if (pageNum < 1 || pageNum > doc.numPages) return;
		try {
			const page = await doc.getPage(pageNum);
			if (myToken !== token) {
				page.cleanup();
				return;
			}
			const ratio = typeof window !== 'undefined' ? window.devicePixelRatio || 1 : 1;
			const containerWidth = scrollEl?.clientWidth ?? 800;
			const containerHeight = scrollEl?.clientHeight ?? 600;
			// Fit the whole page inside the viewport: pick the smaller of the
			// width-fit and height-fit scales. Padding keeps the page from
			// touching the pane edges.
			const targetCssWidth = Math.max(200, containerWidth - 32);
			const targetCssHeight = Math.max(200, containerHeight - 32);
			const baseViewport = page.getViewport({ scale: 1 });
			const fitScale = Math.min(
				targetCssWidth / baseViewport.width,
				targetCssHeight / baseViewport.height
			);
			const viewport = page.getViewport({ scale: fitScale * ratio });
			const ctx = canvas.getContext('2d');
			if (!ctx) return;
			canvas.width = Math.ceil(viewport.width);
			canvas.height = Math.ceil(viewport.height);
			canvas.style.width = `${Math.floor(viewport.width / ratio)}px`;
			canvas.style.height = `${Math.floor(viewport.height / ratio)}px`;
			if (renderTask) {
				try {
					renderTask.cancel();
				} catch {
					/* ignore */
				}
			}
			renderTask = page.render({ canvasContext: ctx, viewport });
			await renderTask.promise;
			page.cleanup();
		} catch (e: unknown) {
			if (isRenderCancelled(e)) return;
		}
	}

	function describeLoadError(e: unknown): string {
		const name = e && typeof e === 'object' && 'name' in e ? String((e as { name: unknown }).name) : '';
		if (name === 'PasswordException') return 'This PDF is password-protected and cannot be opened.';
		if (name === 'InvalidPDFException') return 'This file is not a valid PDF.';
		if (name === 'MissingPDFException') return 'Could not find the PDF.';
		if (name === 'UnexpectedResponseException') return 'Network error while loading PDF.';
		return e instanceof Error ? e.message : 'Failed to load PDF.';
	}

	function isRenderCancelled(e: unknown): boolean {
		if (!e || typeof e !== 'object') return false;
		const name = 'name' in e ? String((e as { name: unknown }).name) : '';
		return name === 'RenderingCancelledException';
	}

	function teardown(): void {
		untrack(() => {
			if (renderTask) {
				try {
					renderTask.cancel();
				} catch {
					/* ignore */
				}
				renderTask = null;
			}
			if (pdfDoc) {
				void pdfDoc.destroy();
				pdfDoc = null;
			}
			if (loadingTask) {
				try {
					void loadingTask.destroy();
				} catch {
					/* ignore */
				}
				loadingTask = null;
			}
		});
	}

	function goPrev(): void {
		if (currentPage > 1) currentPage -= 1;
	}
	function goNext(): void {
		if (pageCount !== null && currentPage < pageCount) currentPage += 1;
	}
	function jumpToInput(): void {
		const n = Math.floor(pageInputValue);
		if (pageCount !== null && n >= 1 && n <= pageCount) {
			currentPage = n;
		} else {
			pageInputValue = currentPage;
		}
	}

	function onWindowKeydown(e: KeyboardEvent): void {
		const tgt = e.target as HTMLElement | null;
		if (tgt) {
			const tag = tgt.tagName;
			if (tag === 'INPUT' || tag === 'TEXTAREA' || tgt.isContentEditable) return;
		}
		if (e.key === 'ArrowLeft') {
			e.preventDefault();
			goPrev();
		} else if (e.key === 'ArrowRight') {
			e.preventDefault();
			goNext();
		}
	}

	onDestroy(() => {
		teardown();
	});
</script>

<svelte:window onkeydown={onWindowKeydown} />

<div class="flex h-full w-full flex-col">
	<div
		bind:this={scrollEl}
		class="flex flex-1 items-center justify-center overflow-hidden bg-gray-100 p-4"
	>
		{#if loading}
			<div class="p-8 text-gray-500">Loading PDF…</div>
		{:else if error}
			<div class="max-w-md p-8 text-center text-red-600">{error}</div>
		{/if}
		<canvas
			bind:this={canvas}
			class="bg-white shadow-lg"
			class:hidden={loading || error !== null || pdfUrl === null}
			tabindex="0"
			aria-label="PDF page"
		></canvas>
	</div>

	{#if pageCount !== null && pageCount > 0}
		<div class="flex shrink-0 items-center justify-center gap-2 border-t border-gray-200 bg-white px-4 py-2 text-sm text-gray-700">
			<button
				type="button"
				class="rounded border border-gray-300 px-2 py-1 hover:bg-gray-50 disabled:opacity-30"
				onclick={goPrev}
				disabled={loading || currentPage <= 1}
				aria-label="Previous page">‹ Prev</button
			>
			<span>Page</span>
			<input
				type="number"
				class="w-16 rounded border border-gray-300 px-2 py-1 text-center"
				min="1"
				max={pageCount}
				bind:value={pageInputValue}
				onchange={jumpToInput}
				onkeydown={(e) => {
					if (e.key === 'Enter') jumpToInput();
				}}
				disabled={loading}
				aria-label="Jump to page"
			/>
			<span>of {pageCount}</span>
			<button
				type="button"
				class="rounded border border-gray-300 px-2 py-1 hover:bg-gray-50 disabled:opacity-30"
				onclick={goNext}
				disabled={loading || currentPage >= pageCount}
				aria-label="Next page">Next ›</button
			>
		</div>
	{/if}
</div>
