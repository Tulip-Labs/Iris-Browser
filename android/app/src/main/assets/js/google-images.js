(() => {
  window.scrollTo(0, document.body.scrollHeight / 3);
  const out = [], seen = new Set();
  // Google keeps each picture's full-size address in the page's data, after
  // its thumbnail: ["https://encrypted-tbn0.gstatic.com/images?q=tbn:ID",h,w],["full",H,W]
  const big = new Map();
  const unesc = (u) => u.replace(/\\u003d/g, '=').replace(/\\u0026/g, '&').replace(/\\\//g, '/');
  try {
    const re = /\["https:\/\/encrypted-tbn\d\.gstatic\.com\/images\?q(?:=|\\u003d)tbn:([A-Za-z0-9_-]+)[^"]*",\d+,\d+\],\["(https?:\/\/[^"]+)",(\d+),(\d+)\]/g;
    for (const sc of document.scripts) {
      const t = sc.textContent;
      if (!t || t.indexOf('encrypted-tbn') < 0) continue;
      let m;
      while ((m = re.exec(t))) if (!big.has(m[1])) big.set(m[1], unesc(m[2]));
    }
  } catch (e) {}
  const fullOf = (src) => {
    const m = /tbn:([A-Za-z0-9_-]+)/.exec(src);
    return m ? big.get(m[1]) || '' : '';
  };
  for (const img of document.querySelectorAll('img')) {
    const src = img.getAttribute('src') || img.dataset.src || '';
    if (!src || seen.has(src)) continue;
    if (!/^data:image\/(jpeg|png|webp)|^https:\/\/encrypted-tbn\d?\.gstatic\.com\//.test(src)) continue;
    const r = img.getBoundingClientRect();
    if ((img.naturalWidth || r.width) < 50) continue;
    let page = '', full = '', p = img;
    for (let i = 0; i < 10 && p; i++, p = p.parentElement) {
      if (p.dataset && p.dataset.lpage) { page = page || p.dataset.lpage; }
      if (p.dataset && p.dataset.ou) { full = full || p.dataset.ou; }
      if (p.tagName === 'A' && p.href) {
        try {
          const x = new URL(p.href);
          const ref = x.searchParams.get('imgrefurl'), iu = x.searchParams.get('imgurl');
          if (iu) full = full || iu;
          if (ref) { page = page || ref; break; }
          if (!/google\./.test(x.hostname)) { page = page || p.href; break; }
        } catch (e) {}
      }
      if (page && full) break;
    }
    seen.add(src);
    full = full || fullOf(src);
    out.push({src, page, full, alt: (img.alt || '').trim()});
    if (out.length >= 30) break;
  }
  return {images: out, captcha: location.pathname.startsWith('/sorry')};
})()
