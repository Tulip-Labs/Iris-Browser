package main

import (
	"sync"

	"iris/update"
)

// installKind is how this copy was installed, worked out once.
var installKind = sync.OnceValue(func() string { return string(update.Detect()) })
