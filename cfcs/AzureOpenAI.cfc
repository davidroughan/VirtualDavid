<cfcomponent displayname="AzureOpenAI" output="false"
    hint="Wrapper around Azure OpenAI chat completions + embeddings endpoints that captures usage telemetry into ai_usage_log. Copied from Lucinda and extended with callEmbeddings.">

    <!---
        callChatCompletion
        ------------------
        Posts the supplied JSON body to an Azure OpenAI chat completions endpoint,
        parses the response, and writes one row to ai_usage_log.

        endpointURL and apiKey default to request.openAI_endPoint / request.openAI_apiKey
        when not supplied, so most callers can pass just jsonBody and purpose.

        Returns a struct: success, statusCode, fileContent, parsed, usage, logId,
        errorMessage, durationMs, finishReason.
    --->
    <cffunction name="callChatCompletion" access="public" returntype="struct" output="false">
        <cfargument name="jsonBody"    type="string"  required="true">
        <cfargument name="purpose"     type="string"  required="true">
        <cfargument name="endpointURL" type="string"  required="false" default="">
        <cfargument name="apiKey"      type="string"  required="false" default="">
        <cfargument name="modelName"   type="string"  required="false" default="">
        <cfargument name="timeout"     type="numeric" required="false" default="120">

        <cfset var result = {
            "success"      = false,
            "statusCode"   = 0,
            "fileContent"  = "",
            "parsed"       = {},
            "usage"        = { "prompt_tokens" = "", "completion_tokens" = "", "reasoning_tokens" = "", "total_tokens" = "" },
            "logId"        = 0,
            "errorMessage" = "",
            "durationMs"   = 0,
            "finishReason" = ""
        }>
        <cfset var httpResult = "">
        <cfset var startTick = getTickCount()>
        <cfset var endTick = startTick>
        <cfset var parsed = {}>
        <cfset var choice = "">
        <cfset var usageStruct = "">
        <cfset var detailsStruct = "">
        <cfset var effectiveEndpoint = len(arguments.endpointURL) ? arguments.endpointURL : (isDefined("request.openAI_endPoint") ? request.openAI_endPoint : "")>
        <cfset var effectiveApiKey   = len(arguments.apiKey)      ? arguments.apiKey      : (isDefined("request.openAI_apiKey")   ? request.openAI_apiKey   : "")>
        <cfset var effectiveModel    = len(arguments.modelName)   ? arguments.modelName   : (isDefined("request.openAI_modelDeploymentName") ? request.openAI_modelDeploymentName : "")>

        <cftry>
            <cfhttp url="#effectiveEndpoint#"
                    method="POST"
                    timeout="#arguments.timeout#"
                    result="httpResult"
                    charset="utf-8">
                <cfhttpparam type="header" name="api-key"      value="#effectiveApiKey#">
                <cfhttpparam type="header" name="Content-Type" value="application/json">
                <cfhttpparam type="body"   value="#arguments.jsonBody#">
            </cfhttp>
            <cfset endTick = getTickCount()>

            <cfset result.statusCode  = val(httpResult.statusCode)>
            <cfset result.fileContent = isDefined("httpResult.fileContent") ? toString(httpResult.fileContent) : "">
            <cfset result.durationMs  = endTick - startTick>

            <cfif result.statusCode eq 200>
                <cfset result.success = true>
            <cfelse>
                <cfset result.errorMessage = "HTTP " & result.statusCode & ": " & left(result.fileContent, 1000)>
            </cfif>

            <cftry>
                <cfif len(trim(result.fileContent))>
                    <cfset parsed = deserializeJSON(result.fileContent)>
                    <cfif isStruct(parsed)>
                        <cfset result.parsed = parsed>
                        <cfif structKeyExists(parsed, "usage") AND isStruct(parsed.usage)>
                            <cfset usageStruct = parsed.usage>
                            <cfif structKeyExists(usageStruct, "prompt_tokens")>
                                <cfset result.usage.prompt_tokens = val(usageStruct.prompt_tokens)>
                            </cfif>
                            <cfif structKeyExists(usageStruct, "completion_tokens")>
                                <cfset result.usage.completion_tokens = val(usageStruct.completion_tokens)>
                            </cfif>
                            <cfif structKeyExists(usageStruct, "total_tokens")>
                                <cfset result.usage.total_tokens = val(usageStruct.total_tokens)>
                            </cfif>
                            <cfif structKeyExists(usageStruct, "completion_tokens_details") AND isStruct(usageStruct.completion_tokens_details)>
                                <cfset detailsStruct = usageStruct.completion_tokens_details>
                                <cfif structKeyExists(detailsStruct, "reasoning_tokens")>
                                    <cfset result.usage.reasoning_tokens = val(detailsStruct.reasoning_tokens)>
                                </cfif>
                            </cfif>
                        </cfif>
                        <cfif structKeyExists(parsed, "choices") AND isArray(parsed.choices) AND arrayLen(parsed.choices)>
                            <cfset choice = parsed.choices[1]>
                            <cfif isStruct(choice) AND structKeyExists(choice, "finish_reason")>
                                <cfset result.finishReason = toString(choice.finish_reason)>
                            </cfif>
                        </cfif>
                        <cfif NOT result.success AND structKeyExists(parsed, "error") AND isStruct(parsed.error) AND structKeyExists(parsed.error, "message")>
                            <cfset result.errorMessage = "HTTP " & result.statusCode & ": " & toString(parsed.error.message)>
                        </cfif>
                    </cfif>
                </cfif>
                <cfcatch type="any"></cfcatch>
            </cftry>

            <cfcatch type="any">
                <cfset endTick = getTickCount()>
                <cfset result.durationMs   = endTick - startTick>
                <cfset result.success      = false>
                <cfset result.statusCode   = 0>
                <cfset result.errorMessage = "cfhttp threw: " & cfcatch.message & " | " & cfcatch.detail>
            </cfcatch>
        </cftry>

        <cftry>
            <cfset result.logId = logUsage(
                purpose            = arguments.purpose,
                endpointURL        = effectiveEndpoint,
                modelName          = effectiveModel,
                requestSizeBytes   = len(arguments.jsonBody),
                responseSizeBytes  = len(result.fileContent),
                promptTokens       = result.usage.prompt_tokens,
                completionTokens   = result.usage.completion_tokens,
                reasoningTokens    = result.usage.reasoning_tokens,
                totalTokens        = result.usage.total_tokens,
                durationMs         = result.durationMs,
                httpStatusCode     = result.statusCode,
                finishReason       = result.finishReason,
                success            = result.success,
                errorMessage       = result.errorMessage
            )>
            <cfcatch type="any">
                <cfset result.logId = 0>
            </cfcatch>
        </cftry>

        <cfreturn result>
    </cffunction>


    <!---
        callEmbeddings
        --------------
        Posts a single input string to an Azure OpenAI embeddings deployment and
        returns the embedding vector. Defaults endpoint/key to
        request.openAI_embeddingEndpoint / request.openAI_apiKey.

        Returns a struct:
            success      - boolean (HTTP 200 AND a parseable embedding)
            statusCode   - HTTP status code
            vector       - array of floats (empty on failure)
            dims         - length of the vector
            usage        - { prompt_tokens, total_tokens }
            errorMessage - populated on failure
            durationMs   - duration of the cfhttp call
            logId        - ai_usage_log PK (0 if logging failed)
    --->
    <cffunction name="callEmbeddings" access="public" returntype="struct" output="false">
        <cfargument name="inputText"   type="string"  required="true">
        <cfargument name="purpose"     type="string"  required="false" default="embedding">
        <cfargument name="endpointURL" type="string"  required="false" default="">
        <cfargument name="apiKey"      type="string"  required="false" default="">
        <cfargument name="modelName"   type="string"  required="false" default="">
        <cfargument name="timeout"     type="numeric" required="false" default="120">
        <cfargument name="maxRetries"  type="numeric" required="false" default="5">

        <cfset var result = {
            "success"      = false,
            "statusCode"   = 0,
            "vector"       = [],
            "dims"         = 0,
            "usage"        = { "prompt_tokens" = "", "total_tokens" = "" },
            "errorMessage" = "",
            "durationMs"   = 0,
            "logId"        = 0,
            "attempts"     = 0
        }>
        <cfset var httpResult = "">
        <cfset var startTick = getTickCount()>
        <cfset var endTick = startTick>
        <cfset var parsed = {}>
        <cfset var jsonBody = serializeJSON({ "input" = arguments.inputText })>
        <cfset var responseSize = 0>
        <cfset var attempt = 0>
        <cfset var retryAfter = "">
        <cfset var waitMs = 0>
        <cfset var effectiveEndpoint = len(arguments.endpointURL) ? arguments.endpointURL : (isDefined("request.openAI_embeddingEndpoint") ? request.openAI_embeddingEndpoint : "")>
        <cfset var effectiveApiKey   = len(arguments.apiKey)      ? arguments.apiKey      : (isDefined("request.openAI_apiKey")              ? request.openAI_apiKey            : "")>
        <cfset var effectiveModel    = len(arguments.modelName)   ? arguments.modelName   : (isDefined("request.openAI_embeddingModel")      ? request.openAI_embeddingModel    : "")>
        <cfset var fileContent = "">

        <cftry>
            <!--- Retry loop: Azure throttles embeddings with HTTP 429 (and the
                  odd 503). Honour Retry-After when present, else exponential
                  backoff capped at 30s, up to maxRetries times. --->
            <cfloop condition="true">
                <cfset attempt++>
                <cfset startTick = getTickCount()>
                <cfhttp url="#effectiveEndpoint#"
                        method="POST"
                        timeout="#arguments.timeout#"
                        result="httpResult"
                        charset="utf-8">
                    <cfhttpparam type="header" name="api-key"      value="#effectiveApiKey#">
                    <cfhttpparam type="header" name="Content-Type" value="application/json">
                    <cfhttpparam type="body"   value="#jsonBody#">
                </cfhttp>
                <cfset endTick = getTickCount()>

                <cfset result.statusCode = val(httpResult.statusCode)>
                <cfset result.durationMs = endTick - startTick>
                <cfset result.attempts   = attempt>
                <cfset fileContent = isDefined("httpResult.fileContent") ? toString(httpResult.fileContent) : "">
                <cfset responseSize = len(fileContent)>

                <cfif (result.statusCode eq 429 OR result.statusCode eq 503) AND attempt lte arguments.maxRetries>
                    <cfset retryAfter = (isStruct(httpResult.responseHeader) AND structKeyExists(httpResult.responseHeader, "Retry-After")) ? httpResult.responseHeader["Retry-After"] : "">
                    <cfif isNumeric(retryAfter)>
                        <cfset waitMs = min(60, val(retryAfter)) * 1000>
                    <cfelse>
                        <cfset waitMs = min(30000, (2 ^ attempt) * 1000)>
                    </cfif>
                    <cfset sleep(waitMs)>
                    <cfcontinue>
                </cfif>
                <cfbreak>
            </cfloop>

            <cfif result.statusCode neq 200>
                <cfset result.errorMessage = "HTTP " & result.statusCode & ": " & left(fileContent, 1000)>
            </cfif>

            <cftry>
                <cfif len(trim(fileContent))>
                    <cfset parsed = deserializeJSON(fileContent)>
                    <cfif isStruct(parsed)>
                        <cfif structKeyExists(parsed, "data") AND isArray(parsed.data) AND arrayLen(parsed.data)
                              AND isStruct(parsed.data[1]) AND structKeyExists(parsed.data[1], "embedding")
                              AND isArray(parsed.data[1].embedding) AND arrayLen(parsed.data[1].embedding)>
                            <cfset result.vector = parsed.data[1].embedding>
                            <cfset result.dims   = arrayLen(result.vector)>
                            <cfif result.statusCode eq 200>
                                <cfset result.success = true>
                            </cfif>
                        </cfif>
                        <cfif structKeyExists(parsed, "usage") AND isStruct(parsed.usage)>
                            <cfif structKeyExists(parsed.usage, "prompt_tokens")>
                                <cfset result.usage.prompt_tokens = val(parsed.usage.prompt_tokens)>
                            </cfif>
                            <cfif structKeyExists(parsed.usage, "total_tokens")>
                                <cfset result.usage.total_tokens = val(parsed.usage.total_tokens)>
                            </cfif>
                        </cfif>
                        <cfif NOT result.success AND structKeyExists(parsed, "error") AND isStruct(parsed.error) AND structKeyExists(parsed.error, "message")>
                            <cfset result.errorMessage = "HTTP " & result.statusCode & ": " & toString(parsed.error.message)>
                        </cfif>
                    </cfif>
                </cfif>
                <cfcatch type="any"></cfcatch>
            </cftry>

            <cfcatch type="any">
                <cfset endTick = getTickCount()>
                <cfset result.durationMs   = endTick - startTick>
                <cfset result.success      = false>
                <cfset result.statusCode   = 0>
                <cfset result.errorMessage = "cfhttp threw: " & cfcatch.message & " | " & cfcatch.detail>
            </cfcatch>
        </cftry>

        <cftry>
            <cfset result.logId = logUsage(
                purpose            = arguments.purpose,
                endpointURL        = effectiveEndpoint,
                modelName          = effectiveModel,
                requestSizeBytes   = len(jsonBody),
                responseSizeBytes  = responseSize,
                promptTokens       = result.usage.prompt_tokens,
                completionTokens   = "",
                reasoningTokens    = "",
                totalTokens        = result.usage.total_tokens,
                durationMs         = result.durationMs,
                httpStatusCode     = result.statusCode,
                finishReason       = "",
                success            = result.success,
                errorMessage       = result.errorMessage
            )>
            <cfcatch type="any">
                <cfset result.logId = 0>
            </cfcatch>
        </cftry>

        <cfreturn result>
    </cffunction>


    <!---
        callEmbeddingsBatch
        -------------------
        Like callEmbeddings, but embeds an ARRAY of input strings in a single
        Azure call (the embeddings endpoint accepts an "input" array). This is
        the throughput path used by ingestion: one HTTP round-trip per batch
        instead of per chunk, which all but eliminates 429 throttling on big
        repos.

        Returns a struct:
            success      - boolean (HTTP 200 AND a vector for every input)
            statusCode   - HTTP status code
            vectors      - array of float arrays, aligned to arguments.inputs by
                           position (data[].index). Empty on failure.
            count        - number of vectors returned
            usage        - { prompt_tokens, total_tokens }
            errorMessage - populated on failure
            durationMs   - duration of the cfhttp call
            logId        - ai_usage_log PK (0 if logging failed)
            attempts     - number of HTTP attempts (>1 means it retried 429/503)
    --->
    <cffunction name="callEmbeddingsBatch" access="public" returntype="struct" output="false">
        <cfargument name="inputs"      type="array"   required="true">
        <cfargument name="purpose"     type="string"  required="false" default="embedding_batch">
        <cfargument name="endpointURL" type="string"  required="false" default="">
        <cfargument name="apiKey"      type="string"  required="false" default="">
        <cfargument name="modelName"   type="string"  required="false" default="">
        <cfargument name="timeout"     type="numeric" required="false" default="120">
        <cfargument name="maxRetries"  type="numeric" required="false" default="5">

        <cfset var result = {
            "success"      = false,
            "statusCode"   = 0,
            "vectors"      = [],
            "count"        = 0,
            "usage"        = { "prompt_tokens" = "", "total_tokens" = "" },
            "errorMessage" = "",
            "durationMs"   = 0,
            "logId"        = 0,
            "attempts"     = 0
        }>
        <cfset var httpResult = "">
        <cfset var startTick = getTickCount()>
        <cfset var endTick = startTick>
        <cfset var parsed = {}>
        <cfset var jsonBody = serializeJSON({ "input" = arguments.inputs })>
        <cfset var responseSize = 0>
        <cfset var attempt = 0>
        <cfset var retryAfter = "">
        <cfset var waitMs = 0>
        <cfset var effectiveEndpoint = len(arguments.endpointURL) ? arguments.endpointURL : (isDefined("request.openAI_embeddingEndpoint") ? request.openAI_embeddingEndpoint : "")>
        <cfset var effectiveApiKey   = len(arguments.apiKey)      ? arguments.apiKey      : (isDefined("request.openAI_apiKey")              ? request.openAI_apiKey            : "")>
        <cfset var effectiveModel    = len(arguments.modelName)   ? arguments.modelName   : (isDefined("request.openAI_embeddingModel")      ? request.openAI_embeddingModel    : "")>
        <cfset var fileContent = "">
        <cfset var item = "">
        <cfset var idx = 0>
        <cfset var n = arrayLen(arguments.inputs)>
        <cfset var i = 0>

        <cfif n eq 0>
            <cfset result.success = true>
            <cfreturn result>
        </cfif>

        <!--- pre-size the output so we can place each embedding by its index --->
        <cfloop from="1" to="#n#" index="i">
            <cfset arrayAppend(result.vectors, [])>
        </cfloop>

        <cftry>
            <!--- same 429/503 backoff as callEmbeddings: honour Retry-After,
                  else exponential backoff capped at 30s, up to maxRetries. --->
            <cfloop condition="true">
                <cfset attempt++>
                <cfset startTick = getTickCount()>
                <cfhttp url="#effectiveEndpoint#"
                        method="POST"
                        timeout="#arguments.timeout#"
                        result="httpResult"
                        charset="utf-8">
                    <cfhttpparam type="header" name="api-key"      value="#effectiveApiKey#">
                    <cfhttpparam type="header" name="Content-Type" value="application/json">
                    <cfhttpparam type="body"   value="#jsonBody#">
                </cfhttp>
                <cfset endTick = getTickCount()>

                <cfset result.statusCode = val(httpResult.statusCode)>
                <cfset result.durationMs = endTick - startTick>
                <cfset result.attempts   = attempt>
                <cfset fileContent = isDefined("httpResult.fileContent") ? toString(httpResult.fileContent) : "">
                <cfset responseSize = len(fileContent)>

                <cfif (result.statusCode eq 429 OR result.statusCode eq 503) AND attempt lte arguments.maxRetries>
                    <cfset retryAfter = (isStruct(httpResult.responseHeader) AND structKeyExists(httpResult.responseHeader, "Retry-After")) ? httpResult.responseHeader["Retry-After"] : "">
                    <cfif isNumeric(retryAfter)>
                        <cfset waitMs = min(60, val(retryAfter)) * 1000>
                    <cfelse>
                        <cfset waitMs = min(30000, (2 ^ attempt) * 1000)>
                    </cfif>
                    <cfset sleep(waitMs)>
                    <cfcontinue>
                </cfif>
                <cfbreak>
            </cfloop>

            <cfif result.statusCode neq 200>
                <cfset result.errorMessage = "HTTP " & result.statusCode & ": " & left(fileContent, 1000)>
            </cfif>

            <cftry>
                <cfif len(trim(fileContent))>
                    <cfset parsed = deserializeJSON(fileContent)>
                    <cfif isStruct(parsed)>
                        <cfif structKeyExists(parsed, "data") AND isArray(parsed.data)>
                            <!--- place each embedding at its 0-based index+1; the
                                  API returns one data entry per input. --->
                            <cfloop array="#parsed.data#" index="item">
                                <cfif isStruct(item) AND structKeyExists(item, "embedding") AND isArray(item.embedding) AND arrayLen(item.embedding)>
                                    <cfset idx = structKeyExists(item, "index") ? (val(item.index) + 1) : 0>
                                    <cfif idx ge 1 AND idx le n>
                                        <cfset result.vectors[idx] = item.embedding>
                                    </cfif>
                                </cfif>
                            </cfloop>
                            <!--- success only if EVERY input got a non-empty vector --->
                            <cfset result.count = 0>
                            <cfloop from="1" to="#n#" index="i">
                                <cfif arrayLen(result.vectors[i])><cfset result.count++></cfif>
                            </cfloop>
                            <cfif result.statusCode eq 200 AND result.count eq n>
                                <cfset result.success = true>
                            </cfif>
                        </cfif>
                        <cfif structKeyExists(parsed, "usage") AND isStruct(parsed.usage)>
                            <cfif structKeyExists(parsed.usage, "prompt_tokens")>
                                <cfset result.usage.prompt_tokens = val(parsed.usage.prompt_tokens)>
                            </cfif>
                            <cfif structKeyExists(parsed.usage, "total_tokens")>
                                <cfset result.usage.total_tokens = val(parsed.usage.total_tokens)>
                            </cfif>
                        </cfif>
                        <cfif NOT result.success AND structKeyExists(parsed, "error") AND isStruct(parsed.error) AND structKeyExists(parsed.error, "message")>
                            <cfset result.errorMessage = "HTTP " & result.statusCode & ": " & toString(parsed.error.message)>
                        </cfif>
                    </cfif>
                </cfif>
                <cfcatch type="any"></cfcatch>
            </cftry>

            <cfcatch type="any">
                <cfset endTick = getTickCount()>
                <cfset result.durationMs   = endTick - startTick>
                <cfset result.success      = false>
                <cfset result.statusCode   = 0>
                <cfset result.errorMessage = "cfhttp threw: " & cfcatch.message & " | " & cfcatch.detail>
            </cfcatch>
        </cftry>

        <cftry>
            <cfset result.logId = logUsage(
                purpose            = arguments.purpose,
                endpointURL        = effectiveEndpoint,
                modelName          = effectiveModel,
                requestSizeBytes   = len(jsonBody),
                responseSizeBytes  = responseSize,
                promptTokens       = result.usage.prompt_tokens,
                completionTokens   = "",
                reasoningTokens    = "",
                totalTokens        = result.usage.total_tokens,
                durationMs         = result.durationMs,
                httpStatusCode     = result.statusCode,
                finishReason       = "",
                success            = result.success,
                errorMessage       = result.errorMessage
            )>
            <cfcatch type="any">
                <cfset result.logId = 0>
            </cfcatch>
        </cftry>

        <cfreturn result>
    </cffunction>


    <!---
        logUsage (private)
        ------------------
        Inserts one row into ai_usage_log on the configured datasource.
        Returns the inserted ai_usage_log_id (0 on failure).
    --->
    <cffunction name="logUsage" access="private" returntype="numeric" output="false">
        <cfargument name="purpose"           type="string"  required="true">
        <cfargument name="endpointURL"       type="string"  required="true">
        <cfargument name="modelName"         type="string"  required="false" default="">
        <cfargument name="requestSizeBytes"  type="numeric" required="true">
        <cfargument name="responseSizeBytes" type="numeric" required="true">
        <cfargument name="promptTokens"      type="any"     required="false" default="">
        <cfargument name="completionTokens"  type="any"     required="false" default="">
        <cfargument name="reasoningTokens"   type="any"     required="false" default="">
        <cfargument name="totalTokens"       type="any"     required="false" default="">
        <cfargument name="durationMs"        type="numeric" required="true">
        <cfargument name="httpStatusCode"    type="numeric" required="true">
        <cfargument name="finishReason"      type="string"  required="false" default="">
        <cfargument name="success"           type="boolean" required="true">
        <cfargument name="errorMessage"      type="string"  required="false" default="">

        <cfset var insertResult = "">
        <cfset var userId = 0>
        <cfset var userEmail = "">
        <cfset var sessionId = "">
        <cfset var callerTemplate = "">
        <cfset var remoteIp = "">
        <cfset var trimmedError = left(arguments.errorMessage, 2000)>
        <cfset var logId = 0>

        <cftry>
            <cfif isDefined("session.dd")>
                <cfif structKeyExists(session.dd, "userId")>
                    <cfset userId = val(session.dd.userId)>
                </cfif>
                <cfif structKeyExists(session.dd, "email")>
                    <cfset userEmail = toString(session.dd.email)>
                </cfif>
            </cfif>
            <cfcatch type="any"></cfcatch>
        </cftry>

        <cftry>
            <cfset sessionId = left(toString(session.sessionId), 100)>
            <cfcatch type="any"></cfcatch>
        </cftry>

        <cftry>
            <cfset callerTemplate = toString(CGI.SCRIPT_NAME)>
            <cfset remoteIp       = toString(CGI.REMOTE_ADDR)>
            <cfcatch type="any"></cfcatch>
        </cftry>

        <cfquery attributeCollection="#request.queryAttributes#" result="insertResult">
            insert into ai_usage_log (
                user_id, user_email, session_id, caller_template, purpose,
                endpoint_url, model_deployment_name, request_size_bytes, response_size_bytes,
                prompt_tokens, completion_tokens, reasoning_tokens, total_tokens,
                duration_ms, http_status_code, finish_reason, success, error_message, remote_ip
            ) values (
                <cfqueryparam cfsqltype="cf_sql_integer"  value="#userId#"             null="#(userId eq 0)#">,
                <cfqueryparam cfsqltype="cf_sql_nvarchar" value="#userEmail#"          maxlength="200"  null="#(NOT len(userEmail))#">,
                <cfqueryparam cfsqltype="cf_sql_varchar"  value="#sessionId#"          maxlength="100"  null="#(NOT len(sessionId))#">,
                <cfqueryparam cfsqltype="cf_sql_nvarchar" value="#callerTemplate#"     maxlength="500"  null="#(NOT len(callerTemplate))#">,
                <cfqueryparam cfsqltype="cf_sql_varchar"  value="#arguments.purpose#"  maxlength="100"  null="#(NOT len(arguments.purpose))#">,
                <cfqueryparam cfsqltype="cf_sql_nvarchar" value="#arguments.endpointURL#" maxlength="500" null="#(NOT len(arguments.endpointURL))#">,
                <cfqueryparam cfsqltype="cf_sql_varchar"  value="#arguments.modelName#" maxlength="100" null="#(NOT len(arguments.modelName))#">,
                <cfqueryparam cfsqltype="cf_sql_integer"  value="#arguments.requestSizeBytes#"  null="false">,
                <cfqueryparam cfsqltype="cf_sql_integer"  value="#arguments.responseSizeBytes#" null="false">,
                <cfqueryparam cfsqltype="cf_sql_integer"  value="#val(arguments.promptTokens)#"     null="#(NOT len(arguments.promptTokens) OR NOT isNumeric(arguments.promptTokens))#">,
                <cfqueryparam cfsqltype="cf_sql_integer"  value="#val(arguments.completionTokens)#" null="#(NOT len(arguments.completionTokens) OR NOT isNumeric(arguments.completionTokens))#">,
                <cfqueryparam cfsqltype="cf_sql_integer"  value="#val(arguments.reasoningTokens)#"  null="#(NOT len(arguments.reasoningTokens) OR NOT isNumeric(arguments.reasoningTokens))#">,
                <cfqueryparam cfsqltype="cf_sql_integer"  value="#val(arguments.totalTokens)#"      null="#(NOT len(arguments.totalTokens) OR NOT isNumeric(arguments.totalTokens))#">,
                <cfqueryparam cfsqltype="cf_sql_integer"  value="#arguments.durationMs#"     null="false">,
                <cfqueryparam cfsqltype="cf_sql_integer"  value="#arguments.httpStatusCode#" null="false">,
                <cfqueryparam cfsqltype="cf_sql_varchar"  value="#arguments.finishReason#"   maxlength="50" null="#(NOT len(arguments.finishReason))#">,
                <cfqueryparam cfsqltype="cf_sql_bit"      value="#(arguments.success ? 1 : 0)#">,
                <cfqueryparam cfsqltype="cf_sql_nvarchar" value="#trimmedError#"             maxlength="2000" null="#(NOT len(trimmedError))#">,
                <cfqueryparam cfsqltype="cf_sql_varchar"  value="#remoteIp#"                 maxlength="50" null="#(NOT len(remoteIp))#">
            )
        </cfquery>

        <cfif isStruct(insertResult) AND structKeyExists(insertResult, "generatedKey")>
            <cfset logId = val(insertResult.generatedKey)>
        <cfelseif isStruct(insertResult) AND structKeyExists(insertResult, "GENERATED_KEY")>
            <cfset logId = val(insertResult["GENERATED_KEY"])>
        <cfelseif isStruct(insertResult) AND structKeyExists(insertResult, "IDENTITYCOL")>
            <cfset logId = val(insertResult.IDENTITYCOL)>
        </cfif>

        <cfreturn logId>
    </cffunction>

</cfcomponent>
