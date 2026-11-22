// author: andrei
package game

import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import rl "vendor:raylib"

// Car skins: the player picks a body in the plan panel, it is saved in CAR_SKIN_PATH and sent with the signed
// presence (Presence.skin), so other players see it too. Concept is the baked Car Concept model (airship.odin).
// The others are generic body types, no brand or logo: a mid-engine sports car, a compact hatchback and a boxy
// off-roader, and for fun a cigarette on wheels (Andrei, 2026-11-21). Their bodies are built here at start-up from a side profile (Body_Key: floor, belt line, roof and
// widths along the car), lofted into a smooth shell with wheel arches, plus a few blobs and boxes for lights,
// grille, bumpers and mirrors. The wheels are the Car Concept wheels, moved and scaled; the vertex colors use
// the shading classes of CAR_FS (alpha 0 matte, 1 paint, 2 glass, 3 metal, 4 light).
Car_Skin :: enum u8 {
	Concept,
	Sport,
	Hatch,
	Offroad,
	Cigarette,
	Dirigible,
	Solar_Van,
	Buggy,
	Tram,
	Solar_Glider,
	Greenhouse,
	Wind_Sailer,
	Sunbeam,
}
CAR_SKIN_NAMES :: [Car_Skin]string {
	.Concept      = "Concept",
	.Sport        = "Sport",
	.Hatch        = "Hatch",
	.Offroad      = "4x4",
	.Cigarette    = "Smoke",
	.Dirigible    = "Airship",
	.Solar_Van    = "Solar",
	.Buggy        = "Rover",
	.Tram         = "Tram",
	.Solar_Glider = "Glider",
	.Greenhouse   = "Terrarium",
	.Wind_Sailer  = "Sailer",
	.Sunbeam      = "Sunbeam",
}
CAR_SKIN_PATH :: "cache/car_skin.txt"

// Loft resolution: one ring every CAR_STATION_M along the car, CAR_HALF_RING points per side.
CAR_STATION_M :: 0.04
CAR_HALF_RING :: 16
CAR_MAX_STATIONS :: 160
CAR_BLOB_RINGS :: 6
CAR_BLOB_SEGS :: 12
CAR_CYL_SEGS :: 24

CLASS_MATTE :: 0
CLASS_PAINT :: 1
CLASS_GLASS :: 2
CLASS_METAL :: 3
CLASS_LIGHT :: 4
CAR_UNDER :: [4]u8{26, 27, 30, CLASS_MATTE}
CAR_TRIM :: [4]u8{20, 21, 24, CLASS_MATTE}
CAR_GLASS :: [4]u8{24, 32, 42, CLASS_GLASS}
CAR_CHROME :: [4]u8{190, 192, 198, CLASS_METAL}
CAR_HEAD :: [4]u8{235, 238, 230, CLASS_LIGHT}
CAR_TAIL :: [4]u8{200, 16, 22, CLASS_LIGHT}
CAR_AMBER :: [4]u8{240, 140, 20, CLASS_LIGHT}

// Glass on the stretch from this key to the next: side windows, or the whole cabin top (wind screen, rear window).
Body_Glass :: enum u8 {
	None,
	Side,
	Top,
}

// One cross-section of the body, keys run from the nose (largest x) to the tail. Metres in model space.
Body_Key :: struct {
	x:       f32,
	bottom:  f32, // floor height
	belt:    f32, // top of the lower body (bonnet, belt line, boot)
	roof:    f32, // roof height, roof == belt where there is no cabin
	half_w:  f32, // half width of the lower body
	roof_hw: f32, // half width of the roof
	glass:   Body_Glass,
}

Body_Part_Kind :: enum u8 {
	Box,
	Blob, // ellipsoid
	Cylinder, // along x, size = half length, radius in y, radius in z
}

// Lights, grilles, bumpers and mirrors on top of the shell. mirror adds the same part at -z.
Body_Part :: struct {
	kind:   Body_Part_Kind,
	center: [3]f32,
	size:   [3]f32, // half extents (box) or radii (blob)
	color:  [4]u8, // rgb + shading class, paint = the skin's paint
	mirror: bool,
}
PAINT :: [4]u8{0, 0, 0, 255} // marker: use Body_Spec.paint

Body_Spec :: struct {
	keys:             []Body_Key,
	parts:            []Body_Part,
	r_low, r_belt:    f32, // corner radius at the floor and at the belt line
	r_roof, crown:    f32, // roof corner radius, how much the roof and bonnet bulge in the middle
	paint:            [3]u8,
	wheel_x:          [2]f32, // front and rear axle
	wheel_z, wheel_r: f32, // half track, wheel radius
	spare:            bool, // spare wheel on the tail
}

// What car_parts_draw needs of one generated skin.
Skin_Mesh :: struct {
	body:    rl.Mesh,
	wheel_x: [2]f32,
	wheel_z: f32,
	wheel_s: f32, // wheel scale against the Car Concept wheel
	spare:   [3]f32, // pivot of the spare wheel, zero = none
	ready:   bool,
}

SPORT_KEYS :: [?]Body_Key {
	{2.30, 0.30, 0.40, 0.40, 0.66, 0, .None},
	{2.22, 0.18, 0.52, 0.52, 0.86, 0, .None},
	{2.00, 0.13, 0.62, 0.62, 0.97, 0, .None},
	{1.55, 0.12, 0.72, 0.72, 0.99, 0, .None},
	{1.10, 0.12, 0.76, 0.76, 0.97, 0, .None},
	{0.95, 0.12, 0.77, 0.80, 0.96, 0.70, .Top},
	{0.20, 0.12, 0.80, 1.18, 0.95, 0.60, .Side},
	{-0.60, 0.12, 0.84, 1.19, 0.97, 0.57, .None},
	{-0.95, 0.12, 0.89, 1.10, 0.99, 0.52, .None},
	{-1.40, 0.12, 0.93, 0.98, 0.99, 0.40, .None},
	{-1.90, 0.14, 0.94, 0.94, 0.98, 0, .None},
	{-2.18, 0.20, 0.92, 0.92, 0.93, 0, .None},
	{-2.28, 0.32, 0.86, 0.86, 0.86, 0, .None},
}
SPORT_PARTS :: [?]Body_Part {
	{.Blob, {2.08, 0.57, 0.68}, {0.20, 0.03, 0.12}, CAR_HEAD, true},
	{.Box, {2.27, 0.24, 0}, {0.04, 0.07, 0.55}, CAR_TRIM, false}, // intake
	{.Blob, {-2.27, 0.76, 0.66}, {0.03, 0.065, 0.065}, CAR_TAIL, true},
	{.Blob, {-2.27, 0.76, 0.44}, {0.03, 0.065, 0.065}, CAR_TAIL, true},
	{.Box, {-2.18, 0.25, 0}, {0.08, 0.05, 0.55}, CAR_TRIM, false}, // diffuser
	{.Blob, {-2.27, 0.30, 0.16}, {0.04, 0.05, 0.05}, CAR_CHROME, true}, // exhausts
	{.Blob, {0.62, 0.90, 0.92}, {0.08, 0.05, 0.10}, PAINT, true}, // mirror
}
SPORT :: Body_Spec {
	r_low   = 0.08,
	r_belt  = 0.16,
	r_roof  = 0.12,
	crown   = 0.03,
	paint   = {182, 14, 20},
	wheel_x = {1.38, -1.30},
	wheel_z = 0.84,
	wheel_r = 0.35,
}

