// End to end tests: fixed snapshot + fixed inputs through headless_run, compared to stored results.
// On a mismatch the actual output is written to build/test_<name>.txt so it can be diffed.
// Never update an expected file to make a test pass, see AGENTS.md.
package test

import game "../source/game"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"

Case :: struct {
	name:     string,
	snapshot: string,
	inputs:   string,
	expected: string, // "" when the run must fail
}

CASES :: [?]Case {
	// All modes, first and last hour, a route to the same hub.
	{"calm_routes", "test/data/calm.snap", "test/data/routes.txt", "test/data/calm_routes.expected"},
	// Wind and gusts differ per layer, so the three modes must fly different layers.
	{
		"windy_routes",
		"test/data/windy.snap",
		"test/data/windy_routes.txt",
		"test/data/windy_routes.expected",
	},
	// A hub inside a no-fly zone gets no route, a zone above or next to a hub does not stop it.
	{"no_fly", "test/data/calm.snap", "test/data/no_fly.txt", "test/data/no_fly.expected"},
	// A strong headwind: the +6 m/s retry, the 1.5 m/s floor and the crosswind limit each change a route.
	{
		"headwind_routes",
		"test/data/headwind.snap",
		"test/data/headwind_routes.txt",
		"test/data/headwind_routes.expected",
	},
	// Clouds over the shortest path: greenest flies around them for the sun, fastest does not.
	{
		"cloudy_routes",
		"test/data/cloudy.snap",
		"test/data/cloudy_routes.txt",
		"test/data/cloudy_routes.expected",
	},
	// A reported gust zone is avoided, closes every layer, and applies together with the no-fly zones.
	{"gust", "test/data/calm.snap", "test/data/gust.txt", "test/data/gust.expected"},
	// The demo: plan Brussels -> Gent, the three summaries and maneuvers, fly greenest with the autopilot,
	// report a gust after 5 minutes, reroute around it and dock in Gent.
	{"demo_flow", "test/data/windy.snap", "test/data/demo_flow.txt", "test/data/demo_flow.expected"},
	// Long routes with layer changes: the why line and the climb / continue / approach maneuvers.
	{"maneuvers", "test/data/windy.snap", "test/data/maneuvers.txt", "test/data/maneuvers.expected"},
	// The airship as a flying car: lands on the nearest road, follows one-way edges, turns at junctions by
	// the turn input, stops nowhere off the graph; far from any road it does not land.
	{"drive", "test/data/calm.snap", "test/data/drive.txt", "test/data/drive.expected"},
	// A NaN in the wind field must reject the snapshot, not reach the router.
	{"nan_wind", "test/data/nan_wind.snap", "test/data/routes.txt", ""},
}

main :: proc() {
	failed := 0
	for c in CASES {
		if !run_case(c) do failed += 1
	}
	if !run_scan_order() do failed += 1
	fmt.printfln("test: %d passed, %d failed", len(CASES) + 1 - failed, failed)
	os.exit(failed == 0 ? 0 : 1)
}

run_case :: proc(c: Case) -> bool {
	w := (^game.World)(game.game_init())
	if w == nil {
		fmt.printfln("test %s: cannot create the World", c.name)
		return false
	}
	defer game.game_shutdown(w)
	context.allocator = virtual.arena_allocator(&w.perm)
	context.temp_allocator = virtual.arena_allocator(&w.frame)

	inputs, inputs_err := os.read_entire_file(c.inputs, context.allocator)
	if inputs_err != nil {
		fmt.printfln("test %s: cannot read %s: %v", c.name, c.inputs, inputs_err)
		return false
	}

	out := strings.builder_make()
	ok := game.headless_run(w, c.snapshot, inputs, &out)
	if c.expected == "" {
		if ok do fmt.printfln("test %s: run succeeded, it must fail", c.name)
		return !ok
	}
	if !ok {
		fmt.printfln("test %s: run failed, see the log above", c.name)
		return false
	}

	expected, expected_err := os.read_entire_file(c.expected, context.allocator)
	if expected_err != nil {
		fmt.printfln("test %s: cannot read %s: %v", c.name, c.expected, expected_err)
		return false
	}
	got, want := strings.to_string(out), string(expected)
	if got == want do return true

	line := 1
	for {
		g, g_ok := strings.split_lines_iterator(&got)
		e, e_ok := strings.split_lines_iterator(&want)
		if !g_ok && !e_ok do break
		if g != e || g_ok != e_ok {
			fmt.printfln("test %s: line %d differs\n  got:  %q\n  want: %q", c.name, line, g, e)
			break
		}
		line += 1
	}
	actual := fmt.tprintf("build/test_%s.txt", c.name)
	if err := os.write_entire_file(actual, strings.to_string(out)); err != nil {
		fmt.printfln("test %s: cannot write %s: %v", c.name, actual, err)
	} else {
		fmt.printfln("test %s: full output in %s, expected in %s", c.name, actual, c.expected)
	}
	return false
}

