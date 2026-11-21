// author: lars
package game

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:mem/virtual"
import "core:strings"

// Navigation: the three planned routes with their metrics and maneuvers, the navigation state while flying,
// rerouting, gust reports and the autopilot (spec "Navigatie" and "Vluchtmodel en autopilot"). Simulation code:
// no raylib, no wall-clock time. The spec's rules are for 20 m path points; our path has a point every
// RESAMPLE_KM, so windows that the spec gives in points are given here in km.

// Maneuvers (spec "buildManeuvers"): a turn compares the heading over TURN_WINDOW_KM before and after a point.
TURN_WINDOW_KM :: 1.0
TURN_MIN_RAD :: 0.5
TURN_SHARP_RAD :: 1.9
TURN_NORMAL_RAD :: 0.95
TURN_GAP_KM :: 2.0 // between two turns
TURN_START_KM :: 1.0 // no turn this close to the start
TURN_END_KM :: 1.5 // or to the end
// An altitude change: more than ALT_CHANGE_M within ALT_WINDOW_KM.
ALT_CHANGE_M :: 45
ALT_WINDOW_KM :: 1.0
MERGE_KM :: 0.5 // events closer than this keep only the most important one
STRAIGHT_KM :: 20 // a leg this long gets a "Continue" maneuver
// "Turn left toward <hub>": a hub 2..60 km away in the new direction, cos > TOWARD_COS.
TOWARD_MIN_KM :: 2
TOWARD_MAX_KM :: 60
TOWARD_COS :: 0.82
ROAD_NAME_KM :: 2 // road name of a maneuver: the nearest named road or river this close

// Runtime (spec "Runtime"): the banner shows the next maneuver more than BANNER_AHEAD_KM ahead.
BANNER_AHEAD_KM :: 0.015
THEN_KM :: 0.7
CALLOUT_KM :: 1.6
// Rerouting: more than OFF_PATH_KM beside the path for OFF_PATH_S (scaled by the sim speed).
OFF_PATH_KM :: 0.19
OFF_PATH_S :: 1.2
REROUTE_BANNER_S :: 1.6
WARNING_AHEAD_KM :: 3
// Gust report: a zone of GUST_RADIUS_KM on the path GUST_AHEAD_KM ahead of the ship.
GUST_RADIUS_KM :: 0.26
GUST_AHEAD_KM :: 0.7

// Autopilot (spec): lookahead along the path, slow down near the tower, crab into the wind.
AP_LOOKAHEAD_KM :: 0.3
AP_SLOW_KM :: 0.26
AP_MIN_SPEED :: 6.5
AP_TURN_GAIN :: 0.9
AP_MAX_TURN :: 0.22 // rad/s
AP_CLIMB_GAIN :: 0.35
AP_MAX_CLIMB :: 4.0 // m/s
DOCK_ABOVE_M :: 3 // a docked ship is held at the tower top + 3 m
// Metrics (spec "evaluate"): vertical speed used for the time of a climb, straight line baseline.
EVAL_CLIMB_MS :: 3.5
BASELINE_ABOVE_TERRAIN_M :: 80

Route_Tag :: enum u8 {
	None,
	Lowest_Energy, // greenest: "Lowest energy, -38% vs straight line"
	Extra_Energy, // "+69% energy" compared to greenest
	Gust_Index, // calmest: its time weighted gust index
}

// Per mode, from the smoothed path (spec "evaluate"). Units: minutes, km, km/h, kWh, m/s, m.
Route_Summary :: struct {
	minutes, km, kmh, net_kwh, wind_ms: f32,
	tag:                                Route_Tag,
	why:                                [64]u8, // 0-terminated, "Via Skyway 300 and Skyway 550, past Mechelen"
	seconds:                            f32,
	used_kwh, solar_kwh:                f32,
	gust:                               f32, // time weighted gust index 0..1
	tail_ms:                            f32, // mean tailwind along the track, negative = headwind
	max_cross_ms:                       f32,
	climb_m:                            f32,
	vs_straight:                        f32, // net kWh / straight line net kWh - 1 (-0.38 = 38 % less)
	vs_greenest:                        f32, // net kWh / greenest net kWh - 1
}

Maneuver_Kind :: enum u8 {
	Straight,
	Slight_Left,
	Slight_Right,
	Left,
	Right,
	Sharp_Left,
	Sharp_Right,
	Climb,
	Descend,
	Depart,
	Arrive,
}

// text, sub and road are 0-terminated (read them with cstr).
Maneuver :: struct {
	kind:       Maneuver_Kind,
	path_index: int,
	s_km:       f32, // horizontal distance along the path
	text:       [48]u8,
	sub:        [48]u8,
	road:       [64]u8, // the nearest real road or river, or the layer ("Skyway 550")
}

