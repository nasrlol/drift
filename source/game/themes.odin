package game

// Color themes (nasr, 2026-11-22): whole palettes the Colors tab of the settings panel applies at once; single
// colors can be changed after that as usual, and the result is saved and baked like any other setting. Design is
// PALETTE, the default. A new theme is an entry in Theme and a case in theme_palette.
Theme :: enum {
	Design,
	Handmade,
}

theme_palette :: proc(t: Theme) -> Palette {
	switch t {
	case .Design:
		return PALETTE
	case .Handmade:
		return HANDMADE_PALETTE
	}
	return PALETTE
}

// The colors of Casey Muratori's Emacs on Handmade Hero: background #161616, text burlywood3 #CDAA7D, keywords
// DarkGoldenrod3 #CD950C, strings olive drab #6B8E23, comments gray50 #7F7F7F, builtins #DAB98F, the cursor
// #40FF40 and the current line midnight blue #191970. Which color takes which role is ours: panels and land in the
// background greys, text burlywood, the accent and motorways goldenrod, parks and the green roles olive, the
// sea and the banners midnight blue (water a little lighter, so rivers show), the route the cursor green.
HANDMADE_PALETTE :: Palette {
	surface            = {31, 31, 31, 255},
	surface_2          = {42, 42, 42, 255},
	surface_3          = {58, 58, 58, 255},
	text               = {205, 170, 125, 255},
	text_2             = {127, 127, 127, 255},
	line               = {51, 51, 51, 255},
	accent             = {205, 149, 12, 255},
	accent_strong      = {205, 149, 12, 255},
	green              = {107, 142, 35, 255},
	banner             = {25, 25, 112, 255},
	banner_2           = {16, 16, 74, 255},
	red                = {205, 60, 50, 255},
	warning            = {255, 185, 15, 255},
	reroute            = {58, 58, 58, 255},
	arrived            = {75, 107, 18, 255},
	sheet              = {22, 22, 22, 255},
	chip               = {42, 42, 42, 255},
	bubble             = {31, 31, 31, 255},
	bubble_text        = {218, 185, 143, 255},
	pill               = {205, 149, 12, 255},
	land               = {22, 22, 22, 255},
	city               = {30, 28, 26, 255},
	park               = {32, 40, 20, 255},
	farmland           = {27, 27, 21, 255},
	marsh              = {24, 34, 28, 255},
	beach              = {38, 34, 26, 255},
	water              = {38, 38, 140, 255},
	ocean              = {25, 25, 112, 255},
	roof               = {52, 46, 40, 255},
	solar_roof         = {25, 25, 112, 255},
	green_roof         = {85, 107, 47, 255},
	wall               = {34, 31, 27, 255},
	tree               = {85, 107, 47, 255},
	motorway           = {205, 149, 12, 255},
	motorway_casing    = {139, 101, 8, 255},
	main_road          = {139, 115, 85, 255},
	main_road_casing   = {58, 50, 38, 255},
	street             = {84, 72, 58, 255},
	street_casing      = {40, 36, 30, 255},
	track              = {58, 52, 44, 255},
	track_casing       = {36, 31, 26, 255},
	route              = {64, 255, 64, 255},
	route_casing       = {30, 122, 30, 255},
	alt_route          = {107, 142, 35, 255},
	alt_route_casing   = {63, 85, 21, 255},
	green_route        = {141, 179, 58, 255},
	green_route_casing = {63, 85, 21, 255},
	sun                = {205, 149, 12, 255},
	sky                = {12, 12, 12, 255},
	horizon            = {32, 32, 32, 255},
	area_label         = {205, 170, 125, 255},
	water_label        = {123, 123, 216, 255},
	label_halo         = {22, 22, 22, 255},
	shield             = {31, 31, 31, 255},
	shield_border      = {127, 127, 127, 255},
	shield_text        = {218, 185, 143, 255},
	hub                = {107, 142, 35, 255},
	wind_calm          = {127, 127, 127, 255},
	wind_mint          = {141, 179, 58, 255},
	wind_yellow        = {205, 149, 12, 255},
	wind_coral         = {205, 60, 50, 255},
}
