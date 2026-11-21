package game

import "core:math"
import "core:math/linalg"
import "core:time"
import rl "vendor:raylib"

// Houses of the street view (Lars, 2026-11-21: "zoveel mogelijk detail in alles: gebouwen, ..."): the real OSM
// buildings and the generated town buildings, with walls that carry a facade (floors, windows with frames and
// sills, doors, shop fronts, brick / plaster / stone, a bluestone plinth: drawn by STREET_FS from the wall's own uv
// in metres, no extra geometry), pitched roofs (gable or hip, with eaves, a fascia and chimneys) on narrow houses
// and flat roofs with a parapet, coping and roof boxes on the rest, green roofs and solar panels. Built per
// HOUSE_TILE_KM tile around the camera (tiles.odin), in km relative to the tile corner like the other tiles.
// Styles are ours (Belgian row houses), from a hash of the building; footprint and height come from OSM.
HOUSE_TILE_KM :: 0.5
HOUSE_REACH_KM :: 3.4
HOUSE_OVERHANG_M :: 0.35
HOUSE_PARAPET_INSET_M :: 0.25
HOUSE_FASCIA_M :: 0.18

// Materials of the street view's lit shader: vertexColor.a holds the material in the low 5 bits and flags above
// it. STREET_FS uses the numbers, keep them in step (the #asserts).
Street_Mat :: enum u8 {
	Ground,
	Brick,
	Plaster,
	Stone,
	Curtain, // glass and metal office fronts
	Tile_Roof,
	Slate_Roof,
	Flat_Roof,
	Green_Roof,
	Solar,
	Coping,
	Metal,
	Bark,
	Leaves,
	Wood,
}
#assert(int(Street_Mat.Brick) == 1 && int(Street_Mat.Curtain) == 4 && int(Street_Mat.Solar) == 9)
#assert(int(Street_Mat.Wood) == 14 && len(Street_Mat) <= 32)
MAT_SHOP :: 0x20 // the ground floor of this wall is a shop front
MAT_DOOR :: 0x40 // this wall has the front door

// Vertex arrays of a tile under construction (frame arena). Positions in km relative to the tile corner (x east,
// y south, z down), normals in the same frame, uv in metres on the surface, lh = (wall length, eave height) m.
House_Mesh :: struct {
	pos, nrm: [dynamic][3]f32,
	uv, lh:   [dynamic][2]f32,
	col:      [dynamic][4]u8,
}

// A point at height h (m) over p (km, relative to the tile corner).
at :: proc(p: [2]f32, h: f32) -> [3]f32 {
	return {p.x, p.y, -h / 1000}
}

// One triangle facing n (map frame): turned so its corners go counter-clockwise seen from that side, which is
// what the culling keeps after the street view's (proper) rotation.
hm_tri :: proc(m: ^House_Mesh, p: [3][3]f32, uv: [3][2]f32, n: [3]f32, lh: [2]f32, c: [4]u8) {
	order := [3]int{0, 1, 2}
	if linalg.dot(linalg.cross((p[1] - p[0]) * 1000, (p[2] - p[0]) * 1000), n) < 0 do order = {0, 2, 1}
	for k in order {
		append(&m.pos, p[k])
		append(&m.nrm, n)
		append(&m.uv, uv[k])
		append(&m.lh, lh)
		append(&m.col, c)
	}
}

hm_quad :: proc(m: ^House_Mesh, p: [4][3]f32, uv: [4][2]f32, n: [3]f32, lh: [2]f32, c: [4]u8) {
	hm_tri(m, {p[0], p[1], p[2]}, {uv[0], uv[1], uv[2]}, n, lh, c)
	hm_tri(m, {p[0], p[2], p[3]}, {uv[0], uv[2], uv[3]}, n, lh, c)
}

