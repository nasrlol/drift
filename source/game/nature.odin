package game

import "core:math"
import "core:math/linalg"
import rl "vendor:raylib"

// Nature around the route (Lars, 2026-11-21: "natuur/wolken"): clumps of trees in the parks and woods of the
// land use map. A clump is a low six-sided crown, 25-50 m wide and 10-24 m high, placed by a hash inside the
// park triangles, TREE_DENSITY per km2. Only the triangles within TREE_REACH_KM of the camera target get
// trees; the mesh is built again when the target has moved TREE_REBUILD_KM. They grow in with the zoom like the
// buildings and use the buildings' shader. Our values, not from the spec.
TREE_DENSITY :: 70.0
TREE_REACH_KM :: 14.0
TREE_REBUILD_KM :: 4.0
TREE_MAX :: 40_000
TREE_SIDES :: 6

Nature :: struct {
	mesh:   rl.Mesh,
	centre: [2]f32, // camera target the mesh was built around
	built:  bool,
}

// 0 .. 1 from a seed.
nature_rand :: proc(seed: ^u32) -> f32 {
	seed^ = hash_u32(seed^ + 0x9e3779b9)
	return f32(seed^ >> 8) / f32(1 << 24)
}

nature_rebuild :: proc(w: ^World, centre: [2]f32) {
	n := &w.nature
	if n.built && n.mesh.vertexCount > 0 do rl.UnloadMesh(n.mesh)
	n.mesh = {}
	n.centre = centre
	n.built = true

	pos := make([dynamic][3]f32, 0, 8192, context.temp_allocator)
	col := make([dynamic][4]u8, 0, 8192, context.temp_allocator)
	LIGHT :: [2]f32{-0.7071, -0.7071}
	trees := 0
	reach := f32(TREE_REACH_KM)
	for a, ai in w.m.areas {
		if Area_Kind(a.kind) != .Park do continue
		pts := w.m.area_points[a.start:][:a.count]
		for t := 0; t + 2 < len(pts); t += 3 {
			p0, p1, p2 := pts[t], pts[t + 1], pts[t + 2]
			mid := (p0 + p1 + p2) / 3
			if abs(mid.x - centre.x) > reach || abs(mid.y - centre.y) > reach do continue
			e1, e2 := p1 - p0, p2 - p0
			area := abs(e1.x * e2.y - e1.y * e2.x) / 2
			seed := hash_u32(u32(ai) * 7919 + u32(t) * 104729)
			count := int(area * TREE_DENSITY + nature_rand(&seed))
			for _ in 0 ..< count {
				if trees == TREE_MAX do break
				// Uniform in the triangle: fold the unit square.
				u, v := nature_rand(&seed), nature_rand(&seed)
				if u + v > 1 do u, v = 1 - u, 1 - v
				c := p0 + e1 * u + e2 * v
				if linalg.length(c - centre) > reach do continue
				r := (0.012 + 0.013 * nature_rand(&seed)) // km
				h := (0.010 + 0.014 * nature_rand(&seed)) // km
				turn0 := nature_rand(&seed) * math.TAU
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
				trees += 1
			}
		}
	}
	if len(pos) == 0 do return
	m := rl.Mesh {
		vertexCount   = i32(len(pos)),
		triangleCount = i32(len(pos) / 3),
		vertices      = ([^]f32)(raw_data(pos)),
		colors        = ([^]u8)(raw_data(col)),
	}
	rl.UploadMesh(&m, false)
	m.vertices, m.colors = nil, nil
	n.mesh = m
}

// Inside BeginMode3D, right after buildings_draw (which sets the shader's uniforms).
nature_draw :: proc(w: ^World) {
	b := &w.buildings
	if !b.ready do return
	if w.cam.pose.zoom <= BUILDINGS_ZOOM_0 do return
	target := w.cam.view.target.xy
	n := &w.nature
	if !n.built || linalg.length(target - n.centre) > TREE_REBUILD_KM do nature_rebuild(w, target)
	if n.mesh.vertexCount > 0 do rl.DrawMesh(n.mesh, b.material, rl.Matrix(1))
}

nature_unload :: proc(n: ^Nature) {
	if n.built && n.mesh.vertexCount > 0 do rl.UnloadMesh(n.mesh)
	n^ = {}
}
