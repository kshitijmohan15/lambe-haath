import { serve } from '@hono/node-server';
import { Hono, type Context } from 'hono';
import { cors } from 'hono/cors';
import { PDFDocument } from 'pdf-lib';
import { v4 as uuidv4 } from 'uuid';
import { existsSync, promises as fs } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const STORAGE_DIR = join(__dirname, 'storage');
const PORT = Number.parseInt(process.env.PORT ?? '7777', 10);

// ---- Domain types ---------------------------------------------------------

interface ChargesheetMetadata {
	filename: string;
	page_count: number;
	size_bytes: number;
}

interface ProjectRecord {
	id: string;
	name: string;
	description: string | null;
	created_at: string;
	last_opened_at: string;
	chargesheet: ChargesheetMetadata;
}

interface SliceRecord {
	filename: string;
	page_range: [number, number];
	size_bytes: number;
	created_at: string;
}

interface JobResult {
	filename: string;
	status: 'completed' | 'failed';
	page_range: [number, number];
	size_bytes: number;
	error: string | null;
}

interface JobRecord {
	job_id: string;
	status: 'queued' | 'running' | 'completed' | 'failed';
	progress: number;
	results: JobResult[];
	error: string | null;
}

// ---- In-memory state ------------------------------------------------------

const projects = new Map<string, ProjectRecord>();
const jobs = new Map<string, JobRecord>();
const projectSlices = new Map<string, SliceRecord[]>();

// ---- Storage helpers ------------------------------------------------------

function projectPath(id: string): string {
	return join(STORAGE_DIR, id);
}
function chargesheetPath(id: string): string {
	return join(projectPath(id), 'chargesheet.pdf');
}
function metaPath(id: string): string {
	return join(projectPath(id), 'meta.json');
}
function slicesDirPath(id: string): string {
	return join(projectPath(id), 'slices');
}
function slicePath(id: string, filename: string): string {
	return join(slicesDirPath(id), filename);
}
function sliceMetaPath(id: string, filename: string): string {
	return join(slicesDirPath(id), filename + '.meta.json');
}

function isSafeFilename(name: string): boolean {
	if (name.length === 0 || name.length > 255) return false;
	if (name.includes('/') || name.includes('\\')) return false;
	if (name === '.' || name === '..') return false;
	return true;
}

async function loadFromDisk(): Promise<void> {
	await fs.mkdir(STORAGE_DIR, { recursive: true });
	const entries = await fs.readdir(STORAGE_DIR, { withFileTypes: true });
	for (const entry of entries) {
		if (!entry.isDirectory()) continue;
		const mp = join(STORAGE_DIR, entry.name, 'meta.json');
		if (!existsSync(mp)) continue;
		try {
			const meta = JSON.parse(await fs.readFile(mp, 'utf8')) as ProjectRecord;
			projects.set(meta.id, meta);
			const sd = slicesDirPath(meta.id);
			const sliceRecords: SliceRecord[] = [];
			if (existsSync(sd)) {
				const files = await fs.readdir(sd);
				for (const f of files) {
					if (!f.endsWith('.meta.json')) continue;
					try {
						const sliceMeta = JSON.parse(
							await fs.readFile(join(sd, f), 'utf8')
						) as SliceRecord;
						if (existsSync(slicePath(meta.id, sliceMeta.filename))) {
							sliceRecords.push(sliceMeta);
						}
					} catch (e) {
						console.warn(`failed to load slice meta ${f}:`, e);
					}
				}
			}
			projectSlices.set(meta.id, sliceRecords);
		} catch (e) {
			console.warn(`failed to load project ${entry.name}:`, e);
		}
	}
}

// ---- App ------------------------------------------------------------------

const app = new Hono();
app.use(
	'/api/*',
	cors({
		origin: 'http://localhost:5173',
		allowMethods: ['GET', 'POST', 'DELETE', 'OPTIONS'],
		allowHeaders: ['Content-Type']
	})
);

