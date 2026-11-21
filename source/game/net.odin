// author: andrei
package game

import "base:runtime"
import "core:c"
import "core:crypto"
import "core:crypto/chacha20poly1305"
import "core:crypto/ed25519"
import "core:crypto/hash"
import "core:crypto/hkdf"
import "core:crypto/x25519"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:mem/virtual"
import "core:net"
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

// The whole snapshot file (and what peers send) as one struct, no padding between the two parts.
Snapshot :: struct {
	header:  Snapshot_Header,
	weather: Weather,
}
#assert(size_of(Snapshot) == size_of(Snapshot_Header) + size_of(Weather))

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
	snap, why := snapshot_check(data)
	if snap == nil {
		logf(w, "weather", "%s: %s, ignored", path, why)
		return false
	}
	w.weather = snap.weather
	w.weather_hash = snap.header.hash
	f.fetched_at = snap.header.fetched_at
	f.next = snap.header.fetched_at + REFRESH_S
	logf(w, "weather", "loaded %s, start %d, fetched at %d", path, w.weather.start, snap.header.fetched_at)
	return true
}

// The one check for snapshot bytes, from disk or from a peer: size, magic, version, the sha256 in the
// header against the weather bytes, value ranges. data must be 8 byte aligned (arena memory or a Snapshot).
// Returns nil and a constant reason when anything is off.
snapshot_check :: proc(data: []u8) -> (snap: ^Snapshot, why: string) {
	if len(data) != size_of(Snapshot) do return nil, "wrong size"
	snap = (^Snapshot)(raw_data(data))
	if snap.header.magic != SNAPSHOT_MAGIC || snap.header.version != SNAPSHOT_VERSION {
		return nil, "wrong magic or version"
	}
	digest: [32]u8
	hash.hash_bytes_to_buffer(.SHA256, mem.ptr_to_bytes(&snap.weather), digest[:])
	if digest != snap.header.hash do return nil, "hash mismatch, corrupt"
	if !weather_valid(&snap.weather) do return nil, "values out of range"
	return snap, ""
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
	snap := Snapshot {
		header  = f.result,
		weather = f.weather,
	}
	tmp := SNAPSHOT_PATH + ".tmp"
	if err := os.write_entire_file(tmp, mem.ptr_to_bytes(&snap)); err != nil {
		fmt.eprintfln("[weather] cannot write %s: %v, snapshot used but not saved", tmp, err)
	} else if err = os.rename(tmp, SNAPSHOT_PATH); err != nil {
		fmt.eprintfln("[weather] cannot rename %s to %s: %v", tmp, SNAPSHOT_PATH, err)
	}
	// Offers made with this snapshot name its hash, peers will ask for it.
	snap_put(w, &snap)
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

// Carpool messages. Every message is exactly size_of(Message) bytes on the wire and on disk, little endian,
// no implicit padding, so the relay can store and forward them without parsing.
// The signature covers every byte before sig. A message id is the sha256 of all its bytes, sig included.
MSG_MAGIC :: 0x534d5244 // "DRMS"
MSG_VERSION :: 2
MSG_MAX_SEATS :: 8

Msg_Kind :: enum u8 {
	None,
	Offer,
	Request,
	Accept,
	Review,
}

// A driver offers seats from one hub to another, flown with this weather snapshot.
Msg_Offer :: struct {
	from_hub, to_hub: u16le,
	seats:            u8, // free seats, 1..MSG_MAX_SEATS
	mode:             Route_Mode,
	_:                [2]u8,
	depart, arrive:   i64le, // unix seconds
	weather:          [32]u8, // Weather snapshot hash the route was planned with
	energy_kwh:       f32le, // whole trip, so others can recompute and compare
	_:                [4]u8,
}

// A passenger asks for seats on an offer, possibly boarding / leaving at other hubs (detour).
// x25519 is the passenger's half of the trip key exchange (see trip_start), new for every request.
Msg_Request :: struct {
	offer:            [32]u8, // message id
	from_hub, to_hub: u16le,
	seats:            u8,
	_:                [3]u8,
	x25519:           [32]u8,
}

// The driver accepts one request, x25519 is the driver's half of the trip key exchange.
Msg_Accept :: struct {
	offer, request: [32]u8, // message ids
	x25519:         [32]u8,
}

// After a trip, one side rates the other. accept proves the trip was agreed between them.
Msg_Review :: struct {
	subject: [32]u8, // public key of the rated user
	accept:  [32]u8, // message id
	stars:   u8, // 1..5
	_:       [7]u8,
}

Message :: struct {
	magic:   u32le,
	version: u8,
	kind:    Msg_Kind,
	_:       [2]u8,
	time:    i64le, // unix seconds, set by the author
	author:  [32]u8, // ed25519 public key
	using _: struct #raw_union {
		offer:   Msg_Offer,
		request: Msg_Request,
		accept:  Msg_Accept,
		review:  Msg_Review,
	},
	sig:     [64]u8,
}
#assert(size_of(Msg_Offer) == 64 && size_of(Msg_Request) == 72 && size_of(Msg_Accept) == 96)
#assert(size_of(Msg_Review) == 72 && size_of(Message) == 208 && offset_of(Message, sig) == 144)

// Fills magic, version, author and sig. The caller sets kind, time and the body, starting from a zeroed
// Message so unused body bytes are zero. False when this user has no identity yet.
msg_sign :: proc(w: ^World, m: ^Message) -> bool {
	if w.identity_pub == {} {
		logf(w, "net", "cannot sign: no identity")
		return false
	}
	m.magic = MSG_MAGIC
	m.version = MSG_VERSION
	m.author = w.identity_pub
	bytes := mem.ptr_to_bytes(m)
	ed25519.sign(&w.identity, bytes[:offset_of(Message, sig)], m.sig[:])
	return true
}

// Size, header and field ranges, no signature. For the store file, which only ever holds messages that
// passed msg_read before they were written. why is a constant string, "" when ok.
msg_check :: proc(b: []u8) -> (m: Message, why: string) {
	if len(b) != size_of(Message) do return m, "wrong size"
	mem.copy(&m, raw_data(b), size_of(Message))
	if m.magic != MSG_MAGIC do return m, "wrong magic"
	if m.version != MSG_VERSION do return m, "wrong version"
	fields_ok := false
	#partial switch m.kind {
	case .Offer:
		o := m.offer
		fields_ok =
			o.from_hub != o.to_hub &&
			o.seats >= 1 &&
			o.seats <= MSG_MAX_SEATS &&
			o.mode <= max(Route_Mode) &&
			o.arrive > o.depart &&
			o.energy_kwh >= 0 &&
			o.energy_kwh < 1000
	case .Request:
		r := m.request
		fields_ok = r.from_hub != r.to_hub && r.seats >= 1 && r.seats <= MSG_MAX_SEATS && r.x25519 != {}
	case .Accept:
		fields_ok = m.accept.x25519 != {}
	case .Review:
		fields_ok = m.review.stars >= 1 && m.review.stars <= 5
	}
	if !fields_ok do return m, "bad fields"
	return m, ""
}

// For anything that comes from outside: msg_check, then the signature. Runs on network threads too, so it
// returns the reason instead of logging it.
msg_read :: proc(b: []u8) -> (m: Message, why: string) {
	m, why = msg_check(b)
	if why != "" do return
	pub: ed25519.Public_Key
	if !ed25519.public_key_set_bytes(&pub, m.author[:]) do return m, "author is not a valid public key"
	if !ed25519.verify(&pub, b[:offset_of(Message, sig)], m.sig[:]) do return m, "bad signature"
	return m, ""
}

