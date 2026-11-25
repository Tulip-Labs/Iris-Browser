// The CEF engine's light or dark for pages (engine_set_color_scheme,
// engine_api.odin): Chromium's colour scheme on every request context a
// page has, so prefers-color-scheme follows Iris.
package iris

// (not indented: the whole file is this engine's)
when ENGINE_CEF {

CEF_COLOR_VARIANT_LIGHT :: 1
CEF_COLOR_VARIANT_DARK :: 2

@(private="file") pages_dark: Maybe(bool)

engine_set_color_scheme :: proc(dark: bool) {
	pages_dark = dark
	variant := i32(dark ? CEF_COLOR_VARIANT_DARK : CEF_COLOR_VARIANT_LIGHT)
	// the shared context (normal tabs), and each open page's own (containers,
	// private tabs, the sandbox)
	if g := cef_request_context_get_global_context(); g != nil {
		g.set_chrome_color_scheme(g, variant, 0)
		rel(g)
	}
	for t in browser_all_tabs() do tab_color_scheme(t)
}

/// a page's context told Iris's light or dark (a new view: cef_view.odin
/// may call this once its browser exists)
tab_color_scheme :: proc(t: ^Tab) {
	dark, ok := pages_dark.?
	if !ok do return
	v := t.cv
	if v == nil || v.host == nil do return
	c := v.host.get_request_context(v.host)
	if c == nil do return
	c.set_chrome_color_scheme(c, i32(dark ? CEF_COLOR_VARIANT_DARK : CEF_COLOR_VARIANT_LIGHT), 0)
	rel(c)
}

} // when ENGINE_CEF
