// author: nasr
package game

import "core:math"
import "core:math/linalg"
import "core:strings"
import rl "vendor:raylib"

EARTH_RADIUS_KM :: 6371.0
// Belgium centre (MAP_W_KM / 2, MAP_H_KM / 2) in the bake projection (notes.txt).
BELGIUM_LAT0 :: 51.56 - (MAP_H_KM * 0.5) / 111.32
BELGIUM_LON0 :: 2.38 + (MAP_W_KM * 0.5) / (111.32 * 0.63607822) // cos(50.5 deg)

WORLD_MAGIC :: 0x444C5257 // "WRLD"
WORLD_VERSION :: 1
WORLD_MASK_W :: 2048
WORLD_MASK_H :: 1024

WORLD_DATA :: #load("../../assets/world.bin")

World_Header :: struct {
	magic, version:                      u32,
	mask_w, mask_h:                      u32,
	line_count, point_count, city_count: u32,
}

World_Line :: struct {
	start, count, kind: u32,
}

World_City :: struct {
	lon, lat: f32,
	rank:     u8,
	name:     [47]u8,
}

World_Map :: struct {
	mask:   []u8,
	lines:  []World_Line,
	points: [][2]f32,
	cities: []World_City,
}

Globe_GPU :: struct {
	ready:       bool,
	sphere:      rl.Mesh,
	lines:       rl.Mesh,
	mask_tex:    rl.Texture2D,
	material:    rl.Material,
	loc_ocean:   i32,
	loc_land:    i32,
	loc_grid:    i32,
	loc_atmo:    i32,
	loc_cam_pos: i32,
	loc_fade:    i32,
}

GLOBE_VS :: `#version 330
in vec3 vertexPosition;
in vec2 vertexTexCoord;
in vec3 vertexNormal;
uniform mat4 mvp;
out vec2 v_uv;
out vec3 v_world;
out vec3 v_norm;
void main() {
	v_uv = vertexTexCoord;
	v_world = vertexPosition;
	v_norm = vertexNormal;
	gl_Position = mvp * vec4(vertexPosition, 1.0);
}
`

GLOBE_FS :: `#version 330
in vec2 v_uv;
in vec3 v_world;
in vec3 v_norm;
uniform sampler2D texture0;
uniform vec3 u_ocean;
uniform vec3 u_land;
uniform vec3 u_grid;
uniform vec3 u_atmo;
uniform vec3 u_cam_pos;
uniform float u_fade;
out vec4 finalColor;
void main() {
	float land = texture(texture0, v_uv).r;
	vec3 col = mix(u_ocean, u_land, smoothstep(0.35, 0.65, land));

	// Subtle 15-degree graticule when zoomed out on the globe.
	vec2 deg = vec2(v_uv.x * 24.0, v_uv.y * 12.0);
	vec2 fw = max(fwidth(deg), vec2(1e-4));
	vec2 g = abs(fract(deg - 0.5) - 0.5) / fw;
	float line = 1.0 - min(min(g.x, g.y), 1.0);
	col = mix(col, u_grid, line * 0.22 * u_fade);

	vec3 n = normalize(v_norm);
	vec3 v = normalize(u_cam_pos - v_world);
	float ndv = max(dot(n, v), 0.0);
	float rim = pow(1.0 - ndv, 3.2);
	col = mix(col * (0.82 + 0.18 * ndv), u_atmo, rim * 0.55 * u_fade);
	finalColor = vec4(col, 1.0);
}
`

earth_centre :: proc() -> [3]f32 {
	return {MAP_W_KM * 0.5, MAP_H_KM * 0.5, EARTH_RADIUS_KM}
}

// Unit outward normal on the Earth sphere in Drift's world space (x east, y south, z down),
// aligned so Belgium's centre (BELGIUM_LON0, BELGIUM_LAT0) has normal (0, 0, -1).
globe_normal :: proc(lon_deg, lat_deg: f32) -> [3]f32 {
	phi := lat_deg * math.RAD_PER_DEG
	dl := (lon_deg - BELGIUM_LON0) * math.RAD_PER_DEG
	phi0 := f32(BELGIUM_LAT0 * math.RAD_PER_DEG)
	cp, sp := math.cos(phi), math.sin(phi)
	cd, sd := math.cos(dl), math.sin(dl)
	cp0, sp0 := math.cos(phi0), math.sin(phi0)
	return {cp * sd, sp0 * cp * cd - cp0 * sp, -(cp0 * cp * cd + sp0 * sp)}
}

