package game

import "core:fmt"
import "core:math"
import "core:math/linalg"
import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"

// Street view (Lars, 2026-11-21: "een 3d game waar je tussen huizen kan vliegen, zoals gta in third person, zo
// realistisch mogelijk, niet cartoonachtig"). V on the navigation screen puts a third-person camera behind the
// car at real scale; the car flies with ship_free_step. The map stays as it was, V or Esc goes back.
//
// Street space: metres, x east, y up, z south, around origin (km, snapped to STREET_ORIGIN_KM so the f32 values
// stay small and do not shake). The map meshes (x km, y km south, z km down) are drawn with street_place.
// The ground is flat at y = 0: the car's height is its height above the local ground (alt - height_at), the way
// the buildings stand on the map. The view ends at STREET_FAR_M, the haze closes before that.
STREET_ORIGIN_KM :: 0.25
// raylib's own near plane of 0.05 m leaves one step of the 24 bit depth buffer ~0.3 m deep at 500 m and ~1.2 m at
// 1 km, so walls a little apart z-fought in the distance. 0.25 m is five times sharper; the camera keeps
// STREET_CAM_WALL_M from walls so the near plane never cuts one.
STREET_NEAR_M :: 0.25
STREET_FAR_M :: 4000.0
STREET_CAM_WALL_M :: 0.6
STREET_REACH_KM :: 3.6
STREET_FOG_M :: [2]f32{220, 3500}
STREET_CAM_DIST_M :: 8.5
STREET_CAM_MIN_M :: 4.0
STREET_CAM_MAX_M :: 40.0
STREET_CAM_LOOK_UP_M :: 1.6 // the camera looks at this point above the car
STREET_CAM_PITCH :: 0.16 // radians down at rest
STREET_CAM_RATE :: 7.0 // the camera closes this share of the gap per second
STREET_MOUSE_RAD_PER_PX :: 0.0035
STREET_STICK_RAD_PER_S :: 2.5
STREET_RECENTRE_S :: 1.6 // after this long without looking around the camera swings back behind the car
STREET_FOV :: 62.0
STREET_FOV_FAST :: 10.0 // wider at top speed
STREET_ROAD_TILE_KM :: 1.0
STREET_ROAD_CELL_KM :: 2.0
STREET_ROAD_W :: int(MAP_W_KM) / int(STREET_ROAD_CELL_KM) + 1
STREET_ROAD_H :: int(MAP_H_KM) / int(STREET_ROAD_CELL_KM) + 1
STREET_HINT_S :: 7.0 // the key hint shows this long after switching on
Street :: struct {
	on:         bool,
	yaw, pitch: f32, // the player's look-around on top of the chase direction, radians
	dist:       f32, // zero = STREET_CAM_DIST_M
	idle_s:     f32, // seconds since the player last looked around
	on_s:       f32, // seconds since the street view switched on
	origin:     [2]f32, // km
	eye:        [3]f32, // the camera, street space, eased
	seeded:     bool,
	view:       rl.Camera3D,
	// Road ribbons per STREET_ROAD_TILE_KM tile. road_segs lists, per STREET_ROAD_CELL_KM cell, the map line
	// segments it holds: kind << 24 | index of the segment's first point (road_cells has the offsets).
	roads:      Tile_Cache,
	road_cells: []u32,
	road_segs:  []u32,
	// The ground plane, the land use triangles and the roads share one shader.
	ground:     rl.Mesh,
	material:   rl.Material,
	loc:        struct {
		layer, remap, map_colors, real_colors, origin, cities: i32,
		light:                                                 Street_Light_Locs,
	},
	// The houses (houses.odin) with the lit shader, and the sky.
	houses:     Tile_Cache,
	lit:        rl.Material,
	lit_loc:    Street_Light_Locs,
	sky:        rl.Shader,
	sky_loc:    struct {
		fwd, right, up, tan_half, screen: i32,
		light:                            Street_Light_Locs,
	},
	ready:      bool,
}

// Uniform locations of STREET_GLSL in one shader.
Street_Light_Locs :: struct {
	sun_dir, sun_col, sky_zen, sky_hor, amb_sky, amb_gnd, cam, haze: i32,
}

street_light_locs :: proc(sh: rl.Shader) -> Street_Light_Locs {
	return {
		sun_dir = rl.GetShaderLocation(sh, "sun_dir"),
		sun_col = rl.GetShaderLocation(sh, "sun_col"),
		sky_zen = rl.GetShaderLocation(sh, "sky_zen"),
		sky_hor = rl.GetShaderLocation(sh, "sky_hor"),
		amb_sky = rl.GetShaderLocation(sh, "amb_sky"),
		amb_gnd = rl.GetShaderLocation(sh, "amb_gnd"),
		cam = rl.GetShaderLocation(sh, "cam"),
		haze = rl.GetShaderLocation(sh, "haze"),
	}
}

street_light_set :: proc(sh: rl.Shader, l: Street_Light_Locs, cam: [3]f32) {
	look := STREET_LOOK
	cam := cam
	rl.SetShaderValue(sh, l.sun_dir, &look.sun_dir, .VEC3)
	rl.SetShaderValue(sh, l.sun_col, &look.sun_col, .VEC3)
	rl.SetShaderValue(sh, l.sky_zen, &look.sky_zen, .VEC3)
	rl.SetShaderValue(sh, l.sky_hor, &look.sky_hor, .VEC3)
	rl.SetShaderValue(sh, l.amb_sky, &look.amb_up, .VEC3)
	rl.SetShaderValue(sh, l.amb_gnd, &look.amb_down, .VEC3)
	rl.SetShaderValue(sh, l.cam, &cam, .VEC3)
	rl.SetShaderValue(sh, l.haze, &look.haze, .VEC2)
}

