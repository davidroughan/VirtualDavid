<!--- Thin endpoint: take a question, return Virtual David's answer as JSON. --->
<cfsetting requesttimeout="300">
<cfcontent type="application/json; charset=utf-8">
<cfparam name="form.message" default="">
<cfparam name="form.history" default="[]">
<cfset response = { "ok" = false, "answer" = "", "sources" = [], "error" = "" }>

<cftry>
    <cfif NOT len(trim(form.message))>
        <cfset response.error = "Ask a question about the code.">
    <cfelse>
        <!--- history is the prior conversation as a JSON array of {role,content};
              RAG sanitises it, so a malformed value just degrades to no history. --->
        <cfset history = []>
        <cftry>
            <cfif len(trim(form.history)) AND isJSON(form.history)>
                <cfset history = deserializeJSON(form.history)>
            </cfif>
            <cfcatch type="any"><cfset history = []></cfcatch>
        </cftry>
        <cfif NOT isArray(history)><cfset history = []></cfif>

        <cfset rag = createObject("component", "cfcs.RAG").init()>
        <cfset result = rag.answer(question = trim(form.message), history = history)>
        <cfif result.success>
            <cfset response.ok = true>
            <cfset response.answer = result.answer>
            <cfset response.sources = result.sources>
        <cfelse>
            <cfset response.error = result.error>
        </cfif>
    </cfif>
    <cfcatch type="any">
        <cfset response.error = "Server error: " & cfcatch.message>
    </cfcatch>
</cftry>

<cfoutput>#serializeJSON(response)#</cfoutput>
