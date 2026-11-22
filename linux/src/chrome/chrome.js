// Iris's chrome. Iris sends the state (setState) and asks for things
// (toast, contextMenu, dialog...); this page sends back what you chose and,
// every time something moves, where its glass goes, where it takes the
// pointer and where the page sits (layout).
'use strict';

const $ = (id) => document.getElementById(id);
const post = (m) => window.webkit.messageHandlers.iris.postMessage(m);
const el = (tag, cls, text) => {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text !== undefined) e.textContent = text;
  return e;
};

// ------------------------------------------------ line glyphs (24 × 24)

const G = {
  back: 'M15 5l-7 7 7 7',
  forward: 'M9 5l7 7-7 7',
  reload: 'M19.5 12a7.5 7.5 0 1 1-2.2-5.3M19.5 4v4.5H15',
  stop: 'M6.5 6.5l11 11M17.5 6.5l-11 11',
  plus: 'M12 5v14M5 12h14',
  close: 'M7 7l10 10M17 7L7 17',
  shield: 'M12 3l7.5 3v5.5c0 4.6-3.2 8.2-7.5 9.5-4.3-1.3-7.5-4.9-7.5-9.5V6z',
  shieldOn: 'M12 3l7.5 3v5.5c0 4.6-3.2 8.2-7.5 9.5-4.3-1.3-7.5-4.9-7.5-9.5V6zM8.8 12.2l2.2 2.2 4.4-4.6',
  shieldOff: 'M12 3l7.5 3v5.5c0 4.6-3.2 8.2-7.5 9.5-4.3-1.3-7.5-4.9-7.5-9.5V6zM4 4l16 16',
  download: 'M12 4v11M7.5 10.5L12 15l4.5-4.5M5 20h14',
  layers: 'M12 3.5l8.5 4.5-8.5 4.5L3.5 8zM3.5 12.5l8.5 4.5 8.5-4.5M3.5 16.5l8.5 4.5 8.5-4.5',
  search: 'M11 4a7 7 0 1 0 0 14 7 7 0 1 0 0-14M16.2 16.2l4.3 4.3',
  sparkle: 'M12 3c.6 4.6 2.4 6.4 7 7-4.6.6-6.4 2.4-7 7-.6-4.6-2.4-6.4-7-7 4.6-.6 6.4-2.4 7-7zM19 16c.2 1.6.9 2.3 2.5 2.5-1.6.2-2.3.9-2.5 2.5-.2-1.6-.9-2.3-2.5-2.5 1.6-.2 2.3-.9 2.5-2.5z',
  globe: 'M12 3a9 9 0 1 0 0 18 9 9 0 1 0 0-18M3 12h18M12 3c2.5 2.6 3.7 5.6 3.7 9s-1.2 6.4-3.7 9c-2.5-2.6-3.7-5.6-3.7-9S9.5 5.6 12 3',
  warn: 'M12 4l9 16H3zM12 10v4.5M12 17.2v.3',
  mask: 'M3 9c3-2 15-2 18 0 0 5-2.5 7-5 7-2 0-2.5-2-4-2s-2 2-4 2c-2.5 0-5-2-5-7zM8 11.2h.01M16 11.2h.01',
  history: 'M4.5 12a7.5 7.5 0 1 0 2.2-5.3M4.5 4v4.5H9M12 8v4.3l3 1.8',
  link: 'M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1',
  tab: 'M3.5 6.5h17v13h-17zM3.5 10h17M8 6.5v3.5',
  copy: 'M8 8h11v12H8zM5 16V4h11',
  save: 'M12 4v11M7.5 10.5L12 15l4.5-4.5M5 20h14',
  image: 'M3.5 5h17v14h-17zM3.5 16l5-5 4 4 3-3 5 5M15.5 9v.2',
  cut: 'M6 7a2.5 2.5 0 1 0 0 .1M6 17a2.5 2.5 0 1 0 0 .1M8 8.5L19 18M8 15.5L19 6',
  paste: 'M9 4h6v3H9zM7 5.5H5.5v15h13v-15H17',
  selectAll: 'M4 4h16v16H4zM8 12l3 3 5-6',
  check: 'M5 12.5l4.5 4.5L19 7.5',
  folder: 'M3 6.5A1.5 1.5 0 0 1 4.5 5H9l2 2h8.5A1.5 1.5 0 0 1 21 8.5v9a1.5 1.5 0 0 1-1.5 1.5h-15A1.5 1.5 0 0 1 3 17.5z',
  trash: 'M5 7h14M10 7V4.5h4V7M7 7l1 13h8l1-13',
  up: 'M6 15l6-6 6 6',
  down: 'M6 9l6 6 6-6',
  min: 'M6 12h12',
  max: 'M6.5 6.5h11v11h-11z',
  restore: 'M8.5 8.5h9v9h-9zM6 15V6h9',
  open: 'M7 17L17 7M9 7h8v8',
  zoom: 'M11 4a7 7 0 1 0 0 14 7 7 0 1 0 0-14M16.2 16.2l4.3 4.3M8 11h6',
};

