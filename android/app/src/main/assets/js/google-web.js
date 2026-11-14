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
    // Google's mobile page sends results through /goto, whose target is sealed:
    // the link is kept as it is (it leads to the site) and the site read from its text
    const sealed = /^https?:\/\/www\.google\.[a-z.]+\/goto\?/.test(u);
    if (!sealed && /^https?:\/\/([a-z]+\.)?google\.[a-z.]+\//.test(u) || seen.has(u)) continue;
    seen.add(u);
    let box = a;
    // up to the result's own block: never into one that holds another result
    for (let i = 0; i < 7 && box.parentElement; i++) {
      if (box.parentElement.querySelectorAll('a h3, a [role="heading"]').length > 1) break;
      box = box.parentElement;
      if ((box.innerText || '').length > (a.innerText || '').length + 80) break;
    }
    let snip = '';
    for (const el of box.querySelectorAll('div, span')) {
      if (el.contains(h) || a.contains(el) || el.querySelector('h3, cite, [role="heading"]')) continue;
      const t = (el.innerText || '').trim();
      if (t.length > snip.length && t.length < 420) snip = t;
    }
    if (/^(sponsored|ad|ads|patrocinado)\b/i.test((box.innerText || '').trim())) continue;
    const cite = box.querySelector('cite');
    let site = cite ? cite.innerText.split('›')[0].trim() : '';
    if (!site) {
      const line = (a.innerText || '').split('\n').map(s => s.trim()).find(s => /^https?:\/\//.test(s));
      if (line) site = line.replace(/^https?:\/\/(www\.)?/, '').split(/[\/ ›]/)[0];
    }
    if (sealed && !site) continue;
    out.push({t: h.innerText.trim(), u, s: snip.replace(/\s+/g, ' '), site});
    if (out.length >= 12) break;
  }
  // a page built some other way (Google's mobile page): any link to a site
  // with a title-like text, and the longest text near it as the snippet
  if (!out.length) {
    for (const a of root.querySelectorAll('a[href]')) {
      let u = a.href;
      try { const x = new URL(u); if (/google\./.test(x.hostname) && x.pathname === '/url') u = x.searchParams.get('q') || x.searchParams.get('url') || u; } catch (e) {}
      const sealed = /^https?:\/\/www\.google\.[a-z.]+\/goto\?/.test(u);
      if (!/^https?:/.test(u) || !sealed && /^https?:\/\/([a-z]+\.)*(google|gstatic|youtube\.com\/(redirect|results))[a-z.]*\//.test(u) || seen.has(u)) continue;
      if (a.closest('#tads,#tadsb,#bottomads,[data-text-ad],[aria-label="Ads"],[aria-label="Sponsored"],[data-pla],header,footer,nav')) continue;
      // the title: the heading if there is one, else the last line that is not an
      // address (the site's name comes first, the title last)
      const all = (a.innerText || '').split('\n').map(s => s.trim()).filter(Boolean);
      const lines = all.filter(s => s.length > 3 && s.length < 160 && !/›|^https?:\/\/|^www\./.test(s));
      const hd = a.querySelector('h3, [role="heading"]');
      const t = hd ? hd.innerText.trim() : (lines.length > 1 || sealed ? lines[lines.length - 1] : lines[0]) || '';
      if (t.length < 4 || (!sealed && lines.length < 2 && t.length < 12)) continue;
      const addr = all.find(s => /^https?:\/\//.test(s));
      const site = addr ? addr.replace(/^https?:\/\/(www\.)?/, '').split(/[\/ ›]/)[0] : '';
      if (sealed && !site) continue;
      seen.add(u);
      let box = a;
      const titled = (el) => [...el.querySelectorAll('a[href]')].filter(x => (x.innerText || '').trim().length > 3).length;
      for (let i = 0; i < 6 && box.parentElement; i++) {
        if (titled(box.parentElement) > 1) break; // the next block holds another result
        box = box.parentElement;
        if ((box.innerText || '').length > (a.innerText || '').length + 40) break;
      }
      let snip = '';
      for (const el of box.querySelectorAll('div, span')) {
        if (el.contains(a) || a.contains(el) || el.querySelector('a[href]')) continue;
        const s = (el.innerText || '').trim();
        if (s.length > snip.length && s.length < 420) snip = s;
      }
      out.push({t, u, s: snip.replace(/\s+/g, ' '), site});
      if (out.length >= 12) break;
    }
  }
  return {web: out, captcha: location.pathname.startsWith('/sorry') || !!document.querySelector('#captcha-form')};
})()
