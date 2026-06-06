<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Virtual David</title>
<style>
    :root { --bg:#1e1e1e; --panel:#252526; --ink:#e6e6e6; --muted:#9aa0a6; --accent:#2c95b2; --line:#3a3a3a; }
    * { box-sizing:border-box; }
    body { margin:0; background:var(--bg); color:var(--ink); font:15px/1.55 -apple-system,Segoe UI,Roboto,sans-serif; }
    .wrap { max-width:820px; margin:0 auto; padding:28px 18px 80px; }
    h1 { font-size:20px; margin:0 0 4px; }
    .sub { color:var(--muted); margin:0 0 22px; font-size:13px; }
    .sub a { color:var(--accent); }
    form { display:flex; gap:10px; align-items:flex-end; }
    textarea { flex:1; min-height:64px; resize:vertical; background:var(--panel); color:var(--ink);
               border:1px solid var(--line); border-radius:8px; padding:11px 13px; font:inherit; }
    button { background:var(--accent); color:#fff; border:0; border-radius:8px; padding:12px 18px;
             font:inherit; font-weight:600; cursor:pointer; }
    button:disabled { opacity:.5; cursor:default; }
    .answer { margin-top:24px; background:var(--panel); border:1px solid var(--line); border-radius:10px;
              padding:18px 20px; white-space:pre-wrap; display:none; }
    .answer.err { border-color:#7a2330; }
    .sources { margin-top:14px; font-size:13px; color:var(--muted); }
    .sources details { margin-top:6px; }
    .sources code { color:var(--ink); }
    .thinking { color:var(--muted); font-style:italic; margin-top:20px; display:none; }
</style>
</head>
<body>
<div class="wrap">
    <h1>Virtual David</h1>
    <p class="sub">Ask about the indexed codebases. Answers are grounded in vectorised source. &middot; <a href="admin/ingest.cfm">manage repos</a></p>

    <form id="askForm">
        <textarea id="message" name="message" placeholder="e.g. How does AzureOpenAI.cfc log token usage?" autofocus></textarea>
        <button type="submit" id="askBtn">Ask</button>
    </form>

    <div class="thinking" id="thinking">Thinking&hellip;</div>
    <div class="answer" id="answer"></div>
    <div class="sources" id="sources"></div>
</div>

<script>
(function(){
    var form = document.getElementById('askForm'),
        msg = document.getElementById('message'),
        btn = document.getElementById('askBtn'),
        thinking = document.getElementById('thinking'),
        answer = document.getElementById('answer'),
        sources = document.getElementById('sources');

    form.addEventListener('submit', function(e){
        e.preventDefault();
        var q = msg.value.trim();
        if (!q) return;
        btn.disabled = true;
        answer.style.display = 'none';
        sources.innerHTML = '';
        thinking.style.display = 'block';

        fetch('ajax_ask.cfm', {
            method:'POST',
            headers:{'Content-Type':'application/x-www-form-urlencoded'},
            body:'message=' + encodeURIComponent(q)
        })
        .then(function(r){ return r.json(); })
        .then(function(d){
            thinking.style.display = 'none';
            answer.style.display = 'block';
            if (d.ok) {
                answer.classList.remove('err');
                answer.textContent = d.answer;
                if (d.sources && d.sources.length) {
                    var html = '<details open><summary>' + d.sources.length + ' source(s)</summary>';
                    d.sources.forEach(function(s){
                        html += '<div><code>' + s.repo_name + '/' + s.path + ':' + s.lines + '</code> &middot; ' + s.score + '</div>';
                    });
                    html += '</details>';
                    sources.innerHTML = html;
                }
            } else {
                answer.classList.add('err');
                answer.textContent = d.error || 'Something went wrong.';
            }
        })
        .catch(function(err){
            thinking.style.display = 'none';
            answer.style.display = 'block';
            answer.classList.add('err');
            answer.textContent = 'Request failed: ' + err;
        })
        .finally(function(){ btn.disabled = false; });
    });

    // Ctrl/Cmd+Enter submits
    msg.addEventListener('keydown', function(e){
        if ((e.ctrlKey || e.metaKey) && e.key === 'Enter') form.requestSubmit();
    });
})();
</script>
</body>
</html>
