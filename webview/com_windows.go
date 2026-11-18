//go:build windows

package webview

import (
	"sync"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

// guid is a COM interface ID.
type guid struct {
	d1     uint32
	d2, d3 uint16
	d4     [8]byte
}

var (
	iidIUnknown     = guid{0x00000000, 0x0000, 0x0000, [8]byte{0xc0, 0, 0, 0, 0, 0, 0, 0x46}}
	iidIAgileObject = guid{0x94ea2b94, 0xe9cc, 0x49e0, [8]byte{0xc0, 0xff, 0xee, 0x64, 0xca, 0x8f, 0x5b, 0x90}}

	ole32              = windows.NewLazySystemDLL("ole32.dll")
	procCoTaskMemAlloc = ole32.NewProc("CoTaskMemAlloc")
	procCoTaskMemFree  = ole32.NewProc("CoTaskMemFree")
	procCoInitializeEx = ole32.NewProc("CoInitializeEx")
)

const (
	sOK          = 0
	eNoInterface = 0x80004002
	eFail        = 0x80004005
)

// call invokes COM method slot of obj with args (obj itself is passed first).
func call(obj uintptr, slot int, args ...uintptr) uintptr {
	vtbl := *(*uintptr)(unsafe.Pointer(obj))
	fn := *(*uintptr)(unsafe.Pointer(vtbl + uintptr(slot)*unsafe.Sizeof(uintptr(0))))
	all := make([]uintptr, 0, len(args)+1)
	all = append(all, obj)
	all = append(all, args...)
	r, _, _ := syscall.SyscallN(fn, all...)
	return r
}

func failed(hr uintptr) bool { return int32(hr) < 0 }

func release(obj uintptr) {
	if obj != 0 {
		call(obj, 2)
	}
}

func addRef(obj uintptr) {
	if obj != 0 {
		call(obj, 1)
	}
}

// query asks obj for another interface; 0 when it has none.
func query(obj uintptr, iid *guid) uintptr {
	if obj == 0 {
		return 0
	}
	var out uintptr
	if failed(call(obj, 0, uintptr(unsafe.Pointer(iid)), uintptr(unsafe.Pointer(&out)))) {
		return 0
	}
	return out
}

// getPtr calls a getter that returns an interface pointer.
func getPtr(obj uintptr, slot int) uintptr {
	var out uintptr
	if obj == 0 || failed(call(obj, slot, uintptr(unsafe.Pointer(&out)))) {
		return 0
	}
	return out
}

// getString calls a getter that returns a CoTaskMem string and frees it.
func getString(obj uintptr, slot int) string {
	var p *uint16
	if obj == 0 || failed(call(obj, slot, uintptr(unsafe.Pointer(&p)))) || p == nil {
		return ""
	}
	s := windows.UTF16PtrToString(p)
	procCoTaskMemFree.Call(uintptr(unsafe.Pointer(p)))
	return s
}

func getBool(obj uintptr, slot int) bool {
	var b int32
	if obj == 0 || failed(call(obj, slot, uintptr(unsafe.Pointer(&b)))) {
		return false
	}
	return b != 0
}

func getInt(obj uintptr, slot int) int32 {
	var v int32
	if obj == 0 {
		return 0
	}
	call(obj, slot, uintptr(unsafe.Pointer(&v)))
	return v
}

func boolArg(b bool) uintptr {
	if b {
		return 1
	}
	return 0
}

// wstr makes a UTF-16 string for a call; keep the slice alive until the call returns.
func wstr(s string) *uint16 {
	p, err := windows.UTF16PtrFromString(s)
	if err != nil {
		p, _ = windows.UTF16PtrFromString("")
	}
	return p
}

// taskString returns s as a CoTaskMemAlloc'd UTF-16 string, for out-parameters the caller frees.
func taskString(s string) uintptr {
	u, _ := windows.UTF16FromString(s)
	n := uintptr(len(u)) * 2
	p, _, _ := procCoTaskMemAlloc.Call(n)
	if p == 0 {
		return 0
	}
	copy(unsafe.Slice((*uint16)(unsafe.Pointer(p)), len(u)), u)
	return p
}

// ---- COM objects implemented in Go ----

// handler is a WebView2 callback object (completed handlers and event handlers):
// IUnknown plus a single Invoke(a, b).
type handler struct {
	vtbl *[4]uintptr
	refs int32
	iid  guid
	fn   func(a, b uintptr) uintptr
}

var (
	liveMu sync.Mutex
	live   = map[uintptr]any{} // keeps Go COM objects reachable while COM holds them

	handlerVtbl = [4]uintptr{
		syscall.NewCallback(handlerQI),
		syscall.NewCallback(objAddRef),
		syscall.NewCallback(objRelease),
		syscall.NewCallback(handlerInvoke),
	}
)

// newHandler returns a COM pointer to a handler for interface iid. The caller
// owns one reference and releases it when done (the engine adds its own).
func newHandler(iid guid, fn func(a, b uintptr) uintptr) uintptr {
	h := &handler{vtbl: &handlerVtbl, refs: 1, iid: iid, fn: fn}
	p := uintptr(unsafe.Pointer(h))
	liveMu.Lock()
	live[p] = h
	liveMu.Unlock()
	return p
}

func sameGUID(a, b *guid) bool { return *a == *b }

func handlerQI(this, riid, ppv uintptr) uintptr {
	h := (*handler)(unsafe.Pointer(this))
	iid := (*guid)(unsafe.Pointer(riid))
	if sameGUID(iid, &iidIUnknown) || sameGUID(iid, &h.iid) || sameGUID(iid, &iidIAgileObject) {
		*(*uintptr)(unsafe.Pointer(ppv)) = this
		h.refs++
		return sOK
	}
	*(*uintptr)(unsafe.Pointer(ppv)) = 0
	return eNoInterface
}

// refCounted is the common head of every Go COM object.
type refCounted struct {
	vtbl uintptr
	refs int32
}

func objAddRef(this uintptr) uintptr {
	o := (*refCounted)(unsafe.Pointer(this))
	o.refs++
	return uintptr(o.refs)
}

func objRelease(this uintptr) uintptr {
	o := (*refCounted)(unsafe.Pointer(this))
	o.refs--
	if o.refs <= 0 {
		liveMu.Lock()
		delete(live, this)
		liveMu.Unlock()
		return 0
	}
	return uintptr(o.refs)
}

func handlerInvoke(this, a, b uintptr) uintptr {
	h := (*handler)(unsafe.Pointer(this))
	if h.fn == nil {
		return sOK
	}
	return h.fn(a, b)
}

// envOptions implements ICoreWebView2EnvironmentOptions: browser arguments and
// the minimum runtime version.
type envOptions struct {
	vtbl *[11]uintptr
	refs int32
	args string
	ext  envOptions6 // ICoreWebView2EnvironmentOptions6: extensions on
}

// envOptions6 is envOptions' ICoreWebView2EnvironmentOptions6 face (it
// shares envOptions' references).
type envOptions6 struct {
	vtbl  *[5]uintptr
	owner *envOptions
}

var envOptions6Vtbl = [5]uintptr{
	syscall.NewCallback(func(this, riid, ppv uintptr) uintptr {
		return envOptionsQI(uintptr(unsafe.Pointer((*envOptions6)(unsafe.Pointer(this)).owner)), riid, ppv)
	}),
	syscall.NewCallback(func(this uintptr) uintptr {
		o := (*envOptions6)(unsafe.Pointer(this)).owner
		return objAddRef(uintptr(unsafe.Pointer(o)))
	}),
	syscall.NewCallback(func(this uintptr) uintptr {
		o := (*envOptions6)(unsafe.Pointer(this)).owner
		return objRelease(uintptr(unsafe.Pointer(o)))
	}),
	syscall.NewCallback(func(this, out uintptr) uintptr { // get_AreBrowserExtensionsEnabled
		*(*int32)(unsafe.Pointer(out)) = 1
		return sOK
	}),
	syscall.NewCallback(func(this, v uintptr) uintptr { return sOK }), // put_
}

var envOptionsVtbl = [11]uintptr{
	syscall.NewCallback(envOptionsQI),
	syscall.NewCallback(objAddRef),
	syscall.NewCallback(objRelease),
	syscall.NewCallback(func(this, out uintptr) uintptr { // get_AdditionalBrowserArguments
		*(*uintptr)(unsafe.Pointer(out)) = taskString((*envOptions)(unsafe.Pointer(this)).args)
		return sOK
	}),
	syscall.NewCallback(func(this, v uintptr) uintptr { return sOK }), // put_
	syscall.NewCallback(func(this, out uintptr) uintptr { // get_Language: system default
		*(*uintptr)(unsafe.Pointer(out)) = taskString("")
		return sOK
	}),
	syscall.NewCallback(func(this, v uintptr) uintptr { return sOK }),
	syscall.NewCallback(func(this, out uintptr) uintptr { // get_TargetCompatibleBrowserVersion
		*(*uintptr)(unsafe.Pointer(out)) = taskString("86.0.616.0")
		return sOK
	}),
	syscall.NewCallback(func(this, v uintptr) uintptr { return sOK }),
	syscall.NewCallback(func(this, out uintptr) uintptr { // get_AllowSingleSignOnUsingOSPrimaryAccount
		*(*int32)(unsafe.Pointer(out)) = 0
		return sOK
	}),
	syscall.NewCallback(func(this, v uintptr) uintptr { return sOK }),
}

func newEnvOptions(args string) uintptr {
	o := &envOptions{vtbl: &envOptionsVtbl, refs: 1, args: args}
	o.ext = envOptions6{vtbl: &envOptions6Vtbl, owner: o}
	p := uintptr(unsafe.Pointer(o))
	liveMu.Lock()
	live[p] = o
	liveMu.Unlock()
	return p
}

func envOptionsQI(this, riid, ppv uintptr) uintptr {
	iid := (*guid)(unsafe.Pointer(riid))
	if sameGUID(iid, &iidIUnknown) || sameGUID(iid, &iidICoreWebView2EnvironmentOptions) || sameGUID(iid, &iidIAgileObject) {
		*(*uintptr)(unsafe.Pointer(ppv)) = this
		(*envOptions)(unsafe.Pointer(this)).refs++
		return sOK
	}
	if sameGUID(iid, &iidICoreWebView2EnvironmentOptions6) {
		o := (*envOptions)(unsafe.Pointer(this))
		*(*uintptr)(unsafe.Pointer(ppv)) = uintptr(unsafe.Pointer(&o.ext))
		o.refs++
		return sOK
	}
	*(*uintptr)(unsafe.Pointer(ppv)) = 0
	return eNoInterface
}
