package game

import "core:compress/deflate"
import "core:math"
import "core:math/linalg"
import "core:mem/virtual"
import rl "vendor:raylib"

// 3D buildings (Lars, 2026-11-21: "ik wil 3d gebouwen"): the OSM buildings within 1 km of each city, baked by
// tools/bake_buildings into assets/buildings.bin.gz (format there). One mesh per city: the walls and a flat
// roof, raised from the ground plane to -height (world z points down). They grow out of the ground while the
// camera zooms in (BUILDINGS_ZOOM_0 to _1), so the country view stays flat and light.
BUILDINGS_DATA :: #load("../../assets/buildings.bin.gz")
BUILDINGS_MAX_CITIES :: 32
BUILDINGS_ZOOM_0 :: 3.5
BUILDINGS_ZOOM_1 :: 5.0
// Cities further than this from the camera target (km, plus the view's own size) are not drawn.
BUILDINGS_CULL_KM :: 6.0
BUILDINGS_POS_UNIT_M :: 0.5
BUILDINGS_RADIUS_KM :: 1.0 // RADIUS_KM of the bake
// Taller than real, so they read in the chase view where a street is a few pixels wide.
BUILDINGS_HEIGHT_X :: 1.6

Buildings :: struct {
	meshes:   [BUILDINGS_MAX_CITIES]rl.Mesh,
	origins:  [BUILDINGS_MAX_CITIES][2]f32,
	count:    int,
	material: rl.Material,
	loc:      struct {
		roof, wall, tree, fog_c, fog_r, scale: i32,
	},
	ready:    bool,
}

// vertexColor.r = light (0..1), .g = 1 on the roof, .b = 1 for a tree clump (nature.odin, same shader). The roof and wall colors come from the palette, so a theme
// switch rebuilds nothing. height_scale squashes the buildings while they grow in; fog as LINE_VS.
BUILDINGS_VS :: `#version 330
in vec3 vertexPosition;
in vec4 vertexColor;
uniform mat4 mvp;
uniform vec3 roof;
uniform vec3 wall;
uniform vec3 tree;
uniform vec3 fog_color;
uniform vec2 fog_range;
uniform float height_scale;
out vec4 fragColor;
void main() {
	vec4 p = mvp * vec4(vertexPosition.xy, vertexPosition.z * height_scale, 1.0);
	gl_Position = p;
	vec3 c = (vertexColor.b > 0.5 ? tree : mix(wall, roof, vertexColor.g)) * vertexColor.r;
	float f = clamp((p.w - fog_range.x) / max(fog_range.y - fog_range.x, 1e-3), 0.0, 1.0);
	fragColor = vec4(mix(c, fog_color, f * f), 1.0);
}
`

BUILDINGS_FS :: `#version 330
in vec4 fragColor;
out vec4 finalColor;
void main() {
	finalColor = fragColor;
}
`

// Sign of the turn a -> b -> c, positive where a counter-clockwise ring (on the map, y south) turns left.
turn :: proc(a, b, c: [2]f32) -> f32 {
	u, v := b - a, c - b
	return u.y * v.x - u.x * v.y
}

// Ear clipping of a small counter-clockwise ring into out (3 points per triangle). A ring that crosses itself
// can leave no ear: the rest becomes a fan, good enough for a roof.
roof_triangles :: proc(ring: [][2]f32, idx: []int, out: ^[dynamic][2]f32) {
	n := len(ring)
	for i in 0 ..< n do idx[i] = i
	left := n
	for left > 3 {
		found := false
		for i in 0 ..< left {
			a, b, c := ring[idx[(i + left - 1) % left]], ring[idx[i]], ring[idx[(i + 1) % left]]
			if turn(a, b, c) <= 0 do continue
			inside := false
			for j in 0 ..< left {
				p := ring[idx[j]]
				if p == a || p == b || p == c do continue
				if turn(a, b, p) >= 0 && turn(b, c, p) >= 0 && turn(c, a, p) >= 0 {
					inside = true
					break
				}
			}
			if inside do continue
			append(out, a, b, c)
			copy(idx[i:left - 1], idx[i + 1:left])
			left -= 1
			found = true
			break
		}
		if !found do break
	}
	for i in 1 ..< left - 1 do append(out, ring[idx[0]], ring[idx[i]], ring[idx[i + 1]])
}