// A route of plan_routes or a reroute. path, times, dist and maneuvers live in w.plan_mem until the next
// plan_routes call. Zero = no route.
Planned_Route :: struct {
	path:      [][3]f32,
	ok:        bool,
	sum:       Route_Summary,
	maneuvers: []Maneuver,
	times:     []f32, // planned seconds from the start at each path point
	dist:      []f32, // km from the start at each path point
}

Banner_State :: enum u8 {
	Flying,
	Rerouting,
	Arrived,
}

// Navigation state, all derived from the ship's place on the path. Zero = not navigating.
Nav :: struct {
	active:       bool,
	mode:         Route_Mode,
	from, to:     int, // hub ids
	hour:         int, // forecast hour at departure
	start_tick:   u64,
	path_index:   int, // the path point at or before the ship
	s_km:         f32, // the ship's distance along the path
	next:         int, // index into the route's maneuvers, len = none left
	next_m:       f32,
	then_visible: bool,
	eta_s:        f32, // remaining seconds
	remaining_km: f32,
	used_kwh:     f32, // net, since departure
	solar_kwh:    f32,
	banner:       Banner_State,
	banner_s:     f32, // seconds left of the rerouting banner
	warning:      [48]u8, // 0-terminated, empty = none
	manual:       bool,
	off_path_s:   f32,
	reroutes:     int,
	no_route:     bool, // the last reroute found no safe route, the old one is kept
	gust_next:    int, // slot of w.gust_zones the next report fills
	start_used:   f32, // ship counters at departure
	start_solar:  f32,
}

cstr :: proc(buf: []u8) -> string {
	return strings.truncate_to_byte(string(buf), 0)
}

hub_name :: proc(w: ^World, hub: int) -> string {
	if hub < 0 || hub >= w.m.hub_count do return ""
	return cstr(w.m.hubs[hub].name[:])
}

hub_top :: proc(w: ^World, hub: int) -> [3]f32 {
	p := w.m.hubs[hub].pos
	return {p.x, p.y, height_at(w, p.x, p.y) + HUB_TOWER_M}
}

// The layer nearest to an altitude, and its name in the UI ("Skyway 550").
layer_at :: proc(alt: f32) -> int {
	layers := LAYER_ALT
	best := 0
	for a, i in layers do if abs(alt - a) < abs(alt - layers[best]) do best = i
	return best
}

layer_name :: proc(buf: []u8, layer: int) -> string {
	layers := LAYER_ALT
	return fmt.bprintf(buf, "Skyway %.0f", layers[clamp(layer, 0, WIND_LAYERS - 1)])
}

COMPASS :: [8]string {
	"north",
	"north-east",
	"east",
	"south-east",
	"south",
	"south-west",
	"west",
	"north-west",
}

// Compass name of a heading (radians clockwise from north).
compass_name :: proc(heading: f32) -> string {
	names := COMPASS
	k := int(math.round(math.mod(heading + math.TAU, math.TAU) / (math.TAU / 8))) % 8
	return names[k]
}

heading_of :: proc(d: [2]f32) -> f32 {
	return math.atan2(d.x, -d.y)
}

// The forecast hour of the simulated time: while navigating the departure hour plus the flight time,
// otherwise the planned departure hour.
sim_hour :: proc(w: ^World) -> int {
	if w.nav.active do return w.nav.hour + int((w.tick - w.nav.start_tick) / (SIM_HZ * 3600))
	return w.plan.hour
}

// Metrics of a path flown at the mode's airspeed in the weather of hour (spec "evaluate"), plus the planned
// time and distance at every point. times and dist may be nil.
evaluate :: proc(
	w: ^World,
	path: [][3]f32,
	airspeed: f32,
	hour: int,
	times, dist: []f32,
) -> (
	s: Route_Summary,
) {
	wind_sum, tail_sum, gust_sum: f32
	if len(times) > 0 do times[0] = 0
	if len(dist) > 0 do dist[0] = 0
	for i in 1 ..< len(path) {
		a, b := path[i - 1], path[i]
		d := b.xy - a.xy
		km := linalg.length(d)
		dz := b.z - a.z
		mid := (a + b) * 0.5
		layer := layer_at(mid.z)
		wind := wind_at(w, mid.x, mid.y, layer, hour)
		gust := gust_at(w, mid.x, mid.y, layer, hour)
		cloud := cloud_at(w, mid.x, mid.y, hour)
		v := airspeed
		ground := v
		if km > 0 {
			dir := d / km
			g, ok := ground_speed(v, wind, dir)
			if !ok || g < GROUND_RETRY {
				v += GROUND_RETRY_BOOST
				g, ok = ground_speed(v, wind, dir)
			}
			// A path never has such a piece (route() blocks it), a straight baseline can: count it at the floor.
			ground = ok ? max(g, GROUND_MIN) : GROUND_MIN
			cross := abs(wind.x * dir.y - wind.y * dir.x)
			s.max_cross_ms = max(s.max_cross_ms, cross)
			tail_sum += linalg.dot(wind, dir) * km * 1000 / ground
		}
		dt := max(km * 1000 / ground, abs(dz) / EVAL_CLIMB_MS)
		s.seconds += dt
		s.km += km
		s.used_kwh += power_kw(v, gust) * dt / 3600 + climb_kwh(dz)
		s.solar_kwh += solar_kw(cloud) * dt / 3600
		s.climb_m += max(dz, 0)
		gust_sum += gust * dt
		wind_sum += linalg.length(wind) * dt
		if len(times) > i do times[i] = s.seconds
		if len(dist) > i do dist[i] = s.km
	}
	s.net_kwh = max(s.used_kwh - s.solar_kwh, 0)
	if s.seconds > 0 {
		s.gust = gust_sum / s.seconds
		s.wind_ms = wind_sum / s.seconds
		s.tail_ms = tail_sum / s.seconds
		s.minutes = s.seconds / 60
		s.kmh = s.km / (s.seconds / 3600)
	}
	return
}

