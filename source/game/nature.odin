package game

import "core:math"
import "core:math/linalg"
import rl "vendor:raylib"

// Nature around the route (Lars, 2026-11-21: "natuur/wolken"): clumps of trees in the parks and woods of the
// land use map. A clump is a low six-sided crown, 25-50 m wide and 10-24 m high, placed by a hash inside the
// park triangles, TREE_DENSITY per km2. Built per TREE_TILE_KM tile within TREE_REACH_KM of the camera
// (tiles.odin). They grow in with the zoom like the buildings and use the buildings' shader. Our values, not
// from the spec.
TREE_DENSITY :: 70.0
TREE_TILE_KM :: 3.0
TREE_REACH_KM :: 12.0
TREE_SIDES :: 6

// 0 .. 1 from a seed.
nature_rand :: proc(seed: ^u32) -> f32 {
	seed^ = hash_u32(seed^ + 0x9e3779b9)
	return f32(seed^ >> 8) / f32(1 << 24)
}

// The trees whose centre lies in lo ..< hi (Tile_Build), relative to lo. Each park triangle seeds its trees the
// same way for every tile, a tile keeps the ones inside it.
nature_build_tile :: proc(w: ^World, lo, hi: [2]f32) -> rl.Mesh {
	pos := make([dynamic][3]f32, 0, 8192, context.temp_allocator)
	col := make([dynamic][4]u8, 0, 8192, context.temp_allocator)
	LIGHT :: [2]f32{-0.7071, -0.7071}
	for a, ai in w.m.areas {
		if Area_Kind(a.kind) != .Park do continue
		pts := w.m.area_points[a.start:][:a.count]
		for t := 0; t + 2 < len(pts); t += 3 {
			p0, p1, p2 := pts[t], pts[t + 1], pts[t + 2]
			tlo := linalg.min(p0, linalg.min(p1, p2))
			thi := linalg.max(p0, linalg.max(p1, p2))
			if thi.x < lo.x || thi.y < lo.y || tlo.x >= hi.x || tlo.y >= hi.y do continue
			e1, e2 := p1 - p0, p2 - p0
			area := abs(e1.x * e2.y - e1.y * e2.x) / 2
			seed := hash_u32(u32(ai) * 7919 + u32(t) * 104729)
			count := int(area * TREE_DENSITY + nature_rand(&seed))
			for _ in 0 ..< count {
				// Uniform in the triangle: fold the unit square.
				u, v := nature_rand(&seed), nature_rand(&seed)
				if u + v > 1 do u, v = 1 - u, 1 - v
				c := p0 + e1 * u + e2 * v
				r := (0.012 + 0.013 * nature_rand(&seed)) // km
				h := (0.010 + 0.014 * nature_rand(&seed)) // km
				turn0 := nature_rand(&seed) * math.TAU
				if c.x < lo.x || c.y < lo.y || c.x >= hi.x || c.y >= hi.y do continue
				c -= lo
				apex := [3]f32{c.x, c.y, -h}
				for k in 0 ..< TREE_SIDES {
					// Counter-clockwise on the map: the angle goes down.
					a0 := turn0 - f32(k) * math.TAU / TREE_SIDES
					a1 := a0 - math.TAU / TREE_SIDES
					q0 := c + [2]f32{math.cos(a0), math.sin(a0)} * r
					q1 := c + [2]f32{math.cos(a1), math.sin(a1)} * r
					normal := linalg.normalize([2]f32{math.cos((a0 + a1) / 2), math.sin((a0 + a1) / 2)})
					light := 0.7 + 0.25 * linalg.dot(normal, LIGHT)
					low, top := u8(light * 0.75 * 255), u8(min(light * 1.15, 1) * 255)
					append(&pos, [3]f32{q0.x, q0.y, -h * 0.3}, [3]f32{q1.x, q1.y, -h * 0.3}, apex)
					append(&col, [4]u8{low, 0, 255, 255}, [4]u8{low, 0, 255, 255}, [4]u8{top, 0, 255, 255})
				}
			}
		}
	}
	return tile_mesh(pos[:], col[:])
}

// Inside BeginMode3D, right after buildings_draw (which sets the shader's uniforms), around target (km).
nature_draw :: proc(w: ^World, target: [2]f32, reach: f32, place: Placement) {
	b := &w.buildings
	if !b.ready do return
	tiles_update_draw(w, &w.nature, TREE_TILE_KM, reach, nature_build_tile, b.material, target, place)
}
