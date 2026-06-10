<cfcomponent displayname="RAG" output="false"
    hint="Answers a developer's question as Virtual David: embeds the question, retrieves the most relevant code chunks, and asks the chat model to answer in David's voice grounded in that context.">

    <cffunction name="init" access="public" returntype="RAG" output="false">
        <cfset variables.oai     = createObject("component", "cfcs.AzureOpenAI")>
        <cfset variables.store   = createObject("component", "cfcs.VectorStore")>
        <cfset variables.prompts = createObject("component", "cfcs.PromptStore")>
        <cfreturn this>
    </cffunction>

    <!---
        answer
        ------
        Returns a struct:
            success   - boolean
            answer    - the model's reply (David's voice)
            sources   - array of { repo_name, path, lines, score }
            error     - populated on failure
            usage     - token usage struct
    --->
    <cffunction name="answer" access="public" returntype="struct" output="false">
        <cfargument name="question"   type="string"  required="true">
        <cfargument name="history"    type="array"   required="false" default="#arrayNew(1)#">
        <cfargument name="topK"       type="numeric" required="false" default="0">
        <cfargument name="repoFilter" type="string"  required="false" default="">

        <cfset var out = { "success" = false, "answer" = "", "sources" = [], "error" = "", "usage" = {} }>
        <cfset var k = arguments.topK gt 0 ? arguments.topK : val(request.retrieval.topK)>
        <cfset var qEmb = "">
        <cfset var hits = "">
        <cfset var systemText = "">
        <cfset var jsonBody = "">
        <cfset var chat = "">
        <cfset var sourceIds = "">
        <cfset var msgs = "">
        <cfset var priorTurns = "">
        <cfset var retrievalQuery = "">
        <cfset var turn = "">

        <cfif NOT len(trim(arguments.question))>
            <cfset out.error = "Empty question.">
            <cfreturn out>
        </cfif>

        <!--- Normalise prior conversation turns (keep only valid user/assistant
              roles with text content, cap to the most recent N to bound tokens). --->
        <cfset priorTurns = sanitizeHistory(arguments.history)>

        <!--- 1. embed the question. For terse follow-ups ("what about errors?")
              the bare question retrieves poorly, so fold in the most recent prior
              user turn to give the embedding some topical anchor. --->
        <cfset retrievalQuery = buildRetrievalQuery(trim(arguments.question), priorTurns)>
        <cfset qEmb = variables.oai.callEmbeddings(inputText = retrievalQuery, purpose = "ask_embedding")>
        <cfif NOT qEmb.success>
            <cfset out.error = "Could not embed question: " & qEmb.errorMessage>
            <cfreturn out>
        </cfif>

        <!--- 2. retrieve --->
        <cfset hits = variables.store.cosineSearch(queryVector = qEmb.vector, topK = k, repoFilter = arguments.repoFilter)>

        <!--- 3. build the grounded system prompt --->
        <cfset systemText = buildSystemPrompt(hits)>

        <!--- 4. call the chat model (serializeJSON handles all escaping).
              messages = system (fresh context for this turn) + prior turns + current question. --->
        <cfset msgs = [ { "role" = "system", "content" = systemText } ]>
        <cfloop array="#priorTurns#" index="turn">
            <cfset arrayAppend(msgs, turn)>
        </cfloop>
        <cfset arrayAppend(msgs, { "role" = "user", "content" = trim(arguments.question) })>
        <!--- javaCast to int so serializeJSON emits "4000", not "4000.0" (Azure
              rejects a decimal for this integer field). --->
        <cfset jsonBody = serializeJSON({
            "messages" = msgs,
            "max_completion_tokens" = javaCast("int", val(request.retrieval.maxAnswerTokens))
        })>

        <cfset chat = variables.oai.callChatCompletion(jsonBody = jsonBody, purpose = "ask_chat")>

        <cfif NOT chat.success>
            <cfset out.error = "Chat call failed: " & chat.errorMessage>
            <cfset logChat(arguments.question, "", hits, chat, false)>
            <cfreturn out>
        </cfif>

        <cftry>
            <cfset out.answer = chat.parsed.choices[1].message.content>
            <cfcatch type="any">
                <cfset out.error = "Could not parse model reply.">
                <cfset logChat(arguments.question, "", hits, chat, false)>
                <cfreturn out>
            </cfcatch>
        </cftry>

        <cfset out.sources = buildSources(hits)>
        <cfset out.usage = chat.usage>
        <cfset out.success = true>

        <cfset logChat(arguments.question, out.answer, hits, chat, true)>
        <cfreturn out>
    </cffunction>

    <!--- ====================================================================
          Prompt assembly
          ==================================================================== --->

    <cffunction name="buildSystemPrompt" access="private" returntype="string" output="false">
        <cfargument name="hits" type="query" required="true">

        <cfset var persona = "">
        <cfset var sb = "">
        <cfset var i = 0>
        <cfset var kind = "">

        <!--- David's persona, edited via admin/prompt.cfm and stored in the DB so
              the prod 'ask' module reads it from the shared database (no reliance
              on a SystemPrompt.txt on the prod filesystem). Falls back to a
              hardcoded persona if the row is missing. --->
        <cfset persona = variables.prompts.getContent()>

        <!--- Retrieval mixes two kinds of chunk: CODE (real codebases + email
              guidance about the code) and PERSONAL (David's own tweets/profile -
              his views and voice). The grounding rules differ per kind, so each
              chunk is tagged below and the model is told how to use each. --->
        <cfsavecontent variable="sb"><cfoutput>#persona#

