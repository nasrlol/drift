package game

import "core:fmt"
import "core:math"
import "core:reflect"
import "core:strings"
import rl "vendor:raylib"

// Settings panel (nasr, 2026-11-22): F2 opens one panel with a tab per group: Speed (tune.odin), Borders
// (border_edit.odin), Clouds (cloud_edit.odin), Wind (wind_edit.odin), Grass (grass_edit.odin), View (view_edit.odin), Sky (sky_edit.odin), and the look of the game here: Colors (every palette entry),
// Fonts (text size, line spacing and which family stands in for each of the design's three) and Style (corner
// radius and widget ornament design). Debug builds only (nasr: the release runs with the project's settings).
// The defaults are the code with assets/settings.txt on top (settings_store.odin); each tab's Reset goes back
// to them. Every change is saved to cache/settings.txt and loaded at the next start; Bake writes the values
// into assets/settings.txt, which ships once committed.
Settings_Tab :: enum {
	Speed,
	Borders,
	Clouds,
	Wind,
	Grass,
	View,
	Sky,
	Turbines,
	Towers,
	Solar,
	Rural,
	Towns,
	Colors,
	Fonts,
	Style,
}

Ornament :: enum u8 {
	None,
	Brass,
	Botanical,
	Sunburst,
}

Settings :: struct {
	open:       bool,
	tab:        int, // a Settings_Tab (ui_segment takes an int)
	drag:       int, // slider id being dragged, 0 = none
	color:      int, // the palette entry chosen in the Colors tab, index into the Palette fields
	sky_color:  int, // the color chosen in the Sky tab: zenith, horizon, sunlight
	deco_color: int, // the color chosen in the Style tab: trim, leaf
	height:     f32, // the panel's height last frame: the card is drawn before its tab knows its height
	text_scale: f32, // the text size the font atlases were made for (settings_apply)
	loaded:     bool, // cache/settings.txt was read (first frame of the panel)
	saved_sum:  u64, // hash of what cache/settings.txt holds
	save_err:   bool, // the last save failed
	last_town:  Town_Edit, // rebuilds town tiles when Town_Edit changes
}

// The design's font families plus additional bundled families. Font_Family_Of gives the family and weight of each Font.
Font_Family :: enum u8 {
	Figtree,
	Roboto,
	Mono,
	Space,
	Lora,
	JetBrains,
}

FONT_FAMILY_NAMES :: [Font_Family]string {
	.Figtree   = "Figtree",
	.Roboto    = "Roboto",
	.Mono      = "Roboto Mono",
	.Space     = "Space Grotesk",
	.Lora      = "Lora",
	.JetBrains = "JetBrains",
}

Look :: struct {
	palette:         Palette,
	text_scale:      f32, // times every text size of ui_text
	line_spacing:    f32, // line height of wrapped text, in text sizes
	family:          [Font_Family]Font_Family, // the family drawn where the design asks for this one
	radius_scale:    f32, // times every corner radius of round_rect
	ornament:        Ornament, // widget decoration design (Brass, Botanical, Sunburst)
	ornament_detail: f32, // trim thickness and flourish size
	ornament_color:  rl.Color, // brass/gold trim color
	leaf_color:      rl.Color, // botanical leaf motif color
	dial_ticks:      bool, // radial ticks on circular gauges and round buttons
	corner_brackets: bool, // corner flourishes on cards, sheets, and HUD boxes
}

SETTINGS_W :: 400
SETTINGS_TEXT_SCALE :: [2]f32{0.7, 1.6}
SETTINGS_LINE_SPACING :: [2]f32{1, 2.2}
SETTINGS_TEXT_STEP :: 0.05 // the text size snaps to this, so dragging makes few font atlases
SETTINGS_MAX_RADIUS_SCALE :: 2.5
SETTINGS_ORNAMENT_DETAIL :: [2]f32{0.3, 1.6}
SETTINGS_COLOR_COLS :: 10
SETTINGS_TAB_COLS :: 4 // tabs per row of the tab bar: eight in one row run their labels together
SETTINGS_PICKER_COLS :: 3 // themes and font families per row so labels never crowd

look_defaults :: proc() -> Look {
	return {
		palette = PALETTE,
		text_scale = 1,
		line_spacing = TEXT_LINE_SPACING,
		family = {
			.Figtree = .Figtree,
			.Roboto = .Roboto,
			.Mono = .Mono,
			.Space = .Space,
			.Lora = .Lora,
			.JetBrains = .JetBrains,
		},
		radius_scale = 1,
		ornament = .None,
		ornament_detail = 1,
		ornament_color = {200, 155, 62, 255},
		leaf_color = {62, 142, 90, 255},
		dial_ticks = true,
		corner_brackets = true,
	}
}

