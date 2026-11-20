//go:build windows

package winpresent

import (
	"sync"
	"unicode/utf16"
	"unsafe"

	"golang.org/x/sys/windows"
)

// The Windows presenter: the pages' child windows in Iris's window.
//
// Linux has GTK as the compositor (electron_linux.c turns each
// page's frames into a texture the window draws). Windows has no GTK, so the
// pages live in Iris's window as child windows of its own, one per page
// view, painted here with GDI. The child window takes the pointer, the wheel
// and the keys over a page and hands them to the page's engine, exactly as
// the GTK code does on Linux: Iris's own shortcuts are checked first,
// through the view's Events.Key, then the keys and typed text go to the
// page. Pure Go, no cgo: the Windows build runs with CGO_ENABLED=0.
//
// A page's frames arrive as BGRA pixels (premultiplied), the same as on
// Linux, and are kept per view; only the rectangle that changed is copied
// in, and WM_PAINT draws the whole frame with StretchDIBits. One texel on
// one screen pixel when the frame matches the view's size.

const (
	Electron = 1
)

// PageInput is what a page's child window reports to its engine.
type PageInput interface {
	Mouse(id uintptr, kind int, x, y float64, button, clicks int, mods uint)
	Wheel(id uintptr, x, y, dx, dy float64, precise bool, mods uint)
	KeyEv(id uintptr, down bool, code string, mods uint)
	Char(id uintptr, text string, mods uint)
	Nav(id uintptr, fwd bool)
	// key asks whether Iris's shortcut table takes the key (ch is the typed
	// character, 0 when there is none); true means handled, do not send on.
	Key(id uintptr, ch rune, vk uint32, ctrl, shift, alt bool) bool
	Focus(id uintptr)
}

// modifiers, as the Linux code reads them (electron_linux.c)
const (
	modShift = 1
	modCtrl  = 2
	modAlt   = 4
	modMeta  = 8
	modLeft  = 16
	modMid   = 32
	modRight = 64
	modCaps  = 128
)

var (
	user32 = windows.NewLazySystemDLL("user32.dll")
	gdi32  = windows.NewLazySystemDLL("gdi32.dll")
	kernel = windows.NewLazySystemDLL("kernel32.dll")

	procRegisterClassEx  = user32.NewProc("RegisterClassExW")
	procCreateWindowEx   = user32.NewProc("CreateWindowExW")
	procDefWindowProc    = user32.NewProc("DefWindowProcW")
	procDestroyWindow    = user32.NewProc("DestroyWindow")
	procSetWindowPos     = user32.NewProc("SetWindowPos")
	procSetWindowRgn     = user32.NewProc("SetWindowRgn")
	procCreateRoundRgn   = gdi32.NewProc("CreateRoundRectRgn")
	procCreateRectRgn    = gdi32.NewProc("CreateRectRgn")
	procCombineRgn       = gdi32.NewProc("CombineRgn")
	procDeleteObject     = gdi32.NewProc("DeleteObject")
	procShowWindow       = user32.NewProc("ShowWindow")
	procInvalidateRect   = user32.NewProc("InvalidateRect")
	procBeginPaint       = user32.NewProc("BeginPaint")
	procEndPaint         = user32.NewProc("EndPaint")
	procStretchDIBits    = gdi32.NewProc("StretchDIBits")
	procGetDpiForWindow  = user32.NewProc("GetDpiForWindow")
	procGetDC            = user32.NewProc("GetDC")
	procReleaseDC        = user32.NewProc("ReleaseDC")
	procGetDeviceCaps    = gdi32.NewProc("GetDeviceCaps")
	procLoadCursor       = user32.NewProc("LoadCursorW")
	procSetCursor        = user32.NewProc("SetCursor")
	procGetKeyState      = user32.NewProc("GetKeyState")
	procGetDoubleClickT  = user32.NewProc("GetDoubleClickTime")
	procGetSystemMetrics = user32.NewProc("GetSystemMetrics")
	procPostMessage      = user32.NewProc("PostMessageW")
	procTrackMouseEvent  = user32.NewProc("TrackMouseEvent")
	procGetModuleHandle  = kernel.NewProc("GetModuleHandleW")
	procMapVirtualKey    = user32.NewProc("MapVirtualKeyW")
	procSetFocus         = user32.NewProc("SetFocus")
	procScreenToClient   = user32.NewProc("ScreenToClient")
	procFillRect         = user32.NewProc("FillRect")
	procGetStockObject   = gdi32.NewProc("GetStockObject")
)

