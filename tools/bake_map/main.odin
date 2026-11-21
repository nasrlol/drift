package bake_map

import "core:compress/deflate"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"

MAP_MAGIC :: 0x54465244
MAP_VERSION :: 4
MAX_HUBS :: 32
// Same as map.odin: every point in belgium.bin lies inside 0..MAP_W_KM x 0..MAP_H_KM.
MAP_W_KM :: 286
MAP_H_KM :: 237
// Same as map.odin: one height sample per 250 m cell, at the cell centre.
HEIGHT_CELL_KM :: 0.25
HEIGHT_W :: MAP_W_KM * 4
HEIGHT_H :: MAP_H_KM * 4
#assert(HEIGHT_W * HEIGHT_CELL_KM == MAP_W_KM && HEIGHT_H * HEIGHT_CELL_KM == MAP_H_KM)
// Hillshade: the vertical exaggeration that makes the Ardennes readable at 250 m cells (the valleys are
// 100-200 m deep, Flanders stays near flat), and the light from the north-west, 45 degrees up.
HILLSHADE_Z :: 4
HILLSHADE_AZIMUTH_DEG :: 315
HILLSHADE_ALTITUDE_DEG :: 45
// Same as map.odin: the name index is a grid of NAME_CELL_KM cells over the map.
NAME_CELL_KM :: 10
NAME_GRID_W :: (MAP_W_KM + NAME_CELL_KM - 1) / NAME_CELL_KM
NAME_GRID_H :: (MAP_H_KM + NAME_CELL_KM - 1) / NAME_CELL_KM

Map_Header :: struct {
	magic, version:                      u32,
	line_count, point_count, city_count: u32,
	hub_count, names_size:               u32,
	name_cell_count, name_run_count:     u32,
	area_count, area_point_count:        u32,
	height_w, height_h:                  u32,
}
// Triangles area_points[start:][:count], 3 points each, of one land use polygon.
Map_Area :: struct {
	start, count, kind: u32,
}
// Same order as Area_Kind in map.odin. belgium.bin lists the areas in this order.
Area_Kind :: enum u32 {
	City,
	Park,
	Farmland,
	Marsh,
	Beach,
	Water,
}
// Polygons smaller than this are dropped: they are a few pixels at the zoom that shows them, and they are
// most of the polygons (see notes.txt for the numbers).
AREA_MIN_KM2 :: 0.5
// name, ref: offsets into the names blob, 0 = none.
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
// Segments start ..< start + count of line (point indices of each segment's first point), all touching
// one cell of the name index.
Map_Name_Run :: struct {
	line, start, count: u32,
}
// Lines are drawn in this order, so a bigger road lies on top of a smaller one where they cross.
Kind :: enum u32 {
	Border,
	River,
	Tertiary,
	Secondary,
	Primary,
	Trunk,
	Motorway,
}

LON0 :: 2.38
LAT0 :: 51.56
KM_PER_DEG :: 111.32

lines: [dynamic]Map_Line
points: [dynamic][2]f32
cities: [dynamic]Map_City
hubs: [dynamic]Map_Hub
// 0-terminated strings, offset 0 is the empty string. name_at finds a string already in it.
names: [dynamic]u8
name_at: map[string]u32

project :: proc(lon, lat: f64) -> [2]f32 {
	cos_lat := math.cos(50.5 * math.RAD_PER_DEG)
	return {f32((lon - LON0) * KM_PER_DEG * cos_lat), f32((LAT0 - lat) * KM_PER_DEG)}
}

num :: proc(v: json.Value) -> f64 {
	#partial switch n in v {
	case json.Float:
		return f64(n)
	case json.Integer:
		return f64(n)
	}
	return 0
}

to_point :: proc(v: json.Value) -> [2]f32 {
	a := v.(json.Array)
	return project(num(a[0]), num(a[1]))
}

