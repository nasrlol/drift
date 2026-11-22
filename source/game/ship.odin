// author: dario
package game

import "core:math"
import "core:math/linalg"

// All axes are -1..1, zero is neutral. Input code fills it. In map mode the camera reads it,
// in drive mode ship_step will.
Controls :: struct {
	throttle: f32,
	turn:     f32,
	climb:    f32,
}

// One recorded step: the three axes as i8, -127..127 of -1..1. The simulation steps with the quantized
// value, so replaying the recording reproduces the ship path exactly.
Control_Step :: [3]i8

// 1 hour at 60 Hz, 3 bytes per step = 648 KB, allocated once from the perm arena. Recording stops when full.
REPLAY_MAX_STEPS :: 60 * 3600

Replay :: struct {
	steps: []Control_Step,
	count: int,
}

controls_pack :: proc(c: Controls) -> Control_Step {
	return {
		i8(math.round(clamp(c.throttle, -1, 1) * 127)),
		i8(math.round(clamp(c.turn, -1, 1) * 127)),
		i8(math.round(clamp(c.climb, -1, 1) * 127)),
	}
}

controls_unpack :: proc(s: Control_Step) -> Controls {
	return {f32(s[0]) / 127, f32(s[1]) / 127, f32(s[2]) / 127}
}

Ship_Warning :: enum {
	Terrain,
	No_Fly,
	Jam, // in a traffic jam: other cars slow the ship down (ship_jam_factor)
}

// pos is km in map space (y down), alt is m, heading is radians clockwise from north (up on the map),
// speed is m/s along the heading, turn_rate is rad/s. warnings is rebuilt every step, the UI only reads it.
Ship :: struct {
	pos:       [2]f32,
	alt:       f32,
	heading:   f32,
	speed:     f32,
	turn_rate: f32,
	warnings:  bit_set[Ship_Warning],
	// Set while within reach of a hub tower, dock_hub is only meaningful then.
	docked:    bool,
	dock_hub:  int,
	// Held at the tower top + DOCK_ABOVE_M after docking, until the throttle opens again.
	moored:    bool,
	// Energy since the app started (spec "Vermogen"): drawn by the motors and the ballonets, and harvested by
	// the solar film. The battery holds BATTERY_START x BATTERY_KWH - used + solar (ship_battery_kwh).
	used_kwh:  f32,
	solar_kwh: f32,
	// On the ground as a flying car (road.odin): locked to road_edges[road_edge], road_s km along it. landing:
	// sinking onto that edge, lifting: climbing off the road up to the lowest flying height.
	on_road:   bool,
	landing:   bool,
	lifting:   bool,
	road_edge: int,
	road_s:    f32,
	// Free flight (street view, ship_free_step): velocity in m/s (x east, y south, z up) and the part of the
	// position below the f32 resolution of pos, in m, so slow flight still moves at 150 km from the corner.
	free:      bool,
	vel:       [3]f32,
	pos_frac:  [2]f32,
	hit_s:     f32, // seconds since the car last hit a wall, for the street view's shake and the HUD
	// On its wheels on the ground or a roof in free flight (landed by flying down onto it), driving like a car.
	driving:   bool,
}

// Where the ship is drawn, filled by game_update every frame: between its state before and after the last fixed
// step, by the time left in the accumulator. Drawn from the raw state, the car jumped 0, 1 or 2 steps per frame
// when the frame times were uneven (as on a real screen) while the cameras eased smoothly, so buildings and roads
// shook: 1.6 % of the pixels flickered A-B-A in a fast flight (--script frame_ms), 0.03 % with even frames.
Ship_Pose :: struct {
	pos:     [2]f64, // km, pos_frac included
	alt:     f32,
	heading: f32,
}

ship_pose :: proc(s: ^Ship) -> Ship_Pose {
	return {
		pos = {f64(s.pos.x) + f64(s.pos_frac.x) / 1000, f64(s.pos.y) + f64(s.pos_frac.y) / 1000},
		alt = s.alt,
		heading = s.heading,
	}
}

// Battery charge in kWh, BATTERY_START x BATTERY_KWH at the start, clamped to the capacity.
ship_battery_kwh :: proc(s: ^Ship) -> f32 {
	return clamp(BATTERY_START * BATTERY_KWH - s.used_kwh + s.solar_kwh, 0, BATTERY_KWH)
}

