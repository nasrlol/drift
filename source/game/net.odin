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
		for hpa, layer in PRESSURE_HPA {
			fmt.sbprintf(&b, "%swind_speed_%dhPa,wind_direction_%dhPa", layer == 0 ? "" : ",", hpa, hpa)
		}
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
		times, has_times := hourly["time"].(json.Array)
		if !has_hourly || !has_times || len(times) != FORECAST_HOURS {
			fmt.eprintfln("[weather] cell %d: missing hourly data or not %d hours", cell, FORECAST_HOURS)
			return false
		}
		t0, has_t0 := times[0].(json.Float)
		if cell == 0 do w.start = i64(t0)
		if !has_t0 || i64(t0) != w.start {
			fmt.eprintfln("[weather] cell %d: start time %v, cell 0 has %d", cell, times[0], w.start)
			return false
		}
		for hpa, layer in PRESSURE_HPA {
			speed_key := fmt.aprintf("wind_speed_%dhPa", hpa, allocator = scratch)
			dir_key := fmt.aprintf("wind_direction_%dhPa", hpa, allocator = scratch)
			speeds, has_speeds := hourly[speed_key].(json.Array)
			dirs, has_dirs := hourly[dir_key].(json.Array)
			if !has_speeds || !has_dirs || len(speeds) != FORECAST_HOURS || len(dirs) != FORECAST_HOURS {
				fmt.eprintfln(
					"[weather] cell %d: missing wind at %d hPa or not %d hours",
					cell,
					hpa,
					FORECAST_HOURS,
				)
				return false
			}
			for hour in 0 ..< FORECAST_HOURS {
				speed, has_speed := speeds[hour].(json.Float)
				dir, has_dir := dirs[hour].(json.Float)
				if !has_speed || !has_dir {
					fmt.eprintfln(
						"[weather] cell %d, %d hPa, hour %d: speed %v, direction %v are not numbers",
						cell,
						hpa,
						hour,
						speeds[hour],
						dirs[hour],
					)
					return false
				}
				s, rad := f64(speed), f64(dir) * math.RAD_PER_DEG
				w.wind[hour][layer][cell] = {f32(-s * math.sin(rad)), f32(s * math.cos(rad))}
			}
		}
	}
	out^ = w
	return true
}
