// author: andrei
package game

import "core:crypto/ed25519"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:net"
import "core:strings"
import "core:sync"
import "core:time"

// Other cars on the map (Lars, 2026-11-21: "peer-to-peer, geen relay service, gossiping"). Every game signs its
// own position with its ed25519 identity and swaps the fresh positions it knows with its peers every PRESENCE_S
// (op 'Q'), so a position travels from node to node without any central server. A node keeps the newest
// position per author for PRESENCE_TTL_S, checks every signature and drops what is too old or too far ahead.
// Positions are public on purpose: this is the presence everyone sees. The carpool live position stays
// end-to-end encrypted between the two sides of a trip (Live_Packet).
//   'Q' u32 count + count Presence  ->  u32 count + count Presence (what this node knows, own one included)
PRESENCE_MAGIC :: 0x50525244 // "DRRP"
// Other cars showed seconds late (Lars, 2026-11-22: "met delay, die moet je fixen"): a position was signed every
// 2 s and swapped every 2 s, and every exchange waited on Nagle + delayed ACK (now TCP_NODELAY, net_options).
// While any car is live the game signs and swaps 5 times a second; with nothing live every PRESENCE_IDLE_S, so a
// car that shows up is seen within a second or two.
PRESENCE_S :: 0.2
PRESENCE_IDLE_S :: 1.0
PRESENCE_TTL_S :: 20
PRESENCE_FUTURE_S :: 30 // allowed clock difference
PRESENCE_SLOTS :: 256
PRESENCE_GOSSIP :: 64 // most positions in one exchange
PRESENCE_PEERS :: 8
// Drawing (presence_frame): a car is moved on from its last report for at most PRESENCE_AHEAD_S (it may have
// stopped), the jump to a newer report is spread out at PRESENCE_SMOOTH per second unless it is a teleport
// (PRESENCE_SNAP_KM), and a car that sent nothing new for PRESENCE_GONE_S (local clock) is gone. Our values.
PRESENCE_AHEAD_S :: 1.0
PRESENCE_SMOOTH :: 5.0
PRESENCE_SNAP_KM :: 0.25
PRESENCE_GONE_S :: 5.0
// The clock difference to an author is the lowest (receive time - send time) seen; it rises this many ms per ms
// so a value from a lucky packet or a drifting clock does not stick.
PRESENCE_CLOCK_RELAX :: 0.01

Presence_Flag :: enum u8 {
	On_Road,
	Landing,
}

Presence :: struct {
	magic:   u32le,
	flags:   bit_set[Presence_Flag;u8],
	skin:    u8, // Car_Skin of the author's car, unknown values draw as Concept
	_:       [2]u8,
	time_ms: i64le, // unix milliseconds, set by the author
	author:  [32]u8, // ed25519 public key
	x, y:    f32le, // km
	alt:     f32le, // m
	heading: f32le, // radians clockwise from north
	speed:   f32le, // m/s over the ground
	_:       [4]u8,
	sig:     [64]u8, // over every byte before it
}
#assert(size_of(Presence) == 136 && offset_of(Presence, sig) == 72)

// Node side: newest position per author, filled by the sync and serve threads.
Presence_Table :: struct {
	lock:     sync.Mutex,
	slots:    [PRESENCE_SLOTS]Presence,
	recv_ms:  [PRESENCE_SLOTS]i64, // local unix ms at which the slot last took a newer position
	own:      Presence, // the game's latest, signed
	has_own:  bool,
	// The frame loop's newest position, unsigned: the sync thread signs it right before a swap, so signing
	// stays off the frame (#108) and what goes out is as fresh as it can be.
	next:     Presence,
	has_next: bool,
}

