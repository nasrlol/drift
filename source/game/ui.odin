// author: nasr
package game

import "core:strings"
import rl "vendor:raylib"

// Fonts of the design ("Typografie"): Figtree for what is read at a glance, Roboto for running text, Roboto
// Mono for values that change live. Static TTFs, unchanged, licenses next to them in assets/fonts (sources and
// sha256 in notes.txt). Roboto Mono has no static SemiBold, so Mono_600 is the Bold file.
Font :: enum u8 {
	Figtree_500,
	Figtree_600,
	Figtree_700,
	Figtree_800,
	Figtree_Italic_400, // water names
	Roboto_400,
	Roboto_500,
	Roboto_700,
	Mono_400,
	Mono_600,
}

// Embedded file of each font. A switch, not a table: the game package has no globals.
font_file :: proc(font: Font) -> []u8 {
	switch font {
	case .Figtree_500:
		return #load("../../assets/fonts/Figtree-Medium.ttf")
	case .Figtree_600:
		return #load("../../assets/fonts/Figtree-SemiBold.ttf")
	case .Figtree_700:
		return #load("../../assets/fonts/Figtree-Bold.ttf")
	case .Figtree_800:
		return #load("../../assets/fonts/Figtree-ExtraBold.ttf")
	case .Figtree_Italic_400:
		return #load("../../assets/fonts/Figtree-Italic.ttf")
	case .Roboto_400:
		return #load("../../assets/fonts/Roboto-Regular.ttf")
	case .Roboto_500:
		return #load("../../assets/fonts/Roboto-Medium.ttf")
	case .Roboto_700:
		return #load("../../assets/fonts/Roboto-Bold.ttf")
	case .Mono_400:
		return #load("../../assets/fonts/RobotoMono-Regular.ttf")
	case .Mono_600:
		return #load("../../assets/fonts/RobotoMono-Bold.ttf")
	}
	return nil
}

// Codepoints 32..255: ASCII and Latin-1 (Liege with e grave, the copyright sign).
FONT_FIRST :: 32
FONT_COUNT :: 256 - FONT_FIRST
MAX_FONT_SLOTS :: 64 // (font, px) pairs; the design uses about 30

// Every (font, px) pair is rasterized the first time it is drawn, at exactly that size, so text stays pixel
// sharp. The atlases are raylib memory and GPU textures, they survive a hot reload. Never used in headless.
Font_Slot :: struct {
	font:   Font,
	px:     i32,
	loaded: rl.Font,
}

Fonts :: struct {
	slots: [MAX_FONT_SLOTS]Font_Slot,
	count: int,
}

font_get :: proc(w: ^World, font: Font, px: f32) -> rl.Font {
	size := i32(px + 0.5)
	f := &w.fonts
	for &s in f.slots[:f.count] {
		if s.font == font && s.px == size do return s.loaded
	}
	if f.count == MAX_FONT_SLOTS {
		logf(w, "ui", "more than %d font sizes, %v %d px uses the raylib font", MAX_FONT_SLOTS, font, size)
		return rl.GetFontDefault()
	}
	codepoints: [FONT_COUNT]rune
	for &c, i in codepoints do c = rune(FONT_FIRST + i)
	data := font_file(font)
	loaded := rl.LoadFontFromMemory(
		".ttf",
		raw_data(data),
		i32(len(data)),
		size,
		raw_data(codepoints[:]),
		FONT_COUNT,
	)
	if loaded.texture.id == 0 {
		logf(
			w,
			"ui",
			"cannot load %v (%d bytes embedded) at %d px, using the raylib font",
			font,
			len(data),
			size,
		)
		loaded = rl.GetFontDefault()
	}
	f.slots[f.count] = {font, size, loaded}
	f.count += 1
	return loaded
}

// Unloads every atlas this game made, never raylib's own default font.
fonts_unload :: proc(w: ^World) {
	default := rl.GetFontDefault()
	for s in w.fonts.slots[:w.fonts.count] {
		if s.loaded.texture.id != default.texture.id do rl.UnloadFont(s.loaded)
	}
	w.fonts = {}
}

// pos is the top-left corner of the text. Strings are UTF-8, copied to the frame arena for raylib.
ui_text :: proc(w: ^World, pos: [2]f32, text: string, font: Font, px: f32, color: rl.Color) {
	rl.DrawTextEx(
		font_get(w, font, px),
		strings.clone_to_cstring(text, context.temp_allocator),
		pos,
		f32(i32(px + 0.5)),
		0,
		color,
	)
}

ui_text_size :: proc(w: ^World, text: string, font: Font, px: f32) -> [2]f32 {
	return rl.MeasureTextEx(
		font_get(w, font, px),
		strings.clone_to_cstring(text, context.temp_allocator),
		f32(i32(px + 0.5)),
		0,
	)
}

// Immediate mode: a widget is a proc call that draws itself and returns what happened this frame. Nothing is
// kept between frames, there is no widget tree; the caller passes the rect and keeps the state it changes.
UI_BUTTON_W :: 44
UI_BUTTON_H :: 22
UI_FONT_PX :: 13
UI_GAP :: 2 // between the buttons of one group
UI_GROUP_GAP :: 8
UI_PAD :: 4

// Map / Drive, 4 sim speeds, Day / Night.
TOOLBAR_W :: 2 * UI_PAD + 8 * UI_BUTTON_W + 5 * UI_GAP + 2 * UI_GROUP_GAP
TOOLBAR_H :: 2 * UI_PAD + UI_BUTTON_H
#assert(len(SIM_SPEEDS) == 4 && len(Theme) == 2)

// Returns true on the frame the button is clicked. on: the state the button stands for is the current one.
ui_button :: proc(w: ^World, r: rl.Rectangle, text: string, on: bool) -> bool {
	pal := palette(w)
	hot := rl.CheckCollisionPointRec(rl.GetMousePosition(), r)
	rl.DrawRectangleRec(r, on ? pal.accent : hot ? pal.surface_2 : pal.surface)
	size := ui_text_size(w, text, .Roboto_500, UI_FONT_PX)
	ui_text(
		w,
		{r.x, r.y} + ({r.width, r.height} - size) / 2,
		text,
		.Roboto_500,
		UI_FONT_PX,
		on ? pal.surface : pal.text,
	)
	return hot && rl.IsMouseButtonPressed(.LEFT)
}
