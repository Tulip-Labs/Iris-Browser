package main

import (
	"sync"

	"litego/update"
)

// installKind is how this copy was installed, worked out once (on Flatpak it
// asks the host, which takes a moment).
var installKind = sync.OnceValue(func() string { return string(update.Detect()) })
