package game

import "core:fmt"
import rl "vendor:raylib"

// Grass settings (nasr, 2026-11-22): the Grass tab of the settings panel (settings.odin) has sliders for the
// Perlin noise of the open grass in the street view (grass() in STREET_GROUND_FS). Only the picture changes.
// Sizes snap in the shader so the noise still tiles (grass_f).
GRASS_PATCH_M :: 64.0
GRASS_TUFT_M :: 8.0
GRASS_CLUMP_M :: 1.0
GRASS_WORN_M :: 32.0
GRASS_DRY :: 0.7
GRASS_TUFTS :: 0.45
GRASS_CLUMPS :: 0.3
GRASS_WORN :: 0.55
GRASS_OLIVE :: 0.3
GRASS_WORN_FROM :: 0.32

Grass_Edit :: struct {
	patch_m:   f32, // lush and dry patches
	tuft_m:    f32,
	clump_m:   f32,
	worn_m:    f32, // worn spots of bare earth
	dry:       f32, // how far dry patches go to straw, 0 .. 1
	tufts:     f32, // brightness swing of the tufts
	clumps:    f32,
	worn:      f32, // how bare a worn spot gets, 0 .. 1
	olive:     f32, // 0 paint green .. 1 yellow-grey
	worn_from: f32, // noise level where worn spots start: lower, more of them
}

grass_edit_defaults :: proc() -> Grass_Edit {
	return {
		patch_m = GRASS_PATCH_M,
		tuft_m = GRASS_TUFT_M,
		clump_m = GRASS_CLUMP_M,
		worn_m = GRASS_WORN_M,
		dry = GRASS_DRY,
		tufts = GRASS_TUFTS,
		clumps = GRASS_CLUMPS,
		worn = GRASS_WORN,
		olive = GRASS_OLIVE,
		worn_from = GRASS_WORN_FROM,
	}
}

// The grass uniforms of the ground shader.
grass_set :: proc(w: ^World, sh: rl.Shader) {
	e := &w.grass_edit
	l := &w.street.loc
	size := [4]f32{e.patch_m, e.tuft_m, e.clump_m, e.worn_m}
	amt := [4]f32{e.dry, e.tufts, e.clumps, e.worn}
	tone := [2]f32{e.olive, e.worn_from}
	rl.SetShaderValue(sh, l.grass_size, &size, .VEC4)
	rl.SetShaderValue(sh, l.grass_amt, &amt, .VEC4)
	rl.SetShaderValue(sh, l.grass_tone, &tone, .VEC2)
}

// The Grass tab from y down, width wide; returns the y under it.
grass_tab :: proc(w: ^World, x, y, width: f32, drag: ^int) -> f32 {
	e := &w.grass_edit
	pal := palette(w)
	def := w.setting_defaults.grass
	Row :: struct {
		label:  string,
		value:  ^f32,
		def:    f32,
		lo, hi: f32,
		format: string, // one value
	}
	rows := [?]Row {
		{"Patch size", &e.patch_m, def.patch_m, 8, 256, "%.0f m"},
		{"Dry patches", &e.dry, def.dry, 0, 1, "%.2f"},
		{"Tuft size", &e.tuft_m, def.tuft_m, 1, 32, "%.1f m"},
		{"Tufts", &e.tufts, def.tufts, 0, 1.5, "%.2f"},
		{"Clump size", &e.clump_m, def.clump_m, 0.25, 8, "%.2f m"},
		{"Clumps", &e.clumps, def.clumps, 0, 1.5, "%.2f"},
		{"Worn spot size", &e.worn_m, def.worn_m, 4, 128, "%.0f m"},
		{"Worn spots from", &e.worn_from, def.worn_from, -0.2, 0.8, "%.2f"},
		{"Worn spots bare", &e.worn, def.worn, 0, 1, "%.2f"},
		{"Olive", &e.olive, def.olive, 0, 1, "%.2f"},
	}

	y := y
	if !w.street.on {
		ui_text(w, {x, y}, "Zoom in to the car (street view) to see the grass.", .Roboto_400, 13, pal.text_2)
		y += 26
	}
	buf: [32]u8
	for row, i in rows {
		text := fmt.bprintf(buf[:], row.format, row.value^)
		ui_slider_row(w, x, y, width, row.label, text, row.value, row.lo, row.hi, row.def, drag, i + 1)
		y += UI_SLIDER_ROW_H
	}
	return y
}
