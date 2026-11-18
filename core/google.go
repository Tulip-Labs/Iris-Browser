package core

import (
	"encoding/json"
	"net/url"
	"regexp"
	"strings"
)

// Lite results: Google searches are read by a hidden page and shown on Lite Go's
// own results page. These are the scripts that read Google's pages, and the
// parsers for what they return. Google's markup changes over time, so the
// scripts look for meaning (headings inside links, images, the answer column)
// rather than class names, and the results page always offers the original.

// WebResult is one link on the results page.
type WebResult struct {
	Title   string `json:"t"`
	URL     string `json:"u"`
	Snippet string `json:"s"`
	Site    string `json:"site"`
}

// ImageResult is one picture: Src is a data: URI or an https thumbnail.
type ImageResult struct {
	Src  string `json:"src"`
	Page string `json:"page"`
	Alt  string `json:"alt"`
	Full string `json:"full"` // the full-size picture, when Google names it
}

// VideoResult is one YouTube video.
type VideoResult struct {
	ID, Title, Channel, Length, Views, Age string
}

// Thumb is the video's thumbnail address.
func (v VideoResult) Thumb() string { return "https://i.ytimg.com/vi/" + v.ID + "/mqdefault.jpg" }

// BigThumb is the sharp 1280x720 thumbnail (most videos have it).
func (v VideoResult) BigThumb() string { return "https://i.ytimg.com/vi/" + v.ID + "/hq720.jpg" }

// URL is the video's watch page.
func (v VideoResult) URL() string { return "https://www.youtube.com/watch?v=" + v.ID }

// GoogleQuery reads a Google search address: the words and the mode.
func GoogleQuery(u string) (q string, m Mode, ok bool) {
	p, err := url.Parse(u)
	if err != nil {
		return "", 0, false
	}
	host := strings.ToLower(p.Hostname())
	if !(host == "google.com" || strings.HasPrefix(host, "www.google.")) || p.Path != "/search" {
		return "", 0, false
	}
	v := p.Query()
	q = strings.TrimSpace(v.Get("q"))
	if q == "" {
		return "", 0, false
	}
	switch v.Get("udm") {
	case "50":
		m = ModeAI
	case "2":
		m = ModeImages
	case "7":
		m = ModeVideos
	default:
		if v.Get("tbm") == "isch" {
			m = ModeImages
		} else if v.Get("tbm") == "vid" {
			m = ModeVideos
		} else {
			m = ModeWeb
		}
	}
	return q, m, true
}

// WebScript reads the links of a Google web results page (udm=14).
const WebScript = `(() => {
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
})()`

// ImagesScript reads the pictures of a Google image results page (udm=2).
const ImagesScript = `(() => {
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
})()`

// AIScript reads Google AI Mode's answer (udm=50) as it is written: its blocks
// (headings, paragraphs, list items) with **bold** kept, the sources each block
// cites, and the full list of sources. innerText comes along as a fallback.
const AIScript = `(() => {
  const q = s => document.querySelector(s);
  const root = q('[data-subtree="aimc"]') || q('[data-container-id="main-col"]') || q('[role="main"]') || document.body;
  const sources = [], byURL = new Map();
  const isGoogle = h => /(^|\.)google\.|gstatic\.com$|googleusercontent\.com$/.test(h);
  const cite = a => {
    let u = a.href, h = '';
    try {
      const x = new URL(u);
      if (isGoogle(x.hostname) && x.pathname === '/url') u = x.searchParams.get('q') || x.searchParams.get('url') || u;
      h = new URL(u).hostname;
    } catch (e) { return 0; }
    if (!/^https?:/.test(u) || isGoogle(h)) return 0;
    u = u.split('#:~:text=')[0];
    if (byURL.has(u)) return byURL.get(u);
    const t = ((a.getAttribute('aria-label') || a.innerText || a.title || '').trim().split('\n')[0] || h).slice(0, 140);
    sources.push({t, u});
    byURL.set(u, sources.length);
    return sources.length;
  };
  const skip = el => el.closest('button,[role="button"],form,nav,header,footer,textarea,[contenteditable="true"]');
  const inline = el => {
    let out = '';
    const walk = n => {
      if (n.nodeType === 3) { out += n.nodeValue; return; }
      if (n.nodeType !== 1) return;
      const tag = n.tagName;
      if (/^(A|BUTTON|SVG|STYLE|SCRIPT|IMG|SUP)$/.test(tag)) return;
      const st = getComputedStyle(n);
      if (st.display === 'none' || st.visibility === 'hidden') return;
      const bold = tag === 'B' || tag === 'STRONG' || parseInt(st.fontWeight, 10) >= 600;
      if (bold) out += '**';
      for (const c of n.childNodes) walk(c);
      if (bold) out += '**';
      if (tag === 'BR') out += ' ';
    };
    walk(el);
    return out.replace(/\*\*(\s*)\*\*/g, '$1').replace(/\s+/g, ' ').trim();
  };
  const blocks = [];
  for (const el of root.querySelectorAll('h1,h2,h3,h4,h5,p,li,[role="heading"],[role="listitem"]')) {
    if (skip(el) || el.querySelector('p,li,h1,h2,h3,h4,h5,[role="listitem"]')) continue;
    const t = inline(el);
    if (!t || t.length < 2) continue;
    const k = /^H\d$/.test(el.tagName) || el.getAttribute('role') === 'heading' ? 'h'
      : (el.tagName === 'LI' || el.getAttribute('role') === 'listitem') ? 'li' : 'p';
    const cites = [], scope = [el];
    const sib = el.nextElementSibling;
    if (sib && !sib.matches('h1,h2,h3,h4,h5,p,li,ul,ol')) scope.push(sib);
    for (const s of scope) for (const a of s.querySelectorAll('a[href]')) {
      const i = cite(a);
      if (i > 0 && !cites.includes(i)) cites.push(i);
    }
    blocks.push({k, t, c: cites.slice(0, 5)});
  }
  for (const a of root.querySelectorAll('a[href]')) cite(a);
  // the feedback buttons appear once the answer is complete
  const done = !!document.querySelector('[aria-label*="Good response" i],[aria-label*="thumbs up" i],[aria-label*="Positive feedback" i]');
  return {blocks, src: sources.slice(0, 16), ai: (root.innerText || '').slice(0, 24000), done,
    busy: !!q('[aria-busy="true"],[role="progressbar"]'), captcha: location.pathname.startsWith('/sorry')};
})()`

