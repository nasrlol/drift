// author: nasr
package game

import "core:math"
import "core:math/linalg"
import "core:strings"
import rl "vendor:raylib"

EARTH_RADIUS_KM :: 6371.0
// Belgium centre (MAP_W_KM / 2, MAP_H_KM / 2) in the bake projection (notes.txt).
BELGIUM_LAT0 :: MAP_LAT0 - (MAP_H_KM * 0.5) / KM_PER_DEG
BELGIUM_LON0 :: MAP_LON0 + (MAP_W_KM * 0.5) / (KM_PER_DEG * MAP_COS_LAT)
// Round Belgium the globe lies flat in the map's own projection, so its coastlines, borders and land meet the
// flat map exactly; from GLOBE_FLAT_DEG to GLOBE_ROUND_DEG away from Belgium's centre it bends into the sphere.
GLOBE_FLAT_DEG :: 4.0
GLOBE_ROUND_DEG :: 20.0

WORLD_MAGIC :: 0x444C5257 // "WRLD"
WORLD_VERSION :: 2
WORLD_MASK_W :: 2048
WORLD_MASK_H :: 1024

WORLD_DATA :: #load("../../assets/world.bin")

World_Header :: struct {
	magic, version:                      u32,
	mask_w, mask_h:                      u32,
	line_count, point_count, city_count: u32,
	region_w, region_h:                  u32,
	region_lon0, region_lat_top:         f32,
	region_deg_w, region_deg_h:          f32,
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
	region: []u8, // finer land mask round Belgium (tools/bake_world), header fields below
	region_w, region_h: int,
	region_rect: [4]f32, // lon0, lat_top, deg_w, deg_h
	lines:  []World_Line,
	points: [][2]f32,
	cities: []World_City,
}

Globe_GPU :: struct {
	ready:       bool,
	sphere:      rl.Mesh,
	lines:       rl.Mesh,
	mask_tex:    rl.Texture2D,
	region_tex:  rl.Texture2D,
	loc_region:  i32,
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
uniform sampler2D texture1; // the finer land mask round Belgium
uniform vec4 u_region; // lon0, lat_top, deg_w, deg_h
uniform vec3 u_ocean;
uniform vec3 u_land;
uniform vec3 u_grid;
uniform vec3 u_atmo;
uniform vec3 u_cam_pos;
uniform float u_fade;
out vec4 finalColor;
void main() {
	float land = texture(texture0, v_uv).r;
	vec2 ll = vec2(v_uv.x * 360.0 - 180.0, 90.0 - v_uv.y * 180.0);
	vec2 r = vec2((ll.x - u_region.x) / u_region.z, (u_region.y - ll.y) / u_region.w);
	if (u_region.z > 0.0 && r.x > 0.0 && r.x < 1.0 && r.y > 0.0 && r.y < 1.0) {
		// Fade to the world mask over the outer 10 % so the edge of the finer mask does not show.
		vec2 e = min(r, 1.0 - r) / 0.1;
		land = mix(land, texture(texture1, r).r, clamp(min(e.x, e.y), 0.0, 1.0));
	}
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

// Point at lon / lat, depth km under the map plane: the map's flat projection round Belgium, the sphere
// further out, blended between GLOBE_FLAT_DEG and GLOBE_ROUND_DEG.
globe_pos :: proc(lon_deg, lat_deg, depth: f32) -> [3]f32 {
	n := globe_normal(lon_deg, lat_deg)
	round := earth_centre() + n * (EARTH_RADIUS_KM - depth)
	flat := [3]f32 {
		(lon_deg - MAP_LON0) * KM_PER_DEG * MAP_COS_LAT,
		(MAP_LAT0 - lat_deg) * KM_PER_DEG,
		depth,
	}
	away := math.acos(clamp(-n.z, -1, 1)) * math.DEG_PER_RAD
	t := math.smoothstep(f32(GLOBE_FLAT_DEG), f32(GLOBE_ROUND_DEG), away)
	return linalg.lerp(flat, round, t)
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
	wm.region_w, wm.region_h = int(h.region_w), int(h.region_h)
	wm.region_rect = {h.region_lon0, h.region_lat_top, h.region_deg_w, h.region_deg_h}
	wm.region = take(data, &off, u32(wm.region_w * wm.region_h / 8), u8, &bad)
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

	wm := &w.world_map
	if len(wm.region) > 0 {
		rp := make([]u8, wm.region_w * wm.region_h, context.temp_allocator)
		for i in 0 ..< len(rp) {
			if (wm.region[i >> 3] & (1 << u32(i & 7))) != 0 do rp[i] = 255
		}
		rimg := rl.Image {
			data    = raw_data(rp),
			width   = i32(wm.region_w),
			height  = i32(wm.region_h),
			mipmaps = 1,
			format  = .UNCOMPRESSED_GRAYSCALE,
		}
		g.region_tex = rl.LoadTextureFromImage(rimg)
		rl.SetTextureFilter(g.region_tex, .BILINEAR)
		rl.SetTextureWrap(g.region_tex, .CLAMP)
	}

	// UV sphere with radius slightly below z = 0 so Belgium's flat map sits cleanly above it.
	SLICES :: 128
	STACKS :: 64
	SPHERE_R :: EARTH_RADIUS_KM - 0.6
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
				spos[vi] = globe_pos(-180 + t.uv.x * 360, 90 - t.uv.y * 180, EARTH_RADIUS_KM - SPHERE_R)
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
	g.material.maps[rl.MaterialMapIndex.METALNESS].texture = g.region_tex
	g.loc_region = rl.GetShaderLocation(shader, "u_region")
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
				a := globe_pos(pts[k - 1].x, pts[k - 1].y, EARTH_RADIUS_KM - LINE_R)
				b := globe_pos(pts[k].x, pts[k].y, EARTH_RADIUS_KM - LINE_R)
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
	if g.region_tex.id != 0 do rl.UnloadTexture(g.region_tex)
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
	region := w.world_map.region_rect
	if g.region_tex.id == 0 do region = {}
	rl.SetShaderValue(sh, g.loc_region, &region, .VEC4)
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
	cam_pos := w.cam.view.position
	placed := make([dynamic]rl.Rectangle, 0, 64, context.temp_allocator)
	fade := clamp((-z - 0.8) / 0.8, 0, 1)
	col := rl.ColorAlpha(pal.text_2, 0.9 * fade)
	dot_col := rl.ColorAlpha(pal.text_2, 0.7 * fade)

	for &c in w.world_map.cities {
		if c.rank > max_rank do break
		n := globe_normal(c.lon, c.lat)
		pos := globe_pos(c.lon, c.lat, 0)
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
