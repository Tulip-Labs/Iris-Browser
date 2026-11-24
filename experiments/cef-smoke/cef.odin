// The parts of CEF's C API the smoke test uses, hand-written from the
// headers in the CEF 156.0.32 minimal distribution (include/capi/*,
// include/internal/cef_types*.h). Every struct is marked `/// struct _name`
// so linux/abi/check.py holds its layout against the real headers; the
// foreign functions live in cef_gen.odin (tools/bind.py, cef.txt).
package main

// CEF's string: UTF-16, heap-owned, freed with cef_string_utf16_clear.
// cef_string_t is a typedef of this; the alias keeps both C spellings.
cef_string_t :: cef_string_utf16_t

/// struct _cef_string_utf16_t
cef_string_utf16_t :: struct {
	str:    [^]u16,
	length: uint,
	dtor:   proc "c" (str: [^]u16),
}

/// struct _cef_base_ref_counted_t
cef_base_ref_counted_t :: struct {
	size:               uint,
	add_ref:            proc "c" (self: ^cef_base_ref_counted_t),
	release:            proc "c" (self: ^cef_base_ref_counted_t) -> i32,
	has_one_ref:        proc "c" (self: ^cef_base_ref_counted_t) -> i32,
	has_at_least_one_ref: proc "c" (self: ^cef_base_ref_counted_t) -> i32,
}

/// struct _cef_main_args_t
cef_main_args_t :: struct {
	argc: i32,
	argv: [^]cstring,
}

/// struct _cef_rect_t
cef_rect_t :: struct {
	x:      i32,
	y:      i32,
	width:  i32,
	height: i32,
}

// Log severity values (cef_log_severity_t, internal/cef_types.h).
LOGSEVERITY_DEFAULT :: 0
LOGSEVERITY_VERBOSE :: 1
LOGSEVERITY_INFO    :: 2
LOGSEVERITY_WARNING :: 3
LOGSEVERITY_ERROR   :: 4
LOGSEVERITY_FATAL   :: 5
LOGSEVERITY_DISABLE :: 99

// Runtime style values (cef_runtime_style_t, internal/cef_types_runtime.h).
// Alloy is the windowless style; the old Iris code used it too.
CEF_RUNTIME_STYLE_DEFAULT :: 0
CEF_RUNTIME_STYLE_CHROME  :: 1
CEF_RUNTIME_STYLE_ALLOY   :: 2

// Paint element values (cef_paint_element_type_t, internal/cef_types.h).
PET_VIEW  :: 0
PET_POPUP :: 1

/// struct _cef_settings_t
cef_settings_t :: struct {
	size:                                uint,
	no_sandbox:                           i32,
	browser_subprocess_path:              cef_string_utf16_t,
	framework_dir_path:                   cef_string_utf16_t,
	main_bundle_path:                     cef_string_utf16_t,
	multi_threaded_message_loop:          i32,
	external_message_pump:                i32,
	windowless_rendering_enabled:         i32,
	command_line_args_disabled:           i32,
	cache_path:                           cef_string_utf16_t,
	root_cache_path:                      cef_string_utf16_t,
	persist_session_cookies:              i32,
	user_agent:                           cef_string_utf16_t,
	user_agent_product:                   cef_string_utf16_t,
	locale:                                cef_string_utf16_t,
	log_file:                              cef_string_utf16_t,
	log_severity:                         i32,
	log_items:                            i32,
	javascript_flags:                     cef_string_utf16_t,
	resources_dir_path:                   cef_string_utf16_t,
	locales_dir_path:                     cef_string_utf16_t,
	remote_debugging_port:                i32,
	uncaught_exception_stack_size:        i32,
	background_color:                     u32,
	accept_language_list:                 cef_string_utf16_t,
	cookieable_schemes_list:              cef_string_utf16_t,
	cookieable_schemes_exclude_defaults:  i32,
	chrome_policy_id:                     cef_string_utf16_t,
	chrome_app_icon_id:                   i32,
	disable_signal_handlers:              i32,
	use_views_default_popup:              i32,
	keychain_service_name:                cef_string_utf16_t,
	keychain_account_name:                cef_string_utf16_t,
}