// Unpacks the buildings into one GPU mesh per city. Staging memory is a local arena, freed at the end; the
// meshes keep no CPU arrays. Needs the window.
buildings_build :: proc(w: ^World) {
	b := &w.buildings
	scratch: virtual.Arena
	if virtual.arena_init_growing(&scratch) != nil do return
	defer virtual.arena_destroy(&scratch)
	tmp := virtual.arena_allocator(&scratch)

	unzipped := make([dynamic]u8, 0, 4 << 20, tmp)
	if err := deflate.inflate_gzip(&unzipped, BUILDINGS_DATA, allocator = tmp); err != nil {
		logf(w, "buildings", "buildings.bin.gz does not unpack: %v", err)
		return
	}
	data := unzipped[:]
	Header :: struct {
		magic, version, city_count, _: u32le,
	}
	City :: struct {
		origin:                       [2]f32le,
		building_count, vertex_count: u32le,
	}
	if len(data) < size_of(Header) do return
	h := (^Header)(raw_data(data))^
	if h.magic != 0x44425244 || h.version != 1 || int(h.city_count) > BUILDINGS_MAX_CITIES {
		logf(
			w,
			"buildings",
			"buildings.bin: wrong magic, version or more than %d cities",
			BUILDINGS_MAX_CITIES,
		)
		return
	}
	cities := ([^]City)(raw_data(data[size_of(Header):]))[:h.city_count]
	off := size_of(Header) + int(h.city_count) * size_of(City)
	total_b, total_v := 0, 0
	for c in cities {
		total_b += int(c.building_count)
		total_v += int(c.vertex_count)
	}
	if len(data) != off + total_b * 2 + total_v * 4 {
		logf(
			w,
			"buildings",
			"buildings.bin: %d bytes, the header says %d",
			len(data),
			off + total_b * 2 + total_v * 4,
		)
		return
	}
	counts := data[off:][:total_b]
	heights := data[off + total_b:][:total_b]
	planes := data[off + total_b * 2:]
	delta :: proc(planes: []u8, total_v, i: int) -> [2]i32 {
		x := i16(u16(planes[i]) | u16(planes[total_v + i]) << 8)
		y := i16(u16(planes[2 * total_v + i]) | u16(planes[3 * total_v + i]) << 8)
		return {i32(x), i32(y)}
	}

	// Light from the north-west like the hillshade; the bottom of a wall a little darker.
	LIGHT :: [2]f32{-0.7071, -0.7071}
	bi, vi := 0, 0
	ring := make([dynamic][2]f32, 0, 64, tmp)
	idx := make([]int, 64, tmp)
	roof := make([dynamic][2]f32, 0, 192, tmp)
	for c in cities {
		origin := [2]f32{f32(c.origin.x), f32(c.origin.y)}
		pos := make([dynamic][3]f32, 0, int(c.vertex_count) * 9, tmp)
		col := make([dynamic][4]u8, 0, int(c.vertex_count) * 9, tmp)
		for _ in 0 ..< c.building_count {
			n, height := int(counts[bi]), f32(heights[bi]) / 1000
			bi += 1
			clear(&ring)
			q: [2]i32
			for k in 0 ..< n {
				q += delta(planes, total_v, vi + k)
				append(&ring, origin + [2]f32{f32(q.x), f32(q.y)} * BUILDINGS_POS_UNIT_M / 1000)
			}
			vi += n
			if n < 3 do continue
			// Lower towards the edge of the baked circle, so the city rises out of the map instead of ending
			// in a wall.
			mid: [2]f32
			for p in ring do mid += p
			edge := linalg.length(mid / f32(n) - origin) / BUILDINGS_RADIUS_KM
			height *= 1 - 0.75 * math.smoothstep(f32(0.6), 1, edge)
			height *= BUILDINGS_HEIGHT_X
			for k in 0 ..< n {
				a, e := ring[k], ring[(k + 1) % n]
				d := e - a
				l := math.sqrt(d.x * d.x + d.y * d.y)
				if l <= 0 do continue
				normal := [2]f32{-d.y, d.x} / l
				light := 0.68 + 0.22 * (normal.x * LIGHT.x + normal.y * LIGHT.y)
				top, low := u8(light * 255), u8(light * 0.7 * 255)
				// Counter-clockwise seen from outside: bottom a, bottom e, top e and bottom a, top e, top a.
				append(&pos, [3]f32{a.x, a.y, 0}, [3]f32{e.x, e.y, 0}, [3]f32{e.x, e.y, -height})
				append(&pos, [3]f32{a.x, a.y, 0}, [3]f32{e.x, e.y, -height}, [3]f32{a.x, a.y, -height})
				append(&col, [4]u8{low, 0, 0, 255}, [4]u8{low, 0, 0, 255}, [4]u8{top, 0, 0, 255})
				append(&col, [4]u8{low, 0, 0, 255}, [4]u8{top, 0, 0, 255}, [4]u8{top, 0, 0, 255})
			}
			clear(&roof)
			roof_triangles(ring[:], idx[:n], &roof)
			for p in roof {
				append(&pos, [3]f32{p.x, p.y, -height})
				append(&col, [4]u8{255, 255, 0, 255})
			}
		}
		if len(pos) == 0 do continue
		m := rl.Mesh {
			vertexCount   = i32(len(pos)),
			triangleCount = i32(len(pos) / 3),
			vertices      = ([^]f32)(raw_data(pos)),
			colors        = ([^]u8)(raw_data(col)),
		}
		rl.UploadMesh(&m, false)
		m.vertices, m.colors = nil, nil
		b.meshes[b.count] = m
		b.origins[b.count] = origin
		b.count += 1
	}
	b.material = rl.LoadMaterialDefault()
	sh := rl.LoadShaderFromMemory(BUILDINGS_VS, BUILDINGS_FS)
	b.material.shader = sh
	b.loc = {
		roof  = rl.GetShaderLocation(sh, "roof"),
		wall  = rl.GetShaderLocation(sh, "wall"),
		tree  = rl.GetShaderLocation(sh, "tree"),
		fog_c = rl.GetShaderLocation(sh, "fog_color"),
		fog_r = rl.GetShaderLocation(sh, "fog_range"),
		scale = rl.GetShaderLocation(sh, "height_scale"),
	}
	b.ready = true
	logf(w, "buildings", "%d buildings in %d cities", total_b, b.count)
}

