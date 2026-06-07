<!--- Live status for a repo's ingest, for the admin poller. Live job struct if
      one is running, else the last recorded run from ingest_runs. --->
<cfcontent type="application/json; charset=utf-8">
<cfparam name="url.repoId" default="0">
<cfset resp = { "found" = false }>
<cftry>
    <cfset ingestor = createObject("component", "cfcs.Ingestor").init()>
    <cfset resp = ingestor.getRunStatus(val(url.repoId))>
    <cfcatch type="any">
        <cfset resp = { "found" = false, "error" = cfcatch.message }>
    </cfcatch>
</cftry>
<cfoutput>#serializeJSON(resp)#</cfoutput>
