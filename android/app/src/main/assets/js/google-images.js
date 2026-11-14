(() => {
  window.scrollTo(0, document.body.scrollHeight / 3);
  const out = [], seen = new Set();
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
    out.push({src, page, full, alt: (img.alt || '').trim()});
    if (out.length >= 30) break;
  }
  return {images: out, captcha: location.pathname.startsWith('/sorry')};
})()
