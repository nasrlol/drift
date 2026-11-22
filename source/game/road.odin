// author: lars
package game

import "core:math"
import "core:math/linalg"
import "core:mem/virtual"

// Landing picks a road this close. The road graph holds the secondary roads and up, so in a city centre the
// nearest one can be 700 m away (Brussels hub: 660 m). Not from the spec or design, see the PR assumptions.
ROAD_LAND_KM :: 1.0

// The airship as a flying car (#67 part 2, #68 option B): on the ground it is locked to the road graph of
// belgium.bin. Its place is an edge and a distance along it, never a free x, y. It lands on a road by descending
// to its lowest height within ROAD_LAND_KM of an edge, and takes off again by climbing (both gradual, see below).
// Throttle drives along the edge (same speed limits as flying), turn picks the next edge at a junction, a
// one-way road is only ever driven its own way. No wind on the ground.

// Road segments per ROAD_CELL_KM cell of the map, for road_nearest_edge: items[cells[c] : cells[c + 1]] for
// cell c = y * ROAD_CELLS_W + x, each item an edge index and the index of the segment's first point in
// road_points. A segment is in every cell its bounding box touches, cells outside the map are clamped to the
// border. Built once from w.m (indices, no pointers, so it stays valid after a hot reload), in w.perm.
ROAD_CELL_KM :: ROAD_LAND_KM
ROAD_CELLS_W :: int(MAP_W_KM / ROAD_CELL_KM) + 1
ROAD_CELLS_H :: int(MAP_H_KM / ROAD_CELL_KM) + 1
Road_Index :: struct {
	cells: []u32,
	items: [][2]u32,
	built: bool,
}

road_cell_range :: proc(lo, hi: [2]f32) -> (x0, y0, x1, y1: int) {
	x0 = clamp(int(math.floor(lo.x / ROAD_CELL_KM)), 0, ROAD_CELLS_W - 1)
	x1 = clamp(int(math.floor(hi.x / ROAD_CELL_KM)), 0, ROAD_CELLS_W - 1)
	y0 = clamp(int(math.floor(lo.y / ROAD_CELL_KM)), 0, ROAD_CELLS_H - 1)
	y1 = clamp(int(math.floor(hi.y / ROAD_CELL_KM)), 0, ROAD_CELLS_H - 1)
	return
}

// Two passes over the segments: count per cell, then fill.
road_index_build :: proc(w: ^World) {
	ri := &w.road_index
	ri.built = true
	perm := virtual.arena_allocator(&w.perm)
	counts := make([]u32, ROAD_CELLS_W * ROAD_CELLS_H + 1, perm)
	for pass in 0 ..< 2 {
		for e, ei in w.m.road_edges {
			for k in e.start + 1 ..< e.start + e.count {
				a, b := w.m.road_points[k - 1], w.m.road_points[k]
				x0, y0, x1, y1 := road_cell_range(linalg.min(a, b), linalg.max(a, b))
				for y in y0 ..= y1 {
					for x in x0 ..= x1 {
						c := y * ROAD_CELLS_W + x
						if pass == 0 {
							counts[c + 1] += 1
						} else {
							ri.items[ri.cells[c] + counts[c]] = {u32(ei), k - 1}
							counts[c] += 1
						}
					}
				}
			}
		}
		if pass == 0 {
			for c in 1 ..< len(counts) do counts[c] += counts[c - 1]
			ri.cells = counts
			ri.items = make([][2]u32, counts[len(counts) - 1], perm)
			counts = make([]u32, ROAD_CELLS_W * ROAD_CELLS_H + 1, context.temp_allocator)
		}
	}
}

