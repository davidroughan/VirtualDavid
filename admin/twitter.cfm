<cfsetting requesttimeout="1800">
<!--- Twitter/X archive ingest: turns an unzipped account export into retrievable
      tweet chunks so Virtual David can answer as David beyond the code. Reads
      tweets.js from the archive's data/ folder. Separate from ingest.cfm and
      emails.cfm. --->
<cfparam name="form.action" default="">

<cfset twitterDir = request.appRoot & "twitter">
<cfset notice      = "">
<cfset noticeClass = "ok">
<cfset summary     = "">

<cftry>
    <cfif form.action eq "ingest" OR form.action eq "reingest">
        <cfset ingestor = createObject("component", "cfcs.TwitterIngestor").init()>
        <cfset summary = ingestor.ingestArchive(dir = twitterDir, force = (form.action eq "reingest"))>
        <cfset notice = "Ingest complete. Kept " & summary.tweetsKept & " of " & summary.tweetsSeen
            & " tweet(s); " & summary.chunksWritten & " chunk(s) written from " & summary.ingested
            & " file(s) (" & summary.skipped & " unchanged).">
    </cfif>

    <cfcatch type="any">
        <cfset notice = "Error: " & cfcatch.message & (len(cfcatch.detail) ? " — " & cfcatch.detail : "")>
        <cfset noticeClass = "err">
    </cfcatch>
</cftry>

<!--- quick view of what's on disk --->
<cfset dataDir = twitterDir & "\data">
<cfset hasArchive = fileExists(dataDir & "\tweets.js") OR fileExists(twitterDir & "\tweets.js")>

<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Virtual David — Twitter</title>
<style>
    :root { --bg:#1e1e1e; --panel:#252526; --ink:#e6e6e6; --muted:#9aa0a6; --accent:#2c95b2; --line:#3a3a3a; }
    * { box-sizing:border-box; }
    body { margin:0; background:var(--bg); color:var(--ink); font:14px/1.5 -apple-system,Segoe UI,Roboto,sans-serif; }
    .wrap { max-width:1000px; margin:0 auto; padding:26px 18px 80px; }
    h1 { font-size:19px; margin:0 0 4px; }
    .sub { color:var(--muted); margin:0 0 22px; font-size:13px; }
    .sub a { color:var(--accent); }
    .notice { padding:10px 14px; border-radius:8px; margin-bottom:18px; background:#1f3a2a; border:1px solid #2f6b46; }
    .notice.err { background:#3a1f25; border-color:#7a2330; }
    code { color:var(--accent); }
    .panel { background:var(--panel); border:1px solid var(--line); border-radius:10px; padding:16px 18px; margin-bottom:18px; }
    .panel h2 { font-size:15px; margin:0 0 12px; }
    button, .btn { background:var(--accent); color:#fff; border:0; border-radius:7px; padding:7px 13px;
             font:inherit; font-weight:600; cursor:pointer; text-decoration:none; display:inline-block; }
    button.secondary, .btn.secondary { background:#3a3a3a; }
    .mono { font-family:Consolas,monospace; font-size:12.5px; background:#1b1b1b; border:1px solid var(--line);
            border-radius:8px; padding:12px 14px; white-space:pre-wrap; word-break:break-word; }
    .muted { color:var(--muted); }
</style>
</head>
<body>
<cfoutput>
<div class="wrap">
    <h1>Twitter / X archive</h1>
    <p class="sub">Ingest David's tweet history so he can answer as himself beyond the code. &middot;
        <a href="ingest.cfm">repos</a> &middot; <a href="emails.cfm">emails</a> &middot; <a href="prompt.cfm">system prompt</a> &middot; <a href="../index.cfm">ask</a></p>

    <cfif len(notice)>
        <div class="notice #noticeClass#">#encodeForHTML(notice)#</div>
    </cfif>

    <cfif isStruct(summary)>
        <div class="mono">Handle: @#encodeForHTML(summary.handle)#  |  Tweets seen: #summary.tweetsSeen#  |  Tweets kept: #summary.tweetsKept#  |  Files ingested: #summary.ingested#  |  Skipped (unchanged): #summary.skipped#  |  Chunks written: #summary.chunksWritten#<cfif arrayLen(summary.errors)>

Errors (#arrayLen(summary.errors)#):
<cfloop array="#summary.errors#" index="e">  - #encodeForHTML(e)#
</cfloop></cfif></div>
    </cfif>

    <div class="panel">
        <h2>Archive at <code>#encodeForHTML(twitterDir)#</code></h2>
        <cfif NOT hasArchive>
            <p class="muted">No <code>tweets.js</code> found. Unzip your Twitter/X export so that
                <code>#encodeForHTML(twitterDir)#\data\tweets.js</code> exists, then ingest.</p>
        <cfelse>
            <p class="muted" style="margin-top:0">Found <code>tweets.js</code>. Ingest drops retweets, strips reply
                handles and links, and embeds one chunk per remaining tweet. Retweets and tweets that are empty/too
                short after cleaning are skipped.</p>
            <form method="post" style="margin:0;display:inline-block" onsubmit="this.querySelector('button').disabled=true;this.querySelector('button').textContent='Working…';">
                <input type="hidden" name="action" value="ingest">
                <button type="submit">Ingest</button>
                <span class="muted" style="margin-left:8px">Unchanged files are skipped.</span>
            </form>
            <form method="post" style="margin:10px 0 0" onsubmit="this.querySelector('button').disabled=true;this.querySelector('button').textContent='Working…';">
                <input type="hidden" name="action" value="reingest">
                <button type="submit" class="secondary">Force re-ingest</button>
                <span class="muted" style="margin-left:8px">Re-embeds every tweet even if the file is unchanged.</span>
            </form>
        </cfif>
    </div>
</div>
</cfoutput>
</body>
</html>
