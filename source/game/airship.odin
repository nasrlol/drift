// author: dario
package game

import "core:compress/deflate"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:mem/virtual"
import rl "vendor:raylib"

// The flying car (Lars, 2026-11-21: "het is een vliegende auto", "iets realistisch in 3d"): the Car Concept model
// (CC BY 4.0, Eric Chadwick / Darmstadt Graphics Group, from a CC0 model by Unity Fan; assets/car-LICENSE.txt),
// baked by tools/bake_car into assets/car.bin.gz: smooth normals, a color and a shading class per vertex (paint,
// glass, metal, lights, matte), lit by CAR_FS. Taking off, the wheels fold flat under the car and glow as
// thrusters; landing, they fold back down. Car_Anim drives that from the ship state. Model space: metres, x
// forward, y up, z to the right, origin on the ground under the middle of the car.
CAR_DATA :: #load("../../assets/car.bin.gz")
CAR_MAGIC :: 0x52435244 // "DRCR"
CAR_VERSION :: 1
CAR_MAX_PARTS :: 12
CAR_MAX_MATERIALS :: 32
CAR_LEN :: 4.36 // m, the baked model
CAR_WHEEL_R :: 0.36
CAR_STEER :: 0.45 // the front wheels' lock as drawn, radians
CAR_PX :: 110.0 // on-screen length on the flat map
AIRSHIP_TILT :: 1.0 // radians from straight down, so the sides show
CAR_BANK :: 0.35 // roll in radians at the maximum turn rate
CAR_PITCH :: 0.18 // nose up in radians at the maximum climb rate
CAR_ANIM_RATE :: 3.0 // the animation closes this share of the gap per second
// In free flight the wheels come down over the CAR_WHEELS_DOWN_M above CAR_WHEELS_STAND_M over the ground or a
// roof, so they are down before the car lands (Lars, 2026-11-21: "de wielen moeten sneller normaal worden, iets
// voor hij landt"); folding and unfolding run at CAR_WHEELS_RATE (~0.3 s). Our values.
CAR_WHEELS_DOWN_M :: 4.8
CAR_WHEELS_STAND_M :: 1.2
CAR_WHEELS_RATE :: 9.0
CAR_HEADING_RATE :: 8.0
CAR_BOB_M :: 0.06 // hover bob in the air
CAR_GLOW :: rl.Color{90, 230, 255, 255}

Car_Part :: struct {
	mesh:  rl.Mesh,
	kind:  u32, // 0 body, 1..4 wheel front left, front right, rear left, rear right
	pivot: [3]f32,
}

Airship :: struct {
	parts:      [CAR_MAX_PARTS]Car_Part,
	part_count: int,
	glow:       rl.Mesh, // thruster disc under a folded wheel
	material:   rl.Material,
	ready:      bool,
	skins:      [Car_Skin]Skin_Mesh, // generated bodies (car_models.odin), Concept unused
	preview:    rl.RenderTexture2D, // the plan panel's skin preview
}

CAR_VS :: `#version 330
in vec3 vertexPosition;
in vec3 vertexNormal;
in vec4 vertexColor;
uniform mat4 mvp;
uniform mat4 matNormal;
out vec3 normal;
out vec4 color;
void main() {
	normal = normalize((matNormal * vec4(vertexNormal, 0.0)).xyz);
	color = vertexColor;
	gl_Position = mvp * vec4(vertexPosition, 1.0);
}
`

