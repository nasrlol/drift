package game

import "core:fmt"
import "core:math"
import "core:math/linalg"
import rl "vendor:raylib"

// Street view (Lars, 2026-11-21: "een 3d game waar je tussen huizen kan vliegen, zoals gta in third person, zo
// realistisch mogelijk, niet cartoonachtig"). V on the navigation screen puts a third-person camera behind the
// car at real scale; the car flies with ship_free_step. The map stays as it was, V or Esc goes back.
//
// Street space: metres, x east, y up, z south, around origin (km, snapped to STREET_ORIGIN_KM so the f32 values
// stay small and do not shake). The map meshes (x km, y km south, z km down) are drawn with street_transform.
// The ground is flat at y = 0: the car's height is its height above the local ground (alt - height_at), the way
// the buildings stand on the map. raylib's projection has near 0.05 and far 4000 units, so in metres the view
// ends at 4 km; the haze closes before that.
STREET_ORIGIN_KM :: 0.25
STREET_REACH_KM :: 3.6
STREET_FOG_M :: [2]f32{220, 3500}
STREET_CAM_DIST_M :: 8.5
STREET_CAM_MIN_M :: 4.0
STREET_CAM_MAX_M :: 40.0
STREET_CAM_LOOK_UP_M :: 1.6 // the camera looks at this point above the car
STREET_CAM_PITCH :: 0.16 // radians down at rest
STREET_CAM_RATE :: 7.0 // the camera closes this share of the gap per second
STREET_MOUSE_RAD_PER_PX :: 0.0035
STREET_STICK_RAD_PER_S :: 2.5
STREET_RECENTRE_S :: 1.6 // after this long without looking around the camera swings back behind the car
STREET_FOV :: 62.0
STREET_FOV_FAST :: 10.0 // wider at top speed
STREET_ROAD_TILE_KM :: 1.0
STREET_ROAD_CELL_KM :: 2.0
STREET_ROAD_W :: int(MAP_W_KM) / int(STREET_ROAD_CELL_KM) + 1
STREET_ROAD_H :: int(MAP_H_KM) / int(STREET_ROAD_CELL_KM) + 1
STREET_HINT_S :: 7.0 // the key hint shows this long after switching on
// One depth bias unit in NDC: a few steps of the 24 bit depth buffer, so the flat ground layers (land, land use,
// rivers, roads, markings) draw in order without flicker, and pull through a wall's foot by only ~1 m at 1 km.
STREET_DEPTH_UNIT :: 2.5e-7

Street :: struct {
	on:         bool,
	yaw, pitch: f32, // the player's look-around on top of the chase direction, radians
	dist:       f32, // zero = STREET_CAM_DIST_M
	idle_s:     f32, // seconds since the player last looked around
	on_s:       f32, // seconds since the street view switched on
	origin:     [2]f32, // km
	eye:        [3]f32, // the camera, street space, eased
	seeded:     bool,
	view:       rl.Camera3D,
	// Road ribbons per STREET_ROAD_TILE_KM tile. road_segs lists, per STREET_ROAD_CELL_KM cell, the map line
	// segments it holds: kind << 24 | index of the segment's first point (road_cells has the offsets).
	roads:      Tile_Cache,
	road_cells: []u32,
	road_segs:  []u32,
	// The ground plane, the land use triangles and the roads share one shader.
	ground:     rl.Mesh,
	material:   rl.Material,
	loc:        struct {
		fog_c, fog_r, bias, remap, map_colors, real_colors, origin, tone: i32,
	},
	ready:      bool,
}

// Ground shader: vertex colors, land use colors swapped from the map design to natural ones (remap), a little
// noise in world space so large surfaces are not flat paint, haze with distance. vertexColor.a = 1 - layer / 4
// for the depth order within a mesh.
STREET_GROUND_VS :: `#version 330
in vec3 vertexPosition;
in vec4 vertexColor;
uniform mat4 mvp;
uniform mat4 matModel;
uniform float depth_bias;
out vec4 color;
out vec3 world;
out float depth;
void main() {
	vec4 p = mvp * vec4(vertexPosition, 1.0);
	float layer = depth_bias + floor((1.0 - vertexColor.a) * 4.0 + 0.5);
	p.z -= layer * 2.5e-7 * p.w;
	gl_Position = p;
	color = vertexColor;
	world = (matModel * vec4(vertexPosition, 1.0)).xyz;
	depth = p.w;
}
`