// Flying is fast (Lars, 2026-11-21: "ik moet sneller kunnen vliegen en opstijgen"; nasr, 2026-11-22: holding the
// throttle longer has to keep going faster): 140 m/s is 504 km/h. On the
// road it keeps the old limits (road_speed). SHIP_ACCEL stays, the autopilot speeds up with it. Our values.
SHIP_MAX_SPEED :: 140.0
SHIP_ACCEL :: 5.0
SHIP_BRAKE :: 6.0
// Flying by hand on the map (nasr, 2026-11-22: zoomed in it felt slow and sluggish): 0-100 km/h in ~2.3 s,
// top speed after ~12 s. The autopilot keeps SHIP_ACCEL / SHIP_BRAKE. Our values.
SHIP_HAND_ACCEL :: 12.0
SHIP_HAND_BRAKE :: 16.0
SHIP_MAX_TURN_RATE :: 0.6
SHIP_TURN_SMOOTH_S :: 0.5
SHIP_CLIMB_RATE :: 12.0
SHIP_POWER_CAP_MS :: 35.0 // 126 km/h, see the energy in ship_step
// Climbing costs this much power per m/s of climb on top of P(v, g) (spec "Vermogen").
SHIP_CLIMB_KW_PER_MS :: 4.3
SHIP_CEILING :: 900.0
SHIP_MIN_CLEARANCE :: 28.0
SHIP_TERRAIN_WARN_M :: 60.0
DOCK_HORIZONTAL_KM :: 0.030
DOCK_VERTICAL_M :: 25.0
// Closest the ship gets to the map edge, km. The route grid keeps its edge cells blocked anyway.
SHIP_EDGE_KM :: 1.0

