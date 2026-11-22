package game

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:mem/virtual"
import "core:os"
import "core:prof/spall"
import "core:reflect"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import rl "vendor:raylib"

// Timing is compiled in for debug and profile builds only. Wall-clock time is fine here,
// it is only displayed and never fed back into the simulation. Zones go in game and render code only:
// simulation code (route, ship, road, terrain, weather) is timed at its call sites, and the per-step procs the
// bench measures (ship_step, road_nearest_edge, wind_at) get no zone, two clock reads would double their cost.
// Times are CPU time on the frame thread: GPU work shows up later, in Swap (EndDrawing waits for it).
PROFILING :: DRIFT_DEBUG || DRIFT_PROFILE
PROF_FRAMES :: 120
PROF_DEPTH :: 32
PROF_TOP :: 14 // zones listed in the overlay
// Spall flushes the buffer to the file when it is full: 64 KB is a few frames, small enough for the perm arena.
PROF_TRACE_BYTES :: 64 << 10
PROF_TRACE_PATH :: "drift.spall"
FRAME_BUDGET_MS :: 4

// One per system worth watching. Nested zones are fine: excl is a zone's own time, its children taken out.
Prof_Zone :: enum u8 {
	Update, // game_update up to BeginDrawing
	Draw, // BeginDrawing to the profiler overlay
	Swap, // EndDrawing: buffer swap, waiting for the GPU, vsync and the SetTargetFPS wait
	Init,
	Load_Map,
	Weather_Load,
	Font_Load,
	Buildings_Build,
	Airship_Build,
	Clouds_Build,
	Poll,
	Sim_Steps,
	Cam_Update,
	Route,
	Street_Draw,
	Street_Build,
	Street_Camera,
	Street_Shadow,
	Street_Hud,
	Tile_Build,
	Trees_Draw,
	Trees_Build_Tile,
	Collide_Car,
	Post,
	Map_Mesh_Build,
	Wind,
	Globe,
	Areas,
	Hill,
	Ground_Layers,
	Scan,
	Map_Lines,
	Buildings_Draw,
	Towns_Draw,
	Nature_Draw,
	Routes,
	Others,
	Airship_Draw,
	Clouds_Draw,
	Hub_Markers,
	Labels,
	Plan_Ui,
	Map_Controls,
	Nav_Ui,
	Pilot_Ui,
	Ui_Text,
	Ui_Shadow,
}

// Zero is valid: nothing measured yet, overlay hidden (F3 or the layers panel shows it), no trace.
Profiler :: struct {
	last_ms:     [Prof_Zone]f32, // the last call of each zone, for the ones that do not run every frame
	// This frame so far, moved into the rings by prof_frame_end.
	incl:        [Prof_Zone]time.Duration,
	excl:        [Prof_Zone]time.Duration,
	calls:       [Prof_Zone]u32,
	child:       [PROF_DEPTH]time.Duration, // time spent in the children of each open zone
	depth:       int,
	// The last PROF_FRAMES frames, head is the oldest.
	ring_incl:   [PROF_FRAMES][Prof_Zone]f32, // ms
	ring_excl:   [PROF_FRAMES][Prof_Zone]f32, // ms
	ring_calls:  [PROF_FRAMES][Prof_Zone]u32,
	interval:    [PROF_FRAMES]f32, // ms from one frame start to the next: the real frame time
	frame_used:  [PROF_FRAMES]uint, // frame arena bytes
	head:        int,
	frames:      u64, // frames finished since game_init
	last_end:    time.Tick, // the previous prof_frame_end
	init_start:  time.Tick,
	shown:       bool,
	// Spall trace (F4, or the script's profile command). trace_mem is from the perm arena (game_init).
	trace_on:    bool,
	trace_ctx:   spall.Context,
	trace_buf:   spall.Buffer,
	trace_mem:   []u8,
	// The script's profile range: sums over its frames, written as CSV when it ends.
	range_on:    bool,
	range_from:  int,
	range_path:  string, // file prefix, into the script text (perm arena)
	range_n:     int, // frames so far
	range_incl:  [Prof_Zone]f64, // ms
	range_excl:  [Prof_Zone]f64,
	range_calls: [Prof_Zone]u64,
	range_peak:  [Prof_Zone]f32, // the largest incl ms in one frame
	range_frame: [3]f64, // update + draw ms: sum, worst, frames over FRAME_BUDGET_MS
}

// Times the rest of the enclosing scope: prof_zone(w, .Trees_Draw) as the first line of a proc or block.
@(deferred_in_out = prof_end)
prof_zone :: proc(w: ^World, zone: Prof_Zone) -> time.Tick {
	return prof_begin(w, zone)
}

