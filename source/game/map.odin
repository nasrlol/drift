package game

import "core:math"
import "core:strings"

MAP_MAGIC :: 0x54465244
MAP_VERSION :: 4
MAX_HUBS :: 32
// Docking towers, top = ground + HUB_TOWER_M (spec).
HUB_TOWER_M :: 58
// Every point in belgium.bin lies inside 0..MAP_W_KM x 0..MAP_H_KM (same extent as the routing grid).
// The bake clips lines to it (tools/bake_map has a copy of both).
MAP_W_KM :: 286
MAP_H_KM :: 237

Map_Header :: struct {
	magic, version:                      u32,
	line_count, point_count, city_count: u32,
	hub_count, names_size:               u32,
}
// name, ref: offsets into Map.names (map_name), 0 = none. ref is the OSM road number, e.g. "E40;A10".
Map_Line :: struct {
	start, count, kind: u32,
	name, ref:          u32,
}
Map_City :: struct {
	pos:  [2]f32,
	name: [32]u8,
}
Map_Hub :: struct {
	pos:  [2]f32,
	name: [32]u8,
}
// belgium.bin lists the lines in this order, so a bigger road is drawn on top of a smaller one.
Map_Kind :: enum u32 {
	Border,
	River,
	Tertiary,
	Secondary,
	Primary,
	Trunk,
	Motorway,
}

Map :: struct {
	lines:     []Map_Line,
	points:    [][2]f32,
	cities:    []Map_City,
	// Copied, not sliced: a hub id is an index into this fixed array.
	hubs:      [MAX_HUBS]Map_Hub,
	hub_count: int,
	// 0-terminated UTF-8 strings, offset 0 is the empty string, the last byte is always 0.
	names:     []u8,
}

MAP_DATA :: #load("../../assets/belgium.bin")

// Slices belgium.bin, no copies except the hubs. The file is ours but still checked like outside data: every
// block must fit, every index must point inside its block, every coordinate must be finite. A bad file gives
// ok = false and an empty map, never a crash later.
load_map :: proc() -> (m: Map, ok: bool) {
	data := MAP_DATA
	if len(data) < size_of(Map_Header) do return {}, false
	h := (^Map_Header)(raw_data(data))
	if h.magic != MAP_MAGIC || h.version != MAP_VERSION || h.hub_count > MAX_HUBS do return {}, false

	// The next count elements of T, or nil and bad = true when they run past the end. u64 so a huge count
	// cannot wrap.
	off := size_of(Map_Header)
	bad := false
	take :: proc(data: []u8, off: ^int, count: u32, $T: typeid, bad: ^bool) -> []T {
		size := u64(count) * size_of(T)
		if u64(off^) + size > u64(len(data)) {
			bad^ = true
			return nil
		}
		s := ([^]T)(raw_data(data[off^:]))[:count]
		off^ += int(size)
		return s
	}
	finite :: proc(p: [2]f32) -> bool {
		return !math.is_nan(p.x) && !math.is_nan(p.y) && !math.is_inf(p.x) && !math.is_inf(p.y)
	}

	m.lines = take(data, &off, h.line_count, Map_Line, &bad)
	m.points = take(data, &off, h.point_count, [2]f32, &bad)
	m.cities = take(data, &off, h.city_count, Map_City, &bad)
	hubs := take(data, &off, h.hub_count, Map_Hub, &bad)
	m.names = take(data, &off, h.names_size, u8, &bad)
	if bad || off != len(data) do return {}, false

	if len(m.names) == 0 || m.names[0] != 0 || m.names[len(m.names) - 1] != 0 do return {}, false
	for l in m.lines {
		if u64(l.start) + u64(l.count) > u64(len(m.points)) || l.kind > u32(max(Map_Kind)) do return {}, false
		if int(l.name) >= len(m.names) || int(l.ref) >= len(m.names) do return {}, false
	}
	for p in m.points do if !finite(p) do return {}, false
	for c in m.cities do if !finite(c.pos) do return {}, false
	for hub in hubs do if !finite(hub.pos) do return {}, false

	m.hub_count = len(hubs)
	copy(m.hubs[:], hubs)
	return m, true
}

// The string at offset in m.names, "" for 0 or a bad offset. It points into the #load data: valid until the
// next hot reload, so copy it before keeping it in World.
map_name :: proc(m: ^Map, offset: u32) -> string {
	if int(offset) >= len(m.names) do return ""
	return strings.truncate_to_byte(string(m.names[offset:]), 0)
}
