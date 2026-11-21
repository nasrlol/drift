// author: nasr
package game

import rl "vendor:raylib"

WIND_PARTICLES :: 600
WIND_LIFE_S :: 3.0
// Screen speed per m/s of wind, the same at every zoom: a 10 m/s wind moves a particle 40 px/s.
WIND_PX_PER_MS :: 4.0
WIND_TRAIL_S :: 0.4 // trail length = the distance covered in this time
WIND_CALM_MS :: 0.5 // slower particles are not drawn

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

// Every color that is drawn comes from the palette of the current theme: the design's token table
// (docs/drift-design.pdf, "Kleuren"), code never uses a hex value directly. Night is the design default, so it is
// zero. World keeps the theme and a copy of its palette, refreshed every frame: a pointer into this library's
// constants would dangle after a hot reload.
Theme :: enum u8 {
	Night,
	Day,
}

Palette :: struct {
	surface:       rl.Color, // panels, cards, buttons
	surface_2:     rl.Color, // input fields, hover
	surface_3:     rl.Color, // toggle off
	text:          rl.Color, // main text
	text_2:        rl.Color, // secondary text, icons
	line:          rl.Color, // borders, dividers
	accent:        rl.Color, // chosen chip, Start, links
	accent_strong: rl.Color, // chosen route bubble, chosen row
	green:         rl.Color, // Greenest time, leaf, energy
	banner:        rl.Color, // instruction banner
	banner_2:      rl.Color, // "Then" tab
	red:           rl.Color, // Exit, destination pin
	warning:       rl.Color, // warning pill, gust icon
	reroute:       rl.Color, // banner while rerouting
	arrived:       rl.Color, // banner on arrival
	sheet:         rl.Color, // navigation bottom sheet
	chip:          rl.Color, // stat chips in the sheet
	bubble:        rl.Color, // road sign on the map
	bubble_text:   rl.Color, // road sign text
	pill:          rl.Color, // road pill under the ship
	// map, until the map colors item
	background:    rl.Color,
	lines:         [Map_Kind]rl.Color,
	wind:          rl.Color,
}

PALETTES :: [Theme]Palette {
	.Night = {
		surface = {32, 33, 36, 255},
		surface_2 = {43, 45, 49, 255},
		surface_3 = {53, 55, 60, 255},
		text = {232, 234, 237, 255},
		text_2 = {154, 160, 166, 255},
		line = {60, 64, 67, 255},
		accent = {138, 180, 248, 255},
		accent_strong = {26, 115, 232, 255},
		green = {52, 208, 122, 255},
		banner = {12, 90, 83, 255},
		banner_2 = {10, 74, 68, 255},
		red = {229, 65, 59, 255},
		warning = {249, 171, 0, 255},
		reroute = {60, 64, 67, 255},
		arrived = {19, 115, 51, 255},
		sheet = {22, 23, 25, 255},
		chip = {35, 36, 39, 255},
		bubble = {143, 227, 255, 255},
		bubble_text = {11, 42, 58, 255},
		pill = {26, 143, 216, 255},
		background = {18, 22, 30, 255},
		lines = {
			.Border = {150, 150, 165, 255},
			.River = {70, 140, 230, 255},
			.Motorway = {230, 150, 40, 255},
		},
		wind = {170, 200, 255, 255},
	},
	.Day = {
		surface = {255, 255, 255, 255},
		surface_2 = {241, 243, 244, 255},
		surface_3 = {232, 234, 237, 255},
		text = {32, 33, 36, 255},
		text_2 = {95, 99, 104, 255},
		line = {218, 220, 224, 255},
		accent = {26, 115, 232, 255},
		accent_strong = {26, 115, 232, 255},
		green = {24, 128, 56, 255},
		banner = {15, 107, 95, 255},
		banner_2 = {11, 90, 80, 255},
		red = {229, 65, 59, 255},
		warning = {249, 171, 0, 255},
		reroute = {60, 64, 67, 255},
		arrived = {19, 115, 51, 255},
		sheet = {255, 255, 255, 255},
		chip = {241, 243, 244, 255},
		bubble = {255, 255, 255, 255},
		bubble_text = {32, 33, 36, 255},
		pill = {26, 115, 232, 255},
		background = {245, 245, 245, 255},
		lines = {.Border = {80, 80, 80, 255}, .River = {0, 121, 241, 255}, .Motorway = {255, 161, 0, 255}},
		wind = {60, 90, 150, 255},
	},
}

