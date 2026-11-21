// author: dario
package game

import "core:math"

// What the phone page feeds the game. Zero on desktop, so the native build behaves as before.
Web_Input :: struct {
	pad:          Controls,
	panel_hidden: bool,
	stick_top:    f32, // game px, the speed circle sits above the touch stick
	press_pos:    [2]f32,
	press_on_map: bool,
}

WEB_TAP_PX :: 12 // a finger that moved further than this is a drag, not a tap

Web_Action :: enum i32 {
	Street,
	Free_Flight,
	Exit,
	Toggle_Panel,
	Self_Fly,
}

Web_State_Bit :: enum u32 {
	Navigate,
	Street,
	Steering,
	Route_Active,
	Panel_Hidden,
}

web_axis :: proc(v: f32) -> f32 {
	return math.is_nan(v) ? 0 : clamp(v, -1, 1)
}

web_set_pad :: proc(w: ^World, throttle, turn, climb: f32) {
	w.web.pad = {web_axis(throttle), web_axis(turn), web_axis(climb)}
}

web_set_stick_top :: proc(w: ^World, y: f32) {
	if !math.is_nan(y) do w.web.stick_top = clamp(y, 0, 8192)
}

web_do :: proc(w: ^World, action: Web_Action) {
	switch action {
	case .Street:
		street_toggle(w)
	case .Free_Flight:
		if w.screen == .Plan {
			nav_stop(w)
			w.screen = .Navigate
			cam_chase(w)
		}
	case .Exit:
		if w.street.on do street_toggle(w)
		if w.screen == .Navigate do pilot_exit(w)
		w.web.pad = {}
		w.web.panel_hidden = false
	case .Toggle_Panel:
		w.web.panel_hidden = !w.web.panel_hidden
		w.plan.editing = .None
		w.plan.departure_open = false
	case .Self_Fly:
		if w.nav.active do nav_set_manual(w, !w.nav.manual)
	}
}

// amount in zoom levels (log2), positive = closer. x, y in game pixels.
web_zoom :: proc(w: ^World, amount, x, y: f32) {
	if math.is_nan(amount) || math.is_nan(x) || math.is_nan(y) do return
	a := clamp(amount, -1, 1)
	if w.street.on {
		st := &w.street
		if st.dist == 0 do st.dist = STREET_CAM_DIST_M
		st.dist = clamp(st.dist * math.pow(2, -a), STREET_CAM_MIN_M, STREET_CAM_MAX_M)
		return
	}
	if w.cam.mode != .Preview do cam_zoom_by(w, a, {x, y})
}

web_state :: proc(w: ^World) -> u32 {
	s: bit_set[Web_State_Bit;u32]
	if w.screen == .Navigate do s += {.Navigate}
	if w.street.on do s += {.Street}
	if w.nav.manual || !w.nav.active do s += {.Steering}
	if w.nav.active do s += {.Route_Active}
	if w.web.panel_hidden do s += {.Panel_Hidden}
	return transmute(u32)s
}
