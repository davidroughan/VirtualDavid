<cfsetting requesttimeout="3600">
<!--- Repo management + manual ingestion trigger for Virtual David. --->
<cfparam name="form.action" default="">
<cfset ingestor = createObject("component", "cfcs.Ingestor").init()>
<cfset notice = "">
<cfset noticeClass = "ok">
<cfset summary = "">

<cftry>
    <cfif form.action eq "addRepo">
        <cfparam name="form.name" default="">
        <cfparam name="form.local_path" default="">
        <cfparam name="form.extensions" default="">
        <cfparam name="form.exclude_patterns" default="">
        <cfif NOT len(trim(form.name)) OR NOT len(trim(form.local_path))>
            <cfset notice = "Name and path are both required.">
            <cfset noticeClass = "err">
        <cfelse>
            <cfset addArgs = { name = trim(form.name), localPath = trim(form.local_path), extensions = trim(form.extensions) }>
            <cfif len(trim(form.exclude_patterns))>
                <cfset addArgs.exclude = trim(form.exclude_patterns)>
            </cfif>
            <cfset newId = ingestor.addRepo(argumentCollection = addArgs)>
            <cfset notice = "Added repo ##" & newId & ". Hit Ingest to vectorise it.">
        </cfif>

    <cfelseif form.action eq "setExcludes">
        <cfparam name="form.repoId" default="0">
        <cfparam name="form.exclude_patterns" default="">
        <cfset ingestor.setExcludes(repoId = val(form.repoId), patterns = form.exclude_patterns)>
        <cfset notice = "Updated excludes for repo ##" & val(form.repoId) & ". Re-ingest to apply (already-indexed excluded files will be removed).">

    <cfelseif form.action eq "purge">
        <cfparam name="form.repoId" default="0">
        <cfset purged = ingestor.purgeRepo(repoId = val(form.repoId))>
        <cfset notice = "Reset repo ##" & val(form.repoId) & " — deleted " & purged.chunksDeleted & " chunk(s) and " & purged.filesDeleted & " file row(s). Ingest to rebuild from zero.">

    <cfelseif form.action eq "deleteRepo">
        <cfparam name="form.repoId" default="0">
        <cfif ingestor.isRunningNow(val(form.repoId))>
            <cfset notice = "Can't delete repo ##" & val(form.repoId) & " while an ingest is running — Stop it first.">
            <cfset noticeClass = "err">
        <cfelse>
            <cfset ingestor.deleteRepo(repoId = val(form.repoId))>
            <cfset notice = "Deleted repo ##" & val(form.repoId) & " and all its data.">
        </cfif>
    </cfif>

    <cfcatch type="any">
        <cfset notice = "Error: " & cfcatch.message & (len(cfcatch.detail) ? " — " & cfcatch.detail : "")>
        <cfset noticeClass = "err">
    </cfcatch>
</cftry>

<cfset repos = ingestor.getRepos()>