// The edge nearest to pos within radius_km, and the distance along it in km. Searches only the cells within
// radius_km of pos. The closest point of a segment within radius_km lies in a cell of both the segment's box and
// the searched square, so no segment is missed. Equal distances keep the lowest edge, then the lowest point,
// as a scan of all road points in order would, and the distance along is summed in the same order.
road_nearest_edge :: proc(w: ^World, pos: [2]f32, radius_km: f32) -> (edge: int, s_km: f32, ok: bool) {
	if !(abs(pos.x) < math.F32_MAX && abs(pos.y) < math.F32_MAX) do return
	if !w.road_index.built do road_index_build(w)
	ri := &w.road_index
	best := radius_km
	best_item: [2]u32
	best_f: f32
	x0, y0, x1, y1 := road_cell_range(pos - radius_km, pos + radius_km)
	for y in y0 ..= y1 {
		for x in x0 ..= x1 {
			c := y * ROAD_CELLS_W + x
			for item in ri.items[ri.cells[c]:ri.cells[c + 1]] {
				a, b := w.m.road_points[item[1]], w.m.road_points[item[1] + 1]
				ab := b - a
				l2 := linalg.length2(ab)
				f := l2 > 0 ? clamp(linalg.dot(pos - a, ab) / l2, 0, 1) : 0
				d := linalg.length(pos - (a + ab * f))
				earlier := item[0] < best_item[0] || (item[0] == best_item[0] && item[1] < best_item[1])
				if d < best || (ok && d == best && earlier) {
					best, best_item, best_f, ok = d, item, f, true
				}
			}
		}
	}
	if !ok do return
	e := w.m.road_edges[best_item[0]]
	along: f32
	for k in e.start + 1 ..= best_item[1] {
		along += math.sqrt(linalg.length2(w.m.road_points[k] - w.m.road_points[k - 1]))
	}
	seg := math.sqrt(linalg.length2(w.m.road_points[best_item[1] + 1] - w.m.road_points[best_item[1]]))
	return int(best_item[0]), along + seg * best_f, true
}

// Polyline length of an edge in km (length_km is the unsimplified way, the drawn geometry is what we drive on).
road_edge_km :: proc(w: ^World, edge: int) -> f32 {
	e := w.m.road_edges[edge]
	pts := w.m.road_points[e.start:][:e.count]
	km: f32
	for i in 1 ..< len(pts) do km += linalg.length(pts[i] - pts[i - 1])
	return km
}

// Position and heading at s_km along an edge.
road_at :: proc(w: ^World, edge: int, s_km: f32) -> (pos: [2]f32, heading: f32) {
	e := w.m.road_edges[edge]
	pts := w.m.road_points[e.start:][:e.count]
	along: f32
	for i in 1 ..< len(pts) {
		seg := linalg.length(pts[i] - pts[i - 1])
		if along + seg >= s_km || i == len(pts) - 1 {
			f := seg > 0 ? clamp((s_km - along) / seg, 0, 1) : 0
			return linalg.lerp(pts[i - 1], pts[i], f), heading_of(pts[i] - pts[i - 1])
		}
		along += seg
	}
	return pts[0], 0
}

// Heading at the start of an edge.
road_start_heading :: proc(w: ^World, edge: int) -> f32 {
	e := w.m.road_edges[edge]
	pts := w.m.road_points[e.start:][:e.count]
	return heading_of(pts[1] - pts[0])
}

// At the end of edge: the next edge out of its to-node. turn -1..1 bends the wanted heading up to 90 degrees left
// or right of the current one, the edge whose start heading is closest wins. Turning back onto the same road
// (the reverse edge) only at a dead end. -1 when the node has no edge out (a one-way dead end).
road_next_edge :: proc(w: ^World, edge: int, heading: f32, turn: f32) -> int {
	e := w.m.road_edges[edge]
	node := w.m.road_nodes[e.to]
	want := heading + clamp(turn, -1, 1) * math.PI / 2
	best, best_diff := -1, f32(math.F32_MAX)
	back := -1
	for k in node.first ..< node.first + node.count {
		o := w.m.road_edges[k]
		if o.to == e.from && o.count == e.count {
			back = int(k)
			continue
		}
		diff := abs(math.mod(road_start_heading(w, int(k)) - want + 3 * math.PI, math.TAU) - math.PI)
		if diff < best_diff do best, best_diff = int(k), diff
	}
	return best >= 0 ? best : back
}

// Landing and take-off are gradual (Lars, 2026-11-21: a transition between driving and flying). Landing: the
// ship slides onto the road and turns to its heading over ROAD_ALIGN_S while it sinks ROAD_DESCENT_MS from the
// lowest flying height to the road, driving on meanwhile. Take-off: it climbs at least ROAD_LIFT_MS until the
// lowest flying height, the floor does not snap it up. Our values, not from the spec or design.
ROAD_DESCENT_MS :: 4.0
ROAD_LIFT_MS :: 10.0
ROAD_ALIGN_S :: 2.5

