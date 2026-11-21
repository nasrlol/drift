package game

import "core:math/linalg"
import rl "vendor:raylib"

// A cache of square tiles around the camera, each with its own mesh, for what is generated near the camera
// (towns.odin, nature.odin). A tile is built once when it comes within reach, at most TILE_BUILDS_PER_FRAME a
// frame and nearest first, so moving never stalls a frame, and dropped when it is well out of reach.
TILE_SLOTS :: 96
TILE_BUILDS_PER_FRAME :: 2

Tile :: struct {
	key:  [2]i32,
	mesh: rl.Mesh,
	used: bool,
}

Tile_Cache :: struct {
	tiles: [TILE_SLOTS]Tile,
}

// Builds the mesh for what is anchored inside lo ..< hi (km). An empty mesh is fine.
Tile_Build :: #type proc(w: ^World, lo, hi: [2]f32) -> rl.Mesh

tile_centre :: proc(key: [2]i32, size: f32) -> [2]f32 {
	return ([2]f32{f32(key.x), f32(key.y)} + 0.5) * size
}

// Updates the cache around target (km) and draws its tiles with material and transform (inside BeginMode3D).
tiles_update_draw :: proc(
	w: ^World,
	cache: ^Tile_Cache,
	size, reach: f32,
	build: Tile_Build,
	material: rl.Material,
	target: [2]f32,
	transform: rl.Matrix,
) {
	keep := reach + 2 * size
	for &t in cache.tiles {
		if t.used && linalg.length(tile_centre(t.key, size) - target) > keep {
			if t.mesh.vertexCount > 0 do rl.UnloadMesh(t.mesh)
			t = {}
		}
	}
	for _ in 0 ..< TILE_BUILDS_PER_FRAME {
		// The nearest tile within reach that is not built yet.
		best: [2]i32
		best_d := max(f32)
		lo := linalg.floor((target - reach) / size)
		hi := linalg.floor((target + reach) / size)
		for y := i32(lo.y); y <= i32(hi.y); y += 1 {
			for x := i32(lo.x); x <= i32(hi.x); x += 1 {
				key := [2]i32{x, y}
				d := linalg.length(tile_centre(key, size) - target)
				if d > reach + size * 0.71 || d >= best_d do continue
				built := false
				for t in cache.tiles do if t.used && t.key == key do built = true
				if !built do best, best_d = key, d
			}
		}
		if best_d == max(f32) do break
		slot := -1
		for t, i in cache.tiles do if !t.used {slot = i; break}
		if slot < 0 do break
		lo_km := [2]f32{f32(best.x), f32(best.y)} * size
		cache.tiles[slot] = {
			key  = best,
			mesh = build(w, lo_km, lo_km + size),
			used = true,
		}
	}
	for t in cache.tiles {
		if !t.used || t.mesh.vertexCount == 0 do continue
		if linalg.length(tile_centre(t.key, size) - target) > reach + size do continue
		rl.DrawMesh(t.mesh, material, transform)
	}
}

tiles_unload :: proc(cache: ^Tile_Cache) {
	for &t in cache.tiles {
		if t.used && t.mesh.vertexCount > 0 do rl.UnloadMesh(t.mesh)
		t = {}
	}
}

// Uploads the arrays as a mesh and lets go of them (they live in the frame arena).
tile_mesh :: proc(pos: [][3]f32, col: [][4]u8) -> rl.Mesh {
	if len(pos) == 0 do return {}
	m := rl.Mesh {
		vertexCount   = i32(len(pos)),
		triangleCount = i32(len(pos) / 3),
		vertices      = ([^]f32)(raw_data(pos)),
		colors        = ([^]u8)(raw_data(col)),
	}
	rl.UploadMesh(&m, false)
	m.vertices, m.colors = nil, nil
	return m
}
