<cfcomponent displayname="TwitterIngestor" output="false"
    hint="Turns a Twitter/X account export into retrievable knowledge for Virtual David - this is what lets him answer as David on topics outside the code (opinions, views, voice), not just the repos. Reads tweets.js from the archive's data folder, drops retweets and noise, strips reply prefixes / expands links, then embeds one chunk per surviving tweet via VectorStore. Deliberately separate from Ingestor.cfc (the code walker) and EmailIngestor.cfc: tweets are stored as chunks under a synthetic 'Twitter' repo so they're searchable through the existing ask flow with zero schema or VectorStore changes.">

    <cffunction name="init" access="public" returntype="TwitterIngestor" output="false">
        <cfset variables.oai   = createObject("component", "cfcs.AzureOpenAI")>
        <cfset variables.store = createObject("component", "cfcs.VectorStore")>
        <cfreturn this>
    </cffunction>

    <!--- ====================================================================
          Repo bootstrap
          ==================================================================== --->

    <!--- Find (or create) the synthetic repo that owns tweet chunks. Its
          include_extensions are deliberately inert ("__twitter__") so the normal
          code walker (Ingestor.ingestRepo) never tries to index the archive's
          .js files as source - this module is the only thing that writes to it. --->
    <cffunction name="ensureTwitterRepo" access="public" returntype="numeric" output="false">
        <cfargument name="name"      type="string" required="false" default="Twitter">
        <cfargument name="localPath" type="string" required="false" default="">

        <cfset var existing = "">
        <cfset var insertResult = "">
        <cfset var newId = 0>
        <cfset var path = len(arguments.localPath) ? arguments.localPath : (request.appRoot & "twitter")>

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
                <cfqueryparam cfsqltype="cf_sql_nvarchar" value="__twitter__"      maxlength="500">,
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

    <!--- Ingest a whole Twitter export. Point dir at the unzipped archive root
          (the folder holding "Your archive.html" and the data/ subfolder) OR
          directly at the data/ folder. Reads the account handle from account.js,
          stores the profile bio as a chunk, then ingests tweets.js (+ any
          tweets-partN.js). Incremental: a tweets file whose SHA-256 matches the
          stored hash is skipped. Returns a summary struct. --->
    <cffunction name="ingestArchive" access="public" returntype="struct" output="false">
        <cfargument name="dir"     type="string"  required="false" default="">
        <cfargument name="force"   type="boolean" required="false" default="false">
        <cfargument name="minChars" type="numeric" required="false" default="12">

        <cfset var root = len(arguments.dir) ? arguments.dir : (request.appRoot & "twitter")>
        <cfset var dataDir = locateDataDir(root)>
        <cfset var repoId = ensureTwitterRepo(localPath = root)>
        <cfset var files = "">
        <cfset var fullPath = "">
        <cfset var one = "">
        <cfset var acct = "">
        <cfset var summary = {
            "repoId" = repoId, "handle" = "", "displayName" = "",
            "scanned" = 0, "skipped" = 0, "ingested" = 0,
            "tweetsSeen" = 0, "tweetsKept" = 0, "chunksWritten" = 0, "errors" = []
        }>

        <cfif NOT directoryExists(dataDir)>
            <cfthrow message="Twitter data folder not found. Expected a 'data' subfolder under #root# (or pass the data folder directly).">
        </cfif>

        <!--- account handle / display name for self-describing chunks --->
        <cfset acct = readAccount(dataDir)>
        <cfset summary.handle = acct.handle>
        <cfset summary.displayName = acct.displayName>

        <!--- profile bio as its own chunk so "who are you" style questions retrieve it --->
        <cftry>
            <cfset summary.chunksWritten += ingestProfile(repoId, dataDir, acct, arguments.force)>
            <cfcatch type="any">
                <cfset arrayAppend(summary.errors, "profile.js :: " & cfcatch.message)>
            </cfcatch>
        </cftry>

        <!--- tweets.js and any split parts (tweets-part1.js ...) --->
        <cfdirectory action="list" directory="#dataDir#" name="files" type="file"
                     filter="tweets.js|tweets-part*.js" recurse="false" sort="name asc">

        <cfloop query="files">
            <cfset summary.scanned++>
            <cfset fullPath = files.directory & "\" & files.name>
            <cftry>
                <cfset one = ingestTweetsFile(repoId = repoId, path = fullPath, acct = acct,
                                              minChars = arguments.minChars, force = arguments.force)>
                <cfif one.skipped>
                    <cfset summary.skipped++>
                <cfelse>
                    <cfset summary.ingested++>
                    <cfset summary.tweetsSeen   += one.tweetsSeen>
                    <cfset summary.tweetsKept   += one.tweetsKept>
                    <cfset summary.chunksWritten += one.chunksWritten>
                </cfif>
                <cfcatch type="any">
                    <cfset arrayAppend(summary.errors, files.name & " :: " & cfcatch.message)>
                </cfcatch>
            </cftry>
        </cfloop>

        <cfreturn summary>
    </cffunction>

    <!--- Ingest a single tweets*.js file. Returns
          { skipped, tweetsSeen, tweetsKept, chunksWritten, fileId }. --->
    <cffunction name="ingestTweetsFile" access="public" returntype="struct" output="false">
        <cfargument name="repoId"   type="numeric" required="true">
        <cfargument name="path"     type="string"  required="true">
        <cfargument name="acct"     type="struct"  required="false" default="#structNew()#">
        <cfargument name="minChars" type="numeric" required="false" default="12">
        <cfargument name="force"    type="boolean" required="false" default="false">

        <cfset var out = { "skipped" = false, "tweetsSeen" = 0, "tweetsKept" = 0, "chunksWritten" = 0, "fileId" = 0 }>
        <cfset var relPath = getFileFromPath(arguments.path)>
        <cfset var raw = fileRead(arguments.path, "utf-8")>
        <cfset var fileHash = lcase(hash(raw, "SHA-256"))>
        <cfset var sizeBytes = len(raw)>
        <cfset var existing = "">
        <cfset var fileId = 0>
        <cfset var rows = "">
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

        <!--- parse the JS-wrapped JSON array of tweets --->
        <cfset rows = parseTweetsJs(raw)>
        <cfset out.tweetsSeen = arrayLen(rows)>

        <!--- build one retrievable chunk per surviving tweet --->
        <cfset chunks = buildChunks(rows, arguments.acct, arguments.minChars)>
        <cfset out.tweetsKept = arrayLen(chunks)>
        <cfif NOT arrayLen(chunks)>
            <cfthrow message="No usable tweets found in #relPath# (seen #out.tweetsSeen#; all were retweets, replies-only, links or too short).">
        </cfif>

        <!--- upsert the file row, then re-embed from scratch --->
        <cfif existing.recordCount>
            <cfset fileId = val(existing.file_id)>
            <cfset variables.store.deleteChunksForFile(fileId)>
            <cfquery attributeCollection="#request.queryAttributes#">
                update code_files
                set file_hash = <cfqueryparam cfsqltype="cf_sql_char" value="#fileHash#" maxlength="64">,
                    size_bytes = <cfqueryparam cfsqltype="cf_sql_integer" value="#sizeBytes#">,
                    language = 'twitter', is_deleted = 0, indexed_at = getDate()
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
          Archive parsing
          ==================================================================== --->

    <!--- The export wraps each data file as `window.YTD.<name>.partN = [ ... ];`.
          Strip everything up to the first '[' and parse the JSON array that
          follows (it runs to the end of the file). --->
    <cffunction name="parseJsArray" access="private" returntype="array" output="false">
        <cfargument name="raw" type="string" required="true">
        <cfset var start = find("[", arguments.raw)>
        <cfset var json = "">
        <cfset var data = "">
        <cfif start eq 0><cfreturn []></cfif>
        <cfset json = trim(mid(arguments.raw, start, len(arguments.raw) - start + 1))>
        <!--- tolerate a stray trailing semicolon after the closing bracket --->
        <cfif right(json, 1) eq ";"><cfset json = trim(left(json, len(json) - 1))></cfif>
        <cftry>
            <cfset data = deserializeJSON(json)>
            <cfcatch type="any">
                <cfthrow message="Could not parse archive JSON: #cfcatch.message#">
            </cfcatch>
        </cftry>
        <cfreturn isArray(data) ? data : []>
    </cffunction>

    <!--- Pull the bare tweet structs out of the [{ "tweet": {...} }, ...] wrapper. --->
    <cffunction name="parseTweetsJs" access="private" returntype="array" output="false">
        <cfargument name="raw" type="string" required="true">
        <cfset var arr = parseJsArray(arguments.raw)>
        <cfset var out = []>
        <cfset var item = "">
        <cfloop array="#arr#" index="item">
            <cfif isStruct(item) AND structKeyExists(item, "tweet") AND isStruct(item.tweet)>
                <cfset arrayAppend(out, item.tweet)>
            <cfelseif isStruct(item) AND structKeyExists(item, "full_text")>
                <cfset arrayAppend(out, item)>
            </cfif>
        </cfloop>
        <cfreturn out>
    </cffunction>

    <!--- The data folder may be the passed dir itself or a 'data' child of it. --->
    <cffunction name="locateDataDir" access="private" returntype="string" output="false">
        <cfargument name="root" type="string" required="true">
        <cfset var r = arguments.root>
        <cfif right(r, 1) eq "\" OR right(r, 1) eq "/"><cfset r = left(r, len(r) - 1)></cfif>
        <cfif fileExists(r & "\tweets.js")><cfreturn r></cfif>
        <cfreturn r & "\data">
    </cffunction>

    <!--- Read the account handle + display name from account.js (best effort). --->
    <cffunction name="readAccount" access="private" returntype="struct" output="false">
        <cfargument name="dataDir" type="string" required="true">
        <cfset var out = { "handle" = "", "displayName" = "" }>
        <cfset var path = arguments.dataDir & "\account.js">
        <cfset var arr = "">
        <cfset var a = "">
        <cfif NOT fileExists(path)><cfreturn out></cfif>
        <cftry>
            <cfset arr = parseJsArray(fileRead(path, "utf-8"))>
            <cfif arrayLen(arr) AND isStruct(arr[1]) AND structKeyExists(arr[1], "account")>
                <cfset a = arr[1].account>
                <cfif structKeyExists(a, "username")>          <cfset out.handle = a.username></cfif>
                <cfif structKeyExists(a, "accountDisplayName")><cfset out.displayName = a.accountDisplayName></cfif>
            </cfif>
            <cfcatch type="any"></cfcatch>
        </cftry>
        <cfreturn out>
    </cffunction>

    <!--- ====================================================================
          Profile bio chunk
          ==================================================================== --->

    <!--- Store the profile bio + location as a single chunk under a synthetic
          relative_path ("profile") so identity questions retrieve it. Returns the
          number of chunks written (0 or 1). --->
    <cffunction name="ingestProfile" access="private" returntype="numeric" output="false">
        <cfargument name="repoId" type="numeric" required="true">
        <cfargument name="dataDir" type="string"  required="true">
        <cfargument name="acct"   type="struct"  required="true">
        <cfargument name="force"  type="boolean" required="true">

        <cfset var path = arguments.dataDir & "\profile.js">
        <cfset var relPath = "profile">
        <cfset var arr = "">
        <cfset var p = "">
        <cfset var bio = "">
        <cfset var location = "">
        <cfset var website = "">
        <cfset var text = "">
        <cfset var fileHash = "">
        <cfset var existing = "">
        <cfset var fileId = 0>

        <cfif NOT fileExists(path)><cfreturn 0></cfif>

        <cfset arr = parseJsArray(fileRead(path, "utf-8"))>
        <cfif NOT (arrayLen(arr) AND isStruct(arr[1]) AND structKeyExists(arr[1], "profile"))><cfreturn 0></cfif>
        <cfset p = arr[1].profile>
        <cfif structKeyExists(p, "description") AND isStruct(p.description)>
            <cfif structKeyExists(p.description, "bio")>     <cfset bio = trim(decodeEntities(p.description.bio))></cfif>
            <cfif structKeyExists(p.description, "location")><cfset location = trim(p.description.location)></cfif>
            <cfif structKeyExists(p.description, "website")> <cfset website = trim(p.description.website)></cfif>
        </cfif>
        <cfif NOT len(bio) AND NOT len(location)><cfreturn 0></cfif>

        <cfsavecontent variable="text"><cfoutput>TWITTER PROFILE<cfif len(arguments.acct.displayName)> - #arguments.acct.displayName#</cfif><cfif len(arguments.acct.handle)> (@#arguments.acct.handle#)</cfif><cfif len(bio)>
