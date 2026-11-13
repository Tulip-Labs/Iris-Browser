// Package assets holds the fonts embedded in every build.
package assets

import _ "embed"

//go:embed fonts/Nunito-Regular.ttf
var NunitoRegular []byte

//go:embed fonts/Nunito-Bold.ttf
var NunitoBold []byte

//go:embed fonts/DejaVuSansMono.ttf
var Mono []byte
