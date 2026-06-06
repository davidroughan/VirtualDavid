/* ============================================================================
   Virtual David - add a last-modified stamp to code_files so re-ingests can
   skip unchanged files WITHOUT reading + hashing them.

   Detection becomes: if on-disk size AND last-modified both match the stored
   values, skip the file untouched. Only when one differs do we read + SHA-256
   to confirm a real content change. Self-populating: existing rows have NULL
   last_modified, so they get read+hashed once, then fast-skip thereafter.

   Run once against the CodeRepos DB - but NOT while an ingest is running
   (ALTER TABLE takes a schema lock on code_files).
   ============================================================================ */

IF COL_LENGTH('dbo.code_files', 'last_modified') IS NULL
    ALTER TABLE dbo.code_files ADD last_modified VARCHAR(20) NULL;
GO
