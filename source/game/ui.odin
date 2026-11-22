// author: nasr
package game

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:strings"
import rl "vendor:raylib"

// Fonts of the design ("Typografie"): Figtree for what is read at a glance, Roboto for running text, Roboto
// Mono for values that change live. Static TTFs, unchanged, licenses next to them in assets/fonts (sources and
// sha256 in notes.txt). Roboto Mono has no static SemiBold, so Mono_600 is the Bold file.
Font :: enum u8 {
	Figtree_500,
	Figtree_600,
	Figtree_700,
	Figtree_800,
	Figtree_Italic_400, // water names
	Roboto_400,
	Roboto_500,
	Roboto_700,
	Mono_400,
	Mono_600,
	Space_400,
	Space_500,
	Space_700,
	Lora_400,
	Lora_500,
	Lora_600,
	Lora_700,
	Lora_Italic_400,
	JetBrains_400,
	JetBrains_500,
	JetBrains_600,
	JetBrains_700,
	Icons, // Material Symbols Rounded, only the codepoints of Icon
}

// Embedded file of each font. A switch, not a table: the game package has no globals.
font_file :: proc(font: Font) -> []u8 {
	switch font {
	case .Figtree_500:
		return #load("../../assets/fonts/Figtree-Medium.ttf")
	case .Figtree_600:
		return #load("../../assets/fonts/Figtree-SemiBold.ttf")
	case .Figtree_700:
		return #load("../../assets/fonts/Figtree-Bold.ttf")
	case .Figtree_800:
		return #load("../../assets/fonts/Figtree-ExtraBold.ttf")
	case .Figtree_Italic_400:
		return #load("../../assets/fonts/Figtree-Italic.ttf")
	case .Roboto_400:
		return #load("../../assets/fonts/Roboto-Regular.ttf")
	case .Roboto_500:
		return #load("../../assets/fonts/Roboto-Medium.ttf")
	case .Roboto_700:
		return #load("../../assets/fonts/Roboto-Bold.ttf")
	case .Mono_400:
		return #load("../../assets/fonts/RobotoMono-Regular.ttf")
	case .Mono_600:
		return #load("../../assets/fonts/RobotoMono-Bold.ttf")
	case .Space_400:
		return #load("../../assets/fonts/SpaceGrotesk-Regular.ttf")
	case .Space_500:
		return #load("../../assets/fonts/SpaceGrotesk-Medium.ttf")
	case .Space_700:
		return #load("../../assets/fonts/SpaceGrotesk-Bold.ttf")
	case .Lora_400:
		return #load("../../assets/fonts/Lora-Regular.ttf")
	case .Lora_500:
		return #load("../../assets/fonts/Lora-Medium.ttf")
	case .Lora_600:
		return #load("../../assets/fonts/Lora-SemiBold.ttf")
	case .Lora_700:
		return #load("../../assets/fonts/Lora-Bold.ttf")
	case .Lora_Italic_400:
		return #load("../../assets/fonts/Lora-Italic.ttf")
	case .JetBrains_400:
		return #load("../../assets/fonts/JetBrainsMono-Regular.ttf")
	case .JetBrains_500:
		return #load("../../assets/fonts/JetBrainsMono-Medium.ttf")
	case .JetBrains_600:
		return #load("../../assets/fonts/JetBrainsMono-SemiBold.ttf")
	case .JetBrains_700:
		return #load("../../assets/fonts/JetBrainsMono-Bold.ttf")
	case .Icons:
		return #load("../../assets/fonts/MaterialSymbolsRounded-Filled.ttf")
	}
	return nil
}

// Codepoints 32..255: ASCII and Latin-1 (Liege with e grave, the copyright sign).
FONT_FIRST :: 32
FONT_COUNT :: 256 - FONT_FIRST
MAX_FONT_SLOTS :: 64 // (font, px) pairs; the design uses about 30

// Every (font, px) pair is rasterized the first time it is drawn, at exactly that size, so text stays pixel
// sharp. The atlases are raylib memory and GPU textures, they survive a hot reload. Never used in headless.
Font_Slot :: struct {
	font:   Font,
	px:     i32,
	loaded: rl.Font,
}

Fonts :: struct {
	slots: [MAX_FONT_SLOTS]Font_Slot,
	count: int,
}

font_get :: proc(w: ^World, asked: Font, px: f32) -> rl.Font {
	font := font_remap(w, asked)
	size := i32(px + 0.5)
	f := &w.fonts
	for &s in f.slots[:f.count] {
		if s.font == font && s.px == size do return s.loaded
	}
	if f.count == MAX_FONT_SLOTS {
		logf(w, "ui", "more than %d font sizes, %v %d px uses the raylib font", MAX_FONT_SLOTS, font, size)
		return rl.GetFontDefault()
	}
	prof_zone(w, .Font_Load)
	codepoints: [max(FONT_COUNT, len(Icon))]rune
	count := FONT_COUNT
	if font == .Icons {
		icons := ICON_CODEPOINTS
		count = 0
		for c in icons {
			if c == 0 do continue
			codepoints[count] = c
			count += 1
		}
	} else {
		for &c, i in codepoints[:FONT_COUNT] do c = rune(FONT_FIRST + i)
	}
	data := font_file(font)
	loaded := rl.LoadFontFromMemory(
		".ttf",
		raw_data(data),
		i32(len(data)),
		size,
		raw_data(codepoints[:]),
		i32(count),
	)
	if loaded.texture.id == 0 {
		logf(
			w,
			"ui",
			"cannot load %v (%d bytes embedded) at %d px, using the raylib font",
			font,
			len(data),
			size,
		)
		loaded = rl.GetFontDefault()
	}
	f.slots[f.count] = {font, size, loaded}
	f.count += 1
	return loaded
}

// Distance from the top of a ui_text line to the baseline, from the bottom of 'H' in the loaded atlas. Puts text of
// different sizes on one baseline.
ui_text_baseline :: proc(w: ^World, font: Font, design_px: f32) -> f32 {
	f := font_get(w, font, text_px(w, design_px))
	i := rl.GetGlyphIndex(f, 'H')
	return f32(f.glyphs[i].offsetY) + f.recs[i].height
}

// Unloads every atlas this game made, never raylib's own default font.
fonts_unload :: proc(w: ^World) {
	default := rl.GetFontDefault()
	for s in w.fonts.slots[:w.fonts.count] {
		if s.loaded.texture.id != default.texture.id do rl.UnloadFont(s.loaded)
	}
	w.fonts = {}
}

// pos is the top-left corner of the text. Strings are UTF-8, copied to the frame arena for raylib.
ui_text :: proc(w: ^World, pos: [2]f32, text: string, font: Font, design_px: f32, color: rl.Color) {
	prof_zone(w, .Ui_Text)
	px := text_px(w, design_px)
	rl.DrawTextEx(
		font_get(w, font, px),
		strings.clone_to_cstring(text, context.temp_allocator),
		pos,
		f32(i32(px + 0.5)),
		0,
		color,
	)
}

ui_text_size :: proc(w: ^World, text: string, font: Font, design_px: f32) -> [2]f32 {
	prof_zone(w, .Ui_Text)
	px := text_px(w, design_px)
	return rl.MeasureTextEx(
		font_get(w, font, px),
		strings.clone_to_cstring(text, context.temp_allocator),
		f32(i32(px + 0.5)),
		0,
	)
}

