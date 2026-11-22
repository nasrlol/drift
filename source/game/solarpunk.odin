package game

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:mem/virtual"
import rl "vendor:raylib"

// Solarpunk 3D landmarks and rural life for the street view: wind turbines aligned to the live forecast wind,
// 58 m docking towers at the 15 Belgian hubs, tilted solar panel arrays, and rural barns / greenhouses on
// unmapped countryside. Every group keeps clear of cities, towns, parks, water, buildings and roads, and has
// its own F2 editor tab so each can be tuned, toggled off, or reset independently.

PROP_TILE_KM :: 1.0
PROP_SLOTS :: 32
PROP_TILE_MAX :: 48
PROP_REACH_KM :: STREET_VIEW_KM

Turbine_Edit :: struct {
	show:        bool,
	hub_m:       f32,
	rotor_m:     f32,
	farm_chance: f32,
	per_farm:    f32,
	spin:        f32,
	offshore:    bool,
}

Tower_Edit :: struct {
	show:   bool,
	scale:  f32,
	canopy: f32,
	glow:   f32,
}

Solar_Edit :: struct {
	show:         bool,
	farm_chance:  f32,
	rows:         f32,
	scale:        f32,
	ground_cells: f32,
}

Rural_Edit :: struct {
	fields:       bool,
	field_size:   f32,
	field_mix:    f32,
	trees:        bool,
	tree_per_km2: f32,
	barns:        bool,
	barn_chance:  f32,
}

turbine_edit_defaults :: proc() -> Turbine_Edit {
	return {
		show = true,
		hub_m = 55,
		rotor_m = 22,
		farm_chance = 0.14,
		per_farm = 4,
		spin = 1,
		offshore = true,
	}
}

tower_edit_defaults :: proc() -> Tower_Edit {
	return {show = true, scale = 1, canopy = 1, glow = 1}
}

solar_edit_defaults :: proc() -> Solar_Edit {
	return {show = true, farm_chance = 0.07, rows = 5, scale = 1, ground_cells = 0.03}
}

rural_edit_defaults :: proc() -> Rural_Edit {
	return {
		fields = true,
		field_size = 160,
		field_mix = 0.85,
		trees = true,
		tree_per_km2 = 35,
		barns = true,
		barn_chance = 0.28,
	}
}

Prop_Kind :: enum u8 {
	Turbine,
	Solar,
	Barn,
	Greenhouse,
}

Prop :: struct {
	pos:   [2]f32, // m from the tile corner (x east, z south)
	yaw:   f32,
	scale: f32,
	kind:  Prop_Kind,
}

Prop_Tile :: struct {
	key:   [2]i32,
	used:  bool,
	count: int,
	props: [PROP_TILE_MAX]Prop,
}

Solarpunk :: struct {
	ready:         bool,
	lit:           rl.Material,
	lit_loc:       Street_Light_Locs,
	turbine_tower: rl.Mesh,
	turbine_rotor: rl.Mesh,
	hub_tower:     rl.Mesh,
	hub_ring:      rl.Mesh,
	solar_rack:    rl.Mesh,
	barn:          rl.Mesh,
	greenhouse:    rl.Mesh,
	tiles:         [PROP_SLOTS]Prop_Tile,
	last_turbine:  Turbine_Edit,
	last_solar:    Solar_Edit,
	last_rural:    Rural_Edit,
}

// Instanced vertex shader feeding STREET_CAR_FS with non-uniform normal matrix support and round-world bend.
STREET_PROP_VS ::
	`#version 330
in vec3 vertexPosition;
in vec3 vertexNormal;
in vec4 vertexColor;
in mat4 instanceTransform;
uniform mat4 mvp;
out vec3 v_world;
out vec3 v_normal;
out vec4 v_color;
` +
	STREET_BEND_GLSL +
	`
void main() {
	vec4 wp = instanceTransform * vec4(vertexPosition, 1.0);
	v_world = wp.xyz;
	v_normal = normalize(transpose(inverse(mat3(instanceTransform))) * vertexNormal);
	v_color = vertexColor;
	gl_Position = bent(mvp * wp, wp.xyz);
}
`

solarpunk_mesh_upload :: proc(w: ^World, b: ^Car_Builder) -> rl.Mesh {
	indices := make([]u16, len(b.idx), virtual.arena_allocator(&w.perm))
	copy(indices, b.idx[:])
	m := rl.Mesh {
		vertexCount   = i32(len(b.pos)),
		triangleCount = i32(len(b.idx) / 3),
		vertices      = cast([^]f32)raw_data(b.pos),
		normals       = cast([^]f32)raw_data(b.nrm),
		colors        = cast([^]u8)raw_data(b.col),
		indices       = raw_data(indices),
	}
	rl.UploadMesh(&m, false)
	m.vertices, m.normals, m.colors = nil, nil, nil
	return m
}