function apiError(
	c: Context,
	status: number,
	code: string,
	message: string,
	details: unknown = null
) {
	return c.json({ code, message, details }, status as 400 | 404 | 409);
}

// Health
app.get('/api/v1/health', (c) => c.json({ status: 'ok', version: 'mock-1.0.0' }));

// POST /api/v1/projects
app.post('/api/v1/projects', async (c) => {
	let form: FormData;
	try {
		form = await c.req.formData();
	} catch {
		return apiError(c, 400, 'INVALID_REQUEST', 'Failed to parse multipart form');
	}
	const nameRaw = form.get('name');
	const descriptionRaw = form.get('description');
	const file = form.get('chargesheet');

	const name = typeof nameRaw === 'string' ? nameRaw.trim() : '';
	if (!name) return apiError(c, 400, 'INVALID_NAME', 'Name is required');
	if (name.length > 200) return apiError(c, 400, 'INVALID_NAME', 'Name must be <= 200 chars');

	let description: string | null = null;
	if (typeof descriptionRaw === 'string' && descriptionRaw.length > 0) {
		if (descriptionRaw.length > 2000) {
			return apiError(c, 400, 'INVALID_DESCRIPTION', 'Description must be <= 2000 chars');
		}
		description = descriptionRaw;
	}

	if (!(file instanceof File)) {
		return apiError(c, 400, 'INVALID_PDF', 'Chargesheet file missing');
	}

	for (const p of projects.values()) {
		if (p.name === name) {
			return apiError(c, 409, 'NAME_CONFLICT', 'A project with this name already exists');
		}
	}

	const bytes = new Uint8Array(await file.arrayBuffer());
	let pdfDoc: PDFDocument;
	try {
		pdfDoc = await PDFDocument.load(bytes);
	} catch {
		return apiError(c, 400, 'INVALID_PDF', 'File is not a valid PDF');
	}

	const id = 'proj_' + uuidv4();
	const now = new Date().toISOString();
	const record: ProjectRecord = {
		id,
		name,
		description,
		created_at: now,
		last_opened_at: now,
		chargesheet: {
			filename: file.name || 'chargesheet.pdf',
			page_count: pdfDoc.getPageCount(),
			size_bytes: bytes.length
		}
	};

	await fs.mkdir(projectPath(id), { recursive: true });
	await fs.mkdir(slicesDirPath(id), { recursive: true });
	await fs.writeFile(chargesheetPath(id), bytes);
	await fs.writeFile(metaPath(id), JSON.stringify(record, null, 2));
	projects.set(id, record);
	projectSlices.set(id, []);

	return c.json(record, 201);
});

// GET /api/v1/projects
app.get('/api/v1/projects', (c) => {
	const list = [...projects.values()].sort((a, b) =>
		b.last_opened_at.localeCompare(a.last_opened_at)
	);
	return c.json(list);
});

// GET /api/v1/projects/:id
app.get('/api/v1/projects/:id', async (c) => {
	const id = c.req.param('id');
	const proj = projects.get(id);
	if (!proj) return apiError(c, 404, 'NOT_FOUND', 'Project not found');
	proj.last_opened_at = new Date().toISOString();
	await fs.writeFile(metaPath(id), JSON.stringify(proj, null, 2));
	return c.json(proj);
});

// DELETE /api/v1/projects/:id
app.delete('/api/v1/projects/:id', async (c) => {
	const id = c.req.param('id');
	if (!projects.has(id)) return apiError(c, 404, 'NOT_FOUND', 'Project not found');
	projects.delete(id);
	projectSlices.delete(id);
	await fs.rm(projectPath(id), { recursive: true, force: true });
	return c.body(null, 204);
});

// GET /api/v1/projects/:id/chargesheet
app.get('/api/v1/projects/:id/chargesheet', async (c) => {
	const id = c.req.param('id');
	const proj = projects.get(id);
	if (!proj) return apiError(c, 404, 'NOT_FOUND', 'Project not found');
	const bytes = await fs.readFile(chargesheetPath(id));
	return new Response(new Uint8Array(bytes), {
		status: 200,
		headers: {
			'Content-Type': 'application/pdf',
			'Content-Disposition': `inline; filename="${proj.chargesheet.filename.replace(/"/g, '')}"`
		}
	});
});