font_family_of :: proc(font: Font) -> (family: Font_Family, weight: int, italic: bool) {
	switch font {
	case .Figtree_500:
		return .Figtree, 500, false
	case .Figtree_600:
		return .Figtree, 600, false
	case .Figtree_700:
		return .Figtree, 700, false
	case .Figtree_800:
		return .Figtree, 800, false
	case .Figtree_Italic_400:
		return .Figtree, 400, true
	case .Roboto_400:
		return .Roboto, 400, false
	case .Roboto_500:
		return .Roboto, 500, false
	case .Roboto_700:
		return .Roboto, 700, false
	case .Mono_400:
		return .Mono, 400, false
	case .Mono_600:
		return .Mono, 600, false
	case .Space_400:
		return .Space, 400, false
	case .Space_500:
		return .Space, 500, false
	case .Space_700:
		return .Space, 700, false
	case .Lora_400:
		return .Lora, 400, false
	case .Lora_500:
		return .Lora, 500, false
	case .Lora_600:
		return .Lora, 600, false
	case .Lora_700:
		return .Lora, 700, false
	case .Lora_Italic_400:
		return .Lora, 400, true
	case .JetBrains_400:
		return .JetBrains, 400, false
	case .JetBrains_500:
		return .JetBrains, 500, false
	case .JetBrains_600:
		return .JetBrains, 600, false
	case .JetBrains_700:
		return .JetBrains, 700, false
	case .Icons:
	}
	return .Roboto, 400, false
}

// The font of family closest to weight, preferring an italic face when requested.
font_in :: proc(family: Font_Family, weight: int, italic: bool) -> Font {
	best := Font.Roboto_400
	best_d := max(int)
	if italic {
		for f in Font {
			if f == .Icons do continue
			fam, wt, ital := font_family_of(f)
			if fam == family && ital {
				if d := abs(wt - weight); d < best_d {
					best, best_d = f, d
				}
			}
		}
		if best_d < max(int) do return best
	}
	for f in Font {
		if f == .Icons do continue
		fam, wt, ital := font_family_of(f)
		if fam != family || ital do continue
		if d := abs(wt - weight); d < best_d {
			best, best_d = f, d
		}
	}
	return best
}

// The font drawn for font: the same weight in the family the settings put in its family's place.
font_remap :: proc(w: ^World, font: Font) -> Font {
	if font == .Icons do return font
	family, weight, italic := font_family_of(font)
	to := w.look.family[family]
	if to == family do return font
	return font_in(to, weight, italic)
}

// A design text size in px times the settings' text size.
text_px :: proc(w: ^World, px: f32) -> f32 {
	scale := w.settings.text_scale
	return scale > 0 ? px * scale : px
}

// The distance from one line of text to the next for a design text size: the text size times the line spacing.
text_line_px :: proc(w: ^World, px: f32) -> f32 {
	return text_px(w, px) * w.look.line_spacing
}

// Every frame before drawing: the palette from the settings, the font atlases dropped when the text size
// changed, the land use mesh rebuilt when its colors changed (its colors are baked per vertex).
settings_apply :: proc(w: ^World) {
	w.palette = w.look.palette
	step :: SETTINGS_TEXT_STEP
	scale := math.round(w.look.text_scale / step) * step
	if scale != w.settings.text_scale {
		fonts_unload(w)
		w.settings.text_scale = scale
	}
	lm := &w.line_meshes
	if lm.built && lm.areas.vertexCount > 0 && area_colors(&w.palette) != lm.area_colors {
		rl.UnloadMesh(lm.areas)
		lm.areas = {}
		areas_build(w, lm)
	}
	if w.settings.last_town != w.town_edit {
		w.settings.last_town = w.town_edit
		tiles_unload(&w.towns)
		tiles_unload(&w.street.houses)
		for &t in w.street.trees.tiles do t.used = false
	}
}

