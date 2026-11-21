// author: dario
package game

import "core:fmt"
import rl "vendor:raylib"

// Flying controls on the navigation screen (docs/drift-design.pdf "Scherm 2", zones 7, 8, 9, 11, 12): the button
// column, the speed circle, Re-centre, self-fly and Exit in the sheet, the sim speed chips and the 3 x 3 control
// pad with its key card. The ship itself only reads Controls; the pad presses feed them like the keyboard.
NAV_BUTTON :: 64
NAV_BUTTON_GAP :: 14
SPEED_CIRCLE :: 74
SELF_FLY_BUTTON :: 66
PAD_KEY :: 52
PAD_GAP :: 6

// The control pad: which Controls axis each of the 3 x 3 keys pushes (6 used: throttle, turn, climb, descend).
Pad_Key :: struct {
	label: string,
	icon:  Icon,
	axis:  Controls,
}

PAD_KEYS :: [9]Pad_Key {
	{"R", .Climb, {climb = 1}},
	{"W", .Arrow_Up, {throttle = 1}},
	{"", .Close, {}},
	{"A", .Arrow_Left, {turn = -1}},
	{"", .Close, {}},
	{"D", .Arrow_Right, {turn = 1}},
	{"F", .Descend, {climb = -1}},
	{"S", .Arrow_Down, {throttle = -1}},
	{"", .Close, {}},
}

// Reads the pad under the mouse, called before the fixed steps so a press steers the ship this frame.
pilot_pad_controls :: proc(w: ^World) -> Controls {
	c: Controls
	if w.screen != .Navigate || !w.nav.manual || !rl.IsMouseButtonDown(.LEFT) do return c
	m := rl.GetMousePosition()
	keys := PAD_KEYS
	for k, i in keys {
		if k.label == "" do continue
		if rl.CheckCollisionPointRec(m, pilot_pad_rect(w, i)) {
			c.throttle += k.axis.throttle
			c.turn += k.axis.turn
			c.climb += k.axis.climb
		}
	}
	return c
}

pilot_pad_rect :: proc(w: ^World, i: int) -> rl.Rectangle {
	sheet := nav_sheet_rect(w)
	right := f32(rl.GetScreenWidth()) - 16 - NAV_BUTTON - 24
	x0 := right - 3 * PAD_KEY - 2 * PAD_GAP
	y0 := sheet.y - 24 - 3 * PAD_KEY - 2 * PAD_GAP
	return {x0 + f32(i % 3) * (PAD_KEY + PAD_GAP), y0 + f32(i / 3) * (PAD_KEY + PAD_GAP), PAD_KEY, PAD_KEY}
}

// Leaves navigation: back to the plan screen with the routes fitted beside the panel.
pilot_exit :: proc(w: ^World) {
	nav_stop(w)
	w.screen = .Plan
	w.cam.dragged = false
	w.plan.planned = false // plan again from the current weather
}

