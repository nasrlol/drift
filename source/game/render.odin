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

// Every color that is drawn comes from the palette of the current theme. World keeps the theme, not a pointer
// to the palette: a pointer into this library's constants would dangle after a hot reload.
Theme :: enum u8 {
	Day,
	Night,
}

Palette :: struct {
	background: rl.Color,
	lines:      [Map_Kind]rl.Color,
	city:       rl.Color,
	ship:       rl.Color,
	wind:       rl.Color,
	panel:      rl.Color,
	button:     rl.Color,
	button_hot: rl.Color,
	button_on:  rl.Color,
	text:       rl.Color,
}

// Road colors come from the map table in docs/drift-design.pdf: main road = trunk + primary, street =
// secondary + tertiary. Day uses the casing color, the white fill would vanish on the background while lines
// are 1 px without casings. Night uses the fill.
PALETTES :: [Theme]Palette {
	.Day = {
		background = {245, 245, 245, 255},
		lines = {
			.Border = {80, 80, 80, 255},
			.River = {0, 121, 241, 255},
			.Tertiary = {219, 214, 206, 255},
			.Secondary = {219, 214, 206, 255},
			.Primary = {211, 206, 197, 255},
			.Trunk = {211, 206, 197, 255},
			.Motorway = {255, 161, 0, 255},
		},
		city = {20, 20, 20, 255},
		ship = {230, 41, 55, 255},
		wind = {60, 90, 150, 255},
		panel = {255, 255, 255, 220},
		button = {225, 225, 225, 255},
		button_hot = {200, 200, 200, 255},
		button_on = {150, 190, 240, 255},
		text = {20, 20, 20, 255},
	},
	.Night = {
		background = {18, 22, 30, 255},
		lines = {
			.Border = {150, 150, 165, 255},
			.River = {70, 140, 230, 255},
			.Tertiary = {79, 98, 153, 255},
			.Secondary = {79, 98, 153, 255},
			.Primary = {100, 118, 176, 255},
			.Trunk = {100, 118, 176, 255},
			.Motorway = {230, 150, 40, 255},
		},
		city = {235, 235, 235, 255},
		ship = {255, 90, 90, 255},
		wind = {170, 200, 255, 255},
		panel = {30, 34, 44, 220},
		button = {50, 56, 70, 255},
		button_hot = {70, 78, 96, 255},
		button_on = {60, 100, 160, 255},
		text = {235, 235, 235, 255},
	},
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
#assert(LINE_COLORS == 8) // colors[8] in LINE_VS

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
uniform vec4 colors[8];
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