HATCH_KEYS :: [?]Body_Key {
	{2.25, 0.32, 0.56, 0.56, 0.70, 0, .None},
	{2.16, 0.22, 0.68, 0.68, 0.84, 0, .None},
	{1.90, 0.18, 0.78, 0.78, 0.89, 0, .None},
	{1.40, 0.18, 0.85, 0.85, 0.90, 0, .None},
	{0.95, 0.18, 0.88, 0.88, 0.90, 0, .None},
	{0.85, 0.18, 0.89, 0.95, 0.90, 0.72, .Top},
	{0.10, 0.18, 0.92, 1.40, 0.90, 0.66, .Side},
	{-1.45, 0.18, 0.96, 1.38, 0.90, 0.64, .Top},
	{-2.05, 0.20, 0.98, 1.06, 0.87, 0.56, .None},
	{-2.18, 0.26, 0.96, 0.96, 0.84, 0, .None},
	{-2.25, 0.34, 0.90, 0.90, 0.80, 0, .None},
}
HATCH_PARTS :: [?]Body_Part {
	{.Blob, {2.12, 0.67, 0.62}, {0.14, 0.04, 0.17}, CAR_HEAD, true},
	{.Box, {2.21, 0.42, 0}, {0.04, 0.10, 0.42}, CAR_TRIM, false}, // grille
	{.Box, {-2.18, 0.86, 0.68}, {0.04, 0.06, 0.15}, CAR_TAIL, true},
	{.Box, {-1.90, 1.12, 0}, {0.14, 0.02, 0.58}, PAINT, false}, // spoiler
	{.Box, {-2.20, 0.30, 0}, {0.06, 0.06, 0.70}, CAR_TRIM, false}, // bumper
	{.Blob, {0.78, 0.98, 0.88}, {0.08, 0.05, 0.09}, PAINT, true}, // mirror
}
HATCH :: Body_Spec {
	r_low   = 0.07,
	r_belt  = 0.14,
	r_roof  = 0.10,
	crown   = 0.03,
	paint   = {30, 72, 160},
	wheel_x = {1.36, -1.34},
	wheel_z = 0.77,
	wheel_r = 0.33,
}

OFFROAD_KEYS :: [?]Body_Key {
	{2.36, 0.44, 1.06, 1.06, 0.90, 0, .None},
	{2.33, 0.42, 1.10, 1.10, 0.94, 0, .None},
	{1.15, 0.42, 1.14, 1.14, 0.95, 0, .None},
	{1.08, 0.42, 1.16, 1.24, 0.95, 0.86, .Top},
	{0.90, 0.42, 1.17, 1.91, 0.95, 0.86, .None},
	{0.80, 0.42, 1.17, 1.94, 0.95, 0.86, .Side},
	{-0.02, 0.42, 1.17, 1.95, 0.95, 0.86, .None},
	{-0.14, 0.42, 1.17, 1.95, 0.95, 0.86, .Side},
	{-1.10, 0.42, 1.17, 1.95, 0.95, 0.86, .None},
	{-1.24, 0.42, 1.17, 1.95, 0.95, 0.86, .Side},
	{-2.02, 0.42, 1.17, 1.95, 0.95, 0.86, .None},
	{-2.22, 0.42, 1.16, 1.93, 0.95, 0.85, .None},
	{-2.26, 0.44, 1.14, 1.90, 0.93, 0.83, .None},
}
OFFROAD_PARTS :: [?]Body_Part {
	{.Blob, {2.37, 0.86, 0.67}, {0.05, 0.11, 0.11}, CAR_HEAD, true},
	{.Blob, {2.06, 1.17, 0.88}, {0.06, 0.04, 0.05}, CAR_AMBER, true}, // indicator on the wing
	{.Box, {2.37, 0.80, 0}, {0.03, 0.17, 0.44}, CAR_TRIM, false}, // grille
	{.Box, {2.40, 0.42, 0}, {0.08, 0.09, 0.97}, CAR_TRIM, false}, // bumper
	{.Box, {-2.30, 0.42, 0}, {0.07, 0.09, 0.97}, CAR_TRIM, false},
	{.Box, {-2.27, 0.92, 0.84}, {0.03, 0.16, 0.08}, CAR_TAIL, true},
	{.Box, {1.40, 0.86, 0.97}, {0.50, 0.05, 0.05}, CAR_TRIM, true}, // wheel arch flares
	{.Box, {-1.40, 0.86, 0.97}, {0.50, 0.05, 0.05}, CAR_TRIM, true},
	{.Box, {0, 0.50, 0.99}, {0.85, 0.05, 0.04}, CAR_TRIM, true}, // step
	{.Blob, {0.98, 1.26, 1.0}, {0.07, 0.10, 0.06}, PAINT, true}, // mirror
}
OFFROAD :: Body_Spec {
	r_low   = 0.04,
	r_belt  = 0.05,
	r_roof  = 0.07,
	crown   = 0.015,
	paint   = {58, 68, 50},
	wheel_x = {1.42, -1.42},
	wheel_z = 0.80,
	wheel_r = 0.42,
	spare   = true,
}

