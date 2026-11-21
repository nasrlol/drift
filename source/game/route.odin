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

// Energy model (spec). The battery holds BATTERY_KWH, a ship leaves with BATTERY_START of it.
BATTERY_KWH :: 180
BATTERY_START :: 0.86

// Ground speed rules in m/s (spec): below GROUND_RETRY the ship throttles up by GROUND_RETRY_BOOST, below
// GROUND_MIN even then the edge is blocked.
GROUND_RETRY :: 2.5
GROUND_RETRY_BOOST :: 6
GROUND_MIN :: 1.5

// Path cleanup (spec). String pulling looks at most PULL_WINDOW nodes ahead and accepts a straight line that
// costs at most PULL_TOLERANCE more than the A* path it replaces.
PULL_WINDOW :: 14
PULL_TOLERANCE :: 0.004
// Routes start and end this far above the tower top (docking is at the top + 3 m).
TOWER_ABOVE_M :: 6
CHAIKIN_ITERATIONS :: 3
// Spacing of the final path points, horizontal. The spec's 20 m was for a 5 km map; on Belgium it is the
// heightmap spacing, so the terrain clearance still sees every height cell (#46).
RESAMPLE_KM :: 0.25
// Highest climb or descent per metre flown horizontally.
SLOPE_MAX :: 0.24
TERRAIN_CLEARANCE_M :: 40

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

// A cell is blocked in a layer when its highest ground + this margin is above the layer altitude (spec).
TERRAIN_MARGIN_M :: 75
// Ground samples per cell side, 250 m apart including both edges: the spacing of the heightmap, so the
// highest sample is the highest point of the bilinear terrain inside the cell.
TERRAIN_SAMPLES :: 5
MAX_NO_FLY :: 8
MAX_GUST_ZONES :: 4
// Route end points snap to the closest free node at most this many cells away from the hub.
FREE_NODE_CELLS :: 5

GRID_BLOCKED_WORDS :: (GRID_NODES + 63) / 64

// A circle on the map, closed from the ground up to ceiling. radius 0 marks an unused slot,
// so a zeroed array holds no zones.
No_Fly_Zone :: struct {
	center:  [2]f32, // km
	radius:  f32, // km
	ceiling: f32, // m, every layer below it is blocked
}

// A gust cell reported in flight. Closed at every altitude: the spec gives a reported zone only a
// centre and a radius, no ceiling. radius 0 marks an unused slot.
Gust_Zone :: struct {
	center: [2]f32, // km
	radius: f32, // km
}

