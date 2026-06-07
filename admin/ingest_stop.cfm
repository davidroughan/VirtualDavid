<!--- Signal a running ingest to stop after its current file. --->
<cfcontent type="application/json; charset=utf-8">
<cfparam name="url.repoId" default="0">
<cfset resp = { "ok" = true, "signaled" = false }>
<cftry>
    <cfset ingestor = createObject("component", "cfcs.Ingestor").init()>
    <cfset resp.signaled = ingestor.requestStop(val(url.repoId))>
    <cfcatch type="any">
        <cfset resp = { "ok" = false, "signaled" = false, "message" = cfcatch.message }>
    </cfcatch>
</cftry>
<cfoutput>#serializeJSON(resp)#</cfoutput>