// The pair behind prof_zone, for a span that is not a scope (Update and Draw in game_update).
prof_begin :: proc(w: ^World, zone: Prof_Zone) -> time.Tick {
	when PROFILING {
		p := &w.prof
		if p.depth < PROF_DEPTH do p.child[p.depth] = 0
		p.depth += 1
		if p.trace_on do spall._buffer_begin(&p.trace_ctx, &p.trace_buf, reflect.enum_string(zone))
		return time.tick_now()
	} else {
		return {}
	}
}

prof_end :: proc(w: ^World, zone: Prof_Zone, start: time.Tick) {
	when PROFILING {
		d := time.tick_since(start)
		p := &w.prof
		if p.trace_on do spall._buffer_end(&p.trace_ctx, &p.trace_buf)
		p.depth -= 1
		own := d
		if p.depth < PROF_DEPTH do own -= p.child[p.depth]
		if p.depth > 0 && p.depth <= PROF_DEPTH do p.child[p.depth - 1] += d
		p.incl[zone] += d
		p.excl[zone] += own
		p.calls[zone] += 1
		p.last_ms[zone] = f32(time.duration_milliseconds(d))
	}
}

// Zones in order of their value, largest first.
prof_sorted :: proc(v: [Prof_Zone]f64) -> (order: [len(Prof_Zone)]Prof_Zone) {
	for z, i in Prof_Zone {
		j := i
		for j > 0 && v[order[j - 1]] < v[z] {
			order[j] = order[j - 1]
			j -= 1
		}
		order[j] = z
	}
	return
}

prof_trace_start :: proc(w: ^World, path: string) {
	when PROFILING {
		p := &w.prof
		if p.trace_on || len(p.trace_mem) == 0 do return
		ctx, ok := spall.context_create_with_scale(path, false, 1)
		if !ok {
			logf(w, "prof", "cannot create trace file %s", path)
			return
		}
		p.trace_ctx = ctx
		p.trace_buf = spall.buffer_create(p.trace_mem)
		p.trace_on = true
		logf(w, "prof", "trace recording to %s", path)
	}
}

prof_trace_stop :: proc(w: ^World) {
	when PROFILING {
		p := &w.prof
		if !p.trace_on do return
		spall.buffer_destroy(&p.trace_ctx, &p.trace_buf)
		spall.context_destroy(&p.trace_ctx)
		p.trace_on = false
		logf(w, "prof", "trace stopped, open it in https://gravitymoth.com/spall")
	}
}

