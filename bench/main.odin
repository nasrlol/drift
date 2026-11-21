// Times every system, prints min / avg / max per call and arena usage, fails when a budget is exceeded.
// Run it in the profile configuration before every merge:
//   odin run bench -o:speed -debug -define:DRIFT_PROFILE=true -out:build/bench
package bench

import game "../source/game"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:time"

ROUNDS :: 200
POINTS :: 4096 // samples per round for the per-point systems, 48 KB of positions, stays in L2

// Budgets from rules.txt, compared to the average. Changing them needs the owner's approval.
ROUTE_BUDGET_MS :: 10
THREE_MODES_BUDGET_MS :: 30
WEATHER_LOAD_BUDGET_MS :: 5
SHIP_STEP_BUDGET_MS :: 0.001

BENCH_SNAPSHOT :: "test/data/calm.snap"

Stat :: struct {
	min, sum, max: f64, // ns per call
}

add :: proc(s: ^Stat, start: time.Tick, calls: int) {
	ns := f64(time.tick_since(start)) / f64(calls)
	if s.sum == 0 || ns < s.min do s.min = ns
	s.max = max(s.max, ns)
	s.sum += ns
}

report :: proc(name: string, s: Stat) -> (avg_ms: f64) {
	avg := s.sum / ROUNDS
	if avg >= 100_000 {
		fmt.printfln("%-22s min %9.3f  avg %9.3f  max %9.3f ms", name, s.min / 1e6, avg / 1e6, s.max / 1e6)
	} else {
		fmt.printfln("%-22s min %9.1f  avg %9.1f  max %9.1f ns", name, s.min, avg, s.max)
	}
	return avg / 1e6
}

main :: proc() {
	w := (^game.World)(game.game_init())
	if w == nil do os.exit(1)
	context.allocator = virtual.arena_allocator(&w.perm)
	context.temp_allocator = virtual.arena_allocator(&w.frame)

	// Fixed seed LCG: the same weather and sample points on every run.
	seed: u32 = 12345
	rnd := proc(seed: ^u32) -> f32 {
		seed^ = seed^ * 1664525 + 1013904223
		return f32(seed^ >> 8) / f32(1 << 24)
	}
	w.weather.start = 1795176000
	for &hour in w.weather.wind do for &layer in hour do for &v in layer do v = {rnd(&seed) * 30 - 15, rnd(&seed) * 30 - 15}
	for &hour in w.weather.gust do for &layer in hour do for &g in layer do g = rnd(&seed)
	for &hour in w.weather.cloud do for &c in hour do c = rnd(&seed)
	generated := w.weather
	pts := make([][2]f32, POINTS)
	for &p in pts do p = {rnd(&seed) * 285, rnd(&seed) * 229}

	sink: f32
	wind, gust, cloud, height, ship, route, three, reroute, load, load_map: Stat
	for round in 0 ..< ROUNDS {
		layer, hour := round % game.WIND_LAYERS, round % game.FORECAST_HOURS

		t := time.tick_now()
		for p in pts {
			v := game.wind_at(w, p.x, p.y, layer, hour)
			sink += v.x + v.y
		}
		add(&wind, t, POINTS)

		t = time.tick_now()
		for p in pts do sink += game.gust_at(w, p.x, p.y, layer, hour)
		add(&gust, t, POINTS)

		t = time.tick_now()
		for p in pts do sink += game.cloud_at(w, p.x, p.y, hour)
		add(&cloud, t, POINTS)

		t = time.tick_now()
		for p in pts do sink += game.height_at(w, p.x, p.y)
		add(&height, t, POINTS)

		// Varied controls and positions so the clamps, the wind layers and the dock test all run.
		w.ship = {
			pos = pts[round % POINTS],
			alt = 300,
		}
		t = time.tick_now()
		for i in 0 ..< POINTS {
			c := game.Controls{f32(i % 7) / 3 - 1, f32(i % 5) / 2 - 1, f32(i % 3) - 1}
			game.ship_step(w, c, game.SIM_DT)
			w.tick += 1
		}
		add(&ship, t, POINTS)
		sink += w.ship.pos.x + w.ship.alt

		a := w.m.hubs[round % w.m.hub_count].pos
		b := w.m.hubs[(round * 7 + 3) % w.m.hub_count].pos
		from, to := [3]f32{a.x, a.y, game.HUB_TOWER_M}, [3]f32{b.x, b.y, game.HUB_TOWER_M}
		t = time.tick_now()
		path, _ := game.route(w, from, to, .Fastest, hour)
		add(&route, t, 1)
		sink += f32(len(path))

		t = time.tick_now()
		for mode in game.Route_Mode {
			path, _ = game.route(w, from, to, mode, hour)
			sink += f32(len(path))
		}
		add(&three, t, 1)

		// A gust cell reported half way: the blocked set and the free regions are rebuilt, then
		// the route runs again. The zone stays until the next round, so route above never rebuilds.
		w.gust_zones[0] = {(from.xy + to.xy) / 2, 0.26}
		t = time.tick_now()
		path, _ = game.route(w, from, to, .Fastest, hour)
		add(&reroute, t, 1)
		sink += f32(len(path))

		// File read (from the page cache), sha256, validation and copy: what startup pays.
		// It replaces the generated weather, which is put back for the next round.
		t = time.tick_now()
		ok := game.weather_load_snapshot(w, BENCH_SNAPSHOT)
		add(&load, t, 1)
		if !ok {
			fmt.println("bench: cannot load", BENCH_SNAPSHOT)
			os.exit(1)
		}
		sink += w.weather.cloud[hour][0]
		w.weather = generated

		t = time.tick_now()
		m, _ := game.load_map()
		add(&load_map, t, 1)
		sink += f32(m.hub_count)
	}

	fmt.printfln(
		"bench: %d rounds, %d points per round for the *_at procs, build %s",
		ROUNDS,
		POINTS,
		game.BUILD_MODE,
	)
	report("wind_at", wind)
	report("gust_at", gust)
	report("cloud_at", cloud)
	report("height_at", height)
	ship_ms := report("ship_step", ship)
	route_ms := report("route", route)
	three_ms := report("route, three modes", three)
	reroute_ms := report("route after gust", reroute)
	load_ms := report("weather snapshot load", load)
	report("load_map", load_map)
	fmt.printfln(
		"arenas: perm %d / %d, route %d / %d, frame %d / %d bytes (used / reserved)",
		w.perm.total_used,
		w.perm.total_reserved,
		w.route_mem.total_used,
		w.route_mem.total_reserved,
		w.frame.total_used,
		w.frame.total_reserved,
	)
	fmt.printfln("(sink %v)", sink)

	over := 0
	budgets := [?]struct {
		name:     string,
		avg, max: f64,
	} {
		{"ship_step", ship_ms, SHIP_STEP_BUDGET_MS},
		{"route", route_ms, ROUTE_BUDGET_MS},
		{"route, three modes", three_ms, THREE_MODES_BUDGET_MS},
		{"route after gust", reroute_ms, ROUTE_BUDGET_MS},
		{"weather snapshot load", load_ms, WEATHER_LOAD_BUDGET_MS},
	}
	for b in budgets {
		if b.avg > b.max {
			fmt.printfln("bench: %s takes %.3f ms on average, budget %v ms", b.name, b.avg, b.max)
			over += 1
		}
	}
	fmt.println(over == 0 ? "bench: ok" : "bench: over budget")
	game.game_shutdown(w)
	os.exit(over == 0 ? 0 : 1)
}
