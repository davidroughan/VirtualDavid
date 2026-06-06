<cfcomponent displayname="VectorStore" output="false"
    hint="Stores code chunk embeddings in a SQL Server 2025 native VECTOR column and runs similarity search in-database via VECTOR_DISTANCE. No vectors are held in ColdFusion memory.">

    <!--- Dimension of the embedding model (text-embedding-3-small = 1536). --->
    <cfset variables.dims = 1536>

    <!--- ====================================================================
          Persistence
          ==================================================================== --->

    <!--- Insert one chunk. The embedding (a CF array of floats) is serialised to
          a JSON array and CAST to VECTOR in SQL. No client-side normalisation is
          needed - VECTOR_DISTANCE('cosine', ...) is scale-invariant. --->
    <cffunction name="insertChunk" access="public" returntype="numeric" output="false">
        <cfargument name="fileId"         type="numeric" required="true">
        <cfargument name="repoId"         type="numeric" required="true">
        <cfargument name="chunkIndex"     type="numeric" required="true">
        <cfargument name="startLine"      type="numeric" required="true">
        <cfargument name="endLine"        type="numeric" required="true">
        <cfargument name="content"        type="string"  required="true">
        <cfargument name="tokenEstimate"  type="numeric" required="true">
        <cfargument name="embedding"      type="array"   required="true">
        <cfargument name="embeddingModel" type="string"  required="true">

        <cfset var insertResult = "">
        <cfset var newId = 0>
        <cfset var jsonVec = serializeJSON(arguments.embedding)>

        <cfquery attributeCollection="#request.queryAttributes#" result="insertResult">
            insert into code_chunks
                (file_id, repo_id, chunk_index, start_line, end_line, content,
                 token_estimate, embedding_vec, embedding_model, embedding_dims)
            values (
                <cfqueryparam cfsqltype="cf_sql_integer"  value="#arguments.fileId#">,
                <cfqueryparam cfsqltype="cf_sql_integer"  value="#arguments.repoId#">,
                <cfqueryparam cfsqltype="cf_sql_integer"  value="#arguments.chunkIndex#">,
                <cfqueryparam cfsqltype="cf_sql_integer"  value="#arguments.startLine#">,
                <cfqueryparam cfsqltype="cf_sql_integer"  value="#arguments.endLine#">,
                <cfqueryparam cfsqltype="cf_sql_longvarchar" value="#arguments.content#">,
                <cfqueryparam cfsqltype="cf_sql_integer"  value="#arguments.tokenEstimate#">,
                CAST(<cfqueryparam cfsqltype="cf_sql_longvarchar" value="#jsonVec#"> AS VECTOR(#variables.dims#)),
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
          Search (in-database)
          ==================================================================== --->

    <!--- Cosine similarity search via SQL Server's VECTOR_DISTANCE. Returns the
          top-K chunks with file path, line range, content and a similarity score
          (1 = identical), highest first. The query embedding is passed as a JSON
          array and cast to VECTOR server-side. --->
    <cffunction name="cosineSearch" access="public" returntype="query" output="false">
        <cfargument name="queryVector" type="array"   required="true">
        <cfargument name="topK"        type="numeric" required="false" default="8">
        <cfargument name="repoFilter"  type="string"  required="false" default=""><!--- csv of repo_id, blank = all --->

        <cfset var rows = "">
        <cfset var qjson = serializeJSON(arguments.queryVector)>

        <cfquery name="rows" attributeCollection="#request.queryAttributes#">
            select top (<cfqueryparam cfsqltype="cf_sql_integer" value="#val(arguments.topK)#">)
                   c.chunk_id, c.repo_id, r.name as repo_name, f.relative_path,
                   c.start_line, c.end_line, c.content,
                   1 - VECTOR_DISTANCE('cosine', c.embedding_vec,
                         CAST(<cfqueryparam cfsqltype="cf_sql_longvarchar" value="#qjson#"> AS VECTOR(#variables.dims#))) as score
            from code_chunks c
            inner join code_files f on f.file_id = c.file_id
            inner join repos r      on r.repo_id = c.repo_id
            where c.embedding_vec is not null
              and f.is_deleted = 0
              and r.enabled = 1
              <cfif len(trim(arguments.repoFilter))>
                  and c.repo_id in (<cfqueryparam cfsqltype="cf_sql_integer" value="#arguments.repoFilter#" list="true">)
              </cfif>
            order by score desc
        </cfquery>

        <cfreturn rows>
    </cffunction>

</cfcomponent>
