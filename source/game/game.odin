// author: nasr
package game

import "core:crypto/ed25519"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:mem/virtual"
import "core:strings"
import curl "vendor:curl"
import rl "vendor:raylib"

SIM_HZ :: 60
SIM_DT :: 1.0 / SIM_HZ
MAX_FRAME_DT :: 0.25
// Keys 1..4. More simulated time per frame means more fixed steps, dt stays SIM_DT.
SIM_SPEEDS :: [4]f64{1, 5, 15, 40}

// Camera: zoom is log2 relative to the fitted view, so zero is the whole map.
ZOOM_MIN :: -1
ZOOM_MAX :: 7
WHEEL_ZOOM_STEP :: 0.25
ZOOM_PER_S :: 2
PAN_PX_PER_S :: 600

// UI font: Roboto Regular v3.016 (OFL 1.1, assets/fonts/OFL.txt), rasterized once at the size it is drawn,
// so text stays pixel sharp. Codepoints 32..255 cover ASCII and Latin-1 (Liege with e grave, the copyright sign).
FONT_DATA :: #load("../../assets/fonts/Roboto-Regular.ttf")
FONT_PX :: 14
FONT_FIRST :: 32
FONT_COUNT :: 256 - FONT_FIRST

View :: struct {
	pan:  [2]f32, // km from the map centre to the screen centre
	zoom: f32,
}

// Set by compile.sh with -define: debug builds get DRIFT_DEBUG, profile builds DRIFT_PROFILE, release neither.
DRIFT_DEBUG :: #config(DRIFT_DEBUG, false)
DRIFT_PROFILE :: #config(DRIFT_PROFILE, false)
BUILD_MODE :: "debug" when DRIFT_DEBUG else "profile" when DRIFT_PROFILE else "release"

World :: struct {
	perm:         virtual.Arena,
	route_mem:    virtual.Arena,
	frame:        virtual.Arena,
	m:            Map,
	weather:      Weather,
	// sha256 of weather, identifies the snapshot (carpool offers will carry it)
	weather_hash: [32]u8,
	fetch:        Fetch,
	identity:     ed25519.Private_Key, // zero until identity_load_or_create succeeds
	identity_pub: [32]u8,
	store:        Store, // carpool messages, see net.odin
	node:         Net_Node, // peer to peer threads and peers, see net.odin
	trip:         Trip, // the accepted trip in progress, frame loop only
	grid:         Grid,
	controls:     Controls,
	ship:         Ship,
	drive_mode:   bool, // zero = map mode: Controls move the camera. Drive mode: Controls steer the ship
	replay:       Replay,
	no_fly:       [MAX_NO_FLY]No_Fly_Zone,
	tick:         u64,
	accum:        f64,
	sim_speed:    int, // index into SIM_SPEEDS, 0 = 1x
	prof:         Profiler,
	view:         View,
	// GPU texture and glyph tables owned by raylib, zero until the first frame with a window.
	font:         rl.Font,
	line_meshes:  Line_Meshes,
	theme:        Theme, // zero = night (the design default), T toggles
	palette:      Palette, // PALETTES[theme], copied every frame, read through palette(w)
	wind:         Wind_Particles,
}

@(export)
game_memory_size :: proc() -> int {
	return size_of(World)
}

@(export)
game_init_window :: proc() {
	rl.InitWindow(800, 450, "drift")
	rl.SetTargetFPS(60)
}

@(export)
game_init :: proc() -> rawptr {
	w, err := virtual.arena_growing_bootstrap_new(World, "perm")
	if err != nil {
		fmt.eprintln("[game] cannot allocate World:", err)
		return nil
	}
	if res := curl.global_init(curl.GLOBAL_ALL); res != .E_OK {
		fmt.eprintln("[weather] curl global_init failed:", curl.easy_strerror(res))
	}
	game_hot_reloaded(w)

	// The ship starts on top of the Brussels tower. Looked up by name: hub ids follow the bake order.
	START_HUB :: "Bruxelles - Brussel"
	start_found := false
	for &h in w.m.hubs[:w.m.hub_count] {
		if strings.truncate_to_byte(string(h.name[:]), 0) != START_HUB do continue
		w.ship.pos = h.pos
		w.ship.alt = height_at(w, h.pos.x, h.pos.y) + HUB_TOWER_M
		start_found = true
		break
	}
	if !start_found do logf(w, "ship", "no hub named %q in belgium.bin, the ship starts at the map corner", START_HUB)

	weather_load_snapshot(w, SNAPSHOT_PATH)
	identity_load_or_create(w)
	w.replay.steps = make([]Control_Step, REPLAY_MAX_STEPS, virtual.arena_allocator(&w.perm))
	logf(w, "game", "build %s", BUILD_MODE)
	logf(
		w,
		"map",
		"%d lines, %d points, %d cities, %d hubs",
		len(w.m.lines),
		len(w.m.points),
		len(w.m.cities),
		w.m.hub_count,
	)
	return w
}

