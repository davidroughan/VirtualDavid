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
                               └─ store normalised vector (code_chunks.embedding = JSON)
```

Cosine similarity runs in ColdFusion over an in-memory index cached in the `application` scope (rebuilt after each ingest). Vectors are stored **normalised** so scoring is a cheap dot product. This is portable to any SQL Server version; if you move to SQL Server 2025 you can swap to a native `VECTOR` column + `VECTOR_DISTANCE()` and only [VectorStore.cfc](cfcs/VectorStore.cfc) changes.

## Setup

1. **Datasource** — create a ColdFusion datasource named `virtualdavid` (or change `request.dsn` in `config.cfm`) pointing at a SQL Server DB.
2. **Schema** — run [schema/001_schema.sql](schema/001_schema.sql) against that DB.
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
| `cfcs/VectorStore.cfc` | Vector maths, chunk persistence, in-memory cosine search. |
| `cfcs/Ingestor.cfc` | Repo walk, incremental hashing, chunking, embedding. |
| `cfcs/RAG.cfc` | Question → retrieve → grounded answer; logs to `chat_log`. |
| `index.cfm` / `ajax_ask.cfm` | Ask UI + JSON endpoint. |
| `admin/ingest.cfm` | Add repos, trigger ingestion. |
| `admin/test.cfm` | Connectivity smoke test. |
| `schema/001_schema.sql` | SQL Server DDL. |

## Known tradeoffs / follow-ups

- **Search scale ceiling** — in-CF cosine is fine for tens of thousands of chunks; a very large multi-repo corpus will want the SQL 2025 `VECTOR` path or a packed-array optimisation.
- **No auth** — the ask page is open. Add auth if it's reachable beyond a trusted network.
- **Manual ingest** — re-indexing is a button. Once proven, wire a ColdFusion scheduled task to call `Ingestor.ingestRepo` per enabled repo.
- **Embedding cost** — first ingest of a large repo is one embedding HTTP call per chunk; incremental runs after that are cheap.