/// struct _cef_browser_settings_t
cef_browser_settings_t :: struct {
	size:                          uint,
	windowless_frame_rate:         i32,
	standard_font_family:          cef_string_utf16_t,
	fixed_font_family:             cef_string_utf16_t,
	serif_font_family:             cef_string_utf16_t,
	sans_serif_font_family:        cef_string_utf16_t,
	cursive_font_family:           cef_string_utf16_t,
	fantasy_font_family:           cef_string_utf16_t,
	default_font_size:             i32,
	default_fixed_font_size:       i32,
	minimum_font_size:             i32,
	minimum_logical_font_size:     i32,
	default_encoding:              cef_string_utf16_t,
	remote_fonts:                  i32,
	javascript:                    i32,
	javascript_close_windows:      i32,
	javascript_access_clipboard:   i32,
	javascript_dom_paste:          i32,
	image_loading:                 i32,
	image_shrink_standalone_to_fit: i32,
	text_area_resize:              i32,
	tab_to_links:                  i32,
	local_storage:                 i32,
	databases_deprecated:          i32,
	webgl:                         i32,
	background_color:              u32,
	chrome_status_bubble:          i32,
	chrome_zoom_bubble:            i32,
}

/// struct _cef_window_info_t
cef_window_info_t :: struct {
	size:                         uint,
	window_name:                  cef_string_utf16_t,
	bounds:                       cef_rect_t,
	parent_window:                rawptr,
	windowless_rendering_enabled: i32,
	shared_texture_enabled:       i32,
	external_begin_frame_enabled: i32,
	window:                       rawptr,
	runtime_style:                i32,
}

/// struct _cef_client_t
cef_client_t :: struct {
	base:                      cef_base_ref_counted_t,
	get_audio_handler:         proc "c" (self: ^cef_client_t) -> rawptr,
	get_command_handler:       proc "c" (self: ^cef_client_t) -> rawptr,
	get_context_menu_handler:  proc "c" (self: ^cef_client_t) -> rawptr,
	get_dialog_handler:        proc "c" (self: ^cef_client_t) -> rawptr,
	get_display_handler:       proc "c" (self: ^cef_client_t) -> rawptr,
	get_download_handler:      proc "c" (self: ^cef_client_t) -> rawptr,
	get_drag_handler:          proc "c" (self: ^cef_client_t) -> rawptr,
	get_find_handler:          proc "c" (self: ^cef_client_t) -> rawptr,
	get_focus_handler:         proc "c" (self: ^cef_client_t) -> rawptr,
	get_frame_handler:         proc "c" (self: ^cef_client_t) -> rawptr,
	get_permission_handler:    proc "c" (self: ^cef_client_t) -> rawptr,
	get_jsdialog_handler:      proc "c" (self: ^cef_client_t) -> rawptr,
	get_keyboard_handler:      proc "c" (self: ^cef_client_t) -> rawptr,
	get_life_span_handler:     proc "c" (self: ^cef_client_t) -> ^cef_life_span_handler_t,
	get_load_handler:          proc "c" (self: ^cef_client_t) -> ^cef_load_handler_t,
	get_print_handler:         proc "c" (self: ^cef_client_t) -> rawptr,
	get_render_handler:        proc "c" (self: ^cef_client_t) -> ^cef_render_handler_t,
	get_request_handler:       proc "c" (self: ^cef_client_t) -> rawptr,
	on_process_message_received: proc "c" (self: ^cef_client_t, browser: rawptr, frame: rawptr, source_process: i32, message: rawptr) -> i32,
}

