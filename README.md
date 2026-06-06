# Virtual David

A ColdFusion app that answers developers' questions **in David's voice**, grounded in his actual codebases via RAG (retrieval-augmented generation).

Ask a question → the question is embedded → the most relevant code chunks are retrieved from the vector store → they're fed to the chat model alongside David's persona ([SystemPrompt.txt](SystemPrompt.txt)) → you get a grounded, cited answer.

## How it works

```
Ask (index.cfm) ─▶ ajax_ask.cfm ─▶ RAG.cfc
                                      ├─ embed question      (AzureOpenAI.callEmbeddings)
                                      ├─ cosine search top-K (VectorStore.cosineSearch)
                                      └─ chat w/ persona+ctx (AzureOpenAI.callChatCompletion)

Ingest (admin/ingest.cfm) ─▶ Ingestor.cfc
                               ├─ walk repo's local path, filter by ext/size
                               ├─ SHA-256 each file → skip unchanged (incremental)
                               ├─ chunk by lines (overlap), embed each chunk
                               └─ store vector (code_chunks.embedding_vec = VECTOR(1536))
```

Similarity search runs **inside SQL Server 2025** via `VECTOR_DISTANCE('cosine', …)` over a native `VECTOR(1536)` column — see [VectorStore.cosineSearch](cfcs/VectorStore.cfc). ColdFusion never holds the vectors in memory: it sends the question's embedding and gets back the top-K rows. At ~12k chunks an exact scan is instant; add a DiskANN vector index only if the corpus reaches the millions.

> Requires **SQL Server 2025** (engine v17+) for the native vector type. The original design did cosine in ColdFusion over a JSON column (portable to any SQL version) — that's preserved in git history if you ever need the portable path.

## Setup

1. **Datasource** — create a ColdFusion datasource named `CodeRepos` (or change `request.dsn` in `config.cfm`) pointing at a SQL Server 2025 DB.
2. **Schema** — run [schema/001_schema.sql](schema/001_schema.sql) then [schema/002_vector_search.sql](schema/002_vector_search.sql) against that DB.
3. **Config** — `config.cfm` already holds the reused Azure key + chat endpoint. Provision a **text-embedding-3-small** deployment on the same Azure resource and confirm `request.openAI_embeddingEndpoint` / `request.openAI_embeddingModel`.
4. **Smoke test** — hit `admin/test.cfm`. All three checks (datasource, embeddings, chat) should be green before going further.
5. **Add + ingest a repo** — `admin/ingest.cfm` → add a repo (name + local path) → **Ingest**. Start with a small repo to confirm the flow.
6. **Ask** — `index.cfm`.

Re-running ingest only re-embeds files whose contents changed (SHA-256), and drops chunks for files removed from disk.

## Files

| Path | Role |
|------|------|
| `Application.cfc` | App bootstrap; loads `config.cfm`, builds `request.queryAttributes`, maps `/cfcs`. |
| `config.cfm` | Secrets + tunables (gitignored). Template: `config.example.cfm`. |
| `cfcs/AzureOpenAI.cfc` | Azure chat + embeddings HTTP wrapper; logs usage to `ai_usage_log`. From Lucinda. |
| `cfcs/VectorStore.cfc` | Chunk persistence + in-SQL `VECTOR_DISTANCE` search. |
| `cfcs/Ingestor.cfc` | Repo walk, incremental hashing, chunking, embedding. |
| `cfcs/RAG.cfc` | Question → retrieve → grounded answer; logs to `chat_log`. |
| `index.cfm` / `ajax_ask.cfm` | Ask UI + JSON endpoint. |
| `admin/ingest.cfm` | Add repos, edit excludes, ingest, reset. |
| `admin/test.cfm` | Connectivity smoke test. |
| `schema/00*.sql` | SQL Server DDL + the vector-search migration. |

## Known tradeoffs / follow-ups

- **Requires SQL Server 2025** for the native `VECTOR` type. Search itself uses near-zero ColdFusion memory regardless of corpus size.
- **`embedding` JSON column is now dead** — `002` backfilled `embedding_vec` from it. Drop it to reclaim space: `ALTER TABLE code_chunks DROP COLUMN embedding;`
- **No auth** — the ask page is open. Add auth if it's reachable beyond a trusted network.
- **Manual ingest** — re-indexing is a button. Once proven, wire a ColdFusion scheduled task to call `Ingestor.ingestRepo` per enabled repo.
- **Embedding cost** — first ingest of a large repo is one embedding HTTP call per chunk; incremental runs after that are cheap.
