package game

import "core:fmt"
import "core:math"
import "core:math/linalg"
import rl "vendor:raylib"

// The horizon of a tilted map (nasr, 2026-11-22): the far map, the far labels and clouds fade into the horizon
// color, and a sky gradient (pal.horizon to pal.sky) fills what lies above the horizon. Distances are view depth
// in multiples of the camera's distance to its target, so the same settings work at every zoom. The View tab
// of the settings panel (settings.odin) has a slider for each; the defaults are the constants.
VIEW_FOG_START :: 1.2 // where the land starts to fade
VIEW_FOG_END :: 3.5 // where it is gone
VIEW_FOG_STRENGTH :: 1.0
VIEW_SKY_FADE :: 0.25 // share of the screen height above the horizon over which horizon turns into sky
VIEW_LABEL_END :: 2.5 // river and road labels are gone from here
VIEW_HUB_END :: 4.0 // hub names and markers are gone from here
VIEW_FADE_SPAN :: 0.35 // a label fades out over this share of its end distance
VIEW_FOG_ROWS :: 48 // screen strips of the fog overlay

View_Edit :: struct {
	max_tilt_deg:   f32, // the steepest right drag tilt, 0 = straight down
	fog_start:      f32,
	fog_end:        f32,
	fog_strength:   f32, // 0 .. 1
	sky_fade:       f32,
	label_end:      f32,
	hub_end:        f32,
	reroute_banner: bool, // the grey "Rerouting..." banner after a reroute (nav_ui.odin)
	peer_names:     bool, // short handle above P2P cars
	peer_name_px:   f32,
}

view_edit_defaults :: proc() -> View_Edit {
	return {
		max_tilt_deg = CAM_ORBIT_MAX_TILT * math.DEG_PER_RAD,
		fog_start = VIEW_FOG_START,
		fog_end = VIEW_FOG_END,
		fog_strength = VIEW_FOG_STRENGTH,
		sky_fade = VIEW_SKY_FADE,
		label_end = VIEW_LABEL_END,
		hub_end = VIEW_HUB_END,
		reroute_banner = true,
		peer_names = true,
		peer_name_px = 10,
	}
}

view_max_tilt :: proc(w: ^World) -> f32 {
	return clamp(w.view_edit.max_tilt_deg, 0, 88) * math.RAD_PER_DEG
}

// The fog only exists while the camera is tilted.
view_tilted :: proc(w: ^World) -> bool {
	return w.cam.pose.tilt > 0.05 && w.cam.pose.globe_rot == {} && w.cam.pose.zoom >= 0
}

// The camera's distance to the point it looks at, in km: the unit of every View_Edit distance.
view_unit :: proc(w: ^World) -> f32 {
	return max(linalg.length(w.cam.view.target - w.cam.view.position), 1e-3)
}

// View depth in km of a point in camera space units (x km, y km, z km down).
view_depth :: proc(w: ^World, p: [3]f32) -> f32 {
	v := &w.cam.view
	return linalg.dot(p - v.position, linalg.normalize(v.target - v.position))
}

// The fog range as view depth in km, for the line and building shaders (fog_range).
view_fog_range :: proc(w: ^World) -> [2]f32 {
	if !view_tilted(w) do return {1e9, 2e9}
	e := &w.view_edit
	u := view_unit(w)
	return {e.fog_start * u, max(e.fog_end, e.fog_start + 0.01) * u}
}

// 0 clear .. fog_strength at view depth d (km), the curve of the shaders (f squared).
view_fog :: proc(w: ^World, d: f32) -> f32 {
	r := view_fog_range(w)
	f := clamp((d - r.x) / (r.y - r.x), 0, 1)
	return f * f * clamp(w.view_edit.fog_strength, 0, 1)
}

// 1 near .. 0 from end x the camera distance on, for labels at view depth d (km).
view_label_alpha :: proc(w: ^World, d: f32, end: f32) -> f32 {
	if !view_tilted(w) do return 1
	u := view_unit(w)
	far := max(end, 0.1) * u
	near := far * (1 - VIEW_FADE_SPAN)
	return 1 - clamp((d - near) / (far - near), 0, 1)
}

