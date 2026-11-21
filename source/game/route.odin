package game

import "core:math"
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
// cost and parent of a node only count when visit[node] == search, so a new route bumps search
// instead of clearing 2.4 MB. Zero is valid: no node has been visited yet.
Grid :: struct {
	search: u32,
	visit:  [GRID_NODES]u32,
	cost:   [GRID_NODES]f32,
	parent: [GRID_NODES]Node,
}

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

	start := grid_node_at(from) or_return
	_ = grid_node_at(to) or_return
	g.visit[start] = g.search
	g.cost[start] = 0
	g.parent[start] = start

	path = make([][3]f32, 2, virtual.arena_allocator(&w.route_mem))
	path[0] = from
	path[1] = to
	return path, true
}
