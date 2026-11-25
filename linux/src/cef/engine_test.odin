// Pure tests for the CEF engine: the zoom conversion and the header
// constants the engine relies on. Nothing here touches CEF itself, so
// these run without a display or a CEF tree; the link against libcef is
// only because the package's foreign block pulls it in.
package cef

import "core:math"
import "core:strings"
import "core:testing"

@(test)
zoom_factor_level_round_trip :: proc(t: ^testing.T) {
	factors := []f64{0.25, 0.5, 0.67, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 3.0}
	for factor in factors {
		level := zoom_level_from_factor(factor)
		back := zoom_factor_from_level(level)
		testing.expectf(t, math.abs(back-factor) < 1e-9, "zoom %v -> level %v -> %v", factor, level, back)
	}
}

@(test)
zoom_level_of_one_is_zero :: proc(t: ^testing.T) {
	testing.expect(t, zoom_level_from_factor(1.0) == 0.0)
	testing.expect(t, zoom_factor_from_level(0.0) == 1.0)
}

@(test)
zoom_levels_step_by_1_2 :: proc(t: ^testing.T) {
	// Chromium's zoom levels step by a factor of 1.2 per level.
	testing.expectf(t, math.abs(zoom_factor_from_level(1.0)-1.2) < 1e-12, "level 1 is 1.2, got %v", zoom_factor_from_level(1.0))
	testing.expectf(t, math.abs(zoom_factor_from_level(-1.0)-1.0/1.2) < 1e-12, "level -1 is 1/1.2, got %v", zoom_factor_from_level(-1.0))
}

@(test)
eval_wrapper_carries_code_and_id :: proc(t: ^testing.T) {
	w := eval_wrapper(`document.title`, 7)
	testing.expect(t, strings.has_prefix(w, "(function(){var __r;try{__r=(document.title)"))
	testing.expect(t, strings.contains(w, `console.log("[iris-eval:7]"+__s)`))
	testing.expect(t, strings.has_suffix(w, ")})();"))
	// a different id prints a different prefix
	testing.expect(t, strings.contains(eval_wrapper(`1+1`, 41), "[iris-eval:41]"))
}

@(test)
header_constants :: proc(t: ^testing.T) {
	// The values the engine passes to CEF, pinned to the headers
	// (internal/cef_types.h). If a CEF upgrade changes one, this fails
	// before the engine silently sends the wrong flag.
	testing.expect(t, MBT_LEFT == 0)
	testing.expect(t, MBT_MIDDLE == 1)
	testing.expect(t, MBT_RIGHT == 2)
	testing.expect(t, KEYEVENT_RAWKEYDOWN == 0)
	testing.expect(t, KEYEVENT_KEYDOWN == 1)
	testing.expect(t, KEYEVENT_KEYUP == 2)
	testing.expect(t, KEYEVENT_CHAR == 3)
	testing.expect(t, EVENTFLAG_SHIFT_DOWN == 2)
	testing.expect(t, EVENTFLAG_CONTROL_DOWN == 4)
	testing.expect(t, EVENTFLAG_ALT_DOWN == 8)
	testing.expect(t, EVENTFLAG_LEFT_MOUSE_BUTTON == 16)
	testing.expect(t, EVENTFLAG_IS_REPEAT == 8192)
	testing.expect(t, CURSOR_POINTER == 0)
	testing.expect(t, CURSOR_HAND == 2)
	testing.expect(t, CURSOR_IBEAM == 3)
	testing.expect(t, PET_VIEW == 0)
	testing.expect(t, PET_POPUP == 1)
	testing.expect(t, CEF_RUNTIME_STYLE_ALLOY == 2)
}