solarpunk_new_builder :: proc(tmp: mem.Allocator) -> Car_Builder {
	return {
		pos = make([dynamic][3]f32, 0, 2048, tmp),
		nrm = make([dynamic][3]f32, 0, 2048, tmp),
		col = make([dynamic][4]u8, 0, 2048, tmp),
		idx = make([dynamic]u16, 0, 4096, tmp),
	}
}

solarpunk_ring_prism :: proc(b: ^Car_Builder, y0, y1, r0, r1: f32, segs: int, c: [4]u8) {
	for i in 0 ..< segs {
		a0 := f32(i) * math.TAU / f32(segs)
		a1 := f32(i + 1) * math.TAU / f32(segs)
		c0, s0 := math.cos(a0), math.sin(a0)
		c1, s1 := math.cos(a1), math.sin(a1)
		p0 := [3]f32{c0 * r0, y0, s0 * r0}
		p1 := [3]f32{c1 * r0, y0, s1 * r0}
		p2 := [3]f32{c1 * r1, y1, s1 * r1}
		p3 := [3]f32{c0 * r1, y1, s0 * r1}
		n0 := linalg.normalize([3]f32{c0, (r0 - r1) / max(y1 - y0, 0.01), s0})
		n1 := linalg.normalize([3]f32{c1, (r0 - r1) / max(y1 - y0, 0.01), s1})
		car_quad(b, {p0, p1, p2, p3}, {n0, n1, n1, n0}, c, n0 + n1)
	}
}

solarpunk_disc :: proc(b: ^Car_Builder, y, r_in, r_out: f32, segs: int, up: bool, c: [4]u8) {
	n := [3]f32{0, up ? 1 : -1, 0}
	for i in 0 ..< segs {
		a0 := f32(i) * math.TAU / f32(segs)
		a1 := f32(i + 1) * math.TAU / f32(segs)
		p0 := [3]f32{math.cos(a0) * r_in, y, math.sin(a0) * r_in}
		p1 := [3]f32{math.cos(a1) * r_in, y, math.sin(a1) * r_in}
		p2 := [3]f32{math.cos(a1) * r_out, y, math.sin(a1) * r_out}
		p3 := [3]f32{math.cos(a0) * r_out, y, math.sin(a0) * r_out}
		if up do car_quad(b, {p0, p3, p2, p1}, {n, n, n, n}, c, n)
		else do car_quad(b, {p0, p1, p2, p3}, {n, n, n, n}, c, n)
	}
}