STREET_GROUND_FS :: `#version 330
in vec4 color;
in vec3 world;
in float depth;
uniform vec3 fog_color;
uniform vec2 fog_range;
uniform float remap;
uniform vec3 map_colors[6];
uniform vec3 real_colors[6];
uniform vec2 origin;
uniform vec3 tone;
out vec4 finalColor;
float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float noise(vec2 p) {
	vec2 i = floor(p), f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), u.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), u.x), u.y);
}
void main() {
	vec3 c = color.rgb;
	if (remap > 0.5) {
		for (int i = 0; i < 6; i++) {
			if (distance(c, map_colors[i]) < 0.01) c = real_colors[i];
		}
	}
	vec2 q = world.xz + origin;
	float n = noise(q / 9.0) * 0.6 + noise(q / 41.0) * 0.4;
	float near = 1.0 - smoothstep(60.0, 900.0, depth);
	c *= 1.0 + (n - 0.5) * (0.10 + 0.08 * near);
	c *= tone;
	float f = clamp((depth - fog_range.x) / max(fog_range.y - fog_range.x, 1e-3), 0.0, 1.0);
	finalColor = vec4(mix(c, fog_color, f * (2.0 - f)), 1.0);
}
`

// Sky, light and the natural colors for day and night (zero theme = night, as the map).
Street_Look :: struct {
	zenith, horizon:   rl.Color, // sky; horizon is also the haze
	sun_dir:           [3]f32, // towards the sun, street space
	sun:               f32,
	sky_amb, gnd_amb:  [3]f32, // ambient light from above and below, for the car
	tone:              [3]f32, // multiplies the ground colors
	land:              rl.Color,
	areas:             [Area_Kind]rl.Color,
	asphalt, motorway: rl.Color,
	marking, river:    rl.Color,
	buildings:         Buildings_Look,
}

street_look :: proc(w: ^World) -> Street_Look {
	day := Street_Look {
		zenith = {92, 138, 196, 255},
		horizon = {196, 210, 222, 255},
		sun_dir = linalg.normalize([3]f32{-0.45, 0.7, 0.55}),
		sun = 1,
		sky_amb = {0.66, 0.76, 0.9},
		gnd_amb = {0.3, 0.29, 0.25},
		tone = {1, 1, 1},
		land = {106, 122, 78, 255},
		areas = {
			.City = {132, 130, 124, 255},
			.Park = {78, 110, 60, 255},
			.Farmland = {136, 138, 92, 255},
			.Marsh = {96, 112, 86, 255},
			.Beach = {206, 192, 156, 255},
			.Water = {58, 86, 106, 255},
		},
		asphalt = {66, 68, 72, 255},
		motorway = {76, 77, 80, 255},
		marking = {214, 212, 200, 255},
		river = {56, 84, 102, 255},
		buildings = {roof = {0.47, 0.4, 0.37}, wall = {0.74, 0.7, 0.64}, tree = {0.3, 0.4, 0.24}},
	}
	if w.theme == .Night {
		n := day
		n.zenith = {10, 14, 26, 255}
		n.horizon = {34, 42, 62, 255}
		n.sun_dir = linalg.normalize([3]f32{0.3, 0.8, -0.5}) // the moon
		n.sun = 0.35
		n.sky_amb = {0.16, 0.2, 0.3}
		n.gnd_amb = {0.05, 0.05, 0.07}
		n.tone = {0.3, 0.34, 0.46}
		n.buildings = {
			roof = {0.15, 0.15, 0.2},
			wall = {0.25, 0.27, 0.34},
			tree = {0.08, 0.12, 0.1},
		}
		day = n
	}
	day.buildings.fog = rl.ColorNormalize(day.horizon).rgb
	return day
}

// Map space (x km, y km south, z km down) to street space (m, y up) around origin.
street_transform :: proc(origin: [2]f32) -> rl.Matrix {
	return rl.Matrix{1000, 0, 0, -1000 * origin.x, 0, 0, -1000, 0, 0, 1000, 0, -1000 * origin.y, 0, 0, 0, 1}
}

