package game

import "core:fmt"
import "core:math/linalg"
import "core:mem/virtual"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

// Timing is compiled in for debug and profile builds only. Wall-clock time is fine here,
// it is only displayed and never fed back into the simulation.
PROFILING :: DRIFT_DEBUG || DRIFT_PROFILE
PROF_FRAMES :: 120
FRAME_BUDGET_MS :: 4

Prof_Block :: enum u8 {
	Update,
	Draw,
	Route,
	Weather_Load,
}

// Zero is valid: nothing measured yet, overlay hidden (F3 or the layers panel shows it).
Profiler :: struct {
	ms:         [Prof_Block]f32, // last measurement of each block
	frame_ms:   [PROF_FRAMES]f32, // update + draw, ring buffer, head is the oldest
	head:       int,
	frame_used: uint, // frame arena bytes used by the previous frame
	shown:      bool,
}

prof_begin :: proc() -> time.Tick {
	when PROFILING {
		return time.tick_now()
	} else {
		return {}
	}
}

prof_end :: proc(w: ^World, block: Prof_Block, start: time.Tick) {
	when PROFILING {
		w.prof.ms[block] = f32(time.duration_milliseconds(time.tick_since(start)))
	}
}

ROUTE_MODE_NAMES :: [Route_Mode]string {
	.Fastest  = "fastest",
	.Greenest = "greenest",
	.Calmest  = "calmest",
}