// Search state per node, fixed size inside World: allocated once with it, reused by every route.
// cost, parent and slot of a node only count when visit[node] == search, so a new route bumps search
// instead of clearing 4.9 MB. Zero is valid: no node has been visited yet, the open heap is empty,
// the blocked set is not built.
Grid :: struct {
	search:        u32,
	heap_len:      u32,
	visit:         [GRID_NODES]u32,
	cost:          [GRID_NODES]f32, // from the start along the best path so far, unit of the mode
	parent:        [GRID_NODES]Node,
	slot:          [GRID_NODES]u32, // index in heap while open, HEAP_CLOSED once expanded
	heap:          [GRID_NODES]Heap_Item, // binary min-heap on f, the open set of A*
	// Nodes in the order the last route expanded them, for the scan animation: expanded[:expanded_len].
	// An expanded node is never reopened (see grid_estimate), so every node fits at most once.
	expanded:      [GRID_NODES]Node,
	expanded_len:  u32,
	// Bit n set: node n can not be entered. terrain is the edge ring and the cells too close to the ground,
	// blocked is terrain plus blocked_zones and blocked_gusts. Two sets because terrain costs 1.7M height_at
	// calls and only changes with the library (game_hot_reloaded clears terrain_built), the zones change
	// at runtime.
	terrain:       [GRID_BLOCKED_WORDS]u64,
	blocked:       [GRID_BLOCKED_WORDS]u64,
	blocked_zones: [MAX_NO_FLY]No_Fly_Zone,
	blocked_gusts: [MAX_GUST_ZONES]Gust_Zone,
	// Connected free region of each node (A* steps), 0 for a blocked node. Built with blocked.
	region:        [GRID_NODES]u32,
	// wind_at and gust_at at every node centre and cloud_at at every cell centre (cloud cover has no layers)
	// for weather_hour, shared by the three modes and by every route in that hour. Rebuilt when the hour or
	// its forecast differs from the copy it was built from. Zero is a valid cache: a calm, clear hour 0.
	wind:          [GRID_NODES][2]f32,
	gust:          [GRID_NODES]f32,
	cloud:         [GRID_LAYER_CELLS]f32,
	weather_hour:  int,
	weather_wind:  [WIND_LAYERS][WEATHER_CELLS][2]f32,
	weather_gust:  [WIND_LAYERS][WEATHER_CELLS]f32,
	weather_cloud: [WEATHER_CELLS]f32,
	terrain_built: bool,
	blocked_built: bool,
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

grid_blocked :: proc(g: ^Grid, n: Node) -> bool {
	return g.blocked[n >> 6] & (1 << (u32(n) & 63)) != 0
}

// The free node closest to pos (x km, y km) within FREE_NODE_CELLS cells, lowest free layer of that cell
// (spec: start and goal are the closest free node to the hub, lowest layer first). The altitude in pos
// is not used. ok = false when pos lies outside the grid or every node around it is blocked.
grid_free_node_near :: proc(g: ^Grid, pos: [3]f32) -> (n: Node, ok: bool) {
	hub := grid_cell(grid_node_at(pos) or_return)
	best := math.inf_f32(1)
	for y in max(hub.y - FREE_NODE_CELLS, 0) ..= min(hub.y + FREE_NODE_CELLS, GRID_H - 1) {
		for x in max(hub.x - FREE_NODE_CELLS, 0) ..= min(hub.x + FREE_NODE_CELLS, GRID_W - 1) {
			for layer in 0 ..< GRID_LAYERS {
				c := grid_node({x, y, layer})
				if grid_blocked(g, c) do continue
				if d := linalg.length2(grid_node_pos(c).xy - pos.xy); d < best {
					best, n, ok = d, c, true
				}
				break
			}
		}
	}
	return
}

// from, to: x km, y km, altitude m. Hub i is at w.m.hubs[i].pos, its tower top at HUB_TOWER_M.
// Returns the path in the same units, or ok = false when no safe route exists with this wind
// or an end point has no free node near it (outside the grid, in a no-fly or gust zone).
// The path lives in the route arena until the next route call.
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
	g.expanded_len = 0

	alt := LAYER_ALT
	if !g.terrain_built {
		g.terrain = {}
		count: [GRID_LAYERS]int
		for y in 0 ..< GRID_H {
			for x in 0 ..< GRID_W {
				ground := math.inf_f32(-1)
				for sy in 0 ..< TERRAIN_SAMPLES {
					for sx in 0 ..< TERRAIN_SAMPLES {
						step :: f32(GRID_CELL_KM) / (TERRAIN_SAMPLES - 1)
						sample := [2]f32{f32(x), f32(y)} * GRID_CELL_KM + [2]f32{f32(sx), f32(sy)} * step
						ground = max(ground, height_at(w, sample.x, sample.y))
					}
				}
				// The spec closes the outer ring of cells, so no path runs along the edge of the data.
				edge := x == 0 || y == 0 || x == GRID_W - 1 || y == GRID_H - 1
				for layer in 0 ..< GRID_LAYERS {
					// Written as !(free) so a NaN height blocks the cell.
					if edge || !(ground + TERRAIN_MARGIN_M <= alt[layer]) {
						n := grid_node({x, y, layer})
						g.terrain[n >> 6] |= 1 << (u32(n) & 63)
						count[layer] += 1
					}
				}
			}
		}
		g.terrain_built = true
		g.blocked_built = false
		logf(w, "route", "terrain set built: %v of %d nodes per layer blocked", count, GRID_LAYER_CELLS)
	}

	if !g.blocked_built || g.blocked_zones != w.no_fly || g.blocked_gusts != w.gust_zones {
		// Not rebuilt per forecast hour: neither terrain nor the zones depend on it.
		g.blocked = g.terrain
		g.blocked_zones = w.no_fly
		g.blocked_gusts = w.gust_zones
		g.blocked_built = true
		// A gust zone blocks like a no-fly zone without a ceiling.
		zones: [MAX_NO_FLY + MAX_GUST_ZONES]No_Fly_Zone
		copy(zones[:], g.blocked_zones[:])
		for z, i in g.blocked_gusts do zones[MAX_NO_FLY + i] = {z.center, z.radius, math.inf_f32(1)}
		no_fly, gusts, added := 0, 0, 0
		for z, i in zones {
			// Written as !(valid) so NaN and Inf skip the zone, radius 0 is an unused slot.
			if !(z.radius > 0 && z.radius < 1e6 && abs(z.center.x) < 1e6 && abs(z.center.y) < 1e6) do continue
			if i < MAX_NO_FLY {
				no_fly += 1
			} else {
				gusts += 1
			}
			lo := linalg.floor((z.center - z.radius) / GRID_CELL_KM)
			hi := linalg.floor((z.center + z.radius) / GRID_CELL_KM)
			for y in max(int(lo.y), 0) ..= min(int(hi.y), GRID_H - 1) {
				for x in max(int(lo.x), 0) ..= min(int(hi.x), GRID_W - 1) {
					// Overlap, not the cell centre: a zone smaller than a cell must still block it.
					cell := [2]f32{f32(x), f32(y)} * GRID_CELL_KM
					closest := linalg.clamp(z.center, cell, cell + GRID_CELL_KM)
					if linalg.length2(closest - z.center) >= z.radius * z.radius do continue
					for layer in 0 ..< GRID_LAYERS {
						if !(alt[layer] < z.ceiling) do continue
						n := grid_node({x, y, layer})
						bit := u64(1) << (u32(n) & 63)
						if g.blocked[n >> 6] & bit == 0 do added += 1
						g.blocked[n >> 6] |= bit
					}
				}
			}
		}

		// Label the connected free regions: a route between two regions fails at once, instead of
		// expanding every node reachable from the start (a walled-in hub took 33 ms with -o:speed).
		// The open heap is free between routes, so it serves as the flood fill stack.
		g.region = {}
		regions: u32 = 0
		dirs := GRID_DIRS
		for i in 0 ..< GRID_NODES {
			first := Node(i)
			if g.region[first] != 0 || grid_blocked(g, first) do continue
			regions += 1
			g.region[first] = regions
			g.heap[0].n = first
			top := 1
			for top > 0 {
				top -= 1
				c := grid_cell(g.heap[top].n)
				for d in dirs {
					nc := c + d
					if nc.x < 0 || nc.x >= GRID_W || nc.y < 0 || nc.y >= GRID_H do continue
					if nc.z < 0 || nc.z >= GRID_LAYERS do continue
					next := grid_node(nc)
					if g.region[next] != 0 || grid_blocked(g, next) do continue
					g.region[next] = regions
					g.heap[top].n = next
					top += 1
				}
			}
		}
		logf(
			w,
			"route",
			"%d no-fly and %d gust zones block %d nodes beyond the terrain set, %d free regions",
			no_fly,
			gusts,
			added,
			regions,
		)
	}

	start, start_ok := grid_free_node_near(g, from)
	goal, goal_ok := grid_free_node_near(g, to)
	if !start_ok {
		logf(
			w,
			"route",
			"start %v: outside the grid or no free node within %d cells",
			from.xy,
			FREE_NODE_CELLS,
		)
	}
	if !goal_ok {
		logf(w, "route", "goal %v: outside the grid or no free node within %d cells", to.xy, FREE_NODE_CELLS)
	}
	if !start_ok || !goal_ok do return nil, false
	if g.region[start] != g.region[goal] {
		logf(w, "route", "no path from %v to %v: blocked nodes separate them", from.xy, to.xy)
		return nil, false
	}

	h := clamp(hour, 0, FORECAST_HOURS - 1)
	if g.weather_hour != h ||
	   g.weather_wind != w.weather.wind[h] ||
	   g.weather_gust != w.weather.gust[h] ||
	   g.weather_cloud != w.weather.cloud[h] {
		g.weather_hour = h
		g.weather_wind = w.weather.wind[h]
		g.weather_gust = w.weather.gust[h]
		g.weather_cloud = w.weather.cloud[h]
		for y in 0 ..< GRID_H {
			for x in 0 ..< GRID_W {
				p := grid_node_pos(grid_node({x, y, 0}))
				g.cloud[y * GRID_W + x] = cloud_at(w, p.x, p.y, h)
			}
		}
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
		wind_max, gust_min, cloud_min: f32 = 0, 1, 1
		for &layer in g.weather_wind do for v in layer do wind_max = max(wind_max, linalg.length(v))
		for &layer in g.weather_gust do for v in layer do gust_min = min(gust_min, v)
		for c in g.weather_cloud do cloud_min = min(cloud_min, c)
		// Bilinear sampling stays between the grid values, so no edge gets more sun than solar_max.
		solar_max := solar_kw(cloud_min)
		// Ground speed is at most the airspeed plus the strongest wind as a pure tailwind. The boost only
		// happens where the ground speed at v, at least v - wind_max, is below GROUND_RETRY. There
		// sqrt(x + k) <= sqrt(x) + sqrt(k) bounds what the boost adds to sqrt(v^2 - crosswind^2).
		airspeed := MODE_AIRSPEED
		v := airspeed[mode]
		per_km = mode_flight_cost(mode, v, v + wind_max, gust_min, solar_max, 1)
		if wind_max > v - GROUND_RETRY {
			boost := v + GROUND_RETRY_BOOST
			boost_ground := min(boost + wind_max, GROUND_RETRY + math.sqrt(boost * boost - v * v))
			per_km = min(per_km, mode_flight_cost(mode, boost, boost_ground, gust_min, solar_max, 1))
		}
		per_layer = math.inf_f32(1)
		for l in 1 ..< GRID_LAYERS {
			climb := alt[l] - alt[l - 1]
			per_layer = min(per_layer, mode_climb_cost(mode, climb), mode_climb_cost(mode, -climb))
		}
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
		g.expanded[g.expanded_len] = n
		g.expanded_len += 1
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
			route_alloc := virtual.arena_allocator(&w.route_mem)
			err: mem.Allocator_Error

			// The A* nodes from start to goal.
			count := 1
			for p := goal; p != start; p = g.parent[p] do count += 1
			nodes: []Node
			nodes, err = make([]Node, count, route_alloc)
			if err != nil do return nil, false
			{
				i := count - 1
				for p := goal;; p = g.parent[p] {
					nodes[i] = p
					if p == start do break
					i -= 1
				}
			}

			// Cost-aware string pulling (spec): from each kept node jump to the farthest node at most
			// PULL_WINDOW nodes ahead whose straight line stays in free cells of the same layer and costs at
			// most PULL_TOLERANCE more than the A* path between them. Kept nodes are compacted in place.
			kept := 1
			for i := 0; i < len(nodes) - 1; {
				best := i + 1
				a := grid_node_pos(nodes[i])
				layer := grid_cell(nodes[i]).z
				for j in i + 1 ..= min(i + PULL_WINDOW, len(nodes) - 1) {
					if grid_cell(nodes[j]).z != layer do break
					if j == i + 1 do continue
					limit := (g.cost[nodes[j]] - g.cost[nodes[i]]) * (1 + PULL_TOLERANCE)
					straight, free := line_cost(g, a, grid_node_pos(nodes[j]), mode)
					if free && straight <= limit do best = j
				}
				nodes[kept] = nodes[best]
				kept += 1
				i = best
			}

			// Start and end above the tower tops (spec). from.z and to.z are the tops. The ramp point between
			// tower and path lies halfway to the first (last) node, at that node's altitude (#45).
			points: [][3]f32
			points, err = make([][3]f32, kept + 4, route_alloc)
			if err != nil do return nil, false
			first := grid_node_pos(nodes[0])
			last := grid_node_pos(nodes[kept - 1])
			points[0] = {from.x, from.y, from.z + TOWER_ABOVE_M}
			points[1] = {(from.x + first.x) * 0.5, (from.y + first.y) * 0.5, first.z}
			for node, i in nodes[:kept] do points[i + 2] = grid_node_pos(node)
			points[kept + 2] = {(to.x + last.x) * 0.5, (to.y + last.y) * 0.5, last.z}
			points[kept + 3] = {to.x, to.y, to.z + TOWER_ABOVE_M}

			// Chaikin smoothing (spec): every segment becomes its points at 1/4 and 3/4, the end points stay
			// on the towers. Linear in each coordinate, so km and m can share a point.
			for _ in 0 ..< CHAIKIN_ITERATIONS {
				smooth: [][3]f32
				smooth, err = make([][3]f32, 2 * len(points), route_alloc)
				if err != nil do return nil, false
				smooth[0] = points[0]
				for i in 0 ..< len(points) - 1 {
					smooth[2 * i + 1] = points[i] * 0.75 + points[i + 1] * 0.25
					smooth[2 * i + 2] = points[i] * 0.25 + points[i + 1] * 0.75
				}
				smooth[len(smooth) - 1] = points[len(points) - 1]
				points = smooth
			}

			// Resample every RESAMPLE_KM of horizontal distance (spec), the last point is the end tower.
			total: f32
			for i in 1 ..< len(points) do total += linalg.length(points[i].xy - points[i - 1].xy)
			path, err = make([][3]f32, max(int(math.ceil(total / RESAMPLE_KM)), 1) + 1, route_alloc)
			if err != nil do return nil, false
			{
				seg := 0
				seg_start: f32 = 0 // horizontal distance from the start to points[seg]
				for &p, k in path[:len(path) - 1] {
					s := f32(k) * RESAMPLE_KM
					for seg < len(points) - 2 {
						seg_km := linalg.length(points[seg + 1].xy - points[seg].xy)
						if seg_start + seg_km > s do break
						seg_start += seg_km
						seg += 1
					}
					seg_km := linalg.length(points[seg + 1].xy - points[seg].xy)
					t := seg_km > 0 ? clamp((s - seg_start) / seg_km, 0, 1) : 0
					p = linalg.lerp(points[seg], points[seg + 1], t)
				}
				path[len(path) - 1] = points[len(points) - 1]
			}

			// Slope limit (spec): a forward pass caps the climb, a backward pass the descent, both only
			// lower points, the towers stay. Then keep TERRAIN_CLEARANCE_M above the ground.
			for i in 1 ..< len(path) - 1 {
				m := linalg.length(path[i].xy - path[i - 1].xy) * 1000
				path[i].z = min(path[i].z, path[i - 1].z + SLOPE_MAX * m)
			}
			for i := len(path) - 2; i > 0; i -= 1 {
				m := linalg.length(path[i + 1].xy - path[i].xy) * 1000
				path[i].z = min(path[i].z, path[i + 1].z + SLOPE_MAX * m)
			}
			for &p in path do p.z = max(p.z, height_at(w, p.x, p.y) + TERRAIN_CLEARANCE_M)
			return path, true
		}

		for d in dirs {
			next := grid_neighbor(n, d) or_continue
			if grid_blocked(g, next) do continue
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
	logf(
		w,
		"route",
		"no path from %v to %v, every free node reachable from the start was searched",
		from.xy,
		to.xy,
	)
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
// Calmest, kWh for Greenest. Wind, gust and cloud cover are the mean of the two node centres, the weather
// grid is 40 km so that is the value halfway. ok = false when the edge is blocked by the ground speed rules.
edge_cost :: proc(g: ^Grid, a, b: Node, mode: Route_Mode) -> (cost: f32, ok: bool) {
	pa := grid_node_pos(a)
	pb := grid_node_pos(b)
	if pa.xy == pb.xy do return mode_climb_cost(mode, pb.z - pa.z), true

	track := pb.xy - pa.xy
	km := linalg.length(track)
	wind := (g.wind[a] + g.wind[b]) * 0.5
	gust := (g.gust[a] + g.gust[b]) * 0.5
	cloud := (g.cloud[u32(a) % GRID_LAYER_CELLS] + g.cloud[u32(b) % GRID_LAYER_CELLS]) * 0.5
	return flight_cost(mode, wind, track / km, gust, cloud, km)
}

// Cost of the straight line from a to b (x km, y km, a layer altitude in m) in that layer, in the unit of the
// mode. Walks the cells the line crosses (Amanatides-Woo): each piece costs as an edge with the weather of
// its cell. free = false when a crossed cell is blocked or a piece is blocked by the ground speed rules.
// A line through a cell corner does not enter the two cells beside it, the same as a diagonal A* step.
line_cost :: proc(g: ^Grid, a, b: [3]f32, mode: Route_Mode) -> (cost: f32, free: bool) {
	start := grid_node_at(a) or_return
	layer := grid_cell(start).z
	cell := grid_cell(start).xy
	track := b.xy - a.xy
	total := linalg.length(track)
	if total == 0 do return 0, !grid_blocked(g, start)
	dir := track / total

	// Distance along the line to the next cell boundary in x and y, and between two boundaries.
	step, next, delta: [2]f32
	for axis in 0 ..< 2 {
		step[axis] = dir[axis] > 0 ? 1 : -1
		next[axis] = math.inf_f32(1)
		delta[axis] = math.inf_f32(1)
		if dir[axis] != 0 {
			edge := (f32(cell[axis]) + (dir[axis] > 0 ? 1 : 0)) * GRID_CELL_KM
			next[axis] = (edge - a[axis]) / dir[axis]
			delta[axis] = GRID_CELL_KM / abs(dir[axis])
		}
	}

	// Two boundaries closer than this along the line are one corner.
	CORNER_KM :: 1e-4
	done: f32 = 0
	for {
		if cell.x < 0 || cell.x >= GRID_W || cell.y < 0 || cell.y >= GRID_H do return 0, false
		n := grid_node({cell.x, cell.y, layer})
		if grid_blocked(g, n) do return 0, false
		reach := min(next.x, next.y, total)
		cloud := g.cloud[u32(n) % GRID_LAYER_CELLS]
		cost += flight_cost(mode, g.wind[n], dir, g.gust[n], cloud, reach - done) or_return
		if reach >= total do return cost, true
		done = reach
		if abs(next.x - next.y) < CORNER_KM {
			cell += {int(step.x), int(step.y)}
			next += delta
		} else if next.x < next.y {
			cell.x += int(step.x)
			next.x += delta.x
		} else {
			cell.y += int(step.y)
			next.y += delta.y
		}
	}
}

// Cost of km flown along the unit track dir through wind (m/s), gust index gust and cloud cover cloud at the
// mode's airspeed, after the ground speed rules (spec). ok = false when they block the flight.
flight_cost :: proc(mode: Route_Mode, wind, dir: [2]f32, gust, cloud, km: f32) -> (cost: f32, ok: bool) {
	airspeed := MODE_AIRSPEED
	v := airspeed[mode]
	ground := ground_speed(v, wind, dir) or_return
	if ground < GROUND_RETRY {
		v += GROUND_RETRY_BOOST
		ground = ground_speed(v, wind, dir) or_return
		if ground < GROUND_MIN do return 0, false
	}
	return mode_flight_cost(mode, v, ground, gust, solar_kw(cloud), km), true
}

// Ground speed in m/s along the unit track dir at airspeed v in wind (spec): the tailwind plus what is left
// of v once it cancels the crosswind. ok = false when the crosswind is stronger than v, also for NaN wind.
ground_speed :: proc(v: f32, wind, dir: [2]f32) -> (ground: f32, ok: bool) {
	cross := wind.x * dir.y - wind.y * dir.x
	rest := v * v - cross * cross
	if !(rest >= 0) do return 0, false
	return linalg.dot(wind, dir) + math.sqrt(rest), true
}

// Cost of km flown at airspeed v and ground speed ground (m/s) through gust index gust under solar kW of
// sun (spec, per mode). Rises with gust and v, falls with solar (Greenest) and with ground speed, which the
// A* estimate relies on. power_kw is above the strongest sun at every airspeed, so a cost is never negative.
mode_flight_cost :: proc(mode: Route_Mode, v, ground, gust, solar, km: f32) -> f32 {
	dt := km * 1000 / ground
	switch mode {
	case .Fastest:
		return dt
	case .Calmest:
		return dt * (1 + 7 * gust * gust)
	case .Greenest:
		return (power_kw(v, gust) - solar) * dt / 3600 + 0.25 * gust * gust * km
	}
	return 0
}

// Cost of a vertical edge that climbs climb_m metres, negative for a descent (spec).
mode_climb_cost :: proc(mode: Route_Mode, climb_m: f32) -> f32 {
	if mode == .Greenest do return climb_kwh(climb_m) + 0.02
	return 0.2 * abs(climb_m) / 3
}

// Power drawn in kW at airspeed v m/s through gust index gust 0..1 (spec P(v, g)).
power_kw :: proc(v, gust: f32) -> f32 {
	return 3 + 0.0085 * v * v * v + 6 * gust
}

// Solar yield in kW under cloud cover 0..1 (spec S(c)): 9 kW of film at 75 %, overcast takes 78 % of it.
solar_kw :: proc(cloud: f32) -> f32 {
	return 9 * 0.75 * (1 - 0.78 * cloud)
}

// Ballonet energy in kWh to change altitude by climb_m metres, negative for a descent (spec):
// 0.12 kWh per 100 m up, 0.04 kWh per 100 m down.
climb_kwh :: proc(climb_m: f32) -> f32 {
	return climb_m > 0 ? 0.0012 * climb_m : -0.0004 * climb_m
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
