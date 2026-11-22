package game

import "core:math"
import "core:math/linalg"
import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"

// Trees of the street view (Lars, 2026-11-21: "veel groen, solarpunk: parken, straatbomen, tuinen"): single
// trees, a trunk and a crown of a few lumpy blobs, in TREE_KINDS kinds (lime, poplar, oak, spruce, young street
// tree). Placed per TREES_TILE_KM tile from a hash, so the same everywhere every run: parks and woods (the Park
// triangles of the land use map), street trees along the town roads on the outer edge of the sidewalk, trees in
// the empty lots of the towns (gardens), rows along a share of the country roads; never in a building nor on a
// road. Drawn instanced: the detailed meshes within TREES_NEAR_M, a lighter mesh per tree beyond.
// Sizes, densities and shapes are ours.
// Realistic crowns (Lars, 2026-11-22: "de texture van de bomen verbeteren, realistisch"): not lumpy balls any more
// but leaf cards, quads with a twig of leaves (or a spray of needles) in an alpha-tested texture, many per crown
// around a dark core, lit with the crown's normal (from its centre) so the crown shades as one soft volume and
// glows where the sun shines through. Branches reach into the crown, the bark has furrows, the crowns sway in the
// wind and the leaves flutter. The leaf texture is made in code at street_build (tree_leaf_atlas), no photo.
TREE_ATLAS_PX :: 512 // four cells of 256 px: broad leaves, oak leaves, needles, small leaves
// Shared by the lit and the depth vertex shader, so the shadows sway with the trees.
TREE_WIND_GLSL :: `
uniform float time;
vec3 tree_wind(vec3 p, vec4 col, mat4 inst) {
	float ph = dot(inst[3].xz, vec2(0.131, 0.173));
	float h = max(p.y - 0.25, 0.0);
	vec2 sway = vec2(sin(time * 1.1 + ph) + 0.4 * sin(time * 2.3 + ph * 2.1), sin(time * 0.9 + ph * 1.3)) * 0.01 * h * h;
	p.xz += sway;
	int code = int(col.a * 255.0 + 0.5);
	if ((code & 32) != 0) p += vec3(0.0035) * sin(time * 7.0 + dot(p, vec3(91.0, 57.0, 73.0)) + ph);
	return p;
}
`
TREES_TILE_KM :: 0.5
TREES_REACH_KM :: STREET_VIEW_KM
TREES_NEAR_M :: 250.0
TREES_TILE_MAX :: 2048
TREES_SLOTS :: 128
TREES_PARK_PER_KM2 :: 700.0
TREES_STREET_STEP_M :: 11.0
TREES_COUNTRY_STEP_M :: 15.0
TREES_PARK_CELL_KM :: 1.0
TREES_PARK_W :: int(MAP_W_KM / TREES_PARK_CELL_KM) + 1
TREES_PARK_H :: int(MAP_H_KM / TREES_PARK_CELL_KM) + 1
TREE_KINDS :: 5 // 0 lime, 1 poplar, 2 oak, 3 spruce, 4 young street tree

// cs, sn: cos and sin of its turn about the vertical, times its size, so a frame fills its matrix with two adds.
Tree :: struct {
	pos:    [2]f32, // m from the tile corner, x east, z south
	size:   f32, // height, m
	cs, sn: f32,
	kind:   u8,
}

Tree_Tile :: struct {
	key:   [2]i32,
	used:  bool,
	count: int,
	trees: [TREES_TILE_MAX]Tree,
}

Trees :: struct {
	tiles:              [TREES_SLOTS]Tree_Tile,
	// Park triangles per TREES_PARK_CELL_KM cell (index of the first point in w.m.area_points), perm arena.
	park_cells:         []u32,
	park_items:         []u32,
	near:               [TREE_KINDS]rl.Mesh, // height 1
	far:                [2]rl.Mesh, // broadleaf, conifer
	lit:                rl.Material, // STREET_TREE_VS / STREET_TREE_FS, instanced, the leaf atlas as texture0
	depth:              rl.Material, // instanced depth for the shadow pass, leaf cards alpha tested
	lit_loc:            Street_Light_Locs,
	leaf_tex:           rl.Texture2D, // tree_leaf_atlas, mipmapped
	time_loc:           [2]i32, // lit, depth
	last_rural_trees:   bool,
	last_rural_density: f32,
	ready:              bool,
}

// The tree vertex shader: the instance transform places a height-1 tree; v_lh is the tree's position (a hash for
// its colour), v_uv world coordinates for the leaf clumps, v_tex the leaf atlas (cards) or around / along (bark).
STREET_TREE_VS ::
	`#version 330
in vec3 vertexPosition;
in vec3 vertexNormal;
in vec4 vertexColor;
in vec2 vertexTexCoord;
in mat4 instanceTransform;
uniform mat4 mvp;
out vec3 v_world;
out vec3 v_normal;
out vec2 v_uv;
out vec2 v_lh;
out vec4 v_color;
out vec2 v_tex;
` +
	STREET_BEND_GLSL +
	TREE_WIND_GLSL +
	`
void main() {
	vec4 wp = instanceTransform * vec4(tree_wind(vertexPosition, vertexColor, instanceTransform), 1.0);
	v_world = wp.xyz;
	v_normal = normalize(mat3(instanceTransform) * vertexNormal);
	v_uv = wp.xz + vec2(wp.y * 0.7);
	v_lh = instanceTransform[3].xz;
	v_color = vertexColor;
	v_tex = vertexTexCoord;
	gl_Position = bent(mvp * wp, wp.xyz);
}
`

STREET_TREE_FS :: "#version 330\n#define TREE\n" + STREET_FS_BODY

STREET_TREE_DEPTH_VS ::
	`#version 330
in vec3 vertexPosition;
in vec4 vertexColor;
in vec2 vertexTexCoord;
in mat4 instanceTransform;
uniform mat4 mvp;
out vec2 v_tex;
out float v_card;
` +
	TREE_WIND_GLSL +
	`
void main() {
	v_tex = vertexTexCoord;
	v_card = float((int(vertexColor.a * 255.0 + 0.5) & 32) != 0);
	gl_Position = mvp * instanceTransform * vec4(tree_wind(vertexPosition, vertexColor, instanceTransform), 1.0);
}
`

