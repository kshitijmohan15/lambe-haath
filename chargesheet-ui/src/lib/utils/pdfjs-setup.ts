import * as pdfjsLib from 'pdfjs-dist';
// `?url` returns a URL string; pdf.js will create a fresh worker per
// document load. The alternative `?worker` import shares a single worker
// instance which gets terminated by loadingTask.destroy() — that breaks
// subsequent loads with "PDFWorker.fromPort - the worker is being destroyed".
import workerSrc from 'pdfjs-dist/build/pdf.worker.min.mjs?url';

pdfjsLib.GlobalWorkerOptions.workerSrc = workerSrc;

export { pdfjsLib };