solarpunk_build :: proc(w: ^World) {
	sp := &w.street.solarpunk
	if sp.ready do return
	scratch: virtual.Arena
	if virtual.arena_init_growing(&scratch) != nil do return
	defer virtual.arena_destroy(&scratch)
	tmp := virtual.arena_allocator(&scratch)

	// 1. Wind turbine tower + nacelle (unit height 1.0 m at y = 0..1; rotor hub sits at y = 1.0, facing +z).
	{
		b := solarpunk_new_builder(tmp)
		WHITE :: [4]u8{236, 238, 234, CLASS_PAINT}
		BASE :: [4]u8{216, 178, 56, CLASS_MATTE}
		TEAL :: [4]u8{52, 138, 108, CLASS_PAINT}
		BEACON :: [4]u8{240, 64, 48, CLASS_LIGHT}
		solarpunk_ring_prism(&b, 0, 0.08, 0.044, 0.040, 10, BASE)
		solarpunk_ring_prism(&b, 0.08, 1.0, 0.040, 0.020, 10, WHITE)
		car_box(&b, {0, 1.0, -0.012}, {0.022, 0.024, 0.058}, WHITE)
		car_box(&b, {0, 1.026, -0.015}, {0.018, 0.004, 0.042}, TEAL)
		car_blob(&b, {0, 1.032, -0.055}, {0.006, 0.006, 0.006}, BEACON)
		sp.turbine_tower = solarpunk_mesh_upload(w, &b)
	}

	// 2. Wind turbine 3-blade rotor (unit blade radius 1.0 m around origin, facing +z).
	{
		b := solarpunk_new_builder(tmp)
		WHITE :: [4]u8{242, 244, 240, CLASS_PAINT}
		TIP :: [4]u8{48, 148, 114, CLASS_PAINT}
		car_blob(&b, {0, 0, 0.03}, {0.065, 0.065, 0.11}, WHITE)
		for k in 0 ..< 3 {
			ang := f32(k) * math.TAU / 3
			sa, ca := math.sin(ang), math.cos(ang)
			rot := proc(p: [3]f32, sa, ca: f32) -> [3]f32 {
				return {p.x * ca - p.y * sa, p.x * sa + p.y * ca, p.z}
			}
			// Tapered blade from r = 0.05 to 1.0, split with a solarpunk teal tip.
			segs := [2]struct {
				r0, r1, w0, w1, t0, t1: f32,
				c:                      [4]u8,
			}{{0.05, 0.84, 0.048, 0.026, 0.015, 0.009, WHITE}, {0.84, 1.00, 0.026, 0.010, 0.009, 0.005, TIP}}
			for sg in segs {
				pts := [8][3]f32 {
					rot({-sg.w0, sg.r0, -sg.t0}, sa, ca),
					rot({sg.w0, sg.r0, sg.t0}, sa, ca),
					rot({sg.w1, sg.r1, sg.t1}, sa, ca),
					rot({-sg.w1, sg.r1, -sg.t1}, sa, ca),
					rot({-sg.w0, sg.r0, sg.t0}, sa, ca),
					rot({sg.w0, sg.r0, -sg.t0}, sa, ca),
					rot({sg.w1, sg.r1, -sg.t1}, sa, ca),
					rot({-sg.w1, sg.r1, sg.t1}, sa, ca),
				}
				n_f := linalg.normalize(rot({0.15, 0, 1}, sa, ca))
				n_b := linalg.normalize(rot({-0.15, 0, -1}, sa, ca))
				car_quad(&b, {pts[0], pts[1], pts[2], pts[3]}, {n_f, n_f, n_f, n_f}, sg.c, n_f)
				car_quad(&b, {pts[5], pts[4], pts[7], pts[6]}, {n_b, n_b, n_b, n_b}, sg.c, n_b)
			}
		}
		sp.turbine_rotor = solarpunk_mesh_upload(w, &b)
	}

	// 3. Hub docking tower (58 m tall so the ship spawns/docks cleanly above the deck at HUB_TOWER_M).
	{
		b := solarpunk_new_builder(tmp)
		H :: f32(HUB_TOWER_M)
		LEAF :: [4]u8{74, 132, 66, CLASS_MATTE}
		PAD :: [4]u8{228, 224, 212, CLASS_MATTE}
		solarpunk_ring_prism(&b, 0, 2.0, 4.8, 4.2, 12, CAR_WOOD)
		solarpunk_ring_prism(&b, 0, H - 2.2, 1.5, 1.1, 12, CAR_GLASS)
		for k in 0 ..< 4 {
			a := f32(k) * math.PI / 2 + math.PI / 4
			ca, sa := math.cos(a), math.sin(a)
			// Slanted timber/brass legs converging beneath the upper deck collar.
			for st in 0 ..< 4 {
				t0, t1 := f32(st) / 4, f32(st + 1) / 4
				r0, r1 := 3.9 - 2.2 * t0, 3.9 - 2.2 * t1
				y0, y1 := t0 * (H - 4.0), t1 * (H - 4.0)
				mid := [3]f32{ca * (r0 + r1) * 0.5, (y0 + y1) * 0.5, sa * (r0 + r1) * 0.5}
				car_box(&b, mid, {0.36, (y1 - y0) * 0.52, 0.36}, st % 2 == 0 ? CAR_WOOD : CAR_BRASS)
			}
		}
		// Mid-level garden terrace and top solar/docking deck below 58 m so the chase camera sees clearly over it.
		solarpunk_ring_prism(&b, 28, 30, 3.3, 3.7, 14, CAR_WOOD)
		solarpunk_ring_prism(&b, 30, 31.2, 3.5, 3.1, 14, LEAF)
		solarpunk_disc(&b, 31.2, 1.2, 3.1, 14, true, LEAF)
		solarpunk_ring_prism(&b, H - 3.6, H - 2.2, 2.2, 4.2, 16, CAR_BRASS)
		solarpunk_ring_prism(&b, H - 2.2, H - 1.7, 4.2, 4.0, 16, CAR_SOLAR)
		solarpunk_disc(&b, H - 1.7, 3.1, 4.0, 16, true, CAR_SOLAR)
		solarpunk_ring_prism(&b, H - 1.7, H - 1.3, 3.1, 3.1, 16, PAD)
		solarpunk_disc(&b, H - 1.3, 0, 3.1, 16, true, PAD)
		sp.hub_tower = solarpunk_mesh_upload(w, &b)
	}

	// 4. Hub tower glowing docking ring (drawn separately so glow slider scales colDiffuse).
	{
		b := solarpunk_new_builder(tmp)
		H :: f32(HUB_TOWER_M)
		GLOW :: [4]u8{90, 230, 255, CLASS_LIGHT}
		solarpunk_ring_prism(&b, H - 1.35, H - 1.15, 3.2, 3.4, 20, GLOW)
		solarpunk_ring_prism(&b, H - 2.05, H - 1.80, 4.22, 4.22, 20, GLOW)
		sp.hub_ring = solarpunk_mesh_upload(w, &b)
	}

	// 5. Tilted solar panel rack (6 m wide, 3 m deep, facing south +z).
	{
		b := solarpunk_new_builder(tmp)
		car_box(&b, {-2.1, 0.75, 0}, {0.10, 0.75, 0.10}, CAR_CHROME)
		car_box(&b, {2.1, 0.75, 0}, {0.10, 0.75, 0.10}, CAR_CHROME)
		car_box(&b, {0, 1.25, 0}, {2.6, 0.06, 0.08}, CAR_CHROME)
		// Tilted solar face: south edge lower (y=0.95, z=1.15), north edge higher (y=2.05, z=-1.15).
		p := [4][3]f32{{-2.9, 0.95, 1.15}, {2.9, 0.95, 1.15}, {2.9, 2.05, -1.15}, {-2.9, 2.05, -1.15}}
		n := linalg.normalize([3]f32{0, 2.3, 1.1})
		car_quad(&b, p, {n, n, n, n}, CAR_SOLAR, n)
		q := [4][3]f32{{-2.9, 0.91, 1.15}, {2.9, 0.91, 1.15}, {2.9, 2.01, -1.15}, {-2.9, 2.01, -1.15}}
		car_quad(&b, {q[3], q[2], q[1], q[0]}, {-n, -n, -n, -n}, CAR_CHROME, -n)
		sp.solar_rack = solarpunk_mesh_upload(w, &b)
	}

	// 6. Rural barn with solar roof (12 m x 8 m, 6.5 m ridge).
	{
		b := solarpunk_new_builder(tmp)
		WALL :: [4]u8{186, 124, 92, CLASS_MATTE}
		ROOF :: [4]u8{142, 68, 48, CLASS_PAINT}
		car_box(&b, {0, 2.0, 0}, {5.8, 2.0, 3.8}, WALL)
		car_box(&b, {0, 0.3, 0}, {5.86, 0.3, 3.86}, CAR_TRIM)
		// Pitched roof slopes along x, ridge at z = 0, y = 6.5.
		n_s := linalg.normalize([3]f32{0, 4.1, 2.5})
		n_n := linalg.normalize([3]f32{0, 4.1, -2.5})
		car_quad(
			&b,
			{{-6.1, 3.9, 4.1}, {6.1, 3.9, 4.1}, {6.1, 6.4, 0}, {-6.1, 6.4, 0}},
			{n_s, n_s, n_s, n_s},
			ROOF,
			n_s,
		)
		car_quad(
			&b,
			{{6.1, 3.9, -4.1}, {-6.1, 3.9, -4.1}, {-6.1, 6.4, 0}, {6.1, 6.4, 0}},
			{n_n, n_n, n_n, n_n},
			ROOF,
			n_n,
		)
		// Solar strip on the sunny south slope.
		car_quad(
			&b,
			{{-4.6, 4.42, 3.26}, {4.6, 4.42, 3.26}, {4.6, 6.02, 0.66}, {-4.6, 6.02, 0.66}},
			{n_s, n_s, n_s, n_s},
			CAR_SOLAR,
			n_s,
		)
		car_tri(&b, {{-5.8, 4.0, -3.8}, {-5.8, 4.0, 3.8}, {-5.8, 6.4, 0}}, {-1, 0, 0}, WALL)
		car_tri(&b, {{5.8, 4.0, 3.8}, {5.8, 4.0, -3.8}, {5.8, 6.4, 0}}, {1, 0, 0}, WALL)
		sp.barn = solarpunk_mesh_upload(w, &b)
	}

	// 7. Rural glass greenhouse (14 m x 7 m) with copper ribs and greenery inside.
	{
		b := solarpunk_new_builder(tmp)
		FOLIAGE :: [4]u8{74, 146, 68, CLASS_MATTE}
		car_box(&b, {0, 0.45, 0}, {7.0, 0.45, 3.5}, CAR_WOOD)
		car_blob(&b, {0, 1.4, 0}, {5.8, 1.1, 2.2}, FOLIAGE)
		car_box(&b, {0, 1.9, 0}, {6.8, 1.0, 3.3}, CAR_GLASS)
		car_box(&b, {0, 3.4, 0}, {7.0, 0.08, 0.22}, CAR_COPPER)
		for k in -2 ..= 2 {
			car_box(&b, {f32(k) * 3.1, 1.9, 0}, {0.08, 1.02, 3.34}, CAR_COPPER)
		}
		sp.greenhouse = solarpunk_mesh_upload(w, &b)
	}

	sh := rl.LoadShaderFromMemory(STREET_PROP_VS, STREET_CAR_FS)
	if !rl.IsShaderValid(sh) do logf(w, "street", "solarpunk prop shader did not compile")
	sh.locs[rl.ShaderLocationIndex.VERTEX_INSTANCETRANSFORM] = rl.GetShaderLocationAttrib(
		sh,
		"instanceTransform",
	)
	sp.lit = rl.LoadMaterialDefault()
	sp.lit.shader = sh
	sp.lit_loc = street_light_locs(sh)
	sp.ready = true
}

