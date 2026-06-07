/* ============================================================================
   Virtual David - ingest run tracking.

   One row per ingest run, updated live as it progresses and finalised on
   completion / stop / timeout / error. Gives the admin page a persistent record
   of what happened (survives a request timeout or a CF restart).

   Run once against the CodeRepos DB.
   ============================================================================ */

IF OBJECT_ID('dbo.ingest_runs', 'U') IS NULL
CREATE TABLE dbo.ingest_runs (
    ingest_run_id   INT            IDENTITY(1,1) NOT NULL PRIMARY KEY,
    repo_id         INT            NOT NULL,
    status          VARCHAR(20)    NOT NULL DEFAULT 'running',  -- running|completed|stopped|timedout|error
    started_at      DATETIME       NOT NULL DEFAULT GETDATE(),
    finished_at     DATETIME       NULL,
    heartbeat_at    DATETIME       NULL,                         -- last progress write; staleness = stalled/killed
    scanned         INT            NOT NULL DEFAULT 0,
    new_files       INT            NOT NULL DEFAULT 0,
    changed         INT            NOT NULL DEFAULT 0,
    skipped         INT            NOT NULL DEFAULT 0,
    deleted         INT            NOT NULL DEFAULT 0,
    chunks_written  INT            NOT NULL DEFAULT 0,
    error_count     INT            NOT NULL DEFAULT 0,
    current_file    NVARCHAR(500)  NULL,
    message         NVARCHAR(2000) NULL,
    CONSTRAINT FK_ingest_runs_repo FOREIGN KEY (repo_id) REFERENCES dbo.repos(repo_id)
);
GO

CREATE INDEX IX_ingest_runs_repo ON dbo.ingest_runs(repo_id, ingest_run_id DESC);
GO
