'use strict';
// Iris's page engine on Electron.
//
// Iris (Go) starts this when the first page that needs it opens, and drives
// it over the Unix socket in IRIS_SOCK. Pages are drawn off screen at the
// window's scale (IRIS_SCALE) and their frames go to Iris, which draws them
// in its own window; Iris sends back the pointer, the wheel and the keys.
// Nothing here has a window or an interface of its own.
//
// Messages, both ways: length (4 bytes, little endian), kind (1 byte),
// payload. Kind 0 is one JSON object; kind 1 (to Iris) is a frame: header
// length (4 bytes), JSON header {id, fw, fh, x, y, w, h}, then the pixels of
// that rectangle (BGRA, premultiplied, w × 4 bytes a row).
//
// Light on purpose (see docs/engines.md, "Keeping Electron light"): no Node
// in pages, the sandbox on, one renderer per site, few renderers, hidden
// pages do not paint, nothing runs in the background, and the whole helper
// quits two minutes after its last page closes.

const { app, BrowserWindow, session, nativeTheme, ipcMain, clipboard, webContents } = require('electron');
const net = require('net');
const path = require('path');
const fs = require('fs');

const SOCK = process.env.IRIS_SOCK;
const DATA = process.env.IRIS_DATA || path.join(app.getPath('temp'), 'iris-pages');
let SCALE = Math.min(8, Math.max(0.5, parseFloat(process.env.IRIS_SCALE || '1') || 1));
const MEM = parseInt(process.env.IRIS_MEM || '0', 10) || 0;
const LOW = process.env.IRIS_LOW === '1' || (MEM > 0 && MEM <= 8192);
const DEBUG = !!process.env.IRIS_GL_DEBUG;
const CONSOLE = !!process.env.IRIS_CONSOLE;
const IDLE_MS = 120000;

if (!SOCK) {
  console.error('Iris pages: started without Iris (IRIS_SOCK is not set)');
  process.exit(2);
}

// ---- Chromium, before it starts ----

app.setName('Iris');
app.setPath('userData', DATA);
const sw = (k, v) => (v === undefined ? app.commandLine.appendSwitch(k) : app.commandLine.appendSwitch(k, String(v)));
// Pages at exactly the window's scale, one page pixel on one screen pixel.
// Offscreen pages ignore a forced device scale (they take the display's),
// so each page is sized in screen pixels at scale 1 and zoomed by the
// window's scale: Chromium lays it out in CSS pixels of 1.25 screen pixels
// (devicePixelRatio 1.25) and draws every screen pixel itself.
sw('force-device-scale-factor', 1);
// lighter Chromium: pages of one site share a process, and few run
sw('process-per-site');
sw('renderer-process-limit', LOW ? 3 : 5);
sw('disable-background-networking');
sw('disable-component-update');
sw('disable-breakpad');
sw('disable-domain-reliability');
sw('no-pings');
sw('disable-default-apps');
sw('no-first-run');
sw('disk-cache-size', 104857600);
if (LOW) sw('js-flags', '--optimize-for-size --max-old-space-size=512');
sw('disable-features', [
  'HardwareMediaKeyHandling', 'MediaSessionService', 'BackForwardCache', 'Translate', 'OptimizationHints', 'MediaRouter',
  'DialMediaRouteProvider', 'AutofillServerCommunication', 'CertificateTransparencyComponentUpdater', 'InterestFeedContentSuggestions',
  'IsolateOrigins', 'site-per-process', 'SpareRendererForSitePerProcess', 'PrefetchPrivacyChanges', 'Prerender2', 'LensOverlay',
  'GlobalMediaControls', 'PrivacySandboxSettings4', 'FedCm', 'WaylandPerSurfaceScale', 'WaylandFractionalScaleV1',
].join(','));
// videos decoded on the graphics chip (VA-API) where there is one
try {
  fs.accessSync('/dev/dri/renderD128', fs.constants.R_OK | fs.constants.W_OK);
  if (!process.env.LIBGL_ALWAYS_SOFTWARE && process.env.IRIS_GPU !== '0')
    sw('enable-features', 'AcceleratedVideoDecodeLinuxGL,AcceleratedVideoDecodeLinuxZeroCopyGL,AcceleratedVideoEncoder');
} catch (e) {}
for (const a of (process.env.IRIS_ELECTRON_ARGS || '').split(' ').filter(Boolean)) {
  const [k, ...v] = a.replace(/^-+/, '').split('=');
  sw(k, v.length ? v.join('=') : undefined);
}
// Electron's own name out of the user agent (sites treat it as Chrome)
app.userAgentFallback = app.userAgentFallback.replace(/\s(Iris|iris-pages|Electron)\/\S+/g, '');