// The leaf cards' shadows have the leaves' holes (the same test as STREET_TREE_FS).
STREET_TREE_DEPTH_FS :: `#version 330
in vec2 v_tex;
in float v_card;
uniform sampler2D texture0;
void main() {
	if (v_card > 0.5) {
		float mip = max(log2(max(length(fwidth(v_tex)) * 512.0, 1.0)), 0.0);
		if (texture(texture0, v_tex).a * (1.0 + 0.35 * mip) < 0.5) discard;
	}
}
`

// Indexed vertex arrays of a tree mesh under construction (frame arena).
Tree_Mesh :: struct {
	pos, nrm: [dynamic][3]f32,
	col:      [dynamic][4]u8,
	uv:       [dynamic][2]f32,
	idx:      [dynamic]u16,
}

// Street_Mat.Leaves with this bit: a leaf card, textured from the atlas and alpha tested.
TREE_CARD :: 32

// A lumpy ellipsoid: rings x segs grid, radii r around centre, bumped by the seed; darker underneath and deeper
// in the crown (ao).
tree_blob :: proc(m: ^Tree_Mesh, centre, r: [3]f32, rings, segs: int, seed: u32, c: [3]u8, ao: f32) {
	base := u16(len(m.pos))
	s := seed
	for ri in 0 ..= rings {
		th := math.PI * f32(ri) / f32(rings)
		for si in 0 ..< segs {
			ph := math.TAU * f32(si) / f32(segs)
			dir := [3]f32{math.sin(th) * math.cos(ph), math.cos(th), math.sin(th) * math.sin(ph)}
			bump := ri == 0 || ri == rings ? 1 : 0.84 + 0.32 * nature_rand(&s)
			append(&m.pos, centre + dir * r * bump)
			append(&m.nrm, linalg.normalize(dir / r))
			shade := ao * (0.62 + 0.38 * (dir.y * 0.5 + 0.5))
			append(&m.uv, [2]f32{})
			append(
				&m.col,
				[4]u8 {
					u8(f32(c.r) * shade),
					u8(f32(c.g) * shade),
					u8(f32(c.b) * shade),
					u8(Street_Mat.Leaves),
				},
			)
		}
	}
	for ri in 0 ..< rings {
		for si in 0 ..< segs {
			a := base + u16(ri * segs + si)
			b := base + u16(ri * segs + (si + 1) % segs)
			cc := a + u16(segs)
			d := b + u16(segs)
			append(&m.idx, a, b, d, a, d, cc)
		}
	}
}

// A cone (or a cylinder with r1 > 0) about the vertical axis from y0 to y1.
tree_cone :: proc(m: ^Tree_Mesh, y0, y1, r0, r1: f32, segs: int, c: [3]u8, mat: Street_Mat) {
	base := u16(len(m.pos))
	slope := (r0 - r1) / (y1 - y0)
	for si in 0 ..< segs {
		ph := math.TAU * f32(si) / f32(segs)
		d := [2]f32{math.cos(ph), math.sin(ph)}
		n := linalg.normalize([3]f32{d.x, slope, d.y})
		append(&m.pos, [3]f32{d.x * r0, y0, d.y * r0}, [3]f32{d.x * r1, y1, d.y * r1})
		append(&m.nrm, n, n)
		append(&m.uv, [2]f32{f32(si) / f32(segs), y0}, [2]f32{f32(si) / f32(segs), y1})
		low := [4]u8{u8(f32(c.r) * 0.7), u8(f32(c.g) * 0.7), u8(f32(c.b) * 0.7), u8(mat)}
		append(&m.col, low, [4]u8{c.r, c.g, c.b, u8(mat)})
	}
	for si in 0 ..< segs {
		a := base + u16(si * 2)
		b := base + u16(((si + 1) % segs) * 2)
		append(&m.idx, a, b, b + 1, a, b + 1, a + 1)
	}
}

// A tapered branch from a to b, bark coordinates around and along it (STREET_TREE_FS furrows).
tree_branch :: proc(m: ^Tree_Mesh, a, b: [3]f32, r0, r1: f32, segs: int, c: [3]u8) {
	base := u16(len(m.pos))
	axis := linalg.normalize(b - a)
	side := linalg.normalize(linalg.cross(axis, abs(axis.y) < 0.9 ? [3]f32{0, 1, 0} : [3]f32{1, 0, 0}))
	up := linalg.cross(side, axis)
	l := linalg.length(b - a)
	low := [4]u8{u8(f32(c.r) * 0.75), u8(f32(c.g) * 0.75), u8(f32(c.b) * 0.75), u8(Street_Mat.Bark)}
	high := [4]u8{c.r, c.g, c.b, u8(Street_Mat.Bark)}
	for si in 0 ..< segs {
		ph := math.TAU * f32(si) / f32(segs)
		d := side * math.cos(ph) + up * math.sin(ph)
		append(&m.pos, a + d * r0, b + d * r1)
		append(&m.nrm, d, d)
		append(&m.uv, [2]f32{f32(si) / f32(segs), 0}, [2]f32{f32(si) / f32(segs), l})
		append(&m.col, low, high)
	}
	for si in 0 ..< segs {
		i0 := base + u16(si * 2)
		i1 := base + u16(((si + 1) % segs) * 2)
		append(&m.idx, i0, i1, i1 + 1, i0, i1 + 1, i0 + 1)
	}
}