settings_reset :: proc(w: ^World, tab: Settings_Tab) {
	def := w.setting_defaults.look
	switch tab {
	case .Speed:
		w.tune = w.setting_defaults.tune
	case .Borders:
		w.border_edit = w.setting_defaults.borders
	case .Clouds:
		w.cloud_edit = w.setting_defaults.clouds
	case .Wind:
		w.wind_edit = w.setting_defaults.wind
	case .Grass:
		w.grass_edit = w.setting_defaults.grass
	case .View:
		w.view_edit = w.setting_defaults.view
	case .Sky:
		w.sky_edit = w.setting_defaults.sky
	case .Turbines:
		w.turbine_edit = w.setting_defaults.turbines
	case .Towers:
		w.tower_edit = w.setting_defaults.towers
	case .Solar:
		w.solar_edit = w.setting_defaults.solar
	case .Rural:
		w.rural_edit = w.setting_defaults.rural
	case .Towns:
		w.town_edit = w.setting_defaults.towns
	case .Colors:
		w.look.palette = def.palette
	case .Fonts:
		w.look.text_scale = def.text_scale
		w.look.line_spacing = def.line_spacing
		w.look.family = def.family
	case .Style:
		w.look.radius_scale = def.radius_scale
		w.look.ornament = def.ornament
		w.look.ornament_detail = def.ornament_detail
		w.look.ornament_color = def.ornament_color
		w.look.leaf_color = def.leaf_color
		w.look.dial_ticks = def.dial_ticks
		w.look.corner_brackets = def.corner_brackets
	}
}

// The local file: loaded on the first frame (so never in headless runs), saved when the values changed and no
// slider is held (one write per change). A scripted run neither loads nor saves it.
settings_keep :: proc(w: ^World) {
	s := &w.settings
	if w.script.on do return
	if !s.loaded {
		s.loaded = true
		if n := settings_load_local(w); n > 0 do logf(w, "settings", "%d values from %s", n, SETTINGS_LOCAL_PATH)
		_, s.saved_sum = settings_local_text(w)
	}
	if rl.IsMouseButtonDown(.LEFT) do return
	text, sum := settings_local_text(w)
	if sum == s.saved_sum do return
	s.save_err = !settings_save_local(w, text)
	if !s.save_err do s.saved_sum = sum
}

settings_ui :: proc(w: ^World) {
	s := &w.settings
	settings_keep(w)
	if key_pressed(w, .F2) {
		s.open = !s.open
		if w.street.on && !w.script.on {
			if s.open do rl.EnableCursor()
			else do rl.DisableCursor()
		}
	}
	if !s.open do return
	pal := palette(w)
	if !rl.IsMouseButtonDown(.LEFT) do s.drag = 0

	sw := f32(rl.GetScreenWidth())
	def_x := max(sw - 16 - 80 - SETTINGS_W, 16)
	if w.screen == .Plan && w.ui.plan_side == .Right {
		def_x = min(f32(16 + 80), max(sw - SETTINGS_W - 16, 16))
	}
	def_rect := rl.Rectangle{def_x, 80, SETTINGS_W, max(s.height, 200)}
	panel := ui_window_begin(w, .Settings, def_rect, 46)
	ui_card(w, panel)
	handle_hot := rl.CheckCollisionPointRec(rl.GetMousePosition(), {panel.x, panel.y, panel.width, 46})
	ui_draw_grip(w, panel, w.ui.drag_win == .Settings || handle_hot)
	x := panel.x + 16
	inner := panel.width - 32
	ui_text(w, {x, panel.y + 16}, "Settings", .Figtree_600, 16, pal.text)
	ui_text(w, {panel.x + panel.width - 16 - 22, panel.y + 18}, "F2", .Mono_400, 12, pal.text_2)

	names: [len(Settings_Tab)]string
	for t in Settings_Tab do names[int(t)] = fmt.tprint(t)
	y := panel.y + 48
	tab_sel := s.tab
	if settings_segment_grid(w, x, &y, inner, 34, 6, SETTINGS_TAB_COLS, names[:], &tab_sel) {
		s.tab = tab_sel
		s.drag = 0
	}
	tab := Settings_Tab(clamp(s.tab, 0, len(Settings_Tab) - 1))

	y += 14
	switch tab {
	case .Speed:
		y = tune_tab(w, x, y, inner, &s.drag)
	case .Borders:
		y = border_tab(w, x, y, inner, &s.drag)
	case .Clouds:
		y = cloud_tab(w, x, y, inner, &s.drag)
	case .Wind:
		y = wind_tab(w, x, y, inner, &s.drag)
	case .Grass:
		y = grass_tab(w, x, y, inner, &s.drag)
	case .View:
		y = view_tab(w, x, y, inner, &s.drag)
	case .Sky:
		y = sky_tab(w, x, y, inner, &s.drag)
	case .Turbines:
		y = turbine_tab(w, x, y, inner, &s.drag)
	case .Towers:
		y = tower_tab(w, x, y, inner, &s.drag)
	case .Solar:
		y = solar_tab(w, x, y, inner, &s.drag)
	case .Rural:
		y = rural_tab(w, x, y, inner, &s.drag)
	case .Towns:
		y = town_tab(w, x, y, inner, &s.drag)
	case .Colors:
		y = colors_tab(w, x, y, inner, &s.drag)
	case .Fonts:
		y = fonts_tab(w, x, y, inner, &s.drag)
	case .Style:
		y = style_tab(w, x, y, inner, &s.drag)
	}

	name := names[int(tab)]
	label := fmt.tprintf("Reset %s", strings.to_lower(name, context.temp_allocator))
	half := (inner - 10) / 2
	if ui_pill_button(w, {x, y + 8, half, 40}, label, .Secondary) {
		settings_reset(w, tab)
		ui_toast(w, fmt.tprintf("%s back to the defaults", name))
	}
	// Bake: the current values into assets/settings.txt, every tab at once.
	if ui_pill_button(w, {x + half + 10, y + 8, half, 40}, "Bake into build", .Primary) {
		if settings_bake(w) {
			ui_toast(w, "assets/settings.txt written: commit it to ship")
		} else {
			ui_toast(w, "Cannot write assets/settings.txt (run from the repo root)")
		}
	}
	y += 8 + 40 + 12
	status := "Saved to cache/settings.txt"
	if w.script.on do status = "Scripted run: nothing is saved"
	if s.save_err do status = "Cannot save cache/settings.txt"
	ui_text(w, {x, y}, status, .Roboto_400, 11, s.save_err ? pal.warning : pal.text_2)
	s.height = y + 14 + 16 - panel.y
	ui_window_end(w, s.drag == 0)
}

