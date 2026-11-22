package game

import "base:runtime"
import "core:fmt"
import "core:hash"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:reflect"
import "core:strconv"
import "core:strings"
import rl "vendor:raylib"

// Stored settings (nasr, 2026-11-22): the values of the settings panel in three layers, each on top of the one
// before:
//   1. the code: tune_defaults, border_edit_defaults, cloud_edit_defaults, wind_edit_defaults,
//      grass_edit_defaults, view_edit_defaults, look_defaults (the design's values)
//   2. assets/settings.txt, embedded in every build: the project's settings, what the release and the tests
//      run with. Written by Bake in the panel, shipped by committing it.
//   3. cache/settings.txt: this machine's own, saved by the panel after every change. Debug builds only (the
//      panel is debug only), never in headless runs, tests or scripted runs.
// A file holds one "group.field = value" line per value that differs from the layers under it, an enumerated
// array one line per entry ("borders.width.belgium_land = 0.8"). Keys are the field names (core:reflect), so a
// new field is stored without more code. Floats, bools, enums (by name), colors (#RRGGBB, #RRGGBBAA). A line
// that does not fit (a renamed field, a bad value) is logged and skipped, a missing file is no error.
SETTINGS_LOCAL_PATH :: "cache/settings.txt"
SETTINGS_PROJECT_PATH :: "assets/settings.txt"
SETTINGS_PROJECT :: #load("../../assets/settings.txt", string)
SETTINGS_HEADER :: "# Drift settings: only what differs from the layer below (settings_store.odin). Written by the settings panel (F2).\n"

Setting_Values :: struct {
	tune:    Tune,
	borders: Border_Edit,
	clouds:  Cloud_Edit,
	wind:    Wind_Edit,
	grass:   Grass_Edit,
	view:    View_Edit,
	look:    Look,
}

// Where a set of setting values lives: World keeps the current ones in separate fields.
Setting_Ptrs :: struct {
	tune:    ^Tune,
	borders: ^Border_Edit,
	clouds:  ^Cloud_Edit,
	wind:    ^Wind_Edit,
	grass:   ^Grass_Edit,
	view:    ^View_Edit,
	look:    ^Look,
}

Store_Group :: struct {
	name: string,
	data: rawptr,
	type: typeid,
	skip: string, // a field stored as its own group
}

settings_code_defaults :: proc() -> Setting_Values {
	return {
		tune = tune_defaults(),
		borders = border_edit_defaults(),
		clouds = cloud_edit_defaults(),
		wind = wind_edit_defaults(),
		grass = grass_edit_defaults(),
		view = view_edit_defaults(),
		look = look_defaults(),
	}
}

values_ptrs :: proc(v: ^Setting_Values) -> Setting_Ptrs {
	return {&v.tune, &v.borders, &v.clouds, &v.wind, &v.grass, &v.view, &v.look}
}

current_ptrs :: proc(w: ^World) -> Setting_Ptrs {
	return {&w.tune, &w.border_edit, &w.cloud_edit, &w.wind_edit, &w.grass_edit, &w.view_edit, &w.look}
}

current_values :: proc(w: ^World) -> Setting_Values {
	return {w.tune, w.border_edit, w.cloud_edit, w.wind_edit, w.grass_edit, w.view_edit, w.look}
}

store_groups :: proc(p: Setting_Ptrs) -> [8]Store_Group {
	return {
		{"speed", p.tune, Tune, ""},
		{"borders", p.borders, Border_Edit, ""},
		{"clouds", p.clouds, Cloud_Edit, ""},
		{"wind", p.wind, Wind_Edit, ""},
		{"grass", p.grass, Grass_Edit, ""},
		{"view", p.view, View_Edit, ""},
		{"colors", &p.look.palette, Palette, ""},
		{"look", p.look, Look, "palette"},
	}
}

// Layers 1 and 2, into w.setting_defaults (what Reset and the sliders' default marks use) and the current
// values. From game_init, so headless runs and tests get them too.
settings_init :: proc(w: ^World) {
	context.temp_allocator = virtual.arena_allocator(&w.frame)
	w.setting_defaults = settings_code_defaults()
	settings_parse(w, SETTINGS_PROJECT, values_ptrs(&w.setting_defaults), SETTINGS_PROJECT_PATH)
	d := &w.setting_defaults
	w.tune, w.border_edit, w.cloud_edit, w.wind_edit, w.grass_edit, w.view_edit, w.look =
		d.tune, d.borders, d.clouds, d.wind, d.grass, d.view, d.look
}