solarpunk_unload :: proc(sp: ^Solarpunk) {
	if !sp.ready do return
	meshes := [?]^rl.Mesh {
		&sp.turbine_tower,
		&sp.turbine_rotor,
		&sp.hub_tower,
		&sp.hub_ring,
		&sp.solar_rack,
		&sp.barn,
		&sp.greenhouse,
	}
	for m in meshes {
		m.indices = nil
		rl.UnloadMesh(m^)
	}
	rl.UnloadShader(sp.lit.shader)
	sp^ = {}
}

// Area kind at p (km) from the pre-indexed land use triangles, or (Area_Kind(0), false) when unmapped.
solarpunk_area_at :: proc(w: ^World, p: [2]f32) -> (kind: Area_Kind, ok: bool) {
	st := &w.street
	if st.area_cells == nil do return {}, false
	cx := clamp(int(p.x / STREET_AREA_TILE_KM), 0, STREET_AREA_W - 1)
	cy := clamp(int(p.y / STREET_AREA_TILE_KM), 0, STREET_AREA_H - 1)
	cell := cy * STREET_AREA_W + cx
	for item in st.area_items[st.area_cells[cell]:st.area_cells[cell + 1]] {
		k := item & (1 << 28 - 1)
		if in_triangle(p, w.m.area_points[k], w.m.area_points[k + 1], w.m.area_points[k + 2]) {
			kind = Area_Kind(item >> 28)
			ok = true
		}
	}
	return
}

