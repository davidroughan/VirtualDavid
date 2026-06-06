<cfcomponent output="false">

    <cfset this.name = "VirtualDavid">
    <cfset this.applicationTimeout = createTimeSpan(7, 0, 0, 0)>
    <cfset this.sessionManagement = true>
    <cfset this.sessionTimeout = createTimeSpan(0, 2, 0, 0)>
    <cfset this.setClientCookies = true>

    <!--- App folder, resolved regardless of where the site is mounted under IIS.
          "/config.cfm" would resolve to the IIS site root, not this app, so we
          map the app root (/vd) and the cfc folder (/cfcs) explicitly. --->
    <cfset this.appDir = getDirectoryFromPath(getCurrentTemplatePath())>
    <cfset this.mappings["/vd"]   = this.appDir>
    <cfset this.mappings["/cfcs"] = this.appDir & "cfcs">

    <cffunction name="onRequestStart" returntype="boolean" output="false">
        <cfargument name="targetPage" type="string" required="true">

        <!--- Absolute path to the app root for non-mapping consumers (file reads). --->
        <cfset request.appRoot = getDirectoryFromPath(getCurrentTemplatePath())>

        <!--- Load configuration into the request scope (via the /vd app mapping). --->
        <cfinclude template="/vd/config.cfm">

        <!--- Build the queryAttributes struct the same way Lucinda does, so the
              copied AzureOpenAI.cfc logging code works unchanged. --->
        <cfset request.queryAttributes = { datasource = request.dsn }>
        <cfif structKeyExists(request, "dsnUsername") AND len(request.dsnUsername)>
            <cfset request.queryAttributes.username = request.dsnUsername>
        </cfif>
        <cfif structKeyExists(request, "dsnPassword") AND len(request.dsnPassword)>
            <cfset request.queryAttributes.password = request.dsnPassword>
        </cfif>

        <cfreturn true>
    </cffunction>

</cfcomponent>