// The ship in street space: f64 so pos_frac (below the f32 resolution of pos) counts.
street_ship_pos :: proc(w: ^World) -> [3]f32 {
	s := &w.ship
	o := w.street.origin
	x := (f64(s.pos.x) - f64(o.x)) * 1000 + f64(s.pos_frac.x)
	z := (f64(s.pos.y) - f64(o.y)) * 1000 + f64(s.pos_frac.y)
	return {f32(x), max(s.alt - height_at(w, s.pos.x, s.pos.y), 0), f32(z)}
}

// V: on from the navigation screen (and from the plan screen, which first goes to free flight like M).
street_toggle :: proc(w: ^World) {
	st := &w.street
	if st.on {
		st.on = false
		rl.EnableCursor()
		return
	}
	if w.screen == .Plan {
		nav_stop(w)
		w.screen = .Navigate
		cam_chase(w)
	}
	st.on = true
	st.on_s = 0
	st.yaw, st.pitch, st.idle_s = 0, 0, 0
	st.seeded = false
	rl.DisableCursor()
}

// Builds the line index, the ground plane and the shader. Needs the window.
street_build :: proc(w: ^World) {
	st := &w.street
	if st.ready do return
	perm := context.allocator
	if st.road_cells == nil {
		// Map line segments per cell. Two passes: count, then fill. Each segment goes to the cell of its middle.
		counts := make([]u32, STREET_ROAD_W * STREET_ROAD_H + 1, perm)
		for pass in 0 ..< 2 {
			for l in w.m.lines {
				if Map_Kind(l.kind) == .Border do continue
				for k in l.start ..< l.start + max(l.count, 1) - 1 {
					mid := (w.m.points[k] + w.m.points[k + 1]) / 2
					x := clamp(int(mid.x / STREET_ROAD_CELL_KM), 0, STREET_ROAD_W - 1)
					y := clamp(int(mid.y / STREET_ROAD_CELL_KM), 0, STREET_ROAD_H - 1)
					c := y * STREET_ROAD_W + x
					if pass == 0 {
						counts[c + 1] += 1
					} else {
						st.road_segs[st.road_cells[c] + counts[c]] = l.kind << 24 | u32(k)
						counts[c] += 1
					}
				}
			}
			if pass == 0 {
				for c in 1 ..< len(counts) do counts[c] += counts[c - 1]
				st.road_cells = counts
				st.road_segs = make([]u32, counts[len(counts) - 1], perm)
				counts = make([]u32, STREET_ROAD_W * STREET_ROAD_H + 1, context.temp_allocator)
			}
		}
		logf(w, "street", "%d road segments in %d cells", len(st.road_segs), STREET_ROAD_W * STREET_ROAD_H)
	}
	ground: {
		// The land under everything: a quad of 9 x 9 km, drawn under the car in street space.
		R :: 4500
		pos := make([][3]f32, 6, context.temp_allocator)
		copy(pos, [][3]f32{{-R, 0, -R}, {-R, 0, R}, {R, 0, R}, {-R, 0, -R}, {R, 0, R}, {R, 0, -R}})
		st.ground = rl.Mesh {
			vertexCount   = 6,
			triangleCount = 2,
			vertices      = ([^]f32)(raw_data(pos)),
			colors        = ([^]u8)(raw_data(make([][4]u8, 6, context.temp_allocator))),
		}
		rl.UploadMesh(&st.ground, true)
		st.ground.vertices, st.ground.colors = nil, nil
	}
	sh := rl.LoadShaderFromMemory(STREET_GROUND_VS, STREET_GROUND_FS)
	if !rl.IsShaderValid(sh) do logf(w, "street", "ground shader did not compile")
	st.material = rl.LoadMaterialDefault()
	st.material.shader = sh
	st.loc = {
		fog_c       = rl.GetShaderLocation(sh, "fog_color"),
		fog_r       = rl.GetShaderLocation(sh, "fog_range"),
		bias        = rl.GetShaderLocation(sh, "depth_bias"),
		remap       = rl.GetShaderLocation(sh, "remap"),
		map_colors  = rl.GetShaderLocation(sh, "map_colors"),
		real_colors = rl.GetShaderLocation(sh, "real_colors"),
		origin      = rl.GetShaderLocation(sh, "origin"),
		tone        = rl.GetShaderLocation(sh, "tone"),
	}
	st.ready = true
}