// Loads the snapshot file (net.odin format) into w.weather, runs every command in inputs and writes the result to out.
// out only holds deterministic text (no timings), so it can be compared byte for byte.
// Inputs, one command per line, # starts a comment:
//   route <from hub> <to hub> <fastest|greenest|calmest> <hour 0..8>
//   no_fly <x km> <y km> <radius km> <ceiling m>   adds a zone to the first free slot of w.no_fly
//   gust <x km> <y km> <radius km>                 adds a zone to the first free slot of w.gust_zones
headless_run :: proc(w: ^World, snapshot_path: string, inputs: []u8, out: ^strings.Builder) -> bool {
	t := prof_begin()
	weather_ok := weather_load_snapshot(w, snapshot_path)
	prof_end(w, .Weather_Load, t)
	if !weather_ok do return false
	fmt.sbprintfln(out, "weather start %d", w.weather.start)

	text := string(inputs)
	line_no := 0
	for raw in strings.split_lines_iterator(&text) {
		line_no += 1
		line := strings.trim_space(raw)
		if line == "" || line[0] == '#' do continue

		f: [8]string
		n := 0
		for field in strings.fields_iterator(&line) {
			if n == len(f) {
				logf(w, "headless", "inputs line %d: more than %d words", line_no, len(f))
				return false
			}
			f[n] = field
			n += 1
		}

		switch f[0] {
		case "route":
			from, from_ok := strconv.parse_int(f[1], 10)
			to, to_ok := strconv.parse_int(f[2], 10)
			hour, hour_ok := strconv.parse_int(f[4], 10)
			mode, mode_ok := Route_Mode(0), false
			for name, m in ROUTE_MODE_NAMES {
				if f[3] == name do mode, mode_ok = m, true
			}
			if n != 5 || !from_ok || !to_ok || !mode_ok || !hour_ok {
				logf(
					w,
					"headless",
					"inputs line %d: %q, want: route <from hub> <to hub> <fastest|greenest|calmest> <hour>",
					line_no,
					line,
				)
				return false
			}
			if from < 0 || from >= w.m.hub_count || to < 0 || to >= w.m.hub_count {
				logf(
					w,
					"headless",
					"inputs line %d: hubs %d -> %d, valid ids are 0..%d",
					line_no,
					from,
					to,
					w.m.hub_count - 1,
				)
				return false
			}
			if hour < 0 || hour >= FORECAST_HOURS {
				logf(
					w,
					"headless",
					"inputs line %d: hour %d outside 0..%d",
					line_no,
					hour,
					FORECAST_HOURS - 1,
				)
				return false
			}

			a, b := w.m.hubs[from].pos, w.m.hubs[to].pos
			start := [3]f32{a.x, a.y, height_at(w, a.x, a.y) + HUB_TOWER_M}
			goal := [3]f32{b.x, b.y, height_at(w, b.x, b.y) + HUB_TOWER_M}
			t = prof_begin()
			path, path_ok := route(w, start, goal, mode, hour)
			prof_end(w, .Route, t)

			fmt.sbprintf(out, "route %d -> %d %s hour %d: ", from, to, f[3], hour)
			if !path_ok {
				fmt.sbprintln(out, "no safe route")
				continue
			}
			km: f32
			for i in 1 ..< len(path) do km += linalg.length(path[i].xy - path[i - 1].xy)
			fmt.sbprintfln(out, "%d points, %.3f km", len(path), km)
			for p in path do fmt.sbprintfln(out, "  %.3f %.3f %.1f", p.x, p.y, p.z)
		case "no_fly":
			x, x_ok := strconv.parse_f32(f[1])
			y, y_ok := strconv.parse_f32(f[2])
			radius, radius_ok := strconv.parse_f32(f[3])
			ceiling, ceiling_ok := strconv.parse_f32(f[4])
			parsed := n == 5 && x_ok && y_ok && radius_ok && ceiling_ok
			// NaN fails every comparison, Inf fails the upper limits.
			sane := abs(x) < 1e6 && abs(y) < 1e6 && radius > 0 && radius < 1e6
			sane = sane && ceiling > 0 && ceiling < 1e6
			if !parsed || !sane {
				logf(
					w,
					"headless",
					"inputs line %d: %q, want: no_fly <x km> <y km> <radius km > 0> <ceiling m > 0>",
					line_no,
					raw,
				)
				return false
			}
			slot := -1
			for z, i in w.no_fly {
				if z.radius == 0 {
					slot = i
					break
				}
			}
			if slot < 0 {
				logf(w, "headless", "inputs line %d: already %d no-fly zones", line_no, MAX_NO_FLY)
				return false
			}
			w.no_fly[slot] = {{x, y}, radius, ceiling}
			fmt.sbprintfln(
				out,
				"no_fly %d: %.3f %.3f radius %.3f km below %.0f m",
				slot,
				x,
				y,
				radius,
				ceiling,
			)
		case "gust":
			x, x_ok := strconv.parse_f32(f[1])
			y, y_ok := strconv.parse_f32(f[2])
			radius, radius_ok := strconv.parse_f32(f[3])
			parsed := n == 4 && x_ok && y_ok && radius_ok
			// NaN fails every comparison, Inf fails the upper limits.
			sane := abs(x) < 1e6 && abs(y) < 1e6 && radius > 0 && radius < 1e6
			if !parsed || !sane {
				logf(
					w,
					"headless",
					"inputs line %d: %q, want: gust <x km> <y km> <radius km > 0>",
					line_no,
					raw,
				)
				return false
			}
			slot := -1
			for z, i in w.gust_zones {
				if z.radius == 0 {
					slot = i
					break
				}
			}
			if slot < 0 {
				logf(w, "headless", "inputs line %d: already %d gust zones", line_no, MAX_GUST_ZONES)
				return false
			}
			w.gust_zones[slot] = {{x, y}, radius}
			fmt.sbprintfln(out, "gust %d: %.3f %.3f radius %.3f km", slot, x, y, radius)
		case "car":
			// car <x km> <y km> <alt m>: another car from the presence gossip, for the traffic jam cost.
			x, x_ok := strconv.parse_f32(f[1])
			y, y_ok := strconv.parse_f32(f[2])
			alt, alt_ok := strconv.parse_f32(f[3])
			if n != 4 || !x_ok || !y_ok || !alt_ok || !(abs(x) < 1e6 && abs(y) < 1e6 && abs(alt) < 1e5) {
				logf(w, "headless", "inputs line %d: %q, want: car <x km> <y km> <alt m>", line_no, raw)
				return false
			}
			if w.other_count == len(w.others) {
				logf(w, "headless", "inputs line %d: already %d cars", line_no, len(w.others))
				return false
			}
			w.others[w.other_count] = {
				pos = {x, y},
				alt = alt,
			}
			w.others[w.other_count].author[0] = u8(w.other_count)
			w.other_count += 1
			fmt.sbprintfln(out, "car %d: %.3f %.3f alt %.0f m", w.other_count - 1, x, y, alt)
		case "plan":
			// plan <from hub> <to hub> <hour>: the three routes of the plan screen with their summaries and
			// maneuvers, as nav.odin plans them.
			from, from_ok := strconv.parse_int(f[1], 10)
			to, to_ok := strconv.parse_int(f[2], 10)
			hour, hour_ok := strconv.parse_int(f[3], 10)
			if n != 4 ||
			   !from_ok ||
			   !to_ok ||
			   !hour_ok ||
			   from < 0 ||
			   from >= w.m.hub_count ||
			   to < 0 ||
			   to >= w.m.hub_count ||
			   hour < 0 ||
			   hour >= FORECAST_HOURS {
				logf(
					w,
					"headless",
					"inputs line %d: %q, want: plan <from hub> <to hub> <hour>",
					line_no,
					line,
				)
				return false
			}
			w.plan.from, w.plan.to, w.plan.hour = from, to, hour
			w.plan.has_from, w.plan.has_to = true, true
			plan_routes(w, from, to, hour)
			fmt.sbprintfln(out, "plan %s -> %s hour %d", hub_name(w, from), hub_name(w, to), hour)
			mode_names := ROUTE_MODE_NAMES
			for mode in Route_Mode {
				r := &w.routes[mode]
				if !r.ok {
					fmt.sbprintfln(out, "  %s: no safe route", mode_names[mode])
					continue
				}
				sm := &r.sum
				fmt.sbprintfln(
					out,
					"  %s: %.1f min, %.3f km, %.1f km/h, %.3f kWh net, %v, %s",
					mode_names[mode],
					sm.minutes,
					sm.km,
					sm.kmh,
					sm.net_kwh,
					sm.tag,
					cstr(sm.why[:]),
				)
				for &m in r.maneuvers {
					fmt.sbprintfln(
						out,
						"    %.3f km %v: %s / %s / %s",
						m.s_km,
						m.kind,
						cstr(m.text[:]),
						cstr(m.sub[:]),
						cstr(m.road[:]),
					)
				}
			}
		case "drive":
			// drive <x km> <y km> <seconds> <turn -1..1>: lands the ship on the road nearest (x, y), then drives at
			// full throttle with that turn input. Prints every edge it enters and where it ends.
			x, x_ok := strconv.parse_f32(f[1])
			y, y_ok := strconv.parse_f32(f[2])
			secs, secs_ok := strconv.parse_f32(f[3])
			turn, turn_ok := strconv.parse_f32(f[4])
			sane := x_ok && y_ok && secs_ok && turn_ok && abs(x) < 1e6 && abs(y) < 1e6
			if n != 5 || !sane || !(secs > 0 && secs < 1e5) || !(abs(turn) <= 1) {
				logf(
					w,
					"headless",
					"inputs line %d: %q, want: drive <x km> <y km> <seconds> <turn -1..1>",
					line_no,
					line,
				)
				return false
			}
			s := &w.ship
			s^ = {
				pos      = {x, y},
				alt      = height_at(w, x, y) + SHIP_MIN_CLEARANCE,
				used_kwh = s.used_kwh,
			}
			s.on_road = false
			road_try_land(w, {climb = -1})
			if !s.landing {
				near, near_s, near_ok := road_nearest_edge(w, {x, y}, 5)
				p: [2]f32
				if near_ok do p, _ = road_at(w, near, near_s)
				fmt.sbprintfln(
					out,
					"drive %.3f %.3f: no road within %.0f m (nearest within 5 km: %v at %.3f %.3f)",
					x,
					y,
					ROAD_LAND_KM * 1000,
					near_ok,
					p.x,
					p.y,
				)
				continue
			}
			fmt.sbprintfln(
				out,
				"drive from %.3f %.3f, landing on edge %d %v",
				x,
				y,
				s.road_edge,
				Map_Kind(w.m.road_edges[s.road_edge].kind),
			)
			last := s.road_edge
			landed := false
			for k in 0 ..< int(secs / SIM_DT) {
				ship_step(w, {throttle = 1, turn = turn}, SIM_DT)
				if s.on_road && !landed {
					landed = true
					fmt.sbprintfln(
						out,
						"  on the road after %.1f s at %.3f %.3f",
						f32(k + 1) * SIM_DT,
						s.pos.x,
						s.pos.y,
					)
				}
				if s.road_edge != last {
					last = s.road_edge
					e := w.m.road_edges[last]
					fmt.sbprintfln(
						out,
						"  edge %d %v oneway %d at %.3f %.3f",
						last,
						Map_Kind(e.kind),
						e.oneway,
						s.pos.x,
						s.pos.y,
					)
				}
			}
			fmt.sbprintfln(
				out,
				"  after %.0f s: %.3f %.3f, %.1f m/s, alt %.1f m, on road %v",
				secs,
				s.pos.x,
				s.pos.y,
				s.speed,
				s.alt,
				s.on_road,
			)
		case "fly":
			// fly <mode> <max seconds> [report gust after <seconds>]: navigation with the autopilot at 1x, fixed
			// steps, until docked or the time is up. Prints every new maneuver, reroute and the arrival.
			mode, mode_ok := Route_Mode(0), false
			for name, m in ROUTE_MODE_NAMES {
				if f[1] == name do mode, mode_ok = m, true
			}
			limit, limit_ok := strconv.parse_f32(f[2])
			gust_s, gust_ok := f32(-1), true
			if n == 4 do gust_s, gust_ok = strconv.parse_f32(f[3])
			if (n != 3 && n != 4) || !mode_ok || !limit_ok || !gust_ok || !(limit > 0 && limit < 1e5) {
				logf(
					w,
					"headless",
					"inputs line %d: %q, want: fly <fastest|greenest|calmest> <max s> [gust after s]",
					line_no,
					line,
				)
				return false
			}
			if !nav_start(w, mode) {
				fmt.sbprintfln(out, "fly %s: no route to fly", f[1])
				continue
			}
			nv := &w.nav
			fmt.sbprintfln(out, "fly %s from %s to %s", f[1], hub_name(w, nv.from), hub_name(w, nv.to))
			last_next, last_reroutes := -1, 0
			steps := int(limit / SIM_DT)
			for step in 0 ..< steps {
				secs := f32(step) * SIM_DT
				if gust_s >= 0 && secs >= gust_s {
					gust_s = -1
					ok := gust_report(w)
					fmt.sbprintfln(out, "  %.1f s: gust reported (%v)", secs, ok)
				}
				ship_step(w, nav_autopilot(w), SIM_DT)
				nav_update(w, SIM_DT)
				w.tick += 1
				r := nav_route(w)
				if nv.reroutes != last_reroutes {
					last_reroutes = nv.reroutes
					last_next = -1
					fmt.sbprintfln(
						out,
						"  %.1f s: reroute %d, %.3f km left, no route %v",
						secs,
						nv.reroutes,
						r.sum.km,
						nv.no_route,
					)
				}
				if nv.next != last_next && nv.next < len(r.maneuvers) {
					last_next = nv.next
					m := &r.maneuvers[nv.next]
					fmt.sbprintfln(out, "  %.1f s: next %s in %.0f m", secs, cstr(m.text[:]), nv.next_m)
				}
				if nv.banner == .Arrived {
					fmt.sbprintfln(
						out,
						"  %.1f s: arrived, docked %v, %.3f kWh net, %.3f kWh solar",
						secs,
						w.ship.docked,
						nv.used_kwh,
						nv.solar_kwh,
					)
					break
				}
			}
			if nv.banner != .Arrived {
				fmt.sbprintfln(out, "  not arrived after %.0f s, %.3f km left", limit, nv.remaining_km)
			}
			nav_stop(w)
		case:
			logf(w, "headless", "inputs line %d: unknown command %q", line_no, f[0])
			return false
		}
	}
	return true
}

