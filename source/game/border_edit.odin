package game

import "core:fmt"

// Border settings (nasr, 2026-11-22): the Borders tab of the settings panel (settings.odin) shows every kind of border line the map draws, each with its own switch
// and width, to see which line comes from where. Belgium's border from belgium.bin is solid on land and dashed
// round the territorial sea; the countries and coastlines of world.bin come from the globe (globe.odin). The
// Borders switch of the layers panel still hides Belgium's border on top of this. Nothing is saved: a restart
// or Reset is the default again (BORDER_DEFAULT_PX).
Border_Set :: enum {
	Belgium_Land,
	Belgium_Sea,
	Countries,
	Coastlines,
}

Border_Edit :: struct {
	show:     [Border_Set]bool,
	width:    [Border_Set]f32, // px on the screen
	dash_on:  f32, // px, the sea border's dashes and gaps
	dash_off: f32,
}

// Widths picked in the settings (nasr, 2026-11-22): thin lines, Belgium's land border strongest, the
// coastlines off (the water fill already shows the coast).
BORDER_DEFAULT_PX :: [Border_Set]f32 {
	.Belgium_Land = 0.8,
	.Belgium_Sea  = 0.3,
	.Countries    = 0.6,
	.Coastlines   = 0.0,
}

BORDER_EDIT_ROW_H :: 88
BORDER_EDIT_MAX_PX :: 8.0
BORDER_EDIT_MAX_DASH_PX :: 30.0

border_edit_defaults :: proc() -> Border_Edit {
	b := Border_Edit {
		dash_on  = LINE_DASH_ON_PX,
		dash_off = LINE_DASH_OFF_PX,
	}
	b.width = BORDER_DEFAULT_PX
	for set in Border_Set do b.show[set] = true
	return b
}

// Whether the Borders switch of the layers panel hides this set.
border_layer_hides :: proc(set: Border_Set) -> bool {
	return set == .Belgium_Land || set == .Belgium_Sea
}

// The width a set is drawn at this frame (px), 0 = not drawn.
border_width :: proc(w: ^World, set: Border_Set) -> f32 {
	b := &w.border_edit
	if !b.show[set] do return 0
	if border_layer_hides(set) && w.plan.layers.hide_borders do return 0
	return b.width[set]
}

border_segments :: proc(w: ^World, set: Border_Set) -> int {
	switch set {
	case .Belgium_Land:
		return w.line_meshes.border_land
	case .Belgium_Sea:
		return w.line_meshes.border_sea
	case .Countries:
		return w.globe.segments[.Country_Border]
	case .Coastlines:
		return w.globe.segments[.Coastline]
	}
	return 0
}

// The Borders tab from y down, width wide; returns the y under it.
border_tab :: proc(w: ^World, x, y, width: f32, drag: ^int) -> f32 {
	b := &w.border_edit
	pal := palette(w)
	def := w.setting_defaults.borders
	Row :: struct {
		label, source: string,
	}
	rows := [Border_Set]Row {
		.Belgium_Land = {"Belgium, land", "belgium.bin (OSM), solid"},
		.Belgium_Sea  = {"Belgium, territorial sea", "belgium.bin (OSM), dashed"},
		.Countries    = {"Countries", "world.bin (Natural Earth 1:50m)"},
		.Coastlines   = {"Coastlines", "world.bin (Natural Earth 1:50m)"},
	}

	inner := width
	buf: [64]u8
	y := y
	for row, set in rows {
		ui_text(w, {x, y}, row.label, .Roboto_400, 13, pal.text)
		ui_toggle(w, {x + width - 36, y - 2, 36, 20}, &b.show[set])
		hidden := border_layer_hides(set) && w.plan.layers.hide_borders
		note :=
			hidden ? "hidden by the Borders layer" : border_layer_hides(set) ? "Borders layer hides it" : "Borders layer ignores it"
		info := fmt.bprintf(buf[:], "%s, %d segments", row.source, border_segments(w, set))
		ui_text(w, {x, y + 20}, info, .Roboto_400, 11, pal.text_2)
		ui_text(w, {x, y + 34}, note, .Roboto_400, 11, hidden ? pal.warning : pal.text_2)

		text := fmt.bprintf(buf[:], "%.1f px", b.width[set])
		size := ui_text_size(w, text, .Mono_400, 12)
		ui_slider(
			w,
			{x, y + 62, inner - size.x - 12, 4},
			&b.width[set],
			0,
			BORDER_EDIT_MAX_PX,
			def.width[set],
			drag,
			int(set) + 1,
		)
		changed := abs(b.width[set] - def.width[set]) > 1e-4
		ui_text(w, {x + inner - size.x, y + 55}, text, .Mono_400, 12, changed ? pal.accent : pal.text_2)
		y += BORDER_EDIT_ROW_H
	}

	Dash_Row :: struct {
		label: string,
		value: ^f32,
		def:   f32,
	}
	dash_rows := [?]Dash_Row {
		{"Sea border dash", &b.dash_on, def.dash_on},
		{"Sea border gap", &b.dash_off, def.dash_off},
	}
	for row, i in dash_rows {
		text := fmt.bprintf(buf[:], "%.0f px", row.value^)
		id := len(Border_Set) + 1 + i
		ui_slider_row(
			w,
			x,
			y,
			inner,
			row.label,
			text,
			row.value,
			1,
			BORDER_EDIT_MAX_DASH_PX,
			row.def,
			drag,
			id,
		)
		y += UI_SLIDER_ROW_H
	}
	return y
}