// One other car as the game sees it (World.others). pos, alt and heading are where it is drawn this frame; the
// rest is the last report and what presence_frame derived from it.
Other_Car :: struct {
	author:      [32]u8,
	pos:         [2]f32, // km
	alt:         f32,
	heading:     f32,
	speed:       f32, // m/s over the ground
	on_road:     bool,
	skin:        Car_Skin,
	turn:        f32, // rad/s, from the last two reports
	climb:       f32, // m/s
	fly:         f32, // eased 0 on the wheels .. 1 flying, like Car_Anim.fly
	roll:        f32, // wheel rotation, radians
	time_ms:     i64, // the report, the author's clock
	clock_ms:    f32, // local receive time - time_ms, lowest seen (PRESENCE_CLOCK_RELAX)
	rep_pos:     [2]f32,
	rep_alt:     f32,
	rep_heading: f32,
	rep_dt:      f32, // seconds between the last two reports, 0 = first one
	vel:         [2]f32, // km/s, from the last two reports (drift and sliding included), else heading x speed
	err_pos:     [2]f32, // km, what is left of the jump to the last report, decays to zero
	err_alt:     f32,
	err_heading: f32,
}

unix_ms :: proc() -> i64 {
	return time.time_to_unix_nano(time.now()) / 1e6
}

presence_sign :: proc(w: ^World, p: ^Presence) -> bool {
	if w.identity_pub == {} do return false
	p.magic = PRESENCE_MAGIC
	p.author = w.identity_pub
	ed25519.sign(&w.identity, mem.ptr_to_bytes(p)[:offset_of(Presence, sig)], p.sig[:])
	return true
}

// Anything from outside: magic, finite values on the map, time within the window, then the signature.
presence_check :: proc(p: ^Presence, now_ms: i64) -> bool {
	if p.magic != PRESENCE_MAGIC do return false
	x, y, alt := f32(p.x), f32(p.y), f32(p.alt)
	if !(x >= 0 && x <= MAP_W_KM && y >= 0 && y <= MAP_H_KM && alt > -500 && alt < 10_000) do return false
	if !(abs(f32(p.heading)) <= 100 && f32(p.speed) >= 0 && f32(p.speed) <= 200) do return false
	t := i64(p.time_ms)
	if t < now_ms - PRESENCE_TTL_S * 1000 || t > now_ms + PRESENCE_FUTURE_S * 1000 do return false
	pub: ed25519.Public_Key
	if !ed25519.public_key_set_bytes(&pub, p.author[:]) do return false
	return ed25519.verify(&pub, mem.ptr_to_bytes(p)[:offset_of(Presence, sig)], p.sig[:])
}

// Keeps p if it is newer than what the table has for its author. Full: the oldest goes. Checked already.
presence_put :: proc(t: ^Presence_Table, p: ^Presence, now_ms: i64) {
	sync.mutex_lock(&t.lock)
	defer sync.mutex_unlock(&t.lock)
	oldest := 0
	for &q, i in t.slots {
		if q.magic != 0 && q.author == p.author {
			if p.time_ms > q.time_ms {
				q = p^
				t.recv_ms[i] = now_ms
			}
			return
		}
		if q.magic == 0 || q.time_ms < t.slots[oldest].time_ms do oldest = i
	}
	t.slots[oldest] = p^
	t.recv_ms[oldest] = now_ms
	fmt.eprintfln("[net] presence: car %016x appeared", key_short(p.author))
}

// The fresh positions to hand out, own one first, at most len(out).
presence_fresh :: proc(t: ^Presence_Table, out: []Presence, now_ms: i64) -> int {
	sync.mutex_lock(&t.lock)
	defer sync.mutex_unlock(&t.lock)
	count := 0
	if t.has_own && count < len(out) {
		out[count] = t.own
		count += 1
	}
	for q in t.slots {
		if count == len(out) do break
		if q.magic == 0 || i64(q.time_ms) < now_ms - PRESENCE_TTL_S * 1000 do continue
		if t.has_own && q.author == t.own.author do continue
		out[count] = q
		count += 1
	}
	return count
}

