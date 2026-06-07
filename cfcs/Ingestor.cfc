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
        <cfargument name="exclude"    type="string"  required="false" default="\.git\,\.claude\,\.svn\,\.vs\,\node_modules\,\bin\,\obj\,\min\,.min.js,\fontawesome,\svgs\">

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

    <!--- Delete a repo entirely: its chunks, file rows, run history AND the repo
          row itself. Children deleted first to satisfy the foreign keys. --->
    <cffunction name="deleteRepo" access="public" returntype="struct" output="false">
        <cfargument name="repoId" type="numeric" required="true">
        <cfset var r = "">
        <cfquery attributeCollection="#request.queryAttributes#">
            delete from code_chunks where repo_id = <cfqueryparam cfsqltype="cf_sql_integer" value="#arguments.repoId#">
        </cfquery>
        <cfquery attributeCollection="#request.queryAttributes#">
            delete from code_files where repo_id = <cfqueryparam cfsqltype="cf_sql_integer" value="#arguments.repoId#">
        </cfquery>
        <cfquery attributeCollection="#request.queryAttributes#">
            delete from ingest_runs where repo_id = <cfqueryparam cfsqltype="cf_sql_integer" value="#arguments.repoId#">
        </cfquery>
        <cfquery attributeCollection="#request.queryAttributes#" result="r">
            delete from repos where repo_id = <cfqueryparam cfsqltype="cf_sql_integer" value="#arguments.repoId#">
        </cfquery>
        <!--- drop any leftover live status for this repo --->
        <cflock name="vdIngestInit" type="exclusive" timeout="10">
            <cfif structKeyExists(application, "vdIngest") AND structKeyExists(application.vdIngest, arguments.repoId)>
                <cfset structDelete(application.vdIngest, arguments.repoId)>
            </cfif>
        </cflock>
        <cfreturn { "deleted" = (isStruct(r) AND structKeyExists(r, "recordCount")) ? r.recordCount : 0 }>
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
          Run tracking & control

          Live status lives in application.vdIngest[repoId] (fast, polled by the
          admin page); each run is also recorded in the ingest_runs table so the
          history survives a timeout or a CF restart. A single ingest writes its
          own job struct; the stop flag is the one field another request writes.
          ==================================================================== --->

    <cffunction name="initRun" access="private" returntype="numeric" output="false">
        <cfargument name="repoId" type="numeric" required="true">
        <cfset var ins = "">
        <cfset var runId = 0>
        <cfquery attributeCollection="#request.queryAttributes#" result="ins">
            insert into ingest_runs (repo_id, status, started_at, heartbeat_at)
            values (<cfqueryparam cfsqltype="cf_sql_integer" value="#arguments.repoId#">, 'running', getDate(), getDate())
        </cfquery>
        <cfif isStruct(ins) AND structKeyExists(ins, "generatedKey")>
            <cfset runId = val(ins.generatedKey)>
        <cfelseif isStruct(ins) AND structKeyExists(ins, "GENERATED_KEY")>
            <cfset runId = val(ins["GENERATED_KEY"])>
        </cfif>
        <cflock name="vdIngestInit" type="exclusive" timeout="10">
            <cfif NOT structKeyExists(application, "vdIngest")>
                <cfset application.vdIngest = {}>
            </cfif>
            <cfset application.vdIngest[arguments.repoId] = {
                "runId" = runId, "status" = "running", "stop" = false,
                "startedTick" = getTickCount(), "startedAt" = now(), "heartbeat" = now(),
                "scanned" = 0, "newFiles" = 0, "changed" = 0, "skipped" = 0,
                "deleted" = 0, "chunksWritten" = 0, "errorCount" = 0,
                "currentFile" = "", "message" = ""
            }>
        </cflock>
        <cfreturn runId>
    </cffunction>

    <!--- The live job struct for a repo, or an empty struct if none. --->
    <cffunction name="jobRef" access="private" returntype="struct" output="false">
        <cfargument name="repoId" type="numeric" required="true">
        <cfif structKeyExists(application, "vdIngest") AND structKeyExists(application.vdIngest, arguments.repoId)>
            <cfreturn application.vdIngest[arguments.repoId]>
        </cfif>
        <cfreturn {}>
    </cffunction>

    <!--- Cheap unlocked read of the stop flag (eventual consistency is fine). --->
    <cffunction name="stopFlag" access="private" returntype="boolean" output="false">
        <cfargument name="repoId" type="numeric" required="true">
        <cfif structKeyExists(application, "vdIngest")
              AND structKeyExists(application.vdIngest, arguments.repoId)
              AND application.vdIngest[arguments.repoId].stop>
            <cfreturn true>
        </cfif>
        <cfreturn false>
    </cffunction>

    <!--- Mirror cumulative counters + current file + heartbeat into the job. --->
    <cffunction name="touchJob" access="private" returntype="void" output="false">
        <cfargument name="repoId"      type="numeric" required="true">
        <cfargument name="summary"     type="struct"  required="true">
        <cfargument name="currentFile" type="string"  required="false" default="">
        <cfset var j = jobRef(arguments.repoId)>
        <cfif NOT structIsEmpty(j)>
            <cfset j.scanned       = arguments.summary.scanned>
            <cfset j.newFiles      = arguments.summary.newFiles>
            <cfset j.changed       = arguments.summary.changed>
            <cfset j.skipped       = arguments.summary.skipped>
            <cfset j.deleted       = arguments.summary.deleted>
            <cfset j.chunksWritten = arguments.summary.chunksWritten>
            <cfset j.errorCount    = arrayLen(arguments.summary.errors)>
            <cfif len(arguments.currentFile)><cfset j.currentFile = arguments.currentFile></cfif>
            <cfset j.heartbeat     = now()>
        </cfif>
    </cffunction>

    <!--- Persist the live counters to the ingest_runs row (throttled by caller). --->
    <cffunction name="snapshotRun" access="private" returntype="void" output="false">
        <cfargument name="repoId" type="numeric" required="true">
        <cfset var j = jobRef(arguments.repoId)>
        <cfif structIsEmpty(j) OR NOT val(j.runId)><cfreturn></cfif>
        <cftry>
            <cfquery attributeCollection="#request.queryAttributes#">
                update ingest_runs set
                    scanned = <cfqueryparam cfsqltype="cf_sql_integer" value="#j.scanned#">,
                    new_files = <cfqueryparam cfsqltype="cf_sql_integer" value="#j.newFiles#">,
                    changed = <cfqueryparam cfsqltype="cf_sql_integer" value="#j.changed#">,
                    skipped = <cfqueryparam cfsqltype="cf_sql_integer" value="#j.skipped#">,
                    deleted = <cfqueryparam cfsqltype="cf_sql_integer" value="#j.deleted#">,
                    chunks_written = <cfqueryparam cfsqltype="cf_sql_integer" value="#j.chunksWritten#">,
                    error_count = <cfqueryparam cfsqltype="cf_sql_integer" value="#j.errorCount#">,
                    current_file = <cfqueryparam cfsqltype="cf_sql_nvarchar" value="#left(j.currentFile, 500)#" maxlength="500" null="#(NOT len(j.currentFile))#">,
                    heartbeat_at = getDate()
                where ingest_run_id = <cfqueryparam cfsqltype="cf_sql_integer" value="#j.runId#">
            </cfquery>
            <cfcatch type="any"></cfcatch>
        </cftry>
    </cffunction>

    <!--- Finalise the run: set the terminal status in the job + the DB row. --->
    <cffunction name="finishRun" access="private" returntype="void" output="false">
        <cfargument name="repoId"  type="numeric" required="true">
        <cfargument name="status"  type="string"  required="true">
        <cfargument name="message" type="string"  required="false" default="">
        <cfset var j = jobRef(arguments.repoId)>
        <cfif NOT structIsEmpty(j)>
            <cfset j.status = arguments.status>
            <cfset j.message = arguments.message>
            <cfset j.currentFile = "">
            <cfset j.heartbeat = now()>
        </cfif>
        <cfif NOT structIsEmpty(j) AND val(j.runId)>
            <cftry>
                <cfquery attributeCollection="#request.queryAttributes#">
                    update ingest_runs set
                        status = <cfqueryparam cfsqltype="cf_sql_varchar" value="#arguments.status#" maxlength="20">,
                        finished_at = getDate(), heartbeat_at = getDate(),
                        scanned = <cfqueryparam cfsqltype="cf_sql_integer" value="#j.scanned#">,
                        new_files = <cfqueryparam cfsqltype="cf_sql_integer" value="#j.newFiles#">,
                        changed = <cfqueryparam cfsqltype="cf_sql_integer" value="#j.changed#">,
                        skipped = <cfqueryparam cfsqltype="cf_sql_integer" value="#j.skipped#">,
                        deleted = <cfqueryparam cfsqltype="cf_sql_integer" value="#j.deleted#">,
                        chunks_written = <cfqueryparam cfsqltype="cf_sql_integer" value="#j.chunksWritten#">,
                        error_count = <cfqueryparam cfsqltype="cf_sql_integer" value="#j.errorCount#">,
                        current_file = null,
                        message = <cfqueryparam cfsqltype="cf_sql_nvarchar" value="#left(arguments.message, 2000)#" maxlength="2000" null="#(NOT len(arguments.message))#">
                    where ingest_run_id = <cfqueryparam cfsqltype="cf_sql_integer" value="#j.runId#">
                </cfquery>
                <cfcatch type="any"></cfcatch>
            </cftry>
        </cfif>
    </cffunction>

    <!--- Ask a running ingest to stop after its current file. Returns true if
          there was a live run to signal. --->
    <cffunction name="requestStop" access="public" returntype="boolean" output="false">
        <cfargument name="repoId" type="numeric" required="true">
        <cfset var j = jobRef(arguments.repoId)>
        <cfif NOT structIsEmpty(j) AND j.status eq "running">
            <cfset j.stop = true>
            <cfreturn true>
        </cfif>
        <cfreturn false>
    </cffunction>

    <!--- Is an ingest for this repo live right now (running + fresh heartbeat)? --->
    <cffunction name="isRunningNow" access="public" returntype="boolean" output="false">
        <cfargument name="repoId" type="numeric" required="true">
        <cfset var j = jobRef(arguments.repoId)>
        <cfreturn (NOT structIsEmpty(j)) AND j.status eq "running" AND dateDiff("s", j.heartbeat, now()) lt 120>
    </cffunction>

    <!--- Status for the admin poller: live job struct if present, else the last
          ingest_runs row from the DB. --->
    <cffunction name="getRunStatus" access="public" returntype="struct" output="false">
        <cfargument name="repoId" type="numeric" required="true">
        <cfset var j = jobRef(arguments.repoId)>
        <cfset var row = "">
        <cfif NOT structIsEmpty(j)>
            <cfreturn {
                "found" = true, "live" = true, "runId" = j.runId, "status" = j.status,
                "scanned" = j.scanned, "newFiles" = j.newFiles, "changed" = j.changed,
                "skipped" = j.skipped, "deleted" = j.deleted, "chunksWritten" = j.chunksWritten,
                "errorCount" = j.errorCount, "currentFile" = j.currentFile, "message" = j.message,
                "startedAt" = fmtDT(j.startedAt), "finishedAt" = "",
                "elapsedSec" = int((getTickCount() - j.startedTick) / 1000),
                "heartbeatSecAgo" = dateDiff("s", j.heartbeat, now())
            }>
        </cfif>
        <cfquery name="row" attributeCollection="#request.queryAttributes#">
            select top 1 ingest_run_id, status, started_at, finished_at, heartbeat_at,
                   scanned, new_files, changed, skipped, deleted, chunks_written, error_count,
                   current_file, message
            from ingest_runs
            where repo_id = <cfqueryparam cfsqltype="cf_sql_integer" value="#arguments.repoId#">
            order by ingest_run_id desc
        </cfquery>
        <cfif row.recordCount>
            <cfreturn {
                "found" = true, "live" = false, "runId" = row.ingest_run_id, "status" = row.status,
                "scanned" = row.scanned, "newFiles" = row.new_files, "changed" = row.changed,
                "skipped" = row.skipped, "deleted" = row.deleted, "chunksWritten" = row.chunks_written,
                "errorCount" = row.error_count, "currentFile" = "", "message" = row.message,
                "startedAt" = fmtDT(row.started_at),
                "finishedAt" = isDate(row.finished_at) ? fmtDT(row.finished_at) : "",
                "elapsedSec" = isDate(row.finished_at) ? dateDiff("s", row.started_at, row.finished_at) : dateDiff("s", row.started_at, now()),
                "heartbeatSecAgo" = isDate(row.heartbeat_at) ? dateDiff("s", row.heartbeat_at, now()) : ""
            }>
        </cfif>
        <cfreturn { "found" = false }>
    </cffunction>

    <!--- Safe date-time formatting (avoids dateTimeFormat mask ambiguity). --->
    <cffunction name="fmtDT" access="private" returntype="string" output="false">
        <cfargument name="d" type="any" required="true">
        <cfif NOT isDate(arguments.d)><cfreturn ""></cfif>
        <cfreturn dateFormat(arguments.d, "yyyy-mm-dd") & " " & timeFormat(arguments.d, "HH:mm:ss")>
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
            "deleted" = 0, "errors" = [], "status" = "completed", "runId" = 0
        }>
        <cfset var thisExt = "">
        <cfset var skipThis = false>
        <cfset var exItem = "">
        <cfset var currMtime = "">
        <cfset var startTick = getTickCount()>
        <cfset var maxRunSeconds = (structKeyExists(request, "ingest") AND structKeyExists(request.ingest, "maxRunSeconds") AND val(request.ingest.maxRunSeconds) gt 0) ? val(request.ingest.maxRunSeconds) : 14400>
        <cfset var aborted = false>
        <cfset var abortStatus = "completed">
        <cfset var abortMsg = "">
        <cfset var snapshotEveryMs = 4000>
        <cfset var ctl = "">

        <!--- Load repo (must exist - the run row FKs to it) --->
        <cfquery name="repo" attributeCollection="#request.queryAttributes#">
            select repo_id, name, local_path, include_extensions, exclude_patterns, max_file_kb
            from repos
            where repo_id = <cfqueryparam cfsqltype="cf_sql_integer" value="#arguments.repoId#">
        </cfquery>
        <cfif repo.recordCount eq 0>
            <cfthrow message="Repo ##arguments.repoId## not found">
        </cfif>

        <cfset summary.runId = initRun(arguments.repoId)>
        <cfset startTick = getTickCount()>

        <cftry>
            <cfif NOT directoryExists(repo.local_path)>
                <cfthrow message="Repo path does not exist on disk: #repo.local_path#">
            </cfif>

            <cfset allowedExt = repo.include_extensions>
            <cfset excludes    = len(repo.exclude_patterns) ? repo.exclude_patterns : "">
            <cfset maxBytes    = val(repo.max_file_kb) * 1024>

            <!--- Recursive walk that PRUNES excluded directories before descending,
                  so .git / .claude / node_modules are never even enumerated. Keeps
                  startup fast and the Stop signal responsive throughout the walk. --->
            <cfset ctl = {
                "repoId" = arguments.repoId, "aborted" = false,
                "abortStatus" = "completed", "abortMsg" = "",
                "startTick" = startTick, "maxRunSeconds" = maxRunSeconds,
                "lastDbTick" = getTickCount(), "snapshotEveryMs" = snapshotEveryMs
            }>
            <cfset walkAndIngest(arguments.repoId, repo.local_path, repo.local_path, allowedExt, excludes, maxBytes, summary, seenPaths, ctl)>
            <cfset aborted = ctl.aborted>
            <cfset abortStatus = ctl.abortStatus>
            <cfset abortMsg = ctl.abortMsg>

            <!--- Deletions + the last_indexed stamp are only valid after a FULL
                  pass. On a stop/timeout we've walked only part of the tree, so
                  markMissingFiles would wrongly delete every not-yet-seen file. --->
            <cfif NOT aborted>
                <cfset summary.deleted = markMissingFiles(repo.repo_id, seenPaths)>
                <cfset touchJob(arguments.repoId, summary, "")>
                <cfquery attributeCollection="#request.queryAttributes#">
                    update repos set last_indexed = getDate()
                    where repo_id = <cfqueryparam cfsqltype="cf_sql_integer" value="#repo.repo_id#">
                </cfquery>
            </cfif>

            <cfset summary.status = aborted ? abortStatus : "completed">
            <cfset finishRun(arguments.repoId, summary.status, abortMsg)>

            <cfcatch type="any">
                <cfset arrayAppend(summary.errors, "RUN :: " & cfcatch.message)>
                <cfset summary.status = "error">
                <cfset touchJob(arguments.repoId, summary, "")>
                <cfset finishRun(arguments.repoId, "error", cfcatch.message & " | " & cfcatch.detail)>
            </cfcatch>
        </cftry>

        <cfreturn summary>
    </cffunction>

    <!--- ====================================================================
          Helpers
          ==================================================================== --->

    <!--- Does a path contain any of the exclude substrings? --->
    <cffunction name="isExcluded" access="private" returntype="boolean" output="false">
        <cfargument name="path"     type="string" required="true">
        <cfargument name="excludes" type="string" required="true">
        <cfset var ex = "">
        <cfloop list="#arguments.excludes#" index="ex">
            <cfif len(trim(ex)) AND findNoCase(trim(ex), arguments.path)>
                <cfreturn true>
            </cfif>
        </cfloop>
        <cfreturn false>
    </cffunction>

    <!--- Set the abort flags on the control struct if a stop was requested or the
          max run time is reached. Returns true when the walk should unwind. --->
    <cffunction name="checkStopTimeout" access="private" returntype="boolean" output="false">
        <cfargument name="ctl" type="struct" required="true">
        <cfif stopFlag(arguments.ctl.repoId)>
            <cfset arguments.ctl.aborted = true>
            <cfset arguments.ctl.abortStatus = "stopped">
            <cfset arguments.ctl.abortMsg = "Stopped by user.">
            <cfreturn true>
        </cfif>
        <cfif (getTickCount() - arguments.ctl.startTick) gte (arguments.ctl.maxRunSeconds * 1000)>
            <cfset arguments.ctl.aborted = true>
            <cfset arguments.ctl.abortStatus = "timedout">
            <cfset arguments.ctl.abortMsg = "Reached the max run time (#arguments.ctl.maxRunSeconds#s) - re-run to continue from where it stopped.">
            <cfreturn true>
        </cfif>
        <cfreturn false>
    </cffunction>

    <!--- Recursively walk a directory, pruning excluded subdirectories BEFORE
          descending (so .git / .claude / node_modules are never enumerated).
          Checks stop/timeout and updates progress on every entry, so the walk is
          responsive and visible from the first second. --->
    <cffunction name="walkAndIngest" access="private" returntype="void" output="false">
        <cfargument name="repoId"     type="numeric" required="true">
        <cfargument name="repoPath"   type="string"  required="true">
        <cfargument name="dir"        type="string"  required="true">
        <cfargument name="allowedExt" type="string"  required="true">
        <cfargument name="excludes"   type="string"  required="true">
        <cfargument name="maxBytes"   type="numeric" required="true">
        <cfargument name="summary"    type="struct"  required="true">
        <cfargument name="seenPaths"  type="struct"  required="true">
        <cfargument name="ctl"        type="struct"  required="true">

        <cfset var entries = "">
        <cfset var childPath = "">
        <cfset var thisExt = "">
        <cfset var relPath = "">

        <cfif arguments.ctl.aborted><cfreturn></cfif>

        <cfdirectory action="list" directory="#arguments.dir#" type="all" name="entries">

        <cfloop query="entries">
            <cfif arguments.ctl.aborted><cfreturn></cfif>
            <cfif checkStopTimeout(arguments.ctl)><cfreturn></cfif>

            <cfset childPath = entries.directory & "\" & entries.name>
            <cfset touchJob(arguments.repoId, arguments.summary, childPath)>
            <cfif (getTickCount() - arguments.ctl.lastDbTick) gte arguments.ctl.snapshotEveryMs>
                <cfset snapshotRun(arguments.repoId)>
                <cfset arguments.ctl.lastDbTick = getTickCount()>
            </cfif>

            <cfif entries.type eq "Dir">
                <!--- prune excluded directories (trailing slash so \.git\ etc match) --->
                <cfif NOT isExcluded(childPath & "\", arguments.excludes)>
                    <cfset walkAndIngest(arguments.repoId, arguments.repoPath, childPath, arguments.allowedExt, arguments.excludes, arguments.maxBytes, arguments.summary, arguments.seenPaths, arguments.ctl)>
                </cfif>
            <cfelse>
                <!--- file: extension, size and path-substring filters --->
                <cfset thisExt = lcase(listLast(entries.name, "."))>
                <cfif NOT listFindNoCase(arguments.allowedExt, thisExt)><cfcontinue></cfif>
                <cfif arguments.maxBytes gt 0 AND entries.size gt arguments.maxBytes><cfcontinue></cfif>
                <cfif isExcluded(childPath, arguments.excludes)><cfcontinue></cfif>

                <cfset relPath = relativePath(arguments.repoPath, childPath)>
                <cfset arguments.seenPaths[lcase(relPath)] = true>
                <cfset arguments.summary.scanned++>
                <cfset processFile(arguments.repoId, childPath, relPath, entries.size, entries.dateLastModified, thisExt, arguments.summary)>
            </cfif>
        </cfloop>
    </cffunction>

    <!--- Index one file: fast-path on size+mtime, else hash to confirm a real
          change, then upsert + (re-)embed. Mutates the shared summary struct. --->
    <cffunction name="processFile" access="private" returntype="void" output="false">
        <cfargument name="repoId"    type="numeric" required="true">
        <cfargument name="fullPath"  type="string"  required="true">
        <cfargument name="relPath"   type="string"  required="true">
        <cfargument name="fileSize"  type="numeric" required="true">
        <cfargument name="fileMtime" type="any"     required="true">
        <cfargument name="thisExt"   type="string"  required="true">
        <cfargument name="summary"   type="struct"  required="true">

        <cfset var existing = "">
        <cfset var content = "">
        <cfset var fileHash = "">
        <cfset var fileId = 0>
        <cfset var currMtime = mtimeToken(arguments.fileMtime)>

        <cftry>
            <cfquery name="existing" attributeCollection="#request.queryAttributes#">
                select file_id, file_hash, size_bytes, last_modified, is_deleted
                from code_files
                where repo_id = <cfqueryparam cfsqltype="cf_sql_integer" value="#arguments.repoId#">
                  and relative_path = <cfqueryparam cfsqltype="cf_sql_nvarchar" value="#arguments.relPath#" maxlength="500">
            </cfquery>

            <!--- FAST PATH: size + mtime unchanged - skip without reading. --->
            <cfif existing.recordCount AND existing.is_deleted eq 0
                  AND existing.size_bytes eq arguments.fileSize
                  AND len(existing.last_modified) AND existing.last_modified eq currMtime>
                <cfset arguments.summary.skipped++>
                <cfreturn>
            </cfif>

            <cffile action="read" file="#arguments.fullPath#" variable="content" charset="utf-8">
            <cfset fileHash = lcase(hash(content, "SHA-256"))>

            <cfif existing.recordCount AND existing.is_deleted eq 0 AND existing.file_hash eq fileHash>
                <!--- content identical, only the stamp drifted - refresh + skip --->
                <cfquery attributeCollection="#request.queryAttributes#">
                    update code_files
                    set size_bytes = <cfqueryparam cfsqltype="cf_sql_integer" value="#arguments.fileSize#">,
                        last_modified = <cfqueryparam cfsqltype="cf_sql_varchar" value="#currMtime#" maxlength="20">,
                        indexed_at = getDate()
                    where file_id = <cfqueryparam cfsqltype="cf_sql_integer" value="#existing.file_id#">
                </cfquery>
                <cfset arguments.summary.skipped++>
                <cfreturn>
            </cfif>

            <!--- new or genuinely changed - upsert and re-embed --->
            <cfif existing.recordCount>
                <cfset fileId = existing.file_id>
                <cfset arguments.summary.changed++>
                <cfquery attributeCollection="#request.queryAttributes#">
                    update code_files
                    set file_hash = <cfqueryparam cfsqltype="cf_sql_char" value="#fileHash#" maxlength="64">,
                        size_bytes = <cfqueryparam cfsqltype="cf_sql_integer" value="#arguments.fileSize#">,
                        language = <cfqueryparam cfsqltype="cf_sql_varchar" value="#arguments.thisExt#" maxlength="50">,
                        last_modified = <cfqueryparam cfsqltype="cf_sql_varchar" value="#currMtime#" maxlength="20">,
                        is_deleted = 0,
                        indexed_at = getDate()
                    where file_id = <cfqueryparam cfsqltype="cf_sql_integer" value="#fileId#">
                </cfquery>
                <cfset variables.store.deleteChunksForFile(fileId)>
            <cfelse>
                <cfset arguments.summary.newFiles++>
                <cfset fileId = insertFileRow(arguments.repoId, arguments.relPath, fileHash, arguments.fileSize, arguments.thisExt, currMtime)>
            </cfif>

            <cfset arguments.summary.chunksWritten += embedFileChunks(arguments.repoId, fileId, arguments.relPath, content)>

            <cfcatch type="any">
                <cfset arrayAppend(arguments.summary.errors, arguments.relPath & " :: " & cfcatch.message)>
                <!--- a half-embedded file would otherwise be hash-skipped forever;
                      blank its hash so it retries next run --->
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
    </cffunction>

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