// After EndDrawing, with no zone open: this frame goes into the rings, the script's profile ranges start and
// end, F4 starts and stops a trace. The first frame logs where the start-up time went.
prof_frame_end :: proc(w: ^World) {
	when PROFILING {
		p := &w.prof
		ms :: proc(d: time.Duration) -> f32 {return f32(time.duration_milliseconds(d))}
		if p.frames == 0 {
			b := strings.builder_make(context.temp_allocator)
			for z in Prof_Zone {
				if ms(p.incl[z]) >= 0.1 do fmt.sbprintf(&b, "%s%v %.1f", len(b.buf) > 0 ? ", " : "", z, ms(p.incl[z]))
			}
			logf(
				w,
				"prof",
				"first frame done %.1f ms after game_init started, ms per zone: %s",
				ms(time.tick_since(p.init_start)),
				strings.to_string(b),
			)
		}
		h := p.head
		now := time.tick_now()
		if p.last_end != {} do p.interval[h] = ms(time.tick_diff(p.last_end, now))
		p.last_end = now
		for z in Prof_Zone {
			p.ring_incl[h][z] = ms(p.incl[z])
			p.ring_excl[h][z] = ms(p.excl[z])
			p.ring_calls[h][z] = p.calls[z]
		}
		p.frame_used[h] = w.frame.total_used
		if p.range_on {
			for z in Prof_Zone {
				p.range_incl[z] += f64(p.ring_incl[h][z])
				p.range_excl[z] += f64(p.ring_excl[h][z])
				p.range_calls[z] += u64(p.calls[z])
				p.range_peak[z] = max(p.range_peak[z], p.ring_incl[h][z])
			}
			frame := f64(p.ring_incl[h][.Update] + p.ring_incl[h][.Draw])
			p.range_frame += {frame, 0, frame > FRAME_BUDGET_MS ? 1 : 0}
			p.range_frame[1] = max(p.range_frame[1], frame)
			p.range_n += 1
		}
		p.incl, p.excl, p.calls = {}, {}, {}
		p.head = (h + 1) % PROF_FRAMES
		p.frames += 1

		if key_pressed(w, .F4) {
			if p.trace_on do prof_trace_stop(w)
			else do prof_trace_start(w, PROF_TRACE_PATH)
		}

		// script_end has counted the frame that just ended.
		sc := &w.script
		if !sc.on do return
		done := sc.frame - 1
		for e in sc.events {
			if e.kind != .Profile do continue
			if p.range_on && done == int(e.v.x) && p.range_from == e.frame {
				p.range_on = false
				prof_trace_stop(w)
				b := strings.builder_make(context.temp_allocator)
				fmt.sbprintln(&b, "zone,calls_per_frame,incl_ms_per_frame,excl_ms_per_frame,peak_ms")
				n := f64(p.range_n)
				for z in prof_sorted(p.range_excl) {
					if p.range_calls[z] == 0 do continue
					fmt.sbprintfln(
						&b,
						"%v,%.3f,%.4f,%.4f,%.3f",
						z,
						f64(p.range_calls[z]) / n,
						p.range_incl[z] / n,
						p.range_excl[z] / n,
						p.range_peak[z],
					)
				}
				csv := strings.concatenate({p.range_path, ".csv"}, context.temp_allocator)
				if err := os.write_entire_file(csv, b.buf[:]); err != nil {
					logf(w, "prof", "cannot write %s: %v", csv, err)
					sc.failures += 1
				}
				logf(
					w,
					"prof",
					"frames %d..%d: update + draw %.2f ms mean, %.2f worst, %d of %d over %d ms, zones in %s",
					e.frame,
					done,
					p.range_frame[0] / n,
					p.range_frame[1],
					int(p.range_frame[2]),
					p.range_n,
					FRAME_BUDGET_MS,
					csv,
				)
			}
			if done + 1 == e.frame {
				if p.range_on || p.trace_on {
					logf(
						w,
						"prof",
						"profile range at frame %d skipped: another range or trace is running",
						e.frame,
					)
					continue
				}
				p.range_on, p.range_from, p.range_path, p.range_n = true, e.frame, e.path, 0
				p.range_incl, p.range_excl, p.range_calls, p.range_peak, p.range_frame = {}, {}, {}, {}, {}
				prof_trace_start(w, strings.concatenate({e.path, ".spall"}, context.temp_allocator))
			}
		}
	}
}