const KICONS = {"bank": "M8 .5l7.5 4V6H.5V4.5zM2 7h2.5v5H2zm4.75 0h2.5v5h-2.5zM11.5 7H14v5h-2.5zM.5 13h15v2.5H.5z", "book": "M1 2.5c2.4-.8 4.8-.6 6.25.6V15c-1.6-1.1-3.9-1.2-6.25-.5zm14 0c-2.4-.8-4.8-.6-6.25.6V15c1.6-1.1 3.9-1.2 6.25-.5z", "briefcase": "M6 1.5h4a1.5 1.5 0 0 1 1.5 1.5V4H14a1.5 1.5 0 0 1 1.5 1.5v8A1.5 1.5 0 0 1 14 15H2a1.5 1.5 0 0 1-1.5-1.5v-8A1.5 1.5 0 0 1 2 4h2.5V3A1.5 1.5 0 0 1 6 1.5zM6 3v1h4V3z", "cart": "M0.5 1.5h2.3l.5 2H15l-1.6 6.5H4.6l.3 1.5H13v1.5H3.7L1.6 3H.5z", "code": "M5.3 3.3l1.1 1.1L2.8 8l3.6 3.6-1.1 1.1L.6 8zm5.4 0L15.4 8l-4.7 4.7-1.1-1.1L13.2 8 9.6 4.4z", "game": "M4.5 4h7A4.5 4.5 0 0 1 16 8.5v1A2.5 2.5 0 0 1 11.6 11L10.5 10h-5l-1.1 1A2.5 2.5 0 0 1 0 9.5v-1A4.5 4.5 0 0 1 4.5 4zM3.5 6v1.25H2.25v1.5H3.5V10H5V8.75h1.25v-1.5H5V6zm8 0a.9.9 0 1 0 0 1.8.9.9 0 0 0 0-1.8zm-1.6 1.7a.9.9 0 1 0 0 1.8.9.9 0 0 0 0-1.8z", "heart": "M8 14.5S1 10.3 1 5.6A3.6 3.6 0 0 1 8 4a3.6 3.6 0 0 1 7 1.6c0 4.7-7 8.9-7 8.9z", "home": "M8 1l7.5 6.5H13V15H9.5v-4.5h-3V15H3V7.5H.5z", "music": "M15 1v10.5a2.5 2.5 0 1 1-1.5-2.3V4.6L6.5 6v7.5A2.5 2.5 0 1 1 5 11.2V3z", "person": "M8 1.5a3 3 0 1 0 0 6 3 3 0 0 0 0-6zM2 15c0-3.6 2.7-6 6-6s6 2.4 6 6z", "plane": "M15 6.8c.6 0 1 .5 1 1.2s-.4 1.2-1 1.2H10.3L7 15H5.2L7 9.2H3.6L2.2 11H.8l.8-3-.8-3h1.4l1.4 1.8H7L5.2 1H7l3.3 5.8z", "star": "M8 .8l2.2 4.6 5 .7-3.6 3.5.9 5L8 12.2l-4.5 2.4.9-5L.8 6.1l5-.7z"};
const ICON_NAMES = ['person', 'briefcase', 'cart', 'bank', 'home', 'heart', 'game', 'book', 'plane', 'code', 'music', 'star'];

const NS = 'http://www.w3.org/2000/svg';
function glyph(name, size) {
  const s = document.createElementNS(NS, 'svg');
  s.setAttribute('viewBox', '0 0 24 24');
  if (size) { s.style.width = size + 'px'; s.style.height = size + 'px'; }
  const p = document.createElementNS(NS, 'path');
  p.setAttribute('d', G[name] || G.globe);
  p.setAttribute('fill', 'none');
  p.setAttribute('stroke', 'currentColor');
  p.setAttribute('stroke-width', '1.8');
  p.setAttribute('stroke-linecap', 'round');
  p.setAttribute('stroke-linejoin', 'round');
  s.appendChild(p);
  return s;
}
function kicon(k, size = 17) {
  if (k.id === 'private' || k.icon === 'private') {
    const s = glyph('mask', size);
    s.style.color = k.color;
    return s;
  }
  if (!KICONS[k.icon]) {
    const d = el('span', 'kdot');
    d.style.background = k.color;
    return d;
  }
  const s = document.createElementNS(NS, 'svg');
  s.setAttribute('viewBox', '0 0 16 16');
  s.classList.add('kicon');
  s.style.width = size + 'px'; s.style.height = size + 'px';
  const p = document.createElementNS(NS, 'path');
  p.setAttribute('d', KICONS[k.icon]);
  p.setAttribute('fill', k.color || 'currentColor');
  s.appendChild(p);
  return s;
}
function setGlyph(btn, name) {
  if (btn.dataset.g === name) return;
  btn.dataset.g = name;
  [...btn.querySelectorAll('svg')].forEach((s) => s.remove());
  btn.prepend(glyph(name));
}

// ------------------------------------------------ the state

let S = { tabs: [], containers: [], downloads: { items: [], active: 0, unseen: 0 } };
let editing = false;

function setState(s) {
  S = s;
  document.body.classList.toggle('full', !!s.fullscreen);
  $('frame').hidden = !s.ownFrame;
  if (s.ownFrame) setGlyph($('frame').children[1], s.maximized ? 'restore' : 'max');
  drawTabs();
  drawBar();
  if (openPanel === 'downloads') showDownloads();
  if (openPanel === 'shields') showShields();
  kick();
}

