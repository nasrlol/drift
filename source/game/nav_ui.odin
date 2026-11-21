// author: lars
package game

import "core:fmt"
import "core:math"
import "core:math/linalg"
import rl "vendor:raylib"

// Drawing of routes and navigation (docs/drift-design.pdf "Scherm 2: Navigeren" and "De kaart"): the route strips,
// time bubbles, the instruction banner with its "Then" tab, the road sign at the next maneuver, the layer pill
// under the ship, the warning pill and the bottom sheet. Reads w.routes and w.nav, changes only the chosen mode
// (a click on a bubble).
ROUTE_PX :: 14
ALT_ROUTE_PX :: 11
ROUTE_CASING_PX :: 2
BANNER_MAX_W :: 560
BANNER_MIN_H :: 120
BANNER_ICON_COL :: 96
SHEET_MAX_W :: 720
SHEET_H :: 172
WARNING_TOP :: 170
PILL_BELOW_SHIP :: 26

MANEUVER_ICONS :: [Maneuver_Kind]Icon {
	.Straight     = .Straight,
	.Slight_Left  = .Slight_Left,
	.Slight_Right = .Slight_Right,
	.Left         = .Left,
	.Right        = .Right,
	.Sharp_Left   = .Sharp_Left,
	.Sharp_Right  = .Sharp_Right,
	.Climb        = .Climb,
	.Descend      = .Descend,
	.Depart       = .Navigate,
	.Arrive       = .Pin,
}

// Projects a path to the screen; points behind the camera are dropped (the polyline is split there).
// from: first path index to draw (navigation hides the part behind the ship). head: where the strip starts
// instead of path[from] (the ship's point on the path), so the start glides with the ship instead of jumping
// from one 250 m path point to the next. Segments longer than ROUTE_SMOOTH_PX on the screen get Catmull-Rom
// points in between, so curves stay round when zoomed in (drawing only, the path itself is unchanged).
ROUTE_SMOOTH_PX :: 10
ROUTE_SMOOTH_MAX :: 12

draw_path_strip :: proc(
	w: ^World,
	path: [][3]f32,
	from: int,
	px: f32,
	color: rl.Color,
	head: [2]f32 = {},
	has_head := false,
) {
	pts := make([dynamic][2]f32, 0, 2 * len(path), context.temp_allocator)
	flush :: proc(pts: ^[dynamic][2]f32, px: f32, color: rl.Color) {
		if len(pts) >= 2 {
			rl.DrawSplineLinear(raw_data(pts[:]), i32(len(pts)), px, color)
			// Round joins and caps: the spline joins are mitred, circles close the gaps of sharp corners.
			for p in pts do rl.DrawCircleV(p, px / 2, color)
		}
		clear(pts)
	}
	add :: proc(w: ^World, pts: ^[dynamic][2]f32, p: [2]f32, px: f32, color: rl.Color) {
		s, _ := cam_to_screen(w, {p.x, p.y, 0})
		if s.x <= -1e5 {
			flush(pts, px, color)
			return
		}
		// Skip points closer than 2 px to the last one: fewer segments, same picture.
		if len(pts) > 0 && linalg.length2(s - pts[len(pts) - 1]) < 4 do return
		append(pts, s)
	}
	first := clamp(from, 0, len(path))
	if first >= len(path) do return
	if has_head do add(w, &pts, head, px, color)
	else do add(w, &pts, path[first].xy, px, color)
	for i in first ..< len(path) - 1 {
		a, b := path[i].xy, path[i + 1].xy
		sa, _ := cam_to_screen(w, {a.x, a.y, 0})
		sb, _ := cam_to_screen(w, {b.x, b.y, 0})
		n := 1
		if sa.x > -1e5 && sb.x > -1e5 {
			n = clamp(int(linalg.length(sb - sa) / ROUTE_SMOOTH_PX), 1, ROUTE_SMOOTH_MAX)
		}
		p0 := path[max(i - 1, 0)].xy
		p3 := path[min(i + 2, len(path) - 1)].xy
		for k in 1 ..= n {
			t := f32(k) / f32(n)
			if i == first && has_head {
				// The first segment starts at the head: only the part after it.
				if linalg.length(b - a) > 0 && linalg.dot(catmull_rom(p0, a, b, p3, t) - head, b - a) <= 0 do continue
			}
			add(w, &pts, catmull_rom(p0, a, b, p3, t), px, color)
		}
	}
	flush(&pts, px, color)
}

