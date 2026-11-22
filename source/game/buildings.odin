package game

import "core:compress/deflate"
import "core:math"
import "core:math/linalg"
import "core:mem/virtual"
import rl "vendor:raylib"

// 3D buildings (Lars, 2026-11-21: "ik wil 3d gebouwen"): the OSM buildings within 1 km of each city, baked by
// tools/bake_buildings into assets/buildings.bin.gz (format there). One mesh per city: the walls and a flat
// roof, raised from the ground plane to -height (world z points down). They grow out of the ground by their size
// on the screen (BUILDINGS_FADE_PX_0 to _1), so the country view stays flat and light.
BUILDINGS_DATA :: #load("../../assets/buildings.bin.gz")
BUILDINGS_MAX_CITIES :: 32
// A building smaller than a pixel covers a pixel in one frame and misses it in the next: thousands of them
// sparkled while the camera zoomed (zoom 4 and 5: 0.09 % of the pixels flickered, measured with --script). So
// the vertex shader measures each one on the screen, by its depth: below FADE_PX_0 it is flat and has the
// color of the ground under it (what the map shows there anyway), at FADE_PX_1 its own height and colors.
// The size measured is the smallest thing this shader draws, the narrowest generated building (towns.odin).
BUILDINGS_FADE_PX_0 :: 1.5
BUILDINGS_FADE_PX_1 :: 6.0
BUILDINGS_FEATURE_KM :: 2 * TOWN_HALF_MIN * TOWN_LOT_M / 1000
// Cities further than this from the camera target (km, plus the view's own size) are not drawn.
BUILDINGS_CULL_KM :: 6.0
BUILDINGS_POS_UNIT_M :: 0.5
BUILDINGS_RADIUS_KM :: 1.0 // RADIUS_KM of the bake
// Taller than real, so they read in the chase view where a street is a few pixels wide.
BUILDINGS_HEIGHT_X :: 1.6
// Shares of the roofs drawn with solar panels and with plants (ours: a solarpunk map, as the street view's flat
// roofs, notes.txt). Picked by a hash of the building, so a roof keeps its kind between runs.
BUILDINGS_SOLAR_ROOFS :: 0.3
BUILDINGS_GREEN_ROOFS :: 0.25

Buildings :: struct {
	meshes:   [BUILDINGS_MAX_CITIES]rl.Mesh,
	origins:  [BUILDINGS_MAX_CITIES][2]f32,
	count:    int,
	material: rl.Material,
	loc:      struct {
		roof,
		solar_roof,
		green_roof,
		wall,
		tree,
		city,
		park,
		fog_c,
		fog_r,
		fade_px,
		feature_px,
		sun_dir,
		sun_tint,
		amb_tint: i32,
	},
	ready:    bool,
}

