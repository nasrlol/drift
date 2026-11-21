package bake_car

// assets/raw/car/CarConcept.glb (tools/download_car.sh) -> assets/car.bin.gz, the flying car of the game.
// Run from the repo root: odin run tools/bake_car
//
// Keeps the outside of the car: the interior, the wipers, the brake pads, the license plate and the
// textures (Khronos logos) are left out, so the file stays under the 1 MB check. Colors come from the
// material base colors (linear -> sRGB), the shading class from the material: paint (clearcoat), glass
// (transmission), metal, emissive lights, matte.
//
// Model space of the game (airship.odin): metres, x forward, y up, z to the right, origin on the ground under
// the middle of the car. glTF is y up with the car facing +z, so x_game = z, y_game = y, z_game = -x.
//
// car.bin (little endian), gzipped:
//   header   magic u32 "DRCR", version u32, material_count u32, part_count u32, pos_scale f32, 3 x u32 0
//   material rgb u8 x 3, class u8                                        (material_count times)
//   part     kind u32 (0 body, 1..4 wheel FL FR RL RR), vertex_count u32, index_count u32, u32 0,
//            pivot f32 x 3 (game space, m), f32 0                         (part_count times)
//   then per part: vertices (pos i16 x 3 relative to the pivot, times pos_scale; normal octahedral i8 x 2;
//   material u8; u8 0 -> 10 bytes), then u16 indices (triangles), padded to 4 bytes.
// A part has at most 65535 vertices (raylib meshes index with u16); the body is split into several parts.

import "core:compress/deflate"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:os"
import "core:strings"

CAR_MAGIC :: 0x52435244 // "DRCR"
CAR_VERSION :: 1
IN_PATH :: "assets/raw/car/CarConcept.glb"
OUT_PATH :: "assets/car.bin.gz"
MAX_PART_VERTS :: 65535
MAX_BYTES :: 1_000_000

Class :: enum u8 {
	Matte,
	Paint,
	Glass,
	Metal,
	Emissive,
}

Material :: struct {
	rgb:   [3]u8,
	class: Class,
}

Vertex :: struct #packed {
	pos:      [3]i16,
	normal:   [2]i8,
	material: u8,
	_:        u8,
}
#assert(size_of(Vertex) == 10)

Part :: struct {
	kind:  u32,
	pivot: [3]f32,
	pos:   [dynamic][3]f32, // game space, relative to the pivot
	nrm:   [dynamic][3]f32,
	mat:   [dynamic]u8,
	idx:   [dynamic]u16,
}

// Node names (and every name under them) that are left out.
SKIP_NODES :: [?]string {
	"Interior",
	"Engine",
	"License",
	"BodyWindshieldWipers",
	"BodyHoodInterior",
	"BodyHoodUnder",
	"Axles",
}
// Materials left out: hidden behind the rims, or too fine to see at the drawn size.
SKIP_MATERIALS :: [?]string{"Brake", "Rim1", "Dashboard"} // exact names
WHEEL_NODES :: [4]string{"WheelFrontL", "WheelFrontR", "WheelRearL", "WheelRearR"}

Glb :: struct {
	doc:       json.Object,
	bin:       []u8,
	materials: [dynamic]Material,
	mat_index: map[string]u8, // "r g b class" -> index
	parts:     [dynamic]Part,
	skipped:   int,
}

obj :: proc(v: json.Value) -> json.Object {
	o, _ := v.(json.Object)
	return o
}
arr :: proc(v: json.Value) -> json.Array {
	a, _ := v.(json.Array)
	return a
}
num :: proc(v: json.Value) -> f64 {
	#partial switch x in v {
	case json.Float:
		return f64(x)
	case json.Integer:
		return f64(x)
	}
	return 0
}
str :: proc(v: json.Value) -> string {
	s, _ := v.(json.String)
	return s
}

to_srgb :: proc(c: f64) -> u8 {
	l := clamp(c, 0, 1)
	s := l <= 0.0031308 ? l * 12.92 : 1.055 * math.pow(l, 1 / 2.4) - 0.055
	return u8(math.round(s * 255))
}