msg_id :: proc(m: ^Message) -> (id: [32]u8) {
	hash.hash_bytes_to_buffer(.SHA256, mem.ptr_to_bytes(m), id[:])
	return
}

// First 8 bytes of a public key as one number, for logs: "%016x".
key_short :: proc(k: [32]u8) -> (v: u64) {
	for i in 0 ..< 8 do v = v << 8 | u64(k[i])
	return
}

// Every message this node knows, written here or received from peers. Peers sync from it, so it is bounded:
// one key holds at most STORE_PER_AUTHOR slots and a full store drops what expires first.
// Order means nothing, removing moves the last message into the hole. Zero is an empty store.
// The network thread writes it and the frame loop reads it, so every access takes lock.
STORE_PATH :: "cache/messages.log"
STORE_MAX :: 4096
STORE_PER_AUTHOR :: 64
MSG_KEEP_S :: 30 * 24 * 3600 // requests, accepts and reviews; an offer is useless after its depart time
MSG_FUTURE_S :: 3600 // allowed clock difference; a time far ahead would outlive every expiry

Store :: struct {
	lock:      sync.Mutex,
	file_lock: sync.Mutex, // both network threads append; taken before lock, never after
	count:     int,
	ids:       [STORE_MAX][32]u8,
	msgs:      [STORE_MAX]Message,
	file_ok:   bool, // the file was read whole (or did not exist), appending to it is safe
	file_msgs: int, // messages in the file, dropped ones included; rewritten at 2 x STORE_MAX
}

Store_Add :: enum u8 {
	Added,
	Duplicate,
	Expired,
	Future,
	Full, // the store is full of messages that all outlive this one
}

msg_expires :: proc(m: ^Message) -> i64 {
	return m.kind == .Offer ? i64(m.offer.depart) : i64(m.time) + MSG_KEEP_S
}

// m must have passed msg_read. Memory only, store_append writes it to the file.
store_add :: proc(s: ^Store, m: ^Message, now: i64) -> Store_Add {
	if msg_expires(m) <= now do return .Expired
	if i64(m.time) > now + MSG_FUTURE_S do return .Future
	id := msg_id(m)
	sync.mutex_lock(&s.lock)
	defer sync.mutex_unlock(&s.lock)
	for i in 0 ..< s.count {
		if s.ids[i] == id do return .Duplicate
	}

	// Make room. An author over the cap loses its oldest message, so its newest ones always get through.
	// A full store first drops what has expired, then what expires soonest, unless that is m itself.
	own, own_oldest := 0, -1
	for i in 0 ..< s.count {
		if s.msgs[i].author != m.author do continue
		own += 1
		if own_oldest < 0 || s.msgs[i].time < s.msgs[own_oldest].time do own_oldest = i
	}
	if own >= STORE_PER_AUTHOR {
		store_remove(s, own_oldest)
	} else if s.count == STORE_MAX {
		for i := 0; i < s.count; {
			if msg_expires(&s.msgs[i]) <= now {
				store_remove(s, i)
			} else {
				i += 1
			}
		}
		if s.count == STORE_MAX {
			first := 0
			for i in 1 ..< s.count {
				if msg_expires(&s.msgs[i]) < msg_expires(&s.msgs[first]) do first = i
			}
			if msg_expires(m) <= msg_expires(&s.msgs[first]) do return .Full
			store_remove(s, first)
		}
	}
	s.ids[s.count] = id
	s.msgs[s.count] = m^
	s.count += 1
	return .Added
}

// Caller holds s.lock.
store_remove :: proc(s: ^Store, i: int) {
	s.count -= 1
	s.ids[i] = s.ids[s.count]
	s.msgs[i] = s.msgs[s.count]
}

// Once at start, on the network thread: ~4k messages are too slow for the first frame.
// The file is messages back to back. It only ever gets messages that passed msg_read, so loading checks
// header and fields, not signatures. A file that is not whole messages (a node killed while appending)
// is not guessed at: it moves to <path>.bad and the store starts empty, peers send the messages again.
// A file that cannot be read is left alone and the store stays memory only this run.
// Then the file is rewritten without expired and dropped messages. All allocations go to scratch.
store_load :: proc(s: ^Store, path: string, now: i64, scratch: mem.Allocator) {
	if os.exists(path) {
		data, err := os.read_entire_file(path, scratch)
		if err != nil {
			fmt.eprintfln("[net] cannot read %s: %v, store not saved this run", path, err)
			return
		}
		if len(data) % size_of(Message) != 0 {
			bad_buf: [256]u8
			bad_path := fmt.bprintf(bad_buf[:], "%s.bad", path)
			fmt.eprintfln(
				"[net] %s: %d bytes is not a multiple of %d, moved to %s, starting empty",
				path,
				len(data),
				size_of(Message),
				bad_path,
			)
			if rerr := os.rename(path, bad_path); rerr != nil {
				fmt.eprintfln("[net] cannot rename %s: %v, store not saved this run", path, rerr)
				return
			}
			data = nil
		}
		added, bad, dropped := 0, 0, 0
		for at := 0; at < len(data); at += size_of(Message) {
			m, why := msg_check(data[at:][:size_of(Message)])
			if why != "" {
				if bad == 0 {
					fmt.eprintfln("[net] %s: message %d: %s, skipped", path, at / size_of(Message), why)
				}
				bad += 1
				continue
			}
			if store_add(s, &m, now) == .Added {
				added += 1
			} else {
				dropped += 1
			}
		}
		fmt.eprintfln(
			"[net] %s: %d messages, %d bad, %d expired / duplicate / over a cap",
			path,
			added,
			bad,
			dropped,
		)
	}
	sync.mutex_lock(&s.file_lock)
	defer sync.mutex_unlock(&s.file_lock)
	s.file_ok = true
	store_rewrite(s, path)
}

// Appends one message that store_add just added. On a network thread, never in the frame loop.
store_append :: proc(s: ^Store, path: string, m: ^Message) {
	sync.mutex_lock(&s.file_lock)
	defer sync.mutex_unlock(&s.file_lock)
	if !s.file_ok do return
	if s.file_msgs >= 2 * STORE_MAX {
		store_rewrite(s, path)
		return
	}
	perm := os.Permissions{.Read_User, .Write_User}
	file, err := os.open(path, {.Write, .Create, .Append}, perm)
	if err != nil {
		fmt.eprintfln("[net] cannot open %s for appending: %v, message kept in memory only", path, err)
		return
	}
	defer os.close(file)
	if _, werr := os.write(file, mem.ptr_to_bytes(m)); werr != nil {
		fmt.eprintfln("[net] cannot write %s: %v, message kept in memory only", path, werr)
		return
	}
	s.file_msgs += 1
}

// The whole store to a temp file, then rename, so a crash leaves the old file or the new one.
// Caller holds s.file_lock.
store_rewrite :: proc(s: ^Store, path: string) {
	if err := os.make_directory("cache"); err != nil && err != .Exist {
		fmt.eprintln("[net] cannot create cache/:", err)
	}
	sync.mutex_lock(&s.lock)
	defer sync.mutex_unlock(&s.lock)
	tmp_buf: [256]u8
	tmp := fmt.bprintf(tmp_buf[:], "%s.tmp", path)
	os.remove(tmp)
	bytes := mem.slice_to_bytes(s.msgs[:s.count])
	if err := os.write_entire_file(tmp, bytes, {.Read_User, .Write_User}); err != nil {
		fmt.eprintfln("[net] cannot write %s: %v", tmp, err)
		return
	}
	if err := os.rename(tmp, path); err != nil {
		fmt.eprintfln("[net] cannot rename %s to %s: %v", tmp, path, err)
		return
	}
	s.file_msgs = s.count
}