// no window of its own: closing pages never quits by itself
app.on('window-all-closed', () => {});

// ---- the socket ----

let sock = null;
let inBuf = Buffer.alloc(0);

function send(m) {
  if (!sock || sock.destroyed) return;
  const p = Buffer.from(JSON.stringify(m));
  const h = Buffer.alloc(5);
  h.writeUInt32LE(p.length + 1, 0);
  h[4] = 0;
  sock.cork();
  sock.write(h);
  sock.write(p);
  sock.uncork();
}

function sendFrame(hdr, pix) {
  if (!sock || sock.destroyed) return false;
  const hb = Buffer.from(JSON.stringify(hdr));
  const h = Buffer.alloc(9);
  h.writeUInt32LE(1 + 4 + hb.length + pix.length, 0);
  h[4] = 1;
  h.writeUInt32LE(hb.length, 5);
  sock.cork();
  sock.write(h);
  sock.write(hb);
  sock.write(pix);
  sock.uncork();
  return true;
}

function onData(d) {
  inBuf = inBuf.length ? Buffer.concat([inBuf, d]) : d;
  while (inBuf.length >= 5) {
    const n = inBuf.readUInt32LE(0);
    if (inBuf.length < 4 + n) break;
    const kind = inBuf[4];
    const p = inBuf.subarray(5, 4 + n);
    inBuf = inBuf.subarray(4 + n);
    if (kind !== 0) continue;
    let m;
    try {
      m = JSON.parse(p.toString());
    } catch (e) {
      continue;
    }
    try {
      handle(m);
    } catch (e) {
      console.error('Iris pages:', m.t, e && e.message);
    }
  }
}

// ---- sessions: Iris's containers, private and sandbox tabs ----

const sessions = new Map();
let scripts = [];
let dlSeq = 0;
const downloads = new Map(); // n -> DownloadItem
const reqWait = new Map(); // n -> callback
let reqSeq = 0;

ipcMain.on('iris-scripts', (e) => {
  e.returnValue = scripts;
});

function partitionOf(m) {
  if (m.sandbox) return 'iris-sandbox';
  if (m.private) return 'iris-private';
  if (m.profile) return 'persist:c-' + encodeURIComponent(m.profile).replace(/%/g, '_');
  return 'persist:iris';
}

function viewOfContents(id) {
  for (const v of views.values()) if (v.wc && !v.wc.isDestroyed() && v.wc.id === id) return v;
  return null;
}

const kinds = new Set(['mainFrame', 'subFrame', 'stylesheet', 'script', 'image', 'font', 'object', 'xhr', 'ping', 'cspReport', 'media', 'webSocket', 'other']);