// No shell, only cylinders: filter, gold band, paper, ash and a glowing tip, on two axles.
CIG_Y :: 0.66 // axis height
CIG_R :: 0.40
CIG_PARTS :: [?]Body_Part {
	{.Cylinder, {-1.62, CIG_Y, 0}, {0.56, CIG_R, CIG_R}, {196, 128, 58, CLASS_MATTE}, false}, // filter
	{.Cylinder, {-2.18, CIG_Y, 0}, {0.006, CIG_R - 0.03, CIG_R - 0.03}, {228, 214, 184, CLASS_MATTE}, false},
	{.Cylinder, {-1.05, CIG_Y, 0}, {0.03, CIG_R + 0.005, CIG_R + 0.005}, {205, 165, 70, CLASS_METAL}, false},
	{.Cylinder, {0.42, CIG_Y, 0}, {1.44, CIG_R, CIG_R}, {242, 240, 232, CLASS_MATTE}, false}, // paper
	{.Cylinder, {1.99, CIG_Y, 0}, {0.13, CIG_R - 0.01, CIG_R - 0.01}, {120, 116, 110, CLASS_MATTE}, false}, // ash
	{.Blob, {2.12, CIG_Y, 0}, {0.07, CIG_R - 0.07, CIG_R - 0.07}, {255, 96, 24, CLASS_LIGHT}, false}, // glow
	{.Box, {1.35, 0.30, 0}, {0.04, 0.04, 0.62}, CAR_TRIM, false}, // axles
	{.Box, {-1.35, 0.30, 0}, {0.04, 0.04, 0.62}, CAR_TRIM, false},
}
CIGARETTE :: Body_Spec {
	paint   = {242, 240, 232},
	wheel_x = {1.35, -1.35},
	wheel_z = 0.62,
	wheel_r = 0.30,
}

CAR_BRASS :: [4]u8{204, 166, 74, CLASS_METAL}
CAR_COPPER :: [4]u8{198, 128, 68, CLASS_METAL}
CAR_WOOD :: [4]u8{176, 126, 68, CLASS_MATTE}
CAR_SOLAR :: [4]u8{18, 38, 76, CLASS_GLASS}
CAR_CANVAS :: [4]u8{236, 228, 206, CLASS_MATTE}
CAR_CREAM :: [4]u8{238, 232, 214, CLASS_PAINT}

// Solarpunk dirigible: a wheeled wood-and-brass gondola beneath a linen gasbag with twin side nacelles.
DIRIGIBLE_KEYS :: [?]Body_Key {
	{1.95, 0.34, 0.72, 0.72, 0.62, 0, .None},
	{1.80, 0.24, 0.78, 0.84, 0.76, 0.62, .Top},
	{1.15, 0.24, 0.80, 1.24, 0.78, 0.60, .Side},
	{-1.15, 0.24, 0.80, 1.24, 0.78, 0.60, .Top},
	{-1.80, 0.24, 0.78, 0.86, 0.74, 0.56, .None},
	{-1.95, 0.34, 0.72, 0.72, 0.58, 0, .None},
}
DIRIGIBLE_PARTS :: [?]Body_Part {
	{.Blob, {0, 2.15, 0}, {2.35, 0.72, 0.78}, CAR_CANVAS, false}, // envelope
	{.Blob, {2.28, 2.15, 0}, {0.16, 0.22, 0.22}, CAR_BRASS, false}, // nose cap
	{.Cylinder, {0.95, 2.15, 0}, {0.04, 0.67, 0.73}, CAR_BRASS, false}, // hull bands
	{.Cylinder, {-0.95, 2.15, 0}, {0.04, 0.67, 0.73}, CAR_BRASS, false},
	{.Box, {-1.95, 2.26, 0}, {0.36, 0.72, 0.03}, {62, 128, 96, CLASS_PAINT}, false}, // vertical fin
	{.Box, {-1.95, 2.15, 0}, {0.36, 0.03, 0.94}, {62, 128, 96, CLASS_PAINT}, false}, // horizontal fins
	{.Box, {0.85, 1.46, 0.36}, {0.04, 0.30, 0.04}, CAR_BRASS, true}, // gondola struts
	{.Box, {-0.85, 1.46, 0.36}, {0.04, 0.30, 0.04}, CAR_BRASS, true},
	{.Cylinder, {-0.15, 1.38, 0.88}, {0.30, 0.14, 0.14}, CAR_BRASS, true}, // side nacelles
	{.Blob, {-0.46, 1.38, 0.88}, {0.06, 0.11, 0.11}, {90, 230, 255, CLASS_LIGHT}, true}, // nacelle glow
	{.Box, {0, 0.54, 0.79}, {1.20, 0.08, 0.02}, CAR_WOOD, true}, // wood rub rail
	{.Blob, {1.92, 0.62, 0.44}, {0.05, 0.09, 0.09}, CAR_HEAD, true}, // headlamps
	{.Blob, {-1.92, 0.64, 0.44}, {0.04, 0.08, 0.08}, CAR_TAIL, true}, // tail lights
}
DIRIGIBLE :: Body_Spec {
	r_low   = 0.08,
	r_belt  = 0.10,
	r_roof  = 0.12,
	crown   = 0.02,
	paint   = {62, 128, 96},
	wheel_x = {1.30, -1.30},
	wheel_z = 0.76,
	wheel_r = 0.32,
}

// Solarpunk expedition camper van with bamboo trim and a full solar-panel roof array.
SOLAR_VAN_KEYS :: [?]Body_Key {
	{2.24, 0.30, 0.78, 0.78, 0.74, 0, .None},
	{2.10, 0.22, 0.92, 0.96, 0.90, 0.76, .Top},
	{1.45, 0.22, 0.96, 1.62, 0.92, 0.78, .Side},
	{-1.85, 0.22, 0.98, 1.66, 0.92, 0.78, .Top},
	{-2.16, 0.24, 0.96, 1.56, 0.88, 0.74, .None},
	{-2.24, 0.32, 0.90, 0.90, 0.80, 0, .None},
}
SOLAR_VAN_PARTS :: [?]Body_Part {
	{.Box, {0.42, 1.71, 0}, {0.68, 0.03, 0.66}, CAR_SOLAR, false}, // front solar panel
	{.Box, {-1.02, 1.71, 0}, {0.68, 0.03, 0.66}, CAR_SOLAR, false}, // rear solar panel
	{.Box, {-0.30, 1.69, 0.71}, {1.48, 0.04, 0.03}, CAR_CHROME, true}, // roof rack rails
	{.Box, {0, 0.56, 0.92}, {1.50, 0.09, 0.02}, CAR_WOOD, true}, // bamboo side trim
	{.Box, {2.21, 0.52, 0}, {0.04, 0.10, 0.52}, CAR_TRIM, false}, // front grille
	{.Blob, {2.14, 0.76, 0.62}, {0.10, 0.06, 0.13}, CAR_HEAD, true}, // headlamps
	{.Blob, {1.48, 1.62, 0.52}, {0.05, 0.04, 0.07}, CAR_AMBER, true}, // roof markers
	{.Box, {-2.18, 0.78, 0.68}, {0.04, 0.14, 0.09}, CAR_TAIL, true}, // tail lights
	{.Box, {-2.20, 0.30, 0}, {0.06, 0.07, 0.74}, CAR_TRIM, false}, // rear bumper
	{.Blob, {1.20, 1.06, 0.94}, {0.08, 0.06, 0.09}, PAINT, true}, // mirrors
}
SOLAR_VAN :: Body_Spec {
	r_low   = 0.07,
	r_belt  = 0.12,
	r_roof  = 0.14,
	crown   = 0.03,
	paint   = {46, 118, 92},
	wheel_x = {1.38, -1.38},
	wheel_z = 0.82,
	wheel_r = 0.35,
}