// The scan animation replays w.grid.expanded after a route. Catches a scan that does not start at the
// start node or end at the goal, repeats or skips nodes, enters blocked nodes, differs between two runs
// of the same route, or is left over from the previous route when a route fails before searching.
run_scan_order :: proc() -> bool {
	w := (^game.World)(game.game_init())
	if w == nil {
		fmt.println("test scan_order: cannot create the World")
		return false
	}
	defer game.game_shutdown(w)
	context.allocator = virtual.arena_allocator(&w.perm)
	context.temp_allocator = virtual.arena_allocator(&w.frame)

	out := strings.builder_make()
	if !game.headless_run(w, "test/data/calm.snap", nil, &out) {
		fmt.println("test scan_order: cannot load test/data/calm.snap, see the log above")
		return false
	}

	// Tower top of hub i, the end point headless_run routes from and to.
	tower :: proc(w: ^game.World, i: int) -> [3]f32 {
		p := w.m.hubs[i].pos
		return {p.x, p.y, game.height_at(w, p.x, p.y) + game.HUB_TOWER_M}
	}

	g := &w.grid
	seen := make([]bool, game.GRID_NODES)
	for from in 0 ..< w.m.hub_count {
		for to in 0 ..< w.m.hub_count {
			_, ok := game.route(w, tower(w, from), tower(w, to), .Fastest, 0)
			if !ok {
				fmt.printfln("test scan_order: no route %d -> %d on the calm snapshot", from, to)
				return false
			}
			scan := g.expanded[:g.expanded_len]
			start, _ := game.grid_free_node_near(g, tower(w, from))
			goal, _ := game.grid_free_node_near(g, tower(w, to))
			if len(scan) == 0 || scan[0] != start || scan[len(scan) - 1] != goal {
				fmt.printfln(
					"test scan_order: route %d -> %d: scan of %d nodes, want first %v and last %v",
					from,
					to,
					len(scan),
					start,
					goal,
				)
				return false
			}
			for n in scan {
				if seen[n] || game.grid_blocked(g, n) {
					fmt.printfln(
						"test scan_order: route %d -> %d: node %v %s",
						from,
						to,
						n,
						seen[n] ? "expanded twice" : "is blocked",
					)
					return false
				}
				seen[n] = true
			}
			// The returned path is smoothed and resampled (path cleanup), its points can lie in cells A* never
			// expanded. The A* node path, goal back to start through grid.parent, must be in the scan.
			for n := goal;; n = g.parent[n] {
				if !seen[n] {
					fmt.printfln(
						"test scan_order: route %d -> %d: A* path node %v not in the scan",
						from,
						to,
						n,
					)
					return false
				}
				if n == start do break
			}
			for n in scan do seen[n] = false
		}
	}

	_, first_ok := game.route(w, tower(w, 6), tower(w, 10), .Fastest, 0)
	first := slice.clone(g.expanded[:g.expanded_len])
	_, other_ok := game.route(w, tower(w, 14), tower(w, 2), .Fastest, 0)
	_, again_ok := game.route(w, tower(w, 6), tower(w, 10), .Fastest, 0)
	if !first_ok || !other_ok || !again_ok || !slice.equal(first, g.expanded[:g.expanded_len]) {
		fmt.printfln(
			"test scan_order: route 6 -> 10 twice: scans of %d and %d nodes differ",
			len(first),
			g.expanded_len,
		)
		return false
	}

	// Brussels (hub 5) inside a zone over every layer, as in no_fly.txt: the route fails before A* runs.
	w.no_fly[0] = {{139.669, 79.4}, 8, 10000}
	if _, ok := game.route(w, tower(w, 5), tower(w, 10), .Fastest, 0); ok || g.expanded_len != 0 {
		fmt.printfln("test scan_order: failed route 5 -> 10 left a scan of %d nodes, want 0", g.expanded_len)
		return false
	}
	return true
}