const (
	wmPaint       = 0x000F
	wmEraseBkgnd  = 0x0014
	wmSetFocus    = 0x0007
	wmKillFocus   = 0x0008
	wmSetCursor   = 0x0020
	wmMouseMove   = 0x0200
	wmLButtonDown = 0x0201
	wmLButtonUp   = 0x0202
	wmLButtonDbl  = 0x0203
	wmRButtonDown = 0x0204
	wmRButtonUp   = 0x0205
	wmMButtonDown = 0x0207
	wmMButtonUp   = 0x0208
	wmMouseWheel  = 0x020A
	wmXButtonDown = 0x020B
	wmXButtonUp   = 0x020C
	wmMouseHWheel = 0x020E
	wmMouseLeave  = 0x02A3
	wmKeyDown     = 0x0100
	wmKeyUp       = 0x0101
	wmChar        = 0x0102
	wmSysKeyDown  = 0x0104
	wmSysKeyUp    = 0x0105
	wmAppRun      = 0x8001 // run a queued func on the window's thread
	wmDestroy     = 0x0002

	mkLButton  = 0x0001
	mkRButton  = 0x0002
	mkShift    = 0x0004
	mkControl  = 0x0008
	mkMButton  = 0x0010
	mkXButton1 = 0x0020
	mkXButton2 = 0x0040

	swpNoSize     = 0x0001
	swpNoMove     = 0x0002
	swpNoZOrder   = 0x0004
	swpNoActivate = 0x0010
	swpShowWindow = 0x0040
	swpHideWindow = 0x0080

	swHide = 0
	swShow = 5

	logPixelsX = 88
	smCxDblClk = 36
	smCyDblClk = 37

	tmeLeave = 0x00000002

	vkShift     = 0x10
	vkControl   = 0x11
	vkMenu      = 0x12 // Alt
	vkCapital   = 0x14
	vkEscape    = 0x1B
	vkSpace     = 0x20
	vkPrior     = 0x21
	vkNext      = 0x22
	vkEnd       = 0x23
	vkHome      = 0x24
	vkLeft      = 0x25
	vkUp        = 0x26
	vkRight     = 0x27
	vkDown      = 0x28
	vkInsert    = 0x2D
	vkDelete    = 0x2E
	vkLWin      = 0x5B
	vkF1        = 0x70
	vkNumlock   = 0x90
	vkOem1      = 0xBA
	vkOemPlus   = 0xBB
	vkOemComma  = 0xBC
	vkOemMinus  = 0xBD
	vkOemPeriod = 0xBE
	vkOem2      = 0xBF
	vkOem3      = 0xC0
	vkOem4      = 0xDB
	vkOem5      = 0xDC
	vkOem6      = 0xDD
	vkOem7      = 0xDE

	hwndMessage = ^uintptr(2) // HWND_MESSAGE: a window with no visible presence
)

type rect struct{ left, top, right, bottom int32 }

type wndClassEx struct {
	cbSize, style uint32
	lpfnWndProc   uintptr
	cbClsExtra    int32
	cbWndExtra    int32
	hInstance     uintptr
	hIcon         uintptr
	hCursor       uintptr
	hbrBackground uintptr
	lpszMenuName  *uint16
	lpszClassName *uint16
	hIconSm       uintptr
}

type paintStruct struct {
	hdc         uintptr
	fErase      uint32
	rcPaint     rect
	fRestore    uint32
	fIncUpdate  uint32
	rgbReserved [32]byte
}