// Called by the host and the release main with the command line after the program name:
//   --headless --snapshot <file> --inputs <file> [--dump]
//   --headless --node [--port <n>]   (peer to peer node only, runs until killed, see node_run)
// Prints the result (and with --dump the World after the last command) to stdout and timings to stderr. No window is opened.
@(export)
game_headless :: proc(args: []string) -> bool {
	USAGE ::
		"usage: drift --headless --snapshot <file> --inputs <file> [--dump]\n" +
		"       drift --headless --node [--port <n>]"
	snapshot_path, inputs_path: string
	dump, node: bool
	port := 0
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--headless":
		case "--dump":
			dump = true
		case "--node":
			node = true
		case "--port":
			ok: bool
			if i + 1 < len(args) do port, ok = strconv.parse_int(args[i + 1])
			if !ok || port < 1 || port > 65535 {
				fmt.eprintfln("[headless] --port needs a number in 1..65535\n%s", USAGE)
				return false
			}
			i += 1
		case "--snapshot", "--inputs":
			if i + 1 == len(args) {
				fmt.eprintfln("[headless] %s needs a file name\n%s", args[i], USAGE)
				return false
			}
			if args[i] == "--snapshot" do snapshot_path = args[i + 1]
			else do inputs_path = args[i + 1]
			i += 1
		case:
			fmt.eprintfln("[headless] unknown argument %q\n%s", args[i], USAGE)
			return false
		}
	}
	if node do return node_run(port)
	if snapshot_path == "" || inputs_path == "" {
		fmt.eprintln("[headless] missing --snapshot or --inputs\n" + USAGE)
		return false
	}

	w := (^World)(game_init())
	if w == nil do return false
	defer game_shutdown(w)
	context.allocator = virtual.arena_allocator(&w.perm)
	context.temp_allocator = virtual.arena_allocator(&w.frame)

	inputs, inputs_err := os.read_entire_file(inputs_path, context.allocator)
	if inputs_err != nil {
		logf(w, "headless", "cannot read inputs %s: %v", inputs_path, inputs_err)
		return false
	}

	out := strings.builder_make(context.allocator)
	ok := headless_run(w, snapshot_path, inputs, &out)
	if dump do dump_world(w, &out)
	fmt.print(strings.to_string(out))
	logf(
		w,
		"headless",
		"weather load %.3f ms, last route %.3f ms",
		w.prof.ms[.Weather_Load],
		w.prof.ms[.Route],
	)
	return ok
}