// Draws one line of text and returns the y position for the line below it.
ui_line :: proc(w: ^World, pos: [2]f32, text: string, font: Font, design_px: f32, color: rl.Color) -> f32 {
	ui_text(w, pos, text, font, design_px, color)
	return pos.y + text_line_px(w, design_px)
}


// Icons (design "Iconen"): Material Symbols Rounded, filled, weight 500 (static instance from Google Fonts with only
// the icons below, Apache 2.0, license next to it in assets/fonts, source and sha256 in notes.txt), plus the design's own icons that are
// drawn with shapes: the logo, the docking tower, the steering wheel and the muted speaker. Climb / descend use the trending arrows, the jet maneuver
// the wind icon.
Icon :: enum u8 {
	Leaf,
	Bolt,
	Waves,
	Swap,
	Clock,
	Layers,
	Compass,
	Plus,
	Minus,
	Navigate,
	Play,
	Wind,
	Search,
	Speaker,
	Warning,
	Reroute,
	Straight,
	Slight_Left,
	Slight_Right,
	Left,
	Right,
	Sharp_Left,
	Sharp_Right,
	Climb,
	Descend,
	Pin,
	Origin,
	Close,
	Expand,
	Check,
	Arrow_Up,
	Arrow_Down,
	Arrow_Left,
	Arrow_Right,
	// drawn with shapes, not in the font
	Tower,
	Logo,
	Steer,
	Speaker_Off,
	Recentre,
	Leave,
}

// Codepoints in the Google Fonts file; a few icons keep their older Material Icons codepoint there (schedule,
// location_on, warning), so these do not all match the variable font's codepoint list.
ICON_CODEPOINTS :: [Icon]rune {
	.Leaf         = 0xea35, // eco
	.Bolt         = 0xea0b,
	.Waves        = 0xe176,
	.Swap         = 0xe8d5, // swap_vert
	.Clock        = 0xe8b5, // schedule
	.Layers       = 0xe53b,
	.Compass      = 0xf1e0, // north
	.Plus         = 0xe145,
	.Minus        = 0xe15b,
	.Navigate     = 0xe55d, // navigation
	.Play         = 0xe037,
	.Wind         = 0xefd8, // air
	.Search       = 0xef7a,
	.Speaker      = 0xe050, // volume_up
	.Warning      = 0xe002,
	.Reroute      = 0xe863, // autorenew
	.Straight     = 0xeb95,
	.Slight_Left  = 0xeba4,
	.Slight_Right = 0xeb9a,
	.Left         = 0xeba6,
	.Right        = 0xebab,
	.Sharp_Left   = 0xeba7,
	.Sharp_Right  = 0xebaa,
	.Climb        = 0xe8e5, // trending_up
	.Descend      = 0xe8e3, // trending_down
	.Pin          = 0xe0c8, // location_on
	.Origin       = 0xe57b, // trip_origin
	.Close        = 0xe5cd,
	.Expand       = 0xe5cf, // expand_more
	.Check        = 0xe668,
	.Arrow_Up     = 0xe5d8,
	.Arrow_Down   = 0xe5db,
	.Arrow_Left   = 0xe5c4,
	.Arrow_Right  = 0xe5c8,
	.Tower        = 0,
	.Logo         = 0,
	.Steer        = 0,
	.Speaker_Off  = 0,
	.Recentre     = 0,
	.Leave        = 0,
}

// Fixed colors of the logo (design "Iconen"): they are part of the mark, not of the palette.
LOGO_MINT :: rl.Color{127, 227, 196, 255}
LOGO_GREEN :: rl.Color{52, 208, 122, 255}
LOGO_AMBER :: rl.Color{255, 179, 71, 255}

// The icon is a px square around centre. Single color (currentColor in the design), except the logo.
ui_icon :: proc(w: ^World, icon: Icon, centre: [2]f32, px: f32, color: rl.Color) {
	switch icon {
	case .Tower:
		// Lattice tower: a narrow trapezoid with a platform and a mooring mast on top.
		s := px / 24
		c := centre
		rl.DrawTriangle(c + {-6 * s, 9 * s}, c + {6 * s, 9 * s}, c + {2 * s, -4 * s}, color)
		rl.DrawTriangle(c + {-6 * s, 9 * s}, c + {2 * s, -4 * s}, c + {-2 * s, -4 * s}, color)
		rl.DrawRectangleV(c + {-6 * s, -6 * s}, {12 * s, 2.5 * s}, color)
		rl.DrawRectangleV(c + {-1 * s, -11 * s}, {2 * s, 5 * s}, color)
	case .Logo:
		// A mint ring (2.4 px at 30 px), two wavy wind lines in green and a small amber sun in the middle.
		r := px / 2
		rl.DrawRing(centre, r - 2.4 * px / 30, r, 0, 360, 48, LOGO_MINT)
		rl.DrawCircleV(centre, r * 0.22, LOGO_AMBER)
		for row in ([2]f32{-0.42, 0.42}) {
			prev: [2]f32
			for k in 0 ..= 12 {
				t := f32(k) / 12
				p := centre + {(t - 0.5) * r * 1.3, row * r + math.sin(t * math.TAU) * r * 0.1}
				if k > 0 do rl.DrawLineEx(prev, p, max(px / 15, 1.5), LOGO_GREEN)
				prev = p
			}
		}
	case .Steer:
		// Steering wheel: a rim, a hub and three spokes (left, right, down), on the 24 px icon grid.
		s := px / 24
		r := 10 * s
		spoke := 2.6 * s
		rl.DrawRing(centre, r - 2.6 * s, r, 0, 360, 48, color)
		rl.DrawCircleV(centre, 3.4 * s, color)
		rl.DrawLineEx(centre - {r - 1.3 * s, 0}, centre + {r - 1.3 * s, 0}, spoke, color)
		rl.DrawLineEx(centre, centre + {0, r - 1.3 * s}, spoke, color)
	case .Speaker_Off:
		// The speaker glyph with a slash from top left to bottom right, on the 24 px icon grid.
		s := px / 24
		ui_icon(w, .Speaker, centre, px, color)
		rl.DrawLineEx(centre + {-9 * s, -9 * s}, centre + {9 * s, 9 * s}, 2.4 * s, color)
	case .Recentre:
		// Target reticle: outer ring, cardinal crosshairs and centre dot on the 24 px icon grid.
		s := px / 24
		r := 6.8 * s
		sw := max(2.0 * s, 1.5)
		rl.DrawRing(centre, r - sw, r, 0, 360, 36, color)
		rl.DrawCircleV(centre, 2.5 * s, color)
		rl.DrawLineEx(centre + {0, -9.8 * s}, centre + {0, -5.8 * s}, sw, color)
		rl.DrawLineEx(centre + {0, 5.8 * s}, centre + {0, 9.8 * s}, sw, color)
		rl.DrawLineEx(centre + {-9.8 * s, 0}, centre + {-5.8 * s, 0}, sw, color)
		rl.DrawLineEx(centre + {5.8 * s, 0}, centre + {9.8 * s, 0}, sw, color)
	case .Leave:
		// Open doorway bracket and exit arrow pointing right, on the 24 px icon grid.
		s := px / 24
		sw := max(2.2 * s, 1.5)
		rl.DrawLineEx(centre + {-2 * s, -7.5 * s}, centre + {-7.5 * s, -7.5 * s}, sw, color)
		rl.DrawLineEx(centre + {-7.5 * s, -7.5 * s}, centre + {-7.5 * s, 7.5 * s}, sw, color)
		rl.DrawLineEx(centre + {-7.5 * s, 7.5 * s}, centre + {-2 * s, 7.5 * s}, sw, color)
		rl.DrawLineEx(centre + {-2 * s, 0}, centre + {8 * s, 0}, sw, color)
		rl.DrawLineEx(centre + {4 * s, -4 * s}, centre + {8 * s, 0}, sw, color)
		rl.DrawLineEx(centre + {4 * s, 4 * s}, centre + {8 * s, 0}, sw, color)
	case .Leaf ..= .Arrow_Right:
		codepoints := ICON_CODEPOINTS
		size := f32(i32(px + 0.5))
		font := font_get(w, .Icons, size)
		// raylib scales by line height (ascent + descent, 1152 units), the icon square is 960 units wide,
		// so the advance is narrower than size. The line is symmetric around the square, size / 2 centres y.
		half_w := f32(rl.GetGlyphInfo(font, codepoints[icon]).advanceX) / 2
		rl.DrawTextCodepoint(font, codepoints[icon], linalg.floor(centre - {half_w, size / 2}), size, color)
	}
}

