// author: andrei
package game

import "core:math"
import "core:math/linalg"
import "core:sync"
import "core:time"

// Carpooling on top of the signed messages of net.odin: making an offer, finding the offers that fit a trip
// (filter by weather grid cell and forecast hour, then a detour check with the router), verifying an offer by
// recomputing it locally, splitting the energy, and a reputation from signed reviews. Frame loop only: it reads
// w.store under its lock and uses the router, like the plan screen.

// Energy is the net kWh of the spec metrics (used by the motors and ballonets minus solar), the same number the
// plan screen shows, so a passenger compares like with like.
VERIFY_TOLERANCE :: 0.01 // relative: the router is deterministic, this only absorbs float differences between CPUs
MAX_MATCHES :: 16
OFFER_NOW_GRACE_S :: 10 * 60 // boarding window so "Leave now" offers do not expire at creation

Match :: struct {
	offer:         [32]u8, // message id
	author:        [32]u8, // driver's public key
	from_hub:      int, // the driver's hubs
	to_hub:        int,
	depart:        i64,
	seats:         int,
	direct_kwh:    f32, // the driver's own trip, recomputed here
	detour_kwh:    f32, // extra energy to pick up at from and drop at to
	detour_km:     f32,
	segment_kwh:   f32, // the shared part, from -> to on the detoured trip
	passenger_kwh: f32, // what the passenger carries (carpool_split)
	driver_kwh:    f32,
}

// Forecast hour of a unix time in the current snapshot, clamped to the forecast.
forecast_hour :: proc(w: ^World, t: i64) -> int {
	return clamp(int((t - i64(w.weather.start)) / 3600), 0, FORECAST_HOURS - 1)
}

// One leg hub to hub with the router: net kWh and km. ok = false when there is no safe route.
carpool_leg :: proc(w: ^World, from, to: int, mode: Route_Mode, hour: int) -> (kwh, km: f32, ok: bool) {
	if from == to do return 0, 0, true
	path := route(w, hub_top(w, from), hub_top(w, to), mode, hour) or_return
	times := make([]f32, len(path), context.temp_allocator)
	dist := make([]f32, len(path), context.temp_allocator)
	airspeeds := MODE_AIRSPEED
	sum := evaluate(w, path, airspeeds[mode], hour, times, dist)
	return sum.net_kwh, sum.km, true
}

// Departure unix timestamp for an offer at forecast hour, always at least OFFER_NOW_GRACE_S in the future
// so "Leave now" (hour 0) or a cached/fallback weather snapshot does not expire immediately.
carpool_offer_depart :: proc(w: ^World, hour: int) -> i64 {
	now := time.time_to_unix(time.now())
	if hour == 0 do return now + OFFER_NOW_GRACE_S
	return max(i64(w.weather.start) + i64(hour) * 3600, now + OFFER_NOW_GRACE_S)
}

// A signed offer for seats on this user's trip. The energy is recomputed with the current snapshot, whose
// hash goes in the offer so peers can fetch the same weather and check it.
carpool_offer_make :: proc(
	w: ^World,
	from, to: int,
	mode: Route_Mode,
	depart: i64,
	seats: int,
) -> (
	m: Message,
	ok: bool,
) {
	if seats < 1 || seats > MSG_MAX_SEATS || from == to do return
	if from < 0 || from >= w.m.hub_count || to < 0 || to >= w.m.hub_count do return
	hour := forecast_hour(w, depart)
	kwh, km := carpool_leg(w, from, to, mode, hour) or_return
	airspeeds := MODE_AIRSPEED
	m.kind = .Offer
	m.time = i64le(time.time_to_unix(time.now()))
	m.offer = {
		from_hub   = u16le(from),
		to_hub     = u16le(to),
		seats      = u8(seats),
		mode       = mode,
		depart     = i64le(depart),
		arrive     = i64le(depart + i64(km * 1000 / airspeeds[mode])),
		weather    = w.weather_hash,
		energy_kwh = f32le(kwh),
	}
	ok = msg_sign(w, &m)
	return
}

Verify :: enum u8 {
	Ok,
	Other_Weather, // planned with a snapshot this game does not have: fetch it from peers first
	No_Route, // no safe route here: the offer cannot be flown as stated
	Energy_Differs,
}

// Recompute the offer's trip locally and compare its energy.
carpool_verify :: proc(w: ^World, m: ^Message) -> (v: Verify, kwh: f32) {
	o := &m.offer
	if o.weather != w.weather_hash do return .Other_Weather, 0
	ok: bool
	kwh, _, ok = carpool_leg(w, int(o.from_hub), int(o.to_hub), o.mode, forecast_hour(w, i64(o.depart)))
	if !ok do return .No_Route, 0
	claimed := f32(o.energy_kwh)
	if abs(kwh - claimed) > VERIFY_TOLERANCE * max(abs(claimed), 1) do return .Energy_Differs, kwh
	return .Ok, kwh
}