// Wraps a segmented bar into rows of at most cols items, updating chosen on selection and advancing y.
settings_segment_grid :: proc(
	w: ^World,
	x: f32,
	y: ^f32,
	width, row_h, gap: f32,
	cols: int,
	names: []string,
	chosen: ^int,
) -> bool {
	changed := false
	for first := 0; first < len(names); first += cols {
		row := names[first:min(first + cols, len(names))]
		sel := chosen^ - first if chosen^ >= first && chosen^ < first + len(row) else -1
		if ui_segment(w, {x, y^, width, row_h}, row, &sel) {
			chosen^ = first + sel
			changed = true
		}
		y^ += row_h + gap
	}
	return changed
}

// A slider for a u8 channel: value as f32 while dragging, written back rounded.
settings_channel :: proc(w: ^World, x, y, width: f32, label: string, c: ^u8, def: u8, drag: ^int, id: int) {
	v := f32(c^)
	ui_slider_row(w, x, y, width, label, fmt.tprintf("%d", c^), &v, 0, 255, f32(def), drag, id)
	c^ = u8(clamp(math.round(v), 0, 255))
}

// Every palette entry as a swatch (Palette field order: the UI, the map, labels and markers, wind), the chosen
// one with R, G, B sliders under them. A changed entry has an accent dot.
colors_tab :: proc(w: ^World, x, y, width: f32, drag: ^int) -> f32 {
	s := &w.settings
	pal := palette(w)
	def := w.setting_defaults.look.palette
	fields := reflect.struct_fields_zipped(Palette)
	color_at :: proc(p: ^Palette, offset: uintptr) -> ^rl.Color {
		return (^rl.Color)(uintptr(p) + offset)
	}
	s.color = clamp(s.color, 0, len(fields) - 1)

	// Themes (themes.odin): the one the palette matches is chosen, none once a color was changed by hand.
	y := y
	ui_text(w, {x, y}, "Theme", .Roboto_400, 13, pal.text)
	y += 22
	themes: [len(Theme)]string
	chosen := -1
	for t in Theme {
		themes[int(t)] = fmt.tprint(t)
		if theme_palette(t) == w.look.palette do chosen = int(t)
	}
	if settings_segment_grid(w, x, &y, width, 32, 6, SETTINGS_PICKER_COLS, themes[:], &chosen) {
		w.look.palette = theme_palette(Theme(chosen))
	}
	y += 8

	cell := width / SETTINGS_COLOR_COLS
	for f, i in fields {
		r := rl.Rectangle {
			x + f32(i % SETTINGS_COLOR_COLS) * cell + 3,
			y + f32(i / SETTINGS_COLOR_COLS) * cell + 3,
			cell - 6,
			cell - 6,
		}
		c := color_at(&w.look.palette, f.offset)
		_, _, fired := ui_widget(w, r)
		if fired do s.color = i
		round_rect(w, r, 6, c^)
		round_rect_lines(w, r, 6, 1, pal.line)
		if i == s.color do round_rect_lines(w, {r.x - 2, r.y - 2, r.width + 4, r.height + 4}, 8, 2, pal.accent)
		if c^ != color_at(&def, f.offset)^ do rl.DrawCircleV({r.x + r.width - 3, r.y + 3}, 4, pal.accent)
	}
	rows := (len(fields) + SETTINGS_COLOR_COLS - 1) / SETTINGS_COLOR_COLS
	y += f32(rows) * cell + 12

	f := fields[s.color]
	c := color_at(&w.look.palette, f.offset)
	d := color_at(&def, f.offset)^
	name, _ := strings.replace_all(f.name, "_", " ", context.temp_allocator)
	ui_text(w, {x, y}, name, .Roboto_500, 14, pal.text)
	hex := fmt.tprintf("#%02X%02X%02X", c.r, c.g, c.b)
	size := ui_text_size(w, hex, .Mono_400, 12)
	ui_text(w, {x + width - size.x, y + 2}, hex, .Mono_400, 12, c^ != d ? pal.accent : pal.text_2)
	y += 30
	settings_channel(w, x, y, width, "Red", &c.r, d.r, drag, 1)
	settings_channel(w, x, y + UI_SLIDER_ROW_H, width, "Green", &c.g, d.g, drag, 2)
	settings_channel(w, x, y + 2 * UI_SLIDER_ROW_H, width, "Blue", &c.b, d.b, drag, 3)
	return y + 3 * UI_SLIDER_ROW_H
}