// POST /api/v1/projects/:id/jobs/slice
app.post('/api/v1/projects/:id/jobs/slice', async (c) => {
	const id = c.req.param('id');
	const proj = projects.get(id);
	if (!proj) return apiError(c, 404, 'NOT_FOUND', 'Project not found');

	let body: unknown;
	try {
		body = await c.req.json();
	} catch {
		return apiError(c, 400, 'INVALID_REQUEST', 'Body must be JSON');
	}
	if (!body || typeof body !== 'object' || !Array.isArray((body as { slices?: unknown }).slices)) {
		return apiError(c, 400, 'INVALID_REQUEST', 'Expected { slices: [...] }');
	}
	const incomingSlices = (body as { slices: unknown[] }).slices;
	const requested: Array<{ start_page: number; end_page: number; filename: string }> = [];
	for (const s of incomingSlices) {
		if (!s || typeof s !== 'object') {
			return apiError(c, 400, 'INVALID_REQUEST', 'Bad slice item');
		}
		const item = s as Record<string, unknown>;
		const start_page = item.start_page;
		const end_page = item.end_page;
		const filename = item.filename;
		if (
			typeof start_page !== 'number' ||
			typeof end_page !== 'number' ||
			typeof filename !== 'string'
		) {
			return apiError(
				c,
				400,
				'INVALID_RANGE',
				'Each slice needs numeric start_page, end_page and a string filename'
			);
		}
		if (
			!Number.isInteger(start_page) ||
			!Number.isInteger(end_page) ||
			start_page < 1 ||
			end_page > proj.chargesheet.page_count ||
			start_page > end_page
		) {
			return apiError(
				c,
				400,
				'INVALID_RANGE',
				`Pages must be 1..${proj.chargesheet.page_count} integers with start <= end`
			);
		}
		if (!isSafeFilename(filename)) {
			return apiError(c, 400, 'INVALID_FILENAME', `Bad filename: ${filename}`);
		}
		requested.push({ start_page, end_page, filename });
	}
	const seen = new Set<string>();
	for (const r of requested) {
		if (seen.has(r.filename)) {
			return apiError(c, 400, 'DUPLICATE_FILENAMES', `Duplicate filename ${r.filename}`);
		}
		seen.add(r.filename);
	}

	const srcBytes = await fs.readFile(chargesheetPath(id));
	const srcDoc = await PDFDocument.load(srcBytes);

	await fs.mkdir(slicesDirPath(id), { recursive: true });
	const updatedSlices = [...(projectSlices.get(id) ?? [])];
	const results: JobResult[] = [];

	for (const r of requested) {
		try {
			const newDoc = await PDFDocument.create();
			const indices: number[] = [];
			for (let p = r.start_page; p <= r.end_page; p++) indices.push(p - 1);
			const copied = await newDoc.copyPages(srcDoc, indices);
			for (const page of copied) newDoc.addPage(page);
			const out = await newDoc.save();
			await fs.writeFile(slicePath(id, r.filename), out);
			const now = new Date().toISOString();
			const rec: SliceRecord = {
				filename: r.filename,
				page_range: [r.start_page, r.end_page],
				size_bytes: out.length,
				created_at: now
			};
			await fs.writeFile(sliceMetaPath(id, r.filename), JSON.stringify(rec, null, 2));
			const existingIdx = updatedSlices.findIndex((s) => s.filename === r.filename);
			if (existingIdx >= 0) updatedSlices[existingIdx] = rec;
			else updatedSlices.push(rec);
			results.push({
				filename: r.filename,
				status: 'completed',
				page_range: [r.start_page, r.end_page],
				size_bytes: out.length,
				error: null
			});
		} catch (e) {
			results.push({
				filename: r.filename,
				status: 'failed',
				page_range: [r.start_page, r.end_page],
				size_bytes: 0,
				error: e instanceof Error ? e.message : 'Unknown error'
			});
		}
	}

	projectSlices.set(id, updatedSlices);

	const job_id = 'job_' + uuidv4();
	const allFailed = results.length > 0 && results.every((r) => r.status === 'failed');
	const jobRecord: JobRecord = {
		job_id,
		status: allFailed ? 'failed' : 'completed',
		progress: 1,
		results,
		error: allFailed ? 'All slices failed' : null
	};
	jobs.set(job_id, jobRecord);

	return c.json({ job_id, status: 'queued' }, 202);
});

