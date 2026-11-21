package game

import "core:math"
import "core:mem"
import "core:mem/virtual"

Route_Mode :: enum u8 {
	Fastest,
	Greenest,
	Calmest,
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
	search:   u32,
	heap_len: u32,
	visit:    [GRID_NODES]u32,
	cost:     [GRID_NODES]f32, // km from the start along the best path found so far
	parent:   [GRID_NODES]Node,
	slot:     [GRID_NODES]u32, // index in heap while open, HEAP_CLOSED once expanded
	heap:     [GRID_NODES]Heap_Item, // binary min-heap on f, the open set of A*
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
	g.visit[start] = g.search
	g.cost[start] = 0
	g.parent[start] = start
	g.slot[start] = 0
	g.heap_len = 1
	grid_heap_up(g, start, grid_estimate(start, goal) * ESTIMATE_TIE_BREAK)

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
			// For a single step the estimate is exact: 1 or sqrt 2 cells, or one layer of climb.
			cost := g.cost[n] + grid_estimate(n, next)
			if g.visit[next] == g.search {
				if g.slot[next] == HEAP_CLOSED || cost >= g.cost[next] do continue
			} else {
				g.visit[next] = g.search
				g.slot[next] = g.heap_len
				g.heap_len += 1
			}
			g.cost[next] = cost
			g.parent[next] = n
			grid_heap_up(g, next, cost + grid_estimate(next, goal) * ESTIMATE_TIE_BREAK)
		}
	}
	return nil, false
}

// Cost in km of the cheapest path from a to b on an empty grid: octile distance over the cells plus
// the altitude change. Never more than the real cost, and consistent, so A* finds the cheapest path
// and never has to reopen an expanded node.
grid_estimate :: proc(a, b: Node) -> f32 {
	ca := grid_cell(a)
	cb := grid_cell(b)
	dx := abs(ca.x - cb.x)
	dy := abs(ca.y - cb.y)
	alt := LAYER_ALT
	flat := f32(max(dx, dy) - min(dx, dy)) + math.SQRT_TWO * f32(min(dx, dy))
	return flat * GRID_CELL_KM + abs(alt[ca.z] - alt[cb.z]) / 1000
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
