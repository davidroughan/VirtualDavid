<cfcomponent displayname="RAG" output="false"
    hint="Answers a developer's question as Virtual David: embeds the question, retrieves the most relevant code chunks, and asks the chat model to answer in David's voice grounded in that context.">

    <cffunction name="init" access="public" returntype="RAG" output="false">
        <cfset variables.oai   = createObject("component", "cfcs.AzureOpenAI")>
        <cfset variables.store = createObject("component", "cfcs.VectorStore")>
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

        <cfif NOT len(trim(arguments.question))>
            <cfset out.error = "Empty question.">
            <cfreturn out>
        </cfif>

        <!--- 1. embed the question --->
        <cfset qEmb = variables.oai.callEmbeddings(inputText = trim(arguments.question), purpose = "ask_embedding")>
        <cfif NOT qEmb.success>
            <cfset out.error = "Could not embed question: " & qEmb.errorMessage>
            <cfreturn out>
        </cfif>

        <!--- 2. retrieve --->
        <cfset hits = variables.store.cosineSearch(queryVector = qEmb.vector, topK = k, repoFilter = arguments.repoFilter)>

        <!--- 3. build the grounded system prompt --->
        <cfset systemText = buildSystemPrompt(hits)>

        <!--- 4. call the chat model (serializeJSON handles all escaping) --->
        <cfset msgs = [
            { "role" = "system", "content" = systemText },
            { "role" = "user",   "content" = trim(arguments.question) }
        ]>
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

        <!--- David's persona, written once, lives at the app root --->
        <cftry>
            <cffile action="read" file="#request.appRoot#SystemPrompt.txt" variable="persona" charset="utf-8">
            <cfcatch type="any"><cfset persona = "You are Virtual David, an Australian ColdFusion/JavaScript developer. Be direct, concise and practical."></cfcatch>
        </cftry>

        <cfsavecontent variable="sb"><cfoutput>#persona#

---
You are answering questions from other developers about David's codebases. Ground every answer in the CODE CONTEXT below, which was retrieved by semantic search for this question.

Rules:
- Use ONLY the code context to answer questions about how the code works. If the context does not contain the answer, say so plainly - do not invent code, file names, or behaviour.
- When you reference code, cite it as path:startLine-endLine so the developer can find it.
- Stay in David's voice: direct, concise, tradeoffs surfaced, no fluff.

=== CODE CONTEXT ===
<cfif arguments.hits.recordCount eq 0>(no relevant code was found for this question)
<cfelse><cfloop query="arguments.hits">[#arguments.hits.currentRow#] #arguments.hits.repo_name#/#arguments.hits.relative_path# (lines #arguments.hits.start_line#-#arguments.hits.end_line#) score=#numberFormat(arguments.hits.score, "0.000")#
#arguments.hits.content#

</cfloop></cfif>=== END CODE CONTEXT ===</cfoutput></cfsavecontent>

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
