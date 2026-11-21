// author: dario
package game

import "core:math"
import "core:math/linalg"
import rl "vendor:raylib"

// The flying car (Lars, 2026-11-21: "het is een vliegende auto"): a low-poly car with four wheels and four
// ducted fans on folding arms. On the road the arms lie folded along the body and the wheels are down; in the air
// the arms swing out, the fans spin and the wheels tuck in. Car_Anim drives that change from the ship state, so
// landing and take-off show as a transition. Model space: metres, x forward (nose is +x), y up, z to the right,
// origin on the ground under the middle of the car. Colors from docs/drift-design.pdf ("Het luchtschip").
CAR_LEN :: 5.2
CAR_PX :: 90.0 // on-screen length on the flat map
AIRSHIP_TILT :: 0.7 // radians from straight down, so the sides show
CAR_BANK :: 0.4 // roll in radians at the maximum turn rate
CAR_PITCH :: 0.22 // nose up in radians at the maximum climb rate
CAR_ANIM_RATE :: 4.0 // the animation closes this share of the gap per second
CAR_HEADING_RATE :: 8.0
CAR_BOB_M :: 0.12 // hover bob in the air
AIRSHIP_MAX_VERTS :: 4096
AIRSHIP_PROP_VERTS :: 128
CAR_WHEEL_VERTS :: 512
CAR_POD_VERTS :: 2048
CAR_WHEEL_R :: 0.36
CAR_DUCT_R :: 0.75

// Arms: root on the body (model space), folded angle (along the body) and open angle (out at 45 degrees), radians
// around y; an angle t turns the arm from +x to (cos t, 0, -sin t).
CAR_ARMS :: [4]struct {
	root:   [3]f32,
	folded: f32,
	open:   f32,
} {
	{{1.9, 1.0, 0.8}, -math.PI, -math.PI * 0.25},
	{{1.9, 1.0, -0.8}, math.PI, math.PI * 0.25},
	{{-2.1, 1.0, 0.8}, 0, -math.PI * 0.75},
	{{-2.1, 1.0, -0.8}, 0, math.PI * 0.75},
}
CAR_ARM_LEN :: 1.5
CAR_WHEELS :: [4][3]f32 {
	{1.55, CAR_WHEEL_R, 0.92},
	{1.55, CAR_WHEEL_R, -0.92},
	{-1.55, CAR_WHEEL_R, 0.92},
	{-1.55, CAR_WHEEL_R, -0.92},
}

Airship :: struct {
	verts:        [AIRSHIP_MAX_VERTS][3]f32,
	colors:       [AIRSHIP_MAX_VERTS][4]u8,
	prop_verts:   [AIRSHIP_PROP_VERTS][3]f32,
	prop_colors:  [AIRSHIP_PROP_VERTS][4]u8,
	wheel_verts:  [CAR_WHEEL_VERTS][3]f32,
	wheel_colors: [CAR_WHEEL_VERTS][4]u8,
	pod_verts:    [CAR_POD_VERTS][3]f32,
	pod_colors:   [CAR_POD_VERTS][4]u8,
	body:         rl.Mesh,
	prop:         rl.Mesh,
	wheel:        rl.Mesh,
	pod:          rl.Mesh,
	material:     rl.Material,
	ready:        bool,
}

// What the car shows this frame, eased from the ship state (drawing only, frame time is fine).
Car_Anim :: struct {
	fly:      f32, // 0 on the road (arms folded, wheels down) .. 1 in the air
	bank:     f32,
	pitch:    f32,
	heading:  f32,
	climb_ms: f32,
	last_alt: f32,
	spin:     f32,
	time:     f32,
	seeded:   bool,
}

Mesh_Build :: struct {
	verts:  [][3]f32,
	colors: [][4]u8,
	count:  int,
}

LIGHT_DIR :: [3]f32{0.35, 0.85, 0.4}

hex :: proc(rgb: u32) -> [3]f32 {
	return {f32(rgb >> 16 & 0xff), f32(rgb >> 8 & 0xff), f32(rgb & 0xff)}
}