// Layer 3 on top of the current values. Returns how many values it set.
settings_load_local :: proc(w: ^World) -> int {
	data, err := os.read_entire_file(SETTINGS_LOCAL_PATH, context.temp_allocator)
	if err != nil do return 0
	return settings_parse(w, string(data), current_ptrs(w), SETTINGS_LOCAL_PATH)
}

// The file text: SETTINGS_HEADER, then a line for every value of cur that differs from base, in field order.
settings_text :: proc(cur, base: Setting_Ptrs) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, SETTINGS_HEADER)
	cg, bg := store_groups(cur), store_groups(base)
	for g, gi in cg {
		for f in reflect.struct_fields_zipped(g.type) {
			if f.name == g.skip do continue
			a := uintptr(g.data) + f.offset
			b := uintptr(bg[gi].data) + f.offset
			if ea, ok := runtime.type_info_base(f.type).variant.(runtime.Type_Info_Enumerated_Array); ok {
				for i in 0 ..< ea.count {
					name := enum_name_at(ea.index, ea.min_value + runtime.Type_Info_Enum_Value(i))
					key := fmt.tprintf("%s.%s.%s", g.name, f.name, name)
					at := uintptr(i * ea.elem_size)
					store_line(&sb, key, rawptr(a + at), rawptr(b + at), ea.elem)
				}
				continue
			}
			store_line(&sb, fmt.tprintf("%s.%s", g.name, f.name), rawptr(a), rawptr(b), f.type)
		}
	}
	return strings.to_string(sb)
}

store_line :: proc(sb: ^strings.Builder, key: string, a, b: rawptr, ti: ^runtime.Type_Info) {
	if mem.compare_ptrs(a, b, ti.size) == 0 do return
	if text, ok := store_value_text(a, ti); ok do fmt.sbprintf(sb, "%s = %s\n", key, text)
}

// Applies every "key = value" line of text to p; source names the file in the log. Returns the values set.
settings_parse :: proc(w: ^World, text: string, p: Setting_Ptrs, source: string) -> (applied: int) {
	groups := store_groups(p)
	rest := text
	line_no := 0
	for raw in strings.split_lines_iterator(&rest) {
		line_no += 1
		line := strings.trim_space(raw)
		if line == "" || line[0] == '#' do continue
		eq := strings.index_byte(line, '=')
		ok :=
			eq > 0 && store_set(groups[:], strings.trim_space(line[:eq]), strings.trim_space(line[eq + 1:]))
		if ok {
			applied += 1
		} else {
			logf(w, "settings", "%s:%d: cannot use %q, skipped", source, line_no, line)
		}
	}
	return
}

store_set :: proc(groups: []Store_Group, key, value: string) -> bool {
	parts := strings.split(key, ".", context.temp_allocator)
	if len(parts) < 2 || len(parts) > 3 do return false
	for g in groups {
		if g.name != parts[0] do continue
		for f in reflect.struct_fields_zipped(g.type) {
			if f.name == g.skip || f.name != parts[1] do continue
			at := uintptr(g.data) + f.offset
			if ea, ok := runtime.type_info_base(f.type).variant.(runtime.Type_Info_Enumerated_Array); ok {
				if len(parts) != 3 do return false
				v, found := enum_value_of(ea.index, parts[2])
				if !found do return false
				return store_value_parse(
					rawptr(at + uintptr(int(v - ea.min_value) * ea.elem_size)),
					ea.elem,
					value,
				)
			}
			return len(parts) == 2 && store_value_parse(rawptr(at), f.type, value)
		}
	}
	return false
}

store_value_text :: proc(p: rawptr, ti: ^runtime.Type_Info) -> (string, bool) {
	if ti.id == rl.Color {
		c := (^rl.Color)(p)^
		if c.a == 255 do return fmt.tprintf("#%02X%02X%02X", c.r, c.g, c.b), true
		return fmt.tprintf("#%02X%02X%02X%02X", c.r, c.g, c.b, c.a), true
	}
	#partial switch v in runtime.type_info_base(ti).variant {
	case runtime.Type_Info_Float:
		if ti.size == 4 do return fmt.tprintf("%v", (^f32)(p)^), true
	case runtime.Type_Info_Boolean:
		return (^bool)(p)^ ? "true" : "false", true
	case runtime.Type_Info_Enum:
		return enum_name_at(ti, enum_read(p, ti.size)), true
	}
	return "", false
}

