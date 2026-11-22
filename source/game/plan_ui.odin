// author: andrei
package game

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:strings"
import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"

// Plan screen (docs/drift-design.pdf "Scherm 1: Plannen"): the 404 px panel on the left with card A (brand, from /
// to, mode chips, departure) and card B (routes, wind note, Preview / Start), the map buttons, the layers panel,
// the legend and the hub menu on the map.
PLAN_PANEL_W :: 404
PLAN_MARGIN :: 16
PLAN_CARD_GAP :: 12
SEARCH_LIST_MAX_H :: 320
HUB_MENU_W :: 230
LAYERS_PANEL_W :: 300
MAP_BUTTON :: 48
MAP_BUTTON_GAP :: 10
HUB_PICK_PX :: 16 // a click this close to a hub marker opens its menu

Layers :: struct {
	show_wind:    bool, // off by default (nasr, 2026-11-21), the other layers are on
	hide_gusts:   bool,
	hide_no_fly:  bool,
	hide_solar:   bool,
	hide_borders: bool,
	terrain:      bool, // map type tile "3D terrain": relief shading under the map
	wind_layer:   int, // index in LAYER_ALT for the wind trails and the gust layer
}

Plan_Field :: enum u8 {
	None,
	From,
	To,
}

// Zero = nothing chosen: no start, no destination, greenest, leave now, every layer on.
Plan :: struct {
	from, to:         int, // hub ids, valid when has_from / has_to
	has_from, has_to: bool,
	mode:             Route_Mode,
	hour:             int, // forecast hour of the departure, 0 = leave now
	layers:           Layers,
	// What w.routes were planned for, so a change (or a new weather snapshot) plans again.
	planned:          bool,
	planned_from:     int,
	planned_to:       int,
	planned_hour:     int,
	planned_weather:  [32]u8,
	// Panel state
	editing:          Plan_Field,
	query:            [32]u8,
	query_len:        int,
	departure_open:   bool,
	car_open:         bool, // the car skin list under the car row
	layers_open:      bool,
	hub_menu:         int, // hub id + 1 of the open menu on the map, 0 = closed
	scroll:           f32, // route list scroll in px
	carpool_h:        f32, // height of the carpool section inside the scroll box
	nudge_t:          f32, // seconds left of the red outline on an empty from / to field after Start or Preview
	// Carpool state (carpool.odin)
	matches:          [MAX_MATCHES]Match,
	match_count:      int,
	match_gen:        int,
	offer_id:         [32]u8,
	request_id:       [32]u8,
	partner_pub:      [32]u8,
	trip_accept:      [32]u8,
	partner_skin:     Car_Skin,
}

// Start or Preview without a start or a destination: the empty fields shake for PLAN_SHAKE_S and stay red as
// long as the toast that says what is missing.
PLAN_SHAKE_S :: 0.4
PLAN_SHAKE_PX :: 6
PLAN_NUDGE_S :: TOAST_S + 2 * TOAST_FADE_S

plan_side_rect :: proc(w: ^World, side: Plan_Side) -> rl.Rectangle {
	sw, sh := f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())
	x := side == .Left ? f32(PLAN_MARGIN) : max(sw - PLAN_MARGIN - PLAN_PANEL_W, PLAN_MARGIN)
	return {x, PLAN_MARGIN, PLAN_PANEL_W, sh - 2 * PLAN_MARGIN}
}

plan_panel_rect :: proc(w: ^World) -> rl.Rectangle {
	if w.ui.drag_win == .Plan {
		return {w.ui.plan_drag_x, PLAN_MARGIN, PLAN_PANEL_W, f32(rl.GetScreenHeight()) - 2 * PLAN_MARGIN}
	}
	return plan_side_rect(w, w.ui.plan_side)
}

// The open part of the screen opposite the plan panel, where cam_fit puts the routes.
plan_map_rect :: proc(w: ^World) -> rl.Rectangle {
	p := plan_panel_rect(w)
	sw, sh := f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())
	if w.ui.plan_side == .Right {
		x := f32(130)
		return {x, 60, max(p.x - 40 - x, 100), max(sh - 140, 100)}
	}
	x := p.x + p.width + 40
	return {x, 60, max(sw - x - 130, 100), max(sh - 140, 100)}
}

// Belgian local time (CET / CEST): the EU rule, summer time from the last Sunday of March 01:00 UTC to the last
// Sunday of October 01:00 UTC. Only for showing times.
belgian_time :: proc(unix: i64) -> (hour, minute: int) {
	days := unix / 86400
	// Civil date from days since 1970 (Howard Hinnant's algorithm), only the year and day of the week are used.
	z := days + 719468
	era := (z >= 0 ? z : z - 146096) / 146097
	doe := z - era * 146097
	yoe := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
	doy := doe - (365 * yoe + yoe / 4 - yoe / 100)
	mp := (5 * doy + 2) / 153
	year := yoe + era * 400 + (mp >= 10 ? 1 : 0)
	last_sunday :: proc(year: i64, month: i64) -> i64 {
		// Days since 1970 of the last day of the month, then back to a Sunday (1970-01-01 was a Thursday).
		y := month <= 2 ? year - 1 : year
		m := month <= 2 ? month + 9 : month - 3
		era := (y >= 0 ? y : y - 399) / 400
		yoe := y - era * 400
		doy := (153 * m + 2) / 5 + 31 - 1
		doe := yoe * 365 + yoe / 4 - yoe / 100 + doy
		last := era * 146097 + doe - 719468
		return last - (last + 4) %% 7
	}
	summer_start := last_sunday(year, 3) * 86400 + 3600
	summer_end := last_sunday(year, 10) * 86400 + 3600
	offset: i64 = unix >= summer_start && unix < summer_end ? 7200 : 3600
	local := unix + offset
	return int(local %% 86400 / 3600), int(local %% 3600 / 60)
}

// Departure time of a forecast hour. Before the first snapshot the clock is unknown (00:00 of the epoch).
plan_hour_label :: proc(w: ^World, hour: int, buf: []u8) -> string {
	h, m := belgian_time(w.weather.start + i64(hour) * 3600)
	if hour == 0 do return fmt.bprintf(buf, "Leave now, %02d:%02d", h, m)
	return fmt.bprintf(buf, "+%d h, %02d:%02d", hour, h, m)
}

format_duration :: proc(buf: []u8, minutes: f32) -> string {
	m := int(math.round(minutes))
	if m >= 60 do return fmt.bprintf(buf, "%d h %d min", m / 60, m % 60)
	return fmt.bprintf(buf, "%d min", m)
}

MODE_ORDER :: [3]Route_Mode{.Greenest, .Fastest, .Calmest}
MODE_LABELS :: [Route_Mode]string {
	.Fastest  = "Fastest",
	.Greenest = "Greenest",
	.Calmest  = "Calmest",
}

// Base letter of U+00C0..U+00FF (UTF-8 0xC3 0x80..0xBF): "Liege" finds the hub spelled with e grave and back.
LATIN1_BASE :: "aaaaaaaceeeeiiiidnooooo*ouuuuytsaaaaaaaceeeeiiiidnooooo/ouuuuyty"
#assert(len(LATIN1_BASE) == 64)

// Case- and accent-insensitive substring test. Other non-ASCII bytes compare as they are.
match_hub :: proc(name, query: string) -> bool {
	#assert(len(Map_Hub{}.name) == len(Plan{}.query))
	fold :: proc(s: string, buf: ^[len(Map_Hub{}.name)]u8) -> string {
		n := 0
		for i := 0; i < len(s) && n < len(buf); i += 1 {
			c := s[i]
			if c == 0xC3 && i + 1 < len(s) && s[i + 1] >= 0x80 && s[i + 1] <= 0xBF {
				i += 1
				base := LATIN1_BASE
				c = base[s[i] - 0x80]
			} else if c >= 'A' && c <= 'Z' {
				c += 32
			}
			buf[n] = c
			n += 1
		}
		return string(buf[:n])
	}
	name_buf, query_buf: [len(Map_Hub{}.name)]u8
	return strings.contains(fold(name, &name_buf), fold(query, &query_buf))
}

