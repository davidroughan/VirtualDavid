<cfsetting requesttimeout="180">
<!--- Connectivity smoke test: datasource, embeddings endpoint, chat endpoint.
      Hit this first after wiring up the datasource and Azure embeddings deployment. --->
<cfset checks = []>

<!--- 1. Datasource + schema --->
<cftry>
    <cfquery name="q" attributeCollection="#request.queryAttributes#">
        select count(*) as n from code_chunks
    </cfquery>
    <cfset arrayAppend(checks, { name="Datasource '#request.dsn#' + schema", ok=true, detail="OK — #q.n# chunks indexed" })>
    <cfcatch type="any">
        <cfset arrayAppend(checks, { name="Datasource '#request.dsn#' + schema", ok=false, detail=cfcatch.message })>
    </cfcatch>
</cftry>

<!--- 2. Embeddings endpoint --->
<cftry>
    <cfset oai = createObject("component", "cfcs.AzureOpenAI")>
    <cfset emb = oai.callEmbeddings(inputText="hello world", purpose="smoketest_embedding")>
    <cfif emb.success>
        <cfset arrayAppend(checks, { name="Embeddings endpoint", ok=true, detail="OK — #emb.dims#-dim vector, #val(emb.usage.total_tokens)# tokens" })>
    <cfelse>
        <cfset arrayAppend(checks, { name="Embeddings endpoint", ok=false, detail="HTTP #emb.statusCode#: #emb.errorMessage#" })>
    </cfif>
    <cfcatch type="any">
        <cfset arrayAppend(checks, { name="Embeddings endpoint", ok=false, detail=cfcatch.message })>
    </cfcatch>
</cftry>

<!--- 3. Chat endpoint --->
<cftry>
    <cfset oai = createObject("component", "cfcs.AzureOpenAI")>
    <cfset body = serializeJSON({
        "messages" = [ { "role"="user", "content"="Reply with the single word: ok" } ],
        "max_completion_tokens" = 50
    })>
    <cfset chat = oai.callChatCompletion(jsonBody=body, purpose="smoketest_chat")>
    <cfif chat.success>
        <cfset reply = chat.parsed.choices[1].message.content>
        <cfset arrayAppend(checks, { name="Chat endpoint (#request.openAI_modelDeploymentName#)", ok=true, detail="OK — replied: " & left(reply, 60) })>
    <cfelse>
        <cfset arrayAppend(checks, { name="Chat endpoint", ok=false, detail="HTTP #chat.statusCode#: #chat.errorMessage#" })>
    </cfif>
    <cfcatch type="any">
        <cfset arrayAppend(checks, { name="Chat endpoint", ok=false, detail=cfcatch.message })>
    </cfcatch>
</cftry>

<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><title>Virtual David — Smoke test</title>
<style>
    body{margin:0;background:#1e1e1e;color:#e6e6e6;font:15px/1.5 -apple-system,Segoe UI,Roboto,sans-serif;}
    .wrap{max-width:760px;margin:0 auto;padding:28px 18px;}
    h1{font-size:19px;}
    .row{display:flex;gap:12px;align-items:flex-start;padding:14px 16px;border-radius:9px;margin-bottom:12px;
         background:#252526;border:1px solid #3a3a3a;}
    .row.ok{border-color:#2f6b46;} .row.bad{border-color:#7a2330;}
    .dot{font-size:18px;line-height:1.3;}
    .name{font-weight:600;} .detail{color:#9aa0a6;font-family:Consolas,monospace;font-size:13px;margin-top:3px;word-break:break-word;}
    a{color:#2c95b2;}
</style></head>
<body><div class="wrap">
<cfoutput>
    <h1>Connectivity smoke test</h1>
    <p style="color:##9aa0a6"><a href="ingest.cfm">repos</a> &middot; <a href="../index.cfm">ask</a></p>
    <cfloop array="#checks#" index="c">
        <div class="row #c.ok ? 'ok' : 'bad'#">
            <div class="dot">#c.ok ? '&##10003;' : '&##10007;'#</div>
            <div><div class="name">#encodeForHTML(c.name)#</div><div class="detail">#encodeForHTML(c.detail)#</div></div>
        </div>
    </cfloop>
</cfoutput>
</div></body></html>