// Text size, line spacing with a wrapped sample, and per design family the family drawn in its place, each with a sample line in it.
fonts_tab :: proc(w: ^World, x, y, width: f32, drag: ^int) -> f32 {
	pal := palette(w)
	look := &w.look
	def := w.setting_defaults.look
	y := y
	scale := w.settings.text_scale
	ui_slider_row(
		w,
		x,
		y,
		width,
		"Text size",
		fmt.tprintf("x %.2f", scale),
		&look.text_scale,
		SETTINGS_TEXT_SCALE.x,
		SETTINGS_TEXT_SCALE.y,
		def.text_scale,
		drag,
		1,
	)
	y += UI_SLIDER_ROW_H
	ui_slider_row(
		w,
		x,
		y,
		width,
		"Line spacing",
		fmt.tprintf("x %.2f", look.line_spacing),
		&look.line_spacing,
		SETTINGS_LINE_SPACING.x,
		SETTINGS_LINE_SPACING.y,
		def.line_spacing,
		drag,
		2,
	)
	y += UI_SLIDER_ROW_H + 4
	sample := "Wind from the south west at 7 m/s along the route, calmer higher up (4 m/s at 900 m)."
	sample_h := 3 * text_line_px(w, 13)
	ui_text_wrapped(w, {x, y, width, sample_h}, sample, .Roboto_400, 13, pal.text_2)
	y += sample_h + 12

	Row :: struct {
		family: Font_Family,
		label:  string,
		sample: Font,
		text:   string,
	}
	rows := [?]Row {
		{.Figtree, "Headings (Figtree)", .Figtree_600, "Choose a destination"},
		{.Roboto, "Body (Roboto)", .Roboto_400, "or click a docking tower on the map."},
		{.Mono, "Numbers (Roboto Mono)", .Mono_400, "128 km/h  12.5 kWh"},
	}
	fam_names := FONT_FAMILY_NAMES
	families: [len(Font_Family)]string
	for fam in Font_Family do families[int(fam)] = fam_names[fam]
	for row in rows {
		ui_text(w, {x, y}, row.label, .Roboto_400, 13, pal.text)
		y += 22
		sel := int(look.family[row.family])
		if settings_segment_grid(w, x, &y, width, 32, 6, SETTINGS_PICKER_COLS, families[:], &sel) {
			look.family[row.family] = Font_Family(sel)
		}
		y += 2
		ui_text(w, {x, y}, row.text, row.sample, 15, pal.text_2)
		y += text_px(w, 15) + 16
	}
	return y
}

