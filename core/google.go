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
}

// VideoResult is one YouTube video.
type VideoResult struct {
	ID, Title, Channel, Length, Views, Age string
}

// Thumb is the video's thumbnail address.
func (v VideoResult) Thumb() string { return "https://i.ytimg.com/vi/" + v.ID + "/mqdefault.jpg" }

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
  for (const h of root.querySelectorAll('a h3')) {
    const a = h.closest('a');
    if (!a || !a.href) continue;
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
    const cite = box.querySelector('cite');
    out.push({t: h.innerText.trim(), u, s: snip.replace(/\s+/g, ' '), site: cite ? cite.innerText.split('›')[0].trim() : ''});
    if (out.length >= 12) break;
  }
  return {web: out, captcha: location.pathname.startsWith('/sorry') || !!document.querySelector('#captcha-form')};
})()`

// ImagesScript reads the pictures of a Google image results page (udm=2).
const ImagesScript = `(() => {
  window.scrollTo(0, document.body.scrollHeight / 3);
  const out = [], seen = new Set();
  for (const img of document.querySelectorAll('img')) {
    const src = img.getAttribute('src') || img.dataset.src || '';
    if (!src || seen.has(src)) continue;
    if (!/^data:image\/(jpeg|png|webp)|^https:\/\/encrypted-tbn\d?\.gstatic\.com\//.test(src)) continue;
    const r = img.getBoundingClientRect();
    if ((img.naturalWidth || r.width) < 50) continue;
    let page = '', p = img;
    for (let i = 0; i < 10 && p; i++, p = p.parentElement) {
      if (p.dataset && p.dataset.lpage) { page = p.dataset.lpage; break; }
      if (p.tagName === 'A' && p.href) {
        try { const x = new URL(p.href); const ref = x.searchParams.get('imgrefurl'); if (ref) { page = ref; break; } if (!/google\./.test(x.hostname)) { page = p.href; break; } } catch (e) {}
      }
    }
    seen.add(src);
    out.push({src, page, alt: (img.alt || '').trim()});
    if (out.length >= 30) break;
  }
  return {images: out, captcha: location.pathname.startsWith('/sorry')};
})()`

// AIScript reads Google AI Mode's answer (udm=50) as it is written.
const AIScript = `(() => {
  const q = s => document.querySelector(s);
  const root = q('[data-subtree="aimc"]') || q('[data-container-id="main-col"]') || q('[role="main"]') || document.body;
  const src = [], seen = new Set();
  for (const a of root.querySelectorAll('a[href^="http"]')) {
    let u = a.href, host = '';
    try { host = new URL(u).hostname; } catch (e) { continue; }
    if (/(^|\.)google\.|gstatic\.com$|youtube\.com$/.test(host) || seen.has(host)) continue;
    seen.add(host);
    const t = ((a.innerText || a.getAttribute('aria-label') || '').trim().split('\n')[0] || host).slice(0, 90);
    src.push({t, u});
    if (src.length >= 6) break;
  }
  return {ai: (root.innerText || '').slice(0, 24000), src, busy: !!q('[aria-busy="true"]'),
    captcha: location.pathname.startsWith('/sorry')};
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

// AIResult is AI Mode's answer as read so far.
type AIResult struct {
	Text    string
	Sources []WebResult
	Busy    bool
	Captcha bool
}

var aiChrome = regexp.MustCompile(`(?i)^(ai mode|all|images|videos|news|shopping|short videos|forums|web|books|maps|flights|finance|more|tools|search labs|labs|show (more|all|less)|thinking.*|searching.*|looking.*|ask (anything|a follow.?up|about).*|ai (responses|overviews?) (may|can) (include|make) mistakes.*|learn more|dive deeper.*|sources?|\d+ (sites?|sources?|links?)|feedback|share|copy|copied|good response|bad response|thanks?( you)?.*|delete|start (a )?new search|new( chat| search)?|sign in|ai overview|listen|more results|send|edit|undo|done|close|menu|\+\d+|·|•)$`)

// ParseAI reads AIScript's result and keeps only the answer.
func ParseAI(js, query string) AIResult {
	var r struct {
		AI      string      `json:"ai"`
		Src     []WebResult `json:"src"`
		Busy    bool        `json:"busy"`
		Captcha bool        `json:"captcha"`
	}
	if json.Unmarshal([]byte(js), &r) != nil {
		return AIResult{}
	}
	return AIResult{Text: CleanAI(r.AI, query), Sources: r.Src, Busy: r.Busy, Captcha: r.Captcha}
}

// CleanAI removes the page's controls and the prompt (query) from AI Mode's text.
func CleanAI(raw, query string) string {
	var keep []string
	q := strings.ToLower(strings.TrimSpace(query))
	prev := ""
	for _, ln := range strings.Split(raw, "\n") {
		ln = strings.TrimSpace(ln)
		low := strings.ToLower(ln)
		switch {
		case ln == "", aiChrome.MatchString(ln), len([]rune(ln)) < 2, ln == prev:
			continue
		case q != "" && (low == q || len([]rune(low)) >= 12 && strings.Contains(q, low)):
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