// True when p (km) is clear of roads, rivers and buildings for a prop of radius r_m.
solarpunk_clear :: proc(w: ^World, p: [2]f32, r_m: f32) -> bool {
	if push, roof := collide_car(w, p, 0, r_m); push != {} || roof > 0 do return false
	co := &w.collide
	if len(co.road_cells) > 0 {
		cx := clamp(int(p.x / COLLIDE_ROAD_CELL_KM), 0, COLLIDE_ROAD_W - 1)
		cy := clamp(int(p.y / COLLIDE_ROAD_CELL_KM), 0, COLLIDE_ROAD_H - 1)
		cell := cy * COLLIDE_ROAD_W + cx
		for item in co.road_items[co.road_cells[cell]:co.road_cells[cell + 1]] {
			k := int(item & 0xffffff)
			a, b := w.m.points[k], w.m.points[k + 1]
			ab := b - a
			l2 := linalg.dot(ab, ab)
			s := l2 > 0 ? clamp(linalg.dot(p - a, ab) / l2, 0, 1) : 0
			need := road_half_width_m(Map_Kind(item >> 24)) + ROAD_SIDEWALK_M + r_m + 4
			if linalg.length(a + ab * s - p) * 1000 < need do return false
		}
	}
	return true
}

// True when p (km) lies on open unmapped rural land (or offshore coastal sea if allow_sea).
solarpunk_rural_ok :: proc(w: ^World, p: [2]f32, r_m: f32, allow_sea: bool) -> bool {
	if !belgium_inside(w, p.x, p.y) || urban_at(w, p) do return false
	if kind, has := solarpunk_area_at(w, p); has {
		if kind != .Farmland do return false
	}
	h := height_at(w, p.x, p.y)
	sea := h <= 0.2 && p.x < 80 && p.y < 45
	if sea && !allow_sea do return false
	return solarpunk_clear(w, p, r_m)
}

solarpunk_build_tile :: proc(w: ^World, t: ^Prop_Tile, lo: [2]f32) {
	t.count = 0
	add :: proc(t: ^Prop_Tile, lo, p: [2]f32, yaw, scale: f32, kind: Prop_Kind) {
		if t.count >= PROP_TILE_MAX do return
		t.props[t.count] = {(p - lo) * 1000, yaw, scale, kind}
		t.count += 1
	}

	// Wind farms: grouped on 2 km squares so turbines form realistic clusters instead of uniform noise.
	if w.turbine_edit.show && w.turbine_edit.farm_chance > 0 {
		gx, gy := int(math.floor(f64(t.key.x) / 2)), int(math.floor(f64(t.key.y) / 2))
		fseed := hash_u32(u32(gx) * 73856093 ~ u32(gy) * 19349663 ~ 0x51a7)
		if nature_rand(&fseed) < w.turbine_edit.farm_chance {
			sub := hash_u32(u32(t.key.x) * 83492791 ~ u32(t.key.y) * 2971215073)
			if nature_rand(&sub) < 0.35 {
				n := clamp(int(math.round(w.turbine_edit.per_farm)), 1, 8)
				for _ in 0 ..< n {
					p :=
						lo +
						{0.12 + 0.76 * nature_rand(&sub), 0.12 + 0.76 * nature_rand(&sub)} * PROP_TILE_KM
					if solarpunk_rural_ok(w, p, 10, w.turbine_edit.offshore) {
						add(t, lo, p, 0, 1, .Turbine)
					}
				}
			}
		}
	}

	// Solar farms: neat rows of tilted panels on flat rural parcels.
	if w.solar_edit.show && w.solar_edit.farm_chance > 0 {
		sseed := hash_u32(u32(t.key.x) * 49979687 ~ u32(t.key.y) * 67867967 ~ 0x9e37)
		if nature_rand(&sseed) < w.solar_edit.farm_chance {
			center := lo + {0.2 + 0.6 * nature_rand(&sseed), 0.2 + 0.6 * nature_rand(&sseed)} * PROP_TILE_KM
			if solarpunk_rural_ok(w, center, 35, false) {
				rows := clamp(int(math.round(w.solar_edit.rows)), 2, 8)
				sc := w.solar_edit.scale
				dx, dz := 7.0 * sc / 1000, 6.0 * sc / 1000
				for r in 0 ..< rows {
					for c in 0 ..< rows {
						p :=
							center +
							{(f32(c) - f32(rows - 1) * 0.5) * dx, (f32(r) - f32(rows - 1) * 0.5) * dz}
						if solarpunk_clear(w, p, 4 * sc) {
							add(t, lo, p, 0, sc, .Solar)
						}
					}
				}
			}
		}
	}

	// Occasional rural barns and glass greenhouses on open countryside.
	if w.rural_edit.barns && w.rural_edit.barn_chance > 0 {
		bseed := hash_u32(u32(t.key.x) * 32452843 ~ u32(t.key.y) * 49979693 ~ 0x3b11)
		for _ in 0 ..< 2 {
			if nature_rand(&bseed) >= w.rural_edit.barn_chance do continue
			p := lo + {0.1 + 0.8 * nature_rand(&bseed), 0.1 + 0.8 * nature_rand(&bseed)} * PROP_TILE_KM
			if solarpunk_rural_ok(w, p, 12, false) {
				kind: Prop_Kind = nature_rand(&bseed) < 0.45 ? .Greenhouse : .Barn
				add(t, lo, p, nature_rand(&bseed) * math.TAU, 0.9 + 0.25 * nature_rand(&bseed), kind)
			}
		}
	}
}

