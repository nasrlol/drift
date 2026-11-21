package game

import "core:mem/virtual"

Route_Mode :: enum u8 {
	Fastest,
	Greenest,
	Calmest,
}

// Points are x, y in km and altitude in m. The path lives in the route arena until the next route call.
route :: proc(w: ^World, from, to: [3]f32, mode: Route_Mode) -> [][3]f32 {
	virtual.arena_free_all(&w.route_mem)
	path := make([][3]f32, 2, virtual.arena_allocator(&w.route_mem))
	path[0] = from
	path[1] = to
	return path
}
