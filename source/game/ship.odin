// author: dario
package game

import "core:math"

// All axes are -1..1, zero is neutral. Input code fills it, ship_step reads it.
Controls :: struct {
	throttle: f32,
	turn:     f32,
	climb:    f32,
}

// pos is km in map space (y down), alt is m, heading is radians clockwise from north (up on the map),
// speed is m/s along the heading, turn_rate is rad/s.
Ship :: struct {
	pos:       [2]f32,
	alt:       f32,
	heading:   f32,
	speed:     f32,
	turn_rate: f32,
}

SHIP_MAX_SPEED :: 35.0
SHIP_ACCEL :: 1.2
SHIP_BRAKE :: 1.6
SHIP_MAX_TURN_RATE :: 0.6
SHIP_TURN_SMOOTH_S :: 0.5
SHIP_CLIMB_RATE :: 5.0
SHIP_CEILING :: 900.0
SHIP_MIN_CLEARANCE :: 28.0

// Runs once per fixed step on w.ship. Reads only the ship, the controls and the terrain.
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

	km := s.speed * dt / 1000
	s.pos.x += math.sin(s.heading) * km
	s.pos.y -= math.cos(s.heading) * km

	s.alt += c.climb * SHIP_CLIMB_RATE * dt
	floor := height_at(w, s.pos.x, s.pos.y) + SHIP_MIN_CLEARANCE
	s.alt = min(max(s.alt, floor), SHIP_CEILING)
}