// Alpha of the vertex color is the shading class: 0 matte, 1 paint, 2 glass, 3 metal, 4 light.
CAR_FS :: `#version 330
in vec3 normal;
in vec4 color;
uniform vec4 colDiffuse;
uniform vec3 light_dir;
uniform vec3 view_dir;
uniform vec3 sky;
uniform vec3 ground;
uniform float sun;
out vec4 finalColor;
void main() {
	vec3 n = normalize(normal);
	if (!gl_FrontFacing) n = -n;
	int cls = int(color.a * 255.0 + 0.5);
	vec3 base = color.rgb * colDiffuse.rgb;
	vec3 l = normalize(light_dir);
	vec3 v = normalize(view_dir);
	vec3 h = normalize(l + v);
	float ndl = max(dot(n, l), 0.0);
	float ndh = max(dot(n, h), 0.0);
	vec3 r = reflect(-v, n);
	vec3 env = r.y > 0.0 ? mix(sky * 0.7, sky * 1.3, r.y) : mix(sky * 0.7, ground, min(-r.y * 3.0, 1.0));
	vec3 amb = mix(ground, sky, n.y * 0.5 + 0.5) * 0.6;
	float fres = pow(1.0 - max(dot(n, v), 0.0), 5.0);
	vec3 c;
	if (cls == 4) {
		c = base * 1.3 + 0.25;
	} else if (cls == 2) {
		c = base * (amb + ndl * 0.3) + env * (0.3 + 0.6 * fres) + sun * pow(ndh, 220.0) * 1.6;
	} else if (cls == 3) {
		c = base * (amb * 0.4 + ndl * sun * 0.5) + base * env * 0.7 + sun * pow(ndh, 60.0) * 0.9;
	} else if (cls == 1) {
		c = base * (amb + ndl * sun * 0.95) + env * (0.04 + 0.5 * fres) + sun * pow(ndh, 140.0) * 1.1
			+ sun * pow(ndh, 10.0) * 0.06;
	} else {
		c = base * (amb + ndl * sun * 0.9) + sun * pow(ndh, 16.0) * 0.04;
	}
	finalColor = vec4(c, colDiffuse.a);
}
`

