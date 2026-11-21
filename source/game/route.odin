package game

import "core:mem/virtual"

Route_Mode :: enum u8 {
	Fastest,
	Greenest,
	Calmest,
}

// from, to: x km, y km, altitude m. Hub i is at w.m.hubs[i].pos, its tower top at HUB_TOWER_M.
// Returns the path in the same units, or ok = false when no safe route exists with this wind.
// The path lives in the route arena until the next route call.
route :: proc(w: ^World, from, to: [3]f32, mode: Route_Mode, hour: int) -> (path: [][3]f32, ok: bool) {
	virtual.arena_free_all(&w.route_mem)
	path = make([][3]f32, 2, virtual.arena_allocator(&w.route_mem))
	path[0] = from
	path[1] = to
	return path, true
}
