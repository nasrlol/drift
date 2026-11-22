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
// the buildings stand on the map.
//
// How far the street view reaches (Lars, 2026-11-21: "kleinere wereld, want nu kan je te ver kijken waardoor het
// heel zwaar wordt"): houses, roads, trees and the other cars are built and drawn within STREET_VIEW_KM, the far
// plane sits just beyond, and the world is round (STREET_BEND_GLSL) so its end lies behind the horizon. The
// curvature follows the eye height h: R = (view / (sqrt(h + 1) + sqrt(STREET_CURVE_TALL_M)))^2 / 2 hides things
// up to that height at the edge of the view; low over a street R is ~25 km (the ground's horizon ~450 m away),
// high up it becomes a small planet.
STREET_VIEW_KM :: 1.6
STREET_CURVE_TALL_M :: 25.0
STREET_ORIGIN_KM :: 0.25
// raylib's own near plane of 0.05 m leaves one step of the 24 bit depth buffer ~0.3 m deep at 500 m and ~1.2 m at
// 1 km, so walls a little apart z-fought in the distance. 0.25 m is five times sharper; the camera keeps
// STREET_CAM_WALL_M from walls so the near plane never cuts one.
STREET_NEAR_M :: 0.25
STREET_FAR_M :: STREET_VIEW_KM * 1000 + 300
STREET_CAM_WALL_M :: 0.6
STREET_REACH_KM :: STREET_VIEW_KM
STREET_CAM_DIST_M :: 8.5
STREET_CAM_MIN_M :: 4.0
STREET_CAM_MAX_M :: 40.0 // zoomed out past this the map takes over (street_wants_map)
// While flying, the car's height over the ground picks the view (Lars, 2026-11-22: "minder als 300 m, je moet
// maar een beetje hoger of lager gaan en dan switch je naar de volgende mode"): below STREET_LOW_M the street
// view, above STREET_HIGH_M the map. The tower tops (HUB_TOWER_M) lie below, so take-off and landing are in 3D.
STREET_LOW_M :: 80.0
STREET_HIGH_M :: 120.0
STREET_CAM_LOOK_UP_M :: 1.6 // the camera looks at this point above the car
STREET_CAM_PITCH :: 0.16 // radians down at rest
STREET_CAM_HORIZON :: 0.05 // radians: high up, the horizon stays this far above the middle of the view at rest
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
// The round world bends per vertex (STREET_BEND_GLSL), so the ground is cut fine enough that its straight edges
// stay within a few cm of the curve near the camera: the land is a disc of STREET_LAND_RINGS x STREET_LAND_SEGS
// cells kept under the car, the land use is clipped per STREET_AREA_TILE_KM tile to a grid of
// STREET_GROUND_STEP_KM squares (neighbours are cut at the same points, so no cracks open between them), and
// road ribbons are cut into pieces of at most STREET_ROAD_PIECE_M.
STREET_LAND_RINGS :: 40
STREET_LAND_SEGS :: 128
STREET_AREA_TILE_KM :: 1.0
STREET_AREA_W :: int(MAP_W_KM / STREET_AREA_TILE_KM) + 1
STREET_AREA_H :: int(MAP_H_KM / STREET_AREA_TILE_KM) + 1
STREET_GROUND_STEP_KM :: 0.08
STREET_ROAD_PIECE_M :: 40.0
// Sun shadows (Lars, 2026-11-21: shadows come off the NOT DOING list for the street view): one depth map of
// SHADOW_SIZE^2 texels over a SHADOW_BOX_M square on the ground ahead of the camera, drawn from the sun with an
// orthographic camera that moves in whole texels (in f64 world metres), so the edges do not crawl while flying.
// Houses, trees and cars cast; houses and the ground receive; beyond the box there is no shadow (faded over its
// edge). The light camera stands SHADOW_LIGHT_M up the sun direction, clip planes 1 .. 2 x that.
SHADOW_SIZE :: 2048
SHADOW_BOX_M :: 420.0
SHADOW_LIGHT_M :: 1500.0
SHADOW_SLOT :: 14

Street_Edit :: struct {
	shadows:       bool,
	shadow_box_m:  f32,
	cam_dist_m:    f32,
	cam_look_up_m: f32,
	cam_pitch_deg: f32,
	cam_rate:      f32,
	fov:           f32,
	fov_fast:      f32,
	curve_tall_m:  f32,
	haze_per_km:   f32,
	haze_max:      f32,
	switch_low_m:  f32,
	switch_high_m: f32,
}

street_edit_defaults :: proc() -> Street_Edit {
	return {
		shadows = true,
		shadow_box_m = SHADOW_BOX_M,
		cam_dist_m = STREET_CAM_DIST_M,
		cam_look_up_m = STREET_CAM_LOOK_UP_M,
		cam_pitch_deg = STREET_CAM_PITCH * math.DEG_PER_RAD,
		cam_rate = STREET_CAM_RATE,
		fov = STREET_FOV,
		fov_fast = STREET_FOV_FAST,
		curve_tall_m = STREET_CURVE_TALL_M,
		haze_per_km = STREET_LOOK.haze.x * 1000,
		haze_max = STREET_LOOK.haze.y,
		switch_low_m = STREET_LOW_M,
		switch_high_m = STREET_HIGH_M,
	}
}
Street :: struct {
	on:         bool,
	yaw, pitch: f32, // the player's look-around on top of the chase direction, radians
	dist:       f32, // zero = STREET_CAM_DIST_M
	idle_s:     f32, // seconds since the player last looked around
	on_s:       f32, // seconds in the street view this run, all visits (the key hint shows in the first)
	origin:     [2]f32, // km
	eye:        [3]f32, // the camera, street space, eased
	seeded:     bool,
	// The view was picked by hand (zoom, Esc) against the height band: the band waits until the car has been on
	// the side that agrees with it (below STREET_LOW_M in the street view, above STREET_HIGH_M on the map).
	hold:       bool,
	view:       rl.Camera3D,
	// Road ribbons per STREET_ROAD_TILE_KM tile. road_segs lists, per STREET_ROAD_CELL_KM cell, the map line
	// segments it holds: kind << 24 | index of the segment's first point (road_cells has the offsets).
	roads:      Tile_Cache,
	road_cells: []u32,
	road_segs:  []u32,
	road_s:     []f32, // metres along its line at each map point, modulo 1200 (a whole number of dash periods)
	road:       rl.Material, // STREET_ROAD_VS / FS
	// Land use per STREET_AREA_TILE_KM tile. area_items lists, per tile of the map, the land use triangles that
	// reach into it: kind << 28 | index of the first point in w.m.area_points (area_cells has the offsets).
	areas:      Tile_Cache,
	area_cells: []u32,
	area_items: []u32,
	road_loc:   struct {
		layer: i32,
		light: Street_Light_Locs,
	},
	// The ground plane, the land use triangles and the roads share one shader.
	ground:     rl.Mesh,
	material:   rl.Material,
	loc:        struct {
		layer, remap, map_colors, real_colors, origin, cities: i32,
		grass_size, grass_amt, grass_tone, rural_fields:       i32,
		light:                                                 Street_Light_Locs,
	},
	// The houses (houses.odin) with the lit shader, and the sky.
	houses:     Tile_Cache,
	lit:        rl.Material,
	car:        rl.Material, // STREET_CAR_VS / FS
	car_loc:    Street_Light_Locs,
	lit_loc:    Street_Light_Locs,
	sky:        rl.Shader,
	sky_loc:    struct {
		fwd, right, up, tan_half, screen, clouds: i32,
		light:                                    Street_Light_Locs,
	},
	// The shadow map: a framebuffer with only a depth texture (rlgl ids), the depth-only material, and the
	// light's view-projection of this frame.
	trees:      Trees, // trees.odin
	solarpunk:  Solarpunk, // solarpunk.odin
	shadow_fbo: u32,
	shadow_tex: u32,
	depth:      rl.Material,
	light_vp:   rl.Matrix,
	post:       Post, // post.odin
	up_vs:      [3]f32, // world up in view space this frame, for the AO
	// The round world of this frame: 1 / 2R and the view-projection of the up axis (STREET_BEND_GLSL).
	bend:       f32,
	vp_up:      [4]f32,
	ready:      bool,
}

// Last light uniforms sent to one shader (skip unchanged uploads on idle / steady frames).
Street_Light_Cache :: struct {
	valid:     bool,
	light_vp:  rl.Matrix,
	slot:      i32,
	shadow_on: f32,
	sun_dir:   [3]f32,
	sun_col:   [3]f32,
	sky_zen:   [3]f32,
	sky_hor:   [3]f32,
	sky_curve: f32,
	sky_glow:  f32,
	amb_sky:   [3]f32,
	amb_gnd:   [3]f32,
	cam:       [3]f32,
	haze:      [2]f32,
	bend:      f32,
	vp_up:     [4]f32,
	direct:    f32,
}

// Uniform locations of STREET_GLSL in one shader.
Street_Light_Locs :: struct {
	sun_dir,
	sun_col,
	sky_zen,
	sky_hor,
	sky_curve,
	sky_glow,
	amb_sky,
	amb_gnd,
	cam,
	haze,
	light_vp,
	shadow_map,
	shadow_on,
	bend,
	vp_up,
	direct: i32,
	cache:                                                                                                                                      Street_Light_Cache,
}

street_light_locs :: proc(sh: rl.Shader) -> Street_Light_Locs {
	return {
		sun_dir = rl.GetShaderLocation(sh, "sun_dir"),
		sun_col = rl.GetShaderLocation(sh, "sun_col"),
		sky_zen = rl.GetShaderLocation(sh, "sky_zen"),
		sky_hor = rl.GetShaderLocation(sh, "sky_hor"),
		sky_curve = rl.GetShaderLocation(sh, "sky_curve"),
		sky_glow = rl.GetShaderLocation(sh, "sky_glow"),
		amb_sky = rl.GetShaderLocation(sh, "amb_sky"),
		amb_gnd = rl.GetShaderLocation(sh, "amb_gnd"),
		cam = rl.GetShaderLocation(sh, "cam"),
		haze = rl.GetShaderLocation(sh, "haze"),
		bend = rl.GetShaderLocation(sh, "bend"),
		vp_up = rl.GetShaderLocation(sh, "vp_up"),
		direct = rl.GetShaderLocation(sh, "direct"),
		light_vp = rl.GetShaderLocation(sh, "light_vp"),
		shadow_map = rl.GetShaderLocation(sh, "shadow_map"),
		shadow_on = rl.GetShaderLocation(sh, "shadow_on"),
	}
}

