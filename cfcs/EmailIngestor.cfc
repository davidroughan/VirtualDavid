<cfcomponent displayname="EmailIngestor" output="false"
    hint="Turns saved emails into retrievable knowledge for Virtual David. Reads a .eml/.msg via EmailReader, uses the chat model to separate David's inline 'see comments below' answers from the dev's questions, then embeds David's guidance per ticket and stores it via VectorStore. Deliberately separate from Ingestor.cfc (the code walker) - emails are stored as chunks under a synthetic 'Emails' repo so they're searchable through the existing ask UI with zero schema or VectorStore changes.">

    <cffunction name="init" access="public" returntype="EmailIngestor" output="false">
        <cfset variables.reader = createObject("component", "cfcs.EmailReader").init()>
        <cfset variables.oai    = createObject("component", "cfcs.AzureOpenAI")>
        <cfset variables.store  = createObject("component", "cfcs.VectorStore")>
        <cfreturn this>
    </cffunction>

    <!--- ====================================================================
          Repo bootstrap
          ==================================================================== --->

    <!--- Find (or create) the synthetic repo that owns email chunks. Its
          include_extensions are deliberately inert ("__email__") so the normal
          code walker (Ingestor.ingestRepo) never tries to index the .eml files
          as source - this module is the only thing that writes to it. --->
    <cffunction name="ensureEmailRepo" access="public" returntype="numeric" output="false">
        <cfargument name="name"      type="string" required="false" default="Emails">
        <cfargument name="localPath" type="string" required="false" default="">

        <cfset var existing = "">
        <cfset var insertResult = "">
        <cfset var newId = 0>
        <cfset var path = len(arguments.localPath) ? arguments.localPath : (request.appRoot & "emails")>

        <cfquery name="existing" attributeCollection="#request.queryAttributes#">
            select repo_id from repos
            where name = <cfqueryparam cfsqltype="cf_sql_nvarchar" value="#arguments.name#" maxlength="200">
        </cfquery>
        <cfif existing.recordCount>
            <cfreturn val(existing.repo_id)>
        </cfif>

        <cfquery attributeCollection="#request.queryAttributes#" result="insertResult">
            insert into repos (name, local_path, include_extensions, exclude_patterns, max_file_kb)
            values (
                <cfqueryparam cfsqltype="cf_sql_nvarchar" value="#arguments.name#" maxlength="200">,
                <cfqueryparam cfsqltype="cf_sql_nvarchar" value="#path#"           maxlength="500">,
                <cfqueryparam cfsqltype="cf_sql_nvarchar" value="__email__"        maxlength="500">,
                <cfqueryparam cfsqltype="cf_sql_nvarchar" value="" null="true">,
                <cfqueryparam cfsqltype="cf_sql_integer"  value="0">
            )
        </cfquery>
        <cfif isStruct(insertResult) AND structKeyExists(insertResult, "generatedKey")>
            <cfset newId = val(insertResult.generatedKey)>
        <cfelseif isStruct(insertResult) AND structKeyExists(insertResult, "GENERATED_KEY")>
            <cfset newId = val(insertResult["GENERATED_KEY"])>
        </cfif>
        <cfreturn newId>
    </cffunction>

    <!--- ====================================================================
          Ingestion
          ==================================================================== --->

    <!--- Ingest every .eml/.msg in a folder (defaults to /emails). Incremental:
          a file whose SHA-256 matches the stored hash is skipped. --->
    <cffunction name="ingestFolder" access="public" returntype="struct" output="false">
        <cfargument name="dir"   type="string"  required="false" default="">
        <cfargument name="force" type="boolean"  required="false" default="false">

        <cfset var folder = len(arguments.dir) ? arguments.dir : (request.appRoot & "emails")>
        <cfset var repoId = ensureEmailRepo(localPath = folder)>
        <cfset var files = "">
        <cfset var fullPath = "">
        <cfset var one = "">
        <cfset var summary = {
            "repoId" = repoId, "scanned" = 0, "skipped" = 0, "ingested" = 0,
            "chunksWritten" = 0, "ticketsFound" = 0, "errors" = []
        }>

        <cfif NOT directoryExists(folder)>
            <cfthrow message="Email folder does not exist: #folder#">
        </cfif>

        <cfdirectory action="list" directory="#folder#" name="files" type="file"
                     filter="*.eml|*.msg" recurse="false">

        <cfloop query="files">
            <cfset summary.scanned++>
            <cfset fullPath = files.directory & "\" & files.name>
            <cftry>
                <cfset one = ingestFile(repoId = repoId, path = fullPath, force = arguments.force)>
                <cfif one.skipped>
                    <cfset summary.skipped++>
                <cfelse>
                    <cfset summary.ingested++>
                    <cfset summary.chunksWritten += one.chunksWritten>
                    <cfset summary.ticketsFound  += one.ticketsFound>
                </cfif>
                <cfcatch type="any">
                    <cfset arrayAppend(summary.errors, files.name & " :: " & cfcatch.message)>
                </cfcatch>
            </cftry>
        </cfloop>

        <cfreturn summary>
    </cffunction>

    <!--- Ingest a single email file. Returns
          { skipped, chunksWritten, ticketsFound, fileId, subject }. --->
    <cffunction name="ingestFile" access="public" returntype="struct" output="false">
        <cfargument name="repoId" type="numeric" required="true">
        <cfargument name="path"   type="string"  required="true">
        <cfargument name="force"  type="boolean"  required="false" default="false">

        <cfset var out = { "skipped" = false, "chunksWritten" = 0, "ticketsFound" = 0, "fileId" = 0, "subject" = "" }>
        <cfset var relPath = getFileFromPath(arguments.path)>
        <cfset var bytes = fileReadBinary(arguments.path)>
        <cfset var fileHash = lcase(hash(bytes, "SHA-256"))>
        <cfset var sizeBytes = arrayLen(bytes)>
        <cfset var existing = "">
        <cfset var fileId = 0>
        <cfset var parsed = "">
        <cfset var seg = "">
        <cfset var chunks = "">

        <!--- incremental skip --->
        <cfquery name="existing" attributeCollection="#request.queryAttributes#">
            select file_id, file_hash, is_deleted
            from code_files
            where repo_id = <cfqueryparam cfsqltype="cf_sql_integer" value="#arguments.repoId#">
              and relative_path = <cfqueryparam cfsqltype="cf_sql_nvarchar" value="#relPath#" maxlength="500">
        </cfquery>
        <cfif NOT arguments.force AND existing.recordCount AND existing.is_deleted eq 0 AND existing.file_hash eq fileHash>
            <cfset out.skipped = true>
            <cfset out.fileId = val(existing.file_id)>
            <cfreturn out>
        </cfif>

        <!--- parse --->
        <cfset parsed = variables.reader.readFile(path = arguments.path)>
        <cfif NOT parsed.success>
            <cfthrow message="Could not read email: #parsed.error#">
        </cfif>
        <cfset out.subject = parsed.headers.subject>

        <!--- separate the dev's questions from David's inline answers (LLM) --->
        <cfset seg = segmentTickets(parsed)>
        <cfset out.ticketsFound = arrayLen(seg.tickets)>

        <!--- build retrievable chunks (one per ticket that carries guidance) --->
        <cfset chunks = buildChunks(parsed, seg)>
        <cfif NOT arrayLen(chunks)>
            <cfthrow message="No David guidance extracted from this email - nothing to index. (Tickets seen: #out.ticketsFound#)">
        </cfif>

        <!--- upsert the file row, then re-embed from scratch --->
        <cfif existing.recordCount>
            <cfset fileId = val(existing.file_id)>
            <cfset variables.store.deleteChunksForFile(fileId)>
            <cfquery attributeCollection="#request.queryAttributes#">
                update code_files
                set file_hash = <cfqueryparam cfsqltype="cf_sql_char" value="#fileHash#" maxlength="64">,
                    size_bytes = <cfqueryparam cfsqltype="cf_sql_integer" value="#sizeBytes#">,
                    language = 'email', is_deleted = 0, indexed_at = getDate()
                where file_id = <cfqueryparam cfsqltype="cf_sql_integer" value="#fileId#">
            </cfquery>
        <cfelse>
            <cfset fileId = insertFileRow(arguments.repoId, relPath, fileHash, sizeBytes)>
        </cfif>
        <cfset out.fileId = fileId>

        <cfset out.chunksWritten = embedAndStore(arguments.repoId, fileId, relPath, chunks)>

        <cfquery attributeCollection="#request.queryAttributes#">
            update code_files set chunk_count = <cfqueryparam cfsqltype="cf_sql_integer" value="#out.chunksWritten#">
            where file_id = <cfqueryparam cfsqltype="cf_sql_integer" value="#fileId#">
        </cfquery>

        <cfreturn out>
    </cffunction>

    <!--- ====================================================================
          LLM segmentation of the inline "see comments below" reply
          ==================================================================== --->

    <!---
        segmentTickets
        --------------
        The innermost message (parsed.original) is the dev's email with David's
        answers typed directly under each point - no quote markers. Rules alone
        can't reliably tell whose words are whose, so we ask the chat model to do
        it, returning strict JSON. Result:

            { devName, threadSubject,
              tickets: [ { ref, dev_question, david_answer, files_referenced[], has_david_answer } ] }
    --->
    <cffunction name="segmentTickets" access="public" returntype="struct" output="false">
        <cfargument name="parsed" type="struct" required="true">

        <cfset var original = structKeyExists(arguments.parsed, "original") AND structCount(arguments.parsed.original)
                              ? arguments.parsed.original : { "from" = "", "subject" = arguments.parsed.headers.subject, "body" = arguments.parsed.cleanText }>
        <cfset var devName = len(original.from) ? original.from : "the developer">
        <cfset var subject = len(original.subject) ? original.subject : arguments.parsed.headers.subject>
        <cfset var out = { "devName" = devName, "threadSubject" = subject, "tickets" = [] }>
        <cfset var sys = "">
        <cfset var usr = "">
        <cfset var jsonBody = "">
        <cfset var chat = "">
        <cfset var content = "">
        <cfset var data = "">
        <cfset var t = "">
        <cfset var files = "">
        <cfset var f = "">

        <cfsavecontent variable="sys"><cfoutput>You are parsing a forwarded support email so a knowledge base can store the senior architect's guidance.