// Offset of s in names, added the first time it is seen. Offsets follow the feature order of the geojson
// files, so the blob is the same on every run (the map is only looked up, never iterated).
intern :: proc(s: string) -> u32 {
	if len(s) == 0 do return 0
	if off, ok := name_at[s]; ok do return off
	off := u32(len(names))
	append(&names, s)
	append(&names, 0)
	name_at[s] = off
	return off
}

// The extract reaches a little past the border, so each segment is clipped to the map rectangle
// (Liang-Barsky). A line that leaves the map and comes back becomes two lines. Fewer than 2 points give no
// line: GDAL writes an empty geometry for a way whose nodes are missing from the extract.
add_line :: proc(coords: json.Value, kind: Kind, name, ref: u32) {
	// Ends the line started at start, or drops a lone point.
	flush :: proc(start: ^u32, kind: Kind, name, ref: u32) {
		n := u32(len(points)) - start^
		if n >= 2 do append(&lines, Map_Line{start^, n, u32(kind), name, ref})
		else do resize(&points, int(start^))
		start^ = u32(len(points))
	}

	a := coords.(json.Array)
	start := u32(len(points))
	for i in 1 ..< len(a) {
		p, q := to_point(a[i - 1]), to_point(a[i])
		d := q - p
		t0, t1: f32 = 0, 1
		visible := true
		for e in ([4][2]f32{{-d.x, p.x}, {d.x, MAP_W_KM - p.x}, {-d.y, p.y}, {d.y, MAP_H_KM - p.y}}) {
			if e[0] == 0 {
				if e[1] < 0 do visible = false
			} else if e[0] < 0 {
				t0 = max(t0, e[1] / e[0])
			} else {
				t1 = min(t1, e[1] / e[0])
			}
		}
		if !visible || t0 > t1 {
			flush(&start, kind, name, ref)
			continue
		}

		if t0 > 0 do flush(&start, kind, name, ref)
		if u32(len(points)) == start do append(&points, t0 > 0 ? p + d * t0 : p)
		append(&points, t1 < 1 ? p + d * t1 : q)
		if t1 < 1 do flush(&start, kind, name, ref)
	}
	flush(&start, kind, name, ref)
}

// The features of a geojson file, gunzipped first when the name ends in .gz.
read_features :: proc(path: string) -> json.Array {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintln("can't read", path, err)
		os.exit(1)
	}
	// Big extracts are kept gzipped in git (roads.geojson is 32 MB, 3.9 MB gzipped, #71).
	if strings.has_suffix(path, ".gz") {
		unzipped: [dynamic]u8
		if zerr := deflate.inflate_gzip(&unzipped, data); zerr != nil {
			fmt.eprintln("can't gunzip", path, zerr)
			os.exit(1)
		}
		data = unzipped[:]
	}
	root, jerr := json.parse(data)
	if jerr != .None {
		fmt.eprintln("bad json in", path, jerr)
		os.exit(1)
	}
	return root.(json.Object)["features"].(json.Array)
}

bake_layer :: proc(path: string, kind: Kind, is_cities := false) {
	for f in read_features(path) {
		feature := f.(json.Object)
		geom := feature["geometry"].(json.Object)
		coords := geom["coordinates"]
		props := feature["properties"].(json.Object)

		// Roads carry their class in the OSM highway tag. A link (ramp) belongs to the road it joins.
		kind := kind
		if tag, is_road := props["highway"].(json.String); is_road {
			switch tag {
			case "motorway", "motorway_link":
				kind = .Motorway
			case "trunk", "trunk_link":
				kind = .Trunk
			case "primary", "primary_link":
				kind = .Primary
			case "secondary", "secondary_link":
				kind = .Secondary
			case "tertiary", "tertiary_link":
				kind = .Tertiary
			case:
				fmt.eprintfln("%s: highway=%q is not a road class we bake", path, tag)
				os.exit(1)
			}
		}

		// The border has the country name and the cities keep theirs in Map_City, neither is a line label.
		name_str, _ := props["name"].(json.String)
		ref_str, _ := props["ref"].(json.String)
		name, ref: u32
		if kind != .Border do name, ref = intern(name_str), intern(ref_str)

		switch geom["type"].(json.String) {
		case "Point":
			// GDAL 3.8 simplifies a way shorter than the tolerance to a Point. Only the cities are real points.
			if !is_cities do continue
			c := Map_City {
				pos = to_point(coords),
			}
			copy(c.name[:len(c.name) - 1], name_str)
			append(&cities, c)
		case "LineString":
			add_line(coords, kind, name, ref)
		case "MultiLineString", "Polygon":
			for l in coords.(json.Array) do add_line(l, kind, name, ref)
		case "MultiPolygon":
			for p in coords.(json.Array) do for r in p.(json.Array) do add_line(r, kind, name, ref)
		}
	}
}

