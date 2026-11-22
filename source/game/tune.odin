package game

import "core:fmt"
import rl "vendor:raylib"

// Speed editor (nasr, 2026-11-22): F2 opens sliders for the car's speed while the game runs. The ship reads
// w.tune instead of the constants; the defaults are those constants, so without touching a slider nothing
// changes. Reset puts every value back, nothing is saved: a restart is the default again. Changing a value
// during a recorded run makes its replay differ.
Tune :: struct {
	max_speed:   f32, // m/s, flying top speed (map and street view)
	hand_accel:  f32, // m/s^2, flying by hand on the map
	hand_brake:  f32, // m/s^2
	hand_turn:   f32, // rad/s, flying by hand on the map
	free_accel:  f32, // m/s^2, thrust in the street view
	cruise_rate: f32, // held throttle per second while W / S is down
	open:        bool,
	drag:        int, // slider row + 1 being dragged, 0 = none
}

TUNE_W :: 340
TUNE_ROW_H :: 50

tune_defaults :: proc() -> Tune {
	return {
		max_speed = SHIP_MAX_SPEED,
		hand_accel = SHIP_HAND_ACCEL,
		hand_brake = SHIP_HAND_BRAKE,
		hand_turn = SHIP_MAX_TURN_RATE,
		free_accel = FREE_ACCEL,
		cruise_rate = CRUISE_RATE,
	}
}

tune_reset :: proc(w: ^World) {
	open := w.tune.open
	w.tune = tune_defaults()
	w.tune.open = open
}

tune_ui :: proc(w: ^World) {
	t := &w.tune
	if key_pressed(w, .F2) do t.open = !t.open
	if !t.open do return
	pal := palette(w)
	def := tune_defaults()
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
		{"Throttle build-up", &t.cruise_rate, def.cruise_rate, 0.05, 2, "/s", false},
	}

	sw := f32(rl.GetScreenWidth())
	panel := rl.Rectangle{sw - 16 - TUNE_W - 80, 80, TUNE_W, 56 + len(rows) * TUNE_ROW_H + 60}
	ui_card(w, panel)
	ui_block(w, panel)
	x := panel.x + 16
	ui_text(w, {x, panel.y + 16}, "Speed editor", .Figtree_600, 16, pal.text)
	ui_text(w, {panel.x + panel.width - 16 - 22, panel.y + 18}, "F2", .Mono_400, 12, pal.text_2)

	if !rl.IsMouseButtonDown(.LEFT) do t.drag = 0
	buf: [32]u8
	y := panel.y + 56
	for row, i in rows {
		changed := abs(row.value^ - row.def) > 1e-4
		ui_text(w, {x, y}, row.label, .Roboto_400, 13, pal.text)
		text :=
			row.kmh ? fmt.bprintf(buf[:], "%.0f km/h", row.value^ * 3.6) : fmt.bprintf(buf[:], "%.2f %s", row.value^, row.unit)
		size := ui_text_size(w, text, .Mono_400, 13)
		ui_text(
			w,
			{panel.x + panel.width - 16 - size.x, y},
			text,
			.Mono_400,
			13,
			changed ? pal.accent : pal.text_2,
		)

		track := rl.Rectangle{x, y + 26, panel.width - 32, 4}
		_, _, fired := ui_widget(w, {track.x, track.y - 8, track.width, 20})
		if fired do t.drag = i + 1
		if t.drag == i + 1 {
			k := clamp((rl.GetMousePosition().x - track.x) / track.width, 0, 1)
			row.value^ = row.lo + k * (row.hi - row.lo)
		}
		k := clamp((row.value^ - row.lo) / (row.hi - row.lo), 0, 1)
		kd := clamp((row.def - row.lo) / (row.hi - row.lo), 0, 1)
		round_rect(track, 2, pal.surface_3)
		round_rect({track.x, track.y, track.width * k, track.height}, 2, pal.accent)
		// The default: a small mark on the track.
		rl.DrawRectangleV({track.x + track.width * kd - 1, track.y - 4}, {2, 12}, pal.text_2)
		rl.DrawCircleV({track.x + track.width * k, track.y + 2}, 8, changed ? pal.accent : pal.surface)
		rl.DrawCircleLinesV({track.x + track.width * k, track.y + 2}, 8, pal.line)
		y += TUNE_ROW_H
	}

	if ui_pill_button(w, {x, y + 8, panel.width - 32, 40}, "Reset to defaults", .Secondary) {
		tune_reset(w)
		ui_toast(w, "Speeds back to the defaults")
	}
}
