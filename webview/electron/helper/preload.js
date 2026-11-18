'use strict';
// Iris's scripts (YouTube's ad skipping, the shields' page parts and the
// like) run in each page's own world before the page's scripts. The preload
// runs sandboxed and isolated; webFrame puts them in the page's world.
const { ipcRenderer, webFrame } = require('electron');
try {
  const list = ipcRenderer.sendSync('iris-scripts');
  if (Array.isArray(list)) for (const s of list) webFrame.executeJavaScript(s).catch(() => {});
} catch (e) {}
