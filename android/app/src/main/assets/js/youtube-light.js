(() => {
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
})();
