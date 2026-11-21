package game

import "core:fmt"
import "core:math"
import "core:mem"

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

// Snapshot file: Weather_Header, then the Weather struct as raw bytes (little endian).
// size is size_of(Weather) when written, so a file from an older layout is rejected instead of misread.
WEATHER_MAGIC :: 0x48545744 // "DWTH"
WEATHER_VERSION :: 1

Weather_Header :: struct {
	magic, version, size, _: u32,
}

// The file is untrusted: wrong size, NaN or out of range values reject the whole snapshot.
weather_from_snapshot :: proc(data: []u8) -> (out: Weather, ok: bool) {
	if len(data) != size_of(Weather_Header) + size_of(Weather) {
		fmt.eprintfln(
			"[weather] snapshot is %d bytes, want %d",
			len(data),
			size_of(Weather_Header) + size_of(Weather),
		)
		return
	}
	h: Weather_Header
	mem.copy(&h, raw_data(data), size_of(h))
	if h.magic != WEATHER_MAGIC || h.version != WEATHER_VERSION || h.size != size_of(Weather) {
		fmt.eprintfln(
			"[weather] snapshot header: magic %x version %d size %d, want %x %d %d",
			h.magic,
			h.version,
			h.size,
			WEATHER_MAGIC,
			WEATHER_VERSION,
			size_of(Weather),
		)
		return
	}
	mem.copy(&out, raw_data(data[size_of(h):]), size_of(out))

	if out.start < TIME_MIN || out.start > TIME_MAX || out.start % 3600 != 0 {
		fmt.eprintfln("[weather] snapshot start %d is not a whole hour in 2020..2100", out.start)
		return
	}
	// Written as !(in range) so NaN fails too.
	for hour in 0 ..< FORECAST_HOURS {
		for layer in 0 ..< WIND_LAYERS {
			for cell in 0 ..< WEATHER_CELLS {
				v := out.wind[hour][layer][cell]
				g := out.gust[hour][layer][cell]
				if !(math.abs(v.x) <= WIND_MAX && math.abs(v.y) <= WIND_MAX && g >= 0 && g <= 1) {
					fmt.eprintfln(
						"[weather] snapshot hour %d layer %d cell %d: wind %v gust %v out of range",
						hour,
						layer,
						cell,
						v,
						g,
					)
					return
				}
			}
		}
		for c, cell in out.cloud[hour] {
			if !(c >= 0 && c <= 1) {
				fmt.eprintfln("[weather] snapshot hour %d cell %d: cloud %v outside 0..1", hour, cell, c)
				return
			}
		}
	}
	return out, true
}
