package game

WIND_LAYERS :: 3
FORECAST_HOURS :: 9

// Pressure levels 975, 950, 925 hPa, approximate altitude in m.
LAYER_ALT :: [WIND_LAYERS]f32{300, 550, 800}

// x, y in km, layer 0..WIND_LAYERS-1, hour 0..FORECAST_HOURS-1 counted from the snapshot start.
// Returns the direction the wind blows toward, in m/s, in map axes (x east, y south).
wind_at :: proc(w: ^World, x, y: f32, layer, hour: int) -> [2]f32 {
	return {}
}

// Same arguments as wind_at. Returns 0 (calm) .. 1 (very gusty).
gust_at :: proc(w: ^World, x, y: f32, layer, hour: int) -> f32 {
	return 0
}

// x, y in km, hour as in wind_at. Returns cloud cover 0 (clear) .. 1 (overcast).
cloud_at :: proc(w: ^World, x, y: f32, hour: int) -> f32 {
	return 0
}
