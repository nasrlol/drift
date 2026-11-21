// author: nasr
package game

import rl "vendor:raylib"

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

PALETTES :: [Theme]Palette {
	.Day = {
		background = {245, 245, 245, 255},
		lines = {.Border = {80, 80, 80, 255}, .River = {0, 121, 241, 255}, .Motorway = {255, 161, 0, 255}},
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

// The whole map is one static mesh, uploaded once and drawn with one call. Drawing it as line strips sent
// 36k points through the raylib batch every frame (8.6 ms). Each segment is a quad of two triangles whose
// corners sit on the segment ends; the vertex shader pushes them sideways in screen space, so lines are
// LINE_PX wide at every zoom. Built on the first frame because it needs the window, so never in headless.
Map_Mesh :: struct {
	mesh:       rl.Mesh,
	material:   rl.Material,
	loc_screen: i32,
	loc_colors: i32,
	built:      bool,
}

// vertexNormal carries the other end of the segment (xy) and the side to push this corner to (z), seen from
// this corner's own end. vertexColor.r is the Map_Kind, the colors come from the palette as a uniform,
// so switching the theme does not rebuild the mesh.
MAP_VS :: `#version 330
in vec3 vertexPosition;
in vec3 vertexNormal;
in vec4 vertexColor;
uniform mat4 mvp;
uniform vec2 screen;
uniform vec4 colors[3];
out vec4 fragColor;
const float LINE_PX = 1.0;
void main() {
	vec4 a = mvp * vec4(vertexPosition, 1.0);
	vec4 b = mvp * vec4(vertexNormal.xy, 0.0, 1.0);
	vec2 d = (b.xy - a.xy) * screen;
	vec2 n = vec2(-d.y, d.x) / max(length(d), 1e-6);
	a.xy += n * vertexNormal.z * LINE_PX / screen;
	gl_Position = a;
	fragColor = colors[int(vertexColor.r * 255.0 + 0.5)];
}
`

MAP_FS :: `#version 330
in vec4 fragColor;
out vec4 finalColor;
void main() {
	finalColor = fragColor;
}
`

// GPU objects only exist when the mesh was built (a window is open). The CPU arrays were freed after the
// upload and set to nil, so UnloadMesh only releases the GPU buffers.
map_mesh_unload :: proc(mm: ^Map_Mesh) {
	if !mm.built do return
	rl.UnloadMesh(mm.mesh)
	rl.UnloadMaterial(mm.material)
	mm^ = {}
}