// One flat shaded triangle. The normal is flipped to point away from `centre` and the winding follows it, so
// every part only has to give a point inside itself. Zero area triangles (the nose point) are dropped.
tri :: proc(b: ^Mesh_Build, p0, p1, p2, centre: [3]f32, color: [3]f32) {
	if b.count + 3 > len(b.verts) do return
	n := linalg.cross(p1 - p0, p2 - p0)
	if linalg.length(n) < 1e-5 do return
	n = linalg.normalize(n)
	p1, p2 := p1, p2
	if linalg.dot(n, (p0 + p1 + p2) / 3 - centre) < 0 {
		n = -n
		p1, p2 = p2, p1
	}
	shade := 0.55 + 0.45 * max(linalg.dot(n, linalg.normalize(LIGHT_DIR)), 0)
	c := color * shade
	rgba := [4]u8{u8(clamp(c.x, 0, 255)), u8(clamp(c.y, 0, 255)), u8(clamp(c.z, 0, 255)), 255}
	b.verts[b.count + 0], b.verts[b.count + 1], b.verts[b.count + 2] = p0, p1, p2
	b.colors[b.count + 0], b.colors[b.count + 1], b.colors[b.count + 2] = rgba, rgba, rgba
	b.count += 3
}

// A flat quad, visible from both sides (fins).
quad_flat :: proc(b: ^Mesh_Build, p0, p1, p2, p3: [3]f32, color: [3]f32) {
	mid := (p0 + p1 + p2 + p3) / 4
	n := linalg.normalize(linalg.cross(p1 - p0, p2 - p0))
	for side in ([2]f32{1, -1}) {
		c := mid - n * side
		tri(b, p0, p1, p2, c, color)
		tri(b, p0, p2, p3, c, color)
	}
}

box :: proc(b: ^Mesh_Build, lo, hi: [3]f32, color: [3]f32) {
	mid := (lo + hi) / 2
	v := [8][3]f32 {
		{lo.x, lo.y, lo.z},
		{hi.x, lo.y, lo.z},
		{hi.x, hi.y, lo.z},
		{lo.x, hi.y, lo.z},
		{lo.x, lo.y, hi.z},
		{hi.x, lo.y, hi.z},
		{hi.x, hi.y, hi.z},
		{lo.x, hi.y, hi.z},
	}
	faces := [6][4]int{{0, 1, 2, 3}, {5, 4, 7, 6}, {4, 0, 3, 7}, {1, 5, 6, 2}, {3, 2, 6, 7}, {4, 5, 1, 0}}
	for f in faces {
		tri(b, v[f[0]], v[f[1]], v[f[2]], mid, color)
		tri(b, v[f[0]], v[f[2]], v[f[3]], mid, color)
	}
}

// A cylinder around the z axis (radius 1, z -0.5..0.5), scaled per wheel when drawn.
cylinder :: proc(b: ^Mesh_Build, sides: int, color, cap_color: [3]f32) {
	centre := [3]f32{0, 0, 0}
	for j in 0 ..< sides {
		a0 := math.TAU * f32(j) / f32(sides)
		a1 := math.TAU * f32(j + 1) / f32(sides)
		p0 := [3]f32{math.cos(a0), math.sin(a0), 0}
		p1 := [3]f32{math.cos(a1), math.sin(a1), 0}
		h := [3]f32{0, 0, 0.5}
		tri(b, p0 - h, p1 - h, p1 + h, centre, color)
		tri(b, p0 - h, p1 + h, p0 + h, centre, color)
		tri(b, -h, p0 - h, p1 - h, {0, 0, 1}, cap_color)
		tri(b, h, p0 + h, p1 + h, {0, 0, -1}, cap_color)
	}
}

