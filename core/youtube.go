package core

import (
	"strconv"
	"strings"
)

// YouTubeScript gets past YouTube's ads without YouTube seeing an ad
// blocker. YouTube checks that its ad requests go through and that the ad
// data reaches its player, so Iris no longer blocks or edits either on
// youtube.com (the shield lets YouTube's requests through). Instead, when an
// ad starts in the player, this script mutes it, plays it at 16x, jumps to its
// end and presses Skip as soon as there is one; then the video goes on with
// the sound and speed it had. Ad boxes around the videos are hidden, and if
// YouTube still puts up its "ad blockers are not allowed" notice, it is closed
// and the video resumes. It does nothing on other sites.
const YouTubeScript = `(() => {
  if (!/(^|\.)youtube\.com$/.test(location.hostname) || window.__irisYT) return;
  window.__irisYT = true;
  const css = 'ytd-ad-slot-renderer, ytd-in-feed-ad-layout-renderer, ytd-display-ad-renderer, ytd-promoted-sparkles-web-renderer,' +
    ' ytd-promoted-video-renderer, ytd-banner-promo-renderer, ytd-statement-banner-renderer, ytd-companion-slot-renderer,' +
    ' ytd-action-companion-ad-renderer, ytd-player-legacy-desktop-watch-ads-renderer, #player-ads, #masthead-ad,' +
    ' ytd-rich-item-renderer:has(> #content > ytd-ad-slot-renderer), ytd-merch-shelf-renderer,' +
    ' .ytp-ad-overlay-container, .ytp-ad-overlay-slot, ytm-promoted-sparkles-web-renderer { display: none !important; }';
  const style = () => {
    if (document.getElementById('iris-yt')) return;
    const s = document.createElement('style');
    s.id = 'iris-yt';
    s.textContent = css;
    (document.head || document.documentElement).appendChild(s);
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
    // YouTube's ad blocker notice, if it still comes: close it and play on
    const wall = document.querySelector('ytd-enforcement-message-view-model');
    if (wall) {
      const dlg = wall.closest('tp-yt-paper-dialog, ytd-popup-container > *') || wall;
      dlg.remove();
      document.querySelectorAll('tp-yt-iron-overlay-backdrop').forEach((e) => e.remove());
      document.body && (document.body.style.overflow = '');
      if (v.paused) v.play().catch(() => {});
    }
  };
  // Watch only the player's own class (YouTube marks ads there), not every
  // class change on the page: YouTube changes thousands a second, and running
  // on each one made it lag. A slow check covers the rest.
  let watched = null, queued = false;
  const soon = () => {
    if (queued) return;
    queued = true;
    requestAnimationFrame(() => { queued = false; tick(); });
  };
  const watch = new MutationObserver(soon);
  setInterval(() => {
    const p = document.querySelector('#movie_player, .html5-video-player');
    if (p && p !== watched) {
      watch.disconnect();
      watch.observe(p, { attributes: true, attributeFilter: ['class'] });
      watched = p;
    }
    tick();
  }, 500);
})();`

// IsYouTube says whether the page is YouTube, where the shield lets every
// request through (see YouTubeScript).
func IsYouTube(page string) bool {
	h := strings.TrimPrefix(Host(page), "www.")
	return h == "youtube.com" || strings.HasSuffix(h, ".youtube.com") || h == "youtube-nocookie.com"
}

// YouTubeLightScript makes YouTube lighter: it asks for H.264 video (decoded by
// the graphics chip, with smaller buffers than VP9 and AV1) when the engine
// can play H.264, switches off the
// ambient glow drawn around the player and the video previews that play when
// the pointer rests on a thumbnail, and skips the animated thumbnails.
const YouTubeLightScript = `(() => {
  if (!/(^|\.)youtube\.com$/.test(location.hostname) || window.__irisYTLight) return;
  window.__irisYTLight = true;
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

// H264Script lets a page's H.264 videos play where the engine cannot decode
// them (Iris's Chromium on Linux): it says MP4 may play, so players offer
// their MP4 file, and when a video then fails as unplayable it is pointed at
// Iris's video relay (relay, which ends in "u="), which converts it.
// Streams (HLS, .m3u8: LinkedIn, X, news sites) are nearly always H.264 too:
// it says players may hand them to the video element as they are, so they
// go to the relay whole. Videos made of pieces in the page (blob:
// addresses) are left alone.
func H264Script(relay string) string {
	return `(() => {
  if (window.__irisH264) return;
  window.__irisH264 = true;
  const RELAY = ` + strconv.Quote(relay) + `;
  const cpt = HTMLMediaElement.prototype.canPlayType;
  HTMLMediaElement.prototype.canPlayType = function (t) {
    const r = cpt.call(this, t);
    return !r && /video\/mp4|audio\/mp4|avc1|avc3|hvc1|hev1|hevc|h265|mp4a|video\/quicktime|video\/x-matroska|mpegurl/i.test(t || '') ? 'maybe' : r;
  };
  const fix = (v) => {
    if (!v || v.__lgRelay) return;
    let src = v.currentSrc || v.src;
    if (!src) { const s = v.querySelector('source[src]'); src = s && s.src; }
    if (!src || !/^https?:/.test(src) || src.startsWith(RELAY.slice(0, 30))) return;
    v.__lgRelay = true;
    // a player that already caught the first error (video.js: LinkedIn and
    // many news sites) keeps its error notice over the video: cleared
    const p = v.closest && v.closest('.video-js');
    if (p) p.classList.remove('vjs-error');
    const play = !v.paused || v.autoplay || v.hasAttribute('autoplay');
    v.querySelectorAll('source').forEach((s) => s.remove());
    v.src = RELAY + encodeURIComponent(src) + '&r=' + encodeURIComponent(location.href);
    v.load();
    if (play) v.play().catch(() => {});
  };
  document.addEventListener('error', (e) => {
    const t = e.target;
    let v = null;
    if (t instanceof HTMLVideoElement && t.error && t.error.code === 4) v = t;
    else if (t instanceof HTMLSourceElement && t.parentElement instanceof HTMLVideoElement && !t.nextElementSibling) v = t.parentElement;
    if (!v || v.__lgRelay) return;
    fix(v);
    // the page's own player never hears of the error the relay mends (this
    // listener runs first: capturing, on the document)
    if (v.__lgRelay) e.stopImmediatePropagation();
  }, true);
  // videos that failed before this script ran, or whose error was caught by
  // their player: look again now and then
  const sweep = () => document.querySelectorAll('video').forEach((v) => {
    if (v.error && v.error.code === 4) fix(v);
  });
  sweep();
  setInterval(sweep, 1500);
})();`
}
