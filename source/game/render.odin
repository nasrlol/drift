// author: nasr
package game

import rl "vendor:raylib"

WIND_PARTICLES :: 900
WIND_LIFE_S :: 3.0
// Screen speed per m/s of wind, the same at every zoom: a 10 m/s wind moves a particle 40 px/s.
WIND_PX_PER_MS :: 4.0
WIND_TRAIL_S :: 0.8 // trail length = the distance covered in this time
WIND_WIDTH_PX :: 2.0
WIND_CALM_MS :: 0.5 // slower particles are not drawn
// Random spawn points tried per particle until one lies in Belgium. In a view that is half abroad, 1 in 256
// particles misses and waits a frame.
WIND_SPAWN_TRIES :: 8

// Drawing only, never read by the simulation, so frame time is fine here. Positions in km, spread over the
// visible part of the map; a particle respawns there when it leaves the view or gets older than WIND_LIFE_S.
// Zero is valid: seeded = false spreads all of them, with random ages, on the next frame.
Wind_Particles :: struct {
	x, y, vx, vy, age: [WIND_PARTICLES]f32,
	rand:              u32, // LCG state, seeded so a run looks the same every time
	seeded:            bool,
}

// 0 <= result < 1. Numerical Recipes LCG: good enough to scatter particles, starts fine from zero.
wind_rand :: proc(p: ^Wind_Particles) -> f32 {
	p.rand = p.rand * 1664525 + 1013904223
	return f32(p.rand >> 8) / (1 << 24)
}

// Every color that is drawn comes from the palette: the design's token table (docs/drift-design.pdf, "Kleuren"),
// code never uses a hex value directly. Light only (Lars, 2026-11-21: "alleen light mode, doe de dark mode overal
// weg"). World keeps a copy of PALETTE, refreshed every frame: a pointer into this library's constants would
// dangle after a hot reload.
Palette :: struct {
	surface:          rl.Color, // panels, cards, buttons
	surface_2:        rl.Color, // input fields, hover
	surface_3:        rl.Color, // toggle off
	text:             rl.Color, // main text
	text_2:           rl.Color, // secondary text, icons
	line:             rl.Color, // borders, dividers
	accent:           rl.Color, // chosen chip, Start, links
	accent_strong:    rl.Color, // chosen route bubble, chosen row
	green:            rl.Color, // Greenest time, leaf, energy
	banner:           rl.Color, // instruction banner
	banner_2:         rl.Color, // "Then" tab
	red:              rl.Color, // Exit, destination pin
	warning:          rl.Color, // warning pill, gust icon
	reroute:          rl.Color, // banner while rerouting
	arrived:          rl.Color, // banner on arrival
	sheet:            rl.Color, // navigation bottom sheet
	chip:             rl.Color, // stat chips in the sheet
	bubble:           rl.Color, // road sign on the map
	bubble_text:      rl.Color, // road sign text
	pill:             rl.Color, // road pill under the ship
	// map (design "Kaart" table)
	land:             rl.Color,
	city:             rl.Color,
	park:             rl.Color,
	farmland:         rl.Color,
	marsh:            rl.Color,
	beach:            rl.Color,
	water:            rl.Color,
	roof:             rl.Color,
	wall:             rl.Color,
	tree:             rl.Color, // tree clumps in the parks and woods (nature.odin), our color
	motorway:         rl.Color,
	motorway_casing:  rl.Color,
	main_road:        rl.Color,
	main_road_casing: rl.Color,
	street:           rl.Color,
	street_casing:    rl.Color,
	track:            rl.Color,
	track_casing:     rl.Color,
	route:            rl.Color,
	route_casing:     rl.Color,
	alt_route:        rl.Color,
	alt_route_casing: rl.Color,
	sky:              rl.Color,
	horizon:          rl.Color,
	// labels and markers (design "Labels en markers")
	area_label:       rl.Color,
	water_label:      rl.Color,
	label_halo:       rl.Color,
	shield:           rl.Color,
	shield_border:    rl.Color,
	shield_text:      rl.Color,
	hub:              rl.Color,
	// wind trails by speed (design "Windsporen"): below 6 m/s, to 10, to 14, above
	wind_calm:        rl.Color,
	wind_mint:        rl.Color,
	wind_yellow:      rl.Color,
	wind_coral:       rl.Color,
}