// All three modes from hub from to hub to at forecast hour into w.routes, with metrics, tags, the one-line why
// and the maneuvers (spec "Plannen"). Resets w.plan_mem.
plan_routes :: proc(w: ^World, from, to: int, hour: int) {
	virtual.arena_free_all(&w.plan_mem)
	w.routes = {}
	if from < 0 || from >= w.m.hub_count || to < 0 || to >= w.m.hub_count do return
	a, b := hub_top(w, from), hub_top(w, to)
	for &r, mode in w.routes {
		t := prof_begin()
		path, ok := route(w, a, b, mode, hour)
		prof_end(w, .Route, t)
		if !ok do continue
		route_store(w, &r, path, mode, hour, from, to, true)
	}

	// Straight line baseline (spec): wind blind, at max(lowest layer, terrain + 80 m), greenest airspeed, the same
	// slope limit, flown through the real weather.
	layers := LAYER_ALT
	n := max(int(math.ceil(linalg.length(b.xy - a.xy) / RESAMPLE_KM)), 1) + 1
	line := make([][3]f32, n, context.temp_allocator)
	for &p, i in line {
		xy := linalg.lerp(a.xy, b.xy, f32(i) / f32(n - 1))
		p = {xy.x, xy.y, max(layers[0], height_at(w, xy.x, xy.y) + BASELINE_ABOVE_TERRAIN_M)}
	}
	line[0].z = a.z + TOWER_ABOVE_M
	line[n - 1].z = b.z + TOWER_ABOVE_M
	for i in 1 ..< n - 1 {
		line[i].z = min(
			line[i].z,
			line[i - 1].z + SLOPE_MAX * linalg.length(line[i].xy - line[i - 1].xy) * 1000,
		)
	}
	for i := n - 2; i > 0; i -= 1 {
		line[i].z = min(
			line[i].z,
			line[i + 1].z + SLOPE_MAX * linalg.length(line[i + 1].xy - line[i].xy) * 1000,
		)
	}
	airspeeds := MODE_AIRSPEED
	base := evaluate(w, line, airspeeds[.Greenest], hour, nil, nil)

	green := w.routes[.Greenest]
	for &r, mode in w.routes {
		if !r.ok do continue
		if base.net_kwh > 0 do r.sum.vs_straight = r.sum.net_kwh / base.net_kwh - 1
		if green.ok && green.sum.net_kwh > 0 do r.sum.vs_greenest = r.sum.net_kwh / green.sum.net_kwh - 1
		switch mode {
		case .Greenest:
			r.sum.tag = .Lowest_Energy
		case .Fastest:
			r.sum.tag = green.ok ? .Extra_Energy : .None
		case .Calmest:
			r.sum.tag = .Gust_Index
		}
	}
}

