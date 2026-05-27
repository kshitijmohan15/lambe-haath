CREATE TABLE schema_version (
    version INTEGER PRIMARY KEY
);
INSERT INTO schema_version VALUES (1);

CREATE TABLE projects (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    description TEXT,
    created_at TEXT NOT NULL,
    last_opened_at TEXT NOT NULL,
    chargesheet_filename TEXT NOT NULL,
    chargesheet_page_count INTEGER NOT NULL CHECK (chargesheet_page_count > 0),
    chargesheet_size_bytes INTEGER NOT NULL CHECK (chargesheet_size_bytes >= 0)
);

CREATE INDEX idx_projects_last_opened ON projects(last_opened_at DESC);

CREATE TABLE slices (
    project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    filename TEXT NOT NULL,
    start_page INTEGER NOT NULL CHECK (start_page >= 1),
    end_page INTEGER NOT NULL CHECK (end_page >= start_page),
    size_bytes INTEGER NOT NULL CHECK (size_bytes >= 0),
    created_at TEXT NOT NULL,
    PRIMARY KEY (project_id, filename)
);

CREATE TABLE jobs (
    id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    type TEXT NOT NULL CHECK (type IN ('slice')),
    status TEXT NOT NULL CHECK (status IN ('queued', 'running', 'completed', 'failed')),
    progress REAL NOT NULL DEFAULT 0 CHECK (progress >= 0 AND progress <= 1),
    payload TEXT NOT NULL,
    results TEXT,
    error TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE INDEX idx_jobs_status ON jobs(status);
CREATE INDEX idx_jobs_project ON jobs(project_id);
