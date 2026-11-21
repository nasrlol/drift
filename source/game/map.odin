package game

import "core:math"
import "core:slice"
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
// map_nearest_name looks only at the cells of this grid that its radius touches (tools/bake_map has a copy).
NAME_CELL_KM :: 10
NAME_GRID_W :: (MAP_W_KM + NAME_CELL_KM - 1) / NAME_CELL_KM
NAME_GRID_H :: (MAP_H_KM + NAME_CELL_KM - 1) / NAME_CELL_KM

Map_Header :: struct {
	magic, version:                      u32,
	line_count, point_count, city_count: u32,
	hub_count, names_size:               u32,
	name_cell_count, name_run_count:     u32,
}
// name, ref: offsets into Map.names (map_name), 0 = none. ref is the OSM road number, e.g. "E40;A10".
Map_Line :: struct {
	start, count, kind: u32,
	name, ref:          u32,
}
// Segments start ..< start + count of line (index of each segment's first point in Map.points), all touching
// one cell of the name index.
Map_Name_Run :: struct {
	line, start, count: u32,
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
	lines:      []Map_Line,
	points:     [][2]f32,
	cities:     []Map_City,
	// Copied, not sliced: a hub id is an index into this fixed array.
	hubs:       [MAX_HUBS]Map_Hub,
	hub_count:  int,
	// 0-terminated UTF-8 strings, offset 0 is the empty string, the last byte is always 0.
	names:      []u8,
	// Name index: the runs of cell c are name_runs[name_cells[c]:name_cells[c + 1]], c = y * NAME_GRID_W + x.
	// Lists every labelled line: a road or river with a name, or a motorway with a ref.
	name_cells: []u32,
	name_runs:  []Map_Name_Run,
}

// map_nearest_name ranks a line by distance x weight, so a bigger road wins over a smaller one that is a little
// closer: a motorway at 1.6 km beats a tertiary road at 1 km. Rivers rank like primary roads.
NAME_KIND_WEIGHT :: [Map_Kind]f32 {
	.Border    = 1,
	.River     = 0.8,
	.Tertiary  = 1,
	.Secondary = 0.9,
	.Primary   = 0.8,
	.Trunk     = 0.7,
	.Motorway  = 0.6,
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
	m.name_cells = take(data, &off, h.name_cell_count, u32, &bad)
	m.name_runs = take(data, &off, h.name_run_count, Map_Name_Run, &bad)
	if bad || off != len(data) do return {}, false

	if len(m.names) == 0 || m.names[0] != 0 || m.names[len(m.names) - 1] != 0 do return {}, false
	for l in m.lines {
		if u64(l.start) + u64(l.count) > u64(len(m.points)) || l.kind > u32(max(Map_Kind)) do return {}, false
		if int(l.name) >= len(m.names) || int(l.ref) >= len(m.names) do return {}, false
	}
	if len(m.name_cells) != NAME_GRID_W * NAME_GRID_H + 1 || m.name_cells[0] != 0 do return {}, false
	if int(m.name_cells[len(m.name_cells) - 1]) != len(m.name_runs) do return {}, false
	for i in 1 ..< len(m.name_cells) do if m.name_cells[i] < m.name_cells[i - 1] do return {}, false
	for r in m.name_runs {
		if int(r.line) >= len(m.lines) do return {}, false
		l := m.lines[r.line]
		// A segment k uses points k and k + 1, both inside the line.
		if r.start < l.start || u64(r.start) + u64(r.count) >= u64(l.start) + u64(l.count) do return {}, false
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

// The label of the line nearest to pos within radius_km (see NAME_KIND_WEIGHT): its name, or for a motorway
// without one the first part of its ref ("E40" of "E40;A10"). Rivers and roads from tertiary up, never the
// border. The string points into the #load data like map_name. ok = false when nothing is in range.
// Visits the index cells the radius touches, so the cost grows with radius^2: ~10 km is what it is made for.
map_nearest_name :: proc(
	w: ^World,
	pos: [2]f32,
	radius_km: f32,
) -> (
	name: string,
	kind: Map_Kind,
	ok: bool,
) {
	m := &w.m
	if len(m.name_cells) != NAME_GRID_W * NAME_GRID_H + 1 do return
	// Also false for NaN, so the cell range below is never built from NaN.
	if !(radius_km > 0) || !(abs(pos.x) < 1e6) || !(abs(pos.y) < 1e6) do return
	x0 := max(int(math.floor((pos.x - radius_km) / NAME_CELL_KM)), 0)
	x1 := min(int(math.floor((pos.x + radius_km) / NAME_CELL_KM)), NAME_GRID_W - 1)
	y0 := max(int(math.floor((pos.y - radius_km) / NAME_CELL_KM)), 0)
	y1 := min(int(math.floor((pos.y + radius_km) / NAME_CELL_KM)), NAME_GRID_H - 1)

	// Cells nearest first: once the best score is below what any line in the next cell could reach (its
	// distance x the smallest weight), the rest is skipped. A city cell holds thousands of segments, so in a
	// city usually only the cell under pos is read.
	Cell :: struct {
		d2: f32,
		c:  int,
	}
	cells: [NAME_GRID_W * NAME_GRID_H]Cell
	n := 0
	for y in y0 ..= y1 {
		for x in x0 ..= x1 {
			dx := max(f32(x) * NAME_CELL_KM - pos.x, 0, pos.x - f32(x + 1) * NAME_CELL_KM)
			dy := max(f32(y) * NAME_CELL_KM - pos.y, 0, pos.y - f32(y + 1) * NAME_CELL_KM)
			cells[n] = {dx * dx + dy * dy, y * NAME_GRID_W + x}
			n += 1
		}
	}
	slice.sort_by(cells[:n], proc(a, b: Cell) -> bool {return a.d2 < b.d2})

	// Scores are squared (distance^2 x weight^2), no square root per line.
	weights := NAME_KIND_WEIGHT
	min_w2 := max(f32)
	for k in Map_Kind.River ..= Map_Kind.Motorway do min_w2 = min(min_w2, weights[k] * weights[k])
	best_line := -1
	best_score := max(f32)
	r2 := radius_km * radius_km
	for cell in cells[:n] {
		if cell.d2 > r2 || cell.d2 * min_w2 >= best_score do break
		for run in m.name_runs[m.name_cells[cell.c]:m.name_cells[cell.c + 1]] {
			d2 := max(f32)
			for k in run.start ..< run.start + run.count {
				a, b := m.points[k], m.points[k + 1]
				ab, ap := b - a, pos - a
				len2 := ab.x * ab.x + ab.y * ab.y
				t := len2 > 0 ? clamp((ap.x * ab.x + ap.y * ab.y) / len2, 0, 1) : 0
				e := ap - ab * t
				d2 = min(d2, e.x * e.x + e.y * e.y)
			}
			if d2 > r2 do continue
			wk := weights[Map_Kind(m.lines[run.line].kind)]
			if score := d2 * wk * wk; score < best_score do best_line, best_score = int(run.line), score
		}
	}
	if best_line < 0 do return

	l := m.lines[best_line]
	kind = Map_Kind(l.kind)
	name = map_name(m, l.name)
	if name == "" {
		name = map_name(m, l.ref)
		if i := strings.index_byte(name, ';'); i >= 0 do name = name[:i]
	}
	return name, kind, name != ""
}
