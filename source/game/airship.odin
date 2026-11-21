// author: dario
package game

import "core:math"
import "core:math/linalg"
import rl "vendor:raylib"

// Model space: metres, x forward (nose is +x), y up, z to the right, origin in the middle of the envelope.
// Sizes and colors are the ones in docs/drift-design.pdf ("Het luchtschip").
AIRSHIP_LEN :: 45.0
AIRSHIP_RADIUS :: 8.5
AIRSHIP_WIDEST :: 0.4 // fraction of the length from the nose
AIRSHIP_DECK_Y :: -21.0
AIRSHIP_PX :: 80.0 // on-screen length of the envelope on the flat map
AIRSHIP_TILT :: 0.7 // radians from straight down, so the gondola shows under the envelope
AIRSHIP_BANK :: 0.25 // roll in radians at the maximum turn rate
AIRSHIP_MAX_VERTS :: 4096
AIRSHIP_PROP_VERTS :: 128

Airship :: struct {
	verts:       [AIRSHIP_MAX_VERTS][3]f32,
	colors:      [AIRSHIP_MAX_VERTS][4]u8,
	prop_verts:  [AIRSHIP_PROP_VERTS][3]f32,
	prop_colors: [AIRSHIP_PROP_VERTS][4]u8,
	body:        rl.Mesh,
	prop:        rl.Mesh,
	material:    rl.Material,
	ready:       bool,
}