/// struct _cef_render_handler_t
cef_render_handler_t :: struct {
	base:                            cef_base_ref_counted_t,
	get_accessibility_handler:       proc "c" (self: ^cef_render_handler_t) -> rawptr,
	get_root_screen_rect:            proc "c" (self: ^cef_render_handler_t, browser: rawptr, rect: ^cef_rect_t) -> i32,
	get_view_rect:                   proc "c" (self: ^cef_render_handler_t, browser: rawptr, rect: ^cef_rect_t),
	get_screen_point:                proc "c" (self: ^cef_render_handler_t, browser: rawptr, viewX, viewY: i32, screenX, screenY: ^i32) -> i32,
	get_screen_info:                 proc "c" (self: ^cef_render_handler_t, browser: rawptr, screen_info: rawptr) -> i32,
	on_popup_show:                   proc "c" (self: ^cef_render_handler_t, browser: rawptr, show: i32),
	on_popup_size:                   proc "c" (self: ^cef_render_handler_t, browser: rawptr, rect: ^cef_rect_t),
	on_paint:                        proc "c" (self: ^cef_render_handler_t, browser: rawptr, type: i32, dirtyRectsCount: uint, dirtyRects: ^cef_rect_t, buffer: rawptr, width, height: i32),
	on_accelerated_paint:            proc "c" (self: ^cef_render_handler_t, browser: rawptr, type: i32, dirtyRectsCount: uint, dirtyRects: ^cef_rect_t, info: rawptr),
	get_touch_handle_size:            proc "c" (self: ^cef_render_handler_t, browser: rawptr, orientation: i32, size: rawptr),
	on_touch_handle_state_changed:   proc "c" (self: ^cef_render_handler_t, browser: rawptr, state: rawptr),
	start_dragging:                  proc "c" (self: ^cef_render_handler_t, browser: rawptr, drag_data: rawptr, allowed_ops: u32, x, y: i32) -> i32,
	update_drag_cursor:              proc "c" (self: ^cef_render_handler_t, browser: rawptr, operation: u32),
	on_scroll_offset_changed:        proc "c" (self: ^cef_render_handler_t, browser: rawptr, x, y: f64),
	on_ime_composition_range_changed: proc "c" (self: ^cef_render_handler_t, browser: rawptr, selected_range: rawptr, character_boundsCount: uint, character_bounds: ^cef_rect_t),
	on_text_selection_changed:       proc "c" (self: ^cef_render_handler_t, browser: rawptr, selected_text: ^cef_string_t, selected_range: rawptr),
	on_virtual_keyboard_requested:   proc "c" (self: ^cef_render_handler_t, browser: rawptr, input_mode: i32),
}

/// struct _cef_life_span_handler_t
cef_life_span_handler_t :: struct {
	base:                     cef_base_ref_counted_t,
	on_before_popup:          proc "c" (self: ^cef_life_span_handler_t, browser: rawptr, frame: rawptr, popup_id: i32, target_url: ^cef_string_t, target_frame_name: ^cef_string_t, target_disposition: i32, user_gesture: i32, popupFeatures: rawptr, windowInfo: ^cef_window_info_t, client: ^^cef_client_t, settings: ^cef_browser_settings_t, extra_info: rawptr, no_javascript_access: ^i32) -> i32,
	on_before_popup_aborted:  proc "c" (self: ^cef_life_span_handler_t, browser: rawptr, popup_id: i32),
	on_before_dev_tools_popup: proc "c" (self: ^cef_life_span_handler_t, browser: rawptr, windowInfo: ^cef_window_info_t, client: ^^cef_client_t, settings: ^cef_browser_settings_t, extra_info: rawptr, use_default_window: ^i32),
	on_after_created:         proc "c" (self: ^cef_life_span_handler_t, browser: rawptr),
	do_close:                 proc "c" (self: ^cef_life_span_handler_t, browser: rawptr) -> i32,
	on_before_close:          proc "c" (self: ^cef_life_span_handler_t, browser: rawptr),
}

/// struct _cef_load_handler_t
cef_load_handler_t :: struct {
	base:                   cef_base_ref_counted_t,
	on_loading_state_change: proc "c" (self: ^cef_load_handler_t, browser: rawptr, isLoading, canGoBack, canGoForward: i32),
	on_load_start:          proc "c" (self: ^cef_load_handler_t, browser: rawptr, frame: rawptr, transition_type: i32),
	on_load_end:            proc "c" (self: ^cef_load_handler_t, browser: rawptr, frame: rawptr, httpStatusCode: i32),
	on_load_error:          proc "c" (self: ^cef_load_handler_t, browser: rawptr, frame: rawptr, errorCode: i32, errorText: ^cef_string_t, failedUrl: ^cef_string_t),
}

// The browser object (cef_browser_capi.h). Only get_host and get_identifier
// are called by the smoke test; the rest are rawptr so the layout stays
// exact for the ABI check without spelling out 19 signatures.
/// struct _cef_browser_t
cef_browser_t :: struct {
	base:                    cef_base_ref_counted_t,
	is_valid:                rawptr,
	get_host:                proc "c" (self: ^cef_browser_t) -> ^cef_browser_host_t,
	can_go_back:             rawptr,
	go_back:                 rawptr,
	can_go_forward:          rawptr,
	go_forward:              rawptr,
	is_loading:              rawptr,
	reload:                  rawptr,
	reload_ignore_cache:     rawptr,
	stop_load:               rawptr,
	get_identifier:          proc "c" (self: ^cef_browser_t) -> i32,
	is_same:                 rawptr,
	is_popup:                rawptr,
	has_document:            rawptr,
	get_main_frame:          rawptr,
	get_focused_frame:       rawptr,
	get_frame_by_identifier: rawptr,
	get_frame_by_name:       rawptr,
	get_frame_count:         rawptr,
	get_frame_identifiers:   rawptr,
	get_frame_names:         rawptr,
}

