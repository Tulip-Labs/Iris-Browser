package core

// YouTubeScript removes ads from the YouTube player's data before the player
// reads it (instead of blocking ad requests, which YouTube detects). It prunes
// the ad fields from the initial player response, from JSON the page parses,
// and from /youtubei/v1/player responses. It does nothing on other sites.
const YouTubeScript = `(() => {
  if (!/(^|\.)youtube\.com$/.test(location.hostname) || window.__liteGoYT) return;
  window.__liteGoYT = true;
  const KEYS = ['adPlacements', 'adSlots', 'playerAds', 'adBreakHeartbeatParams'];
  const prune = (o) => {
    try {
      if (o && typeof o === 'object') {
        for (const k of KEYS) if (k in o) delete o[k];
        if (o.playerResponse && typeof o.playerResponse === 'object') prune(o.playerResponse);
      }
    } catch (e) {}
    return o;
  };
  const parse = JSON.parse;
  JSON.parse = function () { return prune(parse.apply(this, arguments)); };
  let initial;
  try {
    Object.defineProperty(window, 'ytInitialPlayerResponse', {
      configurable: true,
      get() { return initial; },
      set(v) { initial = prune(v); },
    });
  } catch (e) {}
  const fetch0 = window.fetch;
  window.fetch = async function (input, init) {
    const res = await fetch0.call(this, input, init);
    try {
      const u = typeof input === 'string' ? input : (input && input.url) || '';
      if (/\/youtubei\/v1\/player\b/.test(u) && res.ok) {
        const data = prune(parse(await res.clone().text()));
        return new Response(JSON.stringify(data), { status: res.status, statusText: res.statusText, headers: res.headers });
      }
    } catch (e) {}
    return res;
  };
})();`

// YouTubeLightScript makes YouTube lighter: it asks for H.264 video (decoded by
// the graphics chip, with smaller buffers than VP9 and AV1) when the engine
// can play H.264, switches off the
// ambient glow drawn around the player and the video previews that play when
// the pointer rests on a thumbnail, and skips the animated thumbnails.
const YouTubeLightScript = `(() => {
  if (!/(^|\.)youtube\.com$/.test(location.hostname) || window.__liteGoYTLight) return;
  window.__liteGoYTLight = true;
  const heavy = /vp0?9|av01/i;
  try {
    const ms = window.MediaSource;
    // only where H.264 really plays: some systems (Fedora without OpenH264 or
    // RPM Fusion, for one) have VP9 and AV1 but no H.264, and hiding those
    // would leave YouTube with nothing it can play
    const h264 = !!(ms && ms.isTypeSupported && ms.isTypeSupported('video/mp4; codecs="avc1.4d401f"'));
    if (!h264) throw 0;
    if (ms && ms.isTypeSupported) {
      const orig = ms.isTypeSupported.bind(ms);
      ms.isTypeSupported = (t) => heavy.test(t) ? false : orig(t);
    }
    const mc = navigator.mediaCapabilities;
    if (mc && mc.decodingInfo) {
      const orig = mc.decodingInfo.bind(mc);
      mc.decodingInfo = (c) => {
        const t = (c && c.video && c.video.contentType) || '';
        return heavy.test(t) ? Promise.resolve({supported: false, smooth: false, powerEfficient: false}) : orig(c);
      };
    }
    const cp = HTMLMediaElement.prototype.canPlayType;
    HTMLMediaElement.prototype.canPlayType = function (t) { return heavy.test(t) ? '' : cp.call(this, t); };
  } catch (e) {}
  const css = '#cinematics, #cinematics-container, ytd-video-preview, #video-preview, #mouseover-overlay,' +
    ' ytd-moving-thumbnail-renderer { display: none !important; }';
  const add = () => {
    const s = document.createElement('style');
    s.textContent = css;
    (document.head || document.documentElement).appendChild(s);
  };
  if (document.documentElement) add(); else document.addEventListener('DOMContentLoaded', add);
})();`
