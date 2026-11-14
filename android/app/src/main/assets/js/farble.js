(() => {
  const host = location.hostname;
  if (!host || /(^|\.)(google\.[a-z.]+|youtube\.com|gstatic\.com|recaptcha\.net|hcaptcha\.com|cloudflare\.com|microsoftonline\.com|live\.com|apple\.com|paypal\.com)$/.test(host) ||
      /^(accounts|login|auth|signin|id)\./.test(host)) return;
  let h = SEED >>> 0;
  for (let i = 0; i < host.length; i++) h = Math.imul(h ^ host.charCodeAt(i), 16777619) >>> 0;
  const rnd = () => { h ^= h << 13; h >>>= 0; h ^= h >>> 17; h ^= h << 5; h >>>= 0; return h / 4294967296; };
  const seedAt = h;
  const noise = (d) => { let s = seedAt; for (let i = 0; i < d.length; i += 4 * (61 + (s % 89))) { s = Math.imul(s ^ i, 2654435761) >>> 0; d[i + (s % 3)] ^= 1; } };
  try {
    // only canvases read the way fingerprinting reads them: off the page, small,
    // read a few times. A canvas on the page that a site draws and reads back
    // (effects, editors, games, image tools) is left exact, and the noise never
    // goes into a page's own canvas: exports are made from a copy.
    const C2D = CanvasRenderingContext2D.prototype, gid = C2D.getImageData;
    const reads = new WeakMap();
    const fp = (cv) => { if (!cv || cv.isConnected || !cv.width || !cv.height || cv.width * cv.height > 262144) return false; const n = (reads.get(cv) || 0) + 1; reads.set(cv, n); return n <= 3; };
    C2D.getImageData = function (...a) { const r = gid.apply(this, a); if (fp(this.canvas)) noise(r.data); return r; };
    const copy = (cv) => { if (!fp(cv)) return cv; try { const c = document.createElement('canvas'); c.width = cv.width; c.height = cv.height; const x = c.getContext('2d'); x.drawImage(cv, 0, 0); const r = gid.call(x, 0, 0, c.width, c.height); noise(r.data); x.putImageData(r, 0, 0); return c; } catch (e) { return cv; } };
    const HC = HTMLCanvasElement.prototype, tdu = HC.toDataURL, tb = HC.toBlob;
    HC.toDataURL = function (...a) { return tdu.apply(copy(this), a); };
    HC.toBlob = function (...a) { return tb.apply(copy(this), a); };
    const AB = AudioBuffer.prototype, gcd = AB.getChannelData;
    const done = new WeakSet();
    AB.getChannelData = function (...a) { const d = gcd.apply(this, a); if (!done.has(d)) { done.add(d); let s = seedAt; for (let i = 0; i < d.length; i += 97) { s = Math.imul(s ^ i, 2654435761) >>> 0; d[i] += ((s & 1023) / 1023 - 0.5) * 1e-7; } } return d; };
    const cores = [2, 4, 4, 6, 8][(rnd() * 5) | 0];
    Object.defineProperty(Navigator.prototype, 'hardwareConcurrency', { get: () => cores, configurable: true });
    Object.defineProperty(Navigator.prototype, 'deviceMemory', { get: () => 8, configurable: true });
  } catch (e) {}
})();