// The light of every street view shader (STREET_GLSL is pasted into each): one sun, a sky gradient that also
// gives the haze its colour (aerial perspective: far things take the colour of the low sky in their direction),
// ambient light from the sky above and the ground below. Lighting runs on linear colours (lin = squared sRGB),
// then an ACES filmic curve and back to sRGB, so bright sunlit walls roll off instead of clipping.
STREET_GLSL :: `
uniform vec3 sun_dir;
uniform vec3 sun_col;
uniform vec3 sky_zen;
uniform vec3 sky_hor;
uniform vec3 amb_sky;
uniform vec3 amb_gnd;
uniform vec3 cam;
uniform vec2 haze;
float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}
float vnoise(vec2 p) {
	vec2 i = floor(p), f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash12(i), hash12(i + vec2(1, 0)), u.x), mix(hash12(i + vec2(0, 1)), hash12(i + vec2(1, 1)), u.x), u.y);
}
vec3 sky_col(vec3 r) {
	float e = clamp(r.y, 0.0, 1.0);
	vec3 c = mix(sky_hor, sky_zen, pow(e, 0.5));
	c += sky_hor * 0.3 * pow(1.0 - e, 12.0);
	float s = max(dot(r, sun_dir), 0.0);
	c += sun_col * (0.035 * pow(s, 4.0) + 0.1 * pow(s, 48.0));
	return c;
}
vec3 aerial(vec3 c, vec3 p) {
	vec3 d = p - cam;
	float dist = length(d);
	vec3 r = d / max(dist, 0.001);
	vec3 h = sky_col(normalize(vec3(r.x, 0.03 + max(r.y, 0.0) * 0.3, r.z)));
	return mix(c, h, haze.y * (1.0 - exp(-dist * haze.x)));
}
vec3 lin(vec3 c) { return c * c; }
vec3 tonemap(vec3 c) {
	c = clamp((c * (2.51 * c + 0.03)) / (c * (2.43 * c + 0.59) + 0.14), 0.0, 1.0);
	return sqrt(c);
}
float box(float x, float h, float w) { return clamp((h - abs(x)) / max(w, 1e-4) + 0.5, 0.0, 1.0); }
`

// Ground shader: vertex colours, land use colours swapped from the map design to natural ones (remap), noise in
// world space so large surfaces are not flat paint, lit by the sun, the haze of STREET_GLSL.
// The ground layers (land, land use, rivers, roads, markings) all lie on y = 0, so the depth buffer cannot order
// them: meshes in km drawn with km x 1000 minus ~150 km in f32 got a depth that is off by 1e-6..3e-6 in NDC
// against the land quad (measured at 280 m), ten times any usable bias, so they lost the depth test at random.
// Nothing can stand below the ground and the camera is always above it, so the ground never hides anything:
// every ground fragment writes the far depth, minus a hair per layer (layer = layer uniform + the vertex alpha,
// alpha = 1 - layer / 4). A later layer always wins over an earlier one, a tie goes to the draw order, and
// everything 3D drawn after the ground is nearer than all of it.
STREET_GROUND_VS :: `#version 330
in vec3 vertexPosition;
in vec4 vertexColor;
uniform mat4 mvp;
uniform mat4 matModel;
out vec4 color;
out vec3 world;
void main() {
	gl_Position = mvp * vec4(vertexPosition, 1.0);
	color = vertexColor;
	world = (matModel * vec4(vertexPosition, 1.0)).xyz;
}
`

STREET_GROUND_FS ::
	`#version 330
in vec4 color;
in vec3 world;
uniform float remap;
uniform vec3 map_colors[6];
uniform vec3 real_colors[6];
uniform vec2 origin;
uniform float layer;
uniform vec3 cities[16]; // x, z in street metres, radius m (0 = none): the circles of real buildings
out vec4 finalColor;
` +
	STREET_GLSL +
	`
void main() {
	vec3 c = color.rgb;
	if (remap > 0.5) {
		for (int i = 0; i < 6; i++) {
			if (distance(c, map_colors[i]) < 0.01) c = real_colors[i];
		}
	}
	c = lin(c);
	// Inside a circle of real OSM buildings the open ground is streets and squares: paving, not grass. Parks are
	// a later layer and stay green.
	if (layer < 0.5) {
		float city = 0.0;
		for (int i = 0; i < 16; i++) {
			if (cities[i].z > 0.0) city = max(city, 1.0 - smoothstep(cities[i].z * 0.85, cities[i].z, distance(world.xz, cities[i].xy)));
		}
		vec2 pv = world.xz;
		float stones = 1.0 - smoothstep(0.004, 0.004 + fwidth(pv.x) * 1.5, min(abs(fract(pv.x / 0.3) - 0.5), abs(fract(pv.y / 0.15 + 0.5 * floor(pv.x / 0.3)) - 0.5)) * 0.1);
		vec3 paving = vec3(0.16, 0.155, 0.145) * (0.9 + 0.2 * vnoise(pv * 0.8)) * (1.0 - 0.15 * stones * (1.0 - smoothstep(0.01, 0.05, fwidth(pv.x))));
		c = mix(c, paving, city);
	}
	vec2 q = world.xz + origin;
	float n = vnoise(q / 9.0) * 0.6 + vnoise(q / 41.0) * 0.4;
	float fine = vnoise(world.xz * 1.7);
	float near = 1.0 - smoothstep(30.0, 400.0, length(world - cam));
	c *= 1.0 + (n - 0.5) * 0.22 + (fine - 0.5) * 0.12 * near;
	c *= sun_col * max(sun_dir.y, 0.0) + amb_sky;
	finalColor = vec4(tonemap(aerial(c, world)), 1.0);
	gl_FragDepth = 1.0 - (layer + floor((1.0 - color.a) * 4.0 + 0.5)) * 2e-7;
}
`

// The lit shader of the houses (and later trees and furniture): per vertex a normal, uv in metres on the surface,
// lh = (wall length, eave height) m and a colour whose alpha is the Street_Mat (houses.odin) plus flags. Walls get
// their facade here: floors, bays, windows with frames, mullions, sills and reveals, the front door, shop fronts
// with a fascia, brick / plaster / stone texture, a bluestone plinth, a cornice and ambient occlusion at the foot
// and under the eave. Everything is filtered by the pixel's footprint on the surface (fw, m per pixel): thin lines
// fade into their average instead of flickering, far facades become their average colour.
STREET_VS :: `#version 330
in vec3 vertexPosition;
in vec3 vertexNormal;
in vec2 vertexTexCoord;
in vec2 vertexTexCoord2;
in vec4 vertexColor;
uniform mat4 mvp;
uniform mat4 matModel;
uniform mat4 matNormal;
out vec3 v_world;
out vec3 v_normal;
out vec2 v_uv;
out vec2 v_lh;
out vec4 v_color;
void main() {
	v_world = (matModel * vec4(vertexPosition, 1.0)).xyz;
	v_normal = (matNormal * vec4(vertexNormal, 0.0)).xyz;
	v_uv = vertexTexCoord;
	v_lh = vertexTexCoord2;
	v_color = vertexColor;
	gl_Position = mvp * vec4(vertexPosition, 1.0);
}
`