// Road colors come from the map table in docs/drift-design.pdf: main road = trunk + primary, street =
// secondary + tertiary, the casing color (the white fill would vanish on the background while lines are 1 px
// without casings).
PALETTE :: Palette {
	surface          = {255, 255, 255, 255},
	surface_2        = {241, 243, 244, 255},
	surface_3        = {232, 234, 237, 255},
	text             = {32, 33, 36, 255},
	text_2           = {95, 99, 104, 255},
	line             = {218, 220, 224, 255},
	accent           = {26, 115, 232, 255},
	accent_strong    = {26, 115, 232, 255},
	green            = {24, 128, 56, 255},
	banner           = {15, 107, 95, 255},
	banner_2         = {11, 90, 80, 255},
	red              = {229, 65, 59, 255},
	warning          = {249, 171, 0, 255},
	reroute          = {60, 64, 67, 255},
	arrived          = {19, 115, 51, 255},
	sheet            = {255, 255, 255, 255},
	chip             = {241, 243, 244, 255},
	bubble           = {255, 255, 255, 255},
	bubble_text      = {32, 33, 36, 255},
	pill             = {26, 115, 232, 255},
	land             = {239, 236, 229, 255},
	city             = {231, 227, 219, 255},
	park             = {200, 232, 196, 255},
	farmland         = {238, 241, 217, 255},
	marsh            = {211, 236, 220, 255},
	beach            = {246, 237, 207, 255},
	water            = {159, 212, 246, 255},
	roof             = {244, 241, 236, 255},
	wall             = {216, 211, 203, 255},
	tree             = {118, 178, 106, 255},
	motorway         = {253, 217, 130, 255},
	motorway_casing  = {226, 180, 82, 255},
	main_road        = {255, 255, 255, 255},
	main_road_casing = {211, 206, 197, 255},
	street           = {255, 255, 255, 255},
	street_casing    = {219, 214, 206, 255},
	track            = {251, 250, 247, 255},
	track_casing     = {227, 223, 215, 255},
	route            = {26, 115, 232, 255},
	route_casing     = {20, 86, 181, 255},
	alt_route        = {159, 189, 236, 255},
	alt_route_casing = {117, 151, 212, 255},
	sky              = {188, 220, 242, 255},
	horizon          = {230, 239, 242, 255},
	area_label       = {60, 64, 67, 255},
	water_label      = {58, 110, 170, 255},
	label_halo       = {255, 255, 255, 255},
	shield           = {255, 255, 255, 255},
	shield_border    = {154, 160, 166, 255},
	shield_text      = {32, 33, 36, 255},
	hub              = {47, 125, 109, 255},
	wind_calm        = {95, 99, 104, 255},
	wind_mint        = {24, 160, 120, 255},
	wind_yellow      = {214, 160, 0, 255},
	wind_coral       = {226, 90, 70, 255},
}

// The palette, refreshed at the start of every frame (game_update).
palette :: proc(w: ^World) -> ^Palette {
	return &w.palette
}

LABEL_PX :: 10
LABEL_GAP_PX :: 2 // space kept free around a label, so two labels never touch

// A dot with its name in screen space. Collected per frame into the frame arena, culled, then drawn in one pass.
Label :: struct {
	dot:   [2]f32,
	rect:  rl.Rectangle, // the text, LABEL_GAP_PX bigger on every side
	text:  cstring,
	shown: bool, // false: it overlaps an earlier label, only the dot is drawn
}

// Map lines and wind trails are line meshes drawn by one shader. Each segment is a quad of two triangles
// whose corners sit on the segment ends; the vertex shader pushes them sideways in screen space, so lines are
// 1 px wide at every zoom. The map is static: built once, drawn with one call. Drawing it as line strips sent
// 36k points through the raylib batch every frame (8.6 ms). The wind mesh is rewritten every frame, one call
// too (1500 DrawLineV calls cost 0.5 ms). Built on the first frame because it needs the window, so never
// in headless.
Line_Meshes :: struct {
	map_lines:       rl.Mesh,
	wind:            rl.Mesh,
	material:        rl.Material,
	loc_screen:      i32,
	loc_colors:      i32,
	loc_widths:      i32,
	loc_fog_c:       i32,
	loc_fog_r:       i32,
	loc_bias:        i32,
	// ground layers (plan_ui layers_draw_ground): a vertex colored grid over the map
	ground:          rl.Mesh,
	ground_material: rl.Material,
	// land use (draw order 1): the baked area triangles, vertex colors from the palette
	areas:           rl.Mesh,
	// hillshade (terrain map type): one quad over the map with the baked shading as a texture
	hill:            rl.Mesh,
	hill_material:   rl.Material,
	built:           bool,
}