// Immediate mode: a widget is a proc call that draws itself and returns what happened this frame. Nothing is
// kept between frames except what the design needs to remember (focus, toast, the toggle slide), in w.ui; the
// caller passes the rect and keeps the state it changes. Every widget is reachable with Tab and fires with
// Enter or Space when it has the focus (2 px focus ring in accent).
UI_MIN_HIT :: 44 // px, the design's smallest click target
UI_FOCUS_RING :: 2
TOAST_S :: 1.6
TOAST_FADE_S :: 0.25
MAX_UI_ANIMS :: 64
WINDOW_SNAP_PX :: 24
WINDOW_MARGIN :: 8
WINDOW_DRAG_PX :: 4 // movement before an empty-body press turns into a window drag

Window_Id :: enum u8 {
	None,
	Plan,
	Layers,
	Settings,
	Profiler,
	Nav_Banner,
	Nav_Sheet,
	Carpool_Nav,
}

Plan_Side :: enum u8 {
	Left, // zero = default left side
	Right,
}

Ui_Window :: struct {
	moved: bool, // false (zero) = docked at its default position
	pos:   [2]f32,
}

Pill_Kind :: enum u8 {
	Primary,
	Secondary,
	Danger,
}

Ui :: struct {
	next_id:        int, // widgets this frame, in draw order
	focus:          int, // 1-based id of the focused widget, 0 = none
	last_count:     int, // widgets in the previous frame, Tab wraps there
	activate:       bool, // Enter / Space / Cross pressed this frame
	cancelled:      bool, // Circle cleared the focus this frame, so it does not also exit the screen
	// Rectangles that hide the map from the mouse, collected while drawing and read by the camera next frame
	// (the camera runs before the UI is drawn).
	blocks:         [32]rl.Rectangle,
	block_count:    int,
	last_blocks:    [32]rl.Rectangle,
	last_count_b:   int,
	// An open popup (hub search list, departure list, hub menu) takes the clicks inside it.
	popup:          rl.Rectangle,
	last_popup:     rl.Rectangle,
	in_popup:       bool,
	toast:          [64]u8,
	toast_len:      int,
	toast_t:        f32, // seconds since the toast appeared
	tip_rect:       rl.Rectangle,
	tip_buf:        [256]u8,
	tip_len:        int,
	anims:          [MAX_UI_ANIMS]f32, // 0..1 per widget id: toggle knob position
	// Movable windows (zero = all at default snapped positions).
	wins:           [Window_Id]Ui_Window,
	plan_side:      Plan_Side,
	plan_drag_x:    f32,
	drag_win:       Window_Id,
	pending_win:    Window_Id,
	drag_offset:    [2]f32,
	drag_start:     [2]f32,
	win_widget_hit: bool,
	current_win:    Window_Id,
	win_rects:      [Window_Id]rl.Rectangle,
	win_order:      [len(Window_Id)]Window_Id,
	win_count:      int,
	last_win_rects: [Window_Id]rl.Rectangle,
	last_win_order: [len(Window_Id)]Window_Id,
	last_win_count: int,
	last_click_win: Window_Id,
	last_click_t:   f64,
}

// Start of the frame: Tab moves the focus over last frame's widgets, Enter / Space fires the focused one.
ui_begin :: proc(w: ^World) {
	u := &w.ui
	u.last_count = u.next_id
	u.next_id = 0
	u.last_blocks = u.blocks
	u.last_count_b = u.block_count
	u.block_count = 0
	u.last_popup = u.popup
	u.popup = {}
	u.last_win_rects = u.win_rects
	u.last_win_order = u.win_order
	u.last_win_count = u.win_count
	u.win_rects = {}
	u.win_order = {}
	u.win_count = 0
	u.current_win = .None
	u.win_widget_hit = false
	if !rl.IsMouseButtonDown(.LEFT) {
		u.pending_win = .None
		if !rl.IsMouseButtonReleased(.LEFT) do u.drag_win = .None
	}
	u.tip_len = 0
	u.cancelled = false
	tab := rl.IsKeyPressed(.TAB)
	back := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
	pad_next :=
		pad_pressed(w, .LEFT_FACE_RIGHT) || (u.last_popup.width > 0 && pad_pressed(w, .LEFT_FACE_DOWN))
	pad_prev := pad_pressed(w, .LEFT_FACE_LEFT) || (u.last_popup.width > 0 && pad_pressed(w, .LEFT_FACE_UP))
	if (tab || pad_next || pad_prev) && u.last_count > 0 {
		go_back := (tab && back) || pad_prev
		if u.focus == 0 {
			u.focus = go_back ? u.last_count : 1
		} else {
			u.focus =
				go_back ? (u.focus + u.last_count - 2) %% u.last_count + 1 : u.focus %% u.last_count + 1
		}
	}
	u.activate =
		u.focus > 0 &&
		(rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.SPACE) || pad_pressed(w, .RIGHT_FACE_DOWN))
	if u.focus > 0 && pad_pressed(w, .RIGHT_FACE_RIGHT) {
		u.focus = 0
		u.cancelled = true
	}
	if rl.IsMouseButtonPressed(.LEFT) do u.focus = 0
	u.toast_t += frame_time(w)
}

// True when a window drawn after win covered m in the previous frame.
ui_point_occluded :: proc(w: ^World, m: [2]f32, win: Window_Id) -> bool {
	u := &w.ui
	for i := u.last_win_count - 1; i >= 0; i -= 1 {
		id := u.last_win_order[i]
		if id == win do break
		if rl.CheckCollisionPointRec(m, u.last_win_rects[id]) do return true
	}
	return false
}