type bitmapInfoHeader struct {
	biSize          uint32
	biWidth         int32
	biHeight        int32
	biPlanes        uint16
	biBitCount      uint16
	biCompression   uint32
	biSizeImage     uint32
	biXPelsPerMeter int32
	biYPelsPerMeter int32
	biClrUsed       uint32
	biClrImportant  uint32
}

type bitmapInfo struct {
	bmiHeader bitmapInfoHeader
	bmiColors [1]uint32
}

type trackMouseEvent struct {
	cbSize      uint32
	dwFlags     uint32
	hwndTrack   windows.HWND
	dwHoverTime uint32
}

type point struct{ x, y int32 }

type pageKey struct {
	kind int
	id   uintptr
}

// pageWin is one page's child window.
type pageWin struct {
	key    pageKey
	hwnd   windows.HWND
	in     PageInput
	shown  bool
	x, y   int // in the parent, physical pixels
	w, h   int
	frame  []byte // the whole frame, BGRA premultiplied
	fw, fh int
	cursor string
	// click counting (as the GTK code counts)
	lastClick   int64 // GetTickCount64 would do; time is simpler here
	lastX       int
	lastY       int
	lastButton  int
	clicks      int
	pendingHigh uint16 // a high surrogate waiting for its low half
	tracked     bool   // TrackMouseEvent asked for WM_MOUSELEAVE
}

type Presenter struct {
	parent windows.HWND
	mu     sync.Mutex
	pages  map[pageKey]*pageWin
	byHwnd map[windows.HWND]*pageWin
	inputs map[int]PageInput // the engine behind each kind of page
	main   windows.HWND      // message-only window for onMain
	queue  []func()
	// overlay is where Iris draws over the pages (x, y, w, h; window pixels)
	overlay [4]int
}

var attached *Presenter

func Attach(parent uintptr) *Presenter {
	if attached != nil && attached.parent == windows.HWND(parent) {
		return attached
	}
	p := &Presenter{parent: windows.HWND(parent), pages: map[pageKey]*pageWin{}, byHwnd: map[windows.HWND]*pageWin{}, inputs: map[int]PageInput{}}
	attached = p
	p.register()
	// a message-only window: its procedure runs on this (the window's)
	// thread, which is where the engine's onMain work must run
	h, _, _ := procCreateWindowEx.Call(0,
		uintptr(unsafe.Pointer(classNamePtr())), uintptr(unsafe.Pointer(nil)),
		0, 0, 0, 0, 0, hwndMessage, 0, hInstance(), 0)
	p.main = windows.HWND(h)
	return p
}

var className = []uint16{'I', 'r', 'i', 's', 'P', 'a', 'g', 'e', 0}

func classNamePtr() *uint16 { return &className[0] }

func hInstance() uintptr {
	h, _, _ := procGetModuleHandle.Call(0)
	return h
}

func (p *Presenter) register() {
	wc := &wndClassEx{
		cbSize:        uint32(unsafe.Sizeof(wndClassEx{})),
		lpfnWndProc:   windows.NewCallback(pageWndProc),
		hInstance:     hInstance(),
		lpszClassName: classNamePtr(),
	}
	procRegisterClassEx.Call(uintptr(unsafe.Pointer(wc)))
}

// scale is the window's DPI scale now (GetDpiForWindow, or the screen's DPI).
func (p *Presenter) Scale() float64 {
	if r, _, _ := procGetDpiForWindow.Call(uintptr(p.parent)); r != 0 {
		return float64(r) / 96
	}
	dc, _, _ := procGetDC.Call(0)
	if dc == 0 {
		return 1
	}
	dpi, _, _ := procGetDeviceCaps.Call(dc, logPixelsX)
	procReleaseDC.Call(0, dc)
	if dpi <= 0 {
		return 1
	}
	return float64(dpi) / 96
}

// setInput is the engine behind a kind of page.
func (p *Presenter) SetInput(kind int, in PageInput) {
	p.mu.Lock()
	p.inputs[kind] = in
	for k, v := range p.pages {
		if k.kind == kind {
			v.in = in
		}
	}
	p.mu.Unlock()
}