// Peer to peer: every game is a node, there is no server. A node listens on NODE_PORT and syncs its store
// with its peers every SYNC_S. Two threads, both blocking with timeouts: serve answers other nodes one
// connection at a time, sync dials peers. Neither runs in the frame loop.
//
// One TCP connection, the dialer asks, the other side answers, until the dialer closes it:
//   both send hello: magic "DRNP" u32le, version u8, listen port u16le (0 = not listening), node id [8]u8
//   'I' since i64le          -> count u32le, count ids (32 bytes): messages with time >= since
//   'G' count u32le, ids     -> count u32le, the messages it has of those (count <= SYNC_BATCH)
//   'P' count u32le, msgs    -> added u32le (count <= SYNC_BATCH)
//   'N'                      -> count u8, count peers: family u8 (4 / 6), address [16]u8, port u16le
//   'W' sha256               -> u8 1 + the Snapshot (22736 bytes), or u8 0 when it does not have it
//   'L' / 'M'                live positions, see node_live
// Sync is by message id, never by position: positions only mean something inside one store.
// Every message from a peer goes through msg_read before store_add, the id of a 'G' answer must be one
// that was asked for.
NODE_PORT :: 7419
NODE_MAGIC :: 0x504e5244 // "DRNP"
NODE_VERSION :: 2 // 2: messages are 208 bytes
NET_TIMEOUT_MS :: 5000
SERVE_MAX_MS :: 30_000 // one connection, so a slow peer cannot keep serve busy
SYNC_S :: 30
SYNC_FULL_S :: 3600 // ask for all ids this often, the rest of the time only the recent ones
SYNC_MARGIN_S :: 600 // messages can arrive a while after their time
SYNC_BATCH :: 64

// Peers: seeds from SEED_NODES and SEEDS_PATH (one "host:port" or "host" per line, # comments), written
// by people. Learned peers come from the peers' 'N' answers and from nodes that dial us (address + the
// listen port in their hello), and are saved to PEERS_PATH so a restart does not start from the seeds.
// A learned peer that fails PEER_FORGET_FAILS syncs in a row (hours, with the back off) is forgotten,
// seeds are kept. A peer whose hello has our own node id is us, behind another address: dropped.
SEED_NODES :: [?]string{} // public nodes that anyone can start from, none yet
SEEDS_PATH :: "cache/seeds.txt"
PEERS_PATH :: "cache/peers.txt"
MAX_PEERS :: 32
PEER_FORGET_FAILS :: 8
PEER_SHARE_S :: 24 * 3600 // 'N' only lists peers that synced this recently
PEER_ENTRY :: 19

Peer :: struct {
	ep:      net.Endpoint,
	seed:    bool,
	next:    i64, // unix s of the next sync
	full_at: i64, // last sync that asked for every id, 0 = never
	last_ok: i64,
	fails:   int, // failed syncs in a row, backs off the next one
}

// Zero is valid: not started, NODE_PORT, no peers. Lives in World, so the threads stop before a reload.
Net_Node :: struct {
	port:         int, // 0 = NODE_PORT; set another one to run two nodes on one machine
	started:      bool,
	loaded:       bool, // store and peer files read, once per run
	id:           [8]u8, // random per run, tells a node it dialed itself
	peers_dirty:  bool, // learned peers changed, write PEERS_PATH
	own:          [4]net.Endpoint, // addresses that turned out to be this node, never added again
	own_count:    int,
	stop:         bool, // atomic
	listening:    bool,
	listener:     net.TCP_Socket,
	server:       ^thread.Thread,
	syncer:       ^thread.Thread,
	mem:          virtual.Arena, // sync thread scratch
	peers_lock:   sync.Mutex,
	peers:        [MAX_PEERS]Peer,
	peer_count:   int,
	snaps_lock:   sync.Mutex, // taken before w.store.lock, never after
	snaps:        [SNAP_KEEP][32]u8, // sha256 of the snapshots in SNAP_DIR
	snap_time:    [SNAP_KEEP]i64, // their fetched_at
	snap_count:   int,
	// Per thread, too big for a thread stack.
	sync_ids:     [STORE_MAX][32]u8,
	sync_msgs:    [SYNC_BATCH]Message,
	serve_ids:    [STORE_MAX][32]u8,
	serve_msgs:   [SYNC_BATCH]Message,
	sync_snap:    Snapshot,
	serve_snap:   Snapshot,
	live_lock:    sync.Mutex,
	live_slots:   [LIVE_SLOTS]Live_Packet, // latest per trip and direction, from anyone (see node_live)
	live_at:      [LIVE_SLOTS]i64, // unix s it arrived, 0 = empty
	live_out:     Live_Packet, // the game's latest, set by live_send
	live_in:      Live_Packet, // the other side's newest, taken by live_poll
	live_has_out: bool,
	live_has_in:  bool,
}

// Called every frame, like weather_poll: starts the node after game start and after every reload.
node_poll :: proc(w: ^World) {
	n := &w.node
	if n.started do return
	n.started = true
	sync.atomic_store(&n.stop, false)
	if n.id == {} do crypto.rand_bytes(n.id[:])
	port := n.port == 0 ? NODE_PORT : n.port
	sock, err := net.listen_tcp({net.IP4_Any, port})
	if err != nil {
		logf(w, "net", "cannot listen on port %d: %v, only dialing out", port, err)
	} else if berr := net.set_blocking(sock, false); berr != nil {
		logf(w, "net", "cannot make the listener non-blocking: %v, only dialing out", berr)
		net.close(sock)
	} else {
		n.listener = sock
		n.listening = true
		n.server = thread.create(node_serve_thread)
		if n.server != nil {
			n.server.data = w
			thread.start(n.server)
		}
	}
	n.syncer = thread.create(node_sync_thread)
	if n.syncer == nil {
		logf(w, "net", "cannot create the sync thread, network off")
		return
	}
	n.syncer.data = w
	thread.start(n.syncer)
	logf(
		w,
		"net",
		"node up, %s port %d, %d peers",
		n.listening ? "listening on" : "not listening,",
		port,
		n.peer_count,
	)
}

// Before a reload and at shutdown. Waits for both threads: at most one network timeout.
node_stop :: proc(w: ^World) {
	n := &w.node
	if !n.started do return
	sync.atomic_store(&n.stop, true)
	if n.server != nil do thread.destroy(n.server)
	if n.syncer != nil do thread.destroy(n.syncer)
	n.server, n.syncer = nil, nil
	if n.listening do net.close(n.listener)
	n.listening = false
	n.started = false
	virtual.arena_free_all(&n.mem)
}

// Adds ep unless it is known. A full list makes room by dropping the learned peer that failed most,
// if any failed at all, so good peers are never pushed out by new names. Safe from any thread.
node_add_peer :: proc(n: ^Net_Node, ep: net.Endpoint, seed: bool) -> bool {
	if ep.port <= 0 || ep.port > 65535 || ep.address == nil do return false
	sync.mutex_lock(&n.peers_lock)
	defer sync.mutex_unlock(&n.peers_lock)
	for own in n.own {
		if own == ep do return false
	}
	for &p in n.peers[:n.peer_count] {
		if p.ep != ep do continue
		p.seed ||= seed
		return false
	}
	if n.peer_count == MAX_PEERS {
		worst := -1
		for p, i in n.peers[:n.peer_count] {
			if !p.seed && p.fails > 0 && (worst < 0 || p.fails > n.peers[worst].fails) do worst = i
		}
		if worst < 0 do return false
		n.peer_count -= 1
		n.peers[worst] = n.peers[n.peer_count]
	}
	n.peers[n.peer_count] = {
		ep   = ep,
		seed = seed,
	}
	n.peer_count += 1
	if !seed do n.peers_dirty = true
	return true
}

