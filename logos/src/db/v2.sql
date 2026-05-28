-- v2: chargesheet pipeline additions
-- Migration runs inside a single transaction wrapped by migrations.zig::applyV2.

INSERT INTO schema_version VALUES (2);

-- slices: add kind/kind_key for fast dispatcher lookup
ALTER TABLE slices ADD COLUMN kind TEXT;
ALTER TABLE slices ADD COLUMN kind_key TEXT;

CREATE INDEX idx_slices_kind ON slices(project_id, kind, kind_key);

-- jobs: expand type CHECK and add 'canceled' status; SQLite requires table rebuild
CREATE TABLE jobs_new (
    id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    type TEXT NOT NULL CHECK (type IN ('slice', 'ocr', 'prompt')),
    status TEXT NOT NULL CHECK (status IN ('queued', 'running', 'completed', 'failed', 'canceled')),
    progress REAL NOT NULL DEFAULT 0 CHECK (progress >= 0 AND progress <= 1),
    payload TEXT NOT NULL,
    results TEXT,
    error TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
INSERT INTO jobs_new SELECT * FROM jobs;
DROP TABLE jobs;
ALTER TABLE jobs_new RENAME TO jobs;
CREATE INDEX idx_jobs_status      ON jobs(status);
CREATE INDEX idx_jobs_project     ON jobs(project_id);
CREATE INDEX idx_jobs_status_type ON jobs(status, type);

-- extractions: one row per OCR'd slice (upsert on conflict)
CREATE TABLE extractions (
    project_id          TEXT    NOT NULL,
    slice_filename      TEXT    NOT NULL,
    markdown_path       TEXT    NOT NULL,
    meta_path           TEXT    NOT NULL,
    model               TEXT    NOT NULL,
    pages               INTEGER NOT NULL CHECK (pages > 0),
    page_markers_found  INTEGER NOT NULL CHECK (page_markers_found >= 0),
    input_tokens        INTEGER,
    output_tokens       INTEGER,
    input_cost_usd      REAL,
    output_cost_usd     REAL,
    latency_s           REAL    NOT NULL,
    created_at          TEXT    NOT NULL,
    PRIMARY KEY (project_id, slice_filename),
    FOREIGN KEY (project_id, slice_filename)
        REFERENCES slices(project_id, filename) ON DELETE CASCADE
);

-- prompt_outputs: one row per (project_id, prompt_name) (upsert on conflict)
CREATE TABLE prompt_outputs (
    project_id       TEXT    NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    prompt_name      TEXT    NOT NULL,
    markdown_path    TEXT    NOT NULL,
    model            TEXT    NOT NULL,
    input_tokens     INTEGER,
    output_tokens    INTEGER,
    input_cost_usd   REAL,
    output_cost_usd  REAL,
    latency_s        REAL    NOT NULL,
    warnings         TEXT    NOT NULL DEFAULT '[]',
    created_at       TEXT    NOT NULL,
    PRIMARY KEY (project_id, prompt_name)
);

-- job_logs: per-line agent logs
CREATE TABLE job_logs (
    id       INTEGER PRIMARY KEY AUTOINCREMENT,
    job_id   TEXT    NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
    ts       TEXT    NOT NULL,
    level    TEXT    NOT NULL CHECK (level IN ('debug','info','warning','error')),
    logger   TEXT    NOT NULL,
    message  TEXT    NOT NULL
);
CREATE INDEX idx_job_logs_job_ts ON job_logs(job_id, ts);