// The material of a primitive as a game material; ok = false for a skipped one.
material_of :: proc(g: ^Glb, index: int) -> (m: u8, ok: bool) {
	mats := arr(g.doc["materials"])
	mo := obj(mats[index])
	name := str(mo["name"])
	for s in SKIP_MATERIALS do if name == s do return 0, false
	pbr := obj(mo["pbrMetallicRoughness"])
	ext := obj(mo["extensions"])
	rgb := [3]u8{200, 200, 200}
	if f := arr(pbr["baseColorFactor"]); len(f) >= 3 {
		rgb = {to_srgb(num(f[0])), to_srgb(num(f[1])), to_srgb(num(f[2]))}
	}
	class := Class.Matte
	metallic := "metallicFactor" in pbr ? num(pbr["metallicFactor"]) : 1
	switch {
	case "KHR_materials_transmission" in ext:
		class, rgb = .Glass, {14, 18, 24}
	case "KHR_materials_emissive_strength" in ext:
		class = .Emissive
		e := arr(mo["emissiveFactor"])
		if len(e) >= 3 do rgb = {to_srgb(num(e[0])), to_srgb(num(e[1])), to_srgb(num(e[2]))}
		if strings.contains(name, "Brake") || strings.contains(name, "Tail") do rgb = {255, 40, 30}
	case "KHR_materials_clearcoat" in ext:
		class = .Paint
	case strings.contains(name, "Mirror"):
		class, rgb = .Metal, {205, 210, 215}
	case strings.contains(name, "Rim2"):
		class, rgb = .Metal, {175, 180, 188}
	case strings.contains(name, "Disc"):
		class, rgb = .Metal, {110, 110, 115}
	case strings.contains(name, "Tire"):
		class, rgb = .Matte, {26, 26, 28}
	case metallic > 0.5:
		class = .Metal
	}
	key := fmt.aprintf("%d %d %d %d", rgb.r, rgb.g, rgb.b, class)
	if i, found := g.mat_index[key]; found do return i, true
	append(&g.materials, Material{rgb, class})
	i := u8(len(g.materials) - 1)
	g.mat_index[key] = i
	return i, true
}

node_matrix :: proc(n: json.Object) -> matrix[4, 4]f32 {
	if m := arr(n["matrix"]); len(m) == 16 {
		flat: [16]f32
		for v, i in m do flat[i] = f32(num(v))
		return transmute(matrix[4, 4]f32)flat // glTF and Odin are both column-major
	}
	t := [3]f32{}
	if v := arr(n["translation"]); len(v) == 3 do t = {f32(num(v[0])), f32(num(v[1])), f32(num(v[2]))}
	q := quaternion128(1)
	if v := arr(n["rotation"]); len(v) == 4 {
		q = quaternion(w = f32(num(v[3])), x = f32(num(v[0])), y = f32(num(v[1])), z = f32(num(v[2])))
	}
	s := [3]f32{1, 1, 1}
	if v := arr(n["scale"]); len(v) == 3 do s = {f32(num(v[0])), f32(num(v[1])), f32(num(v[2]))}
	return(
		linalg.matrix4_translate_f32(t) *
		linalg.matrix4_from_quaternion_f32(q) *
		linalg.matrix4_scale_f32(s) \
	)
}

// glTF (y up, facing +z) to game space (x forward, y up, z right).
to_game :: proc(p: [3]f32) -> [3]f32 {
	return {p.z, p.y, -p.x}
}

// Element i of a float vec3 accessor.
read_vec3 :: proc(g: ^Glb, accessor: int, i: int) -> [3]f32 {
	a := obj(arr(g.doc["accessors"])[accessor])
	bv := obj(arr(g.doc["bufferViews"])[int(num(a["bufferView"]))])
	stride := "byteStride" in bv ? int(num(bv["byteStride"])) : 12
	off := int(num(bv["byteOffset"])) + int(num(a["byteOffset"])) + i * stride
	v: [3]f32
	mem.copy(&v, &g.bin[off], 12)
	return v
}

