package game

import "core:math"
import "core:math/linalg"
import rl "vendor:raylib"

// Buildings everywhere (Lars, 2026-11-21: "ik wil overal 3d gebouwen - niet alleen in hoofdsteden"). The real
// OSM footprints only fit for the 15 city centres (buildings.odin, 7.6 M buildings in all of Belgium), so the
// other built-up land (the City areas of the land use map: residential, commercial, industrial, retail) gets
// generated blocks: a lattice of TOWN_LOT_M lots turned by a hash of the area, a lot keeps a building with
// TOWN_FILL chance, sized and raised by a hash of the lot. Built per TOWN_TILE_KM tile within TOWN_REACH_KM of
// the camera (tiles.odin); the circles of real buildings are left out. Same shader and zoom growth as the real
// buildings. Our values, not from OSM.
TOWN_LOT_M :: 30.0
TOWN_FILL :: 0.62
TOWN_TILE_KM :: 1.5
TOWN_REACH_KM :: 6.0

// Inside the triangle a, b, c (either winding).
in_triangle :: proc(p, a, b, c: [2]f32) -> bool {
	d1 := turn(a, b, p)
	d2 := turn(b, c, p)
	d3 := turn(c, a, p)
	neg := d1 < 0 || d2 < 0 || d3 < 0
	pos := d1 > 0 || d2 > 0 || d3 > 0
	return !(neg && pos)
}

// The generated buildings whose lot centre lies in lo ..< hi (Tile_Build).
towns_build_tile :: proc(w: ^World, lo, hi: [2]f32) -> rl.Mesh {
	b := &w.buildings
	for o in b.origins[:b.count] {
		// The whole tile inside a circle of real buildings: nothing to make.
		far := linalg.max(linalg.abs(lo - o), linalg.abs(hi - o))
		if linalg.length(far) < BUILDINGS_RADIUS_KM do return {}
	}
	pos := make([dynamic][3]f32, 0, 1 << 14, context.temp_allocator)
	col := make([dynamic][4]u8, 0, 1 << 14, context.temp_allocator)
	LIGHT :: [2]f32{-0.7071, -0.7071}
	lot := f32(TOWN_LOT_M) / 1000
	for a, ai in w.m.areas {
		if Area_Kind(a.kind) != .City do continue
		pts := w.m.area_points[a.start:][:a.count]
		// One lattice per area: its own turn, the same for all of its triangles, so they do not overlap.
		seed := hash_u32(u32(ai) * 2654435761 + 17)
		angle := f32(seed >> 8) / f32(1 << 24) * math.PI / 2
		ax := [2]f32{math.cos(angle), math.sin(angle)}
		ay := [2]f32{-ax.y, ax.x}
		for k := 0; k + 2 < len(pts); k += 3 {
			p0, p1, p2 := pts[k], pts[k + 1], pts[k + 2]
			tlo := linalg.max(linalg.min(p0, linalg.min(p1, p2)), lo)
			thi := linalg.min(linalg.max(p0, linalg.max(p1, p2)), hi)
			if tlo.x >= thi.x || tlo.y >= thi.y do continue
			// The lots of the overlap box, in lattice units.
			u0, u1 := max(f32), min(f32)
			v0, v1 := max(f32), min(f32)
			for p in ([4][2]f32{tlo, {tlo.x, thi.y}, thi, {thi.x, tlo.y}}) {
				u, v := linalg.dot(p, ax) / lot, linalg.dot(p, ay) / lot
				u0, u1 = min(u0, u), max(u1, u)
				v0, v1 = min(v0, v), max(v1, v)
			}
			for j := i32(math.floor(v0)); f32(j) <= v1; j += 1 {
				for i := i32(math.floor(u0)); f32(i) <= u1; i += 1 {
					c := (ax * (f32(i) + 0.5) + ay * (f32(j) + 0.5)) * lot
					if c.x < lo.x || c.y < lo.y || c.x >= hi.x || c.y >= hi.y do continue
					if !in_triangle(c, p0, p1, p2) do continue
					h := hash_u32(u32(i) * 73856093 ~ u32(j) * 19349663 ~ seed)
					r0 := f32(h & 0xff) / 255
					r1 := f32((h >> 8) & 0xff) / 255
					r2 := f32((h >> 16) & 0xff) / 255
					r3 := f32(h >> 24) / 255
					if r0 > TOWN_FILL do continue
					real := false
					for o in b.origins[:b.count] do if linalg.length(c - o) < BUILDINGS_RADIUS_KM do real = true
					if real do continue
					half := [2]f32{0.25 + 0.2 * r1, 0.25 + 0.2 * r2} * lot
					height := (5 + 9 * r3 * r3 + (r1 > 0.97 ? 20 * r2 : 0)) / 1000 * BUILDINGS_HEIGHT_X
					// Counter-clockwise on the map (y south): the lattice axes are a rotation, so -u-v, -u+v, +u+v,
					// +u-v turns the same way as the ground quads.
					ring := [4][2]f32 {
						c - ax * half.x - ay * half.y,
						c - ax * half.x + ay * half.y,
						c + ax * half.x + ay * half.y,
						c + ax * half.x - ay * half.y,
					}
					for e in 0 ..< 4 {
						p, q := ring[e], ring[(e + 1) % 4]
						d := linalg.normalize(q - p)
						light := 0.68 + 0.22 * linalg.dot([2]f32{-d.y, d.x}, LIGHT)
						top, low := u8(light * 255), u8(light * 0.7 * 255)
						append(&pos, [3]f32{p.x, p.y, 0}, [3]f32{q.x, q.y, 0}, [3]f32{q.x, q.y, -height})
						append(
							&pos,
							[3]f32{p.x, p.y, 0},
							[3]f32{q.x, q.y, -height},
							[3]f32{p.x, p.y, -height},
						)
						append(&col, [4]u8{low, 0, 0, 255}, [4]u8{low, 0, 0, 255}, [4]u8{top, 0, 0, 255})
						append(&col, [4]u8{low, 0, 0, 255}, [4]u8{top, 0, 0, 255}, [4]u8{top, 0, 0, 255})
					}
					for v in ([6]int{0, 1, 2, 0, 2, 3}) {
						append(&pos, [3]f32{ring[v].x, ring[v].y, -height})
						append(&col, [4]u8{255, 255, 0, 255})
					}
				}
			}
		}
	}
	return tile_mesh(pos[:], col[:])
}

// Inside BeginMode3D, right after buildings_draw (which sets the shader's uniforms).
towns_draw :: proc(w: ^World) {
	b := &w.buildings
	if !b.ready || w.cam.pose.zoom <= BUILDINGS_ZOOM_0 do return
	tiles_update_draw(w, &w.towns, TOWN_TILE_KM, TOWN_REACH_KM, towns_build_tile, b.material)
}
