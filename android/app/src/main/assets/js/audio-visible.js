// Iris background audio: the page always looks visible, so a site does not
// pause its player when the screen goes off or Iris leaves the screen.
// YouTube above all pauses on the Page Visibility API: when document.hidden
// flips to true its player calls video.pause(). Chromium also suspends media
// for pages it believes are hidden, which no script can reach — the native
// side keeps the page visible too (the WebView subclass, the engine's pause
// left out). Only installed while background audio is on.
(() => {
  'use strict';
  if (window.__irisAudioVisible) return;
  window.__irisAudioVisible = true;

  try { Object.defineProperty(document, 'hidden', { get: () => false, configurable: true }); } catch (e) {}
  try { Object.defineProperty(document, 'visibilityState', { get: () => 'visible', configurable: true }); } catch (e) {}
  // the capture-phase listener runs before the page's own, and stops the
  // event there, so no listener of the page ever sees the page hide
  const swallow = (e) => e.stopImmediatePropagation();
  window.addEventListener('visibilitychange', swallow, true);
  document.addEventListener('visibilitychange', swallow, true);
})();
