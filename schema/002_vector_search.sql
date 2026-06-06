/* ============================================================================
   Virtual David - migrate to SQL Server 2025 native VECTOR search.

   Requires SQL Server 2025 (engine v17+). Run once against the CodeRepos DB.
   After this, similarity search runs inside SQL via VECTOR_DISTANCE() and the
   app no longer holds any vectors in ColdFusion memory.
   ============================================================================ */

/* Native vector features expect database compatibility level 170. */
ALTER DATABASE CURRENT SET COMPATIBILITY_LEVEL = 170;
GO

/* Add the native vector column. text-embedding-3-small = 1536 dimensions
   (well under SQL 2025's 1998-dim limit). */
IF COL_LENGTH('dbo.code_chunks', 'embedding_vec') IS NULL
    ALTER TABLE dbo.code_chunks ADD embedding_vec VECTOR(1536) NULL;
GO

/* Backfill from the existing JSON embeddings - NO re-embedding required.
   TRY_CAST so any malformed row becomes NULL instead of failing the batch. */
UPDATE dbo.code_chunks
SET    embedding_vec = TRY_CAST(embedding AS VECTOR(1536))
WHERE  embedding_vec IS NULL
  AND  embedding IS NOT NULL;
GO

/* Sanity check - how many chunks now have a usable vector. */
SELECT COUNT(*) AS total_chunks,
       SUM(CASE WHEN embedding_vec IS NOT NULL THEN 1 ELSE 0 END) AS with_vector
FROM   dbo.code_chunks;
GO

/* The JSON 'embedding' column is now unused by the app. It's left in place so
   this migration stays reversible. Once you're happy, reclaim the space with:
       ALTER TABLE dbo.code_chunks DROP COLUMN embedding;

   At ~12k rows an exact VECTOR_DISTANCE scan is instant, so no vector index is
   needed. If the corpus ever reaches the millions, add a DiskANN index then. */
