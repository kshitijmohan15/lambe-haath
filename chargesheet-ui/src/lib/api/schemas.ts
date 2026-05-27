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
	chargesheet: ChargesheetMetadataSchema
});

export const ProjectListSchema = z.array(ProjectSchema);

export const JobStatusSchema = z.enum(['queued', 'running', 'completed', 'failed']);

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