// One sentence about the wind on the route (design "Windnotitie"): where it comes from along the route, how
// strong at the layers it flies, and whether it is stronger higher up.
wind_note :: proc(w: ^World, mode: Route_Mode, out: []u8) -> string {
	r := &w.routes[mode]
	if !r.ok do return ""
	hour := w.plan.hour
	sum: [2]f32
	per_layer: [WIND_LAYERS][2]f32
	for p in r.path {
		sum += wind_at(w, p.x, p.y, layer_at(p.z), hour)
		for l in 0 ..< WIND_LAYERS do per_layer[l] += wind_at(w, p.x, p.y, l, hour)
	}
	n := f32(len(r.path))
	mean := sum / n
	speed := linalg.length(mean)
	if speed < 0.5 do return fmt.bprintf(out, "Calm air along the whole route.")
	// The wind blows toward mean, it comes from the opposite direction.
	names := [16]string {
		"north",
		"north-north-east",
		"north-east",
		"east-north-east",
		"east",
		"east-south-east",
		"south-east",
		"south-south-east",
		"south",
		"south-south-west",
		"south-west",
		"west-south-west",
		"west",
		"west-north-west",
		"north-west",
		"north-north-west",
	}
	from := math.mod(heading_of(-mean) + math.TAU, math.TAU)
	dir := names[int(math.round(from / (math.TAU / 16))) % 16]
	low := linalg.length(per_layer[0] / n)
	high := linalg.length(per_layer[WIND_LAYERS - 1] / n)
	layers := LAYER_ALT
	if high > low + 1.5 {
		return fmt.bprintf(
			out,
			"Wind from the %s at %.0f m/s along the route, stronger higher up (%.0f m/s at %.0f m).",
			dir,
			speed,
			high,
			layers[WIND_LAYERS - 1],
		)
	}
	if low > high + 1.5 {
		return fmt.bprintf(
			out,
			"Wind from the %s at %.0f m/s along the route, calmer higher up (%.0f m/s at %.0f m).",
			dir,
			speed,
			high,
			layers[WIND_LAYERS - 1],
		)
	}
	return fmt.bprintf(
		out,
		"Wind from the %s at %.0f m/s along the route, about the same at every layer.",
		dir,
		speed,
	)
}

// Plans again when the start, destination, hour or weather changed, then fits all routes beside the panel.
plan_refresh :: proc(w: ^World) {
	p := &w.plan
	if !p.has_from || !p.has_to {
		if p.planned do w.routes = {}
		p.planned = false
		p.match_count = 0
		return
	}
	gen := carpool_offer_gen(w)
	if p.planned &&
	   p.planned_from == p.from &&
	   p.planned_to == p.to &&
	   p.planned_hour == p.hour &&
	   p.planned_weather == w.weather_hash {
		if p.from != p.to && p.match_gen != gen {
			p.match_count = carpool_match(w, p.from, p.to, p.hour, 1, p.matches[:])
			p.match_gen = gen
		}
		return
	}
	plan_routes(w, p.from, p.to, p.hour)
	scan_build(w)
	w.scan_s = 0.001
	p.planned = true
	p.planned_from, p.planned_to, p.planned_hour, p.planned_weather = p.from, p.to, p.hour, w.weather_hash
	p.match_gen = gen
	p.match_count = p.from != p.to ? carpool_match(w, p.from, p.to, p.hour, 1, p.matches[:]) : 0
	lo, hi := [2]f32{1e9, 1e9}, [2]f32{-1e9, -1e9}
	any := false
	for &r in w.routes {
		if !r.ok do continue
		a, b := path_bounds(r.path)
		lo, hi = linalg.min(lo, a), linalg.max(hi, b)
		any = true
	}
	if !any {
		a, b := w.m.hubs[p.from].pos, w.m.hubs[p.to].pos
		lo, hi = linalg.min(a, b), linalg.max(a, b)
	}
	if !w.routes[p.mode].ok {
		for m in MODE_ORDER do if w.routes[m].ok {p.mode = m; break}
	}
	cam_fit(w, lo - 3, hi + 3, plan_map_rect(w))
}