// Copies a route() path into w.plan_mem and fills the rest of r. depart: start with a Depart maneuver (a
// reroute drops it, spec).
route_store :: proc(
	w: ^World,
	r: ^Planned_Route,
	path: [][3]f32,
	mode: Route_Mode,
	hour, from, to: int,
	depart: bool,
) {
	alloc := virtual.arena_allocator(&w.plan_mem)
	r^ = {}
	r.path = make([][3]f32, len(path), alloc)
	copy(r.path, path)
	r.times = make([]f32, len(path), alloc)
	r.dist = make([]f32, len(path), alloc)
	airspeeds := MODE_AIRSPEED
	r.sum = evaluate(w, r.path, airspeeds[mode], hour, r.times, r.dist)
	r.ok = true

	// Why: the layers it cruises in (at least WHY_LAYER_SHARE of the distance, the climb out and the approach
	// do not count), in the order it reaches them, and the hub it passes closest to halfway.
	{
		km: [WIND_LAYERS]f32
		first: [WIND_LAYERS]int
		for &f in first do f = len(r.path)
		for i in 1 ..< len(r.path) {
			l := layer_at(r.path[i].z)
			km[l] += r.dist[i] - r.dist[i - 1]
			// Order by where it cruises: a layer only passed through on a climb comes later.
			if abs(r.path[i].z - r.path[i - 1].z) <= LEVEL_M do first[l] = min(first[l], i)
		}
		total := max(r.dist[len(r.dist) - 1], 1e-3)
		top := 0
		for l in 1 ..< WIND_LAYERS do if km[l] > km[top] do top = l
		b := strings.builder_from_bytes(r.sum.why[:len(r.sum.why) - 1])
		strings.write_string(&b, "Via ")
		written := 0
		for _ in 0 ..< WIND_LAYERS {
			// The next layer by first point among the ones not written yet.
			next := -1
			for l in 0 ..< WIND_LAYERS {
				if km[l] < WHY_LAYER_SHARE * total && l != top do continue
				if next < 0 || first[l] < first[next] do next = l
			}
			if next < 0 do break
			if written > 0 do strings.write_string(&b, " and ")
			buf: [16]u8
			strings.write_string(&b, layer_name(buf[:], next))
			km[next], first[next] = -1, len(r.path)
			if next == top do top = -1
			written += 1
		}
		mid := r.path[len(r.path) / 2].xy
		best, best_d := -1, f32(math.F32_MAX)
		for i in 0 ..< w.m.hub_count {
			if i == from || i == to do continue
			if d := linalg.length(w.m.hubs[i].pos - mid); d < best_d do best, best_d = i, d
		}
		if best >= 0 && best_d < 25 do fmt.sbprintf(&b, ", past %s", hub_name(w, best))
	}

	r.maneuvers = build_maneuvers(w, r, from, to, hour, depart, alloc)
}

LEVEL_M :: 0.5 // a path step that changes the altitude less than this is level flight
WHY_LAYER_SHARE :: 0.2 // a layer is named in the route's why from this share of its distance

