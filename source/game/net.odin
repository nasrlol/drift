// author: andrei
package game

import "base:runtime"
import "core:c"
import "core:crypto"
import "core:crypto/ed25519"
import "core:crypto/hash"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import curl "vendor:curl"

// Static raylib drops libcmt (wants the dynamic CRT), vendor:curl drops msvcrt (wants the static one),
// so a static Windows exe ends up with no CRT at all. Give the dynamic CRT back explicitly.
when ODIN_OS == .Windows && !#config(RAYLIB_SHARED, false) {
	@(require) foreign import windows_crt {"system:msvcrt.lib", "system:vcruntime.lib", "system:ucrt.lib"}
}

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

IDENTITY_PATH :: "cache/identity.key"
SNAPSHOT_PATH :: "cache/weather.snap"
SNAPSHOT_MAGIC :: 0x53575244 // "DRWS"
SNAPSHOT_VERSION :: 1
REFRESH_S :: 15 * 60
RETRY_S :: 5 * 60

// File layout: Snapshot_Header, then the raw bytes of one Weather. hash = sha256 of those Weather bytes.
Snapshot_Header :: struct {
	magic, version: u32,
	fetched_at:     i64, // unix seconds
	hash:           [32]u8,
}

// Zero is valid: no thread, fetch on the first update.
// The thread owns mem and result while it runs. The frame loop only looks at them after is_done.
Fetch :: struct {
	mem:        virtual.Arena,
	thread:     ^thread.Thread,
	cancel:     bool, // atomic, set by the main thread to abort the request
	ok:         bool,
	result:     Snapshot_Header,
	weather:    Weather,
	next:       i64, // unix seconds of the next fetch
	fetched_at: i64, // of the snapshot in w.weather
}

