package bake_world

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:slice"

WORLD_MAGIC :: 0x444C5257 // "WRLD"
WORLD_VERSION :: 2
WORLD_MASK_W :: 2048
WORLD_MASK_H :: 1024
// A finer land mask on the coast next to Belgium (version 2): the world mask is ~12 x 20 km per pixel there, too
// coarse for the Scheldt estuary and the Zeeland islands beside the flat map. Inland the world mask is right
// (all land), and check.sh keeps world.bin under 1 MB, so it covers only the coast: lon 1 .. 5.5, lat 50.9 ..
// 52.5 at 1/80 degree (~0.9 x 1.4 km), 5.6 KB.
REGION_LON0 :: 1.0
REGION_LAT_TOP :: 52.5
REGION_DEG_W :: 4.5
REGION_DEG_H :: 1.6
REGION_PX_PER_DEG :: 80
REGION_W :: int(REGION_DEG_W * REGION_PX_PER_DEG)
REGION_H :: int(REGION_DEG_H * REGION_PX_PER_DEG)
#assert(REGION_W * REGION_H % 8 == 0)

World_Header :: struct {
	magic, version:                      u32,
	mask_w, mask_h:                      u32,
	line_count, point_count, city_count: u32,
	region_w, region_h:                  u32,
	region_lon0, region_lat_top:         f32,
	region_deg_w, region_deg_h:          f32,
}

World_Line :: struct {
	start, count, kind: u32, // kind: 0 = coastline, 1 = country border
}

World_City :: struct {
	lon, lat: f32,
	rank:     u8,
	name:     [47]u8,
}

lines: [dynamic]World_Line
points: [dynamic][2]f32
cities: [dynamic]World_City
mask_xor: [WORLD_MASK_W * WORLD_MASK_H]u8
mask_bits: [WORLD_MASK_W * WORLD_MASK_H / 8]u8
region_xor: [REGION_W * REGION_H]u8
region_bits: [REGION_W * REGION_H / 8]u8

// An equirectangular raster: lon0 at the left edge, lat_top at the top, deg_w x deg_h degrees.
Grid :: struct {
	xor:           []u8,
	w, h:          int,
	lon0, lat_top: f32,
	deg_w, deg_h:  f32,
}

json_num :: proc(v: json.Value) -> f32 {
	#partial switch n in v {
	case json.Float:
		return f32(n)
	case json.Integer:
		return f32(n)
	}
	return 0
}

to_lonlat :: proc(v: json.Value) -> [2]f32 {
	a := v.(json.Array)
	return {clamp(json_num(a[0]), -180, 180), clamp(json_num(a[1]), -90, 90)}
}

add_line :: proc(coords: json.Value, kind: u32) {
	a := coords.(json.Array)
	if len(a) < 2 do return
	start := u32(len(points))
	prev := to_lonlat(a[0])
	append(&points, prev)
	for i in 1 ..< len(a) {
		cur := to_lonlat(a[i])
		// Split segments that jump across the antimeridian (+-180 deg) so no line cuts through the globe.
		if abs(cur.x - prev.x) > 180 {
			n := u32(len(points)) - start
			if n >= 2 do append(&lines, World_Line{start, n, kind})
			else do resize(&points, int(start))
			start = u32(len(points))
		}
		append(&points, cur)
		prev = cur
	}
	n := u32(len(points)) - start
	if n >= 2 do append(&lines, World_Line{start, n, kind})
	else do resize(&points, int(start))
}

// Even-odd scanline edges of one ring: every edge toggles the cell where it crosses a row centre, a crossing
// left of the grid toggles column 0, so rings larger than the grid still fill it right.
raster_ring :: proc(coords: json.Value, g: Grid) {
	a := coords.(json.Array)
	if len(a) < 3 do return
	sx, sy := f32(g.w) / g.deg_w, f32(g.h) / g.deg_h
	for i in 0 ..< len(a) {
		p := to_lonlat(a[i])
		q := to_lonlat(a[(i + 1) % len(a)])
		if abs(p.x - q.x) > 180 do continue
		px := (p.x - g.lon0) * sx
		py := (g.lat_top - p.y) * sy
		qx := (q.x - g.lon0) * sx
		qy := (g.lat_top - q.y) * sy
		lo, hi := min(py, qy), max(py, qy)
		for j := max(int(math.ceil(lo - 0.5)), 0); j < g.h && f32(j) + 0.5 < hi; j += 1 {
			yc := f32(j) + 0.5
			x := px + (qx - px) * (yc - py) / (qy - py)
			ix := max(int(math.ceil(x - 0.5)), 0)
			if ix < g.w do g.xor[j * g.w + ix] ~= 1
		}
	}
}

// Runs the xor toggles along each row into set bits; returns the land cells.
fill_bits :: proc(xor: []u8, bits: []u8, w, h: int) -> (cells: int) {
	for j in 0 ..< h {
		run: u8
		row := j * w
		for i in 0 ..< w {
			run ~= xor[row + i]
			if run != 0 {
				bit := row + i
				bits[bit >> 3] |= 1 << u32(bit & 7)
				cells += 1
			}
		}
	}
	return
}