// tabs, keyed by id, so a tab keeps its element (and its animation) as the state changes
const tabEls = new Map();
function drawTabs() {
  const strip = $('tabs');
  const seen = new Set();
  S.tabs.forEach((t, i) => {
    seen.add(t.id);
    let e = tabEls.get(t.id);
    if (!e) {
      e = el('div', 'tab opening');
      e.dataset.id = t.id;
      e.innerHTML = '<span class="fav"></span><span class="ttl"></span><button class="x" aria-label="Close tab"></button>';
      e.querySelector('.x').appendChild(glyph('close', 14));
      e.addEventListener('mousedown', (ev) => {
        if (ev.target.closest('.x')) return;
        if (ev.button === 1) { post({ op: 'close', id: t.id }); ev.preventDefault(); return; }
        if (ev.button === 0) startDrag(e, ev);
      });
      e.addEventListener('click', (ev) => {
        if (ev.target.closest('.x')) { post({ op: 'close', id: +e.dataset.id }); return; }
        if (!dragMoved) post({ op: 'select', id: +e.dataset.id });
      });
      e.addEventListener('contextmenu', (ev) => { ev.preventDefault(); tabMenu(+e.dataset.id, ev.clientX, ev.clientY); });
      tabEls.set(t.id, e);
      requestAnimationFrame(() => requestAnimationFrame(() => { e.classList.remove('opening'); kick(); }));
    }
    if (strip.children[i] !== e) strip.insertBefore(e, strip.children[i] || null);
    e.classList.toggle('current', t.current);
    e.classList.toggle('sandboxed', t.sandboxed);
    if (t.current) e.dataset.glass = '2'; else delete e.dataset.glass;
    e.title = t.title;
    const ttl = e.querySelector('.ttl');
    if (ttl.textContent !== t.title) ttl.textContent = t.title;
    drawFavicon(e.querySelector('.fav'), t);
    let dot = e.querySelector('.dot');
    if (t.color) {
      if (!dot) { dot = el('span', 'dot'); e.appendChild(dot); }
      dot.style.background = t.color;
    } else if (dot) dot.remove();
  });
  for (const [id, e] of tabEls) {
    if (!seen.has(id)) { e.remove(); tabEls.delete(id); }
  }
}

function drawFavicon(box, t) {
  const key = t.loading ? 'spin' : t.sandboxed ? 'warn' : t.private ? 'mask' : t.ai ? 'sparkle' : (t.favicon || 'globe');
  if (box.dataset.k === key) return;
  box.dataset.k = key;
  box.textContent = '';
  if (key === 'spin') { box.appendChild(el('span', 'spin')); return; }
  if (!t.favicon || t.loading || t.sandboxed || t.private || t.ai) {
    const g = glyph(key, 16);
    if (key === 'warn') g.style.color = 'var(--warn)';
    if (key === 'sparkle') g.style.color = 'var(--accent)';
    box.appendChild(g);
    return;
  }
  // "w:h:base64 RGBA" from Iris
  const [w, h, data] = t.favicon.split(':');
  const c = document.createElement('canvas');
  c.width = +w; c.height = +h;
  const raw = atob(data);
  const img = new ImageData(+w, +h);
  for (let i = 0; i < raw.length && i < img.data.length; i++) img.data[i] = raw.charCodeAt(i);
  c.getContext('2d').putImageData(img, 0, 0);
  box.appendChild(c);
}

function drawBar() {
  setGlyph($('back'), 'back');
  setGlyph($('forward'), 'forward');
  setGlyph($('reload'), S.loading ? 'stop' : 'reload');
  $('back').disabled = !S.canBack;
  $('forward').disabled = !S.canForward;
  if (!editing) $('addr').value = S.address || '';
  $('addr').placeholder = S.ai ? 'Ask Google AI Mode' : 'Ask Google AI Mode or type an address';
  const chip = $('chip');
  chip.textContent = '';
  chip.className = '';
  if (S.sandboxed) {
    chip.className = 'sandbox';
    chip.append(glyph('warn', 16), el('span', 'kname', 'Sandbox'));
    chip.title = 'Iris does not trust this site: it is in a sandbox of its own, with none of your data';
  } else if (S.private) {
    chip.append(glyph('mask', 16), el('span', 'kname', 'Private'));
  } else if (S.container) {
    const k = S.containers.find((c) => c.id === S.container);
    if (k) { const n = el('span', 'kname', k.name); n.style.color = k.color; chip.append(kicon(k, 16), n); }
  } else if (S.ai) {
    const g = glyph('sparkle', 16);
    g.style.color = 'var(--accent)';
    chip.append(g);
  }
  const p = $('progress');
  p.style.opacity = S.loading ? 1 : 0;
  p.style.transform = 'scaleX(' + (S.loading ? Math.max(0.08, S.progress || 0) : 1) + ')';
  const sh = $('shield');
  setGlyph(sh, !S.shields ? 'shieldOff' : S.shieldOn ? 'shieldOn' : 'shield');
  sh.classList.toggle('off', !S.shields || !S.shieldOn);
  const d = S.downloads;
  const dl = $('downloads');
  dl.hidden = !(d.active > 0 || d.unseen > 0 || openPanel === 'downloads');
  setGlyph(dl, 'download');
  dl.classList.toggle('busy', d.active > 0);
  $('badge').hidden = !(d.unseen > 0) || d.active > 0;
  $('badge').textContent = d.unseen;
  setGlyph($('containers'), 'layers');
}