load_world :: proc() -> (wm: World_Map, ok: bool) {
	data := WORLD_DATA
	if len(data) < size_of(World_Header) do return {}, false
	h := (^World_Header)(raw_data(data))
	if h.magic != WORLD_MAGIC || h.version != WORLD_VERSION do return {}, false
	if h.mask_w != WORLD_MASK_W || h.mask_h != WORLD_MASK_H do return {}, false

	off := size_of(World_Header)
	bad := false
	take :: proc(data: []u8, off: ^int, count: u32, $T: typeid, bad: ^bool) -> []T {
		size := u64(count) * size_of(T)
		if u64(off^) + size > u64(len(data)) {
			bad^ = true
			return nil
		}
		s := ([^]T)(raw_data(data[off^:]))[:count]
		off^ += int(size)
		return s
	}

	mask_bytes :: (WORLD_MASK_W * WORLD_MASK_H) / 8
	wm.mask = take(data, &off, mask_bytes, u8, &bad)
	wm.lines = take(data, &off, h.line_count, World_Line, &bad)
	wm.points = take(data, &off, h.point_count, [2]f32, &bad)
	wm.cities = take(data, &off, h.city_count, World_City, &bad)
	if bad || off != len(data) do return {}, false
	for l in wm.lines {
		if u64(l.start) + u64(l.count) > u64(len(wm.points)) do return {}, false
	}
	return wm, true
}

globe_build :: proc(w: ^World) {
	g := &w.globe
	if g.ready || len(w.world_map.mask) == 0 do return

	// Unpack the 1-bit land mask into an R8 texture so bilinear filtering gives smooth coastlines.
	pixels := make([]u8, WORLD_MASK_W * WORLD_MASK_H, context.temp_allocator)
	for i in 0 ..< WORLD_MASK_W * WORLD_MASK_H {
		if (w.world_map.mask[i >> 3] & (1 << u32(i & 7))) != 0 do pixels[i] = 255
	}
	img := rl.Image {
		data    = raw_data(pixels),
		width   = WORLD_MASK_W,
		height  = WORLD_MASK_H,
		mipmaps = 1,
		format  = .UNCOMPRESSED_GRAYSCALE,
	}
	g.mask_tex = rl.LoadTextureFromImage(img)
	rl.SetTextureFilter(g.mask_tex, .BILINEAR)
	rl.SetTextureWrap(g.mask_tex, .REPEAT)

	// UV sphere with radius slightly below z = 0 so Belgium's flat map sits cleanly above it.
	SLICES :: 128
	STACKS :: 64
	SPHERE_R :: EARTH_RADIUS_KM - 0.6
	ec := earth_centre()
	vcount :: SLICES * STACKS * 6
	spos := make([][3]f32, vcount, context.temp_allocator)
	suv := make([][2]f32, vcount, context.temp_allocator)
	snorm := make([][3]f32, vcount, context.temp_allocator)
	vi := 0
	for j in 0 ..< STACKS {
		v0 := f32(j) / STACKS
		v1 := f32(j + 1) / STACKS
		lat0 := 90 - v0 * 180
		lat1 := 90 - v1 * 180
		for i in 0 ..< SLICES {
			u0 := f32(i) / SLICES
			u1 := f32(i + 1) / SLICES
			lon0 := -180 + u0 * 360
			lon1 := -180 + u1 * 360
			n00 := globe_normal(lon0, lat0)
			n10 := globe_normal(lon1, lat0)
			n11 := globe_normal(lon1, lat1)
			n01 := globe_normal(lon0, lat1)
			// Outward-facing counter-clockwise winding when viewed from outside the sphere.
			tris := [6]struct {
				n:  [3]f32,
				uv: [2]f32,
			} {
				{n00, {u0, v0}},
				{n01, {u0, v1}},
				{n11, {u1, v1}},
				{n00, {u0, v0}},
				{n11, {u1, v1}},
				{n10, {u1, v0}},
			}
			for t in tris {
				spos[vi] = ec + t.n * SPHERE_R
				suv[vi] = t.uv
				snorm[vi] = t.n
				vi += 1
			}
		}
	}
	g.sphere = {
		vertexCount   = i32(vcount),
		triangleCount = i32(vcount / 3),
		vertices      = ([^]f32)(raw_data(spos)),
		texcoords     = ([^]f32)(raw_data(suv)),
		normals       = ([^]f32)(raw_data(snorm)),
	}
	rl.UploadMesh(&g.sphere, false)
	g.sphere.vertices = nil
	g.sphere.texcoords = nil
	g.sphere.normals = nil

	shader := rl.LoadShaderFromMemory(GLOBE_VS, GLOBE_FS)
	g.material = rl.LoadMaterialDefault()
	g.material.shader = shader
	g.material.maps[rl.MaterialMapIndex.ALBEDO].texture = g.mask_tex
	g.loc_ocean = rl.GetShaderLocation(shader, "u_ocean")
	g.loc_land = rl.GetShaderLocation(shader, "u_land")
	g.loc_grid = rl.GetShaderLocation(shader, "u_grid")
	g.loc_atmo = rl.GetShaderLocation(shader, "u_atmo")
	g.loc_cam_pos = rl.GetShaderLocation(shader, "u_cam_pos")
	g.loc_fade = rl.GetShaderLocation(shader, "u_fade")

	// Coastline and country border segments on the sphere, slightly above the sphere surface.
	LINE_R :: EARTH_RADIUS_KM - 0.35
	segs := 0
	for l in w.world_map.lines {
		if l.count >= 2 do segs += int(l.count) - 1
	}
	if segs > 0 {
		lv := segs * 6
		lpos := make([][3]f32, lv, context.temp_allocator)
		lother := make([][3]f32, lv, context.temp_allocator)
		lcol := make([][4]u8, lv, context.temp_allocator)
		li := 0
		for l in w.world_map.lines {
			pts := w.world_map.points[l.start:][:l.count]
			alpha: u8 = l.kind == 0 ? 210 : 120
			c := [4]u8{u8(Map_Kind.Border), 0, 0, alpha}
			for k in 1 ..< len(pts) {
				a := ec + globe_normal(pts[k - 1].x, pts[k - 1].y) * LINE_R
				b := ec + globe_normal(pts[k].x, pts[k].y) * LINE_R
				for m in li ..< li + 6 {
					lpos[m] = a
					lother[m] = b
					lcol[m] = c
				}
				li += 6
			}
		}
		g.lines = line_mesh_upload(lpos, lother, lcol, false)
	}
	g.ready = true
}

