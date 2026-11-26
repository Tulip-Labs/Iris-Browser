// Light or dark: GNOME's color-scheme (what `gsettings get
// org.gnome.desktop.interface color-scheme` prints), or IRIS_THEME.
package logic

Scheme :: enum {
	Auto,
	Dark,
	Light,
}

GSETTINGS_SCHEMA :: "org.gnome.desktop.interface"
GSETTINGS_KEY :: "color-scheme"

/// the answer of gsettings: 'prefer-dark', 'prefer-light' or 'default'
parse_color_scheme :: proc(s: string) -> (dark: bool) {
	return contains(s, "prefer-dark")
}

/// IRIS_THEME=dark|light|auto
parse_scheme :: proc(s: string) -> Scheme {
	switch s {
	case "dark": return .Dark
	case "light": return .Light
	}
	return .Auto
}