street_light_set :: proc(w: ^World, sh: rl.Shader, l: ^Street_Light_Locs, cam: [3]f32) {
	look := street_look(w)
	c := &l.cache
	force := !c.valid
	slot := i32(SHADOW_SLOT)
	on: f32 = w.street.shadow_tex != 0 && w.street_edit.shadows ? 1 : 0
	direct: f32 = w.street.post.hdr.id == 0 ? 1 : 0
	shader_set_mat(sh, l.light_vp, &c.light_vp, w.street.light_vp, force)
	shader_set(sh, l.shadow_map, &c.slot, slot, .INT, force)
	shader_set(sh, l.shadow_on, &c.shadow_on, on, .FLOAT, force)
	shader_set(sh, l.sun_dir, &c.sun_dir, look.sun_dir, .VEC3, force)
	shader_set(sh, l.sun_col, &c.sun_col, look.sun_col, .VEC3, force)
	shader_set(sh, l.sky_zen, &c.sky_zen, look.sky_zen, .VEC3, force)
	shader_set(sh, l.sky_hor, &c.sky_hor, look.sky_hor, .VEC3, force)
	shader_set(sh, l.sky_curve, &c.sky_curve, look.sky_curve, .FLOAT, force)
	shader_set(sh, l.sky_glow, &c.sky_glow, look.sky_glow, .FLOAT, force)
	shader_set(sh, l.amb_sky, &c.amb_sky, look.amb_up, .VEC3, force)
	shader_set(sh, l.amb_gnd, &c.amb_gnd, look.amb_down, .VEC3, force)
	shader_set(sh, l.cam, &c.cam, cam, .VEC3, force)
	shader_set(sh, l.haze, &c.haze, look.haze, .VEC2, force)
	shader_set(sh, l.bend, &c.bend, w.street.bend, .FLOAT, force)
	shader_set(sh, l.vp_up, &c.vp_up, w.street.vp_up, .VEC4, force)
	shader_set(sh, l.direct, &c.direct, direct, .FLOAT, force)
	c.valid = true
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
uniform float sky_curve;
uniform float sky_glow;
uniform vec3 amb_sky;
uniform vec3 amb_gnd;
uniform vec3 cam;
uniform vec2 haze;
uniform float bend;
uniform float direct;
uniform mat4 light_vp;
uniform sampler2D shadow_map;
uniform float shadow_on;
// 1 in sunlight, 0 in the shadow of what the shadow pass drew: a 3 x 3 texel filter with bilinear weights (4 x 4
// samples), so edges are soft instead of stair steps near the camera; it fades out at the box edge.
float sun_shadow(vec3 p, vec3 n) {
	if (shadow_on < 0.5) return 1.0;
	vec4 lp = light_vp * vec4(p + n * 0.12, 1.0);
	vec3 c = lp.xyz / lp.w * 0.5 + 0.5;
	vec2 edge = min(c.xy, 1.0 - c.xy);
	float fade = smoothstep(0.0, 0.08, min(edge.x, edge.y));
	if (fade <= 0.0 || c.z >= 1.0) return 1.0;
	float texel = 1.0 / float(textureSize(shadow_map, 0).x);
	vec2 t = c.xy / texel - 0.5;
	vec2 b = floor(t), f = t - b;
	float lit = 0.0;
	for (int y = -1; y <= 2; y++) {
		for (int x = -1; x <= 2; x++) {
			float d = texture(shadow_map, (b + vec2(float(x), float(y)) + 0.5) * texel).r;
			float wx = x == -1 ? 1.0 - f.x : (x == 2 ? f.x : 1.0);
			float wy = y == -1 ? 1.0 - f.y : (y == 2 ? f.y : 1.0);
			lit += (c.z - 0.00003 > d ? 0.0 : 1.0) * wx * wy;
		}
	}
	return mix(1.0, lit / 9.0, fade);
}
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
	vec3 c = mix(sky_hor, sky_zen, pow(e, sky_curve));
	c += sky_hor * sky_glow * pow(1.0 - e, 12.0);
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
// What a smooth surface mirrors in direction r (Lars, 2026-11-22: "realistischer, zoals GTA 6"): the sky above
// a band of town along the horizon (a skyline that depends only on the direction, so neighbouring windows see
// the same street across), the sunlit ground below. rough blurs it towards the average of its half of the sky.
vec3 env_col(vec3 r, float rough) {
	float az = atan(r.z, r.x);
	float line = 0.03 + 0.2 * vnoise(vec2(az * 9.0, 3.0)) + 0.1 * vnoise(vec2(az * 31.0, 7.0));
	vec3 town = mix(amb_sky * 0.45, vec3(0.2, 0.13, 0.09), vnoise(vec2(az * 23.0, 1.0)) * 0.6);
	town += sun_col * 0.05 * (0.5 + vnoise(vec2(az * 70.0, floor(r.y * 50.0))));
	vec3 below = amb_gnd * 0.7 + sun_col * 0.04;
	vec3 c = mix(town, sky_col(r), smoothstep(line - 0.015, line + 0.015, r.y));
	c = mix(c, below, smoothstep(0.0, -0.15, r.y));
	return mix(c, mix(below, amb_sky * 1.3, clamp(r.y * 0.5 + 0.5, 0.0, 1.0)), rough * rough);
}
// The sun's highlight (GGX with Smith shadowing, times n.l; F multiplies it outside).
float ggx(vec3 n, vec3 v, vec3 l, float rough) {
	float nl = max(dot(n, l), 0.0);
	if (nl <= 0.0) return 0.0;
	float nv = max(dot(n, v), 1e-3);
	float a = max(rough * rough, 0.003);
	float nh = max(dot(n, normalize(v + l)), 0.0);
	float d = nh * nh * (a * a - 1.0) + 1.0;
	float k = a * 0.5;
	return a * a / (3.14159 * d * d) * nl / (nl * (1.0 - k) + k) / (nv * (1.0 - k) + k) * 0.25;
}
float fresnel(float f0, vec3 n, vec3 v) { return f0 + (1.0 - f0) * pow(1.0 - max(dot(n, v), 0.0), 5.0); }
// Fresnel of a rough surface: grazing angles do not turn a rough wall into a mirror (Lagarde).
float fresnel_r(float f0, vec3 n, vec3 v, float rough) {
	return f0 + (max(1.0 - rough, f0) - f0) * pow(1.0 - max(dot(n, v), 0.0), 5.0);
}
// Behind the horizon of the round world (STREET_BEND_GLSL): from eye height h a point y m up at d m is hidden
// once d * sqrt(bend) > sqrt(h) + sqrt(y), the tangent to the bent ground passes over it.
bool behind_horizon(vec3 p) {
	return length(p.xz - cam.xz) * sqrt(bend) > sqrt(max(cam.y, 0.0)) + sqrt(max(p.y, 0.0));
}
// The scene draws linear light into post.odin's float target, which tonemaps it; without that target (direct)
// straight to the screen with the same ACES curve.
vec3 hdr_out(vec3 c) {
	if (direct < 0.5) return c;
	c = clamp((c * (2.51 * c + 0.03)) / (c * (2.43 * c + 0.59) + 0.14), 0.0, 1.0);
	return sqrt(c);
}
float box(float x, float h, float w) { return clamp((h - abs(x)) / max(w, 1e-4) + 0.5, 0.0, 1.0); }
// Value noise of f cycles per metre, faded to its mean where a cycle covers less than ~3 pixels (fw: metres per
// pixel), so fine texture never sparkles in the distance.
float fnoise(vec2 p, float f, float fw) { return mix(0.5, vnoise(p * f), 1.0 - smoothstep(0.15, 0.4, fw * f)); }
// The contrast of a feature wd metres wide: full while it is over ~1.5 pixels, gone below ~0.6.
float thin(float wd, float fw) { return 1.0 - smoothstep(wd * 0.6, wd * 1.6, fw); }
`

// Ground shader: vertex colours, land use colours swapped from the map design to natural ones (remap), noise in
// world space so large surfaces are not flat paint, lit by the sun, the haze of STREET_GLSL.
// The ground layers (land, land use, rivers, roads, markings) all lie on y = 0, so the depth buffer cannot order
// them: meshes in km drawn with km x 1000 minus ~150 km in f32 got a depth that is off by 1e-6..3e-6 in NDC
// against the land quad (measured at 280 m), ten times any usable bias, so they lost the depth test at random.
// Nothing can stand below the ground and the camera is always above it, so the ground never hides anything:
// every ground fragment writes the far depth, minus a hair per layer (layer = layer uniform + the vertex alpha,
// alpha = 1 - layer / 4), and one hair more so the sky (the clear value 1) stays apart for post.odin's AO. A
// later layer always wins over an earlier one, a tie goes to the draw order, and everything 3D drawn after the
// ground is nearer than all of it.
// The round world (Lars, 2026-11-21, for Abdellah: "niet fog maar een ronde wereld, voor we het einde van de
// rendering zien"): every street vertex shader lowers its vertex on screen by its squared horizontal distance
// from the camera times bend (1 / 2R), so the land falls away behind a horizon before the end of STREET_VIEW_KM.
// Only the picture bends: lighting, shadows, haze and collision use the flat world. vp_up is the
// view-projection of the up axis, so the drop is a sum in clip space. The ground does not hide what lies behind
// it (its depth is layered far, see STREET_GROUND_FS), so every street fragment shader drops what the curve
// hides itself: behind_horizon in STREET_GLSL.
STREET_BEND_GLSL :: `
uniform float bend;
uniform vec4 vp_up;
uniform vec3 cam;
vec4 bent(vec4 clip, vec3 world) {
	vec2 d = world.xz - cam.xz;
	return clip - vp_up * (dot(d, d) * bend);
}
`

STREET_GROUND_VS ::
	`#version 330
in vec3 vertexPosition;
in vec4 vertexColor;
uniform mat4 mvp;
uniform mat4 matModel;
out vec4 color;
out vec3 world;
` +
	STREET_BEND_GLSL +
	`
void main() {
	color = vertexColor;
	world = (matModel * vec4(vertexPosition, 1.0)).xyz;
	gl_Position = bent(mvp * vec4(vertexPosition, 1.0), world);
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
uniform vec4 grass_size; // metres: patches, tufts, clumps, worn spots (grass_edit.odin)
uniform vec4 grass_amt; // dry patches, tufts, clumps, worn spots
uniform vec2 grass_tone; // how olive, where worn spots start
uniform vec4 rural_fields; // x mix, y size m, z solar cell share
out vec4 finalColor;
` +
	STREET_GLSL +
	`
vec2 hash22(vec2 p) { return vec2(hash12(p), hash12(p + 19.19)); }
// Perlin (gradient) noise, about -0.5 .. 0.5 (gradients from the hash, not normalised: no trigonometry), its
// lattice wrapped every per cells so it tiles.
float perlin(vec2 p, float per) {
	vec2 i = floor(p), f = fract(p);
	vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	float a = dot(hash22(mod(i, per)) - 0.5, f), b = dot(hash22(mod(i + vec2(1.0, 0.0), per)) - 0.5, f - vec2(1.0, 0.0));
	float c = dot(hash22(mod(i + vec2(0.0, 1.0), per)) - 0.5, f - vec2(0.0, 1.0)), d = dot(hash22(mod(i + 1.0, per)) - 0.5, f - 1.0);
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}
// Two octaves of Perlin noise from f cycles per metre over p (metres in 0 .. 4096, f x 4096 whole), each faded
// to its mean 0 where a cycle covers less than ~3 pixels (fw: metres per pixel), so it never sparkles.
float fbm(vec2 p, float f, float fw) {
	float s = perlin(p * f, 4096.0 * f) * (1.0 - smoothstep(0.15, 0.4, fw * f));
	return 1.1 * s + 0.55 * perlin(p * f * 2.0, 8192.0 * f) * (1.0 - smoothstep(0.15, 0.4, fw * f * 2.0));
}
// Cycles per metre for a feature of about size metres, snapped so the noise still tiles over 4096 m (fbm).
float grass_f(float size) { return max(floor(4096.0 / max(size, 0.01) + 0.5), 1.0) / 4096.0; }
// Open grass (Lars, 2026-11-22: "maak van de lege groene vlaktes ook perlin noise"): around the colour c, patches
// of lush and dry (straw) grass, tufts, clumps and a few worn spots of bare earth. Sizes and strengths are the
// grass uniforms (the Grass tab of the settings panel).
vec3 grass(vec3 c, vec2 p, float fw) {
	float patches = fbm(p, grass_f(grass_size.x), fw);
	float tufts = fbm(p + 300.0, grass_f(grass_size.y), fw), clumps = fbm(p + 900.0, grass_f(grass_size.z), fw);
	// Real grass is olive rather than paint green: part of the way to a yellow-grey of the same brightness.
	vec3 lush = mix(c, dot(c, vec3(0.3, 0.59, 0.11)) * vec3(0.95, 1.12, 0.55), grass_tone.x);
	vec3 g = mix(lush, vec3(0.13, 0.125, 0.05), smoothstep(-0.15, 0.5, patches) * grass_amt.x);
	g *= 1.0 + grass_amt.y * tufts + grass_amt.z * clumps;
	float worn = smoothstep(grass_tone.y, grass_tone.y + 0.18, fbm(p + 1700.0, grass_f(grass_size.w), fw) + 0.25 * tufts);
	return mix(g, vec3(0.1, 0.075, 0.05) * (1.0 + 0.4 * clumps), worn * grass_amt.w);
}
// The patchwork of fields: cells of about size metres around jittered points; x = the cell's hash, y = metres
// to its border.
vec2 fields(vec2 p, float size) {
	vec2 g0 = floor(p / size), f = p / size - g0;
	float md = 8.0;
	vec2 mr = vec2(0.0), mg = vec2(0.0);
	for (int j = -1; j <= 1; j++) {
		for (int i = -1; i <= 1; i++) {
			vec2 g = vec2(float(i), float(j));
			vec2 r = g + 0.15 + 0.7 * hash22(g0 + g) - f;
			float d = dot(r, r);
			if (d < md) { md = d; mr = r; mg = g; }
		}
	}
	float bd = 8.0;
	for (int j = -2; j <= 2; j++) {
		for (int i = -2; i <= 2; i++) {
			vec2 g = mg + vec2(float(i), float(j));
			vec2 r = g + 0.15 + 0.7 * hash22(g0 + g) - f;
			vec2 dd = r - mr;
			if (dot(dd, dd) > 1e-5) bd = min(bd, dot(0.5 * (mr + r), normalize(dd)));
		}
	}
	return vec2(hash12(g0 + mg), bd * size);
}
void main() {
	vec3 c = color.rgb;
	int kind = -1;
	if (remap > 0.5) {
		for (int i = 0; i < 6; i++) {
			if (distance(c, map_colors[i]) < 0.01) {
				c = real_colors[i];
				kind = i;
			}
		}
	}
	c = lin(c);
	vec2 q = world.xz + origin;
	vec2 qw = mod(q, 4096.0);
	float gw = max(length(fwidth(world.xz)), 1e-4);
	if (layer < 0.5 || kind == 1 || kind == 3) c = grass(c, qw, gw);
	if (layer < 0.5 && rural_fields.x > 0.01) {
		vec2 fd = fields(q, max(rural_fields.y, 40.0));
		float h = fd.x;
		vec3 fc;
		if (h < rural_fields.z) {
			vec2 sp = abs(fract(q / vec2(6.0, 3.0)) - 0.5);
			float grid = smoothstep(0.42, 0.48, max(sp.x, sp.y)) * thin(0.3, gw);
			fc = mix(vec3(0.025, 0.055, 0.12), vec3(0.08, 0.11, 0.14), grid);
		} else {
			vec3 crop = h < 0.28 ? vec3(0.19, 0.17, 0.07) : h < 0.52 ? vec3(0.055, 0.105, 0.03) : h < 0.72 ? vec3(0.085, 0.062, 0.042) : h < 0.92 ? vec3(0.065, 0.115, 0.032) : vec3(0.32, 0.28, 0.035);
			float ang = hash12(vec2(h * 97.0, 3.1)) * 3.14159;
			float across = dot(q, vec2(-sin(ang), cos(ang)));
			float row = smoothstep(0.25, 0.45, abs(fract(across / 0.75) - 0.5)) * thin(0.37, gw);
			float tm = mod(across, 20.0);
			float tram = max(box(tm - 9.1, 0.2, gw), box(tm - 10.9, 0.2, gw)) * thin(0.4, gw);
			fc = crop * (1.0 - 0.24 * row - 0.30 * tram) * (0.9 + 0.2 * fnoise(q, 0.02, gw));
			fc = mix(fc, vec3(0.028, 0.05, 0.018), (1.0 - smoothstep(1.2, 2.6, fd.y)) * thin(2.0, gw));
		}
		c = mix(c, fc, rural_fields.x);
	}
	// Inside a circle of real OSM buildings the open land and the City areas are streets and squares (paving);
	// City areas elsewhere are the gardens of the towns. Parks are their own layer and stay green.
	if (layer < 0.5 || kind == 0) {
		float city = 0.0;
		for (int i = 0; i < 16; i++) {
			if (cities[i].z > 0.0) city = max(city, 1.0 - smoothstep(cities[i].z * 0.85, cities[i].z, distance(world.xz, cities[i].xy)));
		}
		vec2 pv = world.xz;
		float stones = 1.0 - smoothstep(0.004, 0.004 + gw * 1.5, min(abs(fract(pv.x / 0.3) - 0.5), abs(fract(pv.y / 0.15 + 0.5 * floor(pv.x / 0.3)) - 0.5)) * 0.1);
		vec3 paving = vec3(0.16, 0.155, 0.145) * (0.9 + 0.2 * fnoise(pv, 0.8, gw)) * (1.0 - 0.15 * stones * thin(0.03, gw));
		if (kind == 0) {
			float g = fnoise(q, 0.08, gw);
			vec3 garden = mix(vec3(0.05, 0.095, 0.025), vec3(0.078, 0.12, 0.035), g);
			garden = mix(garden, vec3(0.13, 0.12, 0.1), smoothstep(0.72, 0.8, fnoise(q + 31.0, 0.05, gw)) * 0.7);
			c = garden;
		}
		c = mix(c, paving, city);
	}
	if (kind == 2) {
		// Fields of ~160 m, each with its crop and the direction it was sown in: rows 0.75 m apart, tractor
		// tramlines every 20 m, a hedge or ditch along the border.
		vec2 fd = fields(q, 160.0);
		float h = fd.x;
		vec3 crop = h < 0.3 ? vec3(0.22, 0.19, 0.075) : h < 0.55 ? vec3(0.05, 0.1, 0.025) : h < 0.75 ? vec3(0.085, 0.058, 0.04) : h < 0.93 ? vec3(0.065, 0.115, 0.03) : vec3(0.36, 0.31, 0.03);
		float ang = hash12(vec2(h * 97.0, 3.1)) * 3.14159;
		float across = dot(q, vec2(-sin(ang), cos(ang)));
		float row = smoothstep(0.25, 0.45, abs(fract(across / 0.75) - 0.5)) * thin(0.37, gw);
		float tm = mod(across, 20.0);
		float tram = max(box(tm - 9.1, 0.2, gw), box(tm - 10.9, 0.2, gw)) * thin(0.4, gw);
		c = crop * (1.0 - 0.28 * row - 0.35 * tram) * (0.9 + 0.2 * fnoise(q, 0.02, gw));
		c = mix(c, vec3(0.025, 0.045, 0.016), (1.0 - smoothstep(1.2, 2.6, fd.y)) * thin(2.0, gw));
	}
	if (kind != 1 && kind != 3 && layer > 0.5) {
		float n = fnoise(q, 1.0 / 9.0, gw) * 0.6 + fnoise(q, 1.0 / 41.0, gw) * 0.4;
		float fine = fnoise(qw, 1.7, gw);
		c *= 1.0 + (n - 0.5) * 0.22 + (fine - 0.5) * 0.12;
	}
	c *= sun_col * max(sun_dir.y, 0.0) * sun_shadow(world, vec3(0.0, 1.0, 0.0)) + amb_sky;
	finalColor = vec4(hdr_out(aerial(c, world)), 1.0);
	if (behind_horizon(world)) discard;
	gl_FragDepth = 1.0 - (layer + floor((1.0 - color.a) * 4.0 + 0.5) + 1.0) * 2e-7;
}
`

// The lit shader of the houses (and later trees and furniture): per vertex a normal, uv in metres on the surface,
// lh = (wall length, eave height) m and a colour whose alpha is the Street_Mat (houses.odin) plus flags. Walls get
// their facade here: floors, bays, windows with frames, mullions, sills and reveals, the front door, shop fronts
// with a fascia, brick / plaster / stone texture, a bluestone plinth, a cornice and ambient occlusion at the foot
// and under the eave. Everything is filtered by the pixel's footprint on the surface (fw, m per pixel): thin lines
// fade into their average instead of flickering, far facades become their average colour.
STREET_VS ::
	`#version 330
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
` +
	STREET_BEND_GLSL +
	`
void main() {
	v_world = (matModel * vec4(vertexPosition, 1.0)).xyz;
	v_normal = (matNormal * vec4(vertexNormal, 0.0)).xyz;
	v_uv = vertexTexCoord;
	v_lh = vertexTexCoord2;
	v_color = vertexColor;
	gl_Position = bent(mvp * vec4(vertexPosition, 1.0), v_world);
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
	float rough = 0.85, f0 = 0.04;
	float pane = seed;
	float leaf = 0.0;
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
			base = mix(mix(base, mortar, 0.15), mix(b, mortar, joint), thin(0.05, fw));
		} else if (mat == 2) {
			float g = fnoise(uv, 2.0, fw) * 0.5 + fnoise(uv, 9.0, fw) * 0.5;
			base *= (0.94 + 0.1 * g) * mix(0.8, 1.0, smoothstep(0.0, 2.5, v));
			base = mix(base, vec3(dot(base, vec3(0.3, 0.59, 0.11))), 0.2);
			rough = 0.8;
		} else {
			float cy = v / 0.32; float row = floor(cy); float fy = fract(cy);
			float cx = u / 0.65 + 0.37 * mod(row, 3.0); float cl = floor(cx); float fx = fract(cx);
			float j = min(min(fy, 1.0 - fy) * 0.32, min(fx, 1.0 - fx) * 0.65);
			float joint = 1.0 - smoothstep(0.003, 0.003 + fw, j);
			vec3 b = base * (0.92 + 0.14 * hash12(vec2(cl, row) + seed * 51.0));
			base = mix(base * 0.95, mix(b, base * 0.7, joint), thin(0.25, fw));
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
			float tf = thin(0.06, fw);
			if (!is_door) {
				if (ww > 1.0) gc *= 1.0 - box(bx, 0.03, fw) * tf;
				gc *= 1.0 - box(fy - (y1 - (y1 - y0) * 0.28), 0.025, fw) * tf;
			}
			vec3 frame_c = hash12(vec2(seed, 4.0)) < 0.55 ? vec3(0.75) : (hash12(vec2(seed, 6.0)) < 0.6 ? vec3(0.02, 0.022, 0.025) : vec3(0.15, 0.065, 0.03));
			base = mix(base, frame_c, (wc - gc) * fdet * mix(0.35, 1.0, tf));
			if (is_door) {
				vec3 door_c = lin(vec3(0.12 + 0.5 * hash12(vec2(seed, 7.0)), 0.16, 0.1 + 0.25 * hash12(vec2(seed, 8.0))));
				base = mix(base, door_c, gc * fdet);
				gc = box(bx, 0.3, fw) * box(fy - 1.85, 0.25, fw);
			}
			vec3 stone_c = vec3(0.42, 0.41, 0.38);
			float sill = box(bx, ww * 0.5 + 0.06, fw) * box(fy - (y0 - 0.04), 0.04, fw) * has * (is_door || is_shop ? 0.0 : 1.0);
			base = mix(base, stone_c, sill * fdet * tf);
			if (mat == 1) {
				float lintel = box(bx, ww * 0.5 + 0.1, fw) * box(fy - (y1 + 0.07), 0.07, fw) * has;
				base = mix(base, base * 0.75, lintel * fdet * thin(0.14, fw));
			}
			if (is_shop) {
				vec3 sign_c = lin(vec3(0.1 + 0.5 * hash12(vec2(seed, 9.0)), 0.12 + 0.4 * hash12(vec2(seed, 10.0)), 0.1 + 0.3 * hash12(vec2(seed, 11.0))));
				base = mix(base, sign_c, box(fy - (gh - 0.33), 0.2, fw) * fdet);
			}
			float reveal = mix(1.0, smoothstep(0.0, 0.25, (y1 - fr) - fy), thin(0.25, fw));
			interior *= mix(1.0, 0.6 + 0.9 * hash12(vec2(bi, fl) + seed * 13.0), thin(1.0, fw)) * mix(0.45, 1.0, reveal);
			glass = gc * fdet;
			pane = hash12(vec2(bi, fl) + seed * 5.0);
			// Rain streaks under the sills, darker where the water runs off the corners.
			float below = y0 - 0.04 - fy;
			if (below < 0.0) below += fh;
			float streak = box(bx, ww * 0.5, fw) * (1.0 - smoothstep(0.0, 1.9, below)) * step(0.0, below);
			streak *= 0.55 + 0.45 * vnoise(vec2(bx * 7.0 + seed * 31.0, fy * 0.6)) + 0.3 * box(abs(bx) - ww * 0.45, 0.06, fw);
			base *= 1.0 - 0.2 * streak * has * fdet * (1.0 - wc) * (is_shop || is_door ? 0.0 : 1.0);
			float avg = (ww * (y1 - y0)) / (bw * fh) * has;
			base = mix(mix(base, vec3(0.03), avg * 0.8), base, fdet);
		}
		float plinth = 1.0 - smoothstep(0.42, 0.42 + fw, v);
		base = mix(base, vec3(0.05, 0.055, 0.06), plinth * (1.0 - glass));
		float corn = box(v - (H - 0.18), 0.16, fw) * (v < H + 0.05 ? 1.0 : 0.0) * thin(0.32, fw);
		if (mat != 3) base = mix(base, mat == 1 ? vec3(0.48, 0.46, 0.42) : base * 1.08, corn * 0.85);
		// Weathering: splash and dirt at the foot, darker patches, grime under the cornice.
		float grime = fnoise(vec2(u * 0.4, v * 0.15) + seed * 9.0, 1.0, fw);
		base *= mix(0.78, 1.0, smoothstep(0.35, 1.5, v)) * (0.88 + 0.22 * grime);
		base *= 1.0 - 0.12 * smoothstep(1.6, 0.0, abs(H - 0.3 - v)) * grime;
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
		float mull = (1.0 - box(px - 0.75, 0.7, fw)) * thin(0.1, fw);
		float band = box(fy - 0.45, 0.45, fw);
		glass = (1.0 - max(mull, band)) * step(0.6, v) * 0.95;
		pane = hash12(floor(vec2(u / 1.5, v / 3.6)) + seed * 3.0);
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
		detail = thin(course * 0.6, fw);
		float moss = smoothstep(0.55, 0.9, fnoise(uv + seed * 14.0, 0.7, fw)) * 0.35;
		t = mix(t, vec3(0.05, 0.07, 0.025), moss * (mat == 5 ? 1.0 : 0.6));
		base = mix(base * 0.86, t, detail);
		rough = mat == 6 ? 0.38 : 0.62;
	} else if (mat == 7) {
		base *= 0.8 + 0.4 * (fnoise(uv, 3.0, fw) * 0.6 + fnoise(uv, 13.0, fw) * 0.4);
		base *= 0.75 + 0.35 * fnoise(uv + seed * 7.0, 0.25, fw);
		rough = 0.9;
	} else if (mat == 8) {
		float a = fnoise(uv + seed * 3.0, 0.9, fw), b = fnoise(uv + 7.0, 4.0, fw), c = fnoise(uv, 15.0, fw);
		vec3 sedum = mix(vec3(0.05, 0.075, 0.025), vec3(0.11, 0.11, 0.04), b);
		sedum = mix(sedum, vec3(0.14, 0.06, 0.035), smoothstep(0.55, 0.8, a) * 0.8);
		sedum = mix(sedum, vec3(0.16, 0.14, 0.07), smoothstep(0.65, 0.9, c) * 0.6);
		base = sedum * 1.15;
		rough = 1.0;
	} else if (mat == 12) {
		base *= 0.8 + 0.35 * fnoise(uv * vec2(1.0, 0.3), 3.0, fw);
	} else if (mat == 13) {
		// A shade of green per tree (from its position), darker and lighter clumps of leaves.
		float t = hash12(floor(v_lh * 0.37));
		base *= mix(vec3(0.82, 0.95, 0.72), vec3(1.18, 1.06, 0.86), t) * (0.85 + 0.3 * hash12(floor(v_lh * 1.3) + 7.7));
		base *= 0.68 + 0.64 * fnoise(uv, 1.6, fw);
		leaf = 1.0;
		rough = 0.95;
	} else if (mat == 9) {
		float px = fract(uv.x / 1.05) * 1.05, py = fract(uv.y / 1.75) * 1.75;
		float frame = (1.0 - box(px - 0.525, 0.5, fw) * box(py - 0.875, 0.83, fw)) * thin(0.05, fw);
		float cw = fw / 0.175;
		float cells = max(1.0 - box(fract(px / 0.175) - 0.5, 0.46, cw), 1.0 - box(fract(py / 0.175) - 0.5, 0.46, cw)) * (1.0 - smoothstep(0.01, 0.04, fw));
		base = mix(vec3(0.006, 0.01, 0.028), vec3(0.45), frame);
		base = mix(base, vec3(0.04, 0.05, 0.08), cells * 0.6 * (1.0 - frame));
		glass = (1.0 - frame) * 0.85;
		interior = base;
	}

	// Leaves take the light around the crown (wrapped) and let it through when the sun is behind them.
	float ndl = leaf > 0.5 ? clamp((dot(n, sun_dir) + 0.5) / 1.5, 0.0, 1.0) : max(dot(n, sun_dir), 0.0);
	float shd = 1.0;
	if (ndl > 0.0) {
		shd = sun_shadow(v_world, n);
		ndl *= shd;
	}
	if (mat == 10) rough = 0.6;
	if (mat == 11) { rough = 0.35; f0 = 0.5; }
	vec3 amb = mix(amb_gnd, amb_sky, n.y * 0.5 + 0.5);
	float F = fresnel_r(f0, n, V, rough);
	vec3 c = base * (sun_col * ndl + amb) * ao * (1.0 - F);
	c += sun_col * shd * ggx(n, V, sun_dir, rough) * F;
	c += env_col(reflect(-V, n), rough) * F * ao;
	if (leaf > 0.5) c += base * sun_col * 0.35 * pow(max(dot(-V, sun_dir), 0.0), 4.0) * shd;
	if (glass > 0.001) {
		// Each pane a hair out of plane, so neighbouring windows mirror the street a little differently.
		vec3 gn = normalize(n + (vec3(hash12(vec2(pane, 1.0)), hash12(vec2(pane, 2.0)), hash12(vec2(pane, 3.0))) - 0.5) * 0.05);
		vec3 r = reflect(-V, gn);
		float fres = fresnel(0.04, gn, V);
		vec3 refl = env_col(r, 0.0) + sun_col * shd * ggx(gn, V, sun_dir, 0.05);
		vec3 g = interior * (amb + sun_col * 0.15) + refl * clamp(fres + 0.06, 0.0, 1.0);
		c = mix(c, g * ao, glass);
	}
	finalColor = vec4(hdr_out(aerial(c, v_world)), 1.0);
	if (behind_horizon(v_world)) discard;
}
`

// The cars in the street view (Lars, 2026-11-22: "realistischer"): CAR_FS's shading classes (vertex alpha: 0 matte,
// 1 paint, 2 glass, 3 metal, 4 light) in linear light with the street's sun, its shadows and haze, and the
// reflections of env_col: paint is a diffuse coat under a clear coat that mirrors sky and street, glass is dark
// and mirrors, metal mirrors in its own colour. Bent with the round world like everything else.
STREET_CAR_VS ::
	`#version 330