// Inside BeginMode3D, after the roads. fog as the lines (game.odin passes the same range).
buildings_draw :: proc(w: ^World, fog: [2]f32) {
	b := &w.buildings
	if !b.ready do return
	grow := clamp((w.cam.pose.zoom - BUILDINGS_ZOOM_0) / (BUILDINGS_ZOOM_1 - BUILDINGS_ZOOM_0), 0, 1)
	if grow <= 0 do return
	grow = ease_in_out(grow)
	pal := palette(w)
	roof := rl.ColorNormalize(pal.roof).rgb
	wall := rl.ColorNormalize(pal.wall).rgb
	tree := rl.ColorNormalize(pal.tree).rgb
	horizon := rl.ColorNormalize(pal.horizon).rgb
	fog := fog
	sh := b.material.shader
	rl.SetShaderValue(sh, b.loc.roof, &roof, .VEC3)
	rl.SetShaderValue(sh, b.loc.wall, &wall, .VEC3)
	rl.SetShaderValue(sh, b.loc.tree, &tree, .VEC3)
	rl.SetShaderValue(sh, b.loc.fog_c, &horizon, .VEC3)
	rl.SetShaderValue(sh, b.loc.fog_r, &fog, .VEC2)
	rl.SetShaderValue(sh, b.loc.scale, &grow, .FLOAT)
	target := w.cam.view.target.xy
	view_km := w.cam.screen.x / max(w.cam.px_per_km, 1e-3)
	for i in 0 ..< b.count {
		d := b.origins[i] - target
		if math.sqrt(d.x * d.x + d.y * d.y) > BUILDINGS_CULL_KM + view_km do continue
		rl.DrawMesh(b.meshes[i], b.material, rl.Matrix(1))
	}
}

buildings_unload :: proc(b: ^Buildings) {
	if !b.ready do return
	for m in b.meshes[:b.count] do rl.UnloadMesh(m)
	rl.UnloadShader(b.material.shader)
	b^ = {}
}
