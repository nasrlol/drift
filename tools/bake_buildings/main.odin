package bake_buildings

// OSM buildings around the city centres -> assets/buildings.bin.gz, the 3D buildings of the map (Lars,
// 2026-11-21: "ik wil 3d gebouwen"). All 7.6 M buildings of Belgium do not fit (notes.txt, #76), so only the
// ones within RADIUS_KM of each city in assets/geojson/cities.geojson are kept, simplified, and the small
// sheds are dropped. The file stays under the 1 MB check.
//
// Run from the repo root:
//   odin run tools/bake_buildings -- boxes   prints "index min_lon min_lat max_lon max_lat" per city, for
//                                            tools/extract_buildings.sh (ogr2ogr into assets/raw/buildings/)
//   odin run tools/bake_buildings            reads assets/raw/buildings/<index>.geojson, writes the bin
//
// Height: the OSM height tag (m), else building:levels x LEVEL_M + ROOF_M, else DEFAULT_M plus up to 5 m
// from a hash of the footprint, so a street is not one flat wall. Our values, not from the spec.
//
// buildings.bin (little endian), gzipped:
//   header    magic u32 "DRBD", version u32, city_count u32, u32 0
//   city      origin f32 x 2 (map km, the city point), building_count u32, vertex_count u32  (city_count times)
//   then, planar so gzip finds more repeats, for all buildings of all cities (city after city): vertex_count u8
//   per building, height u8 (m) per building, then per vertex dx i16 and dy i16 as four byte planes: the low
//   bytes of dx, the high bytes of dx, the low bytes of dy, the high bytes of dy. The first vertex of a
//   building is relative to its city origin, the next ones to the vertex before, in POS_UNIT_M (0.5 m). The
//   ring is open (the last vertex joins the first) and counter-clockwise on the map (x east, y south).

import "core:compress/deflate"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"

MAGIC :: 0x44425244 // "DRBD"
VERSION :: 1
CITIES_PATH :: "assets/geojson/cities.geojson"
IN_DIR :: "assets/raw/buildings"
OUT_PATH :: "assets/buildings.bin.gz"
MAX_BYTES :: 1_000_000

RADIUS_KM :: 1.0
MIN_AREA_M2 :: 60.0
SIMPLIFY_M :: 1.5
MAX_VERTICES :: 32
POS_UNIT_M :: 0.5
LEVEL_M :: 3.2
ROOF_M :: 1.5
DEFAULT_M :: 7.0
MAX_HEIGHT_M :: 255

// Same projection as tools/bake_map.
LON0 :: 2.38
LAT0 :: 51.56
KM_PER_DEG :: 111.32