// Runs once per fixed step on w.ship. Reads only the ship, the controls, the terrain and the weather.
ship_step :: proc(w: ^World, c: Controls, dt: f32) {
	s := &w.ship
	hour := sim_hour(w)

	if s.moored {
		if c.throttle <= 0 {
			hub := w.m.hubs[s.dock_hub].pos
			s.pos = hub
			s.alt = height_at(w, hub.x, hub.y) + HUB_TOWER_M + DOCK_ABOVE_M
			s.speed, s.turn_rate = 0, 0
			s.docked = true
			return
		}
		s.moored = false
	}
	if s.free {
		// Back from free flight: keep the speed along the heading, the climb clamp below lifts the car to the
		// lowest flying height.
		s.free = false
		s.speed = max(linalg.dot(s.vel.xy, [2]f32{math.sin(s.heading), -math.cos(s.heading)}), 0)
		s.vel, s.pos_frac = {}, {}
	}
	// On the road (or landing on it) only the jam warning applies; in the air the warnings are rebuilt below.
	if s.on_road || s.landing do s.warnings = ship_jam_factor(w) > 1 ? {.Jam} : {}
	if s.landing && road_landing_step(w, c, dt) do return
	if s.on_road && road_step(w, c, dt) do return

	// By hand the speed editor's values (tune.odin), the autopilot keeps its own.
	hand := !(w.nav.active && !w.nav.manual)
	target_turn := c.turn * (hand ? w.tune.hand_turn : SHIP_MAX_TURN_RATE)
	s.turn_rate += (target_turn - s.turn_rate) * min(dt / SHIP_TURN_SMOOTH_S, 1)
	s.heading = math.mod(s.heading + s.turn_rate * dt, math.TAU)

	// In a traffic jam the ship slows down like the router expects (traffic_factor).
	target_speed := max(c.throttle, 0) * w.tune.max_speed / ship_jam_factor(w)
	accel: f32 = hand ? w.tune.hand_accel : SHIP_ACCEL
	brake: f32 = hand ? w.tune.hand_brake : SHIP_BRAKE
	if target_speed > s.speed {
		s.speed = min(s.speed + accel * dt, target_speed)
	} else {
		s.speed = max(s.speed - brake * dt, target_speed)
	}

	// The wind layer nearest to the ship's altitude, the forecast hour from the simulated time.
	layers := LAYER_ALT
	layer := clamp(int(math.round((s.alt - layers[0]) / (layers[1] - layers[0]))), 0, WIND_LAYERS - 1)
	wind := wind_at(w, s.pos.x, s.pos.y, layer, hour)
	air := [2]f32{math.sin(s.heading) * s.speed, -math.cos(s.heading) * s.speed}
	prev := s.pos
	s.pos += (air + wind) * dt / 1000
	// The ship never leaves the map (Lars, 2026-11-21): it slides along the edge, wind included.
	s.pos = linalg.clamp(
		s.pos,
		[2]f32{SHIP_EDGE_KM, SHIP_EDGE_KM},
		[2]f32{MAP_W_KM, MAP_H_KM} - SHIP_EDGE_KM,
	)
	// Nor Belgium (nasr, 2026-11-21): at the border it keeps the axis that stays inside, so it slides along.
	// A ship that is already outside moves freely, so it can come back.
	s.pos = ship_clamp_belgium(w, s.pos, prev)

	alt0 := s.alt
	s.alt += c.climb * SHIP_CLIMB_RATE * dt
	ground := height_at(w, s.pos.x, s.pos.y)
	floor := ground + SHIP_MIN_CLEARANCE
	if s.lifting {
		// Taking off from a road: up at ROAD_LIFT_MS or more until the lowest flying height.
		s.alt = max(s.alt, alt0 + ROAD_LIFT_MS * dt)
		if s.alt >= floor do s.lifting = false
		else do floor = ground
	}
	s.alt = min(max(s.alt, floor), SHIP_CEILING)

	// Energy (spec): P(airspeed, gust) + climbing power, solar from the cloud cover of this hour.
	climb_ms := max(s.alt - alt0, 0) / dt
	gust := gust_at(w, s.pos.x, s.pos.y, layer, hour)
	// Above SHIP_POWER_CAP_MS the draw stops growing (Lars, 2026-11-21: flying at 252 km/h emptied the battery in
	// 3 min with P(v) = 3 + 0.0085 v^3). The routes never fly that fast, so their energy is unchanged.
	s.used_kwh +=
		(power_kw(min(s.speed, SHIP_POWER_CAP_MS), gust) + climb_ms * SHIP_CLIMB_KW_PER_MS) * dt / 3600
	s.solar_kwh += solar_kw(cloud_at(w, s.pos.x, s.pos.y, hour), sun_factor(w, hour)) * dt / 3600

	s.warnings = {}
	if s.alt - ground < SHIP_TERRAIN_WARN_M do s.warnings += {.Terrain}
	for z in w.no_fly {
		if z.radius > 0 && s.alt < z.ceiling && linalg.length(s.pos - z.center) < z.radius {
			s.warnings += {.No_Fly}
		}
	}

	if ship_jam_factor(w) > 1 do s.warnings += {.Jam}

	road_try_land(w, c)
	if s.landing do return

	s.docked = false
	for i in 0 ..< w.m.hub_count {
		hub := w.m.hubs[i].pos
		if linalg.length(s.pos - hub) > DOCK_HORIZONTAL_KM do continue
		top := height_at(w, hub.x, hub.y) + HUB_TOWER_M
		if abs(s.alt - top) <= DOCK_VERTICAL_M {
			s.docked = true
			s.dock_hub = i
			break
		}
	}
}

// At the Belgian border, keeps the axis that stays inside so the car slides along; outside moves freely.
ship_clamp_belgium :: proc(w: ^World, pos, prev: [2]f32) -> [2]f32 {
	if belgium_inside(w, prev.x, prev.y) && !belgium_inside(w, pos.x, pos.y) {
		if belgium_inside(w, pos.x, prev.y) do return {pos.x, prev.y}
		if belgium_inside(w, prev.x, pos.y) do return {prev.x, pos.y}
		return prev
	}
	return pos
}

// How much the other cars around the ship slow it down: 1 when the way is free (see traffic_factor).
ship_jam_factor :: proc(w: ^World) -> f32 {
	if w.other_count == 0 do return 1
	s := &w.ship
	return traffic_factor(u8(min(traffic_near(w, s.pos, s.alt, s.on_road, TRAFFIC_RADIUS_KM), 255)))
}