// One leaf card: a quad of half size sz at p in the plane right x up, the atlas cell's texture on it, lit with ln.
tree_card :: proc(m: ^Tree_Mesh, p, right, up, ln: [3]f32, sz: f32, cell: int, col: [4]u8) {
	base := u16(len(m.pos))
	u0, v0 := f32(cell % 2) * 0.5, f32(cell / 2) * 0.5
	INSET :: 0.004
	for c in ([4][2]f32{{-1, -1}, {1, -1}, {1, 1}, {-1, 1}}) {
		append(&m.pos, p + (right * c.x + up * c.y) * sz)
		append(&m.nrm, ln)
		append(&m.col, col)
		uv := [2]f32{c.x * 0.5 + 0.5, 0.5 - c.y * 0.5}
		append(&m.uv, [2]f32{u0, v0} + INSET + uv * (0.5 - 2 * INSET))
	}
	append(&m.idx, base, base + 1, base + 2, base, base + 2, base + 3)
}

// count leaf cards of about size (in tree heights) in the ellipsoid centre +- radii, most of them near its
// surface, each facing outwards give or take and spun at random. Lit with the ellipsoid's normal (a little of the
// card's own, so neighbours differ), the deeper ones darker.
tree_cards :: proc(
	m: ^Tree_Mesh,
	centre, radii: [3]f32,
	count: int,
	size: f32,
	cell: int,
	tint: [3]u8,
	seed: u32,
) {
	s := seed
	for _ in 0 ..< count {
		z := nature_rand(&s) * 2 - 1
		a := nature_rand(&s) * math.TAU
		rxy := math.sqrt(max(1 - z * z, 0))
		dir := [3]f32{rxy * math.cos(a), z, rxy * math.sin(a)}
		depth := math.pow(nature_rand(&s), 0.4)
		p := centre + dir * radii * depth
		n := linalg.normalize(dir / radii)
		jitter := [3]f32{nature_rand(&s), nature_rand(&s), nature_rand(&s)} - 0.5
		face := linalg.normalize(n + jitter * 1.6)
		t := linalg.normalize(linalg.cross(face, abs(face.y) < 0.95 ? [3]f32{0, 1, 0} : [3]f32{1, 0, 0}))
		b := linalg.cross(face, t)
		spin := nature_rand(&s) * math.TAU
		right := t * math.cos(spin) + b * math.sin(spin)
		up := linalg.cross(face, right)
		shade := (0.45 + 0.55 * depth) * (0.85 + 0.15 * (n.y * 0.5 + 0.5))
		col := [4]u8 {
			u8(f32(tint.r) * shade),
			u8(f32(tint.g) * shade),
			u8(f32(tint.b) * shade),
			u8(Street_Mat.Leaves) | TREE_CARD,
		}
		tree_card(
			m,
			p,
			right,
			up,
			linalg.normalize(n * 0.85 + face * 0.15),
			size * (0.38 + 0.25 * nature_rand(&s)),
			cell,
			col,
		)
	}
}

// A conifer's sprays: count needle cards on a cone from y0 (radius r0) to y1 (0), each pointing out and down
// from the trunk, lying roughly flat, the lower whorls longer.
tree_sprays :: proc(m: ^Tree_Mesh, y0, y1, r0: f32, count: int, size: f32, tint: [3]u8, seed: u32) {
	s := seed
	for _ in 0 ..< count {
		t := math.pow(nature_rand(&s), 0.8)
		y := y0 + (y1 - y0) * t
		a := nature_rand(&s) * math.TAU
		out := linalg.normalize([3]f32{math.cos(a), -0.3 - 0.25 * nature_rand(&s), math.sin(a)})
		tang := [3]f32{-math.sin(a), 0, math.cos(a)}
		r := r0 * (1 - t) * (0.5 + 0.5 * nature_rand(&s))
		sz := size * (0.45 + 0.55 * (1 - t)) * (0.4 + 0.2 * nature_rand(&s))
		p := [3]f32{math.cos(a) * r, y, math.sin(a) * r} + out * sz
		ln := linalg.normalize([3]f32{math.cos(a), 0.7, math.sin(a)})
		shade := 0.55 + 0.45 * (r / max(r0 * (1 - t), 0.001))
		col := [4]u8 {
			u8(f32(tint.r) * shade),
			u8(f32(tint.g) * shade),
			u8(f32(tint.b) * shade),
			u8(Street_Mat.Leaves) | TREE_CARD,
		}
		tree_card(m, p, tang, out, ln, sz, 2, col)
	}
}

