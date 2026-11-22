// author: dario
package game

import "core:math"
import "core:strings"
import rl "vendor:raylib"

STICK_DEADZONE :: 0.15
TRIGGER_DEADZONE :: 0.05
MAX_GAMEPADS :: 4
PAD_ZOOM_HOLD_S :: 0.18
PAD_ZOOM_RATE :: 2.0

// The first available gamepad (GTA style): R2 analog gas, L2 brake and reverse, left stick steers (and pans
// on the plan screen), R1 / L1 climb and sink, right stick looks around in the street view (orbits/tilts on
// the map), R3 re-centres, D-pad up / down zoom (tap = step, hold = smooth), D-pad left / right cycle UI
// focus, Cross activates / toggles wind, Triangle toggles autopilot, Square reports gust, Circle / Options go
// back. A trigger rests at -1 or at 0 depending on the controller's mapping: until it has been seen below -0.5
// only its upper half counts, so a resting trigger never drives.
Pad :: struct {
	connected:  bool,
	index:      i32,
	full_range: [2]bool, // left, right trigger seen at the bottom of -1..1
	pedal:      bool, // true when triggers set throttle directly instead of keyboard cruise control
	zoom_hold:  f32, // seconds D-pad zoom has been held down
	zoom:       f32, // zoom step computed once per frame in pad_poll
}

pad_trigger :: proc(w: ^World, axis: rl.GamepadAxis, k: int) -> f32 {
	v := rl.GetGamepadAxisMovement(w.pad.index, axis)
	if v < -0.5 do w.pad.full_range[k] = true
	raw := w.pad.full_range[k] ? clamp((v + 1) / 2, 0, 1) : clamp(v, 0, 1)
	if raw < TRIGGER_DEADZONE do return 0
	return clamp((raw - TRIGGER_DEADZONE) / (1 - TRIGGER_DEADZONE), 0, 1)
}

// Once per frame before the controls are read: notices a gamepad coming and going.
pad_poll :: proc(w: ^World) {
	if w.script.on {
		if w.pad.connected {
			logf(w, "input", "gamepad %d disconnected", w.pad.index)
			w.pad = {}
		}
		return
	}
	if w.pad.connected && rl.IsGamepadAvailable(w.pad.index) {
		up := rl.IsGamepadButtonDown(w.pad.index, .LEFT_FACE_UP)
		down := rl.IsGamepadButtonDown(w.pad.index, .LEFT_FACE_DOWN)
		dir := f32(int(up)) - f32(int(down))
		if dir == 0 {
			w.pad.zoom_hold = 0
			w.pad.zoom = 0
		} else if rl.IsGamepadButtonPressed(w.pad.index, .LEFT_FACE_UP) ||
		   rl.IsGamepadButtonPressed(w.pad.index, .LEFT_FACE_DOWN) {
			w.pad.zoom_hold = 0
			w.pad.zoom = dir * WHEEL_ZOOM_STEP
		} else {
			w.pad.zoom_hold += frame_time(w)
			w.pad.zoom = w.pad.zoom_hold >= PAD_ZOOM_HOLD_S ? dir * PAD_ZOOM_RATE * frame_time(w) : 0
		}
		return
	}
	for i in i32(0) ..< MAX_GAMEPADS {
		if !rl.IsGamepadAvailable(i) do continue
		w.pad = {
			connected = true,
			index     = i,
		}
		name := strings.clone_from_cstring(rl.GetGamepadName(i), context.temp_allocator)
		logf(w, "input", "gamepad %d connected: %q, %d axes", i, name, rl.GetGamepadAxisCount(i))
		return
	}
	if w.pad.connected {
		logf(w, "input", "gamepad %d disconnected", w.pad.index)
		w.pad = {}
	}
}

pad_pressed :: proc(w: ^World, b: rl.GamepadButton) -> bool {
	return w.pad.connected && rl.IsGamepadButtonPressed(w.pad.index, b)
}