// The map slices point into this library's #load data, so they are re-pointed after every reload.
@(export)
game_hot_reloaded :: proc(memory: rawptr) {
	w := (^World)(memory)
	m, ok := load_map()
	if !ok {
		logf(
			w,
			"map",
			"belgium.bin: wrong magic or version (want %d) or more than %d hubs",
			MAP_VERSION,
			MAX_HUBS,
		)
	}
	w.m = m
	w.grid.terrain_built = false
	// The new library may change the shaders, so the mesh is rebuilt on the next frame.
	line_meshes_unload(&w.line_meshes)
}

@(export)
game_update :: proc(memory: rawptr) -> bool {
	w := (^World)(memory)
	context.allocator = virtual.arena_allocator(&w.perm)
	context.temp_allocator = virtual.arena_allocator(&w.frame)
	defer virtual.arena_free_all(&w.frame)

	if w.font.texture.id == 0 {
		codepoints: [FONT_COUNT]rune
		for &c, i in codepoints do c = rune(FONT_FIRST + i)
		w.font = rl.LoadFontFromMemory(
			".ttf",
			raw_data(FONT_DATA),
			i32(len(FONT_DATA)),
			FONT_PX,
			raw_data(codepoints[:]),
			FONT_COUNT,
		)
		if w.font.texture.id == 0 {
			logf(w, "ui", "cannot load Roboto (%d bytes embedded), using the raylib font", len(FONT_DATA))
			w.font = rl.GetFontDefault()
		}
	}

	t := prof_begin()
	weather_poll(w)
	node_poll(w)
	w.controls = read_controls()

	if rl.IsKeyPressed(.M) do w.drive_mode = !w.drive_mode
	if rl.IsKeyPressed(.T) do w.theme = w.theme == .Night ? .Day : .Night
	for key, i in ([?]rl.KeyboardKey{.ONE, .TWO, .THREE, .FOUR}) {
		if rl.IsKeyPressed(key) do w.sim_speed = i
	}
	speeds := SIM_SPEEDS
	w.accum += min(f64(rl.GetFrameTime()), MAX_FRAME_DT) * speeds[w.sim_speed]
	for w.accum >= SIM_DT {
		if w.drive_mode {
			step := controls_pack(w.controls)
			if w.replay.count < len(w.replay.steps) {
				w.replay.steps[w.replay.count] = step
				w.replay.count += 1
			}
			ship_step(w, controls_unpack(step), SIM_DT)
		}
		w.tick += 1
		w.accum -= SIM_DT
	}
	prof_end(w, .Update, t)

	if rl.IsKeyPressed(.F5) {
		b := strings.builder_make(context.temp_allocator)
		dump_world(w, &b)
		fmt.print(strings.to_string(b))
	}

	// km -> px: Camera2D zoom is px per km, w.view.pan is where the screen centre looks.
	// Map mode: the ship controls move the camera, so keyboard and gamepad work the same way as when flying.
	// Throttle / turn pan, climb zooms around the screen centre. The mouse stays camera only: drag pans, the
	// wheel zooms keeping the point under the cursor in place.
	// Drive mode (M toggles): the controls go to the ship and the camera sits on it, only the wheel zooms.
	// The toolbar is drawn after the map, but laid out here so the mouse does not pan or zoom the map under it.
	toolbar := rl.Rectangle{f32(rl.GetScreenWidth()) - TOOLBAR_W - 8, 8, TOOLBAR_W, TOOLBAR_H}
	mouse_on_ui := rl.CheckCollisionPointRec(rl.GetMousePosition(), toolbar)

	cam: rl.Camera2D
	{
		v := &w.view
		c := w.controls
		if w.drive_mode do c = {}
		dt := rl.GetFrameTime()
		centre := [2]f32{f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())} / 2
		fit := 0.95 * min(centre.x * 2 / MAP_W_KM, centre.y * 2 / MAP_H_KM)
		z0 := fit * math.pow(f32(2), v.zoom)

		v.pan += [2]f32{c.turn, -c.throttle} * PAN_PX_PER_S * dt / z0
		if rl.IsMouseButtonDown(.LEFT) && !w.drive_mode && !mouse_on_ui do v.pan -= rl.GetMouseDelta() / z0
		zoom := c.climb * ZOOM_PER_S * dt
		anchor := centre
		if wheel := rl.GetMouseWheelMove(); wheel != 0 && !mouse_on_ui {
			zoom += wheel * WHEEL_ZOOM_STEP
			anchor = rl.GetMousePosition()
		}
		v.zoom = clamp(v.zoom + zoom, ZOOM_MIN, ZOOM_MAX)
		z1 := fit * math.pow(f32(2), v.zoom)
		v.pan += (anchor - centre) * (1 / z0 - 1 / z1)
		half := [2]f32{MAP_W_KM, MAP_H_KM} / 2
		if w.drive_mode do v.pan = w.ship.pos - half
		v.pan = linalg.clamp(v.pan, -half, half)

		cam = {
			offset = centre,
			target = half + v.pan,
			zoom   = z1,
		}
	}

	palettes := PALETTES
	w.palette = palettes[w.theme]
	pal := palette(w)

	rl.BeginDrawing()
	t = prof_begin()
	rl.ClearBackground(pal.background)
	{
		lm := &w.line_meshes
		if !lm.built {
			segments := 0
			for l in w.m.lines do segments += max(int(l.count) - 1, 0)
			n := segments * 6
			pos := make([][3]f32, n, context.temp_allocator)
			other := make([][3]f32, n, context.temp_allocator)
			color := make([][4]u8, n, context.temp_allocator)
			i := 0
			for l in w.m.lines {
				pts := w.m.points[l.start:][:l.count]
				for s in 1 ..< len(pts) {
					line_quad(pos, other, color, i, pts[s - 1], pts[s], {u8(l.kind), 0, 0, 255})
					i += 6
				}
			}
			if n > 0 do lm.map_lines = line_mesh_upload(pos, other, color, false)
			lm.wind = line_mesh_upload(
				make([][3]f32, WIND_VERTICES, context.temp_allocator),
				make([][3]f32, WIND_VERTICES, context.temp_allocator),
				make([][4]u8, WIND_VERTICES, context.temp_allocator),
				true,
			)
			shader := rl.LoadShaderFromMemory(LINE_VS, LINE_FS)
			if !rl.IsShaderValid(shader) do logf(w, "render", "line shader did not compile, map and wind are not drawn")
			lm.material = rl.LoadMaterialDefault()
			lm.material.shader = shader
			lm.loc_screen = rl.GetShaderLocation(shader, "screen")
			lm.loc_colors = rl.GetShaderLocation(shader, "colors")
			lm.built = true
			logf(
				w,
				"render",
				"map mesh: %d segments, %d vertices, %.1f MB on the GPU",
				segments,
				n,
				f32(n * (size_of([3]f32) * 2 + size_of([4]u8))) / (1 << 20),
			)
		}

		// Wind particles: layer 0 (the lowest, until the layer toggles), forecast hour of the simulated time.
		// Update loop over the SoA arrays, then one pass writes the trails into the wind mesh.
		{
			wp := &w.wind
			dt := min(rl.GetFrameTime(), MAX_FRAME_DT)
			lo := rl.GetScreenToWorld2D({0, 0}, cam)
			hi := rl.GetScreenToWorld2D({f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())}, cam)
			hour := int(w.tick / (SIM_HZ * 3600))
			km_per_ms := WIND_PX_PER_MS / cam.zoom
			for i in 0 ..< WIND_PARTICLES {
				wp.age[i] += dt
				out := wp.x[i] < lo.x || wp.x[i] > hi.x || wp.y[i] < lo.y || wp.y[i] > hi.y
				if !wp.seeded || out || wp.age[i] >= WIND_LIFE_S {
					wp.x[i] = lo.x + wind_rand(wp) * (hi.x - lo.x)
					wp.y[i] = lo.y + wind_rand(wp) * (hi.y - lo.y)
					wp.age[i] = wp.seeded ? 0 : wind_rand(wp) * WIND_LIFE_S
				}
				v := wind_at(w, wp.x[i], wp.y[i], 0, hour)
				wp.vx[i], wp.vy[i] = v.x, v.y
				wp.x[i] += v.x * km_per_ms * dt
				wp.y[i] += v.y * km_per_ms * dt
			}
			wp.seeded = true

			pos := make([][3]f32, WIND_VERTICES, context.temp_allocator)
			other := make([][3]f32, WIND_VERTICES, context.temp_allocator)
			color := make([][4]u8, WIND_VERTICES, context.temp_allocator)
			for i in 0 ..< WIND_PARTICLES {
				v := [2]f32{wp.vx[i], wp.vy[i]}
				if linalg.length(v) < WIND_CALM_MS do continue
				p := [2]f32{wp.x[i], wp.y[i]}
				fade := math.sin(math.PI * wp.age[i] / WIND_LIFE_S)
				tail := p - v * km_per_ms * WIND_TRAIL_S
				line_quad(pos, other, color, i * 6, p, tail, {WIND_COLOR, 0, 0, u8(fade * 255)})
			}
			rl.UpdateMeshBuffer(lm.wind, 0, raw_data(pos), i32(len(pos) * size_of(pos[0])), 0)
			rl.UpdateMeshBuffer(lm.wind, 2, raw_data(other), i32(len(other) * size_of(other[0])), 0)
			rl.UpdateMeshBuffer(lm.wind, 3, raw_data(color), i32(len(color) * size_of(color[0])), 0)
		}

		rl.BeginMode2D(cam)
		{
			screen := [2]f32{f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())}
			uniform: [LINE_COLORS][4]f32
			for c, k in pal.lines do uniform[k] = rl.ColorNormalize(c)
			uniform[WIND_COLOR] = rl.ColorNormalize(pal.wind)
			rl.SetShaderValue(lm.material.shader, lm.loc_screen, &screen, .VEC2)
			rl.SetShaderValueV(lm.material.shader, lm.loc_colors, &uniform, .VEC4, LINE_COLORS)
			if lm.map_lines.vertexCount > 0 do rl.DrawMesh(lm.map_lines, lm.material, rl.Matrix(1))
			rl.DrawMesh(lm.wind, lm.material, rl.Matrix(1))
		}
		// 8 px marker pointing along the heading, DrawPoly puts the first corner at the rotation angle.
		rl.DrawPoly(w.ship.pos, 3, 8 / cam.zoom, math.to_degrees(w.ship.heading) - 90, pal.accent)
		rl.EndMode2D()

		// Labels in screen space, so dots and text keep their pixel size at every zoom.
		// Names are 0-terminated UTF-8 from the bake, the default raylib font covers Latin-1 (Liege has an e grave).
		// Off screen: dropped. Overlapping an earlier label: only the dot. Earlier = first in the bake, there is
		// no population yet to rank cities by.
		labels := make([dynamic]Label, 0, len(w.m.cities), context.temp_allocator)
		screen_rect := rl.Rectangle{0, 0, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())}
		for &c in w.m.cities {
			p := rl.GetWorldToScreen2D(c.pos, cam)
			text := cstring(raw_data(c.name[:]))
			l := Label {
				dot   = p,
				rect  = {
					p.x + 6 - LABEL_GAP_PX,
					p.y - LABEL_PX / 2 - LABEL_GAP_PX,
					f32(rl.MeasureText(text, LABEL_PX)) + 2 * LABEL_GAP_PX,
					LABEL_PX + 2 * LABEL_GAP_PX,
				},
				text  = text,
				shown = true,
			}
			if !rl.CheckCollisionPointRec(p, screen_rect) && !rl.CheckCollisionRecs(l.rect, screen_rect) do continue
			for &prev in labels {
				if prev.shown && rl.CheckCollisionRecs(l.rect, prev.rect) do l.shown = false
			}
			append(&labels, l)
		}
		for &l in labels {
			rl.DrawCircleV(l.dot, 3, pal.text)
			if l.shown do rl.DrawText(l.text, i32(l.rect.x + LABEL_GAP_PX), i32(l.rect.y + LABEL_GAP_PX), LABEL_PX, pal.text)
		}

		// Toolbar: map / drive mode, sim speed, theme. The same keys still work (M, 1-4, T).
		// A click changes the state after this frame's update, so it shows from the next frame on.
		rl.DrawRectangleRec(toolbar, pal.surface)
		r := rl.Rectangle{toolbar.x + UI_PAD, toolbar.y + UI_PAD, UI_BUTTON_W, UI_BUTTON_H}
		if ui_button(r, "Map", !w.drive_mode, pal) do w.drive_mode = false
		r.x += UI_BUTTON_W + UI_GAP
		if ui_button(r, "Drive", w.drive_mode, pal) do w.drive_mode = true
		r.x += UI_BUTTON_W + UI_GROUP_GAP
		for s, i in speeds {
			if ui_button(r, fmt.ctprintf("%.0fx", s), w.sim_speed == i, pal) do w.sim_speed = i
			r.x += UI_BUTTON_W + UI_GAP
		}
		r.x += UI_GROUP_GAP - UI_GAP
		THEME_NAMES :: [Theme]cstring {
			.Day   = "Day",
			.Night = "Night",
		}
		names := THEME_NAMES
		for name, theme in names {
			if ui_button(r, name, w.theme == theme, pal) do w.theme = theme
			r.x += UI_BUTTON_W + UI_GAP
		}
	}
	{
		// The OpenStreetMap license (ODbL) asks for this credit wherever the map is shown.
		CREDIT :: cstring("\u00a9 OpenStreetMap contributors")
		PAD :: 4
		text := rl.MeasureTextEx(w.font, CREDIT, FONT_PX, 0)
		screen := [2]f32{f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())}
		box := linalg.floor(screen - text - 2 * PAD)
		rl.DrawRectangleV(box, text + 2 * PAD, rl.ColorAlpha(pal.surface, 0.8))
		rl.DrawTextEx(w.font, CREDIT, box + PAD, FONT_PX, 0, pal.text_2)
	}
	prof_end(w, .Draw, t)

	// Profiler overlay, F3 toggles it. It shows the previous frame and is not counted in draw ms.
	when PROFILING {
		p := &w.prof
		if rl.IsKeyPressed(.F3) do p.hidden = !p.hidden
		if !p.hidden {
			worst: f32
			for ms in p.frame_ms do worst = max(worst, ms)
			MB :: f32(1 << 20)
			rl.DrawRectangle(8, 8, 300, 132, {0, 0, 0, 170})
			lines := [?]cstring {
				fmt.ctprintf(
					"frame %.2f ms (update %.2f, draw %.2f)",
					p.ms[.Update] + p.ms[.Draw],
					p.ms[.Update],
					p.ms[.Draw],
				),
				fmt.ctprintf("worst of %d frames %.2f ms, budget %d", PROF_FRAMES, worst, FRAME_BUDGET_MS),
				fmt.ctprintf("route %.2f ms, weather load %.2f ms", p.ms[.Route], p.ms[.Weather_Load]),
				fmt.ctprintf(
					"perm %.2f / %.2f MB, route %.2f / %.2f MB",
					f32(w.perm.total_used) / MB,
					f32(w.perm.total_reserved) / MB,
					f32(w.route_mem.total_used) / MB,
					f32(w.route_mem.total_reserved) / MB,
				),
				fmt.ctprintf("frame arena %.1f KB", f32(p.frame_used) / 1024),
			}
			for line, i in lines do rl.DrawText(line, 14, 14 + i32(i) * 12, 10, rl.RAYWHITE)

			// 2 px per frame, oldest on the left, 10 px per ms, the yellow line is the budget.
			base :: 134
			rl.DrawLine(
				14,
				base - FRAME_BUDGET_MS * 10,
				14 + PROF_FRAMES * 2,
				base - FRAME_BUDGET_MS * 10,
				rl.YELLOW,
			)
			for i in 0 ..< PROF_FRAMES {
				ms := p.frame_ms[(p.head + i) % PROF_FRAMES]
				h := clamp(i32(ms * 10), 1, 60)
				rl.DrawRectangle(14 + i32(i) * 2, base - h, 2, h, ms > FRAME_BUDGET_MS ? rl.RED : rl.GREEN)
			}
		}
	}
	rl.EndDrawing()

	when PROFILING {
		w.prof.frame_ms[w.prof.head] = w.prof.ms[.Update] + w.prof.ms[.Draw]
		w.prof.head = (w.prof.head + 1) % PROF_FRAMES
		w.prof.frame_used = w.frame.total_used
	}

	return !rl.WindowShouldClose()
}

// The host calls this on the old library right before it unloads it.
@(export)
game_before_reload :: proc(memory: rawptr) {
	weather_stop((^World)(memory))
	node_stop((^World)(memory))
}

@(export)
game_shutdown :: proc(memory: rawptr) {
	w := (^World)(memory)
	weather_stop(w)
	node_stop(w)
	// raylib skips its own default font here, and headless runs never loaded one (texture id 0).
	if w.font.texture.id != 0 do rl.UnloadFont(w.font)
	line_meshes_unload(&w.line_meshes)
	virtual.arena_destroy(&w.fetch.mem)
	virtual.arena_destroy(&w.node.mem)
	virtual.arena_destroy(&w.frame)
	virtual.arena_destroy(&w.route_mem)
	perm := w.perm
	virtual.arena_destroy(&perm)
}

@(export)
game_shutdown_window :: proc() {
	rl.CloseWindow()
}
