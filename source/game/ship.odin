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
}

// Battery charge in kWh, BATTERY_START x BATTERY_KWH at the start, clamped to the capacity.
ship_battery_kwh :: proc(s: ^Ship) -> f32 {
	return clamp(BATTERY_START * BATTERY_KWH - s.used_kwh + s.solar_kwh, 0, BATTERY_KWH)
}

// Flying is fast (Lars, 2026-11-21: "ik moet sneller kunnen vliegen en opstijgen"): 70 m/s is 252 km/h, the
// same car as before reached 126 km/h. On the road it keeps the old limits (road_speed). Our values.
SHIP_MAX_SPEED :: 70.0
SHIP_ACCEL :: 5.0
SHIP_BRAKE :: 6.0
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
	// On the road (or landing on it) only the jam warning applies; in the air the warnings are rebuilt below.
	if s.on_road || s.landing do s.warnings = ship_jam_factor(w) > 1 ? {.Jam} : {}
	if s.landing && road_landing_step(w, c, dt) do return
	if s.on_road && road_step(w, c, dt) do return

	target_turn := c.turn * SHIP_MAX_TURN_RATE
	s.turn_rate += (target_turn - s.turn_rate) * min(dt / SHIP_TURN_SMOOTH_S, 1)
	s.heading = math.mod(s.heading + s.turn_rate * dt, math.TAU)

	// In a traffic jam the ship slows down like the router expects (traffic_factor).
	target_speed := max(c.throttle, 0) * SHIP_MAX_SPEED / ship_jam_factor(w)
	if target_speed > s.speed {
		s.speed = min(s.speed + SHIP_ACCEL * dt, target_speed)
	} else {
		s.speed = max(s.speed - SHIP_BRAKE * dt, target_speed)
	}

	// The wind layer nearest to the ship's altitude, the forecast hour from the simulated time.
	layers := LAYER_ALT
	layer := clamp(int(math.round((s.alt - layers[0]) / (layers[1] - layers[0]))), 0, WIND_LAYERS - 1)
	wind := wind_at(w, s.pos.x, s.pos.y, layer, hour)
	air := [2]f32{math.sin(s.heading) * s.speed, -math.cos(s.heading) * s.speed}
	s.pos += (air + wind) * dt / 1000
	// The ship never leaves the map (Lars, 2026-11-21): it slides along the edge, wind included.
	s.pos = linalg.clamp(
		s.pos,
		[2]f32{SHIP_EDGE_KM, SHIP_EDGE_KM},
		[2]f32{MAP_W_KM, MAP_H_KM} - SHIP_EDGE_KM,
	)

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
	s.solar_kwh += solar_kw(cloud_at(w, s.pos.x, s.pos.y, hour)) * dt / 3600

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

// How much the other cars around the ship slow it down: 1 when the way is free (see traffic_factor).
ship_jam_factor :: proc(w: ^World) -> f32 {
	if w.other_count == 0 do return 1
	s := &w.ship
	return traffic_factor(u8(min(traffic_near(w, s.pos, s.alt, s.on_road, TRAFFIC_RADIUS_KM), 255)))
}