function sessionFor(m) {
  const name = partitionOf(m);
  let ses = sessions.get(name);
  if (ses) return ses;
  ses = session.fromPartition(name, { cache: !m.private && !m.sandbox });
  sessions.set(name, ses);
  ses.setUserAgent(ses.getUserAgent().replace(/\s(Iris|iris-pages|Electron)\/\S+/g, ''));
  ses.setSpellCheckerEnabled && ses.setSpellCheckerEnabled(false);
  const sandbox = !!m.sandbox;
  // the shield and Iris's own checks: every request is asked to Iris (Go),
  // which answers from its filter lists in microseconds
  ses.webRequest.onBeforeRequest({ urls: ['http://*/*', 'https://*/*'] }, (d, cb) => {
    const v = viewOfContents(d.webContentsId);
    if (!v) return cb({});
    const main = d.resourceType === 'mainFrame';
    const n = ++reqSeq;
    const t = setTimeout(() => {
      if (reqWait.delete(n)) cb({});
    }, 3000);
    reqWait.set(n, (r) => {
      clearTimeout(t);
      if (r.a === 'cancel') cb({ cancel: true });
      else if (r.a === 'redirect' && r.u) cb({ redirectURL: r.u });
      else cb({});
    });
    send({ t: 'req', n, id: v.id, url: d.url, type: kinds.has(d.resourceType) ? d.resourceType : 'other', page: main ? d.url : v.wc.getURL(), main });
  });
  // permissions: a sandbox gets none; others what a page needs to work, and
  // nothing that reaches the camera, the microphone or the location
  const allowed = new Set(['fullscreen', 'clipboard-sanitized-write', 'pointerLock', 'keyboardLock', 'background-sync', 'storage-access', 'top-level-storage-access']);
  ses.setPermissionRequestHandler((wc, perm, cb) => cb(!sandbox && allowed.has(perm)));
  ses.setPermissionCheckHandler((wc, perm) => !sandbox && allowed.has(perm));
  ses.on('will-download', (e, item, wc) => {
    if (sandbox) return e.preventDefault();
    const n = ++dlSeq;
    downloads.set(n, item);
    const dir = app.getPath('downloads');
    const base = item.getFilename() || 'download';
    let p = path.join(dir, base);
    for (let i = 1; fs.existsSync(p) && i < 1000; i++) {
      const ext = path.extname(base);
      p = path.join(dir, path.basename(base, ext) + ' (' + i + ')' + ext);
    }
    item.setSavePath(p);
    const v = wc ? viewOfContents(wc.id) : null;
    const report = (state) =>
      send({ t: 'dl', n, id: v ? v.id : 0, url: item.getURL(), path: p, total: item.getTotalBytes() || -1, got: item.getReceivedBytes(), state });
    report(0);
    item.on('updated', (ev, st) => report(st === 'interrupted' ? 3 : item.isPaused() ? 1 : 0));
    item.once('done', (ev, st) => {
      report(st === 'completed' ? 2 : st === 'cancelled' ? 4 : 3);
      downloads.delete(n);
    });
  });
  return ses;
}

// ---- pages ----

const views = new Map(); // Iris's id -> {id, win, wc, shown, params}
const popups = new Map(); // pid -> BrowserWindow, waiting for Iris
let popSeq = 0;
let idleTimer = null;

function prefs(ses) {
  return {
    offscreen: true,
    session: ses,
    sandbox: true,
    contextIsolation: true,
    nodeIntegration: false,
    nodeIntegrationInSubFrames: false,
    webviewTag: false,
    spellcheck: false,
    backgroundThrottling: true,
    devTools: false,
    preload: path.join(__dirname, 'preload.js'),
  };
}

// a page's zoom: the window's scale times the reader's own zoom (Ctrl +/-)
function applyZoom(v) {
  if (v && !v.wc.isDestroyed()) v.wc.setZoomFactor(SCALE * (v.zoom || 1));
}

function idleCheck() {
  if (idleTimer) clearTimeout(idleTimer);
  idleTimer = null;
  if (views.size === 0 && popups.size === 0 && downloads.size === 0)
    idleTimer = setTimeout(() => {
      if (views.size === 0 && popups.size === 0 && downloads.size === 0) app.quit();
    }, IDLE_MS);
}

function host(u) {
  try {
    return new URL(u).hostname.replace(/^www\./, '');
  } catch (e) {
    return '';
  }
}

// site is a host's last two labels (enough to tell another website)
function site(u) {
  const h = host(u).split('.');
  return h.slice(-2).join('.');
}

function history(wc) {
  const h = wc.navigationHistory;
  return h ? [h.canGoBack(), h.canGoForward()] : [wc.canGoBack(), wc.canGoForward()];
}