solarpunk_draw :: proc(w: ^World, target: [2]f32, reach: f32, cam: [3]f32, shadow: bool) {
	st := &w.street
	sp := &st.solarpunk
	if !sp.ready do return
	if !shadow &&
	   (sp.last_turbine != w.turbine_edit ||
			   sp.last_solar != w.solar_edit ||
			   sp.last_rural != w.rural_edit) {
		for &t in sp.tiles do t.used = false
		sp.last_turbine = w.turbine_edit
		sp.last_solar = w.solar_edit
		sp.last_rural = w.rural_edit
	}
	if !shadow {
		keep := reach + 2 * PROP_TILE_KM
		for &t in sp.tiles {
			if t.used && linalg.length(tile_centre(t.key, PROP_TILE_KM) - target) > keep do t.used = false
		}
		lo := linalg.floor((target - reach) / PROP_TILE_KM)
		hi := linalg.floor((target + reach) / PROP_TILE_KM)
		for y := i32(lo.y); y <= i32(hi.y); y += 1 {
			for x := i32(lo.x); x <= i32(hi.x); x += 1 {
				key := [2]i32{x, y}
				if linalg.length(tile_centre(key, PROP_TILE_KM) - target) > reach + PROP_TILE_KM * 0.71 do continue
				built := false
				for t in sp.tiles do if t.used && t.key == key do built = true
				if built do continue
				for &t in sp.tiles {
					if !t.used {
						t.key, t.used = key, true
						solarpunk_build_tile(w, &t, [2]f32{f32(key.x), f32(key.y)} * PROP_TILE_KM)
						break
					}
				}
			}
		}
	}

	turbine_t := make([dynamic]rl.Matrix, 0, 128, context.temp_allocator)
	turbine_r := make([dynamic]rl.Matrix, 0, 128, context.temp_allocator)
	solar_m := make([dynamic]rl.Matrix, 0, 256, context.temp_allocator)
	barn_m := make([dynamic]rl.Matrix, 0, 64, context.temp_allocator)
	gh_m := make([dynamic]rl.Matrix, 0, 64, context.temp_allocator)
	tower_m := make([dynamic]rl.Matrix, 0, 4, context.temp_allocator)

	hour := sim_hour(w)
	time_s := f32(w.tick) * SIM_DT
	for &t in sp.tiles {
		if !t.used || t.count == 0 do continue
		gap := linalg.max(linalg.abs(tile_centre(t.key, PROP_TILE_KM) - target) - PROP_TILE_KM / 2, 0)
		if linalg.length(gap) > reach do continue
		corner := [2]f64{f64(t.key.x) * PROP_TILE_KM, f64(t.key.y) * PROP_TILE_KM}
		off := [2]f32{f32((corner.x - f64(st.origin.x)) * 1000), f32((corner.y - f64(st.origin.y)) * 1000)}
		for prop in t.props[:t.count] {
			p := off + prop.pos
			if !shadow && linalg.length(p - cam.xz) > PROP_REACH_KM * 1000 + 50 do continue
			switch prop.kind {
			case .Turbine:
				if !w.turbine_edit.show do continue
				km := [2]f32{f32(corner.x) + prop.pos.x / 1000, f32(corner.y) + prop.pos.y / 1000}
				wind := wind_at(w, km.x, km.y, 0, hour)
				ws := linalg.length(wind)
				yaw := ws > 0.2 ? math.atan2(-wind.x, -wind.y) : 0
				hm := max(w.turbine_edit.hub_m, 10)
				rm := max(w.turbine_edit.rotor_m, 4)
				tw := max(hm / 55, 0.5)
				tr := rl.Matrix(
					linalg.matrix4_translate_f32({p.x, 0, p.y}) *
					linalg.matrix4_rotate_f32(yaw, {0, 1, 0}) *
					linalg.matrix4_scale_f32({tw, hm, tw}),
				)
				phase := f32((i32(prop.pos.x) * 73 ~ i32(prop.pos.y) * 19) & 255) * 0.025
				spin := phase + time_s * (0.4 + ws * 0.16) * w.turbine_edit.spin
				rr := rl.Matrix(
					linalg.matrix4_translate_f32(
						{p.x + math.sin(yaw) * 0.045 * tw, hm, p.y + math.cos(yaw) * 0.045 * tw},
					) *
					linalg.matrix4_rotate_f32(yaw, {0, 1, 0}) *
					linalg.matrix4_rotate_f32(spin, {0, 0, 1}) *
					linalg.matrix4_scale_f32({rm, rm, rm}),
				)
				append(&turbine_t, tr)
				append(&turbine_r, rr)
			case .Solar:
				if !w.solar_edit.show do continue
				m := rl.Matrix(
					linalg.matrix4_translate_f32({p.x, 0, p.y}) *
					linalg.matrix4_scale_f32({prop.scale, prop.scale, prop.scale}),
				)
				append(&solar_m, m)
			case .Barn:
				if !w.rural_edit.barns do continue
				m := rl.Matrix(
					linalg.matrix4_translate_f32({p.x, 0, p.y}) *
					linalg.matrix4_rotate_f32(prop.yaw, {0, 1, 0}) *
					linalg.matrix4_scale_f32({prop.scale, prop.scale, prop.scale}),
				)
				append(&barn_m, m)
			case .Greenhouse:
				if !w.rural_edit.barns do continue
				m := rl.Matrix(
					linalg.matrix4_translate_f32({p.x, 0, p.y}) *
					linalg.matrix4_rotate_f32(prop.yaw, {0, 1, 0}) *
					linalg.matrix4_scale_f32({prop.scale, prop.scale, prop.scale}),
				)
				append(&gh_m, m)
			}
		}
	}

	if w.tower_edit.show {
		for h in w.m.hubs[:w.m.hub_count] {
			if linalg.length(h.pos - target) > reach + 0.1 do continue
			d := (h.pos - st.origin) * 1000
			sc := max(w.tower_edit.scale, 0.2)
			cap := max(w.tower_edit.canopy, 0.2)
			xz := sc * cap
			append(
				&tower_m,
				rl.Matrix(
					linalg.matrix4_translate_f32({d.x, 0, d.y}) * linalg.matrix4_scale_f32({xz, 1, xz}),
				),
			)
		}
	}

	mat := shadow ? st.trees.depth : sp.lit
	if !shadow {
		street_light_set(w, sp.lit.shader, sp.lit_loc, cam)
		mat.maps[0].color = rl.WHITE
	}
	draw_batch :: proc(mesh: rl.Mesh, mat: rl.Material, items: []rl.Matrix) {
		if len(items) > 0 && mesh.vertexCount > 0 {
			rl.DrawMeshInstanced(mesh, mat, raw_data(items), i32(len(items)))
		}
	}
	draw_batch(sp.turbine_tower, mat, turbine_t[:])
	draw_batch(sp.turbine_rotor, mat, turbine_r[:])
	draw_batch(sp.solar_rack, mat, solar_m[:])
	draw_batch(sp.barn, mat, barn_m[:])
	draw_batch(sp.greenhouse, mat, gh_m[:])
	draw_batch(sp.hub_tower, mat, tower_m[:])
	if !shadow && len(tower_m) > 0 && w.tower_edit.glow > 0 {
		g := u8(clamp(w.tower_edit.glow * 128, 0, 255))
		ring_mat := sp.lit
		ring_mat.maps[0].color = {g, g, g, 255}
		draw_batch(sp.hub_ring, ring_mat, tower_m[:])
	}
}

