// author: dario
package game

import "core:fmt"
import rl "vendor:raylib"

// Flying controls on the navigation screen (docs/drift-design.pdf "Scherm 2", zones 7, 8, 9, 11, 12): the button
// column, the speed circle, Re-centre, self-fly and Exit in the sheet. The ship itself only reads Controls.
NAV_BUTTON :: 64
NAV_BUTTON_GAP :: 14
SPEED_CIRCLE :: 74
SELF_FLY_BUTTON :: 66
// Labels beside the round buttons and the Manual / Autopilot pill over self-fly, so an icon is never the only
// hint. Our values.
BUTTON_LABEL_PX :: 13
BUTTON_LABEL_GAP :: 8


// Leaves navigation: back to the plan screen with the routes fitted beside the panel.
// Steering yourself works like cruise control (Lars, 2026-11-21: "het sturen gaat niet goed": letting go of W,
// or only turning, stopped the car). W / S move the held throttle up / down by CRUISE_RATE per second, letting
// go keeps it. Taking over from the autopilot starts at the speed the ship has. Our values.
CRUISE_RATE :: 0.35

cruise_throttle :: proc(w: ^World, input, dt: f32) -> f32 {
	s := &w.ship
	// The road and the air have their own top speed: on landing or take-off the held throttle is taken from the
	// speed again, so the car does not jump to the other top speed.
	if w.cruise < 0 || s.on_road != w.cruise_on_road {
		top: f32 = s.on_road ? ROAD_MAX_SPEED : w.tune.max_speed
		w.cruise = clamp(s.speed / top, 0, 1)
		w.cruise_on_road = s.on_road
	}
	w.cruise = clamp(w.cruise + input * w.tune.cruise_rate * dt, 0, 1)
	return w.cruise
}

pilot_exit :: proc(w: ^World) {
	w.cruise = -1
	nav_stop(w)
	w.screen = .Plan
	w.cam.dragged = false
	w.plan.planned = false // plan again from the current weather
}