// ------------------------------------------------ the address bar

const addr = $('addr');
let sel = -1, items = [];
addr.addEventListener('focus', () => {
  editing = true;
  post({ op: 'focus', on: true });
  requestAnimationFrame(() => addr.select());
});
addr.addEventListener('blur', () => {
  editing = false;
  setTimeout(() => { if (document.activeElement !== addr) hideSuggest(); }, 120);
  if (!document.activeElement || document.activeElement === document.body) post({ op: 'focus', on: false });
  addr.value = S.address || '';
});
addr.addEventListener('input', () => {
  sel = -1;
  if (addr.value.trim()) post({ op: 'suggest', text: addr.value }); else hideSuggest();
});
addr.addEventListener('keydown', (e) => {
  if (e.key === 'Enter') {
    const text = sel >= 0 && items[sel] ? items[sel].url : addr.value;
    if (!text.trim()) return;
    hideSuggest();
    addr.blur();
    post({ op: 'go', text });
    post({ op: 'focus', on: false });
  } else if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
    if (!items.length) return;
    e.preventDefault();
    sel = (sel + (e.key === 'ArrowDown' ? 1 : -1) + items.length) % items.length;
    markSuggest();
  } else if (e.key === 'Escape') {
    if (!$('suggest').hidden) hideSuggest(); else { addr.value = S.address || ''; addr.blur(); post({ op: 'focus', on: false }); }
  }
});

function suggestions(list) {
  items = list;
  const box = $('suggest');
  box.textContent = '';
  if (!list.length || document.activeElement !== addr) { hideSuggest(); return; }
  list.forEach((it, i) => {
    const r = el('button', 'row');
    r.append(glyph(it.kind === 'ask' ? 'sparkle' : it.kind === 'go' ? 'open' : 'history'), el('span', 'grow', it.title));
    if (it.sub) r.append(el('span', 'sub', it.sub));
    r.addEventListener('mousedown', (e) => e.preventDefault());
    r.addEventListener('click', () => { hideSuggest(); addr.blur(); post({ op: 'go', text: it.url }); post({ op: 'focus', on: false }); });
    box.appendChild(r);
    if (i === 0 && it.kind === 'ask') r.firstChild.style.color = 'var(--accent)';
  });
  const a = $('address').getBoundingClientRect();
  box.style.left = a.left + 'px';
  box.style.top = (a.bottom + 8) + 'px';
  box.style.width = Math.max(a.width, 420) + 'px';
  box.hidden = false;
  markSuggest();
  kick();
}
function markSuggest() { [...$('suggest').children].forEach((r, i) => r.classList.toggle('sel', i === sel)); }
function hideSuggest() { $('suggest').hidden = true; items = []; sel = -1; kick(); }

function focusAddress() {
  closeMenu();
  addr.focus();
  addr.select();
}
function blurAll() {
  hideSuggest();
  closeMenu();
  if (document.activeElement && document.activeElement !== document.body) document.activeElement.blur();
}

// ------------------------------------------------ buttons

$('plus').appendChild(glyph('plus'));
$('plus').addEventListener('click', () => post({ op: 'newTab' }));
$('plus').addEventListener('contextmenu', (e) => { e.preventDefault(); containersMenu($('plus'), true); });
$('back').addEventListener('click', () => post({ op: 'back' }));
$('forward').addEventListener('click', () => post({ op: 'forward' }));
$('reload').addEventListener('click', () => post({ op: S.loading ? 'stop' : 'reload' }));
$('shield').addEventListener('click', () => toggle('shields', showShields));
$('downloads').addEventListener('click', () => toggle('downloads', showDownloads));
$('containers').addEventListener('click', () => toggle('containers', () => containersMenu($('containers'), false)));
const frameGlyphs = ['min', 'max', 'close'];
[...$('frame').children].forEach((b, i) => {
  b.appendChild(glyph(frameGlyphs[i], 16));
  b.addEventListener('click', () => post({ op: b.dataset.act }));
});
// the empty strip moves the window; a double click maximises it
$('drag').addEventListener('mousedown', (e) => { if (e.button === 0 && e.detail === 1) post({ op: 'move-window' }); });
$('drag').addEventListener('dblclick', () => post({ op: 'maximize' }));

// ------------------------------------------------ dragging tabs

let drag = null, dragMoved = false;
function startDrag(e, ev) {
  dragMoved = false;
  drag = { e, x0: ev.clientX, id: +e.dataset.id };
}
window.addEventListener('mousemove', (ev) => {
  if (!drag) return;
  const dx = ev.clientX - drag.x0;
  if (!dragMoved && Math.abs(dx) < 6) return;
  dragMoved = true;
  drag.e.style.transform = 'translateX(' + dx + 'px)';
  drag.e.style.zIndex = 2;
  kick();
});
window.addEventListener('mouseup', (ev) => {
  if (!drag) return;
  const d = drag;
  drag = null;
  d.e.style.transform = '';
  d.e.style.zIndex = '';
  if (!dragMoved) return;
  // where it was dropped: before the first tab whose middle is right of the pointer
  const tabs = [...$('tabs').children].filter((t) => t !== d.e);
  let to = tabs.length;
  for (let i = 0; i < tabs.length; i++) {
    const r = tabs[i].getBoundingClientRect();
    if (ev.clientX < r.left + r.width / 2) { to = i; break; }
  }
  post({ op: 'move', id: d.id, to });
  setTimeout(() => { dragMoved = false; }, 0);
});

