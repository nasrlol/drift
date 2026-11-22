package game

import "core:math"
import "core:math/linalg"
import rl "vendor:raylib"

// Buildings everywhere (Lars, 2026-11-21: "ik wil overal 3d gebouwen - niet alleen in hoofdsteden"). The real
// OSM footprints only fit for the 15 city centres (buildings.odin, 7.6 M buildings in all of Belgium), so the
// other built-up land (the City areas of the land use map: residential, commercial, industrial, retail) gets
// generated blocks: a lattice of TOWN_LOT_M lots turned by a hash of the area, a lot keeps a building with
// TOWN_FILL chance, sized and raised by a hash of the lot. Built per TOWN_TILE_KM tile within TOWN_REACH_KM of
// the camera (tiles.odin); the circles of real buildings are left out. Same shader and growth as the real
// buildings. Our values, not from OSM.
TOWN_LOT_M :: 30.0
TOWN_HALF_MIN :: 0.25 // half the width of the smallest building, in lots
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

// One lattice per City area: its own turn, the same for all of its triangles, so they do not overlap.
town_lattice :: proc(area: int) -> (seed: u32, ax, ay: [2]f32) {
	seed = hash_u32(u32(area) * 2654435761 + 17)
	angle := f32(seed >> 8) / f32(1 << 24) * math.PI / 2
	ax = {math.cos(angle), math.sin(angle)}
	ay = {-ax.y, ax.x}
	return
}

// The hash of lot (i, j) of a lattice: its low byte decides whether it keeps a building (TOWN_FILL).
town_lot_hash :: proc(seed: u32, i, j: i32) -> u32 {
	return hash_u32(u32(i) * 73856093 ~ u32(j) * 19349663 ~ seed)
}

// The building on lot (i, j) of a lattice, if the lot keeps one: its ring (km) and its real height (km, the map
// draws it BUILDINGS_HEIGHT_X taller). Lots within BUILDINGS_RADIUS_KM of a city with real buildings stay empty,
// and so does a lot whose building would stand on a road or river or its sidewalk (town_lot_clear). Drawing
// (town_houses) and collision (collide.odin) both use this, so a wall stops the car where it shows.
town_lot :: proc(
	w: ^World,
	seed: u32,
	ax, ay: [2]f32,
	i, j: i32,
) -> (
	ring: [4][2]f32,
	height: f32,
	ok: bool,
) {
	lot := f32(TOWN_LOT_M) / 1000
	c := (ax * (f32(i) + 0.5) + ay * (f32(j) + 0.5)) * lot
	h := town_lot_hash(seed, i, j)
	r0 := f32(h & 0xff) / 255
	r1 := f32((h >> 8) & 0xff) / 255
	r2 := f32((h >> 16) & 0xff) / 255
	r3 := f32(h >> 24) / 255
	if r0 > TOWN_FILL do return
	co := &w.collide
	if !co.built do collide_build(w)
	for o in co.cities[:co.city_count] do if linalg.length(c - o) < BUILDINGS_RADIUS_KM do return
	half := [2]f32{TOWN_HALF_MIN + 0.2 * r1, TOWN_HALF_MIN + 0.2 * r2} * lot
	if !town_lot_clear(w, c, ax, ay, half * 1000) do return
	height = (5 + 9 * r3 * r3 + (r1 > 0.97 ? 20 * r2 : 0)) / 1000
	// Counter-clockwise on the map (y south): the lattice axes are a rotation, so -u-v, -u+v, +u+v, +u-v turns
	// the same way as the ground quads.
	ring = {
		c - ax * half.x - ay * half.y,
		c - ax * half.x + ay * half.y,
		c + ax * half.x + ay * half.y,
		c + ax * half.x - ay * half.y,
	}
	return ring, height, true
}

// A generated building: its ring (km, counter-clockwise on the map like the OSM rings), real height (m) and a
// seed for its looks.
Town_House :: struct {
	ring:   [4][2]f32,
	height: f32,
	seed:   u32,
}