// Blocking HTTP request, call it from a thread, never from the frame loop.
// Fills out only when the whole response is valid. All allocations go to scratch, the caller frees it.
// Returns false within about a second after cancel^ becomes true.
fetch_weather :: proc(out: ^Weather, scratch: mem.Allocator, cancel: ^bool) -> bool {
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
		check_cancel :: proc "c" (cancel: rawptr, _, _, _, _: curl.off_t) -> c.int {
			return sync.atomic_load((^bool)(cancel)) ? 1 : 0
		}
		curl.easy_setopt(h, .URL, url)
		curl.easy_setopt(h, .NOPROGRESS, c.long(0))
		curl.easy_setopt(h, .XFERINFOFUNCTION, check_cancel)
		curl.easy_setopt(h, .XFERINFODATA, cancel)
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

// game_init loads SNAPSHOT_PATH, headless mode its --snapshot file.
// A missing or bad snapshot leaves w.weather as it was (zero at startup: calm, fetch now) and returns false.
weather_load_snapshot :: proc(w: ^World, path: string) -> bool {
	f := &w.fetch
	defer virtual.arena_free_all(&f.mem)
	data, err := os.read_entire_file(path, virtual.arena_allocator(&f.mem))
	if err != nil {
		logf(w, "weather", "no snapshot at %s (%v)", path, err)
		return false
	}
	want := size_of(Snapshot_Header) + size_of(Weather)
	if len(data) != want {
		logf(w, "weather", "%s is %d bytes, want %d, ignored", path, len(data), want)
		return false
	}
	h := (^Snapshot_Header)(raw_data(data))
	if h.magic != SNAPSHOT_MAGIC || h.version != SNAPSHOT_VERSION {
		logf(w, "weather", "%s has magic %x version %d, ignored", path, h.magic, h.version)
		return false
	}
	digest: [32]u8
	hash.hash_bytes_to_buffer(.SHA256, data[size_of(Snapshot_Header):], digest[:])
	if digest != h.hash {
		logf(w, "weather", "%s hash mismatch, file is corrupt, ignored", path)
		return false
	}
	snap := (^Weather)(raw_data(data[size_of(Snapshot_Header):]))
	if !weather_valid(snap) {
		logf(w, "weather", "%s has values out of range, ignored", path)
		return false
	}
	w.weather = snap^
	w.weather_hash = h.hash
	f.fetched_at = h.fetched_at
	f.next = h.fetched_at + REFRESH_S
	logf(w, "weather", "loaded %s, start %d, fetched at %d", path, w.weather.start, h.fetched_at)
	return true
}

// Called every frame. Starts a fetch thread when one is due, takes over its result when it is done.
weather_poll :: proc(w: ^World) {
	f := &w.fetch
	now := time.time_to_unix(time.now())
	if f.thread == nil {
		if now < f.next do return
		f.cancel = false
		f.ok = false
		context.allocator = virtual.arena_allocator(&f.mem)
		f.thread = thread.create(fetch_thread)
		if f.thread == nil {
			logf(w, "weather", "cannot create fetch thread")
			f.next = now + RETRY_S
			return
		}
		f.thread.data = w
		thread.start(f.thread)
		return
	}
	if !thread.is_done(f.thread) do return
	thread.destroy(f.thread)
	f.thread = nil
	virtual.arena_free_all(&f.mem)
	if !f.ok {
		f.next = now + RETRY_S
		logf(w, "weather", "fetch failed, keep snapshot from %d, retry in %d s", f.fetched_at, RETRY_S)
		return
	}
	w.weather = f.weather
	w.weather_hash = f.result.hash
	f.fetched_at = f.result.fetched_at
	f.next = now + REFRESH_S
	logf(w, "weather", "new snapshot, start %d, saved to %s", w.weather.start, SNAPSHOT_PATH)
}

// Fetch, hash and save on the worker thread, so the frame loop never waits on network or disk.
fetch_thread :: proc(t: ^thread.Thread) {
	w := (^World)(t.data)
	f := &w.fetch
	if !fetch_weather(&f.weather, virtual.arena_allocator(&f.mem), &f.cancel) do return
	f.result.magic = SNAPSHOT_MAGIC
	f.result.version = SNAPSHOT_VERSION
	f.result.fetched_at = time.time_to_unix(time.now())
	hash.hash_bytes_to_buffer(.SHA256, mem.ptr_to_bytes(&f.weather), f.result.hash[:])

	// Write to a temp file and rename, so a crash never leaves a half written snapshot.
	if err := os.make_directory("cache"); err != nil && err != .Exist {
		fmt.eprintln("[weather] cannot create cache/:", err)
	}
	file: [size_of(Snapshot_Header) + size_of(Weather)]u8
	mem.copy(&file[0], &f.result, size_of(Snapshot_Header))
	mem.copy(&file[size_of(Snapshot_Header)], &f.weather, size_of(Weather))
	tmp := SNAPSHOT_PATH + ".tmp"
	if err := os.write_entire_file(tmp, file[:]); err != nil {
		fmt.eprintfln("[weather] cannot write %s: %v, snapshot used but not saved", tmp, err)
	} else if err = os.rename(tmp, SNAPSHOT_PATH); err != nil {
		fmt.eprintfln("[weather] cannot rename %s to %s: %v", tmp, SNAPSHOT_PATH, err)
	}
	f.ok = true
}

// Before a reload and at shutdown: the thread runs code from this library, it must end first.
weather_stop :: proc(w: ^World) {
	f := &w.fetch
	if f.thread != nil {
		t := time.tick_now()
		sync.atomic_store(&f.cancel, true)
		thread.destroy(f.thread)
		f.thread = nil
		f.next = 0
		logf(w, "weather", "fetch stopped (reload or shutdown), waited %v", time.tick_since(t))
	}
	virtual.arena_free_all(&f.mem)
}

// Called once from game_init. The 32 byte ed25519 seed in IDENTITY_PATH is the user: offers and reviews
// are signed with it, so a file that exists but is bad is reported and left alone, never replaced.
// Without an identity w.identity stays zero and network features stay off.
identity_load_or_create :: proc(w: ^World) {
	seed: [ed25519.PRIVATE_KEY_SIZE]u8
	defer crypto.zero_explicit(&seed, size_of(seed))

	if os.exists(IDENTITY_PATH) {
		file, err := os.open(IDENTITY_PATH)
		if err != nil {
			logf(w, "net", "cannot open %s: %v, network off", IDENTITY_PATH, err)
			return
		}
		buf: [ed25519.PRIVATE_KEY_SIZE + 1]u8
		n, read_err := os.read(file, buf[:])
		os.close(file)
		copy(seed[:], buf[:])
		crypto.zero_explicit(&buf, size_of(buf))
		if read_err != nil || n != ed25519.PRIVATE_KEY_SIZE {
			logf(
				w,
				"net",
				"%s: read %d bytes (%v), want %d, network off",
				IDENTITY_PATH,
				n,
				read_err,
				ed25519.PRIVATE_KEY_SIZE,
			)
			return
		}
		if !ed25519.private_key_set_bytes(&w.identity, seed[:]) {
			logf(w, "net", "%s is not a valid ed25519 key, network off", IDENTITY_PATH)
			return
		}
	} else {
		if !ed25519.private_key_generate(&w.identity) {
			logf(w, "net", "no system entropy source, cannot create a key, network off")
			return
		}
		ed25519.private_key_bytes(&w.identity, seed[:])
		if err := os.make_directory("cache"); err != nil && err != .Exist {
			logf(w, "net", "cannot create cache/: %v", err)
		}
		// A new temp file gets owner-only permissions, rename keeps them.
		tmp := IDENTITY_PATH + ".tmp"
		os.remove(tmp)
		if err := os.write_entire_file(tmp, seed[:], {.Read_User, .Write_User}); err != nil {
			logf(w, "net", "cannot write %s: %v, key only lives until exit", tmp, err)
		} else if err = os.rename(tmp, IDENTITY_PATH); err != nil {
			logf(w, "net", "cannot rename %s to %s: %v", tmp, IDENTITY_PATH, err)
		}
		logf(w, "net", "created a new identity in %s", IDENTITY_PATH)
	}
	ed25519.private_key_public_bytes(&w.identity, w.identity_pub[:])
	logf(w, "net", "identity %016x", key_short(w.identity_pub))
}

// First 8 bytes of a public key as one number, for logs: "%016x".
key_short :: proc(k: [32]u8) -> (v: u64) {
	for i in 0 ..< 8 do v = v << 8 | u64(k[i])
	return
}