read_index :: proc(g: ^Glb, accessor: int, i: int) -> int {
	a := obj(arr(g.doc["accessors"])[accessor])
	bv := obj(arr(g.doc["bufferViews"])[int(num(a["bufferView"]))])
	off := int(num(bv["byteOffset"])) + int(num(a["byteOffset"]))
	switch int(num(a["componentType"])) {
	case 5121:
		return int(g.bin[off + i])
	case 5123:
		v: u16
		mem.copy(&v, &g.bin[off + i * 2], 2)
		return int(v)
	case 5125:
		v: u32
		mem.copy(&v, &g.bin[off + i * 4], 4)
		return int(v)
	}
	fmt.eprintln("unknown index type")
	os.exit(1)
}

// The part with this kind that still has room for count more vertices.
part_for :: proc(g: ^Glb, kind: u32, pivot: [3]f32, count: int) -> ^Part {
	for &p in g.parts {
		if p.kind == kind && len(p.pos) + count <= MAX_PART_VERTS do return &p
	}
	append(&g.parts, Part{kind = kind, pivot = pivot})
	return &g.parts[len(g.parts) - 1]
}

walk :: proc(g: ^Glb, node: int, parent: matrix[4, 4]f32, wheel: u32, wheel_pivot: [3]f32) {
	n := obj(arr(g.doc["nodes"])[node])
	name := str(n["name"])
	for s in SKIP_NODES {
		if strings.has_prefix(name, s) {
			g.skipped += 1
			return
		}
	}
	m := parent * node_matrix(n)
	wheel, wheel_pivot := wheel, wheel_pivot
	for w, i in WHEEL_NODES {
		if name == w {
			wheel = u32(i + 1)
			o := m * [4]f32{0, 0, 0, 1}
			wheel_pivot = to_game(o.xyz)
		}
	}
	if "mesh" in n {
		normal_m := matrix[3, 3]f32{
			m[0, 0], m[0, 1], m[0, 2],
			m[1, 0], m[1, 1], m[1, 2],
			m[2, 0], m[2, 1], m[2, 2],
		}
		mesh := obj(arr(g.doc["meshes"])[int(num(n["mesh"]))])
		for pv in arr(mesh["primitives"]) {
			prim := obj(pv)
			if "mode" in prim && int(num(prim["mode"])) != 4 do continue
			mat, ok := material_of(g, int(num(prim["material"])))
			if !ok do continue
			attrs := obj(prim["attributes"])
			pos_acc := int(num(attrs["POSITION"]))
			nrm_acc := int(num(attrs["NORMAL"]))
			count := int(num(obj(arr(g.doc["accessors"])[pos_acc])["count"]))
			idx_acc := int(num(prim["indices"]))
			icount := int(num(obj(arr(g.doc["accessors"])[idx_acc])["count"]))
			if count > MAX_PART_VERTS {
				fmt.eprintln(name, "has more than", MAX_PART_VERTS, "vertices in one primitive")
				os.exit(1)
			}
			pivot := wheel > 0 ? wheel_pivot : [3]f32{}
			part := part_for(g, wheel, pivot, count)
			base := len(part.pos)
			for i in 0 ..< count {
				p := read_vec3(g, pos_acc, i)
				w := m * [4]f32{p.x, p.y, p.z, 1}
				append(&part.pos, to_game(w.xyz) - pivot)
				nn := linalg.normalize0(normal_m * read_vec3(g, nrm_acc, i))
				append(&part.nrm, to_game(nn))
				append(&part.mat, mat)
			}
			for i in 0 ..< icount do append(&part.idx, u16(base + read_index(g, idx_acc, i)))
		}
	}
	for c in arr(n["children"]) do walk(g, int(num(c)), m, wheel, wheel_pivot)
}

// Octahedral normal encoding, 2 x i8.
oct :: proc(normal: [3]f32) -> [2]i8 {
	n := normal / (abs(normal.x) + abs(normal.y) + abs(normal.z))
	p := n.xy
	if n.z < 0 {
		p = {(1 - abs(n.y)) * math.sign(n.x), (1 - abs(n.x)) * math.sign(n.y)}
	}
	return {i8(math.round(clamp(p.x, -1, 1) * 127)), i8(math.round(clamp(p.y, -1, 1) * 127))}
}

