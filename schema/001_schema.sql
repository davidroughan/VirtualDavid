/* ============================================================================
   Virtual David - database schema (SQL Server)
   Run once against the 'virtualdavid' database.

   Storage model: embeddings are stored as JSON arrays in NVARCHAR(MAX) so this
   works on any SQL Server version. Cosine similarity is computed in ColdFusion.
   If you later move to SQL Server 2025, code_chunks.embedding becomes a VECTOR
   column and only VectorStore.cfc changes.
   ============================================================================ */

/* ----------------------------------------------------------------------------
   repos - the codebases to vectorise. Local filesystem paths.
   ---------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.repos', 'U') IS NULL
CREATE TABLE dbo.repos (
    repo_id            INT             IDENTITY(1,1) NOT NULL PRIMARY KEY,
    name               NVARCHAR(200)   NOT NULL,
    local_path         NVARCHAR(500)   NOT NULL,
    include_extensions NVARCHAR(500)   NOT NULL DEFAULT 'cfm,cfc,cfml,js,sql,md,txt,css,html',
    exclude_patterns   NVARCHAR(1000)  NULL,           -- csv of substrings to skip (e.g. node_modules,.git,\min\)
    max_file_kb        INT             NOT NULL DEFAULT 512,
    enabled            BIT             NOT NULL DEFAULT 1,
    last_indexed       DATETIME        NULL,
    created_at         DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

CREATE UNIQUE INDEX UX_repos_name ON dbo.repos(name);
GO

/* ----------------------------------------------------------------------------
   code_files - one row per ingested file. file_hash drives incremental re-index.
   ---------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.code_files', 'U') IS NULL
CREATE TABLE dbo.code_files (
    file_id        INT            IDENTITY(1,1) NOT NULL PRIMARY KEY,
    repo_id        INT            NOT NULL,
    relative_path  NVARCHAR(500)  NOT NULL,
    file_hash      CHAR(64)       NOT NULL,           -- SHA-256 of file content
    size_bytes     INT            NOT NULL DEFAULT 0,
    language       NVARCHAR(50)   NULL,               -- derived from extension
    chunk_count    INT            NOT NULL DEFAULT 0,
    is_deleted     BIT            NOT NULL DEFAULT 0,  -- file vanished from disk on last run
    indexed_at     DATETIME       NOT NULL DEFAULT GETDATE(),
    CONSTRAINT FK_code_files_repo FOREIGN KEY (repo_id) REFERENCES dbo.repos(repo_id)
);
GO

CREATE UNIQUE INDEX UX_code_files_repo_path ON dbo.code_files(repo_id, relative_path);
GO

/* ----------------------------------------------------------------------------
   code_chunks - the vectorised units. embedding is a normalised JSON float array.
   ---------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.code_chunks', 'U') IS NULL
CREATE TABLE dbo.code_chunks (
    chunk_id         INT            IDENTITY(1,1) NOT NULL PRIMARY KEY,
    file_id          INT            NOT NULL,
    repo_id          INT            NOT NULL,          -- denormalised for fast repo filtering
    chunk_index      INT            NOT NULL,
    start_line       INT            NOT NULL,
    end_line         INT            NOT NULL,
    content          NVARCHAR(MAX)  NOT NULL,
    token_estimate   INT            NOT NULL DEFAULT 0,
    embedding        NVARCHAR(MAX)  NULL,              -- JSON array, L2-normalised (NULL = not yet embedded)
    embedding_model  NVARCHAR(100)  NULL,
    embedding_dims   INT            NULL,
    created_at       DATETIME       NOT NULL DEFAULT GETDATE(),
    CONSTRAINT FK_code_chunks_file FOREIGN KEY (file_id) REFERENCES dbo.code_files(file_id)
);
GO

CREATE INDEX IX_code_chunks_repo ON dbo.code_chunks(repo_id);
GO
CREATE INDEX IX_code_chunks_file ON dbo.code_chunks(file_id);
GO

/* ----------------------------------------------------------------------------
   ai_usage_log - column-identical to Lucinda's so the copied AzureOpenAI.cfc
   logging code runs unchanged.
   ---------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.ai_usage_log', 'U') IS NULL
CREATE TABLE dbo.ai_usage_log (
    ai_usage_log_id        INT            IDENTITY(1,1) NOT NULL PRIMARY KEY,
    user_id                INT            NULL,
    user_email             NVARCHAR(200)  NULL,
    session_id             VARCHAR(100)   NULL,
    caller_template        NVARCHAR(500)  NULL,
    purpose                VARCHAR(100)   NULL,
    endpoint_url           NVARCHAR(500)  NULL,
    model_deployment_name  VARCHAR(100)   NULL,
    request_size_bytes     INT            NOT NULL DEFAULT 0,
    response_size_bytes    INT            NOT NULL DEFAULT 0,
    prompt_tokens          INT            NULL,
    completion_tokens      INT            NULL,
    reasoning_tokens       INT            NULL,
    total_tokens           INT            NULL,
    duration_ms            INT            NOT NULL DEFAULT 0,
    http_status_code       INT            NOT NULL DEFAULT 0,
    finish_reason          VARCHAR(50)    NULL,
    success                BIT            NOT NULL DEFAULT 0,
    error_message          NVARCHAR(2000) NULL,
    remote_ip              VARCHAR(50)    NULL,
    created_at             DATETIME       NOT NULL DEFAULT GETDATE()
);
GO

/* ----------------------------------------------------------------------------
   chat_log - questions asked of Virtual David and the answers given.
   ---------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.chat_log', 'U') IS NULL
CREATE TABLE dbo.chat_log (
    chat_id           INT            IDENTITY(1,1) NOT NULL PRIMARY KEY,
    question          NVARCHAR(MAX)  NOT NULL,
    answer            NVARCHAR(MAX)  NULL,
    source_chunk_ids  NVARCHAR(1000) NULL,             -- csv of chunk_id used as context
    prompt_tokens     INT            NULL,
    completion_tokens INT            NULL,
    total_tokens      INT            NULL,
    success           BIT            NOT NULL DEFAULT 0,
    remote_ip         VARCHAR(50)    NULL,
    created_at        DATETIME       NOT NULL DEFAULT GETDATE()
);
GO