node_serve_thread :: proc(t: ^thread.Thread) {
	w := (^World)(t.data)
	n := &w.node
	for !sync.atomic_load(&n.stop) {
		client, source, err := net.accept_tcp(n.listener)
		if err == .Would_Block {
			time.sleep(50 * time.Millisecond)
			continue
		}
		if err != nil {
			fmt.eprintln("[net] accept failed:", err)
			time.sleep(time.Second)
			continue
		}
		// Accepted sockets inherit non-blocking from the listener on BSD / macOS.
		if net.set_blocking(client, true) == nil && net_timeouts(client) {
			node_serve(w, client, source)
		}
		net.close(client)
	}
}

// Answers one connection. Every count from the peer is checked before it sizes a read.
node_serve :: proc(w: ^World, s: net.TCP_Socket, from: net.Endpoint) {
	n := &w.node
	buf: [64]u8
	port, id, ok := node_hello(n, s)
	if !ok || id == n.id do return
	if port != 0 do node_add_peer(n, {from.address, port}, false)
	start := time.tick_now()
	got, gave := 0, 0
	for time.duration_milliseconds(time.tick_since(start)) < SERVE_MAX_MS {
		op: [1]u8
		if !net_recv(s, op[:]) do break
		switch op[0] {
		case 'I':
			since: i64le
			if !net_recv(s, mem.ptr_to_bytes(&since)) do return
			count := 0
			{
				st := &w.store
				sync.mutex_lock(&st.lock)
				defer sync.mutex_unlock(&st.lock)
				for i in 0 ..< st.count {
					if st.msgs[i].time < since do continue
					n.serve_ids[count] = st.ids[i]
					count += 1
				}
			}
			head := u32le(count)
			if !net_send(s, mem.ptr_to_bytes(&head)) do return
			if !net_send(s, mem.slice_to_bytes(n.serve_ids[:count])) do return
		case 'G':
			count: u32le
			if !net_recv(s, mem.ptr_to_bytes(&count)) || count > SYNC_BATCH do return
			ids := n.serve_ids[:count]
			if !net_recv(s, mem.slice_to_bytes(ids)) do return
			found := 0
			{
				st := &w.store
				sync.mutex_lock(&st.lock)
				defer sync.mutex_unlock(&st.lock)
				for id in ids {
					for i in 0 ..< st.count {
						if st.ids[i] != id do continue
						n.serve_msgs[found] = st.msgs[i]
						found += 1
						break
					}
				}
			}
			head := u32le(found)
			if !net_send(s, mem.ptr_to_bytes(&head)) do return
			if !net_send(s, mem.slice_to_bytes(n.serve_msgs[:found])) do return
			gave += found
		case 'P':
			count: u32le
			if !net_recv(s, mem.ptr_to_bytes(&count)) || count > SYNC_BATCH do return
			msgs := n.serve_msgs[:count]
			if !net_recv(s, mem.slice_to_bytes(msgs)) do return
			added := node_take(w, msgs, nil, from)
			head := u32le(added)
			if !net_send(s, mem.ptr_to_bytes(&head)) do return
			got += added
		case 'L':
			p: Live_Packet
			if !net_recv(s, mem.ptr_to_bytes(&p)) do return
			live_put(n, &p, time.time_to_unix(time.now()))
			if !net_send(s, []u8{0}) do return
		case 'M':
			req: [33]u8
			if !net_recv(s, req[:]) do return
			trip: [32]u8
			copy(trip[:], req[:32])
			p, have := live_get(n, trip, req[32], time.time_to_unix(time.now()))
			if !net_send(s, []u8{u8(have)}) do return
			if have && !net_send(s, mem.ptr_to_bytes(&p)) do return
		case 'W':
			want: [32]u8
			if !net_recv(s, want[:]) do return
			have := [1]u8{snap_read(want, &n.serve_snap) ? 1 : 0}
			if !net_send(s, have[:]) do return
			if have[0] == 1 && !net_send(s, mem.ptr_to_bytes(&n.serve_snap)) do return
		case 'N':
			list: [1 + MAX_PEERS * PEER_ENTRY]u8
			count := 0
			{
				now := time.time_to_unix(time.now())
				sync.mutex_lock(&n.peers_lock)
				defer sync.mutex_unlock(&n.peers_lock)
				for &p in n.peers[:n.peer_count] {
					if now - p.last_ok > PEER_SHARE_S do continue
					e := list[1 + count * PEER_ENTRY:][:PEER_ENTRY]
					switch &a in p.ep.address {
					case net.IP4_Address:
						e[0] = 4
						copy(e[1:], a[:])
					case net.IP6_Address:
						e[0] = 6
						copy(e[1:], mem.ptr_to_bytes(&a))
					}
					(^u16le)(&e[17])^ = u16le(p.ep.port)
					count += 1
				}
			}
			list[0] = u8(count)
			if !net_send(s, list[:1 + count * PEER_ENTRY]) do return
		case:
			fmt.eprintfln("[net] %s: unknown op %d, closing", ep_text(from, buf[:]), op[0])
			return
		}
	}
	if got > 0 || gave > 0 {
		fmt.eprintfln("[net] served %s: took %d, gave %d", ep_text(from, buf[:]), got, gave)
	}
}

// Verifies and stores messages from a peer. With want, each id must be one of those (a 'G' answer).
node_take :: proc(w: ^World, msgs: []Message, want: [][32]u8, from: net.Endpoint) -> (added: int) {
	buf: [64]u8
	now := time.time_to_unix(time.now())
	for &raw in msgs {
		m, why := msg_read(mem.ptr_to_bytes(&raw))
		if why != "" {
			fmt.eprintfln("[net] %s: message refused: %s", ep_text(from, buf[:]), why)
			continue
		}
		if want != nil {
			id := msg_id(&m)
			asked := false
			for wid in want do asked ||= wid == id
			if !asked {
				fmt.eprintfln(
					"[net] %s: sent a message it was not asked for, refused",
					ep_text(from, buf[:]),
				)
				continue
			}
		}
		if store_add(&w.store, &m, now) == .Added {
			store_append(&w.store, STORE_PATH, &m)
			added += 1
		}
	}
	return
}

node_sync_thread :: proc(t: ^thread.Thread) {
	w := (^World)(t.data)
	n := &w.node
	buf: [64]u8
	if !n.loaded {
		store_load(&w.store, STORE_PATH, time.time_to_unix(time.now()), virtual.arena_allocator(&n.mem))
		node_load_peers(n)
		node_load_snaps(w)
		virtual.arena_free_all(&n.mem)
		n.loaded = true
	}
	live_next: i64
	for !sync.atomic_load(&n.stop) {
		now := time.time_to_unix(time.now())
		if now >= live_next {
			node_live(w)
			live_next = now + LIVE_S
		}
		p: Peer
		due := -1
		{
			sync.mutex_lock(&n.peers_lock)
			defer sync.mutex_unlock(&n.peers_lock)
			for i in 0 ..< n.peer_count {
				if n.peers[i].next <= now && (due < 0 || n.peers[i].next < n.peers[due].next) do due = i
			}
			if due >= 0 do p = n.peers[due]
		}
		if due < 0 {
			time.sleep(100 * time.Millisecond)
			continue
		}
		full := now - p.full_at >= SYNC_FULL_S
		result := node_sync(w, p.ep, full ? 0 : max(p.last_ok - SYNC_MARGIN_S, 0))
		switch result {
		case .Ok:
			if full do p.full_at = now
			p.last_ok = now
			p.fails = 0
			p.next = now + SYNC_S
		case .Failed:
			if p.fails == 0 do fmt.eprintfln("[net] sync with %s failed, backing off", ep_text(p.ep, buf[:]))
			p.fails += 1
			p.next = now + SYNC_S << uint(min(p.fails, 6))
		case .Self:
			fmt.eprintfln("[net] %s is this node, dropped", ep_text(p.ep, buf[:]))
		}
		forget := result == .Self || (!p.seed && p.fails >= PEER_FORGET_FAILS)
		if forget && result != .Self {
			fmt.eprintfln("[net] %s failed %d times, forgotten", ep_text(p.ep, buf[:]), p.fails)
		}

		// The list may have changed while the lock was free, find the peer again.
		save := false
		{
			sync.mutex_lock(&n.peers_lock)
			defer sync.mutex_unlock(&n.peers_lock)
			for i := 0; i < n.peer_count; i += 1 {
				if n.peers[i].ep != p.ep do continue
				if result == .Self {
					n.own[n.own_count % len(n.own)] = p.ep
					n.own_count += 1
				}
				if forget {
					n.peer_count -= 1
					n.peers[i] = n.peers[n.peer_count]
					n.peers_dirty = true
				} else {
					n.peers[i] = p
				}
				break
			}
			save = n.peers_dirty
			n.peers_dirty = false
		}
		if save do node_save_peers(n)
	}
}