// Corner roundness and widget ornamentation (Brass, Botanical, Sunburst): geometry, toggles, trim/leaf colors,
// and live shape samples.
style_tab :: proc(w: ^World, x, y, width: f32, drag: ^int) -> f32 {
	s := &w.settings
	pal := palette(w)
	look := &w.look
	def := w.setting_defaults.look
	y := y

	ui_text(w, {x, y}, "Decoration", .Roboto_400, 13, pal.text)
	y += 22
	styles: [len(Ornament)]string
	for o in Ornament do styles[int(o)] = fmt.tprint(o)
	sel := int(look.ornament)
	if ui_segment(w, {x, y, width, 32}, styles[:], &sel) do look.ornament = Ornament(sel)
	y += 42

	ui_slider_row(
		w,
		x,
		y,
		width,
		"Detail",
		fmt.tprintf("x %.2f", look.ornament_detail),
		&look.ornament_detail,
		SETTINGS_ORNAMENT_DETAIL.x,
		SETTINGS_ORNAMENT_DETAIL.y,
		def.ornament_detail,
		drag,
		2,
	)
	y += UI_SLIDER_ROW_H

	Toggle_Row :: struct {
		label: string,
		val:   ^bool,
	}
	toggles := [?]Toggle_Row{{"Dial ticks", &look.dial_ticks}, {"Corner motifs", &look.corner_brackets}}
	for row in toggles {
		ui_text(w, {x, y + 3}, row.label, .Roboto_400, 13, pal.text)
		ui_toggle(w, {x + width - 36, y + 2, 36, 20}, row.val)
		y += 28
	}
	y += 6

	swatches := [?]^rl.Color{&look.ornament_color, &look.leaf_color}
	def_swatches := [?]rl.Color{def.ornament_color, def.leaf_color}
	swatch_names := [?]string{"Trim brass", "Leaf green"}
	s.deco_color = clamp(s.deco_color, 0, len(swatches) - 1)
	cell := (width - 8) / 2
	for i in 0 ..< len(swatches) {
		r := rl.Rectangle{x + f32(i) * (cell + 8), y, cell, 32}
		id, hot, fired := ui_widget(w, r)
		if fired do s.deco_color = i
		round_rect(w, r, 8, hot ? pal.surface_3 : pal.surface_2)
		round_rect(w, {r.x + 8, r.y + 7, 18, 18}, 5, swatches[i]^)
		ui_text(w, {r.x + 32, r.y + 9}, swatch_names[i], .Roboto_400, 12, pal.text)
		if i == s.deco_color do round_rect_lines(w, r, 8, 2, pal.accent)
		ui_focus_ring(w, id, r, 8)
	}
	y += 40
	cc := swatches[s.deco_color]
	dc := def_swatches[s.deco_color]
	settings_channel(w, x, y, width, "Red", &cc.r, dc.r, drag, 3)
	settings_channel(w, x, y + UI_SLIDER_ROW_H, width, "Green", &cc.g, dc.g, drag, 4)
	settings_channel(w, x, y + 2 * UI_SLIDER_ROW_H, width, "Blue", &cc.b, dc.b, drag, 5)
	y += 3 * UI_SLIDER_ROW_H + 4

	ui_slider_row(
		w,
		x,
		y,
		width,
		"Corner radius",
		fmt.tprintf("x %.2f", look.radius_scale),
		&look.radius_scale,
		0,
		SETTINGS_MAX_RADIUS_SCALE,
		def.radius_scale,
		drag,
		1,
	)
	y += UI_SLIDER_ROW_H + 8
	Sample :: struct {
		label:  string,
		radius: f32,
	}
	samples := [?]Sample{{"List 12", 12}, {"Card 18", 18}, {"Button 24", 24}, {"Pill", 100}}
	gap :: 10
	side := (width - gap * f32(len(samples) - 1)) / f32(len(samples))
	for sample, i in samples {
		r := rl.Rectangle{x + f32(i) * (side + gap), y, side, 56}
		round_rect(w, r, sample.radius, pal.surface_2)
		round_rect_lines(w, r, sample.radius, 1, pal.line)
		ui_decorate_rect(w, r, sample.radius)
		size := ui_text_size(w, sample.label, .Roboto_400, 11)
		ui_text(
			w,
			{r.x + (r.width - size.x) / 2, r.y + r.height + 6},
			sample.label,
			.Roboto_400,
			11,
			pal.text_2,
		)
	}
	return y + 56 + 26
}
