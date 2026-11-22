// author: nasr
package game

import "core:math/linalg"
import "core:strings"
import rl "vendor:raylib"

// Map labels (docs/drift-design.pdf "Labels en markers"): water names on rivers and road shields on motorways,
// from the real names and refs in belgium.bin. The places are picked once along the lines (every
// *_SPACING_KM), each frame they are projected and a label that overlaps one drawn before it is dropped.
// Hub names are drawn with the hub markers in game.odin.
MAX_MAP_LABELS :: 1024
RIVER_LABEL_SPACING_KM :: 25
SHIELD_SPACING_KM :: 20
SHIELD_MIN_ZOOM :: 1.5 // below this the whole country is in view and shields would cover it
RIVER_MIN_ZOOM :: 2.5
LABEL_REPEAT_PX :: 150

Map_Label :: struct {
	pos:    [2]f32,
	text:   u32, // offset in w.m.names (name for rivers, ref for motorways)
	shield: bool,
}

Map_Labels :: struct {
	list:  [MAX_MAP_LABELS]Map_Label,
	count: int,
	built: bool, // reset on a hot reload, the offsets may point into another belgium.bin
}

labels_build :: proc(w: ^World) {
	ls := &w.labels
	ls.count = 0
	ls.built = true
	for l in w.m.lines {
		kind := Map_Kind(l.kind)
		shield := kind == .Motorway && l.ref != 0
		if !shield && !(kind == .River && l.name != 0) do continue
		spacing := f32(shield ? SHIELD_SPACING_KM : RIVER_LABEL_SPACING_KM)
		pts := w.m.points[l.start:][:l.count]
		// The first label half a spacing in, so short lines get one in their middle.
		next := spacing / 2
		along: f32
		for i in 1 ..< len(pts) {
			seg := linalg.length(pts[i] - pts[i - 1])
			for along + seg >= next && seg > 0 {
				if ls.count == MAX_MAP_LABELS do return
				t := (next - along) / seg
				ls.list[ls.count] = {linalg.lerp(pts[i - 1], pts[i], t), shield ? l.ref : l.name, shield}
				ls.count += 1
				next += spacing
			}
			along += seg
		}
	}
	logf(w, "render", "%d map labels", ls.count)
}

// taken: the label rects drawn so far this frame (hub names first), a new label must not overlap them.
labels_draw :: proc(w: ^World, taken: ^[dynamic]rl.Rectangle) {
	prof_zone(w, .Labels)
	if !w.labels.built do labels_build(w)
	pal := palette(w)
	z := w.cam.pose.zoom
	// Both carriageways of a motorway are separate lines: the same text again within LABEL_REPEAT_PX is dropped.
	Drawn :: struct {
		p:    [2]f32,
		text: string,
	}
	drawn := make([dynamic]Drawn, 0, 64, context.temp_allocator)
	for &lb in w.labels.list[:w.labels.count] {
		if z < (lb.shield ? w.map_edit.shield_min_zoom : w.map_edit.river_min_zoom) do continue
		p, visible := cam_to_screen(w, {lb.pos.x, lb.pos.y, 0})
		if !visible || p.x < 0 || p.y < 0 || p.x > w.cam.screen.x || p.y > w.cam.screen.y do continue
		// Far labels fade out (view_edit.odin), so names do not pile up along the horizon.
		a := view_label_alpha(w, view_depth(w, {lb.pos.x, lb.pos.y, 0}), w.view_edit.label_end)
		if a <= 0.01 do continue
		text := map_name(&w.m, lb.text)
		if lb.shield {
			// "E40;A10" -> "E40": one shield per road.
			if cut := strings.index_byte(text, ';'); cut >= 0 do text = text[:cut]
		}
		if text == "" do continue
		repeat := false
		for d in drawn do if d.text == text && linalg.length(d.p - p) < LABEL_REPEAT_PX do repeat = true
		if repeat do continue
		// Not under the panels and buttons of last frame.
		under := false
		for b in w.ui.last_blocks[:w.ui.last_count_b] do if rl.CheckCollisionPointRec(p, b) do under = true
		if under do continue
		if lb.shield {
			size := ui_text_size(w, text, .Roboto_700, 12)
			r := rl.Rectangle{p.x - size.x / 2 - 5, p.y - size.y / 2 - 2, size.x + 10, size.y + 4}
			if overlaps(taken[:], r) do continue
			append(taken, r)
			append(&drawn, Drawn{p, text})
			round_rect(w, r, 4, rl.ColorAlpha(pal.shield_border, a))
			round_rect(w, {r.x + 1.5, r.y + 1.5, r.width - 3, r.height - 3}, 3, rl.ColorAlpha(pal.shield, a))
			ui_text(w, {r.x + 5, r.y + 2}, text, .Roboto_700, 12, rl.ColorAlpha(pal.shield_text, a))
		} else {
			px :: f32(15)
			font := font_get(w, .Figtree_Italic_400, px)
			ctext := strings.clone_to_cstring(text, context.temp_allocator)
			spacing := px * 0.14
			size := rl.MeasureTextEx(font, ctext, px, spacing)
			r := rl.Rectangle{p.x - size.x / 2, p.y - size.y / 2, size.x, size.y}
			if overlaps(taken[:], r) do continue
			append(taken, r)
			append(&drawn, Drawn{p, text})
			for o in ([?][2]f32{{-1, 0}, {1, 0}, {0, -1}, {0, 1}}) {
				rl.DrawTextEx(font, ctext, {r.x, r.y} + o, px, spacing, rl.ColorAlpha(pal.label_halo, a))
			}
			rl.DrawTextEx(font, ctext, {r.x, r.y}, px, spacing, rl.ColorAlpha(pal.water_label, a))
		}
	}

	overlaps :: proc(taken: []rl.Rectangle, r: rl.Rectangle) -> bool {
		for t in taken do if rl.CheckCollisionRecs(t, r) do return true
		return false
	}
}