// Learned peers to PEERS_PATH as text, one per line. Seeds stay in their own file.
node_save_peers :: proc(n: ^Net_Node) {
	text: [MAX_PEERS * 64]u8
	b := strings.builder_from_bytes(text[:])
	{
		sync.mutex_lock(&n.peers_lock)
		defer sync.mutex_unlock(&n.peers_lock)
		for p in n.peers[:n.peer_count] {
			if p.seed do continue
			net.endpoint_to_string(p.ep, &b)
			strings.write_byte(&b, '\n')
		}
	}
	if err := os.make_directory("cache"); err != nil && err != .Exist {
		fmt.eprintln("[net] cannot create cache/:", err)
	}
	tmp := PEERS_PATH + ".tmp"
	if err := os.write_entire_file(tmp, strings.to_string(b)); err != nil {
		fmt.eprintfln("[net] cannot write %s: %v", tmp, err)
	} else if err = os.rename(tmp, PEERS_PATH); err != nil {
		fmt.eprintfln("[net] cannot rename %s to %s: %v", tmp, PEERS_PATH, err)
	}
}

// Seeds (SEED_NODES, SEEDS_PATH) and the learned peers of the last run (PEERS_PATH). Host names are resolved
// here, on the sync thread, DNS can take seconds. Allocates in n.mem, the caller frees it.
node_load_peers :: proc(n: ^Net_Node) {
	context.allocator = virtual.arena_allocator(&n.mem)
	seeds := SEED_NODES
	for line in seeds do node_add_peer_text(n, line, true, "SEED_NODES")
	for path, i in ([2]string{SEEDS_PATH, PEERS_PATH}) {
		if !os.exists(path) {
			if i == 0 do fmt.eprintfln("[net] no %s: add \"host:port\" lines to it to find other nodes", path)
			continue
		}
		data, err := os.read_entire_file(path, context.allocator)
		if err != nil {
			fmt.eprintfln("[net] cannot read %s: %v", path, err)
			continue
		}
		text := string(data)
		for line in strings.split_lines_iterator(&text) {
			l := strings.trim_space(line)
			if l == "" || l[0] == '#' do continue
			node_add_peer_text(n, l, i == 0, path)
		}
	}
	n.peers_dirty = false
}

// "1.2.3.4:7419", "[::1]:7419", "host.name:7419" or without the port (NODE_PORT).
node_add_peer_text :: proc(n: ^Net_Node, text: string, seed: bool, source: string) {
	ep4, ep6, err := net.resolve(text)
	if err != nil {
		fmt.eprintfln("[net] %s: cannot use peer %q: %v", source, text, err)
		return
	}
	ep := ep4.address != nil ? ep4 : ep6
	if ep.port == 0 do ep.port = NODE_PORT
	node_add_peer(n, ep, seed)
}


Sync_Result :: enum u8 {
	Failed,
	Ok,
	Self, // the peer is this node
}

// One sync with one peer: fetch what we miss of their ids since `since`, push ours they miss, then ask
// for their peers.
node_sync :: proc(w: ^World, ep: net.Endpoint, since: i64) -> Sync_Result {
	n := &w.node
	buf: [64]u8
	s, dialed := net_dial(ep, &n.stop)
	if !dialed do return .Failed
	defer net.close(s)
	_, id, ok := node_hello(n, s)
	if !ok do return .Failed
	if id == n.id do return .Self
	if !node_swap(w, s, ep, since) do return .Failed

	list: [1 + MAX_PEERS * PEER_ENTRY]u8
	if !net_send(s, []u8{'N'}) || !net_recv(s, list[:1]) || list[0] > MAX_PEERS do return .Failed
	entries := list[1:][:int(list[0]) * PEER_ENTRY]
	if !net_recv(s, entries) do return .Failed
	learned := 0
	for at := 0; at < len(entries); at += PEER_ENTRY {
		e := entries[at:][:PEER_ENTRY]
		peer := net.Endpoint {
			port = int((^u16le)(&e[17])^),
		}
		switch e[0] {
		case 4:
			peer.address = net.IP4_Address{e[1], e[2], e[3], e[4]}
		case 6:
			a: net.IP6_Address
			mem.copy(&a, &e[1], 16)
			peer.address = a
		case:
			continue
		}
		if node_add_peer(n, peer, false) do learned += 1
	}
	if learned > 0 do fmt.eprintfln("[net] %s told us %d new peers", ep_text(ep, buf[:]), learned)

	// Snapshots that live offers refer to and we do not have, a few per sync. Asking for one the peer does
	// not have costs 34 bytes and does not count.
	wanted: [SNAP_KEEP][32]u8
	count := 0
	{
		st := &w.store
		now := time.time_to_unix(time.now())
		sync.mutex_lock(&st.lock)
		defer sync.mutex_unlock(&st.lock)
		next: for &m in st.msgs[:st.count] {
			if m.kind != .Offer || m.offer.weather == {} || msg_expires(&m) <= now do continue
			for h in wanted[:count] {
				if h == m.offer.weather do continue next
			}
			wanted[count] = m.offer.weather
			count += 1
			if count == SNAP_KEEP do break
		}
	}
	fetched := 0
	for h in wanted[:count] {
		if fetched == SNAP_PER_SYNC do break
		if snap_has(n, h) do continue
		req: [33]u8
		req[0] = 'W'
		h := h
		copy(req[1:], h[:])
		have: [1]u8
		if !net_send(s, req[:]) || !net_recv(s, have[:]) do return .Failed
		if have[0] != 1 do continue
		if !net_recv(s, mem.ptr_to_bytes(&n.sync_snap)) do return .Failed
		snap, why := snapshot_check(mem.ptr_to_bytes(&n.sync_snap))
		if snap == nil || snap.header.hash != h {
			fmt.eprintfln(
				"[net] %s: snapshot %016x refused: %s",
				ep_text(ep, buf[:]),
				key_short(h),
				snap == nil ? why : "other hash than asked for",
			)
			continue
		}
		snap_put(w, snap)
		fetched += 1
		fmt.eprintfln("[net] got snapshot %016x from %s", key_short(h), ep_text(ep, buf[:]))
	}
	return .Ok
}