// Solarpunk botanical rover: open-wheel buggy with a glass greenhouse bubble and copper roll cage.
BUGGY_KEYS :: [?]Body_Key {
	{2.28, 0.42, 0.68, 0.68, 0.58, 0, .None},
	{2.05, 0.36, 0.80, 0.80, 0.74, 0, .None},
	{1.15, 0.36, 0.90, 0.90, 0.78, 0, .None},
	{-1.25, 0.36, 0.94, 0.94, 0.78, 0, .None},
	{-2.05, 0.38, 0.92, 0.92, 0.70, 0, .None},
	{-2.20, 0.44, 0.84, 0.84, 0.58, 0, .None},
}
BUGGY_PARTS :: [?]Body_Part {
	{.Blob, {0.05, 1.02, 0}, {1.02, 0.50, 0.66}, CAR_GLASS, false}, // greenhouse canopy
	{.Cylinder, {0.05, 1.42, 0.48}, {0.80, 0.035, 0.035}, CAR_COPPER, true}, // copper cage rails
	{.Box, {0.72, 1.15, 0.48}, {0.04, 0.29, 0.04}, CAR_COPPER, true}, // front pillars
	{.Box, {-0.75, 1.15, 0.48}, {0.04, 0.29, 0.04}, CAR_COPPER, true}, // rear pillars
	{.Box, {-1.45, 1.02, 0}, {0.46, 0.12, 0.58}, CAR_SOLAR, false}, // rear solar deck
	{.Box, {2.30, 0.50, 0}, {0.06, 0.06, 0.62}, CAR_COPPER, false}, // front bullbar
	{.Blob, {2.14, 0.76, 0.48}, {0.07, 0.09, 0.09}, CAR_HEAD, true}, // headlamps
	{.Blob, {-2.16, 0.78, 0.46}, {0.05, 0.07, 0.07}, CAR_TAIL, true}, // tail lights
	{.Box, {0, 0.44, 0.82}, {0.72, 0.04, 0.05}, CAR_TRIM, true}, // side rock sliders
}
BUGGY :: Body_Spec {
	r_low   = 0.06,
	r_belt  = 0.12,
	r_roof  = 0.08,
	crown   = 0.02,
	paint   = {218, 158, 38},
	wheel_x = {1.44, -1.40},
	wheel_z = 0.86,
	wheel_r = 0.40,
}

// Solarpunk garden tram: symmetrical rounded transit pod with panoramic glass, cream roof and brass trim.
TRAM_KEYS :: [?]Body_Key {
	{2.26, 0.28, 0.80, 0.80, 0.72, 0, .None},
	{2.10, 0.20, 0.90, 0.96, 0.86, 0.74, .Top},
	{1.65, 0.20, 0.92, 1.56, 0.88, 0.74, .Side},
	{-1.65, 0.20, 0.92, 1.56, 0.88, 0.74, .Top},
	{-2.10, 0.20, 0.90, 0.96, 0.86, 0.74, .None},
	{-2.26, 0.28, 0.80, 0.80, 0.72, 0, .None},
}
TRAM_PARTS :: [?]Body_Part {
	{.Box, {0, 1.60, 0}, {1.50, 0.04, 0.64}, CAR_CREAM, false}, // cream roof cap
	{.Box, {0, 1.72, 0}, {0.42, 0.08, 0.36}, CAR_BRASS, false}, // pantograph base
	{.Box, {0, 1.84, 0}, {0.10, 0.03, 0.62}, CAR_BRASS, false}, // collector bow
	{.Box, {0, 0.88, 0.88}, {1.80, 0.03, 0.02}, CAR_BRASS, true}, // brass belt trim
	{.Blob, {2.22, 0.64, 0.44}, {0.05, 0.10, 0.10}, CAR_HEAD, true}, // headlamps
	{.Blob, {-2.22, 0.64, 0.44}, {0.05, 0.10, 0.10}, CAR_TAIL, true}, // tail lights
	{.Blob, {2.22, 0.64, 0}, {0.04, 0.07, 0.07}, CAR_AMBER, false}, // center lamp
}
TRAM :: Body_Spec {
	r_low   = 0.08,
	r_belt  = 0.10,
	r_roof  = 0.14,
	crown   = 0.03,
	paint   = {38, 132, 98},
	wheel_x = {1.36, -1.36},
	wheel_z = 0.76,
	wheel_r = 0.33,
}

// Solarpunk winged land-glider: sleek mint fuselage, outstretched solar wings and brass wingtip fins.
GLIDER_KEYS :: [?]Body_Key {
	{2.34, 0.30, 0.44, 0.44, 0.32, 0, .None},
	{1.90, 0.24, 0.62, 0.68, 0.66, 0, .None},
	{1.05, 0.22, 0.80, 1.06, 0.74, 0.56, .Top},
	{-0.75, 0.22, 0.84, 1.04, 0.70, 0.54, .Top},
	{-1.75, 0.24, 0.78, 0.82, 0.54, 0, .None},
	{-2.22, 0.34, 0.66, 0.66, 0.38, 0, .None},
}
GLIDER_PARTS :: [?]Body_Part {
	{.Box, {0, 0.68, 1.38}, {0.58, 0.025, 0.74}, CAR_SOLAR, true}, // solar wings
	{.Box, {0, 0.68, 0.68}, {0.64, 0.035, 0.12}, CAR_BRASS, true}, // wing roots
	{.Box, {-0.05, 0.78, 2.12}, {0.50, 0.14, 0.025}, CAR_BRASS, true}, // wingtip fins
	{.Box, {-1.88, 1.18, 0}, {0.38, 0.30, 0.025}, {72, 148, 114, CLASS_PAINT}, false}, // tail fin
	{.Cylinder, {-1.95, 0.54, 0.32}, {0.24, 0.11, 0.11}, CAR_BRASS, true}, // ion ducts
	{.Blob, {-2.18, 0.54, 0.32}, {0.04, 0.08, 0.08}, {90, 230, 255, CLASS_LIGHT}, true}, // tail glow
	{.Blob, {2.24, 0.46, 0.32}, {0.06, 0.06, 0.08}, CAR_HEAD, true}, // headlamps
}
SOLAR_GLIDER :: Body_Spec {
	r_low   = 0.08,
	r_belt  = 0.12,
	r_roof  = 0.14,
	crown   = 0.03,
	paint   = {72, 148, 114},
	wheel_x = {1.34, -1.34},
	wheel_z = 0.78,
	wheel_r = 0.31,
}