// win is a page's child window, made when first needed (as the GTK code
// makes a page's entry on first use).
func (p *Presenter) win(kind int, id uintptr) *pageWin {
	p.mu.Lock()
	defer p.mu.Unlock()
	k := pageKey{kind, id}
	if v, ok := p.pages[k]; ok {
		return v
	}
	h, _, _ := procCreateWindowEx.Call(0,
		uintptr(unsafe.Pointer(classNamePtr())), uintptr(unsafe.Pointer(nil)),
		0x40000000, // WS_CHILD; shown only when the engine shows the view
		0, 0, 0, 0, uintptr(p.parent), 0, hInstance(), 0)
	v := &pageWin{key: k, hwnd: windows.HWND(h), in: p.inputs[kind]}
	p.pages[k] = v
	p.byHwnd[v.hwnd] = v
	return v
}

// find is a page's window, or nil when it has none yet (windows are made
// on the window's thread only: Place and Show; frames wait for them).
func (p *Presenter) find(kind int, id uintptr) *pageWin {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.pages[pageKey{kind, id}]
}

func (p *Presenter) Place(kind int, id uintptr, x, y, w, h int) {
	v := p.win(kind, id)
	p.mu.Lock()
	v.x, v.y, v.w, v.h = x, y, w, h
	p.mu.Unlock()
	procSetWindowPos.Call(uintptr(v.hwnd), 0, uintptr(x), uintptr(y), uintptr(w), uintptr(h),
		swpNoZOrder|swpNoActivate)
	p.shape(v)
}

// shape gives a page's window its outline: rounded corners like the glass
// around it (none full screen), and a hole where Iris draws a menu over the
// pages (Windows cannot draw over a child window). The system keeps the
// region.
func (p *Presenter) shape(v *pageWin) {
	p.mu.Lock()
	x, y, w, h, ov := v.x, v.y, v.w, v.h, p.overlay
	p.mu.Unlock()
	if w <= 0 || h <= 0 {
		return
	}
	r := 0
	if x != 0 || y != 0 {
		r = int(12*p.Scale() + 0.5)
	}
	rgn, _, _ := procCreateRoundRgn.Call(0, 0, uintptr(w+1), uintptr(h+1), uintptr(2*r+1), uintptr(2*r+1))
	if ov[2] > 0 && ov[3] > 0 {
		hole, _, _ := procCreateRectRgn.Call(uintptr(int32(ov[0]-x)), uintptr(int32(ov[1]-y)), uintptr(int32(ov[0]+ov[2]-x)), uintptr(int32(ov[1]+ov[3]-y)))
		procCombineRgn.Call(rgn, rgn, hole, 4) // RGN_DIFF
		procDeleteObject.Call(hole)
	}
	procSetWindowRgn.Call(uintptr(v.hwnd), rgn, 1)
}

// SetOverlay is where Iris draws over the pages now (a right-click menu), in
// the window's pixels; zero width: nothing. Pages under it are cut away there.
func (p *Presenter) SetOverlay(x, y, w, h int) {
	p.mu.Lock()
	if p.overlay == [4]int{x, y, w, h} {
		p.mu.Unlock()
		return
	}
	p.overlay = [4]int{x, y, w, h}
	vs := make([]*pageWin, 0, len(p.pages))
	for _, v := range p.pages {
		vs = append(vs, v)
	}
	p.mu.Unlock()
	for _, v := range vs {
		p.shape(v)
	}
}

func (p *Presenter) Show(kind int, id uintptr, on bool) {
	v := p.win(kind, id)
	p.mu.Lock()
	v.shown = on
	p.mu.Unlock()
	if on {
		procShowWindow.Call(uintptr(v.hwnd), swShow)
	} else {
		procShowWindow.Call(uintptr(v.hwnd), swHide)
	}
}