// True when the mouse is over UI drawn last frame: the map then ignores drags, the wheel and clicks.
ui_mouse_captured :: proc(w: ^World) -> bool {
	m := rl.GetMousePosition()
	u := &w.ui
	if u.drag_win != .None || u.pending_win != .None do return true
	if u.last_popup.width > 0 && rl.CheckCollisionPointRec(m, u.last_popup) do return true
	for r in u.last_blocks[:u.last_count_b] {
		if rl.CheckCollisionPointRec(m, r) do return true
	}
	return false
}

// A rect that hides the map from the mouse next frame (a card, a button column).
ui_block :: proc(w: ^World, r: rl.Rectangle) {
	u := &w.ui
	if u.block_count < len(u.blocks) {
		u.blocks[u.block_count] = r
		u.block_count += 1
	}
}

// Registers a widget: returns its id, whether the mouse is over it and whether it fired this frame. The hit area
// grows to UI_MIN_HIT around small widgets. Widgets under an open popup or an overlapping window ignore the mouse.
ui_widget :: proc(w: ^World, r: rl.Rectangle) -> (id: int, hot: bool, fired: bool) {
	u := &w.ui
	u.next_id += 1
	id = u.next_id
	hit := r
	if hit.width < UI_MIN_HIT {
		hit.x -= (UI_MIN_HIT - hit.width) / 2
		hit.width = UI_MIN_HIT
	}
	if hit.height < UI_MIN_HIT {
		hit.y -= (UI_MIN_HIT - hit.height) / 2
		hit.height = UI_MIN_HIT
	}
	m := rl.GetMousePosition()
	hot = u.drag_win == .None && rl.CheckCollisionPointRec(m, hit)
	if !u.in_popup {
		if u.last_popup.width > 0 && rl.CheckCollisionPointRec(m, u.last_popup) do hot = false
		if ui_point_occluded(w, m, u.current_win) do hot = false
	}
	if u.current_win != .None && hot && (rl.IsMouseButtonPressed(.LEFT) || rl.IsMouseButtonDown(.LEFT)) {
		u.win_widget_hit = true
	}
	fired = (hot && rl.IsMouseButtonPressed(.LEFT)) || (u.activate && u.focus == id)
	if fired && u.focus == id do u.activate = false
	return
}

// Clamps a window top-left position inside the screen while keeping at least the top header reachable.
ui_clamp_window :: proc(r: rl.Rectangle, clamp_h: f32) -> [2]f32 {
	sw, sh := f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())
	max_x := max(sw - r.width - WINDOW_MARGIN, WINDOW_MARGIN)
	max_y := max(min(sh - clamp_h - WINDOW_MARGIN, sh - 60), WINDOW_MARGIN)
	return {clamp(r.x, WINDOW_MARGIN, max_x), clamp(r.y, WINDOW_MARGIN, max_y)}
}

// Subtle target outline shown at a window's default snap spot while dragging.
ui_snap_guide :: proc(w: ^World, r: rl.Rectangle, snapped: bool, radius: f32 = 18) {
	pal := palette(w)
	round_rect(w, r, radius, rl.ColorAlpha(pal.accent, snapped ? 0.10 : 0.05))
	round_rect_lines(w, r, radius, snapped ? 2 : 1.5, rl.ColorAlpha(pal.accent, snapped ? 0.65 : 0.40))
}

// Subtle centered drag grip pill at the top of a movable window.
ui_draw_grip :: proc(w: ^World, r: rl.Rectangle, active: bool, light := false) {
	pal := palette(w)
	col := active ? pal.accent : (light ? rl.ColorAlpha(rl.WHITE, 0.35) : pal.line)
	grip := rl.Rectangle{r.x + (r.width - 36) / 2, r.y + 7, 36, 4}
	round_rect(w, grip, 2, col)
}

ui_window_record :: proc(w: ^World, id: Window_Id, rect: rl.Rectangle) {
	u := &w.ui
	u.current_win = id
	u.win_widget_hit = false
	u.win_rects[id] = rect
	if u.win_count < len(u.win_order) {
		u.win_order[u.win_count] = id
		u.win_count += 1
	}
}

// Positions a movable window (snapped to default_rect when !moved, clamped inside the screen), handles dragging
// from its handle strip (or double-clicking the handle to snap back), and records it for z-order occlusion.
ui_window_begin :: proc(
	w: ^World,
	id: Window_Id,
	default_rect: rl.Rectangle,
	handle_h: f32,
	clamp_h: f32 = 0,
	snap_radius: f32 = 18,
) -> rl.Rectangle {
	u := &w.ui
	win := &u.wins[id]
	eff_h := clamp_h > 0 ? clamp_h : default_rect.height
	m := rl.GetMousePosition()

	if u.pending_win == id {
		if !rl.IsMouseButtonDown(.LEFT) {
			u.pending_win = .None
		} else if linalg.length(m - u.drag_start) >= WINDOW_DRAG_PX {
			u.pending_win = .None
			u.drag_win = id
			if !win.moved {
				win.pos = {default_rect.x, default_rect.y}
				win.moved = true
			}
		}
	}

	if u.drag_win == id {
		if rl.IsMouseButtonDown(.LEFT) {
			raw := m - u.drag_offset
			clamped := ui_clamp_window({raw.x, raw.y, default_rect.width, default_rect.height}, eff_h)
			snapped := linalg.length(clamped - {default_rect.x, default_rect.y}) <= WINDOW_SNAP_PX
			win.pos = snapped ? {default_rect.x, default_rect.y} : clamped
			ui_snap_guide(w, default_rect, snapped, snap_radius)
		} else {
			if linalg.length(win.pos - {default_rect.x, default_rect.y}) <= WINDOW_SNAP_PX {
				win.moved = false
			}
			u.drag_win = .None
		}
	}

	rect := default_rect
	if win.moved {
		p := ui_clamp_window({win.pos.x, win.pos.y, default_rect.width, default_rect.height}, eff_h)
		rect = {p.x, p.y, default_rect.width, default_rect.height}
	}

	if u.drag_win == .None && handle_h > 0 {
		handle := rl.Rectangle{rect.x, rect.y, rect.width, handle_h}
		if rl.IsMouseButtonPressed(.LEFT) &&
		   rl.CheckCollisionPointRec(m, handle) &&
		   u.last_popup.width == 0 &&
		   !ui_point_occluded(w, m, id) {
			now := rl.GetTime()
			if win.moved && u.last_click_win == id && now - u.last_click_t < 0.35 {
				win.moved = false
				rect = default_rect
				u.last_click_win = .None
			} else {
				u.last_click_win = id
				u.last_click_t = now
				u.drag_win = id
				u.drag_offset = m - {rect.x, rect.y}
				if !win.moved {
					win.pos = {rect.x, rect.y}
					win.moved = true
				}
			}
		}
	}

	ui_window_record(w, id, rect)
	return rect
}

// Finishes a window: if no internal widget was clicked, pressing on empty body space starts a pending drag.
ui_window_end :: proc(w: ^World, body_drag := true) {
	u := &w.ui
	id := u.current_win
	if id == .None do return
	if body_drag && u.drag_win == .None && u.pending_win == .None && !u.win_widget_hit {
		m := rl.GetMousePosition()
		rect := u.win_rects[id]
		if rl.IsMouseButtonPressed(.LEFT) &&
		   u.last_popup.width == 0 &&
		   rl.CheckCollisionPointRec(m, rect) &&
		   !ui_point_occluded(w, m, id) {
			u.pending_win = id
			u.drag_start = m
			u.drag_offset = m - {rect.x, rect.y}
		}
	}
	u.current_win = .None
}

