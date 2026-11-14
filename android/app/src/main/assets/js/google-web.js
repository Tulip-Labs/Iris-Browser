(() => {
  const out = [], seen = new Set();
  const root = document.querySelector('#rso') || document.querySelector('#search') || document.body;
  // h3 on the desktop page; a heading role on the mobile one
  for (const h of root.querySelectorAll('a h3, a [role="heading"]')) {
    const a = h.closest('a');
    if (!a || !a.href) continue;
    // never ads or promoted units
    if (a.closest('#tads,#tadsb,#bottomads,[data-text-ad],[aria-label="Ads"],[aria-label="Sponsored"],[data-pla]')) continue;
    let u = a.href;
    try { const x = new URL(u); if (/google\./.test(x.hostname) && x.pathname === '/url') u = x.searchParams.get('q') || x.searchParams.get('url') || u; } catch (e) {}
    if (/^https?:\/\/([a-z]+\.)?google\.[a-z.]+\//.test(u) || seen.has(u)) continue;
    seen.add(u);
    let box = a;
    for (let i = 0; i < 7 && box.parentElement; i++) { box = box.parentElement; if ((box.innerText || '').length > (a.innerText || '').length + 80) break; }
    let snip = '';
    for (const el of box.querySelectorAll('div, span')) {
      if (el.contains(h) || el.querySelector('h3, cite')) continue;
      const t = (el.innerText || '').trim();
      if (t.length > snip.length && t.length < 420) snip = t;
    }
    if (/^(sponsored|ad|ads|patrocinado)\b/i.test((box.innerText || '').trim())) continue;
    const cite = box.querySelector('cite');
    out.push({t: h.innerText.trim(), u, s: snip.replace(/\s+/g, ' '), site: cite ? cite.innerText.split('›')[0].trim() : ''});
    if (out.length >= 12) break;
  }
  // a page built some other way (Google's mobile page): any link to a site
  // with a title-like text, and the longest text near it as the snippet
  if (!out.length) {
    for (const a of root.querySelectorAll('a[href]')) {
      let u = a.href;
      try { const x = new URL(u); if (/google\./.test(x.hostname) && x.pathname === '/url') u = x.searchParams.get('q') || x.searchParams.get('url') || u; } catch (e) {}
      if (!/^https?:/.test(u) || /^https?:\/\/([a-z]+\.)*(google|gstatic|youtube\.com\/(redirect|results))[a-z.]*\//.test(u) || seen.has(u)) continue;
      if (a.closest('#tads,#tadsb,#bottomads,[data-text-ad],[aria-label="Ads"],[aria-label="Sponsored"],[data-pla],header,footer,nav')) continue;
      // the title: the longest line that is not an address
      const lines = (a.innerText || '').split('\n').map(s => s.trim()).filter(s => s.length > 3 && !/›|^https?:\/\/|^www\./.test(s));
      const t = lines.reduce((p, s) => s.length > p.length && s.length < 160 ? s : p, '');
      if (t.length < 12) continue;
      seen.add(u);
      let box = a;
      for (let i = 0; i < 6 && box.parentElement; i++) { box = box.parentElement; if ((box.innerText || '').length > (a.innerText || '').length + 40) break; }
      let snip = '';
      for (const el of box.querySelectorAll('div, span')) {
        if (el.contains(a) || a.contains(el) || el.querySelector('a[href]')) continue;
        const s = (el.innerText || '').trim();
        if (s.length > snip.length && s.length < 420) snip = s;
      }
      out.push({t, u, s: snip.replace(/\s+/g, ' '), site: ''});
      if (out.length >= 12) break;
    }
  }
  return {web: out, captcha: location.pathname.startsWith('/sorry') || !!document.querySelector('#captcha-form')};
})()
