class PdfStore {
	pageCount = $state<number | null>(null);
	currentPage = $state(1);
	loading = $state(false);
	error = $state<string | null>(null);

	reset(): void {
		this.pageCount = null;
		this.currentPage = 1;
		this.loading = false;
		this.error = null;
	}
}

export const pdfStore = new PdfStore();