// The whole plan screen UI, drawn after the map. Changes take effect at once (the routes are planned again on
// the next frame through plan_refresh).
plan_ui :: proc(w: ^World) {
	prof_zone(w, .Plan_Ui)
	pal := palette(w)
	p := &w.plan
	u := &w.ui
	sw := f32(rl.GetScreenWidth())
	m := rl.GetMousePosition()
	if u.pending_win == .Plan {
		if !rl.IsMouseButtonDown(.LEFT) {
			u.pending_win = .None
		} else if linalg.length(m - u.drag_start) >= WINDOW_DRAG_PX {
			u.pending_win = .None
			u.drag_win = .Plan
			u.plan_drag_x = plan_side_rect(w, u.plan_side).x
			p.editing = .None
			p.departure_open = false
			p.car_open = false
		}
	}
	if u.drag_win == .Plan {
		if rl.IsMouseButtonDown(.LEFT) {
			x := clamp(m.x - u.drag_offset.x, PLAN_MARGIN, max(sw - PLAN_MARGIN - PLAN_PANEL_W, PLAN_MARGIN))
			target := x + PLAN_PANEL_W / 2 < sw / 2 ? Plan_Side.Left : Plan_Side.Right
			snap_r := plan_side_rect(w, target)
			if abs(x - snap_r.x) <= WINDOW_SNAP_PX do x = snap_r.x
			u.plan_drag_x = x
			ui_snap_guide(w, snap_r, abs(x - snap_r.x) < 1)
		} else {
			u.plan_side = u.plan_drag_x + PLAN_PANEL_W / 2 < sw / 2 ? .Left : .Right
			u.drag_win = .None
		}
	}
	panel := plan_panel_rect(w)
	handle := rl.Rectangle{panel.x, panel.y, panel.width, 22}
	if u.drag_win == .None &&
	   rl.IsMouseButtonPressed(.LEFT) &&
	   rl.CheckCollisionPointRec(m, handle) &&
	   u.last_popup.width == 0 &&
	   !ui_point_occluded(w, m, .Plan) {
		now := rl.GetTime()
		if u.last_click_win == .Plan && now - u.last_click_t < 0.35 {
			u.plan_side = u.plan_side == .Left ? .Right : .Left
			panel = plan_panel_rect(w)
			u.last_click_win = .None
		} else {
			u.last_click_win = .Plan
			u.last_click_t = now
			u.drag_win = .Plan
			u.drag_offset = m - {panel.x, panel.y}
			u.plan_drag_x = panel.x
			p.editing = .None
			p.departure_open = false
			p.car_open = false
		}
	}
	ui_window_record(w, .Plan, panel)
	buf: [96]u8
	p.nudge_t = max(p.nudge_t - frame_time(w), 0)

	// Card A: from / to, departure, car. No brand row (Lars, 2026-11-21: the logo goes), no day / night button
	// (light only), no mode chips (nasr, 2026-11-21: the route rows in card B already pick the mode).
	a := rl.Rectangle{panel.x, panel.y, panel.width, 22 + 108 + 50 + 38 + 12}
	ui_card(w, a)
	ui_draw_grip(w, a, u.drag_win == .Plan || rl.CheckCollisionPointRec(m, handle))
	x := a.x + 16
	y := a.y + 22

	// From / To with the rail (ring, three dots, red pin) and the swap button.
	field_x := x + 30
	field_w := a.width - 32 - 30 - 48
	from_r := rl.Rectangle{field_x, y, field_w, 44}
	to_r := rl.Rectangle{field_x, y + 52, field_w, 44}
	rl.DrawRing({x + 11, from_r.y + 22}, 4, 7, 0, 360, 24, pal.text_2)
	for k in 0 ..< 3 do rl.DrawCircleV({x + 11, from_r.y + 36 + f32(k) * 7}, 1.6, pal.text_2)
	ui_icon(w, .Pin, {x + 11, to_r.y + 22}, 16 * 1.25, pal.red)
	query := string(p.query[:p.query_len])
	// The Enter that opens a field must not also pick the first match below.
	opened := false
	for field in ([2]Plan_Field{.From, .To}) {
		r := field == .From ? from_r : to_r
		has := field == .From ? p.has_from : p.has_to
		hub := field == .From ? p.from : p.to
		editing := p.editing == field
		text := editing ? query : has ? hub_name(w, hub) : ""
		nudge := !has && !editing && p.nudge_t > 0
		shake := p.nudge_t - (PLAN_NUDGE_S - PLAN_SHAKE_S)
		if nudge && shake > 0 do r.x += math.sin(shake * 60) * PLAN_SHAKE_PX * shake / PLAN_SHAKE_S
		if ui_input(w, r, text, field == .From ? "Choose start" : "Choose destination", editing, nudge) {
			p.editing = field
			opened = true
			p.query_len = 0
			p.departure_open = false
			p.car_open = false
		}
	}
	swap_r := rl.Rectangle{a.x + a.width - 16 - 40, y + 26, 40, 40}
	ui_tip(w, swap_r, "Swap start and destination")
	if ui_round_button(w, swap_r, .Swap, false) {
		p.from, p.to = p.to, p.from
		p.has_from, p.has_to = p.has_to, p.has_from
	}
	y += 96 + 12

	// Departure: clock + "Leave now, 14:00" .. "+8 h", opens a list.
	dep := rl.Rectangle{x, y, a.width - 32, 38}
	{
		id, hot, fired := ui_widget(w, dep)
		round_rect(w, dep, 8, hot ? pal.surface_3 : pal.surface_2)
		ui_icon(w, .Clock, {dep.x + 20, dep.y + 19}, 20, pal.text_2)
		label := plan_hour_label(w, p.hour, buf[:])
		ui_text(w, {dep.x + 38, dep.y + 10}, label, .Roboto_400, 14, pal.text)
		ui_icon(w, .Expand, {dep.x + dep.width - 18, dep.y + 19}, 20, pal.text_2)
		ui_focus_ring(w, id, dep, 8)
		if hot do ui_tip_set(w, dep, "Pick departure hour for wind and solar forecast")
		if fired {
			p.departure_open = !p.departure_open
			p.car_open = false
			p.editing = .None
		}
	}
	y += 38 + 12

	// Car: the chosen skin, opens the list of skins (car_models.odin).
	car := rl.Rectangle{x, y, a.width - 32, 38}
	skin_names := CAR_SKIN_NAMES
	{
		id, hot, fired := ui_widget(w, car)
		round_rect(w, car, 8, hot ? pal.surface_3 : pal.surface_2)
		ui_text(w, {car.x + 12, car.y + 10}, "Car", .Roboto_400, 14, pal.text_2)
		ui_text(w, {car.x + 52, car.y + 10}, skin_names[w.car_skin], .Roboto_400, 14, pal.text)
		ui_icon(w, .Expand, {car.x + car.width - 18, car.y + 19}, 20, pal.text_2)
		ui_focus_ring(w, id, car, 8)
		if hot do ui_tip_set(w, car, "Choose your car body")
		if fired {
			p.car_open = !p.car_open
			p.departure_open = false
			p.editing = .None
		}
	}

	// Card B: route rows, wind note, actions. Fills the rest of the panel, the list scrolls.
	b := rl.Rectangle {
		panel.x,
		a.y + a.height + PLAN_CARD_GAP,
		panel.width,
		panel.height - a.height - PLAN_CARD_GAP,
	}
	ui_card(w, b)
	// A route row: padding, the time, two lines under it, padding. Follows the text size and the line spacing.
	ROW_PAD :: 14
	row_h := ROW_PAD + text_line_px(w, 21) + text_line_px(w, 14) + text_px(w, 14) + ROW_PAD + 2
	ACTIONS_H :: 76
	note_h: f32 = 64
	routes_box := rl.Rectangle{b.x, b.y + 6, b.width, b.height - ACTIONS_H - note_h - 6}
	if !p.has_from || !p.has_to {
		ui_text(w, {b.x + 16, b.y + 20}, "Choose a start and a destination", .Figtree_600, 16, pal.text)
		ui_text(w, {b.x + 16, b.y + 44}, "or click a docking tower on the map.", .Roboto_400, 14, pal.text_2)
	} else {
		mouse := rl.GetMousePosition()
		if rl.CheckCollisionPointRec(mouse, routes_box) {
			p.scroll -= rl.GetMouseWheelMove() * 40
		}
		p.scroll = clamp(p.scroll, 0, max(3 * row_h + p.carpool_h - routes_box.height, 0))
		rl.BeginScissorMode(
			i32(routes_box.x),
			i32(routes_box.y),
			i32(routes_box.width),
			i32(routes_box.height),
		)
		labels := MODE_LABELS
		for mode, i in MODE_ORDER {
			r := &w.routes[mode]
			row := rl.Rectangle{b.x, routes_box.y + f32(i) * row_h - p.scroll, b.width, row_h}
			id, hot, fired := ui_widget(w, row)
			if !rl.CheckCollisionPointRec(mouse, routes_box) do hot = false
			if hot do rl.DrawRectangleRec(row, pal.surface_2)
			if p.mode == mode do rl.DrawRectangleRec({row.x, row.y + 8, 4, row.height - 16}, pal.accent_strong)
			if i > 0 do rl.DrawLineEx({row.x + 16, row.y}, {row.x + row.width - 16, row.y}, 1, pal.line)
			rx, ry := row.x + 16, row.y + ROW_PAD
			line2 := ry + text_line_px(w, 21)
			line3 := line2 + text_line_px(w, 14)
			if !r.ok {
				ui_text(w, {rx, ry}, labels[mode], .Figtree_600, 21, pal.text_2)
				ui_text(w, {rx, line2}, "No safe route with this wind", .Roboto_400, 14, pal.warning)
			} else {
				green := mode == .Greenest
				ui_text(
					w,
					{rx, ry},
					format_duration(buf[:], r.sum.minutes),
					.Figtree_600,
					21,
					green ? pal.green : pal.text,
				)
				dist := fmt.bprintf(buf[:], "%.0f km, %.0f km/h, ", r.sum.km, r.sum.kmh)
				ui_text(w, {rx, line2}, dist, .Roboto_400, 14, pal.text_2)
				ds := ui_text_size(w, dist, .Roboto_400, 14)
				solar := fmt.bprintf(buf[:], "+%.1f kWh solar", r.sum.solar_kwh)
				ui_text(w, {rx + ds.x, line2}, solar, .Roboto_400, 14, pal.green)
				ui_text(w, {rx, line3}, cstr(r.sum.why[:]), .Roboto_400, 14, pal.text)
				kwh := fmt.bprintf(buf[:], "%.1f kWh", r.sum.net_kwh)
				ks := ui_text_size(w, kwh, .Mono_600, 14)
				ui_text(
					w,
					{row.x + row.width - 16 - ks.x, ry + text_px(w, 2)},
					kwh,
					.Mono_600,
					14,
					green ? pal.green : pal.text,
				)
				wind := fmt.bprintf(buf[:], "%.1f m/s", r.sum.wind_ms)
				ws := ui_text_size(w, wind, .Mono_400, 13)
				ui_text(
					w,
					{row.x + row.width - 16 - ws.x, ry + text_px(w, 2) + text_line_px(w, 14)},
					wind,
					.Mono_400,
					13,
					pal.text_2,
				)
			}
			ui_focus_ring(w, id, row, 0)
			if hot && r.ok {
				tip_buf: [256]u8
				tip: string
				switch mode {
				case .Greenest:
					saved_pct := max(-r.sum.vs_straight * 100, 0)
					denom := 1 + r.sum.vs_straight
					straight_kwh := denom > 0.01 ? r.sum.net_kwh / denom : r.sum.net_kwh
					saved_kwh := max(straight_kwh - r.sum.net_kwh, 0)
					tip = fmt.bprintf(
						tip_buf[:],
						"Greenest ecological wind route\nSaves %.1f kWh (%.0f%%) vs straight line\nUsed %.1f kWh, solar +%.1f kWh, tailwind %+.1f m/s",
						saved_kwh,
						saved_pct,
						r.sum.used_kwh,
						r.sum.solar_kwh,
						r.sum.tail_ms,
					)
				case .Fastest:
					tip = fmt.bprintf(
						tip_buf[:],
						"Fastest route (%.0f km/h avg)\nUses %+.0f%% energy vs Greenest\nUsed %.1f kWh, solar +%.1f kWh, tailwind %+.1f m/s",
						r.sum.kmh,
						r.sum.vs_greenest * 100,
						r.sum.used_kwh,
						r.sum.solar_kwh,
						r.sum.tail_ms,
					)
				case .Calmest:
					tip = fmt.bprintf(
						tip_buf[:],
						"Calmest route (gust index %.2f)\nUses %+.0f%% energy vs Greenest\nUsed %.1f kWh, solar +%.1f kWh, climb %.0f m",
						r.sum.gust,
						r.sum.vs_greenest * 100,
						r.sum.used_kwh,
						r.sum.solar_kwh,
						r.sum.climb_m,
					)
				}
				ui_tip_set(w, row, tip)
			}
			if fired && r.ok do p.mode = mode
		}
		p.carpool_h = plan_carpool_ui(w, routes_box, routes_box.y + 3 * row_h - p.scroll)
		rl.EndScissorMode()

		// Wind note.
		note_y := b.y + b.height - ACTIONS_H - note_h
		rl.DrawLineEx({b.x, note_y}, {b.x + b.width, note_y}, 1, pal.line)
		ui_icon(w, .Wind, {b.x + 28, note_y + 22}, 20, pal.accent)
		note := wind_note(w, p.mode, buf[:])
		ui_text_wrapped(
			w,
			{b.x + 46, note_y + 12, b.width - 62, note_h - 16},
			note,
			.Roboto_400,
			13,
			pal.text_2,
		)
	}

	// Actions: Preview (secondary) and Start (primary, fills the rest).
	{
		ay := b.y + b.height - ACTIONS_H + 16
		rl.DrawLineEx({b.x, ay - 16}, {b.x + b.width, ay - 16}, 1, pal.line)
		ok := w.routes[p.mode].ok
		prev_r := rl.Rectangle{b.x + 16, ay, 128, 44}
		ui_tip(w, prev_r, "Fly the camera along the chosen route")
		preview := ui_pill_button(w, prev_r, "Preview", .Secondary, .Play, true)
		start_r := rl.Rectangle{b.x + 16 + 128 + 10, ay, b.width - 32 - 138, 44}
		if p.request_id != {} {
			ui_tip(w, start_r, "Waiting for a driver to accept your ride request")
			if ui_pill_button(w, start_r, "Waiting...", .Secondary, .Clock, true) {
				ui_toast(w, "Cancel ride request first to fly solo")
			}
			if preview && ok do cam_preview(w, p.mode)
		} else if carpool_is_passenger(w) {
			ui_tip(w, start_r, "Board your driver's car and follow the trip")
			if ui_pill_button(w, start_r, "Board ride", .Primary, .Navigate, true) {
				carpool_board(w)
			}
			if preview && ok do cam_preview(w, p.mode)
		} else {
			ui_tip(w, start_r, "Start flying the selected route")
			start := ui_pill_button(w, start_r, "Start", .Primary, .Navigate, true)
			if (preview || start) && !ok do plan_nudge(w)
			if preview && ok do cam_preview(w, p.mode)
			if start && ok {
				if nav_start(w, p.mode) {
					w.screen = .Navigate
					w.plan.layers_open = false
					cam_chase(w)
				}
			}
		}
	}

	// Popups last, so they are drawn over everything and take the clicks inside them.
	if p.editing != .None {
		r := p.editing == .From ? from_r : to_r
		ui_text_edit(p.query[:], &p.query_len)
		if rl.IsKeyPressed(.ESCAPE) || pad_pressed(w, .RIGHT_FACE_RIGHT) do p.editing = .None
		matches := make([dynamic]int, 0, w.m.hub_count, context.temp_allocator)
		for i in 0 ..< w.m.hub_count do if match_hub(hub_name(w, i), string(p.query[:p.query_len])) do append(&matches, i)
		ROW :: 44
		list := rl.Rectangle {
			r.x,
			r.y + r.height + 4,
			r.width,
			min(f32(len(matches)) * ROW + 8, SEARCH_LIST_MAX_H),
		}
		w.ui.popup = list
		w.ui.in_popup = true
		ui_shadow(w, list, 12)
		round_rect(w, list, 12, pal.surface)
		rl.BeginScissorMode(i32(list.x), i32(list.y), i32(list.width), i32(list.height))
		for hub, i in matches {
			row := rl.Rectangle{list.x, list.y + 4 + f32(i) * ROW, list.width, ROW}
			id, hot, fired := ui_widget(w, row)
			if hot do rl.DrawRectangleRec(row, pal.surface_2)
			ui_icon(w, .Tower, {row.x + 22, row.y + ROW / 2}, 20, pal.text_2)
			ui_text(w, {row.x + 42, row.y + 6}, hub_name(w, hub), .Roboto_400, 15, pal.text)
			ui_text(w, {row.x + 42, row.y + 25}, "Docking tower", .Roboto_400, 12, pal.text_2)
			ui_focus_ring(w, id, row, 0)
			if fired || (!opened && i == 0 && rl.IsKeyPressed(.ENTER)) {
				if p.editing == .From {
					p.from, p.has_from = hub, true
				} else {
					p.to, p.has_to = hub, true
				}
				p.editing = .None
			}
		}
		rl.EndScissorMode()
		w.ui.in_popup = false
		// A click outside the field and the list closes it.
		if rl.IsMouseButtonPressed(.LEFT) && !rl.CheckCollisionPointRec(m, list) && !rl.CheckCollisionPointRec(m, r) do p.editing = .None
	}
	if p.departure_open {
		ROW :: 36
		list := rl.Rectangle{dep.x, dep.y + dep.height + 4, dep.width, FORECAST_HOURS * ROW + 8}
		w.ui.popup = list
		w.ui.in_popup = true
		ui_shadow(w, list, 12)
		round_rect(w, list, 12, pal.surface)
		for h in 0 ..< FORECAST_HOURS {
			row := rl.Rectangle{list.x, list.y + 4 + f32(h) * ROW, list.width, ROW}
			id, hot, fired := ui_widget(w, row)
			if hot || h == p.hour do rl.DrawRectangleRec(row, pal.surface_2)
			ui_text(
				w,
				{row.x + 16, row.y + 9},
				plan_hour_label(w, h, buf[:]),
				.Roboto_400,
				14,
				h == p.hour ? pal.accent : pal.text,
			)
			ui_focus_ring(w, id, row, 0)
			if fired {
				p.hour = h
				p.departure_open = false
			}
		}
		w.ui.in_popup = false
		if rl.IsKeyPressed(.ESCAPE) || pad_pressed(w, .RIGHT_FACE_RIGHT) do p.departure_open = false
		if rl.IsMouseButtonPressed(.LEFT) && !rl.CheckCollisionPointRec(rl.GetMousePosition(), list) && !rl.CheckCollisionPointRec(rl.GetMousePosition(), dep) do p.departure_open = false
	}
	if p.car_open {
		preview := car_preview_atlas(w)
		skin_row_h := max(f32(40), f32(text_px(w, 14)) + 14)
		list_y := car.y + car.height + 4
		max_h := max(f32(rl.GetScreenHeight()) - list_y - 12, f32(len(Car_Skin)) * 28 + 8)
		if f32(len(Car_Skin)) * skin_row_h + 8 > max_h {
			skin_row_h = (max_h - 8) / f32(len(Car_Skin))
		}
		list := rl.Rectangle{car.x, list_y, car.width, f32(len(Car_Skin)) * skin_row_h + 8}
		w.ui.popup = list
		w.ui.in_popup = true
		ui_shadow(w, list, 12)
		round_rect(w, list, 12, pal.surface)
		for name, skin in skin_names {
			row := rl.Rectangle{list.x, list.y + 4 + f32(skin) * skin_row_h, list.width, skin_row_h}
			id, hot, fired := ui_widget(w, row)
			if hot || skin == w.car_skin do rl.DrawRectangleRec(row, pal.surface_2)
			sz := ui_text_size(w, name, .Roboto_400, 14)
			ui_text(
				w,
				{row.x + 16, row.y + (skin_row_h - sz.y) / 2},
				name,
				.Roboto_400,
				14,
				skin == w.car_skin ? pal.accent : pal.text,
			)
			if preview.id != 0 {
				ph := max(skin_row_h - 4, 16)
				pw := ph * f32(CAR_PREVIEW_W) / f32(CAR_PREVIEW_H)
				src := rl.Rectangle {
					0,
					f32(len(Car_Skin) - 1 - int(skin)) * CAR_PREVIEW_H,
					CAR_PREVIEW_W,
					-CAR_PREVIEW_H,
				}
				dst := rl.Rectangle{row.x + row.width - pw - 12, row.y + (skin_row_h - ph) / 2, pw, ph}
				rl.DrawTexturePro(preview, src, dst, {}, 0, rl.WHITE)
			}
			ui_focus_ring(w, id, row, 0)
			if fired {
				w.car_skin = skin
				car_skin_save(w)
				logf(w, "car", "skin %s", name)
				p.car_open = false
			}
		}
		w.ui.in_popup = false
		if rl.IsKeyPressed(.ESCAPE) || pad_pressed(w, .RIGHT_FACE_RIGHT) do p.car_open = false
		if rl.IsMouseButtonPressed(.LEFT) && !rl.CheckCollisionPointRec(m, list) && !rl.CheckCollisionPointRec(m, car) do p.car_open = false
	}
	ui_window_end(w, rl.CheckCollisionPointRec(m, a) || rl.CheckCollisionPointRec(m, b))
	plan_hub_menu(w)
}