// Solarpunk botanical terrarium: timber tub beneath a vaulted glass conservatory full of living greenery.
GREENHOUSE_KEYS :: [?]Body_Key {
	{2.18, 0.30, 0.80, 0.80, 0.72, 0, .None},
	{1.98, 0.22, 0.90, 0.94, 0.86, 0, .None},
	{1.35, 0.22, 0.94, 1.02, 0.90, 0, .None},
	{-1.35, 0.22, 0.94, 1.02, 0.90, 0, .None},
	{-1.98, 0.24, 0.90, 0.94, 0.86, 0, .None},
	{-2.18, 0.30, 0.80, 0.80, 0.72, 0, .None},
}
GREENHOUSE_PARTS :: [?]Body_Part {
	{.Blob, {0, 1.24, 0}, {1.38, 0.56, 0.78}, CAR_GLASS, false}, // vaulted conservatory glass
	{.Cylinder, {0, 1.24, 0}, {0.04, 0.58, 0.80}, CAR_COPPER, false}, // center copper arch
	{.Box, {0, 1.78, 0}, {1.12, 0.04, 0.16}, CAR_COPPER, false}, // ridge vent
	{.Box, {0, 0.54, 0.92}, {1.62, 0.14, 0.025}, CAR_WOOD, true}, // cedar side planks
	{.Blob, {0.52, 1.20, 0.24}, {0.36, 0.26, 0.26}, {74, 148, 70, CLASS_MATTE}, true}, // front foliage
	{.Blob, {-0.48, 1.24, 0.22}, {0.40, 0.30, 0.28}, {96, 166, 78, CLASS_MATTE}, true}, // rear foliage
	{.Blob, {2.12, 0.76, 0.54}, {0.06, 0.09, 0.09}, {255, 212, 110, CLASS_LIGHT}, true}, // warm lanterns
	{.Blob, {-2.12, 0.76, 0.54}, {0.05, 0.08, 0.08}, CAR_TAIL, true}, // tail lights
}
GREENHOUSE :: Body_Spec {
	r_low   = 0.08,
	r_belt  = 0.10,
	r_roof  = 0.08,
	crown   = 0.02,
	paint   = {174, 122, 68},
	wheel_x = {1.34, -1.34},
	wheel_z = 0.82,
	wheel_r = 0.34,
}

// Solarpunk wind-sailer: narrow terracotta land-yacht with tall canvas aero-sail and outrigger solar pods.
SAILER_KEYS :: [?]Body_Key {
	{2.32, 0.34, 0.56, 0.56, 0.26, 0, .None},
	{1.90, 0.26, 0.72, 0.78, 0.62, 0, .None},
	{0.85, 0.24, 0.84, 0.92, 0.72, 0.54, .Top},
	{-1.05, 0.24, 0.84, 0.92, 0.70, 0.52, .Top},
	{-1.95, 0.28, 0.76, 0.82, 0.58, 0, .None},
	{-2.24, 0.36, 0.68, 0.68, 0.42, 0, .None},
}
SAILER_PARTS :: [?]Body_Part {
	{.Box, {-0.12, 1.72, 0}, {0.045, 0.90, 0.045}, CAR_BRASS, false}, // brass mast
	{.Box, {-0.46, 1.80, 0}, {0.58, 0.76, 0.03}, CAR_CANVAS, false}, // linen wing-sail
	{.Box, {-0.46, 1.54, 0}, {0.62, 0.025, 0.045}, CAR_BRASS, false}, // lower batten
	{.Box, {-0.46, 2.08, 0}, {0.50, 0.025, 0.045}, CAR_BRASS, false}, // upper batten
	{.Box, {0, 0.58, 1.02}, {1.24, 0.04, 0.22}, CAR_SOLAR, true}, // solar outriggers
	{.Blob, {2.24, 0.54, 0.42}, {0.06, 0.08, 0.08}, CAR_HEAD, true}, // headlamps
	{.Blob, {-2.18, 0.60, 0.44}, {0.04, 0.08, 0.08}, CAR_TAIL, true}, // tail lights
}
WIND_SAILER :: Body_Spec {
	r_low   = 0.08,
	r_belt  = 0.12,
	r_roof  = 0.10,
	crown   = 0.02,
	paint   = {206, 122, 68},
	wheel_x = {1.36, -1.36},
	wheel_z = 0.84,
	wheel_r = 0.34,
}

// Solarpunk art-nouveau sun-roadster: teal paint, brass cowl and roll hoops, cream cabin and solar decklid.
SUNBEAM_KEYS :: [?]Body_Key {
	{2.26, 0.30, 0.66, 0.66, 0.64, 0, .None},
	{2.04, 0.22, 0.86, 0.88, 0.80, 0, .None},
	{0.95, 0.22, 0.90, 0.94, 0.82, 0.70, .Side},
	{-0.75, 0.22, 0.92, 0.96, 0.82, 0.70, .None},
	{-1.85, 0.24, 0.88, 0.92, 0.76, 0, .None},
	{-2.18, 0.32, 0.80, 0.80, 0.66, 0, .None},
}
SUNBEAM_PARTS :: [?]Body_Part {
	{.Box, {-0.10, 0.96, 0}, {0.72, 0.10, 0.66}, CAR_CREAM, false}, // open cream cockpit
	{.Box, {0.62, 1.18, 0}, {0.04, 0.20, 0.68}, CAR_GLASS, false}, // swept windscreen
	{.Box, {-0.72, 1.18, 0.42}, {0.05, 0.22, 0.05}, CAR_BRASS, true}, // brass roll hoops
	{.Box, {-1.38, 0.94, 0}, {0.52, 0.03, 0.64}, CAR_SOLAR, false}, // rear solar tonneau
	{.Box, {2.24, 0.46, 0}, {0.04, 0.14, 0.42}, CAR_BRASS, false}, // brass radiator grille
	{.Blob, {2.12, 0.72, 0.64}, {0.10, 0.08, 0.09}, CAR_BRASS, true}, // brass lamp shells
	{.Blob, {2.20, 0.72, 0.64}, {0.04, 0.06, 0.06}, CAR_HEAD, true}, // headlamps
	{.Blob, {-2.14, 0.74, 0.58}, {0.04, 0.07, 0.08}, CAR_TAIL, true}, // tail lights
}
SUNBEAM :: Body_Spec {
	r_low   = 0.08,
	r_belt  = 0.14,
	r_roof  = 0.08,
	crown   = 0.02,
	paint   = {48, 124, 114},
	wheel_x = {1.38, -1.36},
	wheel_z = 0.82,
	wheel_r = 0.34,
}

