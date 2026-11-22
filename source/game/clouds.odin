package game

import "core:math"
import "core:math/linalg"
import "core:slice"
import rl "vendor:raylib"

// Clouds over the map (Lars, 2026-11-21: "natuur/wolken"). The forecast cloud cover (cloud_at, 0 clear ..
// 1 overcast) decides how many of the puff spots carry a cloud: every CLOUD_CELL_KM cell has one spot, placed,
// sized and lifted by a hash of the cell, and it is cloudy when its hash is below the cover there. The spots
// drift with the wind of the top layer. A cloud is a few soft sprites drawn in screen space at their projected
// size, far ones first, with its shadow on the ground under it. They fade in while the camera zooms in and fade
// out when the camera gets close to one, so the map and the car stay readable. Our values, not from the spec.
CLOUD_CELL_KM :: 1.6
CLOUD_BASE_M :: 650.0
CLOUD_TOP_M :: 1100.0
CLOUD_SIZE_KM :: [2]f32{0.35, 0.8} // radius of one puff, smallest .. biggest
CLOUD_PUFFS :: 8
// Clouds clump: value noise over the map (two octaves, CLOUD_NOISE_KM wide) decides where the cover goes.
CLOUD_NOISE_KM :: 7.0
CLOUD_MAX :: 900
CLOUD_ZOOM_0 :: 2.0
CLOUD_ZOOM_1 :: 3.5
CLOUD_TEX :: 128
CLOUD_OPACITY :: 0.92
CLOUD_SHADOW_ALPHA :: 34 // of 255

Cloud_Sprites :: struct {
	puff:  rl.Texture2D, // soft white disc
	ready: bool,
}

Cloud :: struct {
	pos:   [3]f32, // km, km, m
	size:  f32, // km
	seed:  u32,
	depth: f32, // distance to the camera, for the draw order
	alpha: f32,
}

hash_u32 :: proc(x: u32) -> u32 {
	h := x
	h ~= h >> 16
	h *= 0x7feb352d
	h ~= h >> 15
	h *= 0x846ca68b
	h ~= h >> 16
	return h
}

// 0 .. 1 from a cell and a salt.
cloud_rand :: proc(cx, cy: i32, salt: u32) -> f32 {
	return f32(hash_u32(u32(cx) * 73856093 ~ u32(cy) * 19349663 ~ salt * 83492791) >> 8) / f32(1 << 24)
}

// Smooth value noise 0 .. 1 at p (km), two octaves.
cloud_noise :: proc(p: [2]f32) -> f32 {
	octave :: proc(p: [2]f32, salt: u32) -> f32 {
		f := linalg.floor(p)
		t := p - f
		t = t * t * (3 - 2 * t)
		x, y := i32(f.x), i32(f.y)
		a := math.lerp(cloud_rand(x, y, salt), cloud_rand(x + 1, y, salt), t.x)
		b := math.lerp(cloud_rand(x, y + 1, salt), cloud_rand(x + 1, y + 1, salt), t.x)
		return math.lerp(a, b, t.y)
	}
	return octave(p / CLOUD_NOISE_KM, 11) * 0.65 + octave(p / (CLOUD_NOISE_KM * 0.4), 12) * 0.35
}

clouds_build :: proc(w: ^World) {
	prof_zone(w, .Clouds_Build)
	s := &w.cloud_sprites
	if s.ready do return
	// White with a soft round falloff, (1 - r^2)^2: no visible edge where puffs overlap.
	pixels := make([][4]u8, CLOUD_TEX * CLOUD_TEX, context.temp_allocator)
	for y in 0 ..< CLOUD_TEX {
		for x in 0 ..< CLOUD_TEX {
			d := ([2]f32{f32(x), f32(y)} + 0.5) / (CLOUD_TEX / 2) - 1
			a := max(1 - (d.x * d.x + d.y * d.y), 0)
			pixels[y * CLOUD_TEX + x] = {255, 255, 255, u8(a * a * 255)}
		}
	}
	img := rl.Image {
		data    = raw_data(pixels),
		width   = CLOUD_TEX,
		height  = CLOUD_TEX,
		mipmaps = 1,
		format  = .UNCOMPRESSED_R8G8B8A8,
	}
	s.puff = rl.LoadTextureFromImage(img)
	rl.SetTextureFilter(s.puff, .BILINEAR)
	s.ready = true
}

clouds_unload :: proc(s: ^Cloud_Sprites) {
	if !s.ready do return
	rl.UnloadTexture(s.puff)
	s^ = {}
}

// Screen radius in pixels of a sphere of radius r km at pos (km, km, m), from the camera's right direction.
cloud_px :: proc(w: ^World, pos: [3]f32, r: f32) -> (centre: [2]f32, radius: f32, ok: bool) {
	c := &w.cam
	fwd := linalg.normalize(c.view.target - c.view.position)
	right := linalg.normalize(linalg.cross(fwd, c.view.up))
	centre, ok = cam_to_screen(w, pos)
	if !ok do return
	edge, edge_ok := cam_to_screen(w, pos + [3]f32{right.x * r, right.y * r, -right.z * r * 1000})
	if !edge_ok {
		ok = false
		return
	}
	radius = linalg.length(edge - centre)
	return
}

