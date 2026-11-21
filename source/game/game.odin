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
// Simulated time runs at real time (Lars, 2026-11-21: no sim speed buttons, the speed is shown in km/h).

// Screens of the design: plan (zero, the start screen) and navigate. Esc goes back to plan.
Screen :: enum u8 {
	Plan,
	Navigate,
}

LOADING_MIN_S :: 0.9 // the loading screen stays at least this long
LOADING_FADE_S :: 0.4
LOADING_TURN_S :: 0.9 // one turn of the ring
SCAN_S :: 1.6 // the A* scan animation after a new plan
LINE_DEPTH_BIAS :: 2e-4 // NDC depth step between the line passes on the ground plane (casing, fill, wind)
HUB_MARKER_PX :: 26

// Set by compile.sh with -define: debug builds get DRIFT_DEBUG, profile builds DRIFT_PROFILE, release neither.
DRIFT_DEBUG :: #config(DRIFT_DEBUG, false)
DRIFT_PROFILE :: #config(DRIFT_PROFILE, false)
BUILD_MODE :: "debug" when DRIFT_DEBUG else "profile" when DRIFT_PROFILE else "release"

World :: struct {
	perm:            virtual.Arena,
	route_mem:       virtual.Arena,
	frame:           virtual.Arena,
	m:               Map,
	world_map:       World_Map,
	globe:           Globe_GPU,
	weather:         Weather,
	// sha256 of weather, identifies the snapshot (carpool offers will carry it)
	weather_hash:    [32]u8,
	fetch:           Fetch,
	identity:        ed25519.Private_Key, // zero until identity_load_or_create succeeds
	identity_pub:    [32]u8,
	store:           Store, // carpool messages, see net.odin
	node:            Net_Node, // peer to peer threads and peers, see net.odin
	trip:            Trip, // the accepted trip in progress, frame loop only
	live_send_s:     f32, // seconds since our live position was last sent (carpool_frame)
	partner:         [3]f32, // the carpool partner's newest live position, km, km, m
	partner_seen:    bool,
	grid:            Grid,
	belgium:         [HEIGHT_W * HEIGHT_H]u8, // inside-Belgium mask with depth, see belgium_build
	controls:        Controls,
	ship:            Ship,
	screen:          Screen, // zero = plan: Controls move the camera. Navigate: Controls steer the ship
	plan:            Plan,
	plan_mem:        virtual.Arena, // paths and maneuvers of w.routes, reset by plan_routes
	routes:          [Route_Mode]Planned_Route,
	nav:             Nav,
	nav_wind:        bool, // wind trails while navigating (design: off by default)
	replay:          Replay,
	no_fly:          [MAX_NO_FLY]No_Fly_Zone,
	gust_zones:      [MAX_GUST_ZONES]Gust_Zone, // reported in flight, route() goes around them
	tick:            u64,
	accum:           f64,
	prof:            Profiler,
	cam:             Cam,
	ui:              Ui,
	loading_s:       f32, // seconds the window has shown frames, for the loading screen
	scan_s:          f32, // seconds since the last plan, for the A* scan animation
	// GPU texture and glyph tables owned by raylib, zero until the first frame with a window.
	fonts:           Fonts,
	line_meshes:     Line_Meshes,
	labels:          Map_Labels,
	palette:         Palette, // PALETTE, copied every frame, read through palette(w)
	wind:            Wind_Particles,
	airship:         Airship,
	buildings:       Buildings,
	cloud_sprites:   Cloud_Sprites,
	nature:          Tile_Cache,
	towns:           Tile_Cache,
	// Cruise control while steering yourself: the throttle the ship holds, -1 = take the current speed first.
	cruise:          f32,
	cruise_on_road:  bool,
	car_anim:        Car_Anim,
	car_skin:        Car_Skin, // the player's car body, car_models.odin
	// Other cars from the presence gossip (presence.odin), copied from the node table every PRESENCE_COPY_S.
	others:          [PRESENCE_SLOTS]Other_Car,
	other_count:     int,
	others_copied_s: f32, // seconds since that copy
	presence_send_s: f32,
	presence_copy_s: f32,
	street:          Street, // the third-person street view, street.odin
	pose_prev:       Ship_Pose, // the ship before the last fixed step
	pose:            Ship_Pose, // where the ship is drawn this frame (ship.odin)
	collide:         Collide, // building footprints for free flight, collide.odin
	script:          Script, // --script: keys, mouse and screenshots per frame, debug.odin
}