// The leaf cards' texture, TREE_ATLAS_PX square in four cells: 0 a twig of broad, rounded leaves (lime, young
// trees), 1 a twig of darker, lobed leaves (oak), 2 a spray of needles (spruce), 3 a twig of small leaves (poplar).
// Pale colours around one grey green: the tree's tint multiplies them (STREET_TREE_FS). The empty pixels carry the
// cell's mean colour, so the mipmaps do not darken the leaf edges. Deterministic (nature_rand).
tree_leaf_atlas :: proc() -> []u8 {
	N :: TREE_ATLAS_PX
	C :: N / 2
	px := make([][4]f32, N * N, context.temp_allocator)
	// Over: coverage a of colour c on top of what is there.
	put :: proc(px: [][4]f32, x, y: int, c: [3]f32, a: f32) {
		d := &px[y * N + x]
		d.rgb = d.a > 0 ? linalg.lerp(d.rgb, c, a) : c
		d.a = max(d.a, a)
	}
	// A leaf from base b along dir (unit), length l, half width hw in px, clipped to the cell lo ..< lo + C.
	leaf :: proc(px: [][4]f32, b, dir: [2]f32, l, hw: f32, col: [3]f32, lobed: bool, lo: [2]int) {
		perp := [2]f32{-dir.y, dir.x}
		tip := b + dir * l
		mn := linalg.min(b, tip) - hw - 2
		mx := linalg.max(b, tip) + hw + 2
		for y in max(int(mn.y), lo.y) ..< min(int(mx.y) + 1, lo.y + C) {
			for x in max(int(mn.x), lo.x) ..< min(int(mx.x) + 1, lo.x + C) {
				q := [2]f32{f32(x) + 0.5, f32(y) + 0.5} - b
				u := linalg.dot(q, dir) / l
				if u < 0 || u > 1 do continue
				v := linalg.dot(q, perp)
				w := hw * math.pow(math.sin(math.PI * u), 0.7) * (1.15 - 0.35 * u)
				if lobed do w *= 0.78 + 0.22 * math.cos(u * 7 * math.PI)
				cov := clamp(w - abs(v) + 0.5, 0, 1)
				if cov <= 0 do continue
				edge := abs(v) / max(w, 0.01)
				rib := clamp(1 - abs(v) * 1.4, 0, 1) * (1 - u)
				shade := (0.9 + 0.14 * (1 - edge * edge) - 0.08 * u) * (v > 0 ? 1.04 : 0.94)
				put(px, x, y, col * shade + rib * 0.1, cov)
			}
		}
	}
	// A twig: a line from a to b of half width hw.
	twig :: proc(px: [][4]f32, a, b: [2]f32, hw: f32, lo: [2]int) {
		col := [3]f32{0.52, 0.45, 0.36}
		d := b - a
		l2 := max(linalg.dot(d, d), 1e-4)
		mn := linalg.min(a, b) - hw - 2
		mx := linalg.max(a, b) + hw + 2
		for y in max(int(mn.y), lo.y) ..< min(int(mx.y) + 1, lo.y + C) {
			for x in max(int(mn.x), lo.x) ..< min(int(mx.x) + 1, lo.x + C) {
				p := [2]f32{f32(x) + 0.5, f32(y) + 0.5}
				t := clamp(linalg.dot(p - a, d) / l2, 0, 1)
				cov := clamp(hw - linalg.length(a + d * t - p) + 0.5, 0, 1)
				if cov > 0 do put(px, x, y, col, cov)
			}
		}
	}
	rot :: proc(v: [2]f32, a: f32) -> [2]f32 {
		c, s := math.cos(a), math.sin(a)
		return {v.x * c - v.y * s, v.x * s + v.y * c}
	}
	seed: u32 = 4242
	PALE :: [3]f32{0.7, 0.76, 0.58}
	for cell in 0 ..< 4 {
		lo := [2]int{(cell % 2) * C, (cell / 2) * C}
		o := [2]f32{f32(lo.x), f32(lo.y)}
		// The main stem from the bottom middle up to near the top, a little bent; side shoots off it.
		base := o + {C * 0.5, C - 6}
		top := o + {C * (0.42 + 0.16 * nature_rand(&seed)), 14}
		twig(px, base, top, cell == 2 ? 1.6 : 1.2, lo)
		shoots := cell == 2 ? 16 : cell == 3 ? 11 : 9
		for k in 0 ..< shoots {
			t := 0.12 + 0.86 * f32(k) / f32(shoots)
			at := linalg.lerp(base, top, t)
			stem := linalg.normalize(top - base)
			side: f32 = k % 2 == 0 ? 1 : -1
			sdir := rot(stem, side * (0.75 + 0.35 * nature_rand(&seed)))
			slen := (cell == 2 ? 58 : 44) * (1.15 - 0.6 * t) * (0.8 + 0.4 * nature_rand(&seed))
			send := at + sdir * slen
			twig(px, at, send, 0.8, lo)
			switch cell {
			case 2:
				// Needles both sides along the shoot, and along the stem.
				for u: f32 = 0.05; u < 1; u += 0.07 {
					p := linalg.lerp(at, send, u)
					for sd in ([2]f32{-1, 1}) {
						d := rot(sdir, sd * (1.0 + 0.2 * nature_rand(&seed)))
						shade := 0.85 + 0.25 * nature_rand(&seed)
						leaf(
							px,
							p,
							d,
							11 + 5 * nature_rand(&seed),
							1.0,
							PALE * {0.86, 0.95, 1.05} * shade,
							false,
							lo,
						)
					}
				}
			case:
				// Leaves along the shoot and at its tip, alternating, at 30-60 degrees.
				n := cell == 3 ? 8 : 5
				for j in 0 ..< n {
					u := 0.25 + 0.75 * f32(j) / f32(n - 1)
					p := linalg.lerp(at, send, u)
					sd: f32 = j % 2 == 0 ? 1 : -1
					d := rot(sdir, sd * (0.5 + 0.5 * nature_rand(&seed)))
					if j == n - 1 do d = sdir
					l := (cell == 3 ? 12 : cell == 1 ? 24 : 21) * (0.75 + 0.5 * nature_rand(&seed))
					hw := l * (cell == 3 ? 0.36 : cell == 1 ? 0.3 : 0.42)
					tone := 0.82 + 0.3 * nature_rand(&seed)
					hue := nature_rand(&seed)
					col := PALE * tone
					if hue < 0.15 do col *= {1.1, 1.04, 0.8} // yellower
					if hue > 0.85 do col *= {0.88, 0.95, 1.02} // bluer, darker
					if cell == 1 do col *= {0.94, 0.95, 0.9}
					leaf(px, p, d, l, hw, col, cell == 1, lo)
				}
			}
		}
		// Empty pixels take the cell's mean colour.
		sum: [3]f32
		cnt: f32
		for y in lo.y ..< lo.y + C do for x in lo.x ..< lo.x + C {
			p := px[y * N + x]
			sum += p.rgb * p.a
			cnt += p.a
		}
		mean := sum / max(cnt, 1)
		for y in lo.y ..< lo.y + C do for x in lo.x ..< lo.x + C {
			p := &px[y * N + x]
			if p.a <= 0 do p.rgb = mean
		}
	}
	out := make([]u8, N * N * 4, context.temp_allocator)
	for p, i in px {
		for k in 0 ..< 4 do out[i * 4 + k] = u8(clamp(p[k], 0, 1) * 255 + 0.5)
	}
	return out
}