// Start or Preview with no route to fly: says what is missing, the empty fields shake and turn red.
plan_nudge :: proc(w: ^World) {
	p := &w.plan
	switch {
	case !p.has_from && !p.has_to:
		ui_toast(w, "Choose a start and a destination first")
	case !p.has_from:
		ui_toast(w, "Choose a start first")
	case !p.has_to:
		ui_toast(w, "Choose a destination first")
	case:
		ui_toast(w, "No safe route with this wind, pick another route or time")
		return
	}
	p.nudge_t = PLAN_NUDGE_S
}

// Click on a hub marker: "Fly from here" / "Fly to here" (230 px, under the icon).
plan_hub_menu :: proc(w: ^World) {
	p := &w.plan
	pal := palette(w)
	m := rl.GetMousePosition()
	outside := w.ui.last_popup.width == 0 || !rl.CheckCollisionPointRec(m, w.ui.last_popup)
	// A click anywhere outside the open menu closes it, on the map it may open the menu of another hub.
	if rl.IsMouseButtonPressed(.LEFT) && p.hub_menu > 0 && outside do p.hub_menu = 0
	if rl.IsMouseButtonPressed(.LEFT) && !ui_mouse_captured(w) && w.ui.popup.width == 0 {
		for i in 0 ..< w.m.hub_count {
			px, visible := cam_to_screen(w, {w.m.hubs[i].pos.x, w.m.hubs[i].pos.y, 0})
			if visible && linalg.length(px - m) < HUB_PICK_PX {
				p.hub_menu = i + 1
				p.editing = .None
				break
			}
		}
	}
	if p.hub_menu == 0 do return
	hub := p.hub_menu - 1
	px, visible := cam_to_screen(w, {w.m.hubs[hub].pos.x, w.m.hubs[hub].pos.y, 0})
	if !visible {
		p.hub_menu = 0
		return
	}
	r := rl.Rectangle{px.x - HUB_MENU_W / 2, px.y + 20, HUB_MENU_W, 2 * 44 + 40}
	w.ui.popup = r
	w.ui.in_popup = true
	ui_shadow(w, r, 12)
	round_rect(w, r, 12, pal.surface)
	ui_text(w, {r.x + 16, r.y + 10}, hub_name(w, hub), .Figtree_600, 14, pal.text)
	items := [2]string{"Fly from here", "Fly to here"}
	for item, i in items {
		row := rl.Rectangle{r.x, r.y + 36 + f32(i) * 44, r.width, 44}
		id, hot, fired := ui_widget(w, row)
		if hot do rl.DrawRectangleRec(row, pal.surface_2)
		ui_icon(w, i == 0 ? .Origin : .Pin, {row.x + 24, row.y + 22}, 20, i == 0 ? pal.text_2 : pal.red)
		ui_text(w, {row.x + 46, row.y + 13}, item, .Roboto_400, 15, pal.text)
		ui_focus_ring(w, id, row, 0)
		if fired {
			if i == 0 {
				p.from, p.has_from = hub, true
			} else {
				p.to, p.has_to = hub, true
			}
			p.hub_menu = 0
		}
	}
	w.ui.in_popup = false
}