// Unpacks assets/car.bin.gz into GPU meshes (format in tools/bake_car). Staging memory is a local arena freed at
// the end; only the index arrays stay (in w.perm), because raylib's DrawMesh picks indexed drawing by
// mesh.indices. The GL objects live in raylib, a shared library in debug builds, so they survive a hot reload.
// Needs the window.
airship_build :: proc(w: ^World) {
	a := &w.airship
	scratch: virtual.Arena
	if virtual.arena_init_growing(&scratch) != nil do return
	defer virtual.arena_destroy(&scratch)
	tmp := virtual.arena_allocator(&scratch)
	perm := virtual.arena_allocator(&w.perm)

	unzipped := make([dynamic]u8, 0, 2 << 20, tmp)
	if err := deflate.inflate_gzip(&unzipped, CAR_DATA, allocator = tmp); err != nil {
		logf(w, "car", "car.bin.gz does not unpack: %v", err)
		return
	}
	data := unzipped[:]
	Header :: struct {
		magic, version, material_count, part_count: u32le,
		scale:                                      f32le,
		_:                                          [3]u32le,
	}
	Part_Header :: struct {
		kind, vertex_count, index_count, _: u32le,
		pivot:                              [3]f32le,
		_:                                  f32le,
	}
	Vertex :: struct #packed {
		pos:      [3]i16le,
		normal:   [2]i8,
		material: u8,
		_:        u8,
	}
	#assert(size_of(Header) == 32 && size_of(Part_Header) == 32 && size_of(Vertex) == 10)
	if len(data) < size_of(Header) do return
	h: Header
	mem.copy(&h, raw_data(data), size_of(Header))
	if h.magic != CAR_MAGIC ||
	   h.version != CAR_VERSION ||
	   h.part_count > CAR_MAX_PARTS ||
	   h.material_count > CAR_MAX_MATERIALS {
		logf(w, "car", "car.bin.gz: wrong magic, version or counts")
		return
	}
	off := size_of(Header)
	need := off + int(h.material_count) * 4 + int(h.part_count) * size_of(Part_Header)
	if len(data) < need do return
	materials: [CAR_MAX_MATERIALS][4]u8
	mem.copy(&materials, &data[off], int(h.material_count) * 4)
	off += int(h.material_count) * 4
	heads: [CAR_MAX_PARTS]Part_Header
	mem.copy(&heads, &data[off], int(h.part_count) * size_of(Part_Header))
	off += int(h.part_count) * size_of(Part_Header)

	for ph, pi in heads[:h.part_count] {
		vc, ic := int(ph.vertex_count), int(ph.index_count)
		vbytes := vc * size_of(Vertex)
		if vc > 65535 || off + vbytes + ic * 2 > len(data) {
			logf(w, "car", "car.bin.gz: part %d is cut off", pi)
			return
		}
		verts := make([][3]f32, vc, tmp)
		normals := make([][3]f32, vc, tmp)
		colors := make([][4]u8, vc, tmp)
		indices := make([]u16, ic, perm)
		for i in 0 ..< vc {
			v: Vertex
			mem.copy(&v, &data[off + i * size_of(Vertex)], size_of(Vertex))
			verts[i] = {f32(v.pos.x), f32(v.pos.y), f32(v.pos.z)} * f32(h.scale)
			// Octahedral normal.
			o := [2]f32{f32(v.normal.x), f32(v.normal.y)} / 127
			nz := 1 - abs(o.x) - abs(o.y)
			if nz < 0 do o = {(1 - abs(o.y)) * math.sign(o.x), (1 - abs(o.x)) * math.sign(o.y)}
			normals[i] = linalg.normalize0([3]f32{o.x, o.y, nz})
			mat := materials[min(int(v.material), CAR_MAX_MATERIALS - 1)]
			colors[i] = mat
		}
		if ph.kind > 0 {
			// The model's front wheels are steered (~22 deg) at rest, so rolling them around the car's axle
			// swung them about (Lars: "de voorbanden maken rare animatie"). Each wheel is turned straight: the
			// direction of its largest spread in the ground plane (the rolling direction, found by the
			// covariance of its points) is put on the car's forward axis. Its own steering is drawn later.
			cxx, cxz, czz: f32
			for v in verts {
				cxx += v.x * v.x
				cxz += v.x * v.z
				czz += v.z * v.z
			}
			phi := 0.5 * math.atan2(2 * cxz, cxx - czz)
			cp, sp := math.cos(phi), math.sin(phi)
			for &v in verts do v = {v.x * cp + v.z * sp, v.y, -v.x * sp + v.z * cp}
			for &n in normals do n = {n.x * cp + n.z * sp, n.y, -n.x * sp + n.z * cp}
		}
		off += vbytes
		mem.copy(raw_data(indices), &data[off], ic * 2)
		off += ic * 2
		for off % 4 != 0 do off += 1
		for &i in indices do if int(i) >= vc do i = 0
		mesh := rl.Mesh {
			vertexCount   = i32(vc),
			triangleCount = i32(ic / 3),
			vertices      = cast([^]f32)raw_data(verts),
			normals       = cast([^]f32)raw_data(normals),
			colors        = cast([^]u8)raw_data(colors),
			indices       = raw_data(indices),
		}
		rl.UploadMesh(&mesh, false)
		mesh.vertices, mesh.normals, mesh.colors = nil, nil, nil
		a.parts[a.part_count] = {
			mesh  = mesh,
			kind  = u32(ph.kind),
			pivot = {f32(ph.pivot.x), f32(ph.pivot.y), f32(ph.pivot.z)},
		}
		a.part_count += 1
	}

	// Thruster glow: a disc in the x-z plane, radius 1, light class.
	{
		SEG :: 20
		verts := make([][3]f32, SEG * 3, tmp)
		normals := make([][3]f32, SEG * 3, tmp)
		colors := make([][4]u8, SEG * 3, tmp)
		indices := make([]u16, SEG * 3, perm)
		for k in 0 ..< SEG {
			a0 := math.TAU * f32(k) / SEG
			a1 := math.TAU * f32(k + 1) / SEG
			verts[k * 3 + 0] = {0, 0, 0}
			verts[k * 3 + 1] = {math.cos(a1), 0, math.sin(a1)}
			verts[k * 3 + 2] = {math.cos(a0), 0, math.sin(a0)}
			for j in 0 ..< 3 {
				normals[k * 3 + j] = {0, -1, 0}
				colors[k * 3 + j] = {CAR_GLOW.r, CAR_GLOW.g, CAR_GLOW.b, j == 0 ? 4 : 4}
				indices[k * 3 + j] = u16(k * 3 + j)
			}
		}
		a.glow = rl.Mesh {
			vertexCount   = SEG * 3,
			triangleCount = SEG,
			vertices      = cast([^]f32)raw_data(verts),
			normals       = cast([^]f32)raw_data(normals),
			colors        = cast([^]u8)raw_data(colors),
			indices       = raw_data(indices),
		}
		rl.UploadMesh(&a.glow, false)
		a.glow.vertices, a.glow.normals, a.glow.colors = nil, nil, nil
	}

	a.material = rl.LoadMaterialDefault()
	a.material.shader = rl.LoadShaderFromMemory(CAR_VS, CAR_FS)
	a.ready = a.part_count > 0
	if a.ready do car_skins_build(w, tmp)
	logf(w, "car", "car model: %d parts", a.part_count)
}