func (p *Presenter) Drop(kind int, id uintptr) {
	p.mu.Lock()
	v := p.pages[pageKey{kind, id}]
	if v != nil {
		delete(p.pages, pageKey{kind, id})
		delete(p.byHwnd, v.hwnd)
	}
	p.mu.Unlock()
	if v == nil {
		return
	}
	procDestroyWindow.Call(uintptr(v.hwnd))
}

func (p *Presenter) Focus(kind int, id uintptr) {
	v := p.find(kind, id)
	if v == nil {
		return
	}
	// SetFocus is user32's; the child takes the keyboard from here
	procSetFocus.Call(uintptr(v.hwnd))
}

func (p *Presenter) Paint(kind int, id uintptr, fw, fh, x, y, w, h int, pix []byte) {
	v := p.find(kind, id) // frames come from the engine's reader, off the window's thread
	if v == nil {
		return
	}
	p.mu.Lock()
	if v.frame == nil || v.fw != fw || v.fh != fh {
		v.frame = make([]byte, fw*fh*4)
		v.fw, v.fh = fw, fh
	}
	if x < 0 {
		w += x
		x = 0
	}
	if y < 0 {
		h += y
		y = 0
	}
	if x+w > fw {
		w = fw - x
	}
	if y+h > fh {
		h = fh - y
	}
	if w > 0 && h > 0 {
		// pix holds rows of w pixels, 4 bytes each, in order
		for r := 0; r < h; r++ {
			copy(v.frame[((y+r)*fw+x)*4:], pix[r*w*4:(r+1)*w*4])
		}
	}
	p.mu.Unlock()
	procInvalidateRect.Call(uintptr(v.hwnd), 0, 0)
}

func (p *Presenter) Cursor(kind int, id uintptr, name string) {
	v := p.find(kind, id)
	if v == nil {
		return
	}
	p.mu.Lock()
	v.cursor = name
	p.mu.Unlock()
}

// runOnMain runs f on the window's thread (through the message-only window).
func (p *Presenter) RunOnMain(f func()) {
	p.mu.Lock()
	p.queue = append(p.queue, f)
	p.mu.Unlock()
	if p.main != 0 {
		procPostMessage.Call(uintptr(p.main), wmAppRun, 0, 0)
	}
}

func (p *Presenter) drainMain() {
	p.mu.Lock()
	q := p.queue
	p.queue = nil
	p.mu.Unlock()
	for _, f := range q {
		f()
	}
}

func pageWndProc(hwnd windows.HWND, msg uint32, wparam, lparam uintptr) uintptr {
	p := attached
	if p == nil {
		r, _, _ := procDefWindowProc.Call(uintptr(hwnd), uintptr(msg), wparam, lparam)
		return r
	}
	if hwnd == p.main {
		if msg == wmAppRun {
			p.drainMain()
			return 0
		}
		r, _, _ := procDefWindowProc.Call(uintptr(hwnd), uintptr(msg), wparam, lparam)
		return r
	}
	p.mu.Lock()
	v := p.byHwnd[hwnd]
	p.mu.Unlock()
	if v == nil {
		r, _, _ := procDefWindowProc.Call(uintptr(hwnd), uintptr(msg), wparam, lparam)
		return r
	}
	switch msg {
	case wmEraseBkgnd:
		return 1 // painted in WM_PAINT, no flicker
	case wmPaint:
		p.paintWin(v)
		return 0
	case wmSetCursor:
		if lparam&0xffff == 1 { // HTCLIENT: the pointer is over the page
			if c := cursorHandle(v.cursor); c != 0 {
				procSetCursor.Call(c)
				return 1
			}
		}
	case wmSetFocus:
		if v.in != nil {
			v.in.Focus(v.key.id)
		}
		return 0
	case wmMouseLeave:
		if v.in != nil {
			v.in.Mouse(v.key.id, 3, -1, -1, 0, 0, 0)
		}
		v.tracked = false
		return 0
	case wmMouseMove, wmLButtonDown, wmLButtonUp, wmRButtonDown, wmRButtonUp, wmMButtonDown, wmMButtonUp, wmMouseWheel, wmMouseHWheel, wmXButtonDown, wmXButtonUp:
		p.pointer(v, msg, wparam, lparam)
		return 0
	case wmKeyDown, wmSysKeyDown, wmKeyUp, wmSysKeyUp:
		p.key(v, msg, wparam, lparam)
		return 0
	case wmChar:
		p.char(v, wparam, lparam)
		return 0
	}
	r, _, _ := procDefWindowProc.Call(uintptr(hwnd), uintptr(msg), wparam, lparam)
	return r
}