STREET_FS ::
	`#version 330
in vec3 v_world;
in vec3 v_normal;
in vec2 v_uv;
in vec2 v_lh;
in vec4 v_color;
out vec4 finalColor;
` +
	STREET_GLSL +
	`
void main() {
	int code = int(v_color.a * 255.0 + 0.5);
	int mat = code & 31;
	bool shop = (code & 32) != 0;
	bool door = (code & 64) != 0;
	vec3 n = normalize(v_normal);
	vec3 V = normalize(cam - v_world);
	vec3 base = lin(v_color.rgb);
	vec3 ci = floor(v_color.rgb * 255.0 + 0.5);
	float seed = hash12(vec2(ci.r + ci.g * 256.0, ci.b + 17.0));
	float ao = 1.0;
	float glass = 0.0;
	vec3 interior = vec3(0.012, 0.013, 0.015);
	float spec = 0.0;
	vec2 uv = v_uv;
	float fw = max(length(fwidth(uv)), 1e-4);

	if (mat >= 1 && mat <= 3) {
		float u = uv.x, v = uv.y, L = v_lh.x, H = v_lh.y;
		float detail = 1.0 - smoothstep(0.006, 0.03, fw);
		if (mat == 1) {
			// Belgian brick 19 x 5 cm with 1 cm joints, running bond.
			float cy = v / 0.06; float row = floor(cy); float fy = fract(cy);
			float cx = u / 0.2 + 0.5 * mod(row, 2.0); float cl = floor(cx); float fx = fract(cx);
			float j = min(min(fy, 1.0 - fy) * 0.06, min(fx, 1.0 - fx) * 0.2);
			float joint = 1.0 - smoothstep(0.004, 0.004 + fw, j);
			vec3 b = base * (0.84 + 0.32 * hash12(vec2(cl, row) + seed * 97.0));
			vec3 mortar = vec3(0.36, 0.34, 0.31);
			base = mix(mix(base, mortar, 0.15), mix(b, mortar, joint), detail);
		} else if (mat == 2) {
			float g = vnoise(uv * 2.0) * 0.5 + vnoise(uv * 9.0) * 0.5;
			base *= (0.94 + 0.1 * g) * mix(0.8, 1.0, smoothstep(0.0, 2.5, v));
		} else {
			float cy = v / 0.32; float row = floor(cy); float fy = fract(cy);
			float cx = u / 0.65 + 0.37 * mod(row, 3.0); float cl = floor(cx); float fx = fract(cx);
			float j = min(min(fy, 1.0 - fy) * 0.32, min(fx, 1.0 - fx) * 0.65);
			float joint = 1.0 - smoothstep(0.003, 0.003 + fw, j);
			vec3 b = base * (0.92 + 0.14 * hash12(vec2(cl, row) + seed * 51.0));
			base = mix(base, mix(b, base * 0.7, joint), detail);
		}

		float fh = 2.85 + 0.55 * hash12(vec2(seed, 1.0));
		float gh = fh * 1.18;
		float bayw = 2.7 + 1.4 * hash12(vec2(seed, 2.0));
		float nb = floor(L / bayw);
		float fdet = 1.0 - smoothstep(0.12, 0.45, fw);
		if (nb >= 1.0 && v < H) {
			float bw = L / nb;
			float bi = clamp(floor(u / bw), 0.0, nb - 1.0);
			float bx = u - (bi + 0.5) * bw;
			bool gf = v < gh;
			float fl = gf ? 0.0 : floor((v - gh) / fh) + 1.0;
			float fy = gf ? v : v - gh - (fl - 1.0) * fh;
			float ww = min(1.05 + 0.5 * hash12(vec2(seed, 3.0)), bw * 0.64);
			float y0 = 0.9, y1 = min(fh - 0.5, 2.3);
			bool is_door = door && gf && bi == floor(hash12(vec2(seed, 5.0)) * nb);
			bool is_shop = shop && gf && !is_door;
			if (gf) { y0 = 0.95; y1 = min(gh - 0.55, 2.45); }
			if (is_shop) { ww = bw - 0.5; y0 = 0.45; y1 = gh - 0.6; }
			if (is_door) { ww = 1.05; y0 = 0.0; y1 = 2.3; }
			float wtop = (gf ? 0.0 : gh + (fl - 1.0) * fh) + y1;
			float has = wtop < H - 0.25 ? 1.0 : 0.0;
			float hy = (y1 - y0) * 0.5, cy2 = fy - (y0 + y1) * 0.5;
			float fr = 0.065;
			float wc = box(bx, ww * 0.5, fw) * box(cy2, hy, fw) * has;
			float gc = box(bx, ww * 0.5 - fr, fw) * box(cy2, hy - fr, fw) * has;
			if (!is_door) {
				if (ww > 1.0) gc *= 1.0 - box(bx, 0.03, fw);
				gc *= 1.0 - box(fy - (y1 - (y1 - y0) * 0.28), 0.025, fw);
			}
			vec3 frame_c = hash12(vec2(seed, 4.0)) < 0.55 ? vec3(0.75) : (hash12(vec2(seed, 6.0)) < 0.6 ? vec3(0.02, 0.022, 0.025) : vec3(0.15, 0.065, 0.03));
			base = mix(base, frame_c, (wc - gc) * fdet);
			if (is_door) {
				vec3 door_c = lin(vec3(0.12 + 0.5 * hash12(vec2(seed, 7.0)), 0.16, 0.1 + 0.25 * hash12(vec2(seed, 8.0))));
				base = mix(base, door_c, gc * fdet);
				gc = box(bx, 0.3, fw) * box(fy - 1.85, 0.25, fw);
			}
			vec3 stone_c = vec3(0.42, 0.41, 0.38);
			float sill = box(bx, ww * 0.5 + 0.06, fw) * box(fy - (y0 - 0.04), 0.04, fw) * has * (is_door || is_shop ? 0.0 : 1.0);
			base = mix(base, stone_c, sill * fdet);
			if (mat == 1) {
				float lintel = box(bx, ww * 0.5 + 0.1, fw) * box(fy - (y1 + 0.07), 0.07, fw) * has;
				base = mix(base, base * 0.75, lintel * fdet);
			}
			if (is_shop) {
				vec3 sign_c = lin(vec3(0.1 + 0.5 * hash12(vec2(seed, 9.0)), 0.12 + 0.4 * hash12(vec2(seed, 10.0)), 0.1 + 0.3 * hash12(vec2(seed, 11.0))));
				base = mix(base, sign_c, box(fy - (gh - 0.33), 0.2, fw) * fdet);
			}
			float reveal = smoothstep(0.0, 0.25, (y1 - fr) - fy);
			interior *= (0.6 + 0.9 * hash12(vec2(bi, fl) + seed * 13.0)) * mix(0.45, 1.0, reveal);
			glass = gc * fdet;
			float avg = (ww * (y1 - y0)) / (bw * fh) * has;
			base = mix(mix(base, vec3(0.03), avg * 0.8), base, fdet);
		}
		float plinth = 1.0 - smoothstep(0.42, 0.42 + fw, v);
		base = mix(base, vec3(0.05, 0.055, 0.06), plinth * (1.0 - glass));
		float corn = box(v - (H - 0.18), 0.16, fw) * (v < H + 0.05 ? 1.0 : 0.0);
		if (mat != 3) base = mix(base, mat == 1 ? vec3(0.48, 0.46, 0.42) : base * 1.08, corn * 0.85);
		ao *= mix(0.55, 1.0, smoothstep(0.0, 1.4, v));
		ao *= mix(0.75, 1.0, smoothstep(0.0, 0.6, abs(H - v)));
		if (v > H + 0.7 && L > 4.0) {
			float ga = box(u - L * 0.5, 0.42, fw) * box(v - (H + 1.3), 0.5, fw);
			float gg = box(u - L * 0.5, 0.36, fw) * box(v - (H + 1.3), 0.44, fw);
			base = mix(base, vec3(0.75), (ga - gg) * fdet);
			glass = max(glass, gg * fdet);
		}
	} else if (mat == 4) {
		float u = uv.x, v = uv.y;
		float fy = fract(v / 3.6) * 3.6;
		float px = fract(u / 1.5) * 1.5;
		float mull = 1.0 - box(px - 0.75, 0.7, fw);
		float band = box(fy - 0.45, 0.45, fw);
		glass = (1.0 - max(mull, band)) * step(0.6, v) * 0.95;
		interior = vec3(0.01, 0.014, 0.018);
		base = mix(base, vec3(0.1, 0.11, 0.12), mull);
		ao *= mix(0.65, 1.0, smoothstep(0.0, 1.0, v));
	} else if (mat == 5 || mat == 6) {
		float course = mat == 5 ? 0.33 : 0.21;
		float tw = mat == 5 ? 0.24 : 0.3;
		float cy = uv.y / course; float row = floor(cy); float fy = fract(cy);
		float cx = uv.x / tw + 0.5 * mod(row, 2.0); float cid = floor(cx); float fx = fract(cx);
		float detail = 1.0 - smoothstep(0.01, 0.06, fw);
		float shade = mix(0.7, 1.0, smoothstep(0.0, 0.35, fy));
		float gap = 1.0 - smoothstep(0.004, 0.004 + fw, min(fx, 1.0 - fx) * tw);
		vec3 t = base * (0.82 + 0.3 * hash12(vec2(cid, row) + seed * 7.0)) * shade * (1.0 - gap * 0.35);
		float moss = smoothstep(0.55, 0.9, vnoise(uv * 0.7 + seed * 10.0)) * 0.35;
		t = mix(t, vec3(0.05, 0.07, 0.025), moss * (mat == 5 ? 1.0 : 0.6));
		base = mix(base * 0.86, t, detail);
		spec = mat == 6 ? 0.12 : 0.03;
	} else if (mat == 7) {
		base *= 0.8 + 0.4 * (vnoise(uv * 3.0) * 0.6 + vnoise(uv * 13.0) * 0.4);
	} else if (mat == 8) {
		float a = vnoise(uv * 0.9 + seed * 3.0), b = vnoise(uv * 4.0 + 7.0), c = vnoise(uv * 15.0);
		vec3 sedum = mix(vec3(0.045, 0.1, 0.018), vec3(0.12, 0.14, 0.03), b);
		sedum = mix(sedum, vec3(0.15, 0.055, 0.03), smoothstep(0.62, 0.8, a) * 0.8);
		sedum = mix(sedum, vec3(0.19, 0.17, 0.05), smoothstep(0.7, 0.9, c) * 0.5);
		base = sedum * 1.5;
	} else if (mat == 9) {
		float px = fract(uv.x / 1.05) * 1.05, py = fract(uv.y / 1.75) * 1.75;
		float frame = 1.0 - box(px - 0.525, 0.5, fw) * box(py - 0.875, 0.83, fw);
		float cw = fw / 0.175;
		float cells = max(1.0 - box(fract(px / 0.175) - 0.5, 0.46, cw), 1.0 - box(fract(py / 0.175) - 0.5, 0.46, cw)) * (1.0 - smoothstep(0.01, 0.04, fw));
		base = mix(vec3(0.006, 0.01, 0.028), vec3(0.45), frame);
		base = mix(base, vec3(0.04, 0.05, 0.08), cells * 0.6 * (1.0 - frame));
		glass = (1.0 - frame) * 0.85;
		interior = base;
		spec = 0.5;
	}

	float ndl = max(dot(n, sun_dir), 0.0);
	vec3 amb = mix(amb_gnd, amb_sky, n.y * 0.5 + 0.5);
	vec3 c = base * (sun_col * ndl + amb) * ao;
	c += sun_col * spec * pow(max(dot(n, normalize(sun_dir + V)), 0.0), 60.0) * ndl;
	if (glass > 0.001) {
		vec3 r = reflect(-V, n);
		float fres = 0.05 + 0.95 * pow(1.0 - max(dot(n, V), 0.0), 5.0);
		vec3 refl = r.y > 0.0 ? sky_col(r) : mix(amb_gnd * 0.7, sky_hor * 0.5, exp(r.y * 6.0));
		refl += sun_col * 3.0 * pow(max(dot(r, sun_dir), 0.0), 400.0);
		vec3 g = interior * (amb + sun_col * 0.15) + refl * clamp(fres + 0.18, 0.0, 1.0);
		c = mix(c, g * ao, glass);
	}
	finalColor = vec4(tonemap(aerial(c, v_world)), 1.0);
}
`