function attach(v) {
  const { wc, id } = v;
  wc.setFrameRate(60);
  wc.stopPainting(); // until Iris shows it
  wc.on('paint', (e, dirty, image) => paint(v, dirty, image));
  wc.on('did-start-loading', () => {
    const [b, f] = history(wc);
    send({ t: 'loading', id, on: true, back: b, fwd: f });
  });
  wc.on('did-stop-loading', () => {
    const [b, f] = history(wc);
    send({ t: 'loading', id, on: false, back: b, fwd: f });
  });
  wc.on('did-navigate', (e, url) => {
    applyZoom(views.get(id)); // a new site starts at Chromium's own zoom
    send({ t: 'url', id, url });
  });
  wc.on('did-navigate-in-page', (e, url, isMain) => {
    if (isMain !== false) send({ t: 'url', id, url });
  });
  wc.on('page-title-updated', (e, title) => send({ t: 'title', id, title }));
  wc.on('did-fail-load', (e, code, desc, url, isMain) => {
    if (isMain && code !== -3) send({ t: 'failed', id, url, code });
  });
  wc.on('render-process-gone', () => send({ t: 'crashed', id }));
  wc.on('audio-state-changed', () => send({ t: 'audio', id, on: wc.isCurrentlyAudible() }));
  wc.on('enter-html-full-screen', () => send({ t: 'full', id, on: true }));
  wc.on('leave-html-full-screen', () => send({ t: 'full', id, on: false }));
  wc.on('cursor-changed', (e, type) => send({ t: 'cursor', id, name: cursorName(type) }));
  wc.on('context-menu', (e, p) => menu(v, p));
  if (CONSOLE)
    wc.on('console-message', (e, a, b) => {
      const msg = typeof a === 'object' && a ? a.message : b;
      console.error('Iris page ' + id + ': ' + msg);
    });
  // a click to another website: Iris says whether it opens in a new tab
  wc.on('will-navigate', (e, u) => {
    const url = typeof u === 'string' ? u : e.url;
    if (e.isMainFrame === false || e.isSameDocument) return;
    const cur = wc.getURL();
    if (!cur || !/^https?:/.test(url) || site(cur) === site(url)) return;
    e.preventDefault();
    send({ t: 'nav', id, url });
  });
  wc.setWindowOpenHandler((d) => {
    if (d.disposition === 'new-window') {
      // a pop-up (sign-in, payment): a page of its own, kept as the
      // opener's child so window.opener keeps working
      return { action: 'allow', overrideBrowserWindowOptions: { show: false, webPreferences: prefs(wc.session) } };
    }
    send({ t: 'newtab', id, url: d.url });
    return { action: 'deny' };
  });
  wc.on('did-create-window', (win, d) => {
    const pid = ++popSeq;
    popups.set(pid, win);
    send({ t: 'popup', id, url: d.url || '', pid });
  });
}

const cursors = { nodrop: 'no-drop', custom: 'default', hand: 'pointer', ibeam: 'text' };
function cursorName(t) {
  return cursors[t] || t || 'default';
}

// paint sends the part of the frame that changed (the whole frame after a
// show or a resize).
function paint(v, dirty, image) {
  if (!v.shown || !sock) return;
  if (sock.writableLength > 64 << 20) {
    v.full = true; // Iris is behind: this frame is dropped, the next is whole
    return;
  }
  const { width: W, height: H } = image.getSize();
  const bmp = image.toBitmap();
  if (!W || !H || bmp.length < W * H * 4) return;
  let x = 0, y = 0, w = W, h = H;
  if (!v.full && dirty && v.fw === W && v.fh === H) {
    // the changed part (in pixels: the page is at scale 1), a little larger
    const k = 1;
    x = Math.max(0, Math.floor(dirty.x * k) - 1);
    y = Math.max(0, Math.floor(dirty.y * k) - 1);
    w = Math.min(W - x, Math.ceil(dirty.width * k) + 2);
    h = Math.min(H - y, Math.ceil(dirty.height * k) + 2);
    if (w <= 0 || h <= 0) return;
  }
  v.full = false;
  v.fw = W, v.fh = H;
  let pix;
  if (x === 0 && y === 0 && w === W && h === H) pix = bmp;
  else {
    pix = Buffer.allocUnsafe(w * h * 4);
    for (let r = 0; r < h; r++) bmp.copy(pix, r * w * 4, ((y + r) * W + x) * 4, ((y + r) * W + x + w) * 4);
  }
  sendFrame({ id: v.id, fw: W, fh: H, x, y, w, h }, pix);
}

