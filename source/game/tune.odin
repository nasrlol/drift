package game

import "core:fmt"

// Speed settings (nasr, 2026-11-22): the Speed tab of the settings panel (settings.odin) has sliders for the
// car's speed while the game runs. The ship reads w.tune instead of the constants; the defaults are those
// constants, so without touching a slider nothing changes. Nothing is saved: a restart is the default again.
// Changing a value during a recorded run makes its replay differ.
Tune :: struct {
	max_speed:   f32, // m/s, flying top speed (map and street view)
	hand_accel:  f32, // m/s^2, flying by hand on the map
	hand_brake:  f32, // m/s^2
	hand_turn:   f32, // rad/s, flying by hand on the map
	free_accel:  f32, // m/s^2, thrust in the street view
	drive_steer: f32, // times the steering on the wheels in the street view (DRIVE_STEER, DRIVE_LAT_ACCEL, DRIVE_GRIP)
	cruise_rate: f32, // held throttle per second while W / S is down
	map_time:    f32, // times real time while driving on the map (map_time_scale)
}

// On the map at real speed the car crept across Belgium (nasr, 2026-11-22: "it feels really slow and
// sluggish"). So while driving on the map the whole simulation runs this many times faster than real time: the
// car covers more ground per second at the same speed, and the wind, the battery, the arrival times and the
// clock stay consistent with it (the clock runs faster too). The street view stays real time.
MAP_TIME_SCALE :: 4.0
MAP_TIME_MAX :: 10.0
MAP_TIME_EASE_S :: 0.5 // real seconds to go between real time and map time, so the street switch never jerks

// How many times faster than real time the simulation runs this frame: tune.map_time in navigation on the map,
// real time on the plan screen and in the street view, eased over MAP_TIME_EASE_S. Once a frame.
map_time_scale :: proc(w: ^World, frame_dt: f32) -> f32 {
	target: f32 = w.screen == .Navigate && !w.street.on ? w.tune.map_time : 1
	if w.map_time_now == 0 do w.map_time_now = 1
	w.map_time_now += (target - w.map_time_now) * min(frame_dt / MAP_TIME_EASE_S, 1)
	return w.map_time_now
}

tune_defaults :: proc() -> Tune {
	return {
		max_speed = SHIP_MAX_SPEED,
		hand_accel = SHIP_HAND_ACCEL,
		hand_brake = SHIP_HAND_BRAKE,
		hand_turn = SHIP_MAX_TURN_RATE,
		free_accel = FREE_ACCEL,
		drive_steer = 1,
		cruise_rate = CRUISE_RATE,
		map_time = MAP_TIME_SCALE,
	}
}

// The Speed tab from y down, width wide; returns the y under it.
tune_tab :: proc(w: ^World, x, y, width: f32, drag: ^int) -> f32 {
	t := &w.tune
	def := w.setting_defaults.tune
	Row :: struct {
		label:  string,
		value:  ^f32,
		def:    f32,
		lo, hi: f32,
		unit:   string,
		kmh:    bool,
	}
	rows := [?]Row {
		{"Top speed", &t.max_speed, def.max_speed, 20, 300, "", true},
		{"Acceleration (map)", &t.hand_accel, def.hand_accel, 1, 40, "m/s2", false},
		{"Brake (map)", &t.hand_brake, def.hand_brake, 1, 50, "m/s2", false},
		{"Turn rate (map)", &t.hand_turn, def.hand_turn, 0.1, 2.5, "rad/s", false},
		{"Thrust (street view)", &t.free_accel, def.free_accel, 1, 40, "m/s2", false},
		{"Steering (driving)", &t.drive_steer, def.drive_steer, 0.3, 3, "x", false},
		{"Throttle build-up", &t.cruise_rate, def.cruise_rate, 0.05, 2, "/s", false},
		{"Time on the map", &t.map_time, def.map_time, 1, MAP_TIME_MAX, "x", false},
	}
	buf: [32]u8
	y := y
	for row, i in rows {
		text :=
			row.kmh ? fmt.bprintf(buf[:], "%.0f km/h", row.value^ * 3.6) : fmt.bprintf(buf[:], "%.2f %s", row.value^, row.unit)
		ui_slider_row(w, x, y, width, row.label, text, row.value, row.lo, row.hi, row.def, drag, i + 1)
		y += UI_SLIDER_ROW_H
	}
	return y
}