// ------------------------------------------------ menus and panels

let openPanel = null;   // 'shields' | 'downloads' | 'containers' | 'tab' | 'context' | 'option'
let optionId = 0;
function toggle(name, show) {
  if (openPanel === name) { closeMenu(); return; }
  show();
}
function closeMenu() {
  const m = $('menu');
  if (m.hidden) return;
  if (openPanel === 'option' && optionId) post({ op: 'option', id: optionId, index: -1 });
  optionId = 0;
  if (openPanel === 'downloads') post({ op: 'dlSeen' });
  m.hidden = true;
  m.textContent = '';
  openPanel = null;
  drawBar();
  kick();
}
function closeAll() {
  closeMenu();
  hideSuggest();
  if (!$('dialog').hidden) answerDialog(false);
  if (!$('find').hidden) closeFind();
}
/// the menu, opened with content, under an element or at a point
function openMenu(name, content, at, width, right) {
  const m = $('menu');
  const keepOption = name === 'option';
  if (!m.hidden && openPanel === 'option' && optionId && !keepOption) post({ op: 'option', id: optionId, index: -1 });
  m.textContent = '';
  m.appendChild(content);
  m.hidden = false;
  m.style.width = width ? width + 'px' : '';
  openPanel = name;
  const W = innerWidth, H = innerHeight;
  const r = m.getBoundingClientRect();
  let x, y;
  if (at instanceof Element) {
    const a = at.getBoundingClientRect();
    x = right ? a.right - r.width : a.left;
    y = a.bottom + 8;
  } else { x = at.x; y = at.y; }
  x = Math.max(8, Math.min(W - r.width - 8, x));
  if (y + r.height > H - 8) y = Math.max(8, (at instanceof Element ? H - r.height - 8 : at.y - r.height));
  m.style.left = x + 'px';
  m.style.top = y + 'px';
  kick();
}
function row(g, text, f, opts = {}) {
  const r = el('button', 'row' + (opts.on ? ' on' : ''));
  if (g instanceof Node) r.append(g); else if (g) r.append(glyph(g)); else r.append(el('span', 'kicon'));
  r.append(el('span', 'grow', text));
  if (opts.keys) r.append(el('span', 'keys', opts.keys));
  if (opts.disabled) r.disabled = true;
  r.addEventListener('click', () => { if (!opts.keep) closeMenu(); f(); });
  return r;
}
const frag = (...kids) => { const f = el('div'); kids.flat().forEach((k) => k && f.appendChild(k)); return f; };
window.addEventListener('mousedown', (e) => {
  // a press away from the menu closes it
  const m = $('menu');
  if (!m.hidden && !m.contains(e.target) && !e.target.closest('#shield,#downloads,#containers')) closeMenu();
}, true);

// shields
function showShields() {
  const kids = [el('div', 'title', 'Iris Shields'),
    el('div', 'note', 'Ads and trackers are stopped inside the engine, before a request leaves the computer. Cookies never go to other sites.')];
  if (S.site && S.shields) {
    kids.push(row(S.shieldOn ? 'shieldOn' : 'shieldOff', (S.shieldOn ? 'On for ' : 'Off for ') + S.site, () => post({ op: 'shieldSite' }), { on: S.shieldOn, keep: true }));
  }
  kids.push(row(S.shields ? 'shieldOn' : 'shieldOff', S.shields ? 'On everywhere' : 'Off everywhere', () => post({ op: 'shieldAll' }), { on: S.shields, keep: true }));
  if (S.shields) {
    kids.push(el('div', 'sep'));
    const levels = [['moderate', 'Moderate', 'Ads and trackers from other sites. A site’s own requests always load.'],
      ['aggressive', 'Aggressive', 'Also a site’s own ads and trackers, and the empty boxes ads leave.'],
      ['ultra', 'Ultra aggressive', 'Also cookie notices, sign-up pop-ups and other annoyances.']];
    for (const [id, name] of levels) kids.push(row(S.level === id ? 'check' : null, name, () => post({ op: 'level', level: id }), { on: S.level === id, keep: true }));
    kids.push(el('div', 'note', (levels.find((l) => l[0] === S.level) || levels[1])[2]));
    if (!S.ready) kids.push(el('div', 'note', 'Getting the block list ready (the first start takes a moment)…'));
  }
  openMenu('shields', frag(kids), $('shield'), 320, true);
}

