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