// The ground layer grid: a vertex every GROUND_CELL_KM over the map.
GROUND_CELL_KM :: 8
GROUND_W :: MAP_W_KM / GROUND_CELL_KM + 2
GROUND_H :: MAP_H_KM / GROUND_CELL_KM + 2
GROUND_VERTICES :: (GROUND_W - 1) * (GROUND_H - 1) * 6

// The grid points of quad (gx, gy) as two triangles, counter-clockwise on the map.
ground_quad :: proc(gx, gy: int) -> [6][2]int {
	return {{gx, gy}, {gx, gy + 1}, {gx + 1, gy + 1}, {gx, gy}, {gx + 1, gy + 1}, {gx + 1, gy}}
}

// Line colors and widths are uniform arrays: the Map_Kind entries, then the four wind trail colors. Switching the
// zooming rebuilds nothing; the casing pass draws the same mesh again with the casing colors and wider
// widths, so every casing lies under every fill (design: casings first, then fills).
WIND_COLOR :: len(Map_Kind)
WIND_COLOR_COUNT :: 4
LINE_COLORS :: len(Map_Kind) + WIND_COLOR_COUNT
WIND_VERTICES :: WIND_PARTICLES * 6
#assert(LINE_COLORS == 11) // colors[11], widths[11] in LINE_VS

// Every vertex of a segment quad carries both ends: vertexPosition = A, vertexNormal.xy = B (km on the ground).
// Which corner it is follows from gl_VertexID % 6: A-, B-, B+ and A-, B+, A+, counter-clockwise on screen
// whatever the direction of the segment. The ends are projected (with the perspective divide, so a tilted
// camera works), the quad is pushed sideways by half the width in pixels and lengthened by half the width at
// both ends, so thick lines meet without gaps at bends. A segment with an end behind the camera or a width of
// 0 is dropped. vertexColor.r is the index into colors and widths, vertexColor.a scales the alpha. Far away
// lines fade into the horizon color (fog_color, fog over the clip w range fog_range). vertexColor.g 255 draws
// the segment dashed (LINE_DASH_ON_PX / LINE_DASH_OFF_PX on screen): vertexTexCoord is then the distance along
// its line in km at A and at B, turned into screen pixels with the segment's own scale.
LINE_DASH_ON_PX :: 7
LINE_DASH_OFF_PX :: 5
LINE_VS :: `#version 330
in vec3 vertexPosition;
in vec3 vertexNormal;
in vec4 vertexColor;
in vec2 vertexTexCoord;
uniform mat4 mvp;
uniform vec2 screen;
uniform vec4 colors[11];
uniform float widths[11];
uniform vec3 fog_color;
uniform vec2 fog_range;
uniform float depth_bias;
out vec4 fragColor;
noperspective out float along_px;
flat out int dashed;
const float AT_B[6] = float[6](0.0, 1.0, 1.0, 0.0, 1.0, 0.0);
const float SIDE[6] = float[6](-1.0, -1.0, 1.0, -1.0, 1.0, 1.0);
void main() {
	int k = gl_VertexID % 6;
	int ci = int(vertexColor.r * 255.0 + 0.5);
	float width = widths[ci];
	vec4 a = mvp * vec4(vertexPosition, 1.0);
	vec4 b = mvp * vec4(vertexNormal, 1.0);
	if (a.w < 0.001 || b.w < 0.001 || width <= 0.0) {
		gl_Position = vec4(2.0, 2.0, 2.0, 1.0);
		fragColor = vec4(0.0);
		return;
	}
	vec2 d = (b.xy / b.w - a.xy / a.w) * screen;
	vec2 dir = d / max(length(d), 1e-6);
	dashed = vertexColor.g > 0.5 ? 1 : 0;
	float km = length(vertexNormal.xy - vertexPosition.xy);
	along_px = mix(vertexTexCoord.x, vertexTexCoord.y, AT_B[k]) * 0.5 * length(d) / max(km, 1e-6);
	vec2 n = vec2(-dir.y, dir.x);
	vec4 p = mix(a, b, AT_B[k]);
	p.xy += (n * SIDE[k] + dir * (AT_B[k] * 2.0 - 1.0)) * width / screen * p.w;
	gl_Position = p;
	// Everything lies on z = 0: each pass sits a little nearer than the one before so it never fights it.
	gl_Position.z -= depth_bias * p.w;
	vec4 c = colors[ci];
	float f = clamp((p.w - fog_range.x) / max(fog_range.y - fog_range.x, 1e-3), 0.0, 1.0);
	fragColor = vec4(mix(c.rgb, fog_color, f * f), c.a * vertexColor.a);
}
`

