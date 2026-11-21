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

Map_Header :: struct {
	magic, version:                      u32,
	line_count, point_count, city_count: u32,
	hub_count, names_size:               u32,
}
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

bake_layer :: proc(path: string, kind: Kind, is_cities := false) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintln("can't read", path, err)
		os.exit(1)
	}
	// roads.geojson is 32 MB, git keeps it gzipped (3.9 MB, #71).
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

	for f in root.(json.Object)["features"].(json.Array) {
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

main :: proc() {
	append(&names, 0)
	bake_layer("assets/geojson/border.geojson", .Border)
	bake_layer("assets/geojson/rivers.geojson", .River)
	bake_layer("assets/geojson/roads.geojson.gz", .Motorway) // kind comes from each road's highway tag
	bake_layer("assets/geojson/cities.geojson", .Border, is_cities = true)

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

	h := Map_Header {
		MAP_MAGIC,
		MAP_VERSION,
		u32(len(lines)),
		u32(len(points)),
		u32(len(cities)),
		u32(len(hubs)),
		0,
	}
	// Padded with zeros so the next block stays 4-byte aligned; the last byte is always 0.
	for len(names) % 4 != 0 do append(&names, 0)
	h.names_size = u32(len(names))

	out: [dynamic]u8
	append(&out, ..mem.ptr_to_bytes(&h))
	append(&out, ..slice.to_bytes(lines[:]))
	append(&out, ..slice.to_bytes(points[:]))
	append(&out, ..slice.to_bytes(cities[:]))
	append(&out, ..slice.to_bytes(hubs[:]))
	append(&out, ..names[:])

	if err := os.write_entire_file("assets/belgium.bin", out[:]); err != nil {
		fmt.eprintln("can't write assets/belgium.bin", err)
		os.exit(1)
	}
	fmt.printfln(
		"assets/belgium.bin: %d lines, %d points, %d cities, %d hubs, %d bytes of names, %d bytes",
		h.line_count,
		h.point_count,
		h.city_count,
		h.hub_count,
		h.names_size,
		len(out),
	)
}
