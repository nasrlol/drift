package game

import "core:fmt"

// Wind line settings (nasr, 2026-11-22): the Wind tab of the settings panel (settings.odin) has sliders for the
// wind particles over the map (game.odin, the wind layer). Only the picture changes: the forecast wind, the
// routes and the energy stay as they are. The defaults are the constants, so untouched nothing changes.
Wind_Edit :: struct {
	count:        f32, // particles drawn, at most WIND_PARTICLES
	life_s:       f32,
	px_per_ms:    f32, // screen speed per m/s of wind
	trail_s:      f32, // trail length = the distance covered in this time
	width_px:     f32,
	calm_ms:      f32, // slower particles are not drawn
	opacity_plan: f32, // 0 .. 1, on the plan screen
	opacity_nav:  f32, // 0 .. 1, while flying
}

wind_edit_defaults :: proc() -> Wind_Edit {
	return {
		count = WIND_PARTICLES,
		life_s = WIND_LIFE_S,
		px_per_ms = WIND_PX_PER_MS,
		trail_s = WIND_TRAIL_S,
		width_px = WIND_WIDTH_PX,
		calm_ms = WIND_CALM_MS,
		opacity_plan = WIND_OPACITY_PLAN,
		opacity_nav = WIND_OPACITY_NAV,
	}
}

// The Wind tab from y down, width wide; returns the y under it.
wind_tab :: proc(w: ^World, x, y, width: f32, drag: ^int) -> f32 {
	e := &w.wind_edit
	def := w.setting_defaults.wind
	Row :: struct {
		label:  string,
		value:  ^f32,
		def:    f32,
		lo, hi: f32,
		format: string, // one value
	}
	rows := [?]Row {
		{"Lines", &e.count, def.count, 0, WIND_PARTICLES, "%.0f"},
		{"Life", &e.life_s, def.life_s, 0.5, 10, "%.1f s"},
		{"Speed", &e.px_per_ms, def.px_per_ms, 0.5, 15, "%.1f px/s per m/s"},
		{"Trail length", &e.trail_s, def.trail_s, 0.1, 3, "%.2f s"},
		{"Width", &e.width_px, def.width_px, 0.5, 6, "%.1f px"},
		{"Hide below", &e.calm_ms, def.calm_ms, 0, 10, "%.1f m/s"},
		{"Opacity, plan", &e.opacity_plan, def.opacity_plan, 0, 1, "%.2f"},
		{"Opacity, flying", &e.opacity_nav, def.opacity_nav, 0, 1, "%.2f"},
	}

	y := y
	buf: [32]u8
	for row, i in rows {
		text := fmt.bprintf(buf[:], row.format, row.value^)
		ui_slider_row(w, x, y, width, row.label, text, row.value, row.lo, row.hi, row.def, drag, i + 1)
		y += UI_SLIDER_ROW_H
	}
	return y
}