// Vertex data while a body is built, in the scratch arena.
Car_Builder :: struct {
	pos: [dynamic][3]f32,
	nrm: [dynamic][3]f32,
	col: [dynamic][4]u8,
	idx: [dynamic]u16,
}

// Builds the generated skins (Car Concept comes from car.bin). Called by airship_build with the window up.
car_skins_build :: proc(w: ^World, tmp: mem.Allocator) {
	a := &w.airship
	for skin in Car_Skin {
		spec: Body_Spec
		switch skin {
		case .Concept:
			continue
		case .Sport:
			keys, parts := SPORT_KEYS, SPORT_PARTS
			spec = SPORT
			spec.keys, spec.parts = keys[:], parts[:]
			a.skins[skin] = car_body_upload(w, &spec, tmp)
		case .Hatch:
			keys, parts := HATCH_KEYS, HATCH_PARTS
			spec = HATCH
			spec.keys, spec.parts = keys[:], parts[:]
			a.skins[skin] = car_body_upload(w, &spec, tmp)
		case .Offroad:
			keys, parts := OFFROAD_KEYS, OFFROAD_PARTS
			spec = OFFROAD
			spec.keys, spec.parts = keys[:], parts[:]
			a.skins[skin] = car_body_upload(w, &spec, tmp)
		case .Cigarette:
			parts := CIG_PARTS
			spec = CIGARETTE
			spec.parts = parts[:]
			a.skins[skin] = car_body_upload(w, &spec, tmp)
		case .Dirigible:
			keys, parts := DIRIGIBLE_KEYS, DIRIGIBLE_PARTS
			spec = DIRIGIBLE
			spec.keys, spec.parts = keys[:], parts[:]
			a.skins[skin] = car_body_upload(w, &spec, tmp)
		case .Solar_Van:
			keys, parts := SOLAR_VAN_KEYS, SOLAR_VAN_PARTS
			spec = SOLAR_VAN
			spec.keys, spec.parts = keys[:], parts[:]
			a.skins[skin] = car_body_upload(w, &spec, tmp)
		case .Buggy:
			keys, parts := BUGGY_KEYS, BUGGY_PARTS
			spec = BUGGY
			spec.keys, spec.parts = keys[:], parts[:]
			a.skins[skin] = car_body_upload(w, &spec, tmp)
		case .Tram:
			keys, parts := TRAM_KEYS, TRAM_PARTS
			spec = TRAM
			spec.keys, spec.parts = keys[:], parts[:]
			a.skins[skin] = car_body_upload(w, &spec, tmp)
		case .Solar_Glider:
			keys, parts := GLIDER_KEYS, GLIDER_PARTS
			spec = SOLAR_GLIDER
			spec.keys, spec.parts = keys[:], parts[:]
			a.skins[skin] = car_body_upload(w, &spec, tmp)
		case .Greenhouse:
			keys, parts := GREENHOUSE_KEYS, GREENHOUSE_PARTS
			spec = GREENHOUSE
			spec.keys, spec.parts = keys[:], parts[:]
			a.skins[skin] = car_body_upload(w, &spec, tmp)
		case .Wind_Sailer:
			keys, parts := SAILER_KEYS, SAILER_PARTS
			spec = WIND_SAILER
			spec.keys, spec.parts = keys[:], parts[:]
			a.skins[skin] = car_body_upload(w, &spec, tmp)
		case .Sunbeam:
			keys, parts := SUNBEAM_KEYS, SUNBEAM_PARTS
			spec = SUNBEAM
			spec.keys, spec.parts = keys[:], parts[:]
			a.skins[skin] = car_body_upload(w, &spec, tmp)
		}
	}
}

car_body_upload :: proc(w: ^World, spec: ^Body_Spec, tmp: mem.Allocator) -> (s: Skin_Mesh) {
	b := Car_Builder {
		pos = make([dynamic][3]f32, 0, 32768, tmp),
		nrm = make([dynamic][3]f32, 0, 32768, tmp),
		col = make([dynamic][4]u8, 0, 32768, tmp),
		idx = make([dynamic]u16, 0, 65536, tmp),
	}
	if !car_body_build(&b, spec) {
		logf(w, "car", "generated body does not fit one mesh (%d vertices)", len(b.pos))
		return
	}
	indices := make([]u16, len(b.idx), virtual.arena_allocator(&w.perm))
	copy(indices, b.idx[:])
	s.body = rl.Mesh {
		vertexCount   = i32(len(b.pos)),
		triangleCount = i32(len(b.idx) / 3),
		vertices      = cast([^]f32)raw_data(b.pos),
		normals       = cast([^]f32)raw_data(b.nrm),
		colors        = cast([^]u8)raw_data(b.col),
		indices       = raw_data(indices),
	}
	rl.UploadMesh(&s.body, false)
	s.body.vertices, s.body.normals, s.body.colors = nil, nil, nil
	s.wheel_x = spec.wheel_x
	s.wheel_z = spec.wheel_z
	s.wheel_s = spec.wheel_r / CAR_WHEEL_R
	if spec.spare do s.spare = {spec.keys[len(spec.keys) - 1].x - 0.16, 1.02, 0}
	s.ready = true
	return
}

// The shell (when the skin has keys), then the parts. False when it needs more vertices than one u16 mesh holds.
car_body_build :: proc(b: ^Car_Builder, spec: ^Body_Spec) -> bool {
	paint := [4]u8{spec.paint.r, spec.paint.g, spec.paint.b, CLASS_PAINT}
	if len(spec.keys) >= 2 do car_shell_build(b, spec, paint)
	for part in spec.parts {
		c := part.color == PAINT ? paint : part.color
		for side in ([2]f32{1, -1}) {
			if side < 0 && !part.mirror do break
			center := part.center
			center.z *= side
			switch part.kind {
			case .Box:
				car_box(b, center, part.size, c)
			case .Blob:
				car_blob(b, center, part.size, c)
			case .Cylinder:
				car_cylinder(b, center, part.size, c)
			}
		}
	}
	return len(b.pos) <= 65535
}