// What the car shows this frame, eased from the ship state (drawing only, frame time is fine).
Car_Anim :: struct {
	fly:      f32, // 0 on the road (wheels down) .. 1 in the air (wheels folded flat, thrusters on)
	bank:     f32,
	pitch:    f32,
	heading:  f32,
	climb_ms: f32,
	last_alt: f32,
	roll:     f32, // wheel rotation, radians
	steer:    f32, // front wheel angle, radians, positive to the right
	time:     f32,
	seeded:   bool,
}

// Eases w.car_anim towards the drawn ship (w.pose and the ship state): fly from the height above the road (landing
// and take-off show as the arms swinging and the wheels tucking), bank from the turn rate, pitch from the climb,
// the heading without jumps.
car_anim_update :: proc(w: ^World, dt: f32) {
	s := &w.ship
	p := w.pose
	an := &w.car_anim
	ground := height_at(w, f32(p.pos.x), f32(p.pos.y))
	fly: f32 = 1
	if s.on_road || (s.free && s.driving) {
		fly = 0
	} else if s.landing || s.lifting {
		fly = clamp((p.alt - ground) / SHIP_MIN_CLEARANCE, 0, 1)
	} else if s.free {
		hag := p.alt - ground
		_, roof := collide_car(w, {f32(p.pos.x), f32(p.pos.y)}, hag, 0.5)
		fly = clamp((hag - max(roof, 0) - CAR_WHEELS_STAND_M) / CAR_WHEELS_DOWN_M, 0, 1)
	}
	if !an.seeded {
		an^ = {
			fly      = fly,
			heading  = p.heading,
			last_alt = p.alt,
			seeded   = true,
		}
	}
	k := 1 - math.exp(-dt * CAR_ANIM_RATE)
	an.fly += (fly - an.fly) * (s.free ? 1 - math.exp(-dt * CAR_WHEELS_RATE) : k)
	if dt > 0 {
		an.climb_ms += ((p.alt - an.last_alt) / dt - an.climb_ms) * k
	}
	an.last_alt = p.alt
	bank := clamp(s.turn_rate / SHIP_MAX_TURN_RATE, -1, 1) * CAR_BANK * an.fly
	pitch := clamp(an.climb_ms / SHIP_CLIMB_RATE, -1, 1) * CAR_PITCH * an.fly
	an.bank += (bank - an.bank) * k
	an.pitch += (pitch - an.pitch) * k
	an.heading = angle_lerp(an.heading, p.heading, 1 - math.exp(-dt * CAR_HEADING_RATE))
	an.roll -= dt * s.speed / CAR_WHEEL_R * (1 - an.fly)
	steer := (1 - an.fly) * w.controls.turn * CAR_STEER
	an.steer += (steer - an.steer) * (1 - math.exp(-dt * 8))
	an.time += dt
}

