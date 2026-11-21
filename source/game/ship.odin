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
// speed is m/s along the heading.
Ship :: struct {
	pos:     [2]f32,
	alt:     f32,
	heading: f32,
	speed:   f32,
}

SHIP_MAX_SPEED :: 35.0
SHIP_TURN_RATE :: 0.6
SHIP_CLIMB_RATE :: 5.0

ship_step :: proc(s: ^Ship, c: Controls, dt: f32) {
	s.heading = math.mod(s.heading + c.turn * SHIP_TURN_RATE * dt, math.TAU)
	s.speed = max(c.throttle, 0) * SHIP_MAX_SPEED
	s.alt += c.climb * SHIP_CLIMB_RATE * dt
	km := s.speed * dt / 1000
	s.pos.x += math.sin(s.heading) * km
	s.pos.y -= math.cos(s.heading) * km
}