func (p *Presenter) paintWin(v *pageWin) {
	var ps paintStruct
	hdc, _, _ := procBeginPaint.Call(uintptr(v.hwnd), uintptr(unsafe.Pointer(&ps)))
	if hdc == 0 {
		return
	}
	p.mu.Lock()
	frame, fw, fh, w, h := v.frame, v.fw, v.fh, v.w, v.h
	p.mu.Unlock()
	if frame != nil && fw > 0 && fh > 0 && w > 0 && h > 0 {
		bi := bitmapInfo{bmiHeader: bitmapInfoHeader{
			biSize:        uint32(unsafe.Sizeof(bitmapInfoHeader{})),
			biWidth:       int32(fw),
			biHeight:      -int32(fh), // top-down
			biPlanes:      1,
			biBitCount:    32,
			biCompression: 0, // BI_RGB: BGRA bytes, alpha ignored
		}}
		procStretchDIBits.Call(hdc, 0, 0, uintptr(w), uintptr(h), 0, 0, uintptr(fw), uintptr(fh),
			uintptr(unsafe.Pointer(&frame[0])), uintptr(unsafe.Pointer(&bi)), 0, 0x00CC0020) // DIB_RGB_COLORS, SRCCOPY
	} else {
		// no frame yet: white, as the GTK code paints
		white := rect{0, 0, int32(w), int32(h)}
		brush, _, _ := procGetStockObject.Call(0) // WHITE_BRUSH
		procFillRect.Call(hdc, uintptr(unsafe.Pointer(&white)), brush)
	}
	procEndPaint.Call(uintptr(v.hwnd), uintptr(unsafe.Pointer(&ps)))
}

// pointer is a pointer or wheel message over a page.
func (p *Presenter) pointer(v *pageWin, msg uint32, wparam, lparam uintptr) {
	if v.in == nil {
		return
	}
	x := int(int16(lparam & 0xffff))
	y := int(int16(lparam >> 16 & 0xffff))
	mods := modsOfWParam(wparam)
	if !v.tracked {
		v.tracked = true
		tme := trackMouseEvent{cbSize: uint32(unsafe.Sizeof(trackMouseEvent{})), dwFlags: tmeLeave, hwndTrack: v.hwnd}
		procTrackMouseEvent.Call(uintptr(unsafe.Pointer(&tme)))
	}
	switch msg {
	case wmMouseMove:
		v.in.Mouse(v.key.id, 0, float64(x), float64(y), 0, 0, mods)
	case wmLButtonDown, wmRButtonDown, wmMButtonDown:
		button := 0
		switch msg {
		case wmRButtonDown:
			button = 2
		case wmMButtonDown:
			button = 1
		}
		now := tickCount()
		dx, dy := int64(0), int64(0)
		if v.lastX != 0 || v.lastY != 0 {
			dx, dy = int64(x-v.lastX), int64(y-v.lastY)
		}
		dblT, _, _ := procGetDoubleClickT.Call()
		cx, _, _ := procGetSystemMetrics.Call(smCxDblClk)
		cy, _, _ := procGetSystemMetrics.Call(smCyDblClk)
		if button == v.lastButton && now-v.lastClick < int64(dblT) && dx*dx+dy*dy < int64(cx*cx+cy*cy) {
			v.clicks = v.clicks%3 + 1
		} else {
			v.clicks = 1
		}
		v.lastClick, v.lastX, v.lastY, v.lastButton = now, x, y, button
		procSetFocus.Call(uintptr(v.hwnd))
		v.in.Focus(v.key.id)
		v.in.Mouse(v.key.id, 1, float64(x), float64(y), button, v.clicks, mods)
	case wmLButtonUp, wmRButtonUp, wmMButtonUp:
		button := 0
		switch msg {
		case wmRButtonUp:
			button = 2
		case wmMButtonUp:
			button = 1
		}
		v.in.Mouse(v.key.id, 2, float64(x), float64(y), button, v.clicks, mods)
	case wmMouseWheel, wmMouseHWheel:
		// a wheel notch is 120; the Linux code sends 40 pixels a notch.
		// The wheel's position is in screen coordinates, not the child's.
		pt := point{x: int32(x), y: int32(y)}
		procScreenToClient.Call(uintptr(v.hwnd), uintptr(unsafe.Pointer(&pt)))
		d := int16(wparam >> 16)
		dx, dy := 0.0, float64(d)/120*40
		if msg == wmMouseHWheel {
			dx, dy = float64(d)/120*40, 0
		}
		if mods&modShift != 0 && dx == 0 {
			dx, dy = dy, 0
		}
		v.in.Wheel(v.key.id, float64(pt.x), float64(pt.y), dx, dy, false, mods)
	case wmXButtonDown:
		if wparam>>16&0xffff == 1 {
			v.in.Nav(v.key.id, false)
		} else {
			v.in.Nav(v.key.id, true)
		}
	}
}