function open(m) {
  if (views.has(m.id)) return;
  const ses = sessionFor(m);
  const win = new BrowserWindow({ show: false, width: 800, height: 600, frame: false, paintWhenInitiallyHidden: true, webPreferences: prefs(ses) });
  const v = { id: m.id, win, wc: win.webContents, shown: false, full: true, main: partitionOf(m) === 'persist:iris' };
  views.set(m.id, v);
  attach(v);
  extTab(v);
  idleCheck();
}

function bind(pid, id) {
  const win = popups.get(pid);
  popups.delete(pid);
  if (!win || win.isDestroyed()) return;
  const v = { id, win, wc: win.webContents, shown: false, full: true, main: win.webContents.session === sessions.get('persist:iris') };
  views.set(id, v);
  attach(v);
  extTab(v);
  send({ t: 'url', id, url: win.webContents.getURL() });
}

function close(id) {
  const v = views.get(id);
  if (!v) return;
  views.delete(id);
  try {
    if (exts) exts.removeTab(v.wc);
  } catch (e) {}
  if (!v.win.isDestroyed()) v.win.destroy();
  idleCheck();
}

function show(v, on) {
  if (v.shown === on) return;
  v.shown = on;
  v.wc.setBackgroundThrottling(!on);
  if (on) {
    v.full = true;
    v.wc.startPainting();
    v.wc.invalidate();
    try {
      if (exts && v.main) exts.selectTab(v.wc);
    } catch (e) {}
  } else {
    v.wc.stopPainting(); // a hidden page costs nothing to draw
  }
}

// ---- the right-click menu: drawn by Iris, chosen here ----

const C = {
  back: 1, fwd: 2, reload: 3,
  linkTab: 10, linkCopy: 11, linkSave: 12,
  imgTab: 20, imgCopyURL: 21, imgSave: 22, imgCopy: 23,
  cut: 30, copy: 31, paste: 32, selectAll: 33, undo: 34, redo: 35,
  search: 40,
};

function menu(v, p) {
  v.params = p;
  const items = [];
  const sep = () => {
    if (items.length && items[items.length - 1].c !== 0) items.push({ c: 0 });
  };
  if (p.linkURL) {
    items.push({ c: C.linkTab, l: 'Open link in new tab', e: true }, { c: C.linkSave, l: 'Save link as…', e: true }, { c: C.linkCopy, l: 'Copy link address', e: true });
  }
  if (p.mediaType === 'image' && p.srcURL) {
    sep();
    items.push({ c: C.imgTab, l: 'Open image in new tab', e: true }, { c: C.imgSave, l: 'Save image as…', e: true },
      { c: C.imgCopy, l: 'Copy image', e: true }, { c: C.imgCopyURL, l: 'Copy image address', e: true });
  }
  const sel = (p.selectionText || '').trim();
  if (sel) {
    sep();
    const shown = sel.length > 32 ? sel.slice(0, 30) + '…' : sel;
    items.push({ c: C.search, l: 'Search Google for “' + shown.replace(/\s+/g, ' ') + '”', e: true });
  }
  const f = p.editFlags || {};
  if (p.isEditable) {
    sep();
    items.push({ c: C.undo, l: 'Undo', e: !!f.canUndo }, { c: C.redo, l: 'Redo', e: !!f.canRedo }, { c: 0 },
      { c: C.cut, l: 'Cut', e: !!f.canCut }, { c: C.copy, l: 'Copy', e: !!f.canCopy }, { c: C.paste, l: 'Paste', e: !!f.canPaste },
      { c: C.selectAll, l: 'Select all', e: !!f.canSelectAll });
  } else if (sel) {
    items.push({ c: C.copy, l: 'Copy', e: true });
  }
  if (!p.linkURL && !sel && !p.isEditable && p.mediaType !== 'image') {
    const [b, fw] = history(v.wc);
    items.push({ c: C.back, l: 'Back', e: b }, { c: C.fwd, l: 'Forward', e: fw }, { c: C.reload, l: 'Reload', e: true });
  }
  while (items.length && items[items.length - 1].c === 0) items.pop();
  if (!items.length) return;
  send({ t: 'menu', id: v.id, x: p.x, y: p.y, items });
}

