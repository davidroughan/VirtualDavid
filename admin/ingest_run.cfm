<!--- Runs an ingest to completion (or until its internal max-run / stop).
      Called via fetch() from the admin page so it's detached from the page view -
      closing the tab doesn't stop it. Returns a JSON summary when it finishes. --->
<cfset maxRun = (structKeyExists(request, "ingest") AND structKeyExists(request.ingest, "maxRunSeconds") AND val(request.ingest.maxRunSeconds) gt 0) ? val(request.ingest.maxRunSeconds) : 14400>
<cfsetting requesttimeout="#maxRun + 300#">
<cfcontent type="application/json; charset=utf-8">
<cfparam name="url.repoId" default="0">

<cfset resp = { "ok" = false, "message" = "" }>
<cftry>
    <cfif val(url.repoId) eq 0>
        <cfthrow message="repoId is required.">
    </cfif>
    <cfset ingestor = createObject("component", "cfcs.Ingestor").init()>
    <cfif ingestor.isRunningNow(val(url.repoId))>
        <cfset resp.message = "An ingest is already running for this repo.">
    <cfelse>
        <cfset summary = ingestor.ingestRepo(repoId = val(url.repoId))>
        <cfset resp.ok = true>
        <cfset resp.message = "Run finished: " & summary.status & ".">
        <cfset resp.summary = summary>
    </cfif>
    <cfcatch type="any">
        <cfset resp.message = "Error: " & cfcatch.message>
    </cfcatch>
</cftry>
<cfoutput>#serializeJSON(resp)#</cfoutput>