func modsOfWParam(wparam uintptr) uint {
	var m uint
	if wparam&mkShift != 0 {
		m |= modShift
	}
	if wparam&mkControl != 0 {
		m |= modCtrl
	}
	if wparam&mkLButton != 0 {
		m |= modLeft
	}
	if wparam&mkMButton != 0 {
		m |= modMid
	}
	if wparam&mkRButton != 0 {
		m |= modRight
	}
	if keyDown(vkMenu) {
		m |= modAlt
	}
	if keyDown(vkCapital) {
		m |= modCaps
	}
	return m
}

func keyDown(vk uint32) bool {
	r, _, _ := procGetKeyState.Call(uintptr(vk))
	return int16(r) < 0
}

func tickCount() int64 {
	// GetTickCount64 is kernel32's; the click window only needs a steady clock
	r, _, _ := procGetTickCount64.Call()
	return int64(r)
}

var procGetTickCount64 = kernel.NewProc("GetTickCount64")

// key is a key press or release over a page.
func (p *Presenter) key(v *pageWin, msg uint32, wparam, lparam uintptr) {
	if v.in == nil {
		return
	}
	vk := uint32(wparam)
	down := msg == wmKeyDown || msg == wmSysKeyDown
	ctrl, shift, alt := keyDown(vkControl), keyDown(vkShift), keyDown(vkMenu)
	mods := modsOfWParam(0)
	if ctrl {
		mods |= modCtrl
	}
	if shift {
		mods |= modShift
	}
	if alt {
		mods |= modAlt
	}
	if down {
		// Iris's own shortcuts first (Ctrl+T, Ctrl+L, F5, Alt+Left…)
		var ch rune
		if c, _, _ := procMapVirtualKey.Call(uintptr(vk), 2); c != 0 { // MAPVK_VK_TO_CHAR
			ch = rune(c)
		}
		if v.in.Key(v.key.id, ch, vk, ctrl, shift, alt) {
			return
		}
		if name := winKeyName(vk, shift); name != "" {
			v.in.KeyEv(v.key.id, true, name, mods)
		}
	} else {
		if name := winKeyName(vk, shift); name != "" {
			v.in.KeyEv(v.key.id, false, name, mods)
		}
	}
}