// A wall from a to b (km, ring order: the outside is on the right of a -> b on the map), from h0 to h1 m, uv from
// u0 m along the wall. top_mid > h1 raises a gable triangle to that height over the middle.
hm_wall :: proc(m: ^House_Mesh, a, b: [2]f32, h0, h1, top_mid, eave: f32, c: [4]u8) {
	d := (b - a) * 1000
	l := linalg.length(d)
	if l < 0.05 do return
	n := [3]f32{-d.y / l, d.x / l, 0}
	lh := [2]f32{l, eave}
	hm_quad(m, {at(a, h0), at(b, h0), at(b, h1), at(a, h1)}, {{0, h0}, {l, h0}, {l, h1}, {0, h1}}, n, lh, c)
	if top_mid > h1 + 0.05 {
		mid := (a + b) / 2
		hm_tri(m, {at(a, h1), at(b, h1), at(mid, top_mid)}, {{0, h1}, {l, h1}, {l / 2, top_mid}}, n, lh, c)
	}
}

// A box (chimney, roof unit) around centre (km) with half sizes (m) along dir and across it, from h0 to h1.
hm_box :: proc(m: ^House_Mesh, centre, dir: [2]f32, half: [2]f32, h0, h1: f32, side, top: [4]u8) {
	across := [2]f32{-dir.y, dir.x}
	ca := dir * half.x / 1000
	cb := across * half.y / 1000
	// Counter-clockwise on the map like the building rings.
	q := [4][2]f32{centre - ca - cb, centre - ca + cb, centre + ca + cb, centre + ca - cb}
	if turn(q[0], q[1], q[2]) < 0 do q = {q[0], q[3], q[2], q[1]}
	for k in 0 ..< 4 do hm_wall(m, q[k], q[(k + 1) % 4], h0, h1, 0, h1 + 10, side)
	hm_quad(m, {at(q[0], h1), at(q[1], h1), at(q[2], h1), at(q[3], h1)}, {}, {0, 0, -1}, {}, top)
}

// One of the first n entries, by the seed.
pick :: proc(seed: ^u32, n: int) -> int {
	return min(int(nature_rand(seed) * f32(n)), n - 1)
}

// The colour c with a small random shift, and the material code (Street_Mat | flags) in alpha.
house_color :: proc(seed: ^u32, c: [3]u8, mat: Street_Mat, flags: u8 = 0) -> [4]u8 {
	k := 0.92 + 0.16 * nature_rand(seed)
	return {
		u8(clamp(f32(c.r) * k, 0, 255)),
		u8(clamp(f32(c.g) * k, 0, 255)),
		u8(clamp(f32(c.b) * k, 0, 255)),
		u8(mat) | flags,
	}
}

HOUSE_BRICKS :: [?][3]u8 {
	{150, 74, 54},
	{132, 62, 46},
	{164, 92, 64},
	{118, 66, 52},
	{98, 54, 44},
	{190, 156, 108}, // yellow Kempen brick
	{226, 222, 212}, // white-washed brick
}
HOUSE_PLASTERS :: [?][3]u8 {
	{236, 232, 222},
	{232, 220, 190},
	{214, 212, 204},
	{226, 200, 172},
	{204, 214, 192},
	{196, 206, 214},
	{230, 214, 206},
}
HOUSE_STONES :: [?][3]u8{{208, 198, 178}, {184, 180, 170}, {196, 186, 160}}
HOUSE_CURTAINS :: [?][3]u8{{70, 84, 96}, {88, 100, 104}, {60, 70, 84}}
HOUSE_TILES :: [?][3]u8{{148, 64, 44}, {170, 92, 58}, {112, 56, 40}, {92, 52, 40}}
HOUSE_SLATES :: [?][3]u8{{64, 68, 76}, {80, 84, 94}, {56, 58, 64}}

