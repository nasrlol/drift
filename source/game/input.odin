// author: dario
package game

import rl "vendor:raylib"

STICK_DEADZONE :: 0.15

// Keyboard and the first gamepad add up, so either can be used at any time. Turn is positive to the right,
// stick Y is negative when pushed up, so throttle and climb flip it. In the street view Space and Shift climb
// and sink too (on the map Space fires the focused button).
read_controls :: proc(w: ^World) -> Controls {
	c: Controls
	if w.street.on {
		if key_down(w, .SPACE) do c.climb += 1
		if key_down(w, .LEFT_SHIFT) || key_down(w, .LEFT_CONTROL) do c.climb -= 1
	}
	if key_down(w, .W) || key_down(w, .UP) do c.throttle += 1
	if key_down(w, .S) || key_down(w, .DOWN) do c.throttle -= 1
	if key_down(w, .D) || key_down(w, .RIGHT) do c.turn += 1
	if key_down(w, .A) || key_down(w, .LEFT) do c.turn -= 1
	if key_down(w, .R) || key_down(w, .PAGE_UP) do c.climb += 1
	if key_down(w, .F) || key_down(w, .PAGE_DOWN) do c.climb -= 1

	if !w.script.on && rl.IsGamepadAvailable(0) {
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

// The game's keys and the street view's mouse look go through these, so a scripted run (debug.odin) drives them
// frame by frame and real keys or mouse moves cannot change its screenshots.
key_down :: proc(w: ^World, k: rl.KeyboardKey) -> bool {
	if w.script.on do return w.script.down[k]
	return rl.IsKeyDown(k)
}

key_pressed :: proc(w: ^World, k: rl.KeyboardKey) -> bool {
	if w.script.on do return w.script.down[k] && !w.script.was[k]
	return rl.IsKeyPressed(k)
}

mouse_delta :: proc(w: ^World) -> [2]f32 {
	if w.script.on do return w.script.mouse
	return rl.GetMouseDelta()
}

mouse_wheel :: proc(w: ^World) -> f32 {
	if w.script.on do return w.script.wheel
	return rl.GetMouseWheelMove()
}