street_unload :: proc(st: ^Street) {
	tiles_unload(&st.roads)
	if !st.ready do return
	rl.UnloadMesh(st.ground)
	rl.UnloadShader(st.material.shader)
	st.ready = false
}

// Road ribbons of one tile at their real width, the river beds, and the lane markings (Tile_Build).
street_road_tile :: proc(w: ^World, lo, hi: [2]f32) -> rl.Mesh {
	st := &w.street
	look := street_look(w)
	pos := make([dynamic][3]f32, 0, 1 << 14, context.temp_allocator)
	col := make([dynamic][4]u8, 0, 1 << 14, context.temp_allocator)
	quad :: proc(
		pos: ^[dynamic][3]f32,
		col: ^[dynamic][4]u8,
		a, b: [2]f32,
		hw: f32,
		c: rl.Color,
		layer: u8,
	) {
		d := b - a
		l := linalg.length(d)
		if l <= 0 do return
		d /= l
		n := [2]f32{-d.y, d.x} * hw
		// Counter-clockwise on the map, like the other ground meshes.
		p0, p1, p2, p3 := a - n, a + n, b + n, b - n
		append(pos, [3]f32{p0.x, p0.y, 0}, [3]f32{p1.x, p1.y, 0}, [3]f32{p2.x, p2.y, 0})
		append(pos, [3]f32{p0.x, p0.y, 0}, [3]f32{p2.x, p2.y, 0}, [3]f32{p3.x, p3.y, 0})
		v := [4]u8{c.r, c.g, c.b, 255 - layer * 64}
		append(col, v, v, v, v, v, v)
	}
	cx := clamp(int(lo.x / STREET_ROAD_CELL_KM), 0, STREET_ROAD_W - 1)
	cy := clamp(int(lo.y / STREET_ROAD_CELL_KM), 0, STREET_ROAD_H - 1)
	c := cy * STREET_ROAD_W + cx
	for item in st.road_segs[st.road_cells[c]:st.road_cells[c + 1]] {
		k := int(item & 0xffffff)
		kind := Map_Kind(item >> 24)
		a, b := w.m.points[k], w.m.points[k + 1]
		mid := (a + b) / 2
		if mid.x < lo.x || mid.y < lo.y || mid.x >= hi.x || mid.y >= hi.y do continue
		// Half widths in m: OSM draws a motorway carriageway, the others both directions on one line.
		hw: f32
		lanes := 0
		color := look.asphalt
		layer: u8 = 2
		#partial switch kind {
		case .Motorway:
			hw, lanes, color = 6.5, 3, look.motorway
		case .Trunk:
			hw, lanes = 5.5, 2
		case .Primary:
			hw, lanes = 4.5, 2
		case .Secondary:
			hw, lanes = 3.8, 2
		case .Tertiary:
			hw, lanes = 3.0, 2
		case .River:
			hw, color, layer = 14, look.river, 1
		case:
			continue
		}
		d := b - a
		l := linalg.length(d)
		if l <= 0 do continue
		dir := d / l
		// Longer by half a width at both ends, so the joints between segments are covered.
		ext := dir * hw / 1000
		quad(&pos, &col, a - ext, b + ext, hw / 1000, color, layer)
		if lanes == 0 do continue
		// Markings: dashed lines between the lanes (3 m dash, 9 m gap), solid edge lines on the motorway.
		side := [2]f32{-dir.y, dir.x}
		length_m := l * 1000
		for lane in 1 ..< lanes {
			off := (f32(lane) / f32(lanes) * 2 - 1) * (hw - 0.4) / 1000
			for s: f32 = 0; s + 3 < length_m; s += 12 {
				p := a + side * off + dir * (s / 1000)
				quad(&pos, &col, p, p + dir * 0.003, 0.00007, look.marking, 3)
			}
		}
		if kind == .Motorway {
			for edge in ([2]f32{-1, 1}) {
				off := side * edge * (hw - 0.5) / 1000
				quad(&pos, &col, a + off, b + off, 0.0001, look.marking, 3)
			}
		}
	}
	return tile_mesh(pos[:], col[:])
}

