<!--- Thin endpoint: take a question, return Virtual David's answer as JSON. --->
<cfcontent type="application/json; charset=utf-8">
<cfparam name="form.message" default="">
<cfset response = { "ok" = false, "answer" = "", "sources" = [], "error" = "" }>

<cftry>
    <cfif NOT len(trim(form.message))>
        <cfset response.error = "Ask a question about the code.">
    <cfelse>
        <cfset rag = createObject("component", "cfcs.RAG").init()>
        <cfset result = rag.answer(question = trim(form.message))>
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
