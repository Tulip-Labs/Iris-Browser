// Prints every Wayland interface table, for abi/check.sh to compare with
// wayland-scanner's C (the same text from both, or the check fails).
package wl_dump

import "core:fmt"
import wl "../wl"

dump :: proc(i: ^wl.Interface) {
	fmt.printf("%s v%d %d %d\n", i.name, i.version, i.method_count, i.event_count)
	msgs := [2][^]wl.Message{i.methods, i.events}
	counts := [2]i32{i.method_count, i.event_count}
	for k in 0 ..< 2 {
		for j in 0 ..< counts[k] {
			m := msgs[k][j]
			fmt.printf("  %s %s", m.name, m.signature)
			n := 0
			for c in string(m.signature) do if c != '?' && (c < '0' || c > '9') do n += 1
			for a in 0 ..< n {
				t := m.types == nil ? nil : m.types[a]
				fmt.printf(" %s", t == nil ? "-" : string(t.name))
			}
			fmt.printf("\n")
		}
	}
}

main :: proc() {
	all := [?]^wl.Interface{
		&wl.wl_display_interface,
		&wl.wl_registry_interface,
		&wl.wl_callback_interface,
		&wl.wl_compositor_interface,
		&wl.wl_shm_pool_interface,
		&wl.wl_shm_interface,
		&wl.wl_buffer_interface,
		&wl.wl_data_offer_interface,
		&wl.wl_data_source_interface,
		&wl.wl_data_device_interface,
		&wl.wl_data_device_manager_interface,
		&wl.wl_shell_interface,
		&wl.wl_shell_surface_interface,
		&wl.wl_surface_interface,
		&wl.wl_seat_interface,
		&wl.wl_pointer_interface,
		&wl.wl_keyboard_interface,
		&wl.wl_touch_interface,
		&wl.wl_output_interface,
		&wl.wl_region_interface,
		&wl.wl_subcompositor_interface,
		&wl.wl_subsurface_interface,
		&wl.wl_fixes_interface,
		&wl.xdg_wm_base_interface,
		&wl.xdg_positioner_interface,
		&wl.xdg_surface_interface,
		&wl.xdg_toplevel_interface,
		&wl.xdg_popup_interface,
		&wl.wp_viewporter_interface,
		&wl.wp_viewport_interface,
		&wl.zwp_tablet_manager_v2_interface,
		&wl.zwp_tablet_seat_v2_interface,
		&wl.zwp_tablet_tool_v2_interface,
		&wl.zwp_tablet_v2_interface,
		&wl.zwp_tablet_pad_ring_v2_interface,
		&wl.zwp_tablet_pad_strip_v2_interface,
		&wl.zwp_tablet_pad_group_v2_interface,
		&wl.zwp_tablet_pad_v2_interface,
		&wl.zwp_tablet_pad_dial_v2_interface,
		&wl.wp_fractional_scale_manager_v1_interface,
		&wl.wp_fractional_scale_v1_interface,
		&wl.wp_cursor_shape_manager_v1_interface,
		&wl.wp_cursor_shape_device_v1_interface,
		&wl.zxdg_decoration_manager_v1_interface,
		&wl.zxdg_toplevel_decoration_v1_interface,
		&wl.ext_background_effect_manager_v1_interface,
		&wl.ext_background_effect_surface_v1_interface,
		&wl.zwp_text_input_v3_interface,
		&wl.zwp_text_input_manager_v3_interface,
	}
	for i in all do dump(i)
}