// The store part of node_sync.
node_swap :: proc(w: ^World, s: net.TCP_Socket, ep: net.Endpoint, since: i64) -> bool {
	n := &w.node
	buf: [64]u8

	// 1. Their ids.
	theirs: []([32]u8)
	{
		req: [9]u8
		req[0] = 'I'
		(^i64le)(&req[1])^ = i64le(since)
		count: u32le
		net_send(s, req[:]) or_return
		net_recv(s, mem.ptr_to_bytes(&count)) or_return
		if count > STORE_MAX do return false
		theirs = n.sync_ids[:count]
		net_recv(s, mem.slice_to_bytes(theirs)) or_return
	}

	// 2. Get the ones we do not have, SYNC_BATCH at a time.
	got := 0
	for at := 0; at < len(theirs); {
		want: [SYNC_BATCH][32]u8
		count := 0
		for ; at < len(theirs) && count < SYNC_BATCH; at += 1 {
			if !store_has(&w.store, theirs[at]) {
				want[count] = theirs[at]
				count += 1
			}
		}
		if count == 0 do break
		req: [5]u8
		req[0] = 'G'
		(^u32le)(&req[1])^ = u32le(count)
		head: u32le
		net_send(s, req[:]) or_return
		net_send(s, mem.slice_to_bytes(want[:count])) or_return
		net_recv(s, mem.ptr_to_bytes(&head)) or_return
		if int(head) > count do return false
		net_recv(s, mem.slice_to_bytes(n.sync_msgs[:head])) or_return
		got += node_take(w, n.sync_msgs[:head], want[:count], ep)
	}

	// 3. Push ours from since on that they do not have. The store can change between batches (removal moves
	// messages), so a message may be skipped this round. The next sync sends it.
	sent, at := 0, 0
	for {
		count := 0
		{
			st := &w.store
			sync.mutex_lock(&st.lock)
			defer sync.mutex_unlock(&st.lock)
			for ; at < st.count && count < SYNC_BATCH; at += 1 {
				if st.msgs[at].time < i64le(since) do continue
				has := false
				for id in theirs do has ||= id == st.ids[at]
				if has do continue
				n.sync_msgs[count] = st.msgs[at]
				count += 1
			}
		}
		if count == 0 do break
		req: [5]u8
		req[0] = 'P'
		(^u32le)(&req[1])^ = u32le(count)
		added: u32le
		net_send(s, req[:]) or_return
		net_send(s, mem.slice_to_bytes(n.sync_msgs[:count])) or_return
		net_recv(s, mem.ptr_to_bytes(&added)) or_return
		sent += int(added)
	}
	if got > 0 || sent > 0 {
		fmt.eprintfln(
			"[net] synced %s: got %d, sent %d, they list %d since %d",
			ep_text(ep, buf[:]),
			got,
			sent,
			len(theirs),
			since,
		)
	}
	return true
}

store_has :: proc(s: ^Store, id: [32]u8) -> bool {
	sync.mutex_lock(&s.lock)
	defer sync.mutex_unlock(&s.lock)
	for i in 0 ..< s.count {
		if s.ids[i] == id do return true
	}
	return false
}

// Both sides send a hello and check the other one. Returns the port the peer listens on and its node id.
node_hello :: proc(n: ^Net_Node, s: net.TCP_Socket) -> (port: int, id: [8]u8, ok: bool) {
	hello: [15]u8
	(^u32le)(&hello[0])^ = NODE_MAGIC
	hello[4] = NODE_VERSION
	if n.listening do (^u16le)(&hello[5])^ = u16le(n.port == 0 ? NODE_PORT : n.port)
	copy(hello[7:], n.id[:])
	theirs: [15]u8
	net_send(s, hello[:]) or_return
	net_recv(s, theirs[:]) or_return
	if (^u32le)(&theirs[0])^ != NODE_MAGIC || theirs[4] != NODE_VERSION do return
	copy(id[:], theirs[7:])
	return int((^u16le)(&theirs[5])^), id, true
}

// "1.2.3.4:7419" for logs, without allocating.
ep_text :: proc(ep: net.Endpoint, buf: []u8) -> string {
	b := strings.builder_from_bytes(buf)
	return net.endpoint_to_string(ep, &b)
}

net_timeouts :: proc(s: net.TCP_Socket) -> bool {
	t := NET_TIMEOUT_MS * time.Millisecond
	return net.set_option(s, .Receive_Timeout, t) == nil && net.set_option(s, .Send_Timeout, t) == nil
}

net_recv :: proc(s: net.TCP_Socket, buf: []u8) -> bool {
	for got := 0; got < len(buf); {
		n, err := net.recv_tcp(s, buf[got:])
		if err != nil || n == 0 do return false
		got += n
	}
	return true
}

net_send :: proc(s: net.TCP_Socket, buf: []u8) -> bool {
	for sent := 0; sent < len(buf); {
		n, err := net.send_tcp(s, buf[sent:])
		if err != nil do return false
		sent += n
	}
	return true
}

// drift --headless --node: the same store and sync as in the game, without a window or the frame loop.
// Anyone can run one on a machine that stays online, so games that come and go find each other and the
// messages outlive them. Runs until the process is killed. Prints a status line every NODE_STATUS_S.
// A node that cannot listen is useless to others, so that is an error here (the game just dials out).
NODE_STATUS_S :: 300

node_run :: proc(port: int) -> bool {
	w := (^World)(game_init())
	if w == nil do return false
	defer game_shutdown(w)
	w.node.port = port
	node_poll(w)
	if !w.node.listening {
		logf(w, "node", "a node others cannot reach is no use to them, exiting (try another --port)")
		return false
	}
	for {
		time.sleep(NODE_STATUS_S * time.Second)
		now := time.time_to_unix(time.now())
		ok := 0
		{
			n := &w.node
			sync.mutex_lock(&n.peers_lock)
			defer sync.mutex_unlock(&n.peers_lock)
			for p in n.peers[:n.peer_count] {
				if now - p.last_ok < 2 * SYNC_S do ok += 1
			}
		}
		sync.mutex_lock(&w.store.lock)
		count := w.store.count
		sync.mutex_unlock(&w.store.lock)
		fmt.eprintfln("[node] %d messages, %d peers, %d reachable", count, w.node.peer_count, ok)
	}
}

// Weather snapshots between peers. An offer names the snapshot its route was planned with (offer.weather),
// so a passenger can recompute the same route with the same wind. A node keeps up to SNAP_KEEP snapshots
// as files in SNAP_DIR, named by their sha256 in hex: its own (the fetch thread, SNAPSHOT_PATH at start)
// and the ones that live offers in its store refer to, asked from the peer it syncs with ('W'). A full
// directory drops the oldest snapshot no live offer refers to, or else the oldest one.
// Snapshots only ever reach the simulation through a file and snapshot_check, never straight off the wire.
SNAP_DIR :: "cache/snaps"
SNAP_KEEP :: 32
SNAP_PER_SYNC :: 4

// "cache/snaps/<64 hex digits>.snap". Built from the hash digit by digit, never from text a peer sent.
snap_path :: proc(h: [32]u8, buf: []u8) -> string {
	HEX :: "0123456789abcdef"
	digits := HEX
	b := strings.builder_from_bytes(buf)
	strings.write_string(&b, SNAP_DIR + "/")
	for x in h {
		strings.write_byte(&b, digits[x >> 4])
		strings.write_byte(&b, digits[x & 15])
	}
	strings.write_string(&b, ".snap")
	return strings.to_string(b)
}

snap_has :: proc(n: ^Net_Node, h: [32]u8) -> bool {
	sync.mutex_lock(&n.snaps_lock)
	defer sync.mutex_unlock(&n.snaps_lock)
	for x in n.snaps[:n.snap_count] {
		if x == h do return true
	}
	return false
}