// char is typed text over a page (WM_CHAR).
func (p *Presenter) char(v *pageWin, wparam, lparam uintptr) {
	if v.in == nil {
		return
	}
	u := uint16(wparam)
	if u < 0x20 {
		return // a control character (Enter, Tab, Ctrl+C…): the key event carries it
	}
	if keyDown(vkControl) && !keyDown(vkMenu) {
		return
	}
	var r rune
	switch {
	case u >= 0xD800 && u <= 0xDBFF:
		v.pendingHigh = u // a high surrogate: wait for its low half
		return
	case u >= 0xDC00 && u <= 0xDFFF && v.pendingHigh != 0:
		r = utf16.DecodeRune(rune(v.pendingHigh), rune(u))
		v.pendingHigh = 0
	default:
		r = rune(u)
	}
	if r == 0 {
		return
	}
	mods := modsOfWParam(0)
	v.in.Char(v.key.id, string(r), mods)
}

// winKeyName is Electron's name for a key (an accelerator's key code); ""
// for keys that only type text. It follows electron_linux.c's keyName.
func winKeyName(vk uint32, shift bool) string {
	switch {
	case vk >= 'A' && vk <= 'Z':
		return string(rune(vk))
	case vk >= '0' && vk <= '9':
		return string(rune(vk))
	case vk >= 0x60 && vk <= 0x69: // the number pad's digits
		return string(rune('0' + vk - 0x60))
	case vk >= vkF1 && vk <= vkF1+23:
		return "F" + itoa(int(vk-vkF1+1))
	}
	switch vk {
	case 0x08:
		return "Backspace"
	case 0x09:
		return "Tab"
	case 0x0D:
		return "Enter"
	case 0x1B:
		return "Escape"
	case 0x20:
		return "Space"
	case vkPrior:
		return "PageUp"
	case vkNext:
		return "PageDown"
	case vkEnd:
		return "End"
	case vkHome:
		return "Home"
	case vkLeft:
		return "Left"
	case vkUp:
		return "Up"
	case vkRight:
		return "Right"
	case vkDown:
		return "Down"
	case 0x2D:
		return "Insert"
	case vkDelete:
		return "Delete"
	case 0x10:
		return "Shift"
	case 0x11:
		return "Control"
	case 0x12:
		return "Alt"
	case vkLWin, 0x5C:
		return "Super"
	case vkCapital:
		return "Capslock"
	case vkNumlock:
		return "Numlock"
	case 0x5D:
		return "ContextMenu"
	case vkOemMinus, 0x6D:
		return "-"
	case vkOemPlus, 0x6B:
		if shift {
			return "Plus"
		}
		return "="
	case vkOemComma:
		return ","
	case vkOemPeriod, 0x6E:
		return "."
	case vkOem2, 0x6F:
		return "/"
	case 0x6A:
		return "*"
	case vkOem1:
		return ";"
	case vkOem7:
		return "'"
	case vkOem4:
		return "["
	case vkOem6:
		return "]"
	case vkOem5:
		return "\\"
	case vkOem3:
		return "`"
	}
	return ""
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b [8]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	return string(b[i:])
}

// cursorHandle is the system cursor for the name the engine reports.
func cursorHandle(name string) uintptr {
	var id uintptr = 32512 // IDC_ARROW
	switch name {
	case "pointer", "hand":
		id = 32649 // IDC_HAND
	case "text", "vertical-text":
		id = 32513 // IDC_IBEAM
	case "wait", "progress":
		id = 32514 // IDC_WAIT
	case "crosshair":
		id = 32515 // IDC_CROSS
	case "move":
		id = 32646 // IDC_SIZEALL
	case "not-allowed":
		id = 32648 // IDC_NO
	case "help":
		id = 32651 // IDC_HELP
	case "col-resize", "ew-resize":
		id = 32644 // IDC_SIZEWE
	case "row-resize", "ns-resize":
		id = 32645 // IDC_SIZENS
	case "nesw-resize":
		id = 32643 // IDC_SIZENESW
	case "nwse-resize":
		id = 32642 // IDC_SIZENWSE
	case "cell":
		id = 32516 // IDC_UPARROW
	}
	h, _, _ := procLoadCursor.Call(0, id)
	return h
}
