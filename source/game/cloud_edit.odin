package game

import "core:fmt"

// Cloud settings (nasr, 2026-11-22): the Clouds tab of the settings panel (settings.odin) has sliders for the clouds over the map (clouds.odin) and the solar
// layer's cloud shade on the ground (layers_draw_ground). Only the picture changes: the forecast cover
// (cloud_at), the routes and the solar energy stay as they are. The defaults are the constants, so untouched
// nothing changes. Nothing is saved.
Cloud_Edit :: struct {
	show:         bool,
	cover:        f32, // times the forecast cover, for the clouds drawn only
	size:         f32, // times the puff size
	cell_km:      f32, // one cloud spot per cell: smaller cells, more and closer clouds
	base_m:       f32,
	top_m:        f32,
	opacity:      f32, // 0 .. 1
	shadow:       f32, // alpha of the ground shadow, of 255
	drift:        f32, // times the wind the clouds drift with
	zoom_0:       f32, // clouds fade in from this camera zoom ..
	zoom_1:       f32, // .. and are full from this one
	ground_shade: f32, // alpha of the solar layer's shade under full cover, of 255
	ground_sun:   f32, // alpha of the solar layer's sunlit wash under a clear sky and the sun overhead, of 255
}

cloud_edit_defaults :: proc() -> Cloud_Edit {
	return {
		show = true,
		cover = 1,
		size = 1,
		cell_km = CLOUD_CELL_KM,
		base_m = CLOUD_BASE_M,
		top_m = CLOUD_TOP_M,
		opacity = CLOUD_OPACITY,
		shadow = CLOUD_SHADOW_ALPHA,
		drift = 1,
		zoom_0 = CLOUD_ZOOM_0,
		zoom_1 = CLOUD_ZOOM_1,
		ground_shade = SOLAR_SHADE_ALPHA,
		ground_sun = SOLAR_SUN_ALPHA,
	}
}

// The Clouds tab from y down, width wide; returns the y under it.
cloud_tab :: proc(w: ^World, x, y, width: f32, drag: ^int) -> f32 {
	e := &w.cloud_edit
	pal := palette(w)
	def := w.setting_defaults.clouds
	Row :: struct {
		label:  string,
		value:  ^f32,
		def:    f32,
		lo, hi: f32,
		format: string, // one value
	}
	rows := [?]Row {
		{"Cover", &e.cover, def.cover, 0, 3, "x %.2f"},
		{"Size", &e.size, def.size, 0.2, 3, "x %.2f"},
		{"Spacing", &e.cell_km, def.cell_km, 0.6, 5, "%.1f km"},
		{"Lowest", &e.base_m, def.base_m, 100, 3000, "%.0f m"},
		{"Highest", &e.top_m, def.top_m, 100, 3000, "%.0f m"},
		{"Opacity", &e.opacity, def.opacity, 0, 1, "%.2f"},
		{"Shadow", &e.shadow, def.shadow, 0, 150, "%.0f"},
		{"Drift with the wind", &e.drift, def.drift, 0, 10, "x %.1f"},
		{"Fade in from zoom", &e.zoom_0, def.zoom_0, ZOOM_MIN, ZOOM_MAX, "%.1f"},
		{"Full from zoom", &e.zoom_1, def.zoom_1, ZOOM_MIN, ZOOM_MAX, "%.1f"},
		{"Solar layer shade", &e.ground_shade, def.ground_shade, 0, 200, "%.0f"},
		{"Solar layer sunlight", &e.ground_sun, def.ground_sun, 0, 200, "%.0f"},
	}

	y := y
	ui_text(w, {x, y}, "Clouds", .Roboto_400, 13, pal.text)
	ui_toggle(w, {x + width - 36, y - 2, 36, 20}, &e.show)
	y += 32
	buf: [32]u8
	for row, i in rows {
		text := fmt.bprintf(buf[:], row.format, row.value^)
		ui_slider_row(w, x, y, width, row.label, text, row.value, row.lo, row.hi, row.def, drag, i + 1)
		y += UI_SLIDER_ROW_H
	}
	return y
}