// One building into m. ring: km relative to the tile corner, counter-clockwise on the map (the outside on the
// right of each edge), at most 32 corners. height: m, the very top (OSM height is to the ridge). real: an OSM
// building (city centre), else a generated town building.
house_add :: proc(m: ^House_Mesh, ring: [][2]f32, height: f32, seed: u32, real: bool, idx: []int) {
	n := len(ring)
	if n < 3 || height < 2 do return
	r := seed

	// Shape: a near-rectangle of 4 corners that is narrow enough gets a pitched roof.
	side := [4]f32{}
	rect := n == 4
	if n == 4 {
		for k in 0 ..< 4 {
			a, b, c := ring[k], ring[(k + 1) % 4], ring[(k + 2) % 4]
			side[k] = linalg.length(b - a) * 1000
			u, v := linalg.normalize(b - a), linalg.normalize(c - b)
			if abs(linalg.dot(u, v)) > 0.34 do rect = false
		}
	}
	len_a := (side[0] + side[2]) / 2 // along ring[0] -> ring[1]
	len_b := (side[1] + side[3]) / 2
	short, long := min(len_a, len_b), max(len_a, len_b)
	pitched := rect && short >= 3 && short <= 13 && height >= 5 && height <= 24 && nature_rand(&r) < 0.92

	// Looks.
	wall: Street_Mat
	wall_c: [3]u8
	t := nature_rand(&r)
	switch {
	case real && height > 28 && nature_rand(&r) < 0.65:
		c := HOUSE_CURTAINS
		wall, wall_c = .Curtain, c[pick(&r, len(c))]
	case t < 0.5:
		c := HOUSE_BRICKS
		wall, wall_c = .Brick, c[pick(&r, len(c))]
	case t < 0.86:
		c := HOUSE_PLASTERS
		wall, wall_c = .Plaster, c[pick(&r, len(c))]
	case:
		c := HOUSE_STONES
		wall, wall_c = .Stone, c[pick(&r, len(c))]
	}
	shop := real && height >= 8 && nature_rand(&r) < 0.5
	flags: u8 = shop ? MAT_SHOP : 0
	wc := house_color(&r, wall_c, wall, flags)
	door_wall := int(nature_rand(&r) * f32(n)) % n

	if !pitched {
		// Flat roof: the walls rise into a parapet, coping on top, the roof inside an inset ring.
		parapet := height < 4 ? 0 : 0.45 + 0.6 * nature_rand(&r)
		for k in 0 ..< n {
			c := wc
			if k == door_wall do c.a |= MAT_DOOR
			hm_wall(m, ring[k], ring[(k + 1) % n], 0, height + parapet, 0, height, c)
		}
		inset := make([][2]f32, n, context.temp_allocator)
		for k in 0 ..< n {
			p0, p1, p2 := ring[(k + n - 1) % n], ring[k], ring[(k + 1) % n]
			n0 := linalg.normalize([2]f32{(p1 - p0).y, -(p1 - p0).x}) // inward
			n1 := linalg.normalize([2]f32{(p2 - p1).y, -(p2 - p1).x})
			bis := linalg.normalize(n0 + n1)
			inset[k] = p1 + bis * (HOUSE_PARAPET_INSET_M / 1000) / max(linalg.dot(bis, n0), 0.35)
		}
		coping := house_color(&r, {196, 194, 188}, .Coping)
		if parapet > 0 {
			for k in 0 ..< n {
				// The parapet's inner face (the outside of the inset ring seen from the roof) and its coping.
				a, b := inset[(k + 1) % n], inset[k]
				hm_wall(m, a, b, height, height + parapet, 0, height + parapet, wc)
				o0, o1 := ring[k], ring[(k + 1) % n]
				hm_quad(
					m,
					{
						at(o0, height + parapet),
						at(o1, height + parapet),
						at(inset[(k + 1) % n], height + parapet),
						at(inset[k], height + parapet),
					},
					{},
					{0, 0, -1},
					{},
					coping,
				)
			}
		}
		roof_mat := Street_Mat.Flat_Roof
		roof_c := [3]u8{98, 96, 92}
		rt := nature_rand(&r)
		if rt < 0.45 {
			roof_mat, roof_c = .Green_Roof, {92, 118, 62}
		}
		rc := house_color(&r, roof_c, roof_mat)
		tris := make([dynamic][2]f32, 0, 3 * n, context.temp_allocator)
		roof_triangles(inset, idx[:n], &tris)
		for k := 0; k + 2 < len(tris); k += 3 {
			p := [3][2]f32{tris[k], tris[k + 1], tris[k + 2]}
			hm_tri(
				m,
				{at(p[0], height), at(p[1], height), at(p[2], height)},
				{p[0] * 1000, p[1] * 1000, p[2] * 1000},
				{0, 0, -1},
				{},
				rc,
			)
		}
		// Roof units and solar rows on larger roofs: inside the inset ring.
		lo, hi := inset[0], inset[0]
		for p in inset {
			lo = linalg.min(lo, p)
			hi = linalg.max(hi, p)
		}
		size := (hi - lo) * 1000
		if size.x > 8 && size.y > 8 {
			units := 1 + int(nature_rand(&r) * 2.5)
			metal := house_color(&r, {150, 152, 150}, .Metal)
			for _ in 0 ..< units {
				c := lo + (hi - lo) * [2]f32{0.2 + 0.6 * nature_rand(&r), 0.2 + 0.6 * nature_rand(&r)}
				if !in_ring(inset, c) do continue
				half := [2]f32{0.6 + 0.8 * nature_rand(&r), 0.5 + 0.6 * nature_rand(&r)}
				hm_box(m, c, {1, 0}, half, height, height + 0.8 + 0.8 * nature_rand(&r), metal, metal)
			}
			if rt >= 0.45 && rt < 0.8 {
				// Rows of panels facing south (+y on the map), 1.7 m deep, tilted 20 deg, 1.5 m apart.
				solar := house_color(&r, {28, 36, 64}, .Solar)
				tilt :: 0.35
				for y := lo.y + 0.0015; y + 0.0017 < hi.y - 0.001; y += 0.0032 {
					x0, x1 := lo.x + 0.0012, hi.x - 0.0012
					if x1 - x0 < 0.002 do continue
					a0, a1 := [2]f32{x0, y}, [2]f32{x1, y}
					b0, b1 :=
						[2]f32{x0, y + 0.0017 * math.cos(f32(tilt))},
						[2]f32{x1, y + 0.0017 * math.cos(f32(tilt))}
					if !in_ring(inset, a0) || !in_ring(inset, a1) || !in_ring(inset, b0) || !in_ring(inset, b1) do continue
					top := height + 0.3 + 1.7 * math.sin(f32(tilt))
					w := (x1 - x0) * 1000
					nrm := [3]f32{0, math.sin(f32(tilt)), -math.cos(f32(tilt))}
					// Low edge on the south side (b), so the panel faces south and up.
					pts := [4][3]f32{at(b0, height + 0.3), at(b1, height + 0.3), at(a1, top), at(a0, top)}
					hm_quad(m, pts, {{0, 0}, {w, 0}, {w, 1.7}, {0, 1.7}}, nrm, {}, solar)
					hm_quad(m, pts, {}, -nrm, {}, metal)
				}
			}
		}
		return
	}

	// Pitched roof. The ridge runs along the long side, or for a narrow row house across it (parallel to the
	// street front: the slopes face the street and the garden, the gables are the party walls).
	q := [4][2]f32{ring[0], ring[1], ring[2], ring[3]}
	row := short <= 8.5 && long / short >= 1.3
	ridge_along_a := (len_a >= len_b) != row
	if !ridge_along_a do q = {ring[1], ring[2], ring[3], ring[0]}
	// Now q[0] -> q[1] and q[2] -> q[3] are the eaves, q[1] -> q[2] and q[3] -> q[0] the gables.
	span := (linalg.length(q[2] - q[1]) + linalg.length(q[0] - q[3])) / 2 * 1000
	tanp := 0.75 + 0.45 * nature_rand(&r)
	rise := min(span / 2 * tanp, 0.42 * height, 6)
	eave := height - rise
	if eave < 2.6 {
		eave = 2.6
		rise = height - eave
	}
	tanp = rise / (span / 2)
	cosp := 1 / math.sqrt(1 + tanp * tanp)
	sinp := tanp * cosp
	hip := !row && long / short < 1.8 && nature_rand(&r) < 0.35
	g1, g2 := (q[1] + q[2]) / 2, (q[3] + q[0]) / 2 // gable middles
	rdir := linalg.normalize(g1 - g2)
	o := f32(HOUSE_OVERHANG_M) / 1000
	r1, r2 := g1 + rdir * o, g2 - rdir * o
	if hip {
		in_ := min(span / 2, linalg.length(g1 - g2) * 500) / 1000
		r1, r2 = g1 - rdir * in_, g2 + rdir * in_
	}

	// Walls: the eave walls to the eave, the gable walls up to the ridge (not under a hip roof).
	for k in 0 ..< 4 {
		c := wc
		gable := k == 1 || k == 3
		if k == door_wall % 2 * 2 do c.a |= MAT_DOOR // a door on one of the eave walls
		top := gable && !hip ? height : 0
		hm_wall(m, q[k], q[(k + 1) % 4], 0, eave, top, eave, c)
	}

	// Roof planes with the overhang: each corner moves out along both its walls' normals and down the slope.
	outn :: proc(a, b: [2]f32) -> [2]f32 {
		d := linalg.normalize(b - a)
		return {-d.y, d.x}
	}
	corner :: proc(q: [4][2]f32, k: int, o: f32) -> [2]f32 {
		return q[k] + (outn(q[(k + 3) % 4], q[k]) + outn(q[k], q[(k + 1) % 4])) * o
	}
	c0, c1, c2, c3 := corner(q, 0, o), corner(q, 1, o), corner(q, 2, o), corner(q, 3, o)
	he := eave - HOUSE_OVERHANG_M * tanp
	tiles, slates := HOUSE_TILES, HOUSE_SLATES
	roof_mat := Street_Mat.Tile_Roof
	roof_c := tiles[pick(&r, len(tiles))]
	if nature_rand(&r) < 0.4 do roof_mat, roof_c = .Slate_Roof, slates[pick(&r, len(slates))]
	rc := house_color(&r, roof_c, roof_mat)
	under := house_color(&r, {200, 196, 186}, .Wood)
	plane :: proc(m: ^House_Mesh, e0, e1, t1, t0: [2]f32, he, top, sinp, cosp: f32, rc, under: [4]u8) {
		// e0 -> e1 the eave, t0 / t1 the ridge ends above them; uv: along the eave, up the slope (m).
		ed := linalg.normalize(e1 - e0)
		out := [2]f32{-ed.y, ed.x}
		uv :: proc(p, e0, ed, out: [2]f32, cosp: f32) -> [2]f32 {
			return {linalg.dot(p - e0, ed) * 1000, -linalg.dot(p - e0, out) * 1000 / cosp}
		}
		pts := [4][3]f32{at(e0, he), at(e1, he), at(t1, top), at(t0, top)}
		uvs := [4][2]f32 {
			uv(e0, e0, ed, out, cosp),
			uv(e1, e0, ed, out, cosp),
			uv(t1, e0, ed, out, cosp),
			uv(t0, e0, ed, out, cosp),
		}
		nrm := [3]f32{out.x * sinp, out.y * sinp, -cosp}
		if t0 == t1 {
			hm_tri(m, {pts[0], pts[1], pts[2]}, {uvs[0], uvs[1], uvs[2]}, nrm, {}, rc)
			hm_tri(m, {pts[0], pts[1], pts[2]}, {}, -nrm, {}, under)
		} else {
			hm_quad(m, pts, uvs, nrm, {}, rc)
			hm_quad(m, pts, {}, -nrm, {}, under)
		}
	}
	plane(m, c0, c1, r1, r2, he, height, sinp, cosp, rc, under)
	plane(m, c2, c3, r2, r1, he, height, sinp, cosp, rc, under)
	if hip {
		plane(m, c1, c2, r1, r1, he, height, sinp, cosp, rc, under)
		plane(m, c3, c0, r2, r2, he, height, sinp, cosp, rc, under)
	}
	// Fascia boards under the eaves.
	fascia := house_color(&r, {226, 224, 218}, .Wood)
	for e in ([2][2][2]f32{{c0, c1}, {c2, c3}}) {
		l := linalg.length(e[1] - e[0]) * 1000
		d := linalg.normalize(e[1] - e[0])
		hm_quad(
			m,
			{at(e[0], he - HOUSE_FASCIA_M), at(e[1], he - HOUSE_FASCIA_M), at(e[1], he), at(e[0], he)},
			{{0, 0}, {l, 0}, {l, 0.2}, {0, 0.2}},
			{-d.y, d.x, 0},
			{},
			fascia,
		)
	}

	// Solar panels on the slope that faces the sun best (south-west on the map: +y south, -x west).
	if nature_rand(&r) < 0.38 {
		pick := linalg.dot(outn(c0, c1), [2]f32{-0.45, 0.6}) > linalg.dot(outn(c2, c3), [2]f32{-0.45, 0.6})
		e0, e1, t1, t0 := c0, c1, r1, r2
		if !pick do e0, e1, t1, t0 = c2, c3, r2, r1
		ed := linalg.normalize(e1 - e0)
		out := [2]f32{-ed.y, ed.x}
		along := linalg.length(e1 - e0) * 1000
		slope := (height - he) / sinp
		cols := int((along - 1.4) / 1.05)
		rows := int((slope - 1.2) / 1.75)
		if cols >= 2 && rows >= 1 {
			w, hgt := f32(cols) * 1.05, f32(rows) * 1.75
			u0 := (along - w) / 2
			v0 := f32(0.7)
			lift := f32(0.09)
			p :: proc(e0, ed, out: [2]f32, u, v, he, sinp, cosp, lift: f32) -> [3]f32 {
				xy := e0 + ed * u / 1000 - out * v * cosp / 1000 + out * lift * sinp / 1000
				return at(xy, he + v * sinp + lift * cosp)
			}
			solar := house_color(&r, {28, 36, 64}, .Solar)
			pts := [4][3]f32 {
				p(e0, ed, out, u0, v0, he, sinp, cosp, lift),
				p(e0, ed, out, u0 + w, v0, he, sinp, cosp, lift),
				p(e0, ed, out, u0 + w, v0 + hgt, he, sinp, cosp, lift),
				p(e0, ed, out, u0, v0 + hgt, he, sinp, cosp, lift),
			}
			hm_quad(
				m,
				pts,
				{{0, 0}, {w, 0}, {w, hgt}, {0, hgt}},
				{out.x * sinp, out.y * sinp, -cosp},
				{},
				solar,
			)
		}
	}

	// A chimney near one gable end, through the ridge.
	if nature_rand(&r) < 0.55 && !hip {
		c := g1 - rdir * (0.9 / 1000) + outn(q[0], q[1]) * (0.35 / 1000)
		bricks := HOUSE_BRICKS
		brick := house_color(&r, bricks[pick(&r, 5)], .Brick)
		cap := house_color(&r, {120, 118, 112}, .Coping)
		hm_box(m, c, rdir, {0.4, 0.3}, eave + rise * 0.4, height + 0.7, brick, cap)
	}
}

