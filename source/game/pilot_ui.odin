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
		ui_tip(w, r, "Toggle wind flow particles")
		if ui_round_button(w, r, .Wind, w.nav_wind) do w.nav_wind = !w.nav_wind
		button_label(w, "Wind", r.x - BUTTON_LABEL_GAP, r.y + r.height / 2, pal.pill, rl.WHITE)
		r.y += NAV_BUTTON + NAV_BUTTON_GAP
		button_label(w, "Report gust", r.x - BUTTON_LABEL_GAP, r.y + r.height / 2, pal.pill, rl.WHITE)
		// Report gust: reroutes around a gust here, same icon as the reroute banner.
		id, hot, fired := ui_widget(w, r)
		if hot do ui_tip_set(w, r, "Report turbulence ahead and reroute around it")
		c := [2]f32{r.x + r.width / 2, r.y + r.height / 2}
		ui_shadow(w, r, r.width / 2)
		rl.DrawCircleV(c, r.width / 2, hot ? pal.surface_2 : pal.surface)
		ui_decorate_circle(w, c, r.width / 2)
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

		sc := [2]f32{16 + r, nav_sheet_default_rect(w).y - 84 - dia - 12 - r}
		ui_shadow(w, {sc.x - r, sc.y - r, dia, dia}, r)
		rl.DrawCircleV(sc, r, pal.surface)
		ui_decorate_circle(w, sc, r)
		stop := sc.y - spd_h / 2
		ui_text(w, {sc.x - svs.x / 2, stop}, sv, .Figtree_700, 25, pal.text)
		ui_text(w, {sc.x - sus.x / 2, stop + svs.y + 2}, "km/h", .Figtree_700, 11, pal.text_2)

		ui_battery_circle(w, {16 + r, nav_sheet_default_rect(w).y - 84 - r}, dia, bat)
	}

	// Re-centre, self-fly and Exit (Done on arrival) in the sheet, right.
	{
		w.ui.current_win = .Nav_Sheet
		passenger := carpool_is_passenger(w)
		done := !passenger && n.banner == .Arrived && n.active
		exit_text := passenger ? "Plan" : done ? "Done" : "Exit"
		exit_icon := done ? Icon.Check : Icon.Leave
		label_sz := ui_text_size(w, exit_text, .Figtree_500, 21)
		icon_px := text_px(w, 22)
		ew := label_sz.x + icon_px + 56
		exit := rl.Rectangle{sheet.x + sheet.width - 24 - ew, sheet.y + 26, ew, SELF_FLY_BUTTON}
		{
			id, hot, fired := ui_widget(w, exit)
			if hot do ui_tip_set(w, exit, "Return to route planning")
			bg := hot ? pal.surface_3 : pal.surface_2
			fg := done ? pal.green : pal.red
			round_rect(w, exit, exit.height / 2, bg)
			round_rect_lines(w, exit, exit.height / 2, 1, pal.line)
			ui_decorate_rect(w, exit, exit.height / 2)
			icon_w := icon_px + 8
			tx := exit.x + (exit.width - label_sz.x - icon_w) / 2
			ui_icon(w, exit_icon, {tx + icon_px / 2, exit.y + exit.height / 2}, icon_px, fg)
			ui_text(
				w,
				{tx + icon_w, exit.y + (exit.height - label_sz.y) / 2},
				exit_text,
				.Figtree_500,
				21,
				fg,
			)
			ui_focus_ring(w, id, exit, exit.height / 2)
			if fired do pilot_exit(w)
		}
		left_x := exit.x
		if !passenger && n.active {
			fly := rl.Rectangle{exit.x - 14 - SELF_FLY_BUTTON, exit.y, SELF_FLY_BUTTON, SELF_FLY_BUTTON}
			left_x = fly.x
			id, hot, fired := ui_widget(w, fly)
			if hot do ui_tip_set(w, fly, "Switch between manual flight and autopilot")
			c := [2]f32{fly.x + fly.width / 2, fly.y + fly.height / 2}
			on := n.manual
			bg := on ? pal.accent : (hot ? pal.surface_3 : pal.surface_2)
			rl.DrawCircleV(c, SELF_FLY_BUTTON / 2, bg)
			ui_decorate_circle(w, c, SELF_FLY_BUTTON / 2)
			ui_icon(w, .Steer, c, 32, on ? pal.sheet : pal.accent)
			ui_focus_ring(w, id, fly, SELF_FLY_BUTTON / 2)
			if fired do nav_set_manual(w, !n.manual)
			// The flying state over the button, above the sheet: Manual in accent, Autopilot in the dark pill.
			state := on ? "Manual" : "Autopilot"
			size := ui_text_size(w, state, .Figtree_600, BUTTON_LABEL_PX)
			pill_bg, pill_fg := on ? pal.accent : pal.pill, on ? pal.sheet : rl.WHITE
			pill_y :=
				sheet.y >= 40 ? sheet.y - 12 - (size.y + 10) / 2 : sheet.y + sheet.height + 12 + (size.y + 10) / 2
			button_label(w, state, c.x + (size.x + 20) / 2, pill_y, pill_bg, pill_fg)
		}
		if w.cam.dragged {
			rec := rl.Rectangle{left_x - 14 - SELF_FLY_BUTTON, exit.y, SELF_FLY_BUTTON, SELF_FLY_BUTTON}
			ui_tip(w, rec, "Snap camera back to your car")
			id, hot, fired := ui_widget(w, rec)
			c := [2]f32{rec.x + rec.width / 2, rec.y + rec.height / 2}
			rl.DrawCircleV(c, SELF_FLY_BUTTON / 2, hot ? pal.surface_3 : pal.surface_2)
			ui_decorate_circle(w, c, SELF_FLY_BUTTON / 2)
			ui_icon(w, .Recentre, c, 30, pal.accent)
			ui_focus_ring(w, id, rec, SELF_FLY_BUTTON / 2)
			ui_block(w, rec)
			if fired do cam_recentre(w)
		}
		ui_window_end(w)
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