in vec3 vertexPosition;
in vec3 vertexNormal;
in vec4 vertexColor;
uniform mat4 mvp;
uniform mat4 matModel;
uniform mat4 matNormal;
out vec3 v_world;
out vec3 v_normal;
out vec4 v_color;
` +
	STREET_BEND_GLSL +
	`
void main() {
	v_world = (matModel * vec4(vertexPosition, 1.0)).xyz;
	v_normal = normalize((matNormal * vec4(vertexNormal, 0.0)).xyz);
	v_color = vertexColor;
	gl_Position = bent(mvp * vec4(vertexPosition, 1.0), v_world);
}
`

STREET_CAR_FS ::
	`#version 330
in vec3 v_world;
in vec3 v_normal;
in vec4 v_color;
uniform vec4 colDiffuse;
out vec4 finalColor;
` +
	STREET_GLSL +
	`
void main() {
	vec3 n = normalize(v_normal);
	if (!gl_FrontFacing) n = -n;
	int cls = int(v_color.a * 255.0 + 0.5);
	vec3 base = lin(v_color.rgb * colDiffuse.rgb);
	vec3 V = normalize(cam - v_world);
	float ndl = max(dot(n, sun_dir), 0.0);
	float shd = ndl > 0.0 ? sun_shadow(v_world, n) : 1.0;
	vec3 amb = mix(amb_gnd, amb_sky, n.y * 0.5 + 0.5);
	vec3 r = reflect(-V, n);
	vec3 c;
	if (cls == 4) {
		c = base * 3.0;
	} else if (cls == 2) {
		float F = fresnel(0.04, n, V);
		c = base * 0.12 * amb + (env_col(r, 0.02) + sun_col * shd * ggx(n, V, sun_dir, 0.05)) * mix(0.1, 1.0, F);
	} else if (cls == 3) {
		c = base * (env_col(r, 0.3) * 0.85 + amb * 0.15) + base * sun_col * shd * ggx(n, V, sun_dir, 0.3);
	} else if (cls == 1) {
		float F = fresnel(0.04, n, V);
		c = base * (sun_col * ndl * shd + amb) * (1.0 - F);
		c += (env_col(r, 0.04) + sun_col * shd * ggx(n, V, sun_dir, 0.06)) * F;
		c += base * sun_col * shd * ggx(n, V, sun_dir, 0.45) * 0.08;
	} else {
		c = base * (sun_col * ndl * shd + amb) + sun_col * shd * ggx(n, V, sun_dir, 0.7) * 0.04;
	}
	finalColor = vec4(hdr_out(aerial(c, v_world)), colDiffuse.a);
	if (behind_horizon(v_world)) discard;
}
`

// Roads, sidewalks, rivers and zebra crossings (street_road_tile): uv = (metres along the line, metres from its
// centre), hk.x = the road's half width, colour r = kind (0 asphalt, 1 motorway, 2 sidewalk, 3 water, 4 zebra),
// g = lanes, b = 2 for edge lines, a = layer as in the ground shader. Markings are drawn here, filtered by the
// pixel's footprint like the facades, so dashes do not sparkle in the distance.
STREET_ROAD_VS ::
	`#version 330