// The car at pos (km) and alt (m), heading: soft shadow on the ground, then the model through an orthographic
// camera that looks at it from the south. One world unit is one pixel, so the model stays px long at every zoom,
// and the camera target is moved so the model lands on its screen position. The altitude shows in a tilted view
// as the gap between the car and its shadow.
car_draw :: proc(
	w: ^World,
	pos: [2]f32,
	alt, heading: f32,
	an: Car_Anim,
	px: f32,
	tint: rl.Color,
	skin: Car_Skin,
) {
	a := &w.airship
	if !a.ready do return
	ground := height_at(w, pos.x, pos.y)
	above := max(alt - ground, 0)
	pg, visible := cam_to_screen(w, {pos.x, pos.y, 0})
	if !visible do return
	pa, _ := cam_to_screen(w, {pos.x, pos.y, above})
	screen := [2]f32{f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())}

	// Shadow: smaller and fainter the higher the car.
	f := 1 - clamp(above / 400, 0, 0.6)
	for k in 0 ..< 3 {
		g := (1 - f32(k) * 0.25) * f
		rl.DrawEllipse(i32(pg.x), i32(pg.y), px * 0.5 * g, px * 0.24 * g, {0, 0, 0, u8(45 * f)})
	}

	d := pa - screen / 2
	scale := px / CAR_LEN
	// A tilted map camera shows the car more from behind, never less tilted than on the flat map.
	tilt := max(f32(AIRSHIP_TILT), w.cam.pose.tilt)
	sin_t := math.sin(tilt)
	cos_t := math.cos(tilt)
	target := [3]f32{-d.x, d.y * sin_t, -d.y * cos_t}
	cam3 := rl.Camera3D {
		position   = target + {0, 1000 * cos_t, 1000 * sin_t},
		target     = target,
		up         = {0, 0, -1},
		fovy       = screen.y,
		projection = .ORTHOGRAPHIC,
	}
	car_shader_light(w, {-0.45, 1.3, 0.3}, {0, cos_t, sin_t})

	yaw := math.PI / 2 - (heading - w.cam.pose.yaw)
	bob := math.sin(an.time * 2.2) * CAR_BOB_M * an.fly
	m := linalg.matrix4_scale_f32({scale, scale, scale})
	m = m * linalg.matrix4_rotate_f32(yaw, {0, 1, 0})
	m = m * linalg.matrix4_translate_f32({0, bob + 0.25 * an.fly, 0})
	m = m * linalg.matrix4_rotate_f32(-an.bank, {1, 0, 0})
	m = m * linalg.matrix4_rotate_f32(an.pitch, {0, 0, 1})
	mat := a.material
	mat.maps[0].color = tint
	rl.BeginMode3D(cam3)
	car_parts_draw(w, skin, m, an, mat, true)
	rl.EndMode3D()
}

// Sky, ground and sun of the map view for CAR_FS, with the light and view direction.
car_shader_light :: proc(w: ^World, light, view: [3]f32) {
	sky, gnd, sun := [3]f32{0.72, 0.82, 0.98}, [3]f32{0.24, 0.26, 0.3}, f32(1)
	car_shader_set(w, light, view, sky, gnd, sun)
}

car_shader_set :: proc(w: ^World, light, view, sky, gnd: [3]f32, sun: f32) {
	sh := w.airship.material.shader
	light, view, sky, gnd, sun := light, view, sky, gnd, sun
	rl.SetShaderValue(sh, rl.GetShaderLocation(sh, "light_dir"), &light, .VEC3)
	rl.SetShaderValue(sh, rl.GetShaderLocation(sh, "view_dir"), &view, .VEC3)
	rl.SetShaderValue(sh, rl.GetShaderLocation(sh, "sky"), &sky, .VEC3)
	rl.SetShaderValue(sh, rl.GetShaderLocation(sh, "ground"), &gnd, .VEC3)
	rl.SetShaderValue(sh, rl.GetShaderLocation(sh, "sun"), &sun, .FLOAT)
}

// Body and wheels of one skin with model matrix m (inside BeginMode3D). Wheels roll on the road and fold flat
// (tread down, hub out) in the air; glow adds the thruster discs under the folded wheels. A generated skin moves
// and scales the Car Concept wheels to its own axles.
car_parts_draw :: proc(
	w: ^World,
	skin: Car_Skin,
	m: matrix[4, 4]f32,
	an: Car_Anim,
	mat: rl.Material,
	glow: bool,
) {
	a := &w.airship
	gen := &a.skins[skin]
	concept := skin == .Concept || !gen.ready
	if !concept do rl.DrawMesh(gen.body, mat, rl.Matrix(m))
	spare := -1
	for part, pi in a.parts[:a.part_count] {
		if part.kind == 0 {
			if concept do rl.DrawMesh(part.mesh, mat, rl.Matrix(m))
			continue
		}
		pivot := part.pivot
		scale: f32 = 1
		if !concept {
			pivot = {
				gen.wheel_x[part.pivot.x > 0 ? 0 : 1],
				CAR_WHEEL_R * gen.wheel_s,
				math.sign(part.pivot.z) * gen.wheel_z,
			}
			scale = gen.wheel_s
			if part.pivot.z > 0 do spare = pi
		}
		side: f32 = pivot.z > 0 ? 1 : -1
		fold := an.fly * math.PI / 2 * side
		wm := m * linalg.matrix4_translate_f32(pivot)
		// Front wheels (kinds 1, 2) steer; model space x forward, z right, so right is a turn about -y.
		if part.kind <= 2 do wm = wm * linalg.matrix4_rotate_f32(-an.steer, {0, 1, 0})
		wm = wm * linalg.matrix4_rotate_f32(fold, {1, 0, 0}) * linalg.matrix4_scale_f32(scale)
		rl.DrawMesh(part.mesh, mat, rl.Matrix(wm * linalg.matrix4_rotate_f32(an.roll, {0, 0, 1})))
		if glow && an.fly > 0.3 {
			r := CAR_WHEEL_R * 0.85 * (an.fly - 0.3) / 0.7
			gm := wm * linalg.matrix4_rotate_f32(-fold, {1, 0, 0})
			gm = gm * linalg.matrix4_translate_f32({0, -0.12, 0}) * linalg.matrix4_scale_f32({r, 1, r})
			rl.DrawMesh(a.glow, mat, rl.Matrix(gm))
		}
	}
	// The spare wheel on the tail, hub to the back.
	if spare >= 0 && gen.spare != {} {
		sm :=
			m * linalg.matrix4_translate_f32(gen.spare) * linalg.matrix4_rotate_f32(-math.PI / 2, {0, 1, 0})
		rl.DrawMesh(a.parts[spare].mesh, mat, rl.Matrix(sm * linalg.matrix4_scale_f32(gen.wheel_s)))
	}
}