// The passenger's share: their part of the shared segment (split over everyone on board, driver included) plus
// the whole detour, which only exists because of them. The driver carries the rest.
carpool_split :: proc(direct_kwh, detour_kwh, segment_kwh: f32, seats: int) -> (passenger, driver: f32) {
	on_board := f32(seats + 1)
	passenger = segment_kwh * f32(seats) / on_board + max(detour_kwh, 0)
	driver = direct_kwh + max(detour_kwh, 0) - passenger
	return
}

// The weather cell of a hub.
hub_cell :: proc(w: ^World, hub: int) -> [2]int {
	p := w.m.hubs[hub].pos
	return {
		clamp(int(p.x / WEATHER_CELL_KM), 0, WEATHER_GRID_W - 1),
		clamp(int(p.y / WEATHER_CELL_KM), 0, WEATHER_GRID_H - 1),
	}
}

// True when cell c is on, or next to, a weather cell that the straight line from a to b crosses. A coarse first
// filter: the router's detour check decides.
cell_near_line :: proc(w: ^World, a, b: int, c: [2]int) -> bool {
	pa, pb := w.m.hubs[a].pos, w.m.hubs[b].pos
	steps := int(math.ceil(max(abs(pb.x - pa.x), abs(pb.y - pa.y)) / (WEATHER_CELL_KM / 4))) + 1
	for i in 0 ..= steps {
		p := pa + (pb - pa) * f32(i) / f32(steps)
		cell := [2]int{int(p.x / WEATHER_CELL_KM), int(p.y / WEATHER_CELL_KM)}
		if abs(cell.x - c.x) <= 1 && abs(cell.y - c.y) <= 1 do return true
	}
	return false
}

// Offers that can take seats passengers from hub from to hub to, departing in forecast hour hour, cheapest for the
// passenger first. Own offers and full ones are skipped. Each candidate costs four router runs.
carpool_match :: proc(w: ^World, from, to, hour, seats: int, out: []Match) -> int {
	offers := make([dynamic]Message, 0, 64, context.temp_allocator)
	{
		s := &w.store
		sync.mutex_lock(&s.lock)
		defer sync.mutex_unlock(&s.lock)
		for &m in s.msgs[:s.count] {
			if m.kind != .Offer || m.author == w.identity_pub || int(m.offer.seats) < seats do continue
			if forecast_hour(w, i64(m.offer.depart)) != hour do continue
			append(&offers, m)
		}
	}
	cf, ct := hub_cell(w, from), hub_cell(w, to)
	n := 0
	for &m in offers {
		o := &m.offer
		a, b := int(o.from_hub), int(o.to_hub)
		if a >= w.m.hub_count || b >= w.m.hub_count do continue
		if !cell_near_line(w, a, b, cf) || !cell_near_line(w, a, b, ct) do continue
		direct, direct_km, ok := carpool_leg(w, a, b, o.mode, hour)
		if !ok do continue
		k1, km1, ok1 := carpool_leg(w, a, from, o.mode, hour)
		k2, km2, ok2 := carpool_leg(w, from, to, o.mode, hour)
		k3, km3, ok3 := carpool_leg(w, to, b, o.mode, hour)
		if !ok1 || !ok2 || !ok3 do continue
		mt := Match {
			offer       = msg_id(&m),
			author      = m.author,
			from_hub    = a,
			to_hub      = b,
			depart      = i64(o.depart),
			seats       = int(o.seats),
			direct_kwh  = direct,
			detour_kwh  = k1 + k2 + k3 - direct,
			detour_km   = km1 + km2 + km3 - direct_km,
			segment_kwh = k2,
		}
		mt.passenger_kwh, mt.driver_kwh = carpool_split(direct, mt.detour_kwh, k2, seats)
		// Insertion by passenger cost, the most expensive falls off a full list.
		i := min(n, len(out) - 1)
		if i < 0 || (n == len(out) && mt.passenger_kwh >= out[i].passenger_kwh) do continue
		for i > 0 && out[i - 1].passenger_kwh > mt.passenger_kwh {
			out[i] = out[i - 1]
			i -= 1
		}
		out[i] = mt
		n = min(n + 1, len(out))
	}
	return n
}