// raylib draws a mesh by its indices only while mesh.indices is set, so they stay (perm arena, as the car's); the
// vertex arrays are let go after the upload.
tree_mesh_upload :: proc(m: ^Tree_Mesh) -> rl.Mesh {
	indices := make([]u16, len(m.idx), context.allocator)
	copy(indices, m.idx[:])
	mesh := rl.Mesh {
		vertexCount   = i32(len(m.pos)),
		triangleCount = i32(len(m.idx) / 3),
		vertices      = ([^]f32)(raw_data(m.pos)),
		normals       = ([^]f32)(raw_data(m.nrm)),
		colors        = ([^]u8)(raw_data(m.col)),
		texcoords     = ([^]f32)(raw_data(m.uv)),
		indices       = raw_data(indices),
	}
	rl.UploadMesh(&mesh, false)
	mesh.vertices, mesh.normals, mesh.colors, mesh.texcoords = nil, nil, nil, nil
	return mesh
}

// The meshes, materials and the park index. Needs the window.
trees_build :: proc(w: ^World) {
	tr := &w.street.trees
	if tr.ready do return
	perm := context.allocator
	if tr.park_cells == nil {
		counts := make([]u32, TREES_PARK_W * TREES_PARK_H + 1, perm)
		for pass in 0 ..< 2 {
			for a in w.m.areas {
				if Area_Kind(a.kind) != .Park do continue
				for k := a.start; k + 2 < a.start + a.count; k += 3 {
					p := w.m.area_points[k:][:3]
					lo := linalg.min(p[0], linalg.min(p[1], p[2]))
					hi := linalg.max(p[0], linalg.max(p[1], p[2]))
					for y in clamp(int(lo.y / TREES_PARK_CELL_KM), 0, TREES_PARK_H - 1) ..= clamp(int(hi.y / TREES_PARK_CELL_KM), 0, TREES_PARK_H - 1) {
						for x in clamp(int(lo.x / TREES_PARK_CELL_KM), 0, TREES_PARK_W - 1) ..= clamp(int(hi.x / TREES_PARK_CELL_KM), 0, TREES_PARK_W - 1) {
							c := y * TREES_PARK_W + x
							if pass == 0 {
								counts[c + 1] += 1
							} else {
								tr.park_items[tr.park_cells[c] + counts[c]] = k
								counts[c] += 1
							}
						}
					}
				}
			}
			if pass == 0 {
				for c in 1 ..< len(counts) do counts[c] += counts[c - 1]
				tr.park_cells = counts
				tr.park_items = make([]u32, counts[len(counts) - 1], perm)
				counts = make([]u32, TREES_PARK_W * TREES_PARK_H + 1, context.temp_allocator)
			}
		}
	}

	BARK :: [3]u8{78, 66, 54}
	new_mesh :: proc() -> Tree_Mesh {
		return {
			pos = make([dynamic][3]f32, 0, 4096, context.temp_allocator),
			nrm = make([dynamic][3]f32, 0, 4096, context.temp_allocator),
			col = make([dynamic][4]u8, 0, 4096, context.temp_allocator),
			uv = make([dynamic][2]f32, 0, 4096, context.temp_allocator),
			idx = make([dynamic]u16, 0, 16384, context.temp_allocator),
		}
	}
	// Branches from the top of the trunk (y0) fanning out and up to radius r at y1, n of them.
	branches :: proc(m: ^Tree_Mesh, y0, y1, r, r0: f32, n: int, seed: u32) {
		s := seed
		for k in 0 ..< n {
			a := f32(k) * math.TAU / f32(n) + nature_rand(&s) * 0.8
			rr := r * (0.7 + 0.3 * nature_rand(&s))
			end := [3]f32{rr * math.cos(a), y1 + (nature_rand(&s) - 0.5) * 0.08, rr * math.sin(a)}
			tree_branch(m, {0, y0 - 0.03 * nature_rand(&s), 0}, end, r0, r0 * 0.3, 5, BARK)
		}
	}
	for kind in 0 ..< TREE_KINDS {
		m := new_mesh()
		switch kind {
		case 0:
			// Lime: a round crown on a clear trunk.
			tree_cone(&m, 0, 0.45, 0.026, 0.017, 8, BARK, .Bark)
			branches(&m, 0.42, 0.7, 0.22, 0.013, 5, 11)
			tree_blob(&m, {0, 0.65, 0}, {0.2, 0.2, 0.2}, 5, 8, 12, {36, 54, 24}, 0.6)
			tree_cards(&m, {0, 0.65, 0}, {0.31, 0.3, 0.31}, 300, 0.17, 0, {74, 104, 42}, 101)
		case 1:
			// Poplar: tall and slender, small leaves.
			tree_cone(&m, 0, 0.5, 0.02, 0.012, 7, {120, 114, 104}, .Bark)
			branches(&m, 0.3, 0.75, 0.07, 0.008, 4, 21)
			tree_blob(&m, {0, 0.62, 0}, {0.06, 0.3, 0.06}, 5, 7, 22, {38, 56, 26}, 0.6)
			tree_cards(&m, {0, 0.63, 0}, {0.11, 0.36, 0.11}, 220, 0.11, 3, {76, 104, 44}, 102)
		case 2:
			// Oak: broad, lower crown, branches wide.
			tree_cone(&m, 0, 0.4, 0.04, 0.026, 8, BARK, .Bark)
			branches(&m, 0.36, 0.62, 0.3, 0.018, 6, 31)
			tree_blob(&m, {0, 0.6, 0}, {0.25, 0.17, 0.25}, 5, 9, 32, {30, 46, 20}, 0.55)
			tree_cards(&m, {0, 0.62, 0}, {0.38, 0.27, 0.38}, 340, 0.19, 1, {62, 90, 36}, 103)
		case 3:
			// Spruce: a dark cone under drooping sprays of needles.
			tree_cone(&m, 0, 0.95, 0.025, 0.004, 7, BARK, .Bark)
			tree_cone(&m, 0.1, 0.96, 0.17, 0.0, 9, {24, 38, 24}, .Leaves)
			tree_sprays(&m, 0.08, 1.0, 0.27, 280, 0.26, {46, 68, 42}, 104)
		case 4:
			// Young street tree: thin trunk, small crown.
			tree_cone(&m, 0, 0.5, 0.018, 0.012, 7, BARK, .Bark)
			branches(&m, 0.47, 0.72, 0.15, 0.008, 4, 41)
			tree_blob(&m, {0, 0.72, 0}, {0.13, 0.15, 0.13}, 5, 7, 42, {40, 58, 26}, 0.6)
			tree_cards(&m, {0, 0.73, 0}, {0.21, 0.25, 0.21}, 170, 0.15, 0, {80, 108, 46}, 105)
		}
		tr.near[kind] = tree_mesh_upload(&m)
	}
	{
		// Beyond TREES_NEAR_M: fewer, larger cards round the same core.
		m := new_mesh()
		tree_cone(&m, 0, 0.45, 0.03, 0.02, 5, BARK, .Bark)
		tree_blob(&m, {0, 0.64, 0}, {0.22, 0.23, 0.22}, 4, 6, 71, {36, 54, 24}, 0.6)
		tree_cards(&m, {0, 0.64, 0}, {0.31, 0.32, 0.31}, 48, 0.42, 0, {70, 100, 40}, 111)
		tr.far[0] = tree_mesh_upload(&m)
		m = new_mesh()
		tree_cone(&m, 0, 0.6, 0.03, 0.01, 4, BARK, .Bark)
		tree_cone(&m, 0.1, 0.96, 0.18, 0.0, 6, {26, 40, 26}, .Leaves)
		tree_sprays(&m, 0.08, 1.0, 0.27, 56, 0.5, {44, 66, 40}, 112)
		tr.far[1] = tree_mesh_upload(&m)
	}
	{
		pixels := tree_leaf_atlas()
		img := rl.Image {
			data    = raw_data(pixels),
			width   = TREE_ATLAS_PX,
			height  = TREE_ATLAS_PX,
			mipmaps = 1,
			format  = .UNCOMPRESSED_R8G8B8A8,
		}
		tr.leaf_tex = rl.LoadTextureFromImage(img)
		rl.GenTextureMipmaps(&tr.leaf_tex)
		rl.SetTextureFilter(tr.leaf_tex, .TRILINEAR)
		rl.SetTextureFilter(tr.leaf_tex, .ANISOTROPIC_4X)
		rl.SetTextureWrap(tr.leaf_tex, .CLAMP)
	}
	lit := rl.LoadShaderFromMemory(STREET_TREE_VS, STREET_TREE_FS)
	if !rl.IsShaderValid(lit) do logf(w, "trees", "tree shader did not compile")
	lit.locs[rl.ShaderLocationIndex.VERTEX_INSTANCETRANSFORM] = rl.GetShaderLocationAttrib(
		lit,
		"instanceTransform",
	)
	tr.lit = rl.LoadMaterialDefault()
	tr.lit.shader = lit
	tr.lit.maps[rl.MaterialMapIndex.ALBEDO].texture = tr.leaf_tex
	tr.lit_loc = street_light_locs(lit)
	tr.time_loc[0] = rl.GetShaderLocation(lit, "time")
	depth := rl.LoadShaderFromMemory(STREET_TREE_DEPTH_VS, STREET_TREE_DEPTH_FS)
	if !rl.IsShaderValid(depth) do logf(w, "trees", "tree depth shader did not compile")
	depth.locs[rl.ShaderLocationIndex.VERTEX_INSTANCETRANSFORM] = rl.GetShaderLocationAttrib(
		depth,
		"instanceTransform",
	)
	tr.depth = rl.LoadMaterialDefault()
	tr.depth.shader = depth
	tr.depth.maps[rl.MaterialMapIndex.ALBEDO].texture = tr.leaf_tex
	tr.time_loc[1] = rl.GetShaderLocation(depth, "time")
	tr.ready = true
}