// Builds the meshes once into the arrays inside World and uploads them. The GL objects live in raylib, which is a
// shared library in debug builds, so they survive a hot reload. Needs the window.
airship_build :: proc(a: ^Airship) {
	b := Mesh_Build {
		verts  = a.verts[:],
		colors = a.colors[:],
	}
	cream := hex(0xf3e9d4)
	navy := hex(0x22406f)
	sage := hex(0x7ea886)
	copper := hex(0xc98a52)
	glass := hex(0xa9e6ea)
	dark := hex(0x2b2f36)

	// Body: chassis, a wedge nose, the cabin with glass all round, roof, sage stripe, mint glow strip under it.
	box(&b, {-2.5, 0.38, -0.95}, {1.7, 1.0, 0.95}, cream)
	{
		// Nose wedge from the body front (x 1.7) down to the bumper (x 2.6).
		c := [3]f32{2.0, 0.6, 0}
		lt, lb := [3]f32{1.7, 1.0, -0.95}, [3]f32{1.7, 0.38, -0.95}
		rt, rb := [3]f32{1.7, 1.0, 0.95}, [3]f32{1.7, 0.38, 0.95}
		nlt, nlb := [3]f32{2.6, 0.72, -0.85}, [3]f32{2.6, 0.38, -0.85}
		nrt, nrb := [3]f32{2.6, 0.72, 0.85}, [3]f32{2.6, 0.38, 0.85}
		tri(&b, lt, rt, nrt, c, cream)
		tri(&b, lt, nrt, nlt, c, cream)
		tri(&b, nlt, nrt, nrb, c, cream)
		tri(&b, nlt, nrb, nlb, c, cream)
		tri(&b, lt, nlt, nlb, c, cream)
		tri(&b, lt, nlb, lb, c, cream)
		tri(&b, rt, nrb, nrt, c, cream)
		tri(&b, rt, rb, nrb, c, cream)
		tri(&b, lb, nlb, nrb, c, dark)
		tri(&b, lb, nrb, rb, c, dark)
	}
	box(&b, {-1.6, 1.0, -0.82}, {0.9, 1.52, 0.82}, glass)
	box(&b, {-1.65, 1.52, -0.86}, {0.7, 1.62, 0.86}, navy)
	box(&b, {-1.2, 1.0, -0.84}, {-1.0, 1.52, 0.84}, navy)
	box(&b, {-2.52, 0.62, -0.97}, {1.72, 0.72, 0.97}, sage)
	box(&b, {-2.2, 0.3, -0.7}, {2.2, 0.38, 0.7}, hex(0x8ff2e8))
	// Lights: white at the front, red at the back, and the nav lights left red, right green on the roof.
	box(&b, {2.58, 0.52, -0.8}, {2.62, 0.66, -0.45}, hex(0xffffff))
	box(&b, {2.58, 0.52, 0.45}, {2.62, 0.66, 0.8}, hex(0xffffff))
	box(&b, {-2.53, 0.78, -0.9}, {-2.5, 0.92, -0.5}, hex(0xff3b3b))
	box(&b, {-2.53, 0.78, 0.5}, {-2.5, 0.92, 0.9}, hex(0xff3b3b))
	box(&b, {0.2, 1.62, -0.86}, {0.5, 1.68, -0.7}, hex(0xff3b3b))
	box(&b, {0.2, 1.62, 0.7}, {0.5, 1.68, 0.86}, hex(0x3bd86b))
	// Arm hinges on the body.
	for arm in CAR_ARMS do box(&b, arm.root - {0.18, 0.1, 0.18}, arm.root + {0.18, 0.1, 0.18}, copper)
	a.body = rl.Mesh {
		vertexCount   = i32(b.count),
		triangleCount = i32(b.count / 3),
		vertices      = cast([^]f32)raw_data(a.verts[:]),
		colors        = cast([^]u8)raw_data(a.colors[:]),
	}

	// Wheel: tyre with a light hub, radius 1, scaled when drawn.
	wb := Mesh_Build {
		verts  = a.wheel_verts[:],
		colors = a.wheel_colors[:],
	}
	cylinder(&wb, 12, dark, hex(0xb8bcc4))
	a.wheel = rl.Mesh {
		vertexCount   = i32(wb.count),
		triangleCount = i32(wb.count / 3),
		vertices      = cast([^]f32)raw_data(a.wheel_verts[:]),
		colors        = cast([^]u8)raw_data(a.wheel_colors[:]),
	}

	// Pod: the arm along +x from its root, the duct ring around the fan at the end (fan axis = y).
	pb := Mesh_Build {
		verts  = a.pod_verts[:],
		colors = a.pod_colors[:],
	}
	box(&pb, {0, -0.06, -0.1}, {CAR_ARM_LEN, 0.06, 0.1}, copper)
	SEGS :: 16
	for j in 0 ..< SEGS {
		a0 := math.TAU * f32(j) / SEGS
		a1 := math.TAU * f32(j + 1) / SEGS
		c := [3]f32{CAR_ARM_LEN, 0, 0}
		for r in ([2]f32{CAR_DUCT_R, CAR_DUCT_R + 0.12}) {
			p0 := c + [3]f32{math.cos(a0) * r, -0.15, math.sin(a0) * r}
			p1 := c + [3]f32{math.cos(a1) * r, -0.15, math.sin(a1) * r}
			q0 := p0 + {0, 0.3, 0}
			q1 := p1 + {0, 0.3, 0}
			inside := r < CAR_DUCT_R + 0.01
			// The inner wall faces the fan, the outer wall faces out.
			mid := (p0 + q1) / 2
			centre := inside ? mid + (mid - c) : c
			tri(&pb, p0, p1, q1, centre, inside ? hex(0x5b6170) : navy)
			tri(&pb, p0, q1, q0, centre, inside ? hex(0x5b6170) : navy)
		}
		top0 := c + [3]f32{math.cos(a0), 0, math.sin(a0)}
		top1 := c + [3]f32{math.cos(a1), 0, math.sin(a1)}
		r0, r1 := f32(CAR_DUCT_R), f32(CAR_DUCT_R + 0.12)
		tri(
			&pb,
			c + (top0 - c) * r0 + {0, 0.15, 0},
			c + (top1 - c) * r0 + {0, 0.15, 0},
			c + (top1 - c) * r1 + {0, 0.15, 0},
			c,
			cream,
		)
		tri(
			&pb,
			c + (top0 - c) * r0 + {0, 0.15, 0},
			c + (top1 - c) * r1 + {0, 0.15, 0},
			c + (top0 - c) * r1 + {0, 0.15, 0},
			c,
			cream,
		)
	}
	box(&pb, {CAR_ARM_LEN - 0.12, -0.1, -0.12}, {CAR_ARM_LEN + 0.12, 0.08, 0.12}, copper)
	a.pod = rl.Mesh {
		vertexCount   = i32(pb.count),
		triangleCount = i32(pb.count / 3),
		vertices      = cast([^]f32)raw_data(a.pod_verts[:]),
		colors        = cast([^]u8)raw_data(a.pod_colors[:]),
	}

	// Fan: two crossed blades in the x-z plane, radius 1, scaled per fan when drawn.
	p := Mesh_Build {
		verts  = a.prop_verts[:],
		colors = a.prop_colors[:],
	}
	blade := hex(0xefe6d2)
	box(&p, {-1, -0.03, -0.1}, {1, 0.03, 0.1}, blade)
	box(&p, {-0.1, -0.03, -1}, {0.1, 0.03, 1}, blade)
	a.prop = rl.Mesh {
		vertexCount   = i32(p.count),
		triangleCount = i32(p.count / 3),
		vertices      = cast([^]f32)raw_data(a.prop_verts[:]),
		colors        = cast([^]u8)raw_data(a.prop_colors[:]),
	}

	rl.UploadMesh(&a.body, false)
	rl.UploadMesh(&a.wheel, false)
	rl.UploadMesh(&a.pod, false)
	rl.UploadMesh(&a.prop, false)
	a.material = rl.LoadMaterialDefault()
	a.ready = true
}

