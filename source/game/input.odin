// author: dario
package game

import rl "vendor:raylib"

STICK_DEADZONE :: 0.15

// Keyboard and the first gamepad add up, so either can be used at any time. Turn is positive to the right,
// stick Y is negative when pushed up, so throttle and climb flip it. In the street view Space and Shift climb
// and sink too (on the map Space fires the focused button).
read_controls :: proc(street: bool) -> Controls {
	c: Controls
	if street {
		if rl.IsKeyDown(.SPACE) do c.climb += 1
		if rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.LEFT_CONTROL) do c.climb -= 1
	}
	if rl.IsKeyDown(.W) || rl.IsKeyDown(.UP) do c.throttle += 1
	if rl.IsKeyDown(.S) || rl.IsKeyDown(.DOWN) do c.throttle -= 1
	if rl.IsKeyDown(.D) || rl.IsKeyDown(.RIGHT) do c.turn += 1
	if rl.IsKeyDown(.A) || rl.IsKeyDown(.LEFT) do c.turn -= 1
	if rl.IsKeyDown(.R) || rl.IsKeyDown(.PAGE_UP) do c.climb += 1
	if rl.IsKeyDown(.F) || rl.IsKeyDown(.PAGE_DOWN) do c.climb -= 1

	if rl.IsGamepadAvailable(0) {
		c.throttle -= stick_axis(rl.GetGamepadAxisMovement(0, .LEFT_Y))
		c.turn += stick_axis(rl.GetGamepadAxisMovement(0, .LEFT_X))
		c.climb -= stick_axis(rl.GetGamepadAxisMovement(0, .RIGHT_Y))
	}

	c.throttle = clamp(c.throttle, -1, 1)
	c.turn = clamp(c.turn, -1, 1)
	c.climb = clamp(c.climb, -1, 1)
	return c
}

// Inside the deadzone is 0, outside it is rescaled so the output still reaches 1.
stick_axis :: proc(v: f32) -> f32 {
	a := abs(v)
	if a < STICK_DEADZONE do return 0
	return clamp(a - STICK_DEADZONE, 0, 1 - STICK_DEADZONE) / (1 - STICK_DEADZONE) * (v < 0 ? -1 : 1)
}