// Reads count + positions from s, keeps the ones that check. False on a broken connection or a bad count.
presence_recv :: proc(t: ^Presence_Table, s: net.TCP_Socket, buf: []Presence, now_ms: i64) -> bool {
	count: u32le
	if !net_recv(s, mem.ptr_to_bytes(&count)) || int(count) > len(buf) do return false
	got := buf[:count]
	if !net_recv(s, mem.slice_to_bytes(got)) do return false
	at := unix_ms()
	for &p in got {
		if presence_check(&p, now_ms) do presence_put(t, &p, at)
	}
	return true
}

presence_send :: proc(s: net.TCP_Socket, ps: []Presence) -> bool {
	count := u32le(len(ps))
	return net_send(s, mem.ptr_to_bytes(&count)) && net_send(s, mem.slice_to_bytes(ps))
}

// Server side of 'Q': take theirs, answer with ours (after taking, so it already holds theirs).
presence_serve :: proc(w: ^World, s: net.TCP_Socket) -> bool {
	n := &w.node
	now_ms := unix_ms()
	if !presence_recv(&n.presence, s, n.presence_serve[:], now_ms) do return false
	count := presence_fresh(&n.presence, n.presence_serve[:], now_ms)
	return presence_send(s, n.presence_serve[:count])
}

// On the sync thread, every PRESENCE_S while anything is live (else PRESENCE_IDLE_S): signs the game's newest
// position, then swaps with up to PRESENCE_PEERS peers that synced recently. Each swap passes on what the other
// peers said, so positions spread over several hops within a few rounds. Returns whether anything is live.
node_presence :: proc(w: ^World) -> bool {
	n := &w.node
	t := &n.presence
	{
		sync.mutex_lock(&t.lock)
		p, fresh := t.next, t.has_next
		t.has_next = false
		sync.mutex_unlock(&t.lock)
		if fresh && presence_sign(w, &p) {
			sync.mutex_lock(&t.lock)
			t.own = p
			t.has_own = true
			sync.mutex_unlock(&t.lock)
		}
	}
	now := time.time_to_unix(time.now())
	now_ms := unix_ms()
	eps: [PRESENCE_PEERS]net.Endpoint
	count := 0
	{
		sync.mutex_lock(&n.peers_lock)
		defer sync.mutex_unlock(&n.peers_lock)
		for p in n.peers[:n.peer_count] {
			if count == PRESENCE_PEERS do break
			if now - p.last_ok > 2 * SYNC_S do continue
			eps[count] = p.ep
			count += 1
		}
	}
	live := presence_fresh(t, n.presence_sync[:], now_ms) > 0
	for ep in eps[:count] {
		s, dialed := net_dial(ep, &n.stop)
		if !dialed do continue
		defer net.close(s)
		if _, _, ok := node_hello(n, s); !ok do continue
		mine := presence_fresh(t, n.presence_sync[:], now_ms)
		if !net_send(s, []u8{'Q'}) || !presence_send(s, n.presence_sync[:mine]) do continue
		presence_recv(t, s, n.presence_sync[:], now_ms)
	}
	return live || presence_fresh(t, n.presence_sync[:], now_ms) > 0
}