// Throttle on the ground: slower than flying, 126 km/h at most. Coming down faster than that, the car brakes.
ROAD_MAX_SPEED :: 35.0
ROAD_ACCEL :: 1.2
ROAD_BRAKE :: 1.6

road_speed :: proc(w: ^World, c: Controls, dt: f32) {
	s := &w.ship
	target := max(c.throttle, 0) * ROAD_MAX_SPEED / ship_jam_factor(w)
	if target > s.speed {
		s.speed = min(s.speed + ROAD_ACCEL * dt, target)
	} else {
		s.speed = max(s.speed - (s.speed > ROAD_MAX_SPEED ? SHIP_BRAKE : ROAD_BRAKE) * dt, target)
	}
}

// Moves road_s on by the speed, onto the next edge at a junction (turn picks it), stops at a dead end.
road_advance :: proc(w: ^World, c: Controls, dt: f32) {
	s := &w.ship
	s.road_s += s.speed * dt / 1000
	for s.road_s > road_edge_km(w, s.road_edge) {
		over := s.road_s - road_edge_km(w, s.road_edge)
		_, h := road_at(w, s.road_edge, s.road_s)
		next := road_next_edge(w, s.road_edge, h, c.turn)
		if next < 0 {
			// A dead end: stop at the node.
			s.road_s = road_edge_km(w, s.road_edge)
			s.speed = 0
			break
		}
		s.road_edge, s.road_s = next, over
	}
}

// One fixed step on the road. Returns false when the ship took off (climb > 0): ship_step then flies on.
road_step :: proc(w: ^World, c: Controls, dt: f32) -> bool {
	s := &w.ship
	if c.climb > 0 {
		s.on_road = false
		s.lifting = true
		return false
	}
	road_speed(w, c, dt)
	road_advance(w, c, dt)
	s.pos, s.heading = road_at(w, s.road_edge, s.road_s)
	s.alt = height_at(w, s.pos.x, s.pos.y)
	s.turn_rate = 0
	s.used_kwh += power_kw(s.speed, 0) * dt / 3600
	s.solar_kwh +=
		solar_kw(cloud_at(w, s.pos.x, s.pos.y, sim_hour(w)), sun_factor(w, sim_hour(w))) * dt / 3600
	s.warnings = {}
	s.docked = false
	return true
}

// One fixed step of a landing. Returns false when the pilot climbs again: the landing is called off and
// ship_step flies on.
road_landing_step :: proc(w: ^World, c: Controls, dt: f32) -> bool {
	s := &w.ship
	if c.climb > 0 {
		s.landing = false
		return false
	}
	road_speed(w, c, dt)
	road_advance(w, c, dt)
	goal, h := road_at(w, s.road_edge, s.road_s)
	k := min(dt / ROAD_ALIGN_S, 1)
	s.pos += (goal - s.pos) * k
	diff := math.mod(h - s.heading + 3 * math.PI, math.TAU) - math.PI
	s.heading = math.mod(s.heading + diff * k + math.TAU, math.TAU)
	s.turn_rate = diff * k / dt
	ground := height_at(w, goal.x, goal.y)
	s.alt = max(s.alt - ROAD_DESCENT_MS * dt, ground)
	s.used_kwh += power_kw(s.speed, 0) * dt / 3600
	s.solar_kwh +=
		solar_kw(cloud_at(w, s.pos.x, s.pos.y, sim_hour(w)), sun_factor(w, sim_hour(w))) * dt / 3600
	s.warnings = {}
	s.docked = false
	if s.alt <= ground {
		s.landing = false
		s.on_road = true
		s.pos, s.heading = goal, h
		s.turn_rate = 0
	}
	return true
}

// Landing starts: at the lowest flying height, descending, within ROAD_LAND_KM of a road.
road_try_land :: proc(w: ^World, c: Controls) {
	s := &w.ship
	floor := height_at(w, s.pos.x, s.pos.y) + SHIP_MIN_CLEARANCE
	if s.lifting || c.climb >= 0 || s.alt > floor + 0.5 || len(w.m.road_edges) == 0 do return
	edge, along, ok := road_nearest_edge(w, s.pos, ROAD_LAND_KM)
	if !ok do return
	s.landing = true
	s.road_edge, s.road_s = edge, along
	logf(
		w,
		"ship",
		"landing on road edge %d (%v), %.3f km along",
		edge,
		Map_Kind(w.m.road_edges[edge].kind),
		along,
	)
}