trees_unload :: proc(tr: ^Trees) {
	for &t in tr.tiles do t.used = false
	if !tr.ready do return
	// The indices live in the perm arena: UnloadMesh must not free them.
	for &m in tr.near {
		m.indices = nil
		rl.UnloadMesh(m)
	}
	for &m in tr.far {
		m.indices = nil
		rl.UnloadMesh(m)
	}
	rl.UnloadShader(tr.lit.shader)
	rl.UnloadShader(tr.depth.shader)
	rl.UnloadTexture(tr.leaf_tex)
	tr.ready = false
}

// The trees of one tile: lo ..< hi (km).
trees_build_tile :: proc(w: ^World, t: ^Tree_Tile, lo, hi: [2]f32) {
	prof_zone(w, .Trees_Build_Tile)
	t.count = 0
	tr := &w.street.trees
	st := &w.street
	// A tree at p (km) of the given size keeps out of buildings (radius r m) and off the carriageways.
	add :: proc(w: ^World, t: ^Tree_Tile, lo, hi, p: [2]f32, size, turn: f32, kind: u8, r: f32) {
		if t.count >= TREES_TILE_MAX do return
		if p.x < lo.x || p.y < lo.y || p.x >= hi.x || p.y >= hi.y do return
		if push, roof := collide_car(w, p, 0, r); push != {} || roof > 0 do return
		co := &w.collide
		cx := clamp(int(p.x / COLLIDE_ROAD_CELL_KM), 0, COLLIDE_ROAD_W - 1)
		cy := clamp(int(p.y / COLLIDE_ROAD_CELL_KM), 0, COLLIDE_ROAD_H - 1)
		cell := cy * COLLIDE_ROAD_W + cx
		for item in co.road_items[co.road_cells[cell]:co.road_cells[cell + 1]] {
			k := int(item & 0xffffff)
			a, b := w.m.points[k], w.m.points[k + 1]
			ab := b - a
			l2 := linalg.dot(ab, ab)
			s := l2 > 0 ? clamp(linalg.dot(p - a, ab) / l2, 0, 1) : 0
			if linalg.length(a + ab * s - p) * 1000 < road_half_width_m(Map_Kind(item >> 24)) + 0.6 do return
		}
		t.trees[t.count] = {(p - lo) * 1000, size, math.cos(turn) * size, math.sin(turn) * size, kind}
		t.count += 1
	}

	// Parks and woods.
	x0 := clamp(int(lo.x / TREES_PARK_CELL_KM), 0, TREES_PARK_W - 1)
	y0 := clamp(int(lo.y / TREES_PARK_CELL_KM), 0, TREES_PARK_H - 1)
	x1 := clamp(int(hi.x / TREES_PARK_CELL_KM), 0, TREES_PARK_W - 1)
	y1 := clamp(int(hi.y / TREES_PARK_CELL_KM), 0, TREES_PARK_H - 1)
	for cy in y0 ..= y1 do for cx in x0 ..= x1 {
		cell := cy * TREES_PARK_W + cx
		for k in tr.park_items[tr.park_cells[cell]:tr.park_cells[cell + 1]] {
			p0, p1, p2 := w.m.area_points[k], w.m.area_points[k + 1], w.m.area_points[k + 2]
			tlo := linalg.min(p0, linalg.min(p1, p2))
			// A triangle in several cells is planted from the first of them that the tile covers.
			first := [2]int{max(x0, int(tlo.x / TREES_PARK_CELL_KM)), max(y0, int(tlo.y / TREES_PARK_CELL_KM))}
			if first != {cx, cy} do continue
			thi := linalg.max(p0, linalg.max(p1, p2))
			if thi.x < lo.x || thi.y < lo.y || tlo.x >= hi.x || tlo.y >= hi.y do continue
			e1, e2 := p1 - p0, p2 - p0
			area := abs(e1.x * e2.y - e1.y * e2.x) / 2
			seed := hash_u32(k * 2654435761 + 99)
			n := int(area * TREES_PARK_PER_KM2 + nature_rand(&seed))
			for _ in 0 ..< n {
				u, v := nature_rand(&seed), nature_rand(&seed)
				if u + v > 1 do u, v = 1 - u, 1 - v
				c := p0 + e1 * u + e2 * v
				r := nature_rand(&seed)
				kind: u8 = r < 0.35 ? 2 : r < 0.6 ? 0 : r < 0.85 ? 3 : 1
				size := (kind == 1 ? 18 : 10) + 10 * nature_rand(&seed)
				add(w, t, lo, hi, c, size, nature_rand(&seed) * math.TAU, kind, 2)
			}
		}
	}

	// Street trees and country rows along the road segments of the tile.
	rcx := clamp(int(lo.x / STREET_ROAD_CELL_KM), 0, STREET_ROAD_W - 1)
	rcy := clamp(int(lo.y / STREET_ROAD_CELL_KM), 0, STREET_ROAD_H - 1)
	rc := rcy * STREET_ROAD_W + rcx
	for item in st.road_segs[st.road_cells[rc]:st.road_cells[rc + 1]] {
		k := int(item & 0xffffff)
		kind := Map_Kind(item >> 24)
		if kind != .Primary && kind != .Secondary && kind != .Tertiary do continue
		a, b := w.m.points[k], w.m.points[k + 1]
		mid := (a + b) / 2
		if mid.x < lo.x - 0.05 || mid.y < lo.y - 0.05 || mid.x >= hi.x + 0.05 || mid.y >= hi.y + 0.05 do continue
		hw := road_half_width_m(kind)
		urban := urban_at(w, mid)
		seed := hash_u32(u32(k) * 2246822519 + 5)
		if !urban && nature_rand(&seed) > 0.4 do continue
		step := f32(urban ? TREES_STREET_STEP_M : TREES_COUNTRY_STEP_M)
		off := urban ? hw + ROAD_SIDEWALK_M - 0.9 : hw + 3.5
		d := (b - a) * 1000
		l := linalg.length(d)
		if l <= 0 do continue
		dir := d / l
		side := [2]f32{-dir.y, dir.x}
		// Spaced along the whole line (road_s), so the rows run on across segments.
		u0 := st.road_s[k]
		first := (math.floor(u0 / step) + 1) * step - u0
		row_kind: u8 = urban ? (nature_rand(&seed) < 0.5 ? 4 : 0) : (nature_rand(&seed) < 0.6 ? 1 : 0)
		for s := first; s < l; s += step {
			for sd in ([2]f32{-1, 1}) {
				p := a + (dir * s + side * off * sd) / 1000
				size := (row_kind == 1 ? 18 : urban ? 7 : 10) + 4 * nature_rand(&seed)
				add(w, t, lo, hi, p, size, nature_rand(&seed) * math.TAU, row_kind, 1)
			}
		}
	}

	// Garden trees in the empty lots of the towns.
	gardens := make([dynamic][2]f32, 0, 512, context.temp_allocator)
	houses := make([dynamic]Town_House, 0, 512, context.temp_allocator)
	town_houses(w, lo, hi, &houses, &gardens)
	for g in gardens {
		seed := hash_u32(u32(i32(g.x * 1e5)) * 73856093 ~ u32(i32(g.y * 1e5)) * 19349663)
		n := 1 + int(nature_rand(&seed) * 2.2)
		for _ in 0 ..< n {
			p := g + [2]f32{nature_rand(&seed) - 0.5, nature_rand(&seed) - 0.5} * 0.022
			r := nature_rand(&seed)
			kind: u8 = r < 0.4 ? 0 : r < 0.6 ? 4 : r < 0.8 ? 3 : 2
			add(w, t, lo, hi, p, 5 + 7 * nature_rand(&seed), nature_rand(&seed) * math.TAU, kind, 1.5)
		}
	}

	// Sparse hedgerow copses on unmapped rural countryside (strictly outside cities, towns, parks and water).
	if w.rural_edit.trees && w.rural_edit.tree_per_km2 > 0 {
		rseed := hash_u32(u32(t.key.x) * 92821 ~ u32(t.key.y) * 68917 ~ 0x7a31)
		n := int((hi.x - lo.x) * (hi.y - lo.y) * w.rural_edit.tree_per_km2 + nature_rand(&rseed))
		for i := 0; i < n; {
			anchor := lo + {nature_rand(&rseed), nature_rand(&rseed)} * (hi - lo)
			if !belgium_inside(w, anchor.x, anchor.y) ||
			   urban_at(w, anchor) ||
			   height_at(w, anchor.x, anchor.y) <= 0.2 {
				i += 1
				continue
			}
			if kind, has := solarpunk_area_at(w, anchor); has && kind != .Farmland {
				i += 1
				continue
			}
			cluster := min(1 + int(nature_rand(&rseed) * 3), n - i)
			for _ in 0 ..< cluster {
				p := anchor + {nature_rand(&rseed) - 0.5, nature_rand(&rseed) - 0.5} * 0.028
				if !belgium_inside(w, p.x, p.y) || urban_at(w, p) do continue
				if kind, has := solarpunk_area_at(w, p); has && kind != .Farmland do continue
				r := nature_rand(&rseed)
				tk: u8 = r < 0.5 ? 2 : r < 0.8 ? 0 : 1
				size := (tk == 1 ? 14 : 9) + 6 * nature_rand(&rseed)
				add(w, t, lo, hi, p, size, nature_rand(&rseed) * math.TAU, tk, 2)
			}
			i += cluster
		}
	}
}