// Screen space, after the routes and the car (the clouds fly above both). The values the cloud editor changes
// (cloud_edit.odin) come from w.cloud_edit, whose defaults are the constants above. Only the picture: cloud_at
// and the solar energy stay the forecast.
clouds_draw :: proc(w: ^World) {
	prof_zone(w, .Clouds_Draw)
	s := &w.cloud_sprites
	e := &w.cloud_edit
	if !s.ready || !e.show do return
	fade := clamp((w.cam.pose.zoom - e.zoom_0) / max(e.zoom_1 - e.zoom_0, 1e-3), 0, 1)
	if fade <= 0 do return
	hour := sim_hour(w)
	t := f32(w.tick) / SIM_HZ
	target := w.cam.view.target.xy
	drift := wind_at(w, target.x, target.y, WIND_LAYERS - 1, hour) * t / 1000 * e.drift
	cell_km := e.cell_km
	view_km := w.cam.screen.x / max(w.cam.px_per_km, 1e-3)
	reach := clamp(view_km * 0.9, 4, 24)
	screen := w.cam.screen
	cam_pos := w.cam.view.position

	clouds := make([dynamic]Cloud, 0, CLOUD_MAX, context.temp_allocator)
	lo := linalg.floor((target - drift - reach) / cell_km)
	hi := linalg.floor((target - drift + reach) / cell_km)
	for cy := i32(lo.y); cy <= i32(hi.y); cy += 1 {
		for cx := i32(lo.x); cx <= i32(hi.x); cx += 1 {
			if len(clouds) == CLOUD_MAX do break
			p :=
				([2]f32{f32(cx), f32(cy)} + {cloud_rand(cx, cy, 1), cloud_rand(cx, cy, 2)}) * cell_km + drift
			edge := belgium_fade(w, p.x, p.y)
			if edge <= 0 do continue
			cover := clamp(cloud_at(w, p.x, p.y, hour) * e.cover, 0, 1)
			// Noise stretched to 0 .. 1, so a cover of 0.3 clouds about 30 % of the spots. A clear forecast still
			// keeps a few thin ones (10 %), the sky is never empty.
			n :=
				clamp((cloud_noise(p - drift) - 0.5) * 2.2 + 0.5, 0, 1) * 0.85 + 0.15 * cloud_rand(cx, cy, 3)
			if n >= 0.1 + 0.9 * cover do continue
			sizes := CLOUD_SIZE_KM
			size := math.lerp(sizes.x, sizes.y, cloud_rand(cx, cy, 4)) * (0.6 + 0.6 * cover) * e.size
			alt := math.lerp(e.base_m, max(e.top_m, e.base_m), cloud_rand(cx, cy, 5))
			world := [3]f32{p.x, p.y, -alt / 1000}
			append(
				&clouds,
				Cloud {
					pos = {p.x, p.y, alt},
					size = size,
					seed = hash_u32(u32(cx) * 31 + u32(cy) * 7919),
					depth = linalg.length(world - cam_pos),
					alpha = fade * edge * (1 - view_fog(w, view_depth(w, world))),
				},
			)
		}
	}
	slice.sort_by(clouds[:], proc(a, b: Cloud) -> bool {return a.depth > b.depth})

	shadow_c := rl.Color{0, 0, 0, u8(clamp(e.shadow, 0, 255))}
	src := rl.Rectangle{0, 0, CLOUD_TEX, CLOUD_TEX}
	// Shadows first: all on the ground, under every cloud.
	for c in clouds {
		centre, r, ok := cloud_px(w, {c.pos.x, c.pos.y, 0}, c.size * 1.6)
		if !ok || r < 1 do continue
		col := shadow_c
		col.a = u8(f32(col.a) * c.alpha)
		rl.DrawTexturePro(s.puff, src, {centre.x - r, centre.y - r * 0.7, 2 * r, 1.4 * r}, {}, 0, col)
	}
	lit := rl.Color{255, 255, 255, 255}
	shade := rl.Color{226, 231, 240, 255}
	for c in clouds {
		centre, r, ok := cloud_px(w, c.pos, c.size)
		if !ok || r < 1.5 do continue
		// Close to the camera (bigger than half the screen) the cloud fades away, the view goes through it.
		a := c.alpha * (1 - clamp((r - screen.y * 0.35) / (screen.y * 0.25), 0, 1))
		if a <= 0.01 do continue
		// A flat, shaded base of wide puffs, then rounder lit puffs heaped on top (up on the screen).
		for k in 0 ..< CLOUD_PUFFS {
			h := hash_u32(c.seed + u32(k) * 977)
			r0, r1, r2 := f32(h & 0xff) / 255, f32((h >> 8) & 0xff) / 255, f32((h >> 16) & 0xff) / 255
			base := k < 3
			ox := (r0 - 0.5) * (base ? 1.8 : 1.2)
			oy := base ? 0.15 + 0.1 * r1 : -0.1 - 0.45 * r1
			pr := r * (base ? 0.7 + 0.3 * r2 : 0.55 + 0.4 * r2)
			col := base ? shade : lit
			col.a = u8(255 * a * clamp(e.opacity, 0, 1))
			p := centre + [2]f32{ox, oy} * r
			sq: f32 = base ? 0.6 : 0.9 // base puffs are flat
			rl.DrawTexturePro(
				s.puff,
				src,
				{p.x - pr * 1.2, p.y - pr * sq, 2.4 * pr, 2 * pr * sq},
				{},
				0,
				col,
			)
		}
	}
}