// p inside the ring (km, any winding).
in_ring :: proc(ring: [][2]f32, p: [2]f32) -> bool {
	inside := false
	for k in 0 ..< len(ring) {
		a, b := ring[k], ring[(k + 1) % len(ring)]
		if (a.y > p.y) != (b.y > p.y) && p.x < a.x + (b.x - a.x) * (p.y - a.y) / (b.y - a.y) do inside = !inside
	}
	return inside
}

// The houses whose first corner (real) or lot centre (generated) lies in lo ..< hi (Tile_Build), relative to lo.
houses_build_tile :: proc(w: ^World, lo, hi: [2]f32) -> rl.Mesh {
	co := &w.collide
	if !co.built do collide_build(w)
	start := time.tick_now()
	count := 0
	m: House_Mesh
	CAP :: 1 << 16
	m.pos = make([dynamic][3]f32, 0, CAP, context.temp_allocator)
	m.nrm = make([dynamic][3]f32, 0, CAP, context.temp_allocator)
	m.uv = make([dynamic][2]f32, 0, CAP, context.temp_allocator)
	m.lh = make([dynamic][2]f32, 0, CAP, context.temp_allocator)
	m.col = make([dynamic][4]u8, 0, CAP, context.temp_allocator)
	idx := make([]int, 64, context.temp_allocator)
	ring := make([dynamic][2]f32, 0, 64, context.temp_allocator)

	// Real buildings: the 100 m cells of each city that overlap the tile; a building counts in the cell of its
	// first corner, so each is made once.
	half := f32(COLLIDE_CITY_CELLS) * COLLIDE_CELL_KM / 2
	for ci in 0 ..< co.city_count {
		rel_lo := lo - co.cities[ci] + half
		rel_hi := hi - co.cities[ci] + half
		if rel_hi.x < 0 || rel_hi.y < 0 || rel_lo.x > 2 * half || rel_lo.y > 2 * half do continue
		x0 := clamp(int(math.floor(rel_lo.x / COLLIDE_CELL_KM)), 0, COLLIDE_CITY_CELLS - 1)
		x1 := clamp(int(math.floor(rel_hi.x / COLLIDE_CELL_KM)), 0, COLLIDE_CITY_CELLS - 1)
		y0 := clamp(int(math.floor(rel_lo.y / COLLIDE_CELL_KM)), 0, COLLIDE_CITY_CELLS - 1)
		y1 := clamp(int(math.floor(rel_hi.y / COLLIDE_CELL_KM)), 0, COLLIDE_CITY_CELLS - 1)
		for y in y0 ..= y1 {
			for x in x0 ..= x1 {
				c := ci * COLLIDE_CITY_CELLS * COLLIDE_CITY_CELLS + y * COLLIDE_CITY_CELLS + x
				for b in co.city_items[co.city_cells[c]:co.city_cells[c + 1]] {
					pts := co.points[co.b_start[b]:][:co.b_count[b]]
					if len(pts) < 3 do continue
					p0 := pts[0]
					if p0.x < lo.x || p0.y < lo.y || p0.x >= hi.x || p0.y >= hi.y do continue
					home := (p0 - co.cities[ci] + half) / COLLIDE_CELL_KM
					if int(math.floor(home.x)) != x || int(math.floor(home.y)) != y do continue
					clear(&ring)
					for p in pts do append(&ring, p - lo)
					house_add(&m, ring[:], co.b_height[b], hash_u32(b * 2654435761 + 7), true, idx)
					count += 1
				}
			}
		}
	}

	// Generated town buildings.
	town := make([dynamic]Town_House, 0, 1024, context.temp_allocator)
	town_houses(w, lo, hi, &town)
	for th in town {
		clear(&ring)
		for p in th.ring do append(&ring, p - lo)
		house_add(&m, ring[:], th.height, th.seed, false, idx)
	}
	count += len(town)
	logf(
		w,
		"houses",
		"tile %.0f %.0f: %d buildings, %d vertices (%.1f MB), %.1f ms",
		lo.x,
		lo.y,
		count,
		len(m.pos),
		f32(len(m.pos) * 44) / (1 << 20),
		time.duration_milliseconds(time.tick_since(start)),
	)

	if len(m.pos) == 0 do return {}
	mesh := rl.Mesh {
		vertexCount   = i32(len(m.pos)),
		triangleCount = i32(len(m.pos) / 3),
		vertices      = ([^]f32)(raw_data(m.pos)),
		normals       = ([^]f32)(raw_data(m.nrm)),
		texcoords     = ([^]f32)(raw_data(m.uv)),
		texcoords2    = ([^]f32)(raw_data(m.lh)),
		colors        = ([^]u8)(raw_data(m.col)),
	}
	rl.UploadMesh(&mesh, false)
	mesh.vertices, mesh.normals, mesh.texcoords, mesh.texcoords2, mesh.colors = nil, nil, nil, nil, nil
	return mesh
}