---
You are David, answering in an ongoing conversation (earlier messages may set up follow-ups). The CONTEXT below was freshly retrieved by semantic search for the latest question. Each entry is tagged by source:
- [CODE] = a chunk from David's codebases (or his email guidance about that code). The source repo/path is shown.
- [PERSONAL] = David's own words from his Twitter/X history or profile - his opinions, views and voice.

Rules:
- For questions about how code works or how something is built, answer from [CODE] entries only. If they don't contain the answer, say so plainly - do not invent code, file names, or behaviour. Cite code as path:startLine-endLine.
- For questions about what David thinks, his opinions, or anything outside the code, answer from [PERSONAL] entries, as David, in his voice. No file citations for these. If the context doesn't show his view on it, say you're not sure rather than inventing one - don't put words in his mouth.
- Use the conversation so far to resolve what a follow-up refers to, but ground each answer in the CONTEXT below - it is refreshed each turn and is the source of truth.
- Stay in David's voice throughout: direct, concise, tradeoffs surfaced, no fluff.

=== CONTEXT ===
<cfif arguments.hits.recordCount eq 0>(nothing relevant was retrieved for this question)
<cfelse><cfloop query="arguments.hits"><cfset kind = (arguments.hits.repo_name eq "Twitter") ? "PERSONAL" : "CODE">[#arguments.hits.currentRow#] [#kind#] #arguments.hits.repo_name#/#arguments.hits.relative_path# (lines #arguments.hits.start_line#-#arguments.hits.end_line#) score=#numberFormat(arguments.hits.score, "0.000")#
#arguments.hits.content#

</cfloop></cfif>=== END CONTEXT ===</cfoutput></cfsavecontent>

        <cfreturn sb>
    </cffunction>

    <cffunction name="buildSources" access="private" returntype="array" output="false">
        <cfargument name="hits" type="query" required="true">
        <cfset var arr = []>
        <cfloop query="arguments.hits">
            <cfset arrayAppend(arr, {
                "repo_name" = arguments.hits.repo_name,
                "path"      = arguments.hits.relative_path,
                "lines"     = arguments.hits.start_line & "-" & arguments.hits.end_line,
                "score"     = numberFormat(arguments.hits.score, "0.000")
            })>
        </cfloop>
        <cfreturn arr>
    </cffunction>

    <!--- ====================================================================
          Conversation history
          ==================================================================== --->

    <cffunction name="sanitizeHistory" access="private" returntype="array" output="false"
        hint="Coerces client-supplied history into a clean [{role,content}] array: only user/assistant roles with non-empty string content, capped to the most recent maxTurns to bound prompt size.">
        <cfargument name="history"  type="array"   required="true">
        <cfargument name="maxTurns" type="numeric" required="false" default="12">

        <cfset var clean = []>
        <cfset var item = "">
        <cfset var role = "">
        <cfset var content = "">
        <cfset var startIdx = 1>

        <cfloop array="#arguments.history#" index="item">
            <cfif NOT isStruct(item) OR NOT structKeyExists(item, "role") OR NOT structKeyExists(item, "content")>
                <cfcontinue>
            </cfif>
            <cfset role = lcase(trim(item.role))>
            <cfset content = trim(toString(item.content))>
            <cfif (role eq "user" OR role eq "assistant") AND len(content)>
                <cfset arrayAppend(clean, { "role" = role, "content" = content })>
            </cfif>
        </cfloop>

        <!--- keep only the most recent maxTurns messages --->
        <cfif arrayLen(clean) gt arguments.maxTurns>
            <cfset startIdx = arrayLen(clean) - arguments.maxTurns + 1>
            <cfreturn arraySlice(clean, startIdx, arguments.maxTurns)>
        </cfif>
        <cfreturn clean>
    </cffunction>

    <cffunction name="buildRetrievalQuery" access="private" returntype="string" output="false"
        hint="Anchors a terse follow-up with the most recent prior user turn so semantic search has topical context to match against.">
        <cfargument name="question"   type="string" required="true">
        <cfargument name="priorTurns" type="array"  required="true">

        <cfset var i = 0>
        <cfset var lastUser = "">

        <cfloop from="#arrayLen(arguments.priorTurns)#" to="1" index="i" step="-1">
            <cfif arguments.priorTurns[i].role eq "user">
                <cfset lastUser = arguments.priorTurns[i].content>
                <cfbreak>
            </cfif>
        </cfloop>

        <cfif len(lastUser)>
            <cfreturn lastUser & chr(10) & arguments.question>
        </cfif>
        <cfreturn arguments.question>
    </cffunction>

    <!--- ====================================================================
          Logging
          ==================================================================== --->

    <cffunction name="logChat" access="private" returntype="void" output="false">
        <cfargument name="question" type="string"  required="true">
        <cfargument name="answer"   type="string"  required="true">
        <cfargument name="hits"     type="query"   required="true">
        <cfargument name="chat"     type="struct"  required="true">
        <cfargument name="success"  type="boolean" required="true">

        <cfset var ids = "">
        <cfset var remoteIp = "">
        <cftry>
            <cfset remoteIp = left(toString(CGI.REMOTE_ADDR), 50)>
            <cfloop query="arguments.hits">
                <cfset ids = listAppend(ids, arguments.hits.chunk_id)>
            </cfloop>

            <cfquery attributeCollection="#request.queryAttributes#">
                insert into chat_log
                    (question, answer, source_chunk_ids, prompt_tokens, completion_tokens, total_tokens, success, remote_ip)
                values (
                    <cfqueryparam cfsqltype="cf_sql_longvarchar" value="#arguments.question#">,
                    <cfqueryparam cfsqltype="cf_sql_longvarchar" value="#arguments.answer#" null="#(NOT len(arguments.answer))#">,
                    <cfqueryparam cfsqltype="cf_sql_nvarchar" value="#ids#" maxlength="1000" null="#(NOT len(ids))#">,
                    <cfqueryparam cfsqltype="cf_sql_integer" value="#val(arguments.chat.usage.prompt_tokens)#"     null="#(NOT isNumeric(arguments.chat.usage.prompt_tokens))#">,
                    <cfqueryparam cfsqltype="cf_sql_integer" value="#val(arguments.chat.usage.completion_tokens)#" null="#(NOT isNumeric(arguments.chat.usage.completion_tokens))#">,
                    <cfqueryparam cfsqltype="cf_sql_integer" value="#val(arguments.chat.usage.total_tokens)#"      null="#(NOT isNumeric(arguments.chat.usage.total_tokens))#">,
                    <cfqueryparam cfsqltype="cf_sql_bit" value="#(arguments.success ? 1 : 0)#">,
                    <cfqueryparam cfsqltype="cf_sql_varchar" value="#remoteIp#" maxlength="50" null="#(NOT len(remoteIp))#">
                )
            </cfquery>
            <cfcatch type="any"></cfcatch>
        </cftry>
    </cffunction>

</cfcomponent>
