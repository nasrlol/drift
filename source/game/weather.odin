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
	gust:  [FORECAST_HOURS][WIND_LAYERS][WEATHER_CELLS]f32, // 0 calm .. 1 very gusty
	cloud: [FORECAST_HOURS][WEATHER_CELLS]f32, // 0 clear .. 1 overcast
}

// x, y in km, layer 0..WIND_LAYERS-1, hour 0..FORECAST_HOURS-1 counted from the snapshot start.
// Returns the direction the wind blows toward, in m/s, in map axes (x east, y south).
// Outside the grid the edge value holds, hours after the last one keep the last forecast.
wind_at :: proc(w: ^World, x, y: f32, layer, hour: int) -> [2]f32 {
	c, fx, fy := weather_cell(x, y)
	g := &w.weather.wind[clamp(hour, 0, FORECAST_HOURS - 1)][clamp(layer, 0, WIND_LAYERS - 1)]
	top := g[c] * (1 - fx) + g[c + 1] * fx
	bottom := g[c + WEATHER_GRID_W] * (1 - fx) + g[c + WEATHER_GRID_W + 1] * fx
	return top * (1 - fy) + bottom * fy
}

// Same arguments as wind_at. Returns 0 (calm) .. 1 (very gusty).
gust_at :: proc(w: ^World, x, y: f32, layer, hour: int) -> f32 {
	c, fx, fy := weather_cell(x, y)
	g := &w.weather.gust[clamp(hour, 0, FORECAST_HOURS - 1)][clamp(layer, 0, WIND_LAYERS - 1)]
	top := g[c] * (1 - fx) + g[c + 1] * fx
	bottom := g[c + WEATHER_GRID_W] * (1 - fx) + g[c + WEATHER_GRID_W + 1] * fx
	return top * (1 - fy) + bottom * fy
}

// x, y in km, hour as in wind_at. Returns cloud cover 0 (clear) .. 1 (overcast).
cloud_at :: proc(w: ^World, x, y: f32, hour: int) -> f32 {
	c, fx, fy := weather_cell(x, y)
	g := &w.weather.cloud[clamp(hour, 0, FORECAST_HOURS - 1)]
	top := g[c] * (1 - fx) + g[c + 1] * fx
	bottom := g[c + WEATHER_GRID_W] * (1 - fx) + g[c + WEATHER_GRID_W + 1] * fx
	return top * (1 - fy) + bottom * fy
}

// Top-left grid point of the square around (x, y) and the bilinear weights inside it.
weather_cell :: proc(x, y: f32) -> (cell: int, fx, fy: f32) {
	gx := clamp(x / WEATHER_CELL_KM, 0, WEATHER_GRID_W - 1)
	gy := clamp(y / WEATHER_CELL_KM, 0, WEATHER_GRID_H - 1)
	ix := min(int(gx), WEATHER_GRID_W - 2)
	iy := min(int(gy), WEATHER_GRID_H - 2)
	return iy * WEATHER_GRID_W + ix, gx - f32(ix), gy - f32(iy)
}

// For snapshots read from disk. Written so that NaN fails every test.
weather_valid :: proc(w: ^Weather) -> bool {
	if w.start % 3600 != 0 do return false
	for &hour in w.wind do for &layer in hour do for v in layer {
		if !(abs(v.x) <= 100 && abs(v.y) <= 100) do return false
	}
	for &hour in w.gust do for &layer in hour do for v in layer {
		if !(v >= 0 && v <= 1) do return false
	}
	for &hour in w.cloud do for v in hour {
		if !(v >= 0 && v <= 1) do return false
	}
	return true
}