// The snapshot with sha256 h from SNAP_DIR into out, checked. False when it is not there or not valid.
// Any thread; the game will use it to recompute an offer's route with the driver's weather.
snap_read :: proc(h: [32]u8, out: ^Snapshot) -> bool {
	buf: [128]u8
	path := snap_path(h, buf[:])
	f, err := os.open(path)
	if err != nil do return false
	defer os.close(f)
	n, rerr := os.read_full(f, mem.ptr_to_bytes(out))
	if rerr != nil || n != size_of(Snapshot) do return false
	snap, _ := snapshot_check(mem.ptr_to_bytes(out))
	return snap != nil && snap.header.hash == h
}

// Writes a checked snapshot to SNAP_DIR (temp file + rename) and adds it to the index, making room first.
snap_put :: proc(w: ^World, snap: ^Snapshot) {
	n := &w.node
	h := snap.header.hash
	sync.mutex_lock(&n.snaps_lock)
	defer sync.mutex_unlock(&n.snaps_lock)
	for x in n.snaps[:n.snap_count] {
		if x == h do return
	}
	buf, tmp_buf: [128]u8
	path := snap_path(h, buf[:])
	tmp := fmt.bprintf(tmp_buf[:], "%s.tmp", path)
	if !os.exists(path) {
		if err := os.make_directory_all(SNAP_DIR); err != nil && err != .Exist {
			fmt.eprintfln("[net] cannot create %s: %v", SNAP_DIR, err)
			return
		}
		if err := os.write_entire_file(tmp, mem.ptr_to_bytes(snap)); err != nil {
			fmt.eprintfln("[net] cannot write %s: %v", tmp, err)
			return
		}
		if err := os.rename(tmp, path); err != nil {
			fmt.eprintfln("[net] cannot rename %s: %v", tmp, err)
			return
		}
	}
	if n.snap_count == SNAP_KEEP {
		victim, victim_used := -1, true
		now := time.time_to_unix(time.now())
		st := &w.store
		sync.mutex_lock(&st.lock)
		for x, i in n.snaps[:n.snap_count] {
			used := false
			for &m in st.msgs[:st.count] {
				if m.kind == .Offer && m.offer.weather == x && msg_expires(&m) > now {
					used = true
					break
				}
			}
			better := victim < 0 || (victim_used && !used)
			better ||= used == victim_used && n.snap_time[i] < n.snap_time[victim]
			if better do victim, victim_used = i, used
		}
		sync.mutex_unlock(&st.lock)
		os.remove(snap_path(n.snaps[victim], buf[:]))
		n.snap_count -= 1
		n.snaps[victim] = n.snaps[n.snap_count]
		n.snap_time[victim] = n.snap_time[n.snap_count]
	}
	n.snaps[n.snap_count] = h
	n.snap_time[n.snap_count] = snap.header.fetched_at
	n.snap_count += 1
}

// At start, on the sync thread: index SNAP_DIR (files that fail snapshot_check are deleted), then make sure
// the snapshot the game runs on (SNAPSHOT_PATH) is in it. Allocates in w.node.mem.
node_load_snaps :: proc(w: ^World) {
	n := &w.node
	files, err := os.read_all_directory_by_path(SNAP_DIR, virtual.arena_allocator(&n.mem))
	if err != nil && err != .Not_Exist {
		fmt.eprintfln("[net] cannot list %s: %v", SNAP_DIR, err)
	}
	for f in files {
		h: [32]u8
		name := f.name
		ok := len(name) == 69 && strings.has_suffix(name, ".snap")
		for i := 0; ok && i < 64; i += 1 {
			c := name[i]
			d: u8
			switch c {
			case '0' ..= '9':
				d = c - '0'
			case 'a' ..= 'f':
				d = c - 'a' + 10
			case:
				ok = false
			}
			h[i / 2] |= d << (i % 2 == 0 ? 4 : 0)
		}
		if !ok do continue
		if !snap_read(h, &n.sync_snap) {
			buf: [128]u8
			fmt.eprintfln("[net] %s is not a valid snapshot, deleted", f.name)
			os.remove(snap_path(h, buf[:]))
			continue
		}
		snap_put(w, &n.sync_snap)
	}
	if own, oerr := os.open(SNAPSHOT_PATH); oerr == nil {
		got, _ := os.read_full(own, mem.ptr_to_bytes(&n.sync_snap))
		os.close(own)
		snap, _ := snapshot_check(mem.ptr_to_bytes(&n.sync_snap))
		if got == size_of(Snapshot) && snap != nil do snap_put(w, snap)
	}
	fmt.eprintfln("[net] %d weather snapshots in %s", n.snap_count, SNAP_DIR)
}

// Live position between the two users of one accepted trip. Not a signed Message: sent about once a
// second, passed on by nodes that keep it only in memory and cannot read it, readable only by the two.
// Key exchange: each side makes a fresh x25519 key pair (trip_keypair) and puts the public half in its
// signed Request / Accept, so the exchange is authenticated by the ed25519 identities.
// key = HKDF-SHA256(salt = accept id, ikm = x25519 shared secret, info = LIVE_INFO).
// Nonce = seq (8 bytes LE) + from_driver + 3 zero bytes: both directions share the key, never a nonce.
LIVE_INFO :: "drift live position v1"

// Zero is no trip. One trip at a time.
Trip :: struct {
	own_x25519:  [32]u8, // private half, wiped once the key is derived
	accept:      [32]u8, // message id, names the trip
	key:         [32]u8,
	driver:      bool,
	active:      bool,
	sent, heard: u64, // last sequence numbers sent and accepted, replays and old packets are dropped
}

Live_Position :: struct {
	x, y, alt: f32le, // km, km, m
	_:         [4]u8,
	time:      i64le, // unix seconds
}

Live_Packet :: struct {
	trip:        [32]u8, // accept id, so nodes can keep the latest packet per trip and direction
	seq:         u64le,
	from_driver: u8,
	_:           [7]u8,
	box:         [size_of(Live_Position)]u8, // encrypted Live_Position
	tag:         [chacha20poly1305.TAG_SIZE]u8, // authenticates box and every header byte before it
}
#assert(size_of(Live_Position) == 24 && size_of(Live_Packet) == 88 && offset_of(Live_Packet, box) == 48)

// Before signing a Request (passenger) or an Accept (driver): a fresh key pair, the public half goes
// into the message. Starting a new one drops the trip in progress.
trip_keypair :: proc(w: ^World) -> (public: [32]u8) {
	w.trip = {}
	crypto.rand_bytes(w.trip.own_x25519[:])
	x25519.scalarmult_basepoint(public[:], w.trip.own_x25519[:])
	return
}

// Both sides call it with the same two verified messages (from msg_read). driver = this user sent accept.
trip_start :: proc(w: ^World, request, accept: ^Message, driver: bool) -> bool {
	t := &w.trip
	defer crypto.zero_explicit(&t.own_x25519, size_of(t.own_x25519))
	if request.kind != .Request || accept.kind != .Accept || accept.accept.request != msg_id(request) {
		logf(w, "net", "trip: accept does not answer this request")
		return false
	}
	own_side := driver ? accept.author : request.author
	if accept.accept.offer != request.request.offer || own_side != w.identity_pub {
		logf(w, "net", "trip: wrong offer, or this user is not the %s", driver ? "driver" : "passenger")
		return false
	}
	shared: [32]u8
	defer crypto.zero_explicit(&shared, size_of(shared))
	peer := driver ? request.request.x25519 : accept.accept.x25519
	x25519.scalarmult(shared[:], t.own_x25519[:], peer[:])
	if shared == {} {
		logf(w, "net", "trip: peer x25519 key %016x is a low order point", key_short(peer))
		return false
	}
	t.accept = msg_id(accept)
	hkdf.extract_and_expand(.SHA256, t.accept[:], shared[:], transmute([]u8)string(LIVE_INFO), t.key[:])
	t.driver = driver
	t.active = true
	t.sent, t.heard = 0, 0
	logf(w, "net", "trip %016x started as %s", key_short(t.accept), driver ? "driver" : "passenger")
	return true
}