// Uniform Catmull-Rom between b and c, t 0..1.
catmull_rom :: proc(a, b, c, d: [2]f32, t: f32) -> [2]f32 {
	t2 := t * t
	t3 := t2 * t
	return 0.5 * (2 * b + (c - a) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (3 * b - a - 3 * c + d) * t3)
}

// Draw order 5: the alternatives first (grey, 11 px), then the chosen one (cyan, 14 px), each with a 2 px darker
// casing. While navigating only the active route from the ship on.
nav_draw_routes :: proc(w: ^World) {
	pal := palette(w)
	if w.screen == .Navigate {
		r := nav_route(w)
		if r == nil do return
		from := clamp(w.nav.path_index, 0, len(r.path) - 1)
		head := r.path[from].xy
		if from + 1 < len(r.path) {
			seg := r.dist[from + 1] - r.dist[from]
			f := seg > 0 ? clamp((w.nav.s_km - r.dist[from]) / seg, 0, 1) : 0
			head = linalg.lerp(r.path[from].xy, r.path[from + 1].xy, f)
		}
		draw_path_strip(w, r.path, from, ROUTE_PX + 2 * ROUTE_CASING_PX, pal.route_casing, head, true)
		draw_path_strip(w, r.path, from, ROUTE_PX, pal.route, head, true)
		return
	}
	for mode in MODE_ORDER {
		r := &w.routes[mode]
		if !r.ok || mode == w.plan.mode do continue
		draw_path_strip(w, r.path, 0, ALT_ROUTE_PX + 2 * ROUTE_CASING_PX, pal.alt_route_casing)
		draw_path_strip(w, r.path, 0, ALT_ROUTE_PX, pal.alt_route)
	}
	if r := &w.routes[w.plan.mode]; r.ok {
		draw_path_strip(w, r.path, 0, ROUTE_PX + 2 * ROUTE_CASING_PX, pal.route_casing)
		draw_path_strip(w, r.path, 0, ROUTE_PX, pal.route)
	}
}

// Time bubbles (plan screen): each on the point of its route furthest from the other routes and the bubbles
// already placed (spec), the chosen one on top. A click picks that route.
nav_draw_bubbles :: proc(w: ^World) {
	pal := palette(w)
	buf: [32]u8
	kbuf: [32]u8
	placed: [Route_Mode][2]f32
	has: [Route_Mode]bool
	for mode in MODE_ORDER {
		r := &w.routes[mode]
		if !r.ok || len(r.path) < 3 do continue
		best, best_d := len(r.path) / 2, f32(-1)
		step := max(len(r.path) / 60, 1)
		for i := step; i < len(r.path) - step; i += step {
			p := r.path[i].xy
			d := f32(math.F32_MAX)
			for other in Route_Mode {
				o := &w.routes[other]
				if other == mode || !o.ok do continue
				ostep := max(len(o.path) / 60, 1)
				for j := 0; j < len(o.path); j += ostep do d = min(d, linalg.length(o.path[j].xy - p))
				if has[other] do d = min(d, linalg.length(placed[other] - p))
			}
			if d > best_d do best, best_d = i, d
		}
		placed[mode] = r.path[best].xy
		has[mode] = true
	}
	order := [3]Route_Mode{}
	k := 0
	for mode in MODE_ORDER do if mode != w.plan.mode {order[k] = mode; k += 1}
	order[2] = w.plan.mode
	for mode in order {
		r := &w.routes[mode]
		if !r.ok || !has[mode] do continue
		p, visible := cam_to_screen(w, {placed[mode].x, placed[mode].y, 0})
		if !visible do continue
		chosen := mode == w.plan.mode
		top := format_duration(buf[:], r.sum.minutes)
		bottom := fmt.bprintf(kbuf[:], "%.1f kWh", r.sum.net_kwh)
		ts := ui_text_size(w, top, .Figtree_500, 14)
		bs := ui_text_size(w, bottom, .Roboto_400, 12)
		leaf: f32 = mode == .Greenest ? 18 : 0
		box := rl.Rectangle{p.x + 6, p.y - 46, max(ts.x + leaf, bs.x) + 20, 42}
		bg := chosen ? pal.accent_strong : rl.WHITE
		fg := chosen ? rl.WHITE : pal.text
		id, hot, fired := ui_widget(w, box)
		ui_shadow(w, box, 10)
		round_rect(box, 10, hot && !chosen ? pal.surface_2 : bg)
		// Tail bottom-left, pointing at the route.
		rl.DrawTriangle(
			{box.x, box.y + box.height - 10},
			p,
			{box.x + 12, box.y + box.height},
			hot && !chosen ? pal.surface_2 : bg,
		)
		if mode == .Greenest do ui_icon(w, .Leaf, {box.x + 18, box.y + 13}, 16, chosen ? rl.WHITE : pal.green)
		ui_text(w, {box.x + 10 + leaf, box.y + 5}, top, .Figtree_500, 14, fg)
		ui_text(w, {box.x + 10, box.y + 23}, bottom, .Roboto_400, 12, chosen ? rl.WHITE : pal.text_2)
		ui_focus_ring(w, id, box, 10)
		ui_block(w, box)
		if fired do w.plan.mode = mode
	}
}