Bio: #bio#</cfif><cfif len(location)>
Location: #location#</cfif><cfif len(website)>
Website: #website#</cfif></cfoutput></cfsavecontent>
        <cfset text = trim(text)>
        <cfset fileHash = lcase(hash(text, "SHA-256"))>

        <cfquery name="existing" attributeCollection="#request.queryAttributes#">
            select file_id, file_hash, is_deleted
            from code_files
            where repo_id = <cfqueryparam cfsqltype="cf_sql_integer" value="#arguments.repoId#">
              and relative_path = <cfqueryparam cfsqltype="cf_sql_nvarchar" value="#relPath#" maxlength="500">
        </cfquery>
        <cfif NOT arguments.force AND existing.recordCount AND existing.is_deleted eq 0 AND existing.file_hash eq fileHash>
            <cfreturn 0>
        </cfif>

        <cfif existing.recordCount>
            <cfset fileId = val(existing.file_id)>
            <cfset variables.store.deleteChunksForFile(fileId)>
            <cfquery attributeCollection="#request.queryAttributes#">
                update code_files
                set file_hash = <cfqueryparam cfsqltype="cf_sql_char" value="#fileHash#" maxlength="64">,
                    size_bytes = <cfqueryparam cfsqltype="cf_sql_integer" value="#len(text)#">,
                    language = 'twitter', is_deleted = 0, indexed_at = getDate()
                where file_id = <cfqueryparam cfsqltype="cf_sql_integer" value="#fileId#">
            </cfquery>
        <cfelse>
            <cfset fileId = insertFileRow(arguments.repoId, relPath, fileHash, len(text))>
        </cfif>

        <cfset embedAndStore(arguments.repoId, fileId, relPath, [ { "index" = 1, "text" = text, "tokenEst" = ceiling(len(text) / 4) } ])>
        <cfquery attributeCollection="#request.queryAttributes#">
            update code_files set chunk_count = 1
            where file_id = <cfqueryparam cfsqltype="cf_sql_integer" value="#fileId#">
        </cfquery>
        <cfreturn 1>
    </cffunction>

    <!--- ====================================================================
          Tweet -> chunk assembly
          ==================================================================== --->

    <!--- One self-describing chunk per tweet that carries David's own words.
          Dropped: retweets (not his words), and tweets that are empty/too short
          after stripping the reply @mentions and links. --->
    <cffunction name="buildChunks" access="private" returntype="array" output="false">
        <cfargument name="tweets"   type="array"   required="true">
        <cfargument name="acct"     type="struct"  required="true">
        <cfargument name="minChars" type="numeric" required="true">

        <cfset var chunks = []>
        <cfset var t = "">
        <cfset var raw = "">
        <cfset var clean = "">
        <cfset var who = "">
        <cfset var when = "">
        <cfset var replyTo = "">
        <cfset var text = "">
        <cfset var idx = 0>
        <cfset var handle = "">
        <cfset var displayName = "">

        <cfset handle = (structKeyExists(arguments.acct, "handle") AND len(trim(toString(arguments.acct.handle)))) ? trim(toString(arguments.acct.handle)) : "">
        <cfset displayName = (structKeyExists(arguments.acct, "displayName") AND len(trim(toString(arguments.acct.displayName)))) ? trim(toString(arguments.acct.displayName)) : "">
        <cfset who = len(displayName) ? displayName : "David Roughan">
        <cfif len(handle)><cfset who = who & " (@" & handle & ")"></cfif>

        <cfloop array="#arguments.tweets#" index="t">
            <cfif NOT isStruct(t) OR NOT structKeyExists(t, "full_text")><cfcontinue></cfif>
            <cfset raw = toString(t.full_text)>

            <!--- skip retweets: not David's words --->
            <cfif (structKeyExists(t, "retweeted") AND isBoolean(t.retweeted) AND t.retweeted)
                  OR reFindNoCase("^RT @", raw)>
                <cfcontinue>
            </cfif>

            <cfset clean = cleanTweetText(raw, t)>
            <cfif len(clean) lt arguments.minChars><cfcontinue></cfif>

            <cfset idx++>
            <cfset when = parseTwitterDate(structKeyExists(t, "created_at") ? t.created_at : "")>
            <cfset replyTo = (structKeyExists(t, "in_reply_to_screen_name") AND len(trim(toString(t.in_reply_to_screen_name))))
                             ? trim(toString(t.in_reply_to_screen_name)) : "">

            <cfsavecontent variable="text"><cfoutput>TWEET - #who#<cfif len(when)>, #when#</cfif><cfif len(replyTo)>
