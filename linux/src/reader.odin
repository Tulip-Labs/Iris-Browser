// The reader, as in Safari: the article of a page alone, in a calm page of
// Iris's (its glass and its colours, light or dark). Iris looks at a page
// once when it has loaded (privacy.odin's survey: is it an article?), and
// the reader's button shows in the address only then. Ctrl+Alt+R or the
// button: reader.js finds and cleans the article, in a world of Iris's own,
// and Iris shows it with a policy that runs no script at all.
package iris

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"

@(private="file") READER_JS :: #load("reader.js", string)

Reader_Article :: struct {
	title, byline, site, lang, dir, content: string,
	words: int,
}

/// into the reader, or out of it
reader_toggle :: proc(t: ^Tab) {
	if t == nil || !tab_has_view(t) do return
	if t.reader {
		tab_reader_exit(t)
		return
	}
	if !t.article {
		browser_toast("This page has no article for the reader")
		return
	}
	tab_run_isolated(t, READER_JS, proc(t: ^Tab, result: string) {
		a: Reader_Article
		if json.unmarshal(transmute([]u8)result, &a, allocator = context.temp_allocator) != nil || len(strings.trim_space(a.content)) == 0 {
			browser_toast("The reader found no article here")
			return
		}
		tab_show_html(t, reader_page(a, theme.dark), t.url)
	})
}

/// text for HTML (names, titles: never markup)
html_escape :: proc(s: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for r in s {
		switch r {
		case '&': strings.write_string(&b, "&amp;")
		case '<': strings.write_string(&b, "&lt;")
		case '>': strings.write_string(&b, "&gt;")
		case '"': strings.write_string(&b, "&quot;")
		case '\'': strings.write_string(&b, "&#39;")
		case: strings.write_rune(&b, r)
		}
	}
	return strings.to_string(b)
}

/// a language or direction attribute: letters, digits and dashes only
@(private="file") attr_word :: proc(s: string) -> string {
	for c in transmute([]u8)s {
		ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-'
		if !ok do return ""
	}
	return s[:min(len(s), 24)]
}

READER_CSS :: `:root{color-scheme:light;--bg1:#f5f6f8;--bg2:#eceef2;--card:rgba(255,255,255,.78);--ink:#1a1c21;--dim:rgba(26,28,33,.6);--rim:rgba(255,255,255,.95);--line:rgba(26,28,33,.12);--accent:#007aff}
.dark{color-scheme:dark;--bg1:#0b0c0e;--bg2:#15171b;--card:rgba(30,32,37,.78);--ink:#f2f4f7;--dim:rgba(242,244,247,.6);--rim:rgba(255,255,255,.09);--line:rgba(255,255,255,.12);--accent:#0a84ff}
html{background:linear-gradient(var(--bg1),var(--bg2)) fixed;min-height:100%}
body{margin:0;padding:56px 20px 96px;color:var(--ink);font:19px/1.66 "Iowan Old Style","Charter","Source Serif 4","Noto Serif",Georgia,serif;-webkit-font-smoothing:antialiased;text-rendering:optimizeLegibility}
main{max-width:40rem;margin:0 auto;padding:44px 52px 56px;background:var(--card);border-radius:28px;box-shadow:inset 0 1px 0 var(--rim),0 1px 2px rgba(0,0,0,.04),0 18px 50px rgba(20,24,40,.10)}
header{margin-bottom:28px;padding-bottom:22px;border-bottom:1px solid var(--line)}
.site{font:700 12px/1.2 system-ui,sans-serif;letter-spacing:.08em;text-transform:uppercase;color:var(--dim);margin:0 0 14px}
h1{font-size:2.05em;line-height:1.16;margin:0 0 12px;letter-spacing:-.01em}
.by{font:14px/1.4 system-ui,sans-serif;color:var(--dim);margin:0}
h2,h3,h4{line-height:1.25;margin:1.6em 0 .5em}
p{margin:0 0 1.05em}
article img{max-width:100%;height:auto;border-radius:14px;display:block;margin:1.4em auto}
a{color:var(--accent);text-decoration:none}a:hover{text-decoration:underline}
blockquote{margin:1.4em 0;padding:.1em 1.2em;border-left:3px solid var(--accent);color:var(--dim)}
pre{overflow:auto;padding:14px 16px;border-radius:14px;background:var(--line);font:14px/1.5 ui-monospace,monospace}
code,kbd,samp{font-family:ui-monospace,monospace;font-size:.86em}
figure{margin:1.6em 0}figcaption{font:14px/1.45 system-ui,sans-serif;color:var(--dim);text-align:center}
table{border-collapse:collapse;width:100%;font-size:.88em;display:block;overflow:auto}td,th{border-bottom:1px solid var(--line);padding:6px 8px;text-align:left}
hr{border:0;height:1px;background:var(--line);margin:2em 0}
@media (max-width:720px){body{padding:20px 8px 60px}main{padding:28px 22px;border-radius:22px}}`

/// the reader's page: the article in a card of frosted glass. Its policy
/// lets pictures load and runs nothing (no script, no frame, no form).
reader_page :: proc(a: Reader_Article, dark: bool, allocator := context.temp_allocator) -> string {
	minutes := max(1, (a.words + 220) / 230)
	by := len(a.byline) > 0 ? fmt.tprintf("%s · %d min read", html_escape(a.byline), minutes) : fmt.tprintf("%d min read", minutes)
	lang := attr_word(a.lang)
	dir := attr_word(a.dir)
	return fmt.aprintf(`<!doctype html><html class="%s"%s%s><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src http: https: data:; style-src 'unsafe-inline'; form-action 'none'; base-uri 'none'"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="referrer" content="no-referrer"><title>%s</title><style>%s</style></head><body><main><header><p class="site">%s</p><h1>%s</h1><p class="by">%s</p></header><article>%s</article></main></body></html>`,
		dark ? "dark" : "light",
		len(lang) > 0 ? fmt.tprintf(` lang="%s"`, lang) : "",
		len(dir) > 0 ? fmt.tprintf(` dir="%s"`, dir) : "",
		html_escape(a.title), READER_CSS, html_escape(a.site), html_escape(a.title), by, a.content, allocator = allocator)
}

@(test) test_reader_page :: proc(t: ^testing.T) {
	testing.expect_value(t, html_escape(`<a href="x">Tom & 'Jerry'</a>`), "&lt;a href=&quot;x&quot;&gt;Tom &amp; &#39;Jerry&#39;&lt;/a&gt;")
	testing.expect_value(t, attr_word("en-GB"), "en-GB")
	testing.expect_value(t, attr_word(`en" onload="x`), "")
	p := reader_page({title = "<script>alert(1)</script>", site = "example.com", lang = "en", words = 900, content = "<p>Hello</p>"}, true)
	testing.expect(t, !strings.contains(p, "<script>"), "a title became markup")
	testing.expect(t, strings.contains(p, `class="dark" lang="en"`))
	testing.expect(t, strings.contains(p, "4 min read"))
	testing.expect(t, strings.contains(p, "default-src 'none'"), "the reader's page runs scripts")
	testing.expect(t, strings.contains(p, "<article><p>Hello</p></article>"))
}
