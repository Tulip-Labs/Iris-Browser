package webview

import (
	"errors"
	"fmt"
	"unsafe"
)

// Browser extensions on WebView2 (ICoreWebView2Profile7). The environment is
// made with AreBrowserExtensionsEnabled (ICoreWebView2EnvironmentOptions6,
// see com_windows.go); extensions belong to the default profile, reached
// through any page open in it.


const (
	slotProfile7_AddBrowserExtension  = 22
	slotProfile7_GetBrowserExtensions = 23
	slotExtList_Count                 = 3
	slotExtList_GetValueAtIndex       = 4
	slotExt_Id                        = 3
	slotExt_Name                      = 4
	slotExt_Remove                    = 5
	slotExt_IsEnabled                 = 6
	slotExt_Enable                    = 7
)

var errNoExtensions = errors.New("extensions need a newer WebView2 runtime; Windows Update brings it")

// profile7 is the default profile's extension interface, through a page
// open in it; the caller releases it.
func (e *engine) profile7() uintptr {
	for v := range e.defaults {
		if v.closed {
			continue
		}
		c13 := query(v.core, &iidICoreWebView2_13)
		if c13 == 0 {
			continue
		}
		prof := getPtr(c13, slotICoreWebView2_13_Profile)
		release(c13)
		if prof == 0 {
			continue
		}
		p7 := query(prof, &iidICoreWebView2Profile7)
		release(prof)
		if p7 != 0 {
			return p7
		}
	}
	return 0
}

func readExtension(x uintptr) Extension {
	return Extension{ID: getString(x, slotExt_Id), Name: getString(x, slotExt_Name), Enabled: getBool(x, slotExt_IsEnabled)}
}

func (e *engine) AddExtension(dir string, done func(Extension, error)) {
	p7 := e.profile7()
	if p7 == 0 {
		done(Extension{}, errNoExtensions)
		return
	}
	defer release(p7)
	var h uintptr
	h = newHandler(iidICoreWebView2ProfileAddBrowserExtensionCompletedHandler, func(code, x uintptr) uintptr {
		defer release(h)
		if failed(code) || x == 0 {
			done(Extension{}, fmt.Errorf("the extension could not be added (0x%08x)", uint32(code)))
			return sOK
		}
		done(readExtension(x), nil)
		return sOK
	})
	if hr := call(p7, slotProfile7_AddBrowserExtension, uintptr(unsafe.Pointer(wstr(dir))), h); failed(hr) {
		release(h)
		done(Extension{}, fmt.Errorf("the extension could not be added (0x%08x)", uint32(hr)))
	}
}

// each calls f with every installed extension (the COM object is valid
// during the call only).
func (e *engine) each(f func(x uintptr) bool, done func(error)) {
	p7 := e.profile7()
	if p7 == 0 {
		done(errNoExtensions)
		return
	}
	defer release(p7)
	var h uintptr
	h = newHandler(iidICoreWebView2ProfileGetBrowserExtensionsCompletedHandler, func(code, list uintptr) uintptr {
		defer release(h)
		if failed(code) || list == 0 {
			done(fmt.Errorf("the extensions could not be listed (0x%08x)", uint32(code)))
			return sOK
		}
		var n uint32
		call(list, slotExtList_Count, uintptr(unsafe.Pointer(&n)))
		for i := uint32(0); i < n && i < 500; i++ {
			x := getPtrArg(list, slotExtList_GetValueAtIndex, uintptr(i))
			if x == 0 {
				continue
			}
			more := f(x)
			release(x)
			if !more {
				break
			}
		}
		done(nil)
		return sOK
	})
	if hr := call(p7, slotProfile7_GetBrowserExtensions, h); failed(hr) {
		release(h)
		done(fmt.Errorf("the extensions could not be listed (0x%08x)", uint32(hr)))
	}
}

func getPtrArg(obj uintptr, slot int, arg uintptr) uintptr {
	var out uintptr
	if obj == 0 || failed(call(obj, slot, arg, uintptr(unsafe.Pointer(&out)))) {
		return 0
	}
	return out
}

func (e *engine) Extensions(done func([]Extension, error)) {
	var out []Extension
	e.each(func(x uintptr) bool { out = append(out, readExtension(x)); return true }, func(err error) { done(out, err) })
}

func (e *engine) RemoveExtension(id string, done func(error)) {
	e.onExtension(id, func(x uintptr, finish func(error)) {
		var h uintptr
		h = newHandler(iidICoreWebView2BrowserExtensionRemoveCompletedHandler, func(code, _ uintptr) uintptr {
			defer release(h)
			finish(hrErr(code, "removed"))
			return sOK
		})
		if hr := call(x, slotExt_Remove, h); failed(hr) {
			release(h)
			finish(hrErr(hr, "removed"))
		}
	}, done)
}

func (e *engine) EnableExtension(id string, on bool, done func(error)) {
	e.onExtension(id, func(x uintptr, finish func(error)) {
		var h uintptr
		h = newHandler(iidICoreWebView2BrowserExtensionEnableCompletedHandler, func(code, _ uintptr) uintptr {
			defer release(h)
			finish(hrErr(code, "changed"))
			return sOK
		})
		if hr := call(x, slotExt_Enable, boolArg(on), h); failed(hr) {
			release(h)
			finish(hrErr(hr, "changed"))
		}
	}, done)
}

// onExtension runs act on extension id (keeping it alive until act finishes).
func (e *engine) onExtension(id string, act func(x uintptr, finish func(error)), done func(error)) {
	var found uintptr
	e.each(func(x uintptr) bool {
		if getString(x, slotExt_Id) == id {
			addRef(x)
			found = x
			return false
		}
		return true
	}, func(err error) {
		if err != nil {
			done(err)
			return
		}
		if found == 0 {
			done(errors.New("that extension is not installed"))
			return
		}
		act(found, func(err error) { release(found); done(err) })
	})
}

func hrErr(hr uintptr, what string) error {
	if failed(hr) {
		return fmt.Errorf("the extension could not be %s (0x%08x)", what, uint32(hr))
	}
	return nil
}
