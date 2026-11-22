package game

import "core:fmt"
import "core:math"
import "core:math/linalg"
import rl "vendor:raylib"

// The street view's sky and sun (nasr, 2026-11-22): the Sky tab of the settings panel. Colors are picked in sRGB
// and reach the shaders in linear light the way STREET_GLSL converts (lin = squared sRGB). The defaults come
// from STREET_LOOK, so untouched the street view looks as before (the colors to within rounding to 8 bits).
// The sky's light on the car and the walls (amb_up, sky_amb) takes the tint of the sky, so an orange sky also
// lights the street orange.
Sky_Edit :: struct {
	zenith:       rl.Color, // sky straight up
	horizon:      rl.Color, // low sky, also the haze far things fade into
	curve:        f32, // gradient: lower keeps the zenith color further down to the horizon
	glow:         f32, // the bright band just above the horizon
	sun_color:    rl.Color,
	sun_strength: f32, // linear, the brightest channel of the sunlight
	sun_height:   f32, // degrees above the horizon
	sun_azimuth:  f32, // degrees from street +z (south) towards +x (east)
}

sky_edit_defaults :: proc() -> Sky_Edit {
	l := STREET_LOOK
	srgb :: proc(lin: [3]f32) -> rl.Color {
		c := [3]f32{math.sqrt(lin.r), math.sqrt(lin.g), math.sqrt(lin.b)} * 255
		return {u8(math.round(c.r)), u8(math.round(c.g)), u8(math.round(c.b)), 255}
	}
	strength := max(l.sun_col.r, l.sun_col.g, l.sun_col.b)
	return {
		zenith = srgb(l.sky_zen),
		horizon = srgb(l.sky_hor),
		curve = l.sky_curve,
		glow = l.sky_glow,
		sun_color = srgb(l.sun_col / strength),
		sun_strength = strength,
		sun_height = math.asin(l.sun_dir.y) * math.DEG_PER_RAD,
		sun_azimuth = math.atan2(l.sun_dir.x, l.sun_dir.z) * math.DEG_PER_RAD,
	}
}

// STREET_LOOK with the Sky tab's values: what every street view pass draws with.
street_look :: proc(w: ^World) -> Street_Look {
	look := STREET_LOOK
	e := &w.sky_edit
	lin :: proc(c: rl.Color) -> [3]f32 {
		v := [3]f32{f32(c.r), f32(c.g), f32(c.b)} / 255
		return v * v
	}
	look.sky_zen = lin(e.zenith)
	look.sky_hor = lin(e.horizon)
	look.sky_curve = max(e.curve, 0.01)
	look.sky_glow = e.glow
	tint := (look.sky_zen + look.sky_hor) / (STREET_LOOK.sky_zen + STREET_LOOK.sky_hor)
	look.amb_up *= tint
	look.sky_amb *= tint
	look.sun_col = lin(e.sun_color) * e.sun_strength
	height := clamp(e.sun_height, 1, 90) * math.RAD_PER_DEG
	azimuth := e.sun_azimuth * math.RAD_PER_DEG
	look.sun_dir = {
		math.cos(height) * math.sin(azimuth),
		math.sin(height),
		math.cos(height) * math.cos(azimuth),
	}
	return look
}

// Sky color in linear light along ray r (street space: +x east, +y up, +z south), matching STREET_GLSL sky_col.
sky_color_at :: proc(look: Street_Look, r: [3]f32, with_sun := true) -> [3]f32 {
	e := clamp(r.y, 0, 1)
	c := look.sky_hor + (look.sky_zen - look.sky_hor) * math.pow(e, look.sky_curve)
	c += look.sky_hor * look.sky_glow * math.pow(1 - e, 12)
	if with_sun {
		s := max(linalg.dot(r, look.sun_dir), 0)
		c += look.sun_col * (0.035 * math.pow(s, 4) + 0.1 * math.pow(s, 48))
	}
	return c
}

// Linear RGB to sRGB rl.Color, scaling down only when HDR channels exceed 1 so warm highlights keep their hue.
sky_srgb :: proc(c: [3]f32) -> rl.Color {
	peak := max(c.r, c.g, c.b, 1)
	v := linalg.max(c / peak, [3]f32{0, 0, 0})
	return {
		u8(math.round(math.sqrt(v.r) * 255)),
		u8(math.round(math.sqrt(v.g) * 255)),
		u8(math.round(math.sqrt(v.b) * 255)),
		255,
	}
}

// Street-space sun_dir turned into map space (x east, y south, z down).
map_sun_dir :: proc(look: Street_Look) -> [3]f32 {
	return {look.sun_dir.x, look.sun_dir.z, -look.sun_dir.y}
}

// Horizontal look direction of the map camera in map space (x east, y south).
map_cam_fwd_2d :: proc(w: ^World) -> [2]f32 {
	fwd := w.cam.view.target.xy - w.cam.view.position.xy
	if linalg.length(fwd) > 1e-4 do return linalg.normalize(fwd)
	return {math.sin(w.cam.pose.yaw), -math.cos(w.cam.pose.yaw)}
}

// Horizon color of the tilted 2D map in the camera's look direction, matching the street view's low sky.
map_horizon_color :: proc(w: ^World) -> rl.Color {
	look := street_look(w)
	h := map_cam_fwd_2d(w)
	r := linalg.normalize([3]f32{h.x, 0.03, h.y})
	return sky_srgb(sky_color_at(look, r))
}