// Map buttons on the side opposite the plan panel (music, layers, compass, zoom pill) and the layers panel.
plan_map_controls :: proc(w: ^World) {
	prof_zone(w, .Map_Controls)
	pal := palette(w)
	p := &w.plan
	sw, sh := f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())
	x := w.ui.plan_side == .Left ? sw - PLAN_MARGIN - MAP_BUTTON : PLAN_MARGIN
	zoom := rl.Rectangle{x, sh - 24 - 92, MAP_BUTTON, 92}
	switch ui_zoom_pill(w, zoom) {
	case 1:
		cam_zoom_by(w, 1, w.cam.screen / 2)
	case -1:
		cam_zoom_by(w, -1, w.cam.screen / 2)
	}
	compass := rl.Rectangle{x, zoom.y - MAP_BUTTON_GAP - MAP_BUTTON, MAP_BUTTON, MAP_BUTTON}
	ui_tip(w, compass, "Reset map north up")
	if compass_button(w, compass) do cam_north(w)
	layers := rl.Rectangle{x, compass.y - MAP_BUTTON_GAP - MAP_BUTTON, MAP_BUTTON, MAP_BUTTON}
	ui_tip(w, layers, "Map type & weather overlays")
	if ui_round_button(w, layers, .Layers, p.layers_open) do p.layers_open = !p.layers_open
	music_button(w, {x, layers.y - MAP_BUTTON_GAP - MAP_BUTTON, MAP_BUTTON, MAP_BUTTON})

	if p.layers_open {
		// Profile and debug builds get one more row: the profiler overlay.
		extra: f32 = PROFILING ? 32 : 0
		def_x := w.ui.plan_side == .Left ? layers.x - 12 - LAYERS_PANEL_W : layers.x + MAP_BUTTON + 12
		def_r := rl.Rectangle{def_x, layers.y - 282 - extra, LAYERS_PANEL_W, 418 + extra}
		r := ui_window_begin(w, .Layers, def_r, 40)
		ui_card(w, r)
		handle_hot := rl.CheckCollisionPointRec(rl.GetMousePosition(), {r.x, r.y, r.width, 40})
		ui_draw_grip(w, r, w.ui.drag_win == .Layers || handle_hot)
		y := r.y + 22
		heading :: proc(w: ^World, pos: [2]f32, text: string) {
			ui_text(w, pos, text, .Figtree_600, 14, palette(w).text_2)
		}
		heading(w, {r.x + 16, y}, "MAP TYPE")
		y += 26
		tile_w := (r.width - 32 - 10) / 2
		if ui_tile(w, {r.x + 16, y, tile_w, 88}, "Map", pal.land, !p.layers.terrain) do p.layers.terrain = false
		if ui_tile(w, {r.x + 26 + tile_w, y, tile_w, 88}, "3D terrain", pal.farmland, p.layers.terrain) do p.layers.terrain = true
		y += 100
		heading(w, {r.x + 16, y}, "LAYERS")
		y += 24
		// show: the flag means shown (zero = off by default) instead of hidden (zero = on).
		toggles := [5]struct {
			label: string,
			flag:  ^bool,
			show:  bool,
		} {
			{"Wind flow", &p.layers.show_wind, true},
			{"Gust risk", &p.layers.hide_gusts, false},
			{"No-fly zones", &p.layers.hide_no_fly, false},
			{"Solar", &p.layers.hide_solar, false},
			{"Borders", &p.layers.hide_borders, false},
		}
		for t in toggles {
			ui_text(w, {r.x + 16, y + 2}, t.label, .Roboto_400, 14, pal.text)
			on := t.flag^ == t.show
			if ui_toggle(w, {r.x + r.width - 16 - 36, y, 36, 20}, &on) do t.flag^ = on == t.show
			y += 32
		}
		when PROFILING {
			ui_text(w, {r.x + 16, y + 2}, "Profiler", .Roboto_400, 14, pal.text)
			ui_toggle(w, {r.x + r.width - 16 - 36, y, 36, 20}, &w.prof.shown)
			y += 32
		}
		heading(w, {r.x + 16, y + 4}, "WIND LAYER")
		y += 28
		layer_alt := LAYER_ALT
		names: [WIND_LAYERS]string
		for a, i in layer_alt do names[i] = fmt.tprintf("%.0f m", a)
		ui_segment(w, {r.x + 16, y, r.width - 32, 36}, names[:], &p.layers.wind_layer)
		ui_window_end(w)
	}

}