project :: proc(lon, lat: f64) -> [2]f64 {
	cos_lat := math.cos(50.5 * math.RAD_PER_DEG)
	return {(lon - LON0) * KM_PER_DEG * cos_lat, (LAT0 - lat) * KM_PER_DEG}
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

read_json :: proc(path: string) -> json.Object {
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
	return root.(json.Object)
}

// Shoelace area in the map's units, positive = counter-clockwise on the map (x east, y south).
ring_area :: proc(r: [][2]f64) -> f64 {
	a: f64
	for p, i in r {
		q := r[(i + 1) % len(r)]
		a += q.x * p.y - p.x * q.y
	}
	return a / 2
}

// Douglas-Peucker on an open ring: keeps the points further than tol from the line between the kept ones.
simplify :: proc(r: [][2]f64, tol: f64, keep: []bool, a, b: int) {
	if b <= a + 1 do return
	best, best_d := -1, tol
	d := r[b] - r[a]
	l := math.sqrt(d.x * d.x + d.y * d.y)
	for i in a + 1 ..< b {
		e := r[i] - r[a]
		dist := l > 0 ? abs(d.x * e.y - d.y * e.x) / l : math.sqrt(e.x * e.x + e.y * e.y)
		if dist > best_d do best, best_d = i, dist
	}
	if best < 0 do return
	keep[best] = true
	simplify(r, tol, keep, a, best)
	simplify(r, tol, keep, best, b)
}

dist2 :: proc(a, b: [2]f64) -> f64 {
	d := a - b
	return d.x * d.x + d.y * d.y
}

parse_m :: proc(v: json.Value) -> (f64, bool) {
	s, ok := v.(json.String)
	if !ok do return 0, false
	s = strings.trim_space(strings.trim_suffix(strings.trim_space(s), "m"))
	f, fok := strconv.parse_f64(strings.trim_space(s))
	return f, fok && f > 0 && f < 1000
}

main :: proc() {
	cities := read_json(CITIES_PATH)["features"].(json.Array)
	centres := make([][2]f64, len(cities))
	lonlat := make([][2]f64, len(cities))
	for c, i in cities {
		pt := c.(json.Object)["geometry"].(json.Object)["coordinates"].(json.Array)
		lonlat[i] = {num(pt[0]), num(pt[1])}
		centres[i] = project(lonlat[i].x, lonlat[i].y)
	}

	if len(os.args) > 1 && os.args[1] == "boxes" {
		// A little more than RADIUS_KM, ogr2ogr keeps what touches the box.
		cos_lat := math.cos(50.5 * math.RAD_PER_DEG)
		dlon := RADIUS_KM / (KM_PER_DEG * cos_lat)
		dlat := RADIUS_KM / KM_PER_DEG
		for ll, i in lonlat {
			fmt.printfln("%d %.5f %.5f %.5f %.5f", i, ll.x - dlon, ll.y - dlat, ll.x + dlon, ll.y + dlat)
		}
		return
	}

	heads: [dynamic]u8
	verts: [dynamic]i16
	city_info: [dynamic][4]u32
	total, dropped_small, dropped_far: int
	for centre, ci in centres {
		path := fmt.tprintf("%s/%d.geojson", IN_DIR, ci)
		features := read_json(path)["features"].(json.Array)
		count, vcount: u32
		for f in features {
			obj := f.(json.Object)
			geom, gok := obj["geometry"].(json.Object)
			if !gok do continue
			coords, cok := geom["coordinates"].(json.Array)
			if !cok || len(coords) == 0 do continue
			// Outer ring only (courtyards are filled, they are not seen from the air anyway).
			poly := coords
			if geom["type"].(json.String) == "MultiPolygon" do poly = coords[0].(json.Array)
			outer := poly[0].(json.Array)
			ring := make([dynamic][2]f64, context.temp_allocator)
			for p in outer {
				a := p.(json.Array)
				km := project(num(a[0]), num(a[1]))
				append(&ring, (km - centre) * 1000) // m from the city point
			}
			if len(ring) > 1 && ring[0] == ring[len(ring) - 1] do pop(&ring)
			if len(ring) < 3 do continue

			mid: [2]f64
			for p in ring do mid += p
			mid /= f64(len(ring))
			if math.sqrt(mid.x * mid.x + mid.y * mid.y) > RADIUS_KM * 1000 {
				dropped_far += 1
				continue
			}
			area := ring_area(ring[:])
			if abs(area) < MIN_AREA_M2 {
				dropped_small += 1
				continue
			}
			if area < 0 {
				for i in 0 ..< len(ring) / 2 do ring[i], ring[len(ring) - 1 - i] = ring[len(ring) - 1 - i], ring[i]
			}
			// Simplify between the first point and the one furthest from it, both kept.
			far := 0
			for p, i in ring do if dist2(p, ring[0]) > dist2(ring[far], ring[0]) do far = i
			closed := make([dynamic][2]f64, context.temp_allocator)
			append(&closed, ..ring[:])
			append(&closed, ring[0])
			keep := make([]bool, len(closed), context.temp_allocator)
			keep[0], keep[far], keep[len(closed) - 1] = true, true, true
			simplify(closed[:], SIMPLIFY_M, keep, 0, far)
			simplify(closed[:], SIMPLIFY_M, keep, far, len(closed) - 1)
			kept := make([dynamic][2]f64, context.temp_allocator)
			for p, i in closed[:len(closed) - 1] do if keep[i] do append(&kept, p)
			if len(kept) < 3 || len(kept) > MAX_VERTICES {
				dropped_small += 1
				continue
			}

			props, _ := obj["properties"].(json.Object)
			height: f64
			if h, ok := parse_m(props["height"]); ok {
				height = h
			} else if l, lok := parse_m(props["levels"]); lok {
				height = l * LEVEL_M + ROOF_M
			} else {
				hash := u32(abs(area) * 7919) ~ u32(abs(mid.x) * 31 + abs(mid.y) * 17)
				height = DEFAULT_M + f64(hash % 6)
			}

			append(&heads, u8(len(kept)), u8(clamp(math.round(height), 3, MAX_HEIGHT_M)))
			prev: [2]i32
			for p, i in kept {
				q := [2]i32{i32(math.round(p.x / POS_UNIT_M)), i32(math.round(p.y / POS_UNIT_M))}
				d := i == 0 ? q : q - prev
				prev = q
				append(&verts, i16(d.x), i16(d.y))
			}
			count += 1
			vcount += u32(len(kept))
		}
		append(&city_info, [4]u32{transmute(u32)f32(centre.x), transmute(u32)f32(centre.y), count, vcount})
		total += int(count)
		fmt.printfln("city %d: %d buildings, %d vertices", ci, count, vcount)
		free_all(context.temp_allocator)
	}

	out: [dynamic]u8
	put :: proc(out: ^[dynamic]u8, v: u32) {
		b := transmute([4]u8)v
		append(out, ..b[:])
	}
	put(&out, MAGIC)
	put(&out, VERSION)
	put(&out, u32(len(city_info)))
	put(&out, 0)
	for c in city_info do for v in c do put(&out, v)
	// Planar, city after city: all vertex counts, all heights, then the vertices (below).
	for i := 0; i < len(heads); i += 2 do append(&out, heads[i])
	for i := 1; i < len(heads); i += 2 do append(&out, heads[i])
	for half in 0 ..< 2 {
		for byte_i in 0 ..< 2 {
			for i := half; i < len(verts); i += 2 do append(&out, (transmute([2]u8)verts[i])[byte_i])
		}
	}

	zipped: [dynamic]u8
	if zerr := deflate.deflate_gzip(&zipped, out[:], .Best); zerr != nil {
		fmt.eprintln("gzip:", zerr)
		os.exit(1)
	}
	fmt.printfln(
		"%d buildings (%d too small or too complex, %d too far), %d bytes, %d gzipped",
		total,
		dropped_small,
		dropped_far,
		len(out),
		len(zipped),
	)
	if len(zipped) > MAX_BYTES {
		fmt.eprintfln(
			"%s would be %d bytes, more than the %d of the check",
			OUT_PATH,
			len(zipped),
			MAX_BYTES,
		)
		os.exit(1)
	}
	if werr := os.write_entire_file(OUT_PATH, zipped[:]); werr != nil {
		fmt.eprintln("can't write", OUT_PATH, werr)
		os.exit(1)
	}
}
