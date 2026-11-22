// End to end tests: fixed snapshot + fixed inputs through headless_run, compared to stored results.
// On a mismatch the actual output is written to build/test_<name>.txt so it can be diffed.
// Never update an expected file to make a test pass, see AGENTS.md.
package test

import game "../source/game"
import "core:crypto/ed25519"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strconv"
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
	{"traffic", "test/data/calm.snap", "test/data/traffic.txt", "test/data/traffic.expected"},
	// A NaN in the wind field must reject the snapshot, not reach the router.
	{"nan_wind", "test/data/nan_wind.snap", "test/data/routes.txt", ""},
}

main :: proc() {
	failed := 0
	for c in CASES {
		if !run_case(c) do failed += 1
	}
	if !run_scan_order() do failed += 1
	if !run_carpool() do failed += 1
	if !run_free_flight() do failed += 1
	fmt.printfln("test: %d passed, %d failed", len(CASES) + 3 - failed, failed)
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

// Carpooling (carpool.odin) on the calm snapshot with three fixed identities: A offers Oostende -> Namur, the
// offer verifies and a tampered one does not, B finds it for Brussels -> Namur with a split that adds up, and
// only B's first review of the trip counts towards A's reputation (C was not on it).
run_carpool :: proc() -> bool {
	w := (^game.World)(game.game_init())
	if w == nil {
		fmt.println("test carpool: cannot create the World")
		return false
	}
	defer game.game_shutdown(w)
	context.allocator = virtual.arena_allocator(&w.perm)
	context.temp_allocator = virtual.arena_allocator(&w.frame)
	out := strings.builder_make()
	if !game.headless_run(w, "test/data/calm.snap", nil, &out) {
		fmt.println("test carpool: cannot load test/data/calm.snap, see the log above")
		return false
	}
	fail :: proc(what: string, args: ..any) -> bool {
		fmt.printf("test carpool: ")
		fmt.printfln(what, ..args)
		return false
	}
	be :: proc(w: ^game.World, seed: u8) -> [32]u8 {
		b: [ed25519.PRIVATE_KEY_SIZE]u8
		for &x in b do x = seed
		_ = ed25519.private_key_set_bytes(&w.identity, b[:])
		ed25519.private_key_public_bytes(&w.identity, w.identity_pub[:])
		return w.identity_pub
	}
	depart := i64(w.weather.start) + 1800
	now := depart - 600
	// Messages are stamped an hour before the departure, inside the store's time window for "now".
	add :: proc(w: ^game.World, m: ^game.Message, now: i64) -> bool {
		m.time = i64le(now - 3000)
		game.msg_sign(w, m)
		return game.store_add(&w.store, m, now) == .Added
	}

	a := be(w, 1)
	offer, ok := game.carpool_offer_make(w, 6, 12, .Greenest, depart, 3)
	if !ok do return fail("no offer Oostende -> Namur")
	if v, _ := game.carpool_verify(w, &offer); v != .Ok do return fail("own offer does not verify: %v", v)
	bad := offer
	bad.offer.energy_kwh += 5
	game.msg_sign(w, &bad)
	if v, _ := game.carpool_verify(w, &bad); v != .Energy_Differs do return fail("tampered energy gives %v", v)
	if !add(w, &offer, now) do return fail("offer not stored")
	offer_id := game.msg_id(&offer)

	b := be(w, 2)
	matches: [game.MAX_MATCHES]game.Match
	n := game.carpool_match(w, 5, 12, 0, 1, matches[:])
	if n != 1 || matches[0].offer != offer_id do return fail("Brussels -> Namur finds %d offers", n)
	mt := matches[0]
	if mt.passenger_kwh <= 0 ||
	   abs(mt.passenger_kwh + mt.driver_kwh - (mt.direct_kwh + max(mt.detour_kwh, 0))) > 1e-3 {
		return fail("split does not add up: %v", mt)
	}
	if p, d := game.carpool_split(10, 2, 6, 1); p != 5 || d != 7 do return fail("split 10 / 2 / 6 / 1 seat = %v %v", p, d)
	if n = game.carpool_match(w, 5, 12, 3, 1, matches[:]); n != 0 do return fail("an offer of hour 0 matches hour 3")

	req: game.Message
	req.kind = .Request
	req.request = {
		offer    = offer_id,
		from_hub = 5,
		to_hub   = 12,
		seats    = 1,
	}
	if !add(w, &req, now) do return fail("request not stored")
	be(w, 1)
	acc: game.Message
	acc.kind = .Accept
	acc.accept = {
		offer   = offer_id,
		request = game.msg_id(&req),
	}
	if !add(w, &acc, now) do return fail("accept not stored")
	acc_id := game.msg_id(&acc)
	be(w, 2)
	r1, _ := game.carpool_review_make(w, acc_id, a, 4)
	r2, _ := game.carpool_review_make(w, acc_id, a, 1)
	if !add(w, &r1, now) || !add(w, &r2, now) do return fail("reviews not stored")
	be(w, 3)
	r3, _ := game.carpool_review_make(w, acc_id, a, 1)
	if !add(w, &r3, now) do return fail("stranger review not stored")
	stars, count := game.carpool_reputation(w, a)
	if count != 1 || stars != 4 do return fail("reputation of A: %v stars from %d reviews, want 4 from 1", stars, count)
	if _, cb := game.carpool_reputation(w, b); cb != 0 do return fail("B has %d reviews, want 0", cb)
	return true
}

// Free flight in the street view (ship_free_step) through the headless free command. Catches a car that flies
// through a building, does not land on a roof or the ground, misses its top speed (252 km/h flying, 126 km/h on
// its wheels), slides sideways on its wheels, ignores a crosswind, or flies a different path for the same inputs.
run_free_flight :: proc() -> bool {
	World_Run :: struct {
		w:   ^game.World,
		out: string,
	}
	// A fresh World, the inputs through headless_run; the World is left open for the checks.
	run :: proc(snapshot, inputs: string) -> (r: World_Run, ok: bool) {
		r.w = (^game.World)(game.game_init())
		if r.w == nil do return
		context.allocator = virtual.arena_allocator(&r.w.perm)
		b := strings.builder_make()
		ok = game.headless_run(r.w, snapshot, transmute([]u8)inputs, &b)
		r.out = strings.to_string(b)
		return
	}
	// The number in front of what in the last line of out ("3 wall hits", "inside 0 steps").
	count :: proc(out, what: string) -> int {
		lines := strings.trim_space(out)
		last := lines[strings.last_index_byte(lines, '\n') + 1:]
		if what == "steps" {
			i := strings.index(last, "inside ")
			if i < 0 do return -1
			n, _ := strconv.parse_int(strings.fields(last[i + 7:], context.temp_allocator)[0])
			return n
		}
		i := strings.index(last, what)
		if i < 0 do return -1
		f := strings.fields(last[:i], context.temp_allocator)
		n, _ := strconv.parse_int(f[len(f) - 1])
		return n
	}
	inside :: proc(ring: [][2]f32, p: [2]f32) -> bool {
		in_ring := false
		for k in 0 ..< len(ring) {
			a, b := ring[k], ring[(k + 1) % len(ring)]
			if (a.y > p.y) != (b.y > p.y) && p.x < a.x + (b.x - a.x) * (p.y - a.y) / (b.y - a.y) do in_ring = !in_ring
		}
		return in_ring
	}
	pose_km :: proc(w: ^game.World) -> [2]f32 {
		p := game.ship_pose(&w.ship).pos
		return {f32(p.x), f32(p.y)}
	}
	heading_deg :: proc(dir: [2]f32) -> f32 {
		return math.atan2(dir.x, -dir.y) * 180 / math.PI
	}

	// A known building in Brussels: real footprint, at least 12 m high and 400 m2, its centroid inside it, with a
	// wall of 12 m or more that has 9 m of free space in front of it.
	base, base_ok := run("test/data/calm.snap", "")
	if !base_ok {
		fmt.println("test free_flight: cannot load test/data/calm.snap")
		return false
	}
	w := base.w
	defer game.game_shutdown(w)
	context.allocator = virtual.arena_allocator(&w.perm)
	context.temp_allocator = virtual.arena_allocator(&w.frame)
	tower := w.ship.pos // game_init starts on the Brussels tower
	game.collide_build(w)
	co := &w.collide
	ring: [][2]f32
	height: f32
	centre, start, wall_a, wall_b, toward: [2]f32
	search: for bi in 0 ..< len(co.b_count) {
		n := int(co.b_count[bi])
		if n < 4 || co.b_height[bi] < 12 do continue
		pts := co.points[co.b_start[bi]:][:n]
		if linalg.length(pts[0] - tower) > 1 do continue
		area: f32
		c: [2]f32
		for k in 0 ..< n {
			// Relative to the first corner: km of ~140 squared in f32 would drown a 400 m2 area.
			a, b := pts[k] - pts[0], pts[(k + 1) % n] - pts[0]
			cr := a.x * b.y - b.x * a.y
			area += cr / 2
			c += (a + b) * cr
		}
		if abs(area) * 1e6 < 400 do continue
		c = pts[0] + c / (6 * area)
		if !inside(pts, c) do continue
		for k in 0 ..< n {
			a, b := pts[k], pts[(k + 1) % n]
			if linalg.length(b - a) * 1000 < 12 do continue
			mid := (a + b) / 2
			d := linalg.normalize(b - a)
			out := [2]f32{-d.y, d.x}
			if linalg.dot(out, mid - c) < 0 do out = -out
			for s: f32 = 0; s <= 6; s += 1 {
				push, roof := game.collide_car(w, mid + out * (9 - s) / 1000, 2, game.FREE_RADIUS_M)
				if push != {} || roof > 0 do continue search
			}
			ring, height, centre = pts, co.b_height[bi], c
			start, wall_a, wall_b, toward = mid + out * 0.009, a, b, -out
			break search
		}
	}
	if ring == nil {
		fmt.println(
			"test free_flight: no building in Brussels with a free wall of 12 m, 12 m high, 9 m clear",
		)
		return false
	}

	// 1: full throttle into the wall from 9 m: stopped against it, never inside, at the car's radius.
	{
		r, ok := run(
			"test/data/calm.snap",
			fmt.tprintf("free %.5f %.5f 2 %.2f 1 0 0 6\n", start.x, start.y, heading_deg(toward)),
		)
		defer if r.w != nil do game.game_shutdown(r.w)
		if !ok {
			fmt.println("test free_flight: wall run failed")
			return false
		}
		p := pose_km(r.w)
		ab := wall_b - wall_a
		q := wall_a + ab * clamp(linalg.dot(p - wall_a, ab) / linalg.dot(ab, ab), 0, 1)
		dist := linalg.length(p - q) * 1000
		if count(r.out, "steps") != 0 ||
		   count(r.out, "wall hits") < 1 ||
		   inside(ring, p) ||
		   dist < game.FREE_RADIUS_M - 0.5 ||
		   dist > game.FREE_RADIUS_M + 1 {
			fmt.printfln(
				"test free_flight: into the wall: %.2f m from it (want ~%.1f), inside the footprint %v\n  %s",
				dist,
				game.FREE_RADIUS_M,
				inside(ring, p),
				r.out,
			)
			return false
		}
	}

	// 2: down onto the roof, then hands off: it lands on its wheels on the roof and stays there.
	{
		r, ok := run(
			"test/data/calm.snap",
			fmt.tprintf(
				"free %.5f %.5f %.2f 0 0 0 -1 4\nfree_on 0 0 0 3\n",
				centre.x,
				centre.y,
				height + 12,
			),
		)
		defer if r.w != nil do game.game_shutdown(r.w)
		s := &r.w.ship
		hag := s.alt - game.height_at(r.w, s.pos.x, s.pos.y)
		before := s.alt
		more := strings.builder_make()
		ok2 :=
			ok &&
			game.headless_run(r.w, "test/data/calm.snap", transmute([]u8)string("free_on 0 0 0 3\n"), &more)
		if !ok2 || !s.driving || abs(hag - height) > 0.25 || abs(s.alt - before) > 0.01 {
			fmt.printfln(
				"test free_flight: on the roof (%.1f m): %.2f m above the ground (want %.2f), then moved %.3f m\n  %s",
				height,
				hag,
				height,
				s.alt - before,
				r.out,
			)
			return false
		}
	}

	// 3: full throttle in open country: the top speed the game runs with (tune.max_speed, SHIP_MAX_SPEED unless
	// assets/settings.txt changes it).
	{
		r, ok := run("test/data/calm.snap", "free 132.924 83.707 60 0 1 0 0 60\n")
		defer if r.w != nil do game.game_shutdown(r.w)
		if !ok || abs(r.w.ship.speed - r.w.tune.max_speed) > 0.5 || count(r.out, "wall hits") != 0 {
			fmt.printfln(
				"test free_flight: top speed %.2f m/s, want %.0f\n  %s",
				r.w.ship.speed,
				r.w.tune.max_speed,
				r.out,
			)
			return false
		}
	}

	// 4: across the wind at 300 m: the car drifts with it, sideways by about the wind speed.
	{
		r, ok := run("test/data/windy.snap", "")
		defer if r.w != nil do game.game_shutdown(r.w)
		x, y: f32 = 132.924, 83.707
		alt := game.height_at(r.w, x, y) + 300
		wind := game.wind_at(r.w, x, y, game.layer_at(alt), 0)
		speed := linalg.length(wind)
		if !ok || speed < 2 {
			fmt.printfln(
				"test free_flight: windy.snap has %.1f m/s at %.0f m there, too little for the test",
				speed,
				alt,
			)
			return false
		}
		across := linalg.normalize([2]f32{-wind.y, wind.x})
		b := strings.builder_make()
		inputs := fmt.tprintf("free %.3f %.3f 300 %.2f 0.5 0 0 20\n", x, y, heading_deg(across))
		ok = game.headless_run(r.w, "test/data/windy.snap", transmute([]u8)inputs, &b)
		moved := (pose_km(r.w) - {x, y}) * 1000
		drift := linalg.dot(moved, wind / speed)
		if !ok || drift < 0.8 * speed * 20 || drift > 1.05 * speed * 20 {
			fmt.printfln(
				"test free_flight: %.1f m/s across the wind for 20 s drifted %.1f m with it, want ~%.0f m\n  %s",
				speed,
				drift,
				speed * 20,
				strings.to_string(b),
			)
			return false
		}
	}

	// 6: down onto open ground: it lands on its wheels and drives like a car: top speed ROAD_MAX_SPEED on the
	// ground, it turns without sliding sideways, and up lifts it off again.
	{
		r, ok := run("test/data/calm.snap", "free 132.924 83.707 3 0 0 0 -1 2\nfree_on 1 0 0 40\n")
		defer if r.w != nil do game.game_shutdown(r.w)
		s := &r.w.ship
		hag := s.alt - game.height_at(r.w, s.pos.x, s.pos.y)
		top := s.speed
		h0 := s.heading
		b := strings.builder_make()
		ok &&= game.headless_run(
			r.w,
			"test/data/calm.snap",
			transmute([]u8)string("free_on 0.6 1 0 4\n"),
			&b,
		)
		fwd := [2]f32{math.sin(s.heading), -math.cos(s.heading)}
		side := abs(linalg.dot(s.vel.xy, [2]f32{-fwd.y, fwd.x}))
		turned := abs(math.mod(s.heading - h0 + 3 * math.PI, 2 * math.PI) - math.PI)
		driving := s.driving
		ok &&= game.headless_run(r.w, "test/data/calm.snap", transmute([]u8)string("free_on 0 0 1 2\n"), &b)
		lifted := !s.driving && s.alt - game.height_at(r.w, s.pos.x, s.pos.y) > 2
		if !ok ||
		   abs(hag) > 0.05 ||
		   abs(top - game.ROAD_MAX_SPEED) > 1 ||
		   !driving ||
		   turned < 0.5 ||
		   side > 1 ||
		   !lifted {
			fmt.printfln(
				"test free_flight: driving: %.2f m up, top %.1f m/s (want %.0f), turned %.2f rad, sideways %.2f m/s, on wheels %v, lifted %v\n  %s",
				hag,
				top,
				game.ROAD_MAX_SPEED,
				turned,
				side,
				driving,
				lifted,
				r.out,
			)
			return false
		}
	}

	// 5: the same inputs twice (gusty weather, turning and climbing) give the same flight to the bit.
	{
		IN :: "free 139.50 79.30 40 30 1 0.4 0.3 8\nfree_on 0.5 -1 -0.5 6\n"
		a, a_ok := run("test/data/windy.snap", IN)
		defer if a.w != nil do game.game_shutdown(a.w)
		b, b_ok := run("test/data/windy.snap", IN)
		defer if b.w != nil do game.game_shutdown(b.w)
		sa, sb := a.w.ship, b.w.ship
		same := sa.pos == sb.pos && sa.pos_frac == sb.pos_frac && sa.alt == sb.alt && sa.vel == sb.vel
		same &&= sa.heading == sb.heading && a.out == b.out
		if !a_ok || !b_ok || !same {
			fmt.printfln("test free_flight: the same inputs twice differ\n  %s\n  %s", a.out, b.out)
			return false
		}
	}
	return true
}