// vertexColor.r = ambient occlusion (0..1), .g = 1 on the roof, .b = 1 for a tree clump (nature.odin, same
// shader), .a the roof kind (roof_alpha). vertexNormal is the surface normal in map space (x east, y south, z
// down). The roof, wall and sun/sky tint colors come from the palette and sky_edit as uniforms.
// feature_px: the size of BUILDINGS_FEATURE_KM on the screen at a view depth (clip w) of 1 km, so w gives its
// size at a vertex; fade_px as BUILDINGS_FADE_PX_0 and _1. Fog as LINE_VS.
BUILDINGS_VS :: `#version 330
in vec3 vertexPosition;
in vec3 vertexNormal;
in vec4 vertexColor;
uniform mat4 mvp;
uniform vec3 roof;
uniform vec3 solar_roof;
uniform vec3 green_roof;
uniform vec3 wall;
uniform vec3 tree;
uniform vec3 city;
uniform vec3 park;
uniform vec3 fog_color;
uniform vec2 fog_range;
uniform vec2 fade_px;
uniform float feature_px;
uniform vec3 sun_dir;
uniform vec3 sun_tint;
uniform vec3 amb_tint;
out vec4 fragColor;
void main() {
	float w = (mvp * vec4(vertexPosition.xy, 0.0, 1.0)).w;
	float grow = smoothstep(fade_px.x, fade_px.y, feature_px / max(w, 1e-6));
	vec4 p = mvp * vec4(vertexPosition.xy, vertexPosition.z * grow, 1.0);
	gl_Position = p;
	bool is_tree = vertexColor.b > 0.5;
	vec3 top = vertexColor.a > 0.75 ? roof : (vertexColor.a > 0.25 ? green_roof : solar_roof);
	float ndl = max(dot(normalize(vertexNormal), sun_dir), 0.0);
	vec3 lit = (amb_tint + sun_tint * ndl) * vertexColor.r;
	vec3 c = (is_tree ? tree : mix(wall, top, vertexColor.g)) * lit;
	c = mix(is_tree ? park : city, c, grow);
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
// vertexColor.a of a roof for BUILDINGS_VS from a building's hash: 0 solar panels, 128 plants, 255 plain.
roof_alpha :: proc(seed: u32) -> u8 {
	r := f32(hash_u32(seed) >> 8) / (1 << 24)
	if r < BUILDINGS_SOLAR_ROOFS do return 0
	if r < BUILDINGS_SOLAR_ROOFS + BUILDINGS_GREEN_ROOFS do return 128
	return 255
}

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
	prof_zone(w, .Buildings_Build)
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

	// Vertical AO: wall bases slightly darker than eaves; directional sun/sky shading runs in BUILDINGS_VS.
	bi, vi := 0, 0
	ring := make([dynamic][2]f32, 0, 64, tmp)
	idx := make([]int, 64, tmp)
	roof := make([dynamic][2]f32, 0, 192, tmp)
	for c in cities {
		origin := [2]f32{f32(c.origin.x), f32(c.origin.y)}
		pos := make([dynamic][3]f32, 0, int(c.vertex_count) * 9, tmp)
		norm := make([dynamic][3]f32, 0, int(c.vertex_count) * 9, tmp)
		col := make([dynamic][4]u8, 0, int(c.vertex_count) * 9, tmp)
		for _ in 0 ..< c.building_count {
			n, height := int(counts[bi]), f32(heights[bi]) / 1000
			bi += 1
			clear(&ring)
			q: [2]i32
			for k in 0 ..< n {
				q += delta(planes, total_v, vi + k)
				append(&ring, [2]f32{f32(q.x), f32(q.y)} * BUILDINGS_POS_UNIT_M / 1000)
			}
			vi += n
			if n < 3 do continue
			// Lower towards the edge of the baked circle, so the city rises out of the map instead of ending
			// in a wall.
			mid: [2]f32
			for p in ring do mid += p
			edge := linalg.length(mid / f32(n)) / BUILDINGS_RADIUS_KM
			height *= 1 - 0.75 * math.smoothstep(f32(0.6), 1, edge)
			height *= BUILDINGS_HEIGHT_X
			for k in 0 ..< n {
				a, e := ring[k], ring[(k + 1) % n]
				d := e - a
				l := math.sqrt(d.x * d.x + d.y * d.y)
				if l <= 0 do continue
				wn := [3]f32{-d.y / l, d.x / l, 0}
				top, low := u8(255), u8(178)
				// Counter-clockwise seen from outside: bottom a, bottom e, top e and bottom a, top e, top a.
				append(&pos, [3]f32{a.x, a.y, 0}, [3]f32{e.x, e.y, 0}, [3]f32{e.x, e.y, -height})
				append(&pos, [3]f32{a.x, a.y, 0}, [3]f32{e.x, e.y, -height}, [3]f32{a.x, a.y, -height})
				append(&norm, wn, wn, wn, wn, wn, wn)
				append(&col, [4]u8{low, 0, 0, 255}, [4]u8{low, 0, 0, 255}, [4]u8{top, 0, 0, 255})
				append(&col, [4]u8{low, 0, 0, 255}, [4]u8{top, 0, 0, 255}, [4]u8{top, 0, 0, 255})
			}
			clear(&roof)
			roof_triangles(ring[:], idx[:n], &roof)
			kind := roof_alpha(u32(bi) * 2654435761 + 11)
			for p in roof {
				append(&pos, [3]f32{p.x, p.y, -height})
				append(&norm, [3]f32{0, 0, -1})
				append(&col, [4]u8{255, 255, 0, kind})
			}
		}
		if len(pos) == 0 do continue
		m := rl.Mesh {
			vertexCount   = i32(len(pos)),
			triangleCount = i32(len(pos) / 3),
			vertices      = ([^]f32)(raw_data(pos)),
			normals       = ([^]f32)(raw_data(norm)),
			colors        = ([^]u8)(raw_data(col)),
		}
		rl.UploadMesh(&m, false)
		m.vertices, m.normals, m.colors = nil, nil, nil
		b.meshes[b.count] = m
		b.origins[b.count] = origin
		b.count += 1
	}
	b.material = rl.LoadMaterialDefault()
	sh := rl.LoadShaderFromMemory(BUILDINGS_VS, BUILDINGS_FS)
	b.material.shader = sh
	b.loc = {
		roof       = rl.GetShaderLocation(sh, "roof"),
		solar_roof = rl.GetShaderLocation(sh, "solar_roof"),
		green_roof = rl.GetShaderLocation(sh, "green_roof"),
		wall       = rl.GetShaderLocation(sh, "wall"),
		tree       = rl.GetShaderLocation(sh, "tree"),
		fog_c      = rl.GetShaderLocation(sh, "fog_color"),
		city       = rl.GetShaderLocation(sh, "city"),
		park       = rl.GetShaderLocation(sh, "park"),
		fog_r      = rl.GetShaderLocation(sh, "fog_range"),
		fade_px    = rl.GetShaderLocation(sh, "fade_px"),
		feature_px = rl.GetShaderLocation(sh, "feature_px"),
		sun_dir    = rl.GetShaderLocation(sh, "sun_dir"),
		sun_tint   = rl.GetShaderLocation(sh, "sun_tint"),
		amb_tint   = rl.GetShaderLocation(sh, "amb_tint"),
	}
	b.ready = true
	logf(w, "buildings", "%d buildings in %d cities", total_b, b.count)
}

// The size of BUILDINGS_FEATURE_KM on the screen at a view depth of 1 km (px), and whether the nearest ground in
// view shows it at BUILDINGS_FADE_PX_0 or more, so anything of the buildings' shader is seen. The nearest ground
// is the middle of the bottom screen edge, at depth dist cos(tilt) cos(fov / 2) / cos(tilt - fov / 2).
buildings_feature_px :: proc(c: ^Cam) -> (px: f32, shown: bool) {
	dist := linalg.length(c.view.position - c.view.target)
	px = BUILDINGS_FEATURE_KM * c.px_per_km * dist
	half_fov := f32(CAM_FOV_DEG) * math.RAD_PER_DEG / 2
	near := dist * math.cos(c.pose.tilt) * math.cos(half_fov) / max(math.cos(c.pose.tilt - half_fov), 1e-3)
	return px, px / max(near, 1e-6) >= BUILDINGS_FADE_PX_0
}

// Inside BeginMode3D, after the roads. fog as the lines (game.odin passes the same range), feature_px from
// buildings_feature_px, cities within reach (km) of target are drawn where place puts them (a city mesh is
// relative to its origin). look gives the roof, wall, tree and fog colors and the ground under them.
Buildings_Look :: struct {
	roof, solar_roof, green_roof, wall, tree, city, park, fog, sun_dir, sun_tint, amb_tint: [3]f32,
}

buildings_draw :: proc(
	w: ^World,
	fog: [2]f32,
	feature_px: f32,
	target: [2]f32,
	reach: f32,
	place: Placement,
	look: Buildings_Look,
) {
	prof_zone(w, .Buildings_Draw)
	b := &w.buildings
	if !b.ready do return
	roof, solar_roof, green_roof := look.roof, look.solar_roof, look.green_roof
	wall, tree, city, park, horizon := look.wall, look.tree, look.city, look.park, look.fog
	sun_dir, sun_tint, amb_tint := look.sun_dir, look.sun_tint, look.amb_tint
	fog := fog
	fade := [2]f32{BUILDINGS_FADE_PX_0, BUILDINGS_FADE_PX_1}
	feature_px := feature_px
	sh := b.material.shader
	rl.SetShaderValue(sh, b.loc.roof, &roof, .VEC3)
	rl.SetShaderValue(sh, b.loc.solar_roof, &solar_roof, .VEC3)
	rl.SetShaderValue(sh, b.loc.green_roof, &green_roof, .VEC3)
	rl.SetShaderValue(sh, b.loc.wall, &wall, .VEC3)
	rl.SetShaderValue(sh, b.loc.tree, &tree, .VEC3)
	rl.SetShaderValue(sh, b.loc.city, &city, .VEC3)
	rl.SetShaderValue(sh, b.loc.park, &park, .VEC3)
	rl.SetShaderValue(sh, b.loc.fog_c, &horizon, .VEC3)
	rl.SetShaderValue(sh, b.loc.fog_r, &fog, .VEC2)
	rl.SetShaderValue(sh, b.loc.fade_px, &fade, .VEC2)
	rl.SetShaderValue(sh, b.loc.feature_px, &feature_px, .FLOAT)
	rl.SetShaderValue(sh, b.loc.sun_dir, &sun_dir, .VEC3)
	rl.SetShaderValue(sh, b.loc.sun_tint, &sun_tint, .VEC3)
	rl.SetShaderValue(sh, b.loc.amb_tint, &amb_tint, .VEC3)
	for i in 0 ..< b.count {
		d := b.origins[i] - target
		if math.sqrt(d.x * d.x + d.y * d.y) > reach do continue
		rl.DrawMesh(b.meshes[i], b.material, place_at(place, b.origins[i]))
	}
}

// The map's colors and golden-hour sun/sky lighting for the buildings, trees and fog.
buildings_map_look :: proc(w: ^World) -> Buildings_Look {
	pal := palette(w)
	sun_tint, amb_tint := map_sun_tints(w)
	return {
		roof = rl.ColorNormalize(pal.roof).rgb,
		solar_roof = rl.ColorNormalize(pal.solar_roof).rgb,
		green_roof = rl.ColorNormalize(pal.green_roof).rgb,
		wall = rl.ColorNormalize(pal.wall).rgb,
		tree = rl.ColorNormalize(pal.tree).rgb,
		city = rl.ColorNormalize(pal.city).rgb,
		park = rl.ColorNormalize(pal.park).rgb,
		fog = rl.ColorNormalize(map_horizon_color(w)).rgb,
		sun_dir = map_sun_dir(street_look(w)),
		sun_tint = sun_tint,
		amb_tint = amb_tint,
	}
}

buildings_unload :: proc(b: ^Buildings) {
	if !b.ready do return
	for m in b.meshes[:b.count] do rl.UnloadMesh(m)
	rl.UnloadShader(b.material.shader)
	b^ = {}
}
