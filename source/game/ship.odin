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
}

SHIP_MAX_SPEED :: 35.0
SHIP_ACCEL :: 1.2
SHIP_BRAKE :: 1.6
SHIP_MAX_TURN_RATE :: 0.6
SHIP_TURN_SMOOTH_S :: 0.5
SHIP_CLIMB_RATE :: 5.0
SHIP_CEILING :: 900.0
SHIP_MIN_CLEARANCE :: 28.0
SHIP_TERRAIN_WARN_M :: 60.0
DOCK_HORIZONTAL_KM :: 0.030
DOCK_VERTICAL_M :: 25.0

// Runs once per fixed step on w.ship. Reads only the ship, the controls, the terrain and the weather.
ship_step :: proc(w: ^World, c: Controls, dt: f32) {
	s := &w.ship

	target_turn := c.turn * SHIP_MAX_TURN_RATE
	s.turn_rate += (target_turn - s.turn_rate) * min(dt / SHIP_TURN_SMOOTH_S, 1)
	s.heading = math.mod(s.heading + s.turn_rate * dt, math.TAU)

	target_speed := max(c.throttle, 0) * SHIP_MAX_SPEED
	if target_speed > s.speed {
		s.speed = min(s.speed + SHIP_ACCEL * dt, target_speed)
	} else {
		s.speed = max(s.speed - SHIP_BRAKE * dt, target_speed)
	}

	// The wind layer nearest to the ship's altitude, the forecast hour from the simulated time.
	layers := LAYER_ALT
	layer := clamp(int(math.round((s.alt - layers[0]) / (layers[1] - layers[0]))), 0, WIND_LAYERS - 1)
	hour := int(w.tick / (SIM_HZ * 3600))
	wind := wind_at(w, s.pos.x, s.pos.y, layer, hour)
	air := [2]f32{math.sin(s.heading) * s.speed, -math.cos(s.heading) * s.speed}
	s.pos += (air + wind) * dt / 1000

	s.alt += c.climb * SHIP_CLIMB_RATE * dt
	floor := height_at(w, s.pos.x, s.pos.y) + SHIP_MIN_CLEARANCE
	s.alt = min(max(s.alt, floor), SHIP_CEILING)

	s.warnings = {}
	if s.alt - (floor - SHIP_MIN_CLEARANCE) < SHIP_TERRAIN_WARN_M do s.warnings += {.Terrain}
	for z in w.no_fly {
		if z.radius > 0 && s.alt < z.ceiling && linalg.length(s.pos - z.center) < z.radius {
			s.warnings += {.No_Fly}
		}
	}

	s.docked = false
	for i in 0 ..< w.m.hub_count {
		hub := w.m.hubs[i].pos
		top := height_at(w, hub.x, hub.y) + HUB_TOWER_M
		if linalg.length(s.pos - hub) <= DOCK_HORIZONTAL_KM && abs(s.alt - top) <= DOCK_VERTICAL_M {
			s.docked = true
			s.dock_hub = i
			break
		}
	}
}