// Spec "buildManeuvers", adapted to RESAMPLE_KM points: depart, turns, altitude changes, long legs, arrive,
// sorted along the path, events closer than MERGE_KM keep the most important one.
build_maneuvers :: proc(
	w: ^World,
	r: ^Planned_Route,
	from, to, hour: int,
	depart: bool,
	alloc := context.allocator,
) -> []Maneuver {
	path, dist := r.path, r.dist
	n := len(path)
	total := dist[n - 1]
	events := make([dynamic]Maneuver, 0, 32, context.temp_allocator)

	// Index of the first point at least km further along than point i (or the last one).
	ahead :: proc(dist: []f32, i: int, km: f32) -> int {
		j := i
		for j < len(dist) - 1 && dist[j] - dist[i] < km do j += 1
		return j
	}
	behind :: proc(dist: []f32, i: int, km: f32) -> int {
		j := i
		for j > 0 && dist[i] - dist[j] < km do j -= 1
		return j
	}
	ev :: proc(events: ^[dynamic]Maneuver, kind: Maneuver_Kind, i: int, dist: []f32) -> ^Maneuver {
		append(events, Maneuver{kind = kind, path_index = i, s_km = dist[i]})
		return &events[len(events) - 1]
	}

	hour := hour
	if depart {
		j := ahead(dist, 0, 1)
		m := ev(&events, .Depart, 0, dist)
		fmt.bprintf(m.text[:len(m.text) - 1], "Head %s", compass_name(heading_of(path[j].xy - path[0].xy)))
		fmt.bprintf(m.sub[:len(m.sub) - 1], "Leave %s and climb", hub_name(w, from))
	}

	// Turns: heading change over TURN_WINDOW_KM before and after, a local maximum.
	{
		delta := make([]f32, n, context.temp_allocator)
		for i in 1 ..< n - 1 {
			p, q := behind(dist, i, TURN_WINDOW_KM), ahead(dist, i, TURN_WINDOW_KM)
			if p == i || q == i do continue
			h0 := heading_of(path[i].xy - path[p].xy)
			h1 := heading_of(path[q].xy - path[i].xy)
			delta[i] = math.mod(h1 - h0 + 3 * math.PI, math.TAU) - math.PI
		}
		last_turn := f32(-1e9)
		for i in 1 ..< n - 1 {
			d := delta[i]
			if abs(d) <= TURN_MIN_RAD || dist[i] < TURN_START_KM || total - dist[i] < TURN_END_KM do continue
			if dist[i] - last_turn < TURN_GAP_KM do continue
			local_max := true
			for j in behind(dist, i, TURN_WINDOW_KM) ..= ahead(dist, i, TURN_WINDOW_KM) {
				if abs(delta[j]) > abs(d) do local_max = false
			}
			if !local_max do continue
			last_turn = dist[i]
			left := d < 0
			kind: Maneuver_Kind
			verb: string
			switch {
			case abs(d) > TURN_SHARP_RAD:
				kind, verb = left ? .Sharp_Left : .Sharp_Right, "Turn sharp"
			case abs(d) > TURN_NORMAL_RAD:
				kind, verb = left ? .Left : .Right, "Turn"
			case:
				kind, verb = left ? .Slight_Left : .Slight_Right, "Bear"
			}
			m := ev(&events, kind, i, dist)
			q := ahead(dist, i, TURN_WINDOW_KM)
			dir := linalg.normalize0(path[q].xy - path[i].xy)
			// The hub in the new direction, closer ones first (spec score cos / (1 + d / 2500 m), scaled).
			toward, score := -1, f32(0)
			for h in 0 ..< w.m.hub_count {
				off := w.m.hubs[h].pos - path[i].xy
				hd := linalg.length(off)
				if hd < TOWARD_MIN_KM || hd > TOWARD_MAX_KM do continue
				c := linalg.dot(off / hd, dir)
				if c > TOWARD_COS && c / (1 + hd / 25) > score do toward, score = h, c / (1 + hd / 25)
			}
			side := left ? "left" : "right"
			if toward >= 0 {
				fmt.bprintf(m.text[:len(m.text) - 1], "%s %s toward %s", verb, side, hub_name(w, toward))
			} else {
				fmt.bprintf(m.text[:len(m.text) - 1], "%s %s", verb, side)
			}
			wind := wind_at(w, path[i].x, path[i].y, layer_at(path[i].z), hour)
			tail := linalg.dot(wind, dir)
			fmt.bprintf(
				m.sub[:len(m.sub) - 1],
				"%s %.0f m/s",
				tail >= 0 ? "Tailwind" : "Headwind",
				abs(tail),
			)
		}
	}

	// Altitude changes: more than ALT_CHANGE_M within ALT_WINDOW_KM, one event per change.
	for i := 1; i < n - 1; {
		j := ahead(dist, i, ALT_WINDOW_KM)
		dz := path[j].z - path[i].z
		if abs(dz) <= ALT_CHANGE_M || dist[i] < TURN_START_KM || total - dist[i] < TURN_END_KM {
			i += 1
			continue
		}
		// Follow the change until it stops, the new layer is where it levels out.
		k := j
		for k < n - 1 && (path[k + 1].z - path[k].z) * dz > 0 do k += 1
		up := dz > 0
		m := ev(&events, up ? .Climb : .Descend, i, dist)
		buf: [16]u8
		name := layer_name(buf[:], layer_at(path[k].z))
		verb := up ? "Climb" : "Descend"
		switch {
		case k >= n - 1:
			// The approach: the tower is the goal, not the layer its platform happens to be in.
			fmt.bprintf(m.text[:len(m.text) - 1], "%s to the %s tower", verb, hub_name(w, to))
		case layer_at(path[k].z) != layer_at(path[i].z):
			fmt.bprintf(m.text[:len(m.text) - 1], "%s to %s", verb, name)
		case:
			fmt.bprintf(m.text[:len(m.text) - 1], "%s to %.0f m", verb, path[k].z)
		}
		dir := linalg.normalize0(path[k].xy - path[i].xy)
		gain := linalg.dot(wind_at(w, path[k].x, path[k].y, layer_at(path[k].z), hour), dir)
		gain -= linalg.dot(wind_at(w, path[i].x, path[i].y, layer_at(path[i].z), hour), dir)
		if gain > 0.5 {
			fmt.bprintf(
				m.sub[:len(m.sub) - 1],
				"%.0f m, +%.0f m/s tailwind %s",
				path[k].z,
				gain,
				up ? "above" : "below",
			)
		} else {
			fmt.bprintf(m.sub[:len(m.sub) - 1], "%.0f m, smoother air %s", path[k].z, up ? "above" : "below")
		}
		i = k + 1
	}

	{
		m := ev(&events, .Arrive, n - 1, dist)
		fmt.bprintf(m.text[:len(m.text) - 1], "Dock at %s", hub_name(w, to))
		fmt.bprintf(m.sub[:len(m.sub) - 1], "Platform at %.0f m", path[n - 1].z - TOWER_ABOVE_M)
	}

	// Sort by distance along the path (insertion sort, a few dozen events).
	for i in 1 ..< len(events) {
		for j := i; j > 0 && events[j].s_km < events[j - 1].s_km; j -= 1 {
			events[j], events[j - 1] = events[j - 1], events[j]
		}
	}
	// Merge: arrive > depart > altitude > turn > straight.
	rank :: proc(k: Maneuver_Kind) -> int {
		#partial switch k {
		case .Arrive:
			return 4
		case .Depart:
			return 3
		case .Climb, .Descend:
			return 2
		case .Straight:
			return 0
		}
		return 1
	}
	merged := make([dynamic]Maneuver, 0, len(events) + 8, context.temp_allocator)
	for e in events {
		if len(merged) > 0 && e.s_km - merged[len(merged) - 1].s_km < MERGE_KM {
			if rank(e.kind) > rank(merged[len(merged) - 1].kind) do merged[len(merged) - 1] = e
			continue
		}
		// A long leg gets a "Continue" just after the event before it.
		if len(merged) > 0 && e.s_km - merged[len(merged) - 1].s_km > STRAIGHT_KM {
			prev := merged[len(merged) - 1]
			i := ahead(dist, prev.path_index, MERGE_KM + 0.25)
			// Where the climb or descent of the event before levels out: the layer the leg cruises in.
			for i < e.path_index - 1 && abs(path[i + 1].z - path[i].z) > LEVEL_M do i += 1
			s := Maneuver {
				kind       = .Straight,
				path_index = i,
				s_km       = dist[i],
			}
			buf: [16]u8
			fmt.bprintf(s.text[:len(s.text) - 1], "Continue on %s", layer_name(buf[:], layer_at(path[i].z)))
			fmt.bprintf(s.sub[:len(s.sub) - 1], "for %.0f km", e.s_km - dist[i])
			append(&merged, s)
		}
		append(&merged, e)
	}

	out := make([]Maneuver, len(merged), alloc)
	copy(out, merged[:])
	for &m in out {
		p := path[m.path_index]
		name, _, found := map_nearest_name(w, p.xy, ROAD_NAME_KM)
		if found {
			// Cut on a character boundary: a long bilingual Brussels name must not end in half a letter.
			keep := min(len(name), len(m.road) - 1)
			for keep > 0 && keep < len(name) && name[keep] & 0xc0 == 0x80 do keep -= 1
			copy(m.road[:], name[:keep])
		} else {
			layer_name(m.road[:len(m.road) - 1], layer_at(p.z))
		}
	}
	return out
}

