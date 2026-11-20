//go:build !windows && !(linux && webkit)

package main

// pickPicture: the desktop's file box (zenity or kdialog), for one picture.
func pickPicture() string {
	if f := pickFiles(); len(f) > 0 {
		return f[0]
	}
	return ""
}
