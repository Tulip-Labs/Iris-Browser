package link

// page is what the phone sees.
const page = `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="theme-color" content="#f4eefb">
<title>Iris link</title>
<style>
:root{--bg:#f6f1fb;--card:#ffffffcc;--ink:#231b2e;--soft:#6c6078;--pri:#7a4bb5;--line:#e6dcf1;--ok:#2e8a5c;--bad:#b3403a}
@media(prefers-color-scheme:dark){:root{--bg:#17131d;--card:#241d2ecc;--ink:#efe8f7;--soft:#a79bb5;--pri:#c7a5f2;--line:#3a3046;--ok:#7fd4a6;--bad:#f09a94}}
*{box-sizing:border-box}
body{margin:0;font:16px/1.45 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;color:var(--ink);
background:linear-gradient(160deg,#fbe4ee 0%,var(--bg) 38%,#e2ecfb 100%) fixed;min-height:100vh}
@media(prefers-color-scheme:dark){body{background:linear-gradient(160deg,#2a1a2c 0%,var(--bg) 40%,#16202f 100%) fixed}}
main{max-width:560px;margin:0 auto;padding:22px 16px 60px}
h1{font-size:22px;margin:6px 0 2px}
p.sub{margin:0 0 18px;color:var(--soft);font-size:14px}
section{background:var(--card);border:1px solid var(--line);border-radius:22px;padding:16px;margin:0 0 14px;backdrop-filter:blur(12px)}
h2{font-size:15px;margin:0 0 10px;color:var(--pri)}
label.pick{display:flex;align-items:center;justify-content:center;gap:10px;min-height:92px;border:2px dashed var(--pri);border-radius:18px;
color:var(--pri);font-weight:600;cursor:pointer;text-align:center;padding:12px}
label.pick:active{background:#7a4bb514}
input[type=file]{position:absolute;opacity:0;width:1px;height:1px}
ul{list-style:none;margin:10px 0 0;padding:0}
li{display:flex;align-items:center;gap:10px;padding:10px 0;border-top:1px solid var(--line)}
li:first-child{border-top:0}
.n{flex:1;min-width:0}
.n b{display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-weight:600}
.n small{color:var(--soft)}
.bar{height:5px;border-radius:3px;background:var(--line);overflow:hidden;margin-top:6px}
.bar i{display:block;height:100%;width:0;background:var(--pri);border-radius:3px;transition:width .15s}
a.btn,button.btn{flex:none;border:0;border-radius:999px;background:var(--pri);color:#fff;font:600 14px system-ui;padding:9px 16px;text-decoration:none}
@media(prefers-color-scheme:dark){a.btn,button.btn{color:#1a1322}}
.ok{color:var(--ok)}.bad{color:var(--bad)}
.empty{color:var(--soft);font-size:14px;margin:4px 0 0}
footer{color:var(--soft);font-size:12.5px;text-align:center;margin-top:18px}
</style></head><body><main>
<h1>Iris link</h1>
<p class="sub">Connected to <b>{{PC}}</b> over this network.</p>
<section id="pairbox" style="display:none">
<h2>Iris for Android</h2>
<p class="empty" style="margin:0 0 12px">Keep history, open tabs and the palette the same on this phone and the computer. They sync by themselves whenever both are on this network.</p>
<a class="btn" id="pair" href="#">Pair with Iris</a>
<p class="empty" style="margin-top:12px">Iris for Android must be installed first: <a href="https://github.com/Tulip-Labs/Iris-Browser/releases/latest" rel="noopener noreferrer" target="_blank" style="color:var(--pri)">get it here</a>.</p>
</section>
<section>
<h2>Send to the computer</h2>
<label class="pick"><input id="pick" type="file" multiple>Choose photos or files</label>
<ul id="ups"></ul>
</section>
<section>
<h2>From the computer</h2>
<ul id="items"></ul>
<p class="empty" id="none">Nothing shared yet. Files sent from Iris appear here by themselves.</p>
</section>
<footer>Files travel only inside your network. Close this page when you are done.</footer>
</main>
<script>
const $ = (id) => document.getElementById(id);
const pairURL = "{{PAIR}}";
if (/^iris:\/\/pair\?/.test(pairURL)) { $('pair').href = pairURL; $('pairbox').style.display = ''; }
const size = (n) => n < 0 ? '' : n < 1024 ? n + ' B' : n < 1048576 ? (n / 1024).toFixed(0) + ' KB' : n < 1073741824 ? (n / 1048576).toFixed(1) + ' MB' : (n / 1073741824).toFixed(2) + ' GB';
const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };

let queue = [], busy = false;
$('pick').addEventListener('change', (ev) => {
  for (const f of ev.target.files) {
    const li = el('li'), n = el('div', 'n'), b = el('b', '', f.name), s = el('small', '', size(f.size) + ' · waiting');
    const bar = el('div', 'bar'), fill = el('i');
    bar.append(fill); n.append(b, s, bar); li.append(n); $('ups').prepend(li);
    queue.push({ f, s, fill, bar });
  }
  ev.target.value = '';
  next();
});
function next() {
  if (busy || !queue.length) return;
  busy = true;
  const { f, s, fill, bar } = queue.shift();
  const x = new XMLHttpRequest();
  x.open('POST', 'up?name=' + encodeURIComponent(f.name));
  x.upload.onprogress = (e) => { if (e.lengthComputable) { fill.style.width = (100 * e.loaded / e.total) + '%'; s.textContent = size(e.loaded) + ' of ' + size(e.total); } };
  const done = (ok) => { bar.remove(); s.textContent = ok ? size(f.size) + ' · sent' : 'Not sent. Try again.'; s.className = ok ? 'ok' : 'bad'; busy = false; next(); };
  x.onload = () => done(x.status >= 200 && x.status < 300);
  x.onerror = x.onabort = () => done(false);
  x.send(f);
}

let shown = '';
async function refresh() {
  try {
    const r = await fetch('list', { cache: 'no-store' });
    if (!r.ok) throw 0;
    const text = await r.text();
    if (text !== shown) {
      shown = text;
      const items = JSON.parse(text), ul = $('items');
      ul.textContent = '';
      for (const it of items) {
        const li = el('li'), n = el('div', 'n');
        n.append(el('b', '', it.name));
        if (it.text) {
          n.append(el('small', '', it.text));
          const open = /^https?:\/\//.test(it.text);
          const a = el(open ? 'a' : 'button', 'btn', open ? 'Open' : 'Copy');
          if (open) { a.href = it.text; a.target = '_blank'; a.rel = 'noopener noreferrer'; }
          else a.onclick = () => navigator.clipboard && navigator.clipboard.writeText(it.text);
          li.append(n, a);
        } else {
          n.append(el('small', '', size(it.size)));
          const a = el('a', 'btn', 'Save');
          a.href = 'f/' + it.id; a.download = it.name;
          li.append(n, a);
        }
        ul.append(li);
      }
      $('none').style.display = items.length ? 'none' : '';
    }
  } catch (e) {
    $('none').style.display = ''; $('none').textContent = 'The link is closed on the computer.'; $('items').textContent = ''; shown = '';
  }
}
refresh();
setInterval(refresh, 2500);
</script></body></html>`
