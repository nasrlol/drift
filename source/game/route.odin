package game

import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:mem/virtual"

Route_Mode :: enum u8 {
	Fastest,
	Greenest,
	Calmest,
}

// Cruise airspeed per mode in m/s (spec).
MODE_AIRSPEED :: [Route_Mode]f32 {
	.Fastest  = 18,
	.Greenest = 11,
	.Calmest  = 13,
}

// 1 km cells over every point in belgium.bin (x 0.6..285.2 km, y 1.0..236.5 km), one layer per wind layer.
GRID_CELL_KM :: 1
GRID_W :: 286
GRID_H :: 237
GRID_LAYERS :: WIND_LAYERS
GRID_LAYER_CELLS :: GRID_W * GRID_H
GRID_NODES :: GRID_LAYERS * GRID_LAYER_CELLS

// node = layer * GRID_LAYER_CELLS + y * GRID_W + x. Each layer is one contiguous row-major plane,
// so per-layer data (blocked cells, scan animation) can be read as a flat slice.
Node :: distinct u32

// Offsets in cells and layers (x, y, layer): the 8 horizontal directions, then up and down one layer.
GRID_DIRS :: [10][3]int {
	{1, 0, 0},
	{1, 1, 0},
	{0, 1, 0},
	{-1, 1, 0},
	{-1, 0, 0},
	{-1, -1, 0},
	{0, -1, 0},
	{1, -1, 0},
	{0, 0, 1},
	{0, 0, -1},
}

// Search state per node, fixed size inside World: allocated once with it, reused by every route.
// cost, parent and slot of a node only count when visit[node] == search, so a new route bumps search
// instead of clearing 4.9 MB. Zero is valid: no node has been visited yet, the open heap is empty.
Grid :: struct {
	search:       u32,
	heap_len:     u32,
	visit:        [GRID_NODES]u32,
	cost:         [GRID_NODES]f32, // from the start along the best path so far, unit of the mode
	parent:       [GRID_NODES]Node,
	slot:         [GRID_NODES]u32, // index in heap while open, HEAP_CLOSED once expanded
	heap:         [GRID_NODES]Heap_Item, // binary min-heap on f, the open set of A*
	// wind_at and gust_at at every node centre for weather_hour, shared by the three modes and by every
	// route in that hour. Rebuilt when the hour or its forecast differs from the copy it was built from.
	// Zero is a valid cache: a calm hour 0.
	wind:         [GRID_NODES][2]f32,
	gust:         [GRID_NODES]f32,
	weather_hour: int,
	weather_wind: [WIND_LAYERS][WEATHER_CELLS][2]f32,
	weather_gust: [WIND_LAYERS][WEATHER_CELLS]f32,
}

// f = cost + estimate to the goal, the key of the open heap.
Heap_Item :: struct {
	f: f32,
	n: Node,
}

HEAP_CLOSED :: max(u32)

// On an open 8-direction grid thousands of nodes have (almost) the same f, so plain A* expands a wide
// band around the line: 35k nodes corner to corner. Weighting the estimate a little prefers nodes
// closer to the goal: 286 nodes, at most 0.1 % longer than the cheapest path.
ESTIMATE_TIE_BREAK :: 1.001

grid_node :: proc(c: [3]int) -> Node {
	return Node(c.z * GRID_LAYER_CELLS + c.y * GRID_W + c.x)
}

// Inverse of grid_node: x, y, layer.
grid_cell :: proc(n: Node) -> [3]int {
	i := int(n)
	return {i % GRID_W, i / GRID_W % GRID_H, i / GRID_LAYER_CELLS}
}

// pos: x km, y km, altitude m. Snaps to the cell under (x, y) and the layer closest to the altitude.
// ok = false outside the grid or for NaN.
grid_node_at :: proc(pos: [3]f32) -> (n: Node, ok: bool) {
	cx := pos.x / GRID_CELL_KM
	cy := pos.y / GRID_CELL_KM
	// Written as !(inside) so a NaN coordinate fails the test.
	if !(cx >= 0 && cx < GRID_W && cy >= 0 && cy < GRID_H) || math.is_nan(pos.z) do return 0, false

	alt := LAYER_ALT
	layer := 0
	for a, i in alt {
		if abs(pos.z - a) < abs(pos.z - alt[layer]) do layer = i
	}
	return grid_node({int(cx), int(cy), layer}), true
}