pilot_ui :: proc(w: ^World) {
	prof_zone(w, .Pilot_Ui)
	pal := palette(w)
	n := &w.nav
	s := &w.ship
	sw, sh := f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())
	sheet := nav_sheet_rect(w)

	// Button column, right middle: music, wind, report gust.
	{
		count :: 3
		x := sw - 16 - NAV_BUTTON
		y := (sh - count * NAV_BUTTON - (count - 1) * NAV_BUTTON_GAP) / 2 - 40
		r := rl.Rectangle{x, y, NAV_BUTTON, NAV_BUTTON}
		music_button(w, r)
		button_label(w, "Music", r.x - BUTTON_LABEL_GAP, r.y + r.height / 2, pal.pill, rl.WHITE)
		r.y += NAV_BUTTON + NAV_BUTTON_GAP
		if ui_round_button(w, r, .Wind, w.nav_wind) do w.nav_wind = !w.nav_wind
		button_label(w, "Wind", r.x - BUTTON_LABEL_GAP, r.y + r.height / 2, pal.pill, rl.WHITE)
		r.y += NAV_BUTTON + NAV_BUTTON_GAP
		button_label(w, "Report gust", r.x - BUTTON_LABEL_GAP, r.y + r.height / 2, pal.pill, rl.WHITE)
		// Report gust: reroutes around a gust here, same icon as the reroute banner.
		id, hot, fired := ui_widget(w, r)
		c := [2]f32{r.x + r.width / 2, r.y + r.height / 2}
		ui_shadow(w, r, r.width / 2)
		rl.DrawCircleV(c, r.width / 2, hot ? pal.surface_2 : pal.surface)
		ui_icon(w, .Reroute, c, 30, pal.warning)
		ui_focus_ring(w, id, r, r.width / 2)
		ui_block(w, r)
		if fired {
			if gust_report(w) {
				ui_toast(w, "Gust reported, rerouting around it")
			} else {
				ui_toast(w, "No route to report a gust on")
			}
		}
	}

	// Speed circle 16 px from the left, the battery circle under it, 84 px above the sheet.
	{
		sv := fmt.tprintf("%.0f", s.speed * 3.6)
		svs := ui_text_size(w, sv, .Figtree_700, 25)
		sus := ui_text_size(w, "km/h", .Figtree_700, 11)
		spd_h := svs.y + sus.y + 2
		bat := ui_battery_badge(w, SPEED_CIRCLE)
		dia := max(bat.dia, spd_h + 18, max(svs.x, sus.x) + 18)
		r := dia / 2

		sc := [2]f32{16 + r, sheet.y - 84 - dia - 12 - r}
		ui_shadow(w, {sc.x - r, sc.y - r, dia, dia}, r)
		rl.DrawCircleV(sc, r, pal.surface)
		stop := sc.y - spd_h / 2
		ui_text(w, {sc.x - svs.x / 2, stop}, sv, .Figtree_700, 25, pal.text)
		ui_text(w, {sc.x - sus.x / 2, stop + svs.y + 2}, "km/h", .Figtree_700, 11, pal.text_2)

		ui_battery_circle(w, {16 + r, sheet.y - 84 - r}, dia, bat)
	}

	// Re-centre after the user moved the map.
	if w.cam.dragged {
		lbl := "Re-centre"
		ls := ui_text_size(w, lbl, .Figtree_500, 18)
		rw := max(170, 52 + ls.x + 20)
		rh := max(56, ls.y + 20)
		r := rl.Rectangle{16, sheet.y - 16 - rh, rw, rh}
		id, hot, fired := ui_widget(w, r)
		dark := rl.Color{32, 33, 36, 255}
		round_rect(w, r, rh / 2, hot ? rl.ColorBrightness(dark, 0.15) : dark)
		ui_icon(w, .Navigate, {r.x + 30, r.y + rh / 2}, 24, {138, 180, 248, 255})
		ui_text(w, {r.x + 52, r.y + (rh - ls.y) / 2}, lbl, .Figtree_500, 18, rl.WHITE)
		ui_focus_ring(w, id, r, rh / 2)
		ui_block(w, r)
		if fired do cam_recentre(w)
	}

	// Self-fly and Exit (Done on arrival) in the sheet, right.
	{
		passenger := carpool_is_passenger(w)
		exit_text := passenger ? "Plan" : n.banner == .Arrived && n.active ? "Done" : "Exit"
		ew := ui_text_size(w, exit_text, .Figtree_500, 21).x + 60
		exit := rl.Rectangle{sheet.x + sheet.width - 24 - ew, sheet.y + 26, ew, 66}
		if ui_pill_button(w, exit, exit_text, .Danger) do pilot_exit(w)
		if !passenger && n.active {
			fly := rl.Rectangle{exit.x - 14 - SELF_FLY_BUTTON, exit.y, SELF_FLY_BUTTON, SELF_FLY_BUTTON}
			id, hot, fired := ui_widget(w, fly)
			c := [2]f32{fly.x + fly.width / 2, fly.y + fly.height / 2}
			on := n.manual
			bg := on ? pal.accent : pal.surface_2
			rl.DrawCircleV(c, SELF_FLY_BUTTON / 2, hot && !on ? rl.ColorBrightness(bg, 0.1) : bg)
			ui_icon(w, .Steer, c, 32, on ? pal.sheet : pal.accent)
			ui_focus_ring(w, id, fly, SELF_FLY_BUTTON / 2)
			if fired do nav_set_manual(w, !n.manual)
			// The flying state over the button, above the sheet: Manual in accent, Autopilot in the dark pill.
			state := on ? "Manual" : "Autopilot"
			size := ui_text_size(w, state, .Figtree_600, BUTTON_LABEL_PX)
			pill_bg, pill_fg := on ? pal.accent : pal.pill, on ? pal.sheet : rl.WHITE
			button_label(
				w,
				state,
				c.x + (size.x + 20) / 2,
				sheet.y - 12 - (size.y + 10) / 2,
				pill_bg,
				pill_fg,
			)
		}
	}

}

// A pill of BUTTON_LABEL_PX text whose right edge is at right_x, centred on centre_y. Only drawn, the
// button beside it takes the input.
button_label :: proc(w: ^World, text: string, right_x, centre_y: f32, bg, fg: rl.Color) {
	size := ui_text_size(w, text, .Figtree_600, BUTTON_LABEL_PX)
	box := rl.Rectangle{right_x - size.x - 20, centre_y - (size.y + 10) / 2, size.x + 20, size.y + 10}
	round_rect(w, box, box.height / 2, bg)
	ui_text(w, {box.x + 10, box.y + 5}, text, .Figtree_600, BUTTON_LABEL_PX, fg)
}