// Warm sunlight and cool sky ambient tints in sRGB [0, 1] for 2D map geometry (buildings, trees, terrain).
map_sun_tints :: proc(w: ^World) -> (sun_tint, amb_tint: [3]f32) {
	e := &w.sky_edit
	sun_norm := [3]f32{f32(e.sun_color.r), f32(e.sun_color.g), f32(e.sun_color.b)} / 255
	sun_k := clamp(e.sun_strength / 2.2, 0, 1.3)
	zen := [3]f32{f32(e.zenith.r), f32(e.zenith.g), f32(e.zenith.b)} / 255
	hor := [3]f32{f32(e.horizon.r), f32(e.horizon.g), f32(e.horizon.b)} / 255
	sky_mix := linalg.lerp(zen, hor, 0.3)
	amb_tint = linalg.lerp([3]f32{0.58, 0.58, 0.58}, sky_mix * 1.15, 0.45)
	sun_tint = sun_norm * (0.42 * sun_k)
	return
}

// Terrain hillshade highlight and shadow tints in sRGB [0, 1] from w.sky_edit.
map_hill_tints :: proc(w: ^World) -> (sun_tint, shade_tint: [3]f32) {
	e := &w.sky_edit
	sun_norm := [3]f32{f32(e.sun_color.r), f32(e.sun_color.g), f32(e.sun_color.b)} / 255
	zen := [3]f32{f32(e.zenith.r), f32(e.zenith.g), f32(e.zenith.b)} / 255
	sun_tint = linalg.lerp([3]f32{1, 1, 1}, sun_norm, 0.85) * clamp(e.sun_strength / 2.0, 0.25, 1.15)
	shade_tint = linalg.lerp([3]f32{0.08, 0.10, 0.14}, zen * 0.45, 0.65)
	return
}

// The Sky tab from y down, width wide; returns the y under it.
sky_tab :: proc(w: ^World, x, y, width: f32, drag: ^int) -> f32 {
	e := &w.sky_edit
	pal := palette(w)
	def := w.setting_defaults.sky
	y := y
	id := 1

	// A preview of the gradient from the horizon (bottom) to the zenith (top), as sky_col draws it.
	{
		PREVIEW_H :: 72
		STRIPS :: 24
		look := street_look(w)
		for i in 0 ..< STRIPS {
			el := 1 - (f32(i) + 0.5) / STRIPS
			c := sky_color_at(look, {0, el, 0}, false)
			strip := rl.Rectangle{x, y + f32(i) * PREVIEW_H / STRIPS, width, PREVIEW_H / STRIPS + 1}
			rl.DrawRectangleRec(strip, sky_srgb(c))
		}
		round_rect_lines(w, {x, y, width, PREVIEW_H}, 6, 1, pal.line)
		y += PREVIEW_H + 14
	}

	// Three swatches, the chosen one (w.settings.sky_color) with R, G, B sliders under them.
	{
		colors := [3]^rl.Color{&e.zenith, &e.horizon, &e.sun_color}
		defs := [3]rl.Color{def.zenith, def.horizon, def.sun_color}
		names := [3]string{"Zenith", "Horizon", "Sunlight"}
		chosen := &w.settings.sky_color
		chosen^ = clamp(chosen^, 0, 2)
		cell := width / 3
		for c, i in colors {
			r := rl.Rectangle{x + f32(i) * cell + 3, y, cell - 6, 30}
			_, _, fired := ui_widget(w, r)
			if fired do chosen^ = i
			round_rect(w, r, 6, c^)
			round_rect_lines(w, r, 6, 1, pal.line)
			if i == chosen^ do round_rect_lines(w, {r.x - 2, r.y - 2, r.width + 4, r.height + 4}, 8, 2, pal.accent)
			if c^ != defs[i] do rl.DrawCircleV({r.x + r.width - 3, r.y + 3}, 4, pal.accent)
			ui_text(w, {r.x, r.y + 36}, names[i], .Roboto_400, 13, i == chosen^ ? pal.text : pal.text_2)
		}
		y += 62
		c, d := colors[chosen^], defs[chosen^]
		channels := [3]^u8{&c.r, &c.g, &c.b}
		channel_defs := [3]u8{d.r, d.g, d.b}
		channel_names := [3]string{"Red", "Green", "Blue"}
		for k in 0 ..< 3 {
			settings_channel(w, x, y, width, channel_names[k], channels[k], channel_defs[k], drag, id)
			id += 1
			y += UI_SLIDER_ROW_H
		}
	}

	Row :: struct {
		label:  string,
		value:  ^f32,
		def:    f32,
		lo, hi: f32,
		format: string, // one value
	}
	rows := [?]Row {
		{"Gradient curve", &e.curve, def.curve, 0.05, 3, "%.2f"},
		{"Horizon glow", &e.glow, def.glow, 0, 2, "%.2f"},
		{"Sun strength", &e.sun_strength, def.sun_strength, 0, 6, "%.2f"},
		{"Sun height", &e.sun_height, def.sun_height, 1, 90, "%.0f deg"},
		{"Sun direction", &e.sun_azimuth, def.sun_azimuth, -180, 180, "%.0f deg"},
	}
	buf: [32]u8
	for row in rows {
		text := fmt.bprintf(buf[:], row.format, row.value^)
		ui_slider_row(w, x, y, width, row.label, text, row.value, row.lo, row.hi, row.def, drag, id)
		id += 1
		y += UI_SLIDER_ROW_H
	}
	return y
}