// downloads
function showDownloads() {
  const d = S.downloads;
  const head = el('div');
  head.style.cssText = 'display:flex;align-items:center;gap:6px;padding:2px 4px 4px 0';
  const t = el('div', 'title', 'Downloads');
  t.style.flex = '1';
  const folder = el('button', 'pill', 'Folder');
  folder.onclick = () => post({ op: 'dlFolder' });
  head.append(t, folder);
  if (d.items.some((x) => x.done || x.failed)) {
    const clear = el('button', 'pill', 'Clear');
    clear.onclick = () => post({ op: 'dlClear' });
    head.append(clear);
  }
  const kids = [head];
  if (!d.items.length) kids.push(el('div', 'note', 'Nothing downloaded yet'));
  for (const it of d.items) {
    const r = el('div', 'row');
    r.style.cssText = 'flex-direction:column;align-items:stretch;gap:2px';
    const top = el('div');
    top.style.cssText = 'display:flex;align-items:center;gap:10px';
    top.append(glyph(it.failed ? 'warn' : 'download'), el('span', 'grow', it.name || 'Starting…'));
    const act = el('button', 'btn');
    act.style.cssText = 'width:26px;height:26px';
    if (!it.done && !it.failed) { act.append(glyph('stop', 15)); act.onclick = (e) => { e.stopPropagation(); post({ op: 'dlCancel', id: it.id }); }; }
    else if (it.done) { act.append(glyph('folder', 15)); act.onclick = (e) => { e.stopPropagation(); post({ op: 'dlShow', id: it.id }); }; }
    top.append(act);
    r.append(top);
    if (!it.done && !it.failed) { const b = el('div', 'bar2'); const i = el('i'); i.style.width = Math.round(it.progress * 100) + '%'; b.append(i); r.append(b); }
    const st = el('div', 'sub', it.status);
    st.style.maxWidth = 'none';
    r.append(st);
    if (it.done) r.onclick = () => post({ op: 'dlOpen', id: it.id });
    kids.push(r);
  }
  openMenu('downloads', frag(kids), $('downloads'), 380, true);
}

// containers
function containersMenu(anchor, newTabOnly) {
  const kids = [el('div', 'head', 'New tab in'), row('globe', 'No Container', () => post({ op: 'newTab' }))];
  for (const k of S.containers) kids.push(row(kicon(k), k.name, () => post({ op: 'newTab', container: k.id })));
  kids.push(row(kicon({ id: 'private', color: '#5e5ce6' }), 'Private', () => post({ op: 'newTab', container: 'private' })));
  if (!newTabOnly && S.display) {
    kids.push(el('div', 'sep'), el('div', 'head', 'Open this page in'));
    if (S.container) kids.push(row('globe', 'No Container', () => post({ op: 'openIn', container: '' })));
    for (const k of S.containers) if (k.id !== S.container) kids.push(row(kicon(k), k.name, () => post({ op: 'openIn', container: k.id })));
  }
  kids.push(el('div', 'sep'), row('plus', 'New Container…', newContainer, { keep: true }));
  if (S.containers.length) kids.push(row('trash', 'Remove a Container…', removeContainer, { keep: true }));
  openMenu('containers', frag(kids), anchor, 270, anchor !== $('plus'));
}
function newContainer() {
  let icon = 'star';
  const name = el('input', 'field');
  name.placeholder = 'Name';
  const grid = el('div', 'icons');
  for (const n of ICON_NAMES) {
    const b = el('button');
    b.append(kicon({ icon: n, color: 'currentColor' }, 18));
    if (n === icon) b.classList.add('sel');
    b.onclick = () => { icon = n; [...grid.children].forEach((c) => c.classList.remove('sel')); b.classList.add('sel'); };
    grid.append(b);
  }
  const add = el('button', 'pill primary', 'Add');
  const go = () => { if (name.value.trim()) { closeMenu(); post({ op: 'containerNew', name: name.value.trim(), icon }); } };
  add.onclick = go;
  name.addEventListener('keydown', (e) => { if (e.key === 'Enter') go(); });
  const buttons = el('div', 'buttons');
  buttons.append(add);
  openMenu('containers', frag(el('div', 'title', 'New Container'),
    el('div', 'note', 'A container keeps its own cookies, sign-ins and site data, apart from every other.'), name, grid, buttons), $('containers'), 290, true);
  name.focus();
  post({ op: 'focus', on: true });
}
function removeContainer() {
  const kids = [el('div', 'title', 'Remove a Container'), el('div', 'note', 'Its tabs close, and its cookies, sign-ins and site data are deleted.')];
  for (const k of S.containers) kids.push(row(kicon(k), k.name, () => post({ op: 'containerRemove', id: k.id })));
  openMenu('containers', frag(kids), $('containers'), 290, true);
}

// a tab's menu
function tabMenu(id, x, y) {
  const t = S.tabs.find((t) => t.id === id);
  if (!t) return;
  const kids = [row('reload', 'Reload', () => post({ op: 'reloadTab', id })), row('copy', 'Duplicate', () => post({ op: 'duplicate', id }))];
  const ks = S.containers.filter((k) => k.id !== (t.current ? S.container : ''));
  if (ks.length) kids.push(el('div', 'sep'));
  for (const k of ks) kids.push(row(kicon(k), 'Open in ' + k.name, () => post({ op: 'openIn', id, container: k.id })));
  kids.push(el('div', 'sep'), row('close', 'Close Other Tabs', () => post({ op: 'closeOthers', id })), row('close', 'Close Tab', () => post({ op: 'close', id }), { keys: 'Ctrl+W' }));
  openMenu('tab', frag(kids), { x, y: y + 4 }, 240);
}

