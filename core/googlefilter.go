package core

import (
	"encoding/json"
	"fmt"
	"net/url"
	"strings"
)

// Google search, cleaned: Iris shows Google's own results page (its AI
// Overview included) without ads, sponsored results, "People also ask" and
// shopping blocks, puts the best sources first (references, documentation,
// research, official sites, real discussions, serious news), leaves content
// farms out, and offers filters over the page: time, exact words, type of
// site, and the content-farm filter itself.

// GoogleFilters are the filters of one Google search.
type GoogleFilters struct {
	Time  string // "" any time, or h, d, w, m, y
	Exact bool   // Google's verbatim: the words as written, no synonyms
	Type  string // "" all, forums, news, videos, pdf
	All   bool   // content farms and SEO spam shown too (off: left out)
}

// GoogleTimes and GoogleTypes are the choices, in the order shown.
var (
	GoogleTimes = []struct{ ID, Label string }{{"", "Any time"}, {"h", "Hour"}, {"d", "Day"}, {"w", "Week"}, {"m", "Month"}, {"y", "Year"}}
	GoogleTypes = []struct{ ID, Label string }{{"", "All"}, {"forums", "Forums"}, {"news", "News"}, {"videos", "Videos"}, {"pdf", "PDFs"}}
)

const pdfTerm = " filetype:pdf"

// googleSearchURL parses u when it is a Google search with words.
func googleSearchURL(u string) (*url.URL, url.Values, bool) {
	p, err := url.Parse(u)
	if err != nil {
		return nil, nil, false
	}
	host := strings.ToLower(p.Hostname())
	if !(host == "google.com" || strings.HasPrefix(host, "www.google.")) || p.Path != "/search" {
		return nil, nil, false
	}
	v := p.Query()
	if strings.TrimSpace(v.Get("q")) == "" {
		return nil, nil, false
	}
	return p, v, true
}

// ReadGoogleFilters reads the filters of a Google search address; ok is
// false for anything else, and for image searches and AI Mode, which have
// no filters.
func ReadGoogleFilters(u string) (f GoogleFilters, ok bool) {
	_, v, ok := googleSearchURL(u)
	if !ok {
		return f, false
	}
	udm, tbm := v.Get("udm"), v.Get("tbm")
	if udm == "2" || udm == "50" || tbm == "isch" {
		return f, false
	}
	for _, t := range strings.Split(v.Get("tbs"), ",") {
		switch {
		case t == "li:1":
			f.Exact = true
		case strings.HasPrefix(t, "qdr:") && len(t) == 5 && strings.ContainsRune("hdwmy", rune(t[4])):
			f.Time = t[4:]
		}
	}
	switch {
	case udm == "18":
		f.Type = "forums"
	case tbm == "nws":
		f.Type = "news"
	case udm == "7" || tbm == "vid":
		f.Type = "videos"
	case strings.HasSuffix(strings.TrimSpace(v.Get("q")), strings.TrimSpace(pdfTerm)):
		f.Type = "pdf"
	}
	f.All = v.Get("irisall") == "1"
	return f, true
}

// Apply gives the address of the same search with filters f.
func (f GoogleFilters) Apply(u string) string {
	p, v, ok := googleSearchURL(u)
	if !ok {
		return u
	}
	q := strings.TrimSpace(strings.TrimSuffix(strings.TrimSpace(v.Get("q")), strings.TrimSpace(pdfTerm)))
	for _, k := range []string{"udm", "tbm", "tbs", "start", "irisall"} {
		v.Del(k)
	}
	var tbs []string
	if f.Time != "" {
		tbs = append(tbs, "qdr:"+f.Time)
	}
	if f.Exact {
		tbs = append(tbs, "li:1")
	}
	if len(tbs) > 0 {
		v.Set("tbs", strings.Join(tbs, ","))
	}
	switch f.Type {
	case "forums":
		v.Set("udm", "18")
	case "news":
		v.Set("tbm", "nws")
	case "videos":
		v.Set("udm", "7")
	case "pdf":
		q += pdfTerm
	}
	v.Set("q", q)
	if f.All {
		v.Set("irisall", "1")
	}
	p.RawQuery = v.Encode()
	return p.String()
}

// GoogleCleanScript cleans Google's results page (see the top of this file).
// It runs on google.*/search only, not on image searches or AI Mode.
func GoogleCleanScript() string {
	good, low, shop := map[string]string{}, map[string]bool{}, map[string]bool{}
	for h, t := range siteTiers {
		switch {
		case t.weight >= 1.3 && t.label != "":
			good[h] = t.label
		case t.label == "Shop":
			shop[h] = true
		case t.weight <= 0.3:
			low[h] = true
		}
	}
	j := func(x any) string { b, _ := json.Marshal(x); return string(b) }
	return fmt.Sprintf(googleCleanJS, j(good), j(low), j(shop), j(buyIntent.String()), j(adTitle.String()))
}

