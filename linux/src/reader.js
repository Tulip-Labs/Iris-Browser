// Iris's reader: the article of a page, found and cleaned (run in a world of
// Iris's own, on demand only). Returns JSON: title, byline, site, lang, dir,
// words and content (HTML of a few plain elements, links and pictures; no
// scripts, styles, frames, forms or event handlers survive).
(() => {
  const doc = document;
  const BAD = /comment|meta|footer|footnote|foot|masthead|nav|menu|share|social|related|recommend|sidebar|aside|promo|advert|sponsor|newsletter|subscribe|signup|cookie|banner|popup|modal|breadcrumb|pagination|pager|tags|author-bio|byline-share|outbrain|taboola/i;
  const GOOD = /article|body|content|entry|main|page|post|text|blog|story|prose/i;
  const nameOf = n => ((typeof n.className === 'string' ? n.className : '') + ' ' + (n.id || ''));
  const textLen = n => (n.textContent || '').replace(/\s+/g, ' ').trim().length;
  const linkLen = n => { let s = 0; for (const a of n.querySelectorAll('a')) s += textLen(a); return s; };

  // the container with the most paragraph text, links counting against it
  const score = new Map();
  const add = (n, v) => { if (n && n !== doc.documentElement) score.set(n, (score.get(n) || 0) + v); };
  for (const p of doc.querySelectorAll('p, pre, blockquote')) {
    const n = textLen(p);
    if (n < 25) continue;
    const s = 1 + Math.min(3, Math.floor(n / 100)) + (p.textContent.split(',').length - 1) * 0.5;
    add(p.parentElement, s);
    if (p.parentElement) add(p.parentElement.parentElement, s / 2);
  }
  let best = null, top = 0;
  for (const [n, s0] of score) {
    let s = s0;
    const id = nameOf(n);
    if (BAD.test(id) && !GOOD.test(id)) s *= 0.3;
    if (GOOD.test(id)) s *= 1.25;
    s *= 1 - Math.min(0.9, linkLen(n) / Math.max(1, textLen(n)));
    if (s > top) { best = n; top = s; }
  }
  const art = doc.querySelector('article');
  if (art && textLen(art) > 800 && (!best || art.contains(best))) best = art;
  if (!best) return JSON.stringify({ content: '' });

  // the article, rebuilt from allowed elements only
  const KEEP = new Set(['P','H1','H2','H3','H4','H5','H6','UL','OL','LI','BLOCKQUOTE','PRE','CODE','EM','STRONG','B','I','A','IMG','FIGURE','FIGCAPTION','BR','HR','TABLE','THEAD','TBODY','TR','TD','TH','SUP','SUB','DL','DT','DD','MARK','SMALL','Q','CITE','ABBR','TIME','S','U','DEL','INS','KBD','SAMP','VAR']);
  const UNWRAP = new Set(['DIV','SPAN','SECTION','ARTICLE','MAIN','HEADER','FONT','CENTER','PICTURE','DETAILS','SUMMARY']);
  const DROP = new Set(['SCRIPT','STYLE','NOSCRIPT','IFRAME','FRAME','OBJECT','EMBED','FORM','INPUT','BUTTON','SELECT','TEXTAREA','NAV','ASIDE','FOOTER','SVG','CANVAS','VIDEO','AUDIO','SOURCE','TEMPLATE','DIALOG','LINK','META']);
  const abs = u => { try { const x = new URL(u, location.href); return /^(https?|mailto):$/.test(x.protocol) ? x.href : ''; } catch (e) { return ''; } };
  const imgSrc = e => {
    for (const k of ['data-src', 'data-lazy-src', 'data-original', 'src']) { const v = e.getAttribute(k); if (v && !v.startsWith('data:')) return abs(v); }
    const ss = e.getAttribute('srcset') || e.getAttribute('data-srcset');
    if (ss) return abs(ss.split(',').pop().trim().split(/\s+/)[0]);
    return e.currentSrc ? abs(e.currentSrc) : '';
  };
  const hidden = e => e.hidden || e.getAttribute('aria-hidden') === 'true' || (e.style && (e.style.display === 'none' || e.style.visibility === 'hidden'));
  const out = doc.createElement('div');
  let words = 0;
  const walk = (src, dst, depth) => {
    for (const n of src.childNodes) {
      if (n.nodeType === 3) { dst.appendChild(doc.createTextNode(n.data)); words += (n.data.match(/\S+/g) || []).length; continue; }
      if (n.nodeType !== 1) continue;
      const tag = n.tagName.toUpperCase();
      if (DROP.has(tag) || hidden(n)) continue;
      if (n !== best && depth > 0 && BAD.test(nameOf(n)) && !GOOD.test(nameOf(n)) && linkLen(n) > textLen(n) * 0.3) continue;
      if (UNWRAP.has(tag)) { walk(n, dst, depth + 1); continue; }
      if (!KEEP.has(tag)) { walk(n, dst, depth + 1); continue; }
      const e = doc.createElement(tag);
      if (tag === 'A') { const h = abs(n.getAttribute('href') || ''); if (h) e.setAttribute('href', h); }
      if (tag === 'IMG') {
        const s = imgSrc(n);
        if (!s) continue;
        e.setAttribute('src', s);
        if (n.alt) e.setAttribute('alt', n.alt);
        dst.appendChild(e);
        continue;
      }
      if ((tag === 'TD' || tag === 'TH') && n.colSpan > 1) e.setAttribute('colspan', String(n.colSpan));
      walk(n, e, depth + 1);
      if (tag !== 'BR' && tag !== 'HR' && !e.textContent.trim() && !e.querySelector('img')) continue;
      dst.appendChild(e);
    }
  };
  walk(best, out, 0);
  const meta = k => { const m = doc.querySelector(`meta[property="${k}"], meta[name="${k}"]`); return m ? (m.getAttribute('content') || '').trim() : ''; };
  const title = meta('og:title') || (doc.querySelector('h1') ? doc.querySelector('h1').textContent.trim() : '') || doc.title;
  // the title once: not again as the article's first heading
  const h = out.querySelector('h1, h2');
  if (h && h.textContent.trim() === title.trim()) h.remove();
  const by = meta('author') || meta('article:author') || ((doc.querySelector('[rel="author"], .byline, .author') || {}).textContent || '').trim();
  return JSON.stringify({
    title, byline: by.slice(0, 160), site: meta('og:site_name') || location.hostname.replace(/^www\./, ''),
    lang: doc.documentElement.lang || '', dir: doc.documentElement.dir || '', words, content: out.innerHTML,
  });
})()