// The sky: drawn over the whole screen before the 3D pass, the ray of each pixel from the camera's axes.
STREET_SKY_FS ::
	`#version 330
in vec2 fragTexCoord;
in vec4 fragColor;
uniform vec3 cam_fwd;
uniform vec3 cam_right;
uniform vec3 cam_up;
uniform vec2 tan_half;
uniform vec2 screen;
out vec4 finalColor;
` +
	STREET_GLSL +
	`
void main() {
	vec2 ndc = gl_FragCoord.xy / screen * 2.0 - 1.0;
	vec3 r = normalize(cam_fwd + cam_right * ndc.x * tan_half.x + cam_up * ndc.y * tan_half.y);
	vec3 c = sky_col(r);
	c += sun_col * 6.0 * smoothstep(0.99985, 0.99993, dot(r, sun_dir));
	if (r.y < 0.0) c = mix(c, sky_hor * 0.9, smoothstep(0.0, -0.05, r.y));
	finalColor = vec4(tonemap(c), 1.0);
}
`

// Sky, light and the natural colors. Always a bright day (Lars, 2026-11-21: "there is only light mode").
Street_Look :: struct {
	zenith, horizon:   rl.Color, // sky; horizon is also the haze
	sun_dir:           [3]f32, // towards the sun, street space
	sun:               f32,
	sky_amb, gnd_amb:  [3]f32, // ambient light from above and below, for the car
	tone:              [3]f32, // multiplies the ground colors
	land:              rl.Color,
	areas:             [Area_Kind]rl.Color,
	asphalt, motorway: rl.Color,
	marking, river:    rl.Color,
	buildings:         Buildings_Look,
	// Linear light of the street shaders (STREET_GLSL).
	sun_col:           [3]f32,
	sky_zen, sky_hor:  [3]f32,
	amb_up, amb_down:  [3]f32,
	haze:              [2]f32, // per metre, the most it covers
}