// Once per frame while on: looking around, the chase camera and the raylib camera. Drawing only, frame time is
// fine.
street_camera :: proc(w: ^World) {
	st := &w.street
	dt := min(rl.GetFrameTime(), MAX_FRAME_DT)
	st.on_s += dt
	s := &w.ship

	// The origin follows the car in steps; the eased camera moves with it.
	origin := linalg.floor(s.pos / STREET_ORIGIN_KM) * STREET_ORIGIN_KM
	if origin != st.origin {
		shift := (st.origin - origin) * 1000
		st.eye += {shift.x, 0, shift.y}
		st.origin = origin
	}

	look := rl.GetMouseDelta() * STREET_MOUSE_RAD_PER_PX
	if rl.IsGamepadAvailable(0) {
		look.x += stick_axis(rl.GetGamepadAxisMovement(0, .RIGHT_X)) * STREET_STICK_RAD_PER_S * dt
	}
	if look != {} {
		st.yaw += look.x
		st.pitch = clamp(st.pitch + look.y, -0.45, 1.2)
		st.idle_s = 0
	} else {
		st.idle_s += dt
	}
	if st.idle_s > STREET_RECENTRE_S {
		k := 1 - math.exp(-dt * 2.5)
		st.yaw = angle_lerp(st.yaw, 0, k)
		st.pitch += (0 - st.pitch) * k
	}
	if wheel := rl.GetMouseWheelMove(); wheel != 0 {
		if st.dist == 0 do st.dist = STREET_CAM_DIST_M
		st.dist = clamp(st.dist * (1 - wheel * 0.12), STREET_CAM_MIN_M, STREET_CAM_MAX_M)
	}
	dist := st.dist == 0 ? STREET_CAM_DIST_M : st.dist

	car := street_ship_pos(w)
	target := car + {0, STREET_CAM_LOOK_UP_M, 0}
	yaw := w.car_anim.heading + st.yaw
	pitch := STREET_CAM_PITCH + st.pitch
	back := [3]f32{-math.sin(yaw) * math.cos(pitch), math.sin(pitch), math.cos(yaw) * math.cos(pitch)}
	goal := target + back * dist
	if !st.seeded {
		st.eye = goal
		st.seeded = true
	}
	st.eye += (goal - st.eye) * (1 - math.exp(-dt * STREET_CAM_RATE))
	// Never further than 1.6 x the distance from the car, however fast it goes.
	if off := st.eye - target; linalg.length(off) > dist * 1.6 do st.eye = target + linalg.normalize(off) * dist * 1.6

	// Walls between the car and the camera pull the camera in, it stays above the ground.
	{
		off := st.eye - target
		l := linalg.length(off)
		steps := int(l / 0.5)
		for i in 1 ..= steps {
			p := target + off * (f32(i) / f32(steps))
			km := st.origin + {p.x, p.z} / 1000
			push, _ := collide_car(w, km, p.y, 0.4)
			if push != {} {
				st.eye = target + off * (f32(max(i - 1, 0)) / f32(steps))
				break
			}
		}
		st.eye.y = max(st.eye.y, 0.5)
	}

	// A short shake after a hit, nothing at rest.
	shake: [3]f32
	if s.free && s.hit_s < 0.35 {
		a := (0.35 - s.hit_s) * 0.25
		t := st.on_s * 60
		shake = {math.sin(t * 1.7), math.sin(t * 2.3), math.sin(t * 1.3)} * a
	}
	speed := clamp(s.speed / SHIP_MAX_SPEED, 0, 1)
	st.view = rl.Camera3D {
		position   = st.eye + shake,
		target     = target + shake,
		up         = {0, 1, 0},
		fovy       = STREET_FOV + STREET_FOV_FAST * speed * speed,
		projection = .PERSPECTIVE,
	}
}