// Position and heading at t 0..1 of the way along the chosen route (by distance), for the preview camera.
route_sample :: proc(w: ^World, mode: Route_Mode, t: f32) -> (pos: [3]f32, heading: f32) {
	r := &w.routes[mode]
	if !r.ok || len(r.path) < 2 do return {}, 0
	s := clamp(t, 0, 1) * r.dist[len(r.dist) - 1]
	i := 0
	for i < len(r.dist) - 2 && r.dist[i + 1] < s do i += 1
	seg := r.dist[i + 1] - r.dist[i]
	f := seg > 0 ? clamp((s - r.dist[i]) / seg, 0, 1) : 0
	pos = linalg.lerp(r.path[i], r.path[i + 1], f)
	// Heading over about a kilometre, so the camera does not twitch on every path point.
	j := i
	for j < len(r.path) - 1 && r.dist[j] - r.dist[i] < 1 do j += 1
	k := i
	for k > 0 && r.dist[i] - r.dist[k] < 1 do k -= 1
	heading = heading_of(r.path[j].xy - r.path[k].xy)
	return
}

// Starts navigating the planned route of mode: the ship goes to the departure tower, the autopilot flies.
nav_start :: proc(w: ^World, mode: Route_Mode) -> bool {
	r := &w.routes[mode]
	if !r.ok do return false
	n := &w.nav
	n^ = {
		active      = true,
		mode        = mode,
		from        = w.plan.from,
		to          = w.plan.to,
		hour        = w.plan.hour,
		start_tick  = w.tick,
		start_used  = w.ship.used_kwh,
		start_solar = w.ship.solar_kwh,
		gust_next   = n.gust_next,
	}
	s := &w.ship
	s.pos = r.path[0].xy
	s.alt = r.path[0].z
	s.speed = 0
	s.turn_rate = 0
	s.moored = false
	if len(r.path) > 1 do s.heading = heading_of(r.path[1].xy - r.path[0].xy)
	nav_update(w, 0)
	return true
}

nav_stop :: proc(w: ^World) {
	w.nav.active = false
}

// Manual flying (keys or the self-fly button) or the autopilot. Routing and rerouting go on in both.
nav_set_manual :: proc(w: ^World, on: bool) {
	w.nav.manual = on
}

// The active route, nil when not navigating.
nav_route :: proc(w: ^World) -> ^Planned_Route {
	if !w.nav.active || !w.routes[w.nav.mode].ok do return nil
	return &w.routes[w.nav.mode]
}

