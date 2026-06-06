<cfcomponent displayname="PromptStore" output="false"
    hint="Reads and writes editable prompts (e.g. the RAG persona) from the system_prompts table. Keyed so several named prompts can coexist. Lets the prod 'ask' module get the persona straight from the shared DB - no SystemPrompt.txt on disk.">

    <!--- The key the RAG persona lives under. --->
    <cfset variables.personaKey = "rag_persona">

    <!--- Last-resort persona if the row is missing (e.g. table not seeded).
          Kept identical to RAG.cfc's historical inline fallback. --->
    <cfset variables.fallback = "You are Virtual David, an Australian ColdFusion/JavaScript developer. Be direct, concise and practical.">

    <cffunction name="getPersonaKey" access="public" returntype="string" output="false">
        <cfreturn variables.personaKey>
    </cffunction>

    <!--- Return the prompt text for a key, or the hardcoded fallback if the row
          is absent or anything goes wrong. Never throws - the ask path must
          degrade gracefully rather than fail on a missing prompt. --->
    <cffunction name="getContent" access="public" returntype="string" output="false">
        <cfargument name="key" type="string" required="false" default="#variables.personaKey#">
        <cfset var rec = getRecord(arguments.key)>
        <cfreturn (rec.exists AND len(trim(rec.content))) ? rec.content : variables.fallback>
    </cffunction>

    <!--- Full record for admin display: { exists, content, updatedAt }. --->
    <cffunction name="getRecord" access="public" returntype="struct" output="false">
        <cfargument name="key" type="string" required="false" default="#variables.personaKey#">
        <cfset var rows = "">
        <cfset var out = { "exists" = false, "content" = "", "updatedAt" = "" }>
        <cftry>
            <cfquery name="rows" attributeCollection="#request.queryAttributes#">
                select content, updated_at
                from system_prompts
                where prompt_key = <cfqueryparam cfsqltype="cf_sql_varchar" value="#arguments.key#" maxlength="100">
            </cfquery>
            <cfif rows.recordCount>
                <cfset out.exists = true>
                <cfset out.content = rows.content>
                <cfset out.updatedAt = rows.updated_at>
            </cfif>
            <cfcatch type="any"></cfcatch>
        </cftry>
        <cfreturn out>
    </cffunction>

    <!--- Upsert the prompt text for a key. Updates in place if present, else
          inserts. updatedBy is optional (no auth in the admin pages today). --->
    <cffunction name="save" access="public" returntype="void" output="false">
        <cfargument name="content"   type="string" required="true">
        <cfargument name="key"       type="string" required="false" default="#variables.personaKey#">
        <cfargument name="updatedBy" type="string" required="false" default="">

        <cfset var upd = "">
        <cfquery attributeCollection="#request.queryAttributes#" result="upd">
            update system_prompts
            set content = <cfqueryparam cfsqltype="cf_sql_longvarchar" value="#arguments.content#">,
                updated_at = getDate(),
                updated_by = <cfqueryparam cfsqltype="cf_sql_varchar" value="#arguments.updatedBy#" maxlength="100" null="#(NOT len(arguments.updatedBy))#">
            where prompt_key = <cfqueryparam cfsqltype="cf_sql_varchar" value="#arguments.key#" maxlength="100">
        </cfquery>

        <cfif (isStruct(upd) AND structKeyExists(upd, "recordCount") AND upd.recordCount eq 0)>
            <cfquery attributeCollection="#request.queryAttributes#">
                insert into system_prompts (prompt_key, content, updated_by)
                values (
                    <cfqueryparam cfsqltype="cf_sql_varchar" value="#arguments.key#" maxlength="100">,
                    <cfqueryparam cfsqltype="cf_sql_longvarchar" value="#arguments.content#">,
                    <cfqueryparam cfsqltype="cf_sql_varchar" value="#arguments.updatedBy#" maxlength="100" null="#(NOT len(arguments.updatedBy))#">
                )
            </cfquery>
        </cfif>
    </cffunction>

</cfcomponent>
