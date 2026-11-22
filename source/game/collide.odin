package game

import "core:compress/deflate"
import "core:math"
import "core:math/linalg"
import "core:mem/virtual"

// Building collision for free flight in the street view (Lars, 2026-11-21: "tussen huizen vliegen"). The car
// hits the same walls the street view draws: the real OSM buildings of BUILDINGS_DATA (buildings.odin) at their
// real height, lowered at the edge of the baked circle like the mesh, and the generated town buildings, which
// are not stored but made again from the City triangles around the query point (town_lot). Simulation code: no
// raylib, no camera state. Built on first use from the perm arena, the same for every run.
COLLIDE_CELL_KM :: 0.1
// Cells per side of a city's grid: 2.4 km around the city point holds the 1 km circle and its largest buildings.
COLLIDE_CITY_CELLS :: 24
COLLIDE_TRI_CELL_KM :: 1.0
COLLIDE_TRI_W :: int(MAP_W_KM / COLLIDE_TRI_CELL_KM) + 1
COLLIDE_TRI_H :: int(MAP_H_KM / COLLIDE_TRI_CELL_KM) + 1
// The most buildings one query looks at (a dense city centre has ~20 within 30 m).
COLLIDE_MAX_SEEN :: 96
// Roads and rivers, for keeping the generated buildings off them (town_lot) and for the street view: the map's
// line segments per COLLIDE_ROAD_CELL_KM cell, each filed in every cell within COLLIDE_ROAD_REACH_M of it, so
// one cell answers a query.
COLLIDE_ROAD_CELL_KM :: 0.25
COLLIDE_ROAD_W :: int(MAP_W_KM / COLLIDE_ROAD_CELL_KM) + 1
COLLIDE_ROAD_H :: int(MAP_H_KM / COLLIDE_ROAD_CELL_KM) + 1
// Urban roads get a sidewalk on each side in the street view; a generated building keeps TOWN_ROAD_GAP_M from it
// (Lars, 2026-11-21: "sommige gebouwen komen in de weg, niet logisch"). Our values.
ROAD_SIDEWALK_M :: 2.5
TOWN_ROAD_GAP_M :: 1.5
// The widest half width, the sidewalk, the gap and the largest lot's half diagonal (0.45 x 30 m x sqrt 2).
COLLIDE_ROAD_REACH_M :: 14 + ROAD_SIDEWALK_M + TOWN_ROAD_GAP_M + 20

// Half width (m) of a road or river as the street view draws it: OSM draws a motorway per carriageway, the others
// both directions on one line. 0 for lines that are not roads.
road_half_width_m :: proc(kind: Map_Kind) -> f32 {
	#partial switch kind {
	case .Motorway:
		return 6.5
	case .Trunk:
		return 5.5
	case .Primary:
		return 4.5
	case .Secondary:
		return 3.8
	case .Tertiary:
		return 3.0
	case .River:
		return 14
	}
	return 0
}

// Zero = not built yet.
Collide :: struct {
	built:      bool,
	points:     [][2]f32, // building rings, km
	b_start:    []u32, // first point of building b
	b_count:    []u32,
	b_height:   []f32, // m above the ground
	cities:     [BUILDINGS_MAX_CITIES][2]f32, // city points of the real buildings, km
	city_count: int,
	// Building indices per 100 m cell of each city: city_items[city_cells[c] : city_cells[c + 1]] for cell
	// c = city * COLLIDE_CITY_CELLS^2 + y * COLLIDE_CITY_CELLS + x.
	city_cells: []u32,
	city_items: []u32,
	// City triangles per 1 km cell of the map: area index and first point index in w.m.area_points.
	tri_cells:  []u32,
	tri_items:  [][2]u32,
	// Road and river segments per COLLIDE_ROAD_CELL_KM cell: kind << 24 | index of the first point.
	road_cells: []u32,
	road_items: []u32,
}

// The distance (m) from segment a-b to the box of half sizes h around 0 (all in the box's frame, m): 0 when the
// segment enters the box.
segment_box_m :: proc(a, b, h: [2]f32) -> f32 {
	d := b - a
	t0, t1: f32 = 0, 1
	enters := true
	for pq in ([4][2]f32{{-d.x, a.x + h.x}, {d.x, h.x - a.x}, {-d.y, a.y + h.y}, {d.y, h.y - a.y}}) {
		if pq[0] == 0 {
			if pq[1] < 0 do enters = false
		} else if pq[0] < 0 {
			t0 = max(t0, pq[1] / pq[0])
		} else {
			t1 = min(t1, pq[1] / pq[0])
		}
	}
	if enters && t0 <= t1 do return 0
	box :: proc(p, h: [2]f32) -> f32 {return linalg.length(linalg.max(linalg.abs(p) - h, 0))}
	best := min(box(a, h), box(b, h))
	l2 := linalg.dot(d, d)
	for c in ([4][2]f32{{-h.x, -h.y}, {-h.x, h.y}, {h.x, h.y}, {h.x, -h.y}}) {
		t := l2 > 0 ? clamp(linalg.dot(c - a, d) / l2, 0, 1) : 0
		best = min(best, linalg.length(a + d * t - c))
	}
	return best
}

