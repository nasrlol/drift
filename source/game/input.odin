// author: dario
package game

import rl "vendor:raylib"

STICK_DEADZONE :: 0.15

// Keyboard and the first gamepad add up, so either can be used at any time. Turn is positive to the right,
// stick Y is negative when pushed up, so throttle flips it. The right stick pans the camera, so climb is on the bumpers.
read_controls :: proc() -> Controls {
	c: Controls
	if rl.IsKeyDown(.W) do c.throttle += 1
	if rl.IsKeyDown(.S) do c.throttle -= 1
	if rl.IsKeyDown(.D) do c.turn += 1
	if rl.IsKeyDown(.A) do c.turn -= 1
	if rl.IsKeyDown(.R) do c.climb += 1
	if rl.IsKeyDown(.F) do c.climb -= 1

	if rl.IsGamepadAvailable(0) {
		c.throttle -= stick_axis(rl.GetGamepadAxisMovement(0, .LEFT_Y))
		c.turn += stick_axis(rl.GetGamepadAxisMovement(0, .LEFT_X))
		if rl.IsGamepadButtonDown(0, .RIGHT_TRIGGER_1) do c.climb += 1
		if rl.IsGamepadButtonDown(0, .LEFT_TRIGGER_1) do c.climb -= 1
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
