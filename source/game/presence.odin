// author: andrei
package game

import "core:crypto/ed25519"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:net"
import "core:sync"
import "core:time"

// Other cars on the map (Lars, 2026-11-21: "peer-to-peer, geen relay service, gossiping"). Every game signs its
// own position with its ed25519 identity every PRESENCE_S and swaps the fresh positions it knows with its peers
// (op 'Q'), so a position travels from node to node without any central server. A node keeps the newest
// position per author for PRESENCE_TTL_S, checks every signature and drops what is too old or too far ahead.
// Positions are public on purpose: this is the presence everyone sees. The carpool live position stays
// end-to-end encrypted between the two sides of a trip (Live_Packet).
//   'Q' u32 count + count Presence  ->  u32 count + count Presence (what this node knows, own one included)
PRESENCE_MAGIC :: 0x50525244 // "DRRP"
PRESENCE_S :: 2.0
PRESENCE_TTL_S :: 20
PRESENCE_FUTURE_S :: 30 // allowed clock difference
PRESENCE_SLOTS :: 256
PRESENCE_GOSSIP :: 64 // most positions in one exchange
PRESENCE_PEERS :: 8
// Copies of the table the game draws from, refreshed this often.
PRESENCE_COPY_S :: 0.25

Presence_Flag :: enum u8 {
	On_Road,
	Landing,
}

Presence :: struct {
	magic:   u32le,
	flags:   bit_set[Presence_Flag;u8],
	_:       [3]u8,
	time_ms: i64le, // unix milliseconds, set by the author
	author:  [32]u8, // ed25519 public key
	x, y:    f32le, // km
	alt:     f32le, // m
	heading: f32le, // radians clockwise from north
	speed:   f32le, // m/s along the heading
	_:       [4]u8,
	sig:     [64]u8, // over every byte before it
}
#assert(size_of(Presence) == 136 && offset_of(Presence, sig) == 72)

// Node side: newest position per author, filled by the sync and serve threads.
Presence_Table :: struct {
	lock:    sync.Mutex,
	slots:   [PRESENCE_SLOTS]Presence,
	own:     Presence, // the game's latest, signed
	has_own: bool,
}

// One other car as the game sees it (World.others), already in game units.
Other_Car :: struct {
	author:  [32]u8,
	pos:     [2]f32,
	alt:     f32,
	heading: f32,
	speed:   f32,
	on_road: bool,
	age_s:   f32, // seconds since the author sent it, at the copy
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
presence_put :: proc(t: ^Presence_Table, p: ^Presence) {
	sync.mutex_lock(&t.lock)
	defer sync.mutex_unlock(&t.lock)
	oldest := 0
	for &q, i in t.slots {
		if q.magic != 0 && q.author == p.author {
			if p.time_ms > q.time_ms do q = p^
			return
		}
		if q.magic == 0 || q.time_ms < t.slots[oldest].time_ms do oldest = i
	}
	t.slots[oldest] = p^
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
	for &p in got {
		if presence_check(&p, now_ms) do presence_put(t, &p)
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
	now_ms := time.time_to_unix_nano(time.now()) / 1e6
	if !presence_recv(&n.presence, s, n.presence_serve[:], now_ms) do return false
	count := presence_fresh(&n.presence, n.presence_serve[:], now_ms)
	return presence_send(s, n.presence_serve[:count])
}

// Every PRESENCE_S on the sync thread: swap with up to PRESENCE_PEERS peers that synced recently. Each swap
// passes on what the other peers said, so positions spread over several hops within a few rounds.
node_presence :: proc(w: ^World) {
	n := &w.node
	now := time.time_to_unix(time.now())
	now_ms := time.time_to_unix_nano(time.now()) / 1e6
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
	for ep in eps[:count] {
		s, dialed := net_dial(ep, &n.stop)
		if !dialed do continue
		defer net.close(s)
		if _, _, ok := node_hello(n, s); !ok do continue
		mine := presence_fresh(&n.presence, n.presence_sync[:], now_ms)
		if !net_send(s, []u8{'Q'}) || !presence_send(s, n.presence_sync[:mine]) do continue
		presence_recv(&n.presence, s, n.presence_sync[:], now_ms)
	}
}

// Frame loop: signs the ship's position every PRESENCE_S while flying or driving, and copies the fresh other
// cars into w.others every PRESENCE_COPY_S. Their positions move on from the last report with heading and
// speed when drawn (others_draw_pos), so they glide between reports.
presence_frame :: proc(w: ^World, dt: f32) {
	n := &w.node
	t := &n.presence
	w.others_copied_s += dt
	w.presence_send_s += dt
	if w.screen == .Navigate && w.presence_send_s >= PRESENCE_S {
		w.presence_send_s = 0
		s := &w.ship
		p := Presence {
			time_ms = i64le(time.time_to_unix_nano(time.now()) / 1e6),
			x       = f32le(s.pos.x),
			y       = f32le(s.pos.y),
			alt     = f32le(s.alt),
			heading = f32le(s.heading),
			speed   = f32le(s.speed),
		}
		if s.on_road do p.flags += {.On_Road}
		if s.landing do p.flags += {.Landing}
		if presence_sign(w, &p) {
			sync.mutex_lock(&t.lock)
			t.own = p
			t.has_own = true
			sync.mutex_unlock(&t.lock)
		}
	}
	w.presence_copy_s += dt
	if w.presence_copy_s < PRESENCE_COPY_S do return
	w.presence_copy_s = 0
	now_ms := time.time_to_unix_nano(time.now()) / 1e6
	sync.mutex_lock(&t.lock)
	defer sync.mutex_unlock(&t.lock)
	w.other_count = 0
	for q in t.slots {
		if q.magic == 0 || q.author == w.identity_pub do continue
		age := f32(now_ms - i64(q.time_ms)) / 1000
		if age > PRESENCE_TTL_S do continue
		w.others[w.other_count] = {
			author  = q.author,
			pos     = {f32(q.x), f32(q.y)},
			alt     = f32(q.alt),
			heading = f32(q.heading),
			speed   = f32(q.speed),
			on_road = .On_Road in q.flags,
			age_s   = max(age, 0),
		}
		w.other_count += 1
	}
	w.others_copied_s = 0
}

// Where to draw another car now: its report moved on along its heading for the time since (at most
// PRESENCE_S + 1 s, so a car that stopped reporting does not fly off).
others_draw_pos :: proc(w: ^World, o: Other_Car) -> [2]f32 {
	ahead := min(o.age_s + w.others_copied_s, PRESENCE_S + 1)
	return o.pos + [2]f32{math.sin(o.heading), -math.cos(o.heading)} * o.speed * ahead / 1000
}