live_seal :: proc(w: ^World, pos: Live_Position) -> (p: Live_Packet, ok: bool) {
	t := &w.trip
	if !t.active do return
	t.sent += 1
	p.trip = t.accept
	p.seq = u64le(t.sent)
	p.from_driver = u8(t.driver)
	pos := pos
	nonce := live_nonce(&p)
	ctx: chacha20poly1305.Context
	chacha20poly1305.init(&ctx, t.key[:])
	header := mem.ptr_to_bytes(&p)[:offset_of(Live_Packet, box)]
	chacha20poly1305.seal(&ctx, p.box[:], p.tag[:], nonce[:], header, mem.ptr_to_bytes(&pos))
	chacha20poly1305.reset(&ctx)
	return p, true
}

// For packets from peers: only the other side of this trip, only newer than the last one, only
// when the tag verifies.
live_open :: proc(w: ^World, p: ^Live_Packet) -> (pos: Live_Position, ok: bool) {
	t := &w.trip
	if !t.active || p.trip != t.accept || p.from_driver != u8(!t.driver) || u64(p.seq) <= t.heard do return
	nonce := live_nonce(p)
	ctx: chacha20poly1305.Context
	chacha20poly1305.init(&ctx, t.key[:])
	header := mem.ptr_to_bytes(p)[:offset_of(Live_Packet, box)]
	ok = chacha20poly1305.open(&ctx, mem.ptr_to_bytes(&pos), nonce[:], header, p.box[:], p.tag[:])
	chacha20poly1305.reset(&ctx)
	if !ok {
		logf(w, "net", "trip %016x: live packet %d does not verify, dropped", key_short(t.accept), p.seq)
		return {}, false
	}
	t.heard = u64(p.seq)
	return pos, true
}

live_nonce :: proc(p: ^Live_Packet) -> (nonce: [chacha20poly1305.IV_SIZE]u8) {
	(^u64le)(&nonce[0])^ = p.seq
	nonce[8] = p.from_driver
	return
}

// The game's side of the transport, frame loop only. live_send seals the position and leaves the packet
// for the node thread, live_poll returns the newest position from the other side that verifies.
// Starting a trip needs a restart of neither: the node thread only looks at live_out.
live_send :: proc(w: ^World, pos: Live_Position) -> bool {
	p := live_seal(w, pos) or_return
	n := &w.node
	sync.mutex_lock(&n.live_lock)
	defer sync.mutex_unlock(&n.live_lock)
	n.live_out = p
	n.live_has_out = true
	return true
}

live_poll :: proc(w: ^World) -> (pos: Live_Position, ok: bool) {
	n := &w.node
	p: Live_Packet
	{
		sync.mutex_lock(&n.live_lock)
		defer sync.mutex_unlock(&n.live_lock)
		if !n.live_has_in do return
		p = n.live_in
		n.live_has_in = false
	}
	return live_open(w, &p)
}

// After the trip: forget the key and stop sending.
trip_end :: proc(w: ^World) {
	crypto.zero_explicit(&w.trip, size_of(w.trip))
	n := &w.node
	sync.mutex_lock(&n.live_lock)
	defer sync.mutex_unlock(&n.live_lock)
	n.live_has_out, n.live_has_in = false, false
}

// Live packets between nodes. Not gossiped like messages: the sender leaves its packet ('L') at its own
// node and at every peer that synced recently, the other side asks those same nodes ('M'). Any node both
// are connected to carries it. Nodes keep the latest packet per trip and direction, in memory only, for
// LIVE_TTL_S, and cannot read them. So a node cannot tell a real packet from garbage with a higher seq:
// whoever knows a trip id (accept ids are public) can spoil it at one node. The receiver asks every node
// it reaches and keeps the newest packet that verifies, so it has to be every node.
//   'L' packet (88 bytes)         -> u8 0
//   'M' trip id, from_driver u8   -> u8 1 + packet, or u8 0
LIVE_S :: 1
LIVE_TTL_S :: 60
LIVE_SLOTS :: 1024
LIVE_PEERS :: 8

// Stores p unless the slot for its trip and direction already has a newer one. Full: the oldest goes.
live_put :: proc(n: ^Net_Node, p: ^Live_Packet, now: i64) {
	sync.mutex_lock(&n.live_lock)
	defer sync.mutex_unlock(&n.live_lock)
	oldest := 0
	for &q, i in n.live_slots {
		if n.live_at[i] != 0 && q.trip == p.trip && q.from_driver == p.from_driver {
			if p.seq > q.seq {
				q = p^
				n.live_at[i] = now
			}
			return
		}
		if n.live_at[i] < n.live_at[oldest] do oldest = i
	}
	n.live_slots[oldest] = p^
	n.live_at[oldest] = now
}

live_get :: proc(n: ^Net_Node, trip: [32]u8, from_driver: u8, now: i64) -> (p: Live_Packet, ok: bool) {
	sync.mutex_lock(&n.live_lock)
	defer sync.mutex_unlock(&n.live_lock)
	for q, i in n.live_slots {
		if n.live_at[i] == 0 || now - n.live_at[i] > LIVE_TTL_S do continue
		if q.trip == trip && q.from_driver == from_driver do return q, true
	}
	return
}

// Every LIVE_S on the sync thread while the game has a packet to send. Leaves it at this node and at
// up to LIVE_PEERS peers that synced recently, asks each for the other side's latest, hands the one
// with the highest seq to the game (live_poll opens it there).
node_live :: proc(w: ^World) {
	n := &w.node
	now := time.time_to_unix(time.now())
	out: Live_Packet
	{
		sync.mutex_lock(&n.live_lock)
		defer sync.mutex_unlock(&n.live_lock)
		if !n.live_has_out do return
		out = n.live_out
	}
	live_put(n, &out, now)
	want := out.from_driver ~ 1
	best, found := live_get(n, out.trip, want, now)

	eps: [LIVE_PEERS]net.Endpoint
	count := 0
	{
		sync.mutex_lock(&n.peers_lock)
		defer sync.mutex_unlock(&n.peers_lock)
		for p in n.peers[:n.peer_count] {
			if count == LIVE_PEERS do break
			if now - p.last_ok > 2 * SYNC_S do continue
			eps[count] = p.ep
			count += 1
		}
	}
	for ep in eps[:count] {
		s, dialed := net_dial(ep, &n.stop)
		if !dialed do continue
		defer net.close(s)
		if _, _, ok := node_hello(n, s); !ok do continue
		put: [1 + size_of(Live_Packet)]u8
		put[0] = 'L'
		mem.copy(&put[1], &out, size_of(Live_Packet))
		get: [34]u8
		get[0] = 'M'
		copy(get[1:], out.trip[:])
		get[33] = want
		status, have: [1]u8
		if !net_send(s, put[:]) || !net_recv(s, status[:]) do continue
		if !net_send(s, get[:]) || !net_recv(s, have[:]) || have[0] != 1 do continue
		p: Live_Packet
		if !net_recv(s, mem.ptr_to_bytes(&p)) || p.trip != out.trip || p.from_driver != want do continue
		if !found || p.seq > best.seq do best, found = p, true
	}
	if !found do return
	sync.mutex_lock(&n.live_lock)
	defer sync.mutex_unlock(&n.live_lock)
	if !n.live_has_in || best.seq > n.live_in.seq {
		n.live_in = best
		n.live_has_in = true
	}
}