// Inside a town or city: within a circle of real buildings or in a City triangle of the land use map.
urban_at :: proc(w: ^World, p: [2]f32) -> bool {
	co := &w.collide
	if !co.built do collide_build(w)
	for c in co.cities[:co.city_count] do if linalg.length(p - c) < BUILDINGS_RADIUS_KM do return true
	cx := clamp(int(p.x / COLLIDE_TRI_CELL_KM), 0, COLLIDE_TRI_W - 1)
	cy := clamp(int(p.y / COLLIDE_TRI_CELL_KM), 0, COLLIDE_TRI_H - 1)
	cell := cy * COLLIDE_TRI_W + cx
	for item in co.tri_items[co.tri_cells[cell]:co.tri_cells[cell + 1]] {
		a, b, c := w.m.area_points[item[1]], w.m.area_points[item[1] + 1], w.m.area_points[item[1] + 2]
		if in_triangle(p, a, b, c) do return true
	}
	return false
}

// True when the box of half sizes half (m) around c (km), turned to the axes ax / ay, keeps clear of every road
// and river with its sidewalk and TOWN_ROAD_GAP_M.
town_lot_clear :: proc(w: ^World, c, ax, ay, half: [2]f32) -> bool {
	co := &w.collide
	if !co.built do collide_build(w)
	if len(co.road_cells) == 0 do return true
	cx := clamp(int(c.x / COLLIDE_ROAD_CELL_KM), 0, COLLIDE_ROAD_W - 1)
	cy := clamp(int(c.y / COLLIDE_ROAD_CELL_KM), 0, COLLIDE_ROAD_H - 1)
	cell := cy * COLLIDE_ROAD_W + cx
	for item in co.road_items[co.road_cells[cell]:co.road_cells[cell + 1]] {
		k := int(item & 0xffffff)
		need := road_half_width_m(Map_Kind(item >> 24)) + ROAD_SIDEWALK_M + TOWN_ROAD_GAP_M
		pa, pb := (w.m.points[k] - c) * 1000, (w.m.points[k + 1] - c) * 1000
		a := [2]f32{linalg.dot(pa, ax), linalg.dot(pa, ay)}
		b := [2]f32{linalg.dot(pb, ax), linalg.dot(pb, ay)}
		if segment_box_m(a, b, half) < need do return false
	}
	return true
}