STREET_LOOK :: Street_Look {
	zenith = {92, 138, 196, 255},
	horizon = {196, 210, 222, 255},
	sun_dir = {-0.4874, 0.7581, 0.5957}, // normalize(-0.45, 0.7, 0.55)
	sun = 1,
	sky_amb = {0.66, 0.76, 0.9},
	gnd_amb = {0.3, 0.29, 0.25},
	tone = {1, 1, 1},
	land = {80, 106, 50, 255},
	areas = {
		.City = {118, 116, 108, 255},
		.Park = {66, 100, 44, 255},
		.Farmland = {128, 130, 78, 255},
		.Marsh = {84, 104, 70, 255},
		.Beach = {206, 192, 156, 255},
		.Water = {46, 72, 90, 255},
	},
	asphalt = {66, 68, 72, 255},
	motorway = {76, 77, 80, 255},
	marking = {214, 212, 200, 255},
	river = {56, 84, 102, 255},
	buildings = {
		roof = {0.47, 0.4, 0.37},
		wall = {0.74, 0.7, 0.64},
		tree = {0.3, 0.4, 0.24},
		fog = {196.0 / 255, 210.0 / 255, 222.0 / 255},
	},
	sun_col = {2.15, 2.05, 1.85},
	sky_zen = {0.12, 0.27, 0.66},
	sky_hor = {0.62, 0.7, 0.8},
	amb_up = {0.25, 0.31, 0.42},
	amb_down = {0.1, 0.095, 0.075},
	haze = {0.00038, 0.9},
}

// Map space (x km, y km south, z km down) to street space (m, y up) around origin.
street_place :: proc(origin: [2]f32) -> Placement {
	return {axes = rl.Matrix{1000, 0, 0, 0, 0, 0, -1000, 0, 0, 1000, 0, 0, 0, 0, 0, 1}, origin = origin}
}

// The drawn ship (w.pose) in street space, in f64 so the part below the f32 resolution of pos counts.
street_ship_pos :: proc(w: ^World) -> [3]f32 {
	p := w.pose
	o := w.street.origin
	km := [2]f32{f32(p.pos.x), f32(p.pos.y)}
	x := (p.pos.x - f64(o.x)) * 1000
	z := (p.pos.y - f64(o.y)) * 1000
	return {f32(x), max(p.alt - height_at(w, km.x, km.y), 0), f32(z)}
}

// V: on from the navigation screen (and from the plan screen, which first goes to free flight like M).
street_toggle :: proc(w: ^World) {
	st := &w.street
	if st.on {
		st.on = false
		if !w.script.on do rl.EnableCursor()
		return
	}
	if w.screen == .Plan {
		nav_stop(w)
		w.screen = .Navigate
		cam_chase(w)
	}
	st.on = true
	st.on_s = 0
	st.yaw, st.pitch, st.idle_s = 0, 0, 0
	st.seeded = false
	if !w.script.on do rl.DisableCursor()
}

// Builds the line index, the ground plane and the shader. Needs the window.
street_build :: proc(w: ^World) {
	st := &w.street
	if st.ready do return
	perm := context.allocator
	if st.road_cells == nil {
		// Map line segments per cell. Two passes: count, then fill. Each segment goes to the cell of its middle.
		counts := make([]u32, STREET_ROAD_W * STREET_ROAD_H + 1, perm)
		for pass in 0 ..< 2 {
			for l in w.m.lines {
				if Map_Kind(l.kind) == .Border do continue
				for k in l.start ..< l.start + max(l.count, 1) - 1 {
					mid := (w.m.points[k] + w.m.points[k + 1]) / 2
					x := clamp(int(mid.x / STREET_ROAD_CELL_KM), 0, STREET_ROAD_W - 1)
					y := clamp(int(mid.y / STREET_ROAD_CELL_KM), 0, STREET_ROAD_H - 1)
					c := y * STREET_ROAD_W + x
					if pass == 0 {
						counts[c + 1] += 1
					} else {
						st.road_segs[st.road_cells[c] + counts[c]] = l.kind << 24 | u32(k)
						counts[c] += 1
					}
				}
			}
			if pass == 0 {
				for c in 1 ..< len(counts) do counts[c] += counts[c - 1]
				st.road_cells = counts
				st.road_segs = make([]u32, counts[len(counts) - 1], perm)
				counts = make([]u32, STREET_ROAD_W * STREET_ROAD_H + 1, context.temp_allocator)
			}
		}
		logf(w, "street", "%d road segments in %d cells", len(st.road_segs), STREET_ROAD_W * STREET_ROAD_H)
	}
	ground: {
		// The land under everything: a quad of 9 x 9 km, drawn under the car in street space.
		R :: 4500
		pos := make([][3]f32, 6, context.temp_allocator)
		copy(pos, [][3]f32{{-R, 0, -R}, {-R, 0, R}, {R, 0, R}, {-R, 0, -R}, {R, 0, R}, {R, 0, -R}})
		st.ground = rl.Mesh {
			vertexCount   = 6,
			triangleCount = 2,
			vertices      = ([^]f32)(raw_data(pos)),
			colors        = ([^]u8)(raw_data(make([][4]u8, 6, context.temp_allocator))),
		}
		rl.UploadMesh(&st.ground, true)
		st.ground.vertices, st.ground.colors = nil, nil
	}
	sh := rl.LoadShaderFromMemory(STREET_GROUND_VS, STREET_GROUND_FS)
	if !rl.IsShaderValid(sh) do logf(w, "street", "ground shader did not compile")
	st.material = rl.LoadMaterialDefault()
	st.material.shader = sh
	st.loc = {
		layer       = rl.GetShaderLocation(sh, "layer"),
		remap       = rl.GetShaderLocation(sh, "remap"),
		map_colors  = rl.GetShaderLocation(sh, "map_colors"),
		real_colors = rl.GetShaderLocation(sh, "real_colors"),
		origin      = rl.GetShaderLocation(sh, "origin"),
		cities      = rl.GetShaderLocation(sh, "cities"),
		light       = street_light_locs(sh),
	}
	lit := rl.LoadShaderFromMemory(STREET_VS, STREET_FS)
	if !rl.IsShaderValid(lit) do logf(w, "street", "lit shader did not compile")
	st.lit = rl.LoadMaterialDefault()
	st.lit.shader = lit
	st.lit_loc = street_light_locs(lit)
	st.sky = rl.LoadShaderFromMemory(nil, STREET_SKY_FS)
	if !rl.IsShaderValid(st.sky) do logf(w, "street", "sky shader did not compile")
	st.sky_loc = {
		fwd      = rl.GetShaderLocation(st.sky, "cam_fwd"),
		right    = rl.GetShaderLocation(st.sky, "cam_right"),
		up       = rl.GetShaderLocation(st.sky, "cam_up"),
		tan_half = rl.GetShaderLocation(st.sky, "tan_half"),
		screen   = rl.GetShaderLocation(st.sky, "screen"),
		light    = street_light_locs(st.sky),
	}
	st.ready = true
}