// Free flight in the street view (Lars, 2026-11-21: "zoals gta, zo realistisch mogelijk"): the car keeps its
// momentum. Thrust along the heading, quadratic air drag (top speed SHIP_MAX_SPEED), sideways grip of the fans
// against the air, so the car crabs in a crosswind and slides a little in fast turns; vertical thrust with an
// altitude hold. Wind is the forecast at the car's layer, weaker near the ground, with gusts as smooth
// turbulence. Flying down onto the ground or a roof lands it on its wheels (DRIVE_*); it is pushed out of walls
// (collide_car), losing the speed into the wall. Our values. Deterministic: same inputs, same path.
FREE_ACCEL :: 10.0 // m/s^2 at full throttle, 0-100 km/h in ~2.8 s, 90 % of top speed after ~21 s
FREE_BRAKE :: 11.0
FREE_REVERSE_MS :: 8.0
FREE_GRIP :: 2.4 // 1/s, how fast sideways air speed dies out
FREE_TURN_SLOW :: 1.4 // rad/s turn rate when hovering
FREE_TURN_FAST :: 0.55 // rad/s at top speed
FREE_TURN_SMOOTH_S :: 0.22
FREE_CLIMB_ACCEL :: 14.0
FREE_VZ_DAMP :: 1.15 // 1/s, the altitude hold: climbs settle at ~12 m/s
FREE_RADIUS_M :: 2.2 // the car as a circle for the walls
FREE_WALL_KEEP :: 0.35 // share of the speed along the wall kept in a hit
FREE_GROUND_WIND_M :: 80.0 // the wind grows to its layer value over this height
FREE_GUST_ACCEL :: 2.2 // m/s^2 of turbulence at gust index 1
// On the wheels (Lars, 2026-11-21: "auto moet landen op grond, dan banden goed en dan rijden"): flying down onto
// the ground or a roof lands the car, then it drives like a car: the wheels hold the velocity on the heading
// (DRIVE_GRIP), the throttle drives to ROAD_MAX_SPEED and brakes, the steering turns by the speed over a 2.7 m
// wheelbase (less lock at speed), up lifts it off, a drop of DRIVE_DROP_M (a roof edge) makes it fly. Our values.
DRIVE_ACCEL :: 4.0
DRIVE_BRAKE :: 9.0
DRIVE_REVERSE_MS :: 6.0
DRIVE_ROLL :: 0.04 // 1/s rolling loss
DRIVE_AIR :: (DRIVE_ACCEL - DRIVE_ROLL * ROAD_MAX_SPEED) / (ROAD_MAX_SPEED * ROAD_MAX_SPEED) // top speed = ROAD_MAX_SPEED
DRIVE_GRIP :: 9.0 // 1/s, how fast sideways speed dies out on the wheels
DRIVE_WHEELBASE_M :: 2.7
DRIVE_STEER :: 0.6 // rad of lock when slow
DRIVE_STEER_SMOOTH_S :: 0.15
DRIVE_LAT_ACCEL :: 7.0 // m/s^2, the most the tyres hold in a bend (0.7 g)
DRIVE_LIFT_MS :: 3.0 // the jump off the ground on take-off
DRIVE_DROP_M :: 0.5