// What a circle of radius_m around pos (km) touches with its underside at hag m above the ground. push (m, x east,
// y south) moves it out of the walls it overlaps; roof is the highest roof right under it that it is above
// (m above the ground, 0 = none), so the car can land on a roof.
collide_car :: proc(w: ^World, pos: [2]f32, hag, radius_m: f32) -> (push: [2]f32, roof: f32) {
	prof_zone(w, .Collide_Car)
	co := &w.collide
	if !co.built do collide_build(w)

	// One footprint against the circle: pts in metres relative to pos.
	test :: proc(pts: [][2]f32, height, hag, radius_m: f32, push: ^[2]f32, roof: ^f32) {
		inside := false
		best := max(f32)
		closest: [2]f32
		n := len(pts)
		for k in 0 ..< n {
			a, b := pts[k], pts[(k + 1) % n]
			if (a.y > 0) != (b.y > 0) && a.x + (b.x - a.x) * (0 - a.y) / (b.y - a.y) > 0 do inside = !inside
			ab := b - a
			l2 := linalg.dot(ab, ab)
			t := l2 > 0 ? clamp(-linalg.dot(a, ab) / l2, 0, 1) : 0
			q := a + ab * t
			if d := linalg.dot(q, q); d < best {
				best = d
				closest = q
			}
		}
		dist := math.sqrt(best)
		if hag >= height - 0.3 {
			// Above the roof: it carries the car while the middle of the car is over it.
			if inside || dist < radius_m * 0.4 do roof^ = max(roof^, height)
			return
		}
		if inside {
			// Out through the nearest wall, then a radius further.
			push^ += dist > 1e-4 ? closest * (1 + radius_m / dist) : {radius_m, 0}
		} else if dist < radius_m {
			push^ -= closest / dist * (radius_m - dist)
		}
	}

	seen: [COLLIDE_MAX_SEEN]u32
	seen_n := 0
	ring := make([dynamic][2]f32, 0, 32, context.temp_allocator)
	r_km := radius_m / 1000

	// Real buildings: the 3 x 3 cells around pos in each city near it.
	half := f32(COLLIDE_CITY_CELLS) * COLLIDE_CELL_KM / 2
	for ci in 0 ..< co.city_count {
		rel := pos - co.cities[ci] + half
		if rel.x < -r_km || rel.y < -r_km || rel.x > 2 * half + r_km || rel.y > 2 * half + r_km do continue
		cx, cy := int(math.floor(rel.x / COLLIDE_CELL_KM)), int(math.floor(rel.y / COLLIDE_CELL_KM))
		for y in max(cy - 1, 0) ..= min(cy + 1, COLLIDE_CITY_CELLS - 1) {
			for x in max(cx - 1, 0) ..= min(cx + 1, COLLIDE_CITY_CELLS - 1) {
				c := ci * COLLIDE_CITY_CELLS * COLLIDE_CITY_CELLS + y * COLLIDE_CITY_CELLS + x
				items: for b in co.city_items[co.city_cells[c]:co.city_cells[c + 1]] {
					for s in seen[:seen_n] do if s == b do continue items
					if seen_n < COLLIDE_MAX_SEEN {
						seen[seen_n] = b
						seen_n += 1
					}
					clear(&ring)
					for p in co.points[co.b_start[b]:][:co.b_count[b]] do append(&ring, (p - pos) * 1000)
					test(ring[:], co.b_height[b], hag, radius_m, &push, &roof)
				}
			}
		}
	}

	// Generated town buildings: the lots around pos in every City triangle of the cells it touches.
	lot := f32(TOWN_LOT_M) / 1000
	reach := lot + r_km
	x0 := clamp(int(math.floor((pos.x - reach) / COLLIDE_TRI_CELL_KM)), 0, COLLIDE_TRI_W - 1)
	x1 := clamp(int(math.floor((pos.x + reach) / COLLIDE_TRI_CELL_KM)), 0, COLLIDE_TRI_W - 1)
	y0 := clamp(int(math.floor((pos.y - reach) / COLLIDE_TRI_CELL_KM)), 0, COLLIDE_TRI_H - 1)
	y1 := clamp(int(math.floor((pos.y + reach) / COLLIDE_TRI_CELL_KM)), 0, COLLIDE_TRI_H - 1)
	Lot :: struct {
		seed: u32,
		i, j: i32,
	}
	lots: [COLLIDE_MAX_SEEN]Lot
	lots_n := 0
	for cy in y0 ..= y1 {
		for cx in x0 ..= x1 {
			c := cy * COLLIDE_TRI_W + cx
			for item in co.tri_items[co.tri_cells[c]:co.tri_cells[c + 1]] {
				p0, p1, p2 :=
					w.m.area_points[item[1]], w.m.area_points[item[1] + 1], w.m.area_points[item[1] + 2]
				seed, ax, ay := town_lattice(int(item[0]))
				u := i32(math.floor(linalg.dot(pos, ax) / lot))
				v := i32(math.floor(linalg.dot(pos, ay) / lot))
				for j in v - 1 ..= v + 1 {
					lots_loop: for i in u - 1 ..= u + 1 {
						centre := (ax * (f32(i) + 0.5) + ay * (f32(j) + 0.5)) * lot
						if !in_triangle(centre, p0, p1, p2) do continue
						for l in lots[:lots_n] do if l == {seed, i, j} do continue lots_loop
						if lots_n < COLLIDE_MAX_SEEN {
							lots[lots_n] = {seed, i, j}
							lots_n += 1
						}
						corners, height, ok := town_lot(w, seed, ax, ay, i, j)
						if !ok do continue
						clear(&ring)
						for p in corners do append(&ring, (p - pos) * 1000)
						test(ring[:], height * 1000, hag, radius_m, &push, &roof)
					}
				}
			}
		}
	}
	return
}