main :: proc() {
	data, err := os.read_entire_file(IN_PATH, context.allocator)
	if err != nil {
		fmt.eprintln("can't read", IN_PATH, err, "- run tools/download_car.sh")
		os.exit(1)
	}
	g: Glb
	{
		magic, json_len: u32
		mem.copy(&magic, &data[0], 4)
		mem.copy(&json_len, &data[12], 4)
		if magic != 0x46546c67 {
			fmt.eprintln(IN_PATH, "is not a glb")
			os.exit(1)
		}
		doc, jerr := json.parse(data[20:20 + json_len])
		if jerr != nil {
			fmt.eprintln("json:", jerr)
			os.exit(1)
		}
		g.doc = obj(doc)
		bin_at := 20 + int(json_len)
		bin_len: u32
		mem.copy(&bin_len, &data[bin_at], 4)
		g.bin = data[bin_at + 8:][:bin_len]
	}
	scene := obj(arr(g.doc["scenes"])[int(num(g.doc["scene"]))])
	for r in arr(scene["nodes"]) do walk(&g, int(num(r)), 1, 0, {})

	// Ground and centre: the lowest point of the wheels on y = 0, the middle of the length and width at 0.
	lo, hi := [3]f32{1e9, 1e9, 1e9}, [3]f32{-1e9, -1e9, -1e9}
	for &p in g.parts {
		for v in p.pos {
			w := v + p.pivot
			lo = linalg.min(lo, w)
			hi = linalg.max(hi, w)
		}
	}
	shift := [3]f32{-(lo.x + hi.x) / 2, -lo.y, -(lo.z + hi.z) / 2}
	extent: f32
	tris := 0
	verts := 0
	for &p in g.parts {
		if p.kind == 0 {
			for &v in p.pos do v += shift
		} else {
			p.pivot += shift
		}
		for v in p.pos do extent = max(extent, abs(v.x), abs(v.y), abs(v.z))
		tris += len(p.idx) / 3
		verts += len(p.pos)
	}
	scale := extent / 32767

	out: [dynamic]u8
	put :: proc(out: ^[dynamic]u8, v: $T) {
		v := v
		append(out, ..mem.ptr_to_bytes(&v))
	}
	put(&out, u32(CAR_MAGIC))
	put(&out, u32(CAR_VERSION))
	put(&out, u32(len(g.materials)))
	put(&out, u32(len(g.parts)))
	put(&out, scale)
	put(&out, [3]u32{})
	for m in g.materials do put(&out, m)
	for p in g.parts {
		put(&out, p.kind)
		put(&out, u32(len(p.pos)))
		put(&out, u32(len(p.idx)))
		put(&out, u32(0))
		put(&out, p.pivot)
		put(&out, f32(0))
	}
	for p in g.parts {
		for v, i in p.pos {
			q := linalg.round(v / scale)
			put(
				&out,
				Vertex{pos = {i16(q.x), i16(q.y), i16(q.z)}, normal = oct(p.nrm[i]), material = p.mat[i]},
			)
		}
		append(&out, ..mem.slice_to_bytes(p.idx[:]))
		for len(out) % 4 != 0 do append(&out, 0)
	}
	zipped: [dynamic]u8
	if zerr := deflate.deflate_gzip(&zipped, out[:], .Best); zerr != nil {
		fmt.eprintln("gzip:", zerr)
		os.exit(1)
	}
	if len(zipped) > MAX_BYTES {
		fmt.eprintln(OUT_PATH, "would be", len(zipped), "bytes, over the 1 MB check: skip more parts")
		os.exit(1)
	}
	if werr := os.write_entire_file(OUT_PATH, zipped[:]); werr != nil {
		fmt.eprintln("can't write", OUT_PATH, werr)
		os.exit(1)
	}
	size := hi - lo
	fmt.printfln(
		"%s: %d parts, %d materials, %d vertices, %d triangles, %.2f x %.2f x %.2f m, %d nodes skipped, %d bytes (%d raw)",
		OUT_PATH,
		len(g.parts),
		len(g.materials),
		verts,
		tris,
		size.x,
		size.y,
		size.z,
		g.skipped,
		len(zipped),
		len(out),
	)
}
