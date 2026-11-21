// author: nasr
package game

import rl "vendor:raylib"

// Immediate mode: a widget is a proc call that draws itself and returns what happened this frame. Nothing is
// kept between frames, there is no widget tree; the caller passes the rect and keeps the state it changes.
UI_BUTTON_W :: 44
UI_BUTTON_H :: 22
UI_FONT_PX :: 10
UI_GAP :: 2 // between the buttons of one group
UI_GROUP_GAP :: 8
UI_PAD :: 4

// Map / Drive, 4 sim speeds, Day / Night.
TOOLBAR_W :: 2 * UI_PAD + 8 * UI_BUTTON_W + 5 * UI_GAP + 2 * UI_GROUP_GAP
TOOLBAR_H :: 2 * UI_PAD + UI_BUTTON_H
#assert(len(SIM_SPEEDS) == 4 && len(Theme) == 2)

// Returns true on the frame the button is clicked. on: the state the button stands for is the current one.
ui_button :: proc(r: rl.Rectangle, text: cstring, on: bool, pal: ^Palette) -> bool {
	hot := rl.CheckCollisionPointRec(rl.GetMousePosition(), r)
	rl.DrawRectangleRec(r, on ? pal.button_on : hot ? pal.button_hot : pal.button)
	tw := f32(rl.MeasureText(text, UI_FONT_PX))
	rl.DrawText(
		text,
		i32(r.x + (r.width - tw) / 2),
		i32(r.y + (r.height - UI_FONT_PX) / 2),
		UI_FONT_PX,
		pal.text,
	)
	return hot && rl.IsMouseButtonPressed(.LEFT)
}
