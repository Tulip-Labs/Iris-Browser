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
  // An ad that still plays is never seen: while the player says "ad", its
  // video is see-through and muted (style, before the first frame), then
  // skipped or run to its end at once.
  const css = 'ytd-ad-slot-renderer, ytd-in-feed-ad-layout-renderer, ytd-display-ad-renderer, ytd-promoted-sparkles-web-renderer,' +
    ' ytd-promoted-video-renderer, ytd-banner-promo-renderer, ytd-statement-banner-renderer, ytd-companion-slot-renderer,' +
    ' ytd-action-companion-ad-renderer, ytd-player-legacy-desktop-watch-ads-renderer, #player-ads, #masthead-ad,' +
    ' ytd-rich-item-renderer:has(> #content > ytd-ad-slot-renderer), ytd-merch-shelf-renderer,' +
    ' ytd-video-masthead-ad-v3-renderer, ytd-search-pyv-renderer, ytd-ads-engagement-panel-content-renderer,' +
    ' ytd-engagement-panel-section-list-renderer[target-id="engagement-panel-ads"], ytd-rich-section-renderer:has(ytd-statement-banner-renderer),' +
    ' .ytp-ad-overlay-container, .ytp-ad-overlay-slot, .ytp-ad-image-overlay, ytm-promoted-sparkles-web-renderer,' +
    ' ytm-companion-ad-renderer, ytm-promoted-video-renderer, ad-slot-renderer { display: none !important; }' +
    ' .iris-ad.ad-showing video, .iris-ad.ad-interrupting video, .iris-ad.ad-showing .ytp-ad-player-overlay,' +
    ' .iris-ad.ad-showing .ytp-ad-player-overlay-layout { opacity: 0 !important; }';
  let styled = false;
  const style = () => {
    if (styled || !document.documentElement) return;
    const s = document.createElement('style');
    s.textContent = css;
    (document.head || document.documentElement).appendChild(s);
    styled = true;
  };
  let saved = null; // the video's own sound and speed, while an ad plays
  const skipSel = '.ytp-skip-ad-button, .ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-ad-skip-button-container button,' +
    ' .ytp-ad-skip-button-slot button, .ytp-skip-ad button, button[id^="skip-button"]';
  const marked = (p) => p.classList.contains('ad-showing') || p.classList.contains('ad-interrupting');
  // YouTube's own ad parts in the player: a class left behind with none of
  // them for STALE ms is no ad, and the video shows and sounds again
  const adSel = '.ytp-ad-player-overlay, .ytp-ad-player-overlay-layout, .ytp-ad-text, .ytp-ad-preview-container,' +
    ' .ytp-ad-module > *, .video-ads > *, .ytp-ad-persistent-progress-bar-container, .ytp-ad-simple-ad-badge';
  const STALE = 3000;
  let adSeen = 0, markedSince = 0;
  const isAd = (p) => {
    if (!marked(p)) {
      markedSince = 0;
      p.classList.remove('iris-ad');
      return false;
    }
    const now = Date.now();
    if (!markedSince) markedSince = now;
    if (p.querySelector(adSel)) adSeen = now;
    const ad = now - Math.max(adSeen, markedSince) < STALE;
    p.classList.toggle('iris-ad', ad);
    return ad;
  };
  const tick = () => {
    style();
    const player = document.querySelector('#movie_player, .html5-video-player');
    const v = player && player.querySelector('video');
    if (!v) return;
    if (isAd(player)) {
      if (!saved) saved = { muted: v.muted, rate: v.playbackRate };
      v.muted = true;
      const b = player.querySelector(skipSel) || document.querySelector(skipSel);
      if (b) b.click();
      try { if (v.playbackRate < 16) v.playbackRate = 16; } catch (e) {}
      if (isFinite(v.duration) && v.duration > 0.2 && v.currentTime < v.duration - 0.15) {
        try { v.currentTime = v.duration - 0.05; } catch (e) {}
      }
      if (v.paused && v.readyState > 0) v.play().catch(() => {});
    } else if (saved) {
      v.muted = saved.muted;
      v.playbackRate = saved.rate > 0 && saved.rate <= 4 ? saved.rate : 1;
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
  // class change on the page: YouTube changes thousands a second. The check
  // runs in the same task as the change (no frame later), and again when
  // the video learns its length or plays (media events, caught on their way
  // down); a slow check covers the rest.
  let watched = null;
  const watch = new MutationObserver(tick);
  const follow = () => {
    const p = document.querySelector('#movie_player, .html5-video-player');
    if (p && p !== watched) {
      watch.disconnect();
      watch.observe(p, { attributes: true, attributeFilter: ['class'] });
      watched = p;
    }
    tick();
  };
  const onMedia = (e) => {
    if (!(e.target instanceof HTMLVideoElement)) return;
    const p = e.target.closest('#movie_player, .html5-video-player');
    if (p && (marked(p) || saved)) tick();
  };
  for (const ev of ['loadedmetadata', 'durationchange', 'playing', 'timeupdate']) document.addEventListener(ev, onMedia, true);
  style();
  document.addEventListener('DOMContentLoaded', follow, { once: true });
  setInterval(follow, 500);
})();
