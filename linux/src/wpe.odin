// The parts of WPE's API that tools/bind.py does not write: the class
// structs Iris subclasses (their virtual functions sit at the offsets the
// headers give: abi/check.sh holds them to it), two value structs, and the
// enums' values.
package iris

/// struct _WPEDisplayClass
WPEDisplayClass :: struct {
	parent_class:                 GObjectClass,
	connect:                      proc "c" (d: ^WPEDisplay, err: ^^GError) -> gboolean,
	create_view:                  proc "c" (d: ^WPEDisplay) -> ^WPEView,
	get_egl_display:              proc "c" (d: ^WPEDisplay, err: ^^GError) -> rawptr,
	get_keymap:                   proc "c" (d: ^WPEDisplay) -> ^WPEKeymap,
	get_clipboard:                proc "c" (d: ^WPEDisplay) -> ^WPEClipboard,
	get_preferred_buffer_formats: proc "c" (d: ^WPEDisplay) -> ^WPEBufferFormats,
	get_n_screens:                rawptr,
	get_screen:                   rawptr,
	get_drm_device:               proc "c" (d: ^WPEDisplay) -> ^WPEDRMDevice,
	use_explicit_sync:            rawptr,
	create_input_method_context:  rawptr,
	create_toplevel:              proc "c" (d: ^WPEDisplay, max_views: u32) -> ^WPEToplevel,
	create_gamepad_manager:       rawptr,
	padding:                      [32]rawptr,
}

/// struct _WPEViewClass
WPEViewClass :: struct {
	parent_class:          GObjectClass,
	buffers_changed:       rawptr,
	render_buffer:         proc "c" (v: ^WPEView, b: ^WPEBuffer, damage: [^]WPERectangle, n: u32, err: ^^GError) -> gboolean,
	lock_pointer:          rawptr,
	unlock_pointer:        rawptr,
	set_cursor_from_name:  proc "c" (v: ^WPEView, name: cstring),
	set_cursor_from_bytes: rawptr,
	set_opaque_rectangles: rawptr,
	can_be_mapped:         rawptr,
	get_accessible:        rawptr,
	padding:               [32]rawptr,
}

/// struct _WPEToplevelClass
WPEToplevelClass :: struct {
	parent_class:                 GObjectClass,
	set_title:                    proc "c" (t: ^WPEToplevel, title: cstring),
	get_screen:                   rawptr,
	resize:                       proc "c" (t: ^WPEToplevel, w, h: i32) -> gboolean,
	set_fullscreen:               proc "c" (t: ^WPEToplevel, on: gboolean) -> gboolean,
	set_maximized:                proc "c" (t: ^WPEToplevel, on: gboolean) -> gboolean,
	set_minimized:                proc "c" (t: ^WPEToplevel) -> gboolean,
	get_preferred_buffer_formats: rawptr,
	padding:                      [32]rawptr,
}

/// struct _WPEClipboardClass
WPEClipboardClass :: struct {
	parent_class: GObjectClass,
	read:         rawptr,
	changed:      proc "c" (c: ^WPEClipboard, formats: ^GPtrArray, is_local: gboolean, content: ^WPEClipboardContent),
	padding:      [8]rawptr,
}

/// struct _WPERectangle
WPERectangle :: struct {
	x, y, width, height: i32,
}

/// struct _WebKitColor
WebKitColor :: struct {
	red, green, blue, alpha: f64,
}

// WPEEventType
WPE_EVENT_POINTER_DOWN :: i32(1)
WPE_EVENT_POINTER_UP :: i32(2)
WPE_EVENT_POINTER_MOVE :: i32(3)
WPE_EVENT_POINTER_ENTER :: i32(4)
WPE_EVENT_POINTER_LEAVE :: i32(5)
WPE_EVENT_SCROLL :: i32(6)
WPE_EVENT_KEYBOARD_KEY_DOWN :: i32(7)
WPE_EVENT_KEYBOARD_KEY_UP :: i32(8)

// WPEInputSource
WPE_INPUT_SOURCE_MOUSE :: i32(0)
WPE_INPUT_SOURCE_KEYBOARD :: i32(2)
WPE_INPUT_SOURCE_TOUCHPAD :: i32(4)

// WPEModifiers
WPE_MODIFIER_KEYBOARD_CONTROL :: i32(1 << 0)
WPE_MODIFIER_KEYBOARD_SHIFT :: i32(1 << 1)
WPE_MODIFIER_KEYBOARD_ALT :: i32(1 << 2)
WPE_MODIFIER_KEYBOARD_META :: i32(1 << 3)
WPE_MODIFIER_POINTER_BUTTON1 :: i32(1 << 8)
WPE_MODIFIER_POINTER_BUTTON2 :: i32(1 << 9)
WPE_MODIFIER_POINTER_BUTTON3 :: i32(1 << 10)

// WPEToplevelState
WPE_TOPLEVEL_STATE_FULLSCREEN :: i32(1 << 0)
WPE_TOPLEVEL_STATE_ACTIVE :: i32(1 << 2)

WPE_BUFFER_FORMAT_USAGE_RENDERING :: i32(0)

// WebKitLoadEvent
WEBKIT_LOAD_STARTED :: u32(0)
WEBKIT_LOAD_COMMITTED :: u32(2)
WEBKIT_LOAD_FINISHED :: u32(3)

// WebKitPolicyDecisionType
WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION :: u32(0)
WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION :: u32(1)
WEBKIT_POLICY_DECISION_TYPE_RESPONSE :: u32(2)

// WebKitCookieAcceptPolicy
WEBKIT_COOKIE_POLICY_ACCEPT_NO_THIRD_PARTY :: i32(2)

// WebKitCacheModel
WEBKIT_CACHE_MODEL_WEB_BROWSER :: i32(1)

// WebKitScriptDialogType
WEBKIT_SCRIPT_DIALOG_ALERT :: i32(0)
WEBKIT_SCRIPT_DIALOG_CONFIRM :: i32(1)
WEBKIT_SCRIPT_DIALOG_PROMPT :: i32(2)
WEBKIT_SCRIPT_DIALOG_BEFORE_UNLOAD_CONFIRM :: i32(3)

// WebKitWebsiteDataTypes: everything
WEBKIT_WEBSITE_DATA_ALL :: i32((1 << 12) - 1)

// WebKitUserContentInjectedFrames, WebKitUserScriptInjectionTime
WEBKIT_USER_CONTENT_INJECT_TOP_FRAME :: i32(1)
WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_END :: i32(1)

// WebKitNavigationType
WEBKIT_NAVIGATION_TYPE_LINK_CLICKED :: i32(0)

// editing commands
WEBKIT_EDITING_COMMAND_CUT :: "Cut"
WEBKIT_EDITING_COMMAND_COPY :: "Copy"
WEBKIT_EDITING_COMMAND_PASTE :: "Paste"
WEBKIT_EDITING_COMMAND_SELECT_ALL :: "SelectAll"

// drm_fourcc.h
DRM_FORMAT_MOD_INVALID :: u64(0x00ffffffffffffff)