street_unload :: proc(st: ^Street) {
	tiles_unload(&st.roads)
	tiles_unload(&st.houses)
	if !st.ready do return
	rl.UnloadMesh(st.ground)
	rl.UnloadShader(st.material.shader)
	rl.UnloadShader(st.lit.shader)
	rl.UnloadShader(st.sky)
	st.ready = false
}

// Road ribbons of one tile at their real width, the river beds, and the lane markings (Tile_Build), relative
// to lo.
street_road_tile :: proc(w: ^World, lo, hi: [2]f32) -> rl.Mesh {
	st := &w.street
	look := STREET_LOOK
	pos := make([dynamic][3]f32, 0, 1 << 14, context.temp_allocator)
	col := make([dynamic][4]u8, 0, 1 << 14, context.temp_allocator)
	quad :: proc(
		pos: ^[dynamic][3]f32,
		col: ^[dynamic][4]u8,
		a, b: [2]f32,
		hw: f32,
		c: rl.Color,
		layer: u8,
	) {
		d := b - a
		l := linalg.length(d)
		if l <= 0 do return
		d /= l
		n := [2]f32{-d.y, d.x} * hw
		// Counter-clockwise on the map, like the other ground meshes.
		p0, p1, p2, p3 := a - n, a + n, b + n, b - n
		append(pos, [3]f32{p0.x, p0.y, 0}, [3]f32{p1.x, p1.y, 0}, [3]f32{p2.x, p2.y, 0})
		append(pos, [3]f32{p0.x, p0.y, 0}, [3]f32{p2.x, p2.y, 0}, [3]f32{p3.x, p3.y, 0})
		v := [4]u8{c.r, c.g, c.b, 255 - layer * 64}
		append(col, v, v, v, v, v, v)
	}
	cx := clamp(int(lo.x / STREET_ROAD_CELL_KM), 0, STREET_ROAD_W - 1)
	cy := clamp(int(lo.y / STREET_ROAD_CELL_KM), 0, STREET_ROAD_H - 1)
	c := cy * STREET_ROAD_W + cx
	for item in st.road_segs[st.road_cells[c]:st.road_cells[c + 1]] {
		k := int(item & 0xffffff)
		kind := Map_Kind(item >> 24)
		a, b := w.m.points[k], w.m.points[k + 1]
		mid := (a + b) / 2
		if mid.x < lo.x || mid.y < lo.y || mid.x >= hi.x || mid.y >= hi.y do continue
		a, b = a - lo, b - lo
		// Half widths in m: OSM draws a motorway carriageway, the others both directions on one line.
		hw: f32
		lanes := 0
		color := look.asphalt
		layer: u8 = 2
		#partial switch kind {
		case .Motorway:
			hw, lanes, color = 6.5, 3, look.motorway
		case .Trunk:
			hw, lanes = 5.5, 2
		case .Primary:
			hw, lanes = 4.5, 2
		case .Secondary:
			hw, lanes = 3.8, 2
		case .Tertiary:
			hw, lanes = 3.0, 2
		case .River:
			hw, color, layer = 14, look.river, 1
		case:
			continue
		}
		d := b - a
		l := linalg.length(d)
		if l <= 0 do continue
		dir := d / l
		// Longer by half a width at both ends, so the joints between segments are covered.
		ext := dir * hw / 1000
		quad(&pos, &col, a - ext, b + ext, hw / 1000, color, layer)
		if lanes == 0 do continue
		// Markings: dashed lines between the lanes (3 m dash, 9 m gap), solid edge lines on the motorway.
		side := [2]f32{-dir.y, dir.x}
		length_m := l * 1000
		for lane in 1 ..< lanes {
			off := (f32(lane) / f32(lanes) * 2 - 1) * (hw - 0.4) / 1000
			for s: f32 = 0; s + 3 < length_m; s += 12 {
				p := a + side * off + dir * (s / 1000)
				quad(&pos, &col, p, p + dir * 0.003, 0.00007, look.marking, 3)
			}
		}
		if kind == .Motorway {
			for edge in ([2]f32{-1, 1}) {
				off := side * edge * (hw - 0.5) / 1000
				quad(&pos, &col, a + off, b + off, 0.0001, look.marking, 3)
			}
		}
	}
	return tile_mesh(pos[:], col[:])
}

