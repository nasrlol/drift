package game

import "core:fmt"
import "core:math"
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
			c := look.sky_hor + (look.sky_zen - look.sky_hor) * math.pow(el, look.sky_curve)
			c += look.sky_hor * look.sky_glow * math.pow(1 - el, 12)
			s := [3]f32{math.sqrt(min(c.r, 1)), math.sqrt(min(c.g, 1)), math.sqrt(min(c.b, 1))} * 255
			strip := rl.Rectangle{x, y + f32(i) * PREVIEW_H / STRIPS, width, PREVIEW_H / STRIPS + 1}
			rl.DrawRectangleRec(strip, {u8(s.r), u8(s.g), u8(s.b), 255})
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