function menuChoose(v, c) {
  const p = v.params || {};
  const wc = v.wc;
  const h = wc.navigationHistory || wc;
  switch (c) {
    case C.back: return h.goBack();
    case C.fwd: return h.goForward();
    case C.reload: return wc.reload();
    case C.linkTab: return send({ t: 'newtab', id: v.id, url: p.linkURL });
    case C.linkCopy: return clipboard.writeText(p.linkURL || '');
    case C.linkSave: return wc.downloadURL(p.linkURL);
    case C.imgTab: return send({ t: 'newtab', id: v.id, url: p.srcURL });
    case C.imgCopyURL: return clipboard.writeText(p.srcURL || '');
    case C.imgSave: return wc.downloadURL(p.srcURL);
    case C.imgCopy: return wc.copyImageAt(p.x, p.y);
    case C.cut: return wc.cut();
    case C.copy: return wc.copy();
    case C.paste: return wc.paste();
    case C.selectAll: return wc.selectAll();
    case C.undo: return wc.undo();
    case C.redo: return wc.redo();
    case C.search:
      return send({ t: 'newtab', id: v.id, url: 'https://www.google.com/search?q=' + encodeURIComponent((p.selectionText || '').trim()) });
  }
}

// ---- extensions (normal tabs: Iris's default container) ----

let exts = null; // electron-chrome-extensions, where it loads
const extFile = () => path.join(DATA, 'extensions.json');
let extList = []; // [{id, dir, name, version, enabled}]

function extSession() {
  return sessionFor({});
}

function extApi(ses) {
  return ses.extensions || ses;
}

function extSave() {
  try {
    fs.writeFileSync(extFile(), JSON.stringify(extList));
  } catch (e) {}
}

async function extLoad(dir) {
  const x = await extApi(extSession()).loadExtension(dir, { allowFileAccess: true });
  return { id: x.id, name: x.name, version: x.version };
}

async function extStart() {
  try {
    const { ElectronChromeExtensions } = require('electron-chrome-extensions');
    exts = new ElectronChromeExtensions({
      license: 'GPL-3.0',
      session: extSession(),
      createTab: async (d) => {
        // an extension opening a tab: Iris opens it
        const any = [...views.values()].find((v) => v.main);
        if (any) send({ t: 'newtab', id: any.id, url: d.url || 'about:blank' });
        throw new Error('Iris opens the tab');
      },
      selectTab: () => {},
      removeTab: (wc) => {
        const v = viewOfContents(wc.id);
        if (v) send({ t: 'closetab', id: v.id });
      },
    });
  } catch (e) {
    if (DEBUG) console.error('Iris pages: extensions without electron-chrome-extensions:', e && e.message);
  }
  try {
    extList = JSON.parse(fs.readFileSync(extFile(), 'utf8'));
  } catch (e) {
    extList = [];
  }
  for (const x of extList) {
    if (!x.enabled) continue;
    try {
      await extLoad(x.dir);
    } catch (e) {
      console.error('Iris pages: extension', x.name || x.dir, e && e.message);
    }
  }
}

function extTab(v) {
  try {
    if (exts && v.main) exts.addTab(v.wc, v.win);
  } catch (e) {}
}

async function ext(m) {
  const reply = (r) => send({ t: 'reply', n: m.n, r });
  try {
    switch (m.do) {
      case 'add': {
        const x = await extLoad(m.dir);
        extList = extList.filter((e) => e.id !== x.id && e.dir !== m.dir);
        extList.push({ ...x, dir: m.dir, enabled: true });
        extSave();
        return reply({ ID: x.id, Name: x.name, Version: x.version, Enabled: true });
      }
      case 'list':
        return reply(extList.map((x) => ({ ID: x.id, Name: x.name, Version: x.version, Enabled: !!x.enabled })));
      case 'remove': {
        try {
          extApi(extSession()).removeExtension(m.ext);
        } catch (e) {}
        extList = extList.filter((x) => x.id !== m.ext);
        extSave();
        return reply(true);
      }
      case 'enable': {
        const x = extList.find((e) => e.id === m.ext);
        if (x && x.enabled !== !!m.on) {
          x.enabled = !!m.on;
          if (m.on) await extLoad(x.dir);
          else
            try {
              extApi(extSession()).removeExtension(x.id);
            } catch (e) {}
          extSave();
        }
        return reply(true);
      }
    }
  } catch (e) {
    return reply({ Err: (e && e.message) || 'the extension could not be loaded' });
  }
  reply(null);
}

