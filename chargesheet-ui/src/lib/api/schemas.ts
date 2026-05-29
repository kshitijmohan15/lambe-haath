import { z } from 'zod';

export const ChargesheetMetadataSchema = z.object({
	filename: z.string(),
	page_count: z.number().int().positive(),
	size_bytes: z.number().int().nonnegative()
});

export const ProjectSchema = z.object({
	id: z.string(),
	name: z.string(),
	description: z.string().nullable(),
	created_at: z.string(),
	last_opened_at: z.string(),
	chargesheet: ChargesheetMetadataSchema,
	slice_count: z.number().int().nonnegative(),
	extraction_count: z.number().int().nonnegative(),
	prompt_count: z.number().int().nonnegative(),
	current_stage: z.enum(['slice', 'extract', 'analyze', 'review'])
});

export const ProjectListSchema = z.array(ProjectSchema);

export const JobStatusSchema = z.enum(['queued', 'running', 'completed', 'failed', 'canceled']);

export const SliceResultSchema = z.object({
	filename: z.string(),
	status: z.enum(['completed', 'failed']),
	page_range: z.tuple([z.number().int(), z.number().int()]),
	size_bytes: z.number().int().nonnegative(),
	error: z.string().nullable()
});

export const JobStatusResponseSchema = z.object({
	job_id: z.string(),
	status: JobStatusSchema,
	progress: z.number().min(0).max(1),
	results: z.array(SliceResultSchema),
	error: z.string().nullable()
});

export const JobCreatedResponseSchema = z.object({
	job_id: z.string(),
	status: z.literal('queued')
});

export const SliceListingItemSchema = z.object({
	filename: z.string(),
	page_range: z.tuple([z.number().int(), z.number().int()]),
	size_bytes: z.number().int().nonnegative(),
	created_at: z.string()
});

export const SliceListResponseSchema = z.object({
	slices: z.array(SliceListingItemSchema)
});

export const HealthResponseSchema = z.object({
	status: z.literal('ok'),
	version: z.string()
});

export const ApiErrorSchema = z.object({
	code: z.string(),
	message: z.string(),
	details: z.unknown().optional()
});

// --- Extractions ---

export const ExtractionRowSchema = z.object({
	project_id: z.string(),
	slice_filename: z.string(),
	markdown_path: z.string(),
	meta_path: z.string(),
	model: z.string(),
	pages: z.number().int().positive(),
	page_markers_found: z.number().int().nonnegative(),
	input_tokens: z.number().int().nullable(),
	output_tokens: z.number().int().nullable(),
	input_cost_usd: z.number().nullable(),
	output_cost_usd: z.number().nullable(),
	latency_s: z.number(),
	created_at: z.string(),
});

export const ExtractionsListResponseSchema = z.array(ExtractionRowSchema);

// --- Prompt outputs ---

export const PromptOutputRowSchema = z.object({
	project_id: z.string(),
	prompt_name: z.string(),
	markdown_path: z.string(),
	model: z.string(),
	input_tokens: z.number().int().nullable(),
	output_tokens: z.number().int().nullable(),
	input_cost_usd: z.number().nullable(),
	output_cost_usd: z.number().nullable(),
	latency_s: z.number(),
	warnings: z.array(z.string()),
	created_at: z.string(),
});

export const PromptOutputsListResponseSchema = z.array(PromptOutputRowSchema);

// --- Job logs ---

export const LogLevelSchema = z.enum(['debug', 'info', 'warning', 'error']);

export const JobLogEntrySchema = z.object({
	ts: z.string(),
	level: LogLevelSchema,
	logger: z.string(),
	message: z.string(),
});

export const JobLogsResponseSchema = z.array(JobLogEntrySchema);

// --- Job (full status) ---

export const JobSchema = z.object({
	job_id: z.string(),
	status: JobStatusSchema,
	progress: z.number().min(0).max(1),
	results: z.unknown().nullable(),
	error: z.string().nullable(),
});

// --- Job list (GET /projects/:id/jobs) ---

export const JobListEntrySchema = z.object({
	job_id: z.string(),
	type: z.enum(['slice', 'ocr', 'prompt']),
	status: JobStatusSchema,
	progress: z.number().min(0).max(1),
	payload: z.unknown(), // raw JSON value; UI extracts slice_filename / prompt_name from it
	created_at: z.string(),
});

export const JobsListResponseSchema = z.array(JobListEntrySchema);

// --- Stats ---

export const KindTotalsSchema = z.object({
	kind: z.string(),
	runs: z.number().int().nonnegative(),
	in_tokens: z.number().int().nonnegative(),
	out_tokens: z.number().int().nonnegative(),
	cost_usd: z.number().nonnegative(),
	avg_latency_s: z.number().nonnegative(),
});

export const ModelTotalsSchema = z.object({
	model: z.string(),
	runs: z.number().int().nonnegative(),
	in_tokens: z.number().int().nonnegative(),
	out_tokens: z.number().int().nonnegative(),
	cost_usd: z.number().nonnegative(),
});

export const ProjectTotalsSchema = z.object({
	project_id: z.string(),
	ocr_cost_usd: z.number().nonnegative(),
	prompt_cost_usd: z.number().nonnegative(),
	total_in_tokens: z.number().int().nonnegative(),
	total_out_tokens: z.number().int().nonnegative(),
	ocr_runs: z.number().int().nonnegative(),
	prompt_runs: z.number().int().nonnegative(),
});

export const OverviewSchema = z.object({
	lifetime: z.object({
		ocr: KindTotalsSchema,
		prompt: KindTotalsSchema,
	}),
	per_model: z.array(ModelTotalsSchema),
	top_projects: z.array(ProjectTotalsSchema),
});

export const DayBucketSchema = z.object({
	day: z.string(),
	in_tokens: z.number().int().nonnegative(),
	out_tokens: z.number().int().nonnegative(),
	cost_usd: z.number().nonnegative(),
});

export const TimeseriesResponseSchema = z.array(DayBucketSchema);

export const SlowJobSchema = z.object({
	kind: z.enum(['extraction', 'prompt']),
	project_id: z.string(),
	subject: z.string(),
	model: z.string(),
	latency_s: z.number().nonnegative(),
	total_tokens: z.number().int().nonnegative(),
	created_at: z.string(),
});

export const SlowJobsResponseSchema = z.array(SlowJobSchema);