// PageScript reads the open page for the AI side panel.
const PageScript = `(() => {
  const main = document.querySelector('article') || document.querySelector('main') || document.body;
  const sel = String(window.getSelection ? window.getSelection() : '').trim();
  return {title: document.title, url: location.href, text: (main.innerText || '').replace(/\s+/g, ' ').slice(0, 6000), sel: sel.slice(0, 1500)};
})()`

// ParseWeb reads WebScript's result.
func ParseWeb(js string) (out []WebResult, captcha bool) {
	var r struct {
		Web     []WebResult `json:"web"`
		Captcha bool        `json:"captcha"`
	}
	if json.Unmarshal([]byte(js), &r) != nil {
		return nil, false
	}
	for _, w := range r.Web {
		w.Title, w.Snippet = strings.TrimSpace(w.Title), strings.TrimSpace(w.Snippet)
		if w.Snippet == w.Title {
			w.Snippet = ""
		}
		if w.Site == "" {
			w.Site = strings.TrimPrefix(Host(w.URL), "www.")
		}
		if w.Title != "" && strings.HasPrefix(w.URL, "http") {
			out = append(out, w)
		}
	}
	return out, r.Captcha
}

// ParseImages reads ImagesScript's result.
func ParseImages(js string) (out []ImageResult, captcha bool) {
	var r struct {
		Images  []ImageResult `json:"images"`
		Captcha bool          `json:"captcha"`
	}
	if json.Unmarshal([]byte(js), &r) != nil {
		return nil, false
	}
	return r.Images, r.Captcha
}

// AIBlock is one part of an answer: a heading ("h"), paragraph ("p") or list
// item ("li"). Text may hold **bold** runs; Cites are 1-based source numbers.
type AIBlock struct {
	Kind  string `json:"k"`
	Text  string `json:"t"`
	Cites []int  `json:"c"`
}

// AIResult is AI Mode's answer as read so far.
type AIResult struct {
	Text    string // plain text, for copying
	Blocks  []AIBlock
	Sources []WebResult
	Busy    bool
	Done    bool // Google shows the answer as complete
	Captcha bool
}

// ParseAI reads AIScript's result and keeps only the answer.
func ParseAI(js, prompt string) AIResult {
	var r struct {
		Blocks  []AIBlock   `json:"blocks"`
		AI      string      `json:"ai"`
		Src     []WebResult `json:"src"`
		Busy    bool        `json:"busy"`
		Done    bool        `json:"done"`
		Captcha bool        `json:"captcha"`
	}
	if json.Unmarshal([]byte(js), &r) != nil {
		return AIResult{}
	}
	plain := CleanAI(r.AI, prompt)
	blocks := cleanBlocks(r.Blocks, prompt, len(r.Src))
	// the structured reading is used when it covers most of the answer
	n := 0
	for _, b := range blocks {
		n += len(Unbold(b.Text))
	}
	if len(blocks) == 0 || n < len(plain)/2 {
		blocks = blocksFromText(plain)
	}
	var lines []string
	for _, b := range blocks {
		lines = append(lines, Unbold(b.Text))
	}
	return AIResult{Text: strings.Join(lines, "\n"), Blocks: blocks, Sources: r.Src, Busy: r.Busy, Done: r.Done, Captcha: r.Captcha}
}