// Average stars and count of the valid reviews of subject. A review counts when its accept is in the store, its
// author is one side of that trip (the driver who accepted or the passenger who asked), subject is the other
// side, and it is the author's first review of that trip.
carpool_reputation :: proc(w: ^World, subject: [32]u8) -> (stars: f32, count: int) {
	s := &w.store
	sync.mutex_lock(&s.lock)
	defer sync.mutex_unlock(&s.lock)
	find :: proc(s: ^Store, id: [32]u8) -> ^Message {
		for i in 0 ..< s.count do if s.ids[i] == id do return &s.msgs[i]
		return nil
	}
	total := 0
	for &r, i in s.msgs[:s.count] {
		if r.kind != .Review || r.review.subject != subject do continue
		if r.review.stars < 1 || r.review.stars > 5 do continue
		acc := find(s, r.review.accept)
		if acc == nil || acc.kind != .Accept do continue
		req := find(s, acc.accept.request)
		if req == nil || req.kind != .Request do continue
		driver, passenger := acc.author, req.author
		ok := (r.author == driver && subject == passenger) || (r.author == passenger && subject == driver)
		if !ok do continue
		first := true
		for &e in s.msgs[:i] {
			if e.kind == .Review && e.author == r.author && e.review.accept == r.review.accept do first = false
		}
		if !first do continue
		total += int(r.review.stars)
		count += 1
	}
	if count > 0 do stars = f32(total) / f32(count)
	return
}

// A signed review of the other side of an accepted trip.
carpool_review_make :: proc(
	w: ^World,
	accept: [32]u8,
	subject: [32]u8,
	stars: int,
) -> (
	m: Message,
	ok: bool,
) {
	if stars < 1 || stars > 5 do return
	m.kind = .Review
	m.time = i64le(time.time_to_unix(time.now()))
	m.review = {
		subject = subject,
		accept  = accept,
		stars   = u8(stars),
	}
	ok = msg_sign(w, &m)
	return
}

// Live position during an accepted trip: send our own once per LIVE_SEND_S, keep the partner's newest for the
// map (carpool_draw_partner in nav_ui.odin).
LIVE_SEND_S :: 1.0

carpool_frame :: proc(w: ^World, dt: f32) {
	if !w.trip.active do return
	w.live_send_s += dt
	if w.live_send_s >= LIVE_SEND_S {
		w.live_send_s = 0
		s := &w.ship
		live_send(
			w,
			{
				x = f32le(s.pos.x),
				y = f32le(s.pos.y),
				alt = f32le(s.alt),
				time = i64le(time.time_to_unix(time.now())),
			},
		)
	}
	if pos, ok := live_poll(w); ok {
		w.partner = {f32(pos.x), f32(pos.y), f32(pos.alt)}
		w.partner_seen = true
	}
}

// Signed request for seats on offer_id, generating a fresh x25519 keypair in w.trip.
// Caller must ensure no trip is active and no other request is pending (trip_keypair resets w.trip).
carpool_request_make :: proc(w: ^World, offer_id: [32]u8, from, to, seats: int) -> (m: Message, ok: bool) {
	if seats < 1 || seats > MSG_MAX_SEATS || from == to do return
	if from < 0 || from >= w.m.hub_count || to < 0 || to >= w.m.hub_count do return
	pub := trip_keypair(w)
	m.kind = .Request
	m.time = i64le(time.time_to_unix(time.now()))
	m.request = {
		offer    = offer_id,
		from_hub = u16le(from),
		to_hub   = u16le(to),
		seats    = u8(seats),
		x25519   = pub,
	}
	ok = msg_sign(w, &m)
	return
}

// Signed accept answering a passenger's request, generating the driver's x25519 half in w.trip.
carpool_accept_make :: proc(w: ^World, req: ^Message) -> (m: Message, ok: bool) {
	if req.kind != .Request do return
	pub := trip_keypair(w)
	m.kind = .Accept
	m.time = i64le(time.time_to_unix(time.now()))
	m.accept = {
		offer   = req.request.offer,
		request = msg_id(req),
		x25519  = pub,
	}
	ok = msg_sign(w, &m)
	return
}

// Posts a locally signed message into memory and queues it for the sync thread to write to disk.
// Never locks w.store.lock before calling store_post (store_add acquires s.lock itself).
carpool_post :: proc(w: ^World, m: ^Message) -> Store_Add {
	return store_post(&w.store, m, time.time_to_unix(time.now()))
}

carpool_find_message :: proc(w: ^World, id: [32]u8) -> (m: Message, ok: bool) {
	s := &w.store
	sync.mutex_lock(&s.lock)
	defer sync.mutex_unlock(&s.lock)
	for i in 0 ..< s.count {
		if s.ids[i] == id do return s.msgs[i], true
	}
	return {}, false
}

carpool_offer_gen :: proc(w: ^World) -> int {
	s := &w.store
	sync.mutex_lock(&s.lock)
	defer sync.mutex_unlock(&s.lock)
	return s.offer_gen
}