// --- F2 Editor tabs ---

turbine_tab :: proc(w: ^World, x, y, width: f32, drag: ^int) -> f32 {
	e := &w.turbine_edit
	pal := palette(w)
	def := w.setting_defaults.turbines
	y := y
	ui_text(w, {x, y}, "Wind turbines", .Roboto_400, 13, pal.text)
	ui_toggle(w, {x + width - 36, y - 2, 36, 20}, &e.show)
	y += 28
	ui_text(w, {x, y}, "Offshore sea arrays", .Roboto_400, 13, pal.text)
	ui_toggle(w, {x + width - 36, y - 2, 36, 20}, &e.offshore)
	y += 30
	Row :: struct {
		label:  string,
		value:  ^f32,
		def:    f32,
		lo, hi: f32,
		format: string,
	}
	rows := [?]Row {
		{"Hub height", &e.hub_m, def.hub_m, 25, 110, "%.0f m"},
		{"Rotor radius", &e.rotor_m, def.rotor_m, 10, 45, "%.0f m"},
		{"Farm chance", &e.farm_chance, def.farm_chance, 0, 0.5, "%.2f"},
		{"Turbines per farm", &e.per_farm, def.per_farm, 1, 8, "%.0f"},
		{"Spin speed", &e.spin, def.spin, 0, 3, "x %.2f"},
	}
	buf: [32]u8
	for row, i in rows {
		text := fmt.bprintf(buf[:], row.format, row.value^)
		ui_slider_row(w, x, y, width, row.label, text, row.value, row.lo, row.hi, row.def, drag, i + 1)
		y += UI_SLIDER_ROW_H
	}
	return y
}