// Once per fixed step while navigating, after ship_step: place on the path, next maneuver, ETA, warnings,
// rerouting and arrival.
nav_update :: proc(w: ^World, dt: f32) {
	n := &w.nav
	r := nav_route(w)
	if r == nil do return
	s := &w.ship
	if n.banner_s > 0 {
		n.banner_s = max(n.banner_s - dt, 0)
		if n.banner_s == 0 && n.banner == .Rerouting do n.banner = .Flying
	}
	n.used_kwh = (s.used_kwh - n.start_used) - (s.solar_kwh - n.start_solar)
	n.solar_kwh = s.solar_kwh - n.start_solar
	if n.banner == .Arrived do return

	// Closest point on the path in a window around the last one (spec: -30 .. +90 points of 20 m).
	path, dist := r.path, r.dist
	best_d := f32(math.F32_MAX)
	lo := max(n.path_index - 4, 0)
	hi := min(n.path_index + 12, len(path) - 2)
	for i in lo ..= hi {
		a, b := path[i].xy, path[i + 1].xy
		ab := b - a
		l2 := linalg.length2(ab)
		f := l2 > 0 ? clamp(linalg.dot(s.pos - a, ab) / l2, 0, 1) : 0
		d := linalg.length(s.pos - (a + ab * f))
		if d < best_d {
			best_d = d
			n.path_index = i
			n.s_km = dist[i] + (dist[i + 1] - dist[i]) * f
		}
	}
	last := len(path) - 1

	// Rerouting (spec): more than OFF_PATH_KM beside the path for OFF_PATH_S, scaled by the sim speed.
	speeds := SIM_SPEEDS
	if best_d > OFF_PATH_KM {
		n.off_path_s += dt
		if n.off_path_s > OFF_PATH_S * f32(speeds[w.sim_speed]) {
			n.off_path_s = 0
			nav_reroute(w)
			return
		}
	} else {
		n.off_path_s = 0
	}

	// Next maneuver, the one after it within THEN_KM, remaining time and distance from the planned times.
	n.next = len(r.maneuvers)
	for m, i in r.maneuvers {
		if m.s_km > n.s_km + BANNER_AHEAD_KM {
			n.next = i
			break
		}
	}
	n.then_visible = false
	if n.next < len(r.maneuvers) {
		n.next_m = (r.maneuvers[n.next].s_km - n.s_km) * 1000
		n.then_visible =
			n.next + 1 < len(r.maneuvers) &&
			r.maneuvers[n.next + 1].s_km - r.maneuvers[n.next].s_km < THEN_KM
	}
	i := n.path_index
	seg := dist[i + 1] - dist[i]
	f := seg > 0 ? (n.s_km - dist[i]) / seg : 0
	n.eta_s = max(r.times[last] - (r.times[i] + (r.times[i + 1] - r.times[i]) * f), 0)
	n.remaining_km = max(dist[last] - n.s_km, 0)

	// Warning: a no-fly zone the path enters below its ceiling, or a reported gust zone, in the next km.
	n.warning = {}
	warn: for j in i ..= last {
		if dist[j] - n.s_km > WARNING_AHEAD_KM do break
		p := path[j]
		for z in w.no_fly {
			if z.radius > 0 && p.z < z.ceiling && linalg.length(p.xy - z.center) < z.radius {
				fmt.bprintf(
					n.warning[:len(n.warning) - 1],
					"No-fly zone ahead, climb above %.0f m",
					z.ceiling,
				)
				break warn
			}
		}
		for z in w.gust_zones {
			if z.radius > 0 && linalg.length(p.xy - z.center) < z.radius + 0.3 {
				fmt.bprintf(n.warning[:len(n.warning) - 1], "Gust zone ahead, keep clear")
				break warn
			}
		}
	}

	if s.docked && s.dock_hub == n.to {
		n.banner = .Arrived
		n.eta_s = 0
		n.remaining_km = 0
		n.next = len(r.maneuvers)
		s.moored = true
		logf(w, "nav", "docked at %s, %.2f kWh net, %d reroutes", hub_name(w, n.to), n.used_kwh, n.reroutes)
	}
}

// A new route of the same mode from the ship's position and altitude (spec: a pseudo-hub whose top is the
// current altitude) to the destination tower, in the current forecast hour.
nav_reroute :: proc(w: ^World) {
	n := &w.nav
	s := &w.ship
	from := [3]f32{s.pos.x, s.pos.y, s.alt - TOWER_ABOVE_M}
	hour := sim_hour(w)
	t := prof_begin()
	path, ok := route(w, from, hub_top(w, n.to), n.mode, hour)
	prof_end(w, .Route, t)
	n.reroutes += 1
	n.banner = .Rerouting
	n.banner_s = REROUTE_BANNER_S
	if !ok {
		n.no_route = true
		logf(w, "nav", "reroute %d: no safe route from %v, keeping the old one", n.reroutes, s.pos)
		return
	}
	n.no_route = false
	r := &w.routes[n.mode]
	route_store(w, r, path, n.mode, hour, n.from, n.to, false)
	// The planned times now count from here: the ETA and the warnings start over on the new path.
	n.path_index = 0
	n.s_km = 0
	logf(w, "nav", "reroute %d: %d points, %.1f km", n.reroutes, len(path), r.sum.km)
}