// Unbold removes the **bold** marks.
func Unbold(s string) string { return strings.ReplaceAll(s, "**", "") }

func cleanBlocks(in []AIBlock, prompt string, nsrc int) []AIBlock {
	var out []AIBlock
	q := strings.ToLower(strings.TrimSpace(prompt))
	first, _, _ := strings.Cut(q, "\n") // the question itself, before any instructions
	prev := ""
	for _, b := range in {
		t := strings.TrimSpace(b.Text)
		plain := strings.TrimSpace(Unbold(t))
		low := strings.ToLower(plain)
		if plain == "" || aiChrome.MatchString(plain) || plain == prev || len([]rune(plain)) < 2 ||
			q != "" && (low == q || low == first || len([]rune(low)) >= 12 && strings.Contains(q, low)) {
			continue
		}
		if b.Kind == "h" || strings.HasPrefix(t, "**") && strings.HasSuffix(t, "**") && strings.Count(t, "**") == 2 && len(plain) < 80 && b.Kind == "p" {
			b.Kind, t = "h", plain
		}
		var cites []int
		for _, c := range b.Cites {
			if c >= 1 && c <= nsrc {
				cites = append(cites, c)
			}
		}
		out = append(out, AIBlock{Kind: b.Kind, Text: t, Cites: cites})
		prev = plain
	}
	return out
}

// blocksFromText guesses blocks from plain lines: bullets, short headings, paragraphs.
func blocksFromText(text string) []AIBlock {
	var out []AIBlock
	lines := strings.Split(text, "\n")
	for i, ln := range lines {
		ln = strings.TrimSpace(ln)
		if ln == "" {
			continue
		}
		kind := "p"
		for _, b := range []string{"• ", "- ", "* ", "· "} {
			if strings.HasPrefix(ln, b) {
				ln, kind = strings.TrimSpace(ln[len(b):]), "li"
				break
			}
		}
		next := ""
		if i+1 < len(lines) {
			next = strings.TrimSpace(lines[i+1])
		}
		if kind == "p" && len(ln) < 70 && next != "" && !strings.ContainsAny(ln[len(ln)-1:], ".,;!?)") && len(strings.Fields(ln)) <= 9 {
			kind = "h"
		}
		out = append(out, AIBlock{Kind: kind, Text: ln})
	}
	return out
}

var aiChrome = regexp.MustCompile(`(?i)^(ai mode|all|images|videos|news|shopping|short videos|forums|web|books|maps|flights|finance|more|tools|search labs|labs|show (more|all|less)|thinking.*|searching.*|looking.*|ask (anything|a follow.?up|about).*|ai (responses|overviews?) (may|can) (include|make) mistakes.*|learn more|dive deeper.*|sources?|\d+ (sites?|sources?|links?)|feedback|share|copy|copied|good response|bad response|thanks?( you)?.*|delete|start (a )?new search|new( chat| search)?|sign in|ai overview|listen|more results|send|edit|undo|done|close|menu|\+\d+|·|•|[a-z0-9 .'-]{2,40} \+\d+)$`)

// CleanAI removes the page's controls and the prompt (query) from AI Mode's text.
func CleanAI(raw, query string) string {
	var keep []string
	q := strings.ToLower(strings.TrimSpace(query))
	first, _, _ := strings.Cut(q, "\n")
	prev := ""
	for _, ln := range strings.Split(raw, "\n") {
		ln = strings.TrimSpace(ln)
		low := strings.ToLower(ln)
		switch {
		case ln == "", aiChrome.MatchString(ln), len([]rune(ln)) < 2, ln == prev:
			continue
		case q != "" && (low == q || low == first || len([]rune(low)) >= 12 && strings.Contains(q, low)):
			continue // the question (and the page text sent with it) echoed back
		}
		keep = append(keep, ln)
		prev = ln
	}
	return strings.Join(keep, "\n")
}

// PagePrompt is the question sent to AI Mode about a page: the question, the
// page's address (AI Mode can read it) and as much of its text as fits.
func PagePrompt(question, title, pageURL, text, selection string) string {
	question = strings.TrimSpace(question)
	head := question
	if pageURL != "" {
		head += "\n\nAbout this page: " + strings.TrimSpace(title) + " (" + pageURL + ")"
	}
	if selection != "" {
		head += "\n\nSelected text: " + selection
		text = ""
	}
	const limit = 1800 // keeps the address well under Google's length limit
	if text != "" && len(head) < limit-80 {
		room := limit - len(head) - 20
		if len(text) > room {
			text = text[:room]
			if i := strings.LastIndexByte(text, ' '); i > room/2 {
				text = text[:i]
			}
			text += "..."
		}
		head += "\n\nPage text: " + text
	}
	if len(head) > limit {
		head = head[:limit]
	}
	return head
}