// Keeps the tiles within reach of target (km) built (one a frame) and draws the trees with the lit material, or
// with depth (the shadow pass) those within reach of target only. cam: the camera in street space.
trees_draw :: proc(w: ^World, target: [2]f32, reach: f32, cam: [3]f32, shadow: bool) {
	prof_zone(w, .Trees_Draw)
	tr := &w.street.trees
	st := &w.street
	if !tr.ready do return
	size := f32(TREES_TILE_KM)
	if !shadow {
		if tr.last_rural_trees != w.rural_edit.trees || tr.last_rural_density != w.rural_edit.tree_per_km2 {
			for &t in tr.tiles do t.used = false
			tr.last_rural_trees = w.rural_edit.trees
			tr.last_rural_density = w.rural_edit.tree_per_km2
		}
		keep := reach + 2 * size
		for &t in tr.tiles {
			if t.used && linalg.length(tile_centre(t.key, size) - target) > keep do t.used = false
		}
		best: [2]i32
		best_d := max(f32)
		lo := linalg.floor((target - reach) / size)
		hi := linalg.floor((target + reach) / size)
		for y := i32(lo.y); y <= i32(hi.y); y += 1 {
			for x := i32(lo.x); x <= i32(hi.x); x += 1 {
				key := [2]i32{x, y}
				d := linalg.length(tile_centre(key, size) - target)
				if d > reach + size * 0.71 || d >= best_d do continue
				built := false
				for t in tr.tiles do if t.used && t.key == key do built = true
				if !built do best, best_d = key, d
			}
		}
		if best_d < max(f32) {
			slot := -1
			for t, i in tr.tiles do if !t.used {slot = i; break}
			if slot >= 0 {
				t := &tr.tiles[slot]
				t.key, t.used = best, true
				lo_km := [2]f32{f32(best.x), f32(best.y)} * size
				trees_build_tile(w, t, lo_km, lo_km + size)
			}
		}
	}

	near: [TREE_KINDS][dynamic]rl.Matrix
	far: [2][dynamic]rl.Matrix
	for k in 0 ..< TREE_KINDS do near[k] = make([dynamic]rl.Matrix, 0, 1024, context.temp_allocator)
	for k in 0 ..< 2 do far[k] = make([dynamic]rl.Matrix, 0, 4096, context.temp_allocator)
	for &t in tr.tiles {
		if !t.used || t.count == 0 do continue
		gap := linalg.max(linalg.abs(tile_centre(t.key, size) - target) - size / 2, 0)
		if linalg.length(gap) > reach do continue
		corner := [2]f64{f64(t.key.x) * f64(size), f64(t.key.y) * f64(size)}
		off := [2]f32{f32((corner.x - f64(st.origin.x)) * 1000), f32((corner.y - f64(st.origin.y)) * 1000)}
		for tree in t.trees[:t.count] {
			p := off + tree.pos
			d := linalg.length(p - cam.xz)
			if !shadow && d > TREES_REACH_KM * 1000 + 50 do continue
			// translate(p) x turn x scale(size), written out; far poplars are drawn thinner.
			near_tree := d < TREES_NEAR_M
			thin: f32 = !near_tree && tree.kind == 1 ? 0.45 : 1
			cs, sn := tree.cs * thin, tree.sn * thin
			m := rl.Matrix{cs, 0, sn, p.x, 0, tree.size, 0, 0, -sn, 0, cs, p.y, 0, 0, 0, 1}
			if near_tree {
				append(&near[tree.kind], m)
			} else {
				append(&far[tree.kind == 3 ? 1 : 0], m)
			}
		}
	}
	mat := shadow ? tr.depth : tr.lit
	if !shadow do street_light_set(w, tr.lit.shader, &tr.lit_loc, cam)
	// The simulated clock, so a scripted run sways the same every time.
	t := f32(w.tick % (SIM_HZ * 3600)) * SIM_DT
	rl.SetShaderValue(mat.shader, tr.time_loc[shadow ? 1 : 0], &t, .FLOAT)
	// Leaf cards have two faces.
	rlgl.DrawRenderBatchActive()
	rlgl.DisableBackfaceCulling()
	defer rlgl.EnableBackfaceCulling()
	for k in 0 ..< TREE_KINDS {
		if len(near[k]) > 0 do rl.DrawMeshInstanced(tr.near[k], mat, raw_data(near[k]), i32(len(near[k])))
	}
	for k in 0 ..< 2 {
		if len(far[k]) > 0 do rl.DrawMeshInstanced(tr.far[k], mat, raw_data(far[k]), i32(len(far[k])))
	}
}