// ---- Iris's messages ----

function handle(m) {
  if (m.t === 'reqr') {
    const f = reqWait.get(m.n);
    if (f) reqWait.delete(m.n), f(m);
    return;
  }
  const v = m.id !== undefined ? views.get(m.id) : null;
  switch (m.t) {
    case 'open': return open(m);
    case 'bind': return bind(m.pid, m.id);
    case 'unpop': {
      const w = popups.get(m.pid);
      popups.delete(m.pid);
      if (w && !w.isDestroyed()) w.destroy();
      return idleCheck();
    }
    case 'close': return close(m.id);
    case 'scale':
      if (m.s >= 0.5 && m.s <= 8 && m.s !== SCALE) {
        SCALE = m.s;
        for (const v of views.values()) applyZoom(v);
      }
      return;
    case 'scripts': scripts = Array.isArray(m.list) ? m.list : []; return;
    case 'scheme': nativeTheme.themeSource = m.dark ? 'dark' : 'light'; return;
    case 'ext': return void ext(m);
    case 'dl': {
      const it = downloads.get(m.n);
      if (!it) return;
      if (m.do === 'cancel') it.cancel();
      else if (m.do === 'pause') it.pause();
      else if (m.do === 'resume') it.resume();
      return;
    }
  }
  if (!v || v.wc.isDestroyed()) {
    if (m.t === 'eval' && m.n) send({ t: 'reply', n: m.n, r: null });
    return;
  }
  const wc = v.wc;
  const h = wc.navigationHistory || wc;
  switch (m.t) {
    case 'nav': return void wc.loadURL(m.url).catch(() => {});
    case 'back': return h.canGoBack() && h.goBack();
    case 'fwd': return h.canGoForward() && h.goForward();
    case 'reload': return wc.reload();
    case 'stop': return wc.stop();
    case 'bounds':
      if (m.w > 0 && m.h > 0) {
        v.win.setContentSize(m.w, m.h);
        v.full = true;
      }
      return;
    case 'show': return show(v, !!m.on);
    case 'focus':
      wc.focus();
      return;
    case 'eval':
      return void wc.executeJavaScript(m.js, true).then(
        (r) => m.n && send({ t: 'reply', n: m.n, r: r === undefined ? null : r }),
        () => m.n && send({ t: 'reply', n: m.n, r: null }),
      );
    case 'mute': return wc.setAudioMuted(!!m.on);
    case 'zoom':
      v.zoom = m.f > 0 ? m.f : 1;
      return applyZoom(v);
    case 'in':
      try {
        if (m.e.type === 'mouseDown' && !wc.isFocused()) wc.focus();
        wc.sendInputEvent(m.e);
      } catch (e) {}
      return;
    case 'menuc':
      if (m.c > 0) menuChoose(v, m.c);
      return;
  }
}

// ---- start ----

app.whenReady().then(async () => {
  await extStart();
  sock = net.createConnection(SOCK);
  sock.on('data', onData);
  sock.on('close', () => app.quit()); // Iris went away
  sock.on('error', () => app.quit());
  send({ t: 'hello', version: process.versions.electron + ' (Chromium ' + process.versions.chrome + ')' });
  if (DEBUG) console.error('Iris pages: Electron ' + process.versions.electron + ', Chromium ' + process.versions.chrome + ', scale ' + SCALE);
  // the engine's memory, for Iris's memory readout
  setInterval(() => {
    let kb = 0;
    for (const p of app.getAppMetrics()) kb += (p.memory && p.memory.workingSetSize) || 0;
    send({ t: 'mem', mb: Math.round(kb / 102.4) / 10 });
    if (process.env.IRIS_MEM_LOG) console.error('Iris pages: memory ' + Math.round(kb / 1024) + ' MB in ' + app.getAppMetrics().length + ' processes');
  }, 5000);
  idleCheck();
});