in vec3 vertexPosition;
in vec2 vertexTexCoord;
in vec2 vertexTexCoord2;
in vec4 vertexColor;
uniform mat4 mvp;
uniform mat4 matModel;
out vec3 world;
out vec2 uv;
out vec2 hk;
out vec4 color;
` +
	STREET_BEND_GLSL +
	`
void main() {
	world = (matModel * vec4(vertexPosition, 1.0)).xyz;
	gl_Position = bent(mvp * vec4(vertexPosition, 1.0), world);
	uv = vertexTexCoord;
	hk = vertexTexCoord2;
	color = vertexColor;
}
`

STREET_ROAD_FS ::
	`#version 330
in vec3 world;
in vec2 uv;
in vec2 hk;
in vec4 color;
uniform float layer;
out vec4 finalColor;
` +
	STREET_GLSL +
	`
// A square wave of period p that is on for the first on metres, box filtered over w metres (exact average).
float dash(float x, float p, float on, float w) {
	w = max(w, 0.001);
	float a = x - w * 0.5, b = x + w * 0.5;
	float fa = floor(a / p) * on + min(mod(a, p), on);
	float fb = floor(b / p) * on + min(mod(b, p), on);
	return (fb - fa) / w;
}
void main() {
	int mat = int(color.r * 255.0 + 0.5);
	int lanes = int(color.g * 255.0 + 0.5);
	int flags = int(color.b * 255.0 + 0.5);
	float hw = hk.x;
	float u = uv.x, v = uv.y;
	vec2 fv = fwidth(uv);
	float fw = max(length(fv), 1e-4);
	vec3 V = normalize(cam - world);
	vec3 base;
	float water = 0.0;
	if (mat <= 1) {
		base = mat == 1 ? vec3(0.07, 0.072, 0.076) : vec3(0.058, 0.06, 0.064);
		base *= 0.86 + 0.18 * fnoise(uv, 0.35, fw) + 0.12 * (fnoise(uv, 7.0, fw) - 0.5);
		float lane_w = 2.0 * hw / float(max(lanes, 1));
		float lp = mod(v + hw, lane_w) - lane_w * 0.5;
		base *= 1.0 - 0.1 * box(abs(lp) - 0.8, 0.28, fv.y) * thin(0.4, fv.y);
		float m = 0.0;
		for (int i = 1; i < 4; i++) {
			if (i >= lanes) break;
			float line = box(v - (-hw + lane_w * float(i)), 0.065, fv.y);
			m = max(m, line * dash(u, 12.0, 3.0, fv.x) * thin(0.13, fv.y));
		}
		if ((flags & 2) != 0) m = max(m, box(abs(v) - (hw - 0.35), 0.075, fv.y) * thin(0.15, fv.y));
		base = mix(base, vec3(0.62, 0.62, 0.6), m * 0.9);
	} else if (mat == 2) {
		float av = abs(v);
		vec2 t = vec2(u, av - hw) / 0.3;
		float detail = thin(0.03, fw);
		vec2 j = abs(fract(t) - 0.5);
		float joints = smoothstep(0.47 - fw / 0.3, 0.5, max(j.x, j.y));
		base = vec3(0.2, 0.196, 0.185) * (0.93 + 0.14 * hash12(floor(t)) * detail) * (1.0 - 0.22 * joints * detail);
		float kerb = box(av - (hw + 0.08), 0.08, fv.y);
		base = mix(base, vec3(0.3, 0.3, 0.28), kerb);
		base *= 1.0 - 0.35 * box(av - hw, 0.04, fv.y) * thin(0.08, fv.y);
	} else if (mat == 3) {
		base = vec3(0.012, 0.025, 0.03);
		water = 1.0;
	} else {
		base = vec3(0.058, 0.06, 0.064) * (0.9 + 0.2 * fnoise(uv, 3.0, fw));
		float stripe = dash(v + hw, 1.0, 0.5, fv.y) * box(u, 1.5, fv.x);
		base = mix(base, vec3(0.62, 0.62, 0.6), stripe * thin(0.5, fv.y) * 0.9);
	}
	float sh = sun_shadow(world, vec3(0.0, 1.0, 0.0));
	vec3 c = base * (sun_col * max(sun_dir.y, 0.0) * sh + amb_sky);
	if (water > 0.0) {
		vec2 q = world.xz;
		vec3 n = normalize(vec3((fnoise(q, 1.3, fw) - 0.5) * 0.12, 1.0, (fnoise(q + 17.0, 1.1, fw) - 0.5) * 0.12));
		vec3 r = reflect(-V, n);
		float fres = 0.03 + 0.97 * pow(1.0 - max(dot(n, V), 0.0), 5.0);
		c = mix(c, sky_col(r), fres) + sun_col * 2.0 * pow(max(dot(r, sun_dir), 0.0), 200.0) * sh;
	}
	finalColor = vec4(hdr_out(aerial(c, world)), 1.0);
	if (behind_horizon(world)) discard;
	gl_FragDepth = 1.0 - (layer + floor((1.0 - color.a) * 4.0 + 0.5) + 1.0) * 2e-7;
}
`

// The shadow pass draws only depth.
STREET_DEPTH_VS :: `#version 330
in vec3 vertexPosition;
uniform mat4 mvp;
void main() {
	gl_Position = mvp * vec4(vertexPosition, 1.0);
}
`

STREET_DEPTH_FS :: `#version 330
void main() {}
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
uniform vec2 sky_clouds;
out vec4 finalColor;
` +
	STREET_GLSL +
	`
