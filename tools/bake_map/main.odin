package bake_map

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:slice"

MAP_MAGIC :: 0x54465244
MAP_VERSION :: 1

Map_Header :: struct {
	magic, version:                      u32,
	line_count, point_count, city_count: u32,
}
Map_Line :: struct {
	start, count, kind: u32,
}
Map_City :: struct {
	pos:  [2]f32,
	name: [32]u8,
}
Kind :: enum u32 {
	Border,
	River,
	Motorway,
}

LON0 :: 2.38
LAT0 :: 51.56
KM_PER_DEG :: 111.32

lines: [dynamic]Map_Line
points: [dynamic][2]f32
cities: [dynamic]Map_City

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

add_line :: proc(coords: json.Value, kind: Kind) {
	a := coords.(json.Array)
	start := u32(len(points))
	for c in a do append(&points, to_point(c))
	append(&lines, Map_Line{start, u32(len(a)), u32(kind)})
}

bake_layer :: proc(path: string, kind: Kind) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintln("can't read", path, err)
		os.exit(1)
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

		switch geom["type"].(json.String) {
		case "Point":
			c := Map_City {
				pos = to_point(coords),
			}
			name, _ := feature["properties"].(json.Object)["name"].(json.String)
			copy(c.name[:len(c.name) - 1], name)
			append(&cities, c)
		case "LineString":
			add_line(coords, kind)
		case "MultiLineString", "Polygon":
			for l in coords.(json.Array) do add_line(l, kind)
		case "MultiPolygon":
			for p in coords.(json.Array) do for r in p.(json.Array) do add_line(r, kind)
		}
	}
}

main :: proc() {
	bake_layer("assets/geojson/border.geojson", .Border)
	bake_layer("assets/geojson/rivers.geojson", .River)
	bake_layer("assets/geojson/motorways.geojson", .Motorway)
	bake_layer("assets/geojson/cities.geojson", .Border)

	h := Map_Header{MAP_MAGIC, MAP_VERSION, u32(len(lines)), u32(len(points)), u32(len(cities))}

	out: [dynamic]u8
	append(&out, ..mem.ptr_to_bytes(&h))
	append(&out, ..slice.to_bytes(lines[:]))
	append(&out, ..slice.to_bytes(points[:]))
	append(&out, ..slice.to_bytes(cities[:]))

	if err := os.write_entire_file("assets/belgium.bin", out[:]); err != nil {
		fmt.eprintln("can't write assets/belgium.bin", err)
		os.exit(1)
	}
	fmt.printfln(
		"assets/belgium.bin: %d lines, %d points, %d cities, %d bytes",
		h.line_count,
		h.point_count,
		h.city_count,
		len(out),
	)
}