pad_down :: proc(w: ^World, b: rl.GamepadButton) -> bool {
	return w.pad.connected && rl.IsGamepadButtonDown(w.pad.index, b)
}

// Keyboard and gamepad add up, so either can be used at any time. Turn is positive to the right, stick Y is
// negative when pushed up. On the navigate screen R2/L2 act as an analog gas/brake pedal directly, while
// keyboard W/S keeps cruise control. In the street view Space and Shift climb and sink too.
read_controls :: proc(w: ^World) -> Controls {
	c: Controls
	if w.street.on {
		if key_down(w, .SPACE) do c.climb += 1
		if key_down(w, .LEFT_SHIFT) || key_down(w, .LEFT_CONTROL) do c.climb -= 1
	}
	kb_throttle: f32
	if key_down(w, .W) || key_down(w, .UP) do kb_throttle += 1
	if key_down(w, .S) || key_down(w, .DOWN) do kb_throttle -= 1
	c.throttle += kb_throttle
	if key_down(w, .D) || key_down(w, .RIGHT) do c.turn += 1
	if key_down(w, .A) || key_down(w, .LEFT) do c.turn -= 1
	if key_down(w, .R) || key_down(w, .PAGE_UP) do c.climb += 1
	if key_down(w, .F) || key_down(w, .PAGE_DOWN) do c.climb -= 1

	if w.pad.connected {
		ls := stick_2d(
			rl.GetGamepadAxisMovement(w.pad.index, .LEFT_X),
			rl.GetGamepadAxisMovement(w.pad.index, .LEFT_Y),
		)
		r2 := pad_trigger(w, .RIGHT_TRIGGER, 1)
		l2 := pad_trigger(w, .LEFT_TRIGGER, 0)
		c.turn += ls.x
		if w.screen == .Plan {
			c.throttle -= ls.y
		} else {
			if kb_throttle != 0 do w.pad.pedal = false
			if r2 > 0 || l2 > 0 do w.pad.pedal = true
			// In street-view air, quadratic drag makes steady speed sqrt(throttle); r2^1.5 keeps low-end thrust
			// responsive while giving smooth speed control across the whole trigger pull.
			gas := w.street.on && !w.ship.driving ? r2 * math.sqrt(r2) : r2
			c.throttle += gas - l2
		}
		if rl.IsGamepadButtonDown(w.pad.index, .RIGHT_TRIGGER_1) do c.climb += 1
		if rl.IsGamepadButtonDown(w.pad.index, .LEFT_TRIGGER_1) do c.climb -= 1
	}

	c.throttle = clamp(c.throttle, -1, 1)
	c.turn = clamp(c.turn, -1, 1)
	c.climb = clamp(c.climb, -1, 1)
	return c
}

// Radial deadzone: inside STICK_DEADZONE is zero, outside it rescales smoothly to radius 1.
stick_2d :: proc(x, y: f32) -> [2]f32 {
	v := [2]f32{x, y}
	len := math.sqrt(v.x * v.x + v.y * v.y)
	if len < STICK_DEADZONE do return {}
	scale := clamp((len - STICK_DEADZONE) / (1 - STICK_DEADZONE), 0, 1) / len
	return v * scale
}

pad_right_stick :: proc(w: ^World) -> [2]f32 {
	if !w.pad.connected do return {}
	return stick_2d(
		rl.GetGamepadAxisMovement(w.pad.index, .RIGHT_X),
		rl.GetGamepadAxisMovement(w.pad.index, .RIGHT_Y),
	)
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

// D-pad up / down: tap for one wheel notch, hold for smooth continuous zoom.
pad_zoom :: proc(w: ^World) -> f32 {
	if !w.pad.connected || w.ui.last_popup.width > 0 do return 0
	return w.pad.zoom
}

mouse_wheel :: proc(w: ^World) -> f32 {
	if w.script.on do return w.script.wheel
	return rl.GetMouseWheelMove()
}