// Unanswered valid requests targeting offer_id.
carpool_incoming_requests :: proc(w: ^World, offer_id: [32]u8, out: []Message) -> int {
	if offer_id == {} || len(out) == 0 do return 0
	offer, offer_ok := carpool_find_message(w, offer_id)
	if !offer_ok || offer.kind != .Offer do return 0
	s := &w.store
	sync.mutex_lock(&s.lock)
	defer sync.mutex_unlock(&s.lock)
	n := 0
	for i in 0 ..< s.count {
		m := &s.msgs[i]
		if m.kind != .Request || m.author == w.identity_pub do continue
		if m.request.offer != offer_id do continue
		if int(m.request.seats) < 1 || int(m.request.seats) > int(offer.offer.seats) do continue
		fh, th := int(m.request.from_hub), int(m.request.to_hub)
		if fh >= w.m.hub_count || th >= w.m.hub_count || fh == th do continue
		req_id := s.ids[i]
		answered := false
		for j in 0 ..< s.count {
			a := &s.msgs[j]
			if a.kind == .Accept && a.accept.request == req_id && a.author == w.identity_pub {
				answered = true
				break
			}
		}
		if answered do continue
		out[n] = m^
		n += 1
		if n == len(out) do break
	}
	return n
}

carpool_is_passenger :: proc(w: ^World) -> bool {
	return w.trip.active && !w.trip.driver
}

carpool_partner_target :: proc(
	w: ^World,
) -> (
	pos: [2]f32,
	alt, heading, speed: f32,
	on_road: bool,
	skin: Car_Skin,
	ok: bool,
) {
	for o in w.others[:w.other_count] {
		if o.author != w.plan.partner_pub do continue
		return o.pos, o.alt, o.heading, o.speed, o.on_road, o.skin, true
	}
	if w.partner_seen {
		return w.partner.xy, w.partner.z, w.ship.heading, 0, false, w.plan.partner_skin, true
	}
	return {}, 0, 0, 0, false, w.plan.partner_skin, false
}

carpool_board :: proc(w: ^World) {
	nav_stop(w)
	w.screen = .Navigate
	w.plan.layers_open = false
	if pos, alt, heading, speed, on_road, skin, ok := carpool_partner_target(w); ok {
		w.ship.pos = pos
		w.ship.pos_frac = {}
		w.ship.alt = alt
		w.ship.heading = heading
		w.ship.speed = speed
		w.ship.on_road = on_road
		w.plan.partner_skin = skin
	}
	cam_chase(w)
}

carpool_abort :: proc(w: ^World) {
	trip_end(w)
	w.partner_seen = false
	w.plan.partner_pub = {}
	w.plan.trip_accept = {}
	w.plan.request_id = {}
	w.plan.partner_skin = .Concept
	if w.screen == .Navigate do pilot_exit(w)
}

carpool_passenger_step :: proc(w: ^World, dt: f32) {
	pos, alt, heading, speed, on_road, skin, ok := carpool_partner_target(w)
	if !ok do return
	s := &w.ship
	w.plan.partner_skin = skin
	if linalg.length(pos - s.pos) > 1.0 {
		s.pos = pos
		s.alt = alt
		s.heading = heading
	} else {
		k := min(dt * 8, 1)
		s.pos += (pos - s.pos) * k
		s.alt += (alt - s.alt) * k
		diff := math.mod(heading - s.heading + 3 * math.PI, math.TAU) - math.PI
		s.heading = math.mod(s.heading + diff * k + math.TAU, math.TAU)
	}
	s.pos_frac = {}
	s.speed = speed
	s.on_road = on_road
	s.landing, s.lifting, s.docked = false, false, false
	s.warnings = {}
	s.turn_rate = 0
}

// Starts the passenger's encrypted live trip when an Accept from the offer's author arrives.
carpool_poll_trip :: proc(
	w: ^World,
	pending_req: ^[32]u8,
	partner_out: ^[32]u8 = nil,
	accept_out: ^[32]u8 = nil,
) -> bool {
	if w.trip.active || pending_req^ == {} do return false
	req, req_ok := carpool_find_message(w, pending_req^)
	if !req_ok || req.kind != .Request do return false
	offer, offer_ok := carpool_find_message(w, req.request.offer)
	if !offer_ok || offer.kind != .Offer do return false
	acc: Message
	found := false
	{
		s := &w.store
		sync.mutex_lock(&s.lock)
		defer sync.mutex_unlock(&s.lock)
		for i in 0 ..< s.count {
			m := &s.msgs[i]
			if m.kind != .Accept do continue
			if m.accept.request == pending_req^ &&
			   m.accept.offer == req.request.offer &&
			   m.author == offer.author {
				acc = m^
				found = true
				break
			}
		}
	}
	if !found do return false
	if !trip_start(w, &req, &acc, false) do return false
	if partner_out != nil do partner_out^ = offer.author
	if accept_out != nil do accept_out^ = msg_id(&acc)
	pending_req^ = {}
	return true
}