globe_unload :: proc(g: ^Globe_GPU) {
	if !g.ready do return
	rl.UnloadMesh(g.sphere)
	if g.lines.vertexCount > 0 do rl.UnloadMesh(g.lines)
	rl.UnloadTexture(g.mask_tex)
	rl.UnloadShader(g.material.shader)
	g^ = {}
}

foreign _ {
	rlSetClipPlanes :: proc "c" (near, far: f64) ---
}

globe_set_clip :: proc(w: ^World) {
	dist := f64(linalg.length(w.cam.view.position - w.cam.view.target))
	if dist < 1000 {
		rlSetClipPlanes(0.05, 4000)
	} else {
		rlSetClipPlanes(dist * 0.01, dist + f64(EARTH_RADIUS_KM) * 2.5)
	}
}

globe_draw :: proc(w: ^World) {
	g := &w.globe
	if !g.ready do globe_build(w)
	if !g.ready do return

	pal := palette(w)
	ocean := rl.ColorNormalize(rl.Color{185, 212, 236, 255}).rgb
	land := rl.ColorNormalize(pal.land).rgb
	grid := rl.ColorNormalize(pal.text_2).rgb
	atmo := rl.ColorNormalize(pal.accent).rgb
	cam_pos := w.cam.view.position
	fade := clamp((-w.cam.pose.zoom - 0.5) / 2.0, 0, 1)

	sh := g.material.shader
	rl.SetShaderValue(sh, g.loc_ocean, &ocean, .VEC3)
	rl.SetShaderValue(sh, g.loc_land, &land, .VEC3)
	rl.SetShaderValue(sh, g.loc_grid, &grid, .VEC3)
	rl.SetShaderValue(sh, g.loc_atmo, &atmo, .VEC3)
	rl.SetShaderValue(sh, g.loc_cam_pos, &cam_pos, .VEC3)
	rl.SetShaderValue(sh, g.loc_fade, &fade, .FLOAT)
	rl.DrawMesh(g.sphere, g.material, rl.Matrix(1))
}

globe_draw_lines :: proc(w: ^World) {
	g := &w.globe
	if !g.ready || g.lines.vertexCount <= 0 do return
	rl.DrawMesh(g.lines, w.line_meshes.material, rl.Matrix(1))
}

globe_labels_draw :: proc(w: ^World) {
	z := w.cam.pose.zoom
	if z >= -0.8 || len(w.world_map.cities) == 0 do return

	max_rank: u8 = 0
	if z > -4.5 do max_rank = 1
	if z > -3.5 do max_rank = 2
	if z > -2.5 do max_rank = 3
	if z > -1.6 do max_rank = 4

	pal := palette(w)
	ec := earth_centre()
	cam_pos := w.cam.view.position
	placed := make([dynamic]rl.Rectangle, 0, 64, context.temp_allocator)
	fade := clamp((-z - 0.8) / 0.8, 0, 1)
	col := rl.ColorAlpha(pal.text_2, 0.9 * fade)
	dot_col := rl.ColorAlpha(pal.text_2, 0.7 * fade)

	for &c in w.world_map.cities {
		if c.rank > max_rank do break
		n := globe_normal(c.lon, c.lat)
		pos := ec + n * EARTH_RADIUS_KM
		if linalg.dot(n, cam_pos - pos) <= 0 do continue
		px, ok := cam_to_screen(w, {pos.x, pos.y, -pos.z * 1000})
		if !ok do continue
		name := strings.truncate_to_byte(string(c.name[:]), 0)
		if name == "" do continue
		sz := ui_text_size(w, name, .Figtree_500, 12)
		r := rl.Rectangle{px.x + 6, px.y - sz.y / 2, sz.x + 4, sz.y}
		hit := false
		for p in placed do if rl.CheckCollisionRecs(r, p) {
			hit = true
			break
		}
		if hit do continue
		append(&placed, r)
		rl.DrawCircleV(px, 2, dot_col)
		ui_text(w, {r.x, r.y}, name, .Figtree_500, 12, col)
	}
}
