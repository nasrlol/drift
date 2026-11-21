// author: andrei
package game

import "base:runtime"
import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:strings"
import curl "vendor:curl"

OPEN_METEO_URL :: "https://api.open-meteo.com/v1/forecast"
FETCH_TIMEOUT_MS :: 15_000
FETCH_MAX_BYTES :: 1 << 20
PRESSURE_HPA :: [WIND_LAYERS]int{975, 950, 925}
// Gust minus mean wind at 10 m that counts as "very gusty" (index 1 at the lowest layer).
GUST_SPREAD_MAX :: 10.0
// Anything outside these is a broken response, not weather. Times: 2020-01-01 .. 2100-01-01.
WIND_MAX :: 100.0
TIME_MIN :: 1577836800
TIME_MAX :: 4102444800

// Same projection as tools/bake_map, inverted to get the lat / lon of each grid point.
MAP_LON0 :: 2.38
MAP_LAT0 :: 51.56
KM_PER_DEG :: 111.32

// Blocking HTTP request, call it from a thread, never from the frame loop.
// Fills out only when the whole response is valid. All allocations go to scratch, the caller frees it.
fetch_weather :: proc(out: ^Weather, scratch: mem.Allocator) -> bool {
	url: cstring
	{
		cos_lat := math.cos(50.5 * math.RAD_PER_DEG)
		b := strings.builder_make(scratch)
		strings.write_string(&b, OPEN_METEO_URL + "?latitude=")
		for cell in 0 ..< WEATHER_CELLS {
			y := f64(cell / WEATHER_GRID_W * WEATHER_CELL_KM)
			fmt.sbprintf(&b, "%s%.4f", cell == 0 ? "" : ",", MAP_LAT0 - y / KM_PER_DEG)
		}
		strings.write_string(&b, "&longitude=")
		for cell in 0 ..< WEATHER_CELLS {
			x := f64(cell % WEATHER_GRID_W * WEATHER_CELL_KM)
			fmt.sbprintf(&b, "%s%.4f", cell == 0 ? "" : ",", MAP_LON0 + x / (KM_PER_DEG * cos_lat))
		}
		strings.write_string(&b, "&hourly=")
		for hpa in PRESSURE_HPA {
			fmt.sbprintf(&b, "wind_speed_%dhPa,wind_direction_%dhPa,", hpa, hpa)
		}
		strings.write_string(&b, "wind_speed_10m,wind_gusts_10m,cloud_cover")
		fmt.sbprintf(&b, "&forecast_hours=%d&wind_speed_unit=ms", FORECAST_HOURS)
		strings.write_string(&b, "&timezone=GMT&timeformat=unixtime")
		err: mem.Allocator_Error
		if url, err = strings.to_cstring(&b); err != nil {
			fmt.eprintln("[weather] cannot build request url:", err)
			return false
		}
	}

	body := make([dynamic]u8, 0, 64 * 1024, scratch)
	{
		h := curl.easy_init()
		if h == nil {
			fmt.eprintln("[weather] curl easy_init returned nil")
			return false
		}
		defer curl.easy_cleanup(h)

		write_body :: proc "c" (buf: [^]u8, size, n: c.size_t, user: rawptr) -> c.size_t {
			context = runtime.default_context()
			body := (^[dynamic]u8)(user)
			count := int(size * n)
			if len(body) + count > FETCH_MAX_BYTES do return 0
			if _, err := append(body, ..buf[:count]); err != nil do return 0
			return c.size_t(count)
		}
		curl.easy_setopt(h, .URL, url)
		curl.easy_setopt(h, .WRITEFUNCTION, write_body)
		curl.easy_setopt(h, .WRITEDATA, &body)
		curl.easy_setopt(h, .TIMEOUT_MS, c.long(FETCH_TIMEOUT_MS))
		curl.easy_setopt(h, .FAILONERROR, c.long(1))
		curl.easy_setopt(h, .USERAGENT, cstring("drift"))
		if res := curl.easy_perform(h); res != .E_OK {
			fmt.eprintfln(
				"[weather] GET %s failed: %s (%d bytes received, max %d)",
				OPEN_METEO_URL,
				curl.easy_strerror(res),
				len(body),
				FETCH_MAX_BYTES,
			)
			return false
		}
	}

	// Open-Meteo gives meteorological direction (where the wind comes from, degrees clockwise from north).
	// We store the vector it blows toward in map axes: x east, y south.
	w: Weather
	root, jerr := json.parse(body[:], allocator = scratch)
	if jerr != .None {
		fmt.eprintfln("[weather] response is not valid json: %v (%d bytes)", jerr, len(body))
		return false
	}
	locs, is_array := root.(json.Array)
	if !is_array || len(locs) != WEATHER_CELLS {
		fmt.eprintfln("[weather] expected an array of %d locations, got %d", WEATHER_CELLS, len(locs))
		return false
	}
	for loc, cell in locs {
		obj, _ := loc.(json.Object)
		hourly, has_hourly := obj["hourly"].(json.Object)
		if !has_hourly {
			fmt.eprintfln("[weather] cell %d: no hourly object", cell)
			return false
		}
		times := hourly_values(hourly, "time", cell, TIME_MIN, TIME_MAX) or_return
		if cell == 0 do w.start = i64(times[0])
		for t, hour in times {
			expected := w.start + i64(hour) * 3600
			if i64(t) != expected || w.start % 3600 != 0 {
				fmt.eprintfln("[weather] cell %d: hour %d has time %.0f, want %d", cell, hour, t, expected)
				return false
			}
		}
		for hpa, layer in PRESSURE_HPA {
			speed_key := fmt.aprintf("wind_speed_%dhPa", hpa, allocator = scratch)
			dir_key := fmt.aprintf("wind_direction_%dhPa", hpa, allocator = scratch)
			speeds := hourly_values(hourly, speed_key, cell, 0, WIND_MAX) or_return
			dirs := hourly_values(hourly, dir_key, cell, 0, 360) or_return
			for hour in 0 ..< FORECAST_HOURS {
				s, rad := speeds[hour], dirs[hour] * math.RAD_PER_DEG
				w.wind[hour][layer][cell] = {f32(-s * math.sin(rad)), f32(s * math.cos(rad))}
			}
		}
		// Gusts only exist at 10 m. The spread between gust and mean wind, scaled down with height
		// like in the spec (1.08 - alt / 1600), gives the 0..1 gust index per layer.
		mean := hourly_values(hourly, "wind_speed_10m", cell, 0, WIND_MAX) or_return
		gusts := hourly_values(hourly, "wind_gusts_10m", cell, 0, WIND_MAX) or_return
		clouds := hourly_values(hourly, "cloud_cover", cell, 0, 100) or_return
		for hour in 0 ..< FORECAST_HOURS {
			spread := clamp((gusts[hour] - mean[hour]) / GUST_SPREAD_MAX, 0, 1)
			for alt, layer in LAYER_ALT {
				w.gust[hour][layer][cell] = clamp(f32(spread) * (1.08 - alt / 1600), 0, 1)
			}
			w.cloud[hour][cell] = f32(clouds[hour] / 100)
		}
	}
	out^ = w
	return true
}

// Every hourly series must be FORECAST_HOURS numbers in lo..hi. Open-Meteo sends null for missing values.
// The range test is written so that NaN and infinity fail it too.
hourly_values :: proc(
	hourly: json.Object,
	key: string,
	cell: int,
	lo, hi: f64,
) -> (
	v: [FORECAST_HOURS]f64,
	ok: bool,
) {
	a, is_array := hourly[key].(json.Array)
	if !is_array || len(a) != FORECAST_HOURS {
		fmt.eprintfln("[weather] cell %d: %s needs %d values, got %d", cell, key, FORECAST_HOURS, len(a))
		return
	}
	for x, hour in a {
		n, is_number := x.(json.Float)
		if !is_number {
			fmt.eprintfln("[weather] cell %d: %s hour %d is null or not a number", cell, key, hour)
			return
		}
		if !(f64(n) >= lo && f64(n) <= hi) {
			fmt.eprintfln("[weather] cell %d: %s hour %d is %v, outside %v..%v", cell, key, hour, n, lo, hi)
			return
		}
		v[hour] = f64(n)
	}
	return v, true
}