// Land use polygons -> triangles. Only the outer ring is kept: holes (a clearing in a forest, a lake in a
// park) are dropped, so they are drawn filled. The water polygons are separate areas and drawn on top of the
// land kinds (Water is the last kind), so a lake in a park still shows as water. Triangulated by ear clipping
// in map space, then each triangle is clipped to the map rectangle, so every point stays inside the map.
bake_areas :: proc(path: string) -> (areas: [dynamic]Map_Area, area_points: [dynamic][2]f32) {
	Polygon :: struct {
		kind:      Area_Kind,
		triangles: [][2]f32,
	}
	polygons: [dynamic]Polygon
	dropped_small, dropped_other: int
	// Triangles cover the ring exactly unless ear clipping had to force a cut in a self-crossing ring.
	ring_area, triangle_area: f64
	for f in read_features(path) {
		feature := f.(json.Object)
		geom := feature["geometry"].(json.Object)
		props := feature["properties"].(json.Object)

		landuse, _ := props["landuse"].(json.String)
		natural, _ := props["natural"].(json.String)
		leisure, _ := props["leisure"].(json.String)
		kind: Area_Kind
		switch {
		case landuse == "residential" ||
		     landuse == "commercial" ||
		     landuse == "industrial" ||
		     landuse == "retail":
			kind = .City
		case landuse == "forest" || natural == "wood" || leisure == "park":
			kind = .Park
		case landuse == "farmland" || landuse == "farmyard" || landuse == "orchard" || landuse == "vineyard":
			kind = .Farmland
		case natural == "wetland":
			kind = .Marsh
		case natural == "beach" || natural == "sand":
			kind = .Beach
		case natural == "water":
			kind = .Water
		case:
			fmt.eprintfln(
				"%s: landuse=%q natural=%q leisure=%q is not an area kind we bake",
				path,
				landuse,
				natural,
				leisure,
			)
			os.exit(1)
		}

		// GDAL 3.8 turns a polygon simplified below its tolerance into a line or a collection, those are skipped.
		rings: [dynamic]json.Value
		switch geom["type"].(json.String) {
		case "Polygon":
			append(&rings, geom["coordinates"].(json.Array)[0])
		case "MultiPolygon":
			for p in geom["coordinates"].(json.Array) do append(&rings, p.(json.Array)[0])
		case:
			dropped_other += 1
		}

		for r in rings {
			ring: [dynamic][2]f32
			for c in r.(json.Array) {
				p := to_point(c)
				if len(ring) == 0 || ring[len(ring) - 1] != p do append(&ring, p)
			}
			if len(ring) > 1 && ring[0] == ring[len(ring) - 1] do pop(&ring)
			if len(ring) < 3 do continue

			// Shoelace; made positive so convex corners have a positive cross product below.
			area: f32
			for p, i in ring {
				q := ring[(i + 1) % len(ring)]
				area += p.x * q.y - q.x * p.y
			}
			if area < 0 do slice.reverse(ring[:])
			if abs(area) / 2 < AREA_MIN_KM2 {
				dropped_small += 1
				continue
			}
			triangles := triangulate(ring[:])
			ring_area += f64(abs(area) / 2)
			for t := 0; t + 3 <= len(triangles); t += 3 {
				triangle_area += f64(abs(cross(triangles[t], triangles[t + 1], triangles[t + 2])) / 2)
			}
			append(&polygons, Polygon{kind, triangles})
		}
	}
	slice.stable_sort_by(polygons[:], proc(a, b: Polygon) -> bool {return a.kind < b.kind})

	for poly in polygons {
		start := u32(len(area_points))
		for t := 0; t + 3 <= len(poly.triangles); t += 3 do clip_triangle(&area_points, poly.triangles[t:][:3])
		if n := u32(len(area_points)) - start; n > 0 do append(&areas, Map_Area{start, n, u32(poly.kind)})
	}
	fmt.printfln(
		"areas: %d polygons kept, %d below %v km2 dropped, %d degenerate geometries skipped, %d triangles, rings %.1f km2, triangles %.1f km2",
		len(polygons),
		dropped_small,
		AREA_MIN_KM2,
		dropped_other,
		len(area_points) / 3,
		ring_area,
		triangle_area,
	)
	return
}

