// author: dario
package game

import "core:strings"
import rl "vendor:raylib"

STICK_DEADZONE :: 0.15

// The first gamepad (Lars, 2026-11-21: "controller mode werkt niet"), GTA style: R2 throttle, L2 brake and
// reverse, left stick steers (and drives with up / down), R1 / L1 climb and sink, right stick looks around in the
// street view (climbs on the map), D-pad up / down zoom (the map into the street view and back), Options back
// to the map. A trigger rests at -1 or at 0
// depending on the controller's mapping: until it has been seen below -0.5 only its upper half counts, so a
// resting trigger never drives. Connecting and disconnecting are logged with the name, so the log shows
// whether raylib knows the controller at all (without a mapping every axis stays 0).
Pad :: struct {
	connected:  bool,
	full_range: [2]bool, // left, right trigger seen at the bottom of -1..1
}

pad_trigger :: proc(w: ^World, axis: rl.GamepadAxis, k: int) -> f32 {
	v := rl.GetGamepadAxisMovement(0, axis)
	if v < -0.5 do w.pad.full_range[k] = true
	return w.pad.full_range[k] ? clamp((v + 1) / 2, 0, 1) : clamp(v, 0, 1)
}

// Once per frame before the controls are read: notices the gamepad coming and going.
pad_poll :: proc(w: ^World) {
	on := !w.script.on && rl.IsGamepadAvailable(0)
	if on == w.pad.connected do return
	w.pad = {
		connected = on,
	}
	if on {
		name := strings.clone_from_cstring(rl.GetGamepadName(0), context.temp_allocator)
		logf(w, "input", "gamepad 0 connected: %q, %d axes", name, rl.GetGamepadAxisCount(0))
	} else {
		logf(w, "input", "gamepad 0 disconnected")
	}
}

pad_pressed :: proc(w: ^World, b: rl.GamepadButton) -> bool {
	return w.pad.connected && rl.IsGamepadButtonPressed(0, b)
}

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

	if w.pad.connected {
		c.throttle -= stick_axis(rl.GetGamepadAxisMovement(0, .LEFT_Y))
		c.throttle += pad_trigger(w, .RIGHT_TRIGGER, 1) - pad_trigger(w, .LEFT_TRIGGER, 0)
		c.turn += stick_axis(rl.GetGamepadAxisMovement(0, .LEFT_X))
		if rl.IsGamepadButtonDown(0, .RIGHT_TRIGGER_1) do c.climb += 1
		if rl.IsGamepadButtonDown(0, .LEFT_TRIGGER_1) do c.climb -= 1
		if !w.street.on do c.climb -= stick_axis(rl.GetGamepadAxisMovement(0, .RIGHT_Y))
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

// D-pad up / down: one zoom step in / out this frame, like a wheel notch.
pad_zoom :: proc(w: ^World) -> f32 {
	return f32(int(pad_pressed(w, .LEFT_FACE_UP))) - f32(int(pad_pressed(w, .LEFT_FACE_DOWN)))
}

mouse_wheel :: proc(w: ^World) -> f32 {
	if w.script.on do return w.script.wheel
	return rl.GetMouseWheelMove()
}