// GET /api/v1/projects/:id/jobs/:job_id
app.get('/api/v1/projects/:id/jobs/:job_id', (c) => {
	const id = c.req.param('id');
	const jobId = c.req.param('job_id');
	if (!projects.has(id)) return apiError(c, 404, 'NOT_FOUND', 'Project not found');
	const job = jobs.get(jobId);
	if (!job) return apiError(c, 404, 'NOT_FOUND', 'Job not found');
	return c.json(job);
});

// GET /api/v1/projects/:id/slices
app.get('/api/v1/projects/:id/slices', (c) => {
	const id = c.req.param('id');
	if (!projects.has(id)) return apiError(c, 404, 'NOT_FOUND', 'Project not found');
	return c.json({ slices: projectSlices.get(id) ?? [] });
});

// DELETE /api/v1/projects/:id/slices/:filename
app.delete('/api/v1/projects/:id/slices/:filename', async (c) => {
	const id = c.req.param('id');
	const filenameParam = c.req.param('filename');
	const filename = decodeURIComponent(filenameParam);
	if (!isSafeFilename(filename)) return apiError(c, 400, 'INVALID_FILENAME', 'Bad filename');
	if (!projects.has(id)) return apiError(c, 404, 'NOT_FOUND', 'Project not found');
	const list = projectSlices.get(id) ?? [];
	const idx = list.findIndex((s) => s.filename === filename);
	if (idx < 0) return apiError(c, 404, 'NOT_FOUND', 'Slice not found');
	const sliceFile = slicePath(id, filename);
	const sliceMeta = sliceMetaPath(id, filename);
	try {
		await fs.rm(sliceFile, { force: true });
		await fs.rm(sliceMeta, { force: true });
	} catch (e) {
		console.warn(`failed to remove slice files for ${id}/${filename}:`, e);
	}
	list.splice(idx, 1);
	projectSlices.set(id, list);
	return c.body(null, 204);
});

// GET /api/v1/projects/:id/slices/:filename
app.get('/api/v1/projects/:id/slices/:filename', async (c) => {
	const id = c.req.param('id');
	const filenameParam = c.req.param('filename');
	const filename = decodeURIComponent(filenameParam);
	if (!isSafeFilename(filename)) return apiError(c, 400, 'INVALID_FILENAME', 'Bad filename');
	if (!projects.has(id)) return apiError(c, 404, 'NOT_FOUND', 'Project not found');
	const p = slicePath(id, filename);
	if (!existsSync(p)) return apiError(c, 404, 'NOT_FOUND', 'Slice not found');
	const bytes = await fs.readFile(p);
	return new Response(new Uint8Array(bytes), {
		status: 200,
		headers: {
			'Content-Type': 'application/pdf',
			'Content-Disposition': `inline; filename="${filename.replace(/"/g, '')}"`
		}
	});
});

// Catch-all for unknown /api/* routes
app.all('/api/*', (c) => apiError(c, 404, 'NOT_FOUND', 'Endpoint not found'));

// ---- Startup --------------------------------------------------------------

await loadFromDisk();
console.log(`Loaded ${projects.size} project(s) from ${STORAGE_DIR}`);
serve({ fetch: app.fetch, port: PORT }, (info) => {
	console.log(`Mock daemon listening on http://localhost:${info.port}`);
});