// Draws the focus ring when the widget has the keyboard focus.
ui_focus_ring :: proc(w: ^World, id: int, r: rl.Rectangle, radius: f32) {
	if w.ui.focus != id do return
	g := f32(UI_FOCUS_RING + 1)
	round_rect_lines(
		w,
		{r.x - g, r.y - g, r.width + 2 * g, r.height + 2 * g},
		radius + g,
		UI_FOCUS_RING,
		palette(w).accent,
	)
}

// raylib's roundness of r for a design radius times the corner scale of the settings (w.look.radius_scale),
// never rounder than a pill. A square drawn fully round is a circle (a round button's shadow, its hover) and stays
// one, the circle on it is drawn without round_rect.
corner_roundness :: proc(w: ^World, r: rl.Rectangle, radius: f32) -> f32 {
	m := min(r.width, r.height)
	if abs(r.width - r.height) < 0.5 && 2 * radius >= m do return 1
	return min(2 * radius * w.look.radius_scale / m, 1)
}

round_rect :: proc(w: ^World, r: rl.Rectangle, radius: f32, color: rl.Color) {
	if min(r.width, r.height) <= 0 do return
	rl.DrawRectangleRounded(r, corner_roundness(w, r, radius), 12, color)
}

round_rect_lines :: proc(w: ^World, r: rl.Rectangle, radius, thick: f32, color: rl.Color) {
	if min(r.width, r.height) <= 0 do return
	rl.DrawRectangleRoundedLinesEx(r, corner_roundness(w, r, radius), 12, thick, color)
}

// The design's floating card shadow (day): two soft grey-blue layers.
ui_shadow :: proc(w: ^World, r: rl.Rectangle, radius: f32) {
	prof_zone(w, .Ui_Shadow)
	base := rl.Color{60, 64, 67, 255}
	layers := [2]struct {
		dy, blur, alpha: f32,
	}{{1, 3, 0.3}, {4, 12, 0.18}}
	for l in layers {
		steps :: 4
		for k in 0 ..< steps {
			grow := l.blur * f32(k + 1) / steps / 2
			c := rl.ColorAlpha(base, l.alpha / steps)
			round_rect(
				w,
				{r.x - grow, r.y + l.dy - grow, r.width + 2 * grow, r.height + 2 * grow},
				radius + grow,
				c,
			)
		}
	}
}

// Floating card: surface, 18 px corners, shadow. Hides the map from the mouse.
ui_card :: proc(w: ^World, r: rl.Rectangle) {
	ui_shadow(w, r, 18)
	round_rect(w, r, 18, palette(w).surface)
	ui_decorate_rect(w, r, 18)
	ui_block(w, r)
}

// Round button: 48 px on the map (surface, icon 24 px), 64 px in navigation (icon 30 px). on: icon in accent.
ui_round_button :: proc(w: ^World, r: rl.Rectangle, icon: Icon, on: bool) -> bool {
	pal := palette(w)
	id, hot, fired := ui_widget(w, r)
	c := [2]f32{r.x + r.width / 2, r.y + r.height / 2}
	ui_shadow(w, r, r.width / 2)
	rl.DrawCircleV(c, r.width / 2, hot ? pal.surface_2 : pal.surface)
	if r.width >= 44 do ui_decorate_circle(w, c, r.width / 2)
	ui_icon(w, icon, c, r.width >= 60 ? 30 : 24, on ? pal.accent : pal.text)
	ui_focus_ring(w, id, r, r.width / 2)
	ui_block(w, r)
	return fired
}

// Pill button, 44 px high (Exit 66 px): Primary = accent fill, Secondary = 1 px line border with accent text,
// Danger = red with white text.
ui_pill_button :: proc(
	w: ^World,
	r: rl.Rectangle,
	text: string,
	kind: Pill_Kind,
	icon := Icon.Close,
	has_icon := false,
) -> bool {
	pal := palette(w)
	id, hot, fired := ui_widget(w, r)
	radius := r.height / 2
	fg: rl.Color
	px := f32(15)
	font := Font.Roboto_500
	switch kind {
	case .Primary:
		round_rect(w, r, radius, hot ? rl.ColorBrightness(pal.accent, 0.1) : pal.accent)
		fg = rl.WHITE
	case .Secondary:
		if hot do round_rect(w, r, radius, pal.surface_2)
		round_rect_lines(w, r, radius, 1, pal.line)
		fg = pal.accent
	case .Danger:
		round_rect(w, r, radius, hot ? rl.ColorBrightness(pal.red, 0.1) : pal.red)
		fg = rl.WHITE
		px = 21
		font = .Figtree_500
	}
	size := ui_text_size(w, text, font, px)
	icon_px := text_px(w, kind == .Danger ? 22 : 20)
	icon_w: f32 = has_icon ? icon_px + 8 : 0
	x := r.x + (r.width - size.x - icon_w) / 2
	if has_icon do ui_icon(w, icon, {x + icon_px / 2, r.y + r.height / 2}, icon_px, fg)
	ui_text(w, {x + icon_w, r.y + (r.height - size.y) / 2}, text, font, px, fg)
	ui_focus_ring(w, id, r, radius)
	return fired
}

// Switch 36 x 20 px, knob 16 px: off surface_3, on accent_strong, the knob slides in 0.15 s.
ui_toggle :: proc(w: ^World, r: rl.Rectangle, on: ^bool) -> bool {
	pal := palette(w)
	id, _, fired := ui_widget(w, r)
	if fired do on^ = !on^
	a := &w.ui.anims[(id - 1) % MAX_UI_ANIMS]
	target: f32 = on^ ? 1 : 0
	step := frame_time(w) / 0.15
	a^ = target > a^ ? min(a^ + step, target) : max(a^ - step, target)
	round_rect(w, r, r.height / 2, on^ ? pal.accent_strong : pal.surface_3)
	knob := r.height - 4
	knob_r := rl.Rectangle{r.x + 2 + a^ * (r.width - 4 - knob), r.y + 2, knob, knob}
	rl.DrawRectangleRounded(knob_r, min(w.look.radius_scale, 1), 12, rl.WHITE)
	ui_focus_ring(w, id, r, r.height / 2)
	return fired
}

// Slider on a 4 px track: drag (shared by the panel's sliders, 0 = none) holds the id of the one being dragged,
// the caller clears it when the mouse button is up. def gets a small mark on the track; the knob turns accent
// when the value is not def.
ui_slider :: proc(w: ^World, track: rl.Rectangle, value: ^f32, lo, hi, def: f32, drag: ^int, id: int) {
	pal := palette(w)
	_, _, fired := ui_widget(w, {track.x, track.y - 8, track.width, 20})
	if fired do drag^ = id
	if drag^ == id {
		k := clamp((rl.GetMousePosition().x - track.x) / track.width, 0, 1)
		value^ = lo + k * (hi - lo)
	}
	changed := abs(value^ - def) > 1e-4
	k := clamp((value^ - lo) / (hi - lo), 0, 1)
	kd := clamp((def - lo) / (hi - lo), 0, 1)
	round_rect(w, track, 2, pal.surface_3)
	round_rect(w, {track.x, track.y, track.width * k, track.height}, 2, pal.accent)
	rl.DrawRectangleV({track.x + track.width * kd - 1, track.y - 4}, {2, 12}, pal.text_2)
	rl.DrawCircleV({track.x + track.width * k, track.y + 2}, 8, changed ? pal.accent : pal.surface)
	rl.DrawCircleLinesV({track.x + track.width * k, track.y + 2}, 8, pal.line)
}