store_value_parse :: proc(p: rawptr, ti: ^runtime.Type_Info, text: string) -> bool {
	if ti.id == rl.Color {
		if len(text) != 7 && len(text) != 9 || text[0] != '#' do return false
		v, ok := strconv.parse_u64_of_base(text[1:], 16)
		if !ok do return false
		if len(text) == 7 do v = v << 8 | 0xff
		(^rl.Color)(p)^ = {u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v)}
		return true
	}
	#partial switch v in runtime.type_info_base(ti).variant {
	case runtime.Type_Info_Float:
		if ti.size != 4 do return false
		f, ok := strconv.parse_f32(text)
		if ok do (^f32)(p)^ = f
		return ok
	case runtime.Type_Info_Boolean:
		b, ok := strconv.parse_bool(text)
		if ok do (^bool)(p)^ = b
		return ok
	case runtime.Type_Info_Enum:
		e, found := enum_value_of(ti, text)
		if found do enum_write(p, ti.size, e)
		return found
	}
	return false
}

// The lower case name of an enum value ("Belgium_Land" -> "belgium_land"), "" when it has none.
enum_name_at :: proc(ti: ^runtime.Type_Info, value: runtime.Type_Info_Enum_Value) -> string {
	e, ok := runtime.type_info_base(ti).variant.(runtime.Type_Info_Enum)
	if !ok do return ""
	for name, k in e.names {
		if e.values[k] == value do return strings.to_lower(name, context.temp_allocator)
	}
	return ""
}

enum_value_of :: proc(ti: ^runtime.Type_Info, name: string) -> (runtime.Type_Info_Enum_Value, bool) {
	e, ok := runtime.type_info_base(ti).variant.(runtime.Type_Info_Enum)
	if !ok do return 0, false
	for n, k in e.names {
		if strings.equal_fold(n, name) do return e.values[k], true
	}
	return 0, false
}

enum_read :: proc(p: rawptr, size: int) -> runtime.Type_Info_Enum_Value {
	switch size {
	case 1:
		return runtime.Type_Info_Enum_Value((^u8)(p)^)
	case 2:
		return runtime.Type_Info_Enum_Value((^u16)(p)^)
	case 4:
		return runtime.Type_Info_Enum_Value((^u32)(p)^)
	}
	return runtime.Type_Info_Enum_Value((^i64)(p)^)
}

enum_write :: proc(p: rawptr, size: int, v: runtime.Type_Info_Enum_Value) {
	switch size {
	case 1:
		(^u8)(p)^ = u8(v)
	case 2:
		(^u16)(p)^ = u16(v)
	case 4:
		(^u32)(p)^ = u32(v)
	case:
		(^i64)(p)^ = i64(v)
	}
}

// What differs from the project's settings, the text cache/settings.txt holds, and its hash.
settings_local_text :: proc(w: ^World) -> (text: string, sum: u64) {
	text = settings_text(current_ptrs(w), values_ptrs(&w.setting_defaults))
	return text, hash.fnv64a(transmute([]u8)text)
}

settings_save_local :: proc(w: ^World, text: string) -> bool {
	_ = os.make_directory_all("cache")
	if err := os.write_entire_file(SETTINGS_LOCAL_PATH, text); err != nil {
		logf(w, "settings", "cannot save %s: %v", SETTINGS_LOCAL_PATH, err)
		return false
	}
	return true
}

// Bake: everything that differs from the code into assets/settings.txt (relative to the repo root, where a
// debug build runs). The current values become the project's settings, so the local file empties on the next
// save. Shipped once the file is committed: every build embeds it.
settings_bake :: proc(w: ^World) -> bool {
	code := settings_code_defaults()
	text := settings_text(current_ptrs(w), values_ptrs(&code))
	if err := os.write_entire_file(SETTINGS_PROJECT_PATH, text); err != nil {
		logf(w, "settings", "cannot write %s: %v", SETTINGS_PROJECT_PATH, err)
		return false
	}
	w.setting_defaults = current_values(w)
	return true
}