tower_tab :: proc(w: ^World, x, y, width: f32, drag: ^int) -> f32 {
	e := &w.tower_edit
	pal := palette(w)
	def := w.setting_defaults.towers
	y := y
	ui_text(w, {x, y}, "Hub docking towers (58 m)", .Roboto_400, 13, pal.text)
	ui_toggle(w, {x + width - 36, y - 2, 36, 20}, &e.show)
	y += 30
	Row :: struct {
		label:  string,
		value:  ^f32,
		def:    f32,
		lo, hi: f32,
		format: string,
	}
	rows := [?]Row {
		{"Tower width", &e.scale, def.scale, 0.5, 2, "x %.2f"},
		{"Deck canopy", &e.canopy, def.canopy, 0.3, 2, "x %.2f"},
		{"Ring glow", &e.glow, def.glow, 0, 2, "x %.2f"},
	}
	buf: [32]u8
	for row, i in rows {
		text := fmt.bprintf(buf[:], row.format, row.value^)
		ui_slider_row(w, x, y, width, row.label, text, row.value, row.lo, row.hi, row.def, drag, i + 1)
		y += UI_SLIDER_ROW_H
	}
	return y
}

solar_tab :: proc(w: ^World, x, y, width: f32, drag: ^int) -> f32 {
	e := &w.solar_edit
	pal := palette(w)
	def := w.setting_defaults.solar
	y := y
	ui_text(w, {x, y}, "3D solar farms", .Roboto_400, 13, pal.text)
	ui_toggle(w, {x + width - 36, y - 2, 36, 20}, &e.show)
	y += 30
	Row :: struct {
		label:  string,
		value:  ^f32,
		def:    f32,
		lo, hi: f32,
		format: string,
	}
	rows := [?]Row {
		{"Farm chance", &e.farm_chance, def.farm_chance, 0, 0.4, "%.2f"},
		{"Panel grid", &e.rows, def.rows, 2, 8, "%.0f"},
		{"Panel scale", &e.scale, def.scale, 0.4, 2, "x %.2f"},
		{"Ground solar share", &e.ground_cells, def.ground_cells, 0, 0.25, "%.2f"},
	}
	buf: [32]u8
	for row, i in rows {
		text := fmt.bprintf(buf[:], row.format, row.value^)
		ui_slider_row(w, x, y, width, row.label, text, row.value, row.lo, row.hi, row.def, drag, i + 1)
		y += UI_SLIDER_ROW_H
	}
	return y
}

rural_tab :: proc(w: ^World, x, y, width: f32, drag: ^int) -> f32 {
	e := &w.rural_edit
	pal := palette(w)
	def := w.setting_defaults.rural
	y := y
	Toggle :: struct {
		label: string,
		val:   ^bool,
	}
	for t in ([?]Toggle{{"Rural fields", &e.fields}, {"Rural trees", &e.trees}, {"Barns & greenhouses", &e.barns}}) {
		ui_text(w, {x, y}, t.label, .Roboto_400, 13, pal.text)
		ui_toggle(w, {x + width - 36, y - 2, 36, 20}, t.val)
		y += 28
	}
	y += 4
	Row :: struct {
		label:  string,
		value:  ^f32,
		def:    f32,
		lo, hi: f32,
		format: string,
	}
	rows := [?]Row {
		{"Field size", &e.field_size, def.field_size, 60, 320, "%.0f m"},
		{"Field strength", &e.field_mix, def.field_mix, 0, 1, "%.2f"},
		{"Rural trees / km2", &e.tree_per_km2, def.tree_per_km2, 0, 120, "%.0f"},
		{"Barn / greenhouse", &e.barn_chance, def.barn_chance, 0, 1, "%.2f"},
	}
	buf: [32]u8
	for row, i in rows {
		text := fmt.bprintf(buf[:], row.format, row.value^)
		ui_slider_row(w, x, y, width, row.label, text, row.value, row.lo, row.hi, row.def, drag, i + 1)
		y += UI_SLIDER_ROW_H
	}
	return y
}
