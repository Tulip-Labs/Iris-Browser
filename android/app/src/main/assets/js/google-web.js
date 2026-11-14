(() => {
  const out = [], seen = new Set();
  const root = document.querySelector('#rso') || document.querySelector('#search') || document.body;
  for (const h of root.querySelectorAll('a h3')) {
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
  return {web: out, captcha: location.pathname.startsWith('/sorry') || !!document.querySelector('#captcha-form')};
})()