const googleCleanJS = `(() => {
  if (!/(^|\.)google\.[a-z.]+$/.test(location.hostname) || location.pathname !== '/search' || window.__irisG) return;
  const p = new URLSearchParams(location.search);
  if (p.get('udm') === '2' || p.get('udm') === '50' || p.get('tbm') === 'isch') return;
  window.__irisG = true;
  const GOOD = %s, LOW = %s, SHOP = %s;
  const re = s => new RegExp(s.replace(/^\(\?i\)/, ''), 'i');
  const buy = re(%s).test(p.get('q') || ''), adTitle = re(%s);
  const all = p.get('irisall') === '1';
  // ads, sponsored, shopping and "People also ask", by their usual places
  const css = '#tads,#tadsb,#bottomads,[data-text-ad],.commercial-unit-desktop-top,.commercial-unit-desktop-rhs,' +
    '.cu-container,.pla-unit,[data-pla],.related-question-pair,[jsname="N760b"],[data-initq],' +
    'g-section-with-header:has([data-pla]){display:none!important}' +
    '.iris-q{display:inline-block;margin-left:8px;padding:0 7px;border-radius:9px;font-size:11px;line-height:18px;' +
    'background:rgba(60,110,240,.12);color:#2f5bd3;vertical-align:middle}' +
    '@media (prefers-color-scheme:dark){.iris-q{background:rgba(140,170,255,.18);color:#a9c1ff}}';
  const style = () => {
    if (document.getElementById('iris-g')) return;
    const s = document.createElement('style');
    s.id = 'iris-g';
    s.textContent = css;
    (document.head || document.documentElement).appendChild(s);
  };
  // and by their headings, in English and Spanish (the AI Overview stays)
  const unwanted = /^(sponsored( results)?|ads?|anuncios?|patrocinados?|resultados patrocinados|people also ask|las personas tambi[eé]n preguntan|otras preguntas de los usuarios|popular products|productos populares|shopping|compras|products|productos|deals|ofertas|from sources across the web|de fuentes de toda la web)$/i;
  const aiHead = /ai overview|vista creada con ia|resumen (creado )?(con|de) ia|descripci[oó]n general (creada )?(con|por) ia/i;
  const sponsoredMark = /^(sponsored|patrocinado|anuncio|ad)$/i;
  const hide = el => el.style.setProperty('display', 'none', 'important');
  const hostOf = h => { try { return new URL(h, location.href).hostname.replace(/^www\./, '').toLowerCase(); } catch (e) { return ''; } };
  const find = (m, h) => { while (h) { if (m[h] !== undefined) return m[h]; const i = h.indexOf('.'); if (i < 0) break; h = h.slice(i + 1); } return undefined; };
  const official = h => /\.(gov|edu|int)(\.[a-z]{2})?$/.test(h) ? (/\.edu/.test(h) ? 'Academic' : 'Official') : undefined;
  let lastCount = -1;
  const run = () => {
    style();
    document.querySelectorAll('#rso > *, #center_col > div, #botstuff div[jscontroller], #rhs > div, #bres > div').forEach(b => {
      if (b.dataset.irisHidden) return;
      const hd = b.querySelector('h1,h2,h3[role="heading"],[role="heading"]');
      const txt = (hd && hd.textContent || '').trim();
      if (aiHead.test(txt)) return;
      if (unwanted.test(txt) || Array.from(b.querySelectorAll('span')).some(s => s.childElementCount === 0 && sponsoredMark.test(s.textContent.trim()))) {
        b.dataset.irisHidden = '1';
        hide(b);
      }
    });
    const rso = document.getElementById('rso');
    if (!rso) return;
    const results = [];
    Array.from(rso.children).forEach(b => {
      if (b.dataset.irisHidden) return;
      const a = b.querySelector('a[href] h3') && b.querySelector('a[href] h3').closest('a');
      if (!a) return;
      if (!b.dataset.irisRank) {
        const h = hostOf(a.href), title = a.textContent || '';
        if (!all && (find(LOW, h) || adTitle.test(title))) { b.dataset.irisHidden = '1'; hide(b); return; }
        const label = find(GOOD, h) || official(h);
        b.dataset.irisRank = label ? '2' : (find(SHOP, h) && !buy) ? '0' : '1';
        const cite = b.querySelector('cite');
        if (label && cite && !b.querySelector('.iris-q')) {
          const s = document.createElement('span');
          s.className = 'iris-q';
          s.textContent = label;
          cite.parentNode.insertBefore(s, cite.nextSibling);
        }
      }
      results.push(b);
    });
    // the best sources first, shops last, the rest in Google's order: the
    // results change places among themselves only
    if (results.length === lastCount) return;
    lastCount = results.length;
    const sorted = results.map((b, i) => [b, i]).sort((x, y) => (+y[0].dataset.irisRank - +x[0].dataset.irisRank) || (x[1] - y[1])).map(x => x[0]);
    const marks = results.map(b => { const m = document.createComment('iris'); b.before(m); return m; });
    sorted.forEach((b, i) => marks[i].after(b));
    marks.forEach(m => m.remove());
  };
  let queued = false;
  const later = () => { if (!queued) { queued = true; requestAnimationFrame(() => { queued = false; run(); }); } };
  new MutationObserver(later).observe(document.documentElement, { childList: true, subtree: true });
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', run); else run();
})();`