// "Report gust" (spec "Gust melden"): a zone of GUST_RADIUS_KM on the path GUST_AHEAD_KM ahead of the ship, then
// an immediate reroute around it. Fills the gust zone slots in turn, the oldest goes when all are used.
gust_report :: proc(w: ^World) -> bool {
	n := &w.nav
	r := nav_route(w)
	if r == nil || n.banner == .Arrived do return false
	j := n.path_index
	for j < len(r.path) - 1 && r.dist[j] - n.s_km < GUST_AHEAD_KM do j += 1
	w.gust_zones[n.gust_next] = {r.path[j].xy, GUST_RADIUS_KM}
	logf(w, "nav", "gust reported at %v (slot %d)", r.path[j].xy, n.gust_next)
	n.gust_next = (n.gust_next + 1) % MAX_GUST_ZONES
	nav_reroute(w)
	return true
}

// The autopilot (spec): follow a lookahead point on the path, crab into the wind, slow down near the tower.
// Returns the Controls that ship_step takes, so manual flying and the autopilot go through the same step.
nav_autopilot :: proc(w: ^World) -> Controls {
	n := &w.nav
	r := nav_route(w)
	s := &w.ship
	if r == nil || n.banner == .Arrived do return {}
	path, dist := r.path, r.dist
	last := len(path) - 1

	// Lookahead point AP_LOOKAHEAD_KM along the path from the ship.
	look := path[last]
	target_s := n.s_km + AP_LOOKAHEAD_KM
	for i in n.path_index ..< last {
		if dist[i + 1] >= target_s {
			seg := dist[i + 1] - dist[i]
			look = linalg.lerp(path[i], path[i + 1], seg > 0 ? (target_s - dist[i]) / seg : 0)
			break
		}
	}
	to_goal := linalg.length(path[last].xy - s.pos)
	if to_goal < AP_LOOKAHEAD_KM do look = path[last]

	airspeeds := MODE_AIRSPEED
	v := airspeeds[n.mode]
	wind := wind_at(w, s.pos.x, s.pos.y, layer_at(s.alt), sim_hour(w))
	d := linalg.normalize0(look.xy - s.pos)
	ground, ok := ground_speed(v, wind, d)
	if !ok || ground < GROUND_RETRY {
		v += GROUND_RETRY_BOOST
		ground, ok = ground_speed(v, wind, d)
		if !ok do ground = GROUND_MIN
	}
	// Near the tower: slow the ground speed down to the distance, the air vector still holds against the wind.
	if to_goal < AP_SLOW_KM do ground = max(ground * to_goal / AP_SLOW_KM, 0)
	air := d * ground - wind
	speed := linalg.length(air)
	if to_goal < AP_SLOW_KM do speed = max(speed, min(AP_MIN_SPEED, to_goal * 1000 * 0.05 + linalg.length(wind)))
	heading := speed > 0.1 ? heading_of(air) : s.heading

	c: Controls
	diff := math.mod(heading - s.heading + 3 * math.PI, math.TAU) - math.PI
	c.turn = clamp(diff * AP_TURN_GAIN, -AP_MAX_TURN, AP_MAX_TURN) / SHIP_MAX_TURN_RATE
	c.throttle = clamp(speed / SHIP_MAX_SPEED, 0, 1)
	goal_alt := look.z
	if to_goal < AP_SLOW_KM do goal_alt = hub_top(w, n.to).z + DOCK_ABOVE_M
	c.climb = clamp((goal_alt - s.alt) * AP_CLIMB_GAIN, -AP_MAX_CLIMB, AP_MAX_CLIMB) / SHIP_CLIMB_RATE
	return c
}

// Banner distance (spec): >= 1 km in km with one decimal, >= 100 m rounded to 50 m, else to 10 m.
format_distance :: proc(buf: []u8, m: f32) -> (value: string, unit: string) {
	switch {
	case m >= 1000:
		return fmt.bprintf(buf, "%.1f", m / 1000), "km"
	case m >= 100:
		return fmt.bprintf(buf, "%.0f", math.round(m / 50) * 50), "m"
	}
	return fmt.bprintf(buf, "%.0f", math.round(m / 10) * 10), "m"
}