// tools/warp_dem.sh writes the heights: i16 m, HEIGHT_W x HEIGHT_H, row-major, y down, little endian.
// Hillshade from them: 128 = flat, 255 = facing the light, 0 = facing away by 90 degrees or more.
bake_heights :: proc(path: string) -> (heights: []i16, hillshade: []u8) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintln("can't read", path, err)
		os.exit(1)
	}
	raw: [dynamic]u8
	if zerr := deflate.inflate_gzip(&raw, data); zerr != nil {
		fmt.eprintln("can't gunzip", path, zerr)
		os.exit(1)
	}
	if len(raw) != HEIGHT_W * HEIGHT_H * 2 {
		fmt.eprintfln("%s: %d bytes, want %d x %d x 2", path, len(raw), HEIGHT_W, HEIGHT_H)
		os.exit(1)
	}
	heights = make([]i16, HEIGHT_W * HEIGHT_H)
	lo, hi: i16 = max(i16), min(i16)
	for &h, i in heights {
		h = i16(u16(raw[2 * i]) | u16(raw[2 * i + 1]) << 8)
		lo, hi = min(lo, h), max(hi, h)
	}
	// Belgium is -10..700 m, open pit quarries go below sea level (-97 m near Tournai). Anything far outside
	// is a broken warp, not terrain.
	if lo < -500 || hi > 3000 {
		fmt.eprintfln("%s: heights %d..%d m, outside -500..3000", path, lo, hi)
		os.exit(1)
	}

	hillshade = make([]u8, HEIGHT_W * HEIGHT_H)
	az := f32(HILLSHADE_AZIMUTH_DEG) * math.RAD_PER_DEG
	alt := f32(HILLSHADE_ALTITUDE_DEG) * math.RAD_PER_DEG
	light := [3]f32{math.cos(alt) * math.sin(az), math.cos(alt) * math.cos(az), math.sin(alt)} // east, north, up
	flat := light.z
	at :: proc(heights: []i16, x, y: int) -> f32 {
		return f32(heights[clamp(y, 0, HEIGHT_H - 1) * HEIGHT_W + clamp(x, 0, HEIGHT_W - 1)])
	}
	for y in 0 ..< HEIGHT_H {
		for x in 0 ..< HEIGHT_W {
			// Horn's 3 x 3 gradient, the same as gdaldem hillshade. Row y - 1 is north.
			nw, n, ne := at(heights, x - 1, y - 1), at(heights, x, y - 1), at(heights, x + 1, y - 1)
			w, e := at(heights, x - 1, y), at(heights, x + 1, y)
			sw, s, se := at(heights, x - 1, y + 1), at(heights, x, y + 1), at(heights, x + 1, y + 1)
			cell_m := f32(HEIGHT_CELL_KM * 1000)
			dzdx := ((ne + 2 * e + se) - (nw + 2 * w + sw)) / (8 * cell_m) * HILLSHADE_Z
			dzdn := ((nw + 2 * n + ne) - (sw + 2 * s + se)) / (8 * cell_m) * HILLSHADE_Z
			normal := [3]f32{-dzdx, -dzdn, 1}
			lit :=
				(normal.x * light.x + normal.y * light.y + normal.z * light.z) /
				math.sqrt(normal.x * normal.x + normal.y * normal.y + 1)
			v := lit <= flat ? 128 * max(lit, 0) / flat : 128 + 127 * (lit - flat) / (1 - flat)
			hillshade[y * HEIGHT_W + x] = u8(math.round(clamp(v, 0, 255)))
		}
	}
	fmt.printfln("heights: %d x %d, %d..%d m", HEIGHT_W, HEIGHT_H, lo, hi)
	return
}

