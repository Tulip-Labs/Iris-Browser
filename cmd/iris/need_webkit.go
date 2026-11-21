//go:build !(linux && webkit)

package main

// Iris runs on Linux with WebKitGTK: build it with -tags webkit
// (./build-iris.sh linux does). Anything else stops here.
var _ = Iris_is_built_for_Linux_with_the_webkit_build_tag