// Once per frame while on: looking around, the chase camera and the raylib camera. Drawing only, frame time is
// fine.
street_camera :: proc(w: ^World) {
	st := &w.street
	dt := frame_time(w)
	st.on_s += dt
	s := &w.ship

	// The origin follows the car in steps; the eased camera moves with it.
	origin :=
		linalg.floor([2]f32{f32(w.pose.pos.x), f32(w.pose.pos.y)} / STREET_ORIGIN_KM) * STREET_ORIGIN_KM
	if origin != st.origin {
		shift := (st.origin - origin) * 1000
		st.eye += {shift.x, 0, shift.y}
		st.origin = origin
	}

	look := mouse_delta(w) * STREET_MOUSE_RAD_PER_PX
	if !w.script.on && rl.IsGamepadAvailable(0) {
		look.x += stick_axis(rl.GetGamepadAxisMovement(0, .RIGHT_X)) * STREET_STICK_RAD_PER_S * dt
	}
	if look != {} {
		st.yaw += look.x
		st.pitch = clamp(st.pitch + look.y, -0.45, 1.2)
		st.idle_s = 0
	} else {
		st.idle_s += dt
	}
	if st.idle_s > STREET_RECENTRE_S {
		k := 1 - math.exp(-dt * 2.5)
		st.yaw = angle_lerp(st.yaw, 0, k)
		st.pitch += (0 - st.pitch) * k
	}
	if wheel := mouse_wheel(w); wheel != 0 {
		if st.dist == 0 do st.dist = STREET_CAM_DIST_M
		st.dist = clamp(st.dist * (1 - wheel * 0.12), STREET_CAM_MIN_M, STREET_CAM_MAX_M)
	}
	dist := st.dist == 0 ? STREET_CAM_DIST_M : st.dist

	car := street_ship_pos(w)
	target := car + {0, STREET_CAM_LOOK_UP_M, 0}
	yaw := w.car_anim.heading + st.yaw
	pitch := STREET_CAM_PITCH + st.pitch
	back := [3]f32{-math.sin(yaw) * math.cos(pitch), math.sin(pitch), math.cos(yaw) * math.cos(pitch)}
	goal := target + back * dist
	if !st.seeded {
		st.eye = goal
		st.seeded = true
	}
	st.eye += (goal - st.eye) * (1 - math.exp(-dt * STREET_CAM_RATE))
	// Never further than 1.6 x the distance from the car, however fast it goes.
	if off := st.eye - target; linalg.length(off) > dist * 1.6 do st.eye = target + linalg.normalize(off) * dist * 1.6

	// Walls between the car and the camera pull the camera in, it stays above the ground.
	{
		off := st.eye - target
		l := linalg.length(off)
		steps := int(l / 0.5)
		for i in 1 ..= steps {
			p := target + off * (f32(i) / f32(steps))
			km := st.origin + {p.x, p.z} / 1000
			push, _ := collide_car(w, km, p.y, STREET_CAM_WALL_M)
			if push != {} {
				st.eye = target + off * (f32(max(i - 1, 0)) / f32(steps))
				break
			}
		}
		st.eye.y = max(st.eye.y, 0.5)
	}

	// A short shake after a hit, nothing at rest.
	shake: [3]f32
	if s.free && s.hit_s < 0.35 {
		a := (0.35 - s.hit_s) * 0.25
		t := st.on_s * 60
		shake = {math.sin(t * 1.7), math.sin(t * 2.3), math.sin(t * 1.3)} * a
	}
	speed := clamp(s.speed / SHIP_MAX_SPEED, 0, 1)
	st.view = rl.Camera3D {
		position   = st.eye + shake,
		target     = target + shake,
		up         = {0, 1, 0},
		fovy       = STREET_FOV + STREET_FOV_FAST * speed * speed,
		projection = .PERSPECTIVE,
	}
}

// The whole street view frame: sky, ground, roads, buildings, trees, the cars, then the HUD.
street_draw :: proc(w: ^World) {
	st := &w.street
	street_build(w)
	street_camera(w)
	look := STREET_LOOK
	screen := [2]f32{f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())}
	place := street_place(st.origin)
	centre := [2]f32{f32(w.pose.pos.x), f32(w.pose.pos.y)}

	// Sky: every pixel's ray from the camera's axes (STREET_SKY_FS).
	{
		rl.ClearBackground(look.horizon)
		sh := st.sky
		fwd := linalg.normalize(st.view.target - st.view.position)
		right := linalg.normalize(linalg.cross(fwd, [3]f32{0, 1, 0}))
		up := linalg.cross(right, fwd)
		th := math.tan(st.view.fovy * math.PI / 360)
		render := [2]f32{f32(rl.GetRenderWidth()), f32(rl.GetRenderHeight())}
		tan_half := [2]f32{th * render.x / render.y, th}
		rl.SetShaderValue(sh, st.sky_loc.fwd, &fwd, .VEC3)
		rl.SetShaderValue(sh, st.sky_loc.right, &right, .VEC3)
		rl.SetShaderValue(sh, st.sky_loc.up, &up, .VEC3)
		rl.SetShaderValue(sh, st.sky_loc.tan_half, &tan_half, .VEC2)
		rl.SetShaderValue(sh, st.sky_loc.screen, &render, .VEC2)
		street_light_set(sh, st.sky_loc.light, st.view.position)
		rl.BeginShaderMode(sh)
		rl.DrawRectangle(0, 0, i32(screen.x), i32(screen.y), rl.WHITE)
		rl.EndShaderMode()
	}

	near, far := rlgl.GetCullDistanceNear(), rlgl.GetCullDistanceFar()
	rlgl.SetClipPlanes(STREET_NEAR_M, STREET_FAR_M)
	defer rlgl.SetClipPlanes(near, far)
	rl.BeginMode3D(st.view)
	{
		sh := st.material.shader
		origin := st.origin * 1000
		rl.SetShaderValue(sh, st.loc.origin, &origin, .VEC2)
		street_light_set(sh, st.loc.light, st.view.position)
		cities: [16][3]f32
		for i in 0 ..< min(w.buildings.count, 16) {
			d := (w.buildings.origins[i] - st.origin) * 1000
			cities[i] = {d.x, d.y, BUILDINGS_RADIUS_KM * 1000}
		}
		rl.SetShaderValueV(sh, st.loc.cities, &cities, .VEC3, 16)

		// 1: land, a quad kept under the car.
		layer, remap: f32 = 0, 0
		rl.SetShaderValue(sh, st.loc.layer, &layer, .FLOAT)
		rl.SetShaderValue(sh, st.loc.remap, &remap, .FLOAT)
		mat := st.material
		{
			land: [6][4]u8
			for &c in land do c = {look.land.r, look.land.g, look.land.b, 255}
			rl.UpdateMeshBuffer(st.ground, 3, &land[0], size_of(land), 0)
			car := street_ship_pos(w)
			rl.DrawMesh(st.ground, mat, rl.Matrix(linalg.matrix4_translate_f32({car.x, 0, car.z})))
		}

		// 2: land use with natural colors.
		lm := &w.line_meshes
		if lm.areas.vertexCount > 0 {
			pal := palette(w)
			map_colors := [6][3]f32 {
				rl.ColorNormalize(pal.city).rgb,
				rl.ColorNormalize(pal.park).rgb,
				rl.ColorNormalize(pal.farmland).rgb,
				rl.ColorNormalize(pal.marsh).rgb,
				rl.ColorNormalize(pal.beach).rgb,
				rl.ColorNormalize(pal.water).rgb,
			}
			real_colors: [6][3]f32
			for k in Area_Kind do real_colors[int(k)] = rl.ColorNormalize(look.areas[k]).rgb
			layer, remap = 1, 1
			rl.SetShaderValue(sh, st.loc.layer, &layer, .FLOAT)
			rl.SetShaderValue(sh, st.loc.remap, &remap, .FLOAT)
			rl.SetShaderValueV(sh, st.loc.map_colors, &map_colors, .VEC3, 6)
			rl.SetShaderValueV(sh, st.loc.real_colors, &real_colors, .VEC3, 6)
			// One mesh in km for the whole map: x and z land within ~1.5 cm, the depth is layered (see the shader).
			rl.DrawMesh(lm.areas, mat, place_at(place, {}))
		}

		// 3: rivers, roads and markings (layers 2, 3, 4).
		layer, remap = 1, 0
		rl.SetShaderValue(sh, st.loc.layer, &layer, .FLOAT)
		rl.SetShaderValue(sh, st.loc.remap, &remap, .FLOAT)
		tiles_update_draw(
			w,
			&st.roads,
			STREET_ROAD_TILE_KM,
			STREET_REACH_KM,
			street_road_tile,
			mat,
			centre,
			place,
		)
	}

	// 4: the houses (real and generated, lit, with facades and roofs), then the trees (the map's clumps for now:
	// buildings_draw with no reach only sets their shader's uniforms).
	street_light_set(st.lit.shader, st.lit_loc, st.view.position)
	tiles_update_draw(w, &st.houses, HOUSE_TILE_KM, HOUSE_REACH_KM, houses_build_tile, st.lit, centre, place)
	buildings_draw(w, STREET_FOG_M, 1 / BUILDINGS_HEIGHT_X, centre, -1, place, look.buildings)
	nature_draw(w, centre, STREET_REACH_KM, place)

	// 5: the cars, each with a soft contact shadow.
	car_anim_update(w, frame_time(w))
	{
		car := street_ship_pos(w)
		street_shadow(car, w.car_anim.heading)
		car_draw_street(w, car, w.car_anim, rl.WHITE, look)
		for o in w.others[:w.other_count] {
			p := others_draw_pos(w, o)
			d := (p - st.origin) * 1000
			if linalg.length(d - car.xz) > STREET_REACH_KM * 1000 do continue
			pos := [3]f32{d.x, max(o.alt - height_at(w, p.x, p.y), 0), d.y}
			an := Car_Anim {
				fly     = o.on_road ? 0 : 1,
				heading = o.heading,
			}
			jam := traffic_near(w, o.pos, o.alt, o.on_road, TRAFFIC_RADIUS_KM) >= TRAFFIC_MIN_CARS
			street_shadow(pos, o.heading)
			car_draw_street(w, pos, an, jam ? CAR_JAM_TINT : CAR_OTHER_TINT, look)
		}
	}
	rl.EndMode3D()

	street_hud(w)
}