// The browser host (cef_browser_capi.h). Only close_browser is called;
// the rest are rawptr so the layout stays exact for the ABI check.
/// struct _cef_browser_host_t
cef_browser_host_t :: struct {
	base:                          cef_base_ref_counted_t,
	get_browser:                   rawptr,
	close_browser:                 proc "c" (self: ^cef_browser_host_t, force_close: i32),
	try_close_browser:             rawptr,
	is_ready_to_be_closed:         rawptr,
	set_focus:                     rawptr,
	get_window_handle:             rawptr,
	get_opener_window_handle:      rawptr,
	get_opener_identifier:         rawptr,
	has_view:                      rawptr,
	get_client:                    rawptr,
	get_request_context:           rawptr,
	can_zoom:                      rawptr,
	zoom:                          rawptr,
	get_default_zoom_level:        rawptr,
	get_zoom_level:                rawptr,
	set_zoom_level:                rawptr,
	run_file_dialog:               rawptr,
	start_download:                rawptr,
	download_image:                rawptr,
	print:                         rawptr,
	print_to_pdf:                  rawptr,
	find:                           rawptr,
	stop_finding:                  rawptr,
	show_dev_tools:                rawptr,
	close_dev_tools:               rawptr,
	has_dev_tools:                 rawptr,
	send_dev_tools_message:        rawptr,
	execute_dev_tools_method:      rawptr,
	add_dev_tools_message_observer: rawptr,
	get_navigation_entries:        rawptr,
	replace_misspelling:           rawptr,
	add_word_to_dictionary:        rawptr,
	is_window_rendering_disabled:  rawptr,
	was_resized:                   rawptr,
	was_hidden:                    rawptr,
	notify_screen_info_changed:    rawptr,
	invalidate:                    rawptr,
	send_external_begin_frame:     rawptr,
	send_key_event:                rawptr,
	send_mouse_click_event:        rawptr,
	send_mouse_move_event:         rawptr,
	send_mouse_wheel_event:        rawptr,
	send_touch_event:              rawptr,
	send_capture_lost_event:       rawptr,
	notify_move_or_resize_started: rawptr,
	get_windowless_frame_rate:     rawptr,
	set_windowless_frame_rate:     rawptr,
	ime_set_composition:           rawptr,
	ime_commit_text:               rawptr,
	ime_finish_composing_text:     rawptr,
	ime_cancel_composition:        rawptr,
	drag_target_drag_enter:        rawptr,
	drag_target_drag_over:         rawptr,
	drag_target_drag_leave:        rawptr,
	drag_target_drop:              rawptr,
	drag_source_ended_at:          rawptr,
	drag_source_system_drag_ended: rawptr,
	get_visible_navigation_entry:  rawptr,
	set_accessibility_state:       rawptr,
	set_auto_resize_enabled:       rawptr,
	set_audio_muted:               rawptr,
	is_audio_muted:               rawptr,
	is_fullscreen:                rawptr,
	exit_fullscreen:               rawptr,
	can_execute_chrome_command:    rawptr,
	execute_chrome_command:        rawptr,
	is_render_process_unresponsive: rawptr,
	get_runtime_style:             rawptr,
	set_ax_viewport_collapse:      rawptr,
}

// Request context settings (internal/cef_types.h). An empty cache_path
// means in-memory storage: each context created from these settings is
// its own storage partition, which is what forces a separate renderer
// process per browser using it.
/// struct _cef_request_context_settings_t
cef_request_context_settings_t :: struct {
	size:                              uint,
	cache_path:                         cef_string_utf16_t,
	persist_session_cookies:            i32,
	accept_language_list:               cef_string_utf16_t,
	cookieable_schemes_list:            cef_string_utf16_t,
	cookieable_schemes_exclude_defaults: i32,
}