load_geojson :: proc(path: string) -> json.Object {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintfln("cannot read %s (run tools/download_world.sh first): %v", path, err)
		os.exit(1)
	}
	v, jerr := json.parse(data)
	if jerr != nil {
		fmt.eprintfln("%s: json parse failed: %v", path, jerr)
		os.exit(1)
	}
	return v.(json.Object)
}

main :: proc() {
	world := Grid{mask_xor[:], WORLD_MASK_W, WORLD_MASK_H, -180, 90, 360, 180}
	region := Grid {
		region_xor[:],
		REGION_W,
		REGION_H,
		REGION_LON0,
		REGION_LAT_TOP,
		REGION_DEG_W,
		REGION_DEG_H,
	}
	land := load_geojson("assets/geojson/ne_50m_land.geojson")
	for feat in land["features"].(json.Array) {
		geom := feat.(json.Object)["geometry"].(json.Object)
		coords := geom["coordinates"].(json.Array)
		switch geom["type"].(json.String) {
		case "Polygon":
			for ring in coords {
				raster_ring(ring, world)
				raster_ring(ring, region)
				add_line(ring, 0)
			}
		case "MultiPolygon":
			for poly in coords {
				for ring in poly.(json.Array) {
					raster_ring(ring, world)
					raster_ring(ring, region)
					add_line(ring, 0)
				}
			}
		}
	}

	land_cells := fill_bits(mask_xor[:], mask_bits[:], WORLD_MASK_W, WORLD_MASK_H)
	region_cells := fill_bits(region_xor[:], region_bits[:], REGION_W, REGION_H)

	borders := load_geojson("assets/geojson/ne_50m_borders.geojson")
	for feat in borders["features"].(json.Array) {
		geom := feat.(json.Object)["geometry"].(json.Object)
		coords := geom["coordinates"]
		switch geom["type"].(json.String) {
		case "LineString":
			add_line(coords, 1)
		case "MultiLineString":
			for l in coords.(json.Array) do add_line(l, 1)
		}
	}

	cit_doc := load_geojson("assets/geojson/ne_50m_cities.geojson")
	for feat in cit_doc["features"].(json.Array) {
		obj := feat.(json.Object)
		props := obj["properties"].(json.Object)
		rank := int(json_num(props["scalerank"]))
		if rank > 4 do continue
		geom := obj["geometry"].(json.Object)
		if geom["type"].(json.String) != "Point" do continue
		ll := to_lonlat(geom["coordinates"])
		// Belgium has its own hubs in belgium.bin.
		if ll.x >= 2.4 && ll.x <= 6.5 && ll.y >= 49.4 && ll.y <= 51.6 do continue
		name_str, _ := props["nameascii"].(json.String)
		if name_str == "" do name_str, _ = props["name"].(json.String)
		if name_str == "" do continue
		c := World_City {
			lon  = ll.x,
			lat  = ll.y,
			rank = u8(clamp(rank, 0, 255)),
		}
		copy(c.name[:len(c.name) - 1], name_str)
		append(&cities, c)
	}
	slice.sort_by(cities[:], proc(a, b: World_City) -> bool {return a.rank < b.rank})

	header := World_Header {
		magic          = WORLD_MAGIC,
		version        = WORLD_VERSION,
		mask_w         = WORLD_MASK_W,
		mask_h         = WORLD_MASK_H,
		line_count     = u32(len(lines)),
		point_count    = u32(len(points)),
		city_count     = u32(len(cities)),
		region_w       = u32(REGION_W),
		region_h       = u32(REGION_H),
		region_lon0    = REGION_LON0,
		region_lat_top = REGION_LAT_TOP,
		region_deg_w   = REGION_DEG_W,
		region_deg_h   = REGION_DEG_H,
	}

	out := make([dynamic]u8, 0, 2 * 1024 * 1024)
	push :: proc(out: ^[dynamic]u8, s: []u8) {
		n := len(out^)
		resize(out, n + len(s))
		copy(out[n:], s)
	}
	push(&out, mem.ptr_to_bytes(&header))
	push(&out, mask_bits[:])
	push(&out, region_bits[:])
	push(&out, slice.to_bytes(lines[:]))
	push(&out, slice.to_bytes(points[:]))
	push(&out, slice.to_bytes(cities[:]))

	if err := os.write_entire_file("assets/world.bin", out[:]); err != nil {
		fmt.eprintfln("cannot write assets/world.bin: %v", err)
		os.exit(1)
	}
	fmt.printfln(
		"wrote assets/world.bin (%d KB): %d land cells, %d region land cells, %d lines, %d points, %d cities",
		len(out) / 1024,
		land_cells,
		region_cells,
		len(lines),
		len(points),
		len(cities),
	)
}