// The generated buildings whose lot centre lies in lo ..< hi, appended to out. The map (towns_build_tile) and the
// street view (houses.odin) both draw these. gardens, when given, gets the centres (km) of the lots left empty by
// TOWN_FILL: the street view puts garden trees there.
town_houses :: proc(w: ^World, lo, hi: [2]f32, out: ^[dynamic]Town_House, gardens: ^[dynamic][2]f32 = nil) {
	b := &w.buildings
	for o in b.origins[:b.count] {
		// The whole tile inside a circle of real buildings: nothing to make.
		far := linalg.max(linalg.abs(lo - o), linalg.abs(hi - o))
		if linalg.length(far) < BUILDINGS_RADIUS_KM do return
	}
	// Only the City triangles filed in the 1 km cells of the collision data that overlap lo ..< hi (all of them
	// cost 2.4 ms per tile in the debug build even where there is no town); a triangle in several of those
	// cells is made in the first one.
	co := &w.collide
	if !co.built do collide_build(w)
	lot := f32(TOWN_LOT_M) / 1000
	cx0 := clamp(int(math.floor(lo.x / COLLIDE_TRI_CELL_KM)), 0, COLLIDE_TRI_W - 1)
	cx1 := clamp(int(math.floor(hi.x / COLLIDE_TRI_CELL_KM)), 0, COLLIDE_TRI_W - 1)
	cy0 := clamp(int(math.floor(lo.y / COLLIDE_TRI_CELL_KM)), 0, COLLIDE_TRI_H - 1)
	cy1 := clamp(int(math.floor(hi.y / COLLIDE_TRI_CELL_KM)), 0, COLLIDE_TRI_H - 1)
	for cy in cy0 ..= cy1 do for cx in cx0 ..= cx1 do for item in co.tri_items[co.tri_cells[cy * COLLIDE_TRI_W + cx]:co.tri_cells[cy * COLLIDE_TRI_W + cx + 1]] {
		ai := int(item[0])
		p0, p1, p2 := w.m.area_points[item[1]], w.m.area_points[item[1] + 1], w.m.area_points[item[1] + 2]
		tri_lo := linalg.min(p0, linalg.min(p1, p2))
		first := [2]int{max(cx0, int(math.floor(tri_lo.x / COLLIDE_TRI_CELL_KM))), max(cy0, int(math.floor(tri_lo.y / COLLIDE_TRI_CELL_KM)))}
		if first != {cx, cy} do continue
		seed, ax, ay := town_lattice(ai)
		{
			tlo := linalg.max(tri_lo, lo)
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
					ring, height, ok := town_lot(w, seed, ax, ay, i, j)
					if !ok {
						empty := f32(town_lot_hash(seed, i, j) & 0xff) / 255 > TOWN_FILL
						if gardens != nil && empty do append(gardens, c)
						continue
					}
					h := hash_u32(u32(i) * 2246822519 ~ u32(j) * 3266489917 ~ seed)
					append(out, Town_House{ring, height * 1000, h})
				}
			}
		}
	}
}

// The generated buildings whose lot centre lies in lo ..< hi (Tile_Build), relative to lo.
towns_build_tile :: proc(w: ^World, lo, hi: [2]f32) -> rl.Mesh {
	houses := make([dynamic]Town_House, 0, 1024, context.temp_allocator)
	town_houses(w, lo, hi, &houses)
	pos := make([dynamic][3]f32, 0, len(houses) * 30, context.temp_allocator)
	col := make([dynamic][4]u8, 0, len(houses) * 30, context.temp_allocator)
	LIGHT :: [2]f32{-0.7071, -0.7071}
	for th in houses {
		ring := th.ring
		height := th.height / 1000 * BUILDINGS_HEIGHT_X
		for &q in ring do q -= lo
		for e in 0 ..< 4 {
			p, q := ring[e], ring[(e + 1) % 4]
			d := linalg.normalize(q - p)
			light := 0.68 + 0.22 * linalg.dot([2]f32{-d.y, d.x}, LIGHT)
			top, low := u8(light * 255), u8(light * 0.7 * 255)
			append(&pos, [3]f32{p.x, p.y, 0}, [3]f32{q.x, q.y, 0}, [3]f32{q.x, q.y, -height})
			append(&pos, [3]f32{p.x, p.y, 0}, [3]f32{q.x, q.y, -height}, [3]f32{p.x, p.y, -height})
			append(&col, [4]u8{low, 0, 0, 255}, [4]u8{low, 0, 0, 255}, [4]u8{top, 0, 0, 255})
			append(&col, [4]u8{low, 0, 0, 255}, [4]u8{top, 0, 0, 255}, [4]u8{top, 0, 0, 255})
		}
		for v in ([6]int{0, 1, 2, 0, 2, 3}) {
			append(&pos, [3]f32{ring[v].x, ring[v].y, -height})
			append(&col, [4]u8{255, 255, 0, 255})
		}
	}
	return tile_mesh(pos[:], col[:])
}

// Inside BeginMode3D, right after buildings_draw (which sets the shader's uniforms), around target (km).
towns_draw :: proc(w: ^World, target: [2]f32, reach: f32, place: Placement) {
	b := &w.buildings
	if !b.ready do return
	tiles_update_draw(w, &w.towns, TOWN_TILE_KM, reach, towns_build_tile, b.material, target, place)
}
