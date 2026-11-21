(() => {
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
})();
