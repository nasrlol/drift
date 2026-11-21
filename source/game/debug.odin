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

// Zero is valid: nothing measured yet, overlay shown.
Profiler :: struct {
	ms:         [Prof_Block]f32, // last measurement of each block
	frame_ms:   [PROF_FRAMES]f32, // update + draw, ring buffer, head is the oldest
	head:       int,
	frame_used: uint, // frame arena bytes used by the previous frame
	hidden:     bool,
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

// Loads the snapshot into w.weather, runs every command in inputs and writes the result to out.
// out only holds deterministic text (no timings), so it can be compared byte for byte.
// Inputs, one command per line, # starts a comment:
//   route <from hub> <to hub> <fastest|greenest|calmest> <hour 0..8>
headless_run :: proc(w: ^World, snapshot, inputs: []u8, out: ^strings.Builder) -> bool {
	t := prof_begin()
	weather, weather_ok := weather_from_snapshot(snapshot)
	prof_end(w, .Weather_Load, t)
	if !weather_ok do return false
	w.weather = weather
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
				fmt.eprintfln("[headless] inputs line %d: more than %d words", line_no, len(f))
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
				fmt.eprintfln(
					"[headless] inputs line %d: %q, want: route <from hub> <to hub> <fastest|greenest|calmest> <hour>",
					line_no,
					line,
				)
				return false
			}
			if from < 0 || from >= w.m.hub_count || to < 0 || to >= w.m.hub_count {
				fmt.eprintfln(
					"[headless] inputs line %d: hubs %d -> %d, valid ids are 0..%d",
					line_no,
					from,
					to,
					w.m.hub_count - 1,
				)
				return false
			}
			if hour < 0 || hour >= FORECAST_HOURS {
				fmt.eprintfln(
					"[headless] inputs line %d: hour %d outside 0..%d",
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
		case:
			fmt.eprintfln("[headless] inputs line %d: unknown command %q", line_no, f[0])
			return false
		}
	}
	return true
}

// Called by the host and the release main with the command line after the program name:
//   --headless --snapshot <file> --inputs <file>
// Prints the result to stdout and timings to stderr. No window is opened.
@(export)
game_headless :: proc(args: []string) -> bool {
	USAGE :: "usage: drift --headless --snapshot <file> --inputs <file>"
	snapshot_path, inputs_path: string
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--headless":
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
	if snapshot_path == "" || inputs_path == "" {
		fmt.eprintln("[headless] missing --snapshot or --inputs\n" + USAGE)
		return false
	}

	w := (^World)(game_init())
	if w == nil do return false
	defer game_shutdown(w)
	context.allocator = virtual.arena_allocator(&w.perm)
	context.temp_allocator = virtual.arena_allocator(&w.frame)

	snapshot, snapshot_err := os.read_entire_file(snapshot_path, context.allocator)
	if snapshot_err != nil {
		fmt.eprintfln("[headless] cannot read snapshot %s: %v", snapshot_path, snapshot_err)
		return false
	}
	inputs, inputs_err := os.read_entire_file(inputs_path, context.allocator)
	if inputs_err != nil {
		fmt.eprintfln("[headless] cannot read inputs %s: %v", inputs_path, inputs_err)
		return false
	}

	out := strings.builder_make(context.allocator)
	ok := headless_run(w, snapshot, inputs, &out)
	fmt.print(strings.to_string(out))
	fmt.eprintfln(
		"[headless] weather load %.3f ms, last route %.3f ms",
		w.prof.ms[.Weather_Load],
		w.prof.ms[.Route],
	)
	return ok
}
