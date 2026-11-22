package game

import "core:math/linalg"
import "core:time"
import rl "vendor:raylib"

// A cache of square tiles around the camera, each with its own mesh, for what is generated near the camera
// (towns.odin, nature.odin, houses.odin, the street view's roads). A tile is built once when it comes within
// reach, nearest first: one a frame, more only while the frame's builds stay under TILE_BUILD_MS (the densest
// house tile of Brussels takes 3.3 ms in the profile build), and dropped when it is well out of reach.
TILE_SLOTS :: 192
TILE_BUILDS_PER_FRAME :: 4
TILE_BUILD_MS :: 1.0

Tile :: struct {
	key:  [2]i32,
	mesh: rl.Mesh,
	used: bool,
}

Tile_Cache :: struct {
	tiles: [TILE_SLOTS]Tile,
}

// Builds the mesh for what is anchored inside lo ..< hi (km), its points relative to lo. An empty mesh is fine.
Tile_Build :: #type proc(w: ^World, lo, hi: [2]f32) -> rl.Mesh

// Where a draw call puts map meshes (km, y south, z down): axes scales and turns them (no translation) and origin
// (km) lands at zero. The map: identity around 0. The street view: metres, y up, around the street origin.
// Meshes keep their points relative to an anchor (a tile corner, a city centre) and place_at takes the anchor
// minus the origin in f64, so every number the GPU sees stays small. With the points in km (~150) times 1000
// in f32 the 3D buildings z-fought in the street view: 1.7 % of the pixels jumped colour between two frames
// of a 0.1 px pan from the tower (measured with --script, whole wall faces flipping).
Placement :: struct {
	axes:   rl.Matrix,
	origin: [2]f32,
}

MAP_PLACEMENT :: Placement {
	axes = 1,
}

place_at :: proc(p: Placement, anchor: [2]f32) -> rl.Matrix {
	d := [2]f64{f64(anchor.x) - f64(p.origin.x), f64(anchor.y) - f64(p.origin.y)}
	return p.axes * rl.Matrix(linalg.matrix4_translate_f32({f32(d.x), f32(d.y), 0}))
}

tile_centre :: proc(key: [2]i32, size: f32) -> [2]f32 {
	return ([2]f32{f32(key.x), f32(key.y)} + 0.5) * size
}

// Updates the cache around target (km) and draws its tiles with material where place puts them (inside
// BeginMode3D).
tiles_update_draw :: proc(
	w: ^World,
	cache: ^Tile_Cache,
	size, reach: f32,
	build: Tile_Build,
	material: rl.Material,
	target: [2]f32,
	place: Placement,
) {
	keep := reach + 2 * size
	for &t in cache.tiles {
		if t.used && linalg.length(tile_centre(t.key, size) - target) > keep {
			if t.mesh.vertexCount > 0 do rl.UnloadMesh(t.mesh)
			t = {}
		}
	}
	start := time.tick_now()
	for b in 0 ..< TILE_BUILDS_PER_FRAME {
		if b > 0 && time.duration_milliseconds(time.tick_since(start)) > TILE_BUILD_MS do break
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
		if slot < 0 {
			// Full: the farthest tile out of reach makes room.
			far := reach + size
			for t, i in cache.tiles {
				if d := linalg.length(tile_centre(t.key, size) - target); d > far {
					far = d
					slot = i
				}
			}
			if slot < 0 do break
			if cache.tiles[slot].mesh.vertexCount > 0 do rl.UnloadMesh(cache.tiles[slot].mesh)
		}
		lo_km := [2]f32{f32(best.x), f32(best.y)} * size
		build_t := prof_begin(w, .Tile_Build)
		cache.tiles[slot] = {
			key  = best,
			mesh = build(w, lo_km, lo_km + size),
			used = true,
		}
		prof_end(w, .Tile_Build, build_t)
	}
	tiles_draw(cache, size, reach, material, target, place)
}

// Draws the built tiles whose square comes within reach (km) of target, inside BeginMode3D.
tiles_draw :: proc(
	cache: ^Tile_Cache,
	size, reach: f32,
	material: rl.Material,
	target: [2]f32,
	place: Placement,
) {
	for t in cache.tiles {
		if !t.used || t.mesh.vertexCount == 0 do continue
		gap := linalg.max(linalg.abs(tile_centre(t.key, size) - target) - size / 2, 0)
		if linalg.length(gap) > reach do continue
		rl.DrawMesh(t.mesh, material, place_at(place, [2]f32{f32(t.key.x), f32(t.key.y)} * size))
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