ship_free_step :: proc(w: ^World, c: Controls, dt: f32) {
	s := &w.ship
	hour := sim_hour(w)
	fwd := [2]f32{math.sin(s.heading), -math.cos(s.heading)}
	if !s.free {
		s.free = true
		s.vel = {fwd.x * s.speed, fwd.y * s.speed, 0}
		s.pos_frac = {}
		s.driving = s.on_road
		s.on_road, s.landing, s.lifting = false, false, false
		s.moored, s.docked = false, false
		s.turn_rate = 0
		s.hit_s = 10
	}
	if s.driving && c.climb > 0.2 {
		s.driving = false
		s.vel.z = DRIVE_LIFT_MS
	}
	s.hit_s += dt
	ground := height_at(w, s.pos.x, s.pos.y)
	hag := s.alt - ground

	// Turning: in the air quick when hovering, wider at speed; on the wheels by the speed and the steering lock.
	vh := s.vel.xy
	speed := linalg.length(vh)
	if s.driving {
		v := linalg.dot(vh, fwd)
		steer := c.turn * DRIVE_STEER * (1 - 0.75 * clamp(abs(v) / ROAD_MAX_SPEED, 0, 1))
		limit := DRIVE_LAT_ACCEL / max(abs(v), 1)
		// Keep a minimum pivot speed so A/D turns out of a wall at 0 km/h.
		turn_v := v < -0.5 ? v : max(v, 1.5)
		target := clamp(turn_v * math.tan(steer) / DRIVE_WHEELBASE_M, -limit, limit)
		s.turn_rate += (target - s.turn_rate) * min(dt / DRIVE_STEER_SMOOTH_S, 1)
	} else {
		max_turn :=
			FREE_TURN_SLOW + (FREE_TURN_FAST - FREE_TURN_SLOW) * clamp(speed / w.tune.max_speed, 0, 1)
		s.turn_rate += (c.turn * max_turn - s.turn_rate) * min(dt / FREE_TURN_SMOOTH_S, 1)
	}
	s.heading = math.mod(s.heading + s.turn_rate * dt + math.TAU, math.TAU)
	fwd = {math.sin(s.heading), -math.cos(s.heading)}
	right := [2]f32{-fwd.y, fwd.x}

	// Wind at the car: the layer nearest its altitude, weaker near the ground, plus turbulence from the gust index.
	layers := LAYER_ALT
	layer := clamp(int(math.round((s.alt - layers[0]) / (layers[1] - layers[0]))), 0, WIND_LAYERS - 1)
	wind := wind_at(w, s.pos.x, s.pos.y, layer, hour) * clamp(hag / FREE_GROUND_WIND_M, 0.25, 1)
	gust := gust_at(w, s.pos.x, s.pos.y, layer, hour)
	t := f32(w.tick % (60 * 3600)) * SIM_DT
	turb := [3]f32 {
		math.sin(t * 1.3) + 0.6 * math.sin(t * 3.1 + 1.7),
		math.sin(t * 1.1 + 2.3) + 0.6 * math.sin(t * 2.7 + 0.4),
		0.5 * math.sin(t * 1.9 + 4.1),
	}
	turb *= gust * FREE_GUST_ACCEL / 1.6

	// Forces along and across the heading, from the speed through the air.
	air := vh - wind
	along := linalg.dot(air, fwd)
	across := linalg.dot(air, right)
	thrust: f32
	if c.throttle > 0 {
		thrust = c.throttle * w.tune.free_accel
	} else if c.throttle < 0 {
		// Brake while moving forward, then reverse slowly.
		thrust =
			along > 0.5 ? c.throttle * FREE_BRAKE : (along > -FREE_REVERSE_MS ? c.throttle * w.tune.free_accel * 0.4 : 0)
	}
	// Quadratic air drag (per m), so full thrust ends at the top speed.
	drag := w.tune.free_accel / (w.tune.max_speed * w.tune.max_speed)
	a_along := thrust - drag * along * abs(along)
	a_across := -FREE_GRIP * across - drag * across * abs(across)
	acc := fwd * a_along + right * a_across + turb.xy
	acc_z := c.climb * FREE_CLIMB_ACCEL - FREE_VZ_DAMP * s.vel.z + turb.z
	// In a traffic jam the car is held back like the router expects (traffic_factor).
	jam := ship_jam_factor(w)
	if s.driving {
		// The wheels: speed along the heading by throttle, brake and losses, the sideways part dies out.
		v := linalg.dot(s.vel.xy, fwd)
		side := linalg.dot(s.vel.xy, right)
		drive: f32
		if c.throttle > 0 {
			drive = c.throttle * DRIVE_ACCEL
		} else if c.throttle < 0 {
			drive =
				v > 0.3 ? c.throttle * DRIVE_BRAKE : (v > -DRIVE_REVERSE_MS ? c.throttle * DRIVE_ACCEL * 0.5 : 0)
		}
		v += (drive - DRIVE_ROLL * v - DRIVE_AIR * v * abs(v)) * dt
		if c.throttle == 0 && abs(v) < 0.3 do v = 0
		side *= max(1 - DRIVE_GRIP * dt, 0)
		s.vel = {fwd.x * v + right.x * side, fwd.y * v + right.y * side, 0}
	} else {
		s.vel.xy += acc * dt
		s.vel.z += acc_z * dt
	}
	if jam > 1 do s.vel.xy *= 1 - min(dt * (jam - 1), 1)

	// Move. pos is f32 km (~1.5 cm steps at 150 km): the rest goes into pos_frac and is added on in f64.
	prev := s.pos
	{
		frac := s.pos_frac + s.vel.xy * dt
		x := f64(s.pos.x) + f64(frac.x) / 1000
		y := f64(s.pos.y) + f64(frac.y) / 1000
		s.pos = {f32(x), f32(y)}
		s.pos_frac = {f32((x - f64(s.pos.x)) * 1000), f32((y - f64(s.pos.y)) * 1000)}
	}
	s.alt += s.vel.z * dt

	// Walls: out of every footprint the car overlaps, the speed into the wall is lost.
	ground = height_at(w, s.pos.x, s.pos.y)
	hag = s.alt - ground
	push, roof := collide_car(w, s.pos, hag, FREE_RADIUS_M)
	if push != {} {
		x := f64(s.pos.x) + (f64(s.pos_frac.x) + f64(push.x)) / 1000
		y := f64(s.pos.y) + (f64(s.pos_frac.y) + f64(push.y)) / 1000
		s.pos = {f32(x), f32(y)}
		s.pos_frac = {f32((x - f64(s.pos.x)) * 1000), f32((y - f64(s.pos.y)) * 1000)}
		n := linalg.normalize(push)
		into := linalg.dot(s.vel.xy, n)
		if into < 0 {
			tangent := s.vel.xy - n * into
			s.vel.xy = tangent * (1 - (1 - FREE_WALL_KEEP) * clamp(-into / 20, 0, 1))
			if -into > 3 do s.hit_s = 0
		}
	}

	// Ground and roofs carry the car: flying down onto them lands it, driving it follows them, off a roof edge it
	// flies on. The ceiling stops it.
	floor := ground + max(roof, 0)
	if s.driving {
		if s.alt - floor > DRIVE_DROP_M {
			s.driving = false
		} else {
			s.alt = floor
			s.vel.z = 0
		}
	} else if s.alt <= floor + 0.02 {
		s.alt = floor
		s.driving = s.vel.z <= 0.5
		s.vel.z = max(s.vel.z, 0)
	}
	if s.alt > SHIP_CEILING {
		s.alt = SHIP_CEILING
		s.vel.z = min(s.vel.z, 0)
	}
	clamped := ship_clamp_belgium(w, s.pos, prev)
	if clamped.x != s.pos.x {
		s.pos.x, s.pos_frac.x, s.vel.x = clamped.x, 0, 0
	}
	if clamped.y != s.pos.y {
		s.pos.y, s.pos_frac.y, s.vel.y = clamped.y, 0, 0
	}
	edge_lo := [2]f32{SHIP_EDGE_KM, SHIP_EDGE_KM}
	edge_hi := [2]f32{MAP_W_KM, MAP_H_KM} - SHIP_EDGE_KM
	if s.pos != linalg.clamp(s.pos, edge_lo, edge_hi) {
		s.pos = linalg.clamp(s.pos, edge_lo, edge_hi)
		s.pos_frac = {}
		s.vel.xy = {}
	}
	s.speed = linalg.length(s.vel.xy)

	// Energy as ship_step: power at the air speed and the climbing power, solar from the cloud cover.
	airspeed := linalg.length(s.vel.xy - wind)
	s.used_kwh +=
		(power_kw(min(airspeed, SHIP_POWER_CAP_MS), gust) + max(s.vel.z, 0) * SHIP_CLIMB_KW_PER_MS) *
		dt /
		3600
	s.solar_kwh += solar_kw(cloud_at(w, s.pos.x, s.pos.y, hour), sun_factor(w, hour)) * dt / 3600

	s.warnings = {}
	for z in w.no_fly {
		if z.radius > 0 && s.alt < z.ceiling && linalg.length(s.pos - z.center) < z.radius {
			s.warnings += {.No_Fly}
		}
	}
	if jam > 1 do s.warnings += {.Jam}
}