// A soft dark patch on the ground under a car, fainter the higher it is.
street_shadow :: proc(car: [3]f32, heading: f32) {
	f := 1 - clamp(car.y / 30, 0, 1)
	if f <= 0 do return
	fwd := [3]f32{math.sin(heading), 0, -math.cos(heading)}
	side := [3]f32{-fwd.z, 0, fwd.x}
	base := [3]f32{car.x, 0.03, car.z}
	SEGMENTS :: 20
	for ring in 0 ..< 3 {
		g := 1 - f32(ring) * 0.22
		a := u8(38 * f)
		for i in 0 ..< SEGMENTS {
			t0 := f32(i) / SEGMENTS * math.TAU
			t1 := f32(i + 1) / SEGMENTS * math.TAU
			p0 := base + (fwd * math.cos(t0) * 2.5 + side * math.sin(t0) * 1.1) * g
			p1 := base + (fwd * math.cos(t1) * 2.5 + side * math.sin(t1) * 1.1) * g
			rl.DrawTriangle3D(base, p1, p0, {0, 0, 0, a})
		}
	}
}

// Speed, height and heading bottom left, the keys for a few seconds after switching on. Plain, small, legible.
street_hud :: proc(w: ^World) {
	s := &w.ship
	pal := palette(w)
	screen := [2]f32{f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())}
	speed := fmt.tprintf("%d", int(math.round(s.speed * 3.6)))
	height := fmt.tprintf("%d m", int(math.round(max(s.alt - height_at(w, s.pos.x, s.pos.y), 0))))
	compass := [8]string{"N", "NE", "E", "SE", "S", "SW", "W", "NW"}
	// The heading can be negative (ship_step keeps the sign of math.mod), so wrap the index both ways.
	heading := compass[(int(math.round(s.heading / (math.TAU / 8))) % 8 + 8) % 8]

	PAD :: 24
	box := rl.Rectangle{PAD, screen.y - PAD - 92, 210, 92}
	round_rect(box, 14, rl.ColorAlpha(pal.surface, 0.72))
	size := ui_text_size(w, speed, .Figtree_700, 40)
	ui_text(w, {box.x + 18, box.y + 12}, speed, .Figtree_700, 40, pal.text)
	ui_text(w, {box.x + 22 + size.x, box.y + 32}, "km/h", .Roboto_500, 14, pal.text_2)
	ui_text(w, {box.x + 18, box.y + 62}, height, .Roboto_500, 14, pal.text_2)
	ui_text(w, {box.x + 110, box.y + 62}, heading, .Roboto_500, 14, pal.text_2)
	if w.nav.active && !w.nav.manual {
		ui_text(w, {box.x + 150, box.y + 62}, "auto", .Roboto_500, 14, pal.accent)
	}

	if w.street.on_s < STREET_HINT_S {
		alpha := 1 - clamp((w.street.on_s - (STREET_HINT_S - 1)) / 1, 0, 1)
		HINT :: "W/S throttle and brake   A/D turn   Space/Shift up and down   Mouse look around   V or Esc map"
		hint := ui_text_size(w, HINT, .Roboto_500, 14)
		r := rl.Rectangle{(screen.x - hint.x) / 2 - 14, PAD, hint.x + 28, hint.y + 16}
		round_rect(r, 10, rl.ColorAlpha(pal.surface, 0.72 * alpha))
		ui_text(w, {r.x + 14, r.y + 8}, HINT, .Roboto_500, 14, rl.ColorAlpha(pal.text, alpha))
	}
}