// Screen space over the map, before clouds and labels: per strip of rows the fog of the ground there, then the
// sky above the horizon. A screen row of a camera without roll is a line on the ground at one view depth, so
// one ground point per row gives its fog.
view_horizon_draw :: proc(w: ^World) {
	if !view_tilted(w) do return
	pal := palette(w)
	screen := w.cam.screen
	mid := screen.x / 2
	// The horizon row: ground below it, none above (bisection, rows grow downwards).
	horizon: f32 = 0
	if _, ok := cam_ground_at(w, {mid, 0}); !ok {
		lo, hi: f32 = 0, screen.y
		for _ in 0 ..< 24 {
			m := (lo + hi) / 2
			if _, ok2 := cam_ground_at(w, {mid, m}); ok2 {
				hi = m
			} else {
				lo = m
			}
		}
		horizon = hi
	}

	fog_at :: proc(w: ^World, y, mid: f32) -> f32 {
		g, ok := cam_ground_at(w, {mid, y})
		if !ok do return clamp(w.view_edit.fog_strength, 0, 1)
		return view_fog(w, view_depth(w, {g.x, g.y, 0}))
	}
	step := (screen.y - horizon) / VIEW_FOG_ROWS
	if step > 0 {
		prev := fog_at(w, horizon + 0.5, mid)
		for i in 0 ..< VIEW_FOG_ROWS {
			y0 := horizon + f32(i) * step
			a1 := fog_at(w, y0 + step, mid)
			if prev > 0.002 || a1 > 0.002 {
				rl.DrawRectangleGradientV(
					0,
					i32(y0),
					i32(screen.x),
					i32(math.ceil(step)) + 1,
					rl.ColorAlpha(pal.horizon, prev),
					rl.ColorAlpha(pal.horizon, a1),
				)
			}
			prev = a1
		}
	}
	if horizon > 0 {
		fade := clamp(w.view_edit.sky_fade, 0.01, 1) * screen.y
		top := max(horizon - fade, 0)
		rl.DrawRectangle(0, 0, i32(screen.x), i32(top) + 1, pal.sky)
		t := clamp((horizon - top) / fade, 0, 1)
		rl.DrawRectangleGradientV(
			0,
			i32(top),
			i32(screen.x),
			i32(math.ceil(horizon - top)) + 1,
			lerp_color(pal.horizon, pal.sky, t),
			pal.horizon,
		)
	}
}

lerp_color :: proc(a, b: rl.Color, t: f32) -> rl.Color {
	fa := [4]f32{f32(a.r), f32(a.g), f32(a.b), f32(a.a)}
	fb := [4]f32{f32(b.r), f32(b.g), f32(b.b), f32(b.a)}
	c := linalg.lerp(fa, fb, t)
	return {u8(c.r), u8(c.g), u8(c.b), u8(c.a)}
}

// The View tab from y down, width wide; returns the y under it.
view_tab :: proc(w: ^World, x, y, width: f32, drag: ^int) -> f32 {
	e := &w.view_edit
	pal := palette(w)
	def := w.setting_defaults.view
	Row :: struct {
		label:  string,
		value:  ^f32,
		def:    f32,
		lo, hi: f32,
		format: string, // one value
	}
	rows := [?]Row {
		{"Steepest tilt", &e.max_tilt_deg, def.max_tilt_deg, 30, 88, "%.0f deg"},
		{"Fog starts", &e.fog_start, def.fog_start, 0.5, 6, "x %.2f"},
		{"Fog ends", &e.fog_end, def.fog_end, 0.6, 12, "x %.2f"},
		{"Fog strength", &e.fog_strength, def.fog_strength, 0, 1, "%.2f"},
		{"Sky gradient", &e.sky_fade, def.sky_fade, 0.01, 1, "%.2f"},
		{"Labels until", &e.label_end, def.label_end, 0.5, 12, "x %.2f"},
		{"Towers until", &e.hub_end, def.hub_end, 0.5, 12, "x %.2f"},
		{"P2P name size", &e.peer_name_px, def.peer_name_px, 8, 16, "%.0f px"},
	}

	y := y
	ui_text(w, {x, y}, "Distances in camera distances. Right drag tilts.", .Roboto_400, 13, pal.text_2)
	y += 26
	ui_text(w, {x, y}, "Rerouting banner", .Roboto_400, 13, pal.text)
	ui_toggle(w, {x + width - 36, y - 2, 36, 20}, &e.reroute_banner)
	y += 28
	ui_text(w, {x, y}, "P2P car names", .Roboto_400, 13, pal.text)
	ui_toggle(w, {x + width - 36, y - 2, 36, 20}, &e.peer_names)
	y += 32
	buf: [32]u8
	for row, i in rows {
		text := fmt.bprintf(buf[:], row.format, row.value^)
		ui_slider_row(w, x, y, width, row.label, text, row.value, row.lo, row.hi, row.def, drag, i + 1)
		y += UI_SLIDER_ROW_H
	}
	return y
}