LINE_FS :: `#version 330
in vec4 fragColor;
noperspective in float along_px;
flat in int dashed;
uniform float dash_on;
uniform float dash_off;
out vec4 finalColor;
void main() {
	if (dashed == 1 && mod(along_px, dash_on + dash_off) > dash_on) discard;
	finalColor = fragColor;
}
`

// A border point lies at sea when the surface model is 0 all round it (terrain.odin: sea is exactly 0), so
// polders at sea level (De Moeren on the French border, a little below or above 0) stay land.
// BORDER_SEA_PROBE_KM apart.
BORDER_SEA_PROBE_KM :: 0.5
BORDER_SEA_MAX_M :: 0.05
border_at_sea :: proc(w: ^World, p: [2]f32) -> bool {
	for dy in -1 ..= 1 {
		for dx in -1 ..= 1 {
			q := p + [2]f32{f32(dx), f32(dy)} * BORDER_SEA_PROBE_KM
			if abs(height_at(w, q.x, q.y)) > BORDER_SEA_MAX_M do return false
		}
	}
	return true
}

// The 6 vertices of segment a-b from index i, the shader places the corners (LINE_VS).
line_quad :: proc(pos, other: [][3]f32, color: [][4]u8, i: int, a, b: [2]f32, c: [4]u8) {
	for k in i ..< i + 6 {
		pos[k] = {a.x, a.y, 0}
		other[k] = {b.x, b.y, 0}
		color[k] = c
	}
}

// The arrays usually live in the frame arena: after the upload the mesh no longer points to them, so raylib
// never frees them and UnloadMesh only releases the GPU buffers.
// along: the km along the line at A and B per vertex, only read for dashed segments (LINE_VS).
line_mesh_upload :: proc(
	pos, other: [][3]f32,
	color: [][4]u8,
	is_dynamic: bool,
	along: [][2]f32 = nil,
) -> rl.Mesh {
	m := rl.Mesh {
		vertexCount   = i32(len(pos)),
		triangleCount = i32(len(pos) / 3),
		vertices      = ([^]f32)(raw_data(pos)),
		normals       = ([^]f32)(raw_data(other)),
		colors        = ([^]u8)(raw_data(color)),
		texcoords     = ([^]f32)(raw_data(along)),
	}
	rl.UploadMesh(&m, is_dynamic)
	m.vertices, m.normals, m.colors, m.texcoords = nil, nil, nil, nil
	return m
}

// GPU objects only exist when the meshes were built (a window is open).
line_meshes_unload :: proc(lm: ^Line_Meshes) {
	if !lm.built do return
	if lm.map_lines.vertexCount > 0 do rl.UnloadMesh(lm.map_lines)
	rl.UnloadMesh(lm.wind)
	rl.UnloadMesh(lm.ground)
	if lm.areas.vertexCount > 0 do rl.UnloadMesh(lm.areas)
	if lm.hill.vertexCount > 0 do rl.UnloadMesh(lm.hill)
	rl.UnloadMaterial(lm.ground_material)
	rl.UnloadMaterial(lm.material)
	lm^ = {}
}

