import type { z } from 'zod';
import type * as s from './schemas';

export type ChargesheetMetadata = z.infer<typeof s.ChargesheetMetadataSchema>;
export type Project = z.infer<typeof s.ProjectSchema>;
export type ProjectList = z.infer<typeof s.ProjectListSchema>;
export type JobStatus = z.infer<typeof s.JobStatusSchema>;
export type SliceResult = z.infer<typeof s.SliceResultSchema>;
export type JobStatusResponse = z.infer<typeof s.JobStatusResponseSchema>;
export type JobCreatedResponse = z.infer<typeof s.JobCreatedResponseSchema>;
export type SliceListingItem = z.infer<typeof s.SliceListingItemSchema>;
export type SliceListResponse = z.infer<typeof s.SliceListResponseSchema>;
export type HealthResponse = z.infer<typeof s.HealthResponseSchema>;
export type ApiError = z.infer<typeof s.ApiErrorSchema>;

export interface LocalSlice {
	id: string;
	startPage: number;
	endPage: number;
	filename: string;
	status: 'draft' | 'submitting' | 'completed' | 'failed';
	error: string | null;
}

export interface SliceJobRequestSlice {
	start_page: number;
	end_page: number;
	filename: string;
}

export interface SliceJobRequest {
	slices: SliceJobRequestSlice[];
}

export interface CreateProjectInput {
	name: string;
	description: string;
	chargesheet: File;
}