// Lofts the shell along the keys, with wheel arches and wheel well liners.
car_shell_build :: proc(b: ^Car_Builder, spec: ^Body_Spec, paint: [4]u8) {
	keys := spec.keys
	x0, x1 := keys[0].x, keys[len(keys) - 1].x
	count := min(int(math.ceil((x0 - x1) / CAR_STATION_M)) + 1, CAR_MAX_STATIONS)
	st: [CAR_MAX_STATIONS]Body_Key
	for i in 0 ..< count {
		x := x0 + (x1 - x0) * f32(i) / f32(count - 1)
		k := 0
		for k < len(keys) - 2 && keys[k + 1].x > x do k += 1
		a, c := keys[k], keys[k + 1]
		t := clamp((a.x - x) / max(a.x - c.x, 1e-4), 0, 1)
		st[i] = {
			x       = x,
			bottom  = math.lerp(a.bottom, c.bottom, t),
			belt    = math.lerp(a.belt, c.belt, t),
			roof    = math.lerp(a.roof, c.roof, t),
			half_w  = math.lerp(a.half_w, c.half_w, t),
			roof_hw = math.lerp(a.roof_hw, c.roof_hw, t),
			glass   = a.glass,
		}
	}
	// Two [1 2 1] passes round the corners between keys, the ends stay where the keys put them.
	for _ in 0 ..< 2 {
		prev := st[0]
		for i in 1 ..< count - 1 {
			cur := st[i]
			next := st[i + 1]
			st[i].bottom = (prev.bottom + 2 * cur.bottom + next.bottom) / 4
			st[i].belt = (prev.belt + 2 * cur.belt + next.belt) / 4
			st[i].roof = (prev.roof + 2 * cur.roof + next.roof) / 4
			st[i].half_w = (prev.half_w + 2 * cur.half_w + next.half_w) / 4
			st[i].roof_hw = (prev.roof_hw + 2 * cur.roof_hw + next.roof_hw) / 4
			prev = cur
		}
	}
	// Wheel arches: the floor goes up round each wheel, so the wheel shows from the side.
	arch_r := spec.wheel_r * 1.08 + 0.03
	for i in 0 ..< count {
		for wx in spec.wheel_x {
			d := st[i].x - wx
			if abs(d) >= arch_r do continue
			top := spec.wheel_r + math.sqrt(arch_r * arch_r - d * d)
			st[i].bottom = max(st[i].bottom, min(top, st[i].belt - 0.12))
		}
	}

	grid: [CAR_MAX_STATIONS][CAR_HALF_RING][3]f32
	for i in 0 ..< count do grid[i] = body_ring(st[i], spec)
	norms: [CAR_MAX_STATIONS][CAR_HALF_RING][3]f32
	for i in 0 ..< count {
		for j in 0 ..< CAR_HALF_RING {
			ds := grid[min(i + 1, count - 1)][j] - grid[max(i - 1, 0)][j]
			dj := grid[i][min(j + 1, CAR_HALF_RING - 1)] - grid[i][max(j - 1, 0)]
			p := grid[i][j]
			out := p - {p.x, (st[i].bottom + st[i].roof) / 2, 0}
			n := linalg.normalize0(linalg.cross(ds, dj))
			if linalg.length(n) < 0.5 do n = linalg.normalize0(out)
			if linalg.dot(n, out) < 0 do n = -n
			norms[i][j] = n
		}
	}
	for i in 0 ..< count - 1 {
		for j in 0 ..< CAR_HALF_RING - 1 {
			c := paint
			switch {
			case j == 0:
				c = CAR_UNDER
			case j == 9 && st[i].glass != .None:
				c = CAR_GLASS
			case j >= 10 && st[i].glass == .Top:
				c = CAR_GLASS
			}
			p := [4][3]f32{grid[i][j], grid[i + 1][j], grid[i + 1][j + 1], grid[i][j + 1]}
			n := [4][3]f32{norms[i][j], norms[i + 1][j], norms[i + 1][j + 1], norms[i][j + 1]}
			ref := n[0] + n[1] + n[2] + n[3]
			car_quad(b, p, n, c, ref)
			for k in 0 ..< 4 {
				p[k].z = -p[k].z
				n[k].z = -n[k].z
			}
			ref.z = -ref.z
			car_quad(b, p, n, c, ref)
		}
	}
	// Nose and tail caps: a fan from the middle of the end ring.
	for end in ([2]int{0, count - 1}) {
		ring := grid[end]
		dir: f32 = end == 0 ? 1 : -1
		mid := [3]f32{ring[0].x, (st[end].bottom + st[end].roof) / 2, 0}
		n := [3]f32{dir, 0, 0}
		for j in 0 ..< CAR_HALF_RING - 1 {
			for side in ([2]f32{1, -1}) {
				p1, p2 := ring[j], ring[j + 1]
				p1.z *= side
				p2.z *= side
				car_tri(b, {mid, p1, p2}, n, paint)
			}
		}
	}
	// Wheel well liners: dark walls inside the arches from the axle up, so one cannot look through the car. They
	// stay under the bonnet: the top is a little below the lowest belt line over the arch.
	for wx in spec.wheel_x {
		top := spec.wheel_r + arch_r
		for i in 0 ..< count do if abs(st[i].x - wx) < arch_r do top = min(top, st[i].belt - 0.04)
		low := spec.wheel_r
		mid, half := (top + low) / 2, max(top - low, 0.01) / 2
		car_box(b, {wx, mid, spec.wheel_z - 0.16}, {arch_r, half, 0.01}, CAR_UNDER)
		car_box(b, {wx, mid, -(spec.wheel_z - 0.16)}, {arch_r, half, 0.01}, CAR_UNDER)
	}
}