// Unpacks the footprints of BUILDINGS_DATA (format in tools/bake_buildings, read as in buildings_build) and
// files them and the City triangles into their cells. Staging memory is a local arena, freed at the end.
collide_build :: proc(w: ^World) {
	co := &w.collide
	co^ = {}
	co.built = true
	perm := virtual.arena_allocator(&w.perm)

	// City triangles of the land use map, for the generated buildings. Two passes: count per cell, then fill.
	{
		counts := make([]u32, COLLIDE_TRI_W * COLLIDE_TRI_H + 1, perm)
		for pass in 0 ..< 2 {
			for a, ai in w.m.areas {
				if Area_Kind(a.kind) != .City do continue
				for k := a.start; k + 2 < a.start + a.count; k += 3 {
					p := w.m.area_points[k:][:3]
					lo := linalg.min(p[0], linalg.min(p[1], p[2]))
					hi := linalg.max(p[0], linalg.max(p[1], p[2]))
					x0 := clamp(int(lo.x / COLLIDE_TRI_CELL_KM), 0, COLLIDE_TRI_W - 1)
					x1 := clamp(int(hi.x / COLLIDE_TRI_CELL_KM), 0, COLLIDE_TRI_W - 1)
					y0 := clamp(int(lo.y / COLLIDE_TRI_CELL_KM), 0, COLLIDE_TRI_H - 1)
					y1 := clamp(int(hi.y / COLLIDE_TRI_CELL_KM), 0, COLLIDE_TRI_H - 1)
					for y in y0 ..= y1 {
						for x in x0 ..= x1 {
							c := y * COLLIDE_TRI_W + x
							if pass == 0 {
								counts[c + 1] += 1
							} else {
								co.tri_items[co.tri_cells[c] + counts[c]] = {u32(ai), k}
								counts[c] += 1
							}
						}
					}
				}
			}
			if pass == 0 {
				for c in 1 ..< len(counts) do counts[c] += counts[c - 1]
				co.tri_cells = counts
				co.tri_items = make([][2]u32, counts[len(counts) - 1], perm)
				counts = make([]u32, COLLIDE_TRI_W * COLLIDE_TRI_H + 1, context.temp_allocator)
			}
		}
	}

	// Road and river segments into every road cell within COLLIDE_ROAD_REACH_M of them. Two passes again.
	{
		counts := make([]u32, COLLIDE_ROAD_W * COLLIDE_ROAD_H + 1, perm)
		reach := f32(COLLIDE_ROAD_REACH_M) / 1000
		for pass in 0 ..< 2 {
			for l in w.m.lines {
				if road_half_width_m(Map_Kind(l.kind)) == 0 do continue
				for k := l.start; k + 1 < l.start + l.count; k += 1 {
					a, b := w.m.points[k], w.m.points[k + 1]
					lo := linalg.min(a, b) - reach
					hi := linalg.max(a, b) + reach
					x0 := clamp(int(lo.x / COLLIDE_ROAD_CELL_KM), 0, COLLIDE_ROAD_W - 1)
					x1 := clamp(int(hi.x / COLLIDE_ROAD_CELL_KM), 0, COLLIDE_ROAD_W - 1)
					y0 := clamp(int(lo.y / COLLIDE_ROAD_CELL_KM), 0, COLLIDE_ROAD_H - 1)
					y1 := clamp(int(hi.y / COLLIDE_ROAD_CELL_KM), 0, COLLIDE_ROAD_H - 1)
					for y in y0 ..= y1 {
						for x in x0 ..= x1 {
							c := y * COLLIDE_ROAD_W + x
							if pass == 0 {
								counts[c + 1] += 1
							} else {
								co.road_items[co.road_cells[c] + counts[c]] = l.kind << 24 | k
								counts[c] += 1
							}
						}
					}
				}
			}
			if pass == 0 {
				for c in 1 ..< len(counts) do counts[c] += counts[c - 1]
				co.road_cells = counts
				co.road_items = make([]u32, counts[len(counts) - 1], perm)
				counts = make([]u32, COLLIDE_ROAD_W * COLLIDE_ROAD_H + 1, context.temp_allocator)
			}
		}
	}

	scratch: virtual.Arena
	if virtual.arena_init_growing(&scratch) != nil do return
	defer virtual.arena_destroy(&scratch)
	tmp := virtual.arena_allocator(&scratch)
	unzipped := make([dynamic]u8, 0, 4 << 20, tmp)
	if err := deflate.inflate_gzip(&unzipped, BUILDINGS_DATA, allocator = tmp); err != nil {
		logf(w, "collide", "buildings.bin.gz does not unpack: %v, no building collision", err)
		return
	}
	data := unzipped[:]
	Header :: struct {
		magic, version, city_count, _: u32le,
	}
	City :: struct {
		origin:                       [2]f32le,
		building_count, vertex_count: u32le,
	}
	if len(data) < size_of(Header) do return
	h := (^Header)(raw_data(data))^
	if h.magic != 0x44425244 || h.version != 1 || int(h.city_count) > BUILDINGS_MAX_CITIES {
		logf(w, "collide", "buildings.bin: wrong magic, version or city count %d", h.city_count)
		return
	}
	cities := ([^]City)(raw_data(data[size_of(Header):]))[:h.city_count]
	off := size_of(Header) + int(h.city_count) * size_of(City)
	total_b, total_v := 0, 0
	for c in cities {
		total_b += int(c.building_count)
		total_v += int(c.vertex_count)
	}
	if len(data) != off + total_b * 2 + total_v * 4 {
		logf(
			w,
			"collide",
			"buildings.bin: %d bytes, the header says %d",
			len(data),
			off + total_b * 2 + total_v * 4,
		)
		return
	}
	counts_b := data[off:][:total_b]
	heights := data[off + total_b:][:total_b]
	planes := data[off + total_b * 2:]

	co.points = make([][2]f32, total_v, perm)
	co.b_start = make([]u32, total_b, perm)
	co.b_count = make([]u32, total_b, perm)
	co.b_height = make([]f32, total_b, perm)
	b_city := make([]u32, total_b, tmp)
	bi, vi := 0, 0
	for c, ci in cities {
		origin := [2]f32{f32(c.origin.x), f32(c.origin.y)}
		co.cities[ci] = origin
		for _ in 0 ..< c.building_count {
			n := int(counts_b[bi])
			q: [2]i32
			mid: [2]f32
			for k in 0 ..< n {
				i := vi + k
				q.x += i32(i16(u16(planes[i]) | u16(planes[total_v + i]) << 8))
				q.y += i32(i16(u16(planes[2 * total_v + i]) | u16(planes[3 * total_v + i]) << 8))
				co.points[i] = origin + [2]f32{f32(q.x), f32(q.y)} * BUILDINGS_POS_UNIT_M / 1000
				mid += co.points[i]
			}
			// The same height as the mesh at real scale: lowered towards the edge of the baked circle.
			height := f32(heights[bi])
			if n > 0 {
				edge := linalg.length(mid / f32(n) - origin) / BUILDINGS_RADIUS_KM
				height *= 1 - 0.75 * math.smoothstep(f32(0.6), 1, edge)
			}
			co.b_start[bi] = u32(vi)
			co.b_count[bi] = n >= 3 ? u32(n) : 0
			co.b_height[bi] = height
			b_city[bi] = u32(ci)
			vi += n
			bi += 1
		}
	}
	co.city_count = len(cities)

	// Each building into every 100 m cell its box touches. Two passes again.
	cells := len(cities) * COLLIDE_CITY_CELLS * COLLIDE_CITY_CELLS
	counts := make([]u32, cells + 1, perm)
	half := f32(COLLIDE_CITY_CELLS) * COLLIDE_CELL_KM / 2
	for pass in 0 ..< 2 {
		for b in 0 ..< total_b {
			if co.b_count[b] == 0 do continue
			ci := int(b_city[b])
			pts := co.points[co.b_start[b]:][:co.b_count[b]]
			lo, hi := pts[0], pts[0]
			for p in pts {
				lo = linalg.min(lo, p)
				hi = linalg.max(hi, p)
			}
			lo = lo - co.cities[ci] + half
			hi = hi - co.cities[ci] + half
			x0 := clamp(int(lo.x / COLLIDE_CELL_KM), 0, COLLIDE_CITY_CELLS - 1)
			x1 := clamp(int(hi.x / COLLIDE_CELL_KM), 0, COLLIDE_CITY_CELLS - 1)
			y0 := clamp(int(lo.y / COLLIDE_CELL_KM), 0, COLLIDE_CITY_CELLS - 1)
			y1 := clamp(int(hi.y / COLLIDE_CELL_KM), 0, COLLIDE_CITY_CELLS - 1)
			for y in y0 ..= y1 {
				for x in x0 ..= x1 {
					c := ci * COLLIDE_CITY_CELLS * COLLIDE_CITY_CELLS + y * COLLIDE_CITY_CELLS + x
					if pass == 0 {
						counts[c + 1] += 1
					} else {
						co.city_items[co.city_cells[c] + counts[c]] = u32(b)
						counts[c] += 1
					}
				}
			}
		}
		if pass == 0 {
			for c in 1 ..< len(counts) do counts[c] += counts[c - 1]
			co.city_cells = counts
			co.city_items = make([]u32, counts[len(counts) - 1], perm)
			counts = make([]u32, cells + 1, tmp)
		}
	}
	logf(
		w,
		"collide",
		"%d buildings in %d cities, %d cell entries, %d town triangle entries, %d road entries",
		total_b,
		co.city_count,
		len(co.city_items),
		len(co.tri_items),
		len(co.road_items),
	)
}
