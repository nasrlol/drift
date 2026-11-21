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
	airship:      Airship,
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
	weather_load_snapshot(w, SNAPSHOT_PATH)
	identity_load_or_create(w)
	if rl.IsWindowReady() do airship_build(&w.airship)
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
}

@(export)
game_update :: proc(memory: rawptr) -> bool {
	w := (^World)(memory)
	context.allocator = virtual.arena_allocator(&w.perm)
	context.temp_allocator = virtual.arena_allocator(&w.frame)
	defer virtual.arena_free_all(&w.frame)

	t := prof_begin()
	weather_poll(w)
	w.controls = read_controls()

	if rl.IsKeyPressed(.M) do w.drive_mode = !w.drive_mode
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
		if rl.IsMouseButtonDown(.LEFT) && !w.drive_mode do v.pan -= rl.GetMouseDelta() / z0
		zoom := c.climb * ZOOM_PER_S * dt
		anchor := centre
		if wheel := rl.GetMouseWheelMove(); wheel != 0 {
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

	rl.BeginDrawing()
	t = prof_begin()
	rl.ClearBackground(rl.RAYWHITE)
	{
		// Points are [2]f32 km, the same layout as rl.Vector2, so the strips draw straight from map memory.
		colors := [Map_Kind]rl.Color {
			.Border   = rl.DARKGRAY,
			.River    = rl.BLUE,
			.Motorway = rl.ORANGE,
		}
		rl.BeginMode2D(cam)
		for l in w.m.lines {
			rl.DrawLineStrip(raw_data(w.m.points[l.start:]), i32(l.count), colors[Map_Kind(l.kind)])
		}
		rl.EndMode2D()
		airship_draw(w, cam)

		// Cities in screen space, so dots and text keep their pixel size at every zoom.
		// Names are 0-terminated UTF-8 from the bake, the default raylib font covers Latin-1 (Liege has an e grave).
		for &c in w.m.cities {
			p := rl.GetWorldToScreen2D(c.pos, cam)
			rl.DrawCircleV(p, 3, rl.BLACK)
			rl.DrawText(cstring(raw_data(c.name[:])), i32(p.x) + 6, i32(p.y) - 5, 10, rl.BLACK)
		}
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
}

@(export)
game_shutdown :: proc(memory: rawptr) {
	w := (^World)(memory)
	weather_stop(w)
	virtual.arena_destroy(&w.fetch.mem)
	virtual.arena_destroy(&w.frame)
	virtual.arena_destroy(&w.route_mem)
	perm := w.perm
	virtual.arena_destroy(&perm)
}

@(export)
game_shutdown_window :: proc() {
	rl.CloseWindow()
}