// Right half of a cross-section (z >= 0), from the middle of the floor round to the middle of the roof:
// 0-1 floor, 1-4 lower corner, 4-6 side, 6-8 belt corner, 8-9 window sill, 9-10 side window, 10-15 roof.
// Without a cabin (roof == belt) the window points fold onto the belt corner and 10-15 is the bonnet or boot.
body_ring :: proc(s: Body_Key, spec: ^Body_Spec) -> (r: [CAR_HALF_RING][3]f32) {
	b, belt, hw := s.bottom, s.belt, s.half_w
	low := belt - b
	rb := min(spec.r_low, low * 0.3)
	rs := min(spec.r_belt, low * 0.3, hw * 0.5)
	cabin := max(s.roof - belt, 0)
	k := clamp(cabin / 0.3, 0, 1)
	cb := hw - rs
	tw := math.lerp(cb, s.roof_hw > 0 ? s.roof_hw : cb, k)
	rr := min(spec.r_roof, cabin * 0.4, tw * 0.5)
	top := belt + cabin
	zy: [CAR_HALF_RING][2]f32
	zy[0] = {0, b}
	zy[1] = {hw - rb, b}
	for a, i in ([3]f32{-60, -30, 0}) {
		rad := a * math.RAD_PER_DEG
		zy[2 + i] = {hw - rb + rb * math.cos(rad), b + rb + rb * math.sin(rad)}
	}
	zy[5] = {hw, (b + rb + belt - rs) / 2}
	zy[6] = {hw, belt - rs}
	for a, i in ([2]f32{45, 90}) {
		rad := a * math.RAD_PER_DEG
		zy[7 + i] = {cb + rs * math.cos(rad), belt - rs + rs * math.sin(rad)}
	}
	sill := [2]f32{cb, belt}
	corner := [2]f32{tw, top - rr}
	zy[9] = math.lerp(sill, corner, f32(0.15))
	zy[10] = math.lerp(sill, corner, f32(0.85))
	zy[11] = corner
	zy[12] = {tw - rr + rr * math.cos(f32(math.PI / 4)), top - rr + rr * math.sin(f32(math.PI / 4))}
	zy[13] = {tw - rr, top}
	zy[14] = {(tw - rr) / 2, top + spec.crown * 0.75}
	zy[15] = {0, top + spec.crown}
	for p, i in zy do r[i] = {s.x, p.y, p.x}
	return
}

// Appends a quad p0 p1 p2 p3 (in order round it), wound so its front faces ref.
car_quad :: proc(b: ^Car_Builder, p: [4][3]f32, n: [4][3]f32, c: [4]u8, ref: [3]f32) {
	base := u16(len(b.pos))
	for k in 0 ..< 4 {
		append(&b.pos, p[k])
		append(&b.nrm, n[k])
		append(&b.col, c)
	}
	face := linalg.cross(p[1] - p[0], p[2] - p[0]) + linalg.cross(p[2] - p[0], p[3] - p[0])
	if linalg.dot(face, ref) >= 0 {
		append(&b.idx, base, base + 1, base + 2, base, base + 2, base + 3)
	} else {
		append(&b.idx, base, base + 2, base + 1, base, base + 3, base + 2)
	}
}

car_tri :: proc(b: ^Car_Builder, p: [3][3]f32, n: [3]f32, c: [4]u8) {
	base := u16(len(b.pos))
	for k in 0 ..< 3 {
		append(&b.pos, p[k])
		append(&b.nrm, n)
		append(&b.col, c)
	}
	if linalg.dot(linalg.cross(p[1] - p[0], p[2] - p[0]), n) >= 0 {
		append(&b.idx, base, base + 1, base + 2)
	} else {
		append(&b.idx, base, base + 2, base + 1)
	}
}

car_box :: proc(b: ^Car_Builder, center, half: [3]f32, c: [4]u8) {
	for axis in 0 ..< 3 {
		for side in ([2]f32{1, -1}) {
			n: [3]f32
			n[axis] = side
			u, v: [3]f32
			u[(axis + 1) % 3] = half[(axis + 1) % 3]
			v[(axis + 2) % 3] = half[(axis + 2) % 3]
			f := center + n * half[axis]
			car_quad(b, {f - u - v, f + u - v, f + u + v, f - u + v}, {n, n, n, n}, c, n)
		}
	}
}

// A closed cylinder along x: the round side and two flat ends.
car_cylinder :: proc(b: ^Car_Builder, center, size: [3]f32, c: [4]u8) {
	ring :: proc(center, size: [3]f32, seg: int) -> (p, n: [3]f32) {
		ph := math.TAU * f32(seg) / CAR_CYL_SEGS
		u := [3]f32{0, math.cos(ph), math.sin(ph)}
		return center + u * size, linalg.normalize0(u / size)
	}
	front, back := [3]f32{size.x, 0, 0}, [3]f32{-size.x, 0, 0}
	for j in 0 ..< CAR_CYL_SEGS {
		p0, n0 := ring(center, size, j)
		p1, n1 := ring(center, size, j + 1)
		car_quad(b, {p0 + front, p0 + back, p1 + back, p1 + front}, {n0, n0, n1, n1}, c, n0 + n1)
		car_tri(b, {center + front, p0 + front, p1 + front}, {1, 0, 0}, c)
		car_tri(b, {center + back, p1 + back, p0 + back}, {-1, 0, 0}, c)
	}
}

car_blob :: proc(b: ^Car_Builder, center, radii: [3]f32, c: [4]u8) {
	point :: proc(center, radii: [3]f32, ring, seg: int) -> (p, n: [3]f32) {
		th := math.PI * f32(ring) / CAR_BLOB_RINGS
		ph := math.TAU * f32(seg) / CAR_BLOB_SEGS
		u := [3]f32{math.sin(th) * math.cos(ph), math.cos(th), math.sin(th) * math.sin(ph)}
		return center + u * radii, linalg.normalize0(u / radii)
	}
	for i in 0 ..< CAR_BLOB_RINGS {
		for j in 0 ..< CAR_BLOB_SEGS {
			p0, n0 := point(center, radii, i, j)
			p1, n1 := point(center, radii, i + 1, j)
			p2, n2 := point(center, radii, i + 1, j + 1)
			p3, n3 := point(center, radii, i, j + 1)
			car_quad(b, {p0, p1, p2, p3}, {n0, n1, n2, n3}, c, n0 + n1 + n2 + n3)
		}
	}
}

// The saved skin, Concept when there is none or it is not a name of CAR_SKIN_NAMES.
car_skin_load :: proc(w: ^World) {
	data, err := os.read_entire_file(CAR_SKIN_PATH, context.temp_allocator)
	if err != nil do return
	name := strings.trim_space(string(data))
	for n, skin in CAR_SKIN_NAMES {
		if n == name do w.car_skin = skin
	}
}

car_skin_save :: proc(w: ^World) {
	names := CAR_SKIN_NAMES
	if err := os.write_entire_file(CAR_SKIN_PATH, transmute([]u8)names[w.car_skin]); err != nil {
		logf(w, "car", "cannot save %s: %v", CAR_SKIN_PATH, err)
	}
}

// Skin of a presence byte from outside: unknown values draw as Concept.
car_skin_of :: proc(b: u8) -> Car_Skin {
	return b < u8(len(Car_Skin)) ? Car_Skin(b) : .Concept
}