// One event per line on stderr: "[route t=1234] no path, 3 cells blocked". No allocation, long messages are cut.
logf :: proc(w: ^World, system: string, format: string, args: ..any) {
	buf: [1024]u8
	fmt.eprintfln("[%s t=%d] %s", system, w.tick, fmt.bprintf(buf[:], format, ..args))
}

// The World as text, for bug reports: F5 in the app, --dump in headless mode.
// Only deterministic values (no timings), so a dump can be diffed against another run.
dump_world :: proc(w: ^World, out: ^strings.Builder) {
	fmt.sbprintfln(
		out,
		"tick %d (%.2f s), accum %.4f s, build %s",
		w.tick,
		f64(w.tick) * SIM_DT,
		w.accum,
		BUILD_MODE,
	)
	fmt.sbprintfln(
		out,
		"map %d lines, %d points, %d cities, %d hubs",
		len(w.m.lines),
		len(w.m.points),
		len(w.m.cities),
		w.m.hub_count,
	)
	for &h, i in w.m.hubs[:w.m.hub_count] {
		fmt.sbprintfln(
			out,
			"  hub %d %.3f %.3f %s",
			i,
			h.pos.x,
			h.pos.y,
			strings.truncate_to_byte(string(h.name[:]), 0),
		)
	}

	fmt.sbprintf(out, "weather start %d, sha256 ", w.weather.start)
	for b in w.weather_hash do fmt.sbprintf(out, "%02x", b)
	fmt.sbprintfln(out, ", fetched at %d", w.fetch.fetched_at)
	for hour in 0 ..< FORECAST_HOURS {
		max_wind: [WIND_LAYERS]f32
		max_gust, cloud: f32
		for layer in 0 ..< WIND_LAYERS {
			for cell in 0 ..< WEATHER_CELLS {
				max_wind[layer] = max(max_wind[layer], linalg.length(w.weather.wind[hour][layer][cell]))
				max_gust = max(max_gust, w.weather.gust[hour][layer][cell])
			}
		}
		for c in w.weather.cloud[hour] do cloud += c
		fmt.sbprintfln(
			out,
			"  hour %d: max wind %.1f / %.1f / %.1f m/s, max gust %.2f, mean cloud %.2f",
			hour,
			max_wind[0],
			max_wind[1],
			max_wind[2],
			max_gust,
			cloud / WEATHER_CELLS,
		)
	}

	for z, i in w.no_fly {
		if z.radius == 0 do continue
		fmt.sbprintfln(
			out,
			"no_fly %d: %.3f %.3f radius %.3f km below %.0f m",
			i,
			z.center.x,
			z.center.y,
			z.radius,
			z.ceiling,
		)
	}
	for z, i in w.gust_zones {
		if z.radius == 0 do continue
		fmt.sbprintfln(out, "gust %d: %.3f %.3f radius %.3f km", i, z.center.x, z.center.y, z.radius)
	}
	if w.grid.terrain_built && w.grid.blocked_built {
		count: [GRID_LAYERS]int
		for n in 0 ..< GRID_NODES do count[n / GRID_LAYER_CELLS] += grid_blocked(&w.grid, Node(n)) ? 1 : 0
		changed := w.grid.blocked_zones != w.no_fly || w.grid.blocked_gusts != w.gust_zones
		fmt.sbprintfln(
			out,
			"blocked nodes per layer %v of %d%s",
			count,
			GRID_LAYER_CELLS,
			changed ? ", zones changed since, rebuilt by the next route" : "",
		)
	} else {
		fmt.sbprintln(out, "blocked set not built yet, the next route builds it")
	}
	fmt.sbprintfln(out, "last route expanded %d of %d nodes", w.grid.expanded_len, GRID_NODES)

	fmt.sbprintfln(
		out,
		"arenas perm %d / %d, route %d / %d, frame %d / %d bytes (used / reserved)",
		w.perm.total_used,
		w.perm.total_reserved,
		w.route_mem.total_used,
		w.route_mem.total_reserved,
		w.frame.total_used,
		w.frame.total_reserved,
	)
}
