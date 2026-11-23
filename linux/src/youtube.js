// Iris on YouTube: no ads, and nothing for YouTube to notice. The same file
// in Iris for Linux and Android (CI compares them). Runs at document start in
// the page's own world, before YouTube's scripts, as uBlock Origin's and
// Brave's YouTube scriptlets do:
//  1. the player's answer loses its ads before the player reads it (from the
//     page's HTML, fetch, XHR or JSON.parse), so no ad is ever scheduled and
//     there is no blocked request for YouTube to find;
//  2. the ad blocker notice is taken out of the same answers;
//  3. whatever still gets through (an ad slot in the feed, an ad that
//     plays) is hidden or skipped, muted.
// The patched functions answer toString like the browser's own.
(() => {
  'use strict';
  if (!/(^|\.)youtube(-nocookie)?\.com$/.test(location.hostname)) return;

  // ---------------------------------------------------------------- unseen
  const native = new WeakMap();
  const realToString = Function.prototype.toString;
  const toString = { toString() { return native.has(this) ? native.get(this) : realToString.call(this); } }.toString;
  native.set(toString, realToString.call(realToString));
  const disguise = (fake, real) => {
    native.set(fake, realToString.call(real));
    try { Object.defineProperty(fake, 'name', { value: real.name }); } catch (e) {}
    try { Object.defineProperty(fake, 'length', { value: real.length }); } catch (e) {}
    return fake;
  };
  try {
    Object.defineProperty(Function.prototype, 'toString', { value: toString, writable: true, configurable: true, enumerable: false });
  } catch (e) {}

  // ---------------------------------------------------------------- 1, 2
  const AD_KEYS = ['adPlacements', 'playerAds', 'adSlots', 'adBreakHeartbeatParams'];
  const WALL_KEYS = ['enforcementMessageViewModel', 'bkaEnforcementMessageViewModel'];
  const clean = (r) => {
    if (!r || typeof r !== 'object') return;
    for (const k of AD_KEYS) if (Object.prototype.hasOwnProperty.call(r, k)) delete r[k];
    const m = r.auxiliaryUi && r.auxiliaryUi.messageRenderers;
    if (m && typeof m === 'object') for (const k of WALL_KEYS) delete m[k];
  };
  const strip = (o) => {
    if (o && typeof o === 'object') {
      clean(o);
      clean(o.playerResponse);
      clean(o.raw_player_response);
      if (o.args) clean(o.args.raw_player_response);
    }
    return o;
  };
  const realParse = JSON.parse;
  const realStringify = JSON.stringify;
  const PLAYER = /\/youtubei\/v1\/(player|next|reel|get_watch)\b/;
  const stripText = (t) => {
    if (typeof t !== 'string' || t.indexOf('adPlacements') < 0 && t.indexOf('playerAds') < 0 && t.indexOf('adSlots') < 0 && t.indexOf('nforcementMessageViewModel') < 0) return t;
    try { return realStringify(strip(realParse(t))); } catch (e) { return t; }
  };

  // any JSON YouTube parses
  JSON.parse = disguise(function parse(text, reviver) {
    return strip(realParse.apply(this, arguments));
  }, realParse);

  // the first answer, written into the page's HTML
  for (const name of ['ytInitialPlayerResponse', 'ytPlayerResponse']) {
    let value;
    try {
      Object.defineProperty(window, name, {
        configurable: true,
        enumerable: true,
        get() { return value; },
        set(v) { value = strip(v); },
      });
    } catch (e) {}
  }

  // the player's later answers, by fetch
  const R = Response.prototype;
  const realJson = R.json;
  const realText = R.text;
  R.json = disguise(function json() {
    const p = realJson.apply(this, arguments);
    return PLAYER.test(this.url) ? p.then(strip) : p;
  }, realJson);
  R.text = disguise(function text() {
    const p = realText.apply(this, arguments);
    return PLAYER.test(this.url) ? p.then(stripText) : p;
  }, realText);

  // and by XHR (YouTube for phones)
  const X = XMLHttpRequest.prototype;
  const realOpen = X.open;
  const urls = new WeakMap();
  const cleaned = new WeakMap();
  X.open = disguise(function open(method, url) {
    urls.set(this, String(url));
    cleaned.delete(this);
    return realOpen.apply(this, arguments);
  }, realOpen);
  for (const prop of ['responseText', 'response']) {
    const d = Object.getOwnPropertyDescriptor(X, prop);
    if (!d || !d.get) continue;
    const get = d.get;
    Object.defineProperty(X, prop, {
      configurable: d.configurable,
      enumerable: d.enumerable,
      get: disguise(function () {
        const v = get.call(this);
        if (this.readyState !== 4 || !PLAYER.test(urls.get(this) || '')) return v;
        if (typeof v === 'string') {
          const c = cleaned.get(this);
          if (c && c[0] === v) return c[1];
          const s = stripText(v);
          cleaned.set(this, [v, s]);
          return s;
        }
        return strip(v);
      }, get),
    });
  }

  // ---------------------------------------------------------------- 3
  const css = 'ytd-ad-slot-renderer, ytd-in-feed-ad-layout-renderer, ytd-display-ad-renderer, ytd-promoted-sparkles-web-renderer,' +
    ' ytd-promoted-video-renderer, ytd-banner-promo-renderer, ytd-statement-banner-renderer, ytd-companion-slot-renderer,' +
    ' ytd-action-companion-ad-renderer, ytd-player-legacy-desktop-watch-ads-renderer, #player-ads, #masthead-ad,' +
    ' ytd-rich-item-renderer:has(> #content > ytd-ad-slot-renderer), ytd-merch-shelf-renderer,' +
    ' .ytp-ad-overlay-container, .ytp-ad-overlay-slot, ytm-promoted-sparkles-web-renderer,' +
    ' ytm-companion-ad-renderer, ad-slot-renderer { display: none !important; }';
  let styled = false;
  const style = () => {
    if (styled || !document.documentElement) return;
    const s = document.createElement('style');
    s.textContent = css;
    (document.head || document.documentElement).appendChild(s);
    styled = true;
  };
  let saved = null; // the video's own sound and speed, while an ad plays
  const skipSel = '.ytp-skip-ad-button, .ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-ad-skip-button-container button, button[id^="skip-button"]';
  const tick = () => {
    style();
    const player = document.querySelector('#movie_player, .html5-video-player');
    const v = player && player.querySelector('video');
    if (!v) return;
    const ad = player.classList.contains('ad-showing') || player.classList.contains('ad-interrupting');
    if (ad) {
      if (!saved) saved = { muted: v.muted, rate: v.playbackRate };
      v.muted = true;
      try { v.playbackRate = 16; } catch (e) {}
      if (isFinite(v.duration) && v.duration > 0.5 && v.currentTime < v.duration - 0.3) {
        try { v.currentTime = v.duration - 0.1; } catch (e) {}
      }
      const b = document.querySelector(skipSel);
      if (b) b.click();
      if (v.paused) v.play().catch(() => {});
    } else if (saved) {
      v.muted = saved.muted;
      v.playbackRate = saved.rate || 1;
      saved = null;
    }
    // YouTube's ad blocker notice, if one still comes: close it and play on
    const wall = document.querySelector('ytd-enforcement-message-view-model');
    if (wall) {
      const dlg = wall.closest('tp-yt-paper-dialog, ytd-popup-container > *') || wall;
      dlg.remove();
      document.querySelectorAll('tp-yt-iron-overlay-backdrop').forEach((e) => e.remove());
      if (document.body) document.body.style.overflow = '';
      if (v.paused) v.play().catch(() => {});
    }
  };
  // Watch only the player's own class (YouTube marks ads there), not every
  // class change on the page: YouTube changes thousands a second. A slow
  // check covers the rest.
  let watched = null, queued = false;
  const soon = () => {
    if (queued) return;
    queued = true;
    requestAnimationFrame(() => { queued = false; tick(); });
  };
  const watch = new MutationObserver(soon);
  const follow = () => {
    const p = document.querySelector('#movie_player, .html5-video-player');
    if (p && p !== watched) {
      watch.disconnect();
      watch.observe(p, { attributes: true, attributeFilter: ['class'] });
      watched = p;
    }
    tick();
  };
  style();
  document.addEventListener('DOMContentLoaded', follow, { once: true });
  setInterval(follow, 500);
})();