// The car at real size in the street view (inside its BeginMode3D): pos in street space (m, y up). Lit by the
// street view's sun and sky. No bob and no thruster glow, the street view shows the car as it is (Lars:
// "realistisch, niet te veel animatie"); bank and pitch stay, they come from the flight.
car_draw_street :: proc(
	w: ^World,
	pos: [3]f32,
	an: Car_Anim,
	tint: rl.Color,
	look: Street_Look,
	skin: Car_Skin,
	own: ^rl.Material = nil, // the street view's own material (its car shader, its shadow pass), else CAR_FS
) {
	a := &w.airship
	if !a.ready do return
	view := linalg.normalize(w.street.view.position - pos)
	if own == nil do car_shader_set(w, look.sun_dir, view, look.sky_amb, look.gnd_amb, look.sun)
	// Model space: x forward, y up, z right. Heading 0 is north (-z in street space).
	m := linalg.matrix4_translate_f32(pos)
	m = m * linalg.matrix4_rotate_f32(math.PI / 2 - an.heading, {0, 1, 0})
	m = m * linalg.matrix4_rotate_f32(-an.bank, {1, 0, 0})
	m = m * linalg.matrix4_rotate_f32(an.pitch, {0, 0, 1})
	mat := own != nil ? own^ : a.material
	mat.maps[0].color = tint
	car_parts_draw(w, skin, m, an, mat, false)
}

// The player's car (navigation screen).
airship_draw :: proc(w: ^World) {
	car_anim_update(w, frame_time(w))
	an := w.car_anim
	car_draw(
		w,
		{f32(w.pose.pos.x), f32(w.pose.pos.y)},
		w.pose.alt,
		an.heading,
		an,
		CAR_PX,
		rl.WHITE,
		w.car_skin,
	)
}

// Other cars from the presence gossip, in the skin their player chose and a bit smaller, so the own car stands
// out. Cars in a traffic jam (TRAFFIC_MIN_CARS or more on their way within TRAFFIC_RADIUS_KM, themselves
// included) turn orange.
CAR_OTHER_PX :: 80.0
CAR_JAM_TINT :: rl.Color{255, 150, 90, 255}

others_draw :: proc(w: ^World) {
	px: f32 = w.screen == .Navigate ? CAR_OTHER_PX : CAR_OTHER_PX * 0.6
	for o in w.others[:w.other_count] {
		an := Car_Anim {
			fly  = o.on_road ? 0 : 1,
			time = w.car_anim.time + f32(o.author[0]),
		}
		jam := traffic_near(w, o.pos, o.alt, o.on_road, TRAFFIC_RADIUS_KM) >= TRAFFIC_MIN_CARS
		car_draw(w, others_draw_pos(w, o), o.alt, o.heading, an, px, jam ? CAR_JAM_TINT : rl.WHITE, o.skin)
	}
}
