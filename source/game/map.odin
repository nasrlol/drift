package game

MAP_MAGIC :: 0x54465244
MAP_VERSION :: 2
MAX_HUBS :: 32
// Docking towers, top = ground + HUB_TOWER_M (spec).
HUB_TOWER_M :: 58

Map_Header :: struct {
	magic, version:                      u32,
	line_count, point_count, city_count: u32,
	hub_count:                           u32,
}
Map_Line :: struct {
	start, count, kind: u32,
}
Map_City :: struct {
	pos:  [2]f32,
	name: [32]u8,
}
Map_Hub :: struct {
	pos:  [2]f32,
	name: [32]u8,
}
Map_Kind :: enum u32 {
	Border,
	River,
	Motorway,
}

Map :: struct {
	lines:     []Map_Line,
	points:    [][2]f32,
	cities:    []Map_City,
	// Copied, not sliced: a hub id is an index into this fixed array.
	hubs:      [MAX_HUBS]Map_Hub,
	hub_count: int,
}

MAP_DATA :: #load("../../assets/belgium.bin")

load_map :: proc() -> (m: Map, ok: bool) {
	data := MAP_DATA
	h := (^Map_Header)(raw_data(data))
	if h.magic != MAP_MAGIC || h.version != MAP_VERSION || h.hub_count > MAX_HUBS do return {}, false

	off := size_of(Map_Header)
	m.lines = ([^]Map_Line)(raw_data(data[off:]))[:h.line_count]
	off += int(h.line_count) * size_of(Map_Line)
	m.points = ([^][2]f32)(raw_data(data[off:]))[:h.point_count]
	off += int(h.point_count) * size_of([2]f32)
	m.cities = ([^]Map_City)(raw_data(data[off:]))[:h.city_count]
	off += int(h.city_count) * size_of(Map_City)
	m.hub_count = int(h.hub_count)
	copy(m.hubs[:], ([^]Map_Hub)(raw_data(data[off:]))[:h.hub_count])
	return m, true
}