// Centre of the node's cell in km and its layer altitude in m.
grid_node_pos :: proc(n: Node) -> [3]f32 {
	c := grid_cell(n)
	alt := LAYER_ALT
	return {(f32(c.x) + 0.5) * GRID_CELL_KM, (f32(c.y) + 0.5) * GRID_CELL_KM, alt[c.z]}
}

// The node one step d (an entry of GRID_DIRS) away from n. ok = false past the edge of the grid.
grid_neighbor :: proc(n: Node, d: [3]int) -> (next: Node, ok: bool) {
	c := grid_cell(n) + d
	if c.x < 0 || c.x >= GRID_W || c.y < 0 || c.y >= GRID_H || c.z < 0 || c.z >= GRID_LAYERS do return 0, false
	return grid_node(c), true
}

// from, to: x km, y km, altitude m. Hub i is at w.m.hubs[i].pos, its tower top at HUB_TOWER_M.
// Returns the path in the same units, or ok = false when no safe route exists with this wind
// or an end point lies outside the grid. The path lives in the route arena until the next route call.
route :: proc(w: ^World, from, to: [3]f32, mode: Route_Mode, hour: int) -> (path: [][3]f32, ok: bool) {
	virtual.arena_free_all(&w.route_mem)

	g := &w.grid
	g.search += 1
	if g.search == 0 {
		// Wrapped after 2^32 routes: stale stamps could match the new search, so clear them once.
		g.visit = {}
		g.search = 1
	}
	g.heap_len = 0

	start := grid_node_at(from) or_return
	goal := grid_node_at(to) or_return

	h := clamp(hour, 0, FORECAST_HOURS - 1)
	if g.weather_hour != h || g.weather_wind != w.weather.wind[h] || g.weather_gust != w.weather.gust[h] {
		g.weather_hour = h
		g.weather_wind = w.weather.wind[h]
		g.weather_gust = w.weather.gust[h]
		for layer in 0 ..< GRID_LAYERS {
			for y in 0 ..< GRID_H {
				for x in 0 ..< GRID_W {
					n := grid_node({x, y, layer})
					p := grid_node_pos(n)
					g.wind[n] = wind_at(w, p.x, p.y, layer, h)
					g.gust[n] = gust_at(w, p.x, p.y, layer, h)
				}
			}
		}
	}

	per_km, per_layer: f32
	{
		wind_max, gust_min: f32 = 0, 1
		for &layer in g.weather_wind do for v in layer do wind_max = max(wind_max, linalg.length(v))
		for &layer in g.weather_gust do for v in layer do gust_min = min(gust_min, v)
		airspeed := MODE_AIRSPEED
		per_km = mode_flight_cost(mode, airspeed[mode], airspeed[mode] + wind_max, gust_min, 1)
		alt := LAYER_ALT
		per_layer = math.inf_f32(1)
		for l in 1 ..< GRID_LAYERS do per_layer = min(per_layer, mode_climb_cost(mode, abs(alt[l] - alt[l - 1])))
	}

	g.visit[start] = g.search
	g.cost[start] = 0
	g.parent[start] = start
	g.slot[start] = 0
	g.heap_len = 1
	grid_heap_up(g, start, grid_estimate(start, goal, per_km, per_layer) * ESTIMATE_TIE_BREAK)

	dirs := GRID_DIRS
	for g.heap_len > 0 {
		n := g.heap[0].n
		g.slot[n] = HEAP_CLOSED
		g.heap_len -= 1
		if g.heap_len > 0 {
			last := g.heap[g.heap_len]
			i: u32 = 0
			for {
				c := 2 * i + 1
				if c >= g.heap_len do break
				if c + 1 < g.heap_len && g.heap[c + 1].f < g.heap[c].f do c += 1
				if g.heap[c].f >= last.f do break
				g.heap[i] = g.heap[c]
				g.slot[g.heap[i].n] = i
				i = c
			}
			g.heap[i] = last
			g.slot[last.n] = i
		}

		if n == goal {
			count := 1
			for p := goal; p != start; p = g.parent[p] do count += 1
			err: mem.Allocator_Error
			path, err = make([][3]f32, max(count, 2), virtual.arena_allocator(&w.route_mem))
			if err != nil do return nil, false
			i := len(path) - 1
			for p := goal;; p = g.parent[p] {
				path[i] = grid_node_pos(p)
				if p == start do break
				i -= 1
			}
			path[0] = from
			path[len(path) - 1] = to
			return path, true
		}

		for d in dirs {
			next := grid_neighbor(n, d) or_continue
			step := edge_cost(g, n, next, mode) or_continue
			cost := g.cost[n] + step
			if g.visit[next] == g.search {
				if g.slot[next] == HEAP_CLOSED || cost >= g.cost[next] do continue
			} else {
				g.visit[next] = g.search
				g.slot[next] = g.heap_len
				g.heap_len += 1
			}
			g.cost[next] = cost
			g.parent[next] = n
			grid_heap_up(g, next, cost + grid_estimate(next, goal, per_km, per_layer) * ESTIMATE_TIE_BREAK)
		}
	}
	return nil, false
}