[in reply to @#replyTo#]</cfif>
#clean#</cfoutput></cfsavecontent>

            <cfset arrayAppend(chunks, {
                "index"    = idx,
                "text"     = trim(text),
                "tokenEst" = ceiling(len(text) / 4)
            })>
        </cfloop>

        <cfreturn chunks>
    </cffunction>

    <!--- Turn raw full_text into clean prose: strip leading reply @mentions,
          expand t.co links to their target (entities.urls), drop any leftover
          t.co/pic links, and decode HTML entities. --->
    <cffunction name="cleanTweetText" access="private" returntype="string" output="false">
        <cfargument name="raw"   type="string" required="true">
        <cfargument name="tweet" type="struct" required="true">

        <cfset var txt = arguments.raw>
        <cfset var urls = "">
        <cfset var u = "">

        <!--- expand shortened links so they read meaningfully --->
        <cfif structKeyExists(arguments.tweet, "entities") AND isStruct(arguments.tweet.entities)
              AND structKeyExists(arguments.tweet.entities, "urls") AND isArray(arguments.tweet.entities.urls)>
            <cfset urls = arguments.tweet.entities.urls>
            <cfloop array="#urls#" index="u">
                <cfif isStruct(u) AND structKeyExists(u, "url") AND len(u.url) AND structKeyExists(u, "expanded_url")>
                    <cfset txt = replace(txt, u.url, u.expanded_url, "all")>
                </cfif>
            </cfloop>
        </cfif>

        <!--- strip leading reply handles ("@a @b actual words" -> "actual words") --->
        <cfset txt = reReplace(txt, "^(\s*@[A-Za-z0-9_]+)+\s*", "", "one")>
        <!--- drop any remaining bare t.co links (media/quote-tweet shorteners) --->
        <cfset txt = reReplaceNoCase(txt, "https?://t\.co/[A-Za-z0-9]+", "", "all")>

        <cfreturn trim(decodeEntities(txt))>
    </cffunction>

    <!--- Decode the handful of HTML entities Twitter encodes in full_text. --->
    <cffunction name="decodeEntities" access="private" returntype="string" output="false">
        <cfargument name="s" type="string" required="true">
        <cfset var out = arguments.s>
        <cfset out = replace(out, "&lt;",   "<",  "all")>
        <cfset out = replace(out, "&gt;",   ">",  "all")>
        <cfset out = replace(out, "&quot;", '"',  "all")>
        <cfset out = replace(out, "&##39;", "'",  "all")>
        <cfset out = replace(out, "&amp;",  "&",  "all")><!--- last: handles double-encoding --->
        <cfreturn out>
    </cffunction>

    <!--- "Fri Jun 05 08:57:45 +0000 2026" -> "2026-06-05". Falls back to "". --->
    <cffunction name="parseTwitterDate" access="private" returntype="string" output="false">
        <cfargument name="created" type="string" required="true">
        <cfset var parts = listToArray(trim(arguments.created), " ")>
        <cfset var months = "Jan,Feb,Mar,Apr,May,Jun,Jul,Aug,Sep,Oct,Nov,Dec">
        <cfset var mon = 0>
        <cfif arrayLen(parts) lt 6><cfreturn ""></cfif>
        <cfset mon = listFindNoCase(months, parts[2])>
        <cfif mon eq 0><cfreturn ""></cfif>
        <cfreturn parts[6] & "-" & numberFormat(mon, "00") & "-" & numberFormat(val(parts[3]), "00")>
    </cffunction>

    <!--- ====================================================================
          Embedding + storage
          ==================================================================== --->

    <!--- Embed chunks in token/count-bounded batches (one Azure call per batch)
          and store each. Mirrors Ingestor.embedFileChunks batching so a few
          thousand tweets don't become a few thousand HTTP calls. Returns the
          number of chunks written. Throws on a failed embed batch. --->
    <cffunction name="embedAndStore" access="private" returntype="numeric" output="false">
        <cfargument name="repoId"  type="numeric" required="true">
        <cfargument name="fileId"  type="numeric" required="true">
        <cfargument name="relPath" type="string"  required="true">
        <cfargument name="chunks"  type="array"   required="true">

        <cfset var batchSize = max(1, val(request.ingest.embedBatchSize))>
        <cfset var batchTokens = max(1, val(request.ingest.embedBatchTokens))>
        <cfset var batch = []>
        <cfset var batchTok = 0>
        <cfset var ch = "">
        <cfset var written = 0>

        <cfif NOT arrayLen(arguments.chunks)><cfreturn 0></cfif>

        <cfloop array="#arguments.chunks#" index="ch">
            <cfif arrayLen(batch)
                  AND (arrayLen(batch) ge batchSize OR (batchTok + ch.tokenEst) gt batchTokens)>
                <cfset written += flushBatch(arguments.repoId, arguments.fileId, arguments.relPath, batch)>
                <cfset batch = []>
                <cfset batchTok = 0>
            </cfif>
            <cfset arrayAppend(batch, ch)>
            <cfset batchTok += ch.tokenEst>
        </cfloop>
        <cfif arrayLen(batch)>
            <cfset written += flushBatch(arguments.repoId, arguments.fileId, arguments.relPath, batch)>
        </cfif>

        <cfreturn written>
    </cffunction>

    <!--- Embed one batch in a single Azure call and store each chunk. --->
    <cffunction name="flushBatch" access="private" returntype="numeric" output="false">
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
            <cfset arrayAppend(inputs, c.text)>
        </cfloop>

        <cfset emb = variables.oai.callEmbeddingsBatch(inputs = inputs, purpose = "twitter_embedding")>
        <cfif NOT emb.success>
            <cfthrow message="Batch embedding failed for #arguments.relPath# (#arrayLen(inputs)# chunk(s)): #emb.errorMessage#">
        </cfif>

        <cfloop from="1" to="#arrayLen(arguments.batch)#" index="j">
            <cfset c = arguments.batch[j]>
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

        <cfreturn arrayLen(arguments.batch)>
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
                <cfqueryparam cfsqltype="cf_sql_varchar"  value="twitter" maxlength="50">,
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