// F3 or the Profiler toggle in the layers panel. Shows the frames before this one and is not timed itself.
prof_overlay :: proc(w: ^World) {
	when PROFILING {
		p := &w.prof
		if key_pressed(w, .F3) do p.shown = !p.shown
		if !p.shown do return
		LINE :: 12
		GRAPH_H :: 64
		W :: 380
		H :: 6 + 6 * LINE + 6 + GRAPH_H + 8 + (PROF_TOP + 1) * LINE + 6
		x0 := i32(w.cam.screen.x) - W - 16 - 88 // left of the map controls column
		y0 := i32(w.cam.screen.y) - 38 - H
		rl.DrawRectangle(x0, y0, W, H, {0, 0, 0, 190})

		frames: [PROF_FRAMES]f32
		mean_incl, mean_excl, worst_incl: [Prof_Zone]f64
		mean_calls: [Prof_Zone]f32
		swap, interval, peak_used: f32
		over := 0
		for i in 0 ..< PROF_FRAMES {
			r := p.ring_incl[i]
			frames[i] = r[.Update] + r[.Draw]
			if frames[i] > FRAME_BUDGET_MS do over += 1
			for z in Prof_Zone {
				mean_incl[z] += f64(r[z]) / PROF_FRAMES
				mean_excl[z] += f64(p.ring_excl[i][z]) / PROF_FRAMES
				worst_incl[z] = max(worst_incl[z], f64(r[z]))
				mean_calls[z] += f32(p.ring_calls[i][z]) / PROF_FRAMES
			}
			swap += r[.Swap] / PROF_FRAMES
			interval += p.interval[i] / PROF_FRAMES
			peak_used = max(peak_used, f32(p.frame_used[i]))
		}
		last := p.ring_incl[(p.head + PROF_FRAMES - 1) % PROF_FRAMES]
		sorted := frames
		slice.sort(sorted[:])
		MB :: f32(1 << 20)
		lines := [6]cstring {
			fmt.ctprintf(
				"frame %.2f ms (update %.2f, draw %.2f), budget %d ms",
				last[.Update] + last[.Draw],
				last[.Update],
				last[.Draw],
				FRAME_BUDGET_MS,
			),
			fmt.ctprintf(
				"%d frames: p50 %.2f, p99 %.2f, worst %.2f ms, %d over budget",
				PROF_FRAMES,
				sorted[PROF_FRAMES / 2],
				sorted[PROF_FRAMES * 99 / 100],
				sorted[PROF_FRAMES - 1],
				over,
			),
			fmt.ctprintf(
				"swap %.2f ms (GPU, vsync, fps cap), real frame %.2f ms = %.0f fps",
				swap,
				interval,
				interval > 0 ? 1000 / interval : 0,
			),
			fmt.ctprintf(
				"last route %.2f ms, weather load %.2f ms",
				p.last_ms[.Route],
				p.last_ms[.Weather_Load],
			),
			fmt.ctprintf(
				"perm %.2f / %.2f MB, route %.2f / %.2f MB, frame peak %.1f KB",
				f32(w.perm.total_used) / MB,
				f32(w.perm.total_reserved) / MB,
				f32(w.route_mem.total_used) / MB,
				f32(w.route_mem.total_reserved) / MB,
				peak_used / 1024,
			),
			p.trace_on ? "F4: stop the spall trace (recording)" : "F4: record a spall trace to " + PROF_TRACE_PATH,
		}
		y := y0 + 6
		for line, i in lines {
			rl.DrawText(line, x0 + 6, y, 10, i == 5 && p.trace_on ? rl.RED : rl.RAYWHITE)
			y += LINE
		}

		// 3 px per frame, oldest on the left, 4 px per ms (a 60 fps frame fills it): update green, draw blue, swap grey on top. Red under
		// the bar: over budget. A bar cut at the top gets a white cap.
		{
			y += 6
			base := y + GRAPH_H
			PX_PER_MS :: 4
			rl.DrawLine(
				x0 + 6,
				base - FRAME_BUDGET_MS * PX_PER_MS,
				x0 + 6 + PROF_FRAMES * 3,
				base - FRAME_BUDGET_MS * PX_PER_MS,
				rl.YELLOW,
			)
			for i in 0 ..< PROF_FRAMES {
				r := p.ring_incl[(p.head + i) % PROF_FRAMES]
				x := x0 + 6 + i32(i) * 3
				top := base
				parts := [3]struct {
					ms:    f32,
					color: rl.Color,
				}{{r[.Update], rl.GREEN}, {r[.Draw], rl.SKYBLUE}, {r[.Swap], rl.GRAY}}
				for part in parts {
					h := min(i32(part.ms * PX_PER_MS + 0.5), top - (base - GRAPH_H))
					rl.DrawRectangle(x, top - h, 2, h, part.color)
					top -= h
				}
				if top <= base - GRAPH_H do rl.DrawRectangle(x, base - GRAPH_H, 2, 1, rl.WHITE)
				if r[.Update] + r[.Draw] > FRAME_BUDGET_MS do rl.DrawRectangle(x, base + 1, 2, 2, rl.RED)
			}
			y = base + 8
		}

		// The zones with the most own time (excl) over the window. Update, Draw and Swap are in the lines above.
		cols := [5]i32{x0 + 6, x0 + 150, x0 + 200, x0 + 260, x0 + 320}
		head := [5]cstring{"zone, mean per frame", "calls", "self ms", "total ms", "max ms"}
		for c, i in head do rl.DrawText(c, cols[i], y, 10, rl.YELLOW)
		y += LINE
		shown := 0
		for z in prof_sorted(mean_excl) {
			if shown == PROF_TOP do break
			if z == .Update || z == .Draw || z == .Swap || mean_calls[z] == 0 do continue
			row := [5]cstring {
				fmt.ctprintf("%v", z),
				fmt.ctprintf("%.1f", mean_calls[z]),
				fmt.ctprintf("%.3f", mean_excl[z]),
				fmt.ctprintf("%.3f", mean_incl[z]),
				fmt.ctprintf("%.2f", worst_incl[z]),
			}
			for c, i in row do rl.DrawText(c, cols[i], y, 10, rl.RAYWHITE)
			y += LINE
			shown += 1
		}
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
//   free <x km> <y km> <height m> <heading deg> <throttle> <turn> <climb> <seconds>
//                                                  free flight (the street view's, ship_free_step) from rest
//   free_on <throttle> <turn> <climb> <seconds>    free flight on from where the last one ended
headless_run :: proc(w: ^World, snapshot_path: string, inputs: []u8, out: ^strings.Builder) -> bool {
	weather_ok := weather_load_snapshot(w, snapshot_path)
	if !weather_ok do return false
	fmt.sbprintfln(out, "weather start %d", w.weather.start)

	text := string(inputs)
	line_no := 0
	for raw in strings.split_lines_iterator(&text) {
		line_no += 1
		line := strings.trim_space(raw)
		if line == "" || line[0] == '#' do continue

		f: [10]string
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
			t := prof_begin(w, .Route)
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
		case "free", "free_on":
			// The car at rest at height m above the ground (free), or as the last free command left it
			// (free_on), then fixed controls for the given seconds at SIM_DT. Prints where it ends, its speed,
			// the wall hits and how many steps its centre was inside a building footprint (must be 0).
			s := &w.ship
			k := f[0] == "free" ? 5 : 1
			v: [8]f32
			sane := n == k + 4
			for i in 0 ..< n - 1 {
				ok: bool
				v[i], ok = strconv.parse_f32(f[i + 1])
				sane &&= ok && abs(v[i]) < 1e6
			}
			c := Controls{v[k - 1], v[k], v[k + 1]}
			secs := v[k + 2]
			sane &&= abs(c.throttle) <= 1 && abs(c.turn) <= 1 && abs(c.climb) <= 1 && secs > 0 && secs < 1e5
			if f[0] == "free" {
				sane &&= v[0] >= 0 && v[1] >= 0 && v[0] <= MAP_W_KM && v[1] <= MAP_H_KM && v[2] >= 0
			}
			if !sane {
				logf(
					w,
					"headless",
					"inputs line %d: %q, want: free <x km> <y km> <height m> <heading deg> <throttle> <turn> " +
					"<climb> <seconds> or free_on <throttle> <turn> <climb> <seconds>",
					line_no,
					line,
				)
				return false
			}
			if f[0] == "free" {
				s^ = {
					pos       = {v[0], v[1]},
					alt       = height_at(w, v[0], v[1]) + v[2],
					heading   = v[3] * math.PI / 180,
					used_kwh  = s.used_kwh,
					solar_kwh = s.solar_kwh,
				}
			}
			hits, inside := 0, 0
			top: f32
			for _ in 0 ..< int(secs / SIM_DT + 0.5) {
				before := s.hit_s
				ship_free_step(w, c, SIM_DT)
				w.tick += 1
				if s.hit_s < before do hits += 1
				hag := s.alt - height_at(w, s.pos.x, s.pos.y)
				if push, _ := collide_car(w, s.pos, hag, 0.01); push != {} do inside += 1
				top = max(top, s.speed)
			}
			fmt.sbprintfln(
				out,
				"%s: after %.2f s at %.5f %.5f, height %.2f m%s, %.1f km/h (top %.1f), heading %.1f deg, %d wall hits, inside %d steps",
				f[0],
				secs,
				s.pos.x,
				s.pos.y,
				s.alt - height_at(w, s.pos.x, s.pos.y),
				s.driving ? " on its wheels" : "",
				s.speed * 3.6,
				top * 3.6,
				s.heading * 180 / math.PI,
				hits,
				inside,
			)
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
		w.prof.last_ms[.Weather_Load],
		w.prof.last_ms[.Route],
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

// Scripted run (--script <file>): the real window and drawing, driven by a text file with one command per line,
// so a change to the picture is checked with screenshots instead of by hand. Every frame stands for exactly
// SIM_DT and steps the simulation once, keys and mouse come only from the script (input.odin), and the weather
// comes from a file, not the network, so the same script gives the same screenshots. # starts a comment.
//   snapshot <file>                  weather snapshot (net.odin format), default the embedded fallback
//   frame_ms <ms> [<ms> ...]         frame times to repeat (up to 8) instead of SIM_DT: uneven frames, as on a
//                                    real screen, so a frame steps the simulation 0, 1 or 2 times
//   ship <frame> <x km> <y km> <height above ground m> <heading deg>   the car there, at rest
//   down <frame> <KEY>   up <frame> <KEY>   press <frame> <KEY>    raylib key names: W, SPACE, LEFT_SHIFT, V
//   mouse <frame> <dx px> <dy px>    wheel <frame> <notches>
//   shot <frame> <png file>          after everything of that frame is drawn
//   flicker <from> <to> <max %>      share of pixels that flicker over these frames: a pixel that jumps away in
//                                    one frame and back in the next (A-B-A, by more than 60 summed over r, g, b),
//                                    which smooth motion never does; logs FAILED above max %. Use it with
//                                    sub-pixel motion (mouse 0.05 per frame): thin details that move a few
//                                    pixels per frame jump A-B-A without any flicker
//   judder <from> <to> <max px>      how far the car jumps on the screen from one frame to the next beyond its
//                                    smooth motion (the largest second difference of its screen position); the
//                                    chase camera keeps it nearly still unless frames and steps do not line up
//   profile <from> <to> <prefix>     profiler zones over these frames (debug and profile builds, from >= 1):
//                                    a spall trace in <prefix>.spall and the mean per frame of every zone in
//                                    <prefix>.csv (calls, incl ms, excl ms, peak ms), plus one log line
//   quit <frame>
// Frame 0 is the first frame. The window keeps its size (1440 x 900):
// SetWindowSize on a macOS Retina screen leaves raylib drawing into a quarter of the framebuffer.
Script_Kind :: enum u8 {
	Down,
	Up,
	Mouse,
	Wheel,
	Ship,
	Shot,
	Flicker,
	Judder,
	Profile,
	Quit,
}

Script_Event :: struct {
	frame: int,
	kind:  Script_Kind,
	key:   rl.KeyboardKey,
	v:     [4]f32,
	path:  string, // into the script text, perm arena
}

Script :: struct {
	on:       bool,
	frame:    int,
	events:   []Script_Event, // perm arena, in frame order
	next:     int, // first event after this frame
	first:    int, // first event of this frame
	down:     #sparse[rl.KeyboardKey]bool,
	was:      #sparse[rl.KeyboardKey]bool,
	mouse:    [2]f32, // this frame's mouse move, px
	wheel:    f32,
	failures: int, // shots that could not be written
	frame_ms: [8]f32, // frame_ms pattern, zero = every frame SIM_DT
	frame_n:  int,
	// flicker: the last three frames (perm arena, 4 bytes per pixel) and the count so far
	fl:       [3][]u8,
	fl_size:  [2]i32,
	fl_seen:  int, // frames captured in the current flicker range
	fl_hits:  int,
	fl_total: int,
	// judder: the car's last two screen positions and the largest jump so far
	jd:       [2][2]f32,
	jd_seen:  int,
	jd_max:   f32,
}

// Reads and checks the whole script before the first frame: a bad line stops the run with its line number.
@(export)
game_script :: proc(memory: rawptr, path: string) -> bool {
	w := (^World)(memory)
	context.allocator = virtual.arena_allocator(&w.perm)
	context.temp_allocator = virtual.arena_allocator(&w.frame)
	defer virtual.arena_free_all(&w.frame)
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		logf(w, "script", "cannot read %s: %v", path, err)
		return false
	}
	events := make([dynamic]Script_Event, 0, 64)
	snapshot := ""
	frame_ms: [8]f32
	frame_n := 0
	text := string(data)
	line_no := 0
	for raw in strings.split_lines_iterator(&text) {
		line_no += 1
		line := strings.trim_space(raw)
		if line == "" || line[0] == '#' do continue
		f: [10]string
		n := 0
		for field in strings.fields_iterator(&line) {
			if n == len(f) {
				n += 1
				break
			}
			f[n] = field
			n += 1
		}
		num :: proc(s: string) -> (f32, bool) {
			v, ok := strconv.parse_f32(s)
			return v, ok && abs(v) < 1e7
		}
		frame, frame_ok := strconv.parse_int(f[1], 10)
		frame_ok &&= frame >= 0
		e := Script_Event {
			frame = frame,
		}
		ok := false
		switch f[0] {
		case "snapshot":
			snapshot, ok = f[1], n == 2
		case "frame_ms":
			ok = n >= 2 && n <= 9
			for i in 1 ..< min(n, 9) {
				v, v_ok := num(f[i])
				ok &&= v_ok && v > 0 && v < 250
				frame_ms[i - 1] = v
			}
			frame_n = n - 1
		case "down", "up", "press":
			key, key_ok := reflect.enum_from_name(rl.KeyboardKey, f[2])
			ok = n == 3 && frame_ok && key_ok && key != .KEY_NULL
			e.key = key
			e.kind = f[0] == "up" ? .Up : .Down
			if ok && f[0] == "press" {
				append(&events, e)
				e.frame += 1
				e.kind = .Up
			}
		case "mouse":
			x, x_ok := num(f[2])
			y, y_ok := num(f[3])
			e.kind, e.v.xy = .Mouse, {x, y}
			ok = n == 4 && frame_ok && x_ok && y_ok
		case "wheel":
			x, x_ok := num(f[2])
			e.kind, e.v.x = .Wheel, x
			ok = n == 3 && frame_ok && x_ok
		case "ship":
			x, x_ok := num(f[2])
			y, y_ok := num(f[3])
			h, h_ok := num(f[4])
			deg, deg_ok := num(f[5])
			e.kind, e.v = .Ship, {x, y, h, deg}
			on_map := x >= 0 && y >= 0 && x <= MAP_W_KM && y <= MAP_H_KM && h >= 0 && h <= SHIP_CEILING
			ok = n == 6 && frame_ok && x_ok && y_ok && h_ok && deg_ok && on_map
		case "shot":
			e.kind, e.path = .Shot, f[2]
			ok = n == 3 && frame_ok && strings.has_suffix(f[2], ".png")
		case "flicker":
			to, to_ok := strconv.parse_int(f[2], 10)
			budget, budget_ok := num(f[3])
			e.kind, e.v = .Flicker, {f32(to), budget, 0, 0}
			ok = n == 4 && frame_ok && to_ok && to >= frame + 2 && budget_ok && budget >= 0
		case "judder":
			to, to_ok := strconv.parse_int(f[2], 10)
			budget, budget_ok := num(f[3])
			e.kind, e.v = .Judder, {f32(to), budget, 0, 0}
			ok = n == 4 && frame_ok && to_ok && to >= frame + 2 && budget_ok && budget >= 0
		case "profile":
			to, to_ok := strconv.parse_int(f[2], 10)
			e.kind, e.v.x, e.path = .Profile, f32(to), f[3]
			ok = n == 4 && frame_ok && frame >= 1 && to_ok && to >= frame
			if ok && !PROFILING {
				logf(w, "script", "%s line %d: profile needs a debug or profile build", path, line_no)
				return false
			}
		case "quit":
			e.kind = .Quit
			ok = n == 2 && frame_ok
		}
		if !ok {
			logf(w, "script", "%s line %d: %q is not a valid command (see debug.odin)", path, line_no, line)
			return false
		}
		if f[0] != "snapshot" && f[0] != "frame_ms" do append(&events, e)
	}
	slice.stable_sort_by(events[:], proc(a, b: Script_Event) -> bool {return a.frame < b.frame})
	quits := false
	for e in events do quits ||= e.kind == .Quit
	if !quits {
		logf(w, "script", "%s has no quit command", path)
		return false
	}
	weather_ok := snapshot != "" ? weather_load_snapshot(w, snapshot) : weather_load_fallback(w)
	if !weather_ok {
		logf(w, "script", "weather snapshot %q does not load", snapshot)
		return false
	}
	w.script = {
		on       = true,
		events   = events[:],
		frame_ms = frame_ms,
		frame_n  = frame_n,
	}
	logf(w, "script", "%s: %d events, last frame %d", path, len(events), events[len(events) - 1].frame)
	return true
}

// Start of a scripted frame: key, mouse and ship commands of this frame.
script_frame :: proc(w: ^World) {
	sc := &w.script
	sc.was = sc.down
	sc.mouse, sc.wheel = {}, 0
	sc.first = sc.next
	for sc.next < len(sc.events) && sc.events[sc.next].frame <= sc.frame {
		e := sc.events[sc.next]
		sc.next += 1
		switch e.kind {
		case .Down:
			sc.down[e.key] = true
		case .Up:
			sc.down[e.key] = false
		case .Mouse:
			sc.mouse += e.v.xy
		case .Wheel:
			sc.wheel += e.v.x
		case .Ship:
			s := &w.ship
			s^ = {
				pos       = e.v.xy,
				alt       = height_at(w, e.v.x, e.v.y) + e.v.z,
				heading   = e.v.w * math.PI / 180,
				used_kwh  = s.used_kwh,
				solar_kwh = s.solar_kwh,
			}
			w.pose_prev = ship_pose(s)
			w.car_anim.seeded = false
			w.street.seeded = false
		case .Shot, .Flicker, .Judder, .Profile, .Quit:
		}
	}
}

// End of a scripted frame, after all drawing and before EndDrawing: screenshots and flicker counts, then true on
// the quit frame.
script_end :: proc(w: ^World) -> (quit: bool) {
	sc := &w.script
	// A flicker range that started earlier and has not ended: this frame counts.
	for e in sc.events[:sc.first] {
		if e.kind == .Flicker && sc.frame <= int(e.v.x) do script_flicker(w, e)
		if e.kind == .Judder && sc.frame <= int(e.v.x) do script_judder(w, e)
	}
	for e in sc.events[sc.first:sc.next] {
		switch e.kind {
		case .Shot:
			// raylib batches 2D drawing: flush it, so the shot holds everything drawn this frame.
			rl.EndScissorMode()
			dir := os.dir(e.path)
			if dir != "" && dir != "." do _ = os.make_directory_all(dir)
			img := rl.LoadImageFromScreen()
			ok := rl.ExportImage(img, strings.clone_to_cstring(e.path, context.temp_allocator))
			if !ok do sc.failures += 1
			// The mean and worst update + draw ms of the last PROF_FRAMES frames (0 in a release build).
			mean, worst: f32
			for r in w.prof.ring_incl {
				mean += (r[.Update] + r[.Draw]) / PROF_FRAMES
				worst = max(worst, r[.Update] + r[.Draw])
			}
			logf(
				w,
				"script",
				"frame %d: shot %s %dx%d %s(frames %.2f ms mean, %.2f worst)",
				sc.frame,
				e.path,
				img.width,
				img.height,
				ok ? "" : "FAILED ",
				mean,
				worst,
			)
			rl.UnloadImage(img)
		case .Flicker:
			sc.fl_seen, sc.fl_hits, sc.fl_total = 0, 0, 0
			script_flicker(w, e)
		case .Judder:
			sc.jd_seen, sc.jd_max = 0, 0
			script_judder(w, e)
		case .Quit:
			quit = true
			logf(w, "script", "frame %d: quit, %d shots or checks failed", sc.frame, sc.failures)
		case .Down, .Up, .Mouse, .Wheel, .Ship, .Profile:
		}
	}
	sc.frame += 1
	return quit
}

// One frame of a flicker range e (from e.frame to e.v.x): keeps the last three frames and counts the pixels of the
// middle one that differ from both neighbours in the same direction.
script_flicker :: proc(w: ^World, e: Script_Event) {
	sc := &w.script
	rl.EndScissorMode() // flush raylib's batch, as for a shot
	img := rl.LoadImageFromScreen()
	defer rl.UnloadImage(img)
	size := [2]i32{img.width, img.height}
	bytes := int(size.x) * int(size.y) * 4
	if img.format != .UNCOMPRESSED_R8G8B8A8 || bytes == 0 do return
	if sc.fl_size != size {
		for &f in sc.fl do f = make([]u8, bytes, virtual.arena_allocator(&w.perm))
		sc.fl_size = size
		sc.fl_seen = 0
	}
	sc.fl[0], sc.fl[1], sc.fl[2] = sc.fl[1], sc.fl[2], sc.fl[0]
	copy(sc.fl[2], ([^]u8)(img.data)[:bytes])
	sc.fl_seen += 1
	if sc.fl_seen >= 3 {
		a, b, c := sc.fl[0], sc.fl[1], sc.fl[2]
		for i := 0; i < bytes; i += 4 {
			up, down := 0, 0
			for k in i ..< i + 3 {
				d0 := int(b[k]) - int(a[k])
				d1 := int(b[k]) - int(c[k])
				if d0 > 20 && d1 > 20 do up += min(d0, d1)
				if d0 < -20 && d1 < -20 do down += min(-d0, -d1)
			}
			if up > 60 || down > 60 do sc.fl_hits += 1
		}
		sc.fl_total += bytes / 4
	}
	if sc.frame == int(e.v.x) {
		pct := 100 * f64(sc.fl_hits) / f64(max(sc.fl_total, 1))
		over := pct > f64(e.v.y)
		if over do sc.failures += 1
		logf(
			w,
			"script",
			"frames %d..%d: %.4f %% of the pixels flicker (max %.4f %%) %s",
			e.frame,
			sc.frame,
			pct,
			e.v.y,
			over ? "FAILED" : "ok",
		)
	}
}

// One frame of a judder range e: the car's screen position (street view) against the last two.
script_judder :: proc(w: ^World, e: Script_Event) {
	sc := &w.script
	if !w.street.on do return
	p := rl.GetWorldToScreen(street_ship_pos(w) + {0, 0.8, 0}, w.street.view)
	if sc.jd_seen >= 2 do sc.jd_max = max(sc.jd_max, linalg.length(p - 2 * sc.jd[1] + sc.jd[0]))
	sc.jd[0], sc.jd[1] = sc.jd[1], p
	sc.jd_seen += 1
	if sc.frame == int(e.v.x) {
		over := sc.jd_max > e.v.y
		if over do sc.failures += 1
		logf(
			w,
			"script",
			"frames %d..%d: the car jumps up to %.2f px beyond its motion (max %.2f) %s",
			e.frame,
			sc.frame,
			sc.jd_max,
			e.v.y,
			over ? "FAILED" : "ok",
		)
	}
}