// Lower bound on the cost from a to b: the octile distance in km (the shortest path on the 8-direction
// grid) times the lowest cost per km, plus the layer changes times the cheapest one. Every edge costs
// at least its share of this, so the estimate is consistent and an expanded node is never reopened.
grid_estimate :: proc(a, b: Node, per_km, per_layer: f32) -> f32 {
	ca := grid_cell(a)
	cb := grid_cell(b)
	dx := abs(ca.x - cb.x)
	dy := abs(ca.y - cb.y)
	flat := f32(max(dx, dy) - min(dx, dy)) + math.SQRT_TWO * f32(min(dx, dy))
	return flat * GRID_CELL_KM * per_km + f32(abs(ca.z - cb.z)) * per_layer
}

// Cost of the edge from node a to its neighbour b in the unit of the mode: seconds for Fastest and
// Calmest, kWh for Greenest. Wind and gust are the mean of the two node centres, the weather grid is
// 40 km so that is the value halfway. ok = false when the ship makes no headway.
edge_cost :: proc(g: ^Grid, a, b: Node, mode: Route_Mode) -> (cost: f32, ok: bool) {
	pa := grid_node_pos(a)
	pb := grid_node_pos(b)
	if pa.xy == pb.xy do return mode_climb_cost(mode, abs(pb.z - pa.z)), true

	airspeed := MODE_AIRSPEED
	v := airspeed[mode]
	track := pb.xy - pa.xy
	km := linalg.length(track)
	wind := (g.wind[a] + g.wind[b]) * 0.5
	// Placeholder until the ground speed item: airspeed plus the tailwind, crosswind ignored.
	ground := v + linalg.dot(wind, track) / km
	// Written as !(headway) so NaN blocks the edge.
	if !(ground > 0) do return 0, false
	return mode_flight_cost(mode, v, ground, (g.gust[a] + g.gust[b]) * 0.5, km), true
}

// Cost of km flown at airspeed v and ground speed ground (m/s) through gust index gust (spec, per mode).
// Rises with gust and falls with ground speed, so the calmest gust and the strongest tailwind give the
// lowest cost per km for the A* estimate.
mode_flight_cost :: proc(mode: Route_Mode, v, ground, gust, km: f32) -> f32 {
	dt := km * 1000 / ground
	switch mode {
	case .Fastest:
		return dt
	case .Calmest:
		return dt * (1 + 7 * gust * gust)
	case .Greenest:
		// P(v, g) in kW. Solar yield comes with the energy item.
		power := 3 + 0.0085 * v * v * v + 6 * gust
		return power * dt / 3600 + 0.25 * gust * gust * km
	}
	return 0
}

// Cost of a vertical edge with climb_m metres of altitude change (spec). Greenest adds the climb and
// descent energy with the energy item.
mode_climb_cost :: proc(mode: Route_Mode, climb_m: f32) -> f32 {
	if mode == .Greenest do return 0.02
	return 0.2 * climb_m / 3
}

// Gives n priority f and moves it up from its slot to its place in the open heap.
// Used both for a newly opened node (slot = the end of the heap) and for a cheaper path to an open one.
grid_heap_up :: proc(g: ^Grid, n: Node, f: f32) {
	i := g.slot[n]
	for i > 0 {
		p := (i - 1) / 2
		if g.heap[p].f <= f do break
		g.heap[i] = g.heap[p]
		g.slot[g.heap[i].n] = i
		i = p
	}
	g.heap[i] = {f, n}
	g.slot[n] = i
}