pilot_ui :: proc(w: ^World) {
	pal := palette(w)
	n := &w.nav
	s := &w.ship
	sw, sh := f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())
	sheet := nav_sheet_rect(w)

	// Button column, right middle: compass, overview, wind, report gust.
	{
		count :: 4
		x := sw - 16 - NAV_BUTTON
		y := (sh - count * NAV_BUTTON - (count - 1) * NAV_BUTTON_GAP) / 2 - 40
		r := rl.Rectangle{x, y, NAV_BUTTON, NAV_BUTTON}
		if compass_button(w, r) do cam_north(w)
		r.y += NAV_BUTTON + NAV_BUTTON_GAP
		if ui_round_button(w, r, .Search, w.cam.mode == .Free && w.cam.dragged) {
			if route := nav_route(w); route != nil {
				lo, hi := path_bounds(route.path)
				cam_fit(w, lo - 2, hi + 2, {80, 160, sw - 260, sh - SHEET_H - 200})
				w.cam.dragged = true
			}
		}
		r.y += NAV_BUTTON + NAV_BUTTON_GAP
		show_wind := !w.plan.layers.hide_wind && w.nav_wind
		if ui_round_button(w, r, .Wind, show_wind) do w.nav_wind = !w.nav_wind
		r.y += NAV_BUTTON + NAV_BUTTON_GAP
		// Report gust: the yellow triangle with a plus.
		id, hot, fired := ui_widget(w, r)
		c := [2]f32{r.x + r.width / 2, r.y + r.height / 2}
		ui_shadow(w, r, r.width / 2)
		rl.DrawCircleV(c, r.width / 2, hot ? pal.surface_2 : pal.surface)
		ui_icon(w, .Report_Gust, c, 30, pal.warning)
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

	// Speed circle 16 px from the left, 84 px above the sheet.
	{
		c := [2]f32{16 + SPEED_CIRCLE / 2, sheet.y - 84 - SPEED_CIRCLE / 2}
		ui_shadow(
			w,
			{c.x - SPEED_CIRCLE / 2, c.y - SPEED_CIRCLE / 2, SPEED_CIRCLE, SPEED_CIRCLE},
			SPEED_CIRCLE / 2,
		)
		rl.DrawCircleV(c, SPEED_CIRCLE / 2, rl.WHITE)
		v := fmt.tprintf("%.0f", s.speed * 3.6)
		vs := ui_text_size(w, v, .Figtree_700, 25)
		ui_text(w, {c.x - vs.x / 2, c.y - 19}, v, .Figtree_700, 25, {32, 33, 36, 255})
		us := ui_text_size(w, "km/h", .Figtree_700, 11)
		ui_text(w, {c.x - us.x / 2, c.y + 8}, "km/h", .Figtree_700, 11, {95, 99, 104, 255})
	}

	// Re-centre after the user moved the map.
	if w.cam.dragged {
		r := rl.Rectangle{16, sheet.y - 16 - 56, 170, 56}
		id, hot, fired := ui_widget(w, r)
		dark := rl.Color{32, 33, 36, 255}
		round_rect(r, 28, hot ? rl.ColorBrightness(dark, 0.15) : dark)
		ui_icon(w, .Navigate, {r.x + 30, r.y + 28}, 24, {138, 180, 248, 255})
		ui_text(w, {r.x + 52, r.y + 17}, "Re-centre", .Figtree_500, 18, rl.WHITE)
		ui_focus_ring(w, id, r, 28)
		ui_block(w, r)
		if fired do cam_recentre(w)
	}

	// Self-fly and Exit (Done on arrival) in the sheet, right.
	{
		exit_text := n.banner == .Arrived && n.active ? "Done" : "Exit"
		ew := ui_text_size(w, exit_text, .Figtree_500, 21).x + 60
		exit := rl.Rectangle{sheet.x + sheet.width - 24 - ew, sheet.y + 26, ew, 66}
		if ui_pill_button(w, exit, exit_text, .Danger) do pilot_exit(w)
		fly := rl.Rectangle{exit.x - 14 - SELF_FLY_BUTTON, exit.y, SELF_FLY_BUTTON, SELF_FLY_BUTTON}
		id, hot, fired := ui_widget(w, fly)
		c := [2]f32{fly.x + fly.width / 2, fly.y + fly.height / 2}
		on := n.manual || !n.active
		bg := on ? pal.accent : w.theme == .Night ? rl.Color{48, 49, 52, 255} : pal.surface_2
		rl.DrawCircleV(c, SELF_FLY_BUTTON / 2, hot && !on ? rl.ColorBrightness(bg, 0.1) : bg)
		ui_icon(w, .Steer, c, 32, on ? pal.sheet : pal.accent)
		ui_focus_ring(w, id, fly, SELF_FLY_BUTTON / 2)
		if fired && n.active do nav_set_manual(w, !n.manual)
	}

	// Sim speed chips 1x 5x 15x 40x under the stat chips.
	{
		speeds := SIM_SPEEDS
		x := sheet.x + 24
		y := sheet.y + 172
		for v, i in speeds {
			label := fmt.tprintf("%.0fx", v)
			r := rl.Rectangle{x, y, 44, 22}
			id, hot, fired := ui_widget(w, r)
			chosen := w.sim_speed == i
			round_rect(r, 8, chosen ? pal.accent : hot ? pal.surface_3 : pal.chip)
			size := ui_text_size(w, label, .Mono_400, 13)
			ui_text(
				w,
				{r.x + (r.width - size.x) / 2, r.y + 3},
				label,
				.Mono_400,
				13,
				chosen ? pal.sheet : pal.text,
			)
			ui_focus_ring(w, id, r, 8)
			if fired do w.sim_speed = i
			x += 50
		}
		ui_text(w, {x + 8, y + 3}, "Sim speed", .Roboto_400, 13, pal.text_2)
	}

	// Control pad (only in self-fly) and the key card above it.
	if n.manual || !n.active {
		keys := PAD_KEYS
		pressed := w.controls
		for k, i in keys {
			if k.label == "" do continue
			r := pilot_pad_rect(w, i)
			on :=
				(k.axis.throttle != 0 && k.axis.throttle * pressed.throttle > 0) ||
				(k.axis.turn != 0 && k.axis.turn * pressed.turn > 0) ||
				(k.axis.climb != 0 && k.axis.climb * pressed.climb > 0)
			round_rect(r, 14, on ? pal.accent : rl.ColorAlpha(pal.surface, 0.82))
			ui_icon(w, k.icon, {r.x + r.width / 2, r.y + r.height / 2 - 5}, 22, on ? pal.sheet : pal.text)
			ui_text(
				w,
				{r.x + r.width / 2 - 4, r.y + r.height - 17},
				k.label,
				.Mono_400,
				11,
				on ? pal.sheet : pal.text_2,
			)
			ui_block(w, r)
		}
		first := pilot_pad_rect(w, 0)
		card := rl.Rectangle{first.x, first.y - 12 - 58, 3 * PAD_KEY + 2 * PAD_GAP, 58}
		round_rect(card, 12, rl.ColorAlpha(pal.surface, 0.9))
		ui_text(w, {card.x + 12, card.y + 9}, "W S  speed   A D  turn", .Mono_400, 12, pal.text_2)
		ui_text(w, {card.x + 12, card.y + 31}, "R F  climb   Esc  exit", .Mono_400, 12, pal.text_2)
	}
}