@(export)
game_memory_size :: proc() -> int {
	return size_of(World)
}

@(export)
game_init_window :: proc() {
	rl.SetConfigFlags({.WINDOW_RESIZABLE, .MSAA_4X_HINT})
	rl.InitWindow(1440, 900, "drift")
	rl.SetWindowMinSize(900, 600)
	// Esc leaves navigation (design), it does not close the window.
	rl.SetExitKey(.KEY_NULL)
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

	if !weather_load_snapshot(w, SNAPSHOT_PATH) do weather_load_fallback(w)
	identity_load_or_create(w)
	car_skin_load(w)
	if rl.IsWindowReady() {
		airship_build(w)
		buildings_build(w)
		clouds_build(w)
	}
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
	belgium_build(w)
	wm, wm_ok := load_world()
	if !wm_ok do logf(w, "map", "world.bin: wrong magic or version")
	w.world_map = wm
	globe_unload(&w.globe)
	w.labels.built = false
	w.grid.terrain_built = false
	// The new library may change the shaders, so the mesh is rebuilt on the next frame.
	line_meshes_unload(&w.line_meshes)
	street_unload(&w.street)
	globe_unload(&w.globe)
}

@(export)
game_update :: proc(memory: rawptr) -> bool {
	w := (^World)(memory)
	context.allocator = virtual.arena_allocator(&w.perm)
	context.temp_allocator = virtual.arena_allocator(&w.frame)
	defer virtual.arena_free_all(&w.frame)

	t := prof_begin()
	if w.script.on {
		script_frame(w)
	} else {
		weather_poll(w)
		node_poll(w)
	}
	ui_begin(w)
	keys := read_controls(w)
	pad := pilot_pad_controls(w)
	w.controls = {
		clamp(keys.throttle + pad.throttle, -1, 1),
		clamp(keys.turn + pad.turn, -1, 1),
		clamp(keys.climb + pad.climb, -1, 1),
	}
	typing := w.plan.editing != .None

	if !typing {
		// V: the third-person street view (street.odin), V again or Esc back to the map.
		if key_pressed(w, .V) do street_toggle(w)
		// M: free flight without a route (the old drive mode), or back to the plan screen.
		if key_pressed(w, .M) && !w.street.on {
			if w.screen == .Plan {
				nav_stop(w)
				w.screen = .Navigate
				cam_chase(w)
			} else {
				pilot_exit(w)
			}
		}
	}
	if w.street.on && (w.screen != .Navigate || key_pressed(w, .ESCAPE)) {
		street_toggle(w)
	} else if w.screen == .Navigate {
		if key_pressed(w, .ESCAPE) do pilot_exit(w)
		// Design: whoever presses a steering key in navigation takes over at once.
		if w.nav.active && !w.nav.manual && w.controls != {} do nav_set_manual(w, true)
	} else {
		plan_refresh(w)
	}

	// A scripted run steps exactly once per frame, unless it gives frame times (frame_ms).
	w.accum += w.script.on && w.script.frame_n == 0 ? SIM_DT : f64(frame_time(w))
	for w.accum >= SIM_DT {
		if w.screen == .Navigate {
			w.pose_prev = ship_pose(&w.ship)
			c := w.controls
			autopilot := w.nav.active && !w.nav.manual
			// Street view by hand: free flight with momentum, the throttle is the thrust (no cruise control).
			free := w.street.on && !autopilot
			if autopilot {
				c = nav_autopilot(w)
				w.cruise = -1
			} else if !free {
				c.throttle = cruise_throttle(w, c.throttle, SIM_DT)
			}
			step := controls_pack(c)
			if w.replay.count < len(w.replay.steps) {
				w.replay.steps[w.replay.count] = step
				w.replay.count += 1
			}
			if free {
				ship_free_step(w, controls_unpack(step), SIM_DT)
			} else {
				ship_step(w, controls_unpack(step), SIM_DT)
			}
			nav_update(w, SIM_DT)
		}
		w.tick += 1
		w.accum -= SIM_DT
	}
	{
		// Between the last two steps; a jump (a teleport, a new start) or no stepping at all draws the state as is.
		now := ship_pose(&w.ship)
		p := w.pose_prev
		jump := abs(now.pos.x - p.pos.x) + abs(now.pos.y - p.pos.y) > 0.2
		if w.screen != .Navigate || jump do p = now
		t := f32(clamp(w.accum / SIM_DT, 0, 1))
		w.pose = {
			pos     = p.pos + (now.pos - p.pos) * f64(t),
			alt     = p.alt + (now.alt - p.alt) * t,
			heading = angle_lerp(p.heading, now.heading, t),
		}
	}
	if !w.script.on {
		carpool_frame(w, frame_time(w))
		presence_frame(w, frame_time(w))
	}
	prof_end(w, .Update, t)

	if key_pressed(w, .F5) {
		b := strings.builder_make(context.temp_allocator)
		dump_world(w, &b)
		fmt.print(strings.to_string(b))
	}

	// Camera: input when the mouse is not on last frame's UI, glides, chase / preview, then the raylib camera.
	// The keyboard and stick pan only on the plan screen, in navigation they steer the ship.
	cam_update(w, !ui_mouse_captured(w) && !w.street.on, w.screen == .Plan && !typing)

	w.palette = PALETTE
	pal := palette(w)
	frame_dt := frame_time(w)

	rl.BeginDrawing()
	t = prof_begin()
	space := pal.sky
	bg := rl.ColorLerp(pal.land, space, clamp(-w.cam.pose.zoom, 0, 1))
	rl.ClearBackground(bg)
	if w.street.on do street_draw(w)
	if !w.street.on {
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
			{
				// Ground layer grid (gust risk, solar): GROUND_CELL_KM quads, two triangles each, colors per
				// vertex rewritten every frame, positions fixed.
				gpos := make([][3]f32, GROUND_VERTICES, context.temp_allocator)
				for gy in 0 ..< GROUND_H - 1 {
					for gx in 0 ..< GROUND_W - 1 {
						corners := ground_quad(gx, gy)
						base := (gy * (GROUND_W - 1) + gx) * 6
						for c, k in corners {
							gpos[base + k] = {f32(c.x * GROUND_CELL_KM), f32(c.y * GROUND_CELL_KM), 0}
						}
					}
				}
				lm.ground = rl.Mesh {
					vertexCount   = GROUND_VERTICES,
					triangleCount = GROUND_VERTICES / 3,
					vertices      = ([^]f32)(raw_data(gpos)),
					colors        = ([^]u8)(
						raw_data(make([][4]u8, GROUND_VERTICES, context.temp_allocator)),
					),
				}
				rl.UploadMesh(&lm.ground, true)
				lm.ground.vertices, lm.ground.colors = nil, nil
				lm.ground_material = rl.LoadMaterialDefault()
			}
			areas_build(w, lm)
			hill_build(w, lm)
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
			lm.loc_widths = rl.GetShaderLocation(shader, "widths")
			lm.loc_fog_c = rl.GetShaderLocation(shader, "fog_color")
			lm.loc_fog_r = rl.GetShaderLocation(shader, "fog_range")
			lm.loc_bias = rl.GetShaderLocation(shader, "depth_bias")
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

		// Wind particles: the wind layer of the layers panel, forecast hour of the simulated time. Spread over the
		// ground the camera sees. Update loop over the SoA arrays, then one pass writes the trails into the wind
		// mesh, colored by speed.
		show_wind := w.screen == .Plan ? !w.plan.layers.hide_wind : w.nav_wind
		if show_wind {
			wp := &w.wind
			lo, hi := [2]f32{1e9, 1e9}, [2]f32{-1e9, -1e9}
			screen := w.cam.screen
			for c in ([?][2]f32{{0, 0}, {1, 0}, {0, 1}, {1, 1}, {0.5, 0}, {0.5, 0.5}}) {
				if g, ok := cam_ground_at(w, c * screen); ok {
					lo = linalg.min(lo, g)
					hi = linalg.max(hi, g)
				}
			}
			lo = linalg.max(lo, [2]f32{0, 0})
			hi = linalg.min(hi, [2]f32{MAP_W_KM, MAP_H_KM})
			hour := sim_hour(w)
			km_per_ms := WIND_PX_PER_MS / w.cam.px_per_km
			for i in 0 ..< WIND_PARTICLES {
				wp.age[i] += frame_dt
				out := wp.x[i] < lo.x || wp.x[i] > hi.x || wp.y[i] < lo.y || wp.y[i] > hi.y
				out ||= !belgium_inside(w, wp.x[i], wp.y[i])
				if !wp.seeded || out || wp.age[i] >= WIND_LIFE_S {
					// A few picks to land in Belgium. One that still misses has fade 0 and tries again next frame.
					for _ in 0 ..< WIND_SPAWN_TRIES {
						wp.x[i] = lo.x + wind_rand(wp) * (hi.x - lo.x)
						wp.y[i] = lo.y + wind_rand(wp) * (hi.y - lo.y)
						if belgium_inside(w, wp.x[i], wp.y[i]) do break
					}
					wp.age[i] = wp.seeded ? 0 : wind_rand(wp) * WIND_LIFE_S
				}
				v := wind_at(w, wp.x[i], wp.y[i], w.plan.layers.wind_layer, hour)
				wp.vx[i], wp.vy[i] = v.x, v.y
				wp.x[i] += v.x * km_per_ms * frame_dt
				wp.y[i] += v.y * km_per_ms * frame_dt
			}
			wp.seeded = true

			pos := make([][3]f32, WIND_VERTICES, context.temp_allocator)
			other := make([][3]f32, WIND_VERTICES, context.temp_allocator)
			color := make([][4]u8, WIND_VERTICES, context.temp_allocator)
			// Plan screen 40 % opacity in the design, raised: Lars wants the wind clearer (2026-11-21).
			alpha: f32 = w.screen == .Plan ? 0.75 : 0.9
			for i in 0 ..< WIND_PARTICLES {
				v := [2]f32{wp.vx[i], wp.vy[i]}
				speed := linalg.length(v)
				if speed < WIND_CALM_MS do continue
				p := [2]f32{wp.x[i], wp.y[i]}
				fade := math.sin(math.PI * wp.age[i] / WIND_LIFE_S) * alpha * belgium_fade(w, p.x, p.y)
				tail := p - v * km_per_ms * WIND_TRAIL_S
				k := speed < 6 ? 0 : speed < 10 ? 1 : speed < 14 ? 2 : 3
				line_quad(pos, other, color, i * 6, p, tail, {u8(WIND_COLOR + k), 0, 0, u8(fade * 255)})
			}
			rl.UpdateMeshBuffer(lm.wind, 0, raw_data(pos), i32(len(pos) * size_of(pos[0])), 0)
			rl.UpdateMeshBuffer(lm.wind, 2, raw_data(other), i32(len(other) * size_of(other[0])), 0)
			rl.UpdateMeshBuffer(lm.wind, 3, raw_data(color), i32(len(color) * size_of(color[0])), 0)
		}

		// A tilted camera: the far land fades into the horizon color (design "Kaart").
		if tilt := w.cam.pose.tilt; tilt > 0.05 {
			h := i32(w.cam.screen.y * 0.45)
			rl.DrawRectangleGradientV(
				0,
				0,
				i32(w.cam.screen.x),
				h,
				rl.ColorAlpha(pal.horizon, min(tilt / 0.9, 1)),
				rl.ColorAlpha(pal.horizon, 0),
			)
		}

		// Everything lies on the ground plane (z = 0): raylib's depth test passes equal depths, so later draws go on
		// top. Triangles face the camera when they are counter-clockwise on the map (x east, y south).
		globe_set_clip(w)
		rl.BeginMode3D(w.cam.view)
		globe_draw(w)

		// Draw order 1: land use areas, water last.
		areas_draw(w)
		hill_draw(w)

		// Draw order 2: ground layers.
		if w.screen == .Plan || w.nav_wind do layers_draw_ground(w)

		// A* scan animation: replays the order the last route search expanded its nodes (grid.expanded), a
		// faint accent square per 1 km cell, over SCAN_S after a new plan. The router does no extra work.
		if w.scan_s > 0 && w.scan_s < SCAN_S && w.screen == .Plan {
			w.scan_s += frame_dt
			g := &w.grid
			shown := int(f32(g.expanded_len) * min(w.scan_s / (SCAN_S * 0.7), 1))
			fade := 1 - clamp((w.scan_s - SCAN_S * 0.7) / (SCAN_S * 0.3), 0, 1)
			c := rl.ColorAlpha(pal.accent, 0.18 * fade)
			for n in g.expanded[:shown] {
				cell := grid_cell(n)
				x, y := f32(cell.x) * GRID_CELL_KM, f32(cell.y) * GRID_CELL_KM
				a, b := [3]f32{x + 0.1, y + 0.1, 0}, [3]f32{x + 0.1, y + 0.9, 0}
				c2, d := [3]f32{x + 0.9, y + 0.9, 0}, [3]f32{x + 0.9, y + 0.1, 0}
				rl.DrawTriangle3D(a, b, c2, c)
				rl.DrawTriangle3D(a, c2, d, c)
			}
		}

		// Draw order 3: road casings, then the fills. Widths are pixels on the screen (design "De kaart": 10 / 8 /
		// 6 px + 2 px casing per side). The design's zoom range ends at a ~16 km wide view; zoomed out further
		// the widths shrink and the street classes drop out, otherwise all of Belgium is one blob of roads.
		{
			screen := w.cam.screen
			z := w.cam.pose.zoom
			// Full design widths from zoom ~4.5 (a ~16 km wide view), eased in so a city-to-city view stays light.
			t := clamp((z - 1.5) / 3, 0, 1)
			t *= t
			streets := clamp((z - 3) / 1.5, 0, 1)
			fill, casing: [LINE_COLORS]f32
			fill[Map_Kind.Border] = 1.5
			fill[Map_Kind.River] = 1.5 + 2.5 * t
			fill[Map_Kind.Motorway] = 2 + 8 * t
			fill[Map_Kind.Trunk] = 1 + 7 * t
			fill[Map_Kind.Primary] = 1 + 7 * t
			fill[Map_Kind.Secondary] = streets * 6
			fill[Map_Kind.Tertiary] = streets * 6
			for k in ([?]Map_Kind{.Motorway, .Trunk, .Primary, .Secondary, .Tertiary}) {
				if fill[k] > 0 do casing[k] = fill[k] + 4 * t
			}
			for k in 0 ..< WIND_COLOR_COUNT do fill[WIND_COLOR + k] = WIND_WIDTH_PX
			colors, casing_colors: [LINE_COLORS][4]f32
			colors[Map_Kind.Border] = rl.ColorNormalize(pal.text_2)
			colors[Map_Kind.River] = rl.ColorNormalize(pal.water)
			colors[Map_Kind.Tertiary] = rl.ColorNormalize(pal.street)
			colors[Map_Kind.Secondary] = rl.ColorNormalize(pal.street)
			colors[Map_Kind.Primary] = rl.ColorNormalize(pal.main_road)
			colors[Map_Kind.Trunk] = rl.ColorNormalize(pal.main_road)
			colors[Map_Kind.Motorway] = rl.ColorNormalize(pal.motorway)
			wind := wind_colors(w)
			for c, k in wind do colors[WIND_COLOR + k] = rl.ColorNormalize(c)
			casing_colors[Map_Kind.Tertiary] = rl.ColorNormalize(pal.street_casing)
			casing_colors[Map_Kind.Secondary] = rl.ColorNormalize(pal.street_casing)
			casing_colors[Map_Kind.Primary] = rl.ColorNormalize(pal.main_road_casing)
			casing_colors[Map_Kind.Trunk] = rl.ColorNormalize(pal.main_road_casing)
			casing_colors[Map_Kind.Motorway] = rl.ColorNormalize(pal.motorway_casing)
			horizon := rl.ColorNormalize(pal.horizon).rgb
			// Fog starts a bit beyond the ship in the chase view, none from above.
			dist := linalg.length(w.cam.view.position - w.cam.view.target)
			fog := w.cam.pose.tilt > 0.05 ? [2]f32{dist * 1.2, dist * 3.5} : [2]f32{1e9, 2e9}
			sh := lm.material.shader
			rl.SetShaderValue(sh, lm.loc_screen, &screen, .VEC2)
			rl.SetShaderValue(sh, lm.loc_fog_c, &horizon, .VEC3)
			rl.SetShaderValue(sh, lm.loc_fog_r, &fog, .VEC2)
			{
				bias := f32(0.5 * LINE_DEPTH_BIAS)
				rl.SetShaderValue(sh, lm.loc_bias, &bias, .FLOAT)
				rl.SetShaderValueV(sh, lm.loc_colors, &colors, .VEC4, LINE_COLORS)
				rl.SetShaderValueV(sh, lm.loc_widths, &fill, .FLOAT, LINE_COLORS)
				globe_draw_lines(w)
			}
			if lm.map_lines.vertexCount > 0 {
				bias := f32(LINE_DEPTH_BIAS)
				rl.SetShaderValue(sh, lm.loc_bias, &bias, .FLOAT)
				rl.SetShaderValueV(sh, lm.loc_colors, &casing_colors, .VEC4, LINE_COLORS)
				rl.SetShaderValueV(sh, lm.loc_widths, &casing, .FLOAT, LINE_COLORS)
				rl.DrawMesh(lm.map_lines, lm.material, rl.Matrix(1))
				bias = 2 * LINE_DEPTH_BIAS
				rl.SetShaderValue(sh, lm.loc_bias, &bias, .FLOAT)
				rl.SetShaderValueV(sh, lm.loc_colors, &colors, .VEC4, LINE_COLORS)
				rl.SetShaderValueV(sh, lm.loc_widths, &fill, .FLOAT, LINE_COLORS)
				rl.DrawMesh(lm.map_lines, lm.material, rl.Matrix(1))
			}
			bias := f32(3 * LINE_DEPTH_BIAS)
			rl.SetShaderValue(sh, lm.loc_bias, &bias, .FLOAT)
			rl.SetShaderValueV(sh, lm.loc_colors, &colors, .VEC4, LINE_COLORS)
			rl.SetShaderValueV(sh, lm.loc_widths, &fill, .FLOAT, LINE_COLORS)
			if show_wind do rl.DrawMesh(lm.wind, lm.material, rl.Matrix(1))

			// Draw order 4: the 3D buildings around the cities and the trees, over the roads. They grow out of the
			// ground while the camera zooms in.
			grow := clamp((w.cam.pose.zoom - BUILDINGS_ZOOM_0) / (BUILDINGS_ZOOM_1 - BUILDINGS_ZOOM_0), 0, 1)
			if grow > 0 {
				target := w.cam.view.target.xy
				view_km := w.cam.screen.x / max(w.cam.px_per_km, 1e-3)
				look := buildings_map_look(w)
				buildings_draw(
					w,
					fog,
					ease_in_out(grow),
					target,
					BUILDINGS_CULL_KM + view_km,
					MAP_PLACEMENT,
					look,
				)
				towns_draw(w, target, TOWN_REACH_KM, MAP_PLACEMENT)
				nature_draw(w, target, TREE_REACH_KM, MAP_PLACEMENT)
			}
		}
		rl.EndMode3D()

		// Draw order 5 and 6: routes, then the airship (only while flying).
		globe_labels_draw(w)
		nav_draw_routes(w)
		others_draw(w)
		if w.screen == .Navigate do airship_draw(w)
		carpool_draw_partner(w)
		clouds_draw(w)

		// Draw order 7: hub markers with their names (design: green 26 px circle, white 2 px border, tower icon
		// 15 px, name in Figtree 600 13 px). Names are the real ones from belgium.bin. Screen space, culled: a
		// name that overlaps an earlier one is dropped, the marker stays.
		{
			labels := make([dynamic]rl.Rectangle, 0, w.m.hub_count, context.temp_allocator)
			for i in 0 ..< w.m.hub_count {
				h := w.m.hubs[i].pos
				p, visible := cam_to_screen(w, {h.x, h.y, 0})
				if !visible do continue
				name := hub_name(w, i)
				size := ui_text_size(w, name, .Figtree_600, 13)
				rect := rl.Rectangle{p.x + HUB_MARKER_PX / 2 + 4, p.y - size.y / 2, size.x, size.y}
				shown := true
				for prev in labels do if rl.CheckCollisionRecs(rect, prev) do shown = false
				rl.DrawCircleV(p, HUB_MARKER_PX / 2, rl.WHITE)
				rl.DrawCircleV(p, HUB_MARKER_PX / 2 - 2, pal.hub)
				ui_icon(w, .Tower, p, 15, rl.WHITE)
				if !shown do continue
				append(&labels, rect)
				for o in ([?][2]f32{{-1, 0}, {1, 0}, {0, -1}, {0, 1}}) {
					ui_text(w, {rect.x, rect.y} + o, name, .Figtree_600, 13, pal.label_halo)
				}
				ui_text(w, {rect.x, rect.y}, name, .Figtree_600, 13, pal.area_label)
			}
			labels_draw(w, &labels)
		}
		nav_draw_trip_markers(w)

		// Draw order 8: the screen UI.
		switch w.screen {
		case .Plan:
			nav_draw_bubbles(w)
			plan_ui(w)
			plan_map_controls(w)
		case .Navigate:
			nav_ui(w)
			pilot_ui(w)
		}
	}
	credit: {
		// The OpenStreetMap license (ODbL) asks for this credit wherever the map is shown, CC BY 4.0 for the car
		// model (assets/car-LICENSE.txt).
		CREDIT :: "© OpenStreetMap contributors, car model: Eric Chadwick (CC BY 4.0)"
		PAD :: 4
		text := ui_text_size(w, CREDIT, .Roboto_400, 12)
		screen := [2]f32{f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())}
		box := linalg.floor(screen - text - 2 * PAD)
		rl.DrawRectangleV(box, text + 2 * PAD, rl.ColorAlpha(pal.surface, 0.8))
		ui_text(w, box + PAD, CREDIT, .Roboto_400, 12, pal.text_2)
	}
	ui_toast_draw(w)

	// Loading screen (design "Laadscherm", in the light palette): sky, a 38 px ring with a cyan top turning once per 0.9 s, then
	// it fades out in 0.4 s. Covers the first frames while the map mesh and the fonts are built.
	w.loading_s += frame_dt
	if w.loading_s < LOADING_MIN_S + LOADING_FADE_S {
		pal := PALETTE
		alpha := 1 - clamp((w.loading_s - LOADING_MIN_S) / LOADING_FADE_S, 0, 1)
		screen := w.cam.screen
		rl.DrawRectangleV({0, 0}, screen, rl.ColorAlpha(pal.sky, alpha))
		c := screen / 2 - {0, 16}
		angle := w.loading_s / LOADING_TURN_S * 360
		rl.DrawRing(c, 16, 19, 0, 360, 48, rl.ColorAlpha(pal.surface_3, alpha))
		rl.DrawRing(c, 16, 19, angle - 90, angle, 24, rl.ColorAlpha(pal.route, alpha))
		text := "Building the map of Belgium..."
		size := ui_text_size(w, text, .Roboto_400, 14)
		ui_text(w, {c.x - size.x / 2, c.y + 34}, text, .Roboto_400, 14, rl.ColorAlpha(pal.text_2, alpha))
	}
	prof_end(w, .Draw, t)

	// Profiler overlay, F3 or the Profiler toggle in the layers panel shows it. It shows the previous frame and is not counted in draw ms.
	when PROFILING {
		p := &w.prof
		if key_pressed(w, .F3) do p.shown = !p.shown
		if p.shown {
			worst: f32
			for ms in p.frame_ms do worst = max(worst, ms)
			MB :: f32(1 << 20)
			x0 := i32(w.cam.screen.x) - 316 - 88 // left of the map controls column
			y0 := i32(w.cam.screen.y) - 170
			rl.DrawRectangle(x0, y0, 300, 132, {0, 0, 0, 170})
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
			for line, i in lines do rl.DrawText(line, x0 + 6, y0 + 6 + i32(i) * 12, 10, rl.RAYWHITE)

			// 2 px per frame, oldest on the left, 10 px per ms, the yellow line is the budget.
			base := y0 + 126
			rl.DrawLine(
				x0 + 6,
				base - FRAME_BUDGET_MS * 10,
				x0 + 6 + PROF_FRAMES * 2,
				base - FRAME_BUDGET_MS * 10,
				rl.YELLOW,
			)
			for i in 0 ..< PROF_FRAMES {
				ms := p.frame_ms[(p.head + i) % PROF_FRAMES]
				h := clamp(i32(ms * 10), 1, 60)
				rl.DrawRectangle(
					x0 + 6 + i32(i) * 2,
					base - h,
					2,
					h,
					ms > FRAME_BUDGET_MS ? rl.RED : rl.GREEN,
				)
			}
		}
	}
	quit := w.script.on && script_end(w)
	rl.EndDrawing()

	when PROFILING {
		w.prof.frame_ms[w.prof.head] = w.prof.ms[.Update] + w.prof.ms[.Draw]
		w.prof.head = (w.prof.head + 1) % PROF_FRAMES
		w.prof.frame_used = w.frame.total_used
	}

	return !rl.WindowShouldClose() && !quit
}

// Seconds this frame stands for, for drawing and animation: the real frame time, or exactly one step in a
// scripted run so its screenshots do not depend on the machine.
frame_time :: proc(w: ^World) -> f32 {
	if sc := &w.script; sc.on do return sc.frame_n > 0 ? sc.frame_ms[sc.frame % sc.frame_n] / 1000 : SIM_DT
	return min(rl.GetFrameTime(), MAX_FRAME_DT)
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
	fonts_unload(w)
	line_meshes_unload(&w.line_meshes)
	globe_unload(&w.globe)
	buildings_unload(&w.buildings)
	clouds_unload(&w.cloud_sprites)
	tiles_unload(&w.nature)
	tiles_unload(&w.towns)
	street_unload(&w.street)
	virtual.arena_destroy(&w.fetch.mem)
	virtual.arena_destroy(&w.node.mem)
	virtual.arena_destroy(&w.frame)
	virtual.arena_destroy(&w.plan_mem)
	virtual.arena_destroy(&w.route_mem)
	perm := w.perm
	virtual.arena_destroy(&perm)
}

@(export)
game_shutdown_window :: proc() {
	rl.CloseWindow()
}