// The palette of the current theme. Refreshed at the start of every frame (game_update).
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
	map_lines:  rl.Mesh,
	wind:       rl.Mesh,
	material:   rl.Material,
	loc_screen: i32,
	loc_colors: i32,
	built:      bool,
}

// Line colors are a uniform array: the Map_Kind colors, then the wind. Switching the theme rebuilds nothing.
WIND_COLOR :: len(Map_Kind)
LINE_COLORS :: len(Map_Kind) + 1
WIND_VERTICES :: WIND_PARTICLES * 6
#assert(LINE_COLORS == 4) // colors[4] in LINE_VS

// Every vertex of a segment quad carries both ends: vertexPosition = A, vertexNormal.xy = B. Which corner it is
// follows from gl_VertexID % 6: A-, B-, B+ and A-, B+, A+, counter-clockwise on screen whatever the direction
// of the segment (raylib culls back faces). vertexColor.r is the index into colors, vertexColor.a scales its
// alpha. A zero-length segment gives an invisible quad.
LINE_VS :: `#version 330
in vec3 vertexPosition;
in vec3 vertexNormal;
in vec4 vertexColor;
uniform mat4 mvp;
uniform vec2 screen;
uniform vec4 colors[4];
out vec4 fragColor;
const float LINE_PX = 1.0;
const float AT_B[6] = float[6](0.0, 1.0, 1.0, 0.0, 1.0, 0.0);
const float SIDE[6] = float[6](-1.0, -1.0, 1.0, -1.0, 1.0, 1.0);
void main() {
	int k = gl_VertexID % 6;
	vec4 a = mvp * vec4(vertexPosition.xy, 0.0, 1.0);
	vec4 b = mvp * vec4(vertexNormal.xy, 0.0, 1.0);
	vec2 d = (b.xy - a.xy) * screen;
	vec2 n = vec2(-d.y, d.x) / max(length(d), 1e-6);
	vec4 p = mix(a, b, AT_B[k]);
	p.xy += n * SIDE[k] * LINE_PX / screen;
	gl_Position = p;
	vec4 c = colors[int(vertexColor.r * 255.0 + 0.5)];
	fragColor = vec4(c.rgb, c.a * vertexColor.a);
}
`

LINE_FS :: `#version 330
in vec4 fragColor;
out vec4 finalColor;
void main() {
	finalColor = fragColor;
}
`

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
line_mesh_upload :: proc(pos, other: [][3]f32, color: [][4]u8, is_dynamic: bool) -> rl.Mesh {
	m := rl.Mesh {
		vertexCount   = i32(len(pos)),
		triangleCount = i32(len(pos) / 3),
		vertices      = ([^]f32)(raw_data(pos)),
		normals       = ([^]f32)(raw_data(other)),
		colors        = ([^]u8)(raw_data(color)),
	}
	rl.UploadMesh(&m, is_dynamic)
	m.vertices, m.normals, m.colors = nil, nil, nil
	return m
}

// GPU objects only exist when the meshes were built (a window is open).
line_meshes_unload :: proc(lm: ^Line_Meshes) {
	if !lm.built do return
	if lm.map_lines.vertexCount > 0 do rl.UnloadMesh(lm.map_lines)
	rl.UnloadMesh(lm.wind)
	rl.UnloadMaterial(lm.material)
	lm^ = {}
}