David Roughan (Lead Application Architect) received an email from a developer listing several support/service tickets and asking for guidance. David replied "see comments below" and typed his answers INLINE, directly beneath each of the developer's points, WITHOUT any quote markers (no ">" characters). So in the text, a block of the developer's wording is followed by David's reply in David's own words, then the next ticket, and so on.

Your job: split the thread into individual tickets and, for each, separate the developer's question from David's answer.

Output STRICT JSON only (no prose, no markdown) with this exact shape:
{
  "tickets": [
    {
      "ref": "the ticket heading/number as written, e.g. 'Service Ticket ##259655 - FW: Issues with merging opportunity'",
      "dev_question": "the developer's words for this ticket (what they asked / reported)",
      "david_answer": "David's reply for this ticket, in his words. Empty string if he gave none.",
      "files_referenced": ["any source file names David names, e.g. pop_company_edit.cfm"],
      "has_david_answer": true
    }
  ]
}

Rules:
- One array entry per distinct ticket, in the order they appear.
- david_answer must be ONLY David's text, with the developer's question removed.
- Ignore email signatures, names/titles/phone numbers, "Get Outlook" lines, confidentiality notices, and image placeholders.
- Preserve David's wording; do not summarise or invent. files_referenced only lists files David actually mentions.
- Set has_david_answer false (and david_answer "") when a ticket has no reply from David.</cfoutput></cfsavecontent>

        <cfsavecontent variable="usr"><cfoutput>Thread subject: #subject#