void main() {
	vec2 ndc = gl_FragCoord.xy / screen * 2.0 - 1.0;
	vec3 r = normalize(cam_fwd + cam_right * ndc.x * tan_half.x + cam_up * ndc.y * tan_half.y);
	vec3 c = sky_col(r);
	c += sun_col * 6.0 * smoothstep(0.99985, 0.99993, dot(r, sun_dir));
	if (sky_clouds.x > 0.001 && r.y > 0.015) {
		vec2 cp = r.xz / (r.y + 0.14) * 1.1 + vec2(sky_clouds.y * 0.012, sky_clouds.y * 0.004);
		float n = vnoise(cp) * 0.6 + vnoise(cp * 2.3 + 7.1) * 0.28 + vnoise(cp * 5.1 + 19.3) * 0.12;
		float puff = smoothstep(0.50, 0.80, n) * smoothstep(0.015, 0.20, r.y);
		vec3 cloud_col = mix(sky_hor * 0.85, sky_hor * 0.65 + sun_col * 0.45, smoothstep(0.45, 0.85, n));
		c = mix(c, cloud_col, puff * clamp(sky_clouds.x, 0.0, 1.0) * 0.72);
	}
	// Below the horizon line, down to the curve of the round world, the low sky goes on (sky_col stops at 0).
	finalColor = vec4(hdr_out(c), 1.0);
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
	sky_curve:         f32, // the gradient: mix(sky_hor, sky_zen, elevation^sky_curve)
	sky_glow:          f32, // the bright band just above the horizon
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
	land = {68, 86, 44, 255},
	areas = {
		.City = {118, 116, 108, 255},
		.Park = {58, 84, 38, 255},
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
		solar_roof = {0.16, 0.21, 0.32},
		green_roof = {0.36, 0.47, 0.27},
		wall = {0.74, 0.7, 0.64},
		tree = {0.3, 0.4, 0.24},
		fog = {196.0 / 255, 210.0 / 255, 222.0 / 255},
	},
	sun_col = {2.15, 2.05, 1.85},
	sky_zen = {0.06, 0.19, 0.6},
	sky_hor = {0.56, 0.67, 0.82},
	sky_curve = 0.5,
	sky_glow = 0.3,
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

// One world, no street view key (Lars, 2026-11-22: "geen 2 modes, als je via de map zo laag naar beneden gaat
// switch je naar de 3d game, en omgekeerd als je naar boven gaat terug naar de map"): a zoom in past the closest
// map view (ZOOM_MAX, the camera ~2.3 km away) goes down into the street view at the car, from the plan screen
// too (that leaves the plan for free flight, like M; Lars: "3D at the car"). While flying on the map, the car
// sinking below STREET_LOW_M goes down too. Once a frame from game_update.
street_switch_heights :: proc(w: ^World) -> (low, high: f32) {
	low = max(w.street_edit.switch_low_m, 10)
	high = max(w.street_edit.switch_high_m, low + 5)
	return
}

// Once a frame from game_update: climbs/descends or zoom past ZOOM_MAX switches view.
street_switch :: proc(w: ^World) {
	st := &w.street
	low, high := street_switch_heights(w)
	switch {
	case st.on:
	case w.cam.zoom_past:
		street_enter(w)
	case w.screen != .Navigate:
		st.hold = false
	case st.hold:
		if street_ship_pos(w).y > high do st.hold = false
	case street_ship_pos(w).y < low:
		street_enter(w)
	}
	w.cam.zoom_past = false
}

// Back up to the map (Lars: "fly high or scroll out"): the car climbs above high, or the camera is
// zoomed out past STREET_CAM_MAX_M; Esc, Circle and Options go back too.
street_wants_map :: proc(w: ^World) -> bool {
	st := &w.street
	if w.screen != .Navigate || key_pressed(w, .ESCAPE) || pad_pressed(w, .MIDDLE_RIGHT) {
		return true
	}
	if !w.ui.cancelled && w.ui.focus == 0 && pad_pressed(w, .RIGHT_FACE_RIGHT) do return true
	low, high := street_switch_heights(w)
	h := street_ship_pos(w).y
	if st.hold {
		if h < low do st.hold = false
	} else if h > high {
		return true
	}
	dist := st.dist == 0 ? w.street_edit.cam_dist_m : st.dist
	return mouse_wheel(w) + pad_zoom(w) < 0 && dist >= STREET_CAM_MAX_M
}

street_enter :: proc(w: ^World) {
	st := &w.street
	low, _ := street_switch_heights(w)
	if w.screen == .Plan {
		nav_stop(w)
		w.screen = .Navigate
	}
	st.on = true
	st.yaw, st.pitch, st.idle_s, st.dist = 0, 0, 0, 0
	st.seeded = false
	st.hold = street_ship_pos(w).y >= low
	if !w.script.on do rl.DisableCursor()
	logf(w, "street", "down into the street view at %.0f m", street_ship_pos(w).y)
}

// The map takes over at its closest view behind the car, so one zoom in goes back down.
street_leave :: proc(w: ^World) {
	_, high := street_switch_heights(w)
	w.street.on = false
	w.street.hold = street_ship_pos(w).y <= high
	logf(w, "street", "up to the map at %.0f m", street_ship_pos(w).y)
	if !w.script.on do rl.EnableCursor()
	if w.screen != .Navigate do return
	c := &w.cam
	c.mode = .Chase
	c.dragged = false
	c.pose = cam_chase_pose(w, ZOOM_MAX)
	c.glide_dur = 0
	c.zooming = false
	c.zoom_goal = ZOOM_MAX
}

// Builds the line index, the ground plane and the shader. Needs the window.
street_build :: proc(w: ^World) {
	prof_zone(w, .Street_Build)
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
	if st.area_cells == nil && len(w.m.area_points) < 1 << 28 {
		// Land use triangles into every tile their bounding box touches, in map order (water last, on top).
		counts := make([]u32, STREET_AREA_W * STREET_AREA_H + 1, perm)
		for pass in 0 ..< 2 {
			for a in w.m.areas {
				for k := a.start; k + 2 < a.start + a.count; k += 3 {
					p := w.m.area_points[k:][:3]
					lo := linalg.min(p[0], linalg.min(p[1], p[2])) / STREET_AREA_TILE_KM
					hi := linalg.max(p[0], linalg.max(p[1], p[2])) / STREET_AREA_TILE_KM
					for y in clamp(int(lo.y), 0, STREET_AREA_H - 1) ..= clamp(int(hi.y), 0, STREET_AREA_H - 1) {
						for x in clamp(int(lo.x), 0, STREET_AREA_W - 1) ..= clamp(int(hi.x), 0, STREET_AREA_W - 1) {
							c := y * STREET_AREA_W + x
							if pass == 0 {
								counts[c + 1] += 1
							} else {
								st.area_items[st.area_cells[c] + counts[c]] = a.kind << 28 | k
								counts[c] += 1
							}
						}
					}
				}
			}
			if pass == 0 {
				for c in 1 ..< len(counts) do counts[c] += counts[c - 1]
				st.area_cells = counts
				st.area_items = make([]u32, counts[len(counts) - 1], perm)
				counts = make([]u32, STREET_AREA_W * STREET_AREA_H + 1, context.temp_allocator)
			}
		}
		logf(
			w,
			"street",
			"%d land use entries in %d tiles",
			len(st.area_items),
			STREET_AREA_W * STREET_AREA_H,
		)
	}
	if st.road_s == nil {
		st.road_s = make([]f32, len(w.m.points), perm)
		for l in w.m.lines {
			s: f32
			for k in l.start ..< l.start + l.count {
				st.road_s[k] = math.mod(s, 1200)
				if k + 1 < l.start + l.count do s += linalg.length(w.m.points[k + 1] - w.m.points[k]) * 1000
			}
		}
	}
	ground: {
		// The land under everything: a disc past the far plane, drawn under the car in street space, cut in rings
		// and sectors (STREET_LAND_RINGS), each triangle facing up.
		R :: STREET_FAR_M + 200
		pos := make([dynamic][3]f32, 0, STREET_LAND_RINGS * STREET_LAND_SEGS * 6, context.temp_allocator)
		at :: proc(ring, seg: int) -> [3]f32 {
			r := R * f32(ring) / STREET_LAND_RINGS
			a := 2 * math.PI * f32(seg) / STREET_LAND_SEGS
			return {r * math.cos(a), 0, -r * math.sin(a)}
		}
		for i in 0 ..< STREET_LAND_RINGS {
			for j in 0 ..< STREET_LAND_SEGS {
				p00, p01, p10, p11 := at(i, j), at(i, j + 1), at(i + 1, j), at(i + 1, j + 1)
				if i > 0 do append(&pos, p00, p10, p01)
				append(&pos, p01, p10, p11)
			}
		}
		col := make([][4]u8, len(pos), context.temp_allocator)
		land := STREET_LOOK.land
		for &c in col do c = {land.r, land.g, land.b, 255}
		st.ground = tile_mesh(pos[:], col)
	}
	sh := rl.LoadShaderFromMemory(STREET_GROUND_VS, STREET_GROUND_FS)
	if !rl.IsShaderValid(sh) do logf(w, "street", "ground shader did not compile")
	st.material = rl.LoadMaterialDefault()
	st.material.shader = sh
	st.loc = {
		layer        = rl.GetShaderLocation(sh, "layer"),
		remap        = rl.GetShaderLocation(sh, "remap"),
		map_colors   = rl.GetShaderLocation(sh, "map_colors"),
		real_colors  = rl.GetShaderLocation(sh, "real_colors"),
		origin       = rl.GetShaderLocation(sh, "origin"),
		cities       = rl.GetShaderLocation(sh, "cities"),
		grass_size   = rl.GetShaderLocation(sh, "grass_size"),
		grass_amt    = rl.GetShaderLocation(sh, "grass_amt"),
		grass_tone   = rl.GetShaderLocation(sh, "grass_tone"),
		rural_fields = rl.GetShaderLocation(sh, "rural_fields"),
		light        = street_light_locs(sh),
	}
	lit := rl.LoadShaderFromMemory(STREET_VS, STREET_FS)
	if !rl.IsShaderValid(lit) do logf(w, "street", "lit shader did not compile")
	st.lit = rl.LoadMaterialDefault()
	st.lit.shader = lit
	st.lit_loc = street_light_locs(lit)
	car_sh := rl.LoadShaderFromMemory(STREET_CAR_VS, STREET_CAR_FS)
	if !rl.IsShaderValid(car_sh) do logf(w, "street", "car shader did not compile")
	st.car = rl.LoadMaterialDefault()
	st.car.shader = car_sh
	st.car_loc = street_light_locs(car_sh)
	st.sky = rl.LoadShaderFromMemory(nil, STREET_SKY_FS)
	if !rl.IsShaderValid(st.sky) do logf(w, "street", "sky shader did not compile")
	st.sky_loc = {
		fwd      = rl.GetShaderLocation(st.sky, "cam_fwd"),
		right    = rl.GetShaderLocation(st.sky, "cam_right"),
		up       = rl.GetShaderLocation(st.sky, "cam_up"),
		tan_half = rl.GetShaderLocation(st.sky, "tan_half"),
		screen   = rl.GetShaderLocation(st.sky, "screen"),
		clouds   = rl.GetShaderLocation(st.sky, "sky_clouds"),
		light    = street_light_locs(st.sky),
	}
	st.depth = rl.LoadMaterialDefault()
	st.depth.shader = rl.LoadShaderFromMemory(STREET_DEPTH_VS, STREET_DEPTH_FS)
	road := rl.LoadShaderFromMemory(STREET_ROAD_VS, STREET_ROAD_FS)
	if !rl.IsShaderValid(road) do logf(w, "street", "road shader did not compile")
	st.road = rl.LoadMaterialDefault()
	st.road.shader = road
	trees_build(w)
	solarpunk_build(w)
	st.road_loc = {
		layer = rl.GetShaderLocation(road, "layer"),
		light = street_light_locs(road),
	}
	shadow: {
		st.shadow_fbo = rlgl.LoadFramebuffer()
		if st.shadow_fbo == 0 do break shadow
		rlgl.EnableFramebuffer(st.shadow_fbo)
		st.shadow_tex = rlgl.LoadTextureDepth(SHADOW_SIZE, SHADOW_SIZE, false)
		rlgl.FramebufferAttach(
			st.shadow_fbo,
			st.shadow_tex,
			i32(rlgl.FramebufferAttachType.DEPTH),
			i32(rlgl.FramebufferAttachTextureType.TEXTURE2D),
			0,
		)
		ok := rlgl.FramebufferComplete(st.shadow_fbo)
		rlgl.DisableFramebuffer()
		if !ok {
			logf(w, "street", "shadow framebuffer is not complete, no shadows")
			rlgl.UnloadFramebuffer(st.shadow_fbo)
			st.shadow_fbo, st.shadow_tex = 0, 0
		}
	}
	st.ready = true
}

street_unload :: proc(st: ^Street) {
	tiles_unload(&st.roads)
	tiles_unload(&st.areas)
	tiles_unload(&st.houses)
	trees_unload(&st.trees)
	solarpunk_unload(&st.solarpunk)
	post_unload(&st.post)
	if !st.ready do return
	rl.UnloadMesh(st.ground)
	rl.UnloadShader(st.material.shader)
	rl.UnloadShader(st.lit.shader)
	rl.UnloadShader(st.car.shader)
	rl.UnloadShader(st.sky)
	rl.UnloadShader(st.depth.shader)
	rl.UnloadShader(st.road.shader)
	if st.shadow_fbo != 0 do rlgl.UnloadFramebuffer(st.shadow_fbo)
	st.shadow_fbo, st.shadow_tex = 0, 0
	st.ready = false
}

// One road tile (Tile_Build), relative to lo: for every road and river segment whose middle lies in lo ..< hi a
// ribbon at its real width, uv = (metres along the line from road_s, metres from the centre line), sidewalks with
// a kerb under the roads in towns (a lower layer, so a crossing road always lies on top of them), and zebra
// crossings on each arm of a town junction of the road graph. Shaded by STREET_ROAD_FS.
street_road_tile :: proc(w: ^World, lo, hi: [2]f32) -> rl.Mesh {
	st := &w.street
	Ribbons :: struct {
		pos:    [dynamic][3]f32,
		uv, hk: [dynamic][2]f32,
		col:    [dynamic][4]u8,
	}
	r: Ribbons
	r.pos = make([dynamic][3]f32, 0, 1 << 14, context.temp_allocator)
	r.uv = make([dynamic][2]f32, 0, 1 << 14, context.temp_allocator)
	r.hk = make([dynamic][2]f32, 0, 1 << 14, context.temp_allocator)
	r.col = make([dynamic][4]u8, 0, 1 << 14, context.temp_allocator)
	// A strip from a to b (km, relative to lo) reaching half m to each side, longer by ext m at both ends; u from
	// u0 at a, v = metres from the centre (positive on the left of a -> b on the map).
	strip :: proc(r: ^Ribbons, a, b: [2]f32, half, ext, u0, hw: f32, mat, lanes, flags, layer: u8) {
		d := (b - a) * 1000
		l := linalg.length(d)
		if l <= 0 do return
		dir := d / l
		n := [2]f32{-dir.y, dir.x} * half / 1000
		e := dir * ext / 1000
		c := [4]u8{mat, lanes, flags, 255 - layer * 64}
		pieces := max(int(math.ceil((l + 2 * ext) / STREET_ROAD_PIECE_M)), 1)
		for i in 0 ..< pieces {
			t0 := f32(i) / f32(pieces)
			t1 := f32(i + 1) / f32(pieces)
			pa := linalg.lerp(a - e, b + e, t0)
			pb := linalg.lerp(a - e, b + e, t1)
			ua := u0 - ext + (l + 2 * ext) * t0
			ub := u0 - ext + (l + 2 * ext) * t1
			p0, p1, p2, p3 := pa - n, pa + n, pb + n, pb - n
			for k in ([6]int{0, 1, 2, 0, 2, 3}) {
				p := [4][2]f32{p0, p1, p2, p3}[k]
				uvk := [4][2]f32{{ua, -half}, {ua, half}, {ub, half}, {ub, -half}}[k]
				append(&r.pos, [3]f32{p.x, p.y, 0})
				append(&r.uv, uvk)
				append(&r.hk, [2]f32{hw, 0})
				append(&r.col, c)
			}
		}
	}
	cx := clamp(int(lo.x / STREET_ROAD_CELL_KM), 0, STREET_ROAD_W - 1)
	cy := clamp(int(lo.y / STREET_ROAD_CELL_KM), 0, STREET_ROAD_H - 1)
	c := cy * STREET_ROAD_W + cx
	for item in st.road_segs[st.road_cells[c]:st.road_cells[c + 1]] {
		k := int(item & 0xffffff)
		kind := Map_Kind(item >> 24)
		hw := road_half_width_m(kind)
		if hw == 0 do continue
		a, b := w.m.points[k], w.m.points[k + 1]
		mid := (a + b) / 2
		if mid.x < lo.x || mid.y < lo.y || mid.x >= hi.x || mid.y >= hi.y do continue
		u0 := st.road_s[k]
		if kind == .River {
			strip(&r, a - lo, b - lo, hw, hw, u0, hw, 3, 0, 0, 0)
			continue
		}
		lanes: u8 = kind == .Motorway ? 3 : 2
		flags: u8 = kind == .Motorway || kind == .Trunk || kind == .Primary ? 2 : 0
		if kind != .Motorway && kind != .Trunk && urban_at(w, mid) {
			strip(&r, a - lo, b - lo, hw + ROAD_SIDEWALK_M, hw, u0, hw, 2, lanes, flags, 1)
		}
		strip(&r, a - lo, b - lo, hw, min(hw, 6), u0, hw, kind == .Motorway ? 1 : 0, lanes, flags, 2)
	}
	// Zebra crossings: on every arm of a junction (3 or more roads) in town, a few metres out from the middle.
	for node in w.m.road_nodes {
		if node.count < 3 do continue
		p := node.pos
		if p.x < lo.x || p.y < lo.y || p.x >= hi.x || p.y >= hi.y || !urban_at(w, p) do continue
		widest: f32
		for e in w.m.road_edges[node.first:][:node.count] do widest = max(widest, road_half_width_m(Map_Kind(e.kind)))
		for e in w.m.road_edges[node.first:][:node.count] {
			hw := road_half_width_m(Map_Kind(e.kind))
			if hw == 0 || e.count < 2 || Map_Kind(e.kind) == .Motorway do continue
			next := w.m.road_points[e.start + 1]
			d := next - p
			if linalg.length(d) * 1000 < widest + 8 do continue
			dir := linalg.normalize(d)
			at := p + dir * (widest + 4) / 1000
			strip(&r, at - lo, at + dir * 0.003 - lo, hw, 0, -1.5, hw, 4, 0, 0, 3)
		}
	}
	if len(r.pos) == 0 do return {}
	mesh := rl.Mesh {
		vertexCount   = i32(len(r.pos)),
		triangleCount = i32(len(r.pos) / 3),
		vertices      = ([^]f32)(raw_data(r.pos)),
		texcoords     = ([^]f32)(raw_data(r.uv)),
		texcoords2    = ([^]f32)(raw_data(r.hk)),
		colors        = ([^]u8)(raw_data(r.col)),
	}
	rl.UploadMesh(&mesh, false)
	mesh.vertices, mesh.texcoords, mesh.texcoords2, mesh.colors = nil, nil, nil, nil
	return mesh
}

// The round world's bend (1 / 2R, STREET_BEND_GLSL) for an eye h m above the ground (see STREET_VIEW_KM).
street_bend :: proc(w: ^World, h: f32) -> f32 {
	k := STREET_VIEW_KM * 1000 / (math.sqrt(max(h, 0) + 1) + math.sqrt(max(w.street_edit.curve_tall_m, 1)))
	return 1 / (k * k)
}

// The land use of the tile lo ..< hi (km) in its palette colors (remapped by STREET_GROUND_FS): each triangle
// clipped to every STREET_GROUND_STEP_KM square of the tile it touches, points relative to lo, facing up.
street_area_tile :: proc(w: ^World, lo, hi: [2]f32) -> rl.Mesh {
	st := &w.street
	if st.area_cells == nil do return {}
	pal := palette(w)
	colors := [Area_Kind]rl.Color {
		.City     = pal.city,
		.Park     = pal.park,
		.Farmland = pal.farmland,
		.Marsh    = pal.marsh,
		.Beach    = pal.beach,
		.Water    = pal.water,
	}
	pos := make([dynamic][3]f32, 0, 1 << 15, context.temp_allocator)
	col := make([dynamic][4]u8, 0, 1 << 15, context.temp_allocator)
	// Sutherland-Hodgman: keeps the part of poly[:n] where the coordinate axis is >= v (side 1) or <= v (-1).
	clip :: proc(poly: ^[10][2]f32, n: int, axis: int, v, side: f32) -> int {
		out: [10][2]f32
		m := 0
		for i in 0 ..< n {
			a, b := poly[i], poly[(i + 1) % n]
			da, db := (a[axis] - v) * side, (b[axis] - v) * side
			if da >= 0 {
				out[m] = a
				m += 1
			}
			if (da >= 0) != (db >= 0) {
				out[m] = linalg.lerp(a, b, da / (da - db))
				out[m][axis] = v
				m += 1
			}
		}
		poly^ = out
		return m
	}
	size := hi - lo
	steps := int(math.round(size.x / STREET_GROUND_STEP_KM))
	step := size / f32(steps)
	cx := clamp(int(lo.x / STREET_AREA_TILE_KM + 0.5), 0, STREET_AREA_W - 1)
	cy := clamp(int(lo.y / STREET_AREA_TILE_KM + 0.5), 0, STREET_AREA_H - 1)
	cell := cy * STREET_AREA_W + cx
	for item in st.area_items[st.area_cells[cell]:st.area_cells[cell + 1]] {
		k := item & (1 << 28 - 1)
		cc := colors[Area_Kind(item >> 28)]
		c := [4]u8{cc.r, cc.g, cc.b, 255}
		tri := [3][2]f32{w.m.area_points[k] - lo, w.m.area_points[k + 1] - lo, w.m.area_points[k + 2] - lo}
		t_lo := linalg.min(tri[0], linalg.min(tri[1], tri[2]))
		t_hi := linalg.max(tri[0], linalg.max(tri[1], tri[2]))
		i0, i1 := max(int(t_lo.x / step.x), 0), min(int(t_hi.x / step.x), steps - 1)
		j0, j1 := max(int(t_lo.y / step.y), 0), min(int(t_hi.y / step.y), steps - 1)
		for j in j0 ..= j1 {
			for i in i0 ..= i1 {
				poly: [10][2]f32
				poly[0], poly[1], poly[2] = tri[0], tri[1], tri[2]
				n := 3
				q_lo := [2]f32{f32(i), f32(j)} * step
				q_hi := [2]f32{f32(i + 1), f32(j + 1)} * step
				n = clip(&poly, n, 0, q_lo.x, 1)
				n = clip(&poly, n, 0, q_hi.x, -1)
				n = clip(&poly, n, 1, q_lo.y, 1)
				n = clip(&poly, n, 1, q_hi.y, -1)
				for t in 1 ..< n - 1 {
					p0, p1, p2 := poly[0], poly[t], poly[t + 1]
					e1, e2 := p1 - p0, p2 - p0
					cr := e1.x * e2.y - e1.y * e2.x
					if cr == 0 do continue
					if cr > 0 do p1, p2 = p2, p1
					append(&pos, [3]f32{p0.x, p0.y, 0}, [3]f32{p1.x, p1.y, 0}, [3]f32{p2.x, p2.y, 0})
					append(&col, c, c, c)
				}
			}
		}
	}
	return tile_mesh(pos[:], col[:])
}

// Once per frame while on: looking around, the chase camera and the raylib camera. Drawing only, frame time is
// fine.
street_camera :: proc(w: ^World) {
	prof_zone(w, .Street_Camera)
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

	look := mouse_delta(w) * STREET_MOUSE_RAD_PER_PX + pad_right_stick(w) * STREET_STICK_RAD_PER_S * dt
	if pad_pressed(w, .RIGHT_THUMB) {
		st.yaw, st.pitch, st.idle_s = 0, 0, 0
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
	if wheel := mouse_wheel(w) + pad_zoom(w) * 3; wheel != 0 {
		if st.dist == 0 do st.dist = w.street_edit.cam_dist_m
		st.dist = clamp(st.dist * (1 - wheel * 0.12), STREET_CAM_MIN_M, STREET_CAM_MAX_M)
	}
	se := &w.street_edit
	dist := st.dist == 0 ? se.cam_dist_m : st.dist

	car := street_ship_pos(w)
	target := car + {0, se.cam_look_up_m, 0}
	yaw := w.car_anim.heading + st.yaw
	// High up the round world's horizon sinks (~22 degrees at 250 m, 46 at 700 m): the camera at rest looks
	// down with it so the land stays in the picture, the horizon STREET_CAM_HORIZON above the middle.
	dip := math.atan(2 * math.sqrt(max(car.y, 0) * street_bend(w, car.y)))
	pitch := max(se.cam_pitch_deg * math.RAD_PER_DEG, dip + STREET_CAM_HORIZON) + st.pitch
	back := [3]f32{-math.sin(yaw) * math.cos(pitch), math.sin(pitch), math.cos(yaw) * math.cos(pitch)}
	goal := target + back * dist
	if !st.seeded {
		st.eye = goal
		st.seeded = true
	}
	st.eye += (goal - st.eye) * (1 - math.exp(-dt * max(se.cam_rate, 0.5)))
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
	speed := clamp(s.speed / w.tune.max_speed, 0, 1)
	st.view = rl.Camera3D {
		position   = st.eye + shake,
		target     = target + shake,
		up         = {0, 1, 0},
		fovy       = se.fov + se.fov_fast * speed * speed,
		projection = .PERSPECTIVE,
	}
}

// The whole street view frame: sky, ground, roads, buildings, trees, the cars, then the HUD.
street_draw :: proc(w: ^World) {
	prof_zone(w, .Street_Draw)
	st := &w.street
	street_build(w)
	street_camera(w)
	look := street_look(w)
	screen := [2]f32{f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())}
	place := street_place(st.origin)
	centre := [2]f32{f32(w.pose.pos.x), f32(w.pose.pos.y)}
	car_anim_update(w, frame_time(w))
	street_shadow_pass(w, place)
	post_on := post_begin(w)
	th := math.tan(st.view.fovy * math.PI / 360)
	render := [2]f32{f32(rl.GetRenderWidth()), f32(rl.GetRenderHeight())}
	tan_half := [2]f32{th * render.x / render.y, th}

	// Sky: every pixel's ray from the camera's axes (STREET_SKY_FS).
	{
		rl.ClearBackground(look.horizon)
		sh := st.sky
		fwd := linalg.normalize(st.view.target - st.view.position)
		right := linalg.normalize(linalg.cross(fwd, [3]f32{0, 1, 0}))
		up := linalg.cross(right, fwd)
		rl.SetShaderValue(sh, st.sky_loc.fwd, &fwd, .VEC3)
		rl.SetShaderValue(sh, st.sky_loc.right, &right, .VEC3)
		rl.SetShaderValue(sh, st.sky_loc.up, &up, .VEC3)
		rl.SetShaderValue(sh, st.sky_loc.tan_half, &tan_half, .VEC2)
		rl.SetShaderValue(sh, st.sky_loc.screen, &render, .VEC2)
		sky_clouds := [2]f32{w.sky_edit.clouds ? w.sky_edit.cloud_amt : 0, f32(w.tick) * SIM_DT}
		rl.SetShaderValue(sh, st.sky_loc.clouds, &sky_clouds, .VEC2)
		street_light_set(w, sh, &st.sky_loc.light, st.view.position)
		rl.BeginShaderMode(sh)
		rl.DrawRectangle(0, 0, i32(screen.x), i32(screen.y), rl.WHITE)
		rl.EndShaderMode()
	}

	near, far := rlgl.GetCullDistanceNear(), rlgl.GetCullDistanceFar()
	rlgl.SetClipPlanes(STREET_NEAR_M, STREET_FAR_M)
	defer rlgl.SetClipPlanes(near, far)
	if st.shadow_tex != 0 {
		rlgl.ActiveTextureSlot(SHADOW_SLOT)
		rlgl.EnableTexture(st.shadow_tex)
		rlgl.ActiveTextureSlot(0)
	}
	rl.BeginMode3D(st.view)
	{
		st.vp_up = (rlgl.GetMatrixProjection() * rlgl.GetMatrixModelview()) * [4]f32{0, 1, 0, 0}
		st.up_vs = (rlgl.GetMatrixModelview() * [4]f32{0, 1, 0, 0}).xyz
		st.bend = street_bend(w, st.view.position.y)
	}
	// Land use and roads lie flat: past the horizon (behind_horizon) nothing of them shows, so only the tiles
	// within it are built and drawn (~0.5 km low over a street, ~1.3 km at 250 m).
	ground_reach := min(STREET_REACH_KM, math.sqrt(max(st.view.position.y, 0) / st.bend) / 1000 + 0.1)
	{
		sh := st.material.shader
		origin := st.origin * 1000
		rl.SetShaderValue(sh, st.loc.origin, &origin, .VEC2)
		street_light_set(w, sh, &st.loc.light, st.view.position)
		cities: [16][3]f32
		for i in 0 ..< min(w.buildings.count, 16) {
			d := (w.buildings.origins[i] - st.origin) * 1000
			cities[i] = {d.x, d.y, BUILDINGS_RADIUS_KM * 1000}
		}
		rl.SetShaderValueV(sh, st.loc.cities, &cities, .VEC3, 16)
		grass_set(w, sh)
		rf := [4]f32 {
			w.rural_edit.fields ? w.rural_edit.field_mix : 0,
			w.rural_edit.field_size,
			w.solar_edit.show ? w.solar_edit.ground_cells : 0,
			0,
		}
		rl.SetShaderValue(sh, st.loc.rural_fields, &rf, .VEC4)

		// 1: land, a quad kept under the car.
		layer, remap: f32 = 0, 0
		rl.SetShaderValue(sh, st.loc.layer, &layer, .FLOAT)
		rl.SetShaderValue(sh, st.loc.remap, &remap, .FLOAT)
		mat := st.material
		{
			car := street_ship_pos(w)
			rl.DrawMesh(st.ground, mat, rl.Matrix(linalg.matrix4_translate_f32({car.x, 0, car.z})))
		}

		// 2: land use with natural colors.
		{
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
			tiles_update_draw(
				w,
				&st.areas,
				STREET_AREA_TILE_KM,
				ground_reach,
				street_area_tile,
				mat,
				centre,
				place,
			)
		}

		// 3: rivers, sidewalks, roads and zebra crossings (layers 1 .. 4, STREET_ROAD_FS).
		road_layer: f32 = 1
		rl.SetShaderValue(st.road.shader, st.road_loc.layer, &road_layer, .FLOAT)
		street_light_set(w, st.road.shader, &st.road_loc.light, st.view.position)
		tiles_update_draw(
			w,
			&st.roads,
			STREET_ROAD_TILE_KM,
			ground_reach,
			street_road_tile,
			st.road,
			centre,
			place,
		)
	}

	// 4: the houses (real and generated, lit, with facades and roofs), then the trees (the map's clumps for now:
	// buildings_draw with no reach only sets their shader's uniforms).
	street_light_set(w, st.lit.shader, &st.lit_loc, st.view.position)
	tiles_update_draw(w, &st.houses, HOUSE_TILE_KM, HOUSE_REACH_KM, houses_build_tile, st.lit, centre, place)
	trees_draw(w, centre, TREES_REACH_KM, st.view.position, false)
	solarpunk_draw(w, centre, PROP_REACH_KM, st.view.position, false)

	// 5: the cars.
	street_light_set(w, st.car.shader, &st.car_loc, st.view.position)
	street_cars(w, &st.car)
	rl.EndMode3D()
	if st.shadow_tex != 0 {
		rlgl.ActiveTextureSlot(SHADOW_SLOT)
		rlgl.DisableTexture()
		rlgl.ActiveTextureSlot(0)
	}
	if post_on do post_end(w, {tan_half = tan_half, up_vs = st.up_vs, eye_h = max(st.view.position.y, 0.1)})

	street_hud(w)
}

// The cars at real size, ours and the others from the presence gossip, with the material of this pass: the car
// shader, or the depth shader of the shadow pass.
street_cars :: proc(w: ^World, mat: ^rl.Material) {
	st := &w.street
	look := street_look(w)
	car := street_ship_pos(w)
	car_draw_street(
		w,
		car,
		w.car_anim,
		rl.WHITE,
		look,
		carpool_is_passenger(w) ? w.plan.partner_skin : w.car_skin,
		mat,
	)
	for o in w.others[:w.other_count] {
		if carpool_is_passenger(w) && o.author == w.plan.partner_pub do continue
		p := others_draw_pos(w, o)
		d := (p - st.origin) * 1000
		if linalg.length(d - car.xz) > STREET_REACH_KM * 1000 do continue
		pos := [3]f32{d.x, max(o.alt - height_at(w, p.x, p.y), 0), d.y}
		an := Car_Anim {
			fly     = o.on_road ? 0 : 1,
			heading = o.heading,
		}
		jam := traffic_near(w, o.pos, o.alt, o.on_road, TRAFFIC_RADIUS_KM) >= TRAFFIC_MIN_CARS
		car_draw_street(w, pos, an, jam ? CAR_JAM_TINT : rl.WHITE, look, o.skin, mat)
	}
}

// The shadow map of this frame (see SHADOW_SIZE), and the light's view-projection in st.light_vp.
street_shadow_pass :: proc(w: ^World, place: Placement) {
	prof_zone(w, .Street_Shadow)
	st := &w.street
	if st.shadow_fbo == 0 || !w.street_edit.shadows do return
	box := max(w.street_edit.shadow_box_m, 40)
	look := street_look(w)
	fwd := st.view.target - st.view.position
	fwd.y = 0
	fwd = linalg.length(fwd) > 1e-3 ? linalg.normalize(fwd) : [3]f32{0, 0, -1}
	c := [3]f32{st.view.position.x, 0, st.view.position.z} + fwd * box * 0.3
	// The light camera's axes as raylib's look-at builds them; the centre moves in whole texels along them.
	z := look.sun_dir
	x := linalg.normalize(linalg.cross([3]f32{0, 1, 0}, z))
	y := linalg.cross(z, x)
	{
		texel := f64(box) / SHADOW_SIZE
		o := [3]f64{f64(st.origin.x) * 1000, 0, f64(st.origin.y) * 1000}
		cw := [3]f64{f64(c.x), f64(c.y), f64(c.z)} + o
		xd := [3]f64{f64(x.x), f64(x.y), f64(x.z)}
		yd := [3]f64{f64(y.x), f64(y.y), f64(y.z)}
		px, py := linalg.dot(cw, xd), linalg.dot(cw, yd)
		cw += xd * (math.round(px / texel) * texel - px) + yd * (math.round(py / texel) * texel - py)
		cw -= o
		c = {f32(cw.x), f32(cw.y), f32(cw.z)}
	}
	cam := rl.Camera3D {
		position   = c + z * SHADOW_LIGHT_M,
		target     = c,
		up         = {0, 1, 0},
		fovy       = box,
		projection = .ORTHOGRAPHIC,
	}
	rt := rl.RenderTexture2D {
		id = st.shadow_fbo,
		texture = {width = SHADOW_SIZE, height = SHADOW_SIZE},
		depth = {id = st.shadow_tex, width = SHADOW_SIZE, height = SHADOW_SIZE},
	}
	rlgl.SetClipPlanes(1, 2 * SHADOW_LIGHT_M)
	rl.BeginTextureMode(rt)
	rl.ClearBackground(rl.WHITE)
	rl.BeginMode3D(cam)
	st.light_vp = rlgl.GetMatrixProjection() * rlgl.GetMatrixModelview()
	centre := st.origin + c.xz / 1000
	reach := box * 0.75 / 1000
	tiles_draw(&st.houses, HOUSE_TILE_KM, reach, st.depth, centre, place)
	trees_draw(w, centre, reach, st.view.position, true)
	solarpunk_draw(w, centre, reach, st.view.position, true)
	street_cars(w, &st.depth)
	rl.EndMode3D()
	rl.EndTextureMode()
	rlgl.SetClipPlanes(STREET_NEAR_M, STREET_FAR_M)
}

// Speed, height and heading bottom left, the keys for a few seconds after switching on. Plain, small, legible.
street_hud :: proc(w: ^World) {
	prof_zone(w, .Street_Hud)
	st := &w.street
	if w.view_edit.peer_names {
		fwd := st.view.target - st.view.position
		car := street_ship_pos(w)
		for o in w.others[:w.other_count] {
			p := others_draw_pos(w, o)
			d := (p - st.origin) * 1000
			if linalg.length(d - car.xz) > STREET_REACH_KM * 1000 do continue
			pos := [3]f32{d.x, max(o.alt - height_at(w, p.x, p.y), 0) + 2.2, d.y}
			if linalg.dot(pos - st.view.position, fwd) <= 0 do continue
			peer_label_draw(w, rl.GetWorldToScreen(pos, st.view), o.author)
		}
	}
	s := &w.ship
	pal := palette(w)
	screen := [2]f32{f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())}
	speed := fmt.tprintf("%d", int(math.round(s.speed * 3.6)))
	height := fmt.tprintf("%d m", int(math.round(max(s.alt - height_at(w, s.pos.x, s.pos.y), 0))))
	compass := [8]string{"N", "NE", "E", "SE", "S", "SW", "W", "NW"}
	// The heading can be negative (ship_step keeps the sign of math.mod), so wrap the index both ways.
	heading := compass[(int(math.round(s.heading / (math.TAU / 8))) % 8 + 8) % 8]

	PAD :: 24
	size := ui_text_size(w, speed, .Figtree_700, 40)
	row_h := max(ui_text_size(w, height, .Roboto_500, 14).y, ui_text_size(w, heading, .Roboto_500, 14).y)
	box_h := max(f32(92), 12 + size.y + 4 + row_h + 12)
	box := rl.Rectangle{PAD, screen.y - PAD - box_h, 210, box_h}
	round_rect(w, box, 14, rl.ColorAlpha(pal.surface, 0.72))
	ui_decorate_rect(w, box, 14, 0.72)
	ui_text(w, {box.x + 18, box.y + 12}, speed, .Figtree_700, 40, pal.text)
	ui_text(w, {box.x + 22 + size.x, box.y + 32}, "km/h", .Roboto_500, 14, pal.text_2)
	row_y := box.y + 12 + size.y + 4
	ui_text(w, {box.x + 18, row_y}, height, .Roboto_500, 14, pal.text_2)
	ui_text(w, {box.x + 110, row_y}, heading, .Roboto_500, 14, pal.text_2)
	if w.nav.active && !w.nav.manual {
		ui_text(w, {box.x + 150, row_y}, "auto", .Roboto_500, 14, pal.accent)
	}
	bat := ui_battery_badge(w, max(f32(SPEED_CIRCLE), box_h))
	ui_battery_circle(w, {box.x + box.width + 14 + bat.dia / 2, box.y + box_h / 2}, bat.dia, bat, 0.72)

	if w.street.on_s < STREET_HINT_S {
		alpha := 1 - clamp((w.street.on_s - (STREET_HINT_S - 1)) / 1, 0, 1)
		KB_HINT :: "W/S throttle and brake   A/D turn   Space/Shift up and down   Mouse look around   Scroll out or fly high: map"
		PAD_HINT :: "R2 gas   L2 brake/reverse   L-stick steer   R1/L1 up/down   R-stick look   D-pad down or Circle: map"
		hint_txt := w.pad.connected ? PAD_HINT : KB_HINT
		hint := ui_text_size(w, hint_txt, .Roboto_500, 14)
		r := rl.Rectangle{(screen.x - hint.x) / 2 - 14, PAD, hint.x + 28, hint.y + 16}
		round_rect(w, r, 10, rl.ColorAlpha(pal.surface, 0.72 * alpha))
		ui_text(w, {r.x + 14, r.y + 8}, hint_txt, .Roboto_500, 14, rl.ColorAlpha(pal.text, alpha))
	}
}