// Slider row of an editor panel, 50 px high: the label and text (the value) on top, the slider under them.
UI_SLIDER_ROW_H :: 50
ui_slider_row :: proc(
	w: ^World,
	x, y, width: f32,
	label, text: string,
	value: ^f32,
	lo, hi, def: f32,
	drag: ^int,
	id: int,
) {
	pal := palette(w)
	ui_text(w, {x, y}, label, .Roboto_400, 13, pal.text)
	size := ui_text_size(w, text, .Mono_400, 12)
	changed := abs(value^ - def) > 1e-4
	ui_text(w, {x + width - size.x, y}, text, .Mono_400, 12, changed ? pal.accent : pal.text_2)
	ui_slider(w, {x, y + 26, width, 4}, value, lo, hi, def, drag, id)
}

// Segment control: a surface_2 bar with 10 px corners, the chosen segment surface with a light shadow.
ui_segment :: proc(w: ^World, r: rl.Rectangle, labels: []string, sel: ^int) -> bool {
	pal := palette(w)
	round_rect(w, r, 10, pal.surface_2)
	changed := false
	seg := r.width / f32(len(labels))
	for label, i in labels {
		s := rl.Rectangle{r.x + f32(i) * seg + 3, r.y + 3, seg - 6, r.height - 6}
		id, _, fired := ui_widget(w, s)
		if fired && sel^ != i {
			sel^ = i
			changed = true
		}
		if sel^ == i {
			ui_shadow(w, s, 8)
			round_rect(w, s, 8, pal.surface)
		}
		size := ui_text_size(w, label, .Roboto_500, 13)
		ui_text(
			w,
			{s.x + (s.width - size.x) / 2, s.y + (s.height - size.y) / 2},
			label,
			.Roboto_500,
			13,
			sel^ == i ? pal.text : pal.text_2,
		)
		ui_focus_ring(w, id, s, 8)
	}
	return changed
}

ui_stat_chip_h :: proc(w: ^World) -> f32 {
	return max(58, 8 + text_line_px(w, 11) + text_px(w, 17) + 10)
}

// Stat chip (navigation sheet): label 11 px capitals, value Roboto Mono 17 px. meter 0..1 draws the 4 px green
// battery meter, meter < 0 none.
ui_stat_chip :: proc(w: ^World, r: rl.Rectangle, label, value: string, meter: f32) {
	pal := palette(w)
	round_rect(w, r, 12, pal.chip)
	y := ui_line(w, {r.x + 12, r.y + 8}, label, .Roboto_400, 11, pal.text_2)
	ui_text(w, {r.x + 12, y}, value, .Mono_600, 17, pal.text)
	if meter >= 0 {
		bar := rl.Rectangle{r.x + 12, r.y + r.height - 10, r.width - 24, 4}
		round_rect(w, bar, 2, pal.surface_3)
		round_rect(w, {bar.x, bar.y, bar.width * clamp(meter, 0, 1), bar.height}, 2, pal.green)
	}
}

// Input field 44 px: 1 px line border, 10 px corners, text 15 px; editing shows a caret. Returns true on click.
// error: a red outline, for a field that has to be filled before going on.
ui_input :: proc(
	w: ^World,
	r: rl.Rectangle,
	text, placeholder: string,
	editing: bool,
	error := false,
) -> bool {
	pal := palette(w)
	id, hot, fired := ui_widget(w, r)
	if editing do round_rect(w, r, 10, pal.surface_2)
	if error {
		round_rect_lines(w, r, 10, 2, pal.red)
	} else {
		round_rect_lines(w, r, 10, 1, editing || hot ? pal.text_2 : pal.line)
	}
	shown := text == "" ? placeholder : text
	size := ui_text_size(w, shown, .Roboto_400, 15)
	pos := [2]f32{r.x + 12, r.y + (r.height - size.y) / 2}
	ui_text(w, pos, shown, .Roboto_400, 15, text == "" ? pal.text_2 : pal.text)
	if editing && int(w.ui.toast_t * 2) % 2 == 0 {
		x := text == "" ? pos.x : pos.x + size.x + 1
		rl.DrawRectangleV({x, pos.y}, {1.5, size.y}, pal.accent)
	}
	ui_focus_ring(w, id, r, 10)
	return fired
}

// Adds typed characters to buf[:n^] and handles backspace. ASCII only (hub names are matched without accents).
ui_text_edit :: proc(buf: []u8, n: ^int) -> (changed: bool) {
	for c := rl.GetCharPressed(); c != 0; c = rl.GetCharPressed() {
		if c >= 32 && c < 127 && n^ < len(buf) {
			buf[n^] = u8(c)
			n^ += 1
			changed = true
		}
	}
	if (rl.IsKeyPressed(.BACKSPACE) || rl.IsKeyPressedRepeat(.BACKSPACE)) && n^ > 0 {
		n^ -= 1
		changed = true
	}
	return
}

// Zoom pill 48 x 92: + and - separated by a line, hover per half. Returns +1, -1 or 0.
ui_zoom_pill :: proc(w: ^World, r: rl.Rectangle) -> int {
	pal := palette(w)
	ui_shadow(w, r, 24)
	round_rect(w, r, 24, pal.surface)
	ui_block(w, r)
	out := 0
	for half in 0 ..< 2 {
		h := rl.Rectangle{r.x, r.y + f32(half) * r.height / 2, r.width, r.height / 2}
		id, hot, fired := ui_widget(w, h)
		if hot do round_rect(w, h, 24, pal.surface_2)
		if hot do ui_tip_set(w, h, half == 0 ? "Zoom in" : "Zoom out")
		ui_icon(w, half == 0 ? .Plus : .Minus, {h.x + h.width / 2, h.y + h.height / 2}, 24, pal.text)
		ui_focus_ring(w, id, h, 24)
		if fired do out = half == 0 ? 1 : -1
	}
	rl.DrawLineEx({r.x + 10, r.y + r.height / 2}, {r.x + r.width - 10, r.y + r.height / 2}, 1, pal.line)
	return out
}

// Map type tile in the layers panel: surface_2, 12 px corners, preview 54 px high, chosen = 2 px accent border.
ui_tile :: proc(w: ^World, r: rl.Rectangle, label: string, preview: rl.Color, on: bool) -> bool {
	pal := palette(w)
	id, hot, fired := ui_widget(w, r)
	round_rect(w, r, 12, hot ? pal.surface_3 : pal.surface_2)
	round_rect(w, {r.x + 6, r.y + 6, r.width - 12, 54}, 8, preview)
	size := ui_text_size(w, label, .Roboto_500, 13)
	ui_text(w, {r.x + (r.width - size.x) / 2, r.y + 66}, label, .Roboto_500, 13, pal.text)
	if on do round_rect_lines(w, r, 12, 2, pal.accent)
	ui_focus_ring(w, id, r, 12)
	return fired
}