// Start ring and destination pin of the planned trip (design "Labels en markers").
nav_draw_trip_markers :: proc(w: ^World) {
	pal := palette(w)
	p := &w.plan
	if p.has_from {
		pos := w.m.hubs[p.from].pos
		if s, visible := cam_to_screen(w, {pos.x, pos.y, 0}); visible {
			rl.DrawCircleV(s, 9, rl.WHITE)
			rl.DrawRing(s, 5, 9, 0, 360, 24, {60, 64, 67, 255})
		}
	}
	if p.has_to {
		pos := w.m.hubs[p.to].pos
		if s, visible := cam_to_screen(w, {pos.x, pos.y, 0}); visible {
			// Red drop pin of 30 px with a white border, the tip on the tower.
			rl.DrawCircleV(s - {0, 19}, 11, rl.WHITE)
			rl.DrawTriangle(s - {9, 15}, s, s - {-9, 15}, rl.WHITE)
			rl.DrawCircleV(s - {0, 19}, 9, pal.red)
			rl.DrawTriangle(s - {7, 15}, s - {0, 3}, s - {-7, 15}, pal.red)
			rl.DrawCircleV(s - {0, 19}, 3.5, rl.WHITE)
		}
	}
	// Reported gust zones: a yellow wind icon on the map (spec "Gust melden").
	for z in w.gust_zones {
		if z.radius <= 0 do continue
		if s, visible := cam_to_screen(w, {z.center.x, z.center.y, 0}); visible {
			rl.DrawCircleV(s, 15, pal.warning)
			ui_icon(w, .Wind, s, 20, {32, 33, 36, 255})
		}
	}
}

// The bottom sheet rect: Dario places Exit and self-fly from it.
nav_sheet_rect :: proc(w: ^World) -> rl.Rectangle {
	sw, sh := f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())
	width := min(SHEET_MAX_W, sw - 32)
	return {(sw - width) / 2, sh - SHEET_H, width, SHEET_H}
}