cross :: proc(a, b, c: [2]f32) -> f32 {
	return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
}

// Ear clipping, O(n^2). ring is counter-clockwise in the sense that convex corners have cross > 0.
// The simplified rings can touch or cross themselves; when a full round finds no ear the corner at hand is
// cut anyway, so a bad ring gives a few wrong triangles instead of an endless loop.
triangulate :: proc(ring: [][2]f32) -> [][2]f32 {
	n := len(ring)
	out := make([dynamic][2]f32, 0, 3 * (n - 2))
	prev := make([]int, n)
	next := make([]int, n)
	for i in 0 ..< n {
		prev[i] = (i + n - 1) % n
		next[i] = (i + 1) % n
	}
	i, left, misses := 0, n, 0
	for left > 3 {
		a, b, c := ring[prev[i]], ring[i], ring[next[i]]
		ear := cross(a, b, c) > 0
		// No other corner may lie in the ear (on its edge counts as in).
		for j := next[next[i]]; ear && j != prev[i]; j = next[j] {
			p := ring[j]
			if p == a || p == b || p == c do continue
			if cross(a, b, p) >= 0 && cross(b, c, p) >= 0 && cross(c, a, p) >= 0 do ear = false
		}
		if ear || misses >= left {
			if cross(a, b, c) != 0 do append(&out, a, b, c)
			next[prev[i]], prev[next[i]] = next[i], prev[i]
			left -= 1
			misses = 0
			i = prev[i]
		} else {
			misses += 1
			i = next[i]
		}
	}
	a, b, c := ring[prev[i]], ring[i], ring[next[i]]
	if cross(a, b, c) != 0 do append(&out, a, b, c)
	return out[:]
}

// Sutherland-Hodgman against the map rectangle, the result (convex) as a triangle fan.
clip_triangle :: proc(out: ^[dynamic][2]f32, tri: [][2]f32) {
	poly: [dynamic][2]f32
	append(&poly, ..tri)
	for edge in 0 ..< 4 {
		inside :: proc(p: [2]f32, edge: int) -> f32 {
			switch edge {
			case 0:
				return p.x
			case 1:
				return MAP_W_KM - p.x
			case 2:
				return p.y
			}
			return MAP_H_KM - p.y
		}
		clipped: [dynamic][2]f32
		for p, k in poly {
			q := poly[(k + 1) % len(poly)]
			dp, dq := inside(p, edge), inside(q, edge)
			if dp >= 0 do append(&clipped, p)
			if (dp >= 0) != (dq >= 0) do append(&clipped, p + (q - p) * (dp / (dp - dq)))
		}
		poly = clipped
		if len(poly) < 3 do return
	}
	for k in 1 ..< len(poly) - 1 do append(out, poly[0], poly[k], poly[k + 1])
}