// Land use (draw order 1): one static mesh of the baked area triangles, built once. Each triangle is turned to
// the winding of ground_quad, so back face culling never drops one. Colors per vertex from the palette.
areas_build :: proc(w: ^World, lm: ^Line_Meshes) {
	pts := w.m.area_points
	if len(pts) == 0 do return
	pos := make([][3]f32, len(pts), context.temp_allocator)
	col := make([]rl.Color, len(pts), context.temp_allocator)
	pal := palette(w)
	colors := [Area_Kind]rl.Color {
		.City     = pal.city,
		.Park     = pal.park,
		.Farmland = pal.farmland,
		.Marsh    = pal.marsh,
		.Beach    = pal.beach,
		.Water    = pal.water,
	}
	for a in w.m.areas {
		tri := pts[a.start:][:a.count]
		c := colors[Area_Kind(a.kind)]
		for t := 0; t + 2 < len(tri); t += 3 {
			p0, p1, p2 := tri[t], tri[t + 1], tri[t + 2]
			e1, e2 := p1 - p0, p2 - p0
			if e1.x * e2.y - e1.y * e2.x > 0 do p1, p2 = p2, p1
			base := int(a.start) + t
			pos[base], pos[base + 1], pos[base + 2] = {p0.x, p0.y, 0}, {p1.x, p1.y, 0}, {p2.x, p2.y, 0}
			col[base], col[base + 1], col[base + 2] = c, c, c
		}
	}
	lm.areas = rl.Mesh {
		vertexCount   = i32(len(pts)),
		triangleCount = i32(len(pts) / 3),
		vertices      = ([^]f32)(raw_data(pos)),
		colors        = ([^]u8)(raw_data(col)),
	}
	rl.UploadMesh(&lm.areas, false)
	lm.areas.vertices, lm.areas.colors = nil, nil
}

areas_draw :: proc(w: ^World) {
	lm := &w.line_meshes
	if lm.areas.vertexCount == 0 do return
	rl.DrawMesh(lm.areas, lm.ground_material, rl.Matrix(1))
}

// Shading below this baked value darkens, above it lightens: 180 = cos 45 deg, flat ground under the 45 deg sun.
HILL_FLAT :: 180
HILL_SHADOW_ALPHA :: 130
HILL_LIGHT_ALPHA :: 70

// The hillshade of belgium.bin as one texture on a quad over the whole map (todo: "draw it as one quad"). Shadows
// are black and highlights white with alpha, so it shades whatever land use is under it.
hill_build :: proc(w: ^World, lm: ^Line_Meshes) {
	hs := w.m.hillshade
	if len(hs) != HEIGHT_W * HEIGHT_H do return
	pixels := make([][4]u8, len(hs), context.temp_allocator)
	for v, i in hs {
		if v < HILL_FLAT {
			pixels[i] = {0, 0, 0, u8(f32(HILL_FLAT - v) / HILL_FLAT * HILL_SHADOW_ALPHA)}
		} else {
			pixels[i] = {255, 255, 255, u8(f32(v - HILL_FLAT) / (255 - HILL_FLAT) * HILL_LIGHT_ALPHA)}
		}
	}
	img := rl.Image {
		data    = raw_data(pixels),
		width   = HEIGHT_W,
		height  = HEIGHT_H,
		mipmaps = 1,
		format  = .UNCOMPRESSED_R8G8B8A8,
	}
	tex := rl.LoadTextureFromImage(img)
	rl.SetTextureFilter(tex, .BILINEAR)
	// Two triangles in the winding of ground_quad, texture v follows map y (row 0 = north edge).
	W, H :: f32(MAP_W_KM), f32(MAP_H_KM)
	pos := [6][3]f32{{0, 0, 0}, {0, H, 0}, {W, H, 0}, {0, 0, 0}, {W, H, 0}, {W, 0, 0}}
	uv := [6][2]f32{{0, 0}, {0, 1}, {1, 1}, {0, 0}, {1, 1}, {1, 0}}
	mesh := rl.Mesh {
		vertexCount   = 6,
		triangleCount = 2,
		vertices      = ([^]f32)(&pos),
		texcoords     = ([^]f32)(&uv),
	}
	rl.UploadMesh(&mesh, false)
	mesh.vertices, mesh.texcoords = nil, nil // uploaded, the stack arrays are not kept
	lm.hill = mesh
	lm.hill_material = rl.LoadMaterialDefault()
	rl.SetMaterialTexture(&lm.hill_material, .ALBEDO, tex)
}

hill_draw :: proc(w: ^World) {
	lm := &w.line_meshes
	if lm.hill.vertexCount == 0 || !w.plan.layers.terrain do return
	rl.DrawMesh(lm.hill, lm.hill_material, rl.Matrix(1))
}