// Navigation screen: road sign, layer pill, banner + Then, warning and the sheet. Draw order 7 and 8.
nav_ui :: proc(w: ^World) {
	pal := palette(w)
	n := &w.nav
	r := nav_route(w)
	s := &w.ship
	buf: [96]u8
	sub: [96]u8

	// Road sign at the next maneuver (within CALLOUT_KM), light cyan with a 3 px white border, tail bottom right.
	if r != nil && n.banner == .Flying && n.next < len(r.maneuvers) && n.next_m < CALLOUT_KM * 1000 {
		m := &r.maneuvers[n.next]
		p := r.path[m.path_index]
		if sp, visible := cam_to_screen(w, {p.x, p.y, 0}); visible {
			name := cstr(m.road[:])
			size := ui_text_size(w, name, .Figtree_600, 19)
			box := rl.Rectangle{sp.x - size.x - 34, sp.y - size.y - 30, size.x + 28, size.y + 14}
			round_rect({box.x - 3, box.y - 3, box.width + 6, box.height + 6}, 17, rl.WHITE)
			rl.DrawTriangle(
				{box.x + box.width - 16, box.y + box.height + 2},
				{box.x + box.width + 2, box.y + box.height - 12},
				sp,
				rl.WHITE,
			)
			round_rect(box, 14, pal.bubble)
			ui_text(w, {box.x + 14, box.y + 7}, name, .Figtree_600, 19, pal.bubble_text)
		}
	}

	// Layer pill 26 px under the ship.
	if sp, visible := cam_to_screen(w, {s.pos.x, s.pos.y, 0}); visible {
		name := layer_name(buf[:], layer_at(s.alt))
		// Driving: the real name of the road under the car, like a street name (spec "Namen").
		if s.on_road {
			name = "Road"
			if road, _, ok := map_nearest_name(w, s.pos, ROAD_NAME_KM); ok do name = road
		}
		size := ui_text_size(w, name, .Figtree_600, 17)
		box := rl.Rectangle{sp.x - size.x / 2 - 14, sp.y + PILL_BELOW_SHIP, size.x + 28, size.y + 10}
		round_rect(box, box.height / 2, pal.pill)
		ui_text(w, {box.x + 14, box.y + 5}, name, .Figtree_600, 17, rl.WHITE)
	}

	// Banner: teal while flying, grey with a turning arrow while rerouting, green on arrival.
	if r != nil {
		sw := f32(rl.GetScreenWidth())
		width := min(BANNER_MAX_W, sw - 32 - 100)
		banner := rl.Rectangle{16, 16, width, BANNER_MIN_H}
		color := pal.banner
		icon := Icon.Straight
		text, subline: string
		dist_value, dist_unit: string
		switch n.banner {
		case .Rerouting:
			color = pal.reroute
			icon = .Reroute
			text = "Rerouting..."
			subline = n.no_route ? "No safe route from here, keeping the old one" : "Finding a new route"
		case .Arrived:
			color = pal.arrived
			icon = .Pin
			text = fmt.bprintf(buf[:], "Docked at %s", hub_name(w, n.to))
			saved := r.sum.vs_straight
			subline = fmt.bprintf(
				sub[:],
				"%.2f kWh used, %.2f kWh solar%s",
				n.used_kwh,
				n.solar_kwh,
				saved < 0 ? fmt.tprintf(", %.0f%% less than a straight line", -saved * 100) : "",
			)
		case .Flying:
			if n.next < len(r.maneuvers) {
				m := &r.maneuvers[n.next]
				icons := MANEUVER_ICONS
				icon = icons[m.kind]
				text = cstr(m.text[:])
				subline = cstr(m.sub[:])
				dist_value, dist_unit = format_distance(sub[64:], n.next_m)
			}
		}
		then := n.banner == .Flying && n.then_visible && n.next + 1 < len(r.maneuvers)
		round_rect(banner, 18, color)
		if then do rl.DrawRectangleRec({banner.x, banner.y + banner.height - 18, 18, 18}, color)
		ui_block(w, banner)
		col := rl.Rectangle{banner.x, banner.y, BANNER_ICON_COL, banner.height}
		if n.banner == .Rerouting {
			// The circle arrow turns while rerouting.
			angle := f32(rl.GetTime()) * 360
			c := [2]f32{col.x + col.width / 2, col.y + 44}
			rl.DrawRing(c, 20, 26, angle, angle + 280, 32, rl.WHITE)
			rl.DrawPoly(
				c +
				[2]f32{math.cos(math.to_radians(angle + 280)), math.sin(math.to_radians(angle + 280))} * 23,
				3,
				7,
				angle + 280 + 90,
				rl.WHITE,
			)
		} else {
			ui_icon(w, icon, {col.x + col.width / 2, col.y + 44}, 64, rl.WHITE)
		}
		if dist_value != "" {
			vs := ui_text_size(w, dist_value, .Figtree_600, 34)
			us := ui_text_size(w, dist_unit, .Figtree_500, 18)
			x := col.x + (col.width - vs.x - us.x - 2) / 2
			ui_text(w, {x, col.y + 74}, dist_value, .Figtree_600, 34, rl.WHITE)
			ui_text(w, {x + vs.x + 2, col.y + 88}, dist_unit, .Figtree_500, 18, rl.WHITE)
		}
		tx := banner.x + BANNER_ICON_COL + 4
		ui_text_wrapped(
			w,
			{tx, banner.y + 16, banner.width - BANNER_ICON_COL - 20, 82},
			text,
			.Figtree_500,
			n.banner == .Flying ? 34 : 30,
			rl.WHITE,
		)
		ui_text_wrapped(
			w,
			{tx, banner.y + banner.height - 34, banner.width - BANNER_ICON_COL - 20, 22},
			subline,
			.Roboto_400,
			17,
			rl.ColorAlpha(rl.WHITE, 0.85),
		)

		if then {
			m := &r.maneuvers[n.next + 1]
			tab := rl.Rectangle{banner.x, banner.y + banner.height, 132, 46}
			round_rect(tab, 18, pal.banner_2)
			rl.DrawRectangleRec({tab.x, tab.y, tab.width, 18}, pal.banner_2)
			ui_text(w, {tab.x + 16, tab.y + 12}, "Then", .Figtree_500, 19, rl.WHITE)
			icons := MANEUVER_ICONS
			ui_icon(w, icons[m.kind], {tab.x + 90, tab.y + 23}, 28, rl.WHITE)
			ui_block(w, tab)
		}
	}

	// Warning pill, centred 170 px from the top.
	if warning := cstr(n.warning[:]); warning != "" || s.warnings != {} {
		if warning == "" {
			switch {
			case .No_Fly in s.warnings:
				warning = "Inside a no-fly zone, climb or leave it"
			case .Terrain in s.warnings:
				warning = "Close to the ground, climb"
			case:
				warning = "Traffic jam, slowing down"
			}
		}
		size := ui_text_size(w, warning, .Figtree_600, 15)
		box := rl.Rectangle {
			(f32(rl.GetScreenWidth()) - size.x - 50) / 2,
			WARNING_TOP,
			size.x + 50,
			size.y + 16,
		}
		round_rect(box, box.height / 2, pal.warning)
		dark := rl.Color{32, 33, 36, 255}
		ui_icon(w, .Warning, {box.x + 20, box.y + box.height / 2}, 20, dark)
		ui_text(w, {box.x + 36, box.y + 8}, warning, .Figtree_600, 15, dark)
	}

	// Bottom sheet: remaining time (green + leaf), "km, arrive hh:mm", stat chips. Dario adds the buttons
	// (pilot_ui).
	sheet := nav_sheet_rect(w)
	round_rect({sheet.x, sheet.y, sheet.width, sheet.height + 22}, 22, pal.sheet)
	ui_block(w, sheet)
	x := sheet.x + 24
	if r != nil {
		ui_icon(w, .Leaf, {x + 16, sheet.y + 46}, 32, pal.green)
		ui_text(
			w,
			{x + 38, sheet.y + 24},
			format_duration(buf[:], n.eta_s / 60),
			.Figtree_600,
			38,
			pal.green,
		)
		arrive :=
			w.weather.start + i64(n.hour) * 3600 + i64(f64(w.tick - n.start_tick) * SIM_DT + f64(n.eta_s))
		h, mi := belgian_time(arrive)
		ui_text(
			w,
			{x, sheet.y + 72},
			fmt.bprintf(sub[:], "%.1f km, arrive %02d:%02d", n.remaining_km, h, mi),
			.Roboto_400,
			20,
			pal.text_2,
		)
	} else {
		ui_text(w, {x, sheet.y + 28}, "Free flight", .Figtree_600, 38, pal.text)
		ui_text(w, {x, sheet.y + 72}, "No route, fly with W A S D, R and F", .Roboto_400, 20, pal.text_2)
	}
	chips := [5]struct {
		label, value: string,
		meter:        f32,
	} {
		{"SPEED", fmt.tprintf("%.0f km/h", s.speed * 3.6), -1},
		{
			"BATTERY",
			fmt.tprintf("%.1f%%", ship_battery_kwh(s) / BATTERY_KWH * 100),
			ship_battery_kwh(s) / BATTERY_KWH,
		},
		{"USED", fmt.tprintf("%.2f kWh", n.active ? n.used_kwh : s.used_kwh - s.solar_kwh), -1},
		{"SOLAR", fmt.tprintf("%.1f kW", solar_kw(cloud_at(w, s.pos.x, s.pos.y, sim_hour(w)))), -1},
		{"HEIGHT", fmt.tprintf("%.0f m", s.alt), -1},
	}
	cw := (sheet.width - 48 - 4 * 8) / 5
	for c, i in chips {
		ui_stat_chip(w, {x + f32(i) * (cw + 8), sheet.y + 108, cw, 58}, c.label, c.value, c.meter)
	}
}

// The carpool partner during an accepted trip (live position from net.odin): a ring with the airship arrow and
// "Partner" under it, so two players see each other on the map.
carpool_draw_partner :: proc(w: ^World) {
	if !w.trip.active || !w.partner_seen do return
	pal := palette(w)
	p, visible := cam_to_screen(w, {w.partner.x, w.partner.y, 0})
	if !visible do return
	rl.DrawCircleV(p, 15, rl.WHITE)
	rl.DrawCircleV(p, 12, pal.accent)
	ui_icon(w, .Navigate, p, 16, rl.WHITE)
	size := ui_text_size(w, "Partner", .Figtree_600, 13)
	for o in ([?][2]f32{{-1, 0}, {1, 0}, {0, -1}, {0, 1}}) {
		ui_text(w, {p.x - size.x / 2, p.y + 18} + o, "Partner", .Figtree_600, 13, pal.label_halo)
	}
	ui_text(w, {p.x - size.x / 2, p.y + 18}, "Partner", .Figtree_600, 13, pal.area_label)
}
