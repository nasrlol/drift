// author: andrei
package game

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:strings"
import rl "vendor:raylib"

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
LEGEND_X :: 440
HUB_PICK_PX :: 16 // a click this close to a hub marker opens its menu
CAR_PICKER_H :: 56

Layers :: struct {
	hide_wind:   bool,
	hide_gusts:  bool,
	hide_no_fly: bool,
	hide_solar:  bool,
	terrain:     bool, // map type tile "3D terrain": relief shading under the map
	wind_layer:  int, // index in LAYER_ALT for the wind trails and the gust layer
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
	layers_open:      bool,
	hub_menu:         int, // hub id + 1 of the open menu on the map, 0 = closed
	scroll:           f32, // route list scroll in px
}

plan_panel_rect :: proc(w: ^World) -> rl.Rectangle {
	return {PLAN_MARGIN, PLAN_MARGIN, PLAN_PANEL_W, f32(rl.GetScreenHeight()) - 2 * PLAN_MARGIN}
}

// The part of the screen right of the panel, where cam_fit puts the routes.
plan_map_rect :: proc(w: ^World) -> rl.Rectangle {
	p := plan_panel_rect(w)
	x := p.x + p.width + 40
	return {x, 60, max(f32(rl.GetScreenWidth()) - x - 130, 100), max(f32(rl.GetScreenHeight()) - 140, 100)}
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
MODE_ICONS :: [Route_Mode]Icon {
	.Fastest  = .Bolt,
	.Greenest = .Leaf,
	.Calmest  = .Waves,
}
MODE_LABELS :: [Route_Mode]string {
	.Fastest  = "Fastest",
	.Greenest = "Greenest",
	.Calmest  = "Calmest",
}

// Case-insensitive ASCII substring test; non-ASCII bytes (accents) compare as they are.
match_hub :: proc(name, query: string) -> bool {
	if query == "" do return true
	lower :: proc(c: u8) -> u8 {return c >= 'A' && c <= 'Z' ? c + 32 : c}
	for i in 0 ..= len(name) - len(query) {
		ok := true
		for j in 0 ..< len(query) {
			if lower(name[i + j]) != lower(query[j]) {
				ok = false
				break
			}
		}
		if ok do return true
	}
	return false
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
		return
	}
	if p.planned && p.planned_from == p.from && p.planned_to == p.to && p.planned_hour == p.hour && p.planned_weather == w.weather_hash do return
	plan_routes(w, p.from, p.to, p.hour)
	w.scan_s = 0.001
	p.planned = true
	p.planned_from, p.planned_to, p.planned_hour, p.planned_weather = p.from, p.to, p.hour, w.weather_hash
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
	pal := palette(w)
	p := &w.plan
	panel := plan_panel_rect(w)
	buf: [96]u8

	// Card A: from / to, mode chips, departure. No brand row (Lars, 2026-11-21: the logo goes), no day / night
	// button (light only).
	a := rl.Rectangle{panel.x, panel.y, panel.width, 252 + CAR_PICKER_H + 12}
	ui_card(w, a)
	x := a.x + 16
	y := a.y + 16

	// From / To with the rail (ring, three dots, red pin) and the swap button.
	field_x := x + 30
	field_w := a.width - 32 - 30 - 48
	from_r := rl.Rectangle{field_x, y, field_w, 44}
	to_r := rl.Rectangle{field_x, y + 52, field_w, 44}
	rl.DrawRing({x + 11, from_r.y + 22}, 4, 7, 0, 360, 24, pal.text_2)
	for k in 0 ..< 3 do rl.DrawCircleV({x + 11, from_r.y + 36 + f32(k) * 7}, 1.6, pal.text_2)
	ui_icon(w, .Pin, {x + 11, to_r.y + 22}, 16 * 1.25, pal.red)
	query := string(p.query[:p.query_len])
	for field in ([2]Plan_Field{.From, .To}) {
		r := field == .From ? from_r : to_r
		has := field == .From ? p.has_from : p.has_to
		hub := field == .From ? p.from : p.to
		editing := p.editing == field
		text := editing ? query : has ? hub_name(w, hub) : ""
		if ui_input(w, r, text, field == .From ? "Choose start" : "Choose destination", editing) {
			p.editing = field
			p.query_len = 0
			p.departure_open = false
		}
	}
	if ui_round_button(w, {a.x + a.width - 16 - 40, y + 26, 40, 40}, .Swap, false) {
		p.from, p.to = p.to, p.from
		p.has_from, p.has_to = p.has_to, p.has_from
	}
	y += 96 + 12

	// Mode chips with the travel time of each route.
	chip_w := (a.width - 32 - 16) / 3
	icons := MODE_ICONS
	labels := MODE_LABELS
	for mode, i in MODE_ORDER {
		r := &w.routes[mode]
		top := r.ok ? format_duration(buf[:], r.sum.minutes) : "--"
		if ui_chip(w, {x + f32(i) * (chip_w + 8), y, chip_w, 66}, icons[mode], top, labels[mode], p.mode == mode) do p.mode = mode
	}
	y += 66 + 12

	// Departure: clock + "Leave now, 14:00" .. "+8 h", opens a list.
	dep := rl.Rectangle{x, y, a.width - 32, 38}
	{
		id, hot, fired := ui_widget(w, dep)
		round_rect(dep, 8, hot ? pal.surface_3 : pal.surface_2)
		ui_icon(w, .Clock, {dep.x + 20, dep.y + 19}, 20, pal.text_2)
		label := plan_hour_label(w, p.hour, buf[:])
		ui_text(w, {dep.x + 38, dep.y + 10}, label, .Roboto_400, 14, pal.text)
		ui_icon(w, .Expand, {dep.x + dep.width - 18, dep.y + 19}, 20, pal.text_2)
		ui_focus_ring(w, id, dep, 8)
		if fired {
			p.departure_open = !p.departure_open
			p.editing = .None
		}
	}
	y += 38 + 12

	// The car: turning preview + skin segment (car_models.odin).
	car_skin_picker(w, {x, y, a.width - 32, CAR_PICKER_H})

	// Card B: route rows, wind note, actions. Fills the rest of the panel, the list scrolls.
	b := rl.Rectangle {
		panel.x,
		a.y + a.height + PLAN_CARD_GAP,
		panel.width,
		panel.height - a.height - PLAN_CARD_GAP,
	}
	ui_card(w, b)
	ROW_H :: 112
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
		p.scroll = clamp(p.scroll, 0, max(3 * ROW_H - routes_box.height, 0))
		rl.BeginScissorMode(
			i32(routes_box.x),
			i32(routes_box.y),
			i32(routes_box.width),
			i32(routes_box.height),
		)
		for mode, i in MODE_ORDER {
			r := &w.routes[mode]
			row := rl.Rectangle{b.x, routes_box.y + f32(i) * ROW_H - p.scroll, b.width, ROW_H}
			id, hot, fired := ui_widget(w, row)
			if !rl.CheckCollisionPointRec(mouse, routes_box) do hot = false
			if hot do rl.DrawRectangleRec(row, pal.surface_2)
			if p.mode == mode do rl.DrawRectangleRec({row.x, row.y + 8, 4, row.height - 16}, pal.accent_strong)
			if i > 0 do rl.DrawLineEx({row.x + 16, row.y}, {row.x + row.width - 16, row.y}, 1, pal.line)
			rx, ry := row.x + 16, row.y + 14
			if !r.ok {
				ui_text(w, {rx, ry}, labels[mode], .Figtree_600, 21, pal.text_2)
				ui_text(w, {rx, ry + 30}, "No safe route with this wind", .Roboto_400, 14, pal.warning)
			} else {
				green := mode == .Greenest
				time_x := rx
				if green {
					ui_icon(w, .Leaf, {rx + 11, ry + 13}, 22, pal.green)
					time_x += 26
				}
				ui_text(
					w,
					{time_x, ry},
					format_duration(buf[:], r.sum.minutes),
					.Figtree_600,
					21,
					green ? pal.green : pal.text,
				)
				ui_text(
					w,
					{rx, ry + 28},
					fmt.bprintf(buf[:], "%.0f km, %.0f km/h", r.sum.km, r.sum.kmh),
					.Roboto_400,
					14,
					pal.text_2,
				)
				ui_text(w, {rx, ry + 47}, cstr(r.sum.why[:]), .Roboto_400, 14, pal.text)
				tag: string
				warn := false
				switch r.sum.tag {
				case .None:
				case .Lowest_Energy:
					tag =
						r.sum.vs_straight < 0 ? fmt.bprintf(buf[:], "Lowest energy, %.0f%% vs straight line", r.sum.vs_straight * 100) : "Lowest energy"
				case .Extra_Energy:
					tag = fmt.bprintf(buf[:], "%+.0f%% energy", r.sum.vs_greenest * 100)
					warn = r.sum.vs_greenest > 0.5
				case .Gust_Index:
					tag = fmt.bprintf(buf[:], "Gust index %.2f", r.sum.gust)
					warn = r.sum.gust > 0.25
				}
				if tag != "" {
					size := ui_text_size(w, tag, .Roboto_500, 12)
					pill := rl.Rectangle{rx, ry + 70, size.x + 18, size.y + 6}
					c := warn ? pal.warning : pal.green
					round_rect(pill, pill.height / 2, rl.ColorAlpha(c, 0.16))
					ui_text(w, {pill.x + 9, pill.y + 3}, tag, .Roboto_500, 12, c)
				}
				kwh := fmt.bprintf(buf[:], "%.1f kWh", r.sum.net_kwh)
				ks := ui_text_size(w, kwh, .Mono_600, 14)
				ui_text(
					w,
					{row.x + row.width - 16 - ks.x, ry + 2},
					kwh,
					.Mono_600,
					14,
					green ? pal.green : pal.text,
				)
				wind := fmt.bprintf(buf[:], "%.1f m/s", r.sum.wind_ms)
				ws := ui_text_size(w, wind, .Mono_400, 13)
				ui_text(w, {row.x + row.width - 16 - ws.x, ry + 22}, wind, .Mono_400, 13, pal.text_2)
			}
			ui_focus_ring(w, id, row, 0)
			if fired && r.ok do p.mode = mode
		}
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
		if ui_pill_button(w, {b.x + 16, ay, 128, 44}, "Preview", .Secondary, .Play, true) && ok do cam_preview(w, p.mode)
		if ui_pill_button(
			   w,
			   {b.x + 16 + 128 + 10, ay, b.width - 32 - 138, 44},
			   "Start",
			   .Primary,
			   .Navigate,
			   true,
		   ) &&
		   ok {
			if nav_start(w, p.mode) {
				w.screen = .Navigate
				w.plan.layers_open = false
				cam_chase(w)
			}
		}
	}

	// Popups last, so they are drawn over everything and take the clicks inside them.
	if p.editing != .None {
		r := p.editing == .From ? from_r : to_r
		ui_text_edit(p.query[:], &p.query_len)
		if rl.IsKeyPressed(.ESCAPE) do p.editing = .None
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
		round_rect(list, 12, pal.surface)
		rl.BeginScissorMode(i32(list.x), i32(list.y), i32(list.width), i32(list.height))
		for hub, i in matches {
			row := rl.Rectangle{list.x, list.y + 4 + f32(i) * ROW, list.width, ROW}
			id, hot, fired := ui_widget(w, row)
			if hot do rl.DrawRectangleRec(row, pal.surface_2)
			ui_icon(w, .Tower, {row.x + 22, row.y + ROW / 2}, 20, pal.text_2)
			ui_text(w, {row.x + 42, row.y + 6}, hub_name(w, hub), .Roboto_400, 15, pal.text)
			ui_text(w, {row.x + 42, row.y + 25}, "Docking tower", .Roboto_400, 12, pal.text_2)
			ui_focus_ring(w, id, row, 0)
			if fired || (i == 0 && rl.IsKeyPressed(.ENTER)) {
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
		m := rl.GetMousePosition()
		if rl.IsMouseButtonPressed(.LEFT) && !rl.CheckCollisionPointRec(m, list) && !rl.CheckCollisionPointRec(m, r) do p.editing = .None
	}
	if p.departure_open {
		ROW :: 36
		list := rl.Rectangle{dep.x, dep.y + dep.height + 4, dep.width, FORECAST_HOURS * ROW + 8}
		w.ui.popup = list
		w.ui.in_popup = true
		ui_shadow(w, list, 12)
		round_rect(list, 12, pal.surface)
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
		if rl.IsMouseButtonPressed(.LEFT) && !rl.CheckCollisionPointRec(rl.GetMousePosition(), list) && !rl.CheckCollisionPointRec(rl.GetMousePosition(), dep) do p.departure_open = false
	}
	plan_hub_menu(w)
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
	round_rect(r, 12, pal.surface)
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

// Map buttons bottom right (layers, compass, zoom pill), the layers panel and the legend. Shown on the plan
// screen; the compass also in navigation through pilot_ui.
plan_map_controls :: proc(w: ^World) {
	pal := palette(w)
	p := &w.plan
	sw, sh := f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())
	x := sw - PLAN_MARGIN - MAP_BUTTON
	zoom := rl.Rectangle{x, sh - 24 - 92, MAP_BUTTON, 92}
	switch ui_zoom_pill(w, zoom) {
	case 1:
		cam_zoom_by(w, 1, w.cam.screen / 2)
	case -1:
		cam_zoom_by(w, -1, w.cam.screen / 2)
	}
	compass := rl.Rectangle{x, zoom.y - MAP_BUTTON_GAP - MAP_BUTTON, MAP_BUTTON, MAP_BUTTON}
	if compass_button(w, compass) do cam_north(w)
	layers := rl.Rectangle{x, compass.y - MAP_BUTTON_GAP - MAP_BUTTON, MAP_BUTTON, MAP_BUTTON}
	if ui_round_button(w, layers, .Layers, p.layers_open) do p.layers_open = !p.layers_open

	if p.layers_open {
		// Profile and debug builds get one more row: the profiler overlay.
		extra: f32 = PROFILING ? 32 : 0
		r := rl.Rectangle {
			layers.x - 12 - LAYERS_PANEL_W,
			layers.y - 250 - extra,
			LAYERS_PANEL_W,
			380 + extra,
		}
		ui_card(w, r)
		y := r.y + 16
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
		toggles := [4]struct {
			label: string,
			hide:  ^bool,
		} {
			{"Wind flow", &p.layers.hide_wind},
			{"Gust risk", &p.layers.hide_gusts},
			{"No-fly zones", &p.layers.hide_no_fly},
			{"Solar", &p.layers.hide_solar},
		}
		for t in toggles {
			ui_text(w, {r.x + 16, y + 2}, t.label, .Roboto_400, 14, pal.text)
			on := !t.hide^
			if ui_toggle(w, {r.x + r.width - 16 - 36, y, 36, 20}, &on) do t.hide^ = !on
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
	}

	// Legend: wind gradient 120 x 6, no-fly hatch, gust color.
	{
		r := rl.Rectangle{LEGEND_X, sh - 24 - 40, 420, 40}
		if r.x + r.width > x - 12 do return
		ui_card(w, r)
		lx := r.x + 14
		cy := r.y + 20
		colors := wind_colors(w)
		for k in 0 ..< 120 {
			t := f32(k) / 119 * 16
			rl.DrawRectangleV({lx + f32(k), cy - 3}, {1, 6}, wind_color_at(colors, t))
		}
		ui_text(w, {lx + 126, cy - 8}, "Wind 0-16 m/s", .Roboto_400, 12, pal.text_2)
		hx := lx + 230
		rl.DrawRectangleV({hx, cy - 7}, {14, 14}, rl.ColorAlpha(pal.red, 0.2))
		for k in 0 ..< 3 do rl.DrawLineEx({hx + f32(k) * 5, cy + 7}, {hx + f32(k) * 5 + 7, cy - 7}, 1, pal.red)
		rl.DrawRectangleLinesEx({hx, cy - 7, 14, 14}, 1.5, pal.red)
		ui_text(w, {hx + 20, cy - 8}, "No-fly", .Roboto_400, 12, pal.text_2)
		gx := hx + 76
		rl.DrawCircleGradient({gx + 7, cy}, 8, pal.red, rl.ColorAlpha(pal.warning, 0.3))
		ui_text(w, {gx + 20, cy - 8}, "Gust risk", .Roboto_400, 12, pal.text_2)
	}
}

// Compass button: a red and grey needle that turns with the map.
compass_button :: proc(w: ^World, r: rl.Rectangle) -> bool {
	pal := palette(w)
	id, hot, fired := ui_widget(w, r)
	c := [2]f32{r.x + r.width / 2, r.y + r.height / 2}
	ui_shadow(w, r, r.width / 2)
	rl.DrawCircleV(c, r.width / 2, hot ? pal.surface_2 : pal.surface)
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

// Soft gust risk (warning -> red from gust_at at the wind layer), cloud shade for the solar layer and the no-fly
// zones hatched in red, on the ground. Drawn between the map fills and the roads (design draw order 2).
layers_draw_ground :: proc(w: ^World) {
	pal := palette(w)
	l := &w.plan.layers
	hour := sim_hour(w)
	if (!l.hide_gusts || !l.hide_solar) && w.line_meshes.built {
		// Soft: a color per grid point, the GPU blends across each quad.
		colors := make([][4]u8, GROUND_VERTICES, context.temp_allocator)
		for gy in 0 ..< GROUND_H - 1 {
			for gx in 0 ..< GROUND_W - 1 {
				corners := ground_quad(gx, gy)
				for c, k in corners {
					x, y := f32(c.x * GROUND_CELL_KM), f32(c.y * GROUND_CELL_KM)
					col := rl.Color{}
					if !l.hide_gusts {
						g := gust_at(w, x, y, l.wind_layer, hour)
						col = rl.ColorLerp(pal.warning, pal.red, clamp((g - 0.2) / 0.6, 0, 1))
						col.a = u8(clamp((g - 0.15) / 0.6, 0, 1) * 110)
					}
					if !l.hide_solar {
						shade := u8(clamp(cloud_at(w, x, y, hour), 0, 1) * 60)
						if shade > col.a do col = {0, 0, 0, shade}
					}
					col.a = u8(f32(col.a) * belgium_fade(w, x, y))
					colors[(gy * (GROUND_W - 1) + gx) * 6 + k] = {col.r, col.g, col.b, col.a}
				}
			}
		}
		lm := &w.line_meshes
		rl.UpdateMeshBuffer(lm.ground, 3, raw_data(colors), i32(len(colors) * size_of(colors[0])), 0)
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

// Text wrapped on spaces inside r (line height 1.35).
ui_text_wrapped :: proc(w: ^World, r: rl.Rectangle, text: string, font: Font, px: f32, color: rl.Color) {
	y := r.y
	rest := text
	for rest != "" && y + px <= r.y + r.height + 1 {
		// Longest prefix that fits, cut at a space.
		cut := len(rest)
		for ui_text_size(w, rest[:cut], font, px).x > r.width {
			sp := strings.last_index_byte(rest[:cut], ' ')
			if sp <= 0 do break
			cut = sp
		}
		ui_text(w, {r.x, y}, rest[:cut], font, px, color)
		rest = strings.trim_left_space(rest[cut:])
		y += px * 1.35
	}
}