// Shows a toast for TOAST_S (design: 22 px from the top, #303134, fades in and out in 0.25 s).
ui_toast :: proc(w: ^World, text: string) {
	u := &w.ui
	u.toast_len = copy(u.toast[:], text)
	u.toast_t = 0
}

// Drawn last in the frame.
ui_toast_draw :: proc(w: ^World) {
	u := &w.ui
	if u.toast_len == 0 || u.toast_t > TOAST_S + 2 * TOAST_FADE_S do return
	alpha := clamp(min(u.toast_t, TOAST_S + 2 * TOAST_FADE_S - u.toast_t) / TOAST_FADE_S, 0, 1)
	text := string(u.toast[:u.toast_len])
	size := ui_text_size(w, text, .Roboto_400, 14)
	r := rl.Rectangle{(f32(rl.GetScreenWidth()) - size.x) / 2 - 16, 22, size.x + 32, size.y + 20}
	round_rect(w, r, 10, rl.ColorAlpha({48, 49, 52, 255}, alpha))
	ui_text(w, {r.x + 16, r.y + 10}, text, .Roboto_400, 14, rl.ColorAlpha({232, 234, 237, 255}, alpha))
}

// Records a hover tooltip for r when the mouse is over it; drawn at the end of the frame by ui_tip_draw.
ui_tip :: proc(w: ^World, r: rl.Rectangle, text: string) {
	u := &w.ui
	if u.drag_win != .None do return
	m := rl.GetMousePosition()
	if !u.in_popup {
		if u.last_popup.width > 0 && rl.CheckCollisionPointRec(m, u.last_popup) do return
		if ui_point_occluded(w, m, u.current_win) do return
	}
	if rl.CheckCollisionPointRec(m, r) do ui_tip_set(w, r, text)
}

ui_tip_set :: proc(w: ^World, r: rl.Rectangle, text: string) {
	u := &w.ui
	n := min(len(text), len(u.tip_buf))
	copy(u.tip_buf[:n], text[:n])
	u.tip_len = n
	u.tip_rect = r
}

ui_tip_draw :: proc(w: ^World) {
	u := &w.ui
	if u.tip_len == 0 do return
	pal := palette(w)
	full := string(u.tip_buf[:u.tip_len])
	max_w: f32
	lines := 0
	rest := full
	for line in strings.split_lines_iterator(&rest) {
		font: Font = lines == 0 ? .Figtree_600 : .Roboto_400
		max_w = max(max_w, ui_text_size(w, line, font, 12).x)
		lines += 1
	}
	if lines == 0 do return
	pad_x, pad_y :: f32(12), f32(8)
	lh := text_line_px(w, 12)
	box_w := max_w + 2 * pad_x
	box_h := f32(lines) * lh + 2 * pad_y - (lh - text_px(w, 12))
	sw, sh := f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())
	r := u.tip_rect
	x := clamp(r.x + (r.width - box_w) / 2, 12, max(sw - box_w - 12, 12))
	y := r.y - box_h - 8
	if y < 12 do y = min(r.y + r.height + 8, max(sh - box_h - 12, 12))
	box := rl.Rectangle{x, y, box_w, box_h}
	ui_shadow(w, box, 10)
	round_rect(w, box, 10, pal.surface)
	round_rect_lines(w, box, 10, 1, pal.line)
	rest = full
	i := 0
	for line in strings.split_lines_iterator(&rest) {
		font: Font = i == 0 ? .Figtree_600 : .Roboto_400
		col := i == 0 ? pal.text : pal.text_2
		ui_text(w, {box.x + pad_x, box.y + pad_y + f32(i) * lh}, line, font, 12, col)
		i += 1
	}
}

Battery_Badge :: struct {
	charge: f32,
	bv:     string,
	bvs:    [2]f32,
	bus:    [2]f32,
	h:      f32,
	dia:    f32,
}

// Measures the circular battery gauge so callers can reserve space alongside other HUD elements.
ui_battery_badge :: proc(w: ^World, min_dia: f32) -> Battery_Badge {
	charge := clamp(ship_battery_kwh(&w.ship) / BATTERY_KWH, 0, 1)
	bv := fmt.tprintf("%.0f%%", charge * 100)
	bvs := ui_text_size(w, bv, .Figtree_700, 20)
	bus := ui_text_size(w, "battery", .Figtree_700, 10)
	h := bvs.y + bus.y + 2
	dia := max(min_dia, h + 18, max(bvs.x, bus.x) + 18)
	return {charge = charge, bv = bv, bvs = bvs, bus = bus, h = h, dia = dia}
}

// Draws the circular battery gauge (wavy elixir fill + charge ring) centred at c.
ui_battery_circle :: proc(w: ^World, c: [2]f32, dia: f32, b: Battery_Badge, alpha: f32 = 1) {
	pal := palette(w)
	r := dia / 2
	if alpha >= 0.99 do ui_shadow(w, {c.x - r, c.y - r, dia, dia}, r)
	rl.DrawCircleV(c, r, alpha < 1 ? rl.ColorAlpha(pal.surface, alpha) : pal.surface)

	liquid := b.charge < 0.2 ? pal.warning : pal.green
	ir := r - 6
	if b.charge > 0.005 && ir > 2 {
		t := f32(rl.GetTime())
		y_base := c.y + ir - 2 * ir * b.charge
		amp := min(f32(2.6), 16 * b.charge * (1 - b.charge))
		draw_wave :: proc(c: [2]f32, ir, y_base, amp, freq, phase: f32, col: rl.Color) {
			SLICES :: 32
			for i in 0 ..< SLICES {
				x0 := -ir + 2 * ir * f32(i) / SLICES
				x1 := -ir + 2 * ir * f32(i + 1) / SLICES
				d0 := math.sqrt(max(ir * ir - x0 * x0, 0))
				d1 := math.sqrt(max(ir * ir - x1 * x1, 0))
				y0 := clamp(y_base + amp * math.sin(x0 * freq + phase), c.y - d0, c.y + d0)
				y1 := clamp(y_base + amp * math.sin(x1 * freq + phase), c.y - d1, c.y + d1)
				p00 := [2]f32{c.x + x0, y0}
				p01 := [2]f32{c.x + x0, c.y + d0}
				p11 := [2]f32{c.x + x1, c.y + d1}
				p10 := [2]f32{c.x + x1, y1}
				rl.DrawTriangle(p00, p01, p11, col)
				rl.DrawTriangle(p00, p11, p10, col)
			}
		}
		draw_wave(c, ir, y_base, amp * 0.8, 0.14, -t * 2.3 + 1.4, rl.ColorAlpha(liquid, 0.20 * alpha))
		draw_wave(c, ir, y_base, amp, 0.17, t * 3.1, rl.ColorAlpha(liquid, 0.34 * alpha))
	}

	track := alpha < 1 ? rl.ColorAlpha(pal.surface_3, alpha) : pal.surface_3
	rl.DrawRing(c, r - 6, r - 2, 0, 360, 48, track)
	rl.DrawRing(c, r - 6, r - 2, -90, -90 + 360 * b.charge, 48, rl.ColorAlpha(liquid, alpha))
	ui_decorate_circle(w, c, r, alpha)
	top := c.y - b.h / 2
	ui_text(w, {c.x - b.bvs.x / 2, top}, b.bv, .Figtree_700, 20, pal.text)
	ui_text(w, {c.x - b.bus.x / 2, top + b.bvs.y + 2}, "battery", .Figtree_700, 10, pal.text_2)
}