// Every frame: leaves the ship's newest position for the sync thread to sign while flying or driving, and
// rebuilds w.others from the node table, with a toast for every car that joins. Each car is its last report moved on to now (other_predict); a newer
// report does not jump the car there, the difference fades out over a few frames.
presence_frame :: proc(w: ^World, dt: f32) {
	t := &w.node.presence
	now_ms := unix_ms()
	if w.screen == .Navigate && !carpool_is_passenger(w) {
		s := &w.ship
		speed := s.free ? linalg.length(s.vel.xy) : s.speed
		p := Presence {
			time_ms = i64le(now_ms),
			x       = f32le(w.pose.pos.x),
			y       = f32le(w.pose.pos.y),
			alt     = f32le(w.pose.alt),
			heading = f32le(w.pose.heading),
			speed   = f32le(clamp(speed, 0, 200)),
			skin    = u8(w.car_skin),
		}
		if s.on_road || (s.free && s.driving) do p.flags += {.On_Road}
		if s.landing do p.flags += {.Landing}
		sync.mutex_lock(&t.lock)
		t.next = p
		t.has_next = true
		sync.mutex_unlock(&t.lock)
	} else {
		sync.mutex_lock(&t.lock)
		t.has_next = false
		t.has_own = false
		sync.mutex_unlock(&t.lock)
	}

	prev := make([]Other_Car, w.other_count, context.temp_allocator)
	copy(prev, w.others[:w.other_count])
	decay := math.exp(-dt * PRESENCE_SMOOTH)
	joined := 0
	joined_names: [2]string
	defer switch joined {
	case 0:
	case 1:
		ui_toast(w, fmt.tprintf("%s joined the game", joined_names[0]))
	case 2:
		ui_toast(w, fmt.tprintf("%s and %s joined the game", joined_names[0], joined_names[1]))
	case:
		ui_toast(w, fmt.tprintf("%d players joined the game", joined))
	}
	sync.mutex_lock(&t.lock)
	defer sync.mutex_unlock(&t.lock)
	w.other_count = 0
	for q, i in t.slots {
		if q.magic == 0 || q.author == w.identity_pub do continue
		if now_ms - i64(q.time_ms) > PRESENCE_TTL_S * 1000 do continue
		if f32(now_ms - t.recv_ms[i]) > PRESENCE_GONE_S * 1000 do continue
		o: Other_Car
		known := false
		for p in prev {
			if p.author != q.author do continue
			o, known = p, true
			break
		}
		heading := math.mod(f32(q.heading), math.TAU)
		if heading < 0 do heading += math.TAU
		pos := [2]f32{f32(q.x), f32(q.y)}
		on_road := .On_Road in q.flags
		seen := f32(t.recv_ms[i] - i64(q.time_ms))
		if !known {
			// Someone joined (Lars, 2026-11-22: "notification someone joining the game"): new, or back after
			// PRESENCE_GONE_S without a word. One toast for all who joined this frame.
			buf: [16]u8
			name := peer_name_text(q.author, buf[:])
			logf(w, "presence", "car %s joined", name)
			if joined < len(joined_names) do joined_names[joined] = strings.clone(name, context.temp_allocator)
			joined += 1
			fwd := [2]f32{math.sin(heading), -math.cos(heading)}
			o = {
				author      = q.author,
				time_ms     = i64(q.time_ms),
				clock_ms    = seen,
				rep_pos     = pos,
				rep_alt     = f32(q.alt),
				rep_heading = heading,
				vel         = fwd * f32(q.speed) / 1000,
				fly         = on_road ? 0 : 1,
			}
		} else if i64(q.time_ms) > o.time_ms {
			was_pos, was_alt, was_heading := other_predict(o, now_ms)
			was_pos += o.err_pos
			was_alt += o.err_alt
			was_heading += o.err_heading
			// Two reports a few ms apart (two gossip paths) say little about the speed: keep the last estimate.
			rep_dt := f32(i64(q.time_ms) - o.time_ms) / 1000
			if rep_dt >= 2 {
				o.vel = [2]f32{math.sin(heading), -math.cos(heading)} * f32(q.speed) / 1000
				o.turn, o.climb, o.rep_dt = 0, 0, 0
			} else if rep_dt >= 0.05 {
				o.vel = (pos - o.rep_pos) / rep_dt
				if speed := linalg.length(o.vel); speed > 0.2 do o.vel *= 0.2 / speed
				o.turn = clamp(angle_wrap(heading - o.rep_heading) / rep_dt, -1.5, 1.5)
				o.climb = clamp((f32(q.alt) - o.rep_alt) / rep_dt, -40, 40)
				o.rep_dt = rep_dt
			}
			o.time_ms = i64(q.time_ms)
			o.clock_ms = min(o.clock_ms, seen)
			o.rep_pos, o.rep_alt, o.rep_heading = pos, f32(q.alt), heading
			now_pos, now_alt, now_heading := other_predict(o, now_ms)
			o.err_pos = was_pos - now_pos
			o.err_alt = was_alt - now_alt
			o.err_heading = angle_wrap(was_heading - now_heading)
			if linalg.length(o.err_pos) > PRESENCE_SNAP_KM do o.err_pos, o.err_alt, o.err_heading = {}, 0, 0
		}
		o.clock_ms += dt * 1000 * PRESENCE_CLOCK_RELAX
		o.err_pos *= decay
		o.err_alt *= decay
		o.err_heading *= decay
		o.on_road = on_road
		o.skin = car_skin_of(q.skin)
		o.speed = linalg.length(o.vel) * 1000
		o.fly += ((on_road ? 0 : 1) - o.fly) * (1 - math.exp(-dt * 6))
		o.roll -= dt * o.speed / CAR_WHEEL_R * (1 - o.fly)
		at, alt, h := other_predict(o, now_ms)
		o.pos, o.alt, o.heading = at + o.err_pos, alt + o.err_alt, h + o.err_heading
		w.others[w.other_count] = o
		w.other_count += 1
	}
}

