<cfcomponent displayname="Ingestor" output="false"
    hint="Walks a repo's local filesystem path, chunks text files, embeds each chunk via Azure, and stores the vectors. Incremental: unchanged files (by SHA-256) are skipped.">

    <cffunction name="init" access="public" returntype="Ingestor" output="false">
        <cfset variables.oai    = createObject("component", "cfcs.AzureOpenAI")>
        <cfset variables.store  = createObject("component", "cfcs.VectorStore")>
        <cfreturn this>
    </cffunction>

    <!--- ====================================================================
          Repo management
          ==================================================================== --->

    <cffunction name="addRepo" access="public" returntype="numeric" output="false">
        <cfargument name="name"       type="string"  required="true">
        <cfargument name="localPath"  type="string"  required="true">
        <cfargument name="extensions" type="string"  required="false" default="">
        <cfargument name="maxFileKb"  type="numeric" required="false" default="0">
        <cfargument name="exclude"    type="string"  required="false" default="\.git\,\.claude\,\.svn\,\.vs\,\node_modules\,\bin\,\obj\,\min\,.min.js">

        <cfset var insertResult = "">
        <cfset var newId = 0>
        <cfset var ext = len(arguments.extensions) ? arguments.extensions : request.ingest.defaultExtensions>
        <cfset var mkb = arguments.maxFileKb gt 0 ? arguments.maxFileKb : request.ingest.maxFileKb>

        <cfquery attributeCollection="#request.queryAttributes#" result="insertResult">
            insert into repos (name, local_path, include_extensions, exclude_patterns, max_file_kb)
            values (
                <cfqueryparam cfsqltype="cf_sql_nvarchar" value="#arguments.name#"      maxlength="200">,
                <cfqueryparam cfsqltype="cf_sql_nvarchar" value="#arguments.localPath#" maxlength="500">,
                <cfqueryparam cfsqltype="cf_sql_nvarchar" value="#ext#"                 maxlength="500">,
                <cfqueryparam cfsqltype="cf_sql_nvarchar" value="#arguments.exclude#"   maxlength="1000" null="#(NOT len(arguments.exclude))#">,
                <cfqueryparam cfsqltype="cf_sql_integer"  value="#mkb#">
            )
        </cfquery>
        <cfif isStruct(insertResult) AND structKeyExists(insertResult, "generatedKey")>
            <cfset newId = val(insertResult.generatedKey)>
        <cfelseif isStruct(insertResult) AND structKeyExists(insertResult, "GENERATED_KEY")>
            <cfset newId = val(insertResult["GENERATED_KEY"])>
        </cfif>
        <cfreturn newId>
    </cffunction>

    <cffunction name="getRepos" access="public" returntype="query" output="false">
        <cfset var rows = "">
        <cfquery name="rows" attributeCollection="#request.queryAttributes#">
            select r.repo_id, r.name, r.local_path, r.include_extensions, r.exclude_patterns,
                   r.max_file_kb, r.enabled, r.last_indexed,
                   (select count(*) from code_files f where f.repo_id = r.repo_id and f.is_deleted = 0) as file_count,
                   (select count(*) from code_chunks c where c.repo_id = r.repo_id) as chunk_count
            from repos r
            order by r.name
        </cfquery>
        <cfreturn rows>
    </cffunction>

    <!--- Hard-delete all indexed data for a repo (chunks + file rows), keeping
          the repo row and its config. Use to start a repo's ingest from zero. --->
    <cffunction name="purgeRepo" access="public" returntype="struct" output="false">
        <cfargument name="repoId" type="numeric" required="true">
        <cfset var chunkResult = "">
        <cfset var fileResult = "">

        <!--- chunks first: code_chunks FKs code_files --->
        <cfquery attributeCollection="#request.queryAttributes#" result="chunkResult">
            delete from code_chunks
            where repo_id = <cfqueryparam cfsqltype="cf_sql_integer" value="#arguments.repoId#">
        </cfquery>
        <cfquery attributeCollection="#request.queryAttributes#" result="fileResult">
            delete from code_files
            where repo_id = <cfqueryparam cfsqltype="cf_sql_integer" value="#arguments.repoId#">
        </cfquery>
        <cfquery attributeCollection="#request.queryAttributes#">
            update repos set last_indexed = null
            where repo_id = <cfqueryparam cfsqltype="cf_sql_integer" value="#arguments.repoId#">
        </cfquery>

        <cfreturn {
            "chunksDeleted" = (isStruct(chunkResult) AND structKeyExists(chunkResult, "recordCount")) ? chunkResult.recordCount : 0,
            "filesDeleted"  = (isStruct(fileResult)  AND structKeyExists(fileResult,  "recordCount")) ? fileResult.recordCount  : 0
        }>
    </cffunction>

    <!--- Update a repo's exclude patterns (csv of path substrings to skip). --->
    <cffunction name="setExcludes" access="public" returntype="void" output="false">
        <cfargument name="repoId"   type="numeric" required="true">
        <cfargument name="patterns" type="string"  required="true">
        <cfquery attributeCollection="#request.queryAttributes#">
            update repos
            set exclude_patterns = <cfqueryparam cfsqltype="cf_sql_nvarchar" value="#trim(arguments.patterns)#" maxlength="1000" null="#(NOT len(trim(arguments.patterns)))#">
            where repo_id = <cfqueryparam cfsqltype="cf_sql_integer" value="#arguments.repoId#">
        </cfquery>
    </cffunction>

    <!--- ====================================================================
          Ingestion
          ==================================================================== --->

    <cffunction name="ingestRepo" access="public" returntype="struct" output="false">
        <cfargument name="repoId" type="numeric" required="true">

        <cfset var repo = "">
        <cfset var dirList = "">
        <cfset var fullPath = "">
        <cfset var relPath = "">
        <cfset var extOk = "">
        <cfset var allowedExt = "">
        <cfset var excludes = "">
        <cfset var maxBytes = 0>
        <cfset var content = "">
        <cfset var fileHash = "">
        <cfset var existing = "">
        <cfset var fileId = 0>
        <cfset var seenPaths = {}>
        <cfset var summary = {
            "repoId" = arguments.repoId, "scanned" = 0, "skipped" = 0,
            "changed" = 0, "newFiles" = 0, "chunksWritten" = 0,
            "deleted" = 0, "errors" = []
        }>
        <cfset var thisExt = "">
        <cfset var skipThis = false>
        <cfset var exItem = "">
        <cfset var currMtime = "">

        <!--- Load repo --->
        <cfquery name="repo" attributeCollection="#request.queryAttributes#">
            select repo_id, name, local_path, include_extensions, exclude_patterns, max_file_kb
            from repos
            where repo_id = <cfqueryparam cfsqltype="cf_sql_integer" value="#arguments.repoId#">
        </cfquery>
        <cfif repo.recordCount eq 0>
            <cfthrow message="Repo ##arguments.repoId## not found">
        </cfif>
        <cfif NOT directoryExists(repo.local_path)>
            <cfthrow message="Repo path does not exist on disk: #repo.local_path#">
        </cfif>

        <cfset allowedExt = repo.include_extensions>
        <cfset excludes    = len(repo.exclude_patterns) ? repo.exclude_patterns : "">
        <cfset maxBytes    = val(repo.max_file_kb) * 1024>

        <!--- Walk the tree --->
        <cfdirectory action="list" directory="#repo.local_path#" recurse="true"
                     type="file" name="dirList">

        <cfloop query="dirList">
            <cfset fullPath = dirList.directory & "\" & dirList.name>

            <!--- extension filter --->
            <cfset thisExt = lcase(listLast(dirList.name, "."))>
            <cfif NOT listFindNoCase(allowedExt, thisExt)>
                <cfcontinue>
            </cfif>

            <!--- size filter --->
            <cfif maxBytes gt 0 AND dirList.size gt maxBytes>
                <cfcontinue>
            </cfif>

            <!--- exclude-substring filter --->
            <cfset skipThis = false>
            <cfloop list="#excludes#" index="exItem">
                <cfif len(trim(exItem)) AND findNoCase(trim(exItem), fullPath)>
                    <cfset skipThis = true>
                    <cfbreak>
                </cfif>
            </cfloop>
            <cfif skipThis><cfcontinue></cfif>

            <cfset relPath = relativePath(repo.local_path, fullPath)>
            <cfset seenPaths[lcase(relPath)] = true>
            <cfset summary.scanned++>

            <cfset fileId = 0>
            <cftry>
                <cfset currMtime = mtimeToken(dirList.dateLastModified)>

                <!--- existing file row + its change-detection metadata --->
                <cfquery name="existing" attributeCollection="#request.queryAttributes#">
                    select file_id, file_hash, size_bytes, last_modified, is_deleted
                    from code_files
                    where repo_id = <cfqueryparam cfsqltype="cf_sql_integer" value="#repo.repo_id#">
                      and relative_path = <cfqueryparam cfsqltype="cf_sql_nvarchar" value="#relPath#" maxlength="500">
                </cfquery>

                <!--- FAST PATH: on-disk size AND last-modified both match what we
                      stored, so the content cannot have changed - skip the file
                      without reading or hashing it. --->
                <cfif existing.recordCount AND existing.is_deleted eq 0
                      AND existing.size_bytes eq dirList.size
                      AND len(existing.last_modified) AND existing.last_modified eq currMtime>
                    <cfset summary.skipped++>
                    <cfcontinue>
                </cfif>

                <!--- Size or mtime differs (or the file was never indexed) - read
                      and hash to find out whether the content really changed. --->
                <cffile action="read" file="#fullPath#" variable="content" charset="utf-8">
                <cfset fileHash = lcase(hash(content, "SHA-256"))>

                <cfif existing.recordCount AND existing.is_deleted eq 0 AND existing.file_hash eq fileHash>
                    <!--- Content identical, only the stamp drifted (e.g. file
                          touched, or a row migrated without a stamp). Refresh
                          size/mtime so the next run fast-skips - no re-embed. --->
                    <cfquery attributeCollection="#request.queryAttributes#">
                        update code_files
                        set size_bytes = <cfqueryparam cfsqltype="cf_sql_integer" value="#dirList.size#">,
                            last_modified = <cfqueryparam cfsqltype="cf_sql_varchar" value="#currMtime#" maxlength="20">,
                            indexed_at = getDate()
                        where file_id = <cfqueryparam cfsqltype="cf_sql_integer" value="#existing.file_id#">
                    </cfquery>
                    <cfset summary.skipped++>
                    <cfcontinue>
                </cfif>

                <!--- New, or genuinely changed - upsert and re-embed. --->
                <cfif existing.recordCount>
                    <cfset fileId = existing.file_id>
                    <cfset summary.changed++>
                    <cfquery attributeCollection="#request.queryAttributes#">
                        update code_files
                        set file_hash = <cfqueryparam cfsqltype="cf_sql_char" value="#fileHash#" maxlength="64">,
                            size_bytes = <cfqueryparam cfsqltype="cf_sql_integer" value="#dirList.size#">,
                            language = <cfqueryparam cfsqltype="cf_sql_varchar" value="#thisExt#" maxlength="50">,
                            last_modified = <cfqueryparam cfsqltype="cf_sql_varchar" value="#currMtime#" maxlength="20">,
                            is_deleted = 0,
                            indexed_at = getDate()
                        where file_id = <cfqueryparam cfsqltype="cf_sql_integer" value="#fileId#">
                    </cfquery>
                    <cfset variables.store.deleteChunksForFile(fileId)>
                <cfelse>
                    <cfset summary.newFiles++>
                    <cfset fileId = insertFileRow(repo.repo_id, relPath, fileHash, dirList.size, thisExt, currMtime)>
                </cfif>

                <!--- chunk + embed --->
                <cfset summary.chunksWritten += embedFileChunks(repo.repo_id, fileId, relPath, content)>

            <cfcatch type="any">
                <cfset arrayAppend(summary.errors, relPath & " :: " & cfcatch.message)>
                <!--- A failed file may be half-chunked but hash-marked, which
                      would skip it forever. Blank its hash so it retries next run. --->
                <cfif fileId gt 0>
                    <cftry>
                        <cfquery attributeCollection="#request.queryAttributes#">
                            update code_files set file_hash = ''
                            where file_id = <cfqueryparam cfsqltype="cf_sql_integer" value="#fileId#">
                        </cfquery>
                        <cfcatch type="any"></cfcatch>
                    </cftry>
                </cfif>
            </cfcatch>
            </cftry>
        </cfloop>

        <!--- mark files that vanished from disk --->
        <cfset summary.deleted = markMissingFiles(repo.repo_id, seenPaths)>

        <!--- stamp last_indexed --->
        <cfquery attributeCollection="#request.queryAttributes#">
            update repos set last_indexed = getDate()
            where repo_id = <cfqueryparam cfsqltype="cf_sql_integer" value="#repo.repo_id#">
        </cfquery>

        <cfreturn summary>
    </cffunction>

    <!--- ====================================================================
          Helpers
          ==================================================================== --->

    <cffunction name="insertFileRow" access="private" returntype="numeric" output="false">
        <cfargument name="repoId"   type="numeric" required="true">
        <cfargument name="relPath"  type="string"  required="true">
        <cfargument name="fileHash" type="string"  required="true">
        <cfargument name="sizeBytes" type="numeric" required="true">
        <cfargument name="language" type="string"  required="true">
        <cfargument name="lastModified" type="string" required="false" default="">

        <cfset var insertResult = "">
        <cfset var newId = 0>
        <cfquery attributeCollection="#request.queryAttributes#" result="insertResult">
            insert into code_files (repo_id, relative_path, file_hash, size_bytes, language, last_modified, chunk_count)
            values (
                <cfqueryparam cfsqltype="cf_sql_integer"  value="#arguments.repoId#">,
                <cfqueryparam cfsqltype="cf_sql_nvarchar" value="#arguments.relPath#" maxlength="500">,
                <cfqueryparam cfsqltype="cf_sql_char"     value="#arguments.fileHash#" maxlength="64">,
                <cfqueryparam cfsqltype="cf_sql_integer"  value="#arguments.sizeBytes#">,
                <cfqueryparam cfsqltype="cf_sql_varchar"  value="#arguments.language#" maxlength="50">,
                <cfqueryparam cfsqltype="cf_sql_varchar"  value="#arguments.lastModified#" maxlength="20" null="#(NOT len(arguments.lastModified))#">,
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

    <!--- A sortable, exact-comparison stamp from a file's last-modified date.
          Stored as a string (not DATETIME) to dodge sub-second rounding drift,
          so the equality check in the fast path is reliable. --->
    <cffunction name="mtimeToken" access="private" returntype="string" output="false">
        <cfargument name="d" type="any" required="true">
        <cfreturn dateFormat(arguments.d, "yyyymmdd") & timeFormat(arguments.d, "HHmmss")>
    </cffunction>

    <!--- Split content into line-based chunks, embed them in batches, store.
          Returns the number of chunks written. Embedding is batched (one HTTP
          call per ~embedBatchSize chunks / embedBatchTokens) rather than one
          call per chunk - the single biggest throughput win on a large repo and
          what keeps Azure from 429-throttling the run to death. --->
    <cffunction name="embedFileChunks" access="private" returntype="numeric" output="false">
        <cfargument name="repoId"  type="numeric" required="true">
        <cfargument name="fileId"  type="numeric" required="true">
        <cfargument name="relPath" type="string"  required="true">
        <cfargument name="content" type="string"  required="true">

        <cfset var lines = "">
        <cfset var totalLines = 0>
        <cfset var chunkLines = val(request.ingest.chunkLines)>
        <cfset var overlap = val(request.ingest.chunkOverlap)>
        <cfset var maxChars = val(request.ingest.maxChunkChars)>
        <cfset var step = max(1, chunkLines - overlap)>
        <cfset var batchSize = max(1, val(request.ingest.embedBatchSize))>
        <cfset var batchTokens = max(1, val(request.ingest.embedBatchTokens))>
        <cfset var startIdx = 1>
        <cfset var endIdx = 0>
        <cfset var chunkIndex = 0>
        <cfset var i = 0>
        <cfset var chunkText = "">
        <cfset var slice = "">
        <cfset var chunks = []>
        <cfset var ch = "">
        <cfset var batch = []>
        <cfset var batchTok = 0>
        <cfset var written = 0>

        <!--- normalise line endings then split keeping blank lines --->
        <cfset lines = listToArray(replace(arguments.content, chr(13), "", "all"), chr(10), true)>
        <cfset totalLines = arrayLen(lines)>
        <cfif totalLines eq 0><cfreturn 0></cfif>

        <!--- 1. build the full chunk list for this file (no embedding yet) --->
        <cfloop condition="startIdx lte totalLines">
            <cfset endIdx = min(startIdx + chunkLines - 1, totalLines)>

            <cfset slice = []>
            <cfloop from="#startIdx#" to="#endIdx#" index="i">
                <cfset arrayAppend(slice, lines[i])>
            </cfloop>
            <cfset chunkText = arrayToList(slice, chr(10))>

            <cfif maxChars gt 0 AND len(chunkText) gt maxChars>
                <cfset chunkText = left(chunkText, maxChars)>
            </cfif>

            <cfif len(trim(chunkText))>
                <cfset chunkIndex++>
                <!--- embedInput prepends path + lines so filename queries retrieve too --->
                <cfset arrayAppend(chunks, {
                    "chunkIndex" = chunkIndex,
                    "startLine"  = startIdx,
                    "endLine"    = endIdx,
                    "text"       = chunkText,
                    "embedInput" = "File: " & arguments.relPath & " (lines " & startIdx & "-" & endIdx & ")" & chr(10) & chunkText,
                    "tokenEst"   = ceiling(len(chunkText) / 4)
                })>
            </cfif>

            <cfif endIdx eq totalLines><cfbreak></cfif>
            <cfset startIdx += step>
        </cfloop>

        <!--- 2. embed + store in batches bounded by item count OR token budget --->
        <cfset batch = []>
        <cfset batchTok = 0>
        <cfloop array="#chunks#" index="ch">
            <cfif arrayLen(batch)
                  AND (arrayLen(batch) ge batchSize OR (batchTok + ch.tokenEst) gt batchTokens)>
                <cfset written += flushEmbedBatch(arguments.repoId, arguments.fileId, arguments.relPath, batch)>
                <cfset batch = []>
                <cfset batchTok = 0>
            </cfif>
            <cfset arrayAppend(batch, ch)>
            <cfset batchTok += ch.tokenEst>
        </cfloop>
        <cfif arrayLen(batch)>
            <cfset written += flushEmbedBatch(arguments.repoId, arguments.fileId, arguments.relPath, batch)>
        </cfif>

        <!--- record chunk count on the file --->
        <cfquery attributeCollection="#request.queryAttributes#">
            update code_files set chunk_count = <cfqueryparam cfsqltype="cf_sql_integer" value="#written#">
            where file_id = <cfqueryparam cfsqltype="cf_sql_integer" value="#arguments.fileId#">
        </cfquery>

        <cfreturn written>
    </cffunction>

    <!--- Embed one batch of chunk structs in a single Azure call and store each.
          Throws on failure so the caller's per-file catch blanks the hash and the
          file is retried next run (rather than left silently half-indexed). --->
    <cffunction name="flushEmbedBatch" access="private" returntype="numeric" output="false">
        <cfargument name="repoId"  type="numeric" required="true">
        <cfargument name="fileId"  type="numeric" required="true">
        <cfargument name="relPath" type="string"  required="true">
        <cfargument name="batch"   type="array"   required="true">

        <cfset var inputs = []>
        <cfset var emb = "">
        <cfset var c = "">
        <cfset var j = 0>

        <cfif NOT arrayLen(arguments.batch)><cfreturn 0></cfif>

        <cfloop array="#arguments.batch#" index="c">
            <cfset arrayAppend(inputs, c.embedInput)>
        </cfloop>

        <cfset emb = variables.oai.callEmbeddingsBatch(inputs = inputs, purpose = "ingest_embedding")>
        <cfif NOT emb.success>
            <cfthrow message="Batch embedding failed for #arguments.relPath# (#arrayLen(inputs)# chunk(s)): #emb.errorMessage#">
        </cfif>

        <cfloop from="1" to="#arrayLen(arguments.batch)#" index="j">
            <cfset c = arguments.batch[j]>
            <cfset variables.store.insertChunk(
                fileId         = arguments.fileId,
                repoId         = arguments.repoId,
                chunkIndex     = c.chunkIndex,
                startLine      = c.startLine,
                endLine        = c.endLine,
                content        = c.text,
                tokenEstimate  = c.tokenEst,
                embedding      = emb.vectors[j],
                embeddingModel = request.openAI_embeddingModel
            )>
        </cfloop>

        <cfreturn arrayLen(arguments.batch)>
    </cffunction>

    <!--- Mark DB files not seen on disk this run as deleted, and drop their chunks. --->
    <cffunction name="markMissingFiles" access="private" returntype="numeric" output="false">
        <cfargument name="repoId"    type="numeric" required="true">
        <cfargument name="seenPaths" type="struct"  required="true">

        <cfset var rows = "">
        <cfset var removed = 0>
        <cfquery name="rows" attributeCollection="#request.queryAttributes#">
            select file_id, relative_path
            from code_files
            where repo_id = <cfqueryparam cfsqltype="cf_sql_integer" value="#arguments.repoId#">
              and is_deleted = 0
        </cfquery>
        <cfloop query="rows">
            <cfif NOT structKeyExists(arguments.seenPaths, lcase(rows.relative_path))>
                <cfset variables.store.deleteChunksForFile(rows.file_id)>
                <cfquery attributeCollection="#request.queryAttributes#">
                    update code_files set is_deleted = 1, chunk_count = 0
                    where file_id = <cfqueryparam cfsqltype="cf_sql_integer" value="#rows.file_id#">
                </cfquery>
                <cfset removed++>
            </cfif>
        </cfloop>
        <cfreturn removed>
    </cffunction>

    <!--- Compute a repo-relative path from an absolute path. --->
    <cffunction name="relativePath" access="private" returntype="string" output="false">
        <cfargument name="base" type="string" required="true">
        <cfargument name="full" type="string" required="true">
        <cfset var b = arguments.base>
        <cfset var rel = "">
        <cfif right(b, 1) neq "\" AND right(b, 1) neq "/">
            <cfset b = b & "\">
        </cfif>
        <cfset rel = replaceNoCase(arguments.full, b, "", "one")>
        <cfreturn replace(rel, "\", "/", "all")>
    </cffunction>

</cfcomponent>
