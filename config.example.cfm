<!--- =========================================================================
      Virtual David - configuration template.
      Copy this file to config.cfm and fill in the real values.
      config.cfm is gitignored because it holds secrets.
      ========================================================================= --->
<cfscript>
    // --- Database -----------------------------------------------------------
    // ColdFusion datasource name (you create this in the CF admin).
    request.dsn = "virtualdavid";
    // Optional explicit credentials. Leave blank to use the datasource's own.
    request.dsnUsername = "";
    request.dsnPassword = "";

    // --- Azure OpenAI: chat (reused from Lucinda) ---------------------------
    request.openAI_apiKey              = "YOUR_AZURE_API_KEY";
    request.openAI_endPoint            = "https://YOUR-RESOURCE.cognitiveservices.azure.com/openai/deployments/gpt-5-mini/chat/completions?api-version=2025-04-01-preview";
    request.openAI_modelDeploymentName = "gpt-5-mini";

    // --- Azure OpenAI: embeddings (you provision this deployment) -----------
    // Add a text-embedding-3-small deployment to the SAME Azure resource, then
    // point this at it. -3-small = 1536 dims, -3-large = 3072 dims.
    request.openAI_embeddingEndpoint = "https://YOUR-RESOURCE.cognitiveservices.azure.com/openai/deployments/text-embedding-3-small/embeddings?api-version=2024-02-01";
    request.openAI_embeddingModel    = "text-embedding-3-small";

    // --- Ingestion defaults -------------------------------------------------
    request.ingest.defaultExtensions = "cfm,cfc,cfml,js,sql,md,txt,css,html";
    request.ingest.maxFileKb         = 512;     // skip files larger than this
    request.ingest.chunkLines        = 60;      // lines per chunk
    request.ingest.chunkOverlap      = 10;      // overlapping lines between chunks
    request.ingest.maxChunkChars     = 6000;    // hard char cap per chunk (token guard)

    // --- Retrieval defaults -------------------------------------------------
    request.retrieval.topK           = 8;       // chunks fed to the model per question
    request.retrieval.maxAnswerTokens = 4000;
</cfscript>