// the page's right-click menu
function contextMenu(c) {
  const kids = [];
  const ctx = (o) => post(Object.assign({ op: 'ctx' }, o));
  if (c.link) {
    kids.push(row('tab', 'Open Link in New Tab', () => ctx({ do: 'tab', value: c.link })));
    for (const k of c.containers) kids.push(row(kicon(k), 'Open Link in ' + k.name, () => ctx({ do: 'in', value: c.link, container: k.id })));
    kids.push(row('link', 'Copy Link', () => ctx({ do: 'copy', value: c.link })), row('save', 'Download Link', () => ctx({ do: 'save', value: c.link })));
  }
  if (c.image) {
    if (kids.length) kids.push(el('div', 'sep'));
    kids.push(row('image', 'Open Image in New Tab', () => ctx({ do: 'tab', value: c.image })),
      row('copy', 'Copy Image Address', () => ctx({ do: 'copy', value: c.image })), row('save', 'Save Image', () => ctx({ do: 'save', value: c.image })));
  }
  if (c.media && !c.image) {
    if (kids.length) kids.push(el('div', 'sep'));
    kids.push(row('copy', 'Copy Video Address', () => ctx({ do: 'copy', value: c.media })), row('save', 'Save Video', () => ctx({ do: 'save', value: c.media })));
  }
  if (c.editable) {
    if (kids.length) kids.push(el('div', 'sep'));
    kids.push(row('cut', 'Cut', () => ctx({ do: 'edit', value: 'cut' }), { keys: 'Ctrl+X' }), row('copy', 'Copy', () => ctx({ do: 'edit', value: 'copy' }), { keys: 'Ctrl+C' }),
      row('paste', 'Paste', () => ctx({ do: 'edit', value: 'paste' }), { keys: 'Ctrl+V' }), row('selectAll', 'Select All', () => ctx({ do: 'edit', value: 'selectAll' }), { keys: 'Ctrl+A' }));
  } else if (c.selection) {
    if (kids.length) kids.push(el('div', 'sep'));
    kids.push(row('copy', 'Copy', () => ctx({ do: 'edit', value: 'copy' }), { keys: 'Ctrl+C' }), row('sparkle', 'Ask Google AI Mode', () => ctx({ do: 'askAI' })));
  }
  if (!kids.length) {
    kids.push(row('back', 'Back', () => ctx({ do: 'back' }), { keys: 'Alt+←', disabled: !S.canBack }), row('forward', 'Forward', () => ctx({ do: 'forward' }), { keys: 'Alt+→', disabled: !S.canForward }),
      row('reload', 'Reload', () => ctx({ do: 'reload' }), { keys: 'Ctrl+R' }), row('selectAll', 'Select All', () => ctx({ do: 'edit', value: 'selectAll' }), { keys: 'Ctrl+A' }));
  }
  openMenu('context', frag(kids), { x: c.x, y: c.y }, 250);
}

// a <select>'s list, where the page put it
function optionMenu(id, x, y, width, list) {
  const kids = [];
  list.forEach((it, i) => {
    if (it.group) { kids.push(el('div', 'head', it.label)); return; }
    const r = row(it.selected ? 'check' : null, it.label, () => { optionId = 0; post({ op: 'option', id, index: i }); }, { disabled: !it.enabled, on: it.selected });
    kids.push(r);
  });
  openMenu('option', frag(kids), { x, y: y + 4 }, Math.max(width, 200));
  optionId = id;
  const s = $('menu').querySelector('.row.on');
  if (s) s.scrollIntoView({ block: 'nearest' });
}
function closeOption() { if (openPanel === 'option') { closeMenu(); } }

// ------------------------------------------------ find in page

const findText = $('findText');
function openFind() {
  const f = $('find');
  f.hidden = false;
  const btns = f.querySelectorAll('button');
  setGlyph(btns[0], 'up'); setGlyph(btns[1], 'down'); setGlyph(btns[2], 'close');
  placeFind();
  findText.focus();
  findText.select();
  post({ op: 'focus', on: true });
  kick();
}
function placeFind() {
  const c = $('card').getBoundingClientRect();
  const f = $('find');
  f.style.top = (c.top + 12) + 'px';
  f.style.left = (c.right - f.getBoundingClientRect().width - 12) + 'px';
}
function closeFind() {
  $('find').hidden = true;
  findText.value = '';
  $('findCount').textContent = '';
  post({ op: 'findClose' });
  post({ op: 'focus', on: false });
  kick();
}
findText.addEventListener('input', () => post({ op: 'find', text: findText.value, dir: '' }));
findText.addEventListener('keydown', (e) => {
  if (e.key === 'Enter') post({ op: 'find', text: findText.value, dir: e.shiftKey ? 'prev' : 'next' });
  if (e.key === 'Escape') closeFind();
});
$('find').addEventListener('click', (e) => {
  const b = e.target.closest('button');
  if (!b) return;
  if (b.dataset.act === 'findPrev') post({ op: 'find', text: findText.value, dir: 'prev' });
  if (b.dataset.act === 'findNext') post({ op: 'find', text: findText.value, dir: 'next' });
  if (b.dataset.act === 'findClose') closeFind();
});
function findCount(n) {
  $('findCount').textContent = n < 0 ? '' : n === 0 ? 'No matches' : n === 1 ? '1 match' : n + ' matches';
  placeFind();
  kick();
}

// ------------------------------------------------ notes, status, dialogs