// The whole street view frame: sky, ground, roads, buildings, trees, the cars, then the HUD.
street_draw :: proc(w: ^World) {
	st := &w.street
	street_build(w)
	street_camera(w)
	look := street_look(w)
	screen := [2]f32{f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())}
	transform := street_transform(st.origin)
	centre := w.ship.pos

	// Sky: zenith to the horizon line of this camera, then haze below it (the ground covers that part).
	{
		fwd := st.view.target - st.view.position
		fwd.y = 0
		fwd = linalg.normalize(fwd) * 3000
		h := rl.GetWorldToScreen(st.view.position + fwd, st.view)
		horizon := clamp(h.y, -screen.y, 2 * screen.y)
		rl.ClearBackground(look.horizon)
		if horizon > 0 {
			rl.DrawRectangleGradientV(0, 0, i32(screen.x), i32(horizon) + 1, look.zenith, look.horizon)
		}
	}

	rl.BeginMode3D(st.view)
	{
		sh := st.material.shader
		horizon := rl.ColorNormalize(look.horizon).rgb
		fog := STREET_FOG_M
		origin := st.origin * 1000
		rl.SetShaderValue(sh, st.loc.fog_c, &horizon, .VEC3)
		rl.SetShaderValue(sh, st.loc.fog_r, &fog, .VEC2)
		rl.SetShaderValue(sh, st.loc.origin, &origin, .VEC2)
		rl.SetShaderValue(sh, st.loc.tone, &look.tone, .VEC3)

		// 1: land, a quad kept under the car.
		bias, remap: f32 = 0, 0
		rl.SetShaderValue(sh, st.loc.bias, &bias, .FLOAT)
		rl.SetShaderValue(sh, st.loc.remap, &remap, .FLOAT)
		mat := st.material
		{
			land: [6][4]u8
			for &c in land do c = {look.land.r, look.land.g, look.land.b, 255}
			rl.UpdateMeshBuffer(st.ground, 3, &land[0], size_of(land), 0)
			car := street_ship_pos(w)
			rl.DrawMesh(st.ground, mat, rl.Matrix(linalg.matrix4_translate_f32({car.x, 0, car.z})))
		}

		// 2: land use with natural colors.
		lm := &w.line_meshes
		if lm.areas.vertexCount > 0 {
			pal := palette(w)
			map_colors := [6][3]f32 {
				rl.ColorNormalize(pal.city).rgb,
				rl.ColorNormalize(pal.park).rgb,
				rl.ColorNormalize(pal.farmland).rgb,
				rl.ColorNormalize(pal.marsh).rgb,
				rl.ColorNormalize(pal.beach).rgb,
				rl.ColorNormalize(pal.water).rgb,
			}
			real_colors: [6][3]f32
			for k in Area_Kind do real_colors[int(k)] = rl.ColorNormalize(look.areas[k]).rgb
			bias, remap = 1, 1
			rl.SetShaderValue(sh, st.loc.bias, &bias, .FLOAT)
			rl.SetShaderValue(sh, st.loc.remap, &remap, .FLOAT)
			rl.SetShaderValueV(sh, st.loc.map_colors, &map_colors, .VEC3, 6)
			rl.SetShaderValueV(sh, st.loc.real_colors, &real_colors, .VEC3, 6)
			if lm.area_theme != w.theme {
				areas_color(w, lm)
				rl.UpdateMeshBuffer(
					lm.areas,
					3,
					raw_data(lm.area_colors),
					i32(len(lm.area_colors) * size_of([4]u8)),
					0,
				)
			}
			rl.DrawMesh(lm.areas, mat, transform)
		}

		// 3: rivers, roads and markings.
		bias, remap = 2, 0
		rl.SetShaderValue(sh, st.loc.bias, &bias, .FLOAT)
		rl.SetShaderValue(sh, st.loc.remap, &remap, .FLOAT)
		tiles_update_draw(
			w,
			&st.roads,
			STREET_ROAD_TILE_KM,
			STREET_REACH_KM,
			street_road_tile,
			mat,
			centre,
			transform,
		)
	}

	// 4: buildings at real height, the generated towns, the trees.
	fog := STREET_FOG_M
	buildings_draw(
		w,
		fog,
		1 / BUILDINGS_HEIGHT_X,
		centre,
		STREET_REACH_KM + BUILDINGS_RADIUS_KM,
		transform,
		look.buildings,
	)
	towns_draw(w, centre, STREET_REACH_KM, transform)
	nature_draw(w, centre, STREET_REACH_KM, transform)

	// 5: the cars, each with a soft contact shadow.
	car_anim_update(w, min(rl.GetFrameTime(), MAX_FRAME_DT))
	{
		car := street_ship_pos(w)
		street_shadow(car, w.car_anim.heading)
		car_draw_street(w, car, w.car_anim, rl.WHITE, look, w.car_skin)
		for o in w.others[:w.other_count] {
			p := others_draw_pos(w, o)
			d := (p - st.origin) * 1000
			if linalg.length(d - car.xz) > STREET_REACH_KM * 1000 do continue
			pos := [3]f32{d.x, max(o.alt - height_at(w, p.x, p.y), 0), d.y}
			an := Car_Anim {
				fly     = o.on_road ? 0 : 1,
				heading = o.heading,
			}
			jam := traffic_near(w, o.pos, o.alt, o.on_road, TRAFFIC_RADIUS_KM) >= TRAFFIC_MIN_CARS
			street_shadow(pos, o.heading)
			car_draw_street(w, pos, an, jam ? CAR_JAM_TINT : rl.WHITE, look, o.skin)
		}
	}
	rl.EndMode3D()

	street_hud(w)
}

