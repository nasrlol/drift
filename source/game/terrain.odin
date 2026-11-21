package game

import "core:math"

// x, y in km (map space, y down). Returns ground height above sea level in m: bilinear between the 250 m cell
// centres of w.m.heights (Copernicus surface model, so forests and big buildings are in it, sea is 0).
// Outside the map the edge value holds, like wind_at. NaN in x or y gives 0, and so does a map that failed to
// load (no heights).
height_at :: proc(w: ^World, x, y: f32) -> f32 {
	hs := w.m.heights
	if len(hs) != HEIGHT_W * HEIGHT_H do return 0
	fx := x / HEIGHT_CELL_KM - 0.5
	fy := y / HEIGHT_CELL_KM - 0.5
	// Written so NaN fails the test: a NaN index would be undefined behaviour after the int conversion.
	if !(fx == fx && fy == fy) do return 0
	fx = clamp(fx, 0, HEIGHT_W - 1)
	fy = clamp(fy, 0, HEIGHT_H - 1)
	ix := min(int(fx), HEIGHT_W - 2)
	iy := min(int(fy), HEIGHT_H - 2)
	tx, ty := fx - f32(ix), fy - f32(iy)
	i := iy * HEIGHT_W + ix
	top := f32(hs[i]) + (f32(hs[i + 1]) - f32(hs[i])) * tx
	bottom := f32(hs[i + HEIGHT_W]) + (f32(hs[i + HEIGHT_W + 1]) - f32(hs[i + HEIGHT_W])) * tx
	return top + (bottom - top) * ty
}

// Everything stays over Belgium (nasr, 2026-11-21): wind, clouds, ground layers, camera, ship and routes. The
// country is the Border rings of belgium.bin (the sea zone included), rasterized on the heightmap cells.
// w.belgium per cell: 0 outside, else the distance into Belgium in cells (8 neighbours), capped at
// BELGIUM_DEPTH. Drawing fades in over that distance, so the edge is soft.
BELGIUM_FADE_KM :: 3.0
BELGIUM_DEPTH :: 12
#assert(BELGIUM_DEPTH * HEIGHT_CELL_KM == BELGIUM_FADE_KM)

// Fills w.belgium from w.m, in game_hot_reloaded after load_map. No allocation. A map without border rings
// counts as Belgium everywhere, so nothing is blocked.
belgium_build :: proc(w: ^World) {
	b := &w.belgium
	b^ = {}

	// Even-odd fill: every border segment flips the first cell whose centre lies right of it, in each row
	// whose centre line it crosses. A running xor along the row is then 1 inside.
	rings, open := 0, 0
	for l in w.m.lines {
		if Map_Kind(l.kind) != .Border do continue
		pts := w.m.points[l.start:][:l.count]
		if len(pts) < 2 do continue
		rings += 1
		if pts[0] != pts[len(pts) - 1] do open += 1
		for k in 1 ..< len(pts) {
			p, q := pts[k - 1] / HEIGHT_CELL_KM, pts[k] / HEIGHT_CELL_KM
			lo, hi := min(p.y, q.y), max(p.y, q.y)
			// Rows j with centre j + 0.5 in [lo, hi): a vertex on a centre line counts once.
			for j := max(int(math.ceil(lo - 0.5)), 0); j < HEIGHT_H && f32(j) + 0.5 < hi; j += 1 {
				yc := f32(j) + 0.5
				x := p.x + (q.x - p.x) * (yc - p.y) / (q.y - p.y)
				i := max(int(math.ceil(x - 0.5)), 0)
				if i < HEIGHT_W do b[j * HEIGHT_W + i] ~= 1
			}
		}
	}
	if rings == 0 {
		for &c in b do c = BELGIUM_DEPTH
		logf(w, "map", "no border rings in belgium.bin, the whole map counts as Belgium")
		return
	}
	inside := 0
	for j in 0 ..< HEIGHT_H {
		run: u8
		for i in 0 ..< HEIGHT_W {
			run ~= b[j * HEIGHT_W + i]
			b[j * HEIGHT_W + i] = run * BELGIUM_DEPTH
			inside += int(run)
		}
	}

	// Two chamfer passes: forward from the top-left neighbours, backward from the bottom-right ones. Cells past
	// the map edge do not count as outside: the map is the country's bounding box.
	for j in 0 ..< HEIGHT_H {
		for i in 0 ..< HEIGHT_W {
			c := &b[j * HEIGHT_W + i]
			if c^ == 0 do continue
			if i > 0 do c^ = min(c^, b[j * HEIGHT_W + i - 1] + 1)
			if j == 0 do continue
			for di in -1 ..= 1 {
				if i + di < 0 || i + di >= HEIGHT_W do continue
				c^ = min(c^, b[(j - 1) * HEIGHT_W + i + di] + 1)
			}
		}
	}
	for j := HEIGHT_H - 1; j >= 0; j -= 1 {
		for i := HEIGHT_W - 1; i >= 0; i -= 1 {
			c := &b[j * HEIGHT_W + i]
			if c^ == 0 do continue
			if i < HEIGHT_W - 1 do c^ = min(c^, b[j * HEIGHT_W + i + 1] + 1)
			if j == HEIGHT_H - 1 do continue
			for di in -1 ..= 1 {
				if i + di < 0 || i + di >= HEIGHT_W do continue
				c^ = min(c^, b[(j + 1) * HEIGHT_W + i + di] + 1)
			}
		}
	}
	logf(
		w,
		"map",
		"belgium mask: %d border rings (%d open), %d of %d cells inside",
		rings,
		open,
		inside,
		HEIGHT_W * HEIGHT_H,
	)
}

// x, y in km. true when the 250 m cell under the point lies in Belgium. Outside the map and NaN give false.
belgium_inside :: proc(w: ^World, x, y: f32) -> bool {
	fx, fy := x / HEIGHT_CELL_KM, y / HEIGHT_CELL_KM
	// Written so NaN fails the test.
	if !(fx >= 0 && fy >= 0 && fx < HEIGHT_W && fy < HEIGHT_H) do return false
	return w.belgium[int(fy) * HEIGHT_W + int(fx)] > 0
}

// x, y in km. 0 outside Belgium, rising to 1 at BELGIUM_FADE_KM inside the border, bilinear between the cell
// centres like height_at. NaN gives 0.
belgium_fade :: proc(w: ^World, x, y: f32) -> f32 {
	fx := x / HEIGHT_CELL_KM - 0.5
	fy := y / HEIGHT_CELL_KM - 0.5
	if !(fx == fx && fy == fy) do return 0
	fx = clamp(fx, 0, HEIGHT_W - 1)
	fy = clamp(fy, 0, HEIGHT_H - 1)
	ix := min(int(fx), HEIGHT_W - 2)
	iy := min(int(fy), HEIGHT_H - 2)
	tx, ty := fx - f32(ix), fy - f32(iy)
	b := &w.belgium
	i := iy * HEIGHT_W + ix
	top := f32(b[i]) + (f32(b[i + 1]) - f32(b[i])) * tx
	bottom := f32(b[i + HEIGHT_W]) + (f32(b[i + HEIGHT_W + 1]) - f32(b[i + HEIGHT_W])) * tx
	return (top + (bottom - top) * ty) / BELGIUM_DEPTH
}