street_tab :: proc(w: ^World, x, y, width: f32, drag: ^int) -> f32 {
	e := &w.street_edit
	def := w.setting_defaults.street
	prev_dist := e.cam_dist_m
	cur_y := settings_toggles(w, x, y, width, {{"Sun shadows", &e.shadows}})
	rows := [?]Editor_Slider {
		{"Shadow box", &e.shadow_box_m, def.shadow_box_m, 100, 1000, "%.0f m"},
		{"Camera distance", &e.cam_dist_m, def.cam_dist_m, STREET_CAM_MIN_M, 25, "%.1f m"},
		{"Look-up height", &e.cam_look_up_m, def.cam_look_up_m, 0, 4, "%.2f m"},
		{"Camera pitch", &e.cam_pitch_deg, def.cam_pitch_deg, 0, 40, "%.1f deg"},
		{"Camera follow", &e.cam_rate, def.cam_rate, 1, 20, "%.1f /s"},
		{"Field of view", &e.fov, def.fov, 40, 90, "%.0f deg"},
		{"Speed FOV boost", &e.fov_fast, def.fov_fast, 0, 30, "%.0f deg"},
		{"Horizon curve", &e.curve_tall_m, def.curve_tall_m, 5, 100, "%.0f m"},
		{"Haze density", &e.haze_per_km, def.haze_per_km, 0, 2, "%.2f /km"},
		{"Haze max", &e.haze_max, def.haze_max, 0, 1, "%.2f"},
		{"Enter street at", &e.switch_low_m, def.switch_low_m, 20, 200, "%.0f m"},
		{"Leave street at", &e.switch_high_m, def.switch_high_m, 40, 300, "%.0f m"},
	}
	out_y := settings_sliders(w, x, cur_y, width, rows[:], drag, 1, 2)
	if abs(e.cam_dist_m - prev_dist) > 1e-4 do w.street.dist = e.cam_dist_m
	return out_y
}