// A soft dark patch on the ground under a car, fainter the higher it is.
street_shadow :: proc(car: [3]f32, heading: f32) {
	f := 1 - clamp(car.y / 30, 0, 1)
	if f <= 0 do return
	fwd := [3]f32{math.sin(heading), 0, -math.cos(heading)}
	side := [3]f32{-fwd.z, 0, fwd.x}
	base := [3]f32{car.x, 0.03, car.z}
	SEGMENTS :: 20
	for ring in 0 ..< 3 {
		g := 1 - f32(ring) * 0.22
		a := u8(38 * f)
		for i in 0 ..< SEGMENTS {
			t0 := f32(i) / SEGMENTS * math.TAU
			t1 := f32(i + 1) / SEGMENTS * math.TAU
			p0 := base + (fwd * math.cos(t0) * 2.5 + side * math.sin(t0) * 1.1) * g
			p1 := base + (fwd * math.cos(t1) * 2.5 + side * math.sin(t1) * 1.1) * g
			rl.DrawTriangle3D(base, p1, p0, {0, 0, 0, a})
		}
	}
}

// Speed, height and heading bottom left, the keys for a few seconds after switching on. Plain, small, legible.
street_hud :: proc(w: ^World) {
	s := &w.ship
	pal := palette(w)
	screen := [2]f32{f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())}
	speed := fmt.tprintf("%d", int(math.round(s.speed * 3.6)))
	height := fmt.tprintf("%d m", int(math.round(max(s.alt - height_at(w, s.pos.x, s.pos.y), 0))))
	compass := [8]string{"N", "NE", "E", "SE", "S", "SW", "W", "NW"}
	// The heading can be negative (ship_step keeps the sign of math.mod), so wrap the index both ways.
	heading := compass[(int(math.round(s.heading / (math.TAU / 8))) % 8 + 8) % 8]

	PAD :: 24
	box := rl.Rectangle{PAD, screen.y - PAD - 92, 210, 92}
	round_rect(box, 14, rl.ColorAlpha(pal.surface, 0.72))
	size := ui_text_size(w, speed, .Figtree_700, 40)
	ui_text(w, {box.x + 18, box.y + 12}, speed, .Figtree_700, 40, pal.text)
	ui_text(w, {box.x + 22 + size.x, box.y + 32}, "km/h", .Roboto_500, 14, pal.text_2)
	ui_text(w, {box.x + 18, box.y + 62}, height, .Roboto_500, 14, pal.text_2)
	ui_text(w, {box.x + 110, box.y + 62}, heading, .Roboto_500, 14, pal.text_2)
	if w.nav.active && !w.nav.manual {
		ui_text(w, {box.x + 150, box.y + 62}, "auto", .Roboto_500, 14, pal.accent)
	}

	if w.street.on_s < STREET_HINT_S {
		alpha := 1 - clamp((w.street.on_s - (STREET_HINT_S - 1)) / 1, 0, 1)
		HINT :: "W/S throttle and brake   A/D turn   Space/Shift up and down   Mouse look around   V or Esc map"
		hint := ui_text_size(w, HINT, .Roboto_500, 14)
		r := rl.Rectangle{(screen.x - hint.x) / 2 - 14, PAD, hint.x + 28, hint.y + 16}
		round_rect(r, 10, rl.ColorAlpha(pal.surface, 0.72 * alpha))
		ui_text(w, {r.x + 14, r.y + 8}, HINT, .Roboto_500, 14, rl.ColorAlpha(pal.text, alpha))
	}
}