// Compass button: a red and grey needle that turns with the map.
compass_button :: proc(w: ^World, r: rl.Rectangle) -> bool {
	pal := palette(w)
	id, hot, fired := ui_widget(w, r)
	c := [2]f32{r.x + r.width / 2, r.y + r.height / 2}
	ui_shadow(w, r, r.width / 2)
	rl.DrawCircleV(c, r.width / 2, hot ? pal.surface_2 : pal.surface)
	ui_decorate_circle(w, c, r.width / 2)
	yaw := -w.cam.pose.yaw
	fwd := [2]f32{math.sin(yaw), -math.cos(yaw)}
	side := [2]f32{-fwd.y, fwd.x}
	l := r.width * 0.28
	rl.DrawTriangle(c + fwd * l, c - side * l * 0.3, c + side * l * 0.3, pal.red)
	rl.DrawTriangle(c - fwd * l, c + side * l * 0.3, c - side * l * 0.3, pal.text_2)
	ui_focus_ring(w, id, r, r.width / 2)
	ui_block(w, r)
	return fired
}

// Wind trail colors by speed (design "Windsporen"): white below 6 m/s, mint to 10, yellow to 14, coral above.
wind_colors :: proc(w: ^World) -> [4]rl.Color {
	pal := palette(w)
	return {pal.wind_calm, pal.wind_mint, pal.wind_yellow, pal.wind_coral}
}

// Smooth ramp between the four colors at 0, 6, 10, 14 m/s.
wind_color_at :: proc(c: [4]rl.Color, ms: f32) -> rl.Color {
	stops := [4]f32{0, 6, 10, 14}
	if ms >= stops[3] do return c[3]
	for k in 0 ..< 3 {
		if ms < stops[k + 1] {
			t := (ms - stops[k]) / (stops[k + 1] - stops[k])
			return rl.ColorLerp(c[k], c[k + 1], t * t)
		}
	}
	return c[3]
}

// Alpha (of 255) of the solar layer's cloud shade under full cover, and of its sunlit wash (pal.sun) under a
// clear sky with the sun overhead; the cloud editor changes both (w.cloud_edit).
SOLAR_SHADE_ALPHA :: 60
SOLAR_SUN_ALPHA :: 90

// Soft gust risk (warning -> red from gust_at at the wind layer), cloud shade for the solar layer and the no-fly
// zones hatched in red, on the ground. Drawn between the map fills and the roads (design draw order 2), without
// the depth test: the ground grid and the land use triangles round the same z = 0 to slightly different depths,
// and the shade lost in horizontal strips that moved while zooming.
layers_draw_ground :: proc(w: ^World) {
	prof_zone(w, .Ground_Layers)
	rlgl.DisableDepthTest()
	defer rlgl.EnableDepthTest()
	pal := palette(w)
	l := &w.plan.layers
	hour := sim_hour(w)
	if (!l.hide_gusts || !l.hide_solar) && w.line_meshes.built {
		lm := &w.line_meshes
		key := Ground_Key {
			valid        = true,
			hour         = hour,
			wind_layer   = l.wind_layer,
			hide_gusts   = l.hide_gusts,
			hide_solar   = l.hide_solar,
			ground_sun   = w.cloud_edit.ground_sun,
			ground_shade = w.cloud_edit.ground_shade,
			warning      = pal.warning,
			red          = pal.red,
			sun          = pal.sun,
			weather      = w.weather_hash,
		}
		if key != lm.ground_key {
			lm.ground_key = key
			sun := sun_factor(w, hour)
			// Soft: evaluate each grid point once, then fill each quad so the GPU blends across corners.
			grid := make([][4]u8, GROUND_W * GROUND_H, context.temp_allocator)
			for gy in 0 ..< GROUND_H {
				y := f32(gy * GROUND_CELL_KM)
				for gx in 0 ..< GROUND_W {
					x := f32(gx * GROUND_CELL_KM)
					col := rl.Color{}
					if !l.hide_gusts {
						g := gust_at(w, x, y, l.wind_layer, hour)
						col = rl.ColorLerp(pal.warning, pal.red, clamp((g - 0.2) / 0.6, 0, 1))
						col.a = u8(clamp((g - 0.15) / 0.6, 0, 1) * 110)
					}
					// Sunlit where it is clear and the sun is up, shaded under the clouds: what solar_kw yields.
					if !l.hide_solar {
						cloud := clamp(cloud_at(w, x, y, hour), 0, 1)
						lit := (1 - cloud) * sun * clamp(w.cloud_edit.ground_sun, 0, 255)
						shade := cloud * clamp(w.cloud_edit.ground_shade, 0, 255)
						a := u8(max(lit, shade))
						if a > col.a {
							col = rl.ColorLerp(
								pal.sun,
								{0, 0, 0, 255},
								lit + shade > 0 ? shade / (lit + shade) : 1,
							)
							col.a = a
						}
					}
					col.a = u8(f32(col.a) * belgium_fade(w, x, y))
					grid[gy * GROUND_W + gx] = {col.r, col.g, col.b, col.a}
				}
			}
			colors := make([][4]u8, GROUND_VERTICES, context.temp_allocator)
			for gy in 0 ..< GROUND_H - 1 {
				for gx in 0 ..< GROUND_W - 1 {
					corners := ground_quad(gx, gy)
					base := (gy * (GROUND_W - 1) + gx) * 6
					for c, k in corners {
						colors[base + k] = grid[c.y * GROUND_W + c.x]
					}
				}
			}
			rl.UpdateMeshBuffer(lm.ground, 3, raw_data(colors), i32(len(colors) * size_of(colors[0])), 0)
		}
		rl.DrawMesh(lm.ground, lm.ground_material, rl.Matrix(1))
	}
	if !l.hide_no_fly {
		SEG :: 48
		fill := rl.ColorAlpha(pal.red, 0.12)
		hatch := rl.ColorAlpha(pal.red, 0.45)
		for z in w.no_fly {
			if z.radius <= 0 do continue
			at :: proc(z: No_Fly_Zone, k: int) -> [3]f32 {
				a := f32(k) / SEG * math.TAU
				return {z.center.x + math.cos(a) * z.radius, z.center.y + math.sin(a) * z.radius, 0}
			}
			c := [3]f32{z.center.x, z.center.y, 0}
			for k in 0 ..< SEG do rl.DrawTriangle3D(c, at(z, k + 1), at(z, k), fill)
			// Hatching: diagonal lines every radius / 4 inside the circle, then the sharp edge.
			step := z.radius / 4
			for k := -z.radius + step / 2; k < z.radius; k += step {
				half := math.sqrt(z.radius * z.radius - k * k)
				o := z.center + [2]f32{k, k} * math.SQRT_TWO / 2
				d := [2]f32{1, -1} * math.SQRT_TWO / 2 * half
				rl.DrawLine3D({o.x - d.x, o.y - d.y, 0}, {o.x + d.x, o.y + d.y, 0}, hatch)
			}
			for k in 0 ..< SEG do rl.DrawLine3D(at(z, k), at(z, k + 1), pal.red)
		}
	}
}

