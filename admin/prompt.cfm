<cfsetting requesttimeout="120">
<!--- Edit Virtual David's system prompt (the RAG persona), stored in the DB. --->
<cfparam name="form.action" default="">
<cfset store = createObject("component", "cfcs.PromptStore")>
<cfset notice = "">
<cfset noticeClass = "ok">

<cftry>
    <cfif form.action eq "save">
        <cfparam name="form.content" default="">
        <cfif NOT len(trim(form.content))>
            <cfset notice = "Prompt can't be empty.">
            <cfset noticeClass = "err">
        <cfelse>
            <cfset store.save(content = form.content, updatedBy = left(toString(CGI.REMOTE_ADDR), 100))>
            <cfset notice = "Saved. Virtual David will use this on the next question.">
        </cfif>
    </cfif>
    <cfcatch type="any">
        <cfset notice = "Error: " & cfcatch.message & (len(cfcatch.detail) ? " — " & cfcatch.detail : "")>
        <cfset noticeClass = "err">
    </cfcatch>
</cftry>

<cfset rec = store.getRecord()>

<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Virtual David — System prompt</title>
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
    .panel { background:var(--panel); border:1px solid var(--line); border-radius:10px; padding:18px 20px; }
    .panel h2 { font-size:15px; margin:0 0 4px; }
    .meta { color:var(--muted); font-size:12px; margin:0 0 14px; }
    textarea { width:100%; min-height:560px; background:#1b1b1b; color:var(--ink); border:1px solid var(--line);
               border-radius:7px; padding:12px 14px; font:13px/1.55 Consolas,monospace; resize:vertical; }
    button { background:var(--accent); color:#fff; border:0; border-radius:7px; padding:9px 16px;
             font:inherit; font-weight:600; cursor:pointer; margin-top:14px; }
    .muted { color:var(--muted); }
</style>
</head>
<body>
<cfoutput>
<div class="wrap">
    <h1>System prompt</h1>
    <p class="sub">Virtual David's persona — used to ground every answer. &middot;
        <a href="ingest.cfm">repos</a> &middot; <a href="test.cfm">smoke test</a> &middot; <a href="../index.cfm">back to ask</a></p>

    <cfif len(notice)>
        <div class="notice #noticeClass#">#encodeForHTML(notice)#</div>
    </cfif>

    <div class="panel">
        <h2>Edit prompt</h2>
        <p class="meta">
            <cfif rec.exists>Last updated #dateFormat(rec.updatedAt, "yyyy-mm-dd")# #timeFormat(rec.updatedAt, "HH:mm")#<cfelse>Not saved yet — showing the built-in fallback.</cfif>
        </p>
        <form method="post">
            <input type="hidden" name="action" value="save">
            <textarea name="content" spellcheck="false">#encodeForHTML(rec.exists ? rec.content : store.getContent())#</textarea>
            <div><button type="submit">Save prompt</button></div>
        </form>
    </div>
</div>
</cfoutput>
</body>
</html>
