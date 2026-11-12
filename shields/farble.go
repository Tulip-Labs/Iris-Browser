package shields

import (
	"crypto/rand"
	"encoding/binary"
	"strconv"
	"strings"
)

// Fingerprinting protection, the way Brave does it ("farbling"): what a page
// can measure about this computer (canvas and audio drawing, the number of
// processor cores) changes very slightly, differently for every site and every
// session, so trackers cannot use it to recognise you from site to site, while
// pages still work. Sign-in and human-check pages are left exactly as they are.
const farbleTemplate = `(() => {
  const host = location.hostname;
  if (!host || /(^|\.)(google\.[a-z.]+|youtube\.com|gstatic\.com|recaptcha\.net|hcaptcha\.com|cloudflare\.com|microsoftonline\.com|live\.com|apple\.com|paypal\.com)$/.test(host) ||
      /^(accounts|login|auth|signin|id)\./.test(host)) return;
  let h = SEED >>> 0;
  for (let i = 0; i < host.length; i++) h = Math.imul(h ^ host.charCodeAt(i), 16777619) >>> 0;
  const rnd = () => { h ^= h << 13; h >>>= 0; h ^= h >>> 17; h ^= h << 5; h >>>= 0; return h / 4294967296; };
  const seedAt = h;
  const noise = (d) => { let s = seedAt; for (let i = 0; i < d.length; i += 4 * (61 + (s % 89))) { s = Math.imul(s ^ i, 2654435761) >>> 0; d[i + (s % 3)] ^= 1; } };
  try {
    const C2D = CanvasRenderingContext2D.prototype, gid = C2D.getImageData;
    C2D.getImageData = function (...a) { const r = gid.apply(this, a); noise(r.data); return r; };
    const touch = (cv) => { try { const c = cv.getContext('2d'); if (c && cv.width && cv.height && cv.width * cv.height < 4e6) { const r = gid.call(c, 0, 0, cv.width, cv.height); noise(r.data); c.putImageData(r, 0, 0); } } catch (e) {} };
    const HC = HTMLCanvasElement.prototype, tdu = HC.toDataURL, tb = HC.toBlob;
    HC.toDataURL = function (...a) { touch(this); return tdu.apply(this, a); };
    HC.toBlob = function (...a) { touch(this); return tb.apply(this, a); };
    const AB = AudioBuffer.prototype, gcd = AB.getChannelData;
    const done = new WeakSet();
    AB.getChannelData = function (...a) { const d = gcd.apply(this, a); if (!done.has(d)) { done.add(d); let s = seedAt; for (let i = 0; i < d.length; i += 97) { s = Math.imul(s ^ i, 2654435761) >>> 0; d[i] += ((s & 1023) / 1023 - 0.5) * 1e-7; } } return d; };
    const cores = [2, 4, 4, 6, 8][(rnd() * 5) | 0];
    Object.defineProperty(Navigator.prototype, 'hardwareConcurrency', { get: () => cores, configurable: true });
    Object.defineProperty(Navigator.prototype, 'deviceMemory', { get: () => 8, configurable: true });
  } catch (e) {}
})();`

// FarbleScript returns the protection script with this session's secret seed.
func FarbleScript() string {
	var b [4]byte
	_, _ = rand.Read(b[:])
	return strings.Replace(farbleTemplate, "SEED", strconv.FormatUint(uint64(binary.LittleEndian.Uint32(b[:])), 10), 1)
}

// CollectScript reads the classes and ids used on a page (for the generic hiding rules).
const CollectScript = `(() => {
  const c = new Set(), i = new Set();
  const all = document.querySelectorAll('[class],[id]');
  for (let k = 0; k < all.length && k < 6000; k++) {
    const el = all[k];
    if (el.id) i.add(el.id);
    const cl = el.classList;
    for (let j = 0; j < cl.length; j++) c.add(cl[j]);
  }
  return {c: [...c].slice(0, 4000), i: [...i].slice(0, 2000)};
})()`

// InjectCSS returns a script that adds (or extends) Lite Go's hiding style sheet.
func InjectCSS(css string) string {
	q := strconv.Quote(css)
	return `(() => { const add = () => { let s = document.getElementById('lite-shields'); if (!s) { s = document.createElement('style'); s.id = 'lite-shields'; (document.head || document.documentElement).appendChild(s); } s.textContent += ` + q + `; }; if (document.documentElement) add(); else document.addEventListener('DOMContentLoaded', add); })();`
}