// A test car for the end-to-end check (drift --headless --node --bot, script peers): it circles
// PRESENCE_BOT_KM around centre at PRESENCE_BOT_MS, placed by the wall clock, so every process on one machine
// knows where it really is at any moment and can measure how far its drawn copy is off.
PRESENCE_BOT_KM :: 0.15
PRESENCE_BOT_MS :: 20.0

bot_pose :: proc(centre: [2]f32, now_ms: i64) -> (pos: [2]f32, heading: f32) {
	period: f64 = math.TAU * PRESENCE_BOT_KM * 1000 / PRESENCE_BOT_MS * 1000
	period_ms := i64(period)
	a := f32(f64(now_ms % period_ms) / f64(period_ms) * math.TAU)
	return centre + [2]f32{math.sin(a), -math.cos(a)} * PRESENCE_BOT_KM, a + math.PI / 2
}

// x as an angle in -pi ..< pi, for any x.
angle_wrap :: proc(x: f32) -> f32 {
	return math.mod(math.mod(x, math.TAU) + 3 * math.PI, math.TAU) - math.PI
}

// The last report moved on to now_ms: along the measured velocity, turned on at the measured turn rate (that
// velocity is the chord of the last interval, so it points rep_dt / 2 back), climbing at the measured rate.
other_predict :: proc(o: Other_Car, now_ms: i64) -> (pos: [2]f32, alt, heading: f32) {
	age := clamp((f32(now_ms - o.time_ms) - o.clock_ms) / 1000, 0, PRESENCE_AHEAD_S)
	a := o.turn * (o.rep_dt + age) / 2
	c, s := math.cos(a), math.sin(a)
	v := [2]f32{o.vel.x * c - o.vel.y * s, o.vel.x * s + o.vel.y * c}
	return o.rep_pos + v * age, o.rep_alt + o.climb * age, o.rep_heading + o.turn * age
}

// How another car is drawn: banked in turns and pitched in climbs while flying, front wheels steered and rolling
// on the road, like the own car (car_anim_update).
other_anim :: proc(w: ^World, o: Other_Car) -> Car_Anim {
	ce := &w.car_edit
	return {
		fly = o.fly,
		heading = o.heading,
		bank = clamp(o.turn / SHIP_MAX_TURN_RATE, -1, 1) * ce.bank_deg * math.RAD_PER_DEG * o.fly,
		pitch = clamp(o.climb / SHIP_CLIMB_RATE, -1, 1) * ce.pitch_deg * math.RAD_PER_DEG * o.fly,
		roll = o.roll,
		steer = clamp(o.turn * DRIVE_WHEELBASE_M / max(o.speed, 2), -1, 1) * CAR_STEER * (1 - o.fly),
		time = w.car_anim.time + f32(o.author[0]),
		seeded = true,
	}
}
