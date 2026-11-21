package game

WIND_LAYERS :: 3
FORECAST_HOURS :: 9

// Pressure levels 975, 950, 925 hPa, approximate altitude in m.
LAYER_ALT :: [WIND_LAYERS]f32{300, 550, 800}

// Forecast grid points every WEATHER_CELL_KM from the map origin, 9 x 7 covers the 285 x 229 km map.
// Coarse on purpose: Open-Meteo bills every location as one call, see notes.txt.
WEATHER_CELL_KM :: 40
WEATHER_GRID_W :: 9
WEATHER_GRID_H :: 7
WEATHER_CELLS :: WEATHER_GRID_W * WEATHER_GRID_H

// Zero is a calm forecast. Cells are row major, cell = gy * WEATHER_GRID_W + gx.
Weather :: struct {
	start: i64, // unix seconds of hour 0, UTC
	wind:  [FORECAST_HOURS][WIND_LAYERS][WEATHER_CELLS][2]f32,
}

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