// The default line height of wrapped text, in text sizes (the Fonts tab changes it, w.look.line_spacing).
TEXT_LINE_SPACING :: 1.35

// Text wrapped on spaces inside r, w.look.line_spacing apart.
ui_text_wrapped :: proc(w: ^World, r: rl.Rectangle, text: string, font: Font, px: f32, color: rl.Color) {
	y := r.y
	rest := text
	for rest != "" && y + text_px(w, px) <= r.y + r.height + 1 {
		// Longest prefix that fits, cut at a space.
		cut := len(rest)
		for ui_text_size(w, rest[:cut], font, px).x > r.width {
			sp := strings.last_index_byte(rest[:cut], ' ')
			if sp <= 0 do break
			cut = sp
		}
		ui_text(w, {r.x, y}, rest[:cut], font, px, color)
		rest = strings.trim_left_space(rest[cut:])
		y += text_line_px(w, px)
	}
}

// Carpool offer, incoming requests, matching rides, active trip and rating inside Card B's scroll box.
plan_carpool_ui :: proc(w: ^World, box: rl.Rectangle, start_y: f32) -> f32 {
	p := &w.plan
	pal := palette(w)
	mouse := rl.GetMousePosition()
	in_box := rl.CheckCollisionPointRec(mouse, box)
	btn :: proc(w: ^World, r: rl.Rectangle, label: string, primary, active: bool) -> bool {
		pal := palette(w)
		id, hot, fired := ui_widget(w, r)
		if !active do hot, fired = false, false
		rad := r.height / 2
		fg := primary ? rl.WHITE : pal.accent
		if primary {
			round_rect(w, r, rad, hot ? rl.ColorBrightness(pal.accent, 0.1) : pal.accent)
		} else {
			if hot do round_rect(w, r, rad, pal.surface_2)
			round_rect_lines(w, r, rad, 1, pal.line)
		}
		sz := ui_text_size(w, label, .Roboto_500, 12)
		ui_text(w, {r.x + (r.width - sz.x) / 2, r.y + (r.height - sz.y) / 2}, label, .Roboto_500, 12, fg)
		ui_focus_ring(w, id, r, rad)
		return fired
	}
	rep_text :: proc(w: ^World, author: [32]u8, fallback: string, buf: []u8) -> string {
		stars, n := carpool_reputation(w, author)
		if n == 0 do return fallback
		return fmt.bprintf(buf, "%.1f stars (%d)", stars, n)
	}

	y := start_y + 6
	rl.DrawLineEx({box.x + 16, y}, {box.x + box.width - 16, y}, 1, pal.line)
	y += 12
	y = ui_line(w, {box.x + 16, y}, "CARPOOL", .Figtree_600, 11, pal.text_2) + 4
	buf: [64]u8
	row_h := max(40, 4 + text_line_px(w, 13) + text_px(w, 12) + 8)
	btn_h := max(28, text_px(w, 12) + 12)

	if w.trip.active {
		ui_text(w, {box.x + 16, y + 6}, "Carpool active, partner live", .Roboto_500, 13, pal.green)
		if btn(w, {box.x + box.width - 80, y, 64, 28}, "End", false, in_box) {
			trip_end(w)
			w.partner_seen = false
			p.partner_pub = {}
			p.trip_accept = {}
		}
		y += 36
		if p.partner_pub != {} && p.trip_accept != {} {
			ui_text(w, {box.x + 16, y + 6}, "Rate:", .Roboto_400, 13, pal.text_2)
			for s in 1 ..= 5 {
				sr := rl.Rectangle{box.x + 62 + f32(s - 1) * 34, y, 28, 26}
				if btn(w, sr, fmt.bprintf(buf[:], "%d", s), false, in_box) {
					if m, ok := carpool_review_make(w, p.trip_accept, p.partner_pub, s); ok {
						if carpool_post(w, &m) == .Added {
							ui_toast(w, "Carpool review posted")
						}
					}
					trip_end(w)
					w.partner_seen = false
					p.partner_pub = {}
					p.trip_accept = {}
				}
			}
			y += 34
		}
		return y - start_y + 8
	}

	if p.request_id != {} {
		ui_text(w, {box.x + 16, y + 6}, "Request sent, waiting...", .Roboto_400, 13, pal.text_2)
		if btn(w, {box.x + box.width - 84, y, 68, 28}, "Cancel", false, in_box) {
			p.request_id = {}
		}
		return (y + 36) - start_y + 8
	}

	if p.offer_id != {} {
		if _, ok := carpool_find_message(w, p.offer_id); !ok do p.offer_id = {}
	}
	if p.offer_id != {} {
		ui_text(w, {box.x + 16, y + 6}, "Your ride offer is live", .Roboto_500, 13, pal.accent)
		if btn(w, {box.x + box.width - 84, y, 68, btn_h}, "Cancel", false, in_box) {
			p.offer_id = {}
		}
		y += max(36, text_line_px(w, 13) + 12)
		reqs: [8]Message
		rn := carpool_incoming_requests(w, p.offer_id, reqs[:])
		for ri in 0 ..< rn {
			req := reqs[ri]
			route_txt := fmt.bprintf(
				buf[:],
				"%s -> %s",
				hub_name(w, int(req.request.from_hub)),
				hub_name(w, int(req.request.to_hub)),
			)
			ly := ui_line(w, {box.x + 16, y + 2}, route_txt, .Roboto_500, 13, pal.text)
			sub_buf: [48]u8
			ui_text(
				w,
				{box.x + 16, ly},
				rep_text(w, req.author, "New rider", sub_buf[:]),
				.Roboto_400,
				12,
				pal.text_2,
			)
			if btn(w, {box.x + box.width - 88, y + (row_h - btn_h) / 2, 72, btn_h}, "Accept", true, in_box) {
				if acc, ok := carpool_accept_make(w, &req); ok {
					if carpool_post(w, &acc) == .Added && trip_start(w, &req, &acc, true) {
						p.partner_pub = req.author
						p.trip_accept = msg_id(&acc)
						p.offer_id = {}
						ui_toast(w, "Carpool started, partner live on map")
					}
				}
			}
			y += row_h
		}
	} else if p.from != p.to && w.routes[p.mode].ok {
		if btn(
			w,
			{box.x + 16, y, box.width - 32, max(32, btn_h + 4)},
			"Offer ride (1 seat)",
			false,
			in_box,
		) {
			depart := carpool_offer_depart(w, p.hour)
			if m, ok := carpool_offer_make(w, p.from, p.to, p.mode, depart, 1); ok {
				if carpool_post(w, &m) == .Added {
					p.offer_id = msg_id(&m)
					ui_toast(w, "Carpool offer posted")
				} else {
					ui_toast(w, "Could not store carpool offer")
				}
			}
		}
		y += max(40, btn_h + 12)
	}

	if p.match_count > 0 {
		y = ui_line(w, {box.x + 16, y + 2}, "Matching rides", .Roboto_500, 12, pal.text_2) + 4
		for i in 0 ..< p.match_count {
			mt := p.matches[i]
			line1 := fmt.bprintf(buf[:], "%s -> %s", hub_name(w, mt.from_hub), hub_name(w, mt.to_hub))
			ly := ui_line(w, {box.x + 16, y + 2}, line1, .Roboto_500, 13, pal.text)
			sub_buf: [64]u8
			rep_buf: [32]u8
			rep := rep_text(w, mt.author, "New driver", rep_buf[:])
			line2 := fmt.bprintf(sub_buf[:], "%.1f kWh, %s", mt.passenger_kwh, rep)
			ui_text(w, {box.x + 16, ly}, line2, .Roboto_400, 12, pal.text_2)
			if btn(w, {box.x + box.width - 78, y + (row_h - btn_h) / 2, 62, btn_h}, "Join", true, in_box) {
				if req, ok := carpool_request_make(w, mt.offer, p.from, p.to, 1); ok {
					if carpool_post(w, &req) == .Added {
						p.request_id = msg_id(&req)
						ui_toast(w, "Ride request sent")
					}
				}
			}
			y += row_h
		}
	} else if p.offer_id == {} {
		y = ui_line(w, {box.x + 16, y + 2}, "No matching rides from peers yet", .Roboto_400, 12, pal.text_2)
	}
	return y - start_y + 8
}

