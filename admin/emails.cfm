<cfsetting requesttimeout="1800">
<!--- Email reader: preview the parse of a saved .eml/.msg (headers, reply chain,
      attachments, cleaned text), optionally run the LLM ticket segmentation, and
      ingest David's guidance into the vector store. Separate from ingest.cfm. --->
<cfparam name="form.action" default="">
<cfparam name="url.file"    default="">
<cfparam name="url.segment" default="0">

<cfset emailsDir = request.appRoot & "emails">
<cfset reader    = createObject("component", "cfcs.EmailReader").init()>
<cfset notice    = "">
<cfset noticeClass = "ok">
<cfset summary   = "">
<cfset preview   = "">
<cfset seg       = "">

<cftry>
    <cfif form.action eq "ingestAll">
        <cfset ingestor = createObject("component", "cfcs.EmailIngestor").init()>
        <cfset summary = ingestor.ingestFolder(dir = emailsDir)>
        <cfset notice = "Ingest complete. Ingested " & summary.ingested & " of " & summary.scanned
            & " file(s), " & summary.chunksWritten & " chunk(s) from " & summary.ticketsFound & " ticket(s) with guidance.">

    <cfelseif form.action eq "ingestOne">
        <cfparam name="form.file" default="">
        <cfset ingestor = createObject("component", "cfcs.EmailIngestor").init()>
        <cfset repoId = ingestor.ensureEmailRepo(localPath = emailsDir)>
        <cfset one = ingestor.ingestFile(repoId = repoId, path = emailsDir & "\" & getFileFromPath(form.file), force = true)>
        <cfset notice = one.skipped
            ? ("Unchanged since last ingest — skipped. (" & encodeForHTML(one.subject) & ")")
            : ("Ingested “" & encodeForHTML(one.subject) & "” — " & one.chunksWritten & " chunk(s) from " & one.ticketsFound & " ticket(s).")>
    </cfif>

    <cfcatch type="any">
        <cfset notice = "Error: " & cfcatch.message & (len(cfcatch.detail) ? " — " & cfcatch.detail : "")>
        <cfset noticeClass = "err">
    </cfcatch>
</cftry>

<!--- folder listing --->
<cfset files = "">
<cfif directoryExists(emailsDir)>
    <cfdirectory action="list" directory="#emailsDir#" name="files" type="file" filter="*.eml|*.msg" sort="name asc">
</cfif>

<!--- preview the selected file --->
<cfif len(url.file)>
    <cftry>
        <cfset preview = reader.readFile(path = emailsDir & "\" & getFileFromPath(url.file))>
        <cfif preview.success AND url.segment eq "1">
            <cfset ingestor = isDefined("ingestor") ? ingestor : createObject("component", "cfcs.EmailIngestor").init()>
            <cfset seg = ingestor.segmentTickets(parsed = preview)>
        </cfif>
        <cfcatch type="any">
            <cfset notice = "Preview/segment error: " & cfcatch.message>
            <cfset noticeClass = "err">
        </cfcatch>
    </cftry>
</cfif>

<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Virtual David — Emails</title>
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
    table { width:100%; border-collapse:collapse; margin-bottom:24px; }
    th, td { text-align:left; padding:8px 10px; border-bottom:1px solid var(--line); vertical-align:top; }
    th { color:var(--muted); font-weight:600; font-size:12px; text-transform:uppercase; letter-spacing:.04em; }
    code { color:var(--accent); }
    .panel { background:var(--panel); border:1px solid var(--line); border-radius:10px; padding:16px 18px; margin-bottom:18px; }
    .panel h2 { font-size:15px; margin:0 0 12px; }
    button, .btn { background:var(--accent); color:#fff; border:0; border-radius:7px; padding:7px 13px;
             font:inherit; font-weight:600; cursor:pointer; text-decoration:none; display:inline-block; }
    button.secondary, .btn.secondary { background:#3a3a3a; }
    .mono { font-family:Consolas,monospace; font-size:12.5px; background:#1b1b1b; border:1px solid var(--line);
            border-radius:8px; padding:12px 14px; white-space:pre-wrap; word-break:break-word; }
    .muted { color:var(--muted); }
    .kv { display:grid; grid-template-columns:120px 1fr; gap:4px 12px; font-size:13px; margin-bottom:6px; }
    .kv div:nth-child(odd){ color:var(--muted); }
    .seg { border-left:3px solid var(--line); padding:2px 0 2px 12px; margin:0 0 14px; }
    .seg.david { border-left-color:var(--accent); }
    .tag { font-size:11px; padding:1px 7px; border-radius:10px; background:#3a3a3a; color:var(--ink); }
    .tag.david { background:var(--accent); }
    .ticket { border:1px solid var(--line); border-radius:8px; padding:12px 14px; margin-bottom:12px; }
    .ticket h3 { font-size:13.5px; margin:0 0 8px; color:var(--accent); }
    .q { color:var(--muted); } .a { margin-top:6px; }
</style>
</head>
<body>
<cfoutput>
<div class="wrap">
    <h1>Emails</h1>
    <p class="sub">Read saved emails (.eml / .msg) and store David's guidance for retrieval. &middot;
        <a href="ingest.cfm">repos</a> &middot; <a href="prompt.cfm">system prompt</a> &middot; <a href="../index.cfm">ask</a></p>

    <cfif len(notice)>
        <div class="notice #noticeClass#">#encodeForHTML(notice)#</div>
    </cfif>

    <cfif isStruct(summary)>
        <div class="mono">Scanned: #summary.scanned#  |  Ingested: #summary.ingested#  |  Skipped (unchanged): #summary.skipped#  |  Tickets w/ guidance: #summary.ticketsFound#  |  Chunks written: #summary.chunksWritten#<cfif arrayLen(summary.errors)>

Errors (#arrayLen(summary.errors)#):
<cfloop array="#summary.errors#" index="e">  - #encodeForHTML(e)#
</cfloop></cfif></div>
    </cfif>

    <div class="panel">
        <h2>Saved emails in <code>#encodeForHTML(emailsDir)#</code></h2>
        <cfif NOT isQuery(files) OR files.recordCount eq 0>
            <p class="muted">No .eml or .msg files found. Drop one into the <code>emails</code> folder.</p>
        <cfelse>
            <table>
                <thead><tr><th>File</th><th>Size</th><th>Modified</th><th></th></tr></thead>
                <tbody>
                <cfloop query="files">
                    <tr>
                        <td><a href="?file=#encodeForURL(files.name)#">#encodeForHTML(files.name)#</a></td>
                        <td class="muted">#numberFormat(ceiling(files.size/1024))# KB</td>
                        <td class="muted">#dateFormat(files.dateLastModified, "yyyy-mm-dd")# #timeFormat(files.dateLastModified, "HH:mm")#</td>
                        <td>
                            <form method="post" style="margin:0" onsubmit="this.querySelector('button').disabled=true;this.querySelector('button').textContent='Working…';">
                                <input type="hidden" name="action" value="ingestOne">
                                <input type="hidden" name="file" value="#encodeForHTMLAttribute(files.name)#">
                                <button type="submit">Ingest</button>
                            </form>
                        </td>
                    </tr>
                </cfloop>
                </tbody>
            </table>
            <form method="post" style="margin:0" onsubmit="this.querySelector('button').disabled=true;this.querySelector('button').textContent='Working…';">
                <input type="hidden" name="action" value="ingestAll">
                <button type="submit">Ingest all</button>
                <span class="muted" style="margin-left:8px">Re-runs the chat model per email; unchanged files are skipped.</span>
            </form>
        </cfif>
    </div>

    <cfif isStruct(preview) AND structCount(preview)>
        <cfif NOT preview.success>
            <div class="notice err">Parse failed: #encodeForHTML(preview.error)#</div>
        <cfelse>
            <div class="panel">
                <h2>Parsed: #encodeForHTML(getFileFromPath(url.file))# <span class="tag">#preview.format#</span></h2>
                <div class="kv">
                    <div>Subject</div><div>#encodeForHTML(preview.headers.subject)#</div>
                    <div>From</div><div>#encodeForHTML(preview.headers.from)#</div>
                    <div>To</div><div>#encodeForHTML(preview.headers.to)#</div>
                    <div>Date</div><div>#encodeForHTML(preview.headers.date)#</div>
                </div>
                <p style="margin:12px 0 0">
                    <a class="btn secondary" href="?file=#encodeForURL(getFileFromPath(url.file))#&segment=1">Run ticket segmentation (LLM)</a>
                </p>
            </div>

            <cfif arrayLen(preview.attachments)>
                <div class="panel">
                    <h2>Attachments (#arrayLen(preview.attachments)#)</h2>
                    <table>
                        <thead><tr><th>Filename</th><th>Type</th><th>Disposition</th><th>~Size</th></tr></thead>
                        <tbody>
                        <cfloop array="#preview.attachments#" index="att">
                            <tr>
                                <td>#encodeForHTML(att.filename)#</td>
                                <td class="muted">#encodeForHTML(att.contentType)#</td>
                                <td class="muted">#encodeForHTML(att.disposition)#</td>
                                <td class="muted">#numberFormat(ceiling(att.bytes/1024))# KB</td>
                            </tr>
                        </cfloop>
                        </tbody>
                    </table>
                </div>
            </cfif>

            <div class="panel">
                <h2>Reply / forward chain (#arrayLen(preview.chain)# message#arrayLen(preview.chain) neq 1 ? "s" : ""#)</h2>
                <p class="muted" style="margin-top:-6px">Outermost first; the innermost message is where David's inline answers live.</p>
                <cfloop array="#preview.chain#" index="m">
                    <div class="seg #m.isDavid ? 'david' : ''#">
                        <div class="kv" style="margin-bottom:8px">
                            <div>From</div><div>#encodeForHTML(m.from)# <cfif m.isDavid><span class="tag david">David</span></cfif></div>
                            <cfif len(m.sent)><div>Sent</div><div>#encodeForHTML(m.sent)#</div></cfif>
                            <cfif len(m.subject)><div>Subject</div><div>#encodeForHTML(m.subject)#</div></cfif>
                        </div>
                        <div class="mono">#encodeForHTML(m.body)#</div>
                    </div>
                </cfloop>
            </div>

            <cfif isStruct(seg) AND structCount(seg)>
                <div class="panel">
                    <h2>Ticket segmentation — #arrayLen(seg.tickets)# ticket(s)</h2>
                    <p class="muted" style="margin-top:-6px">From #encodeForHTML(seg.devName)#. Only tickets with a David answer are stored on ingest.</p>
                    <cfloop array="#seg.tickets#" index="t">
                        <div class="ticket">
                            <h3>#encodeForHTML(t.ref)# <cfif NOT t.has_david_answer><span class="tag">no David answer</span></cfif></h3>
                            <div class="q"><strong>Q:</strong> #encodeForHTML(t.dev_question)#</div>
                            <cfif len(t.david_answer)><div class="a"><strong>David:</strong> #encodeForHTML(t.david_answer)#</div></cfif>
                            <cfif arrayLen(t.files_referenced)><div class="muted" style="margin-top:6px">Files: <code>#encodeForHTML(arrayToList(t.files_referenced, ", "))#</code></div></cfif>
                        </div>
                    </cfloop>
                </div>
            </cfif>
        </cfif>
    </cfif>
</div>
</cfoutput>
</body>
</html>