main :: proc() {
	append(&names, 0)
	bake_layer("assets/geojson/border.geojson", .Border)
	bake_layer("assets/geojson/rivers.geojson", .River)
	bake_layer("assets/geojson/roads.geojson.gz", .Motorway) // kind comes from each road's highway tag
	bake_layer("assets/geojson/cities.geojson", .Border, is_cities = true)
	areas, area_points := bake_areas("assets/geojson/areas.geojson.gz")
	heights, hillshade := bake_heights("assets/geojson/heights.i16.gz")

	// OSM cuts a road into a new way at every tag change, so most lines are a few points long and the line
	// table outweighs the points. Join lines of one kind that meet end to end where no third line of that
	// kind touches. The drawing stays the same, only the shared end point and the line entry go. Name and ref
	// are part of the key, so a joined line has one name: E40 and E19 sharing a node stay two lines.
	{
		End :: struct {
			pos:             [2]f32,
			kind, name, ref: u32,
		}
		first :: proc(l: Map_Line, reversed: bool) -> [2]f32 {
			return points[reversed ? l.start + l.count - 1 : l.start]
		}
		last :: proc(l: Map_Line, reversed: bool) -> [2]f32 {
			return points[reversed ? l.start : l.start + l.count - 1]
		}

		// Lines per end point. Only looked up, never iterated, so the output order does not depend on the map.
		at: map[End][dynamic]int
		for l, i in lines {
			for p in ([2][2]f32{first(l, false), last(l, false)}) {
				list := at[{p, l.kind, l.name, l.ref}]
				append(&list, i)
				at[{p, l.kind, l.name, l.ref}] = list
			}
		}
		// The other line at e when exactly two line ends meet there, else -1 (also for a ring closing on itself).
		next :: proc(at: map[End][dynamic]int, e: End, cur: int) -> int {
			list := at[e]
			if len(list) != 2 do return -1
			other := list[0] == cur ? list[1] : list[0]
			return other == cur ? -1 : other
		}

		merged_lines: [dynamic]Map_Line
		merged_points: [dynamic][2]f32
		used := make([]bool, len(lines))
		for l, i in lines {
			if used[i] do continue

			// Walk back to the first line of the chain, stop if it comes round to i (a closed loop).
			head, head_rev := i, false
			for {
				p := first(lines[head], head_rev)
				j := next(at, {p, l.kind, l.name, l.ref}, head)
				if j < 0 || j == i || used[j] do break
				head, head_rev = j, first(lines[j], false) == p
			}

			// Then forward from the head, every following line flipped so it starts where the last one ended.
			start := u32(len(merged_points))
			cur, rev := head, head_rev
			for {
				used[cur] = true
				c := lines[cur]
				pts := points[c.start:][:c.count]
				skip := len(merged_points) > int(start) ? 1 : 0
				if rev {
					#reverse for p, k in pts do if k < len(pts) - skip do append(&merged_points, p)
				} else {
					append(&merged_points, ..pts[skip:])
				}
				p := last(c, rev)
				j := next(at, {p, l.kind, l.name, l.ref}, cur)
				if j < 0 || used[j] do break
				cur, rev = j, last(lines[j], false) == p
			}
			append(&merged_lines, Map_Line{start, u32(len(merged_points)) - start, l.kind, l.name, l.ref})
		}
		lines, points = merged_lines, merged_points
	}
	slice.stable_sort_by(lines[:], proc(a, b: Map_Line) -> bool {return a.kind < b.kind})

	// Hubs start as the cities. They get their own list so towers can later stand away from city centres.
	for c in cities do append(&hubs, Map_Hub{c.pos, c.name})
	if len(hubs) > MAX_HUBS {
		fmt.eprintfln("%d hubs, the game has room for %d (MAX_HUBS)", len(hubs), MAX_HUBS)
		os.exit(1)
	}

	// Name index for map_nearest_name: per cell the runs of labelled segments whose bounding box touches it.
	// Baked rather than built at startup: the game would have to rebuild it into the perm arena after every
	// hot reload, and belgium.bin slices are re-pointed for free.
	name_cells := make([]u32, NAME_GRID_W * NAME_GRID_H + 1)
	name_runs: [dynamic]Map_Name_Run
	{
		labelled :: proc(l: Map_Line) -> bool {
			if Kind(l.kind) == .Border do return false
			return l.name != 0 || (Kind(l.kind) == .Motorway && l.ref != 0)
		}
		// cell, line, segment: sorted so the runs come out in a fixed order.
		hits: [dynamic][3]u32
		for l, i in lines {
			if !labelled(l) do continue
			for k in l.start ..< l.start + l.count - 1 {
				a, b := points[k], points[k + 1]
				x0 := clamp(int(min(a.x, b.x) / NAME_CELL_KM), 0, NAME_GRID_W - 1)
				x1 := clamp(int(max(a.x, b.x) / NAME_CELL_KM), 0, NAME_GRID_W - 1)
				y0 := clamp(int(min(a.y, b.y) / NAME_CELL_KM), 0, NAME_GRID_H - 1)
				y1 := clamp(int(max(a.y, b.y) / NAME_CELL_KM), 0, NAME_GRID_H - 1)
				for y in y0 ..= y1 do for x in x0 ..= x1 do append(&hits, [3]u32{u32(y * NAME_GRID_W + x), u32(i), k})
			}
		}
		slice.sort_by(hits[:], proc(a, b: [3]u32) -> bool {
			if a[0] != b[0] do return a[0] < b[0]
			if a[1] != b[1] do return a[1] < b[1]
			return a[2] < b[2]
		})
		for hit, i in hits {
			prev := i > 0 ? hits[i - 1] : {max(u32), 0, 0}
			if prev[0] == hit[0] && prev[1] == hit[1] && prev[2] + 1 == hit[2] {
				name_runs[len(name_runs) - 1].count += 1
			} else {
				append(&name_runs, Map_Name_Run{hit[1], hit[2], 1})
				name_cells[hit[0] + 1] += 1
			}
		}
		for i in 1 ..< len(name_cells) do name_cells[i] += name_cells[i - 1]
		fmt.printfln("name index: %d segment hits, %d runs", len(hits), len(name_runs))
	}

	// Padded with zeros so the next block stays 4-byte aligned; the last byte is always 0.
	for len(names) % 4 != 0 do append(&names, 0)

	h := Map_Header {
		magic            = MAP_MAGIC,
		version          = MAP_VERSION,
		line_count       = u32(len(lines)),
		point_count      = u32(len(points)),
		city_count       = u32(len(cities)),
		hub_count        = u32(len(hubs)),
		names_size       = u32(len(names)),
		name_cell_count  = u32(len(name_cells)),
		name_run_count   = u32(len(name_runs)),
		area_count       = u32(len(areas)),
		area_point_count = u32(len(area_points)),
		height_w         = HEIGHT_W,
		height_h         = HEIGHT_H,
	}

	out: [dynamic]u8
	append(&out, ..mem.ptr_to_bytes(&h))
	append(&out, ..slice.to_bytes(lines[:]))
	append(&out, ..slice.to_bytes(points[:]))
	append(&out, ..slice.to_bytes(cities[:]))
	append(&out, ..slice.to_bytes(hubs[:]))
	append(&out, ..names[:])
	append(&out, ..slice.to_bytes(name_cells))
	append(&out, ..slice.to_bytes(name_runs[:]))
	append(&out, ..slice.to_bytes(areas[:]))
	append(&out, ..slice.to_bytes(area_points[:]))
	append(&out, ..slice.to_bytes(heights))
	append(&out, ..hillshade)

	if err := os.write_entire_file("assets/belgium.bin", out[:]); err != nil {
		fmt.eprintln("can't write assets/belgium.bin", err)
		os.exit(1)
	}
	fmt.printfln(
		"assets/belgium.bin: %d lines, %d points, %d cities, %d hubs, %d bytes of names, %d areas, %d area points, %d bytes",
		h.line_count,
		h.point_count,
		h.city_count,
		h.hub_count,
		h.names_size,
		h.area_count,
		h.area_point_count,
		len(out),
	)
}