function toast(text, action, url, onAction, ms = 4500) {
  const t = el('div', 'toast' + (action ? '' : ' plain'));
  t.dataset.glass = '1';
  t.append(el('span', '', text));
  if (action) {
    const b = el('button', 'pill primary', action);
    b.onclick = () => { if (onAction) onAction(); else if (url) post({ op: 'newTab', url }); gone(); };
    t.append(b);
  }
  $('toasts').appendChild(t);
  const gone = () => {
    if (!t.isConnected) return;
    t.classList.add('going');
    kick();
    setTimeout(() => { t.remove(); kick(); }, 220);
  };
  setTimeout(gone, ms);
  kick();
  return gone;
}
function permission(id, text) {
  let answered = false;
  toast(text, 'Allow', null, () => { answered = true; post({ op: 'permission', id, allow: true }); }, 6000);
  setTimeout(() => { if (!answered) post({ op: 'permission', id, allow: false }); }, 6100);
}
function status(link) {
  const s = $('status');
  s.textContent = link;
  s.hidden = !link;
  if (link) {
    const c = $('card').getBoundingClientRect();
    s.style.left = (c.left + 10) + 'px';
    s.style.bottom = (innerHeight - c.bottom + 10) + 'px';
  }
  kick();
}

let dialogId = 0, dialogKind = 0;
function dialog(id, kind, host, message, defText) {
  dialogId = id; dialogKind = kind;
  const d = $('dialog');
  d.textContent = '';
  d.append(el('div', 'title', host + ' says'), el('div', 'msg', message));
  let input = null;
  if (kind === 2) { input = el('input', 'field'); input.value = defText; d.append(input); }
  const buttons = el('div', 'buttons');
  const ok = el('button', 'pill primary', kind === 3 ? 'Leave' : 'OK');
  ok.onclick = () => answerDialog(true, input ? input.value : '');
  if (kind !== 0) {
    const cancel = el('button', 'pill', kind === 3 ? 'Stay' : 'Cancel');
    cancel.onclick = () => answerDialog(false);
    buttons.append(cancel);
  }
  buttons.append(ok);
  d.append(buttons);
  $('scrim').hidden = false;
  d.hidden = false;
  (input || ok).focus();
  if (input) input.select();
  d.onkeydown = (e) => { if (e.key === 'Enter') ok.click(); if (e.key === 'Escape') answerDialog(false); };
  post({ op: 'focus', on: true });
  kick();
}
function answerDialog(yes, text) {
  if ($('dialog').hidden) return;
  post({ op: 'dialog', id: dialogId, ok: yes || dialogKind === 0, text: text || '' });
  $('dialog').hidden = true;
  $('scrim').hidden = true;
  post({ op: 'focus', on: false });
  kick();
}

// ------------------------------------------------ the layout Iris draws glass for

/// rounded rect of an element in window pixels, with its radius
function rectOf(e, kind) {
  const r = e.getBoundingClientRect();
  if (r.width < 1 || r.height < 1) return null;
  const cs = getComputedStyle(e);
  if (cs.visibility === 'hidden' || +cs.opacity < 0.02) return null;
  const rad = parseFloat(cs.borderTopLeftRadius) || 0;
  return { x: r.left, y: r.top, w: r.width, h: r.height, r: Math.min(rad, r.height / 2, r.width / 2), k: kind };
}
let lastLayout = '';
function report() {
  const glass = [];
  for (const e of document.querySelectorAll('[data-glass]')) {
    if (e.hidden || e.closest('[hidden]')) continue;
    const g = rectOf(e, +e.dataset.glass);
    if (g) glass.push(g);
  }
  // a hovered button gets a drop of glass of its own
  for (const e of document.querySelectorAll('.btn:hover:not([disabled]), .tab:hover:not(.current)')) {
    const g = rectOf(e, 3);
    if (g) glass.push(g);
  }
  const hits = [];
  for (const e of document.querySelectorAll('.float, .toast')) {
    if (e.hidden || e.classList.contains('quiet')) continue;
    const r = e.getBoundingClientRect();
    if (r.width > 0 && r.height > 0) hits.push([r.left, r.top, r.width, r.height]);
  }
  const c = $('card').getBoundingClientRect();
  const modal = !$('dialog').hidden;
  const msg = { op: 'layout', glass, hits, card: [c.left, c.top, c.width, c.height], modal };
  const key = JSON.stringify(msg);
  if (key !== lastLayout) {
    lastLayout = key;
    post(msg);
  }
}
// while anything moves, the layout goes to Iris every frame; then it stops
let until = 0, ticking = false;
function kick(ms = 700) {
  until = Math.max(until, performance.now() + ms);
  if (ticking) return;
  ticking = true;
  const step = () => {
    report();
    if (performance.now() < until) requestAnimationFrame(step); else ticking = false;
  };
  requestAnimationFrame(step);
}
for (const ev of ['mouseover', 'mouseout', 'transitionrun', 'transitionend', 'animationstart', 'animationend', 'resize', 'scroll'])
  window.addEventListener(ev, () => kick(), true);
window.addEventListener('focusin', () => kick());
window.addEventListener('focusout', (e) => {
  kick();
  // the chrome gives the keyboard back once nothing of it wants keys
  setTimeout(() => {
    const a = document.activeElement;
    if (!a || a === document.body) post({ op: 'focus', on: false });
  }, 0);
});
document.addEventListener('contextmenu', (e) => e.preventDefault());

post({ op: 'ready' });
kick(1500);