// Draws a pointed botanical leaf from stem along unit vector dir, scaled by length and width.
ui_draw_leaf :: proc(stem, dir: [2]f32, length, width: f32, color: rl.Color) {
	perp := [2]f32{-dir.y, dir.x}
	tip := stem + dir * length
	mid := stem + dir * (length * 0.45)
	hw := width * 0.5
	// Negative 2D cross-product winding for raylib's y-down screen coordinates.
	rl.DrawTriangle(stem, tip, mid - perp * hw, color)
	rl.DrawTriangle(stem, mid + perp * hw, tip, color)
}

// Draws Solarpunk ornamentation (Brass, Botanical, Sunburst) inside/around a rectangular widget.
ui_decorate_rect :: proc(w: ^World, r: rl.Rectangle, radius: f32, alpha: f32 = 1) {
	orn := w.look.ornament
	if orn == .None || min(r.width, r.height) < 28 do return
	detail := clamp(w.look.ornament_detail, 0.25, 2)
	trim := rl.ColorAlpha(w.look.ornament_color, alpha * 0.8)
	leaf := rl.ColorAlpha(w.look.leaf_color, alpha * 0.9)
	line_w := max(f32(1), 1.3 * detail)

	inset := min(f32(4), min(r.width, r.height) * 0.12)
	ir := rl.Rectangle{r.x + inset, r.y + inset, r.width - 2 * inset, r.height - 2 * inset}
	in_r := max(radius - inset, 0)
	round_rect_lines(w, ir, in_r, line_w * 0.85, rl.ColorAlpha(trim, 0.55))

	if !w.look.corner_brackets do return
	arm := min(14 * detail, min(ir.width, ir.height) * 0.28)
	off := min(in_r * corner_scale_factor(w) * 0.22, arm * 0.35)
	corners := [4]struct {
		pos, dir: [2]f32,
	} {
		{{ir.x, ir.y}, {1, 1}},
		{{ir.x + ir.width, ir.y}, {-1, 1}},
		{{ir.x, ir.y + ir.height}, {1, -1}},
		{{ir.x + ir.width, ir.y + ir.height}, {-1, -1}},
	}
	for c, i in corners {
		p := c.pos + c.dir * off
		hx := [2]f32{c.dir.x, 0}
		vy := [2]f32{0, c.dir.y}
		switch orn {
		case .None:
		case .Brass:
			rl.DrawLineEx(p, p + hx * arm, line_w, trim)
			rl.DrawLineEx(p, p + vy * arm, line_w, trim)
			rl.DrawCircleV(p, 2.2 * detail, trim)
		case .Botanical:
			rl.DrawLineEx(p, p + hx * (arm * 0.7), line_w * 0.9, trim)
			rl.DrawLineEx(p, p + vy * (arm * 0.7), line_w * 0.9, trim)
			// Full leaf pair on top-left and bottom-right corners; small bud elsewhere to stay uncluttered.
			if i == 0 || i == 3 || min(ir.width, ir.height) >= 120 {
				l_len := min(10 * detail, arm * 0.85)
				d1 := linalg.normalize([2]f32{c.dir.x, c.dir.y * 0.35})
				d2 := linalg.normalize([2]f32{c.dir.x * 0.35, c.dir.y})
				ui_draw_leaf(p + hx * 2, d1, l_len, l_len * 0.45, leaf)
				ui_draw_leaf(p + vy * 2, d2, l_len, l_len * 0.45, leaf)
			}
			rl.DrawCircleV(p, 2.0 * detail, trim)
		case .Sunburst:
			rays :: 4
			ray_len := min(12 * detail, arm)
			base := math.atan2(c.dir.y, c.dir.x)
			for k in 0 ..< rays {
				a := base + (f32(k) - 1.5) * 0.38
				d := [2]f32{math.cos(a), math.sin(a)}
				l := k % 2 == 0 ? ray_len : ray_len * 0.68
				rl.DrawLineEx(p + d * (2.5 * detail), p + d * l, line_w * 0.85, trim)
			}
			rl.DrawCircleV(p, 2.4 * detail, trim)
		}
	}
}

corner_scale_factor :: proc(w: ^World) -> f32 {
	return clamp(w.look.radius_scale, 0, SETTINGS_MAX_RADIUS_SCALE)
}

// Draws Solarpunk ornamentation (bezel ring, radial dial ticks, petals, sun flares) around a circular widget.
ui_decorate_circle :: proc(w: ^World, c: [2]f32, r: f32, alpha: f32 = 1) {
	orn := w.look.ornament
	if orn == .None || r < 14 do return
	detail := clamp(w.look.ornament_detail, 0.25, 2)
	trim := rl.ColorAlpha(w.look.ornament_color, alpha * 0.85)
	leaf := rl.ColorAlpha(w.look.leaf_color, alpha * 0.92)
	line_w := max(f32(1), 1.3 * detail)

	// Rim brass bezel around the circle edge.
	rl.DrawRing(c, max(r - 1.2, 1), r + line_w * 0.7, 0, 360, 48, trim)

	if w.look.dial_ticks {
		ticks :: 12
		for k in 0 ..< ticks {
			a := f32(k) * (math.TAU / ticks)
			d := [2]f32{math.cos(a), math.sin(a)}
			major := k % 3 == 0
			len := (major ? 5.0 : 3.0) * detail
			col := major ? trim : rl.ColorAlpha(trim, 0.55)
			rl.DrawLineEx(c + d * (r + 0.5), c + d * (r + len), major ? line_w : line_w * 0.75, col)
		}
	}

	switch orn {
	case .None:
	case .Brass:
		for k in 0 ..< 4 {
			a := f32(k) * (math.TAU / 4)
			d := [2]f32{math.cos(a), math.sin(a)}
			rl.DrawCircleV(c + d * (r + 0.5), 2.3 * detail, trim)
		}
	case .Botanical:
		// Twin asymmetrical vine sprigs hugging opposite arcs of the circle.
		sprigs := [2]f32{-0.75, 2.39}
		for base_a in sprigs {
			for k in -1 ..= 1 {
				a := base_a + f32(k) * 0.24
				tang := [2]f32{-math.sin(a), math.cos(a)}
				radial := [2]f32{math.cos(a), math.sin(a)}
				stem := c + radial * (r + 1.5)
				ldir := linalg.normalize(tang * (k == 0 ? 0.6 : 0.9) + radial * 0.45)
				l_len := (k == 0 ? 9.5 : 7.0) * detail
				ui_draw_leaf(stem, ldir, l_len, l_len * 0.46, leaf)
			}
			rl.DrawCircleV(c + [2]f32{math.cos(base_a), math.sin(base_a)} * (r + 1), 2.1 * detail, trim)
		}
	case .Sunburst:
		rays :: 16
		for k in 0 ..< rays {
			a := f32(k) * (math.TAU / rays)
			d := [2]f32{math.cos(a), math.sin(a)}
			l := (k % 2 == 0 ? 6.5 : 3.8) * detail
			rl.DrawLineEx(c + d * (r + 0.5), c + d * (r + l), line_w * 0.85, trim)
		}
	}
}
