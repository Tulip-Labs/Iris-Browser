(() => {
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
})();