// Eases w.car_anim towards the ship state: fly from the height above the road (landing and take-off show as the
// arms swinging and the wheels tucking), bank from the turn rate, pitch from the climb, the heading without jumps.
car_anim_update :: proc(w: ^World, dt: f32) {
	s := &w.ship
	an := &w.car_anim
	ground := height_at(w, s.pos.x, s.pos.y)
	fly: f32 = 1
	if s.on_road do fly = 0
	else if s.landing || s.lifting do fly = clamp((s.alt - ground) / SHIP_MIN_CLEARANCE, 0, 1)
	if !an.seeded {
		an^ = {
			fly      = fly,
			heading  = s.heading,
			last_alt = s.alt,
			seeded   = true,
		}
	}
	k := 1 - math.exp(-dt * CAR_ANIM_RATE)
	an.fly += (fly - an.fly) * k
	if dt > 0 {
		an.climb_ms += ((s.alt - an.last_alt) / dt - an.climb_ms) * k
	}
	an.last_alt = s.alt
	bank := clamp(s.turn_rate / SHIP_MAX_TURN_RATE, -1, 1) * CAR_BANK * an.fly
	pitch := clamp(an.climb_ms / SHIP_CLIMB_RATE, -1, 1) * CAR_PITCH * an.fly
	an.bank += (bank - an.bank) * k
	an.pitch += (pitch - an.pitch) * k
	an.heading = angle_lerp(an.heading, s.heading, 1 - math.exp(-dt * CAR_HEADING_RATE))
	an.spin += dt * (8 + s.speed * 0.6) * an.fly
	an.time += dt
}

