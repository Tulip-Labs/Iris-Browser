// Iris background audio: reports when a page starts or stops playing sound,
// so Iris can keep it playing with the screen off and show the controls.
// It changes nothing on the page: it only listens, and writes one line to
// the console when the state flips. The app reads that line (WebChromeClient
// / CefriumChromeClient onConsoleMessage). Installed on every page, whether
// background audio is on or not; the app only acts on it while it is on.
(() => {
  'use strict';
  // installed again (Iris asks for a fresh report when background audio is
  // switched on): say again whether sound plays, without a second install
  if (window.__irisAudio) {
    try { window.__irisAudioReport(); } catch (e) {}
    return;
  }
  window.__irisAudio = true;

  let playing = false;
  const report = () => {
    const now = [...document.querySelectorAll('audio,video')].some((m) => !m.paused && !m.ended);
    if (now === playing) return;
    playing = now;
    try { console.log('[iris-audio] ' + (playing ? 'playing' : 'paused')); } catch (e) {}
  };
  window.__irisAudioReport = report;
  const watch = (el) => {
    if (!el || el.__irisAudio) return;
    el.__irisAudio = true;
    for (const ev of ['play', 'playing', 'pause', 'ended', 'emptied']) el.addEventListener(ev, report);
  };
  const scan = () => document.querySelectorAll('audio,video').forEach(watch);
  // a player the page swaps in later (YouTube rebuilds its video element)
  // is caught the same way, as soon as it appears
  try {
    new MutationObserver(() => { scan(); report(); }).observe(document.documentElement, { childList: true, subtree: true });
  } catch (e) {}
  scan();
  report();
})();
