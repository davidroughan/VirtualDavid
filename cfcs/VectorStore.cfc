<cfcomponent displayname="VectorStore" output="false"
    hint="Stores code chunk embeddings (normalised JSON) and does cosine similarity search in ColdFusion using an application-scoped in-memory index.">

    <!--- ====================================================================
          Vector maths
          ==================================================================== --->

    <!--- L2-normalise an array of numbers. Returns a new array; a zero vector
          is returned unchanged so we never divide by zero. --->
    <cffunction name="normalise" access="public" returntype="array" output="false">
        <cfargument name="vec" type="array" required="true">
        <cfset var i = 0>
        <cfset var n = arrayLen(arguments.vec)>
        <cfset var sumSq = 0>
        <cfset var mag = 0>
        <cfset var out = []>
        <cfloop from="1" to="#n#" index="i">
            <cfset sumSq += (arguments.vec[i] * arguments.vec[i])>
        </cfloop>
        <cfset mag = sqr(sumSq)>
        <cfif mag eq 0>
            <cfreturn arguments.vec>
        </cfif>
        <cfloop from="1" to="#n#" index="i">
            <cfset arrayAppend(out, arguments.vec[i] / mag)>
        </cfloop>
        <cfreturn out>
    </cffunction>

    <!--- Dot product of two equal-length arrays. With normalised inputs this
          equals cosine similarity. --->
    <cffunction name="dot" access="public" returntype="numeric" output="false">
        <cfargument name="a" type="array" required="true">
        <cfargument name="b" type="array" required="true">
        <cfset var i = 0>
        <cfset var n = min(arrayLen(arguments.a), arrayLen(arguments.b))>
        <cfset var s = 0>
        <cfloop from="1" to="#n#" index="i">
            <cfset s += (arguments.a[i] * arguments.b[i])>
        </cfloop>
        <cfreturn s>
    </cffunction>

    <!--- ====================================================================
          Persistence
          ==================================================================== --->

    <!--- Insert one chunk with its normalised embedding stored as JSON. --->
    <cffunction name="insertChunk" access="public" returntype="numeric" output="false">
        <cfargument name="fileId"         type="numeric" required="true">
        <cfargument name="repoId"         type="numeric" required="true">
        <cfargument name="chunkIndex"     type="numeric" required="true">
        <cfargument name="startLine"      type="numeric" required="true">
        <cfargument name="endLine"        type="numeric" required="true">
        <cfargument name="content"        type="string"  required="true">
        <cfargument name="tokenEstimate"  type="numeric" required="true">
        <cfargument name="embedding"      type="array"   required="true"><!--- already normalised --->
        <cfargument name="embeddingModel" type="string"  required="true">

        <cfset var insertResult = "">
        <cfset var newId = 0>
        <cfset var jsonVec = serializeJSON(arguments.embedding)>

        <cfquery attributeCollection="#request.queryAttributes#" result="insertResult">
            insert into code_chunks
                (file_id, repo_id, chunk_index, start_line, end_line, content,
                 token_estimate, embedding, embedding_model, embedding_dims)
            values (
                <cfqueryparam cfsqltype="cf_sql_integer"  value="#arguments.fileId#">,
                <cfqueryparam cfsqltype="cf_sql_integer"  value="#arguments.repoId#">,
                <cfqueryparam cfsqltype="cf_sql_integer"  value="#arguments.chunkIndex#">,
                <cfqueryparam cfsqltype="cf_sql_integer"  value="#arguments.startLine#">,
                <cfqueryparam cfsqltype="cf_sql_integer"  value="#arguments.endLine#">,
                <cfqueryparam cfsqltype="cf_sql_longvarchar" value="#arguments.content#">,
                <cfqueryparam cfsqltype="cf_sql_integer"  value="#arguments.tokenEstimate#">,
                <cfqueryparam cfsqltype="cf_sql_longvarchar" value="#jsonVec#">,
                <cfqueryparam cfsqltype="cf_sql_varchar"  value="#arguments.embeddingModel#" maxlength="100">,
                <cfqueryparam cfsqltype="cf_sql_integer"  value="#arrayLen(arguments.embedding)#">
            )
        </cfquery>

        <cfif isStruct(insertResult) AND structKeyExists(insertResult, "generatedKey")>
            <cfset newId = val(insertResult.generatedKey)>
        <cfelseif isStruct(insertResult) AND structKeyExists(insertResult, "GENERATED_KEY")>
            <cfset newId = val(insertResult["GENERATED_KEY"])>
        </cfif>
        <cfreturn newId>
    </cffunction>

    <!--- Remove all chunks for a file (used before re-chunking a changed file). --->
    <cffunction name="deleteChunksForFile" access="public" returntype="void" output="false">
        <cfargument name="fileId" type="numeric" required="true">
        <cfquery attributeCollection="#request.queryAttributes#">
            delete from code_chunks
            where file_id = <cfqueryparam cfsqltype="cf_sql_integer" value="#arguments.fileId#">
        </cfquery>
    </cffunction>

    <!--- ====================================================================
          In-memory index + search
          ==================================================================== --->

    <!--- Load every embedded chunk's id + repo + normalised vector into the
          application scope. Called after ingestion, or lazily on first search. --->
    <cffunction name="rebuildIndexCache" access="public" returntype="struct" output="false">
        <cfset var rows = "">
        <cfset var items = []>
        <cfset var vec = "">

        <cfquery name="rows" attributeCollection="#request.queryAttributes#">
            select c.chunk_id, c.repo_id, c.embedding
            from code_chunks c
            inner join code_files f on f.file_id = c.file_id
            inner join repos r      on r.repo_id = c.repo_id
            where c.embedding is not null
              and f.is_deleted = 0
              and r.enabled = 1
        </cfquery>

        <cfloop query="rows">
            <cftry>
                <cfset vec = deserializeJSON(rows.embedding)>
                <cfif isArray(vec) AND arrayLen(vec)>
                    <cfset arrayAppend(items, { "chunk_id" = rows.chunk_id, "repo_id" = rows.repo_id, "vec" = vec })>
                </cfif>
                <cfcatch type="any"></cfcatch>
            </cftry>
        </cfloop>

        <cflock scope="application" type="exclusive" timeout="30">
            <cfset application.vdIndex = {
                "builtAt" = now(),
                "count"   = arrayLen(items),
                "items"   = items
            }>
        </cflock>

        <cfreturn { "count" = arrayLen(items) }>
    </cffunction>

    <!--- Ensure the cache exists; build it if missing. --->
    <cffunction name="ensureIndex" access="private" returntype="void" output="false">
        <cfset var have = false>
        <cflock scope="application" type="readonly" timeout="30">
            <cfset have = structKeyExists(application, "vdIndex")>
        </cflock>
        <cfif NOT have>
            <cfset rebuildIndexCache()>
        </cfif>
    </cffunction>

    <!--- Cosine search. Returns a query of the top-K chunks with file path,
          line range, content and similarity score, highest first. --->
    <cffunction name="cosineSearch" access="public" returntype="query" output="false">
        <cfargument name="queryVector" type="array"   required="true">
        <cfargument name="topK"        type="numeric" required="false" default="8">
        <cfargument name="repoFilter"  type="string"  required="false" default=""><!--- csv of repo_id, blank = all --->

        <cfset var qv = normalise(arguments.queryVector)>
        <cfset var items = []>
        <cfset var i = 0>
        <cfset var n = 0>
        <cfset var score = 0>
        <cfset var scored = []>
        <cfset var repoSet = "">
        <cfset var idList = "">
        <cfset var idScore = {}>

        <cfset ensureIndex()>

        <cflock scope="application" type="readonly" timeout="30">
            <cfset items = application.vdIndex.items>
        </cflock>

        <cfif len(trim(arguments.repoFilter))>
            <cfset repoSet = arguments.repoFilter>
        </cfif>

        <!--- Score every cached vector against the query vector --->
        <cfset n = arrayLen(items)>
        <cfloop from="1" to="#n#" index="i">
            <cfif len(repoSet) AND NOT listFind(repoSet, items[i].repo_id)>
                <cfcontinue>
            </cfif>
            <cfset score = dot(qv, items[i].vec)>
            <cfset arrayAppend(scored, { "chunk_id" = items[i].chunk_id, "repo_id" = items[i].repo_id, "score" = score })>
        </cfloop>

        <!--- Sort by score desc and keep top-K --->
        <cfset arraySort(scored, function(a, b){
            return (b.score gt a.score) ? 1 : ((b.score lt a.score) ? -1 : 0);
        })>

        <cfset n = min(arguments.topK, arrayLen(scored))>
        <cfif n eq 0>
            <cfreturn loadChunkDetails("", {})>
        </cfif>
        <cfloop from="1" to="#n#" index="i">
            <cfset idList = listAppend(idList, scored[i].chunk_id)>
            <cfset idScore[scored[i].chunk_id] = scored[i].score>
        </cfloop>

        <cfreturn loadChunkDetails(idList, idScore)>
    </cffunction>

    <!--- Fetch full chunk + file detail for a csv of chunk ids, attaching the
          score we computed and ordering by score desc. --->
    <cffunction name="loadChunkDetails" access="private" returntype="query" output="false">
        <cfargument name="idList"  type="string" required="true">
        <cfargument name="idScore" type="struct" required="true">

        <cfset var rows = "">
        <cfset var out = queryNew(
            "chunk_id,repo_id,repo_name,relative_path,start_line,end_line,content,score",
            "integer,integer,varchar,varchar,integer,integer,varchar,double")>
        <cfset var ranked = []>
        <cfset var i = 0>

        <cfif NOT len(arguments.idList)>
            <cfreturn out>
        </cfif>

        <cfquery name="rows" attributeCollection="#request.queryAttributes#">
            select c.chunk_id, c.repo_id, r.name as repo_name, f.relative_path,
                   c.start_line, c.end_line, c.content
            from code_chunks c
            inner join code_files f on f.file_id = c.file_id
            inner join repos r      on r.repo_id = c.repo_id
            where c.chunk_id in (<cfqueryparam cfsqltype="cf_sql_integer" value="#arguments.idList#" list="true">)
        </cfquery>

        <!--- Build an array we can sort by the precomputed score --->
        <cfloop query="rows">
            <cfset arrayAppend(ranked, {
                "chunk_id"      = rows.chunk_id,
                "repo_id"       = rows.repo_id,
                "repo_name"     = rows.repo_name,
                "relative_path" = rows.relative_path,
                "start_line"    = rows.start_line,
                "end_line"      = rows.end_line,
                "content"       = rows.content,
                "score"         = structKeyExists(arguments.idScore, rows.chunk_id) ? arguments.idScore[rows.chunk_id] : 0
            })>
        </cfloop>

        <cfset arraySort(ranked, function(a, b){
            return (b.score gt a.score) ? 1 : ((b.score lt a.score) ? -1 : 0);
        })>

        <cfloop from="1" to="#arrayLen(ranked)#" index="i">
            <cfset queryAddRow(out)>
            <cfset querySetCell(out, "chunk_id",      ranked[i].chunk_id)>
            <cfset querySetCell(out, "repo_id",       ranked[i].repo_id)>
            <cfset querySetCell(out, "repo_name",     ranked[i].repo_name)>
            <cfset querySetCell(out, "relative_path", ranked[i].relative_path)>
            <cfset querySetCell(out, "start_line",    ranked[i].start_line)>
            <cfset querySetCell(out, "end_line",      ranked[i].end_line)>
            <cfset querySetCell(out, "content",       ranked[i].content)>
            <cfset querySetCell(out, "score",         ranked[i].score)>
        </cfloop>

        <cfreturn out>
    </cffunction>

</cfcomponent>