From (developer): #devName#

--- EMAIL BODY (developer's questions with David's inline answers) ---
#original.body#
--- END ---</cfoutput></cfsavecontent>

        <cfset jsonBody = serializeJSON({
            "messages" = [
                { "role" = "system", "content" = sys },
                { "role" = "user",   "content" = usr }
            ],
            "max_completion_tokens" = javaCast("int", val(request.retrieval.maxAnswerTokens)),
            "response_format" = { "type" = "json_object" }
        })>

        <cfset chat = variables.oai.callChatCompletion(jsonBody = jsonBody, purpose = "email_segment")>
        <cfif NOT chat.success>
            <cfthrow message="Ticket segmentation chat call failed: #chat.errorMessage#">
        </cfif>

        <cftry>
            <cfset content = chat.parsed.choices[1].message.content>
            <cfset data = deserializeJSON(content)>
            <cfcatch type="any">
                <cfthrow message="Model did not return parseable JSON for ticket segmentation.">
            </cfcatch>
        </cftry>

        <cfif isStruct(data) AND structKeyExists(data, "tickets") AND isArray(data.tickets)>
            <cfloop array="#data.tickets#" index="t">
                <cfif NOT isStruct(t)><cfcontinue></cfif>
                <cfset files = []>
                <cfif structKeyExists(t, "files_referenced") AND isArray(t.files_referenced)>
                    <cfloop array="#t.files_referenced#" index="f">
                        <cfif len(trim(toString(f)))><cfset arrayAppend(files, trim(toString(f)))></cfif>
                    </cfloop>
                </cfif>
                <cfset arrayAppend(out.tickets, {
                    "ref"             = structKeyExists(t, "ref") ? trim(toString(t.ref)) : "",
                    "dev_question"    = structKeyExists(t, "dev_question") ? trim(toString(t.dev_question)) : "",
                    "david_answer"    = structKeyExists(t, "david_answer") ? trim(toString(t.david_answer)) : "",
                    "files_referenced" = files,
                    "has_david_answer" = structKeyExists(t, "has_david_answer") ? (t.has_david_answer ? true : false) : (structKeyExists(t, "david_answer") AND len(trim(toString(t.david_answer))) gt 0)
                })>
            </cfloop>
        </cfif>

        <cfreturn out>
    </cffunction>

    <!--- ====================================================================
          Chunk assembly + embedding
          ==================================================================== --->

    <!--- One self-describing chunk per ticket that carries David's guidance, so a
          retrieved chunk reads sensibly as context in the ask flow. Tickets with
          no David answer are dropped (they're just the dev's questions). --->
    <cffunction name="buildChunks" access="private" returntype="array" output="false">
        <cfargument name="parsed" type="struct" required="true">
        <cfargument name="seg"    type="struct" required="true">

        <cfset var chunks = []>
        <cfset var t = "">
        <cfset var idx = 0>
        <cfset var filesCsv = "">
        <cfset var text = "">

        <cfloop array="#arguments.seg.tickets#" index="t">
            <cfif NOT t.has_david_answer OR NOT len(t.david_answer)><cfcontinue></cfif>
            <cfset idx++>
            <cfset filesCsv = arrayToList(t.files_referenced, ", ")>

            <cfsavecontent variable="text"><cfoutput>EMAIL GUIDANCE — from David Roughan's reply