// The car at pos (km) and alt (m), heading: soft shadow on the ground, then the model through an orthographic
// camera that looks at it from the south. One world unit is one pixel, so the model stays px long at every zoom,
// and the camera target is moved so the model lands on its screen position. The altitude shows in a tilted view
// as the gap between the car and its shadow.
car_draw :: proc(w: ^World, pos: [2]f32, alt, heading: f32, an: Car_Anim, px: f32, tint: rl.Color) {
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
		rl.DrawEllipse(i32(pg.x), i32(pg.y), px * 0.5 * g, px * 0.2 * g, {0, 0, 0, u8(40 * f)})
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
	yaw := math.PI / 2 - (heading - w.cam.pose.yaw)
	bob := math.sin(an.time * 2.2) * CAR_BOB_M * an.fly
	m := linalg.matrix4_scale_f32({scale, scale, scale})
	m = m * linalg.matrix4_rotate_f32(yaw, {0, 1, 0})
	m = m * linalg.matrix4_translate_f32({0, bob, 0})
	m = m * linalg.matrix4_rotate_f32(-an.bank, {1, 0, 0})
	m = m * linalg.matrix4_rotate_f32(an.pitch, {0, 0, 1})
	mat := a.material
	mat.maps[0].color = tint
	rl.BeginMode3D(cam3)
	rl.DrawMesh(a.body, mat, rl.Matrix(m))
	// Wheels tuck up and in as the car flies.
	wheels := CAR_WHEELS
	for wp in wheels {
		tuck := [3]f32{0, 0.25 * an.fly, -math.sign(wp.z) * 0.25 * an.fly}
		r := CAR_WHEEL_R * (1 - 0.25 * an.fly)
		wm := m * linalg.matrix4_translate_f32(wp + tuck) * linalg.matrix4_scale_f32({r, r, 0.26})
		rl.DrawMesh(a.wheel, mat, rl.Matrix(wm))
	}
	// Arms swing from folded to open, the fans spin while flying.
	arms := CAR_ARMS
	for arm in arms {
		ang := arm.folded + (arm.open - arm.folded) * an.fly
		pm := m * linalg.matrix4_translate_f32(arm.root) * linalg.matrix4_rotate_f32(ang, {0, 1, 0})
		rl.DrawMesh(a.pod, mat, rl.Matrix(pm))
		fm :=
			pm *
			linalg.matrix4_translate_f32({CAR_ARM_LEN, 0, 0}) *
			linalg.matrix4_rotate_f32(an.spin, {0, 1, 0})
		fm = fm * linalg.matrix4_scale_f32({CAR_DUCT_R - 0.05, 1, CAR_DUCT_R - 0.05})
		rl.DrawMesh(a.prop, mat, rl.Matrix(fm))
	}
	rl.EndMode3D()
}

// The player's car (navigation screen).
airship_draw :: proc(w: ^World) {
	car_anim_update(w, min(rl.GetFrameTime(), MAX_FRAME_DT))
	an := w.car_anim
	car_draw(w, w.ship.pos, w.ship.alt, an.heading, an, CAR_PX, rl.WHITE)
}