<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Virtual David — Repos</title>
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
    table { width:100%; border-collapse:collapse; margin-bottom:30px; }
    th, td { text-align:left; padding:9px 10px; border-bottom:1px solid var(--line); vertical-align:top; }
    th { color:var(--muted); font-weight:600; font-size:12px; text-transform:uppercase; letter-spacing:.04em; }
    code { color:var(--accent); }
    .panel { background:var(--panel); border:1px solid var(--line); border-radius:10px; padding:18px 20px; }
    .panel h2 { font-size:15px; margin:0 0 14px; }
    label { display:block; font-size:12px; color:var(--muted); margin:12px 0 4px; }
    input[type=text] { width:100%; background:#1b1b1b; color:var(--ink); border:1px solid var(--line);
                       border-radius:7px; padding:9px 11px; font:inherit; }
    button { background:var(--accent); color:#fff; border:0; border-radius:7px; padding:9px 16px;
             font:inherit; font-weight:600; cursor:pointer; }
    button.secondary { background:#3a3a3a; }
    button.danger { background:#7a2330; }
    .summary { font-family:Consolas,monospace; font-size:13px; background:##1b1b1b; border:1px solid var(--line);
               border-radius:8px; padding:12px 14px; margin-bottom:22px; white-space:pre-wrap; }
    .muted { color:var(--muted); }
    .statusrow td { padding-top:0; padding-bottom:12px; }
    .status { font-size:12px; color:var(--muted); font-family:Consolas,monospace; line-height:1.7; }
    .status .cur { color:var(--ink); }
    .status .warn { color:#F29900; }
    .badge { display:inline-block; padding:1px 8px; border-radius:10px; font-size:11px; font-weight:700;
             margin-right:8px; color:#fff; text-transform:uppercase; letter-spacing:.03em; }
    .badge.running { background:#2c95b2; } .badge.completed { background:#2f6b46; }
    .badge.stopped, .badge.timedout { background:#8a6d1f; }
    .badge.error { background:#7a2330; } .badge.none { background:#444; }
</style>
</head>
<body>
<cfoutput>
<div class="wrap">
    <h1>Repositories</h1>
    <p class="sub">Vectorise codebases for Virtual David. &middot; <a href="emails.cfm">emails</a> &middot; <a href="twitter.cfm">twitter</a> &middot; <a href="prompt.cfm">system prompt</a> &middot; <a href="../index.cfm">back to ask</a></p>

    <cfif len(notice)>
        <div class="notice #noticeClass#">#encodeForHTML(notice)#</div>
    </cfif>

    <cfif isStruct(summary)>
        <div class="summary">Scanned: #summary.scanned#  |  New: #summary.newFiles#  |  Changed: #summary.changed#  |  Skipped (unchanged): #summary.skipped#  |  Removed: #summary.deleted#  |  Chunks written: #summary.chunksWritten#<cfif arrayLen(summary.errors)>

Errors (#arrayLen(summary.errors)#):
<cfloop array="#summary.errors#" index="e">  - #encodeForHTML(e)#
</cfloop></cfif></div>
    </cfif>

    <table>
        <thead>
            <tr><th>##</th><th>Name</th><th>Path</th><th>Excludes (path substrings to skip)</th><th>Files</th><th>Chunks</th><th>Last indexed</th><th></th></tr>
        </thead>
        <tbody>
        <cfif repos.recordCount eq 0>
            <tr><td colspan="8" class="muted">No repos yet. Add one below.</td></tr>
        <cfelse>
            <cfloop query="repos">
                <tr>
                    <td>#repos.repo_id#</td>
                    <td>#encodeForHTML(repos.name)#</td>
                    <td><code>#encodeForHTML(repos.local_path)#</code></td>
                    <td>
                        <form method="post" style="margin:0;display:flex;gap:6px">
                            <input type="hidden" name="action" value="setExcludes">
                            <input type="hidden" name="repoId" value="#repos.repo_id#">
                            <input type="text" name="exclude_patterns" value="#encodeForHTMLAttribute(repos.exclude_patterns)#" style="min-width:240px">
                            <button type="submit" class="secondary">Save</button>
                        </form>
                    </td>
                    <td>#repos.file_count#</td>
                    <td>#repos.chunk_count#</td>
                    <td class="muted">#repos.last_indexed neq "" ? (dateFormat(repos.last_indexed, "yyyy-mm-dd") & " " & timeFormat(repos.last_indexed, "HH:mm")) : "never"#</td>
                    <td>
                        <div style="display:flex;gap:6px">
                            <button type="button" class="js-ingest" data-repo="#repos.repo_id#">Ingest</button>
                            <button type="button" class="js-stop danger" data-repo="#repos.repo_id#" style="display:none">Stop</button>
                            <form method="post" style="margin:0" onsubmit="return confirm('Reset &quot;#encodeForJavaScript(repos.name)#&quot;: delete its #repos.chunk_count# chunk(s) and file rows but KEEP the repo config?');">
                                <input type="hidden" name="action" value="purge">
                                <input type="hidden" name="repoId" value="#repos.repo_id#">
                                <button type="submit" class="secondary">Reset</button>
                            </form>
                            <form method="post" style="margin:0" onsubmit="return confirm('DELETE repo &quot;#encodeForJavaScript(repos.name)#&quot; entirely — its chunks, file rows, run history AND the repo itself? This cannot be undone.');">
                                <input type="hidden" name="action" value="deleteRepo">
                                <input type="hidden" name="repoId" value="#repos.repo_id#">
                                <button type="submit" class="danger">Delete</button>
                            </form>
                        </div>
                    </td>
                </tr>
                <tr class="statusrow"><td colspan="8"><div class="status" id="status-#repos.repo_id#" data-repo="#repos.repo_id#">…</div></td></tr>
            </cfloop>
        </cfif>
        </tbody>
    </table>

    <div class="panel">
        <h2>Add a repo</h2>
        <form method="post">
            <input type="hidden" name="action" value="addRepo">
            <label>Name</label>
            <input type="text" name="name" placeholder="lucinda" required>
            <label>Local path</label>
            <input type="text" name="local_path" placeholder="c:\sites\lucinda" required>
            <label>Extensions (csv, blank = default)</label>
            <input type="text" name="extensions" placeholder="#encodeForHTML(request.ingest.defaultExtensions)#">
            <label>Excludes (csv of path substrings to skip)</label>
            <input type="text" name="exclude_patterns" value="\.git\,\.claude\,\.svn\,\.vs\,\node_modules\,\bin\,\obj\,\min\,.min.js,\fontawesome,\svgs\">
            <div style="margin-top:16px"><button type="submit">Add repo</button></div>
        </form>
    </div>
</div>
</cfoutput>

<script>
(function(){
    var POLL_MS = 2500;

    function esc(s){ var d = document.createElement('div'); d.textContent = (s==null?'':String(s)); return d.innerHTML; }

    function fmtElapsed(sec){
        sec = sec || 0;
        var h = Math.floor(sec/3600), m = Math.floor((sec%3600)/60), s = sec%60;
        return (h ? h+'h ' : '') + (h||m ? m+'m ' : '') + s + 's';
    }

    function render(repo, d){
        var el = document.getElementById('status-'+repo);
        if (!el) return;
        var ingestBtn = document.querySelector('.js-ingest[data-repo="'+repo+'"]');
        var stopBtn   = document.querySelector('.js-stop[data-repo="'+repo+'"]');

        if (!d || !d.found){
            el.innerHTML = '<span class="badge none">no runs yet</span>';
            if (ingestBtn) ingestBtn.disabled = false;
            if (stopBtn) stopBtn.style.display = 'none';
            return;
        }

        var running = (d.status === 'running');
        var listing = running && d.scanned === 0 && !d.currentFile;   // still enumerating the tree
        var stale = running && !listing && d.live && d.heartbeatSecAgo !== '' && d.heartbeatSecAgo > 60;
        var counts = 'scanned '+d.scanned+' · new '+d.newFiles+' · changed '+d.changed
                   + ' · skipped '+d.skipped+' · removed '+d.deleted+' · chunks '+d.chunksWritten
                   + (d.errorCount ? ' · <span class="warn">errors '+d.errorCount+'</span>' : '');
        var html = '<span class="badge '+esc(d.status)+'">'+esc(stale ? 'stalled?' : d.status)+'</span>' + counts;

        if (running){
            if (listing){
                html += '<br><span class="cur">listing files…</span> (large repos take ~a minute before per-file progress; Stop responds once it starts)';
            } else {
                html += '<br>elapsed '+fmtElapsed(d.elapsedSec);
                if (d.currentFile) html += ' · <span class="cur">'+esc(d.currentFile)+'</span>';
                if (stale) html += ' <span class="warn">(no heartbeat for '+d.heartbeatSecAgo+'s — the run may have died; re-run to resume)</span>';
            }
        } else {
            if (d.startedAt) html += '<br>started '+esc(d.startedAt);
            if (d.finishedAt) html += ' · finished '+esc(d.finishedAt)+' ('+fmtElapsed(d.elapsedSec)+')';
            if (d.message) html += ' · '+esc(d.message);
        }
        el.innerHTML = html;
        if (ingestBtn) ingestBtn.disabled = running;
        if (stopBtn) stopBtn.style.display = running ? '' : 'none';
    }

    function poll(repo){
        fetch('ingest_status.cfm?repoId='+repo, {cache:'no-store'})
            .then(function(r){ return r.json(); })
            .then(function(d){ render(repo, d); })
            .catch(function(){});
    }

    var repos = Array.prototype.map.call(document.querySelectorAll('.status'),
        function(el){ return el.getAttribute('data-repo'); });

    function pollAll(){ repos.forEach(poll); }

    document.querySelectorAll('.js-ingest').forEach(function(btn){
        btn.addEventListener('click', function(){
            var repo = btn.getAttribute('data-repo');
            btn.disabled = true;
            // fire-and-forget: this stays open for the whole run, but we watch via polling
            fetch('ingest_run.cfm?repoId='+repo, {cache:'no-store'})
                .then(function(r){ return r.json(); }).then(function(){ poll(repo); })
                .catch(function(){ poll(repo); });
            setTimeout(function(){ poll(repo); }, 500);
        });
    });

    document.querySelectorAll('.js-stop').forEach(function(btn){
        btn.addEventListener('click', function(){
            var repo = btn.getAttribute('data-repo');
            btn.disabled = true;
            btn.textContent = 'Stopping…';
            fetch('ingest_stop.cfm?repoId='+repo, {cache:'no-store'})
                .then(function(){}).catch(function(){})
                .then(function(){ btn.textContent = 'Stop'; poll(repo); });
        });
    });

    pollAll();
    setInterval(pollAll, POLL_MS);
})();
</script>
</body>
</html>