// Carpool banners while navigating (map or street view):
// - passenger riding: status + Abort button (or Backspace)
// - driver with live offer: incoming request + Accept (Y)
carpool_nav_ui :: proc(w: ^World) {
	if w.screen != .Navigate do return
	p := &w.plan
	pal := palette(w)
	sw := f32(rl.GetScreenWidth())
	if carpool_is_passenger(w) {
		title := "Riding as passenger"
		sub := "Following driver (Esc for plan)"
		tw := max(ui_text_size(w, title, .Figtree_600, 14).x, ui_text_size(w, sub, .Roboto_400, 12).x)
		lbl := "Abort"
		sz := ui_text_size(w, lbl, .Roboto_500, 12)
		bw := max(84, sz.x + 28)
		bh := max(30, sz.y + 14)
		cw := max(316, 14 + tw + 16 + bw + 12)
		ch := max(66, 12 + text_line_px(w, 14) + text_px(w, 12) + 12)
		def_r := rl.Rectangle{sw - cw - 16, 16, cw, ch}
		r := ui_window_begin(w, .Carpool_Nav, def_r, 0, snap_radius = 12)
		ui_shadow(w, r, 12)
		round_rect(w, r, 12, pal.surface)
		ty := ui_line(w, {r.x + 14, r.y + 12}, title, .Figtree_600, 14, pal.green)
		ui_text(w, {r.x + 14, ty}, sub, .Roboto_400, 12, pal.text_2)
		btn_r := rl.Rectangle{r.x + r.width - bw - 12, r.y + (r.height - bh) / 2, bw, bh}
		id, hot, fired := ui_widget(w, btn_r)
		if w.street.on do hot, fired = false, false
		round_rect(w, btn_r, bh / 2, hot ? rl.ColorBrightness(pal.red, 0.1) : pal.red)
		ui_text(
			w,
			{btn_r.x + (btn_r.width - sz.x) / 2, btn_r.y + (btn_r.height - sz.y) / 2},
			lbl,
			.Roboto_500,
			12,
			rl.WHITE,
		)
		ui_focus_ring(w, id, btn_r, bh / 2)
		if !w.street.on do ui_block(w, r)
		ui_window_end(w, !w.street.on)
		if fired || key_pressed(w, .BACKSPACE) {
			carpool_abort(w)
			ui_toast(w, "Left carpool")
		}
		return
	}
	if w.trip.active || p.offer_id == {} do return
	reqs: [1]Message
	if carpool_incoming_requests(w, w.plan.offer_id, reqs[:]) == 0 do return
	req := reqs[0]
	buf: [64]u8
	route_txt := fmt.bprintf(
		buf[:],
		"%s -> %s",
		hub_name(w, int(req.request.from_hub)),
		hub_name(w, int(req.request.to_hub)),
	)
	stars, n := carpool_reputation(w, req.author)
	rep_buf: [32]u8
	rep := n == 0 ? "New rider" : fmt.bprintf(rep_buf[:], "%.1f stars", stars)
	tw := max(ui_text_size(w, route_txt, .Roboto_500, 13).x, ui_text_size(w, rep, .Roboto_400, 11).x)
	lbl := "Accept (Y)"
	sz := ui_text_size(w, lbl, .Roboto_500, 12)
	bw := max(84, sz.x + 24)
	bh := max(30, sz.y + 14)
	cw := max(316, 14 + tw + 16 + bw + 12)
	ch := max(66, 10 + text_line_px(w, 13) + text_line_px(w, 13) + text_px(w, 11) + 10)
	def_r := rl.Rectangle{sw - cw - 16, 16, cw, ch}
	r := ui_window_begin(w, .Carpool_Nav, def_r, 0, snap_radius = 12)
	ui_shadow(w, r, 12)
	round_rect(w, r, 12, pal.surface)
	ty := ui_line(w, {r.x + 14, r.y + 10}, "Ride request", .Figtree_600, 13, pal.accent)
	ty = ui_line(w, {r.x + 14, ty}, route_txt, .Roboto_500, 13, pal.text)
	ui_text(w, {r.x + 14, ty}, rep, .Roboto_400, 11, pal.text_2)
	btn_r := rl.Rectangle{r.x + r.width - bw - 12, r.y + (r.height - bh) / 2, bw, bh}
	id, hot, fired := ui_widget(w, btn_r)
	if w.street.on do hot, fired = false, false
	round_rect(w, btn_r, bh / 2, hot ? rl.ColorBrightness(pal.accent, 0.1) : pal.accent)
	ui_text(
		w,
		{btn_r.x + (btn_r.width - sz.x) / 2, btn_r.y + (btn_r.height - sz.y) / 2},
		lbl,
		.Roboto_500,
		12,
		rl.WHITE,
	)
	ui_focus_ring(w, id, btn_r, bh / 2)
	if !w.street.on do ui_block(w, r)
	ui_window_end(w, !w.street.on)
	if fired || key_pressed(w, .Y) || pad_pressed(w, .RIGHT_FACE_UP) {
		if acc, ok := carpool_accept_make(w, &req); ok {
			if carpool_post(w, &acc) == .Added && trip_start(w, &req, &acc, true) {
				p.partner_pub = req.author
				p.trip_accept = msg_id(&acc)
				p.offer_id = {}
				ui_toast(w, "Carpool started, partner live on map")
			}
		}
	}
}
