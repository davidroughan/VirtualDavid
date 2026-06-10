<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Virtual David</title>
<style>
    :root { --bg:#1e1e1e; --panel:#252526; --ink:#e6e6e6; --muted:#9aa0a6; --accent:#2c95b2; --line:#3a3a3a; --user:#2d3b41; }
    * { box-sizing:border-box; }
    body { margin:0; background:var(--bg); color:var(--ink); font:15px/1.55 -apple-system,Segoe UI,Roboto,sans-serif; }
    .wrap { max-width:820px; margin:0 auto; padding:28px 18px 40px; }
    .head { display:flex; align-items:baseline; justify-content:space-between; gap:12px; }
    h1 { font-size:20px; margin:0 0 4px; }
    .sub { color:var(--muted); margin:0 0 22px; font-size:13px; }
    .sub a { color:var(--accent); }
    .newchat { background:none; border:1px solid var(--line); color:var(--muted); border-radius:8px;
               padding:6px 12px; font:inherit; font-size:13px; cursor:pointer; white-space:nowrap; }
    .newchat:hover { color:var(--ink); border-color:var(--muted); }

    .thread { display:flex; flex-direction:column; gap:14px; margin-bottom:18px; }
    .msg { border:1px solid var(--line); border-radius:10px; padding:13px 16px; white-space:pre-wrap; }
    .msg.user { background:var(--user); align-self:flex-end; max-width:85%; }
    .msg.bot  { background:var(--panel); }
    .msg.bot.err { border-color:#7a2330; }
    .sources { margin-top:10px; font-size:13px; color:var(--muted); }
    .sources details { margin-top:4px; }
    .sources code { color:var(--ink); }
    .thinking { color:var(--muted); font-style:italic; }

    form { display:flex; gap:10px; align-items:flex-end; position:sticky; bottom:0;
           background:var(--bg); padding:12px 0; }
    textarea { flex:1; min-height:64px; resize:vertical; background:var(--panel); color:var(--ink);
               border:1px solid var(--line); border-radius:8px; padding:11px 13px; font:inherit; }
    button.ask { background:var(--accent); color:#fff; border:0; border-radius:8px; padding:12px 18px;
                 font:inherit; font-weight:600; cursor:pointer; }
    button.ask:disabled { opacity:.5; cursor:default; }
</style>
</head>
<body>
<div class="wrap">
    <div class="head">
        <div>
            <h1>Virtual David</h1>
            <p class="sub">Ask about the indexed codebases. Answers are grounded in vectorised source, and you can ask follow-ups. &middot; <a href="admin/ingest.cfm">manage repos</a></p>
        </div>
        <button type="button" class="newchat" id="newChat">New chat</button>
    </div>

    <div class="thread" id="thread"></div>

    <form id="askForm">
        <textarea id="message" name="message" placeholder="e.g. How does AzureOpenAI.cfc log token usage?" autofocus></textarea>
        <button type="submit" class="ask" id="askBtn">Ask</button>
    </form>
</div>

<script>
(function(){
    var form = document.getElementById('askForm'),
        msg = document.getElementById('message'),
        btn = document.getElementById('askBtn'),
        thread = document.getElementById('thread'),
        newChat = document.getElementById('newChat');

    // The full conversation, sent to the server each turn so the model has context.
    var history = [];

    function el(cls){ var d = document.createElement('div'); d.className = cls; return d; }

    function scrollIn(node){ node.scrollIntoView({ behavior:'smooth', block:'end' }); }

    function addMessage(role, text){
        var node = el('msg ' + (role === 'user' ? 'user' : 'bot'));
        node.textContent = text;
        thread.appendChild(node);
        scrollIn(node);
        return node;
    }

    function renderSources(node, list){
        if (!list || !list.length) return;
        var box = el('sources');
        var html = '<details><summary>' + list.length + ' source(s)</summary>';
        list.forEach(function(s){
            html += '<div><code>' + s.repo_name + '/' + s.path + ':' + s.lines + '</code> &middot; ' + s.score + '</div>';
        });
        html += '</details>';
        box.innerHTML = html;
        node.appendChild(box);
    }

    form.addEventListener('submit', function(e){
        e.preventDefault();
        var q = msg.value.trim();
        if (!q || btn.disabled) return;

        addMessage('user', q);
        msg.value = '';
        btn.disabled = true;

        var pending = addMessage('bot', '');
        pending.classList.add('thinking');
        pending.textContent = 'Thinking…';

        // Send the history as it stood BEFORE this question; the server appends
        // the current question itself.
        var payload = 'message=' + encodeURIComponent(q) +
                      '&history=' + encodeURIComponent(JSON.stringify(history));

        fetch('ajax_ask.cfm', {
            method:'POST',
            headers:{'Content-Type':'application/x-www-form-urlencoded'},
            body: payload
        })
        .then(function(r){ return r.json(); })
        .then(function(d){
            pending.classList.remove('thinking');
            if (d.ok) {
                pending.textContent = d.answer;
                renderSources(pending, d.sources);
                history.push({ role:'user', content:q });
                history.push({ role:'assistant', content:d.answer });
            } else {
                pending.classList.add('err');
                pending.textContent = d.error || 'Something went wrong.';
            }
        })
        .catch(function(err){
            pending.classList.remove('thinking');
            pending.classList.add('err');
            pending.textContent = 'Request failed: ' + err;
        })
        .finally(function(){
            btn.disabled = false;
            msg.focus();
        });
    });

    newChat.addEventListener('click', function(){
        history = [];
        thread.innerHTML = '';
        msg.value = '';
        msg.focus();
    });

    // Ctrl/Cmd+Enter submits
    msg.addEventListener('keydown', function(e){
        if ((e.ctrlKey || e.metaKey) && e.key === 'Enter') form.requestSubmit();
    });
})();
</script>
</body>
</html>