// Propeller positions (model space) and radius in metres: two on outriggers, one at the tail.
AIRSHIP_PROPS :: [3]struct {
	pos:    [3]f32,
	radius: f32,
} {
	{{2, -22, -8.5}, 2.6},
	{{2, -22, 8.5}, 2.6},
	{{-12.5, -22.6, 0}, 3.2},
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

envelope_radius :: proc(t: f32) -> f32 {
	// t = 0 at the nose, 1 at the tail. Round ellipse up to the widest point, then a taper to the tail.
	if t < AIRSHIP_WIDEST {
		u := (AIRSHIP_WIDEST - t) / AIRSHIP_WIDEST
		return AIRSHIP_RADIUS * math.sqrt(1 - u * u)
	}
	u := (t - AIRSHIP_WIDEST) / (1 - AIRSHIP_WIDEST)
	return max(AIRSHIP_RADIUS * math.pow(1 - u, 0.8), 0.5)
}

// Builds both meshes once into the arrays inside World and uploads them. The GL objects live in raylib,
// which is a shared library in debug builds, so they survive a hot reload. Needs the window.
airship_build :: proc(a: ^Airship) {
	b := Mesh_Build {
		verts  = a.verts[:],
		colors = a.colors[:],
	}

	cream := [2][3]f32{hex(0xf3e9d4), hex(0xefe4cc)}
	navy := [2][3]f32{hex(0x22406f), hex(0x2a4d82)}
	sage := hex(0x7ea886)
	RINGS :: 16
	SIDES :: 12
	for i in 0 ..< RINGS {
		t0 := f32(i) / RINGS
		t1 := f32(i + 1) / RINGS
		x0 := AIRSHIP_LEN * (AIRSHIP_WIDEST - t0)
		x1 := AIRSHIP_LEN * (AIRSHIP_WIDEST - t1)
		r0 := envelope_radius(t0)
		r1 := envelope_radius(t1)
		for j in 0 ..< SIDES {
			a0 := math.TAU * f32(j) / SIDES
			a1 := math.TAU * f32(j + 1) / SIDES
			p00 := [3]f32{x0, r0 * math.cos(a0), r0 * math.sin(a0)}
			p01 := [3]f32{x0, r0 * math.cos(a1), r0 * math.sin(a1)}
			p10 := [3]f32{x1, r1 * math.cos(a0), r1 * math.sin(a0)}
			p11 := [3]f32{x1, r1 * math.cos(a1), r1 * math.sin(a1)}
			color := cream[j & 1]
			top := math.cos((a0 + a1) / 2) > 0.3
			if top && t0 >= 0.17 && t1 <= 0.86 do color = navy[(i + j) & 1]
			if i == 6 || i == 11 do color = sage
			axis := [3]f32{(x0 + x1) / 2, 0, 0}
			tri(&b, p00, p01, p11, axis, color)
			tri(&b, p00, p11, p10, axis, color)
		}
	}

	// Four tail fins in an X, sage with a terracotta trailing edge.
	for k in 0 ..< 4 {
		ang := math.PI / 4 + f32(k) * math.PI / 2
		dir := [3]f32{0, math.cos(ang), math.sin(ang)}
		root0 := [3]f32{-16, 0, 0} + dir * envelope_radius(0.72) * 0.9
		root1 := [3]f32{-25, 0, 0} + dir * envelope_radius(0.95) * 0.9
		quad_flat(&b, root0, root1, root1 + dir * 4 + [3]f32{-2, 0, 0}, root0 + dir * 8, sage)
		quad_flat(
			&b,
			root1 + dir * 4 + [3]f32{-2, 0, 0},
			root1,
			root1 + [3]f32{-2.4, 0, 0},
			root1 + dir * 4 + [3]f32{-4.4, 0, 0},
			hex(0xd9825b),
		)
	}

	// Gondola: hull, keel, deck, cabin with windows, roof garden, bow planter, tree.
	wood := hex(0xc2834c)
	box(&b, {-11.5, AIRSHIP_DECK_Y - 3.2, -3.5}, {11.5, AIRSHIP_DECK_Y, 3.5}, wood)
	box(&b, {-10, AIRSHIP_DECK_Y - 3.8, -0.8}, {10, AIRSHIP_DECK_Y - 3.2, 0.8}, hex(0x8b5b3b))
	box(&b, {-11.6, AIRSHIP_DECK_Y - 1.9, -3.55}, {11.6, AIRSHIP_DECK_Y - 1.3, 3.55}, sage)
	box(&b, {-11.5, AIRSHIP_DECK_Y, -3.5}, {11.5, AIRSHIP_DECK_Y + 0.2, 3.5}, hex(0xe4cba0))
	box(&b, {-9, AIRSHIP_DECK_Y + 0.2, -2.8}, {2, AIRSHIP_DECK_Y + 2.8, 2.8}, hex(0xf4ecd9))
	box(&b, {-8, AIRSHIP_DECK_Y + 1, -2.85}, {1, AIRSHIP_DECK_Y + 2.1, 2.85}, hex(0xa9e6ea))
	box(&b, {-8.5, AIRSHIP_DECK_Y + 2.8, -2}, {1.5, AIRSHIP_DECK_Y + 3.4, 2}, hex(0x5f9a63))
	box(&b, {-3, AIRSHIP_DECK_Y + 3.4, 0.4}, {-2, AIRSHIP_DECK_Y + 4.1, 1.2}, hex(0xe58fb0))
	box(&b, {7, AIRSHIP_DECK_Y + 0.2, -1.2}, {10, AIRSHIP_DECK_Y + 1.1, 1.2}, hex(0xf2c230))
	box(&b, {-10.7, AIRSHIP_DECK_Y + 0.2, -0.5}, {-9.7, AIRSHIP_DECK_Y + 2.6, 0.5}, hex(0x4f8a4f))

	// Wooden beam under the envelope and six thin cables down to the deck.
	box(&b, {-6, -9.4, -0.6}, {6, -8.5, 0.6}, hex(0xb98a5a))
	for cx in ([3]f32{-5, 0, 5}) {
		for cz in ([2]f32{-0.5, 0.5}) {
			box(&b, {cx - 0.1, AIRSHIP_DECK_Y, cz - 0.1}, {cx + 0.1, -9.4, cz + 0.1}, hex(0xe9e2d2))
		}
	}

	// Outriggers and motor pods (copper), nav lights (red left, green right, white at the back), glow strips.
	box(&b, {1, -22.4, -8.5}, {3, -21.6, -3.5}, hex(0xc98a52))
	box(&b, {1, -22.4, 3.5}, {3, -21.6, 8.5}, hex(0xc98a52))
	for z in ([2]f32{-8.5, 8.5}) do box(&b, {0.5, -22.8, z - 0.7}, {3.5, -21.2, z + 0.7}, hex(0xc98a52))
	box(&b, {-13.5, -23.3, -0.7}, {-11.5, -21.9, 0.7}, hex(0xc98a52))
	box(&b, {0.5, -22.2, -3.8}, {1.5, -21.6, -3.5}, hex(0xff3b3b))
	box(&b, {0.5, -22.2, 3.5}, {1.5, -21.6, 3.8}, hex(0x3bd86b))
	box(&b, {-11.8, -22.2, -0.3}, {-11.5, -21.6, 0.3}, hex(0xffffff))
	for z in ([2]f32{-1.7, 1.1}) {
		box(&b, {-8, AIRSHIP_DECK_Y - 3.9, z}, {8, AIRSHIP_DECK_Y - 3.8, z + 0.6}, hex(0x8ff2e8))
	}

	a.body = rl.Mesh {
		vertexCount   = i32(b.count),
		triangleCount = i32(b.count / 3),
		vertices      = cast([^]f32)raw_data(a.verts[:]),
		colors        = cast([^]u8)raw_data(a.colors[:]),
	}

	// Propeller: two crossed blades in the y-z plane, radius 1, scaled per prop when drawn.
	p := Mesh_Build {
		verts  = a.prop_verts[:],
		colors = a.prop_colors[:],
	}
	blade := hex(0xefe6d2)
	box(&p, {-0.1, -1, -0.12}, {0.1, 1, 0.12}, blade)
	box(&p, {-0.1, -0.12, -1}, {0.1, 0.12, 1}, blade)
	a.prop = rl.Mesh {
		vertexCount   = i32(p.count),
		triangleCount = i32(p.count / 3),
		vertices      = cast([^]f32)raw_data(a.prop_verts[:]),
		colors        = cast([^]u8)raw_data(a.prop_colors[:]),
	}

	rl.UploadMesh(&a.body, false)
	rl.UploadMesh(&a.prop, false)
	a.material = rl.LoadMaterialDefault()
	a.ready = true
}

// The airship in 2D map mode: a soft shadow on the ground, then the model through an orthographic camera that
// looks at the ship from the south. One world unit is one pixel, so the model stays AIRSHIP_PX long at every
// zoom, and the camera target is moved so the model lands on the ship's screen position.
airship_draw :: proc(w: ^World, cam: rl.Camera2D) {
	a := &w.airship
	if !a.ready do return
	s := w.ship
	p := rl.GetWorldToScreen2D(s.pos, cam)
	d := p - {f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())} / 2
	scale := f32(AIRSHIP_PX / AIRSHIP_LEN)

	for k in 0 ..< 3 {
		f := 1 - f32(k) * 0.25
		rl.DrawEllipse(i32(p.x) + 4, i32(p.y) + 16, AIRSHIP_PX * 0.5 * f, AIRSHIP_PX * 0.15 * f, {0, 0, 0, 28})
	}

	sin_t := math.sin(f32(AIRSHIP_TILT))
	cos_t := math.cos(f32(AIRSHIP_TILT))
	target := [3]f32{-d.x, d.y * sin_t, -d.y * cos_t}
	cam3 := rl.Camera3D {
		position   = target + {0, 1000 * cos_t, 1000 * sin_t},
		target     = target,
		up         = {0, 0, -1},
		fovy       = f32(rl.GetScreenHeight()),
		projection = .ORTHOGRAPHIC,
	}
	bank := clamp(s.turn_rate / SHIP_MAX_TURN_RATE, -1, 1) * AIRSHIP_BANK
	yaw := math.PI / 2 - s.heading
	m := linalg.matrix4_scale_f32({scale, scale, scale})
	m = m * linalg.matrix4_rotate_f32(yaw, {0, 1, 0})
	m = m * linalg.matrix4_rotate_f32(bank, {1, 0, 0})
	m = m * linalg.matrix4_translate_f32({0, 10, 0})
	rl.BeginMode3D(cam3)
	rl.DrawMesh(a.body, a.material, rl.Matrix(m))
	spin := f32(w.tick) * (0.15 + s.speed * 0.02)
	for pr in AIRSHIP_PROPS {
		pm := m * linalg.matrix4_translate_f32(pr.pos) * linalg.matrix4_rotate_f32(spin, {1, 0, 0})
		pm = pm * linalg.matrix4_scale_f32({pr.radius, pr.radius, pr.radius})
		rl.DrawMesh(a.prop, a.material, rl.Matrix(pm))
	}
	rl.EndMode3D()
}