Thread: #arguments.seg.threadSubject#
Asked by: #arguments.seg.devName#
Ticket: #t.ref#

Question:
#t.dev_question#

David's guidance:
#t.david_answer#<cfif len(filesCsv)>

Files referenced: #filesCsv#</cfif></cfoutput></cfsavecontent>

            <cfset arrayAppend(chunks, {
                "index"    = idx,
                "ref"      = t.ref,
                "text"     = trim(text),
                "tokenEst" = ceiling(len(text) / 4)
            })>
        </cfloop>

        <cfreturn chunks>
    </cffunction>

    <cffunction name="embedAndStore" access="private" returntype="numeric" output="false">
        <cfargument name="repoId"  type="numeric" required="true">
        <cfargument name="fileId"  type="numeric" required="true">
        <cfargument name="relPath" type="string"  required="true">
        <cfargument name="chunks"  type="array"   required="true">

        <cfset var inputs = []>
        <cfset var c = "">
        <cfset var emb = "">
        <cfset var j = 0>

        <cfif NOT arrayLen(arguments.chunks)><cfreturn 0></cfif>

        <cfloop array="#arguments.chunks#" index="c">
            <cfset arrayAppend(inputs, c.text)>
        </cfloop>

        <cfset emb = variables.oai.callEmbeddingsBatch(inputs = inputs, purpose = "email_embedding")>
        <cfif NOT emb.success>
            <cfthrow message="Batch embedding failed for #arguments.relPath#: #emb.errorMessage#">
        </cfif>

        <cfloop from="1" to="#arrayLen(arguments.chunks)#" index="j">
            <cfset c = arguments.chunks[j]>
            <cfset variables.store.insertChunk(
                fileId         = arguments.fileId,
                repoId         = arguments.repoId,
                chunkIndex     = c.index,
                startLine      = c.index,
                endLine        = c.index,
                content        = c.text,
                tokenEstimate  = c.tokenEst,
                embedding      = emb.vectors[j],
                embeddingModel = request.openAI_embeddingModel
            )>
        </cfloop>

        <cfreturn arrayLen(arguments.chunks)>
    </cffunction>

    <cffunction name="insertFileRow" access="private" returntype="numeric" output="false">
        <cfargument name="repoId"    type="numeric" required="true">
        <cfargument name="relPath"   type="string"  required="true">
        <cfargument name="fileHash"  type="string"  required="true">
        <cfargument name="sizeBytes" type="numeric" required="true">

        <cfset var insertResult = "">
        <cfset var newId = 0>
        <cfquery attributeCollection="#request.queryAttributes#" result="insertResult">
            insert into code_files (repo_id, relative_path, file_hash, size_bytes, language, chunk_count)
            values (
                <cfqueryparam cfsqltype="cf_sql_integer"  value="#arguments.repoId#">,
                <cfqueryparam cfsqltype="cf_sql_nvarchar" value="#arguments.relPath#" maxlength="500">,
                <cfqueryparam cfsqltype="cf_sql_char"     value="#arguments.fileHash#" maxlength="64">,
                <cfqueryparam cfsqltype="cf_sql_integer"  value="#arguments.sizeBytes#">,
                <cfqueryparam cfsqltype="cf_sql_varchar"  value="email" maxlength="50">,
                0
            )
        </cfquery>
        <cfif isStruct(insertResult) AND structKeyExists(insertResult, "generatedKey")>
            <cfset newId = val(insertResult.generatedKey)>
        <cfelseif isStruct(insertResult) AND structKeyExists(insertResult, "GENERATED_KEY")>
            <cfset newId = val(insertResult["GENERATED_KEY"])>
        </cfif>
        <cfreturn newId>
    </cffunction>

</cfcomponent>
